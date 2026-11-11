import logging
import uuid
from datetime import timedelta

import pytz
from psycopg2 import errors

from odoo import fields, http
from odoo.exceptions import ValidationError
from odoo.http import request
from odoo.tools import email_normalize

_logger = logging.getLogger(__name__)

BOOKING_ROOT = "/book"
NO_SLOT_TEXT = "No times are free in the next %(days)s days. Please get in touch."
LOST_SLOT_TEXT = "That time is no longer available. Please pick another."
BAD_VISITOR_TEXT = "Please give your name and a valid email address."
# Mail sent while the visitor waits must be the visitor's own invitation only;
# the rest (staff invitation, portal notifications, our comment) rides the queue.
DEFER_MAIL = {
    "mail_notify_force_send": False,
    "booking_public_defer_staff_mail": True,
}


def _display_tz(booking_type):
    """Timezone the slot labels are shown in."""
    return pytz.timezone(booking_type.resource_calendar_id.tz or "UTC")


def _provider_is_live():
    """True when the invoice portal will offer something to pay with."""
    return bool(
        request.env["payment.provider"]
        .sudo()
        .search_count([("state", "in", ("enabled", "test"))])
    )


def _slot_rows(booking_type):
    """Every bookable start, as the wire value and the local label.

    resource_booking returns timezone-aware datetimes (resource.calendar's
    _work_intervals_batch localises them), so the label is a conversion and the
    wire value is the same instant in UTC. Submitting UTC keeps the round trip
    free of any browser-timezone assumption.
    """
    tz = _display_tz(booking_type)
    booking = request.env["resource.booking"].sudo().with_context(tz=tz.zone)
    probe = booking.new({"type_id": booking_type.id, "duration": booking_type.duration})
    now = fields.Datetime.context_timestamp(probe, fields.Datetime.now())
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    horizon = start + timedelta(days=booking_type.public_horizon_days)
    slots = probe._get_available_slots(start, horizon)
    rows = []
    for day in sorted(slots):
        for slot in sorted(slots[day]):
            local = slot.astimezone(tz)
            utc = slot.astimezone(pytz.utc)
            rows.append(
                {
                    "value": utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "utc": utc.replace(tzinfo=None),
                    "label": local.strftime("%H:%M"),
                    "day": local.date(),
                }
            )
    rows.sort(key=lambda row: row["utc"])
    return rows


def _group_days(rows):
    """Slot rows grouped per local date, in display order."""
    days = []
    for row in rows:
        if not days or days[-1]["date"] != row["day"]:
            days.append(
                {
                    "date": row["day"],
                    "label": row["day"].strftime("%a %d %b"),
                    "slots": [],
                }
            )
        days[-1]["slots"].append(row)
    return days


