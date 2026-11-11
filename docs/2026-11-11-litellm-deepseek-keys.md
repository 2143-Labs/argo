# DeepSeek on llm-proxy: ordered primary/backup keys, and the labs cordon

Date: 2026-11-11
Commits: `2232e49` (llm-proxy: order deepseek primary before its backup, cordon labs key — PR #104).

> **Correction 2026-11-11 (later the same day):** `DEEPSEEK_API_KEY` was split into `DEEPSEEK_API_KEY1` + `DEEPSEEK_API_KEY2`, so the ordered pair below became a 50/50 pool with the backup at `weight: 0`. Every statement about `order: 1` / `order: 2` in this record is superseded by [Two balanced keys](#two-balanced-keys-superseding-the-ordered-pair).

## What was added

`deepseek/*` used to be a single deployment on `DEEPSEEK_API_KEY`. It is now an ordered pair plus a second group for the org account, all in `workloads/llm-proxy/configmap.yaml`:

| group | key | `order` |
|---|---|---|
| `deepseek/*` | `DEEPSEEK_API_KEY` | 1 |
| `deepseek/*` | `DEEPSEEK_API_KEY_BACKUP1` | 2 |
| `deepseek-labs/*` | `DEEPSEEK_API_KEY_LABS` | — |

All three keys live in the OpenBao object behind `ExternalSecret/litellm-secrets` (`workloads/secrets/default-litellm-secrets.yaml`), which `envFrom`s every key in that object into the pod.

## `order`, not a second same-order entry

Two deployments with the same `model_name` are a load-balancing pool, and `simple-shuffle` (the default strategy) re-picks at random on **every retry**. With one dead key that means a single request can hit the same dead key twice:

- unordered pair, primary answering 429: 3 of 20 calls failed (second run: 1 of 20)
- ordered pair, primary answering 402: 0 failures, 6/6 served by the backup

`order` is compared on healthy deployments only (`Router._common_checks_available_deployment` → `litellm/utils.py:get_order_filtered_deployments`), and a failed order-1 attempt escalates to order-2 inside the same request. So the primary serves everything while it is up, and the backup answers only once the primary is in cooldown or gone. Cooldown covers 401/402/404/408/429 and 5xx (`litellm/router_utils/cooldown_handlers.py:_is_cooldown_required`); DeepSeek's drained-balance answer is a 402.

`cooldown_time` is left at the router default (5s on this image). It is router-wide, not per-group, so raising it would also bench single-deployment groups (gemini, anthropic, …) for that long. The cost of the default is one failed attempt per 5s window while the primary is dead.

Two other knobs, deliberately **not** set:

- `enable_weighted_failover: true` makes a same-order group re-pick among the *other* deployments after a failure (async, `simple-shuffle` only). It is the right tool for a genuine load-balanced pair, and it also produced 6/6 on the backup, but an ordered pair does not need it.
- `cooldown_time` / `allowed_fails` per deployment are read from `model_info` only on the deployment-policy path, i.e. they require `allowed_fails` or `allowed_fails_policy` to be set as well (`_get_deployment_cooldown_policy`). `cooldown_time` alone in `model_info` does nothing.

## The labs cordon

`deepseek-labs/*` maps to the same `deepseek/*` provider models on the org key. Org callers opt in by model name, so their spend, budgets and failover decisions never mix with the home pair. `deepseek-labs/*` is the longer pattern and wins `PatternUtils.sorted_patterns`, and `deepseek/*` compiles to `deepseek/(.*)` so it cannot capture `deepseek-labs/...`.

This is a **name-based** cordon, not an authorization boundary: any valid proxy key can still ask for either group. Separating *who* may spend which account needs virtual keys/teams plus `model_info.access_groups` — card #348 (task 2189).

## Session affinity: what works on wildcard groups (for later)

Load balancing *across sessions* instead of across requests is available and was measured, in case the pair ever becomes two same-order home keys:

- `router_settings.optional_pre_call_checks: ["session_affinity"]` pins a session id (`x-litellm-session-id`, `x-claude-code-session-id`, or `metadata.session_id`) to one deployment for `deployment_affinity_ttl_seconds` (default 3600). Measured on `deepseek/*`: 6 sessions → 3 pinned to each key, stable for every turn. `deployment_affinity` pins by caller (virtual key hash) instead.
- Per-group `model_group_affinity_config` **silently does not work for wildcard groups** on v1.108.1: the read path resolves the flags with the requested model name (`deepseek/deepseek-v4-flash`) while the write path uses the deployment's `model_name` (`deepseek/*`), so the pin is written under a key that is never read. It works for exact-named groups. Use the global `optional_pre_call_checks` list.

Pins and cooldowns are shared across both replicas because `litellm_settings.cache_params` points the proxy at `litellm-redis` and the proxy hands that cache to the Router (`proxy/proxy_server.py` → `router.update_redis_cache`).

## Verification

Against the image the proxy pins (`ghcr.io/berriai/litellm:v1.108.1`), with `model_list` read straight out of the edited ConfigMap and the provider pointed at a mock DeepSeek upstream that answers 402 for the home primary:

| check | result |
|---|---|
| `deepseek/deepseek-v4-flash`, both keys healthy | 50/50 selections on `DEEPSEEK_API_KEY` |
| `deepseek/deepseek-reasoner`, both keys healthy | 20/20 on `DEEPSEEK_API_KEY` |
| primary in cooldown | 20/20 on `DEEPSEEK_API_KEY_BACKUP1` |
| `deepseek-labs/deepseek-v4-flash` | 50/50 on `DEEPSEEK_API_KEY_LABS`, model substituted to `deepseek/deepseek-v4-flash` |
| end-to-end `acompletion`, primary 402ing | 8/8 finished on the backup, no client-visible error |
| end-to-end `acompletion`, `deepseek-labs/*` | 4/4 on the labs key |

Rollout: ArgoCD `llm-proxy` synced to `2232e49`, then the reloader rolled both replicas.

## Two balanced keys (superseding the ordered pair)

The same day, the home account grew a second key: `DEEPSEEK_API_KEY` was replaced by `DEEPSEEK_API_KEY1` + `DEEPSEEK_API_KEY2`, and the goal changed from "primary, then backup" to "spend both evenly, keep the backup".

| group | key | `weight` |
|---|---|---|
| `deepseek/*` | `DEEPSEEK_API_KEY1` | 1 |
| `deepseek/*` | `DEEPSEEK_API_KEY2` | 1 |
| `deepseek/*` | `DEEPSEEK_API_KEY_BACKUP1` | 0 |

`weight` drives `simple-shuffle`, and `weight: 0` is never picked by the shuffle, so the backup is reachable only through `router_settings.enable_weighted_failover: true`, which re-picks among the other deployments in the same group after a failure.

### Why the order tiers had to go

`order` escalation fires on the first failure *inside* a tier, not after the tier is exhausted. With one of the two balanced keys answering 402 and its sibling healthy, the dead key's entire share landed on the **backup** (11 of 30 calls) instead of on the sibling (19 of 30). Weighted failover keeps the sibling first and reaches the backup only when no weight-bearing key is left.

`enable_weighted_failover` is load-bearing rather than tuning: without it the generic retry re-picks at random, so a dead key failed 8 of 30 calls and the both-dead case failed 30/30 without ever trying the backup.

### Measured

Against `ghcr.io/berriai/litellm:v1.108.1`, `model_list` and `router_settings` read straight out of the ConfigMap, mock upstream 402ing named keys:

| state | result |
|---|---|
| both keys healthy, 30 calls | 14 `KEY1` / 16 `KEY2`, zero backup |
| both keys healthy, 200 selections | 103 `KEY1` / 97 `KEY2`, zero backup |
| `KEY1` 402ing | 30/30 `KEY2`, no errors |
| `KEY2` 402ing | 30/30 `KEY1`, no errors |
| both 402ing | 30/30 `BACKUP1`, no requests failed |
| `deepseek-labs/*` | 5/5 labs key |

Cooldown semantics are unchanged (401/402/404/408/429/5xx, 5s default, shared across replicas through `litellm-redis`). The labs group still has a single deployment, so it has neither weights nor failover.
