# ─────────────────────────────────────────────────────────────
# api_order.py
#
# PURPOSE:
#   Create a POS Order from the Flutter app.
#
# KEY FIX (session_id consistency):
#   The Flutter app lets the cashier select a POS Session in Settings.
#   The same session_id is sent in EVERY order payload.
#   The order is created in THAT session — not auto-detected.
#
#   This ensures:
#     - Product screen shows session's products  (/api/products?session_id=X)
#     - Order is created in the same session      (/api/order with session_id=X)
#     - Both sides are always in sync.
# ─────────────────────────────────────────────────────────────

import json
import jwt
import logging
from odoo import http
from odoo.http import request

_logger = logging.getLogger(__name__)


class PosApiController(http.Controller):

    # ──────────────────────────────────────────────────────────
    # HELPER: Standard JSON response
    # ──────────────────────────────────────────────────────────
    def _json_response(self, status="success", data=None,
                       message="", code=200):
        return request.make_response(
            json.dumps({
                "status": status,
                "data":   data or {},
                "message": message,
                "code":   code,
            }),
            headers=[('Content-Type', 'application/json')],
            status=code,
        )

    # ──────────────────────────────────────────────────────────
    # HELPER: Validate JWT Bearer token
    # 
    # SECURITY NOTES:
    #   - Checks Authorization header for "Bearer <token>"
    #   - Validates token signature with JWT secret
    #   - Updates Odoo environment to authenticated user
    #   - Logs failures for security monitoring
    # ──────────────────────────────────────────────────────────
    def _validate_token(self):
        """
        Read the Authorization header, decode the JWT,
        and switch the Odoo env to that user.
        
        Returns:
            True if token is valid and user exists
            False otherwise
        """
        auth = request.httprequest.headers.get('Authorization', '')
        
        if not auth.startswith('Bearer '):
            _logger.warning(
                'Missing or invalid Authorization header from IP: %s for endpoint: %s',
                request.httprequest.remote_addr,
                request.httprequest.path,
            )
            return False
        
        token = auth[7:]
        
        try:
            secret = request.env['jwt.config'].sudo().get_secret_key()
            payload = jwt.decode(token, secret, algorithms=['HS256'])
            user_id = payload.get('user_id')
            user = request.env['res.users'].sudo().browse(user_id)
            
            if not user.exists():
                _logger.warning(
                    'JWT token with invalid user_id (%s) for %s from IP: %s',
                    user_id,
                    request.httprequest.path,
                    request.httprequest.remote_addr,
                )
                return False
            
            # --- NEW: Check for POS group membership ---
            # Ensure the authenticated user has either 'Point of Sale / User' or 'Point of Sale / Administrator' group.
            # This prevents users without POS access from using POS APIs.
            has_pos_user_group = user.has_group('point_of_sale.group_pos_user')
            has_pos_manager_group = user.has_group('point_of_sale.group_pos_manager')
            has_system_admin_group = user.has_group('base.group_system')

            if not (has_pos_user_group or has_pos_manager_group):
                _logger.warning(
                    'User %s (ID: %s) does not have POS access for %s from IP: %s',
                    user.login,
                    user_id,
                    request.httprequest.path,
                    request.httprequest.remote_addr,
                )
                # Security Audit: Log unauthorized POS access attempt to database
                self._log(
                    {'login': user.login, 'user_id': user_id, 'event': 'POS_ACCESS_DENIED'},
                    {'status': 'error', 'message': f'Access Denied for endpoint: {request.httprequest.path}'},
                    'error'
                )
                return False # User is authenticated but not authorized for POS

            request.update_env(user=user)
            return True
            
        except jwt.ExpiredSignatureError:
            _logger.warning(
                'Expired JWT token used for %s from IP: %s',
                request.httprequest.path,
                request.httprequest.remote_addr,
            )
            return False
        except jwt.InvalidTokenError as exc:
            _logger.warning(
                'Invalid JWT token for %s from IP: %s: %s',
                request.httprequest.path,
                request.httprequest.remote_addr,
                exc,
            )
            return False
        except Exception as exc:  # pylint: disable=broad-except
            _logger.exception(
                'JWT validation error for %s from IP: %s: %s',
                request.httprequest.path,
                request.httprequest.remote_addr,
                exc,
            )
            return False

    # ──────────────────────────────────────────────────────────
    # HELPER: Write a sync log entry
    # ──────────────────────────────────────────────────────────
    def _log(self, payload, response, status):
        """Write a sync log entry without interrupting the API flow."""
        try:
            safe_payload = payload if isinstance(payload, dict) else {}
            safe_payload = dict(safe_payload)
            for key in ('password', 'token', 'access_token', 'refresh_token'):
                if key in safe_payload:
                    safe_payload[key] = '***REDACTED***'

            request.env['sync.log'].sudo().create({
                'endpoint': request.httprequest.path,
                'method':   request.httprequest.method,
                'payload':  json.dumps(safe_payload, indent=4),
                'response': json.dumps(response, indent=4),
                'status':   status,
            })
        except Exception as exc:  # pylint: disable=broad-except
            _logger.error('Failed to write sync log: %s', exc)

    # ──────────────────────────────────────────────────────────
    # HELPER: Resolve product_id to a product.product record
    #
    # Flutter may send either a product.product id or a
    # product.template id. We handle both cases.
    # ──────────────────────────────────────────────────────────
    def _resolve_product(self, product_id):
        """Resolve product from ID (handles both product and template)."""
        # First: try as product.product (variant)
        product = request.env['product.product'].sudo().browse(product_id)
        if product.exists():
            return product
        # Fallback: treat as product.template id → take the first variant
        template = request.env['product.template'].sudo().browse(product_id)
        if template.exists() and template.product_variant_ids:
            return template.product_variant_ids[0]
        return None

    # ──────────────────────────────────────────────────────────
    # HELPER: Resolve and validate the POS session
    #
    # WHY REQUIRED:
    #   The cashier picks a session in the Flutter Settings screen.
    #   Every order MUST go into THAT session so products, payment
    #   methods, and the Odoo cashier report all stay consistent.
    #
    # WHAT WE CHECK:
    #   1. session_id is present in the payload (required)
    #   2. The session exists in Odoo
    #   3. The session is still in 'opened' state
    # ──────────────────────────────────────────────────────────
    def _resolve_session(self, session_id):
        """
        Returns (session, error_message).
        session       = pos.session record if valid, else None
        error_message = None if OK, string if invalid
        """
        if not session_id:
            return None, (
                'session_id is required. '
                'Please select a POS Session in the app Settings.'
            )

        session = request.env['pos.session'].sudo().browse(session_id)

        if not session.exists():
            return None, f'POS Session {session_id} does not exist.'
            
        # Security Check: Ensure the user calling the API is allowed to use this session.
        # Usually, this means the user is the one who opened it or is a POS manager.
        current_user = request.env.user
        if (
            session.user_id != current_user
            and not current_user.has_group('point_of_sale.group_pos_manager')
            and not current_user.has_group('base.group_system')
        ):
            return None, (
                f'Unauthorized: User {current_user.name} does not have access to Session "{session.name}".'
            )

        if session.state != 'opened':
            return None, (
                f'POS Session "{session.name}" is {session.state}, not open. '
                'Please select an open session in Settings.'
            )

        return session, None

    # ──────────────────────────────────────────────────────────
    # POST /api/order
    #
    # Expected JSON body:
    # {
    #   "session_id":   5,          ← REQUIRED: session chosen in Settings
    #   "external_id":  "APP-001",  ← unique order ID from Flutter
    #   "device_code":  "DEVICE-01",
    #   "customer_id":  12,         ← optional partner_id
    #   "lines": [
    #     {
    #       "product_id": 45,
    #       "qty":        2,
    #       "price":      150.0,
    #       "tax_rate":   5.0
    #     }
    #   ],
    #   "payments": [
    #     { "method": "Cash", "amount": 300.0 }
    #   ]
    # }
    # ──────────────────────────────────────────────────────────
    @http.route('/api/order', type='http', auth='public',
                methods=['POST'], csrf=False)
    def create_order(self):

        # ── Parse JSON body ───────────────────────────────────
        try:
            payload = json.loads(request.httprequest.data)
        except (ValueError, TypeError):
            return self._json_response(
                status="error", message="Invalid JSON", code=400)

        # ── Step 1: Validate JWT token ────────────────────────
        if not self._validate_token():
            res = {'status': 'error', 'message': 'Unauthorized', 'code': 401}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Unauthorized', code=401)

        # ── Step 2: Validate device ───────────────────────────
        device = request.env['device.device'].sudo().search([
            ('device_code', '=', payload.get('device_code')),
            ('status',      '=', 'active'),
        ], limit=1)
        if not device:
            res = {'status': 'error',
                   'message': 'Invalid or inactive device', 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Invalid or inactive device', code=400)

        # ── Step 3: Validate required fields ─────────────────
        for field in ['external_id', 'device_code', 'payments']:
            if not payload.get(field):
                res = {'status': 'error',
                       'message': f'Missing field: {field}', 'code': 400}
                self._log(payload, res, 'error')
                return self._json_response(
                    status='error', message=f'Missing field: {field}', code=400)

        if payload.get('lines') is None:
            res = {'status': 'error', 'message': 'Missing field: lines', 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Missing field: lines', code=400)

        # ── Step 4: Resolve the POS session ──────────────────
        # THIS IS THE KEY STEP:
        # Use the session_id the cashier selected in Settings.
        # Do NOT auto-detect — that caused mismatches between
        # what products were shown and what session got the order.
        session_id = payload.get('session_id')
        session, session_err = self._resolve_session(session_id)

        if session_err:
            res = {'status': 'error', 'message': session_err, 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message=session_err, code=400)

        pos_config = session.config_id  # The POS config linked to this session

        # ── Step 5: Idempotency check (prevent duplicate orders) ──
        #
        # Three cases for an existing order with the same external_pos_id:
        #
        #   a) state = 'draft' — This is a pending draft order that the cashier
        #      restored via "Add to Cart" and is now paying. We must NOT return
        #      early here; instead we fall through so Steps 6-11 run and pay it.
        #      Returning early without paying caused a duplicate: local DB was
        #      marked 'done' but Odoo kept the order as 'draft' → two entries.
        #
        #   b) state in ('done','paid','invoiced') — Already paid. Return early
        #      (true idempotency — cashier retried a successful payment).
        #
        #   c) state = 'cancel' — Cancelled. Fall through to create a fresh order.
        existing = request.env['pos.order'].sudo().search([
            ('external_pos_id', '=', payload['external_id']),
            ('device_code',     '=', device.id),
            ('session_id',      '=', session.id),
        ], limit=1)
        if existing and existing.state in ('done', 'paid', 'invoiced'):
            # Already paid — safe to return early (true idempotent retry)
            res = {'status': 'success',
                   'data': {'order_id': existing.id, 'order_name': existing.name},
                   'message': 'Order already exists', 'code': 200}
            self._log(payload, res, 'success')
            return self._json_response(
                status='success',
                data=res['data'],
                message='Order already exists', code=200)
        # existing is None, or state='draft'/'cancel' → fall through to pay/create

        # ── Step 6: Build order lines ─────────────────────────
        # Flutter now sends both regular and combo lines.
        # Combo lines include two extra fields:
        #   is_combo        (bool) — True for all combo-related lines
        #   combo_parent_id (int|None) — None = parent combo product line,
        #                                int  = child choice line
        # Child lines get a note so they appear grouped in Odoo order detail.
        lines_data       = payload.get('lines', [])
        order_lines_data = []
        amount_untaxed   = 0.0
        amount_tax       = 0.0

        for line in lines_data:
            qty     = line.get('qty') or line.get('quantity') or 0
            product = self._resolve_product(line.get('product_id'))

            if not product:
                res = {'status': 'error',
                       'message': f"Invalid product_id: {line.get('product_id')}",
                       'code': 400}
                self._log(payload, res, 'error')
                return self._json_response(
                    status='error', message=res['message'], code=400)

            price         = line.get('price', 0)
            tax_rate      = line.get('tax_rate', 0)
            subtotal      = round(qty * price, 2)
            tax_amt       = round(subtotal * tax_rate / 100, 2)
            subtotal_incl = round(subtotal + tax_amt, 2)

            # Read combo fields sent by Flutter (absent on regular product lines)
            is_combo        = line.get('is_combo', False)
            combo_parent_id = line.get('combo_parent_id')  # None=parent, int=child
            combo_name      = line.get('combo_name', '')

            amount_untaxed += subtotal
            amount_tax     += tax_amt

            # Build Odoo order line dict
            order_line_vals = {
                'product_id':          product.id,
                'qty':                 qty,
                'price_unit':          price,
                'price_subtotal':      subtotal,
                'price_subtotal_incl': subtotal_incl,

                # Save per-item kitchen note (internal — shown on kitchen ticket)
                'note':                line.get('note', '') or '',

                # Save per-item customer note (customer-facing — shown on receipt/history)
                'customer_note':       line.get('customer_note', '') or '',
            }

            # Combo child lines get a note so they appear grouped in order detail
            if is_combo and combo_parent_id is not None:
                note_text = f'[Combo: {combo_name}]' if combo_name else '[Combo item]'
                order_line_vals['note'] = note_text

            order_lines_data.append((0, 0, order_line_vals))

        # ── Step 7: Compute totals ────────────────────────────
        # Flutter is the source of truth for the total.
        # It includes combo prices too, so we always use payment_total.
        payment_total = round(
            sum(p['amount'] for p in payload.get('payments', [])), 2)
        amount_tax    = round(amount_tax, 2)
        amount_total  = payment_total  # Always trust Flutter's total

        # ── Step 8: Validate payment methods ─────────────────
        # Payment methods must be allowed in the selected session's config.
        # This ensures payment consistency with the chosen session.
        allowed_method_ids   = session.config_id.payment_method_ids.ids
        payment_method_names = [
            p['method'].lower() for p in payload.get('payments', [])]
        all_methods  = request.env['pos.payment.method'].sudo().search(
            [('id', 'in', allowed_method_ids)])
        methods_map  = {
            m.name.lower(): m for m in all_methods
            if m.name.lower() in payment_method_names
        }

        payment_data = []
        for p in payload.get('payments', []):
            method = methods_map.get(p['method'].lower())
            if not method:
                msg = (
                    f"Payment method '{p['method']}' is not configured "
                    f"for POS config '{pos_config.name}' (session: {session.name}). "
                    "Check the POS Settings → Payment Methods."
                )
                res = {'status': 'error', 'message': msg, 'code': 400}
                self._log(payload, res, 'error')
                return self._json_response(
                    status='error', message=msg, code=400)
            payment_data.append({'method_id': method.id, 'amount': p['amount']})

        # ── Step 9: Create or update the POS order ───────────
        #
        # If an existing DRAFT order was found in Step 5 (pending order being paid
        # via "Add to Cart"), we UPDATE it in place instead of creating a new record.
        # This ensures only ONE order exists in Odoo for this sale — the original
        # draft is paid and transitions to 'done', with no duplicate created.
        #
        # If no existing order was found (normal new order), we CREATE a new record.
        if existing and existing.state in ('draft', 'new'):
            # ── Pay the existing draft order ──────────────────
            # Replace lines with the (possibly modified) cart contents,
            # then attach payments and mark as paid.
            existing.lines.sudo().unlink()           # remove old draft lines
            existing.sudo().write({
                'partner_id':    payload.get('customer_id'),
                'raw_payload':   json.dumps(payload),
                'amount_tax':    amount_tax,
                'amount_total':  amount_total,
                'amount_paid':   payment_total,
                'amount_return': 0.0,
                'lines':         order_lines_data,
                'customer_note': payload.get('customer_note', '') or '',
            })
            order = existing
        else:
            # ── Create a brand-new POS order ─────────────────
            # session_id here is the same one the cashier selected in Settings.
            # This is what links the order to the correct session.
            order = request.env['pos.order'].sudo().create({
                'external_pos_id': payload['external_id'],
                'device_code':     device.id,
                'partner_id':      payload.get('customer_id'),
                'raw_payload':     json.dumps(payload),
                'session_id':      session.id,       # ← the selected session
                'config_id':       pos_config.id,    # ← config of that session
                'amount_tax':      amount_tax,
                'amount_total':    amount_total,
                'amount_paid':     payment_total,
                'amount_return':   0.0,
                'lines':           order_lines_data,

                # Order-level customer note (optional — empty if not provided)
                'customer_note':   payload.get('customer_note', '') or '',
            })

        # ── Step 10: Bulk create payments ────────────────────
        request.env['pos.payment'].sudo().create([{
            'pos_order_id':      order.id,
            'payment_method_id': p['method_id'],
            'amount':            p['amount'],
        } for p in payment_data])

        # ── Step 11: Mark order as Paid ──────────────────────
        order.sudo().action_pos_order_paid()

        # Force name format: Session Name - Device Code - Sequence
        order.sudo().write({'name': order._compute_order_name(session)})

        # ── Step 12: Return success ───────────────────────────
        res = {
            'status': 'success',
            'data': {
                'order_id':    order.id,
                'order_name':  order.name,
                'session':     session.name,
                'shop':        pos_config.name,
                'company_id':  [order.company_id.id, order.company_id.name] if order.company_id else False,
                'amount':      amount_total,
            },
            'message': 'POS Order created successfully.',
            'code':    200,
        }
        self._log(payload, res, 'success')
        return self._json_response(
            status='success', data=res['data'],
            message='POS Order created successfully.', code=200)

    # ──────────────────────────────────────────────────────────
    # GET /api/orders
    # ──────────────────────────────────────────────────────────
    @http.route('/api/orders', type='http', auth='public',
                methods=['GET'], csrf=False)
    def get_orders(self, **kwargs):
        if not self._validate_token():
            return self._json_response(
                status='error', message='Unauthorized', code=401)

        limit     = min(int(kwargs.get('limit', 100)), 500)
        filter_by = kwargs.get('filter', 'all')

        # Optional: filter by session_id so cashier sees only their session's orders
        session_id_raw = kwargs.get('session_id', None)
        session_id     = int(session_id_raw) if session_id_raw else None

        # ── SESSION ISOLATION ──
        # To prevent mixing orders between different POS terminals (e.g. Shop vs Restaurant),
        # we strictly require session_id. If missing, we return nothing.
        if not session_id:
             return self._json_response(status='success', data=[], 
                                        message='session_id is required to fetch orders.')

        domain = []
        if filter_by == 'synced':
            domain = [('state', 'in', ['done', 'paid', 'invoiced'])]
        elif filter_by == 'pending':
            domain = [('state', 'in', ['draft', 'new'])]
        elif filter_by == 'cancelled':
            domain = [('state', '=', 'cancel')]

        # If session_id given, only return orders from that session
        if session_id:
            domain.append(('session_id', '=', session_id))

        orders = request.env['pos.order'].sudo().search_read(
            domain=domain,
            fields=['id', 'name', 'state', 'date_order',
                    'amount_total', 'partner_id', 'lines',
                    'payment_ids', 'session_id',
                    'company_id',
                    'customer_note',
                    'account_move',       # NEW: Fetch invoice for backend payments
                    'external_pos_id'],   # also return Flutter's own reference
            limit=limit,
            order='date_order desc',
        )

        # Fetch payment methods in one query (avoid N+1)
        all_pay_ids = [pid for o in orders for pid in (o.get('payment_ids') or [])]
        pay_method_map = {}
        if all_pay_ids:
            payments = request.env['pos.payment'].sudo().search_read(
                domain=[['id', 'in', all_pay_ids]],
                fields=['id', 'payment_method_id'],
            )
            for p in payments:
                m = p.get('payment_method_id')
                if isinstance(m, list) and len(m) > 1:
                    pay_method_map[p['id']] = m[1]

        # ── BACKEND PAYMENTS FIX ─────────────────────────────────────────────
        # POS orders paid via Odoo backend (invoiced) don't have pos.payment records.
        # We must look up the journal used in the linked invoice payments.
        invoice_method_map = {}
        move_ids = [o['account_move'][0] for o in orders 
                    if o.get('account_move') and isinstance(o.get('account_move'), (list, tuple))]
        if move_ids:
            moves = request.env['account.move'].sudo().browse(move_ids)
            for move in moves:
                try:
                    # Get names of journals used for payments on this invoice
                    p_methods = []
                    for payment in move._get_reconciled_payments():
                        if payment.journal_id:
                            p_methods.append(payment.journal_id.name)

                    # Fallback: If no reconciled payments are found yet, use the invoice's own journal
                    if not p_methods and move.journal_id:
                        p_methods.append(move.journal_id.name)

                    if p_methods:
                        invoice_method_map[move.id] = list(set(p_methods))
                except: continue

        # ── FIX 1: Fetch ALL order lines in one query ────────────────────────
        # Collect all line IDs from all orders at once
        all_line_ids = [lid for o in orders for lid in (o.get('lines') or [])]

        # Map: line_id → full line detail dict
        lines_by_id = {}
        if all_line_ids:
            line_records = request.env['pos.order.line'].sudo().search_read(
                domain=[['id', 'in', all_line_ids]],
                fields=[
                    'id',
                    'order_id',
                    'product_id',          # returns [id, name]
                    'qty',
                    'price_unit',
                    'price_subtotal',
                    'price_subtotal_incl',
                    'note',                # kitchen/internal note
                    'customer_note',       # per-item customer note (custom field)
                ],
            )
            for line in line_records:
                product_info = line.get('product_id')
                lines_by_id[line['id']] = {
                    'id':                  line['id'],
                    # product_id field returns [id, name] from search_read
                    'product_id':          product_info[0] if isinstance(product_info, list) else product_info,
                    'product_name': (
                        product_info[1] if isinstance(product_info, (list, tuple)) and len(product_info) > 1 
                        else (line.get('name') or 'Product %s' % (
                            product_info[0] if isinstance(product_info, (list, tuple)) else product_info
                        ))
                    ),
                    'qty':                 line['qty'],
                    'price_unit':          line['price_unit'],
                    'price_subtotal':      line['price_subtotal'],
                    'price_subtotal_incl': line['price_subtotal_incl'],
                    'note':                line.get('note') or '',
                    'customer_note':       line.get('customer_note') or '',
                }

        # ── Build final response ─────────────────────────────────────────────
        result = []
        for o in orders:
            pay_ids = o.get('payment_ids') or []
            methods = list(
                {pay_method_map[pid]
                 for pid in pay_ids if pid in pay_method_map})

            # If no POS payments, check if it was paid via Invoice (Backend)
            if not methods and o.get('account_move'):
                move_info = o.get('account_move')
                move_id = move_info[0] if isinstance(move_info, (list, tuple)) else None
                if move_id and move_id in invoice_method_map:
                    methods = invoice_method_map[move_id]

            partner    = o.get('partner_id')
            date_order = o.get('date_order')
            if hasattr(date_order, 'strftime'):
                date_order = date_order.strftime('%Y-%m-%d %H:%M:%S')
            else:
                date_order = ''

            session_info = o.get('session_id')

            # Build full line details for this order
            # FIX 1: Flutter now gets product_name, qty, price inside orders list
            order_line_ids     = o.get('lines') or []
            order_lines_detail = [
                lines_by_id[lid]
                for lid in order_line_ids
                if lid in lines_by_id
            ]

            result.append({
                'id':              o['id'],
                'external_pos_id': o.get('external_pos_id') or '',
                'name':            o['name'],
                'state':           o['state'],
                'date_order':      date_order or '',
                'amount_total':    o['amount_total'],
                'customer_name':   (partner[1] if isinstance(partner, list) else 'Walk-in'),
                'partner_id':      partner, # Pass raw partner field for Flutter fallback
                'lines':           order_lines_detail,
                'payment_methods': methods,
                'session_id':      session_info[0] if isinstance(session_info, list) else session_info,
                'session_name':    session_info[1] if isinstance(session_info, list) else '',
                'customer_note':   o.get('customer_note') or '',
                'company_id':      o.get('company_id') or False,
            })

        return self._json_response(
            status='success',
            data=result,
            message='Orders fetched successfully.',
            code=200,
        )

    # ──────────────────────────────────────────────────────────────────────────
    # GET /api/orders/pending
    #
    # FIX 3: New dedicated endpoint for the Pending Orders tab in Flutter.
    #
    # Returns draft orders with full product line details embedded.
    # Clearly documents that Flutter must use 'id' (not external_pos_id)
    # when calling /api/order/{id}/pay.
    #
    # Query params:
    #   session_id  (optional) — filter by POS session
    #   limit       (optional, default 50, max 200)
    # ──────────────────────────────────────────────────────────────────────────
    @http.route('/api/orders/pending', type='http', auth='public',
                methods=['GET'], csrf=False)
    def get_pending_orders(self, **kwargs):
        """
        Returns all draft (pending) orders with full product line details.
        These are orders saved but not yet paid
        (e.g. from a previous session or put on hold).
        """

        if not self._validate_token():
            return self._json_response(
                status='error', message='Unauthorized', code=401)

        limit = min(int(kwargs.get('limit', 50)), 200)

        # Optional: filter by session_id
        session_id_raw = kwargs.get('session_id', None)
        session_id     = int(session_id_raw) if session_id_raw else None

        # ── SESSION ISOLATION ──
        # Pending orders MUST be filtered by session to avoid mixing carts
        # between different devices or users.
        if not session_id:
             return self._json_response(status='success', data=[], 
                                        message='session_id is required to fetch pending orders.')

        # Only fetch pending (draft) orders
        domain = [('state', '=', 'draft')]
        domain.append(('session_id', '=', session_id))

        orders = request.env['pos.order'].sudo().search(
            domain,
            limit=limit,
            order='date_order desc',
        )

        if not orders:
            return self._json_response(
                status='success',
                data=[],
                message='No pending orders found.',
                code=200,
            )

        # ── Fetch all line details in ONE query (no N+1 per order) ──────────
        all_line_ids = orders.mapped('lines').ids

        lines_by_order = {}   # Map: order_id → list of line dicts
        if all_line_ids:
            line_records = request.env['pos.order.line'].sudo().browse(all_line_ids)
            for line in line_records:
                order_id_val = line.order_id.id
                if order_id_val not in lines_by_order:
                    lines_by_order[order_id_val] = []

                lines_by_order[order_id_val].append({
                    'id':                  line.id,
                    'product_id':          line.product_id.id,
                    'product_name':        line.product_id.name or 'Unknown',
                    'product_code':        line.product_id.default_code or '',
                    'qty':                 line.qty,
                    'price_unit':          line.price_unit,
                    'price_subtotal':      line.price_subtotal,
                    'price_subtotal_incl': line.price_subtotal_incl,
                    'note':                line.note or '',
                    'customer_note':       line.customer_note or '',
                })

        # ── Build response ────────────────────────────────────────────────────
        result = []
        for order in orders:
            date_str = ''
            if order.date_order:
                date_str = order.date_order.strftime('%Y-%m-%d %H:%M:%S')

            # Get payment methods already recorded (may be empty for pure drafts)
            payment_methods = []
            if order.payment_ids:
                payment_methods = list({
                    p.payment_method_id.name
                    for p in order.payment_ids
                    if p.payment_method_id
                })

            result.append({
                # ─────────────────────────────────────────────────────────────
                # IMPORTANT: Flutter MUST use this 'id' when calling
                # POST /api/order/{id}/pay
                # Do NOT use external_pos_id or a local sequential number.
                # ─────────────────────────────────────────────────────────────
                'id':              order.id,

                # Flutter's own reference (e.g. "ORDER-328") — display only
                'external_pos_id': order.external_pos_id or '',

                'name':            order.name or '',
                'state':           order.state,
                'date_order':      date_str,
                'amount_total':    order.amount_total,
                'customer_name':   order.partner_id.name if order.partner_id else 'Walk-in',
                'partner_id':      [order.partner_id.id, order.partner_id.name] if order.partner_id else False,
                'company_id':      [order.company_id.id, order.company_id.name] if order.company_id else False,
                'customer_note':   order.customer_note or '',
                'session_id':      order.session_id.id if order.session_id else False,
                'session_name':    order.session_id.name if order.session_id else '',

                # Full product lines — no extra API call needed
                'lines':           lines_by_order.get(order.id, []),
                'payment_methods': payment_methods,
            })

        return self._json_response(
            status='success',
            data=result,
            message='Pending orders fetched successfully.',
            code=200,
        )

    # ──────────────────────────────────────────────────────────
    # POST /api/order/cancel
    #
    # Called when the cashier cancels the order from the Flutter cart screen.
    # This creates a cancelled POS order record in Odoo — same as how the
    # native POS handles cancelled orders (they still appear in the order list
    # with state='cancel' instead of disappearing silently).
    #
    # Expected JSON body:
    # {
    #   "external_id":  "APP-UUID",   ← required: unique ID for this order
    #   "device_code":  "DEVICE-01",  ← required: device identifier
    #   "session_id":   5,            ← required: active POS session
    #   "customer_id":  12,           ← optional: partner
    #   "total":        300.0,        ← optional: cart total at time of cancel
    #   "lines": [                    ← optional: items that were in cart
    #     { "product_id": 45, "qty": 2, "price": 150.0, "tax_rate": 5.0 }
    #   ]
    # }
    # ──────────────────────────────────────────────────────────
    @http.route('/api/order/cancel', type='http', auth='public',
                methods=['POST'], csrf=False)
    def cancel_order(self):

        # ── Parse JSON body ───────────────────────────────────
        try:
            payload = json.loads(request.httprequest.data)
        except (ValueError, TypeError):
            return self._json_response(
                status="error", message="Invalid JSON", code=400)

        # ── Step 1: Validate JWT token ────────────────────────
        if not self._validate_token():
            res = {'status': 'error', 'message': 'Unauthorized', 'code': 401}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Unauthorized', code=401)

        # ── Step 2: Validate device ───────────────────────────
        device = request.env['device.device'].sudo().search([
            ('device_code', '=', payload.get('device_code')),
            ('status',      '=', 'active'),
        ], limit=1)
        if not device:
            res = {'status': 'error',
                   'message': 'Invalid or inactive device', 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Invalid or inactive device', code=400)

        # ── Step 3: Validate required fields ─────────────────
        if not payload.get('external_id'):
            res = {'status': 'error',
                   'message': 'Missing field: external_id', 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Missing field: external_id', code=400)

        # ── Step 4: Check if this order already exists ────────
        # If the cashier taps Cancel on an order that was already synced
        # (e.g., saved offline and then synced), we cancel the existing record.
        existing = request.env['pos.order'].sudo().search([
            ('external_pos_id', '=', payload['external_id']),
            ('device_code',     '=', device.id),
        ], limit=1)

        if existing:
            # Order already in Odoo — cancel it if not already cancelled
            if existing.state != 'cancel':
                existing.sudo().write({'state': 'cancel'})
            res = {
                'status': 'success',
                'data':   {'order_id': existing.id},
                'message': 'Order cancelled.',
                'code':    200,
            }
            self._log(payload, res, 'cancel')  
            return self._json_response(
                status='success',
                data={'order_id': existing.id},
                message='Order cancelled.',
                code=200)

        # ── Step 5: Resolve the POS session ──────────────────
        # We need a session to create the cancelled order record.
        session_id = payload.get('session_id')
        session, session_err = self._resolve_session(session_id)
        if session_err:
            res = {'status': 'error', 'message': session_err, 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message=session_err, code=400)

        pos_config = session.config_id

        # ── Step 6: Build order lines from cancelled cart items ──
        # Lines are optional — if Flutter sends them we save them so the
        # cancelled order shows what items were in the cart, just like native POS.
        lines_data       = payload.get('lines', [])
        order_lines_data = []
        amount_untaxed   = 0.0
        amount_tax       = 0.0

        for line in lines_data:
            qty     = line.get('qty') or line.get('quantity') or 0
            product = self._resolve_product(line.get('product_id'))

            # Skip lines with invalid products — don't block the whole cancel
            if not product:
                continue

            price         = line.get('price', 0)
            tax_rate      = line.get('tax_rate', 0)
            subtotal      = round(qty * price, 2)
            tax_amt       = round(subtotal * tax_rate / 100, 2)
            subtotal_incl = round(subtotal + tax_amt, 2)

            amount_untaxed += subtotal
            amount_tax     += tax_amt

            order_lines_data.append((0, 0, {
                'product_id':          product.id,
                'qty':                 qty,
                'price_unit':          price,
                'price_subtotal':      subtotal,
                'price_subtotal_incl': subtotal_incl,

                # Save kitchen note and customer note for cancelled orders too
                'note':          line.get('note', '') or '',
                'customer_note': line.get('customer_note', '') or '',
            }))

        # Use Flutter's total if provided, otherwise compute from lines
        amount_total = payload.get('total') or round(amount_untaxed + amount_tax, 2)

        # ── Step 7: Create the cancelled POS order record ─────
        # We create the order first (state defaults to 'draft'),
        # then immediately write state='cancel'.
        # This mirrors the native Odoo POS cancel behaviour — the order
        # appears in the order list as cancelled, not silently deleted.
        order = request.env['pos.order'].sudo().create({
            'external_pos_id': payload['external_id'],
            'device_code':     device.id,
            'partner_id':      payload.get('customer_id'),
            'raw_payload':     json.dumps(payload),
            'session_id':      session.id,
            'config_id':       pos_config.id,
            'amount_tax':      round(amount_tax, 2),
            'amount_total':    amount_total,
            'amount_paid':     0.0,   # No payment was made — it was cancelled
            'amount_return':   0.0,
            'lines':           order_lines_data,

            # Save order-level customer note for cancelled orders too
            'customer_note':   payload.get('customer_note', '') or '',
        })

        # Set state to cancel after creation
        order.sudo().write({'state': 'cancel'})

        # ── Step 8: Return success ────────────────────────────
        res = {
            'status': 'success',
            'data': {
                'order_id': order.id,
                'session':  session.name,
                'shop':     pos_config.name,
                'company_id': [order.company_id.id, order.company_id.name] if order.company_id else False,
            },
            'message': 'Order cancelled successfully.',
            'code':    200,
        }
        self._log(payload, res, 'cancel')   
        return self._json_response(
            status='success',
            data=res['data'],
            message='Order cancelled successfully.',
            code=200)

    # ──────────────────────────────────────────────────────────
    # GET /api/order/<order_id>/lines
    # ──────────────────────────────────────────────────────────
    @http.route('/api/order/<int:order_id>/lines', type='http',
                auth='public', methods=['GET'], csrf=False)
    def get_order_lines(self, order_id, **kwargs):
        if not self._validate_token():
            return self._json_response(
                status='error', message='Unauthorized', code=401)

        session_id_raw = kwargs.get('session_id')
        session_id = int(session_id_raw) if session_id_raw else None

        order = request.env['pos.order'].sudo().browse(order_id)
        if not order.exists():
            return self._json_response(
                status='error', message='Order not found', code=404)

        # 🔒 SESSION ISOLATION CHECK
        if not session_id:
            return self._json_response(
                status='error',
                message='session_id is required to fetch order lines.',
                code=400)
        if order.session_id.id != session_id:
            return self._json_response(
                status='error', 
                message='Unauthorized: Order lines belong to a different session.', 
                code=403)

        lines = []
        for line in order.lines:
            # Get product image — same logic as _get_product_image_base64() in product_api.py.
            # Odoo stores image_1920 as base64-encoded bytes, NOT raw binary.
            # So we decode('utf-8') when it is already bytes — never re-encode with base64.b64encode().
            # Re-encoding would cause double base64 which Flutter's ProductImage widget cannot display.
            product   = line.product_id
            image_b64 = None
            try:
                raw = product.image_1920 or product.image_512
                if raw:
                    if isinstance(raw, bytes):
                        # Odoo binary field arrived as bytes — already base64, just decode to string
                        img_str = raw.decode('utf-8')
                    else:
                        # Arrived as raw binary data — encode to base64 string
                        import base64
                        img_str = base64.b64encode(raw).decode('utf-8')
                    # Add data URI prefix so Flutter ProductImage widget renders correctly
                    image_b64 = f'data:image/png;base64,{img_str}'
            except Exception:
                image_b64 = None

            # Build variant attribute list for this product line.
            # product.product_template_attribute_value_ids contains all
            # the selected attribute values for this specific variant.
            # e.g. [{'attribute_name': 'Color', 'value_name': 'Red'}, ...]
            variant_attributes = []
            try:
                for ptav in product.product_template_attribute_value_ids:
                    variant_attributes.append({
                        'attribute_name': ptav.attribute_id.name or '',
                        'value_name':     ptav.product_attribute_value_id.name or '',
                    })
            except Exception:
                variant_attributes = []

            lines.append({
                'id':                  line.id,

                # product_id is the Odoo product.product ID (integer).
                # Flutter's _addBackToCart uses this to look up the product
                # in ProductCache so it can restore items into the cart.
                # Without this field, online order "Add to Cart" gives a blank cart.
                'product_id':          line.product_id.id,

                'product_name':        line.product_id.name or 'Unknown',
                'qty':                 line.qty,
                'price_unit':          line.price_unit,
                'price_subtotal':      line.price_subtotal,
                'price_subtotal_incl': line.price_subtotal_incl,

                # Kitchen/internal note (e.g. combo label, or staff note)
                'note':          line.note or '',

                # Per-item customer note entered in Flutter cart
                # (e.g. "No onions", "Extra cheese")
                'customer_note': line.customer_note or '',

                # Product image as data URI (data:image/png;base64,...) — shown in order
                # detail item popup. Same format as /api/products so ProductImage widget works.
                # None if product has no image set in Odoo.
                'image': image_b64,

                # Variant attribute pairs for products with multiple variants.
                # Flutter order history detail sheet uses this to show chips like
                # "Color: Red | Size: M" under the product name.
                # Empty list for non-variant (simple) products.
                'variant_attributes': variant_attributes,
            })

        return self._json_response(
            status='success',
            data=lines,   # list format kept — Flutter parsing unchanged
            message='Order lines fetched successfully.',
            code=200,
        )
    # ──────────────────────────────────────────────────────────────────────────
    # POST /api/order/<order_id>/cancel
    #
    # PURPOSE:
    #   Cancel a POS order directly by its Odoo ID.
    #   Used for orders that have no external_pos_id (e.g. orders created from
    #   the Odoo backend with state='new') — those cannot be found by external_id.
    #
    # Expected JSON body:
    # {
    #   "device_code": "DEVICE-01"   ← REQUIRED
    # }
    #
    # Response:
    # { "status": "success", "data": { "order_id": 123, "state": "cancel" } }
    # ──────────────────────────────────────────────────────────────────────────
    @http.route('/api/order/<int:order_id>/cancel', type='http', auth='public',
                methods=['POST'], csrf=False)
    def cancel_order_by_id(self, order_id):

        # ── Parse JSON body ───────────────────────────────────────────────────
        try:
            payload = json.loads(request.httprequest.data or '{}')
        except (ValueError, TypeError):
            return self._json_response(
                status='error', message='Invalid JSON', code=400)

        # ── Step 1: Validate JWT token ────────────────────────────────────────
        if not self._validate_token():
            res = {'status': 'error', 'message': 'Unauthorized', 'code': 401}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Unauthorized', code=401)

        # ── Step 2: Validate device ───────────────────────────────────────────
        device = request.env['device.device'].sudo().search([
            ('device_code', '=', payload.get('device_code')),
            ('status',      '=', 'active'),
        ], limit=1)
        if not device:
            res = {'status': 'error',
                   'message': 'Invalid or inactive device', 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Invalid or inactive device', code=400)

        # ── Step 3: Find the order by Odoo ID ────────────────────────────────
        order = request.env['pos.order'].sudo().browse(order_id)
        if not order.exists():
            res = {'status': 'error',
                   'message': f'Order {order_id} not found.', 'code': 404}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message=res['message'], code=404)

        # ── Step 4: Cancel the order if not already cancelled/paid ───────────
        # Already cancelled → return success (idempotent)
        # Already paid → return error (cannot cancel a paid order)
        if order.state == 'cancel':
            res = {'status': 'success',
                   'data': {'order_id': order.id, 'state': 'cancel'},
                   'message': 'Order already cancelled.', 'code': 200}
            self._log(payload, res, 'cancel')
            return self._json_response(
                status='success', data=res['data'],
                message='Order already cancelled.', code=200)

        if order.state in ('done', 'paid', 'invoiced'):
            res = {'status': 'error',
                   'message': 'Cannot cancel a paid order.', 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message=res['message'], code=400)

        # Cancel draft/new orders in place — no new record created
        order.sudo().write({'state': 'cancel'})

        # ── Step 5: Return success ────────────────────────────────────────────
        res = {
            'status': 'success',
            'data': {'order_id': order.id, 'state': 'cancel'},
            'message': 'Order cancelled successfully.',
            'code': 200,
        }
        self._log(payload, res, 'cancel')
        return self._json_response(
            status='success',
            data=res['data'],
            message='Order cancelled successfully.',
            code=200,
        )

    # ──────────────────────────────────────────────────────────────────────────
    # POST /api/order/<order_id>/draft
    #
    # PURPOSE:
    #   Update an existing POS order (draft or new) in place with new cart lines.
    #   Used when the cashier holds/re-holds an order that was created from the
    #   Odoo backend (state='new') — those orders have no external_pos_id so
    #   the normal /api/order/draft upsert cannot find them by external_id.
    #
    # Expected JSON body:
    # {
    #   "device_code":   "DEVICE-01",  ← REQUIRED
    #   "session_id":    5,            ← REQUIRED
    #   "customer_id":   12,           ← optional
    #   "customer_note": "Table 3",    ← optional
    #   "lines": [ { "product_id": 45, "qty": 2, "price": 150.0, ... } ]
    # }
    # ──────────────────────────────────────────────────────────────────────────
    @http.route('/api/order/<int:order_id>/draft', type='http', auth='public',
                methods=['POST'], csrf=False)
    def update_draft_order_by_id(self, order_id):

        try:
            payload = json.loads(request.httprequest.data or '{}')
        except (ValueError, TypeError):
            return self._json_response(
                status='error', message='Invalid JSON', code=400)

        if not self._validate_token():
            res = {'status': 'error', 'message': 'Unauthorized', 'code': 401}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Unauthorized', code=401)

        device = request.env['device.device'].sudo().search([
            ('device_code', '=', payload.get('device_code')),
            ('status',      '=', 'active'),
        ], limit=1)
        if not device:
            res = {'status': 'error',
                   'message': 'Invalid or inactive device', 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Invalid or inactive device', code=400)

        order = request.env['pos.order'].sudo().browse(order_id)
        if not order.exists():
            res = {'status': 'error',
                   'message': f'Order {order_id} not found.', 'code': 404}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message=res['message'], code=404)

        payload_session_id = int(payload.get('session_id') or 0)
        if not payload_session_id:
            return self._json_response(
                status='error', message='Missing field: session_id', code=400)
        if order.session_id.id != payload_session_id:
            return self._json_response(
                status='error',
                message='Unauthorized: Order belongs to a different session.',
                code=403)

        # Guard — cannot overwrite a paid order
        if order.state in ('done', 'paid', 'invoiced'):
            res = {'status': 'error',
                   'message': 'Cannot update a paid order.', 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message=res['message'], code=400)

        # Build updated order lines
        lines_data       = payload.get('lines', [])
        order_lines_data = []
        amount_untaxed   = 0.0
        amount_tax       = 0.0

        for line in lines_data:
            qty     = line.get('qty') or line.get('quantity') or 0
            product = self._resolve_product(line.get('product_id'))
            if not product:
                res = {'status': 'error',
                       'message': f"Invalid product_id: {line.get('product_id')}",
                       'code': 400}
                self._log(payload, res, 'error')
                return self._json_response(
                    status='error', message=res['message'], code=400)

            price         = line.get('price', 0)
            tax_rate      = line.get('tax_rate', 0)
            subtotal      = round(qty * price, 2)
            tax_amt       = round(subtotal * tax_rate / 100, 2)
            subtotal_incl = round(subtotal + tax_amt, 2)
            amount_untaxed += subtotal
            amount_tax     += tax_amt

            order_lines_data.append((0, 0, {
                'product_id':          product.id,
                'qty':                 qty,
                'price_unit':          price,
                'price_subtotal':      subtotal,
                'price_subtotal_incl': subtotal_incl,
                'note':                line.get('note', '') or '',
                'customer_note':       line.get('customer_note', '') or '',
            }))

        amount_total = round(amount_untaxed + amount_tax, 2)

        # Replace lines and reset state to 'draft' (re-opens 'new' or 'cancel')
        order.lines.sudo().unlink()
        order.sudo().write({
            'state':         'draft',
            'partner_id':    payload.get('customer_id'),
            'raw_payload':   json.dumps(payload),
            'amount_tax':    round(amount_tax, 2),
            'amount_total':  amount_total,
            'amount_paid':   0.0,
            'amount_return': 0.0,
            'lines':         order_lines_data,
            'customer_note': payload.get('customer_note', '') or '',
        })

        res = {
            'status': 'success',
            'data': {'order_id': order.id, 'state': order.state},
            'message': 'Draft order updated.',
            'code': 200,
        }
        self._log(payload, res, 'success')
        return self._json_response(
            status='success', data=res['data'],
            message='Draft order updated.', code=200,
        )

    #
    # PURPOSE:
    #   Save a cart as a PENDING (draft) order WITHOUT taking payment.
    #   Call this when the user adds items to cart but does not pay yet
    #   (e.g. signs out, switches screens, or puts order on hold).
    #
    #   The order is saved with state='draft' in Odoo.
    #   It will appear in GET /api/orders?filter=pending until it is paid.
    #
    # IDEMPOTENT:
    #   If you send the same external_id again, it UPDATES the existing
    #   draft order (replaces lines) instead of creating a duplicate.
    #   This lets Flutter keep syncing cart changes.
    #
    # Expected JSON body:
    # {
    #   "session_id":    5,           ← REQUIRED: POS session chosen in Settings
    #   "external_id":   "APP-HOLD-001", ← REQUIRED: unique ID for this cart
    #   "device_code":   "DEVICE-01", ← REQUIRED
    #   "customer_id":   12,          ← optional partner_id
    #   "customer_note": "Table 3",   ← optional order-level note
    #   "lines": [
    #     {
    #       "product_id": 45,
    #       "qty":        2,
    #       "price":      150.0,
    #       "tax_rate":   5.0,
    #       "note":       "",         ← kitchen note (optional)
    #       "customer_note": ""       ← per-item customer note (optional)
    #     }
    #   ]
    # }
    #
    # Response:
    # {
    #   "status": "success",
    #   "data": { "order_id": 123, "state": "draft" },
    #   "message": "Draft order saved."
    # }
    # ──────────────────────────────────────────────────────────────────────────
    @http.route('/api/order/draft', type='http', auth='public',
                methods=['POST'], csrf=False)
    def save_draft_order(self):

        # ── Parse JSON body ───────────────────────────────────────────────────
        try:
            payload = json.loads(request.httprequest.data)
        except (ValueError, TypeError):
            return self._json_response(
                status='error', message='Invalid JSON', code=400)

        # ── Step 1: Validate JWT token ────────────────────────────────────────
        if not self._validate_token():
            res = {'status': 'error', 'message': 'Unauthorized', 'code': 401}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Unauthorized', code=401)

        # ── Step 2: Validate device ───────────────────────────────────────────
        device = request.env['device.device'].sudo().search([
            ('device_code', '=', payload.get('device_code')),
            ('status',      '=', 'active'),
        ], limit=1)
        if not device:
            res = {'status': 'error',
                   'message': 'Invalid or inactive device', 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Invalid or inactive device', code=400)

        # ── Step 3: Validate required fields ─────────────────────────────────
        for field in ['external_id', 'device_code']:
            if not payload.get(field):
                res = {'status': 'error',
                       'message': f'Missing field: {field}', 'code': 400}
                self._log(payload, res, 'error')
                return self._json_response(
                    status='error', message=f'Missing field: {field}', code=400)

        if payload.get('lines') is None:
            res = {'status': 'error',
                   'message': 'Missing field: lines', 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Missing field: lines', code=400)

        # ── Step 4: Resolve the POS session ──────────────────────────────────
        session_id = payload.get('session_id')
        session, session_err = self._resolve_session(session_id)
        if session_err:
            res = {'status': 'error', 'message': session_err, 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message=session_err, code=400)

        pos_config = session.config_id

        # ── Step 5: UPSERT — find existing draft to update ───────────────────
        #
        # Two search strategies to prevent duplicate drafts:
        #
        # Search A — by external_pos_id:
        #   Normal case. Flutter reuses the same UUID for re-saves of the
        #   same local cart. This covers 99% of draft saves.
        #
        # Search B — by odoo_order_id:
        #   Handles the "restore pending order → logout → duplicate" bug.
        #
        #   When Flutter restores a pending Odoo order to the cart screen,
        #   it may assign a NEW local UUID to that cart. On logout it calls
        #   this endpoint with the new UUID. Without Search B, Odoo cannot
        #   match the new UUID to the original draft and creates a second one.
        #
        #   Flutter fix required: pass "odoo_order_id" = <original Odoo order id>
        #   in the payload whenever the cart was restored from a pending order.
        #   Example payload:
        #   {
        #     "session_id":    5,
        #     "external_id":   "APP-RESTORED-XYZ",
        #     "odoo_order_id": 42,               <-- NEW field Flutter must send
        #     "device_code":   "DEVICE-01",
        #     "lines": [...]
        #   }

        # Search A: normal external_id match (standard save/re-save of same cart)
        existing_draft = request.env['pos.order'].sudo().search([
            ('external_pos_id', '=', payload['external_id']),
            ('device_code',     '=', device.id),
            ('state',           'in', ['draft', 'new']),   # only update drafts, not paid orders
            ('session_id',      '=', session.id),
        ], limit=1)

        # Search B: match by Odoo order ID (restored pending order re-saved on logout)
        # Only runs if Search A found nothing AND Flutter sent odoo_order_id.
        if not existing_draft:
            odoo_order_id = payload.get('odoo_order_id')
            if odoo_order_id:
                try:
                    candidate = request.env['pos.order'].sudo().browse(
                        int(odoo_order_id))
                    # Only accept if it is an unpaid draft in the same session.
                    # This guards against wrong IDs or already-paid orders.
                    if (candidate.exists()
                            and candidate.state in ('draft', 'new')
                            and candidate.session_id.id == session.id):
                        existing_draft = candidate
                except (ValueError, TypeError):
                    # Invalid odoo_order_id value — skip, fall through to create
                    pass

        # ── Step 6: Build order lines ─────────────────────────────────────────
        lines_data       = payload.get('lines', [])
        order_lines_data = []
        amount_untaxed   = 0.0
        amount_tax       = 0.0

        for line in lines_data:
            qty     = line.get('qty') or line.get('quantity') or 0
            product = self._resolve_product(line.get('product_id'))

            if not product:
                res = {'status': 'error',
                       'message': f"Invalid product_id: {line.get('product_id')}",
                       'code': 400}
                self._log(payload, res, 'error')
                return self._json_response(
                    status='error', message=res['message'], code=400)

            price         = line.get('price', 0)
            tax_rate      = line.get('tax_rate', 0)
            subtotal      = round(qty * price, 2)
            tax_amt       = round(subtotal * tax_rate / 100, 2)
            subtotal_incl = round(subtotal + tax_amt, 2)

            amount_untaxed += subtotal
            amount_tax     += tax_amt

            order_lines_data.append((0, 0, {
                'product_id':          product.id,
                'qty':                 qty,
                'price_unit':          price,
                'price_subtotal':      subtotal,
                'price_subtotal_incl': subtotal_incl,
                'note':                line.get('note', '') or '',
                'customer_note':       line.get('customer_note', '') or '',
            }))

        # Compute totals from lines (no payment yet — amount_paid = 0)
        amount_total = round(amount_untaxed + amount_tax, 2)

        if existing_draft:
            # ── UPDATE existing draft order ───────────────────────────────────
            # Delete old lines first, then write new ones.
            # This replaces the entire cart — Flutter always sends the full list.
            #
            # Also stamp the current external_id onto the record so future
            # saves (after the restore) can match via Search A again without
            # needing odoo_order_id in every subsequent payload.
            existing_draft.lines.sudo().unlink()
            existing_draft.sudo().write({
                'external_pos_id': payload['external_id'],  # stamp new UUID if changed by restore
                'partner_id':    payload.get('customer_id'),
                'raw_payload':   json.dumps(payload),
                'session_id':    session.id,
                'config_id':     pos_config.id,
                'amount_tax':    round(amount_tax, 2),
                'amount_total':  amount_total,
                'amount_paid':   0.0,   # no payment yet
                'amount_return': 0.0,
                'lines':         order_lines_data,
                'customer_note': payload.get('customer_note', '') or '',
            })
            order = existing_draft
            action_msg = 'Draft order updated.'
        else:
            # ── CREATE new draft order ────────────────────────────────────────
            # Odoo's default state is 'draft', so no explicit state write needed.
            order = request.env['pos.order'].sudo().create({
                'external_pos_id': payload['external_id'],
                'device_code':     device.id,
                'partner_id':      payload.get('customer_id'),
                'raw_payload':     json.dumps(payload),
                'session_id':      session.id,
                'config_id':       pos_config.id,
                'amount_tax':      round(amount_tax, 2),
                'amount_total':    amount_total,
                'amount_paid':     0.0,   # no payment yet — stays as pending
                'amount_return':   0.0,
                'lines':           order_lines_data,
                'customer_note':   payload.get('customer_note', '') or '',
            })
            action_msg = 'Draft order saved.'

            # Use the naming logic defined in the model override
            order.sudo().write({'name': order._compute_order_name(session)})
            
            # Update local variable to reflect new name
            action_msg = 'Draft order updated.'
            
            # Update message to reflect this was an update
            action_msg = 'Draft order updated.'



        # ── Step 7: Return success ─────────────────────────────────────────────
        res = {
            'status': 'success',
            'data': {
                'order_id':  order.id,
                'order_name': order.name,
                'state':     order.state,    # will be 'draft'
                'session':   session.name,
                'shop':      pos_config.name,
                'company_id': [order.company_id.id, order.company_id.name] if order.company_id else False,
                'amount':    amount_total,
            },
            'message': action_msg,
            'code':    200,
        }
        self._log(payload, res, 'success')
        return self._json_response(
            status='success',
            data=res['data'],
            message=action_msg,
            code=200,
        )

    # ──────────────────────────────────────────────────────────────────────────
    # POST /api/order/<order_id>/pay
    #
    # PURPOSE:
    #   Complete payment for an existing DRAFT (pending) order.
    #   Call this when the user comes back to a pending order and pays.
    #
    #   The order state changes: draft → paid
    #   After this, the order will NO LONGER appear in pending list.
    #   It will appear in GET /api/orders?filter=synced (state=done/paid).
    #
    # IMPORTANT:
    #   - order_id is the Odoo order ID returned by /api/order/draft
    #   - The order must be in 'draft' state — you cannot pay a cancelled order
    #   - Payment methods must match the session config (same rule as /api/order)
    #
    # Expected JSON body:
    # {
    #   "device_code": "DEVICE-01",   ← REQUIRED
    #   "payments": [
    #     { "method": "Cash", "amount": 300.0 }
    #   ]
    # }
    #
    # Response:
    # {
    #   "status": "success",
    #   "data": { "order_id": 123, "state": "done", "amount": 300.0 },
    #   "message": "Order paid successfully."
    # }
    # ──────────────────────────────────────────────────────────────────────────
    @http.route('/api/order/<int:order_id>/pay', type='http', auth='public',
                methods=['POST'], csrf=False)
    def pay_draft_order(self, order_id):

        # ── Parse JSON body ───────────────────────────────────────────────────
        try:
            payload = json.loads(request.httprequest.data)
        except (ValueError, TypeError):
            return self._json_response(
                status='error', message='Invalid JSON', code=400)

        # ── Step 1: Validate JWT token ────────────────────────────────────────
        if not self._validate_token():
            res = {'status': 'error', 'message': 'Unauthorized', 'code': 401}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Unauthorized', code=401)

        # ── Step 2: Validate device ───────────────────────────────────────────
        device = request.env['device.device'].sudo().search([
            ('device_code', '=', payload.get('device_code')),
            ('status',      '=', 'active'),
        ], limit=1)
        if not device:
            res = {'status': 'error',
                   'message': 'Invalid or inactive device', 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Invalid or inactive device', code=400)

        # ── Step 3: Validate payments field ──────────────────────────────────
        if not payload.get('payments'):
            res = {'status': 'error',
                   'message': 'Missing field: payments', 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Missing field: payments', code=400)

        # ── Step 4: Find the draft order ─────────────────────────────────────
        order = request.env['pos.order'].sudo().browse(order_id)

        if not order.exists():
            # FALLBACK 1: Search by external_pos_id
            # Flutter sets external_pos_id when creating the draft.
            # "ORDER-328" ilike "328" → matches
            order = request.env['pos.order'].sudo().search([
                ('external_pos_id', 'ilike', str(order_id)),
                ('device_code',     '=',     device.id),
                ('state',           '=',     'draft'),
            ], limit=1)

        if not order.exists():
            # FALLBACK 2: Search by pos_reference
            # Odoo sets pos_reference like "Order 00328" for POS orders
            order = request.env['pos.order'].sudo().search([
                ('pos_reference', 'ilike', str(order_id)),
                ('state',         '=',     'draft'),
            ], limit=1)

        if not order.exists():
            # FALLBACK 3: Search by order name
            # Odoo name format is "Clothes Shop - 000328"
            # zfill(6) converts 328 → "000328" to match the format
            order = request.env['pos.order'].sudo().search([
                ('name',  'ilike', str(order_id).zfill(6)),
                ('state', '=',     'draft'),
            ], limit=1)

        # If still not found after all fallbacks → return 404
        if not order.exists():
            res = {
                'status':  'error',
                'message': (
                    f'Order {order_id} not found. '
                    f'Please use the Odoo order id (the "id" field from GET /api/orders), '
                    f'not a local reference number.'
                ),
                'code': 404,
            }
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message=res['message'], code=404)

        payload_session_id = int(payload.get('session_id') or 0)
        if not payload_session_id:
            return self._json_response(
                status='error', message='Missing field: session_id', code=400)
        if order.session_id.id != payload_session_id:
            return self._json_response(
                status='error',
                message='Unauthorized: Order belongs to a different session.',
                code=403)

        # ── Step 5: Guard — only draft orders can be paid ─────────────────────
        # If already paid → return success (idempotent — safe to retry)
        # If cancelled → return error (cannot pay a cancelled order)
        if order.state in ('done', 'paid', 'invoiced'):
            # Already paid — return success so Flutter doesn't get confused
            res = {
                'status': 'success',
                'data':   {'order_id': order.id, 'state': order.state,
                           'amount': order.amount_total},
                'message': 'Order is already paid.',
                'code':    200,
            }
            self._log(payload, res, 'success')
            return self._json_response(
                status='success', data=res['data'],
                message='Order is already paid.', code=200)

        if order.state == 'cancel':
            res = {'status': 'error',
                   'message': 'Cannot pay a cancelled order.', 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message=res['message'], code=400)

        # At this point state must be 'draft' — safe to proceed
        session  = order.session_id
        pos_config = session.config_id

        # ── Step 6: Validate payment methods against this session ─────────────
        allowed_method_ids   = session.config_id.payment_method_ids.ids
        payment_method_names = [
            p['method'].lower() for p in payload.get('payments', [])]
        all_methods  = request.env['pos.payment.method'].sudo().search(
            [('id', 'in', allowed_method_ids)])
        methods_map  = {
            m.name.lower(): m for m in all_methods
            if m.name.lower() in payment_method_names
        }

        payment_data = []
        for p in payload.get('payments', []):
            method = methods_map.get(p['method'].lower())
            if not method:
                msg = (
                    f"Payment method '{p['method']}' is not configured "
                    f"for POS config '{pos_config.name}'. "
                    "Check the POS Settings → Payment Methods."
                )
                res = {'status': 'error', 'message': msg, 'code': 400}
                self._log(payload, res, 'error')
                return self._json_response(
                    status='error', message=msg, code=400)
            payment_data.append({'method_id': method.id, 'amount': p['amount']})

        # ── Step 7: Calculate payment total ──────────────────────────────────
        payment_total = round(
            sum(p['amount'] for p in payload.get('payments', [])), 2)

        # ── Step 8: Update order lines if Flutter sent new lines ──────────────
        #
        # WHY THIS IS NEEDED:
        # When a cashier restores a pending order via "Add back to cart" and
        # adds/removes items before paying, the Flutter app sends the updated
        # lines in the /pay payload. Without this step, Odoo keeps the OLD draft
        # lines — the backend and receipt show the original items, not what was
        # actually sold.
        #
        # If no lines are sent (e.g. simple pay with no changes), we skip this
        # step and keep existing lines — backward compatible.
        lines_data = payload.get('lines')
        if lines_data:
            order_lines_data = []
            amount_untaxed   = 0.0
            amount_tax       = 0.0

            for line in lines_data:
                qty     = line.get('qty') or line.get('quantity') or 0
                product = self._resolve_product(line.get('product_id'))

                # Skip unresolvable products — don't block payment
                if not product:
                    continue

                price         = line.get('price', 0)
                tax_rate      = line.get('tax_rate', 0)
                subtotal      = round(qty * price, 2)
                tax_amt       = round(subtotal * tax_rate / 100, 2)
                subtotal_incl = round(subtotal + tax_amt, 2)

                amount_untaxed += subtotal
                amount_tax     += tax_amt

                order_lines_data.append((0, 0, {
                    'product_id':          product.id,
                    'qty':                 qty,
                    'price_unit':          price,
                    'price_subtotal':      subtotal,
                    'price_subtotal_incl': subtotal_incl,
                    'note':                line.get('note', '') or '',
                    'customer_note':       line.get('customer_note', '') or '',
                }))

            if order_lines_data:
                # Replace old lines with updated cart contents
                order.lines.sudo().unlink()
                order.sudo().write({'lines': order_lines_data})

        # ── Step 9: Update order totals to reflect payment ────────────────────
        order.sudo().write({
            'amount_paid':   payment_total,
            'amount_total':  payment_total,  # trust Flutter's payment total
            'amount_return': 0.0,
        })

        # ── Step 9: Create payment records ───────────────────────────────────
        request.env['pos.payment'].sudo().create([{
            'pos_order_id':      order.id,
            'payment_method_id': p['method_id'],
            'amount':            p['amount'],
        } for p in payment_data])

        # ── Step 10: Mark order as Paid (state: draft → done) ─────────────────
        # This is the key step — the pending order is now completed.
        # After this it will no longer appear in pending list.
        order.sudo().action_pos_order_paid()

        # Update name to final paid format (Session - Device - Seq)
        order.sudo().write({'name': order._compute_order_name(order.session_id)})

        # ── Step 11: Return success ───────────────────────────────────────────
        res = {
            'status': 'success',
            'data': {
                'order_id': order.id,
                'order_name': order.name,
                'state':    order.state,    # will be 'done' or 'paid'
                'session':  session.name,
                'shop':     pos_config.name,
                'company_id': [order.company_id.id, order.company_id.name] if order.company_id else False,
                'amount':   payment_total,
            },
            'message': 'Order paid successfully.',
            'code':    200,
        }
        self._log(payload, res, 'success')
        return self._json_response(
            status='success',
            data=res['data'],
            message='Order paid successfully.',
            code=200,
        )
