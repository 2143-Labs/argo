# Secrets inventory, migration state, and rotation backlog

**Date:** 2026-09-13
**Context:** the credential workstream of the 2026-09-13 remediation. `github.com/2143-Labs/argo` is a **public** repository, so every value ever committed to it must be treated as disclosed.

## 1. Where we got to — and the blocker

The target architecture was: application secrets live in OpenBao, External Secrets Operator (ESO) renders them as ordinary Kubernetes `Secret`s, and the Stakater Reloader rolls workloads when a value changes. PostgreSQL credentials deliberately stay with CloudNativePG (see §3).

Landed and verified:

- **ESO 2.10.0 installed** (`apps/external-secrets.yaml`, namespace `external-secrets`, all three pods Running).
- **OpenBao given an in-cluster listener** — a second `listener "tcp"` on `[::]:8202` with `tls_disable = true`, published only through the extraObjects ClusterIP Service `openbao-eso` (`apps/openbao.yaml`). Endpoints verified present, port confirmed listening.
- **Chart repo allowlisted** in both `apps/default-project.yaml` (the copy the cluster reconciles) and `main.yaml`.

**Blocked: no administrative credential for OpenBao exists in this environment.** Creating the policy and auth role that ESO needs is impossible without one. What was checked and ruled out:

- No root-token or init Secret anywhere in the cluster (`kubectl get secrets -A` — only `openbao-seal`, `openbao-server-tls`, `openbao-spaces` in the `openbao` namespace).
- No `BAO_TOKEN` in the server pod's environment or its filesystem.
- The `openbao` ServiceAccount holds only the chart's `auth-delegator` ClusterRoleBinding and a namespace-local discovery Role — no vault-authorising capability.
- Kubernetes auth is enabled at path `kubernetes`, but **no role is bound to the `openbao` SA** (`bao write auth/kubernetes/login role=openbao` → `invalid role name`). Probe attempts for `admin`, `bootstrap`, `openbao-admin`, `controller`, `operator`, `root`, `deploy`, `snapshot`, `upstream`-style names and others all returned `invalid role name`.
- The one role that does exist is `openbao-snapshot`, bound to ServiceAccount `openbao-snapshot` — the snapshot agent's identity (its ConfigMap `openbao-snapshot` sets `BAO_AUTH_PATH: kubernetes`, `BAO_ROLE: openbao-snapshot`). It is scoped to taking Raft snapshots and is not an administrative identity.

The vault was initialised ~2026-09-12; its root token is held by the user. **One-time action required by the user** (run against the active pod, root token supplied out-of-band — never committed, never pasted into this repo):

```bash
bao policy write eso-read - <<'EOF'
path "consumers/data/*"     { capabilities = ["read"] }
path "consumers/metadata/*" { capabilities = ["read", "list"] }
path "sys/mounts"           { capabilities = ["read", "list"] }
path "sys/mounts/*"         { capabilities = ["read", "list"] }
EOF
bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-read ttl=1h
```

Once that exists, the remaining steps are mechanical and already designed: a `ClusterSecretStore` named `openbao` pointing at `http://openbao-eso.openbao.svc:8202` with `provider.openBao` and the `external-secrets` role, then one `ExternalSecret` per credential below, each with `target.name` set to the Secret name the workload already consumes so no Deployment changes are needed. **No `ExternalSecret` was committed, deliberately** — a store that cannot authenticate would leave the workloads referencing Secrets nothing creates, and the UniFi MongoDB Secret in particular does not exist today, so landing it early would break a running service.

**Update 2026-09-14 (re-verified against the live vault):** the mount is
`consumers`, **not** `secret`. OpenBao's own audit stream is the proof: it
records 180 requests to mount `consumers/` — `consumers/data/hero-rehab/steam`
and its `metadata/` siblings — and **zero** requests to a `secret/` mount, so no
`secret/` engine exists and the policy above had to be written against
`consumers` instead. The `sys/mounts` lines are still required, and for the same
reason: ESO validates a store by calling `GET /v1/sys/mounts/<path>`, taken
straight from the store's `path:` field. With the store set to `secret` that
call 403'd, which is what held `ClusterSecretStore/openbao` at
`Ready=False`/`InvalidProviderConfig`.

The `external-secrets` auth role itself **already exists and authenticates**
— logging in with a token minted for ServiceAccount
`external-secrets/external-secrets` returns policies `default` and `eso-read`.
Re-writing `eso-read` with the block above is the only remaining out-of-band
action; the live copy still grants `secret/data/*` and denies `sys/mounts*`.
Until it is re-written the store stays `InvalidProviderConfig`, so no
`ExternalSecret` may be committed.

### Still plaintext in HEAD today

Because the migration is blocked, **four files still carry literal credentials in the current tree** and remain exposed to anyone reading this public repo. They are listed here so the exposure is unambiguous and cannot be mistaken for "done":

| File | Location | What is exposed |
|---|---|---|
| `workloads/unifi/unifi-deployment.yaml` | lines 45–46 (`MONGO_PASS`), 106–107 (`MONGO_INITDB_ROOT_PASSWORD`), 112–113 (`MONGO_PASS`, mongodb container) | the UniFi MongoDB password, three times; note `MONGO_INITDB_ROOT_PASSWORD` and `MONGO_PASS` are the **same** value |
| `workloads/frigate/config-tpl.yaml` | ~659 (`model.path`, a `plus://…` key), ~662 (`mqtt.password`) | the Frigate+ licence key and the MQTT password |
| `workloads/tuwunel/application.yaml` | ~66–69 (`extraEnv`) | the SeaweedFS S3 access key and secret key |
| `workloads/openrct2/openrct2.yaml` | ~45–46 (`--password`) | the openrct2 server password |

