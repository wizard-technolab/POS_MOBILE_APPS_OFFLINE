# -*- coding: utf-8 -*-
"""Extend res.users to include subscription license fields."""

from odoo import models, fields, api


class ResUsersSubscription(models.Model):
    """Add subscription license fields on users."""

    _inherit = 'res.users'

    subscription_license_id = fields.Many2one(
        'subscription.license',
        string='Subscription License',
        compute='_compute_subscription_license',
        store=False,
    )

    subscription_code = fields.Char(
        string='Subscription Code',
        compute='_compute_subscription_license',
        store=False,
    )

    subscription_exp_date = fields.Date(
        string='Subscription Expiration Date',
        compute='_compute_subscription_license',
        store=False,
    )

    subscription_status = fields.Selection(
        [
            ('active', 'Active'),
            ('expired', 'Expired'),
            ('not_activated', 'Not Activated'),
        ],
        string='Subscription Status',
        compute='_compute_subscription_status',
        store=False,
    )

    subscription_days_remaining = fields.Integer(
        string='Days Remaining',
        compute='_compute_subscription_days_remaining',
        store=False,
    )

    @api.depends()
    def _compute_subscription_license(self):
        """Fetch subscription license linked to the user."""
        License = self.env['subscription.license'].sudo()

        for user in self:
            license_rec = License.search(
                [('user_id', '=', user.id)],
                limit=1,
            )

            user.subscription_license_id = license_rec
            user.subscription_code = license_rec.code or False
            user.subscription_exp_date = (
                license_rec.expiration_date or False
            )

    @api.depends('subscription_exp_date')
    def _compute_subscription_status(self):
        """Compute subscription status based on expiration date."""
        today = fields.Date.today()

        for user in self:
            if not user.subscription_exp_date:
                user.subscription_status = 'not_activated'

            elif user.subscription_exp_date < today:
                user.subscription_status = 'expired'

            else:
                user.subscription_status = 'active'

    @api.depends('subscription_exp_date')
    def _compute_subscription_days_remaining(self):
        """Calculate remaining subscription days."""
        today = fields.Date.today()

        for user in self:
            if not user.subscription_exp_date:
                user.subscription_days_remaining = 0

            else:
                days = (
                    user.subscription_exp_date - today
                ).days

                user.subscription_days_remaining = max(0, days)

    def activate_subscription(self, code):
        """
        Activate subscription for this user.

        Args:
            code (str): License code

        Returns:
            dict: Activation result
        """

        if not code or not code.strip():
            return {
                'status': 'error',
                'message': 'License code cannot be empty',
            }

        try:
            result = (
                self.env['subscription.license']
                .sudo()
                .validate_license_code(
                    code.strip(),
                    email=self.login,
                )
            )

            return result

        except Exception as e:
            return {
                'status': 'error',
                'message': f'Activation failed: {str(e)}',
            }