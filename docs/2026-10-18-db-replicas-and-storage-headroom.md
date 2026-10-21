# Database replicas, Loki memory reservations, and Longhorn rebuild limits

**Date:** 2026-10-18 (executed 2026-10-21)
**Scope:** CNPG cluster replica counts and placement, Loki memory reservations and cache pinning, Longhorn's per-node replica rebuild limit, and the CPU/memory right-sizing that made room for them.
**Verdict summary:** every CNPG cluster now runs two instances on distinct nodes with a live streaming replica. No node exceeds its allocatable requests. **closet is effectively full** (96% CPU, 92% memory requests) and is the ceiling for anything placed there without further rebalancing.

## 1. What changed

| Change | Before | After |
|---|---|---|
| `pelican-db`, `asciinema-db`, `steam-lobby-db`, `mattermost-db`, `temporal-db` | 1 instance | **2 instances** |
| `litellm-db` | 2 instances | unchanged |
| CNPG placement | default pod anti-affinity (preferred) | `podAntiAffinityType: required`, `topologyKey: kubernetes.io/hostname`, required `NotIn [arch]`, preferred `In [big, closet]` |
| Primary updates | `restart` (deletes the primary in place → Longhorn detach/attach) | `switchover` (a replica is promoted first) |
| `temporal-db` resources | `cpu: 2` / `memory: 512Mi`, request = limit | **`cpu: 1` / `memory: 1Gi`**, request = limit (Guaranteed QoS) |
| `loki-write` / `loki-backend` | no resources (BestEffort) | request 512Mi, limit 8Gi each |
| `loki-read` | no resources (BestEffort) | request 256Mi, limit 2Gi |
| Loki caches | preferred affinity for big | **required** on big; `chunksCache.allocatedMemory: 8192` set explicitly at the top level |
| Loki non-big halves | preferred big only | preferred big (100), then **arch** (50) |
| Longhorn `concurrent-replica-rebuild-per-node-limit` | 10 (hand-set in the UI, not in the ConfigMap) | **5**, now in `apps/longhorn.yaml` |
| `factorio` CPU request | 2 | 250m (7-day p95: 0.05) |
| `home-assistant` CPU / memory | 1500m / 3Gi, request = limit | 1 / 1.5Gi, request = limit (still Guaranteed; 30-day peak 939Mi) |
| `minecraft` CPU request | 2 | 1 (memory untouched: 8Gi request, 12Gi limit against an 11.5Gi peak) |

The right-sizing released ~2.1 cores and ~1.5Gi on closet, which is where the four new replicas landed. `temporal-db` at 1 core is 2.8x its observed p99 (0.36 cores) and double the 500m ceiling that was throttling it; 1Gi is 3.4x its observed memory peak (298Mi).

## 2. Placement (as observed after the rollout)

| Cluster | Instance | Node | Role |
|---|---|---|---|
| `pelican-db` | `pelican-db-1` / `pelican-db-2` | big / closet | replica / primary |
| `asciinema-db` | `asciinema-db-1` / `asciinema-db-2` | big / closet | replica / primary |
| `temporal-db` | `temporal-db-1` / `temporal-db-2` | big / closet | replica / primary |
| `steam-lobby-db` | `steam-lobby-db-1` / `steam-lobby-db-2` | big / closet | replica / primary |
| `mattermost-db` | `mattermost-db-1` / `mattermost-db-2` | big / closet | primary / replica |
| `litellm-db` | `litellm-db-4` / `litellm-db-1` | big / nas | primary / replica |

Loki after the same rollout: `loki-write` big + arch, `loki-backend` big + arch, `loki-read` big + arch, `loki-chunks-cache-0` and `loki-results-cache-0` on big.

Every switchover moved the primary to the new instance, so four primaries now sit on closet. Their replicas all sit on big; a closet failure costs a promotion delay, not data.

## 3. Storage headroom

