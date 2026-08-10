# Frigate GenAI — Operations Runbook

## Architecture

```
[MQTT] → triggers-pod (workflow starter + HTTP API + pause mgmt)
               ↓
        [Temporal Server]
       /      |        \      \
  genai-tasks  ffmpeg   gemini  ollama
  (misc acts)  queue    queue   queue
       ↓        ↓        ↓       ↓
   triggers    ffmpeg   gemini  ollama
   (no KEDA)  (KEDA)   (KEDA)  (KEDA)
```

- 4 Temporal task queues: `genai-tasks` (misc activities), `genai-tasks-ffmpeg`, `genai-tasks-gemini`, `genai-tasks-ollama`
- KEDA 2.20.1 temporal scaler scales worker deployments based on queue depth
- Scale-to-zero when idle; triggers pod always runs
- S3 (SeaweedFS `frigate-genai` bucket) stores pause state (`events/_paused/*`), stats (`events/_stats.json`), and per-event frames
- Gateway API HTTPRoute on `cameras.ts.2143.me:8443` with wildcard TLS

## Health Checks

```fish
# KEDA operator
kubectl get pods -n keda | grep operator

# ScaledObjects (all should be Ready=True)
kubectl get scaledobject

# HPAs (metrics show numeric values when tasks exist; <unknown> is normal when idle)
kubectl get hpa

# Worker pods (ffmpeg=0-3, gemini=0-5, ollama=0-1; 0 when idle)
kubectl get pods -l app=frigate-genai-gemini
kubectl get pods -l app=frigate-genai-ffmpeg
kubectl get pods -l app=frigate-genai-ollama

# Triggers pod (always running)
kubectl get pods -l app=frigate-genai-triggers

# Stale-workflow sweep CronJob (terminates workflows Running > 6h, every 30 min)
kubectl get cronjob -n default frigate-genai-stale-workflow-sweep

# API stats (events processed, mqtt/temporal connection)
curl -sk https://cameras.ts.2143.me/api/stats

# Check pending workflows
open https://temporal.ts.2143.me
```

## Pause / Unpause

```fish
# Pause a model (creates S3 object)
curl -X POST https://cameras.ts.2143.me/api/pause/ollama

# Unpause
curl -X DELETE https://cameras.ts.2143.me/api/pause/ollama

# List paused models
curl -sk https://cameras.ts.2143.me/api/pause
```

## Common Failure Modes

### KEDA operator CrashLoopBackOff
Symptom: ScaledObjects stuck `READY: False`, workers never scale up.
Cause: Missing CRD (usually `scaledjobs.keda.sh` after Helm migration).
Fix: `kubectl apply --server-side -f <url>` for the missing CRD, then delete the operator pod.

### Workers scale but workflows fail with 502
Symptom: Temporal shows `InternalServerError: Bad Gateway` on genai turns.
Cause: LiteLLM proxy transient outage. With `_GENAI_RETRY` (20 attempts, 1s→60s exponential backoff), most transient 502s are handled.
If persistent: check LiteLLM at `llm.2143.me`, verify API keys in `frigate-genai-worker-creds`.

### Activity timeouts (heartbeat)
Symptom: `Activity task timed out` for genai turns.
Cause: LLM response > 600s (start_to_close_timeout) or heartbeat not sent within 15s.
Fix: genai turn timeout is 600s (10 min) with a 1h schedule_to_start timeout (drained-version orphans expire); for longer, increase `start_to_close_timeout` in `workflows/agent_session.py`.

### S3 AccessDenied
Symptom: `botocore.exceptions.ClientError: AccessDenied` in triggers pod logs.
Cause: Missing Admin permission on SeaweedFS S3 user.
Fix: Apply `argo/workloads/seaweedfs/s3-config.yaml`, restart filer.

### ollama globally paused
Symptom: No ollama workers ever spawn, all genai routes to gemini.
Check: `curl -sk https://cameras.ts.2143.me/api/pause` — if ollama is listed, unpause it.
Note: ollama is intentionally paused when ollama model is not available.

## Deploy Changes

```fish
# Push code change to dotfiles (paths under nixos/modules/frigate_genai/**):
# → GitHub Action builds the genai + ffmpeg images, pushes ghcr v<run_number>,
#   auto-commits the image/build-id bump to this repo
# → ArgoCD syncs → the Temporal worker-deployment controller rolls the new build out.
git add <files> && git commit -m "..." && git push

# After CI completes (check https://github.com/john2143/dotfiles/actions):
# do NOT kubectl rollout restart — the controller owns the deployments. Verify with:
temporal worker deployment describe -d default/frigate-genai-gemini
# (new build shows Current within ~15 min of the argo auto-commit)

# Rollback: git revert the argo auto-bump commit and push → controller drains the
# bad build and re-promotes the previous tag.
```

## Rollback

KEDA (ArgoCD-managed): change `targetRevision` in `argo/apps/keda.yaml` to previous version.
Worker deployments (ArgoCD-managed): revert the git commit, push, wait for sync.
Bucket data: TTL is 14d on new objects; existing objects with TtlSec=0 are permanent.

---

# steam-lobby PR previews

Every PR to `2143-Labs/steam-lobby` gets a live preview at `https://pvp-{N}.john2143.com` (dev), while `pvp.john2143.com` stays production.

How it works: an [ApplicationSet PR generator](apps/steam-lobby-preview.yaml) polls the GitHub PR API (120s) and, per open PR, renders an Application that deploys the Helm chart `workloads/steam-lobby-preview/` into its own namespace `steam-lobby-pr-{N}`:

- PR-tagged image `ghcr.io/2143-labs/steam-lobby:pr-{N}` (built by the repo's `build.yaml` workflow)
- its own CNPG Postgres (`steam-lobby-db-pr-{N}`, throwaway)
- shared cluster Temporal with a per-PR task queue `lobby-pr-{N}` (isolated from prod's `lobby` queue)
- dev-mode auth: `AUTH_DEV_MODE=true` — anyone can mint a test token; no prod credentials (no TURN, no Discord/OIDC)
- URL at `pvp-{N}.john2143.com` via the shared gateway (`john2143-https` listener, wildcard TLS)

PR close/merge → the Application and its namespace are pruned automatically.

## Health checks

```fish
# Per-PR stack
kubectl get app -n argocd steam-lobby-pr-{N}
kubectl get cluster,secret,deploy,pods -n steam-lobby-pr-{N}

# Reachability + dev auth
curl -s https://pvp-{N}.john2143.com/health
curl -s -X POST https://pvp-{N}.john2143.com/auth/test-token \
  -H 'content-type: application/json' -d '{"steam_id": 900000}'
```

## Cleanup

Per-PR Temporal schedules are normally paused when idle. If a PR closes while players were queued, delete the lingering schedule (via the `temporal-admintools` pod):

```fish
kubectl exec -n default <temporal-admintools-pod> -- temporal schedule delete \
  --schedule-id matchmaker-ranked_1v1-lobby-pr-{N} --namespace pvp
```
