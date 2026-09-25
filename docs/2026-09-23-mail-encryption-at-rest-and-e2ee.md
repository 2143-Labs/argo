# Mail encryption at rest and end to end for `John2143@m.2143.me`

**Date:** 2026-09-23, updated 2026-09-24
**Status:** the server side is implemented and verified, and the client side is now
in place. Mail arriving or appended to account `k` is genuinely encrypted at rest,
proven by reading the stored bytes back and finding ciphertext with the plaintext
absent; the crypto plugin is installed instance-wide and configured; and the
account's public key is registered server-side with `encryptionAtRest` armed
against it, so the encrypted mail is readable in the webmail again. What remains
is **per user**: every account still has to run the two onboarding actions below,
and nothing alerts an account that skips the second one. On top of that, a **WKD
publisher** now serves the same public keys at `https://m.2143.me` so external
correspondents can find them before writing, and the webmail runs Bulwark `v1.10.0`.
**Scope:** automatic PGP/S/MIME encryption plus encryption at rest for
`John2143@m.2143.me` on Stalwart v0.16.22, for **mail from here on only**.
Existing mail is deliberately left plaintext; see *Existing mail* below.

## Why

The relay swap ([`2026-09-20-stalwart-tem-outbound.md`](2026-09-20-stalwart-tem-outbound.md))
moved outbound mail onto Scaleway TEM, which means every cleartext message also
passes through a third party's SMTP relay and sits in a nightly Longhorn backup
of the mail volume. The ask was to close both gaps automatically — no per-message
decision, no desktop client per user.

Three properties of Stalwart v0.16.22 decide the whole design, and each was
confirmed in the upstream source rather than inferred:

- **Stalwart cannot encrypt outbound mail.** There is no WKD or Autocrypt code
  anywhere in the tree, `EncryptMessage`/`encrypt_on_append` are reached only
  from the ingest path, and every milter and hook lives under
  `crates/smtp/src/inbound/`. There is no outbound transformation point, so
  message-level encryption must happen in the **client**, before submission.
- **Bulwark is the client, and already has both halves.** The deployed webmail
  (`ghcr.io/bulwarkmail/webmail:v1.10.0` since 2026-09-24, `1.9.2` before that) ships
  *native* public-key management and encryption-at-rest configuration (added in
  1.8.1), and delivers S/MIME and PGP *message* crypto as plugins. Keys never leave
  the browser.
- **Stalwart has no decrypt path for stored mail.** The only `decrypt*`
  functions are in the OAuth token path. Once stored encrypted, the server
  cannot read it — which is the point, and also the risk.

## What changed

### 1. The `sysPublicKey*` permission grant — **already present, nothing changed**

The plan expected to have to add five permissions to the System Administrator
role. It did not need doing: **both** roles already grant all five, with
`disabledPermissions` empty.

| Role | id | description | permissions | `sysPublicKeyGet/Create/Update/Destroy/Query` |
|---|---|---|---|---|
| User | `b` | User | 244 | all `true` |
| System Administrator | `e` | System Administrator | 452 | all `true` |

`Role.enabledPermissions` is a `Map` whose JMAP property write replaces it
**wholesale**, so re-sending the map to add keys that were already there would
have been a 452-entry rewrite with real corrupting risk for zero benefit. It was
not performed. The grant was proved instead by exercising it: an
`x:PublicKey/set` call reached key *validation*, not a permission error.

Admin role resolution for reference: account `k` carries `roles: {"@type":"Admin"}`,
which resolves through `x:Security.defaultAdminRoleIds` (`{"b":true,"e":true}`).
`x:Authentication.defaultUserRoleIds` is `{"b":true}`.

### 2. A2 — encryption at rest armed

Set through the Bulwark UI (Account settings → Security → **Public Keys**),
which is the path Bulwark maintains and the reason no JMAP client script is
kept for it.

| Object | Value |
|---|---|
| `PublicKey` id | `jgccgom2agqa` (description `main pgp main`) |
| Key fingerprint | `086AAAECF60C30A3FC463135DF001CA8A0977BD6` — `John Schmidt <John2143@m.2143.me>` |
| Primary / subkey | `rsa4096` cap `cEC` / `rsa4096` cap `e` (`B841618F1513D6F1477D1F50C6F723D916B1E508`) |
| `x:Account/k` `encryptionAtRest` | `{"@type":"Aes256","publicKey":"jgccgom2agqa","encryptOnAppend":true,"allowSpamTraining":false}` |

The key stored server-side is byte-identical to the exported `pub.asc`
(3147 bytes both). `allowSpamTraining` is `false` deliberately: training the
spam filter on ciphertext teaches it noise, and the flag is only consulted at all
once an account is armed.

**2026-09-24 — the account points at a second object now.** `x:Account/k`
`encryptionAtRest.publicKey` is `jgf0kscuahqa` (description `new bulwark key`,
created 2026-09-24T03:08:31Z), not the `jgccgom2agqa` recorded above. Both objects
carry the **same key**: `gpg --show-keys` reports fingerprint
`086AAAECF60C30A3FC463135DF001CA8A0977BD6` with encryption subkey
`C6F723D916B1E508` for each, so no rotation happened and the private key held in
the webmail still matches what mail is encrypted to. The duplicate is why a WKD
publish has to dedupe on the fingerprint rather than publish one file per object.

### 3. A3 — appended copies encrypt too

The account flag alone is not enough. From
`crates/email/src/message/ingest.rs:499-511`:

```rust
let do_encrypt = match params.source {
    IngestSource::Jmap { .. } | IngestSource::Imap { .. } => {
        self.core.email.encrypt && self.core.email.encrypt_append && account.flags.encrypt_on_append()
    }
    IngestSource::Smtp { .. } => self.core.email.encrypt,
    IngestSource::Restore => false,
};
let is_encrypted = if do_encrypt && !message.is_encrypted()
    && let Some(encrypt_keys) = &account.encryption_key { … };
```

`IngestSource::Jmap | Imap` therefore needs **both** switches, so the global
`Email.encryptOnAppend` was set too:

