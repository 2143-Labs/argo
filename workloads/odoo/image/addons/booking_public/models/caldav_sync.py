import json
import logging
import os
import uuid
from datetime import datetime, time, timedelta

import icalendar
import pytz
import recurring_ical_events
from caldav import DAVClient

from odoo import api, fields, models

_logger = logging.getLogger(__name__)

# How far ahead busy time is mirrored in. Widening it costs a bigger REPORT and
# more updated rows per run; it is a constant, not a setting.
HORIZON_DAYS = 90
ICAL_URL = "https://caldav.icloud.com/"


def _utc_naive(value, default_end=False):
    """Odoo datetime from an iCalendar date or datetime, in UTC."""
    if value is None:
        return None
    if isinstance(value, datetime):
        if value.tzinfo:
            return value.astimezone(pytz.utc).replace(tzinfo=None)
        return value
    # An all-day value: the whole day. DTEND is exclusive, so an end date at
    # midnight is already the right stop.
    moment = datetime.combine(value, time.min)
    if default_end:
        moment += timedelta(days=1)
    return moment


def _value(occurrence, name):
    """One VEVENT property's Python value, or None.

    Component.decoded() raises KeyError for an absent property, and a pulled
    event legitimately lacks STATUS, DTEND, RECURRENCE-ID and friends.
    """
    prop = occurrence.get(name)
    if prop is None:
        return None
    return getattr(prop, "dt", prop)


def _bounds(occurrence):
    """Start and stop (naive UTC) of one VEVENT occurrence."""
    start = _utc_naive(_value(occurrence, "DTSTART"))
    if start is None:
        return None, None
    stop = _utc_naive(_value(occurrence, "DTEND"), default_end=True)
    if stop is None:
        duration = _value(occurrence, "DURATION")
        stop = start + duration if duration else start + timedelta(hours=1)
    if stop <= start:
        stop = start + timedelta(hours=1)
    return start, stop


