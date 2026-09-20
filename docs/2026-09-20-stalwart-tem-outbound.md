# Stalwart outbound relay via Scaleway TEM

**Date:** 2026-09-20
**Supersedes:** `2026-09-17-stalwart-ses-outbound.md`
**Status:** implemented and partially verified — **the relay credential does not
authenticate; outbound relay is down until it is replaced** (see
[Blocker](#blocker-the-tem-credential-does-not-authenticate)).

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

- **Only 587 is reachable.** `smtp.tem.scaleway.com` answers on 25, 587 and
  2587 from this network; the implicit-TLS ports **465 and 2465 both time
  out**. The encrypted submission path is therefore **587 + STARTTLS**. This
  is the opposite of the SES situation, whose reachable port was 465.
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

### 5. DNS — deliberately **not** changed yet

The plan's DNS edits (drop the three SES DKIM CNAMEs, the `bounce.m` TXT and
MX, and `include:amazonses.com` from both SPF records) are gated on verification
passing. It has not, so they are untouched, and `m.2143.me`'s SPF still carries
both `include:amazonses.com` and `include:_spf.tem.scaleway.com`. TEM's own
records — the `78d3b111-…._domainkey.m` TXT and `_spf.tem.scaleway.com` — exist
and were left alone.

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

### Blocker: the TEM credential does not authenticate

The submission stops at `AUTH`, so `MAIL FROM`/`RCPT TO` were never reached and
**no** `554 MAIL FROM domain not verified` could be observed either way:

```
334 VXNlcm5hbWU6
334 UGFzc3dvcmQ6
535 5.7.8 Permission denied
```

All three plausible pairings of the vault's values were tried from inside the
pod, with credentials injected over stdin and never printed. The server's replies
are specific and between them they pin the mapping down:

| username | password | reply |
|---|---|---|
| `TEM_USERNAME` | `API_SECRET_KEY` | `535 5.7.8 Permission denied` |
| `TEM_USERNAME` | `API_ACCESS_KEY_ID` | `535 5.7.8 Authentication is denied. Please use the Secret Key instead of the Access Key` |
| `API_ACCESS_KEY_ID` | `API_SECRET_KEY` | `535 5.7.8 Invalid credentials` |

The second row is the useful one: the relay recognised the *username* as a valid
SMTP user and rejected only the password's **type**, so `TEM_USERNAME` is the
right field for the username and `API_SECRET_KEY` is the right field for the
password. The first row is therefore the documented configuration, and it is
refused for a reason other than the shape of the credential.

What the API key itself can and cannot do, measured with the same key:

- `POST /transactional-email/v1alpha1/regions/fr-par/emails` with a **valid**
  body returns `permissions_denied` on `email_api` `create`, and does so for
  *every* `project_id` — including random UUIDs. That is the same action SMTP
  submission performs, which is why the relay answers `535 Permission denied`.
  (An earlier probe with an empty `{}` body returned argument-validation errors
  instead; Scaleway validates arguments *before* authorising, so that result
  said nothing about permissions and was briefly read as evidence that sending
  was allowed.)
- `GET …/regions/fr-par/domains` returns `{"total_count":0,"domains":[]}` —
  **no domains** — and returns the same empty result for any `project_id`
  supplied, including random UUIDs, so the endpoint does not enforce scope and
  this is not by itself proof of the wrong project.
- `GET /iam/v1alpha1/api-keys/<access key>` →
  `insufficient permissions`; `account/v3/projects` needs an
  `organization_id` the key cannot obtain. The key is not an IAM
  administrator, so its own project and policy cannot be read from here.

**Root cause: the API key's policy lacks the TEM *send* permission.** Scaleway
gates sending behind two separate permission sets —
`TransactionalEmailEmailApiCreate` for the REST `email_api:create` action and
**`TransactionalEmailEmailSmtpCreate`** for the SMTP relay. A policy holding
only read/domain permission authenticates cleanly and then refuses the send,
which is exactly the observed combination: reads succeed, `email_api:create` is
denied, and the relay answers `535 Permission denied` rather than
`Invalid credentials`.

**A second, independent defect: `TEM_USERNAME` is not a project ID.** The pod's
`TEM_SMTP_USER` is `78d3b111-0472-42fe-bf80-ca1d2c57b2b6` — the **DKIM selector**
from the published `78d3b111-….m.2143.me` TXT record, not the Scaleway **Project
ID** that TEM documents as the SMTP username. Whoever populated the vault copied
the DKIM record's name. This is why the wrong username was not obvious from the
transcript: a well-formed UUID is accepted as plausible and the exchange
proceeds to the password/permission check (`535 … Permission denied`), while a
non-UUID such as `P1335383` is rejected earlier with `Invalid credentials`. Two
different UUIDs therefore produce an identical reply even though only one of
them can be the project.

**To fix**, both are Scaleway console actions:

1. Attach an IAM policy granting **`TransactionalEmailEmailSmtpCreate`** (plus
   `TransactionalEmailEmailApiCreate` if the REST path is wanted) to the
   principal that owns the API key, scoped to the Project that holds the
   verified `m.2143.me` domain. Read permission alone is not enough.
2. Set `TEM_USERNAME` to that Project's **ID** — the project the policy is
   scoped to, and the one whose Domain Overview page lists `m.2143.me`.

Then update the vault entry `john2143-com/stalwart/scaleway-tem-smtp` with the
corrected `TEM_USERNAME`, `API_ACCESS_KEY_ID` and `API_SECRET_KEY` — ESO
propagates it within 10 minutes and Reloader rolls both consumers. The relay
cannot be verified end to end until both are done, but the SMTP leg can be
retested first, without touching the vault, by authenticating with a candidate
pair directly from inside the pod.

**If the Project ID changes, the route must be updated too.** `authUsername` is
stored literally, so the new ID is a JMAP write plus a reload:

```json
{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:MtaRoute/set",{"update":{"jfrumaziaaaa":{"authUsername":"<new Project ID>"}}},"r"]]}
```

…followed by the 4.3 reload. If only the secret key changes, no route write is
needed at all. Nothing else in this change depends on the credential.

### Not yet run

These are downstream of the blocker and are deliberately deferred rather than
half-done:

- the app's end-to-end send (asciinema registration mail → `DKIM: PASS`
  `d=m.2143.me`, `DMARC: PASS`, SPF expected *unaligned* because TEM stamps its
  own envelope domain — an unaligned SPF is **not** a failure);
