from odoo import fields, models


class ResourceResource(models.Model):
    _inherit = "resource.resource"

    caldav_enabled = fields.Boolean(
        "Sync iCloud calendar",
        help="Mirror this person's iCloud busy time into Odoo, and their "
        "bookings back into iCloud. The matching CALDAV_CREDENTIALS entry "
        "is required as well.",
    )
