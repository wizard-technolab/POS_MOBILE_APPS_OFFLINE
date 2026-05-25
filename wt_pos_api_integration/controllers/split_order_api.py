# ─────────────────────────────────────────────────────────────────────────────
# controllers/split_order_api.py
#
# PURPOSE:
#   Handle the Split Bill feature for the Flutter POS app.
#
# HOW SPLIT BILL WORKS (Restaurant-style):
#   1. Cashier taps "Split" on the cart screen.
#   2. Flutter generates ONE shared UUID → this is the split_group_id.
#   3. For EACH person in the group:
#       a. Product selection screen  → person picks their items
#       b. Customer selection screen → pick customer or walk-in
#       c. Payment screen            → person pays their share
#       d. App calls POST /api/order/split → one sub-order created in Odoo
#   4. Repeat step 3 for every person.
#   5. All sub-orders are linked by the same split_group_id in Odoo.
#
# APIS PROVIDED:
#   POST /api/order/split                    → Create sub-order for one person
#   GET  /api/order/split/<split_group_id>   → Fetch all sub-orders of a split
#
# KEY DIFFERENCE from normal /api/order:
#   - Each person selects THEIR OWN products (not all products split equally)
#   - Each person pays THEIR OWN amount separately
#   - All sub-orders share split_group_id so they are linked in Odoo
#   - split_person_index (1, 2, 3...) tells which person this sub-order is for
# ─────────────────────────────────────────────────────────────────────────────

import json
import jwt
from odoo import http
from odoo.http import request


