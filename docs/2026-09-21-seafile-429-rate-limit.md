# Seafile `429` incident: per-IP rate limits throttled photo browsing (2026-09-21)

**Status: COMPLETE and verified.** `seafile.john2143.com` rejected legitimate photo browsing with
`429` for at least two days — 2927 rejections in a six-hour window on 2026-09-20 and a further 1135 on
2026-09-21, every one of them on `GET /thumbnail/…`, from three client IPs. The route attached the
*shared* `public-rate-limit` (`average: 100`/1m, `burst: 50`) and `public-inflight-limit`
(`amount: 50`); both are keyed on client IP and both answer `429`, so either could reject a request.
A single folder view demands ~280 thumbnail GETs in about a second. Fixed by adding a dedicated
`content-*` tier at 50× the public values and attaching it to the Seafile route only. Post-fix: a real
client album load of 348 thumbnails over 19.4 s (peak 84 req/s, 302 req/min) completed with **zero**
`429`, and 300 concurrent requests returned `300 200`.

## 1. Commits (pushed, in order)

| commit | repo | message | content |
|---|---|---|---|
| `3b5bd56` | argo | fix(gateway): raise Seafile route per-IP limits 50x for photo browsing | `workloads/gateway/security-middlewares.yaml` — adds `content-rate-limit` (`average: 5000`, `period: 1m`, `burst: 2500`) and `content-inflight-limit` (`amount: 2500`), and rewrites the file header to document the two tiers; `workloads/gateway/seafile-route.yaml` — repoints the two `ExtensionRef` names, leaving `crowdsec-bouncer` untouched |

## 2. Symptom and measurement

Measured from the edge access logs (Loki, `namespace="kube-system"`, Traefik access logs). Traefik's
own logs rotate within seconds, so `kubectl logs` is useless here — query Loki.

| measurement | value |
|---|---|
| `429`s in a 6-hour window, 2026-09-20, all on `seafile.john2143.com` | **2927** |
| distinct client IPs throttled | **3** — `108.28.68.83` (1577), `108.56.153.222` (1040), `74.96.186.168` (300) |
| further `429`s on 2026-09-21 (00:00–14:40 UTC) | **1135** — `108.28.68.83` (835), `108.56.153.222` (300) |
| peak demand in one second | **278 requests** — 49 admitted, 229 rejected |
| sustained demand, worst client | **388 requests/minute** |
| longest single throttle | 85 minutes (`16:49`–`18:13`, 2026-09-20) |

Every rejected path was a photo thumbnail,
`GET /thumbnail/e0737687065b43a08b4e/256/<file>.JPG`; one client requested **298 distinct files** in a
single burst over HTTP/2. The 278-request second is a textbook token-bucket signature: 49 admitted is
the `burst: 50` bucket draining, and the 229 rejections are everything the 1.67/s refill could not
cover.

## 3. Cause: two independent per-IP limiters, both answering `429`

- `public-rate-limit` is a Traefik `rateLimit` token bucket: `burst: 50` is the bucket *capacity* and
  `average: 100`/`1m` is the *refill* rate (1.67/s). A folder view arrives faster than that refill, so
  the bucket drains and stays drained.
- `public-inflight-limit` is `inFlightReq`, `amount: 50` — a *concurrency* cap, not a rate.
- Both use `sourceCriterion.ipStrategy`, so both are keyed on the client IP, and **both answer `429`**
  when exceeded. That last point is why the incident looked like one fault: the client cannot tell the
  two apart.

**Both had to move.** Raising only `average`/`burst` would simply have moved the wall to the in-flight
cap, which a 280-request burst also exceeds.

## 4. The fix

A second middleware tier, `content-*`, at 50× the public values:

| middleware | `average` | `burst` | in-flight `amount` |
|---|---|---|---|
| `public-rate-limit` / `public-inflight-limit` (unchanged) | 100/1m | 50 | 50 |
| `content-rate-limit` / `content-inflight-limit` (new) | 5000/1m | 2500 | 2500 |

5000/min is ~13× the worst sustained demand ever measured (388/min) and 2500 is ~9× the worst
instantaneous peak (278), so no legitimate folder view or scroll can reach them while a runaway client
is still stopped.

