# Idling factorio, listen-brick and the matrix namespace (2026-11-11)

**Status: COMPLETE and verified.** Closet was the constraint — 23.4 GiB of 28.0 GiB
allocatable in use — and the workloads below were sitting on it doing nothing.
Driving them to zero released **~1.1 CPU / ~4.6 GiB of requests**, which is the number
that matters: most of these pods used a few tens of MiB of RSS, so `kubectl top` barely
moves (23.4 GiB → 21.3 GiB).

This is a deliberate, temporary state. The manifests are the truth, so bringing a
workload back is an edit to `replicas`, never a cluster action.

## What runs at zero

| workload | ns | before | notes |
|---|---|---|---|
| `factorio` | default | 1 on closet, 250m/3000Mi | PVCs kept (`longhorn-2`, 31Gi); host 503s |
| `listen-brick` | default | 1 on closet, 50m/256Mi | SQLite PVC kept; host 503s |
| `coturn` | matrix | 1 on closet | no PVC |
| `livekit-server` | matrix | 1 on closet, 250m/256Mi | no PVC |
| `heorot-voice-relay` | matrix | 1 on big | `/voice` 503s; no PVC |
| `tuwunel-conduwuit` | matrix | 1 on closet, 100m/256Mi | KEDA scale-to-zero, see below |
| `mattermost` | mattermost | already 0 since Jul (`ccaa274`) | — |
| `mattermost-db` | mattermost | 2 instances, one never Ready | `instances: 1` + hibernation |

`element-web` and `heorot` were already idle at 0 (`minReplicaCount: 0`), so they needed
nothing; they still wake on request.

## Commits

| commit | content |
|---|---|
| `0a9e10b` | the five Deployments → `replicas: 0`; `mattermost-db` `instances: 2 → 1` + `cnpg.io/hibernation: "on"`; `matrix.2143.me`'s `/` rule → the keda interceptor; `/spec/replicas` added to `apps/tuwunel.yaml` `ignoreDifferences`; new `apps/tuwunel-keda.yaml` over `workloads/tuwunel` |
| `e9b1056` | `workloads/tuwunel/service.yaml` (`tuwunel-http`, ClusterIP) + InterceptorRoute retarget. It **also carries `workloads/tuwunel/scaledobject.yaml`**, written earlier and swept in by `git add -A`; that file's rationale is in its header, not the commit message. |

## Decisions

**`tuwunel` idles instead of pinning to 0.** The conduwuit chart (2.1.0) hardcodes
`replicas: 1` in `templates/statefulset.yaml` and `values.yaml` exposes no
`replicaCount`, so no value yields 0. Owning a chart fork for a temporary pause was
rejected; the homeserver instead joins `element-web`/`heorot` behind the KEDA HTTP
add-on. Unlike those two — whose Deployments omit `replicas` entirely and leave the
field to KEDA — this StatefulSet *does* render `replicas: 1`, so `/spec/replicas` had to
join `ignoreDifferences`. Without it, selfHeal restores 1 and the app flaps 1→0→1.

**`mattermost-db` hibernates, and `instances` drops with it.** `cnpg.io/hibernation:
"on"` is only honoured on a `Ready` cluster — the operator keeps retrying instead, which
is exactly why `0f1bbd1` reverted the same annotation in October. The second instance
never became healthy on closet, so it both blocked hibernation and held a 1Gi request on
the node that needed it. `instances: 0` is not something CNPG accepts; `2 → 1` is the
repo's own precedent (`ccaa274`). After the scale-down the cluster reported Ready and
hibernated on its own.

**`/voice` stays out of the interceptor.** The `matrix-tuwunel` HTTPRoute keeps
`/voice → heorot-voice-relay` direct and sends only `/` through KEDA. An
InterceptorRoute resolves one target per host, so routing the whole hostname through it
would have sent `/voice` to the homeserver.

## Gotchas (load-bearing)

**A headless Service cannot sit behind the interceptor.** The first attempt 504'd after
a 60s hold on every request. The chart's Service is headless (`clusterIP: None` — it is
the StatefulSet's governing service) with `port: 8008, targetPort: http` while the
container actually listens on **80**. Traefik resolves an HTTPRoute backend to endpoint
addresses and dials the EndpointSlice port, so the mismatch never showed. The
interceptor instead dials `<service>:<target.port>` by name, and a headless Service has
no kube-proxy VIP to DNAT 8008 → 80. Fix: `tuwunel-http`, a real ClusterIP exposing
port 80 on the same pods. Any future interceptor target needs a normal Service on the
port the container listens on.

**A hung sync operation blocks every later sync, silently.** `mattermost-db` had an
operation `Running` since `05:12Z` on revision `f705e69`, waiting for a Cluster that
could never become Ready. ArgoCD starts no new operation while one is Running — there is
no timeout — so the new commit sat in git unapplied while the app read
`OutOfSync/Progressing`. Clearing the operation let the queued revision apply, which is
what made the cluster Ready and hibernated it. Note the `Application` CRD has **no
status subresource**, so a `kubectl patch --subresource=status` fails with NotFound.

**`ssh closet.local '<cmd>'` runs fish.** `grep -E` there is ripgrep and rejects `-E`;
run the query with `awk`, or pull `-o json` and filter with `jq` locally. Heredocs in
the remote command do not survive either.

## Verification

| claim | evidence |
|---|---|
| routing works through the interceptor | `curl https://matrix.2143.me/_matrix/client/versions` → 200; first request after zero took **14.7s** (cold start), steady state **55ms** |
| `tuwunel` really zeroed and woke | pod age reset to 110s on that first request; at 08:43Z `scaledobject tuwunel` was `READY True ACTIVE False` with `sts 0/0` |
| `mattermost-db` hibernated | no pods in `mattermost`; condition `cnpg.io/hibernation True/Hibernated`; Argo health `Suspended` |
| apps converge | `factorio`, `listen-brick`, `coturn`, `livekit`, `heorot-voice-relay`, `gateway`, `tuwunel`, `tuwunel-keda`, `mattermost` all `Synced/Healthy` |

Every changed manifest was validated with `kubectl apply --dry-run=server` before the
push — including the Helm-templated gateway route with its `{{- if }}` guards stripped.

## Bringing something back

- **Deployments** (`factorio`, `listen-brick`, `coturn`, `livekit-server`,
  `heorot-voice-relay`): set `replicas: 1`. ArgoCD does the rest.
- **`mattermost-db`**: set `cnpg.io/hibernation: "off"` (or raise `instances` again). The
  PVCs were never touched. Rehydration has not been drilled — see the board card.
- **`tuwunel`**: nothing to do, it wakes on the next request to `matrix.2143.me`. To
  remove the idle path entirely, delete `apps/tuwunel-keda.yaml` and the
  `/spec/replicas` ignoreDifference, and point the route's `/` rule back at
  `tuwunel-conduwuit:8008`.

## Not freed

Scaling to zero keeps every PVC: `tuwunel` 4Gi (`longhorn-3`, 3 replicas), `factorio`
31Gi (`longhorn-2`), `mattermost` ~32Gi, plus `mattermost-db-2`'s 14Gi now that the
instance is gone. Longhorn disk on closet is unchanged — reclaiming it is a separate
decision.
