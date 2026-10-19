# Internet edge: Verizon → MikroTik → MetalLB

How a packet from the internet reaches a pod, what has to be configured for a new
public port, and how to get back into the router when something breaks. The
forward tables below are the record of state that lives on the two routers, not
in this repository: update them in the same change that edits a router.

## Path

```
internet → 108.56.153.222 (Verizon CR1000B, 192.168.0.1)
  └─ per-port forward → 192.168.0.2 (MikroTik RB5009, interface 2GWAN)
       └─ dst-nat (comment "<service> (<proto>/<port>) -> .6.X") → 192.168.6.X
            └─ BGP /32 from MetalLB (one active next-hop) → node → kube-proxy → pod
```

- **The Verizon router is not a DMZ.** It forwards only the ports listed below.
  On 2026-10-16 external probes to unlisted ports (TCP/UDP 40404, and UDP 3479
  before it was added) never reached the MikroTik.
- **Every public port needs both layers:** a Verizon forward to `192.168.0.2` and
  a MikroTik dst-nat to the service's `.6.x` address. A port with only one of
  them is closed.
- `home-pi` (`192.168.0.154`) sits on the Verizon LAN beside the MikroTik, so its
  forward bypasses the MikroTik.
- There is no inbound IPv6 path. LAN devices reach the internet over IPv6 only
  through NAT66 on the MikroTik.
- LAN clients resolve public names straight to the gateway (see
  [lan-dns.md](lan-dns.md)); hairpinning through Verizon is only the fallback.

## Public ports (live 2026-10-16)

Verizon forwards every entry for TCP and UDP ("Both") unless noted; the MikroTik
dst-nats only the protocol the service uses and drops the other. The `.6.x`
addresses and services are owned by [adding-a-workload.md](adding-a-workload.md) §5.

| Verizon entry | WAN port | MikroTik rule (comment) | Target | Service |
|---|---|---|---|---|
| web, web3 | 80, 443 | `ingress http (tcp/80) -> traefik VIP (ingress-follow)`, `ingress https (tcp/443) -> traefik VIP (ingress-follow)` | ingress VIP (`.6.6`; kept current by router script `ingress-follow`) | Traefik (`shared-gateway`) |
| mail-smtp, mail-submission, mail-imap | 25, 587, 993 | `mail-smtp (tcp/25) -> .6.13` and the 587/993 twins | `.6.13` | stalwart |
| Coturn TURN | 3478 | `steam-lobby coturn TURN (tcp/3478) -> .6.14`, `… (udp/3478) …` | `.6.14` | steam-lobby/coturn |
| p2p relays | 45000-45063 | `steam-lobby coturn relay (udp/45000-45063) -> .6.14` | `.6.14` | steam-lobby/coturn relay range |
| headscale stun | 3479 | `headscale stun (udp/3479) -> .6.18` | `.6.18` | headscale embedded DERP STUN |
| (9987 entry) | 9987 | `teamspeak voice (udp/9987) -> .6.15` | `.6.15` | ts-voice |
| ts-files | 30033 | `teamspeak file transfer (tcp/30033) -> .6.16` | `.6.16` | ts-files |
| rct2 | 11753 | `openrct2 (tcp/11753) -> .6.17` | `.6.17` | openrct2 (scaled to 0: no answer, see fail-closed below) |
| LiveKit WebRTC TCP (TCP only) | 7881 | `livekit webrtc tcp (tcp/7881) -> .6.22` | `.6.22` | matrix/livekit-server-rtc |
| factorio | 34197 | `factorio (udp/34197) -> .6.28` | `.6.28` | factorio-game |
| mc | 25565 | `minecraft (tcp/25565) -> .6.29` | `.6.29` | minecraft-game |
| monero | 18080 | `monero p2p (tcp/18080) -> .5.76` | `192.168.5.76` | Monero on arch (bare metal) |
| wg | 51820 | none: input rule `wireguard remote access` | the router | `wg-remote` tunnel to the DigitalOcean cluster |
| attic local | 8280 | none (goes to home-pi) | `192.168.0.154` | Attic cache used by the Hetzner nodes |
| minecraft enigmatic skies | 25555 → 32565 | **none** | — | **dead**: nothing forwards 32565; remove it from Verizon |

Every other `.6.x` service has no WAN path by design (LAN and tailnet only),
including matrix coturn `.6.21` and LiveKit's `50000/udp`; public Matrix media
uses TURN over TLS on 443.

Verified 2026-10-16 from check-host.net: TCP 80, 443, 587, 993, 3478, 7881, 8280,
18080, 25565 and 30033 connect from 3 of 3 nodes, and TCP 25 from 2 of 3; UDP
3478, 3479, 9987, 34197, 45000 and 51820 reach the MikroTik.

## Adding a public port

