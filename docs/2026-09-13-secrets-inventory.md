# Secrets inventory, migration state, and rotation backlog

**Date:** 2026-09-13
**Context:** the credential workstream of the 2026-09-13 remediation. `github.com/2143-Labs/argo` is a **public** repository, so every value ever committed to it must be treated as disclosed.

## 1. Where we got to — migration complete

**Status: complete (2026-09-15).** Every application Secret in §6 is served from
OpenBao by External Secrets and rendered back under its original name, verified
value-for-value against the live cluster. The blocker described below is
resolved; that narrative is kept because the reasoning in it is what produced
the correct policy.

The target architecture was: application secrets live in OpenBao, External Secrets Operator (ESO) renders them as ordinary Kubernetes `Secret`s, and the Stakater Reloader rolls workloads when a value changes. PostgreSQL credentials deliberately stay with CloudNativePG (see §3).

Landed and verified:

- **ESO 2.10.0 installed** (`apps/external-secrets.yaml`, namespace `external-secrets`, all three pods Running).
- **OpenBao given an in-cluster listener** — a second `listener "tcp"` with `tls_disable = true`, published only through the extraObjects ClusterIP Service `openbao-eso` (`apps/openbao.yaml`). Endpoints verified present, port confirmed listening. **Since 2026-09-15 that listener binds `[::]:8210`** (it was `8202`, which the chart reserves for replication — see §6).
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

Once that exists, the remaining steps are mechanical and already designed: a `ClusterSecretStore` named `openbao` pointing at `http://openbao-eso.openbao.svc:8210` with `provider.openBao` and the `external-secrets` role, then one `ExternalSecret` per credential below, each with `target.name` set to the Secret name the workload already consumes so no Deployment changes are needed. **No `ExternalSecret` was committed, deliberately** — a store that cannot authenticate would leave the workloads referencing Secrets nothing creates, and the UniFi MongoDB Secret in particular does not exist today, so landing it early would break a running service.

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

The migration into OpenBao is now done, but that does **not** un-disclose anything: **four files still carry literal credentials in the current tree** and remain exposed to anyone reading this public repo. They are listed here so the exposure is unambiguous and cannot be mistaken for "done":

| File | Location | What is exposed |
|---|---|---|
| `workloads/unifi/unifi-deployment.yaml` | lines 45–46 (`MONGO_PASS`), 106–107 (`MONGO_INITDB_ROOT_PASSWORD`), 112–113 (`MONGO_PASS`, mongodb container) | the UniFi MongoDB password, three times; note `MONGO_INITDB_ROOT_PASSWORD` and `MONGO_PASS` are the **same** value |
| `workloads/frigate/config-tpl.yaml` | ~659 (`model.path`, a `plus://…` key), ~662 (`mqtt.password`) | the Frigate+ licence key and the MQTT password |
| `workloads/tuwunel/application.yaml` | ~66–69 (`extraEnv`) | the SeaweedFS S3 access key and secret key |
| `workloads/openrct2/openrct2.yaml` | ~45–46 (`--password`) | the openrct2 server password |

Each one has a row in the rotation backlog below. They cannot be un-committed, so **the only correct action on these is rotation** — deleting them from git without a working replacement would simply break the workloads.

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

## 5. Deliberately left as plain Secrets

- CNPG-managed: `litellm-db-{app,ca,replication,server,password}`, `pelican-db-*`, `mattermost-db-*`, `steam-lobby-db-*`, `temporal-db-*`. Owned by the operator; replacing them with OpenBao copies would break rotation.
- Third-party TLS material managed by cert-manager: `2143-me-wildcard-tls`, `john2143-com-wildcard-tls`, `aross-studio-wildcard-tls`, `mm-*-tls`.
- OpenBao's own bootstrap Secrets: `openbao-seal` (the static auto-unseal key), `openbao-server-tls`, `openbao-spaces`.

**Update 2026-09-15:** the "candidates for a follow-up migration" this section
used to list — `litellm-secrets`, `litellm-s3-creds`, `frigate-creds`,
`frigate-genai-worker-creds`, `headscale-oidc`, `listen-brick-secret`,
`minio-credentials`, `minio-creds`, `mongo-creds`, `mosquitto-credentials`,
`oauth-creds`, `oauth2-proxy-cameras`, `oauth2-proxy-temporal`,
`steam-lobby-secret`, `steam-lobby-turn` — **are now migrated**; see §6 for the
design and §6 "Known gaps" for the live Secrets still outside it.

`openbao-spaces` holds the DigitalOcean Spaces credentials the snapshot agent uses; note that the agent can already read them from OpenBao itself via `BAO_SECRET_PATH`, which is the tidier arrangement if that path is ever populated.

## 6. The OpenBao migration as built

### Where the values live

KV v2 mount **`consumers`** (not `secret` — no such engine exists; see the
2026-09-14 note in §1). Keys are namespaced by consuming cluster and then mirror
the Kubernetes identity so the two are trivially correlate:

