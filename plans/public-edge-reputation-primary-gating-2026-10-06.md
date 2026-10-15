# Public edge: reputation-primary gating

**Board task:** 2143 Labs AI Tasks **#4** — "Public edge: real clients are never throttled or banned; stop abuse by reputation"
**Plan name:** `public-edge-reputation-primary-gating`
**Date:** 2026-10-06
**Status:** draft — three open decisions below block steps 6, 7 and 8
**Owner:** John (policy) · **Executor:** unassigned
**Repo:** `~/repos/argo` (home cluster, ArgoCD app-of-apps)

Acceptance criteria are referenced as `AC n` and live on task #4, not here. This file is the *how*; it contains no changes to #4's description.

## 0. Outcome

Every real client is served, and abuse is stopped by reputation and behaviour rather than by counting requests from an address inside a fixed window. Three user-visible faults close: the identity provider failing on a cold load, two real users banned by the WAF, and bans not being enforced on several public routes.

## 1. Design rule

One job per layer, and no layer second-guesses another.

| Layer | Job after this change |
|---|---|
| Router dst-nat | Reachability only. Unchanged. |
| `lan-only` address allowlist | Network boundary. Unchanged. |
| Reputation/WAF bouncer | **Primary gate.** Known-bad addresses, behavioural scenarios, community blocklist, and inline CVE virtual patching. |
| Concurrency cap | One job only: stop a client holding many connections open simultaneously. CrowdSec cannot see this — it observes requests only once they have completed and been logged. |
| Application | Owns auth and accounts, and any limit where a request costs money or guards an account. |
| Per-address request counter | **Removed.** |

## 2. Changes

### Step 1 — Remove every per-address request counter → AC 1, 2

Delete all `rateLimit` middleware and every route filter that references one:

| File | Definitions to delete |
|---|---|
| `workloads/gateway/security-middlewares.yaml` | `public-rate-limit`, `content-rate-limit` |
| `workloads/pocket-id/security-middlewares.yaml` | `public-rate-limit` |
| `workloads/openbao/` (inline in `apps/openbao.yaml`) | `public-rate-limit` |
| `workloads/stalwart/security-middlewares.yaml` | `public-rate-limit` — already orphaned; delete the whole file block |

Then remove the corresponding `ExtensionRef` filters: 20 route rules reference a `public-rate-limit` (18 in `default`, 1 in `pocket-id`, 1 in `openbao`), 2 reference `content-rate-limit` (`seafile`, `tasks`).

Also correct the comment block at the top of `workloads/gateway/security-middlewares.yaml`. It currently states that `excludedIPs` exempts LAN ranges "so home devices are never throttled". The opposite is true: setting `ipStrategy.excludedIPs` switches the source key from the socket address to the `X-Forwarded-For` header, which the websecure entry point strips because no `forwardedHeaders.trustedIPs` is configured. Traefik's `PoolStrategy` then returns an empty string for every request, so all clients share one bucket. That comment is the reason this went unnoticed for two months.

### Step 2 — One concurrency cap instead of two → AC 2, 9

Replace `public-inflight-limit` (50) and `content-inflight-limit` (2500) with a single value in all four namespaces. **Proposed: 300.**

- 300 sits above the number of requests one browser can have in flight at once over HTTP/2, so a cold page load cannot reach it.
- It is low enough that a client hoarding connections is still cut off, which is the only thing this control is for.
- Leave the bulk object-store route (`files.john2143.com`) uncapped; its traffic comes from in-cluster clients and this cap cannot exempt them.
- Keep `sourceCriterion.ipStrategy: {}`. That is `RemoteAddr`, it is correct, and it must not be given `excludedIPs`.

### Step 3 — WAF: drop the out-of-band rules, keep inline virtual patching → AC 3

In `apps/crowdsec.yaml`, in the `crs-vpatch` appsec config:

- **remove** `crowdsecurity/crs` from `outofband_rules`
- **keep** `inband_rules`: `crowdsecurity/base-config`, `crowdsecurity/vpatch-*`

This is a one-line change and it retires the whole false-positive class. It also removes the need for per-application AppSec exceptions, so Vikunja needs no special case.

### Step 4 — Reputation gate on every public route → AC 4, 5

