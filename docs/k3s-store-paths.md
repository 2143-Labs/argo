# k3s store paths: why GC must not break a node

nixpkgs' k3s derivation (`pkgs/applications/networking/cluster/k3s/builder.nix:469-470`) replaces two
files of k3s's embedded bundle with absolute `/nix/store` symlinks: `bin/cni` and
`bin/containerd-shim-runc-v2`. Everything else is hardlinked into
`/var/lib/rancher/k3s/data/<sha256>/`, so those two files are the only ones garbage collection can
break — and `data/current`, `data/previous` and `data/cni/*` all resolve through them.

**Symptom.** The node stays `Ready` and running pods keep running, but no new pod ever starts: the
kubelet fails the sandbox with `failed to find plugin "flannel"`. Confirm with
`journalctl -u k3s | rg "failed to find plugin"`. Hit `nas` on 2026-10-24 and `arch` on 2026-10-25.

**Where the protection lives.** `dotfiles/nixos/modules/k3s-gcroots.nix`: four `L+` tmpfiles roots for
`data/{current,previous}/bin/{cni,containerd-shim-runc-v2}`, plus a `k3s-gcroots` oneshot with a
30-minute timer that roots every extraction dir (`data/<sha256>/bin/…`), because `data/current` does
not reliably name the running build. A root keeps the whole closure, including the glibc those two
binaries' ELF interpreter needs.

**Is this store path protected?**

```sh
sudo env -i /run/current-system/sw/bin/nix-store -q --roots /nix/store/<path>
```

`env -i` is not optional: under plain `sudo`, `SUDO_COMMAND` makes Nix report the invoking process as
a `/proc/<pid>/environ` root and the answer looks safe when it is not. Two more traps on these hosts:
`grep` is aliased to `rg`, so `grep -E` dies with `unknown encoding`; and both `--print-roots` and
`-q --roots` print `<link target> -> <store path>`, never the gcroots filename.

**Traefik's CrowdSec plugin** is deliberately not served from a node's store.
`workloads/traefik-plugin/plugin.tar.gz` — a deterministic tarball — is a ConfigMap, which a `busybox`
initContainer extracts into an `emptyDir` that Traefik mounts. A cluster-scoped manifest must not
reference one node's store path: the old `hostPath` form only worked while every control-plane node
had the path, which nothing enforced. That ConfigMap is ~505 KB, past the 256 KiB
`kubectl.kubernetes.io/last-applied-configuration` limit, so the Application sets
`ServerSideApply=true` — removing that sync option breaks the app.
