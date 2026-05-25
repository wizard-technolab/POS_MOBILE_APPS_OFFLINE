# -*- coding: utf-8 -*-
"""Device model for POS API Integration."""

from odoo import models, fields


class DeviceDevice(models.Model):
    """Model to manage devices."""

    _name = 'device.device'
    _description = 'Device'

    name = fields.Char(string='Name', required=True)
    device_code = fields.Char(string='Device Code', required=True)
    status = fields.Selection(
        [
            ('active', 'Active'),
            ('inactive', 'Inactive')
        ],
        string='Status',
        default='active'
    )
    last_seen = fields.Datetime(string="Last Seen")
    branch_id = fields.Many2one('device.branch', string='Branch')
