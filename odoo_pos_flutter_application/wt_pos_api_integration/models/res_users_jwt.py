# -*- coding: utf-8 -*-
"""Extend res.users to include JWT token generation."""

# Standard library
import logging

# Odoo
from odoo import models, fields

# Third-party
import jwt
from jwt import PyJWTError

_logger = logging.getLogger(__name__)


class ResUsersJwt(models.Model):
    """Add computed JWT token field on users."""

    _inherit = 'res.users'

    jwt_token = fields.Char(
        string='JWT Token',
        compute='_compute_jwt_token',
        store=False,
        readonly=True,
    )

    def _compute_jwt_token(self):
        """Compute JWT token for each user."""
        # sudo: required to access system configuration
        secret = self.env['jwt.config'].sudo().get_secret_key()

        for user in self:
            try:
                payload_data = {
                    'user_id': user.id,
                    'email': (user.email or user.login or '').lower(),
                }
                user.jwt_token = jwt.encode(payload_data, secret, algorithm='HS256')

            except PyJWTError as exc:
                _logger.exception(
                    'Failed to compute JWT token for user id=%s: %s',
                    user.id,
                    exc,
                )
                user.jwt_token = ''
                