1. Give the service a pinned `.6.x` address ([adding-a-workload.md](adding-a-workload.md) §5).
2. Check that no existing MikroTik dst-nat range already covers the port: a
   covering range steals the packet before anything else sees it.
   ```
   mikrotik-connect r '/ip firewall nat print terse where chain=dstnat'
   ```
3. MikroTik, with a unique comment in the pattern above:
   ```
   mikrotik-connect r '/ip firewall nat add chain=dstnat action=dst-nat in-interface-list=WAN protocol=<udp|tcp> dst-port=<port> to-addresses=192.168.6.X to-ports=<port> comment="<service> (<proto>/<port>) -> .6.X"'
   ```
4. Verizon admin UI: forward the port to `192.168.0.2`, same port.
5. Prove it from outside (next section), then add a row to the table above.

Removing a port is the reverse: Verizon entry, MikroTik rule (select it by its
exact comment, never by row number), table row.

## Proving reachability from outside

A test from a home machine proves nothing about the WAN path, and `ping` to the
WAN address always fails (ICMP is filtered upstream).

- TCP: `curl -s -H 'Accept: application/json' 'https://check-host.net/check-tcp?host=108.56.153.222:<port>&max_nodes=3'`,
  then fetch `https://check-host.net/check-result/<request_id>`. A result with an
  `address` field connected.
- UDP: check-host's own UDP verdicts are useless, but its packets are real. Read
  the MikroTik rule's counter before and after a `check-udp` request:
  `mikrotik-connect r ':put [/ip firewall nat get [find comment="<comment>"] packets]'`.
- check-host rate-limits (`{"error":"limit_exceeded"}`) after roughly a dozen
  requests in a few minutes; space them out.

## Router behaviour around the edge

- **Unannounced `.6.x` addresses fail closed.** The router has blackhole routes
  (distance 250, comments starting `fail-closed:`) for `192.168.6.0/24`,
  `192.168.7.0/24`, `fd00:6::/64` and `fd00:7::/64`. A VIP that MetalLB does not
  announce (no Ready endpoints, e.g. openrct2) is dropped instead of being ARPed
  on the bridge. MetalLB's `/32` and `/128` routes override them. Rollback, if a
  `.6.x` address must ever be on the bridge again:
  `/ip address add address=192.168.6.1/24 interface=bridge comment="rollback: service pool connected"`.
- **WAN 80/443 follow the cluster.** Script `ingress-follow` (source
  `dotfiles/network-configs/scripts/ingress-follow.rsc`), run every minute by the
  `test-script` of netwatch `ingress-follow`, resolves `john2143.com` through the
  router's DNS and rewrites both dst-nat rules when the answer (inside
  `192.168.6.0/24`) differs. Never edit those two rules' targets by hand; the
  script reverts them within a minute.
- **Traefik's address is pinned in dotfiles**, not in this repo: the k3s
  HelmChartConfig in `dotfiles/nixos/closet-configuration.nix` sets
  `metallb.io/loadBalancerIPs: "192.168.6.11,fd00:6::10"`. It must list both
  families. A v4-only value on a dual-stack Service makes MetalLB release the
  address, which took every public site down on 2026-10-15 and 10-16.

## Router access and recovery

- Management services: only SSH (22) and Winbox (8291) are enabled. Telnet, FTP,
  web/REST (8081), the API ports and the bandwidth-test server are disabled. To
  re-enable REST in an emergency: `/ip service enable [find name="www" and !dynamic]`.
- None of the MikroTiks has a serial console, and USB is a host port only.
  Recovery, in order:
  1. Winbox or SSH by IP.
  2. Winbox by MAC from any LAN port (works with broken IP settings).
  3. Reset button: the device comes up at `192.168.88.1`, which the LAN reaches
     through the router's `192.168.88.254`.
  4. Netinstall over Ethernet.
- RouterOS changes: select objects by exact comment or name, never by row number
  (`2026-09-17-network-hardening.md` records the outage that rule comes from).
  `/system scheduler` is blocked by device-mode `home`; for a timed rollback, run
  a named script with `:execute` that waits and then checks a flag.

## History

- 2026-10-11: removed the MikroTik `4143 → closet` forward (no linkerd);
  disabled the management services listed above.
- 2026-10-13: headscale STUN moved to UDP 3479 (`800adae`, `5992c84`; MikroTik
  and Verizon forwards added); `192.168.6.1/24` replaced by the fail-closed
  routes; Pi-hole retired, which freed `.6.27`.
- 2026-10-15/16: two Traefik outages from the v4-only annotation, fixed in
  dotfiles `d5a830f`.
- 2026-10-16: Verizon entries with no MikroTik counterpart removed (5432, 5999,
  4143, 5349, 7233, 8080, 30478, 50000-60000); UDP 51820 got its own entry
  (before, it only worked because the 50000-60000 range covered it).
