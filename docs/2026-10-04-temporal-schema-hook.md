# Temporal: schema migration as an Argo CD PreSync hook

**Date:** 2026-10-04
**Status:** implemented; one manual SYNC required after merge
**Scope:**
- `apps/temporal.yaml`

## Why it was wedged

- Deploys #71–#77 (2026-09-12 → 2026-09-13T08:09Z) all succeeded with the chart's default hook Job (`useHelmHooks: true`). #77 already ran chart 1.7.0 with `existingSecret: temporal-db-app`. Argo CD did **not** mishandle the helm.sh hook.
- On 2026-09-13, `ebe8117` added the app-wide `Replace=true` and `39b3b1a` set `schema.useHelmHooks: false`. Every failed sync comes after these two commits.
- With hooks off, the chart renders `Job/temporal-schema-1-7-0-1` as a normal tracked resource with `ttlSecondsAfterFinished: 86400`. The loop:
  1. The TTL deletes the finished Job.
  2. Argo reports it Missing, so the app is OutOfSync.
  3. The sync re-creates it through `Replace=true`, which fails with `Job.batch "temporal-schema-1-7-0-1" is invalid: [spec.selector: Required value, … field is immutable]`.
  4. Argo never auto-retries a failed sync at the same revision.
- The app sat `OutOfSync` with a failed last operation from 2026-09-26T23:47:53Z. Only that Job was OutOfSync; the other 14 resources and all 6 temporal pods were fine.

## The fix

`schema` values:
- `useHelmHooks: true`: the chart emits `helm.sh/hook: pre-install,pre-upgrade` and `hook-delete-policy: before-hook-creation,hook-succeeded` on `Job/temporal-schema`.
  - Argo CD maps these to a PreSync hook with BeforeHookCreation + HookSucceeded.
  - Hooks are excluded from sync-status comparison, so TTL or deletion can never make the app OutOfSync again.
  - The migration (`temporal-sql-tool setup-schema -v 0.0 && … update-schema`) is idempotent. It runs before every sync, including selfHeal syncs, and re-reads the CNPG password (`temporal-db-app/password`) each time.
- `backoffLimit: 5` and `activeDeadlineSeconds: 1800`: the chart default (100 retries, no deadline) could hold a failing hook's sync Running for hours.
- `securityContext` (non-root uid/gid/fsGroup 1000, seccomp `RuntimeDefault`) and `containerSecurityContext` (no privilege escalation, read-only root filesystem, drop ALL capabilities). These apply to both init containers and the `done` container.

`syncPolicy`:
- `Replace=true` is removed. It never fixed the immutability problem: replacing the Job from a manifest without the API-generated `spec.selector` is exactly the error above. Hook Jobs are deleted and re-created by BeforeHookCreation instead.
- `retry: {limit: 5, backoff: {duration: 1m, factor: 2, maxDuration: 10m}}` retries a failed automated sync (for example, the DB briefly unreachable during the hook).

Offline render (helm 4.3.0): every non-Job manifest is byte-identical before and after, so no temporal pod rolls.

Do not add `argocd.argoproj.io/hook` annotations to this chart. Per the Argo CD Helm docs, "If you define any Argo CD hooks, all Helm hooks will be ignored".

## Rollout

After the push, the desired state no longer contains a tracked Job and the other 14 resources are already Synced. The app therefore turns `Synced` without running anything. Argo CD's *Automated Sync Semantics*: "An automated sync will only be performed if the application is OutOfSync", and it "will not reattempt a sync if the previous sync attempt against the same commit-SHA and parameters had failed".

So the stale failed operation stays until someone presses **SYNC** on `temporal` once in the Argo UI (default options). Then:

```fish
kubectl --context closet-as-viewer get application -n argocd temporal -o jsonpath='{.status.operationState.phase} {.status.operationState.startedAt}{"\n"}{range .status.operationState.syncResult.resources[?(@.kind=="Job")]}{.name} {.hookType} {.hookPhase}{"\n"}{end}{.status.conditions}{"\n"}'
# expect: Succeeded <ts> / temporal-schema PreSync Succeeded / empty conditions
kubectl --context closet-as-viewer get job -n default temporal-schema   # NotFound: HookSucceeded deleted it
```

## If the hook fails

A failed PreSync blocks only that sync. The running temporal pods are unaffected. BeforeHookCreation keeps the failed Job until the next sync, so read its logs first:

```fish
kubectl --context closet-as-viewer get pods -n default -l job-name=temporal-schema
kubectl --context closet-as-viewer logs -n default <pod> -c manage-schema-default-store
kubectl --context closet-as-viewer logs -n default <pod> -c manage-schema-visibility-store
kubectl --context closet-as-viewer get application -n argocd temporal -o jsonpath='{.status.operationState.message}'
```

- `read-only file system` in either log: remove `readOnlyRootFilesystem: true` from `containerSecurityContext` (keep everything else), push, and press SYNC again.
- Anything else (DB unreachable, auth): fix the cause and press SYNC again. A manual SYNC is a single attempt; automated syncs use `syncPolicy.retry`.