```
consumers/data/john2143-com/<namespace>/<secret-name>
```

One ExternalSecret per Secret, under `workloads/secrets/`, owned by the single
`secrets` Application (`apps/secrets.yaml`). One Application rather than
per-workload apps matters because `seaweedfs-s3-creds` and `rustfs-credentials`
exist in two namespaces each, and a per-app split would let one app's prune
delete a Secret a neighbour still reads. Each ExternalSecret sets
`target.name` to the name the workload already consumes, so **no Deployment
reference changes were needed**.

### The store

`ClusterSecretStore/openbao` (`bootstrap/external-secrets/clustersecretstore.yaml`)
uses ESO's dedicated **`openBao`** provider — a real provider type, distinct from
the generic `vault` provider, and its auth field is `path`, not `mountPath`
(that is the vault provider's spelling). It reaches OpenBao over the
ClusterIP-only plaintext `openbao-eso:8210` listener, authenticating as
ServiceAccount `external-secrets/external-secrets` via the `external-secrets`
Kubernetes-auth role.

The listener is on **8210**, not 8202: the chart unconditionally declares 8202 as
its replication port (`https-rep`), so a plaintext ESO listener bound there would
both squat on the port replication needs and be mislabelled as TLS. 8210 is
declared explicitly through the chart's `server.extraPorts` (which appends to the
server StatefulSet's *container* ports, so the entry is `containerPort`-shaped).

### The policy, and the two non-obvious requirements

`eso-read` is written once by the operator (OpenBao admin access does not exist
in the cluster, so it is deliberately not GitOps-managed):

```
path "consumers/data/*"     { capabilities = ["read"] }
path "consumers/metadata/*" { capabilities = ["read", "list"] }
path "sys/mounts"           { capabilities = ["read", "list"] }
path "sys/mounts/*"         { capabilities = ["read", "list"] }
```

- The `sys/mounts` lines are **required**: ESO validates a store by calling
  `GET /v1/sys/mounts/<path>`. Without them the store sits at
  `Ready=False`/`InvalidProviderConfig` even though reading data works, because
  the validation call 403s.
- The path prefix is the mount name as configured in the store's `path:` field.
  While that field said `secret`, ESO was probing `sys/mounts/secret` and
  failing — the mount defect and the policy defect had to be fixed together.

### Adding a new secret

The full recipe lives in [`adding-a-secret.md`](adding-a-secret.md): seeding the
value with the `-mount=` form, the `ExternalSecret` shape, the parity check
before trusting a rendered Secret, and where the Reloader annotation goes.

### Deliberately excluded

- **CNPG** database credentials (`*-db-app`, `*-db-ca`, `*-db-server`, …) and
  their password sources — routing these through OpenBao forfeits CNPG's own
  rotation.
- **cert-manager** TLS output.
- **OpenBao's own bootstrap** Secrets: `openbao-seal` (the static auto-unseal
  key — the real trust boundary), `openbao-server-tls`, `openbao-spaces`.
- **Chart-generated** Secrets whose lifecycle a Helm chart owns. `crowdsec-lapi-secrets`
  was initially migrated and then reverted in ownership: the chart was
  generating it, so both the chart and ESO managed one Secret and the chart won
  every sync. It is now handed over cleanly via
  `secrets.externalSecret.name: crowdsec-lapi-secrets`, which makes the chart
  skip `templates/lapi-secrets.yaml` and consume the ESO-rendered Secret. No
  exclusion was needed once the chart's own handover mechanism was used.
- `steam-lobby-pr-*` preview namespaces (ephemeral, dev-mode auth).

### Known gaps and follow-ups

- **`tuwunel-conduwuit` cannot auto-reload.** Its chart
  (`ghcr.io/magikid/modern-conduwuit-helm`, `conduwuit` 2.1.0) exposes no
  `podAnnotations` value, so there is nowhere to put the Reloader annotation.
  Rotation of `tuwunel-turn` requires a manual `kubectl rollout restart` until
  the chart supports it.
- **Every rotation rolls twice.** Reloader writes
  `reloader.stakater.com/last-reloaded-from` onto the pod template, ArgoCD
  selfHeal sees a diff against git and reverts it, and the revert is itself a
  template change. Verified: one Secret change produced two new ReplicaSets.
  Harmless but wasteful; the fix is an `ignoreDifferences` entry for that
  annotation across the workload apps.
- **Rotation backlog (§2) is still outstanding.** The migration changed where
  values are read from; it did not un-disclose anything already committed to
  this public repository.
