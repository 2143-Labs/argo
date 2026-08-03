# Longhorn replica-tier restructure — execution log & paused-state handoff (2026-08-03)

**Status: PAUSED before any PVC migration. User requested no downtime right now.**
Nothing has been migrated. All rollback snapshots exist. Resume instructions below.

## 1. Authoritative references

- **Plan (source of truth for steps, commands, verification):**
  `/home/john/.omp/agent/sessions/-repos/2026-07-31T19-26-18-098Z_019fb9a4-43f2-7000-8663-9f3758d1bb08/local/longhorn-replica-tiers-plan.md`
  (session-local file; if lost, this doc + the repo commits reconstruct it — the plan is also summarized below).
- **Repo:** `~/repos/argo` (github.com/2143-Labs/argo). ArgoCD app-of-apps (`main.yaml`) watches `apps/`; every workload app has `automated.selfHeal: true`.
- **Cluster ops:** `ssh arch 'sudo k3s kubectl ...'` (workstation kubeconfig SA cannot read `longhorn-system`). Remote shell is **fish**: commands must be single pipelines / `kubectl -o jsonpath` with `range` — no bash `for` loops.

## 2. Commits (all pushed to origin/main, in order)

| commit | message | content |
|---|---|---|
| `179c080` | feat(storage): tiered longhorn SCs 1/2/3, rename longhorn to longhorn-3 | added `workloads/storage/longhorn-{1,2,3}-sc.yaml`, deleted `longhorn-sc.yaml` |
| `308bc13` | chore(storage): move workloads to tiered longhorn SCs | 19 files: storageClass refs moved to longhorn-2/3 (incl. `apps/seafile.yaml:33`, `workloads/tuwunel/tuwunel-values.yaml:70` — the latter not in the plan table but required for zero-match grep) |
| `3a8bff2` | fix(storage): align PVC replica annotations with tier counts | `longhorn.io/number-of-replicas` fixed on 4 files: mosquitto 3→2, pihole×2 3→2, teamspeak 3→2, home-assistant 2→3. **Needed so Verification 7 passes.** Pushed; ArgoCD sync of it is inert on live PVCs (annotations are not auto-applied to existing volumes — proven by pre-existing pihole skew). |
| (external) | frigate-genai v134/v135, seaweedfs QoS fixes | concurrent pushes from other agents; repo was rebased cleanly each time |

## 3. Live cluster state (verified 2026-08-03)

- **StorageClasses:** `longhorn-1` (1), `longhorn-2` (2), `longhorn-3` (3), `longhorn-cnpg` (1) exist; bare `longhorn` is **gone**. Storage app Synced.
- **All 25 migration PVCs are still on `longhorn` SC, Bound, unmigrated.** pihole Deployment is back at replicas 1/1 (selfHeal restored it after a test scale-to-0 — see §5).
- **25 `pre-migrate-<pvc>` Longhorn Snapshot CRs exist in `longhorn-system`, all `readyToUse=true`** — created upfront while all workloads ran (plan does them per-PVC; upfront is strictly safer). Delete only after ALL migrations + Verification pass.
- Longhorn v1.11.1; 6 Ready nodes (arch, big, closet, nas, office, pite).

## 4. The migration set (25 PVCs → ordered)

Order: low-value first, observability, then high-value; frigate and headscale LAST.
`sc` = target StorageClass. `vol` = Longhorn volume name (`spec.csi.volumeHandle`).

