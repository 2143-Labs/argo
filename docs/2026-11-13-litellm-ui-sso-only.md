# llm-proxy: the Admin UI is SSO-only (env-credential login disabled)

Date: 2026-11-13
Commit: `0a4c5ac` (llm-proxy: disable env-credential admin UI login).

## What the proxy was doing

LiteLLM enables environment-credential UI login by default, and the password it
checks is `UI_PASSWORD` when set, otherwise the master key — the username
defaults to `admin` (`litellm/proxy/auth/login_utils.py`, `get_ui_credentials`).
This proxy sets neither variable, so `admin` + `LITELLM_MASTER_KEY` signed in to
the Admin UI.

That is not a limited UI session. A successful env-credential login is forced to
`user_role = PROXY_ADMIN`, gets `PROXY_ADMIN_ID` written to `proxy_admin`, and
mints a UI session key (`authenticate_user`, same file). And proxy admin reaches
more than the dashboard: with `litellm_settings.cold_storage_custom_logger: s3_v2`
the `/spend/logs/ui/{request_id}` page downloads the archived payload from S3, so
proxy-admin access reads every archived request and response body. The master key
is not treated as admin-only in practice either — `dotfiles`' `veo.fish` and
`codex-quota.fish` use `$LITELLM_MASTER_KEY` as a client key, so the same secret
sat on client machines.

LiteLLM reports the condition as its critical `env_credential_login` deployment
warning; the UI banner text is generated from that warning id
(`litellm/proxy/health_endpoints/deployment_warning_endpoints.py`).

## Decision

`workloads/llm-proxy/configmap.yaml`, `general_settings`:

```yaml
disable_env_credential_login: true
```

Why it costs nothing here:

- SSO is fully configured. All five `GENERIC_*` keys are present in the OpenBao
  object behind `ExternalSecret/litellm-secrets`, so
  `is_sso_provider_fully_configured()` is true.
- Every `proxy_admin` in the database is SSO-only (no password), and the UI
  already redirects to SSO (`AUTO_REDIRECT_UI_LOGIN_TO_SSO=true`).
- The API path is untouched: `user_api_key_auth` never consults this flag, so
  scripts and clients keep authenticating with the master key.
- There is no lockout: an admin who loses the UI can still administer over the
  API with the master key, and unsetting the flag plus a restart restores env
  login.

`AUTO_REDIRECT_UI_LOGIN_TO_SSO` was deliberately not counted as protection: it
only sets `auto_redirect_to_sso` in `/.well-known/litellm-ui-config`, which is a
client-side redirect. `POST /login` still accepted the env credentials.

## Verified 2026-11-13 (closet cluster, `default/litellm`, both replicas)

| check | before | after |
|---|---|---|
| `GET /health/deployment_warnings` | `env_credential_login`, critical | 200, `warnings: []` |
| `GET /v1/models` with master key | 200 | 200, 446 models |
| `POST /login` as `admin` + master key | 200 + proxy-admin session | 401 `invalid_credentials` |
| `GET /v1/models` with a bogus key | 401 | 401 |

`/.well-known/litellm-ui-config` still reports `sso_configured: true`,
`auto_redirect_to_sso: true`, `admin_ui_disabled: false`, so the UI has a working
sign-in path. The 401 body is the generic "Invalid credentials" message, which
is what `is_env_credential_login_enabled() == False` selects; it does not reveal
whether the username exists.

## Consequences

- The UI now has exactly one sign-in method: SSO. No database user has a
  password, so there is no password break-glass path. Break-glass is the master
  key over the API, intentionally, and that is worth keeping in mind before
  adding SSO-disabling settings such as `disable_password_login_when_sso_enabled`.
- Do not re-enable env login to make a UI sign-in work. Use SSO, or set a
  password on an admin user and leave the flag in place.

## Not done

- The `argo-nonprod` and `argo-vpn-endpoints` checkouts are other branches of
  this repo (`nonprod/bigp`, `vpn-endpoints-tailnet-names`) with the identical
  three-key `general_settings`. Nothing references or deploys them today; if one
  is ever used for a litellm deployment, carry this flag over.
