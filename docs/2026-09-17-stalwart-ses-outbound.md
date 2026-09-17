# Stalwart outbound relay via Amazon SES

**Date:** 2026-09-17
**Scope:** make the Stalwart mail server (`namespace stalwart`, chart `charts/stalwart`,
image `v0.16.22`) able to deliver mail to remote domains, by relaying all remote-bound
messages through Amazon SES in `us-east-1`. Inbound is untouched: the MX record stays at
home and mail is still received directly.

## Why this was needed

The home ISP blocks outbound TCP **25 and 587**, so Stalwart's default direct-to-MX route
(`MtaRoute` `mx`) cannot deliver anything to a remote domain — it retries forever against a
black hole. Measured port matrix from inside the cluster: 25 blocked, 587 blocked,
**465 open**, 2525 open, 2465 open, 443 open.

SES was chosen because its classic SMTP endpoint is reachable on **465** (implicit TLS).
SES's newer *Mail Manager* ingress endpoint was rejected as unusable: it listens only on 25
and 587, both blocked here (verified unreachable on 25/465/587/2525). The dead Mail Manager
hostname remains in OpenBao as the unused `SES_SMTP_ENDPOINT` field.

## What changed

### 1. DNS: MAIL FROM MX (deSEC, outside this repository)

`bounce.m.2143.me` already had its SES SPF TXT record but **no MX**, which SES requires for
the bounce/complaint feedback channel. Added:

```
bounce.m.2143.me.  MX  10  feedback-smtp.us-east-1.amazonses.com.
```

Note the target: **`amazonses.com`**, not `amazonaws.com`. `feedback-smtp.us-east-1.amazonaws.com`
does not resolve (NXDOMAIN); the correct name is `feedback-smtp.us-east-1.amazonses.com`.
Because the identity uses *Behavior on MX failure: Reject message*, publishing a
non-resolving MX would have broken sending outright.

Mail DNS for `2143.me` is **not** managed here — it is configured at deSEC out of band, so
this record is not reproducible from a `git clone`. The `desec-io-dns` Secret in namespace
`cert-manager` (key `token`) can drive the API if it ever needs scripting; pass the token via
a curl config on stdin, never on a command line.

### 2. Credential: OpenBao → External Secrets → `Secret/stalwart/ses-smtp`

Values live in OpenBao at `consumers/data/john2143-com/stalwart/ses-smtp`
(`SES_SMTP_USER`, `SES_SMTP_PASS`). `workloads/secrets/stalwart-ses-smtp.yaml` renders them
into `Secret/ses-smtp` in namespace `stalwart`. No store or policy change was needed: the
`eso-read` policy already covers `consumers/data/*`.

### 3. Pod environment (`charts/stalwart/templates/statefulset.yaml`)

Two additions to the container's `env` list, both `optional: true`:

```yaml
- name: SES_SMTP_USER
  valueFrom:
    secretKeyRef: {name: ses-smtp, key: SES_SMTP_USER, optional: true}
- name: SES_SMTP_PASS
  valueFrom:
    secretKeyRef: {name: ses-smtp, key: SES_SMTP_PASS, optional: true}
```

`optional: true` is deliberate: it stops an ESO/ArgoCD sync-ordering race from wedging the
container in `CreateContainerConfigError`, which would take **inbound** mail down with it. A
missing variable surfaces later as an explicit Stalwart config error instead.

The pod template also gained `reloader.stakater.com/auto: "true"`, so a rotated credential
reaches the pod without a manual rollout. The pre-existing
`secret.reloader.stakater.com/reload` annotation only watched the TLS Secret.

### 4. The relay route and outbound strategy — stored in Stalwart, **not in Git**

This is the non-obvious part. The route and the routing strategy live in Stalwart's RocksDB
datastore and are **not** managed by ArgoCD. A datastore restore will not bring them back,
and nothing in this repository records them except this file. Reproduce them with these
three JMAP calls against `http://127.0.0.1:8080/jmap` from inside the pod, authenticating as
the administrator with a curl config built from `$STALWART_RECOVERY_ADMIN`:

