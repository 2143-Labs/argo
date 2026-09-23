# Claude Code on the Claude Max subscription via llm-proxy

Date: 2026-09-23
Commits: `9f0745e` (llm-proxy: `claude-*` OAuth passthrough groups). Client side: dotfiles `0ebc1e1` (`claude` wrapper) — local commit, not pushed.

## What was added

Two model groups in `workloads/llm-proxy/configmap.yaml` so the official `claude` CLI (Claude Code) can talk to Anthropic through `llm.2143.me` on its **Claude Max subscription** instead of the platform `ANTHROPIC_API_KEY`:

```yaml
- model_name: "claude-*[1m]"
  litellm_params:
    model: "anthropic/claude-*"
- model_name: "claude-*"
  litellm_params:
    model: "anthropic/claude-*"
```

Both groups are required:

- Claude Code appends a literal `[1m]` to the model id for 1M-context models (verified in claude-code 2.1.280: picker values `claude-opus-4-8[1m]`, `claude-sonnet-5[1m]`).
- `claude-*[1m]` looks like a regex character class but is not one: litellm builds the pattern with `re.escape(pattern).replace(r"\*", "(.*)")` (`litellm/router_utils/pattern_match_deployments.py` → `PatternUtils._pattern_to_regex`), so `[1m]` is matched literally.
- Patterns are tried most-specific-first (`PatternUtils.sorted_patterns`, key `(len, complexity)` descending) and the capture group replaces the `*` in `litellm_params.model` (`PatternMatchRouter.set_deployment_model_name`), which is what strips the suffix: `claude-opus-4-8[1m]` → `anthropic/claude-opus-4-8`.
- The bare `claude-*` group also matches `[1m]` names, so it must not be the only entry — without the specific pattern the suffix would reach Anthropic as a bogus model id.

The literal `anthropic/claude-*` form is load-bearing. `model: "anthropic/*"` would produce `anthropic/opus-5`, because the capture group substitutes positionally (it drops the `claude-` prefix).

## Header flow

Claude Code sends two credentials, and litellm must treat them differently:

```
Authorization:      Bearer sk-ant-oat...   (Claude Max subscription token — must reach Anthropic)
x-litellm-api-key:  Bearer sk-...          (proxy virtual key — must NOT reach Anthropic)
```

- `proxy/auth/user_api_key_auth.py` → `get_api_key()` checks `SpecialHeaders.custom_litellm_api_key` (`proxy/_types.py:4229`) before `Authorization`, so the proxy key wins for authentication. This is why the client must use `x-litellm-api-key`; if the proxy key were placed in `Authorization`, `clean_headers` would strip the OAuth token and the request would silently bill the platform key instead.
- `proxy/litellm_pre_call_utils.py:911` → `clean_headers` keeps the `Authorization` header **because** litellm did not authenticate with it (it is an `sk-ant-oat*` token per `types/llms/anthropic.py:751`).
- `proxy/litellm_pre_call_utils.py:3151` → `add_provider_specific_headers_to_request` (called unconditionally at `:1863`) scopes it to the anthropic provider only.
- `llms/anthropic/common_utils.py:92` → `optionally_handle_anthropic_oauth` forwards it as `Authorization: Bearer <token>` and adds `anthropic-beta: oauth-2025-04-20` plus `anthropic-dangerous-direct-browser-access: true`.

`general_settings.forward_client_headers_to_llm_api` is deliberately **not** set: the OAuth path above is unconditional, and enabling it would forward every client `x-*` header upstream. The subscription token is never persisted — litellm's observability copies of the headers go through `redact_credential_headers` (`proxy/litellm_pre_call_utils.py`), so it does not appear in spend logs, S3 callbacks, or pod logs.

## Credential: no `api_key` on the groups (fail-open)

The groups carry no `api_key`, so when the client supplies an `sk-ant-oat*` token that token pays. With **no** client OAuth token, litellm falls back to the environment (`AnthropicModelInfo.get_api_key` = `api_key or get_secret_str("ANTHROPIC_API_KEY")`, `llms/anthropic/common_utils.py:805-808`), i.e. the pod's platform key — so API-key clients keep working on these names, and a misconfigured Claude Code would be billed to the API key rather than failing loudly.

To fail closed instead, add a truthy non-OAuth literal to both groups (`api_key: "oauth-only"`). The OAuth branch still overrides it; with no OAuth token Anthropic answers 401 (`invalid x-api-key`) instead of the platform key paying.