`longhorn-cnpg` is `dataLocality: strict-local`, `numberOfReplicas: "1"`, `reclaimPolicy: Retain`, `volumeBindingMode: WaitForFirstConsumer`. A single copy per volume means no rebuild traffic, which is why the rebuild limit only governs the replicated `longhorn` volumes.

Usable = `storageAvailable − 25% of storageMaximum − storageReserved`:

| Node | Disk | Usable for new volumes |
|---|---|---|
| big | `/var/lib/longhorn` on `/dev/sdb1` (2.0T) | 966 GiB |
| closet | `/mnt/longhorn` on the USB SSD (3.6T) | 637 GiB |
| nas | `/var/lib/longhorn` + `/var/lib/longhorn-2` | 247 GiB (+16.6 GiB on the second disk) |
| **arch** | `/mnt/longhorn` on `nvme1n1p3` (442 GiB) | **0 GiB** |

arch cannot take a new volume: 91.1 GiB available against a 25% floor of 110.6 GiB, plus 242 GiB of deliberate `storageReserved` for the desktop. That is why every new cluster carries a required `NotIn [arch]` node-affinity term. arch still runs pods whose volumes already exist (that is where Loki's second halves went) — the exclusion is about provisioning, not attachment.

## 4. Remaining pressure

| Node | CPU requests | Memory requests |
|---|---|---|
| big | 32151m / 64000m (50%) | 53155Mi (66%) |
| closet | 10626m / 11000m (**96%**) | 25756Mi (**92%**) |
| nas | 4095m / 6000m (68%) | 10332Mi (80%) |
| arch | 1350m / 4000m (33%) | 2572Mi (16%) |

Nothing overflows, and no pod is Pending. But closet has ~370m of CPU and ~2.2Gi of memory left in requests: the next workload placed there needs either a node or another rebalance. Related items still open: the 11 Released PVs holding 81 GiB cluster-wide (Longhorn `Retain` keeps them until deleted by hand), and arch's unusable disk.

## 5. How to verify

```bash
# Two instances per cluster, on distinct nodes
for c in "default pelican-db" "default asciinema-db" "default temporal-db" \
         "steam-lobby steam-lobby-db" "mattermost mattermost-db" "default litellm-db"; do
  set -- $c
  echo "== $2"; kubectl get pods -n "$1" -l cnpg.io/cluster="$2" -o wide --no-headers
done

# Replication live: the primary prints f with N-1 streamers
for c in "default pelican-db" "default asciinema-db" "default temporal-db" \
         "steam-lobby steam-lobby-db" "mattermost mattermost-db" "default litellm-db"; do
  set -- $c
  p=$(kubectl get pods -n "$1" -l "cnpg.io/cluster=$2,cnpg.io/instanceRole=primary" -o jsonpath='{.items[0].metadata.name}')
  echo "$2 primary=$p $(kubectl exec -n "$1" "$p" -c postgres -- psql -U postgres -tAc "select pg_is_in_recovery(), (select count(*) from pg_stat_replication)")"
done

# Requests fit allocatable
for n in big closet nas arch; do echo "== $n"; kubectl describe node "$n" | sed -n '/Allocated resources/,/^Events/p' | grep -E '^  (cpu|memory) '; done
```

Expected: two pods per cluster on distinct nodes, every primary `f|1`, no node above 100% of allocatable. Both `temporal-db` pods report `Guaranteed`.

Loki is checked with a live query (`/ready` on the gateway returns 404) and the WAL counter, which was `1` before the rollout and stayed `1` after:

```bash
curl -s -G 'http://192.168.6.24:3100/loki/api/v1/query' --data-urlencode 'query=sum(count_over_time({namespace="observability"}[5m]))'
curl -sG 'http://192.168.6.23:8080/prometheus/api/v1/query' --data-urlencode 'query=loki_ingester_wal_corruptions_total'
```

Longhorn's new limit:

```bash
kubectl --context closet-as-admin get settings.longhorn.io concurrent-replica-rebuild-per-node-limit -n longhorn-system -o jsonpath='{.value} {.status.applied}'
```

Expected `5 true`.
