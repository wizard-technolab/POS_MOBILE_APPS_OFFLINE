# -*- coding: utf-8 -*-
"""Customer API controller for POS API Integration."""

# Standard library
import json
import logging

# Odoo
from odoo import http
from odoo.http import request

# Third-party
import jwt as pyjwt

_logger = logging.getLogger(__name__)


class CustomerAPI(http.Controller):
    """Controller for customer search and creation APIs."""

    def _json_response(self, status="success", data=None, message="", code=200):
        """Return standard JSON response."""
        return request.make_response(
            json.dumps(
                {
                    "status": status,
                    "data": data or [],
                    "message": message,
                    "code": code,
                },
                indent=2,
            ),
            headers=[('Content-Type', 'application/json')],
            status=code
        )

    def _verify_jwt(self):
        """Verify JWT token."""

        auth_header_data = request.httprequest.headers.get('Authorization', '')
        if not auth_header_data.startswith('Bearer '):
            return None, self._json_response(
                status="error",
                message=(
                    "Missing or invalid Authorization header. "
                    "Use: Authorization: Bearer <token>"
                ),
                code=401,
            )

        token = auth_header_data[7:]

        try:
            secret = request.env['jwt.config'].sudo().get_secret_key()
            payload_data = pyjwt.decode(token, secret, algorithms=['HS256'])

        except pyjwt.ExpiredSignatureError:
            return None, self._json_response(
                status="error", message="Token expired", code=401,
            )

        except pyjwt.InvalidTokenError:
            return None, self._json_response(
                status="error", message="Invalid token", code=401,
            )

        except pyjwt.PyJWTError as exc:
            _logger.exception("JWT verification failed: %s", exc)
            return None, self._json_response(
                status="error", message="Token verification failed", code=500,
            )

        user_id_data = payload_data.get('user_id')
        if not user_id_data:
            return None, self._json_response(
                status="error", message="Invalid token payload", code=401,
            )

        return payload_data, None

    def _log_api_call(
        self,
        endpoint,
        method,
        payload_data,
        response_data,
        status='success',
    ):  # pylint: disable=too-many-arguments, too-many-positional-arguments
        """Log API calls."""
        try:
            request.env['sync.log'].sudo().create({
                'endpoint': endpoint,
                'method': method,
                'payload': (
                    json.dumps(payload_data, indent=2)
                    if isinstance(payload_data, (dict, list))
                    else str(payload_data)
                ),
                'response': json.dumps(response_data, indent=2),
                'status': status,
            })
        except Exception as exc:  # pylint: disable=broad-except
            _logger.error("Failed to log API call: %s", exc)

    def _get_credit_info(self, partner):
        """
        Return a dict with the customer's credit details.

        Fields returned:
          credit           – current outstanding receivable balance (always available)
          credit_limit     – configured limit (0 = no limit set)
          credit_on_hold   – True means the account is blocked
          available_credit – how much they can still spend before hitting the limit
                             (None when credit_limit = 0, meaning no limit)
        """
        # 'credit' is a standard computed field on res.partner (account module).
        # It sums all open receivable journal items for this partner.
        credit = round(partner.credit or 0.0, 2)

        # credit_limit — field added by account_credit_control module or custom code.
        # Use getattr() so this never crashes on a bare Odoo install.
        credit_limit = 0.0
        try:
            credit_limit = round(getattr(partner, 'credit_limit', 0.0) or 0.0, 2)
        except Exception:  # pylint: disable=broad-except
            credit_limit = 0.0

        # credit_on_hold — True when the account is manually blocked by the manager.
        credit_on_hold = False
        try:
            credit_on_hold = bool(getattr(partner, 'credit_on_hold', False))
        except Exception:  # pylint: disable=broad-except
            credit_on_hold = False

        # available_credit = limit − used.  None when no limit is configured.
        available_credit = None
        if credit_limit > 0:
            available_credit = round(max(0.0, credit_limit - credit), 2)

        return {
            'credit':           credit,
            'credit_limit':     credit_limit,   # 0 means no limit configured
            'credit_on_hold':   credit_on_hold, # True = account blocked
            'available_credit': available_credit,  # None when no limit set
        }

    # ──────────────────────────────────────────────────────────
    # GET /api/customers/search
    #
    # NOW ALSO RETURNS credit info so Flutter can show a warning
    # in the cart/payment sheet before the order is submitted.
    #
    # New response fields per customer:
    #   credit           – outstanding balance
    #   credit_limit     – configured limit (0 = unlimited)
    #   credit_on_hold   – True = account blocked
    #   available_credit – remaining allowed spend (null if no limit)
    # ──────────────────────────────────────────────────────────
    @http.route('/api/customers/search', type='http', auth='public', methods=['GET'], csrf=False)
    def search_customer(self, **kwargs):
        """Search customers."""

        _payload_data, auth_error = self._verify_jwt()
        if auth_error:
            return auth_error

        endpoint = '/api/customers/search'
        method = 'GET'

        all_flag   = kwargs.get('all', '')
        query      = (kwargs.get('query') or '').strip()
        phone_data = (kwargs.get('phone') or '').strip()
        email_data = (kwargs.get('email') or '').strip()

        if all_flag == '1':
            # Load all customers, filter by query if provided
            if query:
                domain = ['|',
                    ('name',  'ilike', query),
                    ('phone', 'ilike', query),
                ]
            else:
                # Include both companies and persons, excluding internal/private contacts
                domain = [('active', '=', True), ('type', '!=', 'private')]
        elif phone_data:
            domain = [('phone', 'ilike', phone_data)]
        elif email_data:
            domain = [('email', 'ilike', email_data)]
        else:
            resp_data = {
                "status": "error",
                "data": [],
                "message": "Provide all=1, phone or email",
                "code": 400,
            }
            self._log_api_call(endpoint, method, kwargs, resp_data, 'error')
            return self._json_response(**resp_data)

        partner_ids = request.env['res.partner'].sudo().search(
            domain, limit=50, order='name asc')

        results = []
        for p in partner_ids:
            # Merge base fields + credit info into one dict per customer
            results.append({
                "id":    p.id,
                "name":  p.name,
                "phone": p.phone or "",
                "email": p.email or "",
                **self._get_credit_info(p),   # adds credit, credit_limit, etc.
            })

        if not results:
            resp_data = {"data": [], "message": "No customer found", "code": 200}
            self._log_api_call(endpoint, method, kwargs, resp_data)
            return self._json_response(**resp_data)

        resp_data = {"data": results, "message": "Customer(s) found", "code": 200}
        self._log_api_call(endpoint, method, kwargs, resp_data)
        return self._json_response(**resp_data)

    # ──────────────────────────────────────────────────────────
    # GET /api/customers/ids
    #
    # Returns a list of all active customer IDs.
    # Used by Flutter DeltaSyncManager to identify deleted/new records.
    # ──────────────────────────────────────────────────────────
    @http.route('/api/customers/ids', type='http', auth='public', methods=['GET'], csrf=False)
    def get_customer_ids(self, **kwargs):
        """Return list of all active customer IDs."""
        _payload, auth_error = self._verify_jwt()
        if auth_error:
            return auth_error

        domain = [('active', '=', True), ('type', '!=', 'private')]
        partner_ids = request.env['res.partner'].sudo().search(domain).ids
        
        return self._json_response(data=partner_ids)

    # ──────────────────────────────────────────────────────────
    # GET /api/customers/by-ids
    #
    # Returns full customer details for a list of IDs.
    # Query param: ids=1,2,3
    # ──────────────────────────────────────────────────────────
    @http.route('/api/customers/by-ids', type='http', auth='public', methods=['GET'], csrf=False)
    def get_customers_by_ids(self, **kwargs):
        """Fetch details for specific customer IDs."""
        _payload, auth_error = self._verify_jwt()
        if auth_error:
            return auth_error

        ids_raw = kwargs.get('ids', '')
        if not ids_raw:
            return self._json_response(
                status="error", message="Missing 'ids' parameter", code=400)

        try:
            ids = [int(i) for i in ids_raw.split(',') if i.strip()]
        except (ValueError, TypeError):
            return self._json_response(
                status="error", message="Invalid 'ids' format", code=400)

        if not ids:
            return self._json_response(data=[])

        partners = request.env['res.partner'].sudo().browse(ids).exists()
        
        results = []
        for p in partners:
            results.append({
                "id":    p.id,
                "name":  p.name,
                "phone": p.phone or "",
                "email": p.email or "",
                **self._get_credit_info(p),
            })

        return self._json_response(
            data=results, 
            message=f"Fetched {len(results)} customer(s)")

    # ──────────────────────────────────────────────────────────
    # GET /api/customer/<customer_id>/credit
    #
    # PURPOSE:
    #   Return real-time credit status for ONE customer.
    #   Call this in the Flutter cart just before showing the payment
    #   sheet — so the cashier sees an up-to-date warning even if the
    #   customer was selected earlier in the session.
    #
    # Response:
    # {
    #   "status": "success",
    #   "data": {
    #     "customer_id":     12,
    #     "customer_name":   "John Doe",
    #     "credit":          4500.00,   ← current outstanding balance
    #     "credit_limit":    5000.00,   ← configured limit (0 = no limit)
    #     "credit_on_hold":  false,     ← true = account is blocked
    #     "available_credit": 500.00   ← how much they can still spend
    #   }
    # }
    #
    # Flutter usage:
    #   1. Call this when customer is selected in cart.
    #   2. If credit_on_hold == true  → show RED banner, block checkout.
    #   3. If available_credit != null and order_total > available_credit
    #      → show ORANGE warning, allow override with manager PIN.
    #   4. If credit_limit == 0 → no limit, no warning needed.
    # ──────────────────────────────────────────────────────────
    @http.route('/api/customer/<int:customer_id>/credit',
                type='http', auth='none', methods=['GET'], csrf=False)
    def get_customer_credit(self, customer_id, **kwargs):
        """Return credit status for a single customer."""

        _payload_data, auth_error = self._verify_jwt()
        if auth_error:
            return auth_error

        partner = request.env['res.partner'].sudo().browse(customer_id)
        if not partner.exists():
            return self._json_response(
                status='error', message='Customer not found', code=404)

        credit_info = self._get_credit_info(partner)

        resp_data = {
            'customer_id':   customer_id,
            'customer_name': partner.name,
            **credit_info,
        }

        self._log_api_call(
            f'/api/customer/{customer_id}/credit', 'GET',
            {'customer_id': customer_id},
            resp_data, 'success')

        return self._json_response(
            status='success',
            data=resp_data,
            message='Customer credit info fetched.',
            code=200,
        )

    # ──────────────────────────────────────────────────────────────────────────
    # POST /api/customers/create
    # ──────────────────────────────────────────────────────────────────────────
    @http.route('/api/customers/create', type='http', auth='public', methods=['POST'], csrf=False)
    def create_customer(self):
        """Create customer."""

        _payload_data, auth_error = self._verify_jwt()
        if auth_error:
            return auth_error

        try:
            body_vals = json.loads(request.httprequest.data)
        except (ValueError, TypeError):
            return self._json_response(
                status="error",
                message="Invalid JSON",
                code=400,
            )

        name_data = body_vals.get('name')
        phone_data = body_vals.get('phone')
        email_data = body_vals.get('email')

        if not name_data:
            return self._json_response(status="error", message="Name required", code=400)

        if not phone_data and not email_data:
            return self._json_response(status="error", message="Phone/email required", code=400)

        domain = []
        if phone_data and email_data:
            domain = ['|', ('phone', '=', phone_data), ('email', '=', email_data)]
        elif phone_data:
            domain = [('phone', '=', phone_data)]
        else:
            domain = [('email', '=', email_data)]

        existing_partner_ids = request.env['res.partner'].sudo().search(domain, limit=1)

        if existing_partner_ids:
            return self._json_response(
                data={"id": existing_partner_ids.id},
                message="Customer exists",
                code=200,
            )

        new_partner_ids = request.env['res.partner'].sudo().create({
            'name': name_data,
            'phone': phone_data,
            'email': email_data,
            'company_type': 'person',
        })

        return self._json_response(
            data={"id": new_partner_ids.id},
            message="Customer created",
            code=200,
        )

    # ──────────────────────────────────────────────────────────
    # PUT /api/customers/<customer_id>/update
    # ──────────────────────────────────────────────────────────
    @http.route('/api/customers/<int:customer_id>/update',
                type='http', auth='public', methods=['PUT'], csrf=False)
    def update_customer(self, customer_id, **kwargs):
        """Update existing customer."""

        _payload_data, auth_error = self._verify_jwt()
        if auth_error:
            return auth_error

        # Parse request body
        try:
            body_vals = json.loads(request.httprequest.data)
        except (ValueError, TypeError):
            return self._json_response(
                status="error", message="Invalid JSON", code=400)

        # Find the customer
        partner = request.env['res.partner'].sudo().browse(customer_id)
        if not partner.exists():
            return self._json_response(
                status="error", message="Customer not found", code=404)

        # Build update values — only update fields that are provided
        update_vals = {}
        if body_vals.get('name'):
            update_vals['name'] = body_vals['name']
        if 'phone' in body_vals:
            update_vals['phone'] = body_vals['phone']
        if 'email' in body_vals:
            update_vals['email'] = body_vals['email']

        if not update_vals:
            return self._json_response(
                status="error",
                message="No fields to update. Provide name, phone, or email.",
                code=400)

        partner.sudo().write(update_vals)

        resp_data = {
            "id":    partner.id,
            "name":  partner.name,
            "phone": partner.phone or "",
            "email": partner.email or "",
        }

        self._log_api_call(
            '/api/customers/update', 'PUT',
            {'customer_id': customer_id, **body_vals},
            resp_data, 'success')

        return self._json_response(
            data=resp_data,
            message="Customer updated successfully.",
            code=200)
