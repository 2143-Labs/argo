# Observability retention & health audit — 2026-09-22

Read-only audit of the home-cluster observability stack: Loki (logs), Mimir (metrics),
Tempo (traces), Alloy (collection), SeaweedFS (object storage).
No changes were made. All figures were measured live against the running cluster.

## Headline

**Metrics history is effectively 13 hours, not the configured 30 days.**
43 days of metric blocks are sitting in object storage that the querier cannot read at all.

**Logs are ~55 days, not the configured 90 days**, and the retention mechanism that is
supposed to enforce that policy has never once succeeded (408 consecutive failures).

Traces are the one fully healthy signal: exactly the configured 7 days.

Storage capacity is *not* the constraint — SeaweedFS holds 793 GB on a 17 TB filesystem (5%).

## Retention: configured vs actual

| Signal | Backend | Configured | Actual queryable | Verdict |
|---|---|---|---|---|
| Logs — Loki | s3 `loki-chunks` | `retention_period: 2160h` (90d) | **~55d** (earliest ≈ 2026-07-29) | MISMATCH |
| Metrics — Mimir | s3 `mimir-blocks` | `compactor_blocks_retention_period: 720h` (30d) | **~13h** | BROKEN |
| Traces — Tempo | s3 `tempo-blocks` | `retention: 168h` (7d) | **7d** exactly (7d yes / 8d no) | OK |

Config sources: `apps/loki.yaml:49-53`, `workloads/observability/mimir/all.yaml:31` (`mimir.yaml`),
`apps/tempo.yaml:30`.

## P1 — Mimir: 43 days of blocks in S3, zero readable

The ingester keeps 13h locally (`retention_period: 13h0m0s`); everything older should come
from object storage via the store-gateway. It does not.

Measured:

- `/buckets/mimir-blocks/anonymous/` contains **1432 block directories**, crtime spanning
  **2026-08-10 → 2026-09-22** continuously — i.e. the full life of the bucket, no gaps.
- `cortex_bucket_store_blocks_loaded{component="store-gateway"} = 0`
- `cortex_blocks_meta_synced{component="store-gateway", state="no-bucket-index"} = 1`,
  `state="loaded" = 0`
- `cortex_bucket_index_loaded{component="querier"} = 0` (488 loads, 13 failures)
- `cortex_querier_blocks_found_total = 0`, `cortex_querier_blocks_queried_total = 0`
- `cortex_compactor_tenants_discovered = 0`, `cortex_compactor_tenants_processing_succeeded = 0`,
  despite `cortex_compactor_runs_completed_total = 121`
- **No `bucket-index.json.gz` object exists** under `mimir-blocks/anonymous/` — only ULID
  block dirs and `markers/`.
- Instant queries at 1d / 3d / 7d / 14d / 29d / 30d / 31d / 60d all return NO DATA; a 7d@1h
  range returns 14 points starting 2026-09-21T04:54 (the ingester window only).

Shipping works — `cortex_ingester_shipper_last_successful_upload_timestamp_seconds` is current,
`uploads_total = 59`, `failures_total = 5`. Metadata sync works —
`cortex_blocks_meta_syncs_total = 422`, `failures_total = 0`.

**Root cause:** the compactor never builds the per-tenant bucket index (`tenants_discovered = 0`),
so the store-gateway has no way to enumerate blocks and loads none. The querier therefore only
ever sees the ingesters.

**Second-order effect:** because the compactor's tenant loop never runs, the 30d retention policy
is not enforced either — `cortex_compactor_blocks_deleted_total{reason="retention"} = 0` while
`reason="compaction" = 78`. Blocks older than 30d accumulate indefinitely (43d already on disk).

Contributing factor worth checking: Mimir runs `target: all` on a **2-replica** StatefulSet, so
**two compactors** are in the ring simultaneously (`cortex_ring_members{name="compactor",state="ACTIVE"} = 2`).
Mimir expects a single unsharded compactor.

### Options

1. **Immediate, low risk** — set `blocks_storage.bucket_store.bucket_index.enabled: false` in the
   `mimir-config` ConfigMap. The store-gateway then discovers blocks by scanning the bucket and
   stops depending on the compactor entirely. History up to the 30d retention should appear within
   one `sync_interval`. Trade-off: somewhat slower cold queries.
2. **Correct fix** — make the compactor actually run: give it a dedicated single-replica workload
   (separate `target: compactor`) and confirm `cortex_compactor_tenants_discovered = 1` and that
   `bucket-index.json.gz` appears in the bucket. Do this alongside (1), not instead of it.
3. Once the compactor runs, retention self-enforces and the 30d policy takes effect.

## P2 — Loki: 90d configured, ~55d queryable, retention never succeeds

Measured:

- `loki_compactor_apply_retention_operation_total{status="failure"} = 408` — and there is **no
  `status="success"` series at all**.
- `loki_compactor_apply_retention_last_successful_run_timestamp_seconds = 0` (never).
- `loki_compactor_delete_processing_fails_total{cause="error"} = 408`.
- Live probe of the Loki API (5-day and 25-day windows): data present 0–55d ago, **absent
  55–90d ago**. Cutoff ≈ 2026-07-29.
- The tsdb index tables *do* still exist back to `index_20627` = **2026-06-23** (92 tables),
  so index metadata for the missing window is present but the data is not returned.
