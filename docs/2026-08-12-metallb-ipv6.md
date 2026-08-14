# MetalLB IPv6 dual-stack rollout (2026-08-12/13)

Derived from live verification during rollout: `kubectl get svc -A`,
`mikrotik-connect r` session/route dumps, frr-k8s rendered config, and
non-cluster-host TCP probes.

## End state

Every argo-managed `type: LoadBalancer` service carries an IPv4 **and** IPv6
address, both BGP-announced over the existing MP-BGP sessions to the MikroTik
RB5009. The `services` IPAddressPool is dual-stack; the `.5.10` control-plane
VIP stays v4-only. avahi is untouched on every node.

## What changed (in order)

1. **Pool** — `workloads/metallb/ipaddresspool.yaml`: the `services` pool now
   serves `192.168.6.10-192.168.6.50` **and** `fd00:6::10-fd00:6::50`
   (one pool, both families). `control-plane-vip` unchanged (v4-only,
   `autoAssign: false`).
2. **BGPPeer** — `workloads/metallb/bgppeer.yaml`: added
   `dualStackAddressFamily: true` on `mikrotik-router`. **Required**: without
   it, the frr-k8s controller renders `ipv6 prefix-list …-allowed-ipv6 deny any`
   and no `address-family ipv6` block — v6 prefixes are never advertised even
   after the router negotiates both AFIs.
3. **Router (RouterOS 7.19.6)** — two-part change, both needed:
   - `/routing bgp template set 0 afi=ip,ipv6` (default template)
   - `/routing bgp connection set <n> afi=ip,ipv6` for all 5 `metallb-*`
     connections. The template change alone is **not sufficient on 7.19.6**:
     sessions re-established showing `remote.afi=ip,ipv6` but the router's own
     `local.afi=ip` stayed v4-only until the connections were set directly.
   All 5 sessions now negotiate `afi=ip,ipv6` both directions; v4 routes
   (`.5.10`, all `.6.x`) survived untouched.
4. **Services** — each argo LB service gained the triple:
   `metallb.io/loadBalancerIPs: "192.168.6.X,fd00:6::X"`,
   `spec.ipFamilyPolicy: PreferDualStack`, `spec.ipFamilies: [IPv4, IPv6]`.
   See the table below. `PreferDualStack` (not `RequireDualStack`) so a family
   hiccup never blocks allocation.
5. **steward edge cases**:
   - `steam-lobby/coturn-svc.yaml` used the legacy `spec.loadBalancerIP` field
     (the only one) — converted to the annotation form, dual-stacked.
   - `charts/stalwart`: chart template (`templates/service.yaml`) did not render
     `ipFamilyPolicy`/`ipFamilies`; the LB Service template now hardcodes both
     under `spec:`; annotation extended in `values.yaml`.
   - `mosquitto` deployment: added a **required** `workload-type=general`
     nodeAffinity — it tolerated the `pi` taint and scheduled onto pite (arm64,
     no Longhorn CSI), wedging the pod in `ContainerCreating` for 7h. Not IPv6
     related, found while piloting.

## v6 address table (v4 and v6 are disparate address spaces)

| Service | v4 | v6 |
|---|---|---|
| traefik (kube-system, manual) | 192.168.6.11 | fd00:6::10 |
| unifi-inform | 192.168.6.10 | fd00:6::30 |
| unifi-discovery | 192.168.6.12 | fd00:6::12 |
| stalwart (smtp/submission/imaps) | 192.168.6.13 | fd00:6::13 |
| steam-lobby coturn (TURN 3478 + 45000-45063) | 192.168.6.14 | fd00:6::14 |
| teamspeak ts-voice (9987) | 192.168.6.15 | fd00:6::15 |
| teamspeak ts-files (30033) | 192.168.6.16 | fd00:6::16 |
| openrct2-game | 192.168.6.17 | fd00:6::17 |
| headscale-stun | 192.168.6.18 | fd00:6::18 |
| mosquitto-nodeport (1883) | 192.168.6.19 | fd00:6::19 |
| matrix coturn (3478) | 192.168.6.21 | fd00:6::21 |
| livekit-server-rtc (7881/50000) | 192.168.6.22 | fd00:6::22 |
| mimir-lb | 192.168.6.23 | fd00:6::23 |
| loki-push-lb | 192.168.6.24 | fd00:6::24 |
| unifi-web | 192.168.6.25 | fd00:6::25 |
| **temporal-frontend** | 192.168.6.20 | **v4-only** — chart limitation, see below |
| kubernetes-api (control-plane VIP) | 192.168.5.10 | **v4-only** by design |