class SplitOrderApiController(http.Controller):

    # ─────────────────────────────────────────────────────────────────────────
    # HELPER: Return a standard JSON response
    # Same format as all other controllers in this module for consistency.
    # ─────────────────────────────────────────────────────────────────────────
    def _json_response(self, status="success", data=None, message="", code=200):
        return request.make_response(
            json.dumps({
                "status":  status,
                "data":    data or {},
                "message": message,
                "code":    code,
            }),
            headers=[('Content-Type', 'application/json')],
            status=code,
        )

    # ─────────────────────────────────────────────────────────────────────────
    # HELPER: Validate JWT Bearer token from Authorization header
    # Exact same logic as api_order.py — reused for consistency.
    # ─────────────────────────────────────────────────────────────────────────
    def _validate_token(self):
        auth = request.httprequest.headers.get('Authorization', '')
        if not auth.startswith('Bearer '):
            return False
        token = auth[7:]
        try:
            secret = request.env['jwt.config'].sudo().get_secret_key()
            payload = jwt.decode(token, secret, algorithms=['HS256'])
            user_id = payload.get('user_id')
            user = request.env['res.users'].sudo().browse(user_id)
            if not user.exists():
                return False
            request.update_env(user=user)
            return True
        except (jwt.ExpiredSignatureError, jwt.InvalidTokenError):
            return False

    # ─────────────────────────────────────────────────────────────────────────
    # HELPER: Write a sync log entry for this API call
    # ─────────────────────────────────────────────────────────────────────────
    def _log(self, payload, response, status):
        try:
            request.env['sync.log'].sudo().create({
                'endpoint': request.httprequest.path,
                'method':   request.httprequest.method,
                'payload':  json.dumps(payload, indent=4),
                'response': json.dumps(response, indent=4),
                'status':   status,
            })
        except Exception:
            pass  # Never break the main flow because of a logging error

    # ─────────────────────────────────────────────────────────────────────────
    # HELPER: Resolve product_id to a product.product record
    # Flutter may send either a product.product id or a product.template id.
    # We handle both cases, same as api_order.py.
    # ─────────────────────────────────────────────────────────────────────────
    def _resolve_product(self, product_id):
        # Try product.product (variant) first
        product = request.env['product.product'].sudo().browse(product_id)
        if product.exists():
            return product
        # Fallback: try product.template → return first variant
        template = request.env['product.template'].sudo().browse(product_id)
        if template.exists() and template.product_variant_ids:
            return template.product_variant_ids[0]
        return None

    # ─────────────────────────────────────────────────────────────────────────
    # HELPER: Validate and return an open POS session
    # Returns (session_record, None) on success
    # Returns (None, error_string) on failure
    # ─────────────────────────────────────────────────────────────────────────
    def _resolve_session(self, session_id):
        if not session_id:
            return None, 'session_id is required. Select an open POS session.'
        session = request.env['pos.session'].sudo().browse(session_id)
        if not session.exists():
            return None, f'POS Session {session_id} does not exist.'
        if session.state != 'opened':
            return None, (
                f'POS Session "{session.name}" is {session.state}, not open. '
                'Please select an open session.'
            )
        return session, None

    # ─────────────────────────────────────────────────────────────────────────
    # POST /api/order/split
    #
    # Create ONE sub-order for ONE person in a split bill.
    # Call this ONCE PER PERSON — after that person selects products and pays.
    #
    # Expected JSON body:
    # {
    #   "split_group_id":     "UUID-SPLIT-001",  ← REQUIRED: same for ALL persons
    #   "split_person_index": 1,                 ← REQUIRED: 1=first, 2=second...
    #   "session_id":         5,                 ← REQUIRED: open POS session ID
    #   "external_id":        "APP-UUID-P1",     ← REQUIRED: unique per sub-order
    #   "device_code":        "DEVICE-01",       ← REQUIRED
    #   "customer_id":        12,                ← OPTIONAL (null = walk-in)
    #   "lines": [
    #     { "product_id": 45, "qty": 1, "price": 150.0, "tax_rate": 5.0 }
    #   ],
    #   "payments": [
    #     { "method": "Cash", "amount": 157.5 }
    #   ]
    # }
    # ─────────────────────────────────────────────────────────────────────────
    @http.route('/api/order/split', type='http', auth='none',
                methods=['POST'], csrf=False)
    def create_split_order(self):

        # ── Parse JSON body ───────────────────────────────────────────────────
        try:
            payload = json.loads(request.httprequest.data)
        except (ValueError, TypeError):
            return self._json_response(
                status="error", message="Invalid JSON body", code=400)

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
        required_fields = [
            'split_group_id',
            'split_person_index',
            'external_id',
            'device_code',
            'payments',
        ]
        for field in required_fields:
            if payload.get(field) is None:
                res = {'status': 'error',
                       'message': f'Missing required field: {field}', 'code': 400}
                self._log(payload, res, 'error')
                return self._json_response(
                    status='error',
                    message=f'Missing required field: {field}',
                    code=400)

        if payload.get('lines') is None:
            res = {'status': 'error',
                   'message': 'Missing required field: lines', 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message='Missing required field: lines', code=400)

        split_group_id     = payload['split_group_id']
        split_person_index = int(payload['split_person_index'])

        # Person index must be 1 or higher (not 0, not negative)
        if split_person_index < 1:
            res = {'status': 'error',
                   'message': 'split_person_index must be 1 or greater', 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error',
                message='split_person_index must be 1 or greater',
                code=400)

        # ── Step 4: Resolve POS session ───────────────────────────────────────
        session_id = payload.get('session_id')
        session, session_err = self._resolve_session(session_id)
        if session_err:
            res = {'status': 'error', 'message': session_err, 'code': 400}
            self._log(payload, res, 'error')
            return self._json_response(
                status='error', message=session_err, code=400)

        pos_config = session.config_id

        # ── Step 5: Idempotency check ─────────────────────────────────────────
        # If Flutter retries due to network error, return existing order
        existing = request.env['pos.order'].sudo().search([
            ('external_pos_id', '=', payload['external_id']),
            ('device_code',     '=', device.id),
        ], limit=1)
        if existing:
            res = {
                'status': 'success',
                'data': {
                    'order_id':           existing.id,
                    'split_group_id':     split_group_id,
                    'split_person_index': split_person_index,
                },
                'message': 'Split sub-order already exists (idempotent response)',
                'code': 200,
            }
            self._log(payload, res, 'success')
            return self._json_response(
                status='success', data=res['data'],
                message=res['message'], code=200)

        # ── Step 6: Build order lines for THIS person only ────────────────────
        lines_data       = payload.get('lines', [])
        order_lines_data = []
        amount_untaxed   = 0.0
        amount_tax       = 0.0

        for line in lines_data:
            qty     = line.get('qty') or line.get('quantity') or 0
            product = self._resolve_product(line.get('product_id'))

            if not product:
                res = {
                    'status': 'error',
                    'message': f"Invalid product_id: {line.get('product_id')}",
                    'code': 400,
                }
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
            }))

        # ── Step 7: Compute totals ────────────────────────────────────────────
        payment_total = round(
            sum(p['amount'] for p in payload.get('payments', [])), 2)
        amount_tax    = round(amount_tax, 2)
        amount_total  = payment_total  # Trust Flutter's total

        # ── Step 8: Validate payment methods ─────────────────────────────────
        allowed_method_ids   = session.config_id.payment_method_ids.ids
        payment_method_names = [
            p['method'].lower() for p in payload.get('payments', [])]
        all_methods = request.env['pos.payment.method'].sudo().search(
            [('id', 'in', allowed_method_ids)])
        methods_map = {
            m.name.lower(): m for m in all_methods
            if m.name.lower() in payment_method_names
        }

        payment_data = []
        for p in payload.get('payments', []):
            method = methods_map.get(p['method'].lower())
            if not method:
                msg = (
                    f"Payment method '{p['method']}' is not configured "
                    f"for POS '{pos_config.name}' (session: {session.name}). "
                    "Check POS Settings → Payment Methods."
                )
                res = {'status': 'error', 'message': msg, 'code': 400}
                self._log(payload, res, 'error')
                return self._json_response(
                    status='error', message=msg, code=400)
            payment_data.append({
                'method_id': method.id,
                'amount':    p['amount'],
            })

        # ── Step 9: Create the split sub-order ───────────────────────────────
        order = request.env['pos.order'].sudo().create({
            'external_pos_id':    payload['external_id'],
            'device_code':        device.id,
            'partner_id':         payload.get('customer_id'),
            'raw_payload':        json.dumps(payload),
            'session_id':         session.id,
            'config_id':          pos_config.id,
            'amount_tax':         amount_tax,
            'amount_total':       amount_total,
            'amount_paid':        payment_total,
            'amount_return':      0.0,
            'lines':              order_lines_data,
            'split_group_id':     split_group_id,       # links all split parts
            'split_person_index': split_person_index,   # which person this is
        })

        # ── Step 10: Create payment records ──────────────────────────────────
        request.env['pos.payment'].sudo().create([{
            'pos_order_id':      order.id,
            'payment_method_id': p['method_id'],
            'amount':            p['amount'],
        } for p in payment_data])

        # ── Step 11: Mark as Paid ─────────────────────────────────────────────
        order.sudo().action_pos_order_paid()

        # ── Step 12: Return success ───────────────────────────────────────────
        res = {
            'status': 'success',
            'data': {
                'order_id':           order.id,
                'order_name':         order.name,
                'split_group_id':     split_group_id,
                'split_person_index': split_person_index,
                'session':            session.name,
                'shop':               pos_config.name,
                'company_id':         [order.company_id.id, order.company_id.name] if order.company_id else False,
                'amount':             amount_total,
            },
            'message': f'Split order created successfully for person {split_person_index}.',
            'code': 200,
        }
        self._log(payload, res, 'success')
        return self._json_response(
            status='success', data=res['data'],
            message=res['message'], code=200)

    # ─────────────────────────────────────────────────────────────────────────
    # GET /api/order/split/<split_group_id>
    #
    # Fetch ALL sub-orders of a split group for the summary screen.
    # ─────────────────────────────────────────────────────────────────────────
    @http.route('/api/order/split/<string:split_group_id>', type='http',
                auth='none', methods=['GET'], csrf=False)
    def get_split_orders(self, split_group_id, **kwargs):

        if not self._validate_token():
            return self._json_response(
                status='error', message='Unauthorized', code=401)

        # Fetch all sub-orders sorted by person number
        orders = request.env['pos.order'].sudo().search([
            ('split_group_id', '=', split_group_id),
        ], order='split_person_index asc')

        if not orders:
            return self._json_response(
                status='error',
                message=f'No split orders found for group: {split_group_id}',
                code=404)

        result      = []
        grand_total = 0.0

        for order in orders:
            lines = []
            for line in order.lines:
                lines.append({
                    'product_id':   line.product_id.id,
                    'product_name': line.product_id.name or 'Unknown',
                    'qty':          line.qty,
                    'price_unit':   line.price_unit,
                    'subtotal':     line.price_subtotal_incl,
                })

            partner       = order.partner_id
            customer_name = partner.name if partner else 'Walk-in'
            grand_total  += order.amount_total

            result.append({
                'order_id':           order.id,
                'order_name':         order.name,
                'split_person_index': order.split_person_index,
                'customer_name':      customer_name,
                'company_id':         [order.company_id.id, order.company_id.name] if order.company_id else False,
                'customer_id':        partner.id if partner else None,
                'amount_total':       order.amount_total,
                'state':              order.state,
                'lines':              lines,
            })

        return self._json_response(
            status='success',
            data={
                'split_group_id': split_group_id,
                'total_persons':  len(result),
                'grand_total':    round(grand_total, 2),
                'orders':         result,
            },
            message='Split orders fetched successfully.',
            code=200,
        )