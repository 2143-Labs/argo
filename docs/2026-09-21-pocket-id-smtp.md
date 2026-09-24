# Pocket ID SMTP and email features via Scaleway TEM

**Date:** 2026-09-21
**Scope:** `au.2143.me` (Pocket ID `v2.14.0`, namespace `pocket-id`)

## Why

`au.2143.me` is this cluster's OIDC provider — Grafana, Seafile, ArgoCD,
headscale, Bulwark and Stalwart all authenticate through it — and it had no SMTP
configured and every email feature disabled. It could not send verification
links, new-device login notifications, API-key expiry warnings, or
admin-issued one-time access codes.

## What changed

**One page, entered by hand, nothing in Git.** Everything below is on
`https://au.2143.me/settings/admin/application-configuration`.

### 1. The SMTP transport

| Field | Value |
|---|---|
| SMTP Host | `smtp.tem.scaleway.com` |
| SMTP Port | `587` |
| SMTP User | the Scaleway **Project ID** (`TEM_USERNAME` in the vault) |
| SMTP Password | the API key's **secret key** (`API_SECRET_KEY`) |
| SMTP From | `auth@m.2143.me` |
| SMTP TLS Option | **StartTLS** |
| Skip Certificate Verification | off |

The credential is the same one Stalwart's relay and asciinema use —
`consumers/john2143-com/stalwart/scaleway-tem-smtp` — not a Pocket ID-specific
key. The mapping is opaque and is the thing most likely to be got wrong:
**username = the Project ID, password = an API key's secret key**
(`2026-09-20-stalwart-tem-outbound.md:51-54`).

`auth@m.2143.me` is required rather than merely preferred: TEM only accepts
senders at verified domains, and only `m.2143.me` carries TEM records.
`john2143.com` and `terminals.john2143.com` cannot be used here.

### 2. The five feature switches, and what each one actually sends

| Switch | Email | Fires |
|---|---|---|
| Email Login Notification | `login-with-new-device`, "New device login with 2143 Labs" | automatically, on a **passkey** sign-in from a new (IP + User-Agent) pair |
| Email Verification | `email-verification`, "Verify your 2143 Labs email address" | only when the user presses **Send Email** in their own account |
| Email Login Code from Admin | `one-time-access`, "Login Code" | when an administrator presses **Send Email** in a user's login-code dialog |
| API Key Expiration | `api-key-expiring-soon`, `API Key "<name>" Expiring Soon` | automatically, once, when a key enters its final 7 days — checked daily at 00:00 ± 2 min |
| Email Login Code Requested by User | `one-time-access`, "Login Code" | user-requested from the login page — **left off** |

Three of these are narrower than their labels suggest, and the difference
matters when trying to exercise them.

**Login Notification is passkey-only.** It has exactly one call site —
`backend/internal/webauthn/service.go:312`, inside `VerifyLogin`, the WebAuthn
flow — and it is gated on `count <= 1` where `count` is the user's prior
`SIGN_IN` audit logs for the same `(ip_address, user_agent)` pair
(`service/audit_log_service.go:86-103`), which is where the "new device" framing
comes from. Signing in with a **login code does not send it**, and there is no
password sign-in in Pocket ID for it to cover.

The "already seen" memory is bounded by the audit-log retention window, which
this deployment sets to **90 days** (`AUDIT_LOG_RETENTION_DAYS: "90"` in
`workloads/pocket-id/configmap.yaml`; it is read by `common.EnvConfig` and so is
genuinely live, unlike the `SMTP_*` variables). A device seen 91 days ago is a
stranger again and its next sign-in notifies. `TRUST_PROXY: "true"` means the
recorded address is the real client IP forwarded by Traefik, so changing
networks is enough to look like a new device.

**API Key Expiration is a cron job, not an event.** `apikey/expiry_job.go` runs
`0 0 * * *` with a 2-minute jitter, lists keys that have entered their final
7 days, and marks each one sent so it never repeats. There is no way to trigger
it on demand.

**Email Verification has no admin variant.** The only route is
`POST /api/users/me/send-email-verification`, which mails the *authenticated
user's own* address; an administrator cannot send one to anyone else. The form's
own description claims it fires "when they sign up or change their email
address", which the code does not do — nothing sends it but a user's request.

**Every message goes to a stored address: your own, or a registered user's.**
There is no recipient field anywhere. The test email goes to whoever is signed
in, the verification email to the requester, and the login code to the target
user's `Email` column. Pocket ID is therefore not usable as a general mail
sender — mailing an arbitrary third party would mean giving a user record that
address, which also grants a login identity.

