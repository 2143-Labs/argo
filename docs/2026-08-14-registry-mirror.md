# 2026-08-14 — Registry mirror: all ghcr.io pulls through the local cache

Every cluster `ghcr.io` pull is routed through the in-cluster registry
(`docker-registry` in `kube-system`, public as `containerstore.john2143.com`)
using its GHCR pull-through cache. Image refs keep the meaningful `ghcr.io`
host — the mirror key matches on the ref host and rewrites to the local
endpoint, so no manifests, deployments, or CI need to change.

## Why

- The registry's GHCR proxy-cache (`REGISTRY_PROXY_REMOTEURL=https://ghcr.io`)
  was already enabled; only `heorot` used it. Now every cluster image pull is
  cached locally — faster cold starts, offline resilience, and one place to
  inspect what's deployed.
- The PVC was resized 5Gi → 50Gi on `longhorn-2` (frigate tensorrt alone is
  3.92GB; the registry proxy-cache has no eviction).

## The mirror config

`/etc/rancher/k3s/registries.yaml` on **all 6 k3s nodes** (arch, closet, nas,
big, office, pite):

```yaml
mirrors:
  "10.43.114.59:5000":
    endpoint:
      - "http://10.43.114.59:5000"
  "ghcr.io":
    endpoint:
      - "http://10.43.114.59:5000"
      - "https://ghcr.io"
configs:
  "10.43.114.59:5000":
    tls:
      insecure_skip_verify: true
```

- `10.43.114.59:5000` is the kube-system `docker-registry` Service ClusterIP.
  If that Service is ever recreated and the IP changes, update this file on
  every node (only this file — the 20+ `ghcr.io` refs in deployments are
  untouched by design).
- The second endpoint `https://ghcr.io` is the anonymous fallback if the cache
  is down or full (all cluster images are public; no `imagePullSecrets`).
- k3s reads `registries.yaml` **at startup only** — any change requires
  `systemctl restart k3s` (restarts all pods on that node).

## Where it's declared (durable)

- **Declaratively**: `environment.etc."rancher/k3s/registries.yaml"` in
  `~/dotfiles/nixos/modules/k3s-server.nix` (arch, closet, nas) and
  `k3s-agent.nix` (big, office, pite) — survives every `nixos-rebuild`.
- **Imperatively**: currently also present as a plain file on the nodes (a
  stopgap so it works before the next rebuild; the next `nixos-rebuild`
  replaces it with the NixOS-managed symlink — same content).

k3s 1.35 renders this into the containerd **v3** config path:
`/var/lib/rancher/k3s/agent/etc/containerd/certs.d/<host>/hosts.toml` (check
there, not `config.toml`, to confirm the mirror is live).

## Verify it's working

```bash
ssh arch sudo k3s kubectl logs -n kube-system deploy/docker-registry --tail=40
# look for GET /v2/<owner>/<pkg>/...?ns=ghcr.io (ns=ghcr.io = proxied/cached GHCR content)
ssh arch sudo crictl pull ghcr.io/sooperu/1stanniversary:6   # first pull slow, second instant
```

## Recreate / rollback

- Recreate: write the YAML above to `/etc/rancher/k3s/registries.yaml` on all
  6 nodes and `systemctl restart k3s` per node (workers first, then servers
  one at a time — never two of arch/closet/nas down; 3-node etcd quorum).
- Rollback (pulls break after a change): restore the pre-change file (backups:
  `registries.yaml.bak` on arch/closet/nas) and repeat the restart.
- Registry auth secret recreate: see `workloads/docker-registry/middleware.yaml`
  comments (imperative secret in kube-system, kept out of git).

## Related changes in this session

- `workloads/docker-registry/deployment.yaml`: PVC 5Gi → 50Gi (kept
  `storageClassName: longhorn-2` + `volumeName` pin); image pinned
  `registry:2` → `registry:2.8.3` (the floating `:2` tag is end-of-line).
  Registry 3.x (3.1.1) is deliberately deferred — breaking config changes
  (default config path, deprecations) deserve a dedicated migration.
- Registry auth hash is `{SHA}` (no htpasswd locally); upgrading to bcrypt
  (`htpasswd -Bbn`) is a known follow-up.
- Traefik LB fix (same session): the kube-system `traefik` service needed
  `metallb.io/loadBalancerIPs=192.168.6.11,fd00:6::10` annotated (dual-stack
  mismatch) — applied imperatively; not yet in k3s chart values.