```json
["x:Email/set", {"update": {"singleton": {"encryptOnAppend": true}}}, "e"]
["x:Action/set", {"create": {"reload": {"@type": "ReloadSettings"}}}, "r"]
```

The reload returned `created.reload` with `notCreated` empty. A registry write
alone changes nothing in memory, and a failed reload **silently discards** the
change — hence requiring `created.reload`, the same discipline as the TEM work.

`x:Email` now reads `{"encryptAtRest": true, "encryptOnAppend": true}`; the
account remains capped at `maxPublicKeys: 5`.

**A3 was applied before A2 was finished in the UI, on purpose.** The ordering in
the plan was A2 → A3, but A3 is provably inert while the account is unarmed:
`crates/common/src/cache/principals.rs:427-478` shows `EncryptionAtRest::Disabled`
yielding `encryption_settings = None`, so `encryption_key` is `None` **and**
`ACCOUNT_FLAG_ENCRYPT_APPEND` is never set. Running A3 first removes the window in
which Sent and Drafts copies would have stayed plaintext after the account was
armed. It is the one deviation from the approved ordering, and it changed no
behaviour at the time it was made.

**Reverted 2026-09-25: A3 broke every outgoing message composed in the webmail.**
Bulwark saves the compose as a draft through JMAP (`Email/set`, an
`IngestSource::Jmap` append), so with A3 on, Stalwart stored the draft as
`multipart/encrypted` to the account's at-rest key. `EmailSubmission/set` then sends
that stored blob verbatim (`crates/jmap/src/submission/set.rs:659-678`,
`blob_store().get_blob(metadata.blob_hash…)`); nothing decrypts it on the way out. Every
submission from `John2143@` between 2026-09-23T11:42Z and 2026-09-25T07:28Z was
therefore PGP/MIME encrypted to `C6F723D916B1E508` only:

- all 11 external sends were refused by TEM with `501 'application/octet-stream'`;
- each rejected message has the **exact byte size** of the draft appended to mailbox 3
  in the same second (e.g. 07:28:41, 2286 B draft → 2286 B `BDAT 2286 LAST`), and the
  12:58 queue capture held a single PKESK for the at-rest subkey;
- `leighanne` (at-rest `Disabled`) sent to `john@2143.me` in the same window and TEM
  delivered it (06:56, 06:59, `250`), which isolates the account setting from the relay;
- internal sends in the window (`technology@`, `support@`) were delivered, but the body
  was encrypted to John's at-rest key, so any other member of those groups received a
  message only John can decrypt.

The browser plugin's toggles were never the cause. Fix, applied through admin JMAP:

```json
["x:Email/set", {"update": {"singleton": {"encryptOnAppend": false}}}, "e"]
["x:Action/set", {"create": {"reload": {"@type": "ReloadSettings"}}}, "r"]
```

`created.reload` returned; `x:Email` reads `{"encryptAtRest": true, "encryptOnAppend": false}`.
Verified: a JMAP-created draft is now stored as `text/plain` with its canary readable
(before the change the same probe stored `multipart/encrypted`, 1779 B, no canary), and a
plaintext `EmailSubmission` to `john@2143.me` was accepted by TEM at 07:39:34Z
(`250 OK: queued as c6a53f10-054c-4fd5-bf3d-11af23bde27c`). `x:Account/k` still carries
`encryptOnAppend: true`; it is inert while the global switch is off.

Cost: Drafts, Sent copies and other JMAP/IMAP appends are stored as written again.
Mail arriving by SMTP is still encrypted at rest, and a plugin-encrypted Sent copy is
already ciphertext. **Do not turn the global switch back on** unless Stalwart gains a
draft exclusion or decrypts before submission.

### 4. Corrections — four things the first attempt got wrong

These were found by running the calls, and each cost a round trip:

- **`accountId` must be a method argument for `x:PublicKey/set`.** Passing it only
  inside the created object returns
  `invalidForeignKey {"object": "Account", "id": "d333333"}` — `d333333` is the
  recovery admin's *session* account, not `k`. Working shape:
  `{"accountId":"k","create":{"k1":{"key":…,"description":…,"emailAddresses":{}}}}`.
- **The at-rest key must contain an encryption-capable component.** A sign-only key
  is rejected with `invalidProperties: "Could not find any suitable keys in
  OpenPGP public key"`. Verified accepted: `rsa4096 cert` + `rsa4096 encr`, and
  `ed25519 cert` + `cv25519 encr`. Verified rejected: ed25519 sign-only, and
  `rsa4096` with no subkey.
- **`gpg --quick-gen-key "…" rsa4096 default 2y` creates no encryption subkey at
  all** — the primary comes out `cap=scSC` with no `sub` line, which Stalwart then
  rejects. The correct two-step is:
  `gpg --quick-gen-key "…" rsa4096 cert 2y`, then
  `gpg --quick-add-key <fpr> rsa4096 encr 2y`.
- **The purpose-built type for at-rest is `x:AccountSettings`, not `x:Account`.**
  `x:AccountSettings/get {"accountId":"k","ids":["singleton"]}` returns the account's
  settings including `encryptionAtRest`, and Stalwart's own integration test configures
  it as `ObjectType::AccountSettings` with `Id::singleton()`
  (`tests/src/system/crypto.rs`). Both paths converge on the same field — the Bulwark
  UI's write was visible through `x:Account/get` too — but `AccountSettings` is the
  intended one. Mind the argument: with the recovery admin's default `accountId`
  (`d333333`) the singleton reads back as `notFound`, and `x:AccountSettings/query`
  does not exist at all.

Also, the extension catalogue at `https://extensions.bulwarkmail.org/api/v1/extensions`
no longer exposes a `version` field, so plugins must be matched on **slug**. The
authoritative versions are in the installed registry, `/app/data/admin/plugins/registry.json`
on the `bulwark-data` PVC: `pgp-true-end-to-end` **2.0.0** and `smime` **1.0.2**, both
`enabled: true`, both satisfied by the deployed `v1.10.0` — the upgrade from `1.9.2`
on 2026-09-24 left the registry byte-for-byte intact (both plugins re-checked
`enabled: true` after the roll).

