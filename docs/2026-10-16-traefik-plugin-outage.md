# Traefik plugin outage: one replica dropped all bouncer-gated routes (2026-10-16)

One of three Traefik replicas failed to download the CrowdSec bouncer plugin at startup because its IPv6 DNS lookup failed, so Traefik disabled all plugins on that replica, dropped every router that used one, and stayed Ready. Requests that landed on it got Traefik's own 19-byte 404 from 16:38Z until a manual restart at about 20:22Z — roughly a third of public traffic.

## Timeline (UTC)

| Time | Event |
|---|---|
| 16:38:02 | Replica `traefik-59cdf7565d-cmgnv` starts. |
| 16:38:10 | Logs `Plugins are disabled … lookup plugins.traefik.io on [fd42:42:43::a]:53: server misbehaving`. Readiness (`/ping`) stays green, so the Service keeps routing to it. |
| ~20:22 | Owner restarts the replica; the new pod downloads the plugin and routes normally. |

## Evidence

Traefik's own metrics carry the split with no log parsing: `traefik_service_requests_total` (matched a service) over `traefik_entrypoint_requests_total` (reached a listener) is the fraction of requests that got a router.

- Broken replica `10.42.3.53:9100`: **0.019** at 19:00Z and **0.083** at 20:00Z. Its peers: **0.934** and **0.950**.
- Loki cross-check, same 5-minute window: the broken pod logged 127 unrouted of 132 requests; peers 1 of 357 and 1 of 577.
- Request tallies during the window: `grafana.john2143.com` 17 × 302 + 7 Traefik-404 of 24; `mm.b.hero.rehab/joinlobby` 22 app responses + 8 Traefik-404 of 30; `argocd.ts.2143.me` 24/24 200 (it does not use the bouncer).
- A Traefik-generated 404 is distinguishable by shape: 19-byte `text/plain` body with `x-content-type-options: nosniff`.
- `/ping` never leaves 200: the pod was Ready throughout, which is why the Service kept sending it traffic.

## Cause chain

1. Closet's NetworkManager profile ran `ipv6.method=dhcp`, so it ignored the router's RAs and had no `fd00:1::/64` route — it could not reach any other node over IPv6 (10 of the 36 node→pod cells).
2. Arch's node IPv6 address was a moving stable-privacy SLAAC address while its `--node-ip` named a retired one, so flannel's FDB entries for its VTEP went stale on other nodes.
3. Every pod's `/etc/resolv.conf` lists CoreDNS at `10.43.0.10` **and** `fd42:42:43::a`, so the mesh fault sat in every DNS lookup path.
4. The plugin was downloaded at start from `plugins.traefik.io` over that path. One replica's lookup failed.
5. Without `abortOnPluginFailure`, Traefik logged `Plugins are disabled` and kept serving — with every bouncer-gated router gone. Readiness only checks `/ping`, which does not depend on routers.

## Fixes

- **`a683d09`** (dotfiles) — k3s node networking declared once in `nixos/modules/k3s-net.nix` (`custom.k3sNet`); behaviour-preserving, proven by a per-host flag diff.
- **`23798e7`** (dotfiles) — arch and pite derive their node IPv6 from the NIC MAC (EUI-64) instead of a literal or autodetection: `fd00:1::9ab7:85ff:fe23:4890` and `fd00:1::dea6:32ff:fe25:516e`.
- **`9ac1f90`** (dotfiles) — the bouncer plugin comes from a pinned local copy (`experimental.localPlugins`, `fetchFromGitHub` `v1.7.1` = `bef5dfaa…`) mounted as a store-path hostPath, with `abortOnPluginFailure: true`. A replica that cannot load it now exits instead of serving without it.
- **`0037142`** (argo) — one alert rule, `traefik-restarting` (`increase(kube_pod_container_status_restarts_total{namespace="kube-system", container="traefik"}[15m]) > 0`), because failing closed turns a plugin failure into a visible restart.
- **Host changes (owner):** `ipv6.addr-gen-mode=eui64` on pite and arch, `ipv6.method=auto` on closet (with a dead-man rollback timer), rebuilds of pite, arch, nas and closet, then `systemctl restart k3s` on every node so each rewrites its FDB entry for arch's new address.

## Verification after the fix (2026-10-21)

- Node→pod IPv6: **30/30** cells that have a pod destination pass (office hosts no pods, so it can only be a source), and underlay reachability is **36/36**. Before the fix, 12 of the 36 measured cells failed: every closet cell (10) and arch↔office (2).
- FDB: **30/30** peer VTEP entries point at the peer's advertised `public-ipv6`.
- IPv6 DNS: 3/3 explicitly addressed lookups from a non-hostNetwork pod on each of big and nas.
- Traefik: 3/3 replicas log `Plugins loaded.` with no `plugins.traefik.io` fetch; 30/30 requests per replica returned the expected status (`grafana` 302, `mm /joinlobby` an empty 404) with no 19-byte 404; every pod mounts the pinned `/nix/store/…-source` path.

## Known gaps recorded, not fixed

- **Flannel's advertised IPv6 is not `--node-ip`.** On hosts holding several global IPv6 addresses, flannel keeps advertising its DHCPv6 lease: arch's `InternalIP` is the EUI-64 address while `public-ipv6` is `fd00:1::5`, and pite is the same shape (`::2`). Both addresses are held, so routing works, but the two halves of "node identity" can disagree — see [public-edge.md](public-edge.md#troubleshooting).
- **arch's NetworkManager profile is transient** (`/run/NetworkManager/system-connections/`), so `addr-gen-mode=eui64` does not survive a reboot; making it declarative is board task #95.
- **Mimir ingestion was dropping series during this work** (`failed pushing to ingester mimir-1: context deadline exceeded`), so the new alert can miss a replica until the ingest path is healthy.

## Links

- [public-edge.md](public-edge.md#troubleshooting) — operating the bouncer plugin and the FDB/annotation trap.
- Board cards #58 (node IPv6), #59 (plugin delivery), #60 (readiness and alerts), #61 (docs). Follow-ups filed: #92 (Traefik 3.7.13 is 11 advisories behind 3.7.15), #93 (link failover for closet and arch), #94 (pin big and office identity), #95 (declarative NM profiles), #96 (matter-server stable cluster IPv6), #119 (`mc` migration for the share flow).