```json
{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:MtaRoute/set",{"create":{"ses":{"@type":"Relay","name":"ses","description":"SES outbound relay (us-east-1)","address":"email-smtp.us-east-1.amazonaws.com","port":465,"protocol":"smtp","implicitTls":true,"authUsername":"$SES_SMTP_USER","authSecret":{"@type":"EnvironmentVariable","variableName":"SES_SMTP_PASS"}}}},"r"]]}
```

```json
{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:MtaOutboundStrategy/set",{"update":{"singleton":{"route":{"match":{"0":{"if":"is_local_domain(rcpt_domain)","then":"'local'"}},"else":"'ses'"}}}},"s"]]}
```

```json
{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Action/set",{"create":{"reload":{"@type":"ReloadSettings"}}},"r"]]}
```

Design notes:

- `authSecret` is the only field that can be an environment reference
  (`{"@type":"EnvironmentVariable","variableName":...}`), so the password never lands in the
  datastore. `authUsername` is a plain string and **is** stored literally — accepted
  deliberately.
- The `route` object is supplied whole because a JMAP property write replaces that property
  wholesale. Only `else` changed (`'mx'` → `'ses'`); the
  `is_local_domain(rcpt_domain) → 'local'` branch is preserved, so local delivery is
  untouched.
- `ReloadSettings` is mandatory: a registry write alone changes nothing in memory. A failed
  reload silently discards the change, so require `created.reload` and an empty
  `notCreated`.

## Verification

**Passed.** The `ses` route exists (`id jfca9ujsaaab`, `port 465`, `implicitTls: true`,
env-var secret) alongside the untouched `mx` and `local` routes, and
`MtaOutboundStrategy.route` reads `{"match":{"0":{"if":"is_local_domain(rcpt_domain)","then":"'local'"}},"else":"'ses'"}`.
`ReloadSettings` reported `created.reload` with nothing in `notCreated`. The `secrets` and
`stalwart` Applications were `Synced`/`Healthy` afterwards.

**The SES leg works.** From inside the pod, a full submission to
`email-smtp.us-east-1.amazonaws.com:465` using the OpenBao-sourced credential produced:

```
< 220 email-smtp.amazonaws.com ESMTP SimpleEmailService-...
< 250 Ok                     (EHLO)
< 334 Ok                     (AUTH challenge)
< 235 Authentication successful.
< 250 Ok                     (MAIL FROM)
< 250 Ok                     (RCPT TO)
< 354 End data with <CR><LF>.<CR><LF>
< 554 MAIL FROM domain not verified: DNS setup for MAIL FROM domain is invalid.
```

TLS, AUTH and envelope acceptance all work; only SES's own validation of the MAIL FROM
domain is outstanding. That MX record was published roughly forty minutes before this test,
and SES re-checks a MAIL FROM domain on its own schedule (AWS documents up to 72 hours; the
TTL is 3600). **Expect this 554 to clear on its own.** If it has not cleared a day later,
the record or the SPF TXT beside it is wrong — the SPF record is
`bounce.m.2143.me TXT "v=spf1 include:amazonses.com ~all"`.

**Inbound is externally reachable.** Checked from third-party nodes (check-host.net, TCP
connect to `108.56.153.222`): port 25 3/3 nodes, port 993 3/3, port 587 2/3 — the one
refusal was a single node, not a consistent block. Note that testing from the LAN is
misleading here: the router does not hairpin port 25, so LAN tests against the public IP
time out even though the path works from the internet.

**Verified end to end: Stalwart → SES, accepted.** A message submitted via JMAP
(`EmailSubmission/set`, account `k`, identity `c`) was routed by Stalwart to the relay and SES
accepted it. Tracer output:

```
queueName = "remote"
hostname = "email-smtp.us-east-1.amazonaws.com"     <- the `ses` route was selected
DEBUG SMTP EHLO / authentication / MAIL FROM (code 250) / RCPT TO (code 250)
INFO  Message delivered (delivery.delivered)        code = 250
INFO  Delivery completed
```

**Root cause of the `554`.** The `554 MAIL FROM domain not verified` did **not** clear with
time — it persisted for hours while the MX and SPF records were published and resolving from
independent resolvers. The cause was the *custom MAIL FROM domain* configured on the **domain**
identity `m.2143.me`: SES judged `bounce.m.2143.me`'s DNS invalid and rejected every message
whose envelope sender fell under it.

