# Argo CD: GitHub push webhook, signed with a secret from OpenBao

**Date:** 2026-09-29
**Status:** implemented and **verified**. A push to `main` now reaches Argo CD within about a second. Deliveries are HMAC-signed, and argocd-server rejects unsigned or forged requests.
**Scope:**
- GitHub hook `662488712` on `2143-Labs/argo`.
- GitHub hook `663721590` on `2143-Labs/steam-lobby`.
- OpenBao entry `consumers/data/john2143-com/argocd/webhook-github`.
- `workloads/secrets/argocd-webhook-github.yaml`.
- `Secret/argocd/argocd-secret`, which gains the key `webhook.github.secret`.

## What it does

1. On a push to `2143-Labs/argo`, GitHub POSTs to `https://argo-webhook.john2143.com/api/webhook`.
   - The route is HTTPRoute `argocd-webhook` in `workloads/argocd/ingress.yaml`, pointing at `argocd-server:80`.
   - The route has **no filters, on purpose**: a CrowdSec ban or rate limit must never block GitHub's IPs.
2. argocd-server checks the `X-Hub-Signature-256` HMAC against `webhook.github.secret` in `argocd-secret`. It then refreshes every Application whose source is `https://github.com/2143-Labs/argo.git` at `HEAD`, since a push to the default branch `main` counts as `touchedHead: true`.
   - That is 68 Applications today.
   - None of them sets `argocd.argoproj.io/manifest-generate-paths`, so every push refreshes all of them. That is the same load the poll already caused.
3. Auto-sync applies the change. Polling (`timeout.reconciliation`, default 180 s) is unchanged and stays as the fallback when a delivery is lost.

Measured on the push of `9c09579`:
- Pushed at 18:17:08Z.
- GitHub delivery `push 200` at 18:17:09Z.
- The `secrets` app was `Synced` at `9c09579` by 18:17:10Z.

Before this change, the same measurement was about 114 s (`27bad5f`: pushed 21:40:59Z, auto-synced 21:42:53Z). That was pure polling.

## Why it was broken until 2026-09-29

- Hook `662488712` had existed since 2026-08-07 with `content_type: form`.
- Argo CD parses only JSON, so every delivery returned 400. The argocd-server log showed `Webhook processing failed: invalid character 'p' looking for beginning of value`, and GitHub's response body showed `Webhook processing failed`.
- It was **never a router problem**. The HTTPRoute, the gateway listener and DNS had worked end to end the whole time.
- The earlier note in `2026-08-09-ingress-hardening.md` said otherwise and has been corrected.

The fix switched the hook to `content_type: json` and added a secret on both sides.

## Where the secret lives

| Where | What |
|---|---|
| OpenBao | `consumers/data/john2143-com/argocd/webhook-github`, key `secret` (64 hex chars) |
| ExternalSecret | `argocd/webhook-github` (`workloads/secrets/argocd-webhook-github.yaml`, owned by the `secrets` Application) |
| Kubernetes | `Secret/argocd/argocd-secret`, key `webhook.github.secret` |
| GitHub | `config.secret` on hooks `662488712` (argo) and `663721590` (steam-lobby); write-only, GitHub shows it masked |

The vault key is `secret`. The ExternalSecret maps it onto the dotted Argo key name explicitly through `data[].remoteRef.property`. It does not use `dataFrom.extract`, so anything added to the vault entry later can never land in `argocd-secret`.

The ExternalSecret is **`creationPolicy: Merge`**, unlike every other file in `workloads/secrets/`, which use `Owner`:
- argocd-core (`bootstrap/argocd/install.yaml`) creates `argocd-secret`, and it holds Argo CD's own keys: `admin.password`, `admin.passwordMtime`, `server.secretkey`, `tls.crt`/`tls.key` and `oidc.au.clientSecret`.
- `Owner` would replace the whole Secret and destroy those keys.
- `Merge` adds the one key and never creates the Secret. If `argocd-secret` is missing, the ExternalSecret reports `SecretMissing` and does nothing.

`target.template` (`engineVersion: v2`, `mergePolicy: Merge`, no templates) is **required**:
- When `target.template` is nil, ESO copies the ExternalSecret's own labels and annotations onto the target Secret. You can see this on any Owner-rendered Secret here: it carries the ExternalSecret's `argocd.argoproj.io/tracking-id`.
- On `argocd-secret` that copy would overwrite argocd-core's tracking-id (`argocd-core:/Secret:argocd/argocd-secret`).
- Setting the template turns the copy off. Provider data still passes through untouched.

ESO does add its own `reconcile.external-secrets.io/managed=true` label and `reconcile.external-secrets.io/data-hash` annotation to `argocd-secret`. argocd-core stayed `Synced` after the merge (its `ignoreDifferences` in `apps/argocd-core.yaml` already covers `/data`). If it ever reports OutOfSync on those two fields, add them to that same `ignoreDifferences` entry as `jqPathExpressions`.

Verified after the merge:
- `argocd-secret` holds exactly the 7 previous keys plus `webhook.github.secret`.
- The tracking-id is unchanged.
- `argocd-core` and `secrets` are both `Synced/Healthy`.

