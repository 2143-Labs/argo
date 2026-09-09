# ChatGPT subscription access on llm-proxy (gpt-5.6-terra etc.)

Date: 2026-09-09
Commits: `ffb7534` (chatgpt provider + token PVC), `b9a8aaa` (drop yunwu.ai relays)

## What was added

The LiteLLM proxy (`llm.2143.me`, namespace `default`, ArgoCD app `llm-proxy`) can now serve ChatGPT Pro/Max **subscription** models via LiteLLM's native `chatgpt/*` provider. No third-party scraper/plugin. Requests are authenticated with an OAuth device-code login (the same flow the official Codex CLI uses) instead of an API key.

Config (in `workloads/llm-proxy/configmap.yaml`, model_list):

```yaml
- model_name: "chatgpt/*"
  model_info:
    mode: responses
  litellm_params:
    model: "chatgpt/*"
```

`mode: responses` is required. Any `chatgpt/<slug>` routes through — verified working: `chatgpt/gpt-5.6-terra`. Siblings `gpt-5.6-sol` / `gpt-5.6-luna` share the same codex backend.

## Token storage / persistence

- PVC `litellm-chatgpt-auth` (RWX, `longhorn-3`, 1Gi) in `workloads/llm-proxy/chatgpt-auth-pvc.yaml`.
- Env `CHATGPT_TOKEN_DIR=/litellm/chatgpt` in the deployment; the volume is mounted at `/litellm/chatgpt`.
- The OAuth token lives in `/litellm/chatgpt/auth.json` on the PVC, shared by both replicas. Do NOT `cat` it — it holds credentials. Verify with `kubectl exec <pod> -- ls /litellm/chatgpt/`.

RWX (not RWO) is load-bearing: the two replicas run on different nodes (`big`, `arch`) and both must read the same token file.

## Login procedure (and when you must re-login)

The token comes from a ChatGPT account with Codex access (device flow at `https://auth.openai.com/codex/device`). Login happens **out-of-band**, never via a proxied model request:

1. Watch a pod boot: `kubectl -n default logs -f deployment/litellm` — at startup, with no cached token, litellm validates the `chatgpt/*` model and prints a device code, then **blocks** until authorized.
2. Complete the code at `https://auth.openai.com/codex/device` (valid ~15 min).
3. litellm writes `auth.json` to the PVC and finishes booting. Subsequent pods/restarts read the token and boot without prompting.

Re-login is needed if auth fails / the session expires (watch pod logs for a fresh device-code prompt after a restart).

**Warning (upstream issue BerriAI/litellm#39546):** a proxied `chatgpt/*` request with no cached token starts a synchronous device login inside the serving worker and freezes it ~15 min (until k8s kills the pod). Always complete a login first. On boot this appears as a pod stuck `0/1` waiting on a device code — that is expected on the very first deploy; authorize the code from the logs.

## Cloudflare reality (verified 2026-09-09)

- **`/v1/responses` works end-to-end**: `POST /v1/responses` with `{"model":"chatgpt/gpt-5.6-terra","input":[{"role":"user","content":"…"}]}` (input MUST be a list — a bare string is rejected by the codex backend with `"Input must be a list"`) returns a completed stream with output text. Auth/routing all confirmed.
- **`/v1/chat/completions` is blocked**: the chat bridge calls `chatgpt.com/backend-api/codex/chat/completions`, which Cloudflare challenges (403, "Enable JavaScript and cookies to continue") from this cluster's egress. Upstream issue BerriAI/litellm#27175. Clients must use **Responses semantics** (`/v1/responses`), not chat completions, for `chatgpt/*` models.

## Notes / housekeeping

- Yunwu.ai relays were removed the same day (commit `b9a8aaa`): the `-official`/`-fast` tier aliases (claude-fable/opus, gpt-5.6-terra/luna/sol, gemini previews) and `yunwu/fast/*`, `yunwu/official/*` wildcards are gone. Direct-API wildcards remain: `ollama/*`, `gemini/*`, `deepseek/*`, `anthropic/*`, `openai/*`, `openrouter/*`, `moonshot/*`, plus `veo-3.1` and `chatgpt/*`.
- Image is still `ghcr.io/berriai/litellm:v1.92.0`. A bump (e.g. `v1.100.0`) may improve the chat-bridge path but requires a one-time prisma migration (schema drifted; `DISABLE_SCHEMA_UPDATE=true` is set) — treat as a separate, careful change.
- The empty-output bug (#25429) did not reproduce on the `/v1/responses` path on this image.
