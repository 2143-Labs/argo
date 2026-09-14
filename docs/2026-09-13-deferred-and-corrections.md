# Deferred items and corrections — 2026-09-13 remediation

Three things that need to be on the record: a version deliberately held back, a correction to an earlier commit message, and an unresolved infrastructure gap.

## 1. UniFi held at 10.4.57 (decision, not an oversight)

UniFi stays on `lscr.io/linuxserver/unifi-network-application:10.4.57-ls136` with `docker.io/mongo:7.0`. It is healthy at 2/2.

The 10.6 upgrade was attempted and reverted. The failure signature, for whoever tries again:

- UniFi `10.6.101-ls145` exits with code 14 and `com.mongodb.MongoTimeoutException … ReadPreferenceServerSelector`.
- The MongoDB sidecar crash-loops emitting an `F`-severity `Writing fatal message` with a `currentOp` dump showing a COLLSCAN on `unifi.network_heartbeat`.
- Raising UniFi to 4 GiB and Mongo to 2 GiB did **not** change the outcome, and neither did moving Mongo to 8.0.

**Recommended path before any retry:** establish Ubiquiti's required MongoDB version for the 10.6 line first, take a `mongodump` of the `unifi` database, and only then change the image. Never a bare image bump.

The raised resource limits (UniFi 4 GiB, Mongo 2 GiB) were kept: they are harmless and were demonstrably not the cause.

## 2. Correction: the rationale in the ArgoCD v3.5.2 commit was wrong

Commit `c3ba3e3` ("chore(argocd): step v3.4.8 -> v3.5.2") states that 3.5 brought "support for Kubernetes v1.33+", "the removal of a number of long-deprecated API versions", and the removal of legacy `argocd-util` settings commands.

**Those claims were not verified and are not what the upgrade notes say.** The documented breaking changes for 3.4 → 3.5 are:

1. **Helm was upgraded to 4.2.0.** In Helm v4 the OCI implementation is stricter: a registry that does not speak TLS requires an explicit `--insecure-oci-force-http` (CLI) or `insecureOCIForceHttp: "true"` (repo Secret). There is also a known limitation when both `--insecure-skip-server-verification` and `--insecure-oci-force-http` are set on the same repo — Helm v4 silently drops `--plain-http`.
2. **UI extensions must externalise `react/jsx-runtime`** (the UI moved from React 16 to React 19). Only affects installations that ship UI extensions.
3. **Event-listing gRPC methods now return an ArgoCD `EventList` type.**

The substance of the upgrade stands — ArgoCD is on v3.5.2, all 75 Applications are Synced/Healthy, and the upgrade path 3.3.14 → 3.4.8 → 3.5.2 completed cleanly — but the *reasoning* recorded in that message should not be relied on. The commit message was not rewritten because the branch is shared and rewriting published history is worse than correcting it.

**Impact assessment for this cluster, checked rather than assumed:**

- **OCI Helm sources: none affect the home cluster, one affects CI.** Enumerating every `repoURL:` in the repo gives 17 entries: sixteen are `https://` Helm indexes or git sources, and exactly one is an OCI registry — `ghcr.io/actions/actions-runner-controller-charts`, in `apps/ci/arc-controller.yaml` and `apps/ci/arc-runners.yaml`. Those files are for the **CI** cluster and are never synced from here, so the home cluster is unaffected by the Helm 4 OCI strictness change. The CI cluster, however, will need that OCI repo registered (its repo-server must have OCI Helm repositories enabled, and its AppProject must allow the `ghcr.io` source) before those two Applications can sync — flagged in that commit message too. The seventeen: argo-helm, chartmuseum-free HTTPS Helm indexes for jetstack, longhorn, cloudnative-pg, crowdsec, temporal, grafana, grafana-community, prometheus-community, kedacore, stakater, metallb, openbao, external-secrets, plus two git sources (this repo, kubernetes-sigs/gateway-api), and the single ghcr.io OCI entry above.
- No `spec.source.helm.version` overrides: `grep -rn "version: v3" apps/ workloads/` → no matches. The "setting ignored, Helm v4 used" note does not apply.
- No UI extensions installed.
- The gRPC event-list type change is internal to ArgoCD's API; nothing in this repo calls it.

So the cluster is unaffected by all three breaking changes — but that is a conclusion from checking, not from the original claim.

## 3. Unresolved: the host-metrics scrape pipeline is down

Recorded in full in `docs/2026-09-13-disk-health.md`. In short: the `smartctl`, `home-nodes`, `blackbox-http` and `blackbox-tcp` jobs stopped reporting to Mimir at ~11:15 on 2026-09-13. The exporters are up and Mimir is up; the **external scraper** that fed them is not part of this cluster (the in-cluster Alloy DaemonSet defines none of those jobs), so it is repaired outside this repo.

Consequences while it is down: `ReallocatedSectors` can never fire, `nas` node metrics are absent, and the two public sites have no blackbox uptime checks.

## 4. Also worth picking up

- **`ReallocatedSectors` fires on presence, not growth.** `> 0` means a single lifetime-retired sector alerts forever. Growth-based and pending/uncorrectable split rules are proposed in the disk-health doc.
- **Filesystem headroom** (arch 83.7%, office 83.7%, big 80.2%) was explicitly excluded from this pass by the user and remains outstanding.
- **`mattermost-db-password`** is referenced by `workloads/mattermost-db/cnpg-cluster.yaml` but does not exist; either create it or drop the dangling `passwordSecret` reference.
- **OpenBao admin access** — see `docs/2026-09-13-secrets-inventory.md` §1. One policy and one auth role are all that stand between the current state and a working ESO pipeline.