class BookingPublic(http.Controller):
    def _get_public_type(self, type_id):
        return (
            request.env["resource.booking.type"]
            .sudo()
            .search([("id", "=", type_id), ("public_page", "=", True)], limit=1)
        )

    def _render_type(self, booking_type, error=None, values=None):
        rows = _slot_rows(booking_type)
        return request.render(
            "booking_public.type_page",
            {
                "btype": booking_type,
                "days": _group_days(rows),
                "no_slot_text": NO_SLOT_TEXT
                % {"days": booking_type.public_horizon_days},
                "error": error,
                "values": values or {},
                # One key per rendered page: a resubmission of this form (double
                # click, reload, retry after a dropped connection) is answered
                # with the booking it already made instead of making another.
                "booking_key": uuid.uuid4().hex,
            },
        )

    @http.route([BOOKING_ROOT], type="http", auth="public", website=True, sitemap=True)
    def booking_index(self, **kw):
        types = (
            request.env["resource.booking.type"]
            .sudo()
            .search([("public_page", "=", True)], order="name")
        )
        return request.render("booking_public.index", {"types": types})

    @http.route(
        [BOOKING_ROOT + "/<int:type_id>"],
        type="http",
        auth="public",
        website=True,
    )
    def booking_type(self, type_id, **kw):
        booking_type = self._get_public_type(type_id)
        if not booking_type:
            raise request.not_found()
        return self._render_type(booking_type)

    @http.route(
        [BOOKING_ROOT + "/<int:type_id>/confirm"],
        type="http",
        auth="public",
        website=True,
        methods=["POST"],
    )
    def booking_confirm(
        self, type_id, name=None, email=None, phone=None, when=None, booking_key=None, **kw
    ):
        booking_type = self._get_public_type(type_id)
        if not booking_type:
            raise request.not_found()
        # Before anything else: this page may already have booked. The visitor
        # then gets their booking back instead of a second one, and instead of
        # "that time is no longer available" (it is taken, by them).
        existing = self._already_booked(booking_key)
        if existing:
            return request.redirect(existing.get_portal_url())
        values = {"name": name or "", "email": email or "", "phone": phone or ""}
        name = (name or "").strip()
        phone = (phone or "").strip() or False
        normalized = email_normalize(email or "")
        if not name or not normalized:
            return self._render_type(booking_type, error=BAD_VISITOR_TEXT, values=values)
        # Never trust the posted time: it must be one this page offers right now.
        chosen = next((row for row in _slot_rows(booking_type) if row["value"] == when), None)
        if chosen is None:
            return self._render_type(booking_type, error=LOST_SLOT_TEXT, values=values)
        partner = self._visitor_partner(name, normalized, phone)
        tz = _display_tz(booking_type)
        booking, created = self._book(booking_type, chosen, partner, tz, booking_key)
        if booking is None:
            return self._render_type(booking_type, error=LOST_SLOT_TEXT, values=values)
        if not created:
            return request.redirect(booking.get_portal_url())
        invoice = self._deposit(booking, booking_type, partner)
        if invoice and _provider_is_live():
            return request.redirect(invoice.get_portal_url())
        return request.redirect(booking.get_portal_url())

    def _already_booked(self, booking_key):
        """The booking this form already made, if any."""
        if not booking_key:
            return request.env["resource.booking"]
        return (
            request.env["resource.booking"]
            .sudo()
            .search(
                [("booking_key", "=", booking_key), ("state", "!=", "canceled")],
                limit=1,
            )
        )

    def _visitor_partner(self, name, email, phone):
        """The visitor's partner, created once even for simultaneous submits."""
        cr = request.env.cr
        Partner = request.env["res.partner"].sudo()
        Contact = request.env["booking.contact"].sudo()
        uid = request.env.uid
        # Claim the address first. The insert is atomic, so two requests that
        # arrive together agree on one row instead of both searching, both
        # finding nothing and both creating a contact.
        cr.execute(
            "INSERT INTO booking_contact "
            "(email, create_uid, create_date, write_uid, write_date) "
            "VALUES (%s, %s, now(), %s, now()) ON CONFLICT (email) DO NOTHING",
            (email, uid, uid),
        )
        partner = Partner.search([("email", "=ilike", email)], limit=1)
        if partner:
            Contact.search([("email", "=", email)]).partner_id = partner.id
            return partner
        partner = Partner.create({"name": name, "email": email, "phone": phone})
        # Whoever fills the empty slot owns the address; the other drops the
        # contact it just created and uses the winner's.
        cr.execute(
            "UPDATE booking_contact "
            "SET partner_id = %s, write_uid = %s, write_date = now() "
            "WHERE email = %s AND partner_id IS NULL RETURNING id",
            (partner.id, uid, email),
        )
        if cr.fetchone():
            return partner
        cr.execute("SELECT partner_id FROM booking_contact WHERE email = %s", (email,))
        row = cr.fetchone()
        winner = row and row[0]
        if winner and winner != partner.id:
            try:
                with cr.savepoint():
                    partner.unlink()
            except Exception:
                _logger.warning(
                    "kept duplicate contact %s for %s", partner.id, email, exc_info=True
                )
            return Partner.browse(winner)
        return partner

    def _book(self, booking_type, chosen, partner, tz, booking_key=None):
        """Create the booking. Returns ``(booking, created)``, or ``(None, False)``."""
        Booking = request.env["resource.booking"].sudo()
        context = {"tz": tz.zone}
        probe = Booking.with_context(**context).new(
            {
                "type_id": booking_type.id,
                "duration": booking_type.duration,
                "start": chosen["utc"],
                "partner_ids": [(6, 0, [partner.id])],
            }
        )
        try:
            combination = probe._get_best_combination()
        except ValidationError:
            return None, False
        if not combination:
            return None, False
        employee = combination.resource_ids.filtered(
            lambda res: res.resource_type == "user" and res.user_id
        )[:1].user_id
        try:
            with request.env.cr.savepoint():
                if booking_key:
                    existing = self._already_booked(booking_key)
                    if existing:
                        return existing, False
                booking = Booking.with_context(**context, **DEFER_MAIL).create(
                    {
                        "type_id": booking_type.id,
                        "partner_ids": [(6, 0, [partner.id])],
                        "combination_id": combination.id,
                        # The organizer is the person being booked, not the
                        # anonymous visitor the sudo environment would default to.
                        "user_id": employee.id or False,
                        "start": chosen["utc"],
                        "duration": booking_type.duration,
                        "booking_key": booking_key or False,
                    }
                )
                booking.action_confirm()
                booking.with_context(**DEFER_MAIL).message_post(
                    body=request.env._(
                        "Booked online for %(when)s. Manage it here: %(url)s",
                        when=chosen["label"],
                        url=booking.get_base_url() + booking.get_portal_url(),
                    ),
                    partner_ids=[partner.id],
                    subtype_xmlid="mail.mt_comment",
                )
        except errors.UniqueViolation:
            # Two submissions of one page arrived together and both got past the
            # check above; the unique index let exactly one through. Answer with
            # the booking that won, which is committed by now.
            existing = self._already_booked(booking_key)
            if existing:
                return existing, False
            return None, False
        except ValidationError:
            # Lost the race against another booking, or the slot no longer fits
            # the calendar: tell the visitor instead of showing a 500.
            return None, False
        return booking, True

    def _deposit(self, booking, booking_type, partner):
        """Invoice the deposit. Never loses the booking over it."""
        if booking_type.deposit_mode == "none" or not booking_type.product_id:
            return False
        env = request.env
        try:
            with env.cr.savepoint():
                order = (
                    env["sale.order"]
                    .sudo()
                    .create(
                        {
                            "partner_id": partner.id,
                            "order_line": [
                                (
                                    0,
                                    0,
                                    {
                                        "product_id": booking_type.product_id.id,
                                        "product_uom_qty": 1,
                                    },
                                )
                            ],
                        }
                    )
                )
                order.action_confirm()
                wizard = (
                    env["sale.advance.payment.inv"]
                    .sudo()
                    .create(
                        {
                            "advance_payment_method": "fixed"
                            if booking_type.deposit_mode == "fixed"
                            else "percentage",
                            "fixed_amount": booking_type.deposit_amount,
                            "amount": booking_type.deposit_percent,
                            "sale_order_ids": [(6, 0, order.ids)],
                        }
                    )
                )
                invoice = wizard._create_invoices(order)
                invoice.action_post()
                booking.write({"sale_order_id": order.id, "deposit_invoice_id": invoice.id})
        except Exception:
            _logger.exception("booking_public: deposit failed for booking %s", booking.id)
            return False
        return invoice
