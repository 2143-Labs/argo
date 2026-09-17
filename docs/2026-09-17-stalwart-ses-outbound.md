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

**Verified end to end through Stalwart, up to SES's own DNS check.** A message submitted via
JMAP (`EmailSubmission/set`, account `h`, identity `b`) was routed by Stalwart to the relay
and handed to SES. The tracer output for that attempt:

```
queueName = "remote"
to = ["success@simulator.amazonses.com"]
hostname = "email-smtp.us-east-1.amazonaws.com"     <- the `ses` route was selected
DEBUG SMTP EHLO command / SMTP authentication / SMTP MAIL FROM command / SMTP RCPT TO command
INFO  Message rejected by remote server (delivery.message-rejected)
        code = 554
        details = "MAIL FROM domain not verified: DNS setup for MAIL FROM domain is invalid."
```

Route selection, implicit TLS, SMTP AUTH and the whole envelope exchange against SES work.
The only failure left is SES's own validation of the `bounce.m.2143.me` MAIL FROM domain. That
MX was published about fifty minutes before this attempt and both records are confirmed
present by an independent resolver (MX `10 feedback-smtp.us-east-1.amazonses.com`, TXT
`v=spf1 include:amazonses.com ~all`), so this is SES reading a cached view of the zone rather
than a configuration error. **Expect it to clear on SES's next check** (the record TTL is
3600). Watch the `m.2143.me` identity's MAIL FROM domain status in the SES console.

## Outstanding

- **SES production access.** Until AWS grants it, only the mailbox simulator
  (`success@simulator.amazonses.com`) accepts mail; real recipients are rejected.
- **SES MAIL FROM domain validation** — the 554 above, self-clearing.
- **`stalwart/stalwart-stalwart-env` is still a plain cluster Secret** outside OpenBao, as
  recorded in `docs/2026-09-13-secrets-inventory.md` §6. That gap predates this change and
  is deliberately not addressed here.

## Operating notes, learned the hard way

- **Never address account-scoped JMAP methods with the session's encoded account id.**
  Authenticating as administrator with `$STALWART_RECOVERY_ADMIN` produces a session whose
  own account (`d333333`) is a *different, empty* account from the mailbox account. Queried
  as `d333333`, `Mailbox/get` returns all-zero counts and `Identity/set` rejects every
  address with `E-mail address not configured for this account`, because that account has no
  addresses at all. Use the registry id — **`h`** — as `accountId` for `Email/set`,
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
- **A submission identity now exists** for the account (id `b`, `john2143@m.2143.me`), which
  JMAP submission requires. Nothing has mail clients sending yet: `MtaStageAuth.mustMatchSender`
  means SMTP submission must authenticate as this account, and the account is SSO-only, so an
  app password is still needed before a client such as the iPhone can send.

## Account names are canonicalised to lowercase

Stalwart treats lowercase as the canonical form of an address: `to_canonical_address()`
lowercases both parts, the SMTP path lowercases `MAIL FROM`/`RCPT TO` before indexing, and
`sanitize_email` lowercases a submitted identity. The Account object's `name` is written
through `StringValidator::EmailLocalPart` (the `Property::Name` patch arm in the registry
schema), which applies `sanitize_email_local` as a **replace** — so Stalwart itself lowercases
account names on write, on create as well as on update.

Consequences worth knowing:

- **Every new account is canonicalised automatically.** Creating a user named `CaseProbe`
  while `caseprobe` exists fails with `primaryKeyViolation` on `email` — the candidate name is
  lowercased before the uniqueness check. `CaseProbe@m.2143.me` and `caseprobe@m.2143.me` are
  the same mailbox by construction, for every user, with no per-account work.
- **The existing account was normalised** so that the stored form matches the canonical form
  that every comparison uses: `John2143` was written back through the validator and is now
  stored as `john2143@m.2143.me`. Mail addressed in any case still reaches it. Reverting is
  the same one-property patch with any capitalisation you prefer, but Stalwart will store the
  lowercase form regardless.