## Verification

The checks below read the **stored bytes** through JMAP, which holds no private
key. That is what makes them meaningful: the server cannot fake them.

**1. Inbound mail is encrypted at rest.** A probe was injected through the port-25
listener (`kubectl -n stalwart port-forward svc/stalwart-stalwart 2525:25`), from
`external-probe@example.com` to `John2143@m.2143.me`, subject
`at-rest probe 2026-09-23T0930Z`, body containing the canary
`PLAINTEXT-CANARY-1f4c9d`. Read back:

- `bodyStructure.type` = `multipart/encrypted`, sub-parts `application/pgp-encrypted`
  and `application/octet-stream` named `encrypted.asc`
- `preview` = `null`
- stored blob, 3204 bytes: contains `BEGIN PGP MESSAGE`, **does not contain the canary**
- headers (`Received`, `Authentication-Results`, `Subject`) remain readable, as expected

`IngestSource::Smtp` is the right source to test because **every** delivery path
converges on it — internet inbound, TEM, and local delivery all arrive via
`crates/email/src/message/delivery.rs:179`.

**2. Appended copies are encrypted (A3).** A draft created over JMAP
(`IngestSource::Jmap`) came back `multipart/encrypted` with `preview: null`, its
1780-byte blob containing `BEGIN PGP MESSAGE` and not the canary
`A3-CANARY-77aa11`. Both switches combined, exactly as the gate above predicts.
The probe draft was then destroyed.

**3. Mail arriving since arming is encrypted, and the old mail is untouched.** At
the time of writing, 25 messages total:

| Bucket | Count | State |
|---|---|---|
| Pre-existing (Inbox 14, Sent 6, Drafts 1, Junk 1) | 22 | plaintext, untouched |
| `test` — 09:14:44Z | 1 | `multipart/encrypted` |
| `at-rest probe 2026-09-23T0930Z` — 09:25:57Z | 1 | `multipart/encrypted` |
| `Re: test` — 09:26:44Z | 1 | `multipart/encrypted` |

**No plaintext message has `receivedAt` later than 09:13Z**, the moment A2 landed.

**The silent-no-op trap was explicitly ruled out.** A `publicKey` id that does not
resolve, or a key `parse_public_key` cannot parse, leaves `encryption_key = None`
and encrypts **nothing while the config still reads `Aes256`**. Checks 1 and 2 are
the only things that distinguish that from success, and both would have shown a
`text/plain` bodyStructure with the canary present.

### Re-verified 2026-09-24, against the current key object

The checks above were re-run after the account was re-pointed at `jgf0kscuahqa`, so the
result does not rest on the older object id:

**4. At-rest still encrypts, and to the key the user actually holds.** A fresh probe
(`at-rest probe 2026-09-24T1048Z`, canary `PLAINTEXT-CANARY-wkd1`) injected through the
port-25 listener read back over `Email/get` as:

- `bodyStructure.type` = `multipart/encrypted`, sub-parts `application/pgp-encrypted` and
  `application/octet-stream` named `encrypted.asc`
- `preview` = `null`
- stored blob, 1093 bytes: contains `BEGIN PGP MESSAGE`, **does not contain the canary**
- `gpg --list-packets` on that blob: `encrypted with rsa4096 key, ID 0xC6F723D916B1E508`,
  uid `John Schmidt <John2143@m.2143.me>` — the encryption subkey of the same key the
  webmail holds, so the arming points at the right key and not merely at a parseable one.

**5. The Bulwark upgrade disturbed none of it.** After the `1.9.2` → `v1.10.0` roll,
`/app/data/admin/plugins/registry.json` still lists both plugins `enabled: true` and the
admin plugin config file is unchanged: plugin state and the account's key live on the
`bulwark-data` PVC, so they survive an image change by construction — the roll was still
checked rather than assumed.

## Existing mail is left plaintext — by decision

Encryption happens only at ingest, and there is no re-encrypt or backfill path
anywhere in the tree (a grep for `re-encrypt`/`backfill` across `crates/` returns
nothing). The 22 messages already in account `k` stay plaintext. That is the
decision, not an oversight:

- do **not** backfill them by re-importing through JMAP `Email/import`, which
  *would* encrypt them because it ingests as `IngestSource::Jmap`;
- do **not** reset or wipe the mailboxes. The outbound route and strategy, the
  domain and account objects and the TEM relay credential mapping all live in the
  same RocksDB behind `workloads/stalwart/pvc.yaml`.

## Onboarding a new account

The plugin half is instance-wide and needs nothing per user. The **at-rest** half is per
account, has no server-side default, and cannot be automated without escrow:
`EncryptionAtRest::default()` is `Disabled`, and `AccountSettings` — which looks like a
candidate for a defaults object — is a per-account singleton that mirrors the account
rather than a template for new ones (`x:AccountSettings/query` does not exist).
**A new account therefore stores mail in plaintext until step 2**, because the global
`Email.encryptAtRest` switch has no key to encrypt to on its own.

1. Webmail → **Settings → PGP True End-to-End → Generate Keypair**. Prefer `rsa4096`: the
   plugin's own description warns that the `curve25519` and `ed25519Legacy` engines "may
   not be compatible with all email clients, like Protonmail", and the engine setting
   (`generateKey`) ships with a schema default of the odd value `true`, which matches
   neither of those branches and so falls through to `rsa4096` anyway. Set a passphrase,
   then **export and back up the private key before going further**: there is no escrow,
   so a lost key means every message received after arming is unreadable permanently.
   The private half never leaves the browser.
2. **Same panel → the key's ⋮ menu → the set-server-side-encryption action.** This is a
   *separate action* and is **not** implied by step 1: the plugin's Generate Keypair
   button calls `handleGenerateKey(…)`, whose third parameter is
   `autoAddToServerSideEncryption = false`, so generating a key never arms at-rest. The
   menu item calls `handleSetServerSideEncryption`, which does
   `crypto.createPublicKey` (creating the Stalwart `x:PublicKey`) and then
   `crypto.setEncryptionAtRest({type:"Aes256", publicKeyId})`.

   The equivalent manual path is Account settings → Security → Public Keys → add the
   public key → enable encryption at rest with `Aes256`. That is the path account `k`
   used, and it is why the live object is described `new bulwark key` rather than the
   plugin's own hardcoded `Key imported by PGP True E2E Bulwark Plugin`. Prefer the
   plugin action for new accounts — one click instead of a paste, over the same host API.

