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
- KEDA 2.17.0 temporal scaler scales worker deployments based on queue depth
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
Cause: LiteLLM proxy transient outage. With `_GENAI_RETRY` (5 attempts over ~135s), most transient 502s are handled.
If persistent: check LiteLLM at `llm.2143.me`, verify API keys in `frigate-genai-worker-creds`.

### Activity timeouts (heartbeat)
Symptom: `Activity task timed out` for genai turns.
Cause: LLM response > 300s (start_to_close_timeout) or heartbeat not sent within 15s.
Fix: genai timeout is 300s (5 min); for longer, increase `start_to_close_timeout` in workflow.

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
# Push code change → CI builds image → ArgoCD detects new tag
git add -A && git commit -m "..." && git push

# After CI completes (check https://github.com/john2143/dotfiles/actions):
# ArgoCD auto-syncs within 3 min. Force restart workers if needed:
kubectl rollout restart deploy/frigate-genai-gemini
kubectl rollout restart deploy/frigate-genai-ffmpeg
kubectl rollout restart deploy/frigate-genai-triggers

# Image is ghcr.io/john2143/frigate-genai-genai:latest with imagePullPolicy: Always
```

## Rollback

KEDA (ArgoCD-managed): change `targetRevision` in `argo/apps/keda.yaml` to previous version.
Worker deployments (ArgoCD-managed): revert the git commit, push, wait for sync.
Bucket data: TTL is 14d on new objects; existing objects with TtlSec=0 are permanent.
