# llm-proxy metrics, dashboard and balance alerts

Date: 2026-11-13
Commits: `08458e6` (metrics pipeline — PR #124), `62efd30` (callback must be an instance — PR #125), `630f10e` (ingress NetworkPolicy — PR #127), `585a43e` (scrape path, deployment ids, dashboard, alerts — PR #131).

What the proxy exports, how it reaches Mimir, what the dashboard and the four alerts assume, and the two traps that cost time on the way here. The DeepSeek key layout and the affinity behaviour live in [2026-11-11-litellm-deepseek-keys.md](2026-11-11-litellm-deepseek-keys.md); this record only covers the metrics side.

## What exists

| Piece | Where | Note |
|---|---|---|
| `callbacks: ["prometheus", …]` + a two-group `prometheus_metrics_config` whitelist | `workloads/llm-proxy/configmap.yaml` | Narrow on purpose — see below |
| Balance poller (`balance_metrics.py`, a ConfigMap key of its own) | same | Polls DeepSeek `/user/balance` from inside the pod |
| `ExternalSecret/observability-litellm-metrics` | `workloads/secrets/observability-litellm-metrics.yaml` | Virtual key for Alloy's bearer token |
| `discovery.kubernetes` + `relabel` + `prometheus.scrape "litellm"` | `workloads/alloy/values-prod.yaml` | One target per pod |
| Ingress NetworkPolicy admitting `kube-system/traefik` and `observability/alloy` on 4000 | `workloads/network-policies/litellm.yaml` | Added with the scrape |
| `LiteLLM proxy` dashboard, 8 panels | `workloads/observability/grafana-dashboards/litellm.yaml` | Datasource uid `mimir` |
| 4 alert rules, group `litellm`, folder `Alerts` | `workloads/observability/grafana-dashboards/litellm-alerts.yaml` | Routed by the default ntfy policy |

Metric families in play: `litellm_input_tokens_metric_total`, `litellm_output_tokens_metric_total`, `litellm_spend_metric_total`, `litellm_provider_cache_read_input_tokens_metric_total`, `deepseek_balance_usd`, `deepseek_balance_last_success_timestamp_seconds`.

Series carry `api_provider`, `model_id`, `requested_model` (plus `account` on the balance gauges) and **no** `cluster` label — home is the series without one. Roughly 190 series for `job="litellm"`, against a tenant total of ~185k and `max_global_series_per_user: 750000`, retention `720h`.

## Request and latency metrics are deliberately absent

The whitelist admits only the token, spend, provider-cache and balance families. The proxy's request and latency families carry `client_ip` and `user_agent`, i.e. unbounded label values, and the per-tenant series budget is shared with everything else in the estate. So the dashboard can answer "how many tokens, at what cost, with what cache hit ratio" but not "how many requests, at what p95". Adding those is a series-budget decision, not a dashboard tweak.

## Scrape the slash, and the key needs the route

The proxy answers `GET /metrics` with `307 -> /metrics/`. Scraping `/metrics/` directly removes a wasted request per scrape per pod; steady state in the proxy log is now `"GET /metrics/ HTTP/1.1" 200 OK` from Alloy's pod IP and nothing else.

Two things that are not in git and will bite on a rebuild:

- Scraping is **per pod**, never the Service VIP. Behind a ClusterIP the scrape alternates replicas and the counters look like they reset every 30 s.
- The bearer key needs `/metrics` in its `allowed_routes`. The key that ships for this (`metrics-reading-key`) was created with `["llm_api_routes"]` and refused `/metrics` with a 401 until `/metrics` was added via `POST /key/update`. The endpoint itself stays authenticated — `require_auth_for_metrics_endpoint: false` was rejected in favour of a key grant.

## Deployment ids: deterministic, and a trap when the key comes from the environment

`Router.generate_model_id` (`router.py:9463`) is `sha256(model_group + litellm_params)`; it is assigned only when `model_info.id` is absent. Ids therefore survive restarts. The trap: for a deployment whose `api_key` is `os.environ/X`, the hash is taken over the **resolved secret**, so rotating that provider key silently changes the deployment id and starts a new `model_id` series. Measured in-pod on `v1.108.1`: `gemini/*` hashes to `61e1d2f5…` from raw config and `31d2ab51…` from the resolved key, and `31d2ab51…` was the live series; `anthropic/*` and `openrouter/*` behave the same way.

All 28 deployments now carry an explicit `model_info.id`, so the label, the `x-litellm-model-id` header and spend-log metadata all read as names (`claude`, `anthropic-wildcard`, `deepseek-home-key1`, …). Naming also removes the key-rotation churn above.

Do **not** count deployments from `/model/info`: it wildcard-expands each deployment into every model name it matches (519 rows against 28 real deployments, `openai-wildcard` alone expanding to 217). It is still the right probe for "is any id still a 64-hex string", which is what the check actually asks.

## Why the panels are shaped the way they are

- **`max by (account)`, never `sum`.** Both replicas export the same balance; summing measures 127.30 for a 63.65 balance.
- **Runway divides by a spend rate filtered with `> 0`**, so an idle account shows "No data" rather than a number produced by dividing by a clamped epsilon.
- **The cache-ratio denominator is input tokens**, answering "of the prompt tokens we sent, how many were served from the provider's prefix cache" (measured 0.98–0.997 for the two home keys).
- **Everything aggregates `sum by (model_id)`** across replicas, so one pod restarting does not look like traffic stopping.

## The four alerts

| uid | expr | fires when |
|---|---|---|
| `litellm-balance-low` | `max by (account) (deepseek_balance_usd{account=~"home-key1\|home-key2"})` < 20 | 15m |
| `litellm-balance-critical` | same < 10 | 5m |
| `litellm-balance-poller-stale` | `(time() - max(deepseek_balance_last_success_timestamp_seconds)) > 3600 and on() (sum(increase(litellm_input_tokens_metric_total[1h])) > 0)` | 30m |
| `litellm-scrape-degraded` | `sum(up{job="litellm"})` < 2, `noDataState: Alerting` | 10m |

Thresholds come from measured burn: $2.86/3h on home-key1 and $2.32/3h on home-key2 at the busiest (≈$23 and ≈$19 per day) against ~$63 balances, so $20 is one to six days of runway and $10 is roughly ten hours at the fast rate.

Three deliberate choices:

- **`sum(up{...})`, not `count`.** `sum` survives one replica being unhealthy, and returns no series when the job vanishes entirely — which then trips `noDataState: Alerting` instead of reporting healthy. That is the case worth waking up for.
- **The poller rule needs traffic.** The balance poller rides `async_log_success_event` behind a 900 s gate, so a quiet proxy legitimately has a stale gauge. The `and on() (...)` clause means "stale gauge *while* tokens are flowing", which is a broken poller rather than an idle night.
- **`and on() (...)` instead of `scalar(x) > 0`.** PromQL rejects comparisons between scalars without the `bool` modifier; `on()` matches the two label-less sides.

## Operational notes

- **A ConfigMap change does roll the proxy.** The pod template carries `reloader.stakater.com/auto: "true"` and Stakater Reloader is installed, so `litellm-config` changes roll the Deployment on their own. No manual `rollout restart` is needed or wanted.
- **Alloy hot-reloads its config file**, so a `values-prod.yaml` change reaches running pods without a DaemonSet restart (verified: pods started 05:10, the scrape switched to `/metrics/` after the 08:47 merge with no restart).
- **Mimir quirks.** Queries go to `/prometheus/api/v1/query` — the bare `/api/v1/query` 404s. Grafana's datasource uid is `mimir` pointing at `http://mimir.observability.svc:8080/prometheus`. The remote-write `write_relabel_config` drops only `*_bucket` series for infrastructure jobs, so nothing litellm exports is filtered on the way in.
- **Existing series go stale when an id changes.** Renaming a deployment starts a new `model_id` series and abandons the old one, which lingers for Mimir's retention. Affinity pins that reference a renamed id belong to single-deployment groups, where a stale pin falls through to the only deployment and re-pins within `deployment_affinity_ttl_seconds` (3600); the deepseek pins are untouched.

## Verification that was actually run

`sum(up{job="litellm"})` = 2 on both replicas; zero `"/metrics"` (307) lines in the proxy log after the change; `/model/info` with no 64-hex ids; `model_id="claude"` appearing in Mimir for a group that previously reported a hash; both Grafana sidecars logging the new dashboard and rule file and `provisioning.alerting` finishing without error; all four alert expressions returning non-firing values against live Mimir (balances ~60, `sum(up)` = 2, poller expression empty); `scripts/validate-policies.sh` passing.
