from odoo import fields, models


class ResourceBooking(models.Model):
    _inherit = "resource.booking"

    sale_order_id = fields.Many2one("sale.order", "Sales order", copy=False, index=True)
    deposit_invoice_id = fields.Many2one(
        "account.move", "Deposit invoice", copy=False, index=True
    )
