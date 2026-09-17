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

**Not verified end to end through Stalwart.** See below.

## Outstanding

- **SES production access.** Until AWS grants it, only the mailbox simulator
  (`success@simulator.amazonses.com`) accepts mail; real recipients are rejected.
- **SES MAIL FROM re-verification** (the 554 above) — self-clearing, see above.
- **`stalwart/stalwart-stalwart-env` is still a plain cluster Secret** outside OpenBao, as
  recorded in `docs/2026-09-13-secrets-inventory.md` §6. That gap predates this change and
  is deliberately not addressed here.
- **A mixed-case account address breaks sending and local delivery** — unrelated to SES,
  found while verifying this change. See the next section; it is the reason the relay could
  not be exercised end to end.

## The mixed-case account blocker (not an SES problem)

The only account is `John2143@m.2143.me` (`x:Account/get` → `id h`, `name John2143`). Stalwart
canonicalises addresses to **lowercase** in every path that compares them against the
account's stored address list, but the stored list keeps the account name's original case.
The result is that a mixed-case account fails three separate checks:

| Path | Behaviour |
|---|---|
| `mustMatchSender` (SMTP submission) | MAIL FROM is lowercased (`address_lcase`) and compared against the account's raw addresses; mismatch → `501 You are not allowed to send from this address` |
| JMAP `Identity/set` | the submitted address is lowercased by `sanitize_email` and compared against the raw addresses; mismatch → `invalidProperties: E-mail address not configured for this account` |
| Local delivery | the recipient is lowercased before lookup, then matched case-sensitively against the account's addresses; mismatch → `Mailbox not found` (permanent failure, DSN to the sender) |

Evidence: `Identity/set` is rejected for **both** `John2143@…` and `john2143@…`; and two test
messages injected into the SMTP listener for `John2143@m.2143.me` and `john2143@m.2143.me`
were both accepted (`250`) and then delivered **nowhere** — no mailbox gained a message and
the queue stayed empty.

Consequence: the account can currently neither send nor receive. Mail to `m.2143.me`
reaching the server is accepted and then fails at delivery. This is a **pre-existing**
configuration defect, independent of the SES relay.

Two fixes, both account-level:

1. **Add a lowercase alias** (`john2143@m.2143.me`) to the account. Aliases are indexed for
   the email lookup and included in the account's address list, so this satisfies all three
   checks while leaving the primary address — and SSO login — exactly as they are. Least
   invasive.
2. **Rename the account** to `john2143`. Makes the canonical form and the stored form
   identical, but changes the account's primary address and has to be reconciled with Pocket
   ID, where the identity may still assert the mixed-case address.