Two bouncer variants stay. Assign by route class, never per application:

| Class | Variant | Routes |
|---|---|---|
| A — browser and login surfaces | `crowdsec-bouncer` (inline vpatch on) | `au.2143.me`, `grafana`, `images`, `john2143.com`, `matrix` `/`, `mattermost`, `terminals`, `status`, `cameras`, `temporal`, `chat`, `element`, friend sites, `listen`, `pvp`, `tasks`, `seafile` |
| B — machine, API and bulk bodies | `crowdsec-bouncer-noappsec` (vpatch off) | `files.john2143.com` (S3), `llm.2143.me` (prompt bodies), `openbao` `/v1/`, steam-lobby join-lobby API |

Gates to add (4 routes that currently have none or only an unrelated gate):

- `net.john2143.com`, `net.2143.me` (headscale) → class B
- `livekit.john2143.com` → class B
- `m.2143.me` (web key directory) → class A
- `containerstore.john2143.com` (registry) → class B, keeping its existing `basicAuth`

Exemptions, each with its reason (this list is the CI allowlist in step 8):

| Route | Reason |
|---|---|
| `argo-webhook.john2143.com`, `applicationset-webhook.john2143.com` | GitHub HMAC; GitHub addresses must never be banned |
| `matrix.2143.me` `/voice` rule | Protocol-level relay |
| `temporal-grpc` TLSRoute, `turn.john2143.com` listener | TLS passthrough, not HTTP — no HTTP middleware applies |
| port-80 redirect routes | Redirect only |

### Step 5 — Escalating ban duration → AC 7

`profiles.yaml`: uncomment `duration_expr` so the ban length grows with the address's prior decision count. Today every ban is a flat 4 hours, so a repeat offender returns about six times a day.

### Step 6 — Tailnet split DNS → AC 6 — *blocked, see open decisions*

`workloads/headscale/configmap.yaml` sets `override_local_dns: true` with global nameservers `1.1.1.1`/`1.0.0.1` and `split: {}`. Every tailnet device therefore resolves public hostnames through a public resolver, gets the WAN address, and hairpins out and back in. Two consequences:

1. All household devices appear at the edge as a single address, so any per-address control treats the household as one client.
2. The bouncer's trusted-client list contains a hard-coded WAN address (`108.56.153.222/32`) that exists to compensate. Verizon assigns that address by DHCP, so the entry silently becomes wrong and the household loses its protection from being banned.

Fix: add split DNS for `2143.me` and `john2143.com` pointing at an internal resolver that already holds the split-horizon records. **Pre-check required:** which internal resolver tailnet devices can actually reach, and whether it holds those records. Pi-hole (`192.168.6.27`) sits on an advertised subnet route; the router (`192.168.5.1`) may not be reachable over the tailnet.

Roll out on one canary device first — this changes name resolution tailnet-wide. Only after hairpin traffic is measurably near zero should the hard-coded WAN address be removed from the bouncer's trusted list, because guests and browsers with their own DNS-over-HTTPS will still hairpin.

### Step 7 — Alerts → AC 8 — *blocked, see open decisions*

Rules for all five, routed to the existing receiver:

| Rule | Signal |
|---|---|
| Backend error ratio | per-service 5xx rate above a floor for 15m (would have caught the object-store errors and the identity-provider failures) |
| No healthy backend | service 503 with zero origin response |
| Rejections on a host | sustained 429 at the entry point (after step 1 any 429 is meaningful) |
| Possible WAF false positive | 403 spike beyond a per-host baseline |
| Gate down | CrowdSec scrape target down — the gate fails open, so its health must notify |

Available without new instrumentation: `traefik_entrypoint_requests_total{code}` (has `429`/`403`), `traefik_service_requests_total{service,code}`, `traefik_open_connections`, and the two scraped CrowdSec jobs (`crowdsec-appsec`, `crowdsec-agent`). Note the **LAPI itself is not scraped**, so "gate down" can only be approximated from those two targets.

The five rules must be **declared in git**. The two existing rules (group `cluster`) live only in Mimir's ruler store, pushed by hand through the ruler API — the same undeclared-configuration pattern that bit the Longhorn backup target. Do not add five more rules that way.

### Step 8 — CI invariant → AC 4, 9 — *blocked, see open decisions*

