from odoo import fields, models


class CalendarEvent(models.Model):
    _inherit = "calendar.event"

    caldav_uid = fields.Char(
        "iCloud UID",
        copy=False,
        index=True,
        help="UID of the mirrored event in iCloud; empty for events Odoo owns.",
    )
    caldav_source = fields.Selection(
        [("odoo", "Odoo"), ("icloud", "iCloud")],
        default="odoo",
        required=True,
        index=True,
        help="Where this event came from. Odoo owns the ones it created.",
    )