| # | namespace/name | PV | vol | size | sc |
|---|---|---|---|---|---|
| 1 | default/pihole-config-lh | pvc-0dbbdc7c-61d9-4115-a47c-cd28f0828b30 | same | 5Gi | longhorn-2 |
| 2 | default/pihole-dnsmasq-lh | pvc-388f27f8-316e-4f54-a263-2dea73a45f11 | same | 1Gi | longhorn-2 |
| 3 | default/mosquitto-data-lh | pvc-e8a098fa-835e-4e9a-9394-37f363475db2 | same | 1Gi | longhorn-2 |
| 4 | default/teamspeak-all-lh | pvc-f06012f1-ffff-4279-9905-144359eb15cc | same | 10G | longhorn-2 |
| 5 | kube-system/docker-registry | pvc-883bd590-92a8-4f21-a1a7-d41c50166e83 | same | 5Gi | longhorn-2 |
| 6 | default/home-assistant-config-lh | pvc-374214a1-74f2-4143-8c88-3bedafa66f0b | same | 50Gi | longhorn-3 |
| 7 | default/seaweedfs-master-data | pvc-d5021041-357b-4f3c-afcd-ca48db32dd67 | same | 1Gi | longhorn-3 |
| 8 | matrix/tuwunel-conduwuit-data | pvc-2fb820a3-351e-443d-93d3-97392b431a19 | same | 4Gi | longhorn-3 |
| 9 | stalwart/data-stalwart-stalwart-0 | pvc-acd281cd-6246-4523-9e61-c3a60798fd81 | same | 20Gi | longhorn-3 |
| 10 | pocket-id/pocket-id-data-pocket-id-0 | pocket-id-restored-pv | **pocket-id-restored** | 5Gi | longhorn-3 |
| 11 | default/matter-server-data-restored | matter-server-data-restored-pv | **pvc-a71a966d-restored** | 4770Mi | longhorn-3 |
| 12 | observability/data-loki-write-0 | pvc-b60f0f4f-3ac7-4804-a9a8-558a83db9d3c | same | 20Gi | longhorn-2 |
| 13 | observability/data-loki-write-1 | pvc-315aeede-fc01-4b96-a51f-16bd67e68a46 | same | 20Gi | longhorn-2 |
| 14 | observability/data-loki-backend-0 | pvc-d95bb562-d1af-4b4c-9f16-e4ae31ec2462 | same | 10Gi | longhorn-2 |
| 15 | observability/data-loki-backend-1 | pvc-e59d582e-d5b9-45dd-ae9d-503fd0e75ce3 | same | 10Gi | longhorn-2 |
| 16 | observability/storage-mimir-0 | pvc-438dc3c1-eee8-4dc4-8131-c683d222ef1b | same | 30Gi | longhorn-2 |
| 17 | observability/storage-mimir-1 | pvc-83dfcfca-62f5-4510-a60b-859e76cb9d27 | same | 30Gi | longhorn-2 |
| 18 | default/litellm-redis-data-lh | pvc-3fa989d6-73ba-4ece-87e4-11778a18a70d | same | 1Gi | longhorn-3 |
| 19 | default/unifi-data | pvc-52b14256-466f-48c3-9cc5-8dc0e5c41678 | same | 10G | longhorn-3 |
| 20 | default/unifi-mongodb-data | pvc-754fa733-53fa-47ba-95ff-2264e1d9774d | same | 5Gi | longhorn-3 |
| 21 | mattermost/mattermost-config | pvc-6039965f-e9ea-4331-95f3-6cb62e7fd7d9 | same | 1Gi | longhorn-3 |
| 22 | mattermost/mattermost-data | pvc-190bc839-816f-4c2b-9665-096182f1ef52 | same | 20Gi | longhorn-3 |
| 23 | default/data-seafile-mariadb-0 | pvc-fe30c32a-ba6f-4c15-9ac5-965073429c86 | same | 10Gi | longhorn-3 |
| 24 | default/frigate-config | pvc-7869b719-5bc7-4ad5-a621-d77fab4edfd3 | same | 20Gi | longhorn-3 |
| 25 | default/headscale-data-lh | pvc-d6926bd9-5fd6-4100-a601-85f675f90e23 | same | 1Gi | longhorn-3 |

Per-PVC mechanics (identical for all): scale owning workload to 0 → delete PVC (PV goes Released; Retain keeps data) → patch PV `storageClassName=<target>` + remove `/spec/claimRef` → recreate PVC (same name/ns, RWO, same size, `storageClassName=<target>`, `spec.volumeName=<pv>`) → wait Bound → scale back → verify data via `kubectl exec <pod> -- ls <mount>`.
**Never-run guard: never `kubectl delete pv` / `delete volume` on any migrated volume.**
STS variant: `loki-backend` AND `loki-write` are StatefulSets (verified) — scale the STS to 0 before deleting each of its PVCs, run steps, scale back; the controller adopts the pre-created PVC bound to the original PV.
All loki PVC sizes above (20Gi/10Gi) and mimir (30Gi) verified live; matter-server is 4770Mi, teamspeak 10G.

Out of scope (leave untouched): CNPG PVCs (`litellm-db-1/3`, `temporal-db-1/3`, `mattermost-db-2`, `seaweedfs-filer-data`, + `-wal`), `frigate-recordings` (static NFS PV, no SC), `seafile-data` (local-path SC).

## 5. BLOCKER: ArgoCD selfHeal fights `kubectl scale` (analysis, 2026-08-03)

Evidence: `kubectl scale deploy/pihole --replicas=0` reverted to 1 within **≤10s**, twice. No HPA on pihole (only `keda-hpa-frigate-genai-*` exist cluster-wide). No `--timeout.reconciliation` on argocd-server or the controller; `argocd-cmd-params-cm` only sets `server.insecure`. Cause: every app has `automated.selfHeal: true` and ArgoCD refreshes apps on repo webhooks — this repo saw 3 external pushes this hour, keeping refreshes hot. The plan's "re-run step 3" mitigation is unworkable: the `kubernetes.io/pvc-protection` finalizer needs the pod fully gone (~10-30s), selfHeal resurrects it in ~10s.

Two races:
- **(a) scale-to-0 revert** — blocks PVC deletion.
- **(b) git-tracked PVC recreated by selfHeal/automated sync** after step-4 delete, from the manifest with the new SC and NO `volumeName` → fresh EMPTY volume. Mitigation (if racing): delete the recreated PVC, confirm original PV is `Available`, redo PVC recreation with `volumeName`.

**The application controller is a StatefulSet**: `argocd/argocd-application-controller` (1/1, 125d — v7 chart layout). No HPA on it; replicas not pinned in git.