**Nothing throttles these here.** Every limiter is registered through
`RateLimitMiddleware.Add()`, and `middleware/rate_limit.go:76-80` turns that into
a passthrough whenever `DISABLE_RATE_LIMITING` is set — which this deployment
does, to `"true"` (`workloads/pocket-id/configmap.yaml`, on the grounds that
Traefik already throttles the public surface). The source defaults of 2
verification emails per 10 minutes, and the limits on the login-code endpoints,
are therefore **not in effect**. The admin send-login-code route carries no
limiter even when they are: `onetimeaccess/module.go` guards it with `auth`
alone.

The last one stays off deliberately: the app's own description warns it
"significantly reduces security as anyone with access to the user's email can
gain entry", and the chosen scope is admin-initiated codes only.

**Require Email Address** and **Emails verified by default** were left
untouched.

### 3. Why this is not in Git — the environment variables are inert

This is the part that would otherwise be re-derived painfully, and the reason
the obvious GitOps reflex silently does nothing here.

Pocket ID reads `SMTP_*` and `EMAIL_*` from the environment **only** when
`UI_CONFIG_DISABLED=true` (`backend/internal/appconfig/service.go`). `NewService`
calls `loadDbConfigFromEnv()` — the sole reader of those variables — exclusively
in that branch, and `GetConfig` returns `s.envConfig` only when
`UiConfigDisabled` is set. This deployment sets `UI_CONFIG_DISABLED: "false"`
(`workloads/pocket-id/configmap.yaml:24`) and the live app reports
`uiConfigDisabled=false`, so configuration is read from the DB-backed
`AppConfig` actor state instead.

Consequence: adding `SMTP_HOST` or `EMAIL_VERIFICATION_ENABLED` to the ConfigMap
or a Secret would appear in the container's environment and change nothing —
the worst kind of failure, because `env | grep SMTP_` looks like proof that it
worked. **`workloads/pocket-id/configmap.yaml` and `deployment.yaml` are
unchanged by this work.**

Flipping `UI_CONFIG_DISABLED=true` to make the env path live is the alternative
and is rejected: it makes *every* app-config key env-sourced, and three live
values differ from the source defaults in `getDefaultConfig()`, so they would
silently revert — `appName` `2143 Labs` → `Pocket ID`, `accentColor`
`oklch(0.6 0.15 180)` → `default`, `allowUserSignups` `open` → `disabled`.

### 4. Message bodies are not configurable

The five templates are compiled into the binary from
`backend/resources/email-templates/` via `//go:embed`
(`backend/resources/files.go`), and the subjects are literal strings in
`backend/internal/email/templates.go` with `AppName` substituted. Nothing
overrides them — no environment variable, no config key, no mounted path. The
page governs only *whether* a message is sent. Changing wording would mean
building a custom image.

### 5. Why 587 + StartTLS

StartTLS on 587 is the combination both of the cluster's other TEM consumers
already use successfully, and TEM presents a valid chain, so
skip-certificate-verification stays off.

## Verification

Transport probed directly, from a workstation and from node `big`:

| Check | Result |
|---|---|
| `smtp.tem.scaleway.com:587` | offers `STARTTLS`; upgrades to **TLSv1.3**; advertises `AUTH` after upgrade |
| `:2587` | identical |
| `:465`, `:2465` | TCP open, implicit-TLS handshake completes, `220 … ESMTP Service Ready` |

**This corrects a claim in `2026-09-20-stalwart-tem-outbound.md`**, which had
recorded 465 and 2465 as timing out and concluded from that "**Only 587 is
reachable**". They are not blocked, and that doc is corrected in place alongside
this one. What looks like a timeout is a *plaintext probe against an
implicit-TLS port*: the server waits for a TLS ClientHello and never volunteers
a banner. Measured side by side — 587 greets in the clear in 0.21 s, while 465
stays silent indefinitely and then answers normally once TLS is spoken. The same
doc's own closing note was the clue that went unread: the SES predecessor's
reachable port was 465, so 465 was reachable then too. The 587 + StartTLS choice
stands on its own merits; it just was not forced by a blocked port.

DNS, confirmed by direct query rather than assumed:

- `78d3b111-0472-42fe-bf80-ca1d2c57b2b6._domainkey.m.2143.me` publishes a
  2048-bit RSA DKIM key. The selector is character-for-character the Project ID
  used as the SMTP username — a collision that makes a correct credential look
  like a copy-paste error and has already caused one misdiagnosis
  (`2026-09-20-stalwart-tem-outbound.md:225-231`).
- `m.2143.me` TXT is `v=spf1 mx include:_spf.tem.scaleway.com -all`.

Configuration, read back from the app rather than from the form:

