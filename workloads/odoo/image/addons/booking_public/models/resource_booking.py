import uuid

from odoo import api, fields, models

# calendar.event's own join route. A literal rather than an import of core's
# DISCUSS_ROUTE, whose placement differs by module; tests pin the URL form.
JOIN_ROUTE = "calendar/join_videocall"


class ResourceBooking(models.Model):
    _inherit = "resource.booking"

    sale_order_id = fields.Many2one("sale.order", "Sales order", copy=False, index=True)
    deposit_invoice_id = fields.Many2one(
        "account.move", "Deposit invoice", copy=False, index=True
    )
    caldav_uid = fields.Char(
        "iCloud UID",
        copy=False,
        index=True,
        help="UID of the iCloud event this booking was written to, while it exists.",
    )
    booking_key = fields.Char(
        "Public form key",
        copy=False,
        index=True,
        help="Key of the public page that produced this booking. A second "
        "submission of the same page is answered with this booking instead of "
        "booking the visitor twice.",
    )

    def _prepare_meeting_vals(self):
        vals = super()._prepare_meeting_vals()
        meeting = self.meeting_id
        # calendar.event.write() mails "<name>: Date updated" whenever 'start' is in
        # its values, moved or not, and OCA's _sync_meeting() rewrites the event on
        # every booking write (portal token, deposit, CalDAV uid); its from_ui flag
        # is read nowhere in 18.0. Send the times only when they moved, all three
        # together so an end-only change still notifies.
        if meeting and (meeting.start, meeting.stop, meeting.duration) == (
            self.start,
            self.stop,
            self.duration,
        ):
            for key in ("start", "stop", "duration"):
                vals.pop(key, None)
        # Mint into the create values: calendar.event.create sends the invitation
        # (and its .ics) during create, so a later write would miss the email. An
        # existing meeting keeps its token, so syncs never rotate a sent link.
        if self.type_id.video_call and not meeting:
            token = uuid.uuid4().hex
            vals.update(
                access_token=token,
                videocall_location="%s/%s/%s"
                % (self.get_base_url(), JOIN_ROUTE, token),
            )
        return vals

    @api.depends("meeting_id.videocall_location", "type_id")
    def _compute_videocall_location(self):
        # OCA's compute takes the type's static URL whenever the booking's own
        # value is empty and never reaches the meeting's, so mirror it here.
        super()._compute_videocall_location()
        for booking in self:
            if booking.type_id.video_call and booking.meeting_id.videocall_location:
                booking.videocall_location = booking.meeting_id.videocall_location