Then prove it, because only a server-side read cannot be faked: send the account a
message and confirm over JMAP that `Email/get` reports `multipart/encrypted` with a null
`preview`, and that the stored blob contains `BEGIN PGP MESSAGE` and no plaintext.

### How mail to a colleague bootstraps with no key server

> **Superseded for outbound policy on 2026-09-24.** `alwaysSendPubKey` is now **off**,
> because the `application/pgp-keys` part it adds is refused by TEM. The mechanism below
> still describes what the plugin can do, and it stays the fallback if this instance ever
> moves to a relay without a MIME allow-list, but discovery now runs through WKD — see
> *Outbound policy* below.

No key distribution mechanism exists in Stalwart, and none is needed for the first
message. With `alwaysSendPubKey` on (default `true`) the sender's public key rides along
as `${from.addr}_publickey.asc` (`Content-Type: application/pgp-keys`) on every message
that carries a key — the guard sits **outside** the `if (encrypt)` branch, so a
signed-only message still ships it. The receiver imports it without user action:
`pgpVerify` → `parseMime` → `scanAndImportKeysFromAttachments` → `maybeAutoImportSigner`,
which returns early only when `autoImportSignerCerts === false` (default `true`).

So A → B resolves with no key server: A sends signed-only (it holds no key for B yet) and
the message carries A's key; B auto-imports it and replies **encrypted**; A imports B's
key from that reply's attachment; everything after is encrypted.

**Prerequisite: `forceEncryption` must be `false`.** If it blocks sending to a recipient
who holds no key, the signed-only bootstrap message cannot be sent at all and the flow
deadlocks — B never receives A's key. The same deadlock applies to
`forceDraftAndAttachmentsEncryption`. The admin plugin config is therefore exactly:

| Option | Value | Why |
|---|---|---|
| `forceEncryption` | `false` | Hard prerequisite — otherwise the bootstrap deadlocks. |
| `forceDraftAndAttachmentsEncryption` | `false` | Same deadlock, for drafts and attachments. |
| `allowPersistentKeys` | `true` | Keeps unlocked keys in IndexedDB behind a non-extractable WebCrypto key, so users are not re-prompted every session. |
| `blockUntilDefaultKeyIsAvailable` | `false` | Would block sending during rollout, before every account has a key. |

These are `configSchema` values, stored per plugin in
`/app/data/admin/plugin-config/pgp-true-end-to-end.json` on the `bulwark-data` PVC — the
file the admin API reads and writes (`/app/.next/server/app/api/admin/plugins/[id]/config/route.js`).
Read from that file on 2026-09-24: `{"forceEncryption": false,
"forceDraftAndAttachmentsEncryption": false, "blockUntilDefaultKeyIsAvailable": false,
"allowPersistentKeys": true}`.

### Standing audit — which accounts are really protected

At-rest has no server-side default and nothing alerts an account that skipped step 2, so
run this **whenever accounts are added**. It enumerates every account object and flags any
that is not `Aes256`. `x:Account/query` returns **groups as well as users** (`m` and `l`
here), which have no keys — filter on `@type`, or read the `n/a (group)` rows as such.

```json
["x:Account/query", {"accountId": "d333333"}, "q"],
["x:Account/get", {"accountId": "d333333",
                   "#ids": {"resultOf": "q", "name": "x:Account/query", "path": "/ids"},
                   "properties": ["@type", "name", "encryptionAtRest"]}, "g"]
```

Run on 2026-09-24 — one user account, protected; the two groups carry no key:

```
  m  Group  technology   at-rest=Disabled  key=None        -> n/a (group)
  l  Group  support      at-rest=Disabled  key=None        -> n/a (group)
  k  User   John2143     at-rest=Aes256    key=jgf0kscuahqa -> OK
```

### Outbound policy, decided 2026-09-24: encrypted internally, plaintext outbound

Scaleway TEM refuses the MIME types OpenPGP requires, so **no crypto MIME can leave this
instance as mail** (the constraint and its measurements are in
[`2026-09-20-stalwart-tem-outbound.md`](2026-09-20-stalwart-tem-outbound.md)). The decision
that follows: mail between `m.2143.me` users stays encrypted, everything else leaves in the
clear. It needs no relay change — it is entirely a client configuration.

The plugin has no notion of "internal" or "external", so the policy is assembled out of the
two things it does have: the rule that it encrypts only when **every** recipient holds a key
(`if (encrypt && nonPgpRecipients.length === 0)`), and WKD, which supplies keys for our own
domain and for almost nothing else.

| Setting (per user, browser-side) | Value | Why |
|---|---|---|
| `defaultEncrypt` | **`true`** | encryption stays armed — this is what makes internal mail encrypted with no user thought |
| `defaultSign` | **`false`** | the signature part is `application/pgp-signature`, which TEM refuses; signing becomes a per-message choice, and only for internal recipients |
| `alwaysSendPubKey` | **`false`** | the `_publickey.asc` part is `application/pgp-keys`, also refused; WKD takes over this bootstrap role |
| `encryptDrafts` | **`false`** | otherwise every attachment is encrypted and retyped `application/octet-stream`, and any attachment bounces |
| `tryToFetchMissingKeys` | **`true`** | required — the WKD lookup that finds a colleague's key lives inside this guard |
| `autoImportSignerCerts` | leave `true` | only consulted for signed mail, which is now opt-in |

**The 2026-09-23 → 2026-09-25 external bounces were not caused by these settings.**
They were Stalwart's `encryptOnAppend` encrypting the stored draft that
`EmailSubmission` then sent; see *Reverted 2026-09-25* under A3. With that switch
off, a compose with PGP Encrypt and Sign off leaves as plaintext and TEM accepts it.

