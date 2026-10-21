# Partial config at startup: two Traefik replicas lost every `*.john2143.com` router (2026-10-17 → 2026-10-18)

Two of the three Traefik replicas started during the node-reboot wave with an incomplete configuration. They served Traefik's own 404 for **every** `*.john2143.com` host and most `*.2143.me` hosts for about twelve hours, stayed Ready and in the Service the whole time, and reported healthy gateway status. It was found by accident, not by an alert.

## Timeline (UTC)

| Time | Event |
|---|---|
| 10:04 – 12:05 | All six nodes reboot. |
| 11:43:07 / 11:43:08 | Replicas `traefik-59cdf7565d-79jtq` and `-hs4l2` start, both on `arch`. |
| (through 00:19) | Both serve the 404 to `*.john2143.com` and most `*.2143.me`; `*.ts.2143.me` and `m.2143.me` keep working (different listeners). |
| ~00:19 (10-18) | Fixed by deleting the two pods one at a time, deliberately keeping `pbb4f` (started 00:57 the day before, correct throughout). Replacements `966pd` (nas) and `nr2kt` (arch) come up complete. |

## Evidence

- `files.john2143.com` alone logged **6,149 and 4,510** no-router 404s over the twelve hours on those two pods, and **zero** routed requests.
- The third replica (`pbb4f`) was correct the entire time, so the pre-change baseline was recoverable: after the fix, 50 routed hosts × 3 replicas agreed exactly with it.
- Gateway status looked perfect throughout — generation 63, 12 listeners, `Accepted=True`, `Programmed=True`, `attachedRoutes` 18/11/12 — **because every replica writes status and the healthy one won the last write**. Status is not evidence about a particular replica.
- `RouterName` is absent from the access-log lines: the request arrived and matched no router, which is the same 19-byte `text/plain` 404 signature as the plugin outage.

## Mechanism (verified in v3.7.13 source)

- `pkg/provider/kubernetes/gateway/httproute.go:66-71` increments `listener.Status.AttachedRoutes` for an accepted route **before** the `if accepted && listener.Attached` gate at `:74` decides whether that route's routers are merged into the configuration.
- `pkg/provider/kubernetes/gateway/kubernetes.go:625-664` leaves a TLS listener **not** `Attached` when its certificate Secret cannot be resolved (`ResolvedRefs=False`, `Programmed=False`) — so every route on that listener silently produces no router while the status still counts it as attached.
- Each replica builds its configuration from its own informer caches and rebuilds only on Kubernetes events. An object that never entered the cache never generates one, so the partial configuration is **sticky**; an informer resync replays only what is already cached.
- Nothing was logged at warn or error. The exact trigger at startup was not proven (the pods were deleted before they could be inspected); the signature is consistent with an incomplete initial list, or an unresolved Secret, while the API server was churning.

## Detecting it next time

`./scripts/check-traefik-replicas.sh` (argo `824757c`) asks every replica directly at `<podIP>:8443` with the real SNI and `Host`, and names any replica that answers Traefik's own 404 for a hostname another replica routes. Backend 404s, 5xx and timeouts are not compared, so a flaky app cannot raise a false alarm. Run it after any control-plane churn, node reboot or Traefik rollout.

Known gap: a listener with no hostname that answers (today `mm-b-hero-rehab-https`) cannot show a stale replica; the script prints a warning for those.

## Fix and prevention

- Immediate: restart the affected replicas one at a time. `maxSurge 1 / maxUnavailable 0` keeps the other replicas serving, and a replacement that starts outside the churn comes up complete.
- Prevention is tracked in **#191** (a readiness probe that proves routing, not just `/ping`) and **#108** (a divergence guard job). Neither has shipped.
- The two ways a replica loses routers look identical from outside: a plugin that failed to load ([2026-10-16](2026-10-16-traefik-plugin-outage.md), #190) and a partial configuration at startup (this record). Both are invisible to `/ping`, and both are fixed by restarting that replica.

## Links

- [public-edge.md](public-edge.md#troubleshooting) — the operating notes, including the check script as the first step.
- #190 (plugin download), #191 (readiness and alerts), #192 (docs), #108 (divergence guard).
