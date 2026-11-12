# DOKS secrets from OpenBao: ESO with Kubernetes auth

**Date:** 2026-11-11 (planned), 2026-11-12 (implemented)
**Status:** implemented and verified.
**Scope:** the DOKS cluster (`kubectl` context `2143prod`, cluster
`91133a65-2174-48e5-93a2-26338a61807f`), the OpenBao auth mount `kubernetes-doks/`, the
`consumers/doks/` and `consumers/doks-archive/` KV subtrees, and the SeaweedFS/Spaces Secret
rename on both clusters.

## 1. What changed

Before this change every DOKS credential was a hand-made Kubernetes Secret that existed nowhere
else. Now External Secrets Operator on DOKS renders each one from OpenBao
`consumers/doks/<namespace>/<name>` through the `ClusterSecretStore` `openbao-doks`. It
authenticates with its own ServiceAccount token against the dedicated `kubernetes-doks` auth
mount. Every ExternalSecret uses `creationPolicy: Owner` and `refreshInterval: 10m`, the same as
on the home cluster.

| DOKS Secret | OpenBao path (`consumers/…`) |
|---|---|
| `default/mongo-creds` | `doks/default/mongo-creds` |
| `default/oauth-creds` | `doks/default/oauth-creds` |
| `default/discord-oauth` | `doks/default/discord-oauth` |
| `default/openfront-pro-db-john` | `doks/default/openfront-pro-db-john` |
| `default/digitalocean-dns` | `doks/default/digitalocean-dns` |
| `default/desec-dns` | `doks/default/desec-dns` |
| `default/desec-dns-john` | `doks/default/desec-dns-john` |
| `default/tailscale-exit-auth` | `doks/default/tailscale-exit-auth` |
| `default/wireguard-doks-key` | `doks/default/wireguard-doks-key` |
| `default/analysis` | `doks/default/analysis` |
| `default/openfront-api-discordbot-creds` | `doks/default/openfront-api-discordbot-creds` |
| `default/supabase-db` | `doks/default/supabase-db` |
| `default/seaweedfs-credentials` | `doks/default/seaweedfs-credentials` |
| `default/spaces-credentials` | `doks/default/spaces-credentials` |
| `cert-manager/desec-dns` | `doks/default/desec-dns` (same path as the `default` copy) |
| `cert-manager/desec-dns-john` | `doks/default/desec-dns-john` (same path as the `default` copy) |
| `flux-system/github-token` | `doks/flux-system/github-token` |

- **Adopted in place.** The first nine `default` Secrets, both `cert-manager` copies and
  `github-token` already existed. Before they were adopted, OpenBao was proven to hold
  byte-identical data, so no pod restarted.
- **Moved namespace.** `analysis`, `openfront-api-discordbot-creds` and `supabase-db` used to
  exist only in `tk`, next to an unmanaged copy of the bot Deployment. The Flux-managed
  `openfront-api-discordbot` Deployment is in `default`, so they are rendered there now and the
  `tk` copies were deleted.
- **Renamed (both clusters).** SeaweedFS credentials are in Secret `seaweedfs-credentials` (keys
  `SEAWEEDFS_ACCESS_KEY`/`SEAWEEDFS_SECRET_KEY`). DigitalOcean Spaces credentials are in
  `spaces-credentials` (keys `S3_ACCESS_KEY`/`S3_SECRET_KEY`). The app still reads env vars
  `MINIO_*`, and the Deployments map the new keys onto them. The old `minio-credentials` (DOKS
  and home) and `minio-creds` (home) Secrets are gone, and so are their OpenBao paths. Home reads
  `consumers/john2143-com/default/{seaweedfs,spaces}-credentials`. Home and DOKS Spaces keys
  are different credentials and live on separate paths.
- **Archived and deleted.** Thirteen unreferenced DOKS Secrets are stored base64-encoded under
  `consumers/doks-archive/default/<name>` and were then deleted from the cluster:
  `seaweedfs-s3-creds`, `frigate-genai-worker-creds`, `minio-creds`, `minio-openfront-creds`
  (all dead SeaweedFS keys), `s3-creds`, `s3cmd`, `s3cmd-24mmkbhc72`, `s3cmd-f294b4gmcb`,
  `s3cmd-h8t6dbgmm2`, `openfront-pro-db`, `cafe-tls-private-key-prod`,
  `cafe-tls-private-key-staging`, `temporal-mtls-client`. To restore one, read it with
  `bao kv get`, base64-decode each value, and run `kubectl create secret generic`.
- **Skipped as non-UTF-8.** None. Every migrated value round-tripped through a plain
  `dataFrom.extract`.
- **Left alone on purpose.** Controller-generated Secrets: cert-manager certificates and
  ACME account keys, Helm release records, linkerd/keda/hubble/nginx TLS, `kube-proxy`, the DO
  telemetry token, `tailscale-exit-state`, and linkerd `cluster-credentials-homelab`.

## 2. Runtime objects, verbatim

The OpenBao auth configuration exists only in OpenBao, so it is recorded here.

```bash
bao auth enable -path=kubernetes-doks kubernetes
bao write auth/kubernetes-doks/config \
  kubernetes_host=https://91133a65-2174-48e5-93a2-26338a61807f.k8s.ondigitalocean.com \
  kubernetes_ca_cert=@<DOKS cluster CA, from the 2143prod kubeconfig certificate-authority-data> \
  disable_local_ca_jwt=true \
  disable_iss_validation=true
```

