# LAN and cluster DNS (`lan-dns`)

**Status:** stage 1 (LAN clients) live since 2026-10-11 (UTC). Stage 2 (pods) is
pending on board card #23 ("LAN DNS stage 2", 2143 Labs AI Tasks; stage 1 was
#22), gated on a clean 7-day soak, read on or after 2026-10-18T02:15Z: no
failovers in Loki, both lan-dns pods `2/2`, `check-lan-dns.sh 192.168.5.1` exits 0.

## Contract

A hostname on an HTTPRoute or TLSRoute attached to `shared-gateway`, inside one
of the six zones below, resolves to the gateway address `192.168.6.11` for LAN
clients within about 90 s of the route being applied (route informer, plus
`cache 30` in lan-dns, plus at most 60 s in the router cache). Pods get the same
after stage 2. Nothing else to do.

Zones: `2143.me`, `john2143.com`, `aross.studio`, `balabusta.homes`,
`chess.dsstar.us`, `mm.b.hero.rehab`.

## Resolution paths

| Client | Resolves via | Behavior |
|---|---|---|
| LAN client | DHCP → router `192.168.5.1` → `/ip dns static` FWD entries (`comment="lan-dns forward"`) for the six zones → `lan-dns` `192.168.6.30` | Other names: router upstream `1.1.1.1`. If lan-dns stops answering, netwatch disables the forwards and these zones resolve publicly until it recovers |
| Pod | **Stage 2, pending:** kube-dns `10.43.0.10` → `coredns-custom` (dotfiles). `split-horizon.server` will send the six zones to `192.168.6.30`; `ts.2143.me` is carved out to MagicDNS (`/etc/resolv.conf` → `100.100.100.100`). Until then pods use the hand-kept `hosts.split-horizon` | Public zones fall back to `1.1.1.1` if lan-dns is unreachable. `.ts` route names come from headscale `extra_records`. Tailnet machine names (`nas.ts`, `office.ts`) resolve to their `100.64.` addresses, which Longhorn backups (`nfs://nas.ts.2143.me`) and llm-proxy (`office.ts.2143.me:11434`) depend on |
| Tailnet device | MagicDNS `100.100.100.100` → headscale | `.ts.2143.me` via `extra_records` (hand-kept, `workloads/headscale/configmap.yaml`); everything else public (hairpin). Unchanged by design |
| Node shell (closet, nas, …) | `100.100.100.100` | Public (hairpin) |
| Browser with DNS-over-HTTPS | Its own resolver | Bypasses all of this (hairpin) |

## What lan-dns answers

`workloads/lan-dns/` runs CoreDNS with the `k8s_gateway` plugin
(`ghcr.io/k8s-gateway/k8s_gateway:1.8.2`, 2 replicas) behind the LoadBalancer
`192.168.6.30` / `fd00:6::30`. The Corefile is `workloads/lan-dns/configmap.yaml`.

