from odoo import api, fields, models
from odoo.exceptions import ValidationError


class ResourceBookingType(models.Model):
    _inherit = "resource.booking.type"

    public_page = fields.Boolean(
        "Show on the public booking page",
        default=False,
        help="Publish this booking type at /book so anyone can book a slot.",
    )
    public_intro = fields.Html("Public description")
    public_horizon_days = fields.Integer(
        "Days shown ahead", default=60, required=True
    )
    product_id = fields.Many2one(
        "product.product",
        "Service product",
        domain=[("sale_ok", "=", True)],
        help="Invoiced when a customer books, and the base for a percentage deposit.",
    )
    deposit_mode = fields.Selection(
        [("none", "No deposit"), ("fixed", "Fixed amount"), ("percent", "Percentage")],
        default="none",
        required=True,
    )
    deposit_fixed = fields.Monetary(currency_field="currency_id")
    deposit_percent = fields.Float()
    currency_id = fields.Many2one(related="company_id.currency_id")
    deposit_amount = fields.Monetary(
        compute="_compute_deposit_amount", currency_field="currency_id"
    )
    video_call = fields.Boolean(
        "Create a video room per booking",
        default=False,
        help="Each booking gets its own private Odoo Discuss call link, sent in the "
        "invitation. Leave Meeting URL empty when this is ticked.",
    )

    @api.depends("deposit_mode", "deposit_fixed", "deposit_percent", "product_id.list_price")
    def _compute_deposit_amount(self):
        for one in self:
            if one.deposit_mode == "fixed":
                one.deposit_amount = one.deposit_fixed
            elif one.deposit_mode == "percent" and one.product_id:
                one.deposit_amount = one.product_id.list_price * one.deposit_percent / 100
            else:
                one.deposit_amount = 0.0

    @api.constrains("deposit_mode", "product_id", "deposit_fixed", "deposit_percent")
    def _check_deposit(self):
        for one in self:
            if one.deposit_mode == "none":
                continue
            # A percentage of a zero-price product invoices 0, which
            # sale.advance.payment.inv._check_amount_is_positive rejects.
            valid = (
                one.product_id
                and (
                    (one.deposit_mode == "fixed" and one.deposit_fixed > 0)
                    or (
                        one.deposit_mode == "percent"
                        and 0 < one.deposit_percent <= 100
                        and one.product_id.list_price > 0
                    )
                )
            )
            if not valid:
                raise ValidationError(
                    self.env._(
                        "A deposit needs a service product, and a positive amount "
                        "or a percentage between 1 and 100."
                    )
                )

    @api.constrains("public_page", "combination_rel_ids")
    def _check_public_page(self):
        for one in self:
            if one.public_page and not one.combination_rel_ids:
                # Without a combination _get_best_combination() is empty and the
                # calendar.event would violate combination_required_if_event.
                raise ValidationError(
                    self.env._(
                        "A type on the public booking page needs at least one "
                        "resource combination, or no slot can ever be booked."
                    )
                )
