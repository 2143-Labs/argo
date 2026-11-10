from odoo import models

# Context flag set by the public booking controller. Core sends every attendee's
# invitation with force_send=True, so the visitor's request waits for one SMTP
# round trip per attendee (about two seconds each against the relay).
DEFER_STAFF_MAIL = "booking_public_defer_staff_mail"


class CalendarAttendee(models.Model):
    _inherit = "calendar.attendee"

    def _send_mail_to_attendees(self, mail_template, force_send=False):
        """Mails the visitor now, queues the staff ones.

        Only the visitor is waiting on this HTTP request; staff mail rides the
        mail queue (cron `Mail: Email Queue Manager`, one minute).
        """
        if not self.env.context.get(DEFER_STAFF_MAIL):
            return super()._send_mail_to_attendees(mail_template, force_send=force_send)
        model = self.env["calendar.attendee"].with_context(
            **{DEFER_STAFF_MAIL: False, "mail_notify_force_send": True}
        )
        # Internal users are staff; a portal account is still a visitor.
        staff = self.filtered(
            lambda attendee: attendee.partner_id.user_ids.filtered(
                lambda user: not user.share
            )
        )
        visitors = self - staff
        result = model.browse(visitors.ids)._send_mail_to_attendees(
            mail_template, force_send=True
        )
        model.with_context(mail_notify_force_send=False).browse(
            staff.ids
        )._send_mail_to_attendees(mail_template, force_send=False)
        return result
