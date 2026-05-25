# -*- coding: utf-8 -*-
"""Subscription License API controller for POS API Integration."""

import json
import logging

from odoo import http
from odoo.http import request

_logger = logging.getLogger(__name__)


class SubscriptionController(http.Controller):
    """Controller for subscription license validation via REST API."""

    def _json_response(self, status="success", data=None, message="", code=200):
        """Return standard JSON response."""
        body = json.dumps({
            "status": status,
            "data": data or {},
            "message": message,
            "code": code,
        }, indent=2, default=str)

        return request.make_response(
            body,
            headers=[('Content-Type', 'application/json')],
            status=code,
        )

    @http.route(
        '/api/v1/subscription/validate',
        type='http',
        auth='public',
        methods=['POST'],
        csrf=False,
        cors='*',
    )
    def validate_subscription(self, **kwargs):
        """
        Validate a subscription license code.
        
        Request body (JSON):
        {
            "code": "LICENSE-ABC123-XYZ789",
            "email": "user@example.com"   // optional but recommended
        }
        
        Response (200):
        {
            "status": "success",
            "data": {
                "exp_date": "2025-12-31",
                "days_remaining": 365
            },
            "message": "License valid until 2025-12-31",
            "code": 200
        }
        
        Response (401):
        {
            "status": "error",
            "data": {},
            "message": "License code not found",
            "code": 401
        }
        """
        try:
            # Parse JSON body
            raw_body = request.httprequest.data
            if not raw_body:
                return self._json_response(
                    status="error",
                    message="Request body is empty",
                    code=400,
                )

            try:
                body_data = json.loads(raw_body.decode('utf-8'))
            except (ValueError, TypeError, UnicodeDecodeError):
                return self._json_response(
                    status="error",
                    message="Invalid JSON body",
                    code=400,
                )

            code = (body_data.get('code') or '').strip().upper()
            email = (body_data.get('email') or '').strip().lower()

            # 🔍 DEBUG: Log what was received
            _logger.info(f"🔍 LICENSE VALIDATION REQUEST")
            _logger.info(f"   Received code: '{code}'")
            _logger.info(f"   Received email: '{email}'")
            _logger.info(f"   Code length: {len(code)}")
            _logger.info(f"   Code uppercase: '{code.upper()}'")

            if not code:
                return self._json_response(
                    status="error",
                    message="License code is required",
                    code=400,
                )

            # Validate the license using the model method
            SubscriptionLicense = request.env['subscription.license'].sudo()
            
            # 🔍 DEBUG: Show all existing licenses
            all_licenses = SubscriptionLicense.search([])
            _logger.info(f"📋 Total licenses in system: {len(all_licenses)}")
            for lic in all_licenses:
                _logger.info(f"   - Code: '{lic.code}' | Exp: {lic.expiration_date} | Status: {lic.status}")

            # Call the model's validate method
            result = SubscriptionLicense.validate_license_code(code, email=email or None)

            _logger.info(f"✓ Validation result: {result}")

            if result['status'] == 'success':
                # Calculate days remaining
                from datetime import datetime as dt
                exp_date = dt.strptime(result['exp_date'], '%Y-%m-%d').date()
                today = dt.now().date()
                days_remaining = (exp_date - today).days

                return self._json_response(
                    status="success",
                    data={
                        "exp_date": result['exp_date'],
                        "days_remaining": max(0, days_remaining),
                    },
                    message=result['message'],
                    code=200,
                )
            else:
                return self._json_response(
                    status="error",
                    data={
                        "exp_date": result.get('exp_date', ''),
                    },
                    message=result['message'],
                    code=401,
                )

        except json.JSONDecodeError as e:
            _logger.error(f"JSON decode error: {e}")
            return self._json_response(
                status="error",
                message="Invalid JSON body",
                code=400,
            )
        except Exception as exc:
            _logger.exception("License validation error: %s", exc)
            return self._json_response(
                status="error",
                message="Internal server error during license validation",
                code=500,
            )
