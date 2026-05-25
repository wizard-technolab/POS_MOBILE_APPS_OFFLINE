# -*- coding: utf-8 -*-
"""Sync Log model for POS API Integration."""

from odoo import models, fields, api


class SyncLog(models.Model):
    """Model to store API sync logs."""

    _name = 'sync.log'
    _description = 'API Sync Log'
    _order = 'created_at desc'

    name = fields.Char(string='Name', compute='_compute_name', store=True)
    endpoint = fields.Char(string='Endpoint')
    method = fields.Char(string='Method')
    payload = fields.Text(string='Payload')
    response = fields.Text(string='Response')
    status = fields.Selection(
        [
            ('success', 'Success'),
            ('error', 'Error'),
            ('pending', 'Pending'),
            ('cancel', 'Cancel'), 
        ],
        string='Status',
        default='pending'
    )
    created_at = fields.Datetime(
        string='Created At',
        default=fields.Datetime.now
    )
    device_id = fields.Many2one(
        'device.device',
        string='Related Device'
    )

    @api.depends('created_at', 'endpoint')
    def _compute_name(self):
        """Compute display name for sync log."""
        for log in self:
            date_str = (
                log.created_at.strftime('%Y-%m-%d %H:%M:%S')
                if log.created_at else 'New'
            )
            log.name = f"[{date_str}]"
            
