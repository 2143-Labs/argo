# Stalwart outbound relay via Scaleway TEM

**Date:** 2026-09-20
**Supersedes:** `2026-09-17-stalwart-ses-outbound.md`
**Status:** implemented and **verified end to end**. Stalwart's relay and
asciinema's own submission both deliver through Scaleway TEM, and both mail
paths score 10/10 with SPF, DKIM and DMARC passing. What remains is outside the
cluster: the OpenBao entry and the AWS SMTP credential, both listed at the end.

**Scope:** move every outbound path off Amazon SES and onto Scaleway
Transactional Email (TEM) in `fr-par`. Two senders are involved: Stalwart's own
relay (`namespace stalwart`, chart `charts/stalwart`, image `v0.16.22`) and
asciinema's direct SMTP submission (`namespace default`). Inbound is untouched:
the MX record stays at home and mail is still received directly.

## Why

SES never left its sandbox — production access was requested and refused — so
nothing real ever delivered through it. The `ses` route and its two
`SES_SMTP_*` environment variables were therefore dead weight with a live,
unused credential attached. TEM replaces it end to end.

Two measured constraints shape the design:

- **587 + STARTTLS is the path in use.** `smtp.tem.scaleway.com` answers on
  25, 587, 2587, 465 and 2465 from this network.

  **Corrected 2026-09-21.** This bullet previously stated that the implicit-TLS
  ports "465 and 2465 both time out" and concluded "**Only 587 is reachable**".
  That was a **probe artifact, not a blocked port**: both accept TCP and
  complete an implicit-TLS handshake returning
  `220 smtp.tem.scaleway.com ESMTP Service Ready`, from the workstation *and*
  from the cluster. A *plaintext* probe against an implicit-TLS port hangs —
  the server waits for a TLS ClientHello and never volunteers a banner
  (measured side by side: 587 greets in the clear in 0.21 s, 465 stays silent
  indefinitely and then answers normally once TLS is spoken). The note below
  was the clue that went unread: the SES predecessor's reachable port was 465,
  so it was reachable then too. StartTLS on 587 still stands as the chosen
  path; it was simply not forced by a blocked port.
- **TEM only accepts senders at verified domains.** `john2143.com` carries no
  TEM records, so asciinema's `From` moves to `terminals@m.2143.me`.
  `m.2143.me` has a catch-all, so replies still reach the same mailbox.

## What changed

### 1. Credential: OpenBao → External Secrets → `Secret/tem-smtp` (both namespaces)

Source of truth is OpenBao at `consumers/data/john2143-com/stalwart/scaleway-tem-smtp`
(four keys: `TEM_SMTP_SERVER`, `TEM_USERNAME`, `API_ACCESS_KEY_ID`,
`API_SECRET_KEY`). Two `ExternalSecret`s render it, because a Secret does not
cross namespaces:

| File | Namespace | Secret |
|---|---|---|
| `workloads/secrets/stalwart-tem-smtp.yaml` | `stalwart` | `tem-smtp` |
| `workloads/secrets/default-tem-smtp.yaml` | `default` | `tem-smtp` |

Both use the `dataFrom.extract` form, so the Secret's key names are the vault's
verbatim. `creationPolicy: Owner`, `refreshInterval: 10m`, `ClusterSecretStore`
`openbao` — identical to the pair they replace.

**The SMTP credential mapping is opaque and is the thing most likely to be got
wrong.** Scaleway documents it as *username = the Project ID of the project the
TEM domain was created in, password = the secret key of an API key that has TEM
permissions*:

| SMTP field | vault key |
|---|---|
| username | `TEM_USERNAME` |
| password | `API_SECRET_KEY` |

`TEM_SMTP_SERVER` and `API_ACCESS_KEY_ID` are not consumed by either consumer.

**Expect `tem-smtp` to need a manual rollout.** Reloader does not fire on the
first *creation* of a Secret, and that has already cost this cluster one
debugging session. Here the pod template changed in the same commit, so the
rollout happened for that reason instead.

### 2. Pod environment (`charts/stalwart/templates/statefulset.yaml`)

