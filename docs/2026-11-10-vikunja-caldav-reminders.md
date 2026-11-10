# Vikunja CalDAV, Apple Reminders, and the 2.8.0 upgrade (2026-11-10)

**Date:** 2026-11-10

**Context:** `tasks.2143.me` replaced the ad-hoc task board. On 2026-11-10 a CalDAV token was
created and the account was added to an iPhone so one can complete tasks from Reminders (and
from Siri). This records how that connection works, what it exposes, what the 2.8.0 upgrade
changed, and the one thing that is still missing: events in iCloud **Calendar**.

## Setup as it stands

- `vikunja/vikunja:2.8.0` in namespace `default`, SQLite on the `vikunja-data` PVC, OIDC-only
  through Pocket ID (`auth.local.enabled: false`). CalDAV is enabled (`service.enablecaldav`).
- CalDAV lives at `/dav`, **not** `/api/v1/dav` — the URL in Vikunja's own iOS instructions
  404s on this release. The working principal URL is
  `https://tasks.2143.me/dav/principals/John2143/`.
- Auth is a **CalDAV token**, created by hand in Settings → CalDAV. A password cannot work:
  the account is OIDC and the instance has TOTP available, and Vikunja rejects password-based
  basic auth in both cases. Bot users are rejected for CalDAV, so a bot account cannot be used
  to scope what the phone sees.
- The token exists only on the device. It is **not** stored in OpenBao; nothing needs to read
  it server-side.
- Phone setup: Settings → Apps → Calendar → Accounts → Other → Add CalDAV Account. Calendar
  should be left off — Vikunja serves `VTODO` only, so the Calendar side stays permanently
  empty; enable **Reminders**.

## What the phone sees

- Every non-archived project the user can read (`Project.ReadAll` in
  `pkg/routes/caldav/listStorageProvider.go`), plus saved filters and Favorites as pseudo
  collections. Archived projects are excluded.
- **Every task in those projects, done or not** — the task collection is fetched with only a
  project id, so a 1750-task board means ~1750 reminders on the phone.
- There is no "assigned to me" collection upstream (issue #2304), and no server-side way to
  hide individual projects from a CalDAV client. Noise control has to be client-side (Today /
  Scheduled / smart lists) or by giving the phone a Vikunja user that can only see chosen
  projects — a real user, since bots are rejected.

## Write semantics

- `PUT` creates and updates a task, `DELETE` deletes it, and `STATUS:COMPLETED` (or
  `COMPLETED`) sets `done` + `done_at`. Updating overlays only the properties the VTODO
  expresses: title, description, done, priority, due date, start date, end date, colour,
  alarms.
- Creates land in whichever list (project) the reminder was made in, with `created_by` set to
  the CalDAV user and **no assignee and no start date** — iOS sends `DUE` but not
  `DTSTART`/`DTEND`.
- **Deleting from the phone deletes the task.** Since 2.8.0 it goes to the 30-day trash; on
  2.7.0 it was permanent. "Clear completed" in Reminders is the dangerous button.
- Known upstream bug (#4278, open at 2.8.0): date-only reminders are exported as midnight UTC,
  so iOS shows them as timed and pins times to GMT.
- Siri works on the Reminders database, so it sees these lists. Set Settings → Reminders →
  Default List to a Vikunja list or "remind me to X" never reaches Vikunja. Location reminders
  are lost: Vikunja does not support `LOCATION` and does not echo unknown properties back.

## 2.8.0 upgrade (2026-11-10)

Upgrade from 2.7.0, which had also skipped 2.7.1. One-line image bump, commit `3feadb1`,
pushed to `main`; Argo synced it.

What it bought:

- **Trash for tasks and projects** (30 days, restore pages, permission-aware permanent
  delete) — this is what makes phone/Siri deletes safe.
- **19 security fixes**, three CalDAV-specific (crafted calendar uploads, reminder rendering
  cost, repeated property queries) plus the 41 advisories fixed in 2.7.1.
- CalDAV corrections: `calendar-query` filters applied, sync tokens invalidated after
  permanent deletion, unparsable bodies answered with 403 instead of 500, bounded PROPPATCH.
- Reminders now follow subscriptions; the startup migration re-subscribed creators and
  assignees to existing tasks once, so a deliberately unsubscribed task may notify again.

No config change was needed: `/dav`, the CalDAV token schema and the auth flow are identical
between 2.7.0 and 2.8.0, so the phone account kept working without re-enrolment. Used config
keys (`service.publicurl`, `customlogourl(dark)`, `database.type`, `auth.local`,
`auth.openid.providers.pocketid.*`) all remain valid; 2.8.0's deprecations (legal links, OIDC
email/username fallbacks) target keys this instance does not set.

Verification: pod ready with 0 restarts, migrations logged `Ran all migrations successfully`
in 0.33 s, `/api/v1/info` reports v2.8.0, `/health` 200, `PROPFIND /dav/principals/John2143/`
still 401, UI 200.

## Still missing: events in iCloud Calendar

Vikunja never emits `VEVENT`, so Calendar stays empty; a bridge must read tasks and write
events. Design decisions, the credential paths and the guard rails are in the task board
(card "Vikunja → iCloud Calendar: build the VEVENT bridge"), and the proven iCloud client code
is `workloads/odoo/image/addons/booking_public/models/caldav_sync.py` on the booking branch.

Two constraints worth repeating here:

- The bridge must write to a **separate** iCloud calendar. `odoo-aross` reads its employees'
  iCloud calendars as busy time, so putting task events in a bridged calendar would block
  public bookings.
- "Assigned to me" is not a usable predicate yet: on 2026-11-10 only two tasks had any
  assignee, and neither had dates. Scope the bridge to a dedicated project instead.

## Operations and rollback

- One PVC holds the SQLite DB and attachments; Longhorn `nightly-backup` (03:00, retain 30)
  covers it.
- Migrations run at startup and are forward-only in practice. A tag revert alone is not a
  rollback; restore the volume instead.
- Upgrade procedure used: branch from `origin/main`, bump the image, push to `main`
  (fast-forward), watch Argo, then check version/health/CalDAV challenge and migration logs.
