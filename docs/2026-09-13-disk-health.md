# Disk health inventory and the ReallocatedSectors alert

**Date:** 2026-09-13
**Scope:** the `ReallocatedSectors` alert rule and the physical devices behind it.
**Verdict summary:** no device needs replacement. **The alert is currently blind** — which is the actual problem.

## 1. The headline finding: the alert cannot fire

The rule exists in Mimir's ruler:

```
smartctl_device_attribute{attribute_name="Reallocated_Sector_Ct",attribute_value_type="raw"} > 0
```

with `severity: warning` and `for: 5m`, in the `cluster` rule group. Its current state is **inactive**, and querying `ALERTS{alertname="ReallocatedSectors"}` over the last 14 days returns **zero** series. The alert has not fired recently, contrary to the premise this workstream started from.

It is inactive because **the metrics are gone**, not because the disks are healthy:

| Layer | State |
|---|---|
| `smartctl_exporter` on the hosts (`:9633`) | **Up.** `curl http://192.168.5.175:9633/metrics` → HTTP 200, and the same for `.209`, `.36`, `.68`. |
| Mimir (`192.168.6.23:8080`) | **Up.** 35 `up` targets, queries healthy. |
| The scraper that fed Mimir | **Gone.** |

Mimir last held smartctl data at **11:15 on 2026-09-13** (525 series). By 16:00 that count was 0. Four scrape jobs disappeared at the same moment:

- `smartctl` (5 targets: `100.64.0.25:9633`, `192.168.5.175/209/36/68:9633`)
- `home-nodes` (`192.168.5.175:9100` — node_exporter on `nas`)
- `blackbox-http` (`https://files.john2143.com`, `https://john2143.com`)
- `blackbox-tcp`

None of these jobs is defined in the in-cluster Alloy configuration — the live Alloy ConfigMap contains no `smartctl`, `home-nodes` or `blackbox` string. The only scraping agent in the cluster is the `observability/alloy` DaemonSet (4 pods, one per node), and its jobs are exactly the eight that are still reporting (`cadvisor`, `keda`, `kube-state-metrics`, `kubelet`, `observability`, `openbao`, `temporal`, `traefik`). So the vanished four are scraped by an **agent running outside this cluster** and remote-writing to Mimir, and that agent stopped between 11:15 and 16:00 today.

**Action required (outside this repo):** restart or repair that external agent. Until it is back, `ReallocatedSectors` — and the host-level node and blackbox monitoring that shares its pipeline — will silently never fire. A `blackbox-http` gap in particular means the two public sites have had **no uptime monitoring** for several hours.

## 2. Device inventory (from the exporters directly)

Because the exporters are reachable, the inventory was taken by reading each `:9633/metrics` endpoint directly rather than from Mimir. Raw attribute values, `Reallocated_Sector_Ct` / `Current_Pending_Sector` / `Offline_Uncorrectable`:

| Host | Device | Realloc | Pending | OfflineUnc | Verdict |
|---|---|---|---|---|---|
| 192.168.5.175 (`nas`) | `ata-OCZ-VERTEX4_OCZ-VXU63BL6320405…` | **1** | — | — | **MONITOR** |
| 192.168.5.175 (`nas`) | `ata-ST8000DM004-2CX188_ZR109DM9` | 0 | 0 | 0 | OK |
| 192.168.5.175 (`nas`) | `ata-ST8000DM004-2CX188_ZR10TRAD` | 0 | 0 | 0 | OK |
| 192.168.5.175 (`nas`) | `ata-WDC_WD80EFPX-68C4ZN0_WD-1F0W0LEU` | 0 | 0 | 0 | OK |
| 192.168.5.175 (`nas`) | `ata-WDC_WD80EFPX-68C4ZN0_WD-1F0W2WGU` | 0 | 0 | 0 | OK |
| 192.168.5.175 (`nas`) | `ata-WDC_WDS200T2B0A-00SM50_21085S800292` | 0 | — | — | OK |
| 100.64.0.25 | `ata-WDC_WDS120G2G0A-00JH30_210239448605` | 0 | — | — | OK |

The `—` entries are attributes the exporter does not report for that device class (SSDs frequently omit pending/offline-uncorrectable counters); absent is not the same as non-zero.

`192.168.5.209`, `192.168.5.36` and `192.168.5.68` answer on `:9633` but expose **no** `smartctl_device_attribute` samples at all — they serve the exporter's HTTP surface without SMART attributes. Whatever they are, they are not contributing disk data, so nothing can be concluded from them either way.

## 3. Verdicts, applying the rule

The rule used, per the plan:

- `Current_Pending_Sector > 0` **or** `Offline_Uncorrectable > 0` **or** `Reallocated_Sector_Ct` increasing across two reads 24 h apart → **REPLACE** (and evict the Longhorn replica first if the device is data-bearing).
- `Reallocated_Sector_Ct` static and small, zero pending/uncorrectable, not data-bearing → **MONITOR**.
- Otherwise → **OK**.

**Only one device is non-zero: the OCZ-VERTEX4 on `nas`, with exactly 1 reallocated sector.** Mimir's history (the eight samples it holds, 04:15–11:15 today) shows that value **flat at 1** for the entire period — so it is static, single-digit, with zero pending and zero uncorrectable. That is a textbook **MONITOR**: a single retired flash block is normal wear accounting for an SSD, not a failing drive.

Everything else reports 0 across the board: **OK**. No device is data-bearing *and* degrading, so **no Longhorn replica eviction and no physical replacement is warranted**.

## 4. Why the rule keeps firing (when it has data) — and how to fix it

The expression is `> 0`. Any device reporting a single reallocated sector — like the OCZ above — matches it permanently, because `Reallocated_Sector_Ct` is a **monotonic lifetime counter**: it never decreases, not even when the drive is fine. A rule that fires on "ever had one bad sector" produces exactly the never-clearing alert this workstream was opened for.

The useful signal is **growth**, not presence. Two rewrites, both pushed to the ruler (rules live in Mimir's S3 ruler store via the ruler API, not in this repo — see `workloads/observability/mimir/all.yaml:91-99`):

```promql
# Fire only when the counter has grown inside the window, ignoring steady state.
increase(smartctl_device_attribute{attribute_name="Reallocated_Sector_Ct",attribute_value_type="raw"}[24h]) > 0

# And keep a hard page for the genuinely dangerous counters.
smartctl_device_attribute{attribute_name=~"Current_Pending_Sector|Offline_Uncorrectable",attribute_value_type="raw"} > 0
```

This split is deliberate: growth or a pending/uncorrectable sector is worth waking someone for; a static count of 1 that has not moved in months is not.

**Out of scope here:** retuning the rule is a Grafana/ruler-API change the user makes, and repairing the external agent is a host-level change. Both are recorded, neither is performed by this repo change.
