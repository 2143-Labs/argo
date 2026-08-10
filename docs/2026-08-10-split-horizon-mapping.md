# Split-horizon DNS mapping (2026-08-10)

Derived from: `kubectl get httproute -A`, `kubectl get gateway shared-gateway`,
live dst-nat (`mikrotik-connect r '/ip firewall nat print where chain=dstnat'`),
and public DNS probes (`dig @1.1.1.1`).

## Ground truth

- All 34 HTTPRoute hostnames bind to `shared-gateway` (traefik LB `192.168.6.11`).
- Public DNS: `*.ts.2143.me` + `rots.*` resolve to `174.138.108.28` (dead Hetzner
  endpoint — no TLS response). Everything else resolves to home WAN
  `108.56.153.222` (hairpin + masquerade → the CrowdSec ban incidents).
- Home cluster serves every `ts.*` / `rots.*` name (probed 200/403/503/404 via
  `.6.11`). Tailnet MagicDNS already maps `*.ts.2143.me` → `.6.11`.
- Non-HTTP protocols (mail, temporal gRPC, STUN, livekit media) use dedicated LBs
  by IP in client configs; only `m.2143.me` (mail) and `temporal-grpc.john2143.com`
  (gRPC) are DNS-resolved hostnames in that category.

## Mapping (all → 192.168.6.11 unless noted)

| Hostname | Internal IP | Notes |
|---|---|---|
| argocd.ts.2143.me | 192.168.6.11 | |
| au.2143.me | 192.168.6.11 | pocket-id |
| cameras.ts.2143.me | 192.168.6.11 | frigate-genai internal |
| cams.ts.2143.me | 192.168.6.11 | frigate |
| chat.2143.me | 192.168.6.11 | heorot |
| files-ui.ts.2143.me | 192.168.6.11 | seaweedfs filer UI |
| home.ts.2143.me | 192.168.6.11 | home-assistant |
| images.2143.me | 192.168.6.11 | immich proxy |
| immich.ts.2143.me | 192.168.6.11 | |
| llm.2143.me | 192.168.6.11 | litellm |
| longhorn.ts.2143.me | 192.168.6.11 | |
| m.2143.me | **CHOICE** | mail `.6.13` vs webmail `.6.11` |
| matrix.2143.me | 192.168.6.11 | tuwunel |
| net.2143.me | 192.168.6.11 | headscale |
| pihole.ts.2143.me | 192.168.6.11 | |
| prod.rots.2143.me | 192.168.6.11 | webserver |
| rots.2143.me | 192.168.6.11 | webserver |
| status.2143.me | 192.168.6.11 | pite-status backend via traefik |
| temporal.ts.2143.me | 192.168.6.11 | |
| unifi.ts.2143.me | 192.168.6.11 | |
| argo-webhook.john2143.com | 192.168.6.11 | |
| auth.john2143.com | 192.168.6.11 | |
| cameras.john2143.com | 192.168.6.11 | frigate-genai public |
| containerstore.john2143.com | 192.168.6.11 | docker-registry |
| element.john2143.com | 192.168.6.11 | |
| files.john2143.com | 192.168.6.11 | seaweedfs S3 |
| grafana.john2143.com | 192.168.6.11 | |
| john2143.com | 192.168.6.11 | apex |
| livekit.john2143.com | 192.168.6.11 | signaling; media by IP |
| mattermost.john2143.com | 192.168.6.11 | |
| net.john2143.com | 192.168.6.11 | headscale |
| pvp.john2143.com | 192.168.6.11 | steam-lobby |
| seafile.john2143.com | 192.168.6.11 | |
| temporal.john2143.com | 192.168.6.11 | |
| temporal-grpc.john2143.com | **CHOICE** | direct gRPC `.6.20:7233` vs traefik SNI `.6.11:443` |