**How internal encryption happens with no user action:** each user completes the two
onboarding actions, the key lands in Stalwart's registry, the WKD publisher serves it within
five minutes, and a colleague's plugin finds it at compose time and encrypts. No attachment
bootstrap, no manual exchange, no external key server.

#### What "enforce" can and cannot mean here

- **It can be automatic**, which is what the table buys: nothing per message, and internal
  mail is encrypted whenever the recipient has an armed, WKD-published key.
- **It cannot be a server-applied policy.** Neither `configSchema` (admin) nor
  `settingsSchema` (user) offers "require encryption for these recipients", and
  `forceEncryption` does **not** do that job: its whole effect is
  `if (forceEncryption === true && !getDefaultKeyRecord()) return false`, blocking the send
  when the *sender* has no key. It says nothing about recipients.
- **It cannot be audited from the store.** Stalwart's Sieve has no MIME test (checked — the
  implementation has none), and a message that arrived E2E-encrypted is stored in the same
  shape as one that arrived in cleartext and was wrapped by at-rest encryption: both are
  `multipart/encrypted; protocol="application/pgp-encrypted"`. No query answers "was this
  internal message encrypted in transit".
- **The residual hole is a colleague who has not onboarded** — mail to them leaves in
  cleartext, silently. The available counters are the standing audit above (an account
  reading `at-rest=Disabled` has no key, so nothing can be encrypted to it) and running that
  audit on a schedule instead of by hand.
- **The external failure mode is loud, not silent**: if someone imports an external
  correspondent's key, the send bounces at TEM rather than leaking, and it self-reports.

### The four per-user distribution settings have no admin control

`defaultSign`, `defaultEncrypt`, `alwaysSendPubKey` and `autoImportSignerCerts` are
`settingsSchema` values, which the admin page does not expose — it shows only
`configSchema`. All four default to `true`, and none of them is stored server-side: the
synced settings blob (`data/settings/<sha256(username:serverUrl)>.enc`, decrypted and
listed on 2026-09-24) contains no PGP keys at all, so the plugin's per-user settings live
in the browser. The consequence is that a user can switch one off and silently break key
distribution for themselves, with nothing to alert anyone. The only defence is telling
them not to; it cannot be enforced.

Do **not** make this uniform by pointing every account's `encryptionAtRest.publicKey` at
one shared key: that discards the isolation `PublicKey.accountId` exists to provide, and
one compromised key then reads every mailbox.


#### The plugin's three send scenarios (traced in the bundle, 2026-09-24)

When encryption is requested, `onComposeSend` branches on recipient keys returned by
`recipientKeysFor` (`contacts.search`). WKD and keyserver lookups happen earlier, during
compose; their results must be available to the send-time contact lookup.

| Scenario | Condition | What goes out |
|---|---|---|
| **A** | every recipient resolves to a key | one PGP/MIME message to all recipients, encrypted to the found keys plus your own |
| **B** | some resolve, some do not | a red "mixed recipients" confirmation, then **two separate submissions**: an encrypted envelope to the keyed recipients and a cleartext envelope to the rest (the cleartext one is PGP-signed if signing is on — which TEM refuses). The Sent folder keeps the encrypted envelope |
| **C** | none resolve | a cleartext envelope to everyone (PGP-signed if signing is on — again refused by TEM), plus a Sent copy encrypted to **your own key only** |

If both signing and encryption are off, the hook returns without processing the message.

Two corrections to what this document said earlier:

1. **Mixed sends do not degrade to plaintext for everyone — they split.** Scenario B is
   exactly the desired policy: internal recipients get the encrypted envelope, external
   recipients get the cleartext one, from a single compose. The preconditions are that the
   external addresses resolve to *no* key and that signing is off.
2. **The 2026-09-24 PGP/MIME capture was Stalwart's at-rest wrapper, not the plugin.**
   The raw queue message to `john@2143.me`, `john@john2143.com` and `support@m.2143.me`
   held one recipient-key packet, for the at-rest subkey `C6F723D916B1E508`, because
   `encryptOnAppend` had encrypted the draft that `EmailSubmission` sent. No contact
   keys were involved; the "phantom key" theory was wrong and no keys need deleting.

**Never clear browser site data as a troubleshooting shortcut.** The plugin stores
private keys in IndexedDB; losing an unbacked-up key loses access to encrypted mail.

One more traced detail: the plugin logs the full outgoing message — cleartext included —
at `log.info("final message text - Scenario …")`. Those lines go to the browser console
only; they do not appear in the Bulwark container log (checked 2026-09-24).

## Web Key Directory for `m.2143.me`

Everything above works with **no key server** — keys travel as message attachments. WKD
adds the one thing attachments cannot: an external correspondent (GnuPG, Thunderbird,
Proton) can fetch your key *before* writing the first message. It changes nothing about
the intra-domain guarantee, and Stalwart itself still ships no WKD code — this is a
separate read-only service that only consumes Stalwart's public-key registry.

### Why the direct method, and why `openpgpkey.m.2143.me` stays absent

Bulwark resolves recipient keys on compose through `crypto.getPublicKeyFromWKD()`, and
only falls back to `keys.openpgp.org`. That host API is mapped to `crypto:full` rather
than to the allowlist-gated `http:*` permissions and fetches `https://<domain>/…`
directly, so a self-hosted WKD needs **no change to the plugin**, while a self-hosted
*keyserver* would need a new entry in the plugin's `httpOrigins`.

Bulwark only ever takes the **direct method**: it requests
`/.well-known/openpgpkey/hu/<hash>?l=`, omitting the `/<domain>/` segment the spec
requires for the advanced method (which lives on `openpgpkey.<domain>`). So the WKD is
served on `m.2143.me` itself, and **`openpgpkey.m.2143.me` must not be created**: a
spec-compliant client that resolves that name would try the advanced path, which is not
served here, instead of falling back to the direct one.

### The service

