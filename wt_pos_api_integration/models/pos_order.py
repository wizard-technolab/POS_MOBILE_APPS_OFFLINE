from odoo import models, fields


class PosOrder(models.Model):
    _inherit = 'pos.order'

    # ── Existing custom fields (do not remove) ────────────────────────────────
    external_pos_id = fields.Char(
        string='External POS ID',
        index=True
    )
    device_code = fields.Many2one(
        'device.device',
        string='Device'
    )
    raw_payload = fields.Html(
        string='Raw Payload'
    )

    # ── SPLIT BILL: Shared group ID ───────────────────────────────────────────
    # When a bill is split, ALL sub-orders share the same split_group_id.
    # Flutter generates this UUID ONCE when user taps the Split button.
    # Example: "SPLIT-550e8400-e29b-41d4-a716-446655440000"
    #
    # This lets you:
    #   - Fetch all parts of a split: search([('split_group_id','=', uuid)])
    #   - Show a "split summary" screen after all persons have paid
    split_group_id = fields.Char(
        string='Split Group ID',
        index=True,
        help='Shared UUID across all sub-orders of a split bill'
    )

    # ── SPLIT BILL: Which person is this order for? ───────────────────────────
    # 0 = not a split order (normal order)
    # 1 = first person's sub-order
    # 2 = second person's sub-order
    # 3 = third person's sub-order, etc.
    split_person_index = fields.Integer(
        string='Split Person Index',
        default=0,
        help='0=normal order, 1=first split person, 2=second, etc.'
    )

    # ── Order-level customer note entered in Flutter before placing order ─────
    # Example: "No onions", "Extra spicy", "Less salt"
    customer_note = fields.Text(
        string='Customer Note',
        help='Optional note from the customer for the entire order.'
    )

    # ── SQL constraint: prevent duplicate orders from same device ─────────────
    _sql_constraints = [
        (
            'unique_external_device',
            'unique_external_device',
            'UNIQUE(external_pos_id, device_code)',
            'Order with this external ID and device already exists!'
        )
    ]

    def _compute_order_name(self, session=None):
        """Override to format name as: Session Name - Device Code - Sequence."""
        if self.refunded_order_id:
            return super()._compute_order_name(session)

        session = session or self.session_id
        # Extract the sequence number (last part of the receipt/reference)
        last_part = self.get_reference_last_part()
        # Use the code from the Many2one device relation, fallback to 'API' if not set
        device_str = self.device_code.device_code if self.device_code else 'API'
        
        return f"{session.name} - {device_str} - {last_part}"


class PosOrderLine(models.Model):
    _inherit = 'pos.order.line'

    # ── Per-item customer note entered in Flutter cart screen ─────────────────
    # Different from 'note' field which is the kitchen/internal note.
    # This note is customer-facing (shown on receipt / order history).
    # Example: user taps "Customer Note" on a specific item → "No cheese"
    customer_note = fields.Text(
        string='Customer Note',
        help='Per-item note from the customer, shown on receipt.'
    )
