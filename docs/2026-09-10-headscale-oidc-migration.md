# Headscale OIDC migration to Pocket ID (2026-09-10)

Derived from: live cluster state (`kubectl exec deploy/headscale -- headscale …`),
`headscale policy get`, `sudo tailscale debug netmap` on `office`, and the headscale
v0.27.1 source (`hscontrol/app.go`, `hscontrol/db/users.go`, `hscontrol/db/schema.sql`).

Pilot migration: `john2143` only. All other humans and both machine identities are untouched.

## OIDC settings now in effect

`workloads/headscale/configmap.yaml` (`config.yaml` → `oidc:`):

| Setting | Value |
|---|---|
| issuer | `https://au.2143.me` (Pocket ID v2.8.0) |
| client_id | `e650ddc2-f11b-4ce6-ab0b-5d6b1d492dfd` (public identifier) |
| client_secret | env `HEADSCALE_OIDC_CLIENT_SECRET`, from Secret `headscale-oidc` (never in git) |
| scope | `openid`, `profile`, `email` |
| pkce | enabled, `S256` |
| expiry | `3y` (1095d) |
| use_expiry_from_token | `false` |
| only_start_if_oidc_is_available | `true` (fail fast rather than silently fall back to CLI auth) |

Pocket ID side: callback URL `https://net.john2143.com/oidc/callback` (exact — no trailing slash),
Public Client **off**, Allowed User Groups = `headscale`. Pocket ID denies all access to a client
until that group is configured, so the gate lives entirely in the IdP; headscale sets no
`allowed_domains` / `allowed_users` / `allowed_groups`.

## Result

| | |
|---|---|
| SSO user | id **14** — username `John2143`, name `John Schmidt`, email `john@2143.me` |
| Nodes moved | 13: `1 2 3 4 5 6 7 8 14 17 26 27 28` (`headscale nodes move -i <node id> -u 14`) |
| Node expiry | OIDC nodes expire at login + 3y (the pilot node showed `2029-09-09`); CLI/preauth nodes remain `N/A` |
| Final ACL | `"src": ["john@2143.me"]` on the `192.168.5.0/24` + `192.168.6.0/24` rule |
| `office` identity | `UserID 14` → `LoginName john@2143.me` |

No interruption: the ACL carried **both** `john2143@` and `john@2143.me` across the move, so the
subnet grant never went dark (partial alias resolution keeps the rule alive). The canary
(`tailscale debug netmap | grep -c '192.168.6.0/24'` → 4, `'192.168.5.0/24'` → 5, measured on
`office`) read the same values before the change, after the moves, and after the collapse.

## Deviation: the old CLI user is retained

`headscale users destroy -i 1 --force` **fails** with
`Cannot destroy user: constraint failed: FOREIGN KEY constraint failed (787)`.
The user owns no nodes, so the block is its preauth keys: `DestroyUser` hard-deletes them, but
`nodes.auth_key_id` references `pre_auth_keys(id)` with no `ON DELETE` action, and the 13 moved
nodes still point at those used keys. The user is left in place deliberately — it is inert (no
nodes, no API keys) and the policy no longer references it. To remove it later, clear
`nodes.auth_key_id` for those rows (or delete the nodes) first.

## Operating notes

- A ConfigMap change does **not** restart the pod: the Deployment carries no reloader annotation and
  stakater/reloader only acts on annotated workloads. The image is distroless (no `sh`, `cat`,
  `kill`), so the policy cannot be reloaded with SIGHUP from inside the container. **Restart the pod
  to load config or policy changes:**
  `kubectl -n default delete pod -l app=headscale`
- `headscale policy get` prints the policy the **running server** has loaded — use it to confirm a
  reload happened, rather than reading the file on disk.
- Deleting a node that is still connected can leave stale in-memory state, which surfaces as
  repeating `generating map response for node N: node not found` errors in the logs. A pod restart
  clears it.
- Pre-validate config edits before pushing: run the ConfigMap's embedded `config.yaml` through
  `headscale configtest` in a throwaway container (see the note in the PR/commit for this change).

## Migrating the remaining users

Per person, once they have a Pocket ID account in group `headscale`:

1. Materialise their SSO user with a throwaway client (`docker.io/tailscale/tailscale:stable`,
   `--tun=userspace-networking`) and `tailscale up --login-server=https://net.john2143.com`; they
   complete the Pocket ID login themselves. Delete the throwaway node and container afterwards.
   Do **not** re-auth a real device as the new user — headscale creates a duplicate node.
2. Read their new row in `headscale users list`; note the id and email.
3. Add their token to the matching rule in `policy.hujson` **alongside** the legacy `name@` token,
   push, and restart the pod.
4. `headscale nodes move -i <node id> -u <new user id>` for each of their nodes.
5. Collapse the rule to the new token only, push, restart the pod.
6. Destroy their CLI user if you can (it will fail with the FK caveat above for anyone whose preauth
   keys are still referenced by live nodes).

Still CLI-managed: `browntown`, `dsstar`, `jim`, `rain`, `mystique`, `ewan`, `amanda`, `leigh`,
`mafuyu`, `ms_mafuyu`. Machine identities `system_john` and `system_doks` stay on preauth keys.

**Caveat:** migrating a user destroys that user's preauth keys, so keys must be re-issued under the
SSO user for any device that still authenticates with one.

## Rollback

`git revert` the three commits — `f7f85f6` (enable OIDC), `9f1285b` (two-token ACL), `daf7fd6`
(collapse ACL) — then restart the pod. Nodes keep working throughout: node keys and IPs are
untouched by OIDC and by `nodes move`. Because the CLI user was retained, node ownership can also be
handed back with `headscale nodes move -i <node id> -u 1`.