`workloads/wkd/` — one `node:22-alpine` container, no image build, the script supplied by
`ConfigMap/wkd-script` and mounted read-only at `/app/server.mjs`. It is read-only, holds
no state on disk, and runs as uid 1000 with `readOnlyRootFilesystem`, all capabilities
dropped, and `RuntimeDefault` seccomp.

| Request | Response |
|---|---|
| `GET /.well-known/openpgpkey/hu/<hash>` (and `/hu/<hash>`) | `200`, raw **binary** OpenPGP public key, `Content-Type: application/pgp-keys`, `Cache-Control: public, max-age=300`; `404` for an unknown hash |
| `GET /.well-known/openpgpkey/policy` (and `/policy`) | `200`, zero-length body, `text/plain` |
| `GET /healthz` | `200` (`ok`) |

Nothing else is served — no HTML, no directory index, and `X-Content-Type-Options:
nosniff` on every response. A tree that has never loaded answers `503`, which is what
separates "no key for this address" from "not serving keys yet".

The tree is rebuilt every five minutes (`WKD_REFRESH_MS`) from four JMAP calls:

1. `GET /jmap/session` → the session's own account id
   (`primaryAccounts["urn:stalwart:jmap"]`), which is what scopes everything after it.
2. `x:Account/query {"accountId": <session>}` → every account id. **Groups come back too**
   (`m`, `l`); only `@type == "User"` objects own keys.
3. `x:Domain/get` → domain ids to names, because an account's address is its `name` plus
   its `domainId`, and each alias carries a `domainId` of its own.
4. Per onboarded user (`encryptionAtRest` reading `Aes256`), `x:PublicKey/get
   {"accountId": <user>}`. Accounts with no key, or with at-rest disabled, are skipped.

Each user's primary address and **every enabled alias whose domain is `m.2143.me`** is
published (account `k` contributes `john2143`, `all` and `dmarc` from `m.2143.me`; its
`terminals.john2143.com` aliases are excluded). Hash:
`zbase32_msb(sha1(lowercase(localpart)))`, 32 characters over the alphabet
`ybndrfg8ejkmcpqxot1uwisza345h769` — the exact function Bulwark uses, checked against two
reference values: `john2143` → `fjbwczxhjfmgqs7e11wqxom18mqmdbag` and `john` →
`wwq7w9d96wfsd4zkytndq84kpkjod3eb`. (`john` is deliberately *not* published — it is not an
alias of the account, and it correctly 404s.)

Several `PublicKey` objects can carry the same address — account `k` has two, both the
same key — so the newest `createdAt` wins and a collision between two genuinely different
keys is logged rather than published twice. Dearmoring is mandatory: the stored key is
armored and GnuPG's WKD client expects binary. If dearmoring fails for a key the armored
form is served instead (Bulwark accepts either); it has not had to.

**A failed refresh keeps the previous tree and logs; it never installs an empty one.**
Verified against a running instance by cutting the JMAP path underneath it: two
consecutive scheduled refreshes logged `keeping previous tree` and the key kept serving
byte-identically (`sha256` unchanged, still `200`).

### What stays up to date on its own, and what does not

The tree is rebuilt wholesale every five minutes and the serving path is a pure cache
lookup, so **nothing has to be re-run when a user onboards**. Picked up automatically,
within one refresh plus at most five minutes of HTTP caching:

- a **new user account** that has a server-side key and at-rest armed;
- a **new alias**, and a new address on an existing account — the address list comes from
  `x:Account/get`, not from a hardcoded map;
- a **key rotation** or a re-imported key on the same address (newest `createdAt` wins);
- **removal**: an account that disappears, or loses its key/arming, stops being published
  at the next refresh.

Two things are *not* automatic, and both are per-user rather than per-service:

- **A key that only exists in someone's browser is invisible.** The published key comes
  from the Stalwart registry, so the user has to complete onboarding step 2 (the plugin's
  set-server-side-encryption action) for their address to appear. A user who generated a
  keypair but never armed it is counted under `unarmed` in the refresh log and is
  deliberately skipped — publishing for an un-onboarded account would advertise a key the
  account does not use.
- **An account with no key at all** is logged as `keyless` and skipped, so the failure is
  visible in the pod log rather than silent.

To force it immediately rather than wait out the interval:
`kubectl -n stalwart rollout restart deploy/wkd` (the first refresh runs at startup). The
refresh log line carries `entries`, `published`, `unarmed`, `keyless`, `collisions` and
`misattributed`, which is the whole health picture in one line.

### The credential

`Secret/wkd-jmap` in namespace `stalwart`, key `WKD_JMAP_PASSWORD`: a dedicated **app
password**, not the recovery admin. Its permission map is a `Replace` list, so the
credential can do this and nothing else:

```json
{"@type": "Replace", "permissions": {
  "authenticate": true,
  "impersonate": true,
  "sysAccountGet": true,
  "sysAccountQuery": true,
  "sysDomainGet": true,
  "sysPublicKeyGet": true,
  "sysPublicKeyQuery": true
}}
```

**Three corrections against the first draft of this design**, each found by running it
rather than by reading it:

- **`authenticate` is required, or the credential cannot open a JMAP session at all.**
  With only the four `sys*` permissions every request returns `403` and Stalwart logs
  `security.unauthorized … details = "authenticate"`. The permission map in the design
  was therefore not a working credential.
- **`sysDomainGet` is required** to turn a `domainId` into a domain name — without it the
  service cannot tell `m.2143.me` from `terminals.john2143.com`, the second hosted domain
  on this instance, and cannot build an address at all.
- **`impersonate` is required for the service to keep working for more than one user.**
  Registry Get authorises with `assert_is_member` (`crates/jmap/src/api/request.rs:370`),
  and membership is *the token's own account plus the groups that account belongs to*
  (`crates/common/src/auth/access_token.rs:476`). Measured with the credential as it
  stood: `x:PublicKey/get` for its own account `k` → `200`; for group `m` (which `k` is a
  member of) → `200`; for any other account → `403 You are not an owner of account …`. A
  second user account is neither, so without `impersonate` the **first second user would
  fail the whole refresh** and freeze the tree at today's content. It is not optional
  decoration, and it is the reason the service is single-credential rather than
  per-account.