`disable_local_ca_jwt=true` is required. OpenBao runs as pods in the **home** cluster, so by
default it would use its own home ServiceAccount JWT as the TokenReview reviewer, and DOKS
rejects that. With the flag set, OpenBao reviews each login with the JWT that ESO presents. That
JWT may call TokenReview only because the ESO chart is installed with
`systemAuthDelegator: true`, which creates ClusterRoleBinding
`external-secrets-auth-delegator` (`system:auth-delegator` →
`external-secrets/external-secrets`). Without either piece, every login fails with
`permission denied`. If a control-plane firewall is ever enabled on DOKS, it must allow the
home WAN address, or every login fails at TokenReview.

Policy `doks-eso-read`:

```hcl
path "consumers/data/doks/*"     { capabilities = ["read"] }
path "consumers/metadata/doks/*" { capabilities = ["read", "list"] }
# ESO validates a store with GET /v1/sys/mounts/<mount>
path "sys/mounts"           { capabilities = ["read"] }
path "sys/mounts/consumers" { capabilities = ["read"] }
```

The glob `doks/*` does not match `doks-archive/…`, `john2143-com/…` or `edge/…`, so DOKS can read
only its own subtree.

Role:

```bash
bao write auth/kubernetes-doks/role/doks-eso \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  token_policies=doks-eso-read \
  token_ttl=15m token_max_ttl=1h
```

## 3. How to change a DOKS secret now

```bash
bao kv put -mount=consumers doks/<namespace>/<name> KEY=@file   # whole map; use `bao kv patch` for one key
kubectl --context 2143prod -n <namespace> annotate externalsecret <name> force-sync=$(date +%s) --overwrite
```

Without the force-sync, ESO picks up the change within 10 minutes. `john2143-com` carries
`reloader.stakater.com/auto: "true"`, so it restarts when its Secrets' data changes.

- Never `kubectl edit` a rendered Secret: ESO reverts it on the next refresh.
- Never delete an ExternalSecret to "reset" it: under `Owner` that deletes the Secret too.
  Recover by fixing OpenBao and force-syncing.
- Rotating the SeaweedFS key used by DOKS is `scripts/seaweedfs-rotate.py`
  (`issue`/`propagate`/`verify`/`retire john2143-worker-doks`). `propagate` writes
  `consumers/doks/default/seaweedfs-credentials` and force-syncs the DOKS ExternalSecret. It
  never patches the rendered Secret, but still reads it so that `retire` refuses while DOKS
  holds the key. See `docs/2026-11-09-seaweedfs-s3-credential-rotation.md` §3.

## 4. Where the manifests live

Everything is in `2143-Labs/2143-k8s`, which DOKS Flux follows from `main`:

- `apps/external-secrets/`: HelmRepositories plus HelmReleases for ESO chart `2.15.0`
  (`systemAuthDelegator: true`, explicit requests) and Reloader chart `2.2.20`. `releaseName`
  is set on both so the ServiceAccount is `external-secrets`, not `external-secrets-external-secrets`.
- `apps/external-secrets-config/`: the `openbao-doks` ClusterSecretStore and the 17
  ExternalSecrets, one file per namespace.
- `clusters/prod/flux-system/kustomization-external-secrets.yaml` and
  `kustomization-external-secrets-config.yaml`: two Flux Kustomizations; `-config`
  `dependsOn` the first, so an ExternalSecret is never applied before its CRD exists. Nothing
  reconciles `clusters/prod/flux-system/`, so a change to these files must also be
  `kubectl --context 2143prod apply -f`'d by hand.
- `clusters/prod/flux-system/gotk-components.yaml`: regenerated with
  `flux install --version v2.9.2 --components=…,helm-controller --export`. DOKS previously ran
  without helm-controller.
- ExternalSecrets are deliberately **not** in the `prod` Kustomization. It applies
  `overlays/prod` atomically, so one object with a missing CRD would block every DOKS deploy.

The ESO controller has cluster-wide read/write on Secrets and can create ServiceAccount tokens.
This is the first DOKS component with that reach.

## 5. SPIFFE later

The KV layout and the policy do not depend on how ESO authenticates. Only the way the OpenBao
token is obtained would change. The intended next step is SPIFFE JWT-SVIDs instead of
ServiceAccount TokenReview.

**Proven pattern (timestone).** The OIDC discovery provider is published at
`timestone-argo/workloads/spire/routes.yaml:13-14`. A sync pod
(`timestone-argo/argocd/wave-4/openbao-secret-sync.yaml`) fetches a JWT-SVID configured in
`workloads/openbao-sync/configmap.yaml` with audience `openbao.john2143.com`. It logs in at
`auth/jwt-timestone` role `hello`: `bound_subject=spiffe://trust.hero-rehab.xyz/ns/openbao-sync/sa/openbao-secret-sync`,
`bound_audiences=openbao.john2143.com`, `token_ttl=900`.

**Why DOKS is deferred:**

- **SPIRE is not a working platform on DOKS yet.** `spire-system` has `spire-agent`
  (DaemonSet, 0/2 ready) and `spire-spiffe-csi-driver` (2/2), but **no `spire-server`**. The
  controller-manager config is in git (trust domain `kube.john2143.com`, cluster `do-john2143`,
  `clusterFederatedTrustDomains: true`, `2143-k8s/base/spire-controller-manager.yaml:36-51`),
  but a server has to be stood up first.
- **No OIDC discovery provider.** DOKS has none, and OpenBao would need one at a second public
  endpoint to fetch the JWKS.
- **ESO cannot consume SVIDs.** ESO's OpenBao provider uses ServiceAccount tokens. A
  SPIFFE-based path would need a sync pod like timestone's, or a future ESO JWT-SVID source.
