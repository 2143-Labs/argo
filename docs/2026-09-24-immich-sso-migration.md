# Immich: Pocket ID SSO and SSO-only login

**Date:** 2026-09-24
**Status:** implemented and **verified**. Immich 3.2.2 authenticates through Pocket ID,
local password login is disabled, and the public app and share surfaces are healthy.
John and leighanne are linked; Amanda is ready to link on her first Immich SSO sign-in.
**Scope:** the NAS `services.immich` unit in `dotfiles`, the Pocket ID client named
**Photos**, and the existing `default/immich-proxy` workload in this repository.

## Why

Immich had three existing accounts with photos and metadata but only local login.
The goal was to make Pocket ID the sole authentication path without creating new,
empty accounts or putting the OIDC client secret in the Nix store.

The migration deliberately kept password login enabled until the SSO path was
proven in production. John and leighanne linked their existing accounts before
the final switch. Amanda has an enabled Pocket ID account, a passkey, an exact
email match, and membership in the required group; the operator explicitly chose
to close password login before her first Immich SSO sign-in. She will link when
she uses the SSO button for the first time.

## 1. Pocket ID client

Pocket ID holds a confidential OIDC client named **Photos**:

- Client ID: `fc5eb5a2-013a-4c88-978f-fe2402839411`
- Public client: no
- Group restricted: yes, to the `immich` user group
- Token authentication: `client_secret_post`
- PKCE: S256
- Issuer: `https://au.2143.me`

The client has nine callback URLs:

1. `https://immich.ts.2143.me/auth/login`
2. `https://immich.ts.2143.me/user-settings`
3. `app.immich:///oauth-callback`
4. `http://nas.ts.2143.me:2283/auth/login`
5. `http://nas.ts.2143.me:2283/user-settings`
6. `http://192.168.5.175:2283/auth/login`
7. `http://192.168.5.175:2283/user-settings`
8. `http://100.64.0.14:2283/auth/login`
9. `http://100.64.0.14:2283/user-settings`

**This client exists only in Pocket ID's SQLite database.** It is not declarative
state in either repository. Restoring Pocket ID from a backup that predates this
client silently removes Immich SSO even if the NAS configuration is unchanged.
Recreate the client with the values above if that happens; the client secret must
still match the agenix value on the NAS.

## 2. NixOS configuration and secret delivery

Commit `74a8bfb` added the OIDC client and commit `8581262` closed local password
login. The authoritative configuration is the `services.immich.settings` block
in `dotfiles/nixos/nas-configuration.nix`:

```nix
services.immich.settings = {
  server.externalDomain = "https://images.2143.me";
  oauth = {
    enabled = true;
    issuerUrl = "https://au.2143.me";
    clientId = "fc5eb5a2-013a-4c88-978f-fe2402839411";
    clientSecret._secret = config.age.secrets.immich-oidc-client-secret.path;
    scope = "openid email profile";
    signingAlgorithm = "RS256";
    tokenEndpointAuthMethod = "client_secret_post";
    autoRegister = false;
    autoLaunch = false;
    buttonText = "Sign in with Pocket ID";
  };
  passwordLogin.enabled = false;
};
```

The client ID is a public identifier and is intentionally committed. The client
secret is encrypted at `dotfiles/secrets/immich-oidc-client-secret.age` for the
NAS recipient. systemd supplies `/run/agenix/immich-oidc-client-secret` through
`LoadCredential`; the unit's `preStart` reads that credential and uses `jq` to
replace the `_secret` marker while writing `/run/immich/config.json`. The value
never enters the Nix store or either repository.

The production unit runs with `PrivateUsers=yes`. This delivery path is proven:
John and leighanne both completed real authorization-code exchanges after the
initial switch.

## 3. Existing-account linking

Immich first looks up an OAuth user by the provider subject. If no subject is
linked, it normalizes the `email` claim and looks up the existing Immich account
by exact email. On a match it stores the Pocket ID subject in `oauthId`; it does
not create another account.

`autoRegister = false` is intentional. If a Pocket ID email does not match an
existing Immich email, authentication fails visibly instead of creating a second,
empty timeline. Fix the Pocket ID email rather than enabling automatic
registration. The three email pairs were verified before the cutover:

