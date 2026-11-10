"""One page submission, one booking."""

import re

from odoo.tests import tagged
from odoo.tests.common import HttpCase
from odoo.tools import mute_logger

from .common import create_fixture, first_slot, page, post

KEY = re.compile(r'name="booking_key" value="([^"]+)"')
CSRF = re.compile(r'name="csrf_token" value="([^"]+)"')


@tagged("post_install", "-at_install")
class TestBookingGuard(HttpCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        create_fixture(cls)

    def _submit(self, html, key, when, email="ada@example.com", follow=False):
        data = {
            "csrf_token": CSRF.search(html).group(1),
            "booking_key": key,
            "name": "Ada Lovelace",
            "email": email,
            "when": when,
        }
        return self.url_open(
            "/book/%d/confirm" % self.btype.id, data=data, allow_redirects=follow
        )

    def _key(self, html):
        match = KEY.search(html)
        self.assertTrue(match, "the form carries no booking key")
        return match.group(1)

    def _bookings(self, key=None):
        domain = [("type_id", "=", self.btype.id)]
        if key:
            domain.append(("booking_key", "=", key))
        return self.env["resource.booking"].search(domain)

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_resubmitting_the_same_form_books_once(self):
        html = page(self)
        key = self._key(html)
        when = first_slot(html)
        first = self._submit(html, key, when)
        second = self._submit(html, key, when)
        self.assertEqual(first.status_code, 303)
        self.assertEqual(second.status_code, 303)
        # Both answers point at the one booking, so the visitor who clicked
        # twice lands on their booking instead of a second one or an error.
        self.assertEqual(first.headers["Location"], second.headers["Location"])
        bookings = self._bookings(key)
        self.assertEqual(len(bookings), 1)
        self.assertEqual(bookings.state, "confirmed")

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_second_click_on_another_slot_books_once(self):
        html = page(self)
        key = self._key(html)
        slots = re.findall(r'name="when" value="([^"]+)"', html)
        self.assertGreaterEqual(len(slots), 2, "the fixture offers one slot only")
        first = self._submit(html, key, slots[0])
        second = self._submit(html, key, slots[1])
        self.assertEqual(first.status_code, 303)
        self.assertEqual(second.status_code, 303)
        self.assertEqual(first.headers["Location"], second.headers["Location"])
        bookings = self._bookings(key)
        self.assertEqual(len(bookings), 1)
        self.assertEqual(bookings.state, "confirmed")

    def test_a_repeat_visitor_keeps_one_contact(self):
        # Two separate forms (so two keys, two bookings) from one address, the
        # second spelled with stray case and a space: one booking each, but a
        # single contact.
        first = page(self)
        self.assertEqual(
            self._submit(first, self._key(first), first_slot(first)).status_code, 303
        )
        again = page(self)
        answer = self._submit(
            again,
            self._key(again),
            first_slot(again),
            email="  Ada@Example.COM ",
        )
        self.assertEqual(answer.status_code, 303)
        partners = self.env["res.partner"].search(
            [("email", "=ilike", "ada@example.com")]
        )
        self.assertEqual(len(partners), 1)
        self.assertEqual(len(self._bookings()), 2)

    def test_page_carries_the_key_and_the_submit_guard(self):
        html = page(self)
        self._key(html)
        self.assertIn("booking_form", html)
        self.assertIn("dataset.sending", html)

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_a_form_without_a_key_still_books(self):
        # Pages bookmarked before this change, and any client that posts the
        # form itself, keep working.
        response = post(self, page(self), when=first_slot(page(self)))
        self.assertEqual(response.status_code, 200)
        self.assertIn("/my/bookings/", response.url)
        self.assertEqual(len(self._bookings()), 1)
        self.assertFalse(self._bookings().booking_key)

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_a_failed_submission_does_not_block_the_retry(self):
        html = page(self)
        key = self._key(html)
        failed = self._submit(html, key, "1999-01-01T00:00:00Z")
        self.assertEqual(failed.status_code, 200)
        self.assertFalse(self._bookings(key))
        # Same key: a visitor whose first attempt was refused can try again.
        retried = self._submit(html, key, first_slot(html))
        self.assertEqual(retried.status_code, 303)
        self.assertEqual(len(self._bookings(key)), 1)

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_a_cancelled_booking_is_not_replayed(self):
        html = page(self)
        key = self._key(html)
        self._submit(html, key, first_slot(html))
        booking = self._bookings(key)
        booking.action_cancel()
        # The visitor comes back to the same page and books again: that is a new
        # booking, not a replay of the cancelled one.
        retried = self._submit(page(self), key, first_slot(page(self)))
        self.assertEqual(retried.status_code, 303)
        # OCA archives a cancelled booking, so the key is free again and the
        # retry books; the archived row still carries the key.
        archived = (
            self.env["resource.booking"]
            .with_context(active_test=False)
            .search([("booking_key", "=", key)])
        )
        self.assertEqual(len(archived), 2)
        self.assertEqual(len(self._bookings(key)), 1)
        self.assertEqual(self._bookings(key).state, "confirmed")