- a user-submitted message through the submission port to an external address;
- inbound reachability from an **external** vantage (never from the LAN — the
  router does not hairpin port 25, so LAN tests time out on a healthy path);
- retiring SES: deleting the two `ses-smtp` ExternalSecrets, the vault entry,
  the AWS credential, the three DKIM CNAMEs, `bounce.m`, and
  `include:amazonses.com` from both SPF records.

## State left behind

| Thing | State |
|---|---|
| `tem` MtaRoute | exists — `jfrumaziaaaa`, `smtp.tem.scaleway.com:587`, STARTTLS, env-var secret |
| `ses` MtaRoute | **destroyed** — it had to go for any reload to validate |
| outbound strategy `route` | `'tem'` |
| `Secret/tem-smtp` (stalwart, default) | exists, four keys |
| `SES_SMTP_*` env on the pod | removed |
| SES ExternalSecrets, vault entry, AWS credential | **untouched** |
| SES DNS records, `include:amazonses.com` | **untouched** |

Because the `ses` route is gone and its credential is unused, **rollback to SES
is no longer a single strategy write**. Outbound relay is non-functional until
the credential above is replaced — which is no regression in practice, since SES
delivered nothing real, but it does mean every relayed message now fails
authentication and will be retried and eventually bounced.

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
