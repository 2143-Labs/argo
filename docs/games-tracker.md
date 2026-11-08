# Games tracker: ArgoCD status scrape, tracker label, PR token

The games page on `status.john2143.com` (`games.html`) shows one card per
2143-Labs game with its environments, replicas, ROTS fleet size and every open
PR with its preview environment. This repository supplies three of its inputs:
ArgoCD sync/health metrics, the label that marks an Application as a game, and
the read-only GitHub token the gallery's chart renders. The game list, the feed
producer and the page all live in **2143-Labs/status**.

## 1. ArgoCD status in Mimir

`workloads/alloy/values-prod.yaml` scrapes `argocd-metrics.argocd.svc:8082`
every 30 s as job `argocd`, then keeps only `argocd_app_info` before remote
write. That single metric carries `name`, `sync_status` and `health_status` per
Application (134 series today). The controller's Service admits ingress from
every namespace (`argocd-application-controller-network-policy`), and Alloy
clusters — one peer wins the target hash — so it is reachable from any node.

Everything else the controller exports is dropped on purpose: per-Application
histograms for 130+ Applications would add thousands of series for a page that
needs three labels. The `keep` rule bounds the job at roughly one series per
Application.

```fish
# count(argocd_app_info) should track the Application count
curl -sG http://192.168.6.23:8080/prometheus/api/v1/query \
  --data-urlencode 'query=count(argocd_app_info)'
kubectl get applications -n argocd --no-headers | wc -l
```

If a card's sync/health stays blank, the metric is missing — the feed treats it
as advisory and falls back to replica-derived state, so nothing breaks. Check
the job in Grafana (`{job="argocd"}`) before touching the feed.

Validate the Alloy config before pushing a change to it; a bad config stops
metrics and logs on every node:

```fish
yq -r '.alloy.configMap.content' workloads/alloy/values-prod.yaml > /tmp/alloy.alloy
nix run nixpkgs#grafana-alloy -- validate /tmp/alloy.alloy
```

## 2. The `2143.me/tracker: game` label

Carried by the seven game Applications and by the five preview ApplicationSets'
`.spec.template.metadata.labels` (so each generated preview Application inherits
it):

| kind | files in `apps/` |
|---|---|
| prod | `dino-dash.yaml`, `moss-and-wool.yaml`, `how-poe-sale.yaml`, `rots-web.yaml`, `steam-lobby.yaml` |
| dev | `dino-dash-dev.yaml`, `moss-and-wool-dev.yaml` |
| preview ApplicationSets | `dino-dash-preview.yaml`, `moss-and-wool-preview.yaml`, `how-poe-sale-preview.yaml`, `rots-web-preview.yaml`, `steam-lobby-preview.yaml` |

```fish
kubectl get applications -n argocd -l 2143.me/tracker=game
```

That lists the labelled Applications now — one per preview that has an open PR.

**It is not `edge.2143.me/class: game`.** That tag is functional: it promises the
Application's chart depends on `helm_modules/game-edge`, which puts Anubis in
front of every route, and `scripts/validate-game-edge.sh` fails CI when a tagged
Application lacks that dependency (or has it untagged). `steam-lobby` cannot join:
its lobby API is called by native game clients rather than a browser, and an
Anubis challenge in front of it would break them. The tracker label is inert —
nothing consumes it but operators; the feed's game list is `GAMES` in the status
repo's `games_snapshot.py`.

## 3. GitHub token for the PR column

Fine-grained PAT, created at `github.com/settings/personal-access-tokens/new`:

- Resource owner **2143-Labs**; if the org requires approval, approve it under
  Org settings → Personal access tokens → Pending requests. Until then the API
  answers 403 and the page reports PRs as unavailable.
- Repository access: only `Dino-Dash`, `Moss-And-Wool`, `rots4`, `how.poe.sale`,
  `steam-lobby`.
- Permissions: **Metadata: read**, **Pull requests: read**. One-year expiry.

Store it, typing the value at the prompt (never on argv):

```fish
bao kv put -mount=consumers john2143-com/status-design/github-pr-reader token=-
```

The `-mount=` form matters: `bao kv put consumers/data/...` writes one level too
deep and ESO never finds it (see `adding-a-secret.md` §2).

The `games.githubKey` parameter in `apps/status-design.yaml` is the **only** place
in this repository naming that vault key. The `ExternalSecret` itself ships with
the gallery's own chart, `2143-Labs/status` `templates/github-token.yaml`, which
renders Secret `status-github` in `status-design` only when the parameter is set —
so no `status-pr-<N>` preview gets a token, and two Applications never fight over
one object. The key must exist before the parameter merges; otherwise the
ExternalSecret sits in `SecretSyncedError` and the page shows PRs unavailable.

**Rotation** (GitHub emails the owner a week before expiry): repeat both steps
above, then wait up to an hour for `refreshInterval: 1h`, or force it:

```fish
kubectl -n status-design annotate externalsecret status-github force-sync=$(date +%s) --overwrite
```

The `games` container re-reads the token file on every run, so no restart is
needed.

## 4. Troubleshooting

- **No PRs, page says unavailable.** `github.ok` is false in
  `curl -s https://status.john2143.com/games-live.json | jq .github` — it carries
  the reason (`no token`, or `<repo>: 401/403/404`). A 403 across all repos is
  almost always the pending org approval.
- **Feed not advancing.** `kubectl -n status-design logs deploy/status-design -c games`
  shows only failures; a Mimir outage makes the producer exit 2 and the sidecar
  keeps the last good file.
- **Secret not rendering.**
  `kubectl -n status-design get externalsecret status-github -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}'`
  should print `SecretSynced`. If ESO reports `permission denied`, move the key to
  `john2143-com/default/status-github-pr-reader` and change the parameter to match.

## 5. Adding a game

Not here. Add an entry to `GAMES` in 2143-Labs/status's `games_snapshot.py` and
the same id to `designs/games-sample.json`. Add its Application(s) to this
repository with whatever edge gating it needs, tag it
`2143.me/tracker: game` if it is a game, and add the repo to the PAT's repository
list if it should show PRs.