Add a check alongside the existing `scripts/validate-*.sh` + `.github/workflows/validate-*.yml` pattern: every HTTPRoute on the shared gateway must carry either the LAN allowlist or a reputation gate, unless it appears on the exemption list from step 4. Five routes drifted to no gate at all; without a check this audit goes stale in weeks.

### Step 9 — App-native limits only where a request costs money or guards an account → AC 2, 3

- **Identity provider:** re-enable its built-in limiter (`DISABLE_RATE_LIMITING: "true"` → `"false"`). It is per-endpoint, app-aware, and already trusts the proxy header. It is the right control for the login surface; a global per-address bucket was a crude stand-in. **Must come after step 6**, or the household shares one login bucket.
- **LLM proxy:** per-key budgets and rate limits, so cost is bounded by key rather than by address.
- **oauth2-proxy clients (cameras, temporal):** confirm both are restricted to a group in the identity provider. They currently run with `--email-domain=*` and no group restriction, so unless the provider restricts the clients, any provider account can reach the camera dashboard and the Temporal UI. This is an access-control gap and it matters more than any rate limit in this plan.

### Step 10 — Record non-HTTP surfaces as accepted out of scope → AC 11

Mail (25/587/993), TURN, game servers, MQTT and the Tailscale coordination port have no reputation coverage. CrowdSec ingests only the proxy's access log, so it cannot see them, and nothing here changes that. State it in the estate docs as accepted, with the reason, rather than leaving it implicit.

## 3. Evidence

This plan removes protections, so the case for each removal is recorded.

**The counters stop nothing that the reputation layer misses.** Over 7 days, of 4,293 rejections served to addresses that CrowdSec had already flagged, **none occurred before that address was first blocked**. The counter changes the reply code for traffic that is blocked anyway. It sits earlier in the filter chain than the bouncer, so a banned address that keeps hammering receives the counter's rejection instead of the bouncer's.

**They cost real users.** ~900 rejections in 7 days reached clients that are not scanners: 478 on the identity provider, 287 on the LLM proxy, 69 on dashboards, 66 on the main site.

**Reproduced fault.** A cold load of the identity provider with an empty browser cache: 52 requests succeed, then 21 are rejected. The page renders blank because the rejections carry no content type, so the browser discards the script modules rather than showing an error.