`impersonate` also switches off the per-account filter for registry reads —
`registry/get.rs`: `is_account_filtered` is false when the token has that permission — so
the service no longer trusts the server to scope a query. Every fetched key object is
published only if its `accountId` is absent or names the account that was asked for, and a
key object id seen under two different accounts is refused and logged. That guard is the
piece that makes a wide credential safe; it is exercised in the verification section.

What it *cannot* do, checked with `impersonate` in place rather than assumed:
`Email/query`, `x:AppPassword/get`, `x:AccountSettings/get` and `x:PublicKey/set` all
return `forbidden` — no mail, no credentials, no settings, no writes. Its reach is
read-only account, domain and public-key metadata, which is exactly what the tree needs.

The credential was created with `x:AppPassword/set` as account `k` (it appears as `d` in
`x:AppPassword/get`) rather than through the admin UI, because that is reproducible and
the admin dashboard is disabled anyway (`Admin dashboard disabled (no ADMIN_PASSWORD
set)`). **Its value is not in Git and there is no ExternalSecret yet**: the Kubernetes
Secret was created directly with `kubectl`, which is the documented fallback in
`docs/adding-a-secret.md`. Follow-up: seed
`consumers/data/john2143-com/stalwart/wkd-jmap` and add
`workloads/secrets/stalwart-wkd-jmap.yaml` in the `tem-smtp` shape. Until then
`Secret/wkd-jmap` is the only copy and is not restored by a GitOps sync.

### The public route

`m.2143.me` had no gateway listener, which is why it answered with the gateway's
`404 page not found`. Two additions:

- `workloads/gateway/gateway.yaml`: an `m-2143-me-https` listener — the
  `stalwart-ts-2143-https` block with a different name and hostname, terminating with the
  existing `2143-me-wildcard-tls` secret (`*.2143.me`, already issued; no new
  certificate).
- `workloads/wkd/route.yaml`: an `HTTPRoute` in namespace `stalwart` bound to that
  listener by `sectionName`, hostname `m.2143.me`, one rule to the `wkd` service on 8080.

**It deliberately does not carry the `lan-only` middleware** that
`workloads/stalwart/ingress.yaml` uses: WKD exists to be reached from the open internet.
`m.2143.me` resolves publicly (`108.56.153.222`) — unlike `stalwart.ts.2143.me`, which is
split-horizon to the in-cluster load balancer — so the listener was the only piece
missing.

### Verification

All of it from outside the cluster except where noted.

**1. The service answers, with the right hash and the right bytes.**

```
https://m.2143.me/.well-known/openpgpkey/hu/fjbwczxhjfmgqs7e11wqxom18mqmdbag?l=john2143
  -> 200 application/pgp-keys 2263 bytes
https://m.2143.me/.well-known/openpgpkey/policy   -> 200 text/plain 0 bytes
https://m.2143.me/.well-known/openpgpkey/hu/deadbeef -> 404
```

The body starts `c6 c1 4d 04` — an OpenPGP packet header, not `-----BEGIN`. Its `sha256`
equals the dearmored `x:PublicKey` object `jgf0kscuahqa` that `encryptionAtRest` points
at, and `gpg --show-keys` reports fingerprint `086AAAECF60C30A3FC463135DF001CA8A0977BD6`
with encryption subkey `C6F723D916B1E508` — the key the stored mail is actually encrypted
to, so the published key is usable and not merely well-formed.

**2. The route is public and TLS is valid.** `curl` from the workstation (public DNS
`108.56.153.222`, not the LAN address) with `ssl_verify_result=0`: `policy` → `200`, key
→ `200`, unknown hash → `404`. A `404 page not found` would have meant the listener or
`parentRefs.sectionName` was wrong.

**3. The gateway accepted the route.** `Gateway/shared-gateway` reaches generation 52
`Accepted`/`Programmed` with the new listener in its list, and the `HTTPRoute` is
`Accepted=True`. (Before the gateway Application synced, the route read
`Accepted=False NoMatchingParent` — the listener has to exist first.)

**4. No regression.** Account `k` holds 31 messages: 22 plaintext, all with `receivedAt`
at or before 2026-09-21T15:21Z, and 9 encrypted, all at or after 2026-09-23T09:14Z — the
arming moment. The plaintext count is exactly the 22 recorded on 2026-09-23, so nothing
was re-encrypted or lost by this work. `openpgpkey.m.2143.me` still does not resolve.

**5. The deadlock guard cannot fire.** Read from the installed plugin
(`/app/data/admin/plugins/pgp-true-end-to-end.js`), `onComposeSend` is:

```js
if (await config("forceEncryption") === true && !await getDefaultKeyRecord()) { …; return false; }
if (await config("blockUntilDefaultKeyIsAvailable") === true && !await checkIsKeyUnlocked()) { …; return false; }
```

Both are `false` in the live config, so no send is blocked on either ground. Note the
guard as written keys off the *sender's own* default key, not the recipient's — either
way, the bootstrap cannot deadlock here.

**6. The ownership guard refuses a key that is not the account's.** `impersonate` lifts the
server-side account filter, so this was tested directly against a stub JMAP endpoint
serving three users: `k` with its own key, a synthetic second user `bob` with his own key,
and `carol` whose reply hands back *k's* key labelled with `accountId: k`. Result — `bob`'s
address served his key, `carol`'s address `404`s, and the refresh logged
`skipping key attributed to another account` with `misattributed: 1`. A mis-attributed key
cannot therefore be published under the wrong person's address.

**7. The foreign-account read is exercised against the real server.** A throwaway public
key was planted on a *foreign* account through the admin credential, then queried with the
WKD credential: with `impersonate`, that query returns the foreign account's key for that
account id, and `[]` for accounts that hold no keys, where without it the request is
refused with `You are not an owner of account …`. The probe key was destroyed immediately
afterwards, leaving only account `k`'s two objects. This covers the mechanism for a
second *user* (the stub above covers the per-user address assembly), but the instance has
only one user account today, so no second real mailbox has onboarded yet.

