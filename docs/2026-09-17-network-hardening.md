# Network hardening — state and design

Written 2026-09-17, finalised 2026-09-18 after the outage described below.
This is the running record for the network hardening effort: what is live, what
is written but not deployed, what is deliberately deferred, and which facts were
measured rather than assumed. It is updated in place as phases land.

Related documents: `2026-08-09-ingress-hardening.md` (CrowdSec and Traefik
middleware), `2026-08-12-metallb-ipv6.md` (dual-stack LoadBalancer pools),
`adding-a-workload.md` (IP allocation table), `2026-09-15-matrix-homeserver-remediation.md`.

## The outage this plan exists to prevent

On 2026-09-18 an address-list display index was mistaken for a global RouterOS
object index: `/ip address remove 0` was run against a *filtered* print whose
row 0 was not global row 0. Global row 0 was `192.168.5.1/24` — the LAN gateway
and DNS path. It was deleted, which took down egress and router management for
the whole house. Recovery required adding `192.168.1.250/24` to the core switch
for L2 access and restoring the gateway over router REST at `192.168.1.1:8081`.
Only the gateway address changed; routing, BGP, WireGuard, certificates and the
clusters recovered on their own.

Two rules came out of it and apply to every RouterOS change from now on:

1. **No numeric selectors, ever** — not from a filtered print and not from a
   fresh unfiltered one. Select by a unique exact comment, or by an exact
   multi-property identity that was printed immediately before the mutation and
   returned exactly one row. If no such selector exists, leave the object alone;
   cosmetic cleanliness is not worth an outage.
2. **Two independent authenticated management paths, one Safe Mode transaction
   per mutation.** Keep the normal SSH session to `192.168.5.1` open, and
   separately complete an authenticated login through the `192.168.1.250/24`
   foothold (Winbox/web/REST) or prove Winbox-by-MAC/serial. Then make exactly
   one change with Safe Mode active (`Ctrl+X`), probe from a separate terminal
   (gateway, two public IPv4s, direct router DNS, a critical VIP over HTTP, and
   a *new* SSH login), and only then commit with `Ctrl+X`. On failure press
   `Ctrl+D` to discard — never `/quit`, which commits. A lost session rolls the
   floating change back by itself.

## Live and verified

### WireGuard tunnel to the DigitalOcean cluster

A dedicated privileged `hostNetwork` pod (`wireguard-doks` in `2143-k8s`)
terminates a WireGuard tunnel to the router. Router peer `2143-k8s cluster:
postgres client + tunnel`, `allowed-address=10.99.0.2/32,10.244.0.0/16`,
interface `wg-remote`, listen UDP 51820. The tunnel is used for exactly one
thing — reaching PostgreSQL and MongoDB without public exposure — and the
`chain=forward` rules accept tunnel→`192.168.5.36:5432` and drop the rest
(`wg-drop`).

Public `5432` is closed: a `chain=input` rule `no public postgres; log attempts`
drops and logs WAN-sourced 5432 before the catch-all LAN rule, and its counter
rises on an external probe. (It has to live in `input`, not `forward` — the
destination is the router itself, so a forward rule can never match.)

The router's WireGuard private key was rotated when the interface was recreated;
the pre-rotation key is dead. Router public key
`lNbjEa+tSPp03UIQrmqc1TiRdPO+E4zYYOvXm+a1Wig=`, client public key
`jUMIaOQP8hPqzw3t//WZrpt/WTFkRzkD18LBM27RlEE=`.

### Public MongoDB — NOT retired, still exposed

> **Re-verified 2026-09-18 and the earlier "retired" claim is wrong.**
> `doctl compute firewall get 2c0a7567-3422-4705-a4f9-73bffa8a52ee --format
> InboundRules` still lists `protocol:tcp,ports:32040,address:0.0.0.0/0`, and a
> TCP connection to `161.35.58.72:32040` from a LAN host completes. That is the
> `mongo-nodeport` NodePort (27017) in the DO cluster, and the `mongo` pod is
> running. Treat this as an open internet-facing database until the rule is
> removed. The rule was probably never deleted rather than re-added — the
> `--format InboundRules` output is one long line and is easy to mis-read.
>
> Remediation is a single DO firewall edit, which is shared infrastructure and
> was deliberately left to the owner:
> `doctl compute firewall remove-rules 2c0a7567-3422-4705-a4f9-73bffa8a52ee
> --inbound-rules "protocol:tcp,ports:32040,address:0.0.0.0/0,address:::/0"`.
> Re-check with `nc -vz 161.35.58.72 32040` afterwards (it should time out) and
> confirm nothing in the DO cluster depended on the NodePort: in-cluster traffic
> does not traverse the cloud firewall, so nothing should.