An interim workaround confirmed the rest of the chain was sound: verifying
`John2143@m.2143.me` as an SES **`EmailAddress` identity** produced a sender with no custom MAIL
FROM domain, which SES accepted. That also exercised the confirmation-link flow, which arrives
correctly in the mailbox.

**Fixed properly.** Setting the `m.2143.me` identity's MAIL FROM behavior back to the **default
MAIL FROM domain** in the SES console resolved it at the source, for every address in the domain.
Both spellings are now accepted, and a submission through Stalwart with a deliberately lowercase
envelope sender delivered:

```
MAIL FROM john2143@m.2143.me   ->  250 Ok        <- was 554 before the fix
MAIL FROM John2143@m.2143.me   ->  250 Ok
Stalwart: delivery.mail-from 250 / delivery.rcpt-to 250 / Message delivered 250
```

No casing constraint remains, so nothing in the mail path depends on how a client spells the
sender.

## Outstanding

- **SES production access.** In the sandbox only the mailbox simulator and already-verified
  addresses accept mail, so arbitrary recipients are still rejected. This is the last gate before
  the server can mail anyone.
- **`stalwart/stalwart-stalwart-env` is still a plain cluster Secret** outside OpenBao, as
  recorded in `docs/2026-09-13-secrets-inventory.md` §6. That gap predates this change and
  is deliberately not addressed here.

## Operating notes, learned the hard way

- **Never address account-scoped JMAP methods with the session's encoded account id.**
  Authenticating as administrator with `$STALWART_RECOVERY_ADMIN` produces a session whose
  own account (`d333333`) is a *different, empty* account from the mailbox account. Queried
  as `d333333`, `Mailbox/get` returns all-zero counts and `Identity/set` rejects every
  address with `E-mail address not configured for this account`, because that account has no
  addresses at all. Use the registry id — **`k`** — as `accountId` for `Email/set`,
  `EmailSubmission/set`, `Identity/set` and `Mailbox/get`. Getting this wrong cost hours and
  produced a phantom "server cannot send or receive" defect.
- **Mail that looks missing is usually in Junk.** Messages injected unauthenticated from
  `test@example.com` score as spam and are filed to Junk (`message-ingest.spam`,
  `mailboxId = [2]`). Check every mailbox before concluding delivery failed.
- **Logging: a stdout sink was added on 2026-09-17.** The pre-existing `Log` tracer
  (`x:Tracer/get`, id `iunqkacwaiab`) points at `/var/log/stalwart`, a directory that does
  **not** exist in the container, so it produces nothing — which is why the server had no
  output at all and `kubectl logs` was empty. A `Stdout` tracer at `info` now sends the same
  events to stdout, which is what made this change diagnosable. To chase something, raise it
  to `debug` and put it back afterwards (at `debug` it produced roughly 350 lines per minute
  under test load):

  ```json
  {"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Tracer/set",{"update":{"jfch0mneabac":{"level":"debug"}}},"t"]]}
  ```

  The inert `Log` tracer is left exactly as found. Removing the stdout sink entirely is
  `x:Tracer/set` with `{"destroy":["jfch0mneabac"]}`.
- **A submission identity exists** for the account (id `c`, `John2143@m.2143.me`). JMAP
  submission requires one, and it could not be created until the lowercase alias existed (see
  the mixed-case section below). `MtaStageAuth.mustMatchSender` means SMTP submission must
  authenticate as this account, and the account is SSO-only, so a client needs an app
  password rather than an account password. That gap was closed on 2026-09-17 — app password
  `iphone` ("iPhone Mail") exists on account `k`, and IMAPS login and SMTP submission were
  both verified with it. See the mail-stack audit section at the end of this document.

## Mixed-case identities: how they actually work

Stalwart's canonical form for an address is lowercase: `to_canonical_address()` lowercases both
parts, the SMTP path lowercases `MAIL FROM`/`RCPT TO` before indexing, and `sanitize_email`
lowercases a submitted identity. Every **admin-managed** write therefore forces lowercase —
verified by experiment on 2026-09-17:

| Attempt | Result |
|---|---|
| Create an account named `CaseProbe` | rejected: `primaryKeyViolation` against `caseprobe` (lowercased before the uniqueness check) |
| Send the rename `John2143` | stored as `john2143` |
| Add the alias `John2143` | stored as `john2143` |

