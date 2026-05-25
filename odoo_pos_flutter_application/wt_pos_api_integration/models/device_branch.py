# -*- coding: utf-8 -*-
"""Device Branch model for POS API Integration."""

from odoo import models, fields


class DeviceBranch(models.Model):
    """Model to manage device branches."""

    _name = 'device.branch'
    _description = 'Device Branch'

    name = fields.Char(string='Name', required=True)
    code = fields.Char(string="Code")
    active = fields.Boolean(string='Active', default=True)
    device_ids = fields.One2many(
        'device.device',
        'branch_id',
        string='Devices'
    )