**Not verifiable from this document, and left as such:** that a composed message actually
leaves encrypted and that a colleague's client auto-imports the sender's key. Both need
two onboarded accounts and a logged-in webmail session; see the procedure in *How mail to
a colleague bootstraps* above. No external client has been pointed at this WKD yet.

## Open, and the permanent limits

**Open — what is left unverified or unfinished:**

- **The crypto plugins are installed and enabled.** `pgp-true-end-to-end` **2.0.0** and
  `smime` **1.0.2** are both present with `enabled: true` in
  `/app/data/admin/plugins/registry.json` on the `bulwark-data` PVC, so every user of
  this instance — present and future — gets the crypto UI with no per-user install. The
  plugin's admin config is now the intended one; see the table above.
- **Only account `k` holds a key, and the backup is a human action.** The private key was
  generated in the webmail and lives in that browser; the server holds only the public
  half (`jgf0kscuahqa`). Whether it has actually been exported to offline storage cannot
  be verified from the server, and it is the one step whose failure is unrecoverable.
  Every other account starts from step 1 of the onboarding section.
- **Outbound encryption has not been exercised in a browser session.** The pieces are in
  place and the config no longer blocks the bootstrap, but nothing here proves that a
  composed message actually leaves encrypted: that needs two onboarded accounts and a
  webmail session, which this document cannot supply. The server-side half — the
  attachment-based key exchange and the `forceEncryption: false` prerequisite — is
  described above. S/MIME toward the Google Workspace correspondent is additionally gated
  on the Workspace edition: hosted S/MIME exists only on Frontline Plus, Enterprise Plus
  and the Education tiers, and on **no** Business edition nor Enterprise Standard.
- **The WKD credential has no vault entry.** `Secret/wkd-jmap` was created with `kubectl`
  and is the only copy — a cluster rebuild loses it, and the service then serves `503`
  until it is reissued. Seeding the OpenBao key and adding the ExternalSecret is the
  follow-up.
- **WKD is served for `m.2143.me` only.** `terminals.john2143.com` is a second hosted
  domain on the same instance; serving it means a second listener, a second `HTTPRoute`
  and including that domain's addresses in the tree. `john2143.com` is Google-hosted.
- **No external client has consumed it yet.** The endpoint's shape is verified against
  Bulwark's own request path and against GnuPG's parser, but no GnuPG or Proton lookup of
  a `m.2143.me` address has been observed end to end.
- **Unrelated DNS in the same zone:** `openpgpkey.2143.me` CNAMEs to `2143.me.` and
  presents no certificate for its own name (`TLSV1_UNRECOGNIZED_NAME`). Because the
  sub-domain *does* resolve, compliant clients skip the direct-method fallback for
  `2143.me` addresses, so that record actively suppresses WKD for the Proton-hosted
  domain. Deleting it is a one-line DNS change, independent of everything here;
  publishing WKD for `2143.me` at all is separate work.
- **The WKD credential is deliberately broad in one dimension.** `impersonate` plus the
  `sys*` read permissions let it read account, domain and public-key metadata for every
  account, because a narrower credential provably cannot enumerate a second user's keys
  and would freeze the tree instead. It still cannot read mail, app passwords, account
  settings or write anything (checked), and the service treats every key as untrusted
  until its ownership is confirmed. The alternative — the recovery admin, which the
  design allowed as a fallback — is strictly wider, so this is the narrower of the two
  workable options rather than a convenience.
- **Outbound encrypted mail to external recipients is blocked by the relay, and this is
  now the largest open item.** Scaleway TEM rejects any message containing a MIME type
  outside its fixed allow-list; OpenPGP/MIME *requires* `application/octet-stream` for
  the payload (and `application/pgp-signature` / `application/pgp-keys` for signed or
  key-carrying mail), none of which are on it. Every affected send has bounced — three
  measured on 2026-09-23/24. Intra-domain E2E is unaffected (local delivery never
  touches TEM) and *inbound* from external senders works, but an encrypted reply to a
  correspondent cannot leave today. The routing hook, the options and what is ruled out
  are recorded in
  [`2026-09-20-stalwart-tem-outbound.md`](2026-09-20-stalwart-tem-outbound.md).

**Permanent limits, stated so they are not mistaken for gaps to close later:**

- **Automated senders can never be encrypted.** asciinema's registration mail,
  DMARC and TLS-RPT reports, and any Sieve-driven send have no browser and no key.
  They continue to transit TEM in cleartext.
- **The relay, not the client, decides whether encrypted mail can leave.** Signing and
  encryption necessarily produce MIME types that a strict transactional relay may
  refuse, and with the plugin's defaults every external message composed in the webmail
  carries one. No client-side setting fixes that: it is a relay capability question.
- **At-rest encryption protects stored mail only.** It does nothing about what TEM
  or any other hop can read at send time.
- **There is no server-side decrypt and no escrow.** Losing the private key loses
  every message received after 2026-09-23T09:13Z, permanently.
- **A datastore restore reintroduces plaintext.** `IngestSource::Restore` hardcodes
  `do_encrypt = false` (`crates/services/src/task_manager/restore_item.rs:68`), so
  restored mail comes back readable by the server. Expected, not a bug.
- **At-rest encryption is PGP, so the cipher is `Aes256`.** `EncryptMessage` rejects
  a PGP key combined with an AEAD cipher (`Aes256Gcm`, `ChaCha20Poly1305` are
  S/MIME-only), and Bulwark's UI offers only `Aes128`/`Aes256`.
- **Body-text search no longer matches encrypted mail — measured, not predicted.**
  The indexer has no encrypted-message special case. Observed: `body:"reply"` → **4**
  matches against plaintext bodies, while `body:"PLAINTEXT-CANARY-1f4c9d"` → **0** and
  `body:"A3-CANARY-77aa11"` → **0**. Headers still match — `subject:"at-rest probe"` → **1**
  and `from:"external-probe@example.com"` → **1**. This is the main functional
  regression users will notice.
- **This configuration lives only in RocksDB.** The `encryptionAtRest` object and
  the `PublicKey` are not in Git and are not restored by a GitOps sync, which is
  why this document exists.
