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

## Keep this file current

Board task #4 (public-edge reputation-primary gating, 2143 Labs AI Tasks) changes these gates. Every step of it that lands updates this file and `scripts/route-gate-exemptions.txt` in the same commit.
