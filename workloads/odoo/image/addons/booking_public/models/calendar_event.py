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

    def unlink(self):
        # A booking's call room dies with its event (cancel, unschedule, delete):
        # otherwise anyone who already joined keeps posting and can ring the
        # employee. Events without a booking keep core's behaviour, which also
        # spares rooms shared across a recurrence.
        channels = (
            self.sudo()
            .with_context(active_test=False)
            .filtered("resource_booking_ids")
            .videocall_channel_id
        )
        result = super().unlink()
        if channels:
            channels.sudo().unlink()
        return result