## Consumers of the same key

| Component | Hook | Picks up a new value |
|---|---|---|
| argocd-server | `662488712` on `2143-Labs/argo` (`push`) → `argo-webhook.john2143.com/api/webhook` | Within seconds. `watchSettings` notices the change and logs `github secret modified. restarting` (an in-process restart, not a pod restart) |
| argocd-applicationset-controller | `663721590` on `2143-Labs/steam-lobby` (`pull_request`) → `applicationset-webhook.john2143.com/api/webhook` | **Only at startup.** It reads the settings once in `NewWebhookHandler` |

A ping to `663721590` after the change returned `200`.

The applicationset-controller was deliberately **not** restarted, so it keeps accepting unsigned events until its next natural restart. GitHub already signs with the matching secret, so nothing breaks when enforcement starts.

## Rotation

The order matters. Setting the secret on GitHub before Argo means a mismatch only costs webhook-driven refreshes, and polling covers those. Commands are fish, run from the repo root. `bao` and `openssl` are not on PATH.

```fish
umask 077
od -An -vtx1 -N32 /dev/urandom | tr -d ' \n' > /dev/shm/argo-webhook-secret
test (wc -c < /dev/shm/argo-webhook-secret | string trim) = 64; and echo LEN_OK
jq -n --rawfile s /dev/shm/argo-webhook-secret '{secret: $s}' > /dev/shm/argo-webhook-bao.json
jq -n --rawfile s /dev/shm/argo-webhook-secret '{content_type: "json", secret: $s}' > /dev/shm/argo-webhook-gh.json

# 1. OpenBao. Use -mount=consumers with NO data/ prefix.
BAO_ADDR=https://openbao.ts.2143.me nix run nixpkgs#openbao -- kv put -mount=consumers john2143-com/argocd/webhook-github @/dev/shm/argo-webhook-bao.json

# 2. Both GitHub hooks.
gh api -X PATCH repos/2143-Labs/argo/hooks/662488712/config --input /dev/shm/argo-webhook-gh.json --jq '{content_type, url}'
gh api -X PATCH repos/2143-Labs/steam-lobby/hooks/663721590/config --input /dev/shm/argo-webhook-gh.json --jq '{content_type, url}'

# 3. Render now instead of waiting up to refreshInterval (10m). This is an operator action.
kubectl -n argocd annotate externalsecret webhook-github force-sync=(date +%s) --overwrite

# 4. The applicationset controller only reads the secret at startup.
kubectl -n argocd rollout restart deploy/argocd-applicationset-controller

shred -u /dev/shm/argo-webhook-secret /dev/shm/argo-webhook-bao.json /dev/shm/argo-webhook-gh.json
```

Between step 2 and step 3, argo deliveries return 400 with `HMAC verification failed`, and Argo falls back to polling. This is harmless.

Never read the value back from OpenBao, GitHub or Kubernetes to "check" it. List key names only.

## Verify

```fish
# Recent deliveries: expect push 200.
gh api "repos/2143-Labs/argo/hooks/662488712/deliveries?per_page=5" --jq '.[] | [.delivered_at, .event, .status_code] | @tsv'

# Send a real push event of the latest commit on demand.
gh api -X POST repos/2143-Labs/argo/hooks/662488712/tests

# argocd-server: expect "Received push event … touchedHead: true" plus N x "refreshing app from webhook".
# Always filter these logs: unfiltered argocd-server output includes OIDC login lines.
kubectl -n argocd logs deploy/argocd-server --since=5m | jq -Rr 'fromjson? | select(.msg | test("Received push event|refreshing app from webhook|Webhook processing failed|HMAC")) | .msg' | string replace -r 'refreshing app from webhook.*' 'refreshing app from webhook' | sort | uniq -c

# Enforcement: a forged signature must be rejected with 400, logged as "GitHub webhook HMAC verification failed".
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://argo-webhook.john2143.com/api/webhook \
  -H 'Content-Type: application/json' -H 'X-GitHub-Event: push' \
  -H 'X-Hub-Signature-256: sha256=0000000000000000000000000000000000000000000000000000000000000000' \
  --data '{}'

# The ExternalSecret and the key (names only).
kubectl -n argocd get externalsecret webhook-github
kubectl -n argocd get secret argocd-secret -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}'
```

Results on 2026-09-29:
- Signed test delivery: `push 200`.
- Forged signature: `400`, logged as `HMAC verification failed`.
- Missing signature header: `400`, logged as `missing X-Hub-Signature-256 Header`.

## Gotchas

- **The content type must be `json`.** A `form` hook fails every delivery with 400. Argo does not accept form-encoded bodies.
- **Never switch the ExternalSecret to `Owner`**, and never drop `target.template`. See above.
- **Once argocd-server has a secret, unsigned deliveries are rejected.** Any new GitHub hook pointing at either webhook host must be given the same secret.
- **Leftover key:** `argocd-secret` still holds `applicationset.webhook.github.secret`, written earlier by a `kubectl patch`. Argo CD v3.5.2 never reads that key; the applicationset controller uses `webhook.github.secret` as well. It is harmless. Removing it takes an imperative patch, which is left to the owner.
