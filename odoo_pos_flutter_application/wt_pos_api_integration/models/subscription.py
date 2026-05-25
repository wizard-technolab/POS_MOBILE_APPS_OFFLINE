# -*- coding: utf-8 -*-
"""Subscription License model for POS API Integration."""

from odoo import models, fields, api
from datetime import datetime, timedelta


class SubscriptionLicense(models.Model):
    """Model to manage device subscription licenses."""

    _name = 'subscription.license'
    _description = 'Device Subscription License'
    _rec_name = 'code'

    code = fields.Char(
        string='License Code',
        required=True,
        copy=False,
        help='Unique subscription code (e.g., LICENSE-ABC123-XYZ789)',
    )
    expiration_date = fields.Date(
        string='Expiration Date',
        required=True,
        help='Date when this license expires',
    )
    user_id = fields.Many2one(
        'res.users',
        string='Assigned User',
        ondelete='cascade',
        help='User to whom this license is assigned',
    )
    email = fields.Char(
        string='Assigned Email',
        compute='_compute_email',
        store=True,
        help='Email of the assigned user (auto-filled from user)',
    )
    status = fields.Selection(
        [
            ('active', 'Active'),
            ('expired', 'Expired'),
            ('revoked', 'Revoked'),
        ],
        string='Status',
        default='active',
        compute='_compute_status',
        store=True,
    )
    notes = fields.Text(
        string='Notes',
        help='Internal notes about this license',
    )
    created_at = fields.Datetime(
        string='Created At',
        default=fields.Datetime.now,
    )
    updated_at = fields.Datetime(
        string='Updated At',
        default=fields.Datetime.now,
    )

    _sql_constraints = [
        ('code_unique', 'UNIQUE(code)', 'License code must be unique!'),
    ]

    @api.model_create_multi
    def create(self, vals_list):
        """Convert license codes to uppercase before saving."""
        for vals in vals_list:
            if 'code' in vals and vals['code']:
                vals['code'] = vals['code'].strip().upper()
        return super().create(vals_list)

    @api.depends('user_id', 'user_id.login')
    def _compute_email(self):
        """Auto-fill email from the assigned user."""
        for record in self:
            if record.user_id:
                record.email = record.user_id.login or record.user_id.email or ''
            else:
                record.email = ''

    @api.depends('expiration_date')
    def _compute_status(self):
        """Compute license status based on expiration date."""
        today = fields.Date.today()
        for record in self:
            # Don't overwrite if manually revoked
            if record.status == 'revoked':
                continue
            if record.expiration_date:
                if record.expiration_date < today:
                    record.status = 'expired'
                else:
                    record.status = 'active'
            else:
                record.status = 'active'

    def write(self, vals):
        """Override write to update the updated_at timestamp."""
        vals['updated_at'] = fields.Datetime.now()
        return super().write(vals)

    @api.model
    def validate_license_code(self, code, email=None):
        """
        Validate a license code and optionally check email match.
        
        Args:
            code (str): The license code to validate
            email (str, optional): The user's email to verify ownership
            
        Returns:
            dict: {
                'status': 'success' or 'error',
                'exp_date': '2025-12-31',
                'message': 'License valid until 2025-12-31'
            }
        """
        if not code or not code.strip():
            return {
                'status': 'error',
                'message': 'License code cannot be empty',
            }

        code = code.strip().upper()

        # Search for the license code
        license_record = self.sudo().search(
            [('code', '=', code)],
            limit=1,
        )

        if not license_record:
            return {
                'status': 'error',
                'message': 'License code not found',
            }

        # Check if revoked
        if license_record.status == 'revoked':
            return {
                'status': 'error',
                'message': 'License has been revoked',
            }

        # Check if expired
        today = fields.Date.today()
        if license_record.expiration_date and license_record.expiration_date < today:
            return {
                'status': 'error',
                'message': 'License has expired',
                'exp_date': license_record.expiration_date.isoformat(),
            }

        # Check email match (if email provided and user is assigned)
        if email and license_record.user_id:
            user_email = (license_record.user_id.login or '').strip().lower()
            provided_email = email.strip().lower()

            if user_email and user_email != provided_email:
                return {
                    'status': 'error',
                    'message': 'This license is not assigned to your account',
                }

        # If no user assigned yet and email provided, assign the user
        if email and not license_record.user_id:
            user = self.env['res.users'].sudo().search(
                [('login', '=ilike', email.strip())],
                limit=1,
            )
            if user:
                license_record.sudo().write({'user_id': user.id})

        # License is valid
        return {
            'status': 'success',
            'exp_date': license_record.expiration_date.isoformat(),
            'message': f'License valid until {license_record.expiration_date.isoformat()}',
        }