What *is* in place: the `ddns-mongo` Flux resource was pruned, the deSEC
`mongo/A` record was deleted (note the wildcard still resolves
`mongo.john2143.com`), and `mongo-nodeport` is deliberately kept as the
in-cluster path. `worker-uri` is now `mongodb://…@10.99.0.2:32040/` on both
clusters — home composes it in `workloads/secrets/default-mongo-creds.yaml` from
OpenBao via an ESO v2 template (commit `2c75776`); the DO copy was patched by
hand. The real consumer is the Temporal worker controller's
`john2143-com-worker-209`, not a Deployment named `john2143-worker`.
`wireguard-doks` is Running in the DO cluster, so the tunnel path is live.

### CrowdSec detection

The `crowdsecurity/traefik` collection and `crowdsecurity/traefik-logs` parser
are enabled, acquisition polls the container logs, and route middleware coverage
was extended. A log-based `crowdsecurity/http-probing` ban was verified with the
bouncer returning 403 mid-sweep.

**There is deliberately no prune CronJob.** The CrowdSec image has no `jq`(it
ships `yq`), and the available Secret holds only `csLapiSecret` and
`registrationToken`, neither of which can administer the LAPI. Prune by hand
with the predicate in `2026-08-09-ingress-hardening.md` §7: delete only
`auto_created=true` records. Deleting the `traefik` `auto_created=false` anchor
breaks the bouncer — that was the 2026-09-18 regression.

### Cluster east-west NetworkPolicy, wave 1

`apps/network-policies.yaml` → `workloads/network-policies/`, one file per
namespace, `00-pattern.yaml` documenting the template. Wave 1 covers `keda`,
`crowdsec` and `observability` with default-deny ingress, an exact allow list
and the B1 egress tier.

Verified after the wave: `chat.2143.me` and `anni.2143.me` return 200 through
the KEDA interceptor, `cscli metrics` shows parser and AppSec activity, Grafana
returns 302 through Traefik, Mimir reports all six `kubelet` targets up,
`mimir-lb`/`loki-push-lb` answer, and a pod in `default` cannot reach the Mimir,
CrowdSec LAPI or Grafana pod IPs.

Wave 1 rewrote two assumptions that were wrong on paper and had already caused a
real, silent failure — see "Measured facts" below. `default` is skipped by the
plan's safety gate (it runs Home Assistant, Mosquitto and Matter, whose LAN/IoT
and mDNS/SSDP egress cannot be enumerated, and ingress and egress ship
together). The remaining namespaces need their own audits; `cnpg-system`'s
access to namespaces hosting PostgreSQL `Cluster`s and the KEDA interceptor's
access into `matrix` for `heorot` are the two dependencies that must be settled
first.

## Measured facts (use these instead of assumptions)

These were all verified against the live cluster on 2026-09-18; each one
invalidated something that looked obviously true in a design document.

- **NetworkPolicy is enforced.** k3s's built-in controller (kube-router derived)
  installs `KUBE-NWPLCY-*` / `KUBE-POD-FW-*` iptables chains. They are keyed on
  **pod IPs**.
- **hostNetwork pods are effectively exempt**, because the controller never
  lists a node IP as a pod IP (no node IP appears as a source in any
  `KUBE-POD-FW` chain).
- **kube-router accepts the pod's local node automatically** (`--src-type LOCAL`),
  so kubelet probes and same-node traffic need no rule of their own.
- **Policy ports are the destination pod's container ports, not Service ports.**
  Grafana's Service publishes 80 and the container listens on 3000; a rule
  written for 80 silently breaks HTTP routing to Grafana.
- **Anything that reaches a pod through kube-proxy is masqueraded to a
  pod-network gateway**, not to a LAN address: per node, `flannel.1`
  (`10.42.<n>.0/32`) for cross-node and `cni0` (`10.42.<n>.1/32`) for same-node.
  Measured by conntrack on the destination node: a connection from office to a
  pod on closet arrived as `src=10.42.1.0`. This covers LoadBalancer IPs,
  NodePorts and control-plane processes dialing a Service. Nodes are
  `0=closet 1=office 2=pite 3=nas 4=big 6=arch`; regenerate the list from
  `kubectl get nodes -o json | jq -r '.items[].spec.podCIDR'` if the node set
  changes, or LB/NodePort access to a covered namespace breaks with "connection
  refused".
- **The LoadBalancer masquerade ignores the client.** A pod that connects to a
  VIP is anonymised exactly like an internet client, so allowing the gateways
  effectively allows anything that can reach the VIP, on the listed ports only.
