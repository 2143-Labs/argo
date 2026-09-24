# Mail encryption at rest and end to end for `John2143@m.2143.me`

**Date:** 2026-09-23, updated 2026-09-24
**Status:** the server side is implemented and verified, and the client side is now
in place. Mail arriving or appended to account `k` is genuinely encrypted at rest,
proven by reading the stored bytes back and finding ciphertext with the plaintext
absent; the crypto plugin is installed instance-wide and configured; and the
account's public key is registered server-side with `encryptionAtRest` armed
against it, so the encrypted mail is readable in the webmail again. What remains
is **per user**: every account still has to run the two onboarding actions below,
and nothing alerts an account that skips the second one.
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

**Permanent limits, stated so they are not mistaken for gaps to close later:**

- **Automated senders can never be encrypted.** asciinema's registration mail,
  DMARC and TLS-RPT reports, and any Sieve-driven send have no browser and no key.
  They continue to transit TEM in cleartext.
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