**Only the OIDC directory can create a mixed-case account.** It writes the claim value straight
through, bypassing the validator — which is how `John2143@m.2143.me` exists at all. The same
path creates an account automatically whenever a login's `claimUsername` matches nothing, given
`claimUsername: preferred_username` and `usernameDomain: m.2143.me` on directory object
`iuukp10iaaqa`.

That combination is a trap: a mixed-case claim can never match a lowercase account, so **every
login mints a fresh duplicate account**. It happened twice on 2026-09-17 (accounts `j`, then `k`)
after a lowercase `john2143` account was created beside the original `John2143`.

A mixed-case account also **cannot create a JMAP identity**: `Identity/set` compares the
sanitised (lowercase) address against the account's raw address list and fails with
`E-mail address not configured for this account`. Without an identity there is no sending from
any JMAP client, and the same raw comparison drives `MtaStageAuth.mustMatchSender`.

### The recipe for a mixed-case user

1. **Let them log in first.** Do not pre-create the account — Portal/JMAP creation is forced
   lowercase and will not match the claim, which is what produces duplicates. The login creates
   `<Claim>@m.2143.me` with the claim's exact casing.
2. **Add the lowercase form as an alias:**

   ```json
   {"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Account/set",{"update":{"<account id>":{"aliases":{"0":{"enabled":true,"name":"<lowercase form>","domainId":"<domain id>"}}}}},"u"]]}
   ```

   `aliases` is a `List<EmailAlias>` keyed by **numeric index** — a name-keyed object is
   rejected with `Invalid key for object property`. With the lowercase form present, identity
   creation and `mustMatchSender` both pass, and mail addressed in any case reaches the account.
3. **Grant the role they need.** Directory accounts arrive as plain `User`; the Portal's
   administrative pages require `Admin`.
4. **Never rename that account afterwards.** A rename is lowercased, which breaks the SSO match
   and makes the next login mint a duplicate — exactly what happened on 2026-09-17. The fix was
   to delete the lowercase account, keep the directory-created mixed-case one, and put the
   lowercase form beside it as an alias.

The address list is unique on the canonical form, so the lowercase alias **requires that no
lowercase account already holds that address** — the two cannot coexist. That is why the original
`john2143` account had to be retired for `John2143` to become functional.

## Mail-stack audit (2026-09-17): bans, allow-list, client access

**Ban policy — current values, to be reproduced after a datastore restore.** On the
`x:Security` singleton the four ban *periods* are `86400000` ms (24 h) and the rates are
`abuseBanRate {35, 86400000}`, `authBanRate {100, 86400000}`, `loiterBanRate {150, 86400000}`
and `scanBanRate {30, 86400000}`. A `null` period does **not** mean "ban disabled" — it means
the ban never expires (`expires_at.unwrap_or(u64::MAX)`). That distinction is the whole
June–September outage class: 40 never-expiring `portScanning` records had accumulated, 26 of
them covering the cluster pod CIDR `10.42.0.0/16`, and Stalwart tests the ban list per
connection before the TLS handshake on every listener — so when the CNI handed a pod a
recycled address (`10.42.0.39`, `10.42.6.1`) the mail server refused its own cluster. All 40
were destroyed on 2026-09-17; the 8 correctly-expiring scanner bans were left in place. Note
the real boundary: the newest permanent record is 2026-09-14 and the oldest correctly
expiring one is 2026-09-16, so the period fix took effect that week — not on 2026-08-11 as
an earlier note in this file assumed.

**Allow-list — `x:AllowedIp/get`, eight ranges, each with `expiresAt: null`.** `10.0.0.0/8`
(LAN plus pod CIDR `10.42.0.0/16` and service CIDR `10.43.0.0/16`), `172.16.0.0/12`,
`192.168.0.0/16`, `100.64.0.0/10`, `127.0.0.1`, `::1`, `fd00::/8`, `fe80::/10` — the same
trust set as the cluster's `lan-only` middleware. The allow-list is a hard veto:
`is_ip_blocked()` ends in `&& !is_ip_allowed(ip)`, so none of these ranges can be banned
again. `AllowedIp.address` accepts CIDRs, so a wider range is one record.

