"""Fixtures and helpers shared by the public-page and CalDAV tests."""

import re

import icalendar
import pytz

WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]


def create_fixture(obj):
    """A bookable person, their hours, one combination and a published type."""
    obj.env = obj.env(
        context=dict(
            obj.env.context, tracking_disable=True, no_reset_password=True, tz="UTC"
        )
    )
    obj.calendar = obj.env["resource.calendar"].create(
        {
            "name": "Public booking hours",
            "tz": "UTC",
            "attendance_ids": [
                (0, 0, {"name": day, "dayofweek": str(number), "hour_from": 8, "hour_to": 17})
                for number, day in enumerate(WEEKDAYS)
            ],
        }
    )
    obj.user = obj.env["res.users"].create(
        {
            "name": "Booking Employee",
            "login": "booking_employee",
            "email": "employee@example.com",
            "tz": "UTC",
            "groups_id": [(6, 0, [obj.env.ref("base.group_user").id])],
        }
    )
    obj.resource = obj.env["resource.resource"].create(
        {
            "name": "Booking Employee",
            "resource_type": "user",
            "user_id": obj.user.id,
            "calendar_id": obj.calendar.id,
            "tz": "UTC",
            "caldav_enabled": True,
        }
    )
    obj.combination = obj.env["resource.booking.combination"].create(
        {"resource_ids": [(6, 0, obj.resource.ids)]}
    )
    obj.product = obj.env["product.product"].create(
        {"name": "Photo session", "type": "service", "sale_ok": True, "list_price": 200.0}
    )
    obj.btype = obj.env["resource.booking.type"].create(
        {
            "name": "Photo session",
            "duration": 1.0,
            "slot_duration": 1.0,
            "modifications_deadline": 0,
            "resource_calendar_id": obj.calendar.id,
            "combination_rel_ids": [(0, 0, {"combination_id": obj.combination.id})],
            "public_page": True,
            "public_horizon_days": 14,
            "product_id": obj.product.id,
            "deposit_mode": "fixed",
            "deposit_fixed": 50.0,
        }
    )
    return obj


def page(test, type_id=None):
    """HTML of the public page for the fixture type."""
    return test.url_open("/book/%d" % (type_id or test.btype.id)).text


def first_slot(html):
    """Wire value of the earliest offered slot."""
    match = re.search(r'name="when" value="([^"]+)"', html)
    return match.group(1) if match else None


def csrf(html):
    return re.search(r'name="csrf_token" value="([^"]+)"', html).group(1)


def post(test, html, **values):
    """Submit the booking form, following the redirect."""
    data = {"csrf_token": csrf(html), "name": "Ada Lovelace", "email": "ada@example.com"}
    data.update(values)
    return test.url_open(
        "/book/%d/confirm" % test.btype.id, data=data, allow_redirects=True
    )


def ical(uid, start, stop, summary="Busy"):
    """A minimal single-event VCALENDAR, as iCloud would serve it."""
    calendar = icalendar.Calendar()
    calendar.add("prodid", "-//2143 Labs//test//EN")
    calendar.add("version", "2.0")
    event = icalendar.Event()
    event.add("uid", uid)
    event.add("summary", summary)
    event.add("dtstart", pytz.utc.localize(start))
    event.add("dtend", pytz.utc.localize(stop))
    calendar.add_component(event)
    return calendar.to_ical().decode("utf-8")
