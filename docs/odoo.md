# Odoo (o.aross.studio, o.2143.me)

One Odoo Community 18.0 + OCA instance per company: `https://o.aross.studio` (aross.studio, namespace `odoo-aross`, also `https://book.aross.studio` for the public booking page) and `https://o.2143.me` (2143 Labs LLC, namespace `odoo-labs`, also `https://book.2143.me` for its public booking page). Each is one always-on pod, `strategy: Recreate`, with its own CNPG Postgres (`odoo-db`), its own filestore PVC (`odoo-filestore`), its own admin and users. Both start on OCA's US GAAP chart of accounts (`l10n_us_gaap`, template `us_gaap`).

**No scheduled database backup exists** (deferred 2026-11-08). The filestore PVC is in the nightly Longhorn backup to the NAS; Postgres is not. Enter no real books until a database backup exists, and take the manual dump below before every change.

## What runs where

- Chart `workloads/odoo`, one Application per company: `apps/odoo-aross.yaml`, `apps/odoo-labs.yaml`. Per-company values are the `helm.parameters` there; shared ones (image, module list, DB size) are in `workloads/odoo/values.yaml`.
- Image `ghcr.io/2143-labs/odoo:sha-<commit>`, built by `.github/workflows/odoo-image.yml` from `workloads/odoo/image/` (the `Dockerfile` pins the Odoo base image by digest; `oca-repos.txt` pins every OCA repo by commit).
- OpenBao, mount `consumers`: `john2143-com/<namespace>/odoo-admin` (first-init admin password), `john2143-com/<namespace>/oidc` (Pocket ID client), `john2143-com/<namespace>/caldav` (iCloud app-specific passwords, optional), `john2143-com/stalwart/scaleway-tem-smtp` (outgoing mail, shared).
- Pocket ID (`https://au.2143.me`): one OIDC client per company, allowed groups `aross` and `labs`.
- Mail goes out through Scaleway TEM as `aross_odoo@m.2143.me` / `labs_odoo@m.2143.me` (`m.2143.me` is the only TEM-verified domain).

## How start-up works

Every pod start runs the `odoo-init` initContainer (`workloads/odoo/files/init.sh`). It does nothing unless `INIT_HASH` changed: the image, the module list, the init scripts, the host or the `oidc` flag. The last applied hash is a marker file on the filestore.

When it does run, the database decides what to do, never the markers:

