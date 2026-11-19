# Tempo: a cold start cannot survive a liveness probe on `/ready` — 2026-11-18

Traces were down for ~48 hours and nothing alerted. This records the cause, the fix, and the
two deploy-path traps that cost the most time.

## Timeline

- **2026-11-16 16:40:23 EST** — node `big` re-posted its `Ready` transition (a reboot/eviction;
  `kured` only targets control planes). `tempo-0` was recreated the same minute.
- Span metrics in Mimir decay and **stop at 2026-11-16T21:28Z**. They do not resume until the fix.
- **2026-11-18 23:49:50Z** — the fixed pod reaches Ready, 5 min 30 s after start.
- Total: ~722 restarts, 48 hours of traces lost. The 3.03 TB already in `tempo-blocks` was never at risk.

## Why it never recovered

Tempo's `/ready` is a readiness signal, and during a cold start it legitimately returns 503 while
the process settles: WAL replay, `reloading local blocks`, and the compactor's blocklist poll
(`polling enabled interval=5m0s`). The chart default put **liveness on that same endpoint**
(`initialDelaySeconds: 30`, `failureThreshold: 3`), so the container was killed ~60 s in — before
the ~5.5 minutes it needs — and every kill restarted the sequence from zero. That is a fixed point,
not a flaky start: 60 s < 5.5 min, forever.

The blast radius is what makes it invisible: never Ready also means **no Service endpoints**, so
Alloy's OTLP exports were refused (`connection refused` on `tempo:4317`), its queue filled, and it
began rejecting spans (`sending queue is full`). Traces were dropped at the door while containers,
nodes, disk and the S3 backend were all healthy.

## The change

`apps/tempo.yaml` probes liveness on the port rather than the endpoint, and leaves `/ready` as the
readiness gate:

```yaml
livenessProbe:
  httpGet: null          # required: see below
  tcpSocket: {port: 3200}
  initialDelaySeconds: 10
  periodSeconds: 20
```

Two constraints, both verified by rendering the chart before pushing:

- **Chart 2.4.0 has no `startupProbe` value**, so a startup budget cannot be expressed. A TCP
  liveness probe is the chart-compatible equivalent: it cannot be legitimately 503, and readiness
  still keeps an unready pod out of the Service.
- **`httpGet: null` is load-bearing.** Helm deep-merges values over chart defaults, so overriding
  `livenessProbe` alone emits *both* `httpGet` and `tcpSocket`, which the API server rejects. Null
  out the inherited key explicitly.

## Deploy-path traps

1. **A push does not roll the app by itself.** `tempo` takes its Helm values from the `app-of-apps`
   Application (`path: apps`, `targetRevision: HEAD`), so the *Application object* has to be
   re-synced first (`argocd.argoproj.io/refresh: hard` on `app-of-apps`). Until then the chart spec
   is unchanged and the StatefulSet keeps its old template.
2. **A StatefulSet will not roll a pod that never goes Ready.** After the refresh, the StatefulSet
   reached `generation 33` / `observed 33` with `updateRevision` ≠ `currentRevision`, and the pod
   stayed on the old revision indefinitely. Deleting the crash-looping pod (it served nothing — no
   endpoints) is what applied the new template.

## Verification

| Check | Result |
|---|---|
| Pod | `1/1 Running`, 0 restarts, revision `tempo-5b47974ccd` |
| Time to Ready | 5 min 30 s (matches the 5-minute blocklist poll) |
| Endpoints | `tempo` and `tempo-otlp-lb` both populated |
| Mimir `up{instance="tempo.observability.svc:3200"}` | 0 → 1 |
| `sum(rate(traces_spanmetrics_calls_total[5m]))` | none → 0.12/s and climbing |
| Alloy export failures | 0 in the 5 minutes after |

## Still open

- **Nothing alerts on scrape-target health.** No `PrometheusRule` exists cluster-wide and no rule in
  `apps/` references `up`, which is why 48 hours of trace loss was silent. An `up{job=...} == 0`
  rule plus an expected-target-count check would have caught this on day one.
- Diagnostics are harder than they should be: `observability` has `default-deny-ingress` (no
  cross-namespace probing), `pods/proxy` is RBAC-forbidden for the developer context, and the
  in-namespace container images (`grafana`, `tempo`, `alloy`) carry no shell — so reading `/ready`
  during a bad state needs admin `kubectl` on a control-plane node.
