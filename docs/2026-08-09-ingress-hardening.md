# Ingress hardening: request telemetry + rate limiting + CrowdSec WAF (2026-08-09)

**Status: COMPLETE and verified.** Public web surfaces have request-level telemetry (traefik JSON access logs → Loki), per-IP rate limiting, a per-IP in-flight cap, and a CrowdSec WAF (LAPI + agent + AppSec + traefik plugin bouncer) that bans abusive IPs with 403 and blocks known exploits inline. The 15 routes listed in §3 carry the full 3-filter chain; the routes added in the 2026-09-18 pass (§7) carry either the full chain or the bouncer alone. The 10 internal `*.ts.2143.me` routes remain LAN-only via the pre-existing `lan-only` middleware.

## 1. Commits (pushed, in order)

| commit | repo | message | content |
|---|---|---|---|
| `638f377` | argo | fix(observability): cluster alloy scrape targets to stop mimir out-of-order drops | `apps/alloy.yaml` — `clustering { enabled = true }` in all 7 `prometheus.scrape` blocks (shards targets across the 4 DaemonSet pods; Mimir OOO drops → 0) |
| `7ec5a0e` | argo | feat(security): deploy crowdsec lapi+agent+appsec | `apps/crowdsec.yaml` (helm chart 0.24.0, releaseName crowdsec, ns crowdsec) |
| `c40284c` | argo | fix(crowdsec): add appsec listener acquisition so appsec pod starts | appsec acquisitions (source appsec, listen 0.0.0.0:7422) |
| `46b6ef6` | argo | fix(crowdsec): use crs-vpatch appsec config + COLLECTIONS env (chart CI pattern) | appsec configs `crs-vpatch.yaml` + `COLLECTIONS=crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-crs` |
| `088ba6a` | dotfiles | chore(k3s): enable traefik access logs + crowdsec bouncer plugin (3.7.10) | traefik HelmChartConfig valuesContent: image/accessLog/entryPoints/experimental.plugins/deployment volumes (superseded by fixes below) |
| `0022c4a` | dotfiles | fix(k3s): emit traefik HelmChartConfig via source (raw yaml) | nixpkgs `pkgs.formats.yaml` emits a `%YAML 1.1` directive the k3s helm-controller rejects → raw file via `source` |
| `85a7dc1` | dotfiles | fix(k3s): revert traefik image to 3.7.4 (chart 40.1.3 caps at v3.7.4) | chart 40.1.3 `traefik.io/proxy-max-version: v3.7.4` — 3.7.10 impossible without k3s upgrade |
| `4bc057f` | dotfiles | fix(k3s): wrap traefik valuesContent under spec.valuesContent | **outage fix** — the raw rewrite dropped `spec.valuesContent`, so the chart rendered with defaults and the Gateway provider went dark (all hosts 404/default-cert). Restored the key. |
| `dce226d` | dotfiles | fix(k3s): access log under chart key logs.access | chart 40.1.3 renders access from `logs.access` (not top-level `access`) → `--accesslog=true --accesslog.format=json` |
| `f6754b1` | argo | feat(security): add rate-limit, in-flight, crowdsec-bouncer middlewares | `workloads/gateway/security-middlewares.yaml` (default ns), `workloads/pocket-id/security-middlewares.yaml`, `workloads/stalwart/security-middlewares.yaml` |
| `b18ce2b` | argo | feat(security): protect public web surfaces with rate-limit, in-flight, crowdsec filters | 15 HTTPRoutes (below) gained the 3-filter chain |

## 2. What was deployed