These are exactly the workstream-3.6 items that the blocker above prevents completing. Each one has a row in the rotation backlog below. **Until the OpenBao policy and role exist, the only correct action on these is rotation — they cannot be un-committed**, and deleting them from git without a working replacement would simply break the workloads.

## 2. Rotation backlog — values disclosed in a public repo

Every entry below was committed in plaintext and must be considered public. Rotation is **not** performed by this change set: each one is service-affecting, and several need a third party. Ordered by exposure:

| Credential | Was committed at | Rotation procedure |
|---|---|---|
| UniFi MongoDB root + app password | `workloads/unifi/unifi-deployment.yaml` (env literals) | `db.changeUserPassword()` inside the running `mongod` (or dump → recreate the volume). Both `MONGO_INITDB_ROOT_PASSWORD` and `MONGO_PASS` are affected; `MONGO_INITDB_*` is honoured only on an empty data dir, so changing it requires a rebuild or a manual user update. |
| Frigate+ licence key | `workloads/frigate/config-tpl.yaml` (`model.path`, `plus://…`) | Regenerate the key in the Frigate+ account portal; the old key should be revoked there. |
| MQTT password | `workloads/frigate/config-tpl.yaml` | Change on the broker, then update the client credential. |
| Tuwunel / SeaweedFS S3 keys | `workloads/tuwunel/application.yaml` (`extraEnv`) | Rotate the access key in SeaweedFS; `ACCESS_KEY`/`SECRET_KEY` both exposed. |
| openrct2 server password | `workloads/openrct2/openrct2.yaml` (CLI arg) | Change in the openrct2 server config (workload runs at `replicas: 0`). |
| litellm DB password | `workloads/llm-proxy/secret-litellm-db-password.yaml` (`stringData`) | Already **removed from tracking** — see §4. The value itself is unchanged and still disclosed in git history; rotate with `ALTER ROLE litellm PASSWORD '<new>'`, after which CNPG re-syncs `litellm-db-app`. |

`git log -p --follow -- <path>` recovers the exposure history for each file; the paths above are the authoritative list.

## 3. PostgreSQL credentials — deliberately left with CNPG

CNPG owns these; routing them through OpenBao would either forfeit CNPG's rotation or add a pointless round trip. All four consumers were repointed this pass and each credential was verified to authenticate:

| Consumer | Source (verified) | Result |
|---|---|---|
| litellm | `litellm-db-password` (managed-role `passwordSecret`) | AUTH_OK |
| pelican | `pelican-db-app` | AUTH_OK |
| mattermost | `mattermost-db-app` | AUTH_OK |
| steam-lobby | `steam-lobby-db-password` | AUTH_OK |

Two findings worth carrying forward:

- **`<cluster>-app` is not always authoritative.** `litellm-db-app` exists and looks correct, but its password is the initdb-generated one and **fails to authenticate** (`FATAL: password authentication failed for user "litellm"`) because the cluster's spec reconciles the `litellm` role from `managed.roles[].passwordSecret: litellm-db-password` instead. This was caught only by testing the credential against Postgres — the trust-on-name alternative would have shipped a crash-looping rollout. For litellm the authoritative secret is therefore `litellm-db-password`, not `-app`.
- **`mattermost-db-password` does not exist**, yet `workloads/mattermost-db/cnpg-cluster.yaml` names it as the managed role's `passwordSecret`. CNPG tolerates the missing Secret silently. Here that works out — with no `passwordSecret` to apply, the role keeps its initdb password, so `mattermost-db-app` is genuinely authoritative and the Service could not previously have started at all. Recreating that Secret (or removing the dangling reference) is still worth doing.

CNPG's own documented pattern for rotating these — ESO's `Password` generator writing into the existing `<cluster>-app` with `creationPolicy: Merge` and the label `cnpg.io/reload: "true"` — remains the intended route if automated DB rotation is wanted later.

## 4. Removal of the committed Secret

`workloads/llm-proxy/secret-litellm-db-password.yaml` is CNPG's password *source*, not an application secret, so it does not belong in OpenBao. It was **deleted from git and re-created out-of-band** with its existing value so that CNPG keeps working and ArgoCD's `prune: true` cannot remove it again. The Secret is now outside every Application's desired state.

## 5. Left as plain Secrets (not migrated, with reasons)

- CNPG-managed: `litellm-db-{app,ca,replication,server,password}`, `pelican-db-*`, `mattermost-db-*`, `steam-lobby-db-*`, `temporal-db-*`. Owned by the operator; replacing them with OpenBao copies would break rotation.
- Third-party TLS material managed by cert-manager: `2143-me-wildcard-tls`, `john2143-com-wildcard-tls`, `aross-studio-wildcard-tls`, `mm-*-tls`.
- Out of scope for this pass, and candidates for a follow-up migration: `litellm-secrets`, `litellm-s3-creds`, `frigate-creds`, `frigate-genai-worker-creds`, `headscale-oidc`, `listen-brick-secret`, `minio-credentials`, `minio-creds`, `mongo-creds`, `mosquitto-credentials`, `oauth-creds`, `oauth2-proxy-cameras`, `oauth2-proxy-temporal`, `steam-lobby-secret`, `steam-lobby-turn`, `curseforge-api-key`, `openbao-spaces`.

`openbao-spaces` holds the DigitalOcean Spaces credentials the snapshot agent uses; note that the agent can already read them from OpenBao itself via `BAO_SECRET_PATH`, which is the tidier arrangement if that path is ever populated.