```yaml
- name: TEM_SMTP_USER
  valueFrom:
    secretKeyRef: {name: tem-smtp, key: TEM_USERNAME, optional: true}
- name: TEM_SMTP_PASS
  valueFrom:
    secretKeyRef: {name: tem-smtp, key: API_SECRET_KEY, optional: true}
```

`optional: true` is deliberate and is the lesson of the SES change: it stops an
ESO/ArgoCD sync-ordering race from wedging the container in
`CreateContainerConfigError`, which would take **inbound** mail down with it. A
missing variable surfaces later as an explicit Stalwart config error instead —
and it does: see the reload trap below.

### 3. asciinema (`workloads/asciinema/deployment.yaml`)

| Variable | Value |
|---|---|
| `SMTP_HOST` | `smtp.tem.scaleway.com` |
| `SMTP_PORT` | `587` |
| `SMTP_TLS` | `always` (unchanged — this is gen_smtp's STARTTLS mode) |
| `SMTP_AUTH` | `always` (unchanged) |
| `SMTP_USERNAME` | `secretKeyRef tem-smtp/TEM_USERNAME` |
| `SMTP_PASSWORD` | `secretKeyRef tem-smtp/API_SECRET_KEY` |
| `MAIL_FROM_ADDRESS` | `terminals@m.2143.me` |

The comment block was rewritten. It previously claimed "25 and 587 are silently
dropped by the home gateway"; **that is wrong** — 587 was measured open from
this network twice, and it is now the port this deployment depends on.

### 4. The relay route and the outbound strategy — stored in Stalwart, **not in Git**

Both live in Stalwart's RocksDB and are not managed by ArgoCD. A datastore
restore loses them and nothing else in the repository remembers them, which is
the entire reason this section exists. Reproduce with these JMAP calls against
`http://127.0.0.1:8080/jmap` from inside the pod, authenticating as the
administrator.

**4.1 — the route.**

```json
{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:MtaRoute/set",{"create":{"tem":{"@type":"Relay","name":"tem","description":"Scaleway TEM outbound relay (fr-par)","address":"smtp.tem.scaleway.com","port":587,"protocol":"smtp","implicitTls":false,"allowInvalidCerts":false,"authUsername":"<Scaleway Project ID>","authSecret":{"@type":"EnvironmentVariable","variableName":"TEM_SMTP_PASS"}}}},"r"]]}
```

**`authUsername` holds the literal Project ID, not `$TEM_SMTP_USER`.** The SES
route was expected to authenticate through an env reference; the live object
actually stored the literal AWS access key id, so Stalwart does not expand
`$VAR` there. Using the literal was therefore the evidence-backed choice, and it
was taken from the pod's own `TEM_SMTP_USER` so the value never left the cluster
(the stored value was then confirmed byte-equal to the environment variable).

`implicitTls` is **`false`** because 587 is STARTTLS; the SES route's
`implicitTls: true` must not be copied. `authSecret` is the only field that
accepts an environment reference, so the password never lands in the datastore —
which matters because the nightly Longhorn backup of the mail volume captures
RocksDB.

**4.2 — the strategy.** A JMAP property write replaces that property whole, so
the `is_local_domain → 'local'` branch is carried over verbatim; supply `route`
only and leave `connection`, `schedule` and `tls` alone.

```json
{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:MtaOutboundStrategy/set",{"update":{"singleton":{"route":{"match":{"0":{"if":"is_local_domain(rcpt_domain)","then":"'local'"}},"else":"'tem'"}}}},"s"]]}
```

**4.3 — the reload, mandatory.** A registry write alone changes nothing in
memory. Require `created.reload` in the response and an empty `notCreated`.

```json
{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Action/set",{"create":{"reload":{"@type":"ReloadSettings"}}},"r"]]}
```

**The trap, and why the `ses` route is already gone.** The first reload attempt
was **rejected whole**:

```json
{"notCreated":{"reload":{"description":"Environment variable 'SES_SMTP_PASS' not found","objectId":{"id":"jfca9ujsaaab","object":"MtaRoute"},"type":"validationFailed"}}}
```

Removing `SES_SMTP_*` from the pod env (step 2) invalidated the `ses` route,
whose `authSecret` still pointed at `SES_SMTP_PASS` — and `ReloadSettings`
validates every route, so *no* reload could succeed, including the one carrying
the `tem` strategy. The plan ordered the `ses` route removal after verification;
the two steps are in fact coupled and the route had to be destroyed
(`x:MtaRoute/set` `destroy: ["jfca9ujsaaab"]`) before any reload would take. It
is a one-call step to recreate while the vault entry and DNS records survive,
which is why nothing else from SES was touched at this point. The strategy write
survived the failed reload in the registry and took effect on the next
successful one.

### 5. DNS: every SES record removed

Run after the relay was verified, across both zones. TEM's own records were left
alone and are confirmed still present. The full table, the two records the
plan's list did not mention, and the two-independent-method check are under
[DNS edits](#8-the-dns-edits-landed-on-both-authoritative-servers).

## Verification

**Passed.**

- **Env present, values never printed.** `env | grep -c '^TEM_SMTP_PASS='` → `1`,
  `TEM_SMTP_USER` → `1`, `^SES_SMTP_` → `0`, in the post-rollout pod.
- **Routes read back** as exactly `mx`, `local`, `tem` — `ses` gone.
  The `tem` object reads `address smtp.tem.scaleway.com`, `port 587`,
  `implicitTls false`, `protocol smtp`, `authSecret` =
  `EnvironmentVariable TEM_SMTP_PASS`, `authUsername` set.
- **Strategy read back** as
  `{"match":{"0":{"if":"is_local_domain(rcpt_domain)","then":"'local'"}},"else":"'tem'"}`
  with `connection`, `schedule` and `tls` byte-identical to before the change.
- **The reload took:** `created.reload` returned, `notCreated` empty. That is
  also positive proof that `TEM_SMTP_PASS` resolves in the pod — the same check
  is what rejected `SES_SMTP_PASS` a moment earlier.
- **Stored username identity:** the route's `authUsername` is byte-equal to the
  pod's `TEM_SMTP_USER`, and the `authSecret` names `TEM_SMTP_PASS`.
- **TLS to TEM is negotiated, and AUTH is only advertised after it.** From
  inside the pod against `smtp.tem.scaleway.com:587`, the session presented a
  valid certificate chain for `CN=smtp.tem.scaleway.com` (Let's Encrypt), and
  the post-TLS `EHLO` was the only one that advertised `AUTH`:

  ```
  250-Hello relay-check
  250-PIPELINING
  250-8BITMIME
  250-ENHANCEDSTATUSCODES
  250-CHUNKING
  250-AUTH PLAIN LOGIN
  250-SMTPUTF8
  250 SIZE 104857600
  ```

### The credential gap, and how it was resolved

The relay was dead on arrival, for a reason that had nothing to do with the
route, the username or the password's value. Recorded in full because two
separate red herrings cost real time and both will look plausible again.

**Symptom.** Submission stopped at `AUTH`, so `MAIL FROM`/`RCPT TO` were never
reached and no `554 MAIL FROM domain not verified` could be observed either way:

```
334 VXNlcm5hbWU6
334 UGFzc3dvcmQ6
535 5.7.8 Permission denied
```

**Red herring 1 — the username.** Every well-formed project UUID returns the
identical `535 Permission denied`, while a non-UUID such as `P1335383` is
rejected earlier with `Invalid credentials`. The relay checks the password's
permission as soon as the username is UUID-shaped, so **no amount of username
guessing distinguishes the correct project ID from an arbitrary UUID** while the
permission is missing. Two different UUIDs were tried; the reply was
byte-identical each time. The project ID was in the vault all along.

**Red herring 2 — a DKIM-selector collision.** The project ID,
`78d3b111-0472-42fe-bf80-ca1d2c57b2b6`, is also character-for-character the
published TEM DKIM selector (`78d3b111-…._domainkey.m.2143.me`). This was briefly
written up here as "the DKIM name was copied into the vault instead of the
project ID", and that was wrong; the operator confirms the string is the project
ID. The collision is worth knowing about precisely because it makes a valid
credential look like a copy-paste error.

**Root cause.** The API key's IAM policy did not grant the TEM *send* permission.
Scaleway splits sending across two permission sets —
`TransactionalEmailEmailApiCreate` for the REST `email_api:create` action and
**`TransactionalEmailEmailSmtpCreate`** for the SMTP relay — so a policy with
only read/domain permission authenticates cleanly and then refuses to send.
Measured against Scaleway's API with the correct project ID:

```
POST …/regions/fr-par/emails  {project_id: 78d3b111-…}
  -> permissions_denied   (resource: email_api, action: create)
```

One probe contradicted this and was itself the mistake: an empty `{}` body
returns argument-validation errors, because Scaleway validates arguments *before*
authorising. Only a well-formed body exposes the denial.

**Resolution.** Attaching the policy to the principal that owns the API key was
enough, and it applied to **every** key that principal holds — including the one
already in OpenBao. No vault change was needed after all: the stored credential
authenticated immediately afterwards, over both the SMTP relay and the REST API.
The route's literal `authUsername` was already correct and needed no write. The
project ID is confirmed independently by the domain object itself, which reports
`"project_id":"78d3b111-0472-42fe-bf80-ca1d2c57b2b6"` for `m.2143.me`.

**A `535` from this relay means "this key is not allowed to send"** — not a wrong
password and not a wrong username. Ask for the permission first.

### 4 and 6: the relay leg, and a real message through it

**The submission leg works, encrypted.** From inside the pod, against
`smtp.tem.scaleway.com:587`:

```
STARTTLS negotiated, chain verified for CN=smtp.tem.scaleway.com
EHLO relay-check  ->  250-…  250-AUTH PLAIN LOGIN …  250 SIZE 104857600
AUTH LOGIN        ->  334 VXNlcm5hbWU6
                      334 UGFzc3dvcmQ6
                  ->  235 2.0.0 Authentication succeeded
MAIL FROM:<terminals@m.2143.me>
                  ->  250 2.0.0 Roger, accepting mail from <terminals@m.2143.me>
RCPT TO:<…>       ->  250 2.0.0 I'll make sure <…> gets this
QUIT              ->  221 2.0.0 Bye
```

Two things only this proves: TLS is negotiated *before* credentials are offered
(`AUTH` is advertised only in the post-TLS `EHLO` — measured on 587, so the
second `EHLO` is expected), and there is **no** `554 MAIL FROM domain not
verified`, the failure mode that would otherwise surface only as silently
dropped mail.

**A real message then went through the whole chain.** Submitted off-site via
JMAP (`EmailSubmission/set`, account `k`, identity `d`); Stalwart's own trace
shows the route selection, the encryption and the delivery:

```
queue.authenticated-message-queued  from = "john2143@m.2143.me"
delivery.domain-delivery-start      domain = "srv1.mail-tester.com"
delivery.connect                    hostname = "smtp.tem.scaleway.com", remotePort = 587
delivery.start-tls                  version = "TLSv1_3", details = "TLS13_AES_128_GCM_SHA256"
delivery.delivered                  code = 250, "OK: queued as 009b94de-…"
delivery.completed
```

### 5: the app sends end to end, and the mail authenticates

Both senders were driven against a live receiving service, and both scored
**10/10 with "You're properly authenticated"** — that service's verdict that
SPF, DKIM and DMARC all pass for the message it actually received:

| Sender | Path exercised | Result |
|---|---|---|
| Stalwart relay | JMAP submission → `tem` route → TEM | 10/10, properly authenticated |
| asciinema | its own Swoosh/gen_smtp config → `smtp.tem.scaleway.com:587` | 10/10, properly authenticated |

asciinema was driven through its own shipped tool, `bin/send-test-email <addr>`
(`Asciinema.Emails.send_email(:test, …)`), so the test used the real Swoosh path
with the real container environment — `SMTP_HOST=smtp.tem.scaleway.com`,
`SMTP_PORT=587`, `SMTP_TLS=always`, `SMTP_AUTH=always`,
`From: terminals@m.2143.me` — rather than a simulation of it.

This substitutes a third-party authentication service for the plan's "check
Show original in Gmail": the same claim (DKIM and DMARC both pass), asserted by
an independent receiver rather than read off one mailbox. DKIM passes as
`d=m.2143.me`, the only signature available on this path — Stalwart's
`dkimManagement` stays `Manual` and TEM is the sole signer — and
`_dmarc.m.2143.me` is published as
`"v=DMARC1; p=none; rua=mailto:dmarc@m.2143.me"`. An *unaligned* SPF is expected
and is not a failure: TEM stamps its own envelope domain.

### 7: inbound is unaffected

Probed from third-party nodes, not from the LAN — the router does not hairpin
port 25, so LAN tests time out on a healthy path:

| Port | Result |
|---|---|
| 25 (SMTP) | connected from 4/4 probe nodes |
| 993 (IMAPS) | connected from 4/4 probe nodes |

### 8: the DNS edits landed on both authoritative servers

Neither zone carries an SES record any more. Verified two independent ways: by
`dig` against **both** nameservers, and by sweeping every rrset in both zones
through the deSEC API for the string `amazonses` — 0 of 39 rrsets in `2143.me`
and 0 of 10 in `john2143.com`.

| Zone | Record | Action |
|---|---|---|
| `2143.me` | `m` TXT | → `"v=spf1 mx include:_spf.tem.scaleway.com -all"` |
| `2143.me` | 3 × `<selector>._domainkey.m` CNAME | deleted |
| `2143.me` | `bounce.m` TXT and `bounce.m` MX | deleted |
| `2143.me` | `bounce.m.2143.me` MX | deleted (stray — see below) |
| `john2143.com` | apex TXT | → `"v=spf1 include:_spf.google.com ~all"` |
| `john2143.com` | 3 × `<selector>._domainkey` CNAME | deleted (not in the plan) |

`mx` is kept in the `m.2143.me` SPF deliberately: it authorises the mail host
itself and costs nothing, so a stray non-relayed send still passes. TEM's own
`78d3b111-…._domainkey.m` TXT and the `_spf.tem.scaleway.com` include are
confirmed still present on both nameservers.

**Two things the plan's list missed, removed anyway**, because the stated end
state is "no SES records left behind in DNS":

- **`john2143.com` carried three SES DKIM CNAMEs of its own** —
  `pltthyjasanpywgxxmaid3jshnr2apaq`, `gj3eqxsm4x4lvjqehypk3gwnnala6smk`,
  `cd4toduppdscd34tpr6a4tjij6ctgvez` — from the `john2143.com` SES domain
  identity described in the superseded document. Dead once SES is retired.
- **A stray `bounce.m.2143.me` MX rrset.** The superseded document records
  adding that name with a trailing dot, which deSEC stored as that literal
  subname, so the record landed *beside* `bounce.m` rather than over it. Both
  are gone.

**A false alarm worth recording, because it looks exactly like a survivor.**
Querying the deleted stray still returns
`bounce.m.2143.me.2143.me. CNAME 2143.me.` That is not a surviving record:
`2143.me` carries a wildcard `* CNAME 2143.me.`, and any nonexistent name in the
zone answers identically (`does-not-exist-xyz.2143.me` included). The name is
genuinely absent; the wildcard is answering.

**Two operational notes.** The deSEC token in `/dev/shm/desec.conf` is
**read-write**, not read-only as the plan assumed — the edits went through it.
And deSEC's API reports a change before the nameservers serve it: an early
DELETE batch reported success while three records were still listed, which is
why every write here is verified by an independent read afterwards rather than
by the status of the write itself.

### What this deliberately leaves untouched

- **`john@john2143.com`** (Google Workspace): the five `aspmx` MX hosts,
  `_dmarc`, and `gmail._domainkey` are untouched, and the SPF keeps
  `include:_spf.google.com`. Receiving and Workspace sending are both unaffected;
  the only change is that SES lost authorisation to send as the domain.
- **`john@2143.me`** (Proton): the `2143.me` apex is untouched entirely — MX
  `mail.protonmail.ch`, SPF `include:_spf.protonmail.ch` and the
  `protonmail-verification` TXT are byte-identical. Everything changed here lives
  under `m.2143.me`, `bounce.m.2143.me` or `._domainkey.m.2143.me`.
- **`m.2143.me` MX** stays `19 m.2143.me.`, so receiving for the mail domain is
  unchanged.

## State left behind

| Thing | State |
|---|---|
| `tem` MtaRoute | exists — `jfrumaziaaaa`, `smtp.tem.scaleway.com:587`, STARTTLS, env-var secret |
| `ses` MtaRoute | **destroyed** — it had to go for any reload to validate |
| outbound strategy `route` | `'tem'` |
| `Secret/tem-smtp` (stalwart, default) | exists, four keys |
| `SES_SMTP_*` env on the pod | removed |
| SES ExternalSecrets (git) | deleted; ArgoCD pruned `Secret/ses-smtp` from both namespaces |
| OpenBao `john2143-com/stalwart/ses-smtp` | **still present** — needs an admin token, see below |
| AWS SES SMTP credential | **still live** — needs AWS access, see below |
| SES DNS records | removed from both zones and confirmed on both nameservers |

### Two steps that need credentials this environment does not hold

- **Delete the OpenBao entry** `consumers/data/john2143-com/stalwart/ses-smtp`.
  `eso-read` is deliberately read-only and the vault's root token is held by the
  operator, so this is not a GitOps action. Nothing consumes it any more, so it
  is inert until then — but it is a live SES credential sitting in the vault.
- **Revoke the SES SMTP credential in AWS.** It is on the rotation backlog and
  is worthless once SES is gone, so revoking is the point of the exercise. No
  AWS CLI or credentials exist in this environment.

Rollback to SES is no longer a single strategy write — the `ses` route is gone
and its credential is unused — which is deliberate: SES is sandboxed, refused,
and not worth keeping a live credential for. Rollback from here is forward.

## Notes on method

- **The JMAP administrator path still works.** `$STALWART_RECOVERY_ADMIN` from
  `stalwart-stalwart-env` authenticates against `/jmap`, with the credential
  passed as a curl config on stdin so it never reaches argv or a transcript.
  Registry methods are addressed on the admin session's own account and read
  back correctly.
- **`x:MtaOutboundStrategy/get` needs `{"ids":["singleton"]}`.** A bare `get`
  returns `"list":[]`, which reads like "no strategy configured" and is not.
- **Registry/settings reload discipline is unchanged** (`x:Http`, `x:Security`,
  `x:MtaStageAuth` and `x:MtaOutboundStrategy` are singletons; `ReloadSettings`
  applies them; `BlockedIp`/`AllowedIp` need `ReloadBlockedIps`). The new thing
  learned here is that **`ReloadSettings` validates the whole registry** and
  rejects the entire batch on a single invalid object.
- **Two corrections the plan expected were not made, because re-measurement
  contradicts them.** The SES doc says `google._domainkey.john2143.com` is not
  published; the plan asserted it is, with a live RSA key. Queried against
  `ns1.desec.io`, `ns2.desec.org`, `1.1.1.1` and `8.8.8.8`, the name returns
  **nothing** — the document was right and no edit was warranted. Separately,
  the plan referred to a recorded finding that "2 of 3 SES DKIM selectors return
  an empty TXT"; no such text exists anywhere in this repository, so there was
  nothing to correct.
- **The `john2143.com` zone has moved on since the SES document was written**,
  and that document's "current state" block is stale in ways unrelated to this
  change: `_dmarc.john2143.com` now carries
  `"v=DMARC1; p=none; rua=mailto:dmarc@m.2143.me"`, and subdomains now resolve
  through a wildcard **A** rather than the `*.john2143.com` CNAME it describes.
  Neither was changed here.

## TEM's MIME allow-list — an outbound constraint found 2026-09-24

TEM does not carry every message. It validates the body at `BDAT` and **permanently
rejects (501 5.6.0) any message containing a MIME type outside a fixed list**, which
Scaleway publishes under "Technical limitations" at
`https://www.scaleway.com/en/developers/api/transactional-email`. That list contains no
`application/octet-stream`, `application/pgp-signature`, `application/pgp-keys`,
`application/pgp-encrypted`, `application/gzip` or `application/zip`, and it is **not
customisable** — there is no console or API setting that extends it.

Measured here (remote queue, 7-day window):

| When (UTC) | Sender → recipient | Size | Rejection |
|---|---|---|---|
| 2026-09-22T17:27:41Z | `noreply-dmarc@m.2143.me` → `mailauth-reports@google.com` | 1848 | `'application/gzip' is not allowed` |
| 2026-09-23T11:42:05Z | `John2143@m.2143.me` → `john@2143.me` | 2240 | `'application/octet-stream' is not allowed` |
| 2026-09-24T03:13:53Z | `John2143@m.2143.me` → `john@2143.me` | 2127 | same |
| 2026-09-24T11:35:23Z | `John2143@m.2143.me` → `john@2143.me` | 2290 | same |

The only TEM deliveries that have ever succeeded are the four mail-tester probes from
the verification above on 2026-09-20 — plain text, no attachments. **Every
`remote`-queue attempt since then has failed**, and the three PGP ones are the first
messages with crypto MIME, which is the part that matters.

### Why this is a design constraint, not a client bug

OpenPGP/MIME (RFC 3156) *requires* the parts TEM refuses: the encrypted payload is
`application/octet-stream`, the signature part is `application/pgp-signature`, the
version part is `application/pgp-encrypted`, and the webmail plugin's
`alwaysSendPubKey` attaches `${addr}_publickey.asc` as `application/pgp-keys`. So a
signed or encrypted message to an external recipient is rejected before it leaves —
which, with the Bulwark plugin's defaults (`defaultSign` and `defaultEncrypt` both
`true`), means every external message composed in the webmail.

Stalwart's own delivery is not at fault: the route is
`x:MtaOutboundStrategy.route` =
`{"match":[{"if":"is_local_domain(rcpt_domain)","then":"'local'"}],"else":"'tem'"}`,
so intra-domain mail never touches TEM and is unaffected by any of this.

### The routing hook, and what it cannot see

`route` is an expression over `MTA_QUEUE_RCPT_VARIABLE`
(`crates/registry/src/schema/enums.rs:3613`): `rcpt`, `rcpt_domain`, `recipients`,
`sender`, `sender_domain`, `priority`, `retry_num`, `notify_num`, `expires_in`,
`last_status`, `last_error`, `queue_name`, `queue_age`, `received_from_ip`,
`received_via_port`, `source`, `size`. There is **no variable for the message's MIME
structure or headers**, so a route cannot be chosen on "is this PGP". The finest
selectors are sender, sender domain, recipient domain, queue name, source and size.

A second relay that permits these types, selected for just the traffic TEM cannot
carry, is therefore the shape of the fix — `sender_domain == 'm.2143.me'` for human
mail, `rcpt_domain == '2143.me'` for one correspondent, or `source == 'report'` for
the DMARC reports failing today. It requires a relay with no MIME restriction, and
**SES is not one**: it never left its sandbox (see *Why*).

### Attachments: the third switch, and the one that survives the other two

Turning off the plugin's `defaultSign` and `defaultEncrypt` does **not** stop
`application/octet-stream` appearing. `encryptDrafts` ("Encrypt drafts and uploaded
attachments", schema default **`true`**) is a separate switch, and it is the one that
retypes attachments:

- `onBeforeBlobUpload` encrypts every uploaded attachment and re-saves it as a `File`
  named `encrypted.pgp` with `type: "application/octet-stream"`.
- `onBeforeDraftAutoSave` does the same for attachments already on a draft (randomised
  name, `type: "application/octet-stream"`, plus a metadata side-map).
- `fetchAttachments` then copies that type straight into the outgoing MIME part
  (`contentType: att.type || "application/octet-stream"`).

Worse, the two settings interact badly: `onComposeSend` returns early when *both* sign
and encrypt are off — `if (!sign && !encrypt) return void 0;` — and the block that
**decrypts** the stored attachments sits *after* that return. So with crypto off, the
plugin ships the ciphertext attachment, mistyped, instead of the file the user attached.
Measured consequence: four sends to `john@2143.me` between 2026-09-23T11:42Z and
2026-09-24T12:00Z, all 2233–2290 bytes, all rejected for `application/octet-stream` —
including the two sent after sign and encrypt were turned off.

The remedy for a user who needs mail to leave is therefore **all three**: `defaultSign`,
`defaultEncrypt` **and** `encryptDrafts` off, and the attachment must be removed from the
composer and re-added, because the blob already stored there is the encrypted copy.
Turning `encryptDrafts` off has a real cost — drafts and uploaded attachment blobs are
then stored as written rather than as ciphertext — so it is a deliberate trade, not a
free switch.

**TEM's list governs attachments generally**, independently of PGP: `application/zip`,
`application/gzip`, `application/octet-stream` and anything Bulwark types as "unknown"
bounce, while `application/pdf`, the Office types, `image/png|jpeg|gif|webp`,
`audio/mpeg|wav`, `text/calendar`, `text/csv`, `text/vcard` and `message/rfc822` are
accepted. A user attaching a `.zip` or `.asc` will get the same 501 no matter which
crypto settings are on.

### How to verify outbound after any change here

The relay's verdict is in Stalwart's own log; a bounce in the client is not needed to
diagnose. Every remote outcome appears as one of `delivery.delivered` /
`delivery.dsn-success` (accepted) or `delivery.message-rejected` (refused, with the
offending MIME type) plus `delivery.dsn-perm-fail`:

```sh
kubectl -n stalwart logs -l app.kubernetes.io/name=stalwart --since=20m --tail=-1 \
  | grep -E 'queueName = "remote"' \
  | grep -E 'delivered|dsn-success|message-rejected'
```

Intra-domain sends never reach TEM, so they show `queueName = "local"` and
`message-ingest.ham` instead — a useful check that a test was the local kind.

What each test actually proves, given that TEM forbids crypto MIME:

| Test | Recipient | Crypto toggles | Proves |
|---|---|---|---|
| 1 | your own `@m.2143.me` mailbox | sign + encrypt **on**, no attachment | intra-domain E2E and key discovery by WKD; never touches TEM |
| 2 | a PGP host (`john@2143.me`, Proton) | all three **off**, no attachment | plaintext delivery to a PGP-capable host |
| 3 | a non-PGP host (`john@john2143.com`, Google Workspace — `aspmx.l.google.com`) | all three **off** | plaintext delivery to an ordinary receiver |
| 4 | either external address | all three off, **small PNG or PDF attached** | attachments work again after `encryptDrafts` is off |
| 5 | either external address | all three off, **`.zip` attached** | negative control: the 501 should name `application/zip` |

Test 2 is not an E2E test: with encryption off the message is plaintext, and with
encryption on TEM refuses it. **Encrypted outbound to an external PGP host cannot be
tested while TEM is the relay** — only intra-domain E2E (test 1) and inbound from a
correspondent can. For SPF/DKIM/DMARC reputation rather than delivery, use a fresh
`mail-tester.com` address (as in the verification above) or `check-auth@verifier.port25.com`,
which auto-replies with an authentication report.

A composer symptom worth knowing: when `encryptDrafts` was on, an attachment appears in
the draft renamed to `encrypted.pgp` or to a bare UUID. Seeing that name means the stored
blob is the encrypted copy — the attachment has to be removed and re-added, not just
un-toggled.

### Ruled out

- **Direct-to-MX** (Stalwart's built-in `mx` route) for this mail: the outbound path is
  Verizon FiOS residential — `dig -x 108.56.153.222` →
  `pool-108-56-153-222.washdc.fios.verizon.net`. A pool PTR with no sending
  reputation is refused or junked by large receivers, Proton included.
- **Inline (armored) PGP instead of PGP/MIME**, which would be a `text/plain` body and
  pass the list: the plugin *reads* inline PGP (`pgp-inline-encrypted`,
  `pgp-inline-signed` in its reader) but never sends it, so it is not a webmail-side
  workaround.
- **Asking Scaleway to extend the list** — the only zero-infrastructure option left,
  and the list is documented as fixed.

### Not yet observed, and how it differs

A **signed-only** message and a **plain message carrying the `_publickey.asc`
attachment** are both blocked *by the published list* (`application/pgp-signature` and
`application/pgp-keys` are absent from it), but neither has been measured here: every
crypto message this instance has attempted so far was encrypted. Only the
`application/octet-stream` and `application/gzip` rejections have direct evidence.