The new tier is attached to the **Seafile route only**. The shared `public-rate-limit` object is
referenced by 20 other HTTPRoutes — 21 before this change, Seafile being one of them — including the
SSO provider (`pocket-id`) and `openbao-public-api`. Relaxing those 50× is not needed to deliver
photos. `excludedIPs` on `content-rate-limit` is copied verbatim from `public-rate-limit` so LAN and
tailnet behaviour is byte-for-byte unchanged. `crowdsec-bouncer` is left in place and unchanged: there
is no evidence of AppSec false positives on this route (exactly one AppSec-derived alert in the last
200 cluster-wide, from a scanner already banned for other reasons).

Middleware order on the route is significant and is now `content-rate-limit`,
`content-inflight-limit`, `crowdsec-bouncer` — the rate limit is evaluated first, so the generous
limiter is the one that answers.

## 5. How client IPs are actually presented

This determines what "per-IP" means here, and it was measured directly:

- **Remote clients get their real IP, each in its own bucket.** A phone on a VPN
  (`154.47.30.150`) loading an album appeared in the logs as `154.47.30.150` for all 358 of its
  requests, with no `X-Forwarded-For` — Traefik uses `RemoteAddr` directly because
  `externalTrafficPolicy: Local` preserves the source address.
- **LAN clients share the household WAN IP.** Hairpin NAT presents them all as `108.56.153.222`, which
  is why that address is explicitly listed in `crowdsec-bouncer`'s `clientTrustedIps`. Every device at
  home therefore draws on one bucket — at 5000/min that is a non-issue.

The WAN IP is deliberately **not** in `content-rate-limit`'s `excludedIPs`: keeping the operator's
traffic subject to the same limiter a client is means a test from the workstation genuinely reproduces
client conditions.

## 6. Verification (all passed)

| check | result |
|---|---|
| V1 — new middlewares live | `content-rate-limit` = `average 5000, period 1m, burst 2500` with the eight `excludedIPs`; `content-inflight-limit` = `amount 2500`, `ipStrategy: {}` |
| V2 — route wiring | filters in order: `content-rate-limit`, `content-inflight-limit`, `crowdsec-bouncer`; no `public-*` reference remains |
| V3 — 300 concurrent requests | `300 200`, **zero `429`** (pre-fix the same command returned ~250 `429`) |
| V4 — Loki, since cutover | zero `429` lines for `seafile.john2143.com`; the last `429` of the day was `14:10:30Z`, 55 min before the fix landed |
| V5 — regression guard | `public-rate-limit` still `100 50`, `public-inflight-limit` still `50`; 20 routes still on them |
| client truth — real album load | 358 requests in 19.4 s (348 thumbnails), peak **84 req/s**, **302 req/min**, **zero `429`** |

The client-truth row is the causal one. That load ran *after* the cutover, and under the old limits a
302-request minute would have admitted ~150 (the 50-token burst plus 100 tokens of refill) and
rejected ~150. It completed clean.

## 7. Watch items

- **A single client can now sustain 5000 requests/minute and 2500 concurrent.** The backend is nginx
  with `worker_processes auto` and `worker_connections 10000` (66 workers observed) in front of
  gunicorn `workers = 5, threads = 4`, so excess concurrency queues rather than fails. If the backend
  starts returning `502`/`503` under load, lower `content-inflight-limit`'s `amount` — the observed
  legitimate peak is 278, so anything at or above ~400 still passes every real folder view.
- **`immich-proxy` (`images.2143.me`) has the same shape and the same `public-rate-limit`.** It is
  currently producing no `429`s and was outside this ask, so it was not changed. It will hit the same
  wall on a large photo grid; attach `content-*` there if that appears.
- **If `429`s persist on Seafile**, confirm Traefik picked the middleware up (the HTTPRoute should show
  the new names, and `kubectl -n kube-system logs deploy/traefik | grep -i content-rate-limit`). The
  fallback is to raise `burst` further, not to remove the middleware.
- **Rollback** is `git revert 3b5bd56 && git push`. `selfHeal` restores the `public-*` attachments and
  `prune: true` deletes the now-unreferenced `content-*` objects — harmless, because the reverted route
  no longer names them. There is no data migration and no workload restart in either direction.
- **Seahub has its own `LOGIN_ATTEMPT_LIMIT = 5` / `LOGIN_ATTEMPT_TIMEOUT = 15 * 60`**, separate from
  edge rate limiting and untouched here; it had zero triggers during this incident.