- **`externalTrafficPolicy: Local` is the exception** — it preserves the real
  client address, so those Services need explicit source rules. In this cluster
  that is `kube-system/traefik` and `stalwart/stalwart-stalwart`.
- **Router export line endings depend on the caller.** Through
  `mikrotik-connect` (pty) RouterOS returns CRLF; without a pty it returns LF.
  `network-configs/check-drift.sh` normalises before comparing, otherwise every
  line "differs" on a clean router.
- **No IPv6 pod traffic exists** (0 conntrack entries for `fd42:42:42::/56` or
  `fd00:6::/64`), and the Service CIDR is IPv4-only while 21 LoadBalancer
  Services carry dual-stack VIPs. NetworkPolicy ipBlocks are per-family, so an
  absent IPv6 rule is a deny; today that denies nothing real, but introducing
  IPv6 pod traffic would need mirror rules.

## Written and committed, not yet deployed

- **PostgreSQL `pg_hba` narrowing** in `dotfiles/nixos/closet-configuration.nix`
  (allow `10.99.0.0/24`, `192.168.5.0/24`, `127.0.0.1/32`, `::1/128`; no
  pod-CIDR row needed). It needs a closet rebuild, which is owner-run. After it
  lands, check `pg_stat_ssl` joined to `pg_stat_activity`: if every tunnel
  connection shows `ssl=t`, flip `10.99.0.0/24` to `hostssl` and add a
  `hostnossl` reject above it; if any is false, leave it as `host` and record
  that TLS was not enforced.
- **UniFi MongoDB credentials** must move from literals in git to OpenBao
  (`john2143-com/default/unifi-mongo-creds`). The ExternalSecret is not written
  yet and the controller stays at `replicas: 0` until it is Ready.
- **Pi-hole as the single DNS source** and the router-edge phases below.

## Router edge design (not executed)

The goal is that a withdrawn MetalLB VIP fails closed instead of degrading to an
ARP race, and that the router's management surface is not reachable from every
flat-bridge device. The MetalLB pool is `192.168.6.10-192.168.6.200` +
`fd00:6::10-fd00:6::ff`; `192.168.7.0/24` + `fd00:7::/64` are reserved for a
nonprod cluster.

Order matters and the connected address is removed **last**:

1. Preconditions, all read-only and all required: exactly one
   `192.168.6.1/24` row on `bridge`; no complete/reachable ARP entry for
   `192.168.6.*`; both DHCP networks listed; and active BGP `/32`s for **every
   allocated VIP** — at minimum `.6.11` (Traefik), `.6.13` (mail), `.6.27`
   (Pi-hole). A missing VIP route aborts the step; BGP repair is not improvised
   inside a maintenance window.
2. Add the fail-closed aggregates first (four routes: `192.168.6.0/24`,
   `192.168.7.0/24`, `fd00:6::/64`, `fd00:7::/64`, `type=unreachable
   distance=250`). The connected route stays preferred while it exists and the
   more-specific BGP `/32`s override after it is gone.
3. Attach a unique comment to the connected address row
   (`service-pool-connected-remove-20260918`), verify it matches exactly one row
   with address `192.168.6.1/24` on `bridge`, then remove **by that comment**.
4. Rollback if any post-check fails: `/ip address add
   address=192.168.6.1/24 interface=bridge comment="rollback: service pool
   connected"`. The connected route overrides the aggregates, so the aggregates
   do not need removing in an emergency.

Management surface: disable `ftp`, `telnet`, `api`, `api-ssl` one at a time
(retain `www` for the recovery path), then bind `ssh`, `winbox` and `www` to
`192.168.5.0/24,192.168.1.250/32`. Remove the `192.168.1.250/32` allow and the
core switch's `192.168.1.250/24 temp-recovery` address only after all router and
DNS work passes **and** MAC-Winbox or serial access is proven; otherwise keep
them and say so.

Camera containment is interim until the VLAN work: all six rules go
**immediately before** the exact `chain=forward comment="allow inter-subnet
routing"` rule, never by `move` or a row number. The broad inter-subnet accept is
the first forward rule, so anything placed after it is already bypassed.

Constants a nonprod cluster must use (do not collide with prod):
MetalLB `192.168.7.10-192.168.7.200` + `fd00:7::10-fd00:7::ff`; API VIP
`192.168.5.11` (verify free first — `.10` is prod's); node AS `65002` (prod is
`65000`), peer AS `65001` at `192.168.5.1`; no connected route for
`192.168.7.0/24` — the announcement plus the aggregate is the whole routing
story; and disjoint internals: prod uses pod `10.42.0.0/16` + service
`10.43.0.0/16` + `fd42:42:42::/56`, so nonprod must use `10.44.0.0/16`,
`10.45.0.0/16` and a distinct cluster domain.

