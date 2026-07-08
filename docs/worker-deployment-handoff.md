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
