# DeepSeek refuses thinking together with a forced tool choice

Date: 2026-11-15
Commits: `36bf59a` (proxy guard — PR #134), `c1f9f0f` (guard log line — PR #136).

`400 Thinking mode does not support this tool_choice` was failing every background-job widget author
OMP produced, then falling over to Opus. The rule is the provider's, not our configuration, and the
fix is a pre-call hook that rewrites the one request shape that trips it. Keys, ordering and the labs
cordon: [2026-11-11-litellm-deepseek-keys.md](2026-11-11-litellm-deepseek-keys.md). Why this failure
cannot be seen in Grafana: [2026-11-13-litellm-metrics-and-alerts.md](2026-11-13-litellm-metrics-and-alerts.md).

## The rule

DeepSeek accepts only an omitted, `"auto"` or `"none"` `tool_choice` while thinking is active;
`"required"` and a named function return 400, `"any"` returns 422. Thinking is **on by default** at
effort `high`, so a caller that never mentions reasoning but sets a forced `tool_choice` is refused
without having opted into anything. No configuration keeps both: thinking and forcing are mutually
exclusive per request.

LiteLLM does not repair this. `map_openai_params` never inspects `tool_choice`, `drop_params: true`
is inert here (it is value-level, and `tool_choice` is a *supported* parameter — only the value is
illegal), and the three upstream PRs that would have handled it are unmerged.

For OMP the shape is its job-widget author: `tool_choice:
{"type":"function","function":{"name":"respond"}}` with `thinking: {"type":"enabled"}` in
`extraBody`. 1,761 of the 1,766 captured 400s between 2026-11-09 and 2026-11-15 were that request
(`~/.omp/logs/http-400-requests`, one file per failed 4xx, body included), each followed by
`Fallback: litellm/deepseek/deepseek-flash -> anthropic/claude-opus-5-5`.

## What the proxy does now

`deepseek_forced_tool_choice.py` — a ConfigMap key of its own, registered as
`deepseek_forced_tool_choice.proxy_handler_instance` in `litellm_settings.callbacks`
(`workloads/llm-proxy/configmap.yaml`). Its `CustomLogger.async_pre_call_hook` sets
`thinking: {"type":"disabled"}` when `model` starts with `deepseek/` or `deepseek-labs/` **and**
`tool_choice` is not `None`/`"auto"`/`"none"`. Everything else passes through untouched, so a plain
turn — the whole normal agent loop — is byte-identical to before. The forced call itself runs
without thinking, which is the only version of it DeepSeek will serve.

Verified against the pinned image `ghcr.io/berriai/litellm:v1.108.1`, in the pod:

| claim | anchor |
|---|---|
| the hook is called with `user_api_key_dict, cache, data, call_type` | `proxy/utils.py:3077-3085` |
| returning `None` keeps the in-place-mutated body (`dict` replaces it wholly — never return a partial) | `proxy/utils.py:2305-2320` |
| an explicit `thinking: {"type":"disabled"}` wins over `reasoning_effort`, which it pops alongside | `llms/deepseek/chat/transformation.py:47-57` |
| the `reasoning_content` repair only engages for `{"type":"enabled"}`, so it correctly does not run on the rewritten call | `llms/deepseek/chat/transformation.py:214-225, 314` |

Rejected alternatives: `additional_drop_params: ["tool_choice"]` cures the 400 by dropping the force,
which costs `/force`, sharpshooter extraction, `eval` structured output and the widget author their
guarantee; a deployment-level `thinking: disabled` removes thinking from all traffic; a client-side
dialect (OMP `thinkingFormat: zai`) covers one client and depends on per-request `thinking`
passthrough that could not be confirmed from this side.

## Two traps

### The logger that swallows INFO

The first version logged through `logging.getLogger("LiteLLM")` and produced no line at all. That
logger sits at WARNING (`resolve_log_level` with `set_verbose: false`), so `info()` never creates a
record — the hook worked, the observability did not. A dotted child, `LiteLLM.deepseek_guard` with
`setLevel(INFO)`, inherits the parent's handlers and carries its own level.

The level is not cosmetic. `LiteLLM`'s `LevelRoutingStreamHandler` sends records below WARNING to
stdout and WARNING+ to stderr, and the log collectors treat every stderr line as error severity — so
a routine rewrite logged at WARNING would be reported as an error. It is INFO, on stdout.

### Extend `CustomLogger`, not `CustomGuardrail`

`ProxyLogging.pre_call_hook` routes a `CustomGuardrail` down the unified-guardrail path
(`apply_guardrail`) instead of the event hook, so a guardrail subclass would silently stop running.
The hook is also selected by `vars(cls)` and by being different from the base implementation, which
is why the instance must be a real subclass override, not a bound attribute.

`tool_choice` may be a dict, so membership is tested against a **tuple**, never a set — dicts are
unhashable and a set would raise inside the request path.

## Verification, 2026-11-15

| check | result |
|---|---|
| `tool_choice: "required"` before the sync (old pods) | `400 ... Thinking mode does not support this tool_choice` |
| same request after the sync | `200`, `tool_calls: ["ping"]` |
| thinking on a plain prompt (no tools), before / after | 872 reasoning chars, 300 reasoning tokens — unchanged |
| `tools` + `tool_choice: "auto"` | `200`, no guard line (nothing rewritten) |
| Loki: error count 21:00–22:12Z | **30** |
| Loki: error count 22:13Z–now (first patched pod ready 22:12:38) | **0** |
| OMP captures | frozen at 1,780, newest `1794780761558` = 22:12:41Z, pre-patch |
| guard lines in Loki | `22:18:56 ... 'required'` (probe), `22:21:21` ×2 `{'type': 'function', 'function': {'name': 'respond'}}` (real widget author, both pods) |

The guard line reads:

```
22:18:56 - LiteLLM.deepseek_guard:INFO: deepseek_forced_tool_choice.py:43 - deepseek guard: thinking disabled for forced tool_choice='required' model=deepseek/deepseek-flash
```

## Known limits

- **Log-only signal.** The `prometheus_metrics_config` whitelist admits token, spend, provider-cache
  and balance families, so there is no request-outcome series to alert on: a regression shows up in
  Loki and in OMP's capture directory, not on the dashboard. A rewrite counter would cost one series
  per model group and make the breakage alertable.
- **A forced-tool turn loses thinking for that request.** That is the provider's constraint, not a
  choice this change made; requests without a forced `tool_choice` are untouched.
- **REMOVAL TRIGGER.** Delete the ConfigMap key and its `callbacks` entry once DeepSeek accepts
  forced tool choices in thinking mode, and re-read
  `llms/deepseek/chat/transformation.py` on every image bump — if a release stops honouring
  `{"type":"disabled"}`, forced calls go back to 400.
