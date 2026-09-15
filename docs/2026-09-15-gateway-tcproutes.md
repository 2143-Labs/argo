# Gateway TCPRoute incident: broken Traefik provider fixed via the experimental CRD (2026-09-15)

**Status: COMPLETE and verified.** One of three Traefik replicas answered `404` and presented Traefik's built-in default certificate for every hostname because its Gateway provider could never start — an informer whose `v1alpha2.TCPRoute` watch cannot sync emits no configuration at all. Fixed by installing the experimental-channel `tcproutes` CRD (Gateway API v1.6.2) via GitOps and removing the `safe-upgrades` ValidatingAdmissionPolicy that blocked it. Post-fix: all three replicas serve `*.ts.2143.me` with `307`; 24/24 LoadBalancer handshakes present the wildcard certificate; no `Failed to watch` lines remain.

## 1. Commits (pushed, in order)

| commit | repo | message | content |
|---|---|---|---|
| `b0cc717` | argo | fix(gateway): exclude the safe-upgrades VAP so the experimental TCPRoute CRD can install | `apps/gateway-api-crds.yaml` — `directory.exclude` becomes the single no-space brace glob `{gateway.networking.k8s.io_tcproutes.yaml,gateway.networking.k8s.io_vap_safeupgrades.yaml}` + rationale comment |
| `5dddbeb` | argo | fix(gateway): pin tcproutes app to the v1.6.2 SHA to reset ArgoCD's failed-sync guard | `apps/gateway-api-crds-tcproutes.yaml` — `targetRevision` pinned to `ca6c2a65…` (the commit behind tag `v1.6.2`) so auto-sync retries after its failed-attempt lock |

The VAP and its binding were deleted imperatively (binding first), one time — ArgoCD cannot express "this object must not exist" without `prune: true` on a CRD-managing Application, which would make CRD deletion a side effect of any future path/exclude change.

## 2. Symptom and measurement

- `fbe9884` bumped Gateway API **v1.5.1 → v1.6.2** (landed 2026-09-13 02:13 UTC). The v1.6.2 **standard** channel declares `tcproutes` `v1alpha2 served: false`.
- Traefik **3.7.8** (k3s bundled HelmChart `traefik-40.1.4+up40.1.0`, namespace `kube-system`, 3 replicas) runs `--providers.kubernetesgateway.experimentalchannel=true` and therefore watches `v1alpha2.TCPRoute` — the version the new standard CRD stopped serving.
- A provider whose informer cannot sync emits **no configuration at all**: a freshly started replica has no routers and no certificates, so it answers `404` and presents `TRAEFIK DEFAULT CERT` for every hostname on the cluster.
- Measured 2026-09-15 (pre-fix): 10 of 24, then 8 of 24 TLS handshakes to `openbao.ts.2143.me` got `TRAEFIK DEFAULT CERT` — i.e. roughly one third of connections failed certificate validation.

## 3. Why only one of three replicas broke

The two healthy replicas (`qffjq`, `rcrbw`, started 2026-08-20/24) had their informers sync **before** the CRD changed and keep the last-good configuration in memory. They log the *same* `Failed to watch … *v1alpha2.TCPRoute` error and would break on any restart. Only the replica that started after the CRD change (`t4nk7`, 2026-09-14) had no prior config to fall back on.

## 4. The fix

- `apps/gateway-api-crds.yaml` now excludes **both** the `tcproutes` CRD and the `gateway.networking.k8s.io_vap_safeupgrades.yaml` file (one file, two documents) from the standard-channel install — verified by the two resources flipping to `requiresPruning` in ArgoCD.
- `apps/gateway-api-crds-tcproutes.yaml` (already committed in `59090cb`) owns the `tcproutes` CRD from Gateway API v1.6.2's `config/crd/experimental`, which serves `v1` **and** `v1alpha2`. This is the combination Traefik 3.7 documents support for ("TCPRoute from the Experimental channel").
- The VAP and binding `safe-upgrades.gateway.networking.k8s.io` were deleted (binding first) and confirmed NotFound cluster-wide.
- **ArgoCD quirk hit mid-run:** after a *failed* sync, auto-sync refuses to retry the same source spec (see §6). The initial install stayed stuck even with the VAP gone; pinning `targetRevision` to the v1.6.2 commit SHA (identical content) reset the guard and the sync succeeded.
- The still-broken replica `t4nk7` was deleted — the only pod deletion; the two healthy replicas were never restarted. The replacement (`8c8sn`) started with a working provider.

