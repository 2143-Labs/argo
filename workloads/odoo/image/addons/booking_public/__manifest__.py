{
    "name": "Public booking page",
    "summary": "Anonymous booking entry point on top of resource_booking",
    "version": "18.0.1.0.0",
    "license": "AGPL-3",
    "author": "2143 Labs",
    "depends": ["resource_booking", "website", "sale", "payment", "portal", "mail"],
    "data": [
        "views/resource_booking_type_views.xml",
        "views/templates.xml",
    ],
    "installable": True,
    "application": False,
}
