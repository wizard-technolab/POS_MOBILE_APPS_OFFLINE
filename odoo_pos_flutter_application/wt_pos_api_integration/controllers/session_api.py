# ─────────────────────────────────────────────────────────────────────────────
# session_api.py  — POS Session listing endpoint
#
# Exposes GET /api/v1/pos-sessions
# Returns all currently OPEN POS sessions so the Flutter app can show
# a dropdown and let the cashier pick which session to use.
# ─────────────────────────────────────────────────────────────────────────────
import json
import jwt
from odoo import http
from odoo.http import request


class PosSessionApiController(http.Controller):

    # ── Token validation (same pattern as other controllers) ────────────────
    def _validate_token(self):
        """Verify the JWT Bearer token from the Authorization header."""
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

    # ── JSON response helper ─────────────────────────────────────────────────
    def _json_response(self, status='success', data=None, message='', code=200):
        return request.make_response(
            json.dumps({
                'status': status,
                'data': data or [],
                'message': message,
                'code': code,
            }),
            headers=[('Content-Type', 'application/json')],
            status=code,
        )

    # ── GET /api/v1/pos-sessions ─────────────────────────────────────────────
    @http.route(
        '/api/v1/pos-sessions',
        type='http',
        auth='none',
        methods=['GET'],
        csrf=False,
    )
    def list_pos_sessions(self):
        """
        Return all OPEN POS sessions.

        Response shape:
        {
          "status": "success",
          "data": [
            {
              "id": 5,
              "name": "Opening 0005",
              "pos_config_id": 1,
              "pos_config_name": "Shop",
              "state": "opened"
            },
            ...
          ]
        }
        """
        # Validate JWT token first
        if not self._validate_token():
            return self._json_response(
                status='error', message='Unauthorized', code=401)

        # Fetch all currently open sessions
        sessions = request.env['pos.session'].sudo().search([
            ('state', '=', 'opened'),
        ])

        session_list = []
        for session in sessions:
            session_list.append({
                'id':              session.id,
                'name':            session.name or '',
                'pos_config_id':   session.config_id.id if session.config_id else 0,
                'pos_config_name': session.config_id.name if session.config_id else '',
                'state':           session.state,
                # Currency from POS config — e.g. "₹", "$", "€"
                'company_id':      [session.company_id.id, session.company_id.name] if session.company_id else False,
                'currency_symbol': session.currency_id.symbol if session.currency_id else '₹',
                'currency_name':   session.currency_id.name if session.currency_id else 'INR',
            })

        return self._json_response(data=session_list)