| Key | Before | After |
|---|---|---|
| `emailVerificationEnabled` | `false` | **`true`** |
| `emailOneTimeAccessAsAdminEnabled` | `false` | **`true`** |
| `emailOneTimeAccessAsUnauthenticatedEnabled` | `false` | `false` |

```bash
curl -s https://au.2143.me/api/application-configuration \
  | jq -r '.[] | "\(.key)=\(.value)"' | sort
```

Only these three are readable without authentication — they are the only
app-config keys marked `public:"true"`. Login-notification and API-key-expiry
are not public, and the SMTP fields are not exposed at all, so the five SMTP
values could not be read back and were **not** independently confirmed; the
delivery test below is the evidence for them.

The full-replace hazard did **not** bite. `PUT /api/application-configuration`
is not a patch — `AppConfigModel.Replace()` resets every property absent from
the payload, and any property sent empty, to its source default, so a partial
payload would have silently rescinded unrelated settings. All three
non-default values are intact:

| Key | Expected | Observed |
|---|---|---|
| `appName` | `2143 Labs` | `2143 Labs` |
| `accentColor` | `oklch(0.6 0.15 180)` | `oklch(0.6 0.15 180)` |
| `allowUserSignups` | `open` | `open` |

The test email was delivered to the signed-in administrator's own address.
**This was observed by the operator, not inspected here** — that mailbox is
external, so the `From:` header and the DKIM `d=` value were not read from the
message itself; the records above are DNS-side corroboration only. SPF is
expected to be stamped by TEM's own envelope domain and therefore unaligned,
which is the known shape of this path
(`2026-09-20-stalwart-tem-outbound.md:319-320`), not a fault.

Nothing restarted and nothing else was sent:

```
pocket-id-7d98d564c8-mlfgp   1/1   Running   0   4d3h   big
```

The same pod, 0 restarts, an age older than the change. No restart is needed
because the emailer resolves SMTP **per delivery**
(`backend/internal/email/module.go:smtpConnString`). No verification mail went
out — that feature sends nothing until a user presses **Send Email**.

Authentication is unaffected, as expected from a change that touches no
container, no Secret and no manifest: `https://au.2143.me/.well-known/openid-configuration`
still serves, and the pod was never replaced.

## State left behind

| Thing | State |
|---|---|
| Mail configuration | Pocket ID's SQLite DB (`/app/data/pocket-id.db`, `AppConfig` actor state) — **not reproducible from the manifests** |
| SMTP credential | Shared with Stalwart's relay and asciinema; held twice — in the vault and in Pocket ID's form |
| Verification emails | Feature enabled; nothing is sent until someone presses **Send Email** |
| Login Code Requested by User | Off, deliberately |
| Require Email Address, Emails verified by default | Untouched |
| `configmap.yaml`, `deployment.yaml`, Secrets | Unchanged |

**A from-scratch restore must re-enter the five SMTP fields by hand.** ArgoCD
does not manage them, the container's environment does not carry them, and there
is no config file to copy. Restoring the PVC restores them; rebuilding without
it does not.

**Rotation is coupled.** Because Pocket ID shares the cluster's TEM key, a future
rotation has to be applied in three places that know nothing about each other:
the vault, the two `ExternalSecret`-rendered Secrets, and Pocket ID's SMTP
Password field. Missing the last one breaks sign-in mail while the rest of the
cluster keeps sending.

Two things remain unconfirmed and should not be asserted:

- **Whether the SMTP password is encrypted at rest.** Grepping the DB file for a
  known non-secret value returns nothing, which is consistent with encryption
  *or* with compression; the two were never distinguished.
- **The `m.2143.me` catch-all.** Asserted by
  `2026-09-20-stalwart-tem-outbound.md:29-31` but never independently confirmed,
  so it is not known that a reply to `auth@m.2143.me` reaches the admin mailbox.

## Notes on method

- **Do not paste `/api/application-configuration/all` into a transcript.** While
  UI config is enabled it returns secrets, including the SMTP password, in
  plaintext.
- **Use the form, never a hand-rolled `PUT`.** The full-replace semantics above
  are the reason; the UI form submits every field.
- **A `535` from TEM means the key is not permitted to send**, not a wrong
  password or username. Sending needs `TransactionalEmailEmailSmtpCreate`; a
  policy with read/domain permission alone authenticates cleanly and then
  refuses (`2026-09-20-stalwart-tem-outbound.md:233-243`).
- **To inspect Pocket ID's internals, read the tagged source**
  (`raw.githubusercontent.com/pocket-id/pocket-id/v2.14.0/…`), not the
  container binary — each `grep` pass over the binary costs 30-120 seconds and
  a struct-tag search of it produced an incomplete list that led to a wrong
  conclusion about which settings have environment variables.
