from odoo.exceptions import ValidationError
from odoo.tests import tagged
from odoo.tests.common import HttpCase
from odoo.tools import mute_logger

from .common import create_fixture, first_slot, page, post

BAD_VISITOR = "Please give your name and a valid email address."
LOST_SLOT = "That time is no longer available. Please pick another."


@tagged("post_install", "-at_install")
class TestBookingPublic(HttpCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        create_fixture(cls)

    def test_index_and_type_page_render(self):
        response = self.url_open("/book")
        self.assertEqual(response.status_code, 200)
        self.assertIn("Photo session", response.text)
        html = page(self)
        self.assertIn('name="when"', html)
        self.assertIn("csrf_token", html)

    def test_unknown_and_unpublished_type_is_404(self):
        self.assertEqual(self.url_open("/book/9999999").status_code, 404)
        self.btype.public_page = False
        self.assertEqual(self.url_open("/book/%d" % self.btype.id).status_code, 404)
        self.btype.public_page = True
        self.assertEqual(self.url_open("/book").status_code, 200)

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_booking_confirms_and_invoices_the_deposit(self):
        html = page(self)
        when = first_slot(html)
        response = post(self, html, when=when, phone="555 0100")
        self.assertEqual(response.status_code, 200)
        # No provider is enabled in a fresh database, so the visitor lands on the
        # tokenised booking page rather than an invoice with nothing to pay with.
        self.assertIn("/my/bookings/", response.url)
        booking = self.env["resource.booking"].search(
            [("type_id", "=", self.btype.id)], limit=1
        )
        self.assertEqual(len(booking), 1)
        self.assertEqual(booking.state, "confirmed")
        self.assertTrue(booking.meeting_id)
        self.assertEqual(booking.meeting_id.user_id, self.user)
        self.assertEqual(booking.partner_ids.email, "ada@example.com")
        self.assertEqual(booking.user_id, self.user)
        self.assertEqual(booking.sale_order_id.state, "sale")
        self.assertEqual(booking.deposit_invoice_id.state, "posted")
        self.assertAlmostEqual(
            booking.deposit_invoice_id.amount_total, self.btype.deposit_amount, 2
        )
        # The slot the customer took is gone from the page.
        self.assertNotIn('value="%s"' % when, page(self))

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_confirmed_booking_redirects_to_the_invoice_with_a_provider(self):
        self.env["payment.provider"].create(
            {"name": "Demo", "code": "none", "state": "enabled"}
        )
        response = post(self, page(self), when=first_slot(page(self)))
        self.assertEqual(response.status_code, 200)
        self.assertIn("/my/invoices/", response.url)

    @mute_logger("odoo.addons.mail.models.mail_mail", "odoo.models.unlink")
    def test_the_same_slot_cannot_be_booked_twice(self):
        html = page(self)
        when = first_slot(html)
        post(self, html, when=when)
        response = post(self, page(self), when=when, email="grace@example.com")
        self.assertEqual(response.status_code, 200)
        self.assertIn(LOST_SLOT, response.text)
        self.assertEqual(
            self.env["resource.booking"].search_count([("type_id", "=", self.btype.id)]), 1
        )

    def test_invalid_email_creates_nothing(self):
        response = post(self, page(self), when=first_slot(page(self)), email="nope")
        self.assertEqual(response.status_code, 200)
        self.assertIn(BAD_VISITOR, response.text)
        self.assertFalse(
            self.env["resource.booking"].search([("type_id", "=", self.btype.id)])
        )

    def test_blank_name_creates_nothing(self):
        response = post(self, page(self), when=first_slot(page(self)), name="   ")
        self.assertEqual(response.status_code, 200)
        self.assertIn(BAD_VISITOR, response.text)
        self.assertFalse(
            self.env["resource.booking"].search([("type_id", "=", self.btype.id)])
        )

    def test_empty_horizon_renders_a_notice(self):
        self.btype.public_horizon_days = 0
        response = self.url_open("/book/%d" % self.btype.id)
        self.assertEqual(response.status_code, 200)
        self.assertIn("No times are free", response.text)

    def test_publishing_needs_a_combination(self):
        other = self.btype.copy({"public_page": False, "name": "Copy"})
        other.combination_rel_ids.unlink()
        with self.assertRaises(ValidationError), self.env.cr.savepoint():
            other.public_page = True

    def test_deposit_needs_a_product_and_an_amount(self):
        with self.assertRaises(ValidationError), self.env.cr.savepoint():
            self.btype.product_id = False
        with self.assertRaises(ValidationError), self.env.cr.savepoint():
            self.btype.write({"deposit_mode": "percent", "deposit_percent": 0})
        with self.assertRaises(ValidationError), self.env.cr.savepoint():
            self.product.list_price = 0
            self.btype.write({"deposit_mode": "percent", "deposit_percent": 20})
