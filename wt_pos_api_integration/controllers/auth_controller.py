# -*- coding: utf-8 -*-
"""Authentication controller for JWT-based API with token expiration."""

# Standard library
import json
import logging
from datetime import datetime, timedelta

# Odoo
from odoo import http
from odoo.http import request, Response
from odoo.exceptions import AccessDenied

# Third-party
import jwt

_logger = logging.getLogger(__name__)

TOKEN_EXPIRY_HOURS = 24
TOKEN_EXPIRY_SECONDS = TOKEN_EXPIRY_HOURS * 60 * 60


def _json_response(data: dict, status: int = 200) -> Response:
    """Return JSON HTTP response."""
    return Response(
        json.dumps(data),
        status=status,
        headers={'Content-Type': 'application/json'},
    )


def _build_token(user_id: int, email: str, secret: str,
                 expires_in_hours: int = TOKEN_EXPIRY_HOURS) -> str:
    """Generate JWT token with a backwards-compatible 24-hour expiration."""
    now = datetime.utcnow()
    payload_data = {
        'user_id': user_id,
        'email': email,
        'iat': now,
        'exp': now + timedelta(hours=expires_in_hours),
    }
    token = jwt.encode(payload_data, secret, algorithm='HS256')
    if isinstance(token, bytes):
        token = token.decode('utf-8')
    return token


class AuthController(http.Controller):
    """Controller for authentication endpoints."""

    @http.route(
        '/api/v1/auth',
        type='http',
        auth='none',
        methods=['POST'],
        csrf=False,
    )
    def authenticate(self, **_kwargs):  # renamed to avoid unused warning
        """Authenticate user and return a JWT access token."""

        try:
            body_data = json.loads(request.httprequest.data or '{}')
        except (ValueError, TypeError):
            return _json_response(
                {'status': 'error', 'message': 'Invalid JSON body'},
                status=400,
            )

        email = (body_data.get('email') or '').strip().lower()
        password = body_data.get('password') or ''

        if not email or not password:
            return _json_response(
                {'status': 'error', 'message': 'Email and password required'},
                status=400,
            )

        try:
            credential_data = {
                'type': 'password',
                'login': email,
                'password': password,
            }

            auth_info = request.env['res.users'].sudo().authenticate(
                credential_data,
                {'interactive': False},
            )

        except AccessDenied:
            # Log failed login attempt for security monitoring
            _logger.warning(
                'Failed authentication attempt for email %s from IP %s',
                email,
                request.httprequest.remote_addr,
            )
            return _json_response(
                {'status': 'error', 'message': 'Invalid credentials'},
                status=401,
            )
        except Exception as exc:  # pylint: disable=broad-except
            _logger.exception('Auth error: %s', exc)
            return _json_response(
                {'status': 'error', 'message': 'Internal server error'},
                status=500,
            )

        user_id_data = auth_info.get('uid')

        try:
            user_recs = request.env['res.users'].sudo().browse(user_id_data)
            user_email = (user_recs.email or user_recs.login or '').lower()

            # POS app access: allow POS User, POS Manager, or Odoo Settings/System admin.
            # In Odoo, general Administrators may not always explicitly carry
            # point_of_sale.group_pos_user, especially after group XML/cache changes.
            has_pos_user_group = user_recs.has_group('point_of_sale.group_pos_user')
            has_pos_manager_group = user_recs.has_group('point_of_sale.group_pos_manager')
            has_system_admin_group = user_recs.has_group('base.group_system')

            if not (has_pos_user_group or has_pos_manager_group or has_system_admin_group):
                _logger.warning(
                    'Security Audit: User %s (ID: %s) authenticated but lacks POS/API access from IP %s',
                    email, user_id_data, request.httprequest.remote_addr,
                )
                try:
                    request.env['sync.log'].sudo().create({
                        'endpoint': '/api/v1/auth',
                        'method': 'POST',
                        'payload': json.dumps({'email': email, 'event': 'POS_UNAUTHORIZED_LOGIN'}),
                        'response': json.dumps({'status': 'error', 'message': 'Authenticated but lacks POS/API groups'}),
                        'status': 'error',
                    })
                except Exception:
                    pass
                return _json_response(
                    {
                        'status': 'error',
                        'message': 'This user does not have Point of Sale access.',
                        'code': 403,
                    },
                    status=403,
                )

        except Exception as exc:  # pylint: disable=broad-except
            _logger.exception('User fetch failed: %s', exc)
            return _json_response(
                {'status': 'error', 'message': 'Internal server error'},
                status=500,
            )

        try:
            secret = request.env['jwt.config'].sudo().get_secret_key()
            token = _build_token(
                user_id_data,
                user_email,
                secret,
                expires_in_hours=TOKEN_EXPIRY_HOURS,
            )

        except Exception as exc:  # pylint: disable=broad-except
            _logger.exception('Token generation failed: %s', exc)
            return _json_response(
                {'status': 'error', 'message': 'Token generation failed'},
                status=500,
            )

        _logger.info(
            'Successful authentication for user %s (ID: %s) from IP %s',
            email,
            user_id_data,
            request.httprequest.remote_addr,
        )

        return _json_response({
            'status': 'success',
            'token': token,
            'user_id': user_id_data,
            'email': user_email,
            'expires_in': TOKEN_EXPIRY_SECONDS,
        })
