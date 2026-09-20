# Seafile: DB credential rotation into OpenBao, and SSO-only login

**Date:** 2026-09-20
**Status:** implemented and **verified**. The MariaDB credentials are rotated and
served from OpenBao; non-staff users are refused a local password login.
**Scope:** `default` namespace, Seafile CE (`workloads/seafile*`, `apps/seafile*.yaml`),
and the OpenBao entry at `consumers/data/john2143-com/default/seafile-secret`.

## Why

Two independent problems, both in the same service:

1. **The MariaDB credentials were the literal placeholders `changeme-root` and
   `changeme-seafile`.** They were committed to this public repository on
   2026-07-19 in `c6308e6`, `1f233da` and `8341b0e` (all ancestors of `HEAD`), and
   they were still live: `Secret/default/seafile-secret` carried them and the
   Deployment injects the whole Secret into the internet-facing container as
   environment variables. The values are gone from the current tree but remain
   in git history, so they can only be treated as disclosed.
2. **Non-staff users could authenticate with a local password.** Pocket ID SSO
   via `au.2143.me` was already enabled, but it was additive rather than
   exclusive.

## 1. Credential rotation

`SEAFILE_MYSQL_DB_PASSWORD` and `INIT_SEAFILE_MYSQL_ROOT_PASSWORD` were replaced
with 48-character alphanumeric values, generated from `/dev/urandom` in a
`/dev/shm` workdir with `umask 077` and shredded afterwards.

Order was chosen to make the window explicit: **ALTER the database first, then
write OpenBao, then let the pod restart.** Seafile is unavailable for roughly
1–3 minutes in that window — accepted deliberately, since the alternative
(restart first) leaves the pod pointed at an OpenBao value the database does not
yet have.

Affected account rows, discovered rather than assumed (`mysql.user`):
`root@%`, `root@localhost`, `seafile@%`.

Three details deviate from the obvious procedure and are worth carrying forward:

- **The app user cannot change its own password.** `ALTER USER … IDENTIFIED BY`
  requires `CREATE USER`, which `seafile@%` does not hold
  (`ERROR 1227 … Access denied`). `SET PASSWORD` does not help either. All three
  rows are therefore altered **as root**, which is possible because root still
  authenticated with the disclosed placeholder at rotation time.
