# Deploying a private-repo game

How a game whose repository is private ships its images and binaries without
publishing anything on GitHub, and how its chart pulls them. ROTS (the private
`2143-Labs/rots4` monorepo) is the first and reference user; its chart is
`workloads/rots-web/`.

## 1. When this applies

Use this when the game's repo is private **and** its images and binaries must
not be public.

- `Dino-Dash` and `Moss-And-Wool` are private repos with *public* GHCR
  packages. They need none of this.
- Never push a private repo's images to GHCR. A package that has once been
  public can never be made private again, and private-repo packages and Actions
  artifacts share the Free plan's 500 MB.

## 2. Publish images to zot

Images go to the self-hosted registry **zot** at
`registry.ts.2143.me/2143-labs/<repo>` (`workloads/zot/`). It is reachable only
from the LAN and tailnet (HTTPRoute with `lan-only`), and every request needs a
login: anonymous `/v2/` answers `401` with `Basic realm="zot"`.

For a new repo:

1. **CI user.** Append a bcrypt line for a new user (e.g. `<repo>-ci`) to the
   `htpasswd` property of OpenBao `consumers/john2143-com/default/zot-htpasswd`
   (`bao kv patch` with the *full* value, existing lines included), and store
   the plaintext as `{username, token}` in
   `consumers/john2143-com/default/zot-<repo>-ci`. zot reloads the file by
   itself once ESO syncs it.
2. **Access and retention** in `workloads/zot/configmap.yaml`:
   - add an `accessControl.repositories` entry for `2143-labs/<repo>` giving the
     CI user `read`, `create`, `update`. zot applies only the **longest**
     matching pattern, so the new entry must repeat
     `{"users": ["cluster-pull"], "actions": ["read"]}`: the `**` entry never
     reaches a repo that has its own entry;
   - add a retention policy before the catch-all `**` policy. Tags that match
     no `keepTags` pattern of a repo's policy are deleted at the next GC.