**`x:Http.useXForwarded` is now `false`.** With it `true` — and this version has no
trusted-proxy list for HTTP — the HTTP layer took the client address from whatever
`X-Forwarded-For` the caller sent, and that address decided both `is_ip_blocked` and
`block_ip`. Any client could therefore evade its own ban, or have a *permanent* ban written
against an arbitrary address. Accepted trade-off: Stalwart's own anonymous rate limit now
buckets by Traefik's pod address. Real-client policy still lives in the CrowdSec bouncer and
the rate-limit middlewares in `workloads/stalwart/security-middlewares.yaml`, which see true
client IPs because the mail Service uses `externalTrafficPolicy: Local`. Do not re-enable the
flag on its own.

**Catch-all.** `Domain.catchAllAddress` stays `all@m.2143.me`, and account `k` now carries
aliases at index `0` = `john2143` (lowercase canonical form), `1` = `all` (catch-all
destination) and `2` = `dmarc` (DMARC aggregate reports). `aliases` is a `List<EmailAlias>`
keyed by **numeric index** and a write replaces the whole map, so every future edit must
re-send all three indices. Consequences, recorded so neither is read as a fault later:
`RCPT TO` is accepted for any `<anything>@m.2143.me` and delivered to this mailbox, and
`reportAddressUri` is `mailto:postmaster`, so `postmaster@m.2143.me` lands there too.

**Reload discipline.** `x:Http`, `x:Security` and `x:MtaStageAuth` are settings singletons
patched at id `"singleton"` and take effect only after
`x:Action/set {"@type":"ReloadSettings"}`; `x:BlockedIp` and `x:AllowedIp` are registry
objects and need `{"@type":"ReloadBlockedIps"}`. A write without its reload changes nothing
in the running process.

**Client access, verified 2026-09-17.** App password `iphone` ("iPhone Mail") on account `k`
with `permissions: {"@type":"Inherit"}` and no IP restriction. The pre-existing password
`home thunderirda` (id `b`, expires 2027-11-26) was left untouched — it predates this work
and was not created here. Verified: IMAPS `a LOGIN "John2143@m.2143.me" <app password>` →
`OK`; SMTP `AUTH PLAIN` → `235`, `MAIL FROM` → `250`, `RCPT TO` → `250`. A message addressed
to `nobody-here@m.2143.me` was accepted *and delivered* (to Junk, correctly — it came from an
unauthenticated sender), where before the alias existed it was accepted and then bounced.
Client settings: IMAP `m.2143.me:993` SSL/TLS, SMTP `m.2143.me:587` STARTTLS. Do not use
`imap.m.2143.me` or `smtp.m.2143.me` — the `*.2143.me` certificate matches one label only.

**Obstacle for a client on the home LAN (found 2026-09-17).** The LAN resolver answers
`m.2143.me` → `192.168.6.11`, which is the *web* load balancer and serves only 443; the mail
Service is `192.168.6.13` and serves 25/587/993. A mail client on the home network therefore
cannot reach IMAP or submission under the name `m.2143.me`, and the public address is not
hairpinned for those ports from inside. This cannot be fixed by changing the LAN answer while
the same name also serves the SPA — it resolves once the webmail routing plan moves the SPA
to `stalwart.ts.2143.me` and `m.2143.me` is mail-only.

**Observability caveat.** The mail pod runs on node `arch`. At 2026-09-17T19:09:56Z log
collection from that node stopped for **every** pod on it: `kubectl logs` times out for all of
them while pods on `closet` and `nas` answer in under a second, and nothing from `arch` has
reached Loki since. It is a kubelet log-path defect on that node, not a mail defect — the
server itself kept serving throughout (JMAP and SMTP both answered afterwards). Consequences
until it is fixed: `kubectl logs` is unusable for this pod, and the `stalwart-ip-blocked`
alert rule below cannot fire because its only source is those log lines. The remedy is a
kubelet restart on `arch`.

**Still outstanding, all operator work outside this cluster's configuration.**
SES production access for `us-east-1`; Easy DKIM on the verified `m.2143.me` identity; DMARC
reporting (`_dmarc.m.2143.me` → `v=DMARC1; p=none; rua=mailto:dmarc@m.2143.me`) plus the SRV
and TLS-RPT records set out in the audit plan; and asciinema's sender identity
`hello@terminals.john2143.com`, which is not an SES-verified identity, so its mail is
rejected at SES regardless of sandbox status.
