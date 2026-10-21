# Public edge: gating routes on `shared-gateway`

Every HTTPRoute rule on `shared-gateway` carries exactly one of these gates. CI (`scripts/validate-route-gates.sh`) enforces it.

| Hostname | Gate (ExtensionRef filters, in this order) | Example |
|---|---|---|
| `*.ts.2143.me` (LAN + tailnet only) | `lan-only` | `workloads/immich/ingress.yaml` |
| Public, class A — browser and login surfaces | `public-rate-limit`, `public-inflight-limit`, `crowdsec-bouncer` | `workloads/gateway/grafana-route.yaml` |
| Public, class B — machine, API and bulk bodies (S3, LLM prompts, webhooks that are not GitHub's, upload APIs) | `public-rate-limit`, `public-inflight-limit`, `crowdsec-bouncer-noappsec` | `workloads/llm-proxy/httproute.yaml` |
| HTTP → HTTPS redirect | `RequestRedirect` only | `workloads/gateway/john2143-http-to-https.yaml` |

Definitions and values: `workloads/gateway/security-middlewares.yaml` (rate limits, bouncers) and `workloads/gateway/lan-only-middleware.yaml`. Do not copy values into docs.

## Rules

- **A `.ts.2143.me` rule always carries `lan-only`.** The name is private only in DNS; the gateway serves any routed hostname a client sends to the WAN address.
- **Class B, not A, for machine traffic.** `crowdsec-bouncer` runs AppSec body inspection, which misreads arbitrary request bodies and bans the sender's address. Hairpinned LAN traffic arrives as the household WAN address, so one false positive can take every public host down for the household. `crowdsec-bouncer-noappsec` keeps IP reputation bans and skips body inspection.
- **One host can mix classes by path.** Give each class its own rule (example: `workloads/steam-lobby/mm-route.yaml`, the `/joinlobby` rule is class B).
- **Middlewares resolve only in the route's own namespace.** A route outside `default` needs its own copies, identical to the `default` definitions (precedents: `workloads/pocket-id/security-middlewares.yaml`; `apps/openbao.yaml` `extraObjects`). When a `default` definition changes, change every copy in the same commit: `git grep -n 'name: crowdsec-bouncer' -- apps workloads`.
- **Per-route limits:** never lower the shared values. Define `<app>-rate-limit` / `<app>-inflight-limit` next to the route and point that route's filter at it, on the narrowest rule possible.
- **Who is exempt from what:** rate limits apply to everyone, LAN included (no `excludedIPs`; see the header comment in `security-middlewares.yaml`). CrowdSec checks skip the addresses in the bouncer's `clientTrustedIps` (LAN, tailnet, cluster ranges and the household WAN address), so a ban cannot be tested from home; test from an outside host.

## Ungated routes

The only rules without a gate are listed, with reasons, in `scripts/route-gate-exemptions.txt`. Adding a line there is a review decision: say why in the commit message.

## Anubis in front of an app

Anubis is not a gate: it sits behind the route's gate as the backend. Pattern
(live example: `status.2143.me`):

- `workloads/anubis-<app>/`: one Anubis Deployment + Service per app, reverse-proxy
  mode, `TARGET` = the app's Service, `REDIRECT_DOMAINS` = the app's hostnames,
  no `PUBLIC_URL`, default policy, persistent signing key.
- A failover `TraefikService` next to the route: Anubis first, the app's Service
  on `502-504`, so an Anubis outage serves the app unfiltered instead of failing.
- The route keeps its gate filters and points `backendRefs` at the TraefikService
  (`group: traefik.io`, `kind: TraefikService`, no port).
- Not for an identity provider, or anything else non-browser clients must reach.
  `au.2143.me` (pocket-id) is the case in point: `/authorize` and
  `/api/oidc/end-session` are browser navigations whose whole request rides in
  the query string, `/.well-known/` is the only OIDC path the stock policy
  allow-lists, and the stock policy challenges every `Mozilla|Opera` user
  agent — so a relying party using a browser-like HTTP client would get the
  challenge HTML wherever it expects JSON.

Example: `workloads/anubis-status/`, `workloads/gateway/status-route.yaml`.

## Not covered

Non-HTTP surfaces (mail 25/587/993, TURN, game servers, MQTT, TLS-passthrough listeners such as `temporal-grpc-mtls` and `turn-john2143-passthrough`) get no edge gate: CrowdSec reads only Traefik's HTTP access log.

## Troubleshooting

The bouncer plugin comes from a pinned copy on each control-plane node, defined once in `dotfiles/nixos/modules/k3s-server.nix`: the pods mount that store path, and the same directory is readable on the node at `/etc/traefik-plugins/crowdsec-bouncer-traefik-plugin`. Traefik runs with `abortOnPluginFailure`, so a replica that cannot load it exits instead of serving without it.

Node identity has two halves that can disagree. `--node-ip` fixes the Node's `InternalIP` (what the kubelet reports). The address pod traffic actually uses is the annotation `flannel.alpha.coreos.com/public-ipv6`, which flannel picks from the interface when it starts — on a host holding several global IPv6 addresses (DHCPv6 lease, SLAAC, temporary/privacy ones) it can pick a different one from the address `--node-ip` names. Measured 2026-10-21: arch's `InternalIP` is its EUI-64 SLAAC address while its annotation is the `fd00:1::5` DHCPv6 lease, and pite has the same shape (`::2`). Both hosts hold both addresses, so the mesh works. When debugging, compare FDB destinations against the **annotation**, never `ip -6 addr` and never the InternalIP.

| Symptom | Cause | Fix |
|---|---|---|
| A Traefik pod is in CrashLoopBackOff and its previous log says `failed to create plugin builder` | Plugin source missing or broken on that node | `ls /etc/traefik-plugins/crowdsec-bouncer-traefik-plugin/.traefik.yml` on the node; rebuild that node |
| A Traefik pod is stuck in ContainerCreating with a hostPath type error | The node has not been rebuilt since the plugin was added or bumped | Rebuild the node; when bumping the plugin, rebuild arch and nas before closet |
| A host sometimes returns Traefik's own 404 (19-byte `text/plain` body, `x-content-type-options: nosniff`) while other requests work | One replica has no router for it | Per replica: Mimir `sum by(instance) (rate(traefik_service_requests_total[5m])) / sum by(instance) (rate(traefik_entrypoint_requests_total[5m]))` — a value under 0.2 is the bad one, and `kubectl -n kube-system get pods -o wide` maps `instance` to a pod. Restart only that pod. No alert ships for this symptom; the query is the check. |
| Cross-node pod IPv6 fails for one or two nodes after some node's IPv6 address changed | Each node writes its flannel FDB entry for a peer when its own flannel starts, and those entries do not reliably follow a peer's new `public-ipv6` | On every node compare `bridge fdb show dev flannel-v6.1` destinations against the peers' `flannel.alpha.coreos.com/public-ipv6` annotations, then restart `k3s` on the stale nodes (or `bridge fdb replace <VtepMAC> dev flannel-v6.1 dst <new address>`). Changing any node's address therefore means restarting k3s everywhere. |

The `traefik-restarting` alert reads `kube_pod_container_status_restarts_total` from kube-state-metrics. Check that Mimir is ingesting that scrape before trusting silence: on 2026-10-21 its ingesters were rejecting writes (`failed pushing to ingester mimir-1: context deadline exceeded` in the Alloy logs) and held 2 of the 9 kube-system container series, so a restart on a replica without a series raises nothing.

## Keep this file current

Board task #4 (public-edge reputation-primary gating, 2143 Labs AI Tasks) changes these gates. Every step of it that lands updates this file and `scripts/route-gate-exemptions.txt` in the same commit.
