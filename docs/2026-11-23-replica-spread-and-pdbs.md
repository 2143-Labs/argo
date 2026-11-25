# Replica spread and PodDisruptionBudgets: litellm and the oauth2-proxy front doors

**Date:** 2026-11-23
**Scope:** hostname placement and disruption budgets for the stateless two-replica workloads in
namespace `default`: `litellm`, `oauth2-proxy-cameras`, `oauth2-proxy-temporal`,
`oauth2-proxy-seaweedfs-lan`, `oauth2-proxy-rots-replays`. The litellm rollout strategy follows from
the constraint and is recorded here too.
**Verdict summary:** all five now carry a required hostname `podAntiAffinity` and a PDB
(`minAvailable: 1`), and litellm rolls with `maxSurge: 0` because only two nodes can hold one of its
pods. litellm's two replicas moved from both-on-`big` to `closet` + `big`; the rollout never dropped
below one serving replica.

## 1. What changed

| Workload | Before | After |
|---|---|---|
| `litellm` (2 replicas) | preferred `nodeAffinity` only | required `podAntiAffinity` on `kubernetes.io/hostname`, PDB `minAvailable: 1` |
| `litellm` rollout | `maxSurge: 1`, `maxUnavailable: 0` | `maxSurge: 0`, `maxUnavailable: 1` |
| `oauth2-proxy-cameras` / `-temporal` / `-seaweedfs-lan` / `-rots-replays` (2 each) | preferred `podAntiAffinity` (weight 100), no PDB | **required** `podAntiAffinity`, PDB `minAvailable: 1` each |

Commits: `757e4dc` (litellm), `7386819` (the four proxies), `f18b63f` (rollout strategy).
`workloads/lan-dns` already had this shape and was the model.

## 2. Why: co-location, and why a PDB alone is a trap

Before the change both litellm replicas ran on `big` (`10.42.4.15`, `10.42.4.16`). The only placement
term was a *preferred* `nodeAffinity` for `workload-type=general`, which every eligible node
satisfies — it expresses no separation at all. A node loss on `big` took the whole gateway to zero
endpoints, and there is no descheduler in the cluster to drift pods apart later.

The order matters. A PDB computes allowed disruptions as `ready replicas - minAvailable`; with two
replicas on one node and `minAvailable: 1`, a drain of that node has **zero** allowed disruptions and
hangs forever. So the hard constraint comes first, and the PDB is only added where it is paired with
one:

- `litellm`, the four proxies: required anti-affinity, then PDB (this change).
- `lan-dns`: required anti-affinity, PDB (existing).
- `rots-sync` (`rots-prod`) is the counter-example — preferred spread only, both replicas on `office`
  today, so it must not get a PDB until the constraint is hard. Tracked on ai_tasks #109's sibling
  work, "Replica spread and PDB for rots-sync and twc-manager".

## 3. The schedulable domain is three nodes, and one of them is CPU-full

A litellm pod requests `4Gi` / `200m` (limit `4Gi` / `1000m`) and mounts `litellm-chatgpt-auth`
(`ReadWriteMany`, so the volume never blocks spreading). Nodes it cannot use:

- `office` — `wifi=no-network-storage:NoSchedule`, and `workloads/wifi-node-policy/mutating.yaml`
  withholds that toleration from any pod mounting a PVC; `validating.yaml` would deny it anyway.
- `pite` — arm64, 2.7Gi allocatable.
- `nas` — 10.3Gi of 10.5Gi memory already requested (RAM is reserved for the storage pods only it can
  run).

That leaves `arch`, `big`, `closet` — and `arch` is at **3935m of 4000m CPU requested**, so it cannot
take the 200m pod either. Available for a litellm replica at the time of this change: `big` and
`closet`, exactly two.

## 4. The no-surge correction

With required anti-affinity the first rollout (surge pod, `maxSurge: 1`) asked for a *third* node and
stalled:

```
0/6 nodes are available: 1 Insufficient cpu, 1 Insufficient memory,
2 node(s) didn't match pod anti-affinity rules, 2 node(s) had untolerated taint(s).
```

The second new replica sat `Pending` for 10 minutes and the Deployment hit
`ProgressDeadlineExceeded`; the two old/new replicas kept serving throughout. `maxSurge: 0` with
`maxUnavailable: 1` frees the outgoing replica's node for its replacement instead, and the two
replicas still never share a node. **The cost: during an image bump the gateway serves from one
replica for the ~2 minutes a new pod needs to pass startup and readiness.** Availability is not
zero, but it is not two either.

To get the surge back, free ~135m of CPU on `arch` (or move one litellm-eligible workload off it) and
restore `maxSurge: 1` / `maxUnavailable: 0` in `workloads/llm-proxy/deployment.yaml`. Tracked on
ai_tasks "litellm placement headroom".

## 5. Verification

- `kubectl -n default get pods -o wide`: `litellm-...-4wqpn` on `closet`, `litellm-...-5slz5` on
  `big`; EndpointSlice `litellm` = `10.42.0.131`, `10.42.4.95`.
- `kubectl -n default get pdb`: `litellm`, `oauth2-proxy-cameras`, `-rots-replays`, `-seaweedfs-lan`,
  `-temporal` all report `ALLOWED DISRUPTIONS 1`.
- The four proxies rolled out with the hard constraint satisfied — pairs on `closet`/`office`,
  `closet`/`big`, `closet`/`office`, `office`/`closet`. Two of them now run on `office`, which is
  allowed precisely because they mount no volume and therefore receive the wifi toleration.
- ArgoCD `llm-proxy` application: `Synced` / `Healthy` at `f18b63f`.

## 6. Standing rule for new multi-replica workloads

1. Replicas that must survive a node loss get a **required** hostname `podAntiAffinity` (or
   `topologySpreadConstraints` with `whenUnsatisfiable: DoNotSchedule`), not a preferred hint.
2. A `PodDisruptionBudget` is added **only** together with (1). Otherwise it converts a docile
   co-located pair into a drain that hangs.
3. Check CPU *and* memory headroom, not just memory, before assuming a rollout surge can be placed —
   `arch` being CPU-full is what stalled this one.

## 7. Left open

- `traefik` (kube-system, k3s-packaged chart `traefik-40.1.7`): required anti-affinity is already in
  the chart and one replica sits on each control-plane node; the PDB (`minAvailable: 2`) is still
  absent. ai_tasks #109, needs a `HelmChartConfig` in `dotfiles`, and #108's guard must respect it.
- `rots-sync` (2, `rots-prod`) and `twc-manager` (2, `temporal-system`): preferred-only placement;
  soft location is `workloads/rots-web/templates/sync.yaml` (chart renders `rots-prod` and the
  preview environment) and the vendored upstream `workloads/temporal-worker-controller/controller.yaml`.
- `litellm` has no `NotIn [nas]` node requirement (the db cluster does), so a 4Gi proxy pod is a legal
  target for `nas` if that node ever frees memory.
