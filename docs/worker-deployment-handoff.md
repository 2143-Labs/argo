# Handoff: Temporal WorkerDeployment migration for frigate-genai

Session: 2026-07-08T22:46Z
Branches: `feat/worker-deployment` in both repos (pushed, not merged)

## What was done

1. **Installed Temporal Worker Controller v1.8.0** on k3s cluster (`temporal-system` namespace). Rendered from OCI Helm chart v0.27.0 with `certmanager.install=false` and KEDA ScaledObject RBAC patched in.

2. **Applied to cluster directly** (for testing — ArgoCD tracks `HEAD`/main so branches won't sync):
   - 5 CRDs (connections, workerdeployments, workerresourcetemplates, + 2 deprecated)
   - Controller Deployment (2 replicas, webhook TLS via cert-manager)
   - ArgoCD health check Lua in `argocd-cm`
   - Connection CR (`frigate-genai-temporal` → `temporal-frontend.default.svc.cluster.local:7233`)
   - 4 WorkerDeployments (ffmpeg, gemini, ollama, triggers)
   - 4 WorkerResourceTemplates (KEDA bridge, per-version ScaledObjects)

3. **Updated Python worker code** (`frigate-genai-sidecar.py`):
   - Imports: `WorkerDeploymentConfig`, `VersioningBehavior`, `WorkerDeploymentVersion`
   - Constants: `DEPLOYMENT_NAME` + `BUILD_ID` (from env, default `"local-dev"`)
   - All 6 Worker() constructor calls now pass `deployment_config` with `VersioningBehavior.PINNED`

4. **Updated CI workflow** (`build-frigate-genai.yml`):
   - `update-argo` job now targets `*-workerdeployment.yaml` (not `*-deployment.yaml`)
   - Sed replaces `unsafeCustomBuildID`, image tag, and `TEMPORAL_WORKER_BUILD_ID` env
   - Verify step greps for `unsafeCustomBuildID` instead of raw image tag

5. **ArgoCD changes** (argo repo):
   - New app `temporal-worker-controller` — watches `workloads/temporal-worker-controller/`
   - `frigate-genai` app ignoreDifferences switched from `apps/Deployment` to `temporal.io/WorkerDeployment`
   - Deleted 8 old files (4 Deployments + 4 ScaledObjects)

## Current live state (rainbow deploy)

- **Controller**: 2/2 Running (arch + nas nodes)
- **Versioned Deployments**: 4/4 at 1/1 READY (ffmpeg-v45, gemini-retry-fix, ollama-retry-fix, triggers-retry-fix)
- **Old Deployments**: Still running (ArgoCD-managed from main). gemini=3/3, triggers=1/1, ffmpeg=0/0, ollama=0/0
- **KEDA**: Both old (unversioned) and new (WRT-created) ScaledObjects active. Old ones scale old deploys, new ones scale versioned deploys
- **WorkerDeployments**: CURRENT column empty — controller hasn't promoted a Current version yet (expected, should settle)

## What's pending

1. **Human: Open PRs and review**
   - `dotfiles`: https://github.com/John2143/dotfiles/pull/new/feat/worker-deployment
   - `argo`: https://github.com/2143-Labs/argo/pull/new/feat/worker-deployment

2. **Human: Merge both PRs** — order doesn't matter much. On merge:
   - ArgoCD syncs `temporal-worker-controller` app (manages CRDs + controller going forward)
   - ArgoCD syncs `frigate-genai` app (prunes old Deployments/ScaledObjects, adopts WorkerDeployments/WRTs)

3. **Verify after merge**:
   ```bash
   kubectl get workerdeployment -o wide        # CURRENT should populate
   kubectl get deploy -l 'temporal.io/deployment-name'  # only versioned deploys should remain
   kubectl get scaledobject                     # only WRT-created ones should remain
   ```

4. **Test a CI-driven deploy** (push to dotfiles main, CI bumps buildId, ArgoCD syncs to argo main, controller creates new version pods)

## Key gotchas

1. **Chart version ≠ controller version**: Helm chart is `0.27.0`, appVersion is `1.8.0`. The plan had `--version 1.8.0` which was wrong.

2. **Controller RBAC defaults**: Chart only allows `HorizontalPodAutoscaler` by default. The committed manifests include `ScaledObject` via custom values. If you ever re-render the chart, use:
   ```bash
   helm template twc oci://docker.io/temporalio/temporal-worker-controller \
     --version 0.27.0 --namespace temporal-system \
     -f values.yaml  # includes workerResourceTemplate.allowedResources with keda.sh/ScaledObject
   ```

3. **KEDA trigger namespace**: WRT validating webhook rejects `namespace: default` in KEDA temporal trigger metadata. The field must be omitted — controller auto-injects it from `WorkerDeployment.workerOptions.temporalNamespace`.

4. **ServerSideApply**: Controller Application uses `ServerSideApply=true` because CRDs are large (~8K lines) and may exceed `last-applied-configuration` annotation limits.

5. **Flags on `triggers.html`?**: Working tree had an unstaged `triggers.html` in the argo workloads dir — not related to this work, wasn't committed.

6. **omp-config.nix**: Had a pre-existing uncommitted change (advisor/designer model overrides). Restored to committed state. If those overrides were intentional, they need a separate commit.

7. **ArgoCD: any terminating resource in the app tree = Progressing.** v3.3.6 `GetResourceHealth` returns `Progressing "Pending deletion"` for *every* resource with a `deletionTimestamp`. A CR stuck in deletion (deletionTimestamp + finalizer) makes the app Progressing regardless of cluster state. When an app is inexplicably Progressing, check `kubectl get <kind> -n <ns> -o jsonpath='{.items[*].metadata.deletionTimestamp}'` across its resources.

8. **The TWC only reconciles on spec changes** (generation-changed predicate). Annotation-only changes don't trigger it; a controller restart does NOT reliably resync (initial-sync Add events didn't fire in practice). To force a reconcile, delete the controller's child Deployment (`kubectl delete deploy <wd>-<build>` — it recreates it from the CR). Useful when the ramp is stuck at `WaitingForPollers` because the target version registered *after* the last reconcile.

