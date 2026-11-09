import contextlib
import json
import os
from datetime import datetime, timedelta
from unittest.mock import patch

from odoo.tests import tagged
from odoo.tests.common import HttpCase
from odoo.tools import mute_logger

from .common import create_fixture, first_slot, ical, page, post

EMPLOYEE = "employee@example.com"


class FakeEvent:
    def __init__(self, data, url="/fake/event.ics", calendar=None):
        self.raw_data = data.encode("utf-8") if isinstance(data, str) else data
        self.url = url
        self.calendar = calendar
        self.deleted = False

    def delete(self):
        self.deleted = True
        if self.calendar is not None:
            self.calendar.deleted.append(self.url)


class FakeCalendar:
    """Stands in for a caldav Calendar; records what the module asked of it."""

    def __init__(self, name="Work", feed=None):
        self.name = name
        self.feed = list(feed or [])
        self.added = []
        self.deleted = []
        self.known_uids = set()

    def get_display_name(self):
        return self.name

    def search(self, start=None, end=None, event=False):
        return [FakeEvent(data, calendar=self) for data in self.feed]

    def add_event(self, data):
        self.added.append(data)
        self.known_uids.add(_uid_of(data))
        return FakeEvent(data, calendar=self)

    def get_event_by_uid(self, uid):
        if uid not in self.known_uids:
            raise KeyError(uid)
        return FakeEvent("", url="/fake/%s.ics" % uid, calendar=self)


class FakePrincipal:
    def __init__(self, calendars):
        self._calendars = calendars

    def calendars(self):
        return self._calendars


class FakeClient:
    def __init__(self, calendars):
        self._calendars = calendars

    def principal(self):
        return FakePrincipal(self._calendars)


def _uid_of(data):
    start = data.index("UID:")
    end = data.index("\r\n", start)
    return data[start + 4 : end].strip()


@tagged("post_install", "-at_install")
class TestCaldavSync(HttpCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        create_fixture(cls)

    def setUp(self):
        super().setUp()
        self.calendar_fake = FakeCalendar()
        self.client = FakeClient([self.calendar_fake])

    def _sync(self, employees=None):
        """Run the cron with these credentials and this fake iCloud."""
        entries = (
            employees
            if employees is not None
            else [
                {
                    "email": EMPLOYEE,
                    "username": EMPLOYEE,
                    "app_password": "abcd-efgh-ijkl-mnop",
                    "calendar": "Work",
                }
            ]
        )
        env = {"CALDAV_CREDENTIALS": json.dumps({"employees": entries})}
        booking = type(self.env["resource.booking"])
        with patch.dict(os.environ, env), patch.object(
            booking, "_caldav_client", lambda self_, entry: self.client
        ):
            self.env["resource.booking"]._cron_sync_caldav()

    def test_no_credentials_does_nothing(self):
        with patch.dict(os.environ, {"CALDAV_CREDENTIALS": ""}):
            self.env["resource.booking"]._cron_sync_caldav()
        self.assertEqual(self.calendar_fake.added, [])

    def test_icloud_busy_time_removes_the_slot(self):
        when = first_slot(page(self))
        start = datetime.strptime(when, "%Y-%m-%dT%H:%M:%SZ")
        self.calendar_fake.feed = [
            ical("icloud-1", start, start + timedelta(hours=1), summary="Dentist")
        ]
        self._sync()
        event = self.env["calendar.event"].search([("caldav_uid", "=", "icloud-1")])
        self.assertEqual(len(event), 1)
        self.assertEqual(event.caldav_source, "icloud")
        self.assertEqual(event.show_as, "busy")
        self.assertEqual(event.user_id, self.user)
        self.assertEqual(event.partner_ids, self.user.partner_id)
        # Nobody is mailed about their own calendar being mirrored in.
        self.assertFalse(
            self.env["mail.mail"].search([("model", "=", "calendar.event")])
        )
        self.assertNotIn('value="%s"' % when, page(self))

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_booking_is_pushed_once_and_not_pulled_back(self):
        post(self, page(self), when=first_slot(page(self)))
        booking = self.env["resource.booking"].search(
            [("type_id", "=", self.btype.id)], limit=1
        )
        self._sync()
        self.assertEqual(len(self.calendar_fake.added), 1)
        self.assertIn(booking.caldav_uid, self.calendar_fake.added[0])
        self.assertIn(booking.type_id.name, self.calendar_fake.added[0])
        # A second run must not push it again, and the copy in iCloud must not
        # come back as a second, iCloud-sourced event.
        self.calendar_fake.feed = list(self.calendar_fake.added)
        self._sync()
        self.assertEqual(len(self.calendar_fake.added), 1)
        self.assertFalse(
            self.env["calendar.event"].search([("caldav_source", "=", "icloud")])
        )

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_cancelling_a_booking_deletes_the_icloud_event(self):
        post(self, page(self), when=first_slot(page(self)))
        booking = self.env["resource.booking"].search(
            [("type_id", "=", self.btype.id)], limit=1
        )
        self._sync()
        uid = booking.caldav_uid
        self.assertTrue(uid)
        booking.action_cancel()
        self._sync()
        self.assertEqual(self.calendar_fake.deleted, ["/fake/%s.ics" % uid])
        self.assertFalse(booking.caldav_uid)

    def test_one_broken_entry_does_not_stop_the_others(self):
        start = datetime.strptime(first_slot(page(self)), "%Y-%m-%dT%H:%M:%SZ")
        self.calendar_fake.feed = [
            ical("icloud-2", start, start + timedelta(hours=1))
        ]
        self._sync(
            [
                {
                    "email": "nobody@example.com",
                    "username": "nobody@example.com",
                    "app_password": "x",
                    "calendar": "Work",
                },
                {
                    "email": EMPLOYEE,
                    "username": EMPLOYEE,
                    "app_password": "abcd-efgh-ijkl-mnop",
                    "calendar": "Work",
                },
            ]
        )
        self.assertTrue(
            self.env["calendar.event"].search([("caldav_uid", "=", "icloud-2")])
        )