- The compactor is otherwise healthy and actively compacting tsdb files every ~15 min, with
  **0 errors in the last 24h** of logs.

Interpretation: the retention delete path is in a permanently failing state, so the 90d policy is
not being enforced by it — yet only ~55d is queryable. Those two facts are inconsistent with a
correctly functioning 90d policy, so roughly 2026-06-23 → 2026-07-28 of logs was removed or made
unreachable by something other than working retention. Supporting signals: the `loki-chunks`
bucket dates to 2026-06-23, `loki_cluster_seed.json` was recreated 2026-08-31, and the
`loki-write` StatefulSet is only 39d old.

Also stale: the sole delete-request object `index/delete_requests/delete_requests.gz` has a
crtime of 2026-08-05 and has not moved since.

### Options

- Raise the Loki compactor to `debug` temporarily and capture the retention failure — it is
  currently silent at `info` level, which is why 408 failures produced no log lines.
- Verify the fix by confirming `apply_retention_operation_total{status="success"}` increments and
  `last_successful_run_timestamp_seconds > 0`.
- Then decide the policy deliberately. 90d is affordable: Loki's share of the 793 GB is small
  against a 17 TB volume.

## P3 — Alloy does not cover `office` and `pite`

The Alloy DaemonSet is 4/4 ready — pods only on `arch`, `closet`, `big`, `nas`.
`office` carries taints `wifi,seated` and `pite` carries `pi`; the DaemonSet has an **empty
`nodeSelector` and no tolerations**, so both nodes are silently excluded.

Workloads with no metrics, logs, or traces as a result:

- `office`: longhorn-manager, longhorn-csi-plugin, instance-manager, `nightly-backup` Job
- `pite`: longhorn-manager (**15 restarts**), longhorn-csi-plugin (**38 restarts**),
  metallb-frr-k8s (**46 restarts**), metallb-speaker (**28 restarts**)

The most restart-prone components in the cluster are exactly the ones that are invisible.
Fix: add tolerations for `wifi`, `seated`, `pi` to the Alloy DaemonSet if these nodes are meant to
be monitored — they are clearly running production storage and load-balancer workloads.

## P3 — Thin alerting, and no self-monitoring

- Grafana alert rules: **2**, both Stalwart mail (`workloads/observability/grafana-dashboards/alert-rules.yaml`).
- Mimir ruler: one rule group `cluster` with **2 rules**, evaluating every 60s, 7067 iterations,
  **0 missed** — the mechanism itself is healthy.
- Mimir Alertmanager: `cortex_alertmanager_alerts_received_total = 771` but
  `cortex_alertmanager_notifications_total{integration="webhook"} = 6`. 765 received alerts
  produced 6 notifications — either aggressive grouping/inhibition or a failing webhook. Worth
  confirming the receiver returns 200.

Critically, **nothing in the stack monitors the stack**. No alert would have fired for either P1
or P2 above. Suggested additions:

- `cortex_compactor_tenants_discovered == 0` (Mimir compactor stalled)
- `cortex_bucket_store_blocks_loaded{component="store-gateway"} == 0` (blocks unreadable)
- `loki_compactor_apply_retention_operation_total{status="failure"} > 0`
- `loki_compactor_apply_retention_last_successful_run_timestamp_seconds == 0`
- `up{namespace="observability"} == 0`

## P3 — Restart churn in the observability namespace

`loki-backend-0` 9 restarts (last 18h ago), `loki-backend-1` 8, beyla pods 4–6 each,
loki-canary 1–3. Nothing is currently down, but loki-backend repeatedly restarting warrants a
look at OOMs or scheduling.

## Storage and durability

- SeaweedFS data: `/tank/seaweedfs-data` on `nas`, **793 GB used of 17 TB (5%)**.
- Buckets: `mimir-blocks` (1432 block dirs), `loki-chunks` (12130 fingerprint dirs),
  `tempo-blocks` (1327 entries), plus `mimir-rules`, `mimir-alertmanager`.
- PVCs: `data-loki-write-0/1` 20 Gi each, `data-loki-backend-0/1` 10 Gi each,
  `storage-mimir-0/1` 30 Gi each.
- Durability caveat (not capacity): the SeaweedFS volume server is pinned to `nas` by required
  nodeAffinity and stores to node-local `hostPath`. There is no replication of the volume server,
  so `nas` is a single point of failure for all logs, metrics, and traces.

Tempo note, low urgency: the compactor is healthy (`tempodb_compaction_blocks_total{level="0"} = 194`,
`compaction_errors_total = 0`, `outstanding_blocks = 0`) and queries correctly honour the 7d
retention, but 1327 block entries spanning 2026-08-06 → now remain in `tempo-blocks/single-tenant`.
Block-level deletion beyond the retention window may not be occurring. Harmless at 5% disk use;
worth verifying.

## Recommended order

1. **Mimir bucket index** — 13h of metrics instead of 30d is the largest loss; fix (1) is a
   one-line ConfigMap change.
2. **Loki retention failure**, and explain the 55d cutoff — capture the error at debug level first.
3. **Alloy tolerations** for `office` and `pite`.
4. **Self-monitoring alerts** so these fail loudly next time.
5. Restart churn in `loki-backend`.
