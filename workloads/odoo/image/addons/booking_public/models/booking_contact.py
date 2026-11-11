from odoo import fields, models


class BookingContact(models.Model):
    """One contact per visitor address, enforced by the database.

    ``res.partner.email`` cannot be unique — a couple can share one, a family
    books with a parent's address — so the public form keeps its own table of
    the addresses it has seen. The unique index is what makes "find or create"
    safe: two requests arriving with one address in the same millisecond agree
    on a row instead of searching, both finding nothing, and both creating.
    """

    _name = "booking.contact"
    _description = "One contact per booking address"

    email = fields.Char("Email", required=True, index=True)
    partner_id = fields.Many2one(
        "res.partner",
        "Contact",
        ondelete="cascade",
        help="Empty while the request that owns this address is still creating it.",
    )

    _sql_constraints = [
        ("email_uniq", "unique(email)", "This address already has a contact."),
    ]