## DNS design (not executed)

Today three sources drift: RouterOS static records, the CoreDNS hosts blob in
`dotfiles/nixos/closet-configuration.nix`, and Headscale `extra_records`. The
target is Pi-hole as the shared resolver with records derived from the public
zones.

Pi-hole v6 API facts verified against the pinned instance's own
`/api/docs/specs/`: authenticate with `POST /api/auth` and send the SID in
either the `sid` or `X-FTL-SID` header; host records are individual array items,
`PUT|DELETE /api/config/dns/hosts/<url-encoded-value>` (`PUT` → 201, and **400
`item_already_present`** if the entry exists, which the generator must treat as
success; there is no array-body `PUT`). The migration is additive-first: publish
every desired record, verify the complete set, and only then delete stale names
under `john2143.com`, `2143.me` or `router.lan`. `192.168.5.1 router.lan` is a
required invariant. A generator failure must retain the previous answers.

Cutover order: Pi-hole populated and proved by direct query → CoreDNS → Headscale
→ one workstation canary → one DHCP subnet at a time (router DNS stays
advertised as the second resolver, and one lease interval elapses between
subnets) → forced-DNS redirect rules enabled one protocol at a time → remove the
hard-coded WAN trust from `clientTrustedIps`. Break glass: disabling the two
exact forced-DNS comments, DHCP networks back to `192.168.5.1`, router upstreams
back to `1.1.1.1,1.0.0.1`.

## Deferred deliberately

- **Native IPv6.** Today the LAN uses ULA `fd00:1::/64` with one NAT66 masquerade
  and no DHCPv6 prefix client. Enabling SLAAC first would give the Reolink and
  Wyze cameras GUA egress and bypass the IPv4 camera containment, so it waits
  until the delegated prefix, camera/IoT containment, a stable interface-ID for
  pite and unique ND/NAT66 selectors are all proven.
- **Dual-WAN failover.** The backup CPE is not connected, `ether6` is down and
  unused, and the backup interface, gateway, subnet and passthrough behaviour are
  unknown. Changing the active default route or the sole masquerade rule on those
  unknowns is not acceptable on a network that carries the only management path.
- **VLAN migration** (`192.168.10/30/40/50/60`) — designed in the plan, not
  started. The routers and switches all run `vlan-filtering=no`, so the subnets
  are labels rather than boundaries.
- **Switch NTP** — owner-handled separately. The four switches' clocks run months
  behind; that is expected and does not affect the drift check, which compares
  content, not dates.

## Retained on purpose

- The router's invalid `10.99.0.1/24 interface=*C` address row. The live row has
  the same address, so an address selector matches both and a numeric removal has
  unacceptable blast radius. It is inert, and `check-drift.sh` tolerates it.
- `before-hardening-20260917.backup` on the router — archive only. Loading it
  would also revert the verified firewall, NAT and WireGuard changes.
- The broad Verizon-LAN accept (`192.168.0.0/16 → 192.168.0.0/16`) and the public
  `status.2143.me` page, both by explicit owner decision. Do not tidy them as a
  side effect of another change.
- `mongo.john2143.com` still resolves through the wildcard `CNAME` to the home
  public IP even after the specific `mongo/A` record was deleted, so the name
  resolving is not evidence that the record exists. Do not delete the wildcard.

## Accepted risks

- The UniFi MongoDB password was public and is **not rotated**; moving the
  literal to OpenBao does not change that.
- The router admin password appeared in a recovery transcript and must be rotated
  by the owner before further router work.
- Cluster policies do not yet cover `default`, so a workload there can still
  reach other namespaces' pods; `default` also hosts the LAN/IoT integrations
  that make it the hardest namespace to isolate.

## Owner-held blockers

1. **Close the public MongoDB NodePort.** The DO cloud firewall still admits
   `tcp/32040` from `0.0.0.0/0` (see the MongoDB section above for the exact
   command and the re-check). This one is a live internet-facing database, so
   it outranks everything else here.
2. Closet `nixos-rebuild switch` for the `pg_hba` narrowing (and, separately,
   the CoreDNS change once Pi-hole is populated).
3. OpenBao writes: `john2143-com/default/unifi-mongo-creds`,
   `john2143-com/default/pihole-api`, and a read-only deSEC token at
   `john2143-com/default/dns-sync-desec`.
4. Rotate the router admin password and prove both authenticated management
   paths before any further RouterOS mutation.