## Client wiring (dotfiles)

`dotfiles/nixos/shared-cli-configuration.nix` — the `claude` wrapper (NixOS module, host-gated to `office`/`arch`):

```sh
export ANTHROPIC_BASE_URL="https://llm.2143.me"
export ANTHROPIC_CUSTOM_HEADERS="x-litellm-api-key: Bearer $LITELLM_EDITOR_KEY"
unset ANTHROPIC_API_KEY
```

- The keys come from `/run/agenix/llm-runtime-keys` (`LITELLM_EDITOR_KEY`), sourced before the `unset`.
- `unset ANTHROPIC_API_KEY` is required: an inherited platform key takes precedence over the subscription login inside Claude Code.
- `ANTHROPIC_AUTH_TOKEN` must never be set — it would occupy `Authorization` and clobber the subscription token.
- `ANTHROPIC_MODEL` is deliberately not set, so Claude Code's own model picker (and its `[1m]` suffix) keeps working.

Apply with `sudo nixos-rebuild switch --flake ~/repos/dotfiles#office`. A new shell is needed afterwards.

### Login (and when to re-login)

With `ANTHROPIC_API_KEY` unset, run `claude` and choose **"Claude account with subscription"**, then authorize in the browser. The credential lives in `~/.claude/.credentials.json` and is refreshed by the client — litellm has no Anthropic subscription refresher (unlike its `chatgpt/` provider, which has `authenticator.py` and a token PVC). Nothing on the proxy side depends on the token's lifetime; re-run the login if auth fails.

## Not wired: third-party clients

`omp` and any other non-Claude-Code agent deliberately stay on the API-key route (`anthropic/<slug>`). Anthropic restricts consumer-plan OAuth tokens to its own clients — the compliance page prohibits routing Free/Pro/Max credentials "on behalf of their users" and collecting/intermediating Claude.ai session tokens, while explicitly allowing an end user to sign in to the **unmodified** Claude Code binary with their own subscription. Pointing a different client at these groups is the prohibited shape, and Anthropic enforces it server-side.

## Cost mapping caveat

The pinned image (`ghcr.io/berriai/litellm:v1.100.1`) has no cost entry for slugs newer than its static map, which tops out around `claude-opus-5`, `claude-opus-4-8`, `claude-sonnet-5` (Claude Code 2.1.280 also offers `claude-opus-5-5`). Routing is unaffected — the Anthropic path never consults `supports_native_streaming` — but spend for such a slug is logged with unknown/zero cost. Treat subscription-route spend as token counts until the image is bumped (a separate change: it forces a Prisma migration).

## Verification (2026-09-23)

```sh
# 1. Deploy landed: ArgoCD Synced/Healthy at the new revision, both replicas replaced
kubectl -n argocd get app llm-proxy -o jsonpath='{.status.sync.status} {.status.health.status} {.status.sync.revision}'
kubectl -n default get pods -l app=litellm
```

```sh
# 2. The client's OAuth token — not the platform key — reaches Anthropic.
#    A throwaway sk-ant-oat token proves it: a 200 here would mean the platform key paid.
curl -sS -X POST https://llm.2143.me/v1/messages \
  -H "x-litellm-api-key: Bearer $LITELLM_EDITOR_KEY" \
  -H "Authorization: Bearer sk-ant-oat-DEADBEEF" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-opus-5[1m]","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}'
# observed: HTTP 401, Anthropic "OAuth access token is invalid" (both `claude-opus-5[1m]` and `claude-opus-5`)
```

```sh
# 3. Suffix stripping, visible in Anthropic's own error text: a bogus slug makes Anthropic
#    echo the model name it received. Both patterns must report the name WITHOUT `[1m]`.
#    (Uses the platform-key path, which 404s — no spend.)
# observed: `claude-nonexistent-probe[1m]` and `claude-nonexistent-probe` both →
#          404 `not_found_error: model: claude-nonexistent-probe`
```

A successful call reports the **requested** model name in litellm's response `model` field, so a 200 does not reveal the upstream id — use the bogus-slug probe above when you need to confirm the substituted name.

Housekeeping note: during the ConfigMap rollout the old replicas serve the old config, so `claude-*` requests load-balanced to them fail with `400 ... no healthy deployments` until the second pod is replaced. That is transient (a couple of minutes) and not a config error.