- **Traefik 3.7.4** (rancher mirror — chart 40.1.3 caps the proxy version; the 3.7.10 upgrade was investigated and ruled out: the k3s-pinned chart validates against `traefik.io/proxy-max-version: v3.7.4`, so upgrading would require a k3s upgrade).
- **JSON access logs** (`logs.access.enabled` + `format: json`, header fields dropped) → shipped to Loki by alloy (relabels with `namespace`/`pod`/`container`). Query: `{namespace="kube-system", container="traefik"} | json` → `ClientHost` (real client IPs, preserved by `externalTrafficPolicy: Local`).
- **Alloy scrape clustering**: all 7 `prometheus.scrape` blocks now `clustering { enabled = true }` — each target scraped by exactly one DaemonSet pod. Mimir `err-mimir-sample-out-of-order` drops went to 0.
- **CrowdSec** (chart 0.24.0): `crowdsec-lapi` (8080), `crowdsec-appsec` (7422, AppSec WAF with CRS virtual patching), `crowdsec-agent` DaemonSet reading traefik pod logs (`/var/log/containers/traefik-*.log`, program `traefik`). Collections: `crowdsecurity/appsec-virtual-patching`, `crowdsecurity/appsec-crs`, plus `crowdsecurity/traefik` — but see §7: the Traefik collection was **not** actually installed in the standalone agent until 2026-09-18, so until then every access-log line was ingested and discarded and no log-based scenario could fire. Bouncer key stored as the `crowdsec-bouncer-key` Secret in `kube-system` (never committed — the argo repo is public).
- **Bouncer**: `maxlerebourg/crowdsec-bouncer-traefik-plugin` **v1.7.1** loaded via `experimental.plugins` in the traefik HelmChartConfig; key file mounted at `/etc/traefik/secrets/crowdsec-bouncer-key`. All of it is declarative: the plugin config lives in the HelmChartConfig in `dotfiles/nixos/closet-configuration.nix` (lines ~180-189), the key volume is part of that same HelmChartConfig render, and the Secret itself is created by the k3s bootstrap at `dotfiles/nixos/cluster/modules/k3s-common.nix:326`. There is no post-render `kubectl patch` to re-apply: a chart re-render reproduces the same volume.
- **Middlewares** (one copy per namespace — Gateway API `ExtensionRef` resolves only in the route's namespace):
  - `public-rate-limit` — 100 req/min avg, 50 burst, per source IP; LAN+tailnet ranges exempt (`excludedIPs`).
  - `public-inflight-limit` — 50 concurrent requests per IP (slowloris/connection-exhaustion cap → 429).
  - `crowdsec-bouncer` — LAPI stream mode (60s sync), AppSec enabled, fail-open on AppSec errors.

## 3. Protected routes (15)

All three filters attached to the route's `filters:` list (order: rate-limit → in-flight → bouncer).

| File (workloads/) | Route hostname | Namespace |
|---|---|---|
| `friends/aross/ingress.yaml` | aross.studio | default |
| `element-web/route.yaml` | element.john2143.com | default |
| `frigate-genai/triggers-ingress.yaml` | cameras.john2143.com | default |
| `gateway/grafana-route.yaml` | grafana.john2143.com | default |
| `immich-proxy/ingress.yaml` | images.2143.me | default |
| `imageserver/ingress.yaml` | john2143.com | default |
| `llm-proxy/httproute.yaml` | llm.2143.me | default |
| `gateway/matrix-route.yaml` | matrix.2143.me (non-voice rule) | default |
| `mattermost/route.yaml` | mattermost.john2143.com | default |
| `gateway/seafile-route.yaml` | seafile.john2143.com | default |
| `seaweedfs/ingress.yaml` | files.john2143.com | default |
| `gateway/status-route.yaml` | status.2143.me | default |
| `temporal-routes/httproute.yaml` | temporal.john2143.com | default |
| `pocket-id/ingress.yaml` | au.2143.me | pocket-id |
| `stalwart/ingress.yaml` | m.2143.me | stalwart |

**Deliberate exclusions** (no filters) are protocol-level only, because these routes cannot be rate-limited or banned as HTTP: `argocd/ingress.yaml` (`argocd-webhook` — GitHub IPs must never be banned), `gateway/livekit-route.yaml` (LiveKit signalling), `headscale/ingress.yaml` (net.john2143.com), `docker-registry/route.yaml` (OCI clients), the `/voice` rule inside `gateway/matrix-route.yaml` (voice relay), the TURN/TLS passthrough listener (not HTTP), the mTLS gRPC routes (Temporal), all `*.ts.2143.me` internal routes (already LAN-only via `lan-only`), and `gateway/john2143-http-to-https.yaml` (port-80 redirect). Everything else — including `chat.2143.me`, factorio, pelican, rots/prod.rots, pvp and the steam-lobby joinlobby API — is filtered; see §7.

## 4. Protecting a NEW public route

Append the three ExtensionRefs to the HTTPRoute rule's `filters:` (same shape as the `lan-only` commit):

```yaml
      filters:
        - type: ExtensionRef
          extensionRef: {group: traefik.io, kind: Middleware, name: public-rate-limit}
        - type: ExtensionRef
          extensionRef: {group: traefik.io, kind: Middleware, name: public-inflight-limit}
        - type: ExtensionRef
          extensionRef: {group: traefik.io, kind: Middleware, name: crowdsec-bouncer}
```

For a machine/API surface (S3, upload endpoints, webhooks that aren't GitHub), use `crowdsec-bouncer-noappsec` as the third filter instead of `crowdsec-bouncer` — see the S3 note below.

(The middleware must exist in the route's namespace; the default-ns copies are in `workloads/gateway/security-middlewares.yaml`.)

**S3 API surfaces are bouncer-only**: `files.john2143.com` (`seaweedfs-s3`) serves machine S3 traffic (Loki, Tempo, tuwunel, workers). Two problems arise when the web middlewares are applied to it: (1) the CRS out-of-band rule flags Loki's encoded S3 object keys (`/loki-chunks/...` with `%3A`, `.tsdb.gz`) as suspicious and bans the shared WAN IP — taking down every public host for the household; (2) the web rate-limit/in-flight caps throttle Loki/Tempo compaction bursts (which arrive as the WAN IP via hairpin, so excludedIPs doesn't exempt them). So the S3 route uses **only `crowdsec-bouncer-noappsec`** (IP-ban, `crowdsecAppsecEnabled: false`) — S3 auth itself rejects anonymous access, and the bouncer covers abuse. Web UIs keep the full 3-filter chain. If a new machine/API route is added, use the bouncer-only pattern there too.

## 5. Operational notes

- **Ban/unban an IP**: `kubectl exec -n crowdsec deploy/crowdsec-lapi -- cscli decisions add --ip X -d 1h` / `cscli decisions delete --ip X`. The bouncer re-syncs within ~60s. `cscli decisions list` shows active bans.
- **AppSec model**: CRS runs out-of-band — SQLi/XSS probing is detected and the source IP is banned after the event threshold (6 events / ~30s observed). Inline vpatch rules cover known CVEs. AppSec failures are fail-open (`crowdsecAppsecFailureBlock`/`crowdsecAppsecUnreachableBlock: false`).
- **Rate limit tuning**: `average`/`burst` live in the `public-rate-limit` middleware; raise if a legit client (e.g. S3 syncs to files.john2143.com) trips 429s. In-flight cap (`amount: 50`) likewise.
- **The bouncer reads the socket RemoteAddr**, not `X-Forwarded-For` — a spoofed header will NOT bypass it, but equally, tests must come from the real client IP (external probe) or the LAN IP is used (exempt from rate limit only).

## 6. Known follow-ups (out of scope this run)

- Traefik OTLP traces: fixed 2026-08-09 (commit `39ee505` dotfiles) — `tracing.otlp.grpc.enabled: true` was missing, so the endpoint was never rendered and Tempo had 0 traces. Now flowing: `traefik` spans → alloy OTLP → Tempo (verified 50+ traces/10m).
- Traefik 3.7.10 upgrade is blocked by chart 40.1.3's proxy-version cap; a k3s upgrade would land it (and with it `underscoreHeadersStrategy: reject` for CVE-2026-33433 — the entryPoints block is in the valuesContent and activates when the chart allows ≥3.7.6).
- The bouncer secret volume is a live deployment patch (chart 40.1.3 has no pod-volume hook) — re-apply `kubectl patch` after any traefik helm re-render.
- GitHub webhook delivery (argo-webhook.john2143.com) remains broken at the router — unaffected by this work.
- `Gateway/shared-gateway` shows a persistent ArgoCD OutOfSync drift (controller-owned status) — pre-existing, cosmetic.

## 7. Update 2026-09-18 — detection actually switched on

The 2026-09-17 network review found that this work looked complete but was not detecting anything: the standalone agent had **no Traefik collection**, so the JSON access logs it read were parsed by generic CRI/docker parsers and dropped, and `cscli metrics` showed an empty scenario table. AppSec (inline, in its own namespace) was the only thing working.

What changed:

| Change | File |
|---|---|
| `COLLECTIONS=crowdsecurity/traefik` on the standalone agent (the image's own `prepare_hub` installs it) | `workloads/crowdsec-agent/agent-daemonset.yaml` |
| Acquisition switches from inotify to `poll_without_inotify: true` / `force_inotify: false` — the log file is a rotating symlink inotify cannot follow, which logged a warning on every agent | `workloads/crowdsec-agent/agent-config.yaml` |
| Filters attached to the routes that had none: `chat.2143.me` (full chain), factorio and pelican (bouncer), the steam-lobby joinlobby API (rate limit + in-flight + `crowdsec-bouncer-noappsec`), rots/prod.rots and pvp (full chain) | `workloads/gateway/tuwunel-route.yaml`, `workloads/factorio/ingress.yaml`, `workloads/pelican/ingress.yaml`, `workloads/steam-lobby/mm-route.yaml`, `workloads/webserver/ingress.yaml`, `workloads/steam-lobby/ingress.yaml` |

Verified: a 40-request 404 sweep from an external host produced a **`crowdsecurity/http-probing` alert and a ban** in `cscli alerts list` / `cscli decisions list`, and the bouncer began returning 403 mid-sweep. That scenario only fires from the log-based path, so it is the evidence that the parser is now live — the 50 pre-existing alerts were all AppSec/vpatch, none log-based. (Note: an IP banned this way stays blocked until the bouncer's 60-second decision-stream sync picks up the deletion, so `cscli decisions delete` is not instant.)

### Pruning stale bouncer/machine records — and the rule that makes it safe

Records accumulate because every Traefik replica and every agent pod restart registers a new one: this pass started at 46 bouncers and 75 machines against 3 Traefik pods and ~6 live identities.

**The safe predicate is `auto_created`, not age alone.** CrowdSec records `auto_created=true` for the per-replica registrations that appear on their own, and `auto_created=false` for the records an operator created with `cscli bouncers add -k <key>` — the latter carries the key that Traefik is configured with, and it is the anchor all the auto-created records hang off. Deleting the anchor (which a pure age filter does, since its `last_pull` can be weeks old) stops the LAPI authenticating the plugin entirely. That happened during this pass and was fixed by re-adding the record with the key from the `crowdsec-bouncer-key` Secret; it is why any automated prune must exclude `auto_created=false`.

Machines have no such field, but agents heartbeat frequently, so a 7-day `last_heartbeat`/`last_push` filter is safe there — verified by pruning 37 stale machines with every live agent, the LAPI and AppSec untouched.

The prune itself needs LAPI admin access, which exists only inside the `crowdsec-lapi` pod (`/etc/crowdsec/local_api_credentials.yaml` is not exposed as a Secret, and the agents run with `DISABLE_LOCAL_API=true` so they cannot administer anything). It was therefore run by hand, once:

```bash
kubectl -n crowdsec exec -i deploy/crowdsec-lapi -- sh -s <<'EOF'
cscli bouncers list -o json | yq -r '.[] | select(.auto_created == true) | select((.last_pull // "") < "2026-09-11T00:00:00Z") | .name' \
  | while read -r n; do cscli bouncers delete "$n"; done
cscli machines list -o json | yq -r '.[] | select(((.last_heartbeat // "") < "2026-09-11T00:00:00Z") and ((.last_push // "") < "2026-09-11T00:00:00Z")) | .machineId' \
  | while read -r n; do cscli machines delete "$n"; done
EOF
```

There is no scheduled version of this yet, on purpose: the plan called for a daily CronJob authenticating with `crowdsec-lapi-secrets`, but that Secret holds only `csLapiSecret` and `registrationToken` (usable to *register*, not to administer), the image has no `jq`, and none of the images already on the nodes contain `kubectl`. Automating it needs either an admin credential exposed to a job or a `pods/exec` grant plus a new image — a decision for the owner, not a side effect of this pass.