3. **CI reads it from OpenBao, not from Actions secrets** (see
   [CI credentials](#ci-credentials-github-oidc-to-openbao)).
4. **Push** from the self-hosted runner with `skopeo copy --format oci
   docker-archive://… docker://registry.ts.2143.me/2143-labs/<repo>:<tag>`, as
   rots4's `build_nix.yml` does. Log in to an auth file that does **not** exist
   yet (`skopeo login --authfile "$(mktemp -d)/auth.json" … --password-stdin`):
   skopeo refuses an existing empty one.

## 3. Publish binaries to SeaweedFS

1. Add an S3 identity to the `s3.json` property of OpenBao
   `consumers/john2143-com/default/seaweedfs-s3-config`, with actions
   `Read:<bucket>`, `Write:<bucket>` and `List:<bucket>`. Editing that key
   restarts the filer (about a minute of S3 retries for every consumer).
2. Create the bucket owned by that identity:
   `s3.bucket.create -name <bucket> -owner <identity>` in `weed shell` on the
   filer. Non-admin identities only reach buckets they own.
3. Copy only that identity's keys into their own OpenBao key (rots4:
   `consumers/john2143-com/default/rots4-ci-s3`, fields `access_key_id` and
   `secret_access_key`), so a CI policy never needs the whole `s3.json`.
   Re-copy it whenever you rotate that identity.
4. Upload from CI to the LAN endpoint `http://192.168.6.31:8333`
   (`seaweedfs-s3-lan` in `workloads/seaweedfs/svc.yaml`; plain HTTP, SigV4
   authenticates) with `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` and
   `AWS_RESPONSE_CHECKSUM_VALIDATION=when_required`, path-style addressing.
5. Prune old builds from CI (rots4 keeps `builds/<sha>/` for 90 days and an
   always-overwritten `latest/`).
6. Never use Actions artifacts or GitHub-hosted runners for these builds.

People download binaries through the filer UI `files-ui.ts.2143.me`
(`/buckets/<bucket>/`), or with S3 credentials.

## CI credentials: GitHub OIDC to OpenBao

GitHub stores no credential. Each job that publishes asks GitHub for its OIDC
token (`permissions: id-token: write`), logs in to OpenBao at
`https://openbao.ts.2143.me` (reachable from the runner over the tailnet) on the
auth mount `jwt-github`, and reads only the key its role's policy allows. rots4
does this in its `ci-openbao-read.sh` helper, which masks every value in the job
log. Per repo, create (admin, fish):

```fish
echo 'path "consumers/data/john2143-com/default/zot-<repo>-ci" { capabilities = ["read"] }' | bao policy write <repo>-ci-registry -
echo '{"role_type":"jwt","bound_audiences":["https://openbao.ts.2143.me"],"user_claim":"repository","bound_claims_type":"string","bound_claims":{"repository_id":"<numeric repo id>"},"token_policies":["<repo>-ci-registry"],"token_type":"batch","token_ttl":"10m","token_max_ttl":"10m"}' | bao write auth/jwt-github/role/<repo>-ci-registry -
```

- Bind `repository_id` (`gh api repos/2143-Labs/<repo> --jq .id`), not the
  name: a deleted and re-created repo gets a new id.
- The binaries role additionally binds `"ref":"refs/heads/main","event_name":"push"`
  and reads only the S3 copy key, so PR runs (which can push images) can never
  write releases.
- Rotation needs no GitHub step: CI reads the new value on its next run.

## 4. The pull credential

`consumers/john2143-com/default/zot-cluster-pull` holds `{username, token}` of
zot's read-only user `cluster-pull`. Every game reuses it; it can read every
repository and push to none.

To list a repo's tags with it (fish, values stay in a temp file):

```fish
begin
    set -l d (mktemp -d)
    bao kv get -mount=consumers -field=token john2143-com/default/zot-cluster-pull | nix shell nixpkgs#skopeo -c skopeo login --authfile $d/auth.json --username cluster-pull --password-stdin registry.ts.2143.me
    nix shell nixpkgs#skopeo -c skopeo list-tags --authfile $d/auth.json docker://registry.ts.2143.me/2143-labs/<repo> | jq -r '.Tags[]' | sort
    rm -rf $d
end
```

## 5. The chart

- Copy `workloads/rots-web/templates/registry-pull.yaml` and the
  `imagePullSecret` block of `workloads/rots-web/values.yaml`
  (`key: john2143-com/default/zot-cluster-pull`,
  `registry: registry.ts.2143.me`). The ExternalSecret renders a
  `kubernetes.io/dockerconfigjson` Secret `registry-pull` whose `auths` names
  only that registry, so images elsewhere (public ghcr.io, docker.io) keep
  pulling anonymously.
- Put `imagePullSecrets: [{name: registry-pull}]` on **every** pod spec that
  runs one of the game's images, including PodTemplates that a runtime
  provisioner clones (ROTS: `workloads/rots-web/templates/podtemplate.yaml`).
- Anything that queries the registry itself needs the credential too. The ROTS
  authserver's warm-pool image check reads it as `REGISTRY_DOCKERCONFIGJSON`
  (`secretKeyRef` on `registry-pull`, key `.dockerconfigjson`, `optional: true`)
  and only at container start: after a rotation, restart it.
- These images do not go through the `ghcr.io` mirror
  ([2026-08-14-registry-mirror.md](2026-08-14-registry-mirror.md)): every node
  pulls from `registry.ts.2143.me` through the gateway, resolved by MagicDNS.

## 6. Previews

The ApplicationSet's pullRequest generator (ROTS: `apps/rots-web-preview.yaml`)
reads PRs with Secret `argocd/github-token`, from OpenBao
`consumers/john2143-com/argocd/github-token`. That token must be able to read
the private repo. Check it (fish; must print `200`):

```fish
begin
    set -l t (bao kv get -mount=consumers -field=token john2143-com/argocd/github-token)
    printf 'Authorization: token %s\n' $t | curl -s -o /dev/null -w '%{http_code}\n' -H @- https://api.github.com/repos/2143-Labs/<repo>/pulls
end
```

If it does not, replace the token (a fine-grained PAT for `2143-Labs`, Contents
and Pull requests read-only) with `bao kv patch … token=-` and force-sync
`argocd/github-token`.

## 7. Verify

- Anonymous probe (any LAN/tailnet host; `401` means TLS verified and zot
  demanded a login):

  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' https://registry.ts.2143.me/v2/2143-labs/<repo>/tags/list
  ```

- The pull Secret (admin context): expect `SecretSynced`,
  `kubernetes.io/dockerconfigjson` and `["registry.ts.2143.me"]`.

  ```bash
  kubectl -n <ns> get externalsecret registry-pull -o jsonpath='{.status.conditions[0].reason}'; echo
  kubectl -n <ns> get secret registry-pull -o jsonpath='{.type}'; echo
  kubectl -n <ns> get secret registry-pull -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -c '.auths | keys'
  ```

- The pods: every pod on a `registry.ts.2143.me/…` image is `Running`, and no
  event mentions `ErrImagePull`, `401` or `403`.

  ```bash
  kubectl -n <ns> get pods -o jsonpath='{range .items[*]}{.metadata.name} {.spec.containers[0].image} {.spec.nodeName} {.status.phase}{"\n"}{end}'
  kubectl -n <ns> get events --field-selector reason=Failed -o jsonpath='{range .items[*]}{.message}{"\n"}{end}'
  ```

A pod that started before `registry-pull` existed shows `ImagePullBackOff` and
recovers within about five minutes (kubelet re-reads pull secrets on every
retry). If it persists: `no such host` means that node's MagicDNS is stale
(restart `tailscaled` there); `401` means the Secret's token does not match
zot's htpasswd; `403` from Traefik means `lan-only` rejected the node's source
address.

## 8. Deploy from CI

- Publish only immutable tags (ROTS: `<component>-<sha7>` on main,
  `<component>-pr-<N>-<head sha>` on PRs), and give each a `keepTags` rule in
  zot's retention (section 2).
- Prod: after a green main build, CI rewrites each image parameter in
  `apps/<app>.yaml` (one `- { name: …, value: … }` line each) and pushes the
  commit to argo `main` with a write deploy key. The `main` ruleset only blocks
  force-push and deletion, so no review is needed to land the bump. ROTS does
  this in rots4's `ci-argo-bump.sh` helper (job
  `deploy`), which also refuses to move prod to a commit that is not ahead of
  the deployed one. Roll back by reverting the bot commit.
- A private repo keeps that key base64-encoded on one line in OpenBao (so the
  helper masks it as one value) and pushes from the self-hosted runner, with ssh
  from nixpkgs and GitHub's host keys from `https://api.github.com/meta`.
  Create (admin, fish):

  ```fish
  set d (mktemp -d)
  ssh-keygen -q -t ed25519 -N '' -C <repo>-ci-argo -f $d/id
  gh repo deploy-key add $d/id.pub --repo 2143-Labs/argo --title <repo>-ci-argo --allow-write
  base64 -w0 $d/id > $d/id.b64
  bao kv put -mount=consumers john2143-com/default/<repo>-ci-argo ssh_private_key_b64=@$d/id.b64
  rm -rf $d
  echo 'path "consumers/data/john2143-com/default/<repo>-ci-argo" { capabilities = ["read"] }' | bao policy write <repo>-ci-argo -
  echo '{"role_type":"jwt","bound_audiences":["https://openbao.ts.2143.me"],"user_claim":"repository","bound_claims_type":"string","bound_claims":{"repository_id":"<numeric repo id>","ref":"refs/heads/main","event_name":"push"},"token_policies":["<repo>-ci-argo"],"token_type":"batch","token_ttl":"10m","token_max_ttl":"10m"}' | bao write auth/jwt-github/role/<repo>-ci-argo -
  ```

  Paste these lines exactly as they are. A copy that picks up wrap markers
  (e.g. a `│` in the middle of `repository_id`) still writes the role, but CI
  can never log in with it. Check it with
  `bao read -format=json auth/jwt-github/role/<repo>-ci-argo | jq .data.bound_claims`.
- Previews read `{{.head_sha}}` in the ApplicationSet, so they need no commit.