### Options (analysis — user chose to PAUSE, no downtime now)

- **B (recommended for resume): pause the controller** — `ssh arch 'sudo k3s kubectl -n argocd scale sts argocd-application-controller --replicas=0'` for the migration window, then `--replicas=1`. Kills BOTH races deterministically; concurrent pushes harmless while paused; k8s/Longhorn reconciliation unaffected; reversible anytime; resume syncs cleanly (annotation-fix commit 3a8bff2 applies inertly). Supersedes the plan's selfHeal mitigation paragraph.
- A: declarative `replicas: 0` in git per workload (~36 commits) or one batch (all down at once). Race (b) remains live on any push.
- C: declarative `selfHeal: false` on ~18 `apps/*.yaml` (2 commits). Race (b) remains live on any push.
- D: live-patch app CRs — NOT viable (app-of-apps selfHeal reverts).

## 6. Resume runbook

1. **Pick option** (§5; B recommended). If B: pause the controller STS, confirm `readyReplicas=0`.
2. **2b migrations** — the 25 PVCs in the table order, per-PVC mechanics above. Snapshots already exist (do NOT re-create). Verify each: PVC Bound on the ORIGINAL PV (`get pvc <name> -n <ns> -o jsonpath='{.spec.volumeName}'`), workload Ready, data present.
3. **2c replica alignment** — after ALL migrations, patch the seven tier-3 volumes below 3 replicas to `numberOfReplicas: 3`:
   `ssh arch 'sudo k3s kubectl -n longhorn-system patch volume <vol> --type merge -p "{\"spec\":{\"numberOfReplicas\":3}}"'`
   Volumes: `pvc-d6926bd9-...` (headscale, 1→3), and for home-assistant, stalwart, matter-server (`pvc-a71a966d-restored`), tuwunel, seaweedfs-master, pocket-id (`pocket-id-restored`) — get their volume names via `get pv <pv> -o jsonpath='{.spec.csi.volumeHandle}'` (all 2→3). Wait for 3 `running` replicas on distinct ready nodes, `robust=healthy`.
4. **Step 3 fixups** (independent):
   - 3a: create `apps/nvidia-device-plugin.yaml` (copy `apps/storage.yaml` structure, path `workloads/nvidia-device-plugin`, ns `kube-system`, automated+prune+selfHeal) — auto-discovered by app-of-apps; commit+push.
   - 3b: backup coverage — labels live on volume CRs (`recurring-job-group.longhorn.io/default: enabled`) and survive migration; spot-check each migrated volume after 2b; no re-arm.
   - 3c: delete orphan volumes: PVs `pvc-62768d87` (spire-root), `pvc-a95fad71` (spire-internal), `pvc-a9ea483e` (spire-external), `pvc-b2fb636d` (pocket-id-prod — carries claimRef named like the LIVE claim; deletion safe); volumes `unifi-config-real`, `unifi-mongo-check` (no PV — delete the volume directly). Pre-check no PVC/deploy/sts references. Intentional deletes — the 2b never-run guard does not apply.
   - 3d: `ssh arch 'sudo k3s kubectl label node big nvidia.com/gpu.present-'`.
5. **Verification 1-11** (from the plan file): SCs present/absent; canary provisioning proof (create+delete canary PVCs for longhorn-1/2 — clean up PVC+Released PV+volume); allocations grep; repo zero-match grep (use ANCHORED pattern `storageClass(?:Name)?: "?longhorn"?$` — the plan's literal pattern also matches `longhorn-2/3/cnpg` and is buggy); data spot checks (frigate /api/version, pihole admin, home-assistant dir listing); replica alignment (7 volumes); audit (PVC annotations vs live counts — passes now thanks to 3a8bff2); device-plugin app Synced/Healthy; backup label + newest backup CR dated ≥ migration day; orphans gone; label removed.
6. **Cleanup**: delete the 25 `pre-migrate-*` snapshots (`sudo k3s kubectl -n longhorn-system delete snapshot pre-migrate-<pvc>` for each) ONLY after all migrations + Verification pass.
7. If B was used: controller resume happens at the start of step 5 (or right after 2b — statuses needed for Verification 8).

## 7. Gotchas

- Remote shell is fish: no `for` loops; single jsonpath `range` or grep-filter locally.
- Push discipline: `git fetch origin && git rebase origin/main && git push` — the repo gets concurrent pushes; never force-push, never `--no-verify`.
- The plan's literal Verification-4 grep matches the NEW SC names too (`longhorn` substring) — use the anchored variant in §6.5.
- Do not re-create snapshots; do not delete them before the end.
- `longhorn-cnpg` (CNPG DBs) and `longhorn-static` SCs are intentionally untouched.
- Backups: `nightly-backup` RecurringJob healthy (34 CRs/night); volume CRs carry the recurring-job group label; PVC recreation does not disturb coverage.
- External pushes while paused are fine; if an external push touches `apps/*.yaml` or a workload manifest mid-resume, re-check the app sync state before continuing.
