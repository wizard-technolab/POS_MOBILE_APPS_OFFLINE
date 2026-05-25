# -*- coding: utf-8 -*-
"""Authentication controller for JWT-based API."""

# Standard library
import json
import logging

# Odoo
from odoo import http
from odoo.http import request, Response
from odoo.exceptions import AccessDenied

# Third-party
import jwt

_logger = logging.getLogger(__name__)


def _json_response(data: dict, status: int = 200) -> Response:
    """Return JSON HTTP response."""
    return Response(
        json.dumps(data),
        status=status,
        headers={'Content-Type': 'application/json'},
    )


def _build_token(user_id: int, email: str, secret: str) -> str:
    """Generate JWT token."""
    payload_data = {
        'user_id': user_id,
        'email': email,
    }
    return jwt.encode(payload_data, secret, algorithm='HS256')


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
        """Authenticate user and return JWT token."""

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

        except Exception as exc:  # pylint: disable=broad-except
            _logger.exception('User fetch failed: %s', exc)
            return _json_response(
                {'status': 'error', 'message': 'Internal server error'},
                status=500,
            )

        try:
            secret = request.env['jwt.config'].sudo().get_secret_key()
            token = _build_token(user_id_data, user_email, secret)

        except Exception as exc:  # pylint: disable=broad-except
            _logger.exception('Token generation failed: %s', exc)
            return _json_response(
                {'status': 'error', 'message': 'Token generation failed'},
                status=500,
            )

        return _json_response({
            'status': 'success',
            'token': token,
            'user_id': user_id_data,
            'email': user_email,
        })
