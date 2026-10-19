# Fungible ingress -- 2026-10-15 outage, root cause and redesign

**Date:** 2026-10-15 (redesign executed 2026-10-19)
**Status:** Complete, except ECMP (trialled and reverted, follow-up #78) and pite's own rebuild and migration.

## Outage

13:25 EDT Helm revision v32 re-applied the traefik release, which rewrote the
Service. At 13:27:26 MetalLB logged `clearAssignment` and then
`IP allocation failed ... does not match the ipFamily`: the Service is
PreferDualStack (the k3s-bundled manifest sets `service.spec.ipFamilyPolicy`)
and carried a v4-only `metallb.io/loadBalancerIPs: "192.168.6.11"`, so MetalLB
released the address instead of narrowing it. The VIP left BGP, the router's
fail-closed blackhole dropped WAN 80/443, the Gateway lost its address,
`lan-dns` began answering public IPs and went unready, and headscale
crash-looped. Every public site was down until ~18:24 EDT (about five hours).

It recurred 2026-10-16 10:57-14:10 EDT on Helm v35. The interim fix, dotfiles
`d5a830f`, pinned both families at once. `BlackboxProbeFailed` fired both times;
nothing else noticed a total ingress loss.

See [network-edge.md](network-edge.md) and [lan-dns.md](lan-dns.md).

## The ingress address

Traefik's pair moved from `192.168.6.11`/`fd00:6::10` to `192.168.6.6`/
`fd00:6::6`. The reason is structural: `.6.6` and `fd00:6::6` sit outside the
`services` pool ranges (`.6.10-.6.200`, `fd00:6::10-::ff`), so the new `ingress`
pool is purely additive -- no live allocation moved, no re-range, and the old
pair simply returned to `services`. Both families are symmetric (`6` and `::6`),
which the old pair was not (`11` but `::10`). The address was unused (no
Service, no router route or address-list entry) and lies inside the fail-closed
`192.168.6.0/24` blackhole.

MetalLB takes one address per family from a `loadBalancerIPs` list, so the two
pairs cannot be held at the same time. The move was therefore: add the pool,
remove the stale pin that `kubectl annotate` had written outside Git, rebuild
closet (the pool annotation then clears the old assignment and allocates from
`ingress`), and let the router follow. Reverting means re-adding
`metallb.io/loadBalancerIPs=192.168.6.11,fd00:6::10`, still inside `services`.

Measured transition: Helm revision v41 at 08:30:47Z; `ingress-follow` rewrote
both WAN rules at 08:31:14Z -- **27 seconds**, with no manual router edit.

## Design rule

No Service carries an ingress address. The address exists once, in the
`ingress` IPAddressPool; the Service asks for the pool by name
(`metallb.io/address-pool: ingress`), and the router, `lan-dns` and the Gateway
derive the value. Any pin that survives is a latent outage, and any dual-stack
pin must name both families.

## Changes

| step | repo | commit | what |
|---|---|---|---|
| 0.6 | router | -- | RouterOS 7.24.5, one instance `bgp-instance-1` (AS 65001) |
| 1 | argo | `f276662` | `ingress` IPAddressPool (`.6.6`, `fd00:6::6`, `autoAssign: false`) |
| 2 | dotfiles | `6285839` | `network-configs/scripts/ingress-follow.rsc` |
| 2.10 | argo | `fb0824a` | `network-edge.md`: renamed rules, follower bullet |
| 3.1 | dotfiles | `e3dcb57` | Traefik asks for pool `ingress`; pod DNS and canary probe -> `.6.6` |
| 3.2 | dotfiles | `f4716f3` | UDP 3784 open on every speaker |
| 3.3 | dotfiles | `64ec703` | `LoadBalancerNoIP` / `LoadBalancerNoReadyEndpoints` on pite |
| 3.3b | dotfiles | `f1dae2a` | `DeadMansSwitch` -> `blackhole` receiver |
| 3.4 | dotfiles | `b55b657` | pite registers with `exclude-from-external-load-balancers` |
| 4.9 | argo | `0871967` | headscale `extra_records` + IP table + offsets rule -> `.6.6` |
| 5 | argo | `fbd8c82` | `bfdprofile.yaml` (`router-bfd` 300 ms x 5) + `bfdProfile`/`connectTime: 5s` |
| 7 | argo | `4d2bd13` | `externalTrafficPolicy: Local` for minecraft, factorio, ts-voice, ts-files; ts NodePorts dropped |
| 8 | argo | `713bdd6` | `bgpadvertisement` loses the pite hostname selector (`spec: {}`) |
| 11 | argo | (this commit) | record, `node-maintenance.md`, guide corrections |
| interim | dotfiles | `d5a830f` | dual-stack pin (superseded by 3.1) |
| upgrade | router | -- | 7.19.6 -> 7.24.5, 2026-10-17 (owner) |
| 6/9 | router | -- | `metallb-speakers` listener, `k8s-nodes` admission, `metallb-in` filter, BFD, router-id pin, `multipath=16` trialled and reverted, node migrations (captured by the 9.3 baseline export) |

## How the router follows the cluster

`dst-nat to-addresses` takes an IP or range and never health-checks it, so the
literal is made a function of cluster state. Router script `ingress-follow`
(source `dotfiles/network-configs/scripts/ingress-follow.rsc`) resolves
`john2143.com` through the router's own DNS (FWD -> `lan-dns` -> `k8s_gateway`
-> Gateway status address = Traefik's VIP) and rewrites both WAN rules when the
answer differs. The guard accepts only `192.168.6.0/24`: if `lan-dns` is down the
router resolves publicly, the guard rejects that answer, and the last target is
kept. It runs every minute from the `test-script` of netwatch
`ingress-follow`, because `/system scheduler` is blocked by device-mode `home`.

Verified before the move: installed source identical to the file, `done-tests`
rising, and a deliberate `to-addresses=192.168.6.12` restored to `.6.11` within
75 s with the log line `192.168.6.12 -> 192.168.6.11`.

## Peering and failure detection

Before: five hand-made connections `metallb-<node>`, one per node, no route
filter, a 3-minute hold time, one active next-hop.

After: one listener `metallb-speakers` for `192.168.5.0/24`, every property on
the connection itself. Admission is firewall address-list `k8s-nodes` (one
entry per node, comment = node name), an input rule dropping TCP/179 from
anything else, `remote.allowed-as` on num-list `metallb-as`, a filter chain
`metallb-in` accepting only service /32s in `192.168.6.0/24`, `/128`s in
`fd00:6::/64` service space and the API VIP, and 1000 processed routes per
family. Adding or removing a node needs no router BGP edit.

BFD (300 ms x 5 = 1.5 s detection) plus `connectTime: 5s` turns a dead or
stalled speaker into a withdrawn prefix in about a second and a half, and a
redial in seconds. Graceful restart stays off: with GR negotiated FRR skips the
Cease on shutdown and the router would keep stale routes.

The instance router-id was blank after the 7.20 migration (falling back to
`/routing id`, `192.168.88.254`); it is now pinned to `192.168.5.1`. That
change resets every session, and with `connectTime: 5s` all five were back
within 30 seconds.

Migrations completed on 2026-10-19: `big`, `nas`, `arch`, `closet` moved to the
listener one at a time, each with a 6-minute dead-man script that would have
re-enabled the named connection if the move had gone wrong (the idiom was
proved first with a non-disruptive `fe-revert-test`). Each node verified:
session `E` under the listener, BFD `up` (300/300, multiplier 5), and prefix count
back to its baseline. `pite` still uses its named connection `metallb-pite`
because its rebuild has not completed; it announces nothing either way (the
label and `spec: {}` both exclude it), and it moves last.

ECMP was trialled last (`multipath=16` on the instance) and **reverted**. With it
enabled, TLS connections on the WAN hairpin path died mid-handshake (`curl: (35)
Recv failure: Connection reset by peer`, after ServerHello) while plain HTTP on
port 80 and direct-to-VIP traffic kept working. The A/B was unambiguous: unsetting
`multipath` restored `301`/`200` immediately, re-enabling reproduced the failure,
and `ipv4-multipath-hash-policy=l4` only moved which hostnames broke. The route
shapes themselves were correct (`.6.6/32` and `fd00:6::6/128` as `+` routes over
the two Traefik nodes, `.29/32` single), so the mechanism works and the loss is in
flow delivery -- follow-up #78. BFD alone still gives ~1.5 s withdrawal, which is
the property that matters.

Admission was proved end to end: a TCP probe from office (in `k8s-nodes`, no
speaker) connected; with its address-list entry disabled the probe failed and
the drop rule counted the packets; re-enabling restored it.

Two operational notes: a bare TCP connect to 179 leaves a half-open session
(`.as=0`, `hold-time=infinity`) that does not expire on its own --
`/routing bgp session clear ... flag=...` is rejected by 7.24.5, and the
working removal is to disable and re-enable `metallb-speakers`. And `big`'s
`frr` container still restart-loops on a 1-second probe timeout under CPU
pressure (follow-up #77).

## Long-lived flows and draining

RouterOS has no resilient hashing: whenever a node starts or stops announcing a
VIP, 1/4-1/2 of that VIP's existing flows move to another node and break (TCP
resets; UDP arrives from a new source). Under `Cluster` every speaker announces
every VIP, so any drain touches long-lived flows. `externalTrafficPolicy: Local`
announces only from the node with a ready local endpoint and keeps real client
IPs; it is used for `minecraft-game`, `factorio-game`, `ts-voice` and
`ts-files`, and already by `traefik`, `stalwart` and `headscale-stun`.

`kubectl cordon` does nothing for MetalLB. The label
`node.kubernetes.io/exclude-from-external-load-balancers` withdraws the routes
while the session stays up; that is the first step of every drain.

Proved on `closet` on 2026-10-19 (chosen because `nas` and `arch` each host the
only ready endpoint of a Local Service): labeling took its session from 28
prefixes to 0 within 30 s while the session stayed `E` with an unbroken uptime,
the router's routes via closet went from 15 to 0, and external HTTPS answered
from four check-host nodes throughout. Unlabeling restored 28 prefixes and 15
routes.

See [node-maintenance.md](node-maintenance.md).

## Hardware offload

The RB5009's 88E6393X switch is not on MikroTik's L3 hardware-offloading list
and the device exposes no `l3-hw-offloading` property, so routed traffic was
never offloaded; `hw-offload=yes` on `defconf: fasttrack` is inert. Software
FastTrack stays active with ECMP and BFD, which is why `ipv4-fasttrack-active`
still reads yes.

## Alerts

Two rules on pite, reading kube-state-metrics series back from Mimir through
`remoteRead` (they never exist in pite's local storage):
`LoadBalancerNoIP` (a LoadBalancer Service with no ingress address) and
`LoadBalancerNoReadyEndpoints` (no ready endpoint, with a one-hour grace for
Services deliberately scaled to zero). Both expressions returned the outage's
Services at `2026-10-15T20:00Z`: `kube-system/traefik` for the first,
`lan-dns/lan-dns` and `default/headscale-stun` for the second, and nothing now.
`promtool check rules` passes. `DeadMansSwitch` now routes to a `blackhole`
receiver -- it still proves pite is alive but no longer pages ntfy every four
hours.

## Known literal corrections

- headscale lives in namespace `default`, not `headscale`; the 12 records are
  in `default/headscale-config` under `config.yaml`, and the "fronts EVERY
  *.ts.2143.me host" warning is in the same ConfigMap's `policy.hujson`.
- The traefik Helm release was at v40 before this change, not v38.

## Follow-ups

- #74 CNPG: every database survives a node failure (>=2 instances, spread).
- #75 CNPG: graceful disruption -- drains switch over instead of blocking.
- #76 Longhorn: single-replica non-CNPG volumes block drains.
- #77 big: frr-k8s container restart loop (probe timeout vs CPU pressure).
- #78 ECMP breaks TLS on the WAN hairpin path -- investigate before re-enabling.

## Remaining address literals

- `workloads/metallb/ipaddresspool.yaml` -- by design; the only place the
  ingress pair lives.
- `lan-dns` `hosts`: `.6.13`, `.6.20`.
- `coredns-custom`: `.6.6`, `.6.13`, `.6.20`.
- `headscale` `dns.extra_records`: `.6.6` (12 entries), with
  `scripts/validate-headscale-dns.sh` pinning the same value.
- `clientTrustedIps` allowlists in `workloads/{stalwart,pocket-id,gateway}/
  security-middlewares.yaml`, `apps/openbao.yaml` and
  `crowdsec-agent/agent-whitelists.yaml` carry the WAN address
  `108.56.153.222`: Verizon's hairpin presents LAN clients as the public IP and
  an IP list has no hostname form. Any new middleware copies it -- do not
  "clean it up".
- Router dst-nat for every non-HTTP WAN service; `lan-dns forward` and its
  netwatch (`.6.30`); pite's blackbox targets; `status-page/generate.py`.

## Rejected, with reasons

- **dst-nat straight to node IPs.** RouterOS has no NAT target list and no
  health check; a node going away black-holes WAN traffic.
- **Traefik on `hostPort`.** The Gateway address comes only from `statusAddress`
  or a LoadBalancer Service, so a pinned IP returns.
- **An in-cluster reconciler for the NAT target.** A router script needs no
  cluster credentials and cannot be broken by an RBAC mistake.
- **An egress IP pool.** MetalLB is inbound-only; egress is already one router
  `srcnat` masquerade to the WAN address, identical for every node.

## Verify

```
# ingress address and pool
ssh 192.168.5.36 'kubectl -n kube-system get svc traefik -o jsonpath="{.status.loadBalancer.ingress[*].ip}"'
ssh 192.168.5.36 'kubectl get ipaddresspool -n metallb-system'
mikrotik-connect r '/ip route print terse where dst-address=192.168.6.6/32'
dig +short @192.168.6.30 john2143.com

# follower and WAN rules
mikrotik-connect r '/ip firewall nat print terse where comment~"ingress"'
mikrotik-connect r ':put [/tool netwatch get [find name=ingress-follow] done-tests]'

# peering, BFD, admission
mikrotik-connect r '/routing bgp connection print terse'
mikrotik-connect r '/routing bgp session print proplist=remote.address,prefix-count'
mikrotik-connect r '/routing bfd session print'
mikrotik-connect r '/routing filter rule print detail where chain=metallb-in'
ssh 192.168.5.36 'kubectl get bgpsessionstates -n metallb-system'

# alerts
curl -s http://192.168.5.9:9090/api/v1/rules | jq '.data.groups[].name'
curl -s http://192.168.5.9:9090/api/v1/alerts | jq '.data.alerts[].labels.alertname'

# external
curl -sk -o /dev/null -w '%{http_code}\n' https://john2143.com/
curl -sk -o /dev/null -w '%{http_code}\n' https://net.john2143.com/health
```

## Rollback

1. Traefik: re-add `metallb.io/loadBalancerIPs=192.168.6.11,fd00:6::10` and
   rebuild closet with `metallb.io/address-pool` removed; the old pair is still
   inside `services`.
2. Router: enable a named connection per node (re-create it from the 6.1
   `export terse` snapshot), then disable `metallb-speakers`. Reverting the
   router-id is optional -- a blank value is functional.
3. ECMP: `/routing bgp instance unset [find name="bgp-instance-1"] value-name=multipath`.
4. Games: drop `externalTrafficPolicy: Local` (they fall back to `Cluster`).
5. Alerts: `git revert` the pite commit and rebuild pite.