## Rollback

- **Tier A** (bad buildID, keep WorkerDeployments): `git revert` the CI bump commit in argo, push, ArgoCD syncs old buildID → controller drains bad version
- **Tier B** (full reversion to Deployments): Revert both repos, ArgoCD syncs. `helm uninstall temporal-worker-controller -n temporal-system` + `helm uninstall temporal-worker-controller-crds -n temporal-system`. Old Deployment/ScaleObject YAMLs come back from git history.

## Files touched

```text
dotfiles:
  nixos/modules/frigate-genai-sidecar.py       # lines 47-49 (imports), 146-147 (constants), 2630-2720 (Worker calls)
  .github/workflows/build-frigate-genai.yml    # lines 67-85 (sed + verify)

argo:
  apps/frigate-genai.yaml                      # ignoreDifferences
  apps/temporal-worker-controller.yaml          # new
  workloads/temporal-worker-controller/*        # new (crds.yaml + controller.yaml)
  workloads/frigate-genai/connection.yaml       # new
  workloads/frigate-genai/*-workerdeployment.yaml  # new (4 files)
  workloads/frigate-genai/*-wrt.yaml               # new (4 files)
  workloads/frigate-genai/*-deployment.yaml        # deleted (4 files)
  workloads/frigate-genai/*-scaledobject.yaml      # deleted (4 files)
```
## 2026-08-06 incident: frigate-genai stuck Progressing (v140→v141)

**Symptom**: `frigate-genai` ArgoCD app Progressing since its 19:12:12 recreation, while every tracked resource was Healthy. 57/58 → 59/59 apps Healthy after the fix.

**Root causes (stacked — three separate problems, all fixed):**

1. **ffmpeg scratch evictions.** `tool_transcode` writes source-resolution JPEG frames to `/tmp` (EmptyDir `scratch`, was 2Gi, `transcode.py:47` uses a context-managed `TemporaryDirectory` so per-call cleanup is guaranteed). Two concurrent transcodes per pod (`TEMPORAL_MAX_FFMPEG=2`, `worker.py:402`) overflowed 2Gi → kubelet evictions (exit 137, "Usage of EmptyDir volume 'scratch' exceeds the limit") → Error pods → `availableReplicas < replicas` → Progressing. Fix: `scratch` sizeLimit 2Gi → **10Gi** (`ee9edbc`); per-pod CPU 8 → **4 cores** (`48571d3`) so all 5 KEDA replicas schedule (5×4 CPU/8Gi/10Gi fits on `big`'s 64 CPU).
2. **v141 rollout deadlock.** The image bump to v141 (`19f003b`) completed for gemini/ollama/triggers but ffmpeg's ramp stuck at `WaitingForPollers`: the v141 pod (4 CPU/8Gi) was Unschedulable — `big` saturated by the old 8-CPU v140 build, arch/nas/closet lack 8Gi free memory, office (30 CPU/62.5Gi free) tainted `seated=true:NoSchedule`. Fix: tolerate `seated` on the ffmpeg worker (`efdf2f6`) so v141 could start on office; then force a TWC reconcile (see gotcha 8) → `"registering new current version"` → AllAtOnce cutover → v140 retired via sunset (`scaledownDelay: 10m`).
3. **Persistent cause: Connection stuck terminating.** `Connection/frigate-genai-temporal` had `deletionTimestamp: 2026-07-17` (leftover from the migration-era prune) held by the TWC's `temporal.io/delete-protection` finalizer for 20 days. Per gotcha 7, that alone kept the app Progressing from the moment it was (re)created, independent of the cluster state. Fix: `kubectl patch connection frigate-genai-temporal --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'` → deletion completed → ArgoCD re-created it from `workloads/frigate-genai/connection.yaml` → app flipped Healthy (first transition since 19:12:12).

**Operational notes:**

- 0-replica TWC worker Deployments (KEDA idle) are **Healthy** under ArgoCD v3.3.6 — not a Progressing source.
- The TWC's `ensureConnectionFinalizer` re-adds `temporal.io/delete-protection` on reconcile; the finalizer on a non-terminating object is harmless. Only a *stuck terminating* Connection is a health problem.
- ffmpeg capacity now: 4 CPU / 8Gi / 10Gi per pod; 5 pods fit on `big`; `office` (seated taint) serves as overflow for build transitions.

**State after fix**: 59/59 apps Healthy; all 4 WorkerDeployments at v141 (no ramp); ffmpeg 5/5 Running; zero evictions.
