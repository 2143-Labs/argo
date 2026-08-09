# Ingress hardening: request telemetry + rate limiting + CrowdSec WAF (2026-08-09)

**Status: COMPLETE and verified.** Public web surfaces now have request-level telemetry (traefik JSON access logs → Loki), per-IP rate limiting, a per-IP in-flight cap, and a CrowdSec WAF (LAPI + agent + AppSec + traefik plugin bouncer) that bans abusive IPs with 403 and blocks known exploits inline. All 15 protected routes carry the 3-filter chain (`public-rate-limit` → `public-inflight-limit` → `crowdsec-bouncer`); the 10 internal `*.ts.2143.me` routes remain LAN-only via the pre-existing `lan-only` middleware.

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
- **CrowdSec** (chart 0.24.0): `crowdsec-lapi` (8080), `crowdsec-appsec` (7422, AppSec WAF with CRS virtual patching), `crowdsec-agent` DaemonSet reading traefik pod logs (`/var/log/containers/traefik-*.log`, program `traefik`). Collections: `crowdsecurity/traefik`, `crowdsecurity/appsec-virtual-patching`, `crowdsecurity/appsec-crs`. Bouncer key stored as the `crowdsec-bouncer-key` Secret in `kube-system` (never committed — the argo repo is public).
- **Bouncer**: `maxlerebourg/crowdsec-bouncer-traefik-plugin` **v1.7.1** loaded via `experimental.plugins` in the traefik HelmChartConfig; key file mounted at `/etc/traefik/secrets/crowdsec-bouncer-key`. Note: chart 40.1.3 has no pod-volume hook, so the secret volume is a live `kubectl patch` on the Deployment — it must be re-applied if the chart re-renders.
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

**Deliberate exclusions** (no filters): `argocd/ingress.yaml` (`argocd-webhook` — GitHub IPs must never be banned), `gateway/livekit-route.yaml`, `headscale/ingress.yaml` (net.john2143.com), `gateway/tuwunel-route.yaml` (chat.2143.me — voice relay), `steam-lobby/ingress.yaml` (pvp), `docker-registry/route.yaml`, `webserver/ingress.yaml` (rots.2143.me), all `*.ts.2143.me` internal routes (already LAN-only), `gateway/john2143-http-to-https.yaml` (port-80 redirect).

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

**S3 API surfaces use the no-AppSec bouncer**: `files.john2143.com` (`seaweedfs-s3`) serves machine S3 traffic (Loki, Tempo, tuwunel, workers). The CRS out-of-band rule flags Loki's encoded S3 object keys (`/loki-chunks/...` with `%3A`, `.tsdb.gz`) as suspicious and bans the shared WAN IP — taking down every public host for the household. So the S3 route uses `crowdsec-bouncer-noappsec` (IP-ban only, `crowdsecAppsecEnabled: false`) instead of the full `crowdsec-bouncer`. Web UIs keep full AppSec. If a new machine/API route is added, use the no-AppSec bouncer there too.

## 5. Operational notes

- **Ban/unban an IP**: `kubectl exec -n crowdsec deploy/crowdsec-lapi -- cscli decisions add --ip X -d 1h` / `cscli decisions delete --ip X`. The bouncer re-syncs within ~60s. `cscli decisions list` shows active bans.
- **AppSec model**: CRS runs out-of-band — SQLi/XSS probing is detected and the source IP is banned after the event threshold (6 events / ~30s observed). Inline vpatch rules cover known CVEs. AppSec failures are fail-open (`crowdsecAppsecFailureBlock`/`crowdsecAppsecUnreachableBlock: false`).
- **Rate limit tuning**: `average`/`burst` live in the `public-rate-limit` middleware; raise if a legit client (e.g. S3 syncs to files.john2143.com) trips 429s. In-flight cap (`amount: 50`) likewise.
- **The bouncer reads the socket RemoteAddr**, not `X-Forwarded-For` — a spoofed header will NOT bypass it, but equally, tests must come from the real client IP (external probe) or the LAN IP is used (exempt from rate limit only).

## 6. Known follow-ups (out of scope this run)

- Traefik 3.7.10 upgrade is blocked by chart 40.1.3's proxy-version cap; a k3s upgrade would land it (and with it `underscoreHeadersStrategy: reject` for CVE-2026-33433 — the entryPoints block is in the valuesContent and activates when the chart allows ≥3.7.6).
- The bouncer secret volume is a live deployment patch (chart 40.1.3 has no pod-volume hook) — re-apply `kubectl patch` after any traefik helm re-render.
- GitHub webhook delivery (argo-webhook.john2143.com) remains broken at the router — unaffected by this work.
- `Gateway/shared-gateway` shows a persistent ArgoCD OutOfSync drift (controller-owned status) — pre-existing, cosmetic.