- **`kv put` was not used.** A full-payload `kv put` requires decoding *all six*
  live values out of the Kubernetes Secret to rebuild the payload — reading
  `JWT_PRIVATE_KEY`, `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET` and
  `SEAFILE_ADMIN_PASSWORD` for no reason. `kv patch` writes only the two keys
  being rotated. The `openbao-admin` OIDC token does **not** hold the `patch`
  capability, so the write used the documented `-method=rw`
  ("fetch the secret's data, perform an in-memory update, and write the updated
  data"), which needs only `read` + `update`. The read stays inside the CLI —
  no secret value passed through a shell, a file, or an argument list. Verified:
  the entry kept all six keys, and OpenBao moved version 1 → 2.
- **With `-mount=`, the `data/` prefix must be omitted.** `bao kv get
  -mount=consumers data/john2143-com/…` silently resolves to
  `consumers/data/data/john2143-com/…` and returns nothing, which reads exactly
  like an empty secret. The correct form is `-mount=consumers
  john2143-com/default/seafile-secret`, and for metadata
  `kv metadata get -mount=consumers john2143-com/…`.

Verified after the fact: the new credentials authenticate as `seafile@%` and
`root@localhost`; **both old placeholders now return `ERROR 1045`** and are dead;
the rendered Secret matches OpenBao key-for-key; and a DB round-trip through
Seafile's own settings succeeded.

## 2. SSO-only login for non-staff users

Two statements were appended to the `oauth_settings.py` body of
`workloads/seafile-db/seafile-oauth-cm.yaml` (commit `88abe09`):

```python
DISABLE_ADFS_USER_PWD_LOGIN = True
OAUTH_PROVIDER_DOMAIN = "pocketid"
```

**Both are required; either alone is a silent no-op.** This is the single most
likely thing for a future reader to break, so it is worth stating precisely.
`is_force_user_sso()` (`seahub/utils/auth.py`) resolves the provider it filters
on as:

```python
oauth_provider_identifier = getattr(settings, 'OAUTH_PROVIDER_DOMAIN', '')
…
SocialAuthUser.objects.filter(username=username,
    provider__in=[saml_provider_identifier, oauth_provider_identifier])
```

It reads `OAUTH_PROVIDER_DOMAIN` — **never** `OAUTH_PROVIDER` — and falls back to
the empty string. Meanwhile `seahub/oauth/views.py` stores the row as
`OAUTH_PROVIDER`, which this ConfigMap sets to `"pocketid"`. So without the
second line the filter becomes `provider__in=['saml', '']`, matches nothing, and
the enforcement never fires — with no error anywhere. `OAUTH_PROVIDER_DOMAIN` has
no other effect in 13.0.28: its only two uses are that filter and an
`OAUTH_PROVIDER` fallback that is skipped because `OAUTH_PROVIDER` is set.

`DISABLE_ADFS_USER_PWD_LOGIN` is the correct key for the 13.0 line.
`DISABLE_SSO_USER_LOCAL_PWD_LOGIN` exists only on `master`/14.x and is a no-op
here. Despite the `ADFS` in the name, it is the general switch: it is guarded by
`enable_sso = ENABLE_OAUTH or ENABLE_ADFS_LOGIN`, and `ENABLE_OAUTH` is already
`True`.

The ConfigMap is mounted with `subPath`, which Kubernetes never updates in place,
so the pod restart is mandatory rather than cosmetic.

### Verification

The login form rejects *after* password validation succeeds
(`seahub/auth/forms.py:118`), raising **"Please use Single Sign-On to login."**

A UI password-login test cannot demonstrate this on the current account set —
the only non-staff SSO user has the unusable password `!`, so it fails at
credential validation before reaching the gate. The behaviour was therefore
verified directly against the live application instead:

| account | `is_staff` | `is_force_user_sso` | `can_user_update_password` |
|---|---|---|---|
| `admin@john2143.com` | True | **False** | True |
| `602845ed…@auth.local` | False | **True** | **False** |

The non-staff user is now forced to SSO and **can no longer set a local
password** either. That second column matters: `ENABLE_SSO_USER_CHANGE_PASSWORD`
defaults to `True` in 13.0.28, so before this change an SSO-bound user could
have created exactly the password-login path we are removing.

### Staff keep local password login — by design

`is_force_user_sso()` short-circuits on `if force_sso and (not is_admin)`, and
`is_admin` is `user.is_staff`. `admin@john2143.com` is staff, so it retains
password login. **That is the intended break-glass path**, not an oversight, and
it is not configurable. If SSO or Pocket ID is ever unavailable, this account is
the way in.

## 3. Unplanned: the image moved 13.0.25 → 13.0.28

The restart pulled a newer `seafileltd/seafile-mc:13.0-latest`. The pod had been
running digest `sha256:90c1aaa0…` (seafile-server **13.0.25**); the rescheduled
pod runs `sha256:b0c90832…` (seafile-server **13.0.28**), and the container ran
its bundled `minor-upgrade.sh` on start. This was not part of the change set —
it is a consequence of the tag being floating with `imagePullPolicy:
IfNotPresent`, so any reschedule onto a node without the cached image does this.

It landed cleanly: the upgrade script ran, `seahub.error.log` is empty, and the
service came up normally. The seahub code the change depends on was **re-read at
13.0.28** afterwards and `is_force_user_sso()` is byte-identical to 13.0.25.

Worth noting for next time: the version that is documented (`13.0-latest` →
13.0.25) and the version that is running can diverge silently, and a restart is
enough to close the gap.

## 4. Orphaned duplicate Secrets

Two Secrets were created by hand on 2026-07-19 with no ownerReferences and no
manifest at `HEAD`. They are not equally safe to remove, and the difference is
not visible from the repo:

- **`seafile-oidc` — deleted.** Its `OAUTH_CLIENT_ID` and `OAUTH_CLIENT_SECRET`
  are byte-identical to the `seafile-secret` copies, so nothing unique was lost.
  Confirmed unreferenced before deletion.
- **`seafile-admin` — retained.** Its `SEAFILE_ADMIN_PASSWORD` **differs** from
  the one in `seafile-secret`. Because `INIT_SEAFILE_ADMIN_PASSWORD` is honoured
  only at first init, it is not knowable from the repo which of the two is the
  live admin password — and with local password login now serving as the staff
  break-glass path, deleting it could destroy the only stored copy of the one
  working admin credential. It is the current record of that credential, and it
  is listed as an open follow-up below.

## 5. What remains

- **`seafile-admin` divergence is unresolved.** Determine which password actually
  logs in as `admin@john2143.com`, then either align the Secret with OpenBao or
  retire the Secret. Do not delete it blind.
- **A non-staff *local* account with no `SocialAuthUser` row is not covered.**
  The setting only applies to users who have an SSO binding. Checked at the time
  of writing: there are exactly two accounts and no such user exists. This is a
  residual risk, not a current one, and seahub 13.0 has no global switch for it.
- **The disclosed placeholders are still in git history** (`c6308e6`, `1f233da`,
  `8341b0e`). They are dead but permanently public; they must never be reused,
  and they are being recorded in the §2 rotation backlog of
  `2026-09-13-secrets-inventory.md`, which previously omitted this credential
  entirely — which is how the exposure went unnoticed.
- **Out of scope, still open** (from the same audit, each a larger change): the
  `default` namespace has no NetworkPolicy; the Longhorn backupstore NFS export
  admits the pod CIDR read-write; this route has no HSTS.

## Gotchas for the next operator

- Invoke OpenBao as `nix run nixpkgs#openbao -- …`; there is no `bao` on `PATH`.
  The OIDC token is short-lived (1 h) — renew it before starting.
- The MariaDB client in the pod is `mariadb`, **not** `mysql` — `mysql` is not on
  the non-interactive `PATH` and fails with exit 127.
- In batch mode the client echoes a **failing** statement to stderr. Merge stderr
  carelessly and you will print the password you just tried to set. It happened
  once during this rotation; the value was regenerated and never used.
- ESO's `refreshInterval` is `10m`, but
  `kubectl -n default annotate externalsecret seafile-secret force-sync=$(date +%s) --overwrite`
  renders within seconds when a workload is down and you cannot wait.
- Reloader restarts **both** `seafile` and `seafile-mariadb` on a Secret change.
  The MariaDB restart is harmless — its `MYSQL_*` variables are init-only and the
  existing datadir keeps its users.