- Only **A** queries in the six zones reach the zone block. Inside it the `hosts`
  block wins, then route hostnames (`k8s_gateway`, `resources HTTPRoute TLSRoute`,
  address from the Gateway's `status.addresses`). No match falls through to
  `1.1.1.1`.
- Every other query type and zone goes to `1.1.1.1`/`1.0.0.1`. That is why MX,
  TXT and AAAA answers match public DNS.
- Why A only: for a routed name `k8s_gateway` answers authoritative NODATA on
  MX/TXT, which would hide `john2143.com`'s SPF and `m.2143.me`'s MX from
  Stalwart. AAAA stays public so the LAN gets no IPv6 answers for these names, as
  before.
- Answer TTL is at most 60 (`cache 30` caps it at 30 in practice). On the router,
  an answer with TTL ≤ 60 came from lan-dns; larger TTLs are public answers.

### The zone list lives in four places

1. The zone line after `# lan-dns-zones` in `workloads/lan-dns/configmap.yaml`.
2. The `k8s_gateway` line in the same file. CI
   (`scripts/validate-lan-dns-zones.sh`) checks that 1 and 2 match and that every
   route hostname in the repo is inside a zone.
3. The router FWD entries (`comment="lan-dns forward"`).
4. Dotfiles `coredns-custom` `split-horizon.server` (from stage 2 on).

## How to

- **New route in an existing zone:** nothing.
- **New `.ts.2143.me` name:** also add headscale `extra_records`
  ([adding-a-workload.md](adding-a-workload.md) §3c). Tailnet clients **and pods**
  read `.ts` names from it; LAN clients get route names automatically.
- **New domain:**
  1. Add it to places 1 and 2.
  2. On the router:
     `mikrotik-connect r '/ip dns static add name=<zone> type=FWD forward-to=192.168.6.30 match-subdomain=yes comment="lan-dns forward"'`.
     `match-subdomain=yes` also covers the zone apex (verified 2026-10-11).
  3. After stage 2: dotfiles place 4, then the owner rebuilds closet and deletes
     the `kube-system` coredns pods one at a time (`reload` does not notice
     imported files).
- **Non-HTTP LoadBalancer name** (mail, gRPC): add a line to the `hosts` block in
  `workloads/lan-dns/configmap.yaml` and keep it in sync with the Service's LB IP.
- **Name whose LAN answer must be the public one:** label **every** route that
  lists the hostname with `k8s-gateway.dns/ignore: "true"` and a reason comment.
  One unlabelled route carrying the same hostname still makes lan-dns answer
  `.6.11`. Find them with
  `kubectl --context closet-as-admin get httproute,tlsroute,grpcroute -A -o yaml | grep -n '<name>'`.

### Exceptions

| Name | Answer | Why | Where |
|---|---|---|---|
| `imap.m.2143.me`, `smtp.m.2143.me` | `192.168.6.13` | Not routes (Stalwart LB) | `hosts` block |
| `temporal-grpc.john2143.com` | `192.168.6.20` | Its TLSRoute hands TLS to a plaintext frontend and cannot work | `hosts` block + ignore label |
| `factorio.john2143.com` | public | Also the UDP 34197 game address (router dst-nat → `.6.28`); one A record can't serve both | ignore label |
| `turn.john2143.com` | public | steam-lobby coturn resolves it via kube-dns to learn its public `external-ip` | ignore label |

## Which devices it covers

| Devices | Covered? |
|---|---|
| Anything using DHCP DNS (router `192.168.5.1`) | Yes, automatically; no client change |
| Tailscale devices (office, all k3s nodes, phones or laptops with Tailscale on) | No: MagicDNS → `1.1.1.1`; they hairpin. Unchanged |
| Hardcoded resolvers seen in conntrack: `eight-pod` (→ `1.1.1.1`), `192.168.5.8` (→ `8.8.8.8`), `2LM6LY3` (→ `204.14.183.1`) | No; they hairpin. Unchanged |
| Browsers with DNS-over-HTTPS, Android Private DNS | No; they hairpin. Unchanged |
| IPv6 DNS | The router used to pass Verizon's `2600:4040:25fc:8d00::1` (public answers) to LAN devices in RAs and DHCPv6. Since 2026-10-11 RAs carry no DNS (`/ipv6 nd advertise-dns=no`) and DHCPv6 `ula-dhcp` hands out `fd00:1::1` (option `dns-router-ula`, code 23). Clients pick it up at their next renew (lease 3 d) |
| DNSSEC-validating stubs | Reject any split answer for the five signed zones (`hero.rehab` is unsigned); same as before |

## Availability design

- **Readiness is a real lookup.** The `ready-probe` sidecar (busybox) runs
  `nslookup -type=a john2143.com 127.0.0.1:1053` every 10 s and is Ready only if
  the answer is a `192.168.` address. `k8s_gateway` SERVFAILs until its informers
  sync and has no readiness hook of its own, so without the sidecar a pod could be
  Ready and answer nothing. `john2143.com` is the HTTP→HTTPS redirect route
  (`default/john2143-http-to-https`); if that route ever disappears, every pod goes
  unready, MetalLB stops announcing `.30`, and the router fails over (below).
- **2 replicas on different nodes** (required anti-affinity), `maxUnavailable: 0`,
  PDB `minAvailable: 1`.
- **Router failover.** Netwatch `lan-dns` resolves `john2143.com` via
  `192.168.6.30` every 10 s (timeout 3 s). On failure, script `lan-dns-down`
  re-checks 3 times (2 s apart), then disables the `lan-dns forward` entries,
  flushes the cache and logs `lan-dns down: LAN forwards disabled` (topic
  warning). LAN clients then get public answers. On recovery `lan-dns-up`
  re-enables them and logs `lan-dns up: LAN forwards enabled`. Worst case, LAN
  lookups in the zones fail for about 35 s before failover. There is no
  `ignore-initial-up`, so after a router reboot the initial "up" re-enables the
  forwards.
- **Alerts** (`workloads/observability/grafana-dashboards/lan-dns-alerts.yaml`):
  `lan-dns-replicas` (fewer than 2 available pods for 5 min) and
  `lan-dns-failover` (any `lan-dns down` warning from the router in 15 min).
- **No NetworkPolicy.** The per-node SNAT `ipBlock` list used by the covered
  namespaces would turn a node addition or podCIDR change into silent partial loss
  of LAN DNS. Recorded in `workloads/network-policies/00-pattern.yaml`.

## Debugging runbook

Run from office in `~/repos/argo`, in this order.

1. **Which resolver is wrong?**
   ```
   nix develop -c ./scripts/check-lan-dns.sh 192.168.5.1
   nix develop -c ./scripts/check-lan-dns.sh 192.168.6.30
   nix develop -c ./scripts/check-lan-dns.sh 10.43.0.10
   ```
   LAN, then lan-dns itself, then pods. Exit 0 means every row is OK; the first
   resolver that fails localizes the fault. (Pods show MISMATCHes until stage 2.)
2. **Is lan-dns up?**
   `kubectl --context closet-as-admin -n lan-dns get deploy,pod,svc -o wide`:
   pods `2/2` Ready, EXTERNAL-IP `192.168.6.30,fd00:6::30`.
   `kubectl --context closet-as-admin -n lan-dns logs deploy/lan-dns -c coredns`
   (only errors are logged). To see every query, change `class error` to
   `class all` in the zone block of `workloads/lan-dns/configmap.yaml`, commit and
   push; `reload` applies it within about a minute with no restart. Revert with a
   second commit; it is noisy, because the router forwards every LAN lookup in
   these zones.
3. **Probe from outside the cluster:**
   `mikrotik-connect r ':put [:resolve tasks.2143.me server=192.168.6.30]'`
   must print `192.168.6.11`. Use the router, not `dig` on office or pite: those
   are k3s nodes, so `dig @192.168.6.30` from them goes through their own
   kube-proxy and proves nothing about the BGP path. The router's `:resolve`
   against v6 VIPs (`server=fd00:6::30`, and other `fd00:6::` VIPs) fails with
   `dns server failure`; that is not a lan-dns fault.
4. **Is the name a route?**
   `kubectl --context closet-as-admin get httproute,tlsroute -A -o wide | grep <name>`.
   Its `parentRefs` must name `shared-gateway` with `namespace: default` (an
   omitted namespace means the route's own namespace), and it must not carry
   `k8s-gateway.dns/ignore`.
5. **Router side:**
   - `mikrotik-connect r '/ip dns static print terse where comment="lan-dns forward"'`:
     6 entries. An `X` flag means they are disabled, i.e. failed over.
   - `mikrotik-connect r '/tool netwatch print detail where name="lan-dns"'`: `status`.
   - Failover history in Loki: `{job="mikrotik", level="warning"} |= "lan-dns"`.
     Keep `level="warning"`: the router's info-level audit line for any script
     edit echoes the script source, which contains the same text.
   - Then `mikrotik-connect r '/ip dns cache flush'`.
   - Selecting a static A record by name needs `and type=A`
     (`[find name="john2143.com" and type=A]`); a bare `find name=` also matches
     the FWD entry for the zone apex.
6. **Pod side (after stage 2):**
   `kubectl --context closet-as-admin -n kube-system get cm coredns-custom -o yaml`
   shows the forward. If it was just changed, delete the coredns pods one at a
   time.
7. **Readiness:** a pod at `1/2` is running but cannot answer `john2143.com` from
   routes. See why with
   `kubectl --context closet-as-admin -n lan-dns exec <pod> -c ready-probe -- nslookup -type=a john2143.com 127.0.0.1:1053`.
8. **Metrics and alerts:** Grafana → Alerting shows `lan-dns-replicas` and
   `lan-dns-failover`. Mimir:
   `sum by (rcode) (rate(coredns_dns_responses_total{instance="lan-dns-metrics.lan-dns.svc:9153"}[5m]))`
   (SERVFAIL is the alarm).
9. **Emergency: force public answers by hand.** Disable netwatch first, or the
   up-script re-enables the forwards as soon as lan-dns answers:
   ```
   mikrotik-connect r '/tool netwatch disable [find name="lan-dns"]'
   mikrotik-connect r '/ip dns static disable [find comment="lan-dns forward"]'
   mikrotik-connect r '/ip dns cache flush'
   ```
   Undo with `enable` on both, in reverse order.

   **Full rollback to static records:**
   1. `mikrotik-connect r '/tool netwatch remove [find name="lan-dns"]'`, then
      `/system script remove [find name="lan-dns-down"]` and
      `[find name="lan-dns-up"]`.
   2. `mikrotik-connect r '/ip dns static remove [find comment="lan-dns forward"]'`.
   3. Re-add one A record per route hostname (`192.168.6.11`, `ttl=1d`), plus
      `imap.m.2143.me`/`smtp.m.2143.me` → `192.168.6.13` and
      `temporal-grpc.john2143.com` → `192.168.6.20`. The pre-cutover export had 55
      names; `check-lan-dns.sh 192.168.5.1` confirms the result.
   4. `mikrotik-connect r '/ip dns cache flush'`.

## Known limits

- While failed over, LAN clients get public answers: `.ts` names, the mail names
  and `temporal-grpc` do not resolve usefully on the LAN; everything else
  hairpins through the WAN.
- After stage 2, pods fall back to public answers silently if lan-dns is
  unreachable.
- `k8s_gateway` resolves gateways from `spec.parentRefs`, not `status.parents`,
  so a route the gateway rejected still resolves.
- Routes inside Helm values strings (e.g. `apps/openbao.yaml`) are not CI-checked.
- Metrics come from one pod per scrape (one target behind a ClusterIP).
- The alerts notify nobody until a Grafana contact point is provisioned; they show
  in Grafana → Alerting only. `lan-dns-failover` was verified to evaluate cleanly
  but has not yet fired for real.
- Readiness and netwatch both depend on the `john2143.com` route existing.
- Netwatch counts a timeout as down (drilled); whether it counts SERVFAIL is
  untested. A full outage shows up as a timeout because MetalLB withdraws `.30`
  when no pod is Ready.
- Tailnet DNS is still hand-kept for `.ts.2143.me` (headscale `extra_records`).

## History

- 2026-10-11 (UTC): `lan-dns` deployed (`a3097cd`; alert fix `e1bc8ba`). The
  router's IPv6 DNS hand-out was fixed (RA `advertise-dns=no`, DHCPv6 option
  `dns-router-ula`). The router's 55 static A records were replaced by 6
  `lan-dns forward` FWD entries with netwatch failover.
- Before/after on the router: `check-lan-dns.sh 192.168.5.1` went from 1
  MISMATCH (`factorio.john2143.com` answered `.6.11`) to 0. Of the 55 removed
  names, 52 answer exactly as before; `factorio.john2143.com` now resolves
  publicly on purpose.
- `rots.2143.me` and `prod.rots.2143.me` now resolve publicly (dead
  `174.138.108.28`) because no route serves them; before, they reached a Traefik
  404.
- Pods: 14 MISMATCHes against `10.43.0.10` at cutover (names missing from
  `hosts.split-horizon`). Stage 2 is pending on its follow-up card; CoreDNS still
  uses `hosts.split-horizon` until then.