## 5. Why the VAP was deleted — and what it costs

The `safe-upgrades` ValidatingAdmissionPolicy denies UPDATEing a `gateway.networking.k8s.io` CRD from `channel=standard` to `channel=experimental` — which is exactly what this install does. Upstream's own denial message names uninstalling the policy as the procedure for installing experimental CRDs. Its second rule blocked bundle versions older than v1.5.0 and `-rc` versions; every CRD here is pinned to v1.6.2, so that rule was not protecting anything in practice.

**Cost, stated plainly:** CRD installs in the `gateway.networking.k8s.io` group are now unguarded. In particular, the guard against pre-v1.5.0 / `-rc` bundle versions is gone — a future Gateway API downgrade would no longer be rejected by policy. Treat Gateway API version pins as load-bearing.

## 6. ArgoCD automation notes (why the SHA pin is permanent)

ArgoCD's application controller refuses to auto-sync an application whose **last sync attempt to the current source spec failed** (`alreadyAttemptedSync` in the controller). The guard is keyed on `spec.source`, not the cluster state, so deleting the blocking object (here, the VAP) does not clear it: the app stays `OutOfSync` with a stale `SyncError` until the source changes or a manual sync runs. Because this Application's `targetRevision` is a pinned tag, the source was byte-identical and the lock was permanent. Changing `targetRevision` to the commit SHA the tag resolves to (`ca6c2a65…`) — same content, different spec string — resets the guard, and the guard will stay reset on future failures *as long as the source is a SHA*. Hence the pin is kept, and the comment in the file records to bump the SHA together with the tag in `apps/gateway-api-crds.yaml`. Do not "tidy" the SHA back to the tag: it is the thing that makes failed syncs self-heal.

## 7. Verification (all passed)

| check | result |
|---|---|
| VAP excluded from GitOps | both VAP resources `requiresPruning: true`; 9 CRDs `Synced` |
| VAP gone | `kubectl get validatingadmissionpolicy,validatingadmissionpolicybinding -A` → no `safe-upgrades` |
| CRD serves both versions | `[('v1', True), ('v1alpha2', True)]`, channel annotation `experimental` |
| Traefik per-replica | all 3 pods: `cert=*.ts.2143.me` + `HTTP/1.1 307 Temporary Redirect` on `:8443` |
| LoadBalancer end-to-end | 24/24 handshakes to `openbao.ts.2143.me:443` → `{'*.ts.2143.me': 24}` (pre-fix baseline `16/8`) |
| Watch errors | 0 `Failed to watch` lines in any pod's recent logs |

## 8. Watch items

- **`directory.exclude` is a single brace pattern.** Anyone editing it in `apps/gateway-api-crds.yaml` must keep both filenames, on one line, comma-separated with **no spaces**; a space or a line break makes the pattern fail to match and the VAP gets re-managed (and re-created by self-heal).
- **Gateway API bumps** must update both Applications: the tag in `apps/gateway-api-crds.yaml` and the SHA in `apps/gateway-api-crds-tcproutes.yaml`, and must verify the experimental channel still serves `v1alpha2`.
- **The two surviving replicas** (`qffjq`, `rcrbw`) are from 2026-08-20/24 with long-lived informers; they will rebuild cleanly on rollover now that the CRD serves the watched version. Rolling the Traefik Deployment is safe now but was deliberately deferred — it belongs in a maintenance window.