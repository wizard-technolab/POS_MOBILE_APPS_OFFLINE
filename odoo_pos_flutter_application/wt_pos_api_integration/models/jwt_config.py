# -*- coding: utf-8 -*-
"""JWT Configuration model for POS API Integration."""

import os
import logging

from odoo import models, fields, api

_logger = logging.getLogger(__name__)


class JwtConfig(models.Model):
    """Model to store JWT configuration and secret key."""

    _name = 'jwt.config'
    _description = 'JWT Configuration'
    _rec_name = 'name'

    name = fields.Char(
        string='Config Name',
        default='Default JWT Config',
        required=True
    )
    secret_key = fields.Char(
        string='Secret Key',
        required=True,
        help=(
            'HMAC-SHA256 secret used to sign JWT tokens. '
            'Never change this in production unless you intend '
            'to invalidate all existing tokens.'
        ),
    )

    @api.model
    def get_secret_key(self):
        """Return the active secret key, creating a default config if absent."""
        config_ids = self.search([], limit=1)
        if not config_ids:
            _logger.warning('jwt.config: no record found – generating a new secret key.')
            config_ids = self.create({
                'name': 'Default JWT Config',
                'secret_key': self._generate_secret(),
            })
        return config_ids.secret_key

    @staticmethod
    def _generate_secret(length=64):
        """Generate a cryptographically random hex secret."""
        return os.urandom(length).hex()
        