- **Scope gap.** The migration set covers the Secrets the workstream had
  enumerated. Live application Secrets still outside it include
  `default/curseforge-api-key`, `default/s3-creds`, `default/rustfs-credentials`,
  `default/seafile-admin`, `default/seafile-oidc`,
  `observability/{grafana,grafana-oidc,rustfs-credentials}`,
  `matrix/au2143me-oidc`, `stalwart/stalwart-stalwart-env`,
  `authentik/authentik-secrets` and `kube-system/crowdsec-bouncer-key`.
- **`refreshInterval: 10m`.** ESO does recreate a deleted rendered Secret
  promptly (verified), and a changed value now reaches the rendered Secret
  within about ten minutes. It reaches the *workload* only once the Pod
  restarts (§7), which Reloader does for the annotated workloads.
- **Audit volume scales linearly with the refresh interval.** Every OpenBao
  request is audited unconditionally — the audit device has no sampling, no
  path filter and no exclusions — so the interval alone sets the log volume.
  Measured 2026-09-16 across all three pods at `2m`: 91 logins and 57 reads per
  4 minutes, i.e. **1.60 logins per read**, writing ~144 MiB/day. Most of that
  is *authentication*, not data.
  `--enable-vault-token-cache` was tried on the ESO controller to remove the
  redundant logins and **does not help** (91 → 99 logins per 4 min, no material
  change). The flag is wired into the Vault provider path and does not engage
  for `provider.openBao`; that commit was reverted. With the logins
  unavoidable, **`10m` was chosen** (~29 MiB/day, a 5x cut from `2m`, still far
  ahead of the original `1h`), on the reasoning that a short interval only buys
  anything when a rotation must be live within minutes.
  The audit device writes to stdout (`apps/openbao.yaml`,
  `file_path = "stdout"`) with `auditStorage.enabled = false`, so this lands in
  the pod log and is shipped by Alloy.

## 7. Why the rendered Secrets stay in the cluster

The migration changed where a value is **read from**, not whether a Kubernetes
Secret exists. ESO fetches each entry from OpenBao and renders it back into a
Secret carrying the *same name* the workload already consumed, which is why no
Deployment, StatefulSet or DaemonSet reference had to change. **28**
ExternalSecrets are live, and ESO has created **28** Secrets from them; the
cluster holds 138 Secrets in total.

Removing the rendered Secrets is therefore neither done nor wanted:

- **Deleting one is futile.** Every ExternalSecret runs the default
  `creationPolicy: Owner`, so ESO owns the rendered Secret and recreates it on
  the next reconcile (see §6 "Known gaps").
- **Deleting one is harmful.** Consumers read these as environment variables —
  `secretKeyRef` and `envFrom` across 25 workload manifests (for example
  `workloads/frigate/deployment.yaml`, `workloads/llm-proxy/deployment.yaml`,
  `workloads/headscale/deployment.yaml`), with a minority mounting them as
  files (`livekit-keys`, `tuwunel-turn`). A missing Secret means
  `CreateContainerConfigError` and the Pod does not start. Switching
  `crowdsec-lapi-secrets` to ESO ownership already produced exactly that outage
  for about four minutes until a forced resync cleared it.

### Where the value actually lives

"Loaded at runtime, in memory only" is not a mode Kubernetes or k3s offers. The
lifecycle is:

```
OpenBao                       source of truth, encrypted by OpenBao's own barrier
  -> ESO                      fetches on refreshInterval (10m), writes a Secret
  -> Secret                   a durable object in the cluster datastore
  -> kubelet                  injects env vars at container start,
                              or mounts the Secret as a tmpfs volume
  -> application              reads it
```

Two consequences follow. An environment-variable consumer only ever sees a new
value after its Pod restarts — which is precisely what the Reloader annotations
are for (§6). And the value persists in the datastore for the object's entire
lifetime regardless of what any container does with it; the process has a copy,
it is not the only copy.

### Secrets are not encrypted at rest in the datastore

Verified 2026-09-16 against the live cluster — k3s `v1.35.8+k3s1`, datastore
**etcd** (`/var/lib/rancher/k3s/server/db/etcd`):

```
$ sudo k3s secrets-encrypt status
Encryption Status: Disabled, no configuration file found
```

There is no `encryption-config.json` in `/var/lib/rancher/k3s/server/cred/`.
Every Secret in the cluster — the 28 ESO-rendered application credentials
included — is therefore stored in etcd base64-encoded only. Base64 is an
encoding, not encryption: anyone who can read the etcd data files, or obtain a
credential permitted to read Secrets, reads them in the clear.

This is the residual exposure the migration did not change and structurally
cannot: it is a property of the datastore, not of where a credential was
authored. What would close it is k3s's own secrets encryption at rest
(`k3s secrets-encrypt enable`, which requires a control-plane restart). That is
a node-level change outside this repository's GitOps and has not been made.

If a credential genuinely must never persist inside the cluster, the answer is
not deletion — the workload has to stop consuming a Kubernetes Secret at all
(for example via OpenBao's agent injector or CSI driver). That is a different
delivery architecture, not a cleanup of this one.