Notes:

- **traefik `fd00:6::10` is a manual annotation** (`kubectl annotate`, managedFields
  shows `kubectl-patch`/`kubectl-annotate`), NOT rendered by the HelmChartConfig
  (which only pins `192.168.6.11`). The k3s chart defaults the service to
  `PreferDualStack`, so MetalLB auto-assigned `::10` once the pool gained v6.
  Leave as-is; if it ever collides, pin it to `fd00:6::11`.
- **unifi-inform is `fd00:6::30`, not `::10`** — `::10` is traefik's. This was a
  live collision during rollout (unifi went PENDING with `AllocationFailed:
  address also in use by kube-system/traefik`).
- **temporal-frontend stays v4-only**: the temporal chart (`temporal-1.5.0`,
  remote `go.temporal.io/helm-charts`) renders `annotations` but has no
  `ipFamilyPolicy`/`ipFamilies` passthrough, and it's not vendored (stalwart is,
  which is why stalwart could be patched). To dual-stack it later: vendor the
  chart or add a post-sync patch; do not hand-edit the deployed Service
  (ArgoCD `temporal` app owns it).
- `fd00:6::11` (traefik's twin slot) and `::20` (temporal's twin slot) are free;
  `::28`–`::50` are free for future pins. `.26/::26` (frigate) and `.27/::27`
  (pihole-dns) were allocated 2026-08-13 — the authoritative allocation table
  now lives in `adding-a-workload.md` §5.

## Router state (post-change)

- `/routing bgp template`: `afi=ip,ipv6`; all 5 `metallb-*` connections:
  `afi=ip,ipv6`. Sessions negotiate both; v4 EOR + v6 both present.
- `/ipv6 route`: `fd00:6::X/128` entries with `b` (BGP) flag, gateways =
  speaker node ULAs (`fd00:1::X`). `::/0` via WAN and `fd00:1::/64` SLAAC on
  bridge unchanged.
- ICMP to LB VIPs always times out (kube-proxy DNATs TCP/UDP only) — probe with
  `nc`, never `ping`.

## Verification (what passed)

- Router has every announced v6 /128; v4 routes (`.5.10`, `.6.11`) intact.
- From a **non-cluster LAN host** (phone):
  - `nc -6 -zv -w 5 fd00:6::19 1883` → succeeded (mosquitto pilot)
  - `nc -6 -zv -w 5 fd00:6::13 25` → succeeded (stalwart SMTP)
- Pod-side for all others: pods Running, kube-proxy v6 DNAT rules present,
  IPv6 EndpointSlices populated, router next-hops reachable.
- **Non-cluster hosts only**: office/pite ARE k3s nodes — kube-proxy intercepts
  LB VIPs locally (verified ip6tables), so their probes prove nothing about the
  router path. bigp (Proxmox host) has no IPv6 route (only `fe80::`); the router
  itself blocks `/tool fetch`/`bandwidth-test` in device-mode. Use a
  phone/laptop/AP.

## Rollback

- Router: `/routing bgp connection set <n> afi=ip` (all 5) + template
  `afi=ip` → sessions renegotiate v4-only, v6 routes vanish, v4 unaffected.
- Argo: revert the manifest commits; ArgoCD self-heals services back to
  single-stack. Pool/BGPPeer are additive — reverting them only stops new v6
  allocations.

- ~~Matter-server fabric: `Loaded 0 nodes` at startup~~ — **RESOLVED 2026-08-13**:
  fabric restored from the 2026-08-07 Longhorn backup (PVC
  `matter-server-data-aug7`, byte-exact 243269632-byte restore, `Loaded 11
  nodes`, devices working). See the restore runbook/plan notes.
- matter-server websocket: hourly `No PONG received after 27.5s` (HA ↔
  matter-server) — HA-side processing stall, not IPv6.
- temporal-frontend dual-stack (chart passthrough needed — see above).
- `workloads/tuwunel/livekit-rtc-svc.yaml` is an **orphan** (no ArgoCD app
  references it; carries a stale `kube-vip.io/loadBalancerIPs: 192.168.5.10`
  annotation). Delete or adopt it.
- Network-engineer skill (`~/.omp/agent/skills/network-engineer/SKILL.md`) BGP
  section still documents the retired `kube-vip-*` session names; update to
  `metallb-*` and add the `fd00:6::/64` LB range + v6-twin rule.
- Global IPv6 later: add a global-prefix range to the `services` pool and extend
  the annotations — no structural change needed.
