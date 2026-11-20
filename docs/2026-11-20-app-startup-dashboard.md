# App startup and cold-start dashboard

Date: 2026-11-20
Commits: `1af792d` (dashboard — PR #150).

A nine-panel Grafana dashboard built only from telemetry the estate already had, plus the traps that make its numbers easy to misread. No KSM config change, no app instrumentation, no new scrape job, no recording rule.

## What exists

| Piece | Where | Note |
|---|---|---|
| `App startup` dashboard, 9 panels, uid `app-startup` | `workloads/observability/grafana-dashboards/app-startup.yaml` | ConfigMap label `grafana_dashboard: "1"` |
| `app-startup-dashboard` ConfigMap | `observability` namespace | Loaded by `grafana-sc-dashboard` |
| Live URL | `https://grafana.ts.2143.me/d/app-startup` | SSO |

Data comes from KSM (scraped every 30 s), Tempo span metrics, and Loki. The queries run live on a 30 s refresh; the Mimir ruler's existing `cluster` group is unmanaged by git (card #2361), so no recording rule was added.

## Panels and meaning

| Panel | Source | Meaning |
|---|---|---|
| Cold start — recent (15m) | KSM timestamps | pull (pod created -> first container start) + boot (last start -> Ready) for pods started within 15m |
| Boot time — last hour's starts | KSM timestamps | boot only, pods started within 1h; each boot is a one-hour plateau |
| Cold starts — last 24h | `kube_pod_start_time` | distinct pod names per app over 24h |
| Dino world generation p95 (7d) | Loki log line | `[primal] world seed=... generated in N ms`, p95 over 7d |
| ROTS build & provision p95 (7d) | Tempo span metrics | `world.build` is the spawn phase; `k8s.provision` is the API create call |
| Startup markers (logs) | Loki | raw Dino and ROTS startup lines |
| Ready replicas | KSM | Deployment and StatefulSet ready replicas; 0/1 flaps are KEDA scale-to-zero |
| Restarts (1h) | `kube_pod_container_status_restarts_total` | restart churn by app |
| Unready running pods | `kube_pod_status_ready` + `kube_pod_status_phase` | pods currently Running but not Ready |

## Traps

- **PromQL precedence.** `and` binds looser than `*`. `Q * on(...) group_left(app) APP` applies the join to the right side of an `and` and silently yields no `app`. Parenthesize every delta before joining.
- **Ready time is the last transition, not the first.** `kube_pod_status_container_ready_time` on a pod that flapped or stayed unready reports days (`external-secrets-cert-controller` showed 211,906 s). The boot panel clamps at 600 s.
- **Pull is only valid for young pods.** After a restart, `container_start - pod_start` grows with pod age (`longhorn-manager` showed 5.5M s). Gate on started within 1h.
- **`kube_pod_labels` is not emitted.** KSM has no `metricLabelsAllowlist`, so the app is derived from `kube_pod_owner` (ReplicaSet hash stripped), with `rots-gs-*` normalized to `rots-gameserver`. Jobs are excluded; DaemonSet pod names can misparse into `other`.
- **Deleted pods lose `kube_pod_owner`.** The 24h count uses a pod-name heuristic instead of joining the owner.
- **Dino `server.start` is a zero-duration mark.** Its 2.5 ms is overhead; world generation is only in the log line.
- **Span metrics carry no environment label.** The ROTS panels aggregate prod and previews. `world.build` is not full world generation, and ROTS readiness is not world-readiness.
- **KEDA interceptor metrics are unscraped** (port 2223 is not declared in the container spec). Per-spawn queue and wait time are not visible here.

## Measured on 2026-11-20

- Dino world generation p95, 7d: **3.89 s**.
- ROTS `world.build` p95: **0.243 s**; `k8s.provision` p95: **0.092 s**.
- 24h cold-start count (top): `desec-ddns` 97, `other` 67, `frigate-genai-stale-workflow-sweep` 51, `rots-temporal` 28.

## Verification

- The ConfigMap label is `1`; the sidecar logs `Writing /tmp/dashboards/app-startup.json`.
- Queries return `success` against `http://192.168.6.23:8080/prometheus/api/v1/query` and `http://192.168.6.24:3100/loki/api/v1/query`; substitute `$namespace` with `.*` in direct calls.
- The 15m/1h panels (cold start, boot, restarts, unready) are empty when no matching event occurred in the window. That is valid; it is not a broken join. The join is proven by widening the P1 gate to 24h, which returns non-empty apps.
- Not verified here: the signed-in browser render. The sidecar load and query success prove the data path; the visual check is manual.
