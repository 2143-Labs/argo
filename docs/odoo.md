# Odoo (o.aross.studio, o.2143.me)

One Odoo Community 18.0 + OCA instance per company: `https://o.aross.studio` (aross.studio, namespace `odoo-aross`) and `https://o.2143.me` (2143 Labs LLC, namespace `odoo-labs`). Each is one always-on pod, `strategy: Recreate`, with its own CNPG Postgres (`odoo-db`), its own filestore PVC (`odoo-filestore`), its own admin and users. Both start on OCA's US GAAP chart of accounts (`l10n_us_gaap`, template `us_gaap`).

**No scheduled database backup exists** (deferred 2026-11-08). The filestore PVC is in the nightly Longhorn backup to the NAS; Postgres is not. Enter no real books until a database backup exists, and take the manual dump below before every change.

## What runs where

- Chart `workloads/odoo`, one Application per company: `apps/odoo-aross.yaml`, `apps/odoo-labs.yaml`. Per-company values are the `helm.parameters` there; shared ones (image, module list, DB size) are in `workloads/odoo/values.yaml`.
- Image `ghcr.io/2143-labs/odoo:sha-<commit>`, built by `.github/workflows/odoo-image.yml` from `workloads/odoo/image/` (the `Dockerfile` pins the Odoo base image by digest; `oca-repos.txt` pins every OCA repo by commit).
- OpenBao, mount `consumers`: `john2143-com/<namespace>/odoo-admin` (first-init admin password), `john2143-com/<namespace>/oidc` (Pocket ID client), `john2143-com/stalwart/scaleway-tem-smtp` (outgoing mail, shared).
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

## Staff

- Onboarding: add the person to the company's Pocket ID group (`aross` or `labs`); in Odoo, Settings → Users → New user with their email; they open the invitation email and click "Log in with Pocket ID".
- Offboarding: archive the user in Odoo, then remove them from the Pocket ID group.

## Admin password

The OpenBao value is used once, on first init. After changing the password in Odoo, store the new one without it appearing on screen or in argv:

```bash
read -rsp 'new admin password: ' pw; echo
f=$(mktemp /dev/shm/seed-XXXXXX); printf '{"ODOO_ADMIN_PASSWORD":"%s"}' "$pw" > "$f"
bao kv put -mount=consumers john2143-com/<namespace>/odoo-admin @"$f"; shred -u "$f"; unset pw
```

## Edge

`workloads/odoo/templates/httproute.yaml` has three rules on each host:

- `/web/database`, `/xmlrpc`, `/jsonrpc`: `lan-only` (home LAN and John's tailnet).
- Paths that carry arbitrary request bodies (back-office writes, chatter, live chat, uploads, website editor, websocket): rate limits plus `crowdsec-bouncer-noappsec`. IP bans apply; AppSec body inspection does not.
- Everything else: rate limits plus `crowdsec-bouncer` (AppSec and IP bans).

`workloads/crowdsec-agent/agent-booking-hosts.yaml` switches off the crawl and probing scenarios for these hosts, because normal shop and back-office use looks like both.

When a customer or staff member reports a 403, check for a CrowdSec decision on their address and remove it if the address is not malicious:

```bash
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions list --ip <addr>
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions delete --ip <addr>
```