1. Empty database: install `base`, set the company's name, state and admin password (`files/company.py`), install `l10n_us_gaap` before any other accounting module, and pin the `us_gaap` chart (`files/chart.py`).
2. Image changed since the last run: `-u all` (update mode keeps in-app edits to Odoo's `noupdate` data).
3. Install only the listed modules that are not installed yet. Never pass an installed module to `-i`: install mode rewrites its `noupdate` data (stages, mail templates, ...), and `-i base` resets the company.
4. Set `web.base.url` and the Pocket ID login button (`files/setup.py`).

Because of `Recreate`, an image or module change takes the site down until `odoo-init` finishes: seconds for a new module, minutes for `-u all`. Push those outside business hours and watch:

```bash
kubectl -n <namespace> logs deploy/odoo -c odoo-init -f
```

The last line reads `odoo-init: applied <hash> (first=<0|1>, installed: <modules or "nothing new">)`.

## Take a dump before any image or module change

```bash
P=$(kubectl -n <namespace> get cluster odoo-db -o jsonpath='{.status.currentPrimary}')
kubectl -n <namespace> exec "$P" -c postgres -- pg_dump -Fc -d odoo > <namespace>-$(date +%F).dump
```

Keep the file off the cluster. No restore procedure is written yet: a `-Fc` dump restores with `pg_restore` into an empty `odoo` database, together with the filestore from the Longhorn backup of the same night. Writing and testing that procedure belongs to the database-backup work. Until then, if an update leaves the database broken, stop and keep the dump; do not improvise a restore on the live cluster.

## Add a module

1. Append it to `modules` in `workloads/odoo/values.yaml`.
2. If it comes from an OCA repo that is not in `workloads/odoo/image/oca-repos.txt`, first add the repo with a full commit SHA from its `18.0` branch, push, wait for the `Build and push odoo` workflow, then set `image` to the new `sha-<commit>` tag. If the module's manifest lists `external_dependencies`, add those to the `pip3 install` line in the `Dockerfile`.
3. Push. The next start installs only that module.

Removing a name from the list uninstalls nothing. Uninstall it in Odoo (Apps) first, then remove it from the list.

## Update Odoo or OCA

1. Take the dump (above).
2. Bump the `FROM` digest in the `Dockerfile` (Docker Hub `odoo:18.0-<date>` tags) and/or SHAs in `oca-repos.txt`; push; wait for the workflow; set `image` in `values.yaml` to the new tag; push again, outside business hours.
3. Watch `odoo-init` (above): it runs `-u all`.

If `odoo-init` crash-loops during `-u all`, revert the `image` bump. If the old image then fails too, the database is half-migrated and only the dump can recover it.

Odoo supports 18.0 until about late 2027. The move to 19.0 goes through OpenUpgrade and is its own project; the OCA US modules (`OCA/l10n-usa`) exist only on 18.0 today.

## Public booking page

`https://book.aross.studio/book` is the in-repo addon `booking_public` (`workloads/odoo/image/addons/booking_public`, copied to `/opt/aross/addons` by the image and listed in `modules`). It is the public front door on top of OCA `resource_booking`. Both instances have a booking host (`book.aross.studio`, `book.2143.me`, the `bookingHost` value in their Application); each company publishes its own booking types. On those hosts `/` answers 302 to `/book`, because the root would otherwise render the empty default website.

Publishing a service is done in the booking type (Resource bookings → Booking types → *Public page* tab):

- **Show on the public booking page** publishes it at `/book`; *Public description* is rendered above the time picker.
- **Days shown ahead** (default 60) bounds the horizon. `modifications_deadline` also applies, so with the usual 24 hours nobody can book for today.
- **Service product** is invoiced when a customer books and is the base of a percentage deposit.
- **Deposit**: none, a fixed amount, or a percentage. It becomes a confirmed sale order and a posted invoice for the deposit; the slot is held before payment, so an unpaid deposit does not free the time.
- The type needs at least one **resource combination** holding the person doing the work, and that person's resource needs their working calendar. The type's availability calendar bounds the hours offered.

A customer gives a name and a valid email and nothing else. The booking is created in state Confirmed with a `calendar.event` at the chosen time, the employee is the event organizer, and the calendar invitation goes out. With a deposit and an enabled payment provider the customer is sent to the invoice's payment page; otherwise to `/my/bookings/<id>?access_token=…`. Times are shown in the type's availability-calendar timezone and submitted as UTC, so the visitor's clock is irrelevant.

The page is anonymous, so abuse control is the edge's: the booking host is an ordinary public host with `public-rate-limit`, `public-inflight-limit` and the three CrowdSec rules described under Edge. There is no captcha. If spam bookings appear, add a honeypot field before adding one.

**One page, one booking.** Each rendered page carries a `booking_key`; a second submission of the same page — a double click, a reload, a retry after a dropped connection — is answered with the booking it already made instead of making another. Submissions of one key are serialised in the database (`pg_advisory_xact_lock`), so two clicks that overlap still produce one booking. A submission whose time is refused creates nothing and does not consume the key, so the visitor can simply try again, and a cancelled booking is not replayed.

**One address, one contact.** The visitor's `res.partner` is found or created under a second lock keyed on the normalised address, so two forms submitted at the same moment from one address make two bookings but a single contact. Before that, both requests searched, both found nothing, and both created (partners 44/45 on `odoo-aross` were the result).

**Why a booking takes a second or two.** The visitor's invitation is sent inside the request; the staff invitation, the portal notifications and the addon's own comment are queued and go out on the next run of `Mail: Email Queue Manager`, which this addon retimes to every minute (core ships it hourly). Sending all of them inline made every booking POST wait for one SMTP round trip each — roughly ten seconds against the relay, which is what made visitors click again.

Easy!Appointments is retired: its two Applications (`book-aross` and `book-2143`) and their namespaces are deleted. It had never been installed (no `ea_appointments` table in either MariaDB), so no booking, service or customer data was lost. The chart stays in `workloads/booking` for a restore if it is ever wanted again.

### iCloud calendar sync

A booking only avoids an appointment that Odoo can see, and staff keep their real calendar in iCloud. With `caldav` set for the instance (only `odoo-aross`), the cron `Public booking: iCloud CalDAV sync` runs every 15 minutes and bridges one person at a time:

- **In:** each iCloud event in the next 90 days becomes a busy event owned by that person in Odoo, so the availability engine stops offering the time. Recurrences are expanded; events that disappear from iCloud are archived in Odoo.
- **Out:** a confirmed booking is written into that person's calendar once, so it appears on their phone.
- **Cancel:** cancelling the booking in Odoo deletes the iCloud event.

To bridge a person:

1. Create an app-specific password at `account.apple.com` → *Sign-In and Security* → **App-Specific Passwords**. It needs two-factor authentication on the Apple Account, it is not in the iPhone's iCloud settings, and the Apple Account password itself does not work.
2. Put every bridged employee of one company in one JSON document:

   ```json
   {"employees": [
     {"email": "amanda@aross.studio", "username": "amanda@aross.studio",
      "app_password": "abcd-efgh-ijkl-mnop", "calendar": "Work"}
   ]}
   ```

   `calendar` is the calendar's display name in Apple Calendar, not a URL; the collection is discovered.
3. Store it without the value appearing on screen or in argv:

   ```bash
   read -rsp 'json: ' j; echo
   f=$(mktemp /dev/shm/cd-XXXXXX); printf '%s' "$j" > "$f"
   bao kv put -mount=consumers john2143-com/<namespace>/caldav CALDAV_CREDENTIALS=@"$f"
   shred -u "$f"; unset j
   ```

4. Tick **Sync iCloud calendar** on that person's resource (Settings → Technical → Resources, if you are an administrator). A credential entry alone does nothing; the flag is the opt-in. Rotating a password needs only a new OpenBao value and `kubectl -n <namespace> rollout restart deploy/odoo`.

Odoo is authoritative for bookings: editing or deleting the booking's copy in Apple Calendar changes nothing in Odoo, and the next pull puts it back. iCloud is authoritative for everything else. To stop the bridge, blank the OpenBao value and restart the pod: the cron logs `no CALDAV_CREDENTIALS, nothing to sync` and touches no booking. A wrong password or a renamed calendar is logged for that employee and skipped, so it costs one person's sync rather than the booking page.

### Video calls

Tick **Create a video room per booking** on a booking type (the field sits under *Meeting URL*; leave *Meeting URL* empty). Each new booking of that type gets its own Odoo Discuss link, `https://<o. host>/calendar/join_videocall/<token>`, in the invitation email (*How to Join*), on the booking's portal page as **Join the video call**, and as the URL of its iCloud copy. The first visit creates a private group channel and opens the call; the customer joins as a guest, without an account. A two-person call goes browser to browser, with no media server. Cancelling, unscheduling or deleting the booking deletes the room; rescheduling it through Odoo sends a new invitation with a new link. Bookings made before the box was ticked get no link.

The call rings the employee only while they have an Odoo tab open, so staff open the link at the start time.

With `turn` set for the instance, each call gets 6-hour TURN credentials for `turn.john2143.com:3478` (UDP and TCP), minted from `TURN_AUTH_SECRET` by `models/mail_ice_server.py`. That relay is the steam-lobby coturn (`workloads/steam-lobby`), shared with `pvp.john2143.com`; it refuses to relay to private, CGNAT and link-local addresses. Without the variable Odoo falls back to Google STUN, and two people on networks that block direct connections see a call that connects but shows nothing. To check it, in `odoo shell`: `env["mail.ice.server"]._get_ice_servers()` returns three entries. The secret is OpenBao `john2143-com/steam-lobby/steam-lobby-turn`; after a rotation, Reloader restarts coturn, steam-lobby and both Odoo pods as each copy of the Secret refreshes (up to 10 minutes apart), and calls in that window fall back to STUN.

## Staff

Two gates decide access:

1. **The Pocket ID group** (`aross` or `labs`) decides who may authenticate at all. Pocket ID shows its own refusal to anyone outside the group.
2. **The Odoo user** decides what they can do: user type (Internal User, or Portal for customers) and app groups.

Sign-up is invitation-only (`auth_signup.invitation_scope = b2b`, set in `files/setup.py`; the Website app would otherwise default it to free sign-up, which turns every Pocket ID user into a portal account on first sign-in). A Pocket ID user with no Odoo account and no invitation is refused.

- **Onboarding:** add the person to the Pocket ID group; in Odoo (Settings → Users & Companies → Users → New) create them with their email, set the user type and app groups, then use *Invite*. They click the invitation link, choose "Log in with Pocket ID", and Odoo binds that Pocket ID identity to the account. Later logins are matched by Pocket ID's `sub`.
- **Admin:** set the user type to Internal User and add *Administration → Settings*. An administrator still only sees the apps whose groups they hold, so tick the app groups too; to give someone exactly what the `admin` account has, mirror its groups: `env['res.users'].search([('login', '=', '<login>')], limit=1).write({'groups_id': [(6, 0, env.ref('base.user_admin').groups_id.ids)]})`. The password account `admin` is the break-glass login; see Admin password below.
- **Offboarding:** archive the user in Odoo, then remove them from the Pocket ID group.
- **Unblocking someone** who cannot get in: `kubectl -n <namespace> exec deploy/odoo -c odoo -- bash -c 'odoo shell -d odoo --db_host="$HOST" --db_port="$PORT" --db_user="$USER" --db_password="$PASSWORD"'` and inspect `env['res.users'].search([('login','=',...)]).groups_id`, or the `auth_oauth_provider` record.

## Admin password

The OpenBao value is used once, on first init. After changing the password in Odoo, store the new one without it appearing on screen or in argv:

```bash
read -rsp 'new admin password: ' pw; echo
f=$(mktemp /dev/shm/seed-XXXXXX); printf '{"ODOO_ADMIN_PASSWORD":"%s"}' "$pw" > "$f"
bao kv put -mount=consumers john2143-com/<namespace>/odoo-admin @"$f"; shred -u "$f"; unset pw
```

## Edge

`workloads/odoo/templates/httproute.yaml` has three rules on each host (`odoo.routeRules` in `templates/_helpers.tpl`):

- `/web/database`, `/xmlrpc`, `/jsonrpc`: `lan-only` (home LAN and John's tailnet), on every host.
- Paths that carry arbitrary request bodies (back-office writes, chatter, live chat, uploads, website editor, websocket): rate limits plus the host's CrowdSec bouncer.
- Everything else: rate limits plus the host's CrowdSec bouncer.

The bouncer differs by host, which is why each booking host has its own HTTPRoute (`odoo-<id>-booking`): on `o.*` it is `crowdsec-bouncer` (or `crowdsec-bouncer-noappsec` for bodies), which enforces IP bans; on the booking host it is `crowdsec-bouncer-appsec-only`, which 403s the single request that trips an AppSec rule and never consults the ban list, the community blocklist or bans earned on other hosts. A customer filling in the booking form must never be locked out of everything else (`scripts/validations/booking-never-ban.sh`). Both hostnames serve the same Odoo, so the back office is reachable on the booking host too — behind the same login, with `/web/database` and the XML-RPC APIs still LAN-only.

`workloads/crowdsec-agent/agent-booking-hosts.yaml` switches off the crawl and probing scenarios for these hosts, because normal shop and back-office use looks like both.

When a customer or staff member reports a 403, check for a CrowdSec decision on their address and remove it if the address is not malicious:

```bash
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions list --ip <addr>
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions delete --ip <addr>
```