class ResourceBooking(models.Model):
    _inherit = "resource.booking"

    @api.model
    def _cron_sync_caldav(self):
        """Mirror iCloud busy time in and bookings out, one employee at a time."""
        raw = (os.environ.get("CALDAV_CREDENTIALS") or "").strip()
        if not raw:
            _logger.info("booking_public: no CALDAV_CREDENTIALS, nothing to sync")
            return
        try:
            entries = json.loads(raw).get("employees") or []
        except (ValueError, AttributeError):
            _logger.warning("booking_public: CALDAV_CREDENTIALS is not valid JSON")
            return
        if not entries:
            _logger.info("booking_public: CALDAV_CREDENTIALS lists no employees")
            return
        for entry in entries:
            email = (entry.get("email") or "?").strip()
            # One person's broken calendar must not stop the others, and must
            # not leave half-written rows behind.
            try:
                with self.env.cr.savepoint():
                    self._caldav_sync_employee(entry)
            except Exception:
                _logger.exception("booking_public: caldav sync failed for %s", email)

    @api.model
    def _caldav_sync_employee(self, entry):
        email = (entry.get("email") or "").strip()
        resource = (
            self.env["resource.resource"]
            .sudo()
            .search(
                [
                    ("user_id.partner_id.email", "=ilike", email),
                    ("resource_type", "=", "user"),
                    ("caldav_enabled", "=", True),
                ],
                limit=1,
            )
        )
        if not resource:
            _logger.info("booking_public: no bridged resource for %s", email)
            return
        calendar = self._caldav_calendar(entry)
        if calendar is None:
            _logger.info(
                "booking_public: no iCloud calendar %r for %s",
                entry.get("calendar"),
                email,
            )
            return
        self._caldav_pull(resource, calendar)
        self._caldav_push(resource, calendar)
        self._caldav_cancel(resource, calendar)

    @api.model
    def _caldav_client(self, entry):
        """Seam for tests: the only place that talks to iCloud's HTTP API."""
        return DAVClient(
            url=entry.get("url") or ICAL_URL,
            username=entry["username"],
            password=entry["app_password"],
        )

    @api.model
    def _caldav_calendar(self, entry):
        wanted = (entry.get("calendar") or "").strip()
        for calendar in self._caldav_client(entry).principal().calendars():
            if (calendar.get_display_name() or "").strip() == wanted:
                return calendar
        return None

    @api.model
    def _caldav_ours(self):
        """UIDs of the iCloud events this module wrote, so pull leaves them."""
        return set(
            self.env["resource.booking"]
            .sudo()
            .with_context(active_test=False)
            .search([("caldav_uid", "!=", False)])
            .mapped("caldav_uid")
        )

    @api.model
    def _caldav_pull(self, resource, calendar):
        """Copy iCloud busy time into calendar.event, as the person's own."""
        now = fields.Datetime.now()
        start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        stop = start + timedelta(days=HORIZON_DAYS)
        ours = self._caldav_ours()
        Event = self.env["calendar.event"].sudo()
        seen = set()
        for remote in calendar.search(start=start, end=stop, event=True):
            raw = remote.raw_data or getattr(remote, "data", None)
            if not raw:
                continue
            try:
                ical = icalendar.Calendar.from_ical(raw)
                # recurring_ical_events stamps RECURRENCE-ID on every occurrence,
                # single events included, so recurrence-ness has to come from the
                # stored object: only a real RRULE needs per-instance rows.
                recurring = any(
                    component.get("RRULE") for component in ical.walk("VEVENT")
                )
                occurrences = recurring_ical_events.of(ical).between(start, stop)
            except Exception:
                _logger.warning(
                    "booking_public: skipped an iCloud event that cannot be read or expanded"
                )
                continue
            for occurrence in occurrences:
                uid = str(_value(occurrence, "UID") or "")
                if not uid or uid in ours:
                    continue
                if str(_value(occurrence, "STATUS") or "").upper() == "CANCELLED":
                    continue
                start_dt, stop_dt = _bounds(occurrence)
                if not start_dt or not stop_dt:
                    continue
                # A recurrence instance gets its own row, keyed on its start;
                # a plain event keeps its UID so a move updates it in place.
                key = uid
                if recurring:
                    key = "%s@%s" % (uid, start_dt.strftime("%Y%m%dT%H%M%S"))
                seen.add(key)
                vals = {
                    "name": str(_value(occurrence, "SUMMARY") or "Busy"),
                    "start": start_dt,
                    "stop": stop_dt,
                    "user_id": resource.user_id.id,
                    # resource_booking filters candidate events by partner_ids
                    # before it checks the organizer, so the person must be on
                    # the event even though they already own it.
                    "partner_ids": [(6, 0, [resource.user_id.partner_id.id])],
                    "show_as": "busy",
                    "caldav_source": "icloud",
                    "caldav_uid": key,
                }
                existing = Event.search([("caldav_uid", "=", key)], limit=1)
                if existing:
                    existing.with_context(dont_notify=True).write(vals)
                else:
                    # calendar.event.create() mails attendees unconditionally;
                    # creating bare and attaching the attendee afterwards with
                    # dont_notify keeps a pulled event silent.
                    event = Event.create(
                        {k: v for k, v in vals.items() if k != "partner_ids"}
                    )
                    event.with_context(dont_notify=True).write(
                        {"partner_ids": vals["partner_ids"]}
                    )
        stale = Event.search(
            [
                ("caldav_source", "=", "icloud"),
                ("user_id", "=", resource.user_id.id),
                ("stop", ">=", start),
                ("caldav_uid", "not in", list(seen)),
            ]
        )
        if stale:
            stale.write({"active": False})

    @api.model
    def _caldav_push(self, resource, calendar):
        """Write bookings into iCloud once, and remember their UID."""
        now = fields.Datetime.now()
        bookings = (
            self.env["resource.booking"]
            .sudo()
            .search(
                [
                    ("state", "in", ("scheduled", "confirmed")),
                    ("start", ">=", now - timedelta(days=1)),
                    ("combination_id.resource_ids", "in", resource.ids),
                    ("caldav_uid", "=", False),
                ]
            )
        )
        for booking in bookings:
            uid = str(uuid.uuid4())
            calendar.add_event(booking._caldav_ical(uid).to_ical().decode("utf-8"))
            booking.write({"caldav_uid": uid})

    @api.model
    def _caldav_cancel(self, resource, calendar):
        """Remove from iCloud the events of bookings cancelled in Odoo."""
        bookings = (
            self.env["resource.booking"]
            .sudo()
            .with_context(active_test=False)
            .search(
                [
                    ("state", "=", "canceled"),
                    ("combination_id.resource_ids", "in", resource.ids),
                    ("caldav_uid", "!=", False),
                ]
            )
        )
        for booking in bookings:
            try:
                event = calendar.get_event_by_uid(booking.caldav_uid)
            except Exception:
                event = None
            if event is not None and getattr(event, "url", None):
                event.delete()
            booking.write({"caldav_uid": False})

    def _caldav_ical(self, uid):
        self.ensure_one()
        ical = icalendar.Calendar()
        ical.add("prodid", "-//2143 Labs//Odoo booking//EN")
        ical.add("version", "2.0")
        event = icalendar.Event()
        event.add("uid", uid)
        event.add(
            "summary",
            "%s - %s" % (self.type_id.name, self.partner_ids[:1].name or "Booking"),
        )
        event.add("dtstart", pytz.utc.localize(self.start))
        event.add("dtend", pytz.utc.localize(self.stop))
        event.add("dtstamp", datetime.now(pytz.utc))
        event.add("status", "CONFIRMED")
        event.add("transp", "OPAQUE")
        event.add(
            "description", self.get_base_url() + self.get_portal_url()
        )
        ical.add_component(event)
        return ical