**The out-of-band WAF rules are net-negative.** They banned 42 addresses; 37 were already caught by other detectors. Of the 5 unique ones, 2 were real users (an application's own filter syntax reads as injection) and 3 were a crawler reading static files.

**Inline virtual patching is not.** It flagged 83 addresses across 1,242 alerts and hit no known real client. Keep it.

**No limit setting can work.** Measured real-client peaks are ~120–150 requests per 10s; scanner peaks are ~200–480 per 10s. The two populations overlap by less than 3x, so no threshold separates them. Set high, it passes scanners; set low, it breaks humans.

**Structure.** All ingress is one gateway served by three proxy replicas, and the limiter's state is in memory per replica, so any limit is also per-pod and drifts with routing.

## 4. Rejected, with reasons

| Option | Why not |
|---|---|
| Split SPA routes by path to exempt assets | More configuration surface than the fault it fixes; the counter's problems remain for the API paths either way |
| Tune the counters per application | The threshold cannot separate the two populations (see evidence) |
| Redis-backed counters for cluster-wide accuracy | Adds a stateful dependency to the request path to make a control we do not want more accurate |
| CDN or third-party proxy in front | Large migration; cannot cover mail, TURN, games, LiveKit or federation; puts a third party in front of the identity provider; LAN clients bypass it anyway via split-horizon DNS |
| Block datacenter address ranges at the router | Most abuse arrives from them, but so does federation and CI traffic; needs an allowlist and breaks silently |
| Proof-of-work challenge for browsers | Wrong for the identity provider, APIs, S3 and federation; does not address the current fault, which is self-inflicted |
| Raise the reputation layer's thresholds | It is the layer that works. Raising it reduces the only effective defence |
| Per-application WAF exceptions | Unnecessary once step 3 removes the rule class that caused them |

## 5. Verification

| AC | How it is proven |
|---|---|
| 1 | Fresh browser profile, empty cache, load the identity provider: zero rejections. Corroborate in the access log for that client. |
| 2 | 7-day review: no rejection served to a client that is not independently flagged as abusive. |
| 3 | No new out-of-band AppSec alerts; replay the application filter query that previously caused a ban; no decision created. |
| 4 | Route inventory dump parsed for gate coverage: zero public routes without a gate. |
| 5 | The exemption list above exists in the repo, each entry with a reason. |
| 6 | From a tailnet device both on-LAN and off-LAN, the client address seen in the access log is the device's own address, not the WAN address. |
| 7 | Repeated simulated violations produce a longer ban each time. |
| 8 | A rule fires and a notification arrives. Confirm evaluation in the ruler, not just the rule's presence. |
| 9 | The check fails on a branch that adds a route without a gate. |
| 10 | From the WAN, requesting an internal-only host is refused by the LAN allowlist. |
| 11 | The accepted list is written down. |

## 6. Rollback

Steps 1–5 and 9 are declarative changes in this repo: revert the commit and let the sync apply. Note that after pushing, the affected application must be refreshed explicitly — Gateway API child applications do not reliably pick up a new revision on their own.

Step 7, if the rules are pushed through the ruler API instead of git, has no rollback except manual deletion. That is a second reason to declare them in git.

Step 6 is a tailnet-wide name-resolution change: revert the configmap and restart the coordination server; canary one device first.

## 7. Accepted risks

- **A fast run of requests from a fresh address to a cheap page is no longer limited by the proxy.** Reputation covers dynamic pages and a custom behavioural scenario would be its natural home, but the proxy itself no longer counts. Accepted because the uplink saturates before the backends would.
- **The gate fails open.** If the reputation service is unavailable, nothing is enforced. Mitigated by the alert in step 7. Failing closed would take every site down on each restart of a single-replica service, which is worse.
- **The household shares one address** until step 6 lands.
- **The exemption list is part of the review surface**: a route can be added to it to silence the CI check.

## 8. Out of scope

- Gate coverage for non-HTTP protocols (recorded in step 10).
- Two independent faults found during the investigation, which are not edge-policy problems: steady object-store errors generated by the logging stack, and intermittent 503s from the tailnet coordination server. Each needs its own task.

## 9. Open decisions — blockers

1. **AC 9 tension.** Keeping the gate per-route plus a CI check satisfies AC 4, but only partly satisfies AC 9, because a route author still learns of the requirement when the check fails. A gateway- or entry-point-level default satisfies AC 9 fully and cannot be forgotten — but the proxy's configuration is not in this repo (it is a Helm chart configuration in the NixOS host config, so changing it needs a rebuild on the host), and an entry-point default cannot exempt the webhooks.
2. **Which internal resolver** tailnet devices can reach, and whether it holds the split-horizon records. Blocks step 6.
3. **Alert rules in git or in the ruler API.** Blocks step 7.
4. Does the concurrency cap survive at all, and at what value. Affects step 2.
5. Is the identity provider's own limiter enabled here, or deferred. Affects step 9.

## 10. Files touched

```
workloads/gateway/security-middlewares.yaml      delete both counters, fix comment, cap
workloads/pocket-id/security-middlewares.yaml    delete counter, cap
workloads/openbao/ (in apps/openbao.yaml)        delete counter, cap
workloads/stalwart/security-middlewares.yaml     delete orphaned counter + bouncer
apps/crowdsec.yaml                               drop out-of-band rules; duration_expr
workloads/headscale/configmap.yaml               split DNS                        (step 6)
apps/mimir (rule declaration)                    five alert rules                 (step 7)
scripts/ + .github/workflows/                    route-gate invariant             (step 8)
workloads/pocket-id/configmap.yaml               re-enable built-in limiter       (step 9)
workloads/*/ingress.yaml|route.yaml              filter edits; gates on 4 routes
```

## 11. Noted, not acted on

- The router's forward chain accepts traffic between subnets inside `192.168.0.0/16`, which includes the upstream ISP router's LAN. Devices there are address-translated before reaching the cluster, so the LAN allowlist still sees a translated address — but the forwarding itself is broader than it looks.
- The proxy's own chart configuration lives outside this repo, so any entry-point-level change is a host rebuild rather than a GitOps change. Relevant to open decision 1.