| Pocket ID user | Email | Immich linked at cutover |
|---|---|---|
| `John2143` | `john@2143.me` | yes |
| `leighanne` | `leighanneschmidt2707@gmail.com` | yes |
| `Amandistry.1` | `amanda.m.ross10@gmail.com` | pending first sign-in |

All three users are in the Pocket ID group `immich`, all three Pocket ID accounts
hold a passkey, and none is disabled. Pocket ID's `email_verified` flag is false
for leighanne and Amanda; this does not block Immich linking, as leighanne linked
successfully with the same flag.

### Verification

After activating commit `8581262` on the NAS:

- `/run/current-system` points to NixOS `26.11.20260923.4975466`.
- `immich-server` is active with `Result=success`, `ExecMainStatus=0`, and
  `NRestarts=0` after the activation.
- `/api/public/config` reports OAuth enabled and password login disabled.
- A password POST to `/api/auth/login` returns HTTP 401 with the exact body
  `{"message":"Password login has been disabled"}`.
- `https://immich.ts.2143.me/auth/login` returns HTTP 200.
- `https://images.2143.me/share/healthcheck` returns HTTP 200 with body `ok`.
- The Immich database reports `linked = true` for John and leighanne. Amanda is
  intentionally pending her first SSO sign-in.

The response message is the important password test. A wrong password returned
HTTP 401 before and after the switch; before the switch the message was
`Incorrect email or password`. In Immich 3.2.2, `AuthService.login()` checks
`passwordLogin.enabled` before comparing the password and throws
`UnauthorizedException('Password login has been disabled')`. There is no admin
exception.

## 4. Backup protection

Before the schema migration, a full logical dump was written to
`/tank/immich/backups/pre-sso-db-2026-09-21.sql.gz`. It passed `gzip -t` and
contains the `immich` database. It is outside the rolling
`immich-db-backup-*` retention glob and therefore remains until removed manually.

At final activation time the NAS held 14 nightly dumps. The newest was
`immich-db-backup-20260924T020000-v3.2.1-pg17.11.sql.gz`, created before the
3.2.2 switch. Do not remove the pre-SSO dump until a later file named
`immich-db-backup-<timestamp>-v3.2.2-pg17.11.sql.gz` exists and passes `gzip -t`.
The first expected run is 2026-09-25 at 02:00 EDT.

Immich does not support downgrading after its database migrations. A NixOS
system-generation rollback can restore the service package and unit but cannot
reverse the database schema. The logical dumps are the recovery path.

## 5. What remains

- **Amanda must sign in once through Pocket ID.** Her Pocket ID username is
  `Amandistry.1`; her email exactly matches the existing Immich account. After
  the sign-in, confirm the Immich row reads `linked = true` and that she lands on
  her existing timeline rather than an empty account.
- **Retire the pre-SSO dump only after the backup gate passes.** Confirm a
  post-switch `v3.2.2` nightly dump exists and passes `gzip -t`, then delete
  `/tank/immich/backups/pre-sso-db-*.sql.gz`.
- **SMTP is intentionally out of scope.** Neither Pocket ID nor Immich SMTP was
  configured as part of this migration.

## Gotchas for the next operator

- Setting `services.immich.settings` exports `IMMICH_CONFIG_FILE`. Immich then
  refuses configuration changes from the admin UI; edit Nix and rebuild instead.
- The NAS runs on EDT. Backup timestamps and the 02:00 schedule are local NAS
  time, while the workstation and HTTP response timestamps are UTC.
- Nest writes `WARN` in the application text while journald records stdout at
  priority `info`. `journalctl -p warning` can show no entries despite an auth
  warning. Search the message text, for example `journalctl -u immich-server
  --grep AuthService`.
- Password login has no admin exception. If Pocket ID becomes unreachable, set
  `passwordLogin.enabled = true`, commit and pull, then rebuild over SSH. SSH is
  the break-glass path, not an Immich account.
- Keep `autoRegister = false`. Enabling it to work around an email mismatch
  creates a second empty account instead of restoring access to existing photos.
- Do not close TCP 2283. The cluster reaches the NAS at `100.64.0.14:2283` via
  the `immich` EndpointSlice; closing the port breaks `immich.ts.2143.me`.
- The `images.2143.me` surface is the read-only `immich-public-proxy` Deployment,
  not the Immich application. It never authenticates users.
