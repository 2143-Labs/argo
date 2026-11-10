"""A private video room per booking: mint, invitation, room, portal, iCloud, ICE."""

import base64
import hashlib
import hmac
import os
import time
import uuid
from datetime import timedelta
from unittest.mock import patch
from urllib.parse import urlparse

from odoo.tests import tagged
from odoo.tests.common import HttpCase
from odoo.tools import mute_logger

from .common import create_fixture, first_slot, page, post

JOIN_PATH = "/calendar/join_videocall/"


@tagged("post_install", "-at_install")
class TestVideoCall(HttpCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        create_fixture(cls)
        cls.btype.video_call = True
        # The consultation types take no deposit, and this keeps the mail
        # assertions about the booking sync alone, not the deposit write.
        cls.btype.deposit_mode = "none"

    def _book(self):
        """Book the first free slot through the public form and return the booking."""
        post(self, page(self), when=first_slot(page(self)))
        self.env.invalidate_all()
        booking = self.env["resource.booking"].search(
            [("type_id", "=", self.btype.id)], order="id desc", limit=1
        )
        self.assertTrue(booking, "the public form did not create a booking")
        return booking

    def _invitation_body(self, booking):
        """The sent invitation's body, or a render of its template when none is kept."""
        domain = [
            ("model", "=", "calendar.event"),
            ("res_id", "=", booking.meeting_id.id),
        ]
        for model, body_field in (("mail.mail", "body_html"), ("mail.message", "body")):
            invitations = (
                self.env[model]
                .sudo()
                .search(domain)
                .filtered(lambda mail: "Invitation to" in (mail.subject or ""))
            )
            if invitations:
                return " ".join(body or "" for body in invitations.mapped(body_field))
        attendee = booking.meeting_id.attendee_ids.filtered(
            lambda one: one.partner_id in booking.partner_ids
        )
        return self.env.ref(
            "calendar.calendar_template_meeting_invitation"
        )._render_field("body_html", attendee.ids, compute_lang=True)[attendee.id]

    def _date_updated(self, booking):
        """Subjects of the 'Date updated' mails parked on the booking's meeting."""
        meeting_mail = (
            self.env["mail.message"]
            .sudo()
            .search(
                [
                    ("model", "=", "calendar.event"),
                    ("res_id", "=", booking.meeting_id.id),
                ]
            )
        )
        return meeting_mail.filtered(
            lambda message: (message.subject or "").endswith(": Date updated")
        ).mapped("subject")

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_booking_mints_and_mirrors_the_join_link(self):
        booking = self._book()
        token = booking.meeting_id.access_token
        self.assertRegex(token, r"^[0-9a-f]{32}$")
        expected = "%s%s%s" % (booking.get_base_url(), JOIN_PATH, token)
        self.assertEqual(booking.meeting_id.videocall_location, expected)
        self.assertEqual(booking.videocall_location, expected)

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_invitation_carries_the_link_and_no_date_updated_mail(self):
        booking = self._book()
        self.assertIn(JOIN_PATH, self._invitation_body(booking))
        subjects = self._date_updated(booking)
        self.assertFalse(
            subjects,
            "the booking flow mailed 'Date updated' to the attendees: %s" % subjects,
        )
        # What the CalDAV cron does after writing the iCloud UID.
        booking.write({"caldav_uid": "test-uid"})
        subjects = self._date_updated(booking)
        self.assertFalse(
            subjects,
            "writing caldav_uid mailed 'Date updated' to the attendees: %s" % subjects,
        )

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_a_real_reschedule_still_mails_date_updated(self):
        booking = self._book()
        self.assertFalse(self._date_updated(booking))
        link = booking.meeting_id.videocall_location
        # The fixture calendar is Mon-Fri 08:00-17:00 UTC with 1 h bookings:
        # move away from whichever edge the first slot sits on.
        move = timedelta(hours=-1 if booking.start.hour >= 16 else 1)
        start = booking.start + move
        booking.write({"start": start})
        self.env.invalidate_all()
        self.assertTrue(
            self._date_updated(booking),
            "a real reschedule must mail 'Date updated' to the attendees",
        )
        self.assertEqual(booking.meeting_id.start, start)
        self.assertEqual(booking.meeting_id.videocall_location, link)

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_guest_can_open_the_room(self):
        booking = self._book()
        join_path = urlparse(booking.videocall_location).path
        response = self.url_open(join_path, allow_redirects=False)
        # Request.redirect() defaults to 303 (odoo/http.py, pinned 18.0 base).
        self.assertEqual(response.status_code, 303)
        location = response.headers.get("Location") or ""
        self.env.invalidate_all()
        channel = booking.meeting_id.videocall_channel_id
        self.assertTrue(channel, "the join request did not create a discuss.channel")
        self.assertEqual(channel.channel_type, "group")
        self.assertEqual(channel.default_display_mode, "video_full_screen")
        self.assertEqual(
            channel.invitation_url, "/chat/%d/%s" % (channel.id, channel.uuid)
        )
        self.assertTrue(location.endswith(channel.invitation_url), location)
        self.assertEqual(self.url_open(location).status_code, 200)

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_a_type_without_video_call_gets_no_room(self):
        self.btype.video_call = False
        booking = self._book()
        self.assertFalse(booking.videocall_location)
        response = self.url_open(
            "/calendar/join_videocall/%s" % uuid.uuid4().hex,
            allow_redirects=False,
        )
        self.assertEqual(response.status_code, 404)

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_cancelling_the_booking_deletes_the_room(self):
        booking = self._book()
        join_path = urlparse(booking.videocall_location).path
        # Request.redirect() defaults to 303 (odoo/http.py, pinned 18.0 base).
        self.assertEqual(
            self.url_open(join_path, allow_redirects=False).status_code, 303
        )
        self.env.invalidate_all()
        channel_id = booking.meeting_id.videocall_channel_id.id
        self.assertTrue(channel_id, "the join request did not create a discuss.channel")
        booking.action_cancel()
        self.env.invalidate_all()
        self.assertFalse(self.env["discuss.channel"].browse(channel_id).exists())
        self.assertEqual(
            self.url_open(join_path, allow_redirects=False).status_code, 404
        )

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_portal_shows_the_join_button_only_for_a_video_booking(self):
        booking = self._book()
        response = self.url_open(booking.get_portal_url())
        self.assertEqual(response.status_code, 200)
        self.assertIn("Join the video call", response.text)
        self.assertIn(booking.videocall_location, response.text)
        self.btype.video_call = False
        other = self._book()
        response = self.url_open(other.get_portal_url())
        self.assertEqual(response.status_code, 200)
        self.assertNotIn("Join the video call", response.text)
        self.assertNotIn("Meeting URL:", response.text)

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_icloud_payload_carries_the_join_link(self):
        booking = self._book()
        unfolded = (
            booking._caldav_ical("test-uid").to_ical().decode().replace("\r\n ", "")
        )
        self.assertIn("URL:%s" % booking.videocall_location, unfolded.splitlines())
        self.btype.video_call = False
        other = self._book()
        unfolded = (
            other._caldav_ical("test-uid-2").to_ical().decode().replace("\r\n ", "")
        )
        self.assertFalse(
            [line for line in unfolded.splitlines() if line.startswith("URL:")]
        )

    def test_ice_servers_use_short_lived_turn_credentials(self):
        with patch.dict(os.environ, {"TURN_AUTH_SECRET": "test-secret"}):
            servers = self.env["mail.ice.server"]._get_ice_servers()
        self.assertEqual(len(servers), 3)
        self.assertTrue(servers[0]["urls"].startswith("stun:"))
        self.assertTrue(servers[1]["urls"].endswith("?transport=udp"))
        self.assertTrue(servers[2]["urls"].endswith("?transport=tcp"))
        for server in servers[1:]:
            username = server["username"]
            self.assertRegex(username, r"^\d+:odoo$")
            self.assertAlmostEqual(
                int(username.split(":")[0]), time.time() + 6 * 3600, delta=60
            )
            credential = base64.b64encode(
                hmac.new(b"test-secret", username.encode(), hashlib.sha1).digest()
            ).decode()
            self.assertEqual(server["credential"], credential)
        self.assertFalse(self.env["mail.ice.server"].search([]))
        with patch.dict(os.environ):
            os.environ.pop("TURN_AUTH_SECRET", None)
            self.assertFalse(self.env["mail.ice.server"]._get_ice_servers())
