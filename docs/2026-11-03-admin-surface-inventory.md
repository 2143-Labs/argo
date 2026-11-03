# Admin surface inventory (2026-11-03)

**Date:** 2026-11-03  
> **Correction 2026-11-03:** `ts-files` no longer exists — its `30033/TCP` moved onto `ts-voice` (`192.168.6.15`), so the LoadBalancer table below lists one TeamSpeak VIP instead of two.

**Context:** the SeaweedFS admin lockdown (filer UI behind oauth2-proxy, `seaweedfs.yaml` ingress policies). This record lists every other admin surface and its auth state. It fixes nothing; the follow-ups are the backlog.

## Method

Data came from `kubectl get httproute,tlsroute,tcproute,grpcroute,svc,networkpolicy -A` and, for each HTTP route's first hostname, one anonymous `curl https://<host>/` pinned to the Traefik VIP (`--resolve <host>:443:192.168.6.6`), so `Reach` is a property of the route's gates, not of where the probe ran. Every LoadBalancer TCP port got one anonymous `curl http://<vip>:<port>/` (a NodePort without a VIP is probed on a node address); UDP ports are not probed. `Auth class`, first match wins: a backend named `oauth2-proxy-*` is `proxy`; a 3xx whose redirect mentions `au.2143.me`, login, signin, oauth, auth or sso is `redirect-login`; 401/403 is `denied-anon`; 200 with a `type="password"` field is `login-form`; any other 200 is `open`; a wildcard route is `wildcard`; HTTP 000 on a LoadBalancer port is `non-http`; anything else is `unreachable-<code>`. Two refinements over a purely mechanical read: a route with no backends only redirects HTTP to HTTPS, so it is `redirect-only` and its probe result belongs to the HTTPS route for the same host; and a backend `nonprod-traefik*` (the nonprod cluster) or `keda-add-ons-http-interceptor-proxy` (scale-to-zero) only hands the request on to the real app, so it does not by itself make a route admin-capable. `Admin-capable` means the route, service or backend name matches a list of known admin or data-plane software (Argo CD, Grafana, Longhorn, Mimir/Loki/Tempo, OpenBao, Temporal, SeaweedFS and similar). `Ingress policed` means a NetworkPolicy with an Ingress rule selects the Service's endpoint pods; a policy elsewhere in the namespace does not count. The probe cannot see logins rendered by JavaScript, so `open` on an app with its own login (Argo CD, Home Assistant, Immich) is a prompt to check by hand, not a finding.

## HTTP routes

| Route | Hostnames | Gates | Backends | Anonymous GET | Auth class | Reach | Admin-capable |
|---|---|---|---|---|---|---|---|
| `argocd/argocd` | `argocd.ts.2143.me` | `lan-only` | `argocd-server:80` | 200 | open | LAN | yes |
| `argocd/argocd-applicationset-webhook` | `applicationset-webhook.john2143.com` | `argocd-applicationset-controller:7000` |  | 404 | redirect-only | internet | yes |
| `argocd/argocd-webhook` | `argo-webhook.john2143.com` | `argocd-server:80` |  | 404 | redirect-only | internet | yes |
| `default/anni` | `anni.2143.me` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `keda-add-ons-http-interceptor-proxy:8080` | 200 | open | internet | no (hand-off) |
| `default/aross-studio` | `aross.studio` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `keda-add-ons-http-interceptor-proxy:8080` | 200 | open | internet | no (hand-off) |
| `default/asciinema` | `terminals.john2143.com` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `asciinema:80` | 200 | open | internet | yes |
| `default/balabusta` | `balabusta.homes` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `keda-add-ons-http-interceptor-proxy:8080` | 200 | open | internet | no (hand-off) |
| `default/balabusta-http-to-https` | `balabusta.homes`<br>`www.balabusta.homes` |  |  | 200 | redirect-only | internet | no |
| `default/balabusta-www-redirect` | `www.balabusta.homes` |  |  | 301 | redirect-only | internet | no |
| `default/bulwark` | `mail.ts.2143.me` | `lan-only` | `bulwark:3000` | 307 | unreachable-307 | LAN | yes |
| `default/casual-docs` | `docs.john2143.com` | `crowdsec-bouncer`<br>`crowdsec-bouncer-noappsec`<br>`public-inflight-limit`<br>`public-rate-limit` | `casual-docs-share:80`<br>`casual-docs:80` | 200 | open | internet | no |
| `default/casual-docs-http-to-https` | `docs.john2143.com` |  |  | 200 | redirect-only | internet | no |
| `default/chat-heorot` | `chat.2143.me` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `keda-add-ons-http-interceptor-proxy:8080` | 200 | open | internet | no (hand-off) |
| `default/chess-dsstar-redirect` | `chess.dsstar.us` |  |  | 302 | redirect-only | internet | no |
| `default/dev-to-nonprod` | `*.dev.john2143.com` | `nonprod-traefik:443` |  | skip | wildcard | internet | no |
| `default/dev-to-nonprod-au` | `au-dev.2143.me` | `nonprod-traefik-2143me:443` |  | 200 | redirect-only | internet | no |
| `default/dino-dash` | `dino.dsstar.us` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `dino-dash-server:80`<br>`keda-add-ons-http-interceptor-proxy:8080` | 200 | open | internet | no |
| `default/dino-dash-http-to-https` | `dino.dsstar.us` |  |  | 200 | redirect-only | internet | no |
| `default/dino-dev` | `dino-dev.dsstar.us` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `keda-add-ons-http-interceptor-proxy:8080` | 200 | open | internet | no (hand-off) |
| `default/dino-dev-http-to-https` | `dino-dev.dsstar.us` |  |  | 200 | redirect-only | internet | no |
| `default/element-web` | `element.john2143.com` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `keda-add-ons-http-interceptor-proxy:8080` | 200 | open | internet | no (hand-off) |
| `default/factorio` | `factorio.john2143.com` | `crowdsec-bouncer` | `factorio-http:80` | 200 | open | internet | no |
| `default/frigate` | `cams.ts.2143.me` | `lan-only` | `frigate-http:5000` | 200 | open | LAN | yes |
| `default/frigate-genai-triggers-internal` | `cameras.ts.2143.me` | `auth-security-headers`<br>`lan-only` | `frigate-genai-dashboard:9090` | 200 | open | LAN | yes |
| `default/frigate-genai-triggers-public` | `cameras.john2143.com` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `oauth2-proxy-cameras:4180` | 403 | proxy | internet | yes |
| `default/grafana-route` | `grafana.john2143.com` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `grafana:80` | 302 | redirect-login | internet | yes |
| `default/headscale` | `net.john2143.com`<br>`net.2143.me` | `headscale:8080` |  | 200 | redirect-only | internet | yes |
| `default/home-assistant` | `home.ts.2143.me` | `lan-only` | `home-assistant:80` | 200 | open | LAN | yes |
| `default/how-poe-sale` | `how.john2143.com`<br>`how.poe.sale` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `how-poe-sale:80` | 200 | open | internet | no |
| `default/how-poe-sale-http-to-https` | `how.john2143.com`<br>`how.poe.sale` |  |  | 200 | redirect-only | internet | no |
| `default/how-pr-5` | `how-5.john2143.com` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `keda-add-ons-http-interceptor-proxy:8080` | 200 | open | internet | no (hand-off) |
| `default/how-pr-5-http-to-https` | `how-5.john2143.com` |  |  | 200 | redirect-only | internet | no |
| `default/how-pr-6` | `how-6.john2143.com` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `keda-add-ons-http-interceptor-proxy:8080` | 200 | open | internet | no (hand-off) |
| `default/how-pr-6-http-to-https` | `how-6.john2143.com` |  |  | 200 | redirect-only | internet | no |
| `default/immich` | `immich.ts.2143.me` | `lan-only` | `immich:80` | 200 | open | LAN | yes |
| `default/immich-proxy` | `images.2143.me` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `immich-proxy:80` | 200 | open | internet | yes |
| `default/john2143-com` | `john2143.com` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `john2143-com:80` | 301 | unreachable-301 | internet | no |
| `default/john2143-com-i-prefix` | `i.john2143.com` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `john2143-com:80` | 200 | open | internet | no |
| `default/john2143-http-to-https` | `john2143.com`<br>`aross.studio`<br>`auth.john2143.com`<br>`anni.2143.me`<br>`element.john2143.com`<br>`files.john2143.com`<br>`i.john2143.com`<br>`home.ts.2143.me`<br>`files-ui.ts.2143.me`<br>`mattermost.john2143.com`<br>`mm.b.hero.rehab`<br>`mm.timestone.2143.me`<br>`mm.timestone.john2143.com`<br>`llm.2143.me`<br>`terminals.john2143.com`<br>`tasks.2143.me` |  |  | 301 | redirect-only | internet | no |
| `default/listen-brick` | `listen.2143.me` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `listen-brick:80` | 200 | open | internet | no |
| `default/litellm` | `llm.2143.me` | `crowdsec-bouncer-noappsec`<br>`public-inflight-limit`<br>`public-rate-limit` | `litellm:4000` | 200 | open | internet | yes |
| `default/livekit-john2143` | `livekit.john2143.com` | `livekit-server:7880` |  | 200 | redirect-only | internet | no |
| `default/matrix-tuwunel` | `matrix.2143.me` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `heorot-voice-relay:8088`<br>`tuwunel-conduwuit:8008` | 200 | open | internet | no |
| `default/mattermost` | `mattermost.john2143.com` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `mattermost:8065` | 503 | unreachable-503 | internet | yes |
| `default/moss-dev` | `moss-dev.dsstar.us` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `keda-add-ons-http-interceptor-proxy:8080` | 200 | open | internet | no (hand-off) |
| `default/moss-dev-http-to-https` | `moss-dev.dsstar.us` |  |  | 200 | redirect-only | internet | no |
| `default/moss-prod` | `moss.dsstar.us` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `keda-add-ons-http-interceptor-proxy:8080` | 200 | open | internet | no (hand-off) |
| `default/moss-prod-http-to-https` | `moss.dsstar.us` |  |  | 200 | redirect-only | internet | no |
| `default/pelican` | `pelican.john2143.com` | `crowdsec-bouncer` | `pelican-http:80` | 503 | unreachable-503 | internet | yes |
| `default/rots-web` | `rots.john2143.com` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `keda-add-ons-http-interceptor-proxy:8080`<br>`rots-authserver:80`<br>`rots-gs-0:80`<br>`rots-gs-1:80`<br>`rots-gs-2:80`<br>`rots-gs-3:80` | 200 | open | internet | no |
| `default/rots-web-http-to-https` | `rots.john2143.com` |  |  | 200 | redirect-only | internet | no |
| `default/seafile` | `seafile.john2143.com` | `crowdsec-bouncer-noappsec`<br>`public-inflight-limit`<br>`public-rate-limit` | `seafile:80` | 302 | redirect-login | internet | yes |
| `default/seaweedfs-filer-ui` | `files-ui.ts.2143.me` | `auth-security-headers`<br>`lan-only` | `oauth2-proxy-seaweedfs-lan:4180` | 403 | proxy | LAN | yes |
| `default/seaweedfs-s3` | `files.john2143.com` | `crowdsec-bouncer-noappsec`<br>`lan-only` | `seaweedfs-s3:8333` | 403 | denied-anon | LAN | yes |
| `default/status-design` | `status.john2143.com` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `status-design:80` | 200 | open | internet | no |
| `default/status-pr-23` | `status-23.john2143.com` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `status-design:80` | 200 | open | internet | no |
| `default/status-pr-24` | `status-24.john2143.com` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `status-design:80` | 200 | open | internet | no |
| `default/status-pr-3` | `status-3.john2143.com` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `status-design:80` | 200 | open | internet | no |
| `default/status-route` | `status.2143.me` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `status-anubis:null` | 200 | open | internet | no |
| `default/steam-lobby` | `pvp.john2143.com` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `steam-lobby:80` | 200 | open | internet | no |
| `default/steam-lobby-mm-joinlobby` | `mm.b.hero.rehab` | `crowdsec-bouncer-noappsec`<br>`public-inflight-limit`<br>`public-rate-limit` | `steam-lobby:80` | 404 | unreachable-404 | internet | no |
| `default/temporal-internal` | `temporal.ts.2143.me` | `auth-security-headers`<br>`lan-only` | `temporal-web:8080` | 200 | open | LAN | yes |
| `default/temporal-public` | `temporal.john2143.com` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `oauth2-proxy-temporal:4180` | 403 | proxy | internet | yes |
| `default/unifi-os-ts-2143` | `unifi.ts.2143.me` | `lan-only` | `unifi-os:11443` | 200 | open | LAN | yes |
| `default/vikunja` | `tasks.2143.me` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `vikunja:80` | 200 | open | internet | yes |
| `kube-system/docker-registry` | `containerstore.john2143.com` | `registry-basic-auth` | `docker-registry:5000` | 401 | denied-anon | internet | yes |
| `longhorn-system/longhorn` | `longhorn.ts.2143.me` | `lan-only` | `longhorn-frontend:80` | 200 | open | LAN | yes |
| `openbao/openbao` | `openbao.ts.2143.me` | `lan-only` | `openbao-active:8200` | 307 | unreachable-307 | LAN | yes |
| `openbao/openbao-public-api` | `openbao.john2143.com` | `crowdsec-bouncer-noappsec`<br>`public-inflight-limit`<br>`public-rate-limit` | `openbao-active:8200` | 404 | unreachable-404 | internet | yes |
| `pocket-id/pocket-id` | `au.2143.me` | `crowdsec-bouncer`<br>`public-inflight-limit`<br>`public-rate-limit` | `pocket-id:80` | 200 | open | internet | yes |
| `stalwart/stalwart` | `stalwart.ts.2143.me` | `lan-only` | `stalwart-stalwart-web:8080` | 302 | unreachable-302 | LAN | yes |
| `stalwart/wkd` | `m.2143.me` | `wkd:8080` |  | 404 | redirect-only | internet | yes |

## LoadBalancer and NodePort services

| Service | Type | VIP | Ports | Probe | Auth class | Admin-capable |
|---|---|---|---|---|---|---|
| `default/factorio-game` | LoadBalancer | `192.168.6.28`<br>`fd00:6::28` | 34197/UDP/- |  | udp (1 port) | no |
| `default/frigate` | LoadBalancer | `192.168.6.26`<br>`fd00:6::26` | 5000/TCP/-<br>1984/TCP/31482<br>8554/TCP/-<br>8555/UDP/- | 1984:200<br>5000:200<br>8554:000 | open (1984, 5000); non-http (8554); udp (1 port) | yes |
| `default/headscale-stun` | LoadBalancer | `192.168.6.18`<br>`fd00:6::18` | 3479/UDP/- |  | udp (1 port) | yes |
| `default/kubernetes-api` | LoadBalancer | `192.168.5.10` | 6443/TCP/31291 | 6443:400 | unreachable-400 (6443) | no |
| `default/minecraft-game` | LoadBalancer | `192.168.6.29`<br>`fd00:6::29` | 25565/TCP/- | 25565:000 | non-http (25565) | no |
| `default/mosquitto-nodeport` | LoadBalancer | `192.168.6.19`<br>`fd00:6::19` | 1883/TCP/31883 | 1883:000 | non-http (1883) | no |
| `default/openrct2-game` | LoadBalancer | `192.168.6.17`<br>`fd00:6::17` | 11753/TCP/31753 | 11753:000 | non-http (11753) | no |
| `default/seaweedfs-s3-lan` | LoadBalancer | `192.168.6.31`<br>`fd00:6::31` | 8333/TCP/- | 8333:403 | denied-anon (8333) | yes |
| `default/temporal-frontend` | LoadBalancer | `192.168.6.20` | 7233/TCP/32682<br>7243/TCP/31618 | 7233:000<br>7243:404 | non-http (7233); unreachable-404 (7243) | yes |
| `default/ts-files` | LoadBalancer | `192.168.6.16`<br>`fd00:6::16` | 30033/TCP/- | 30033:000 | non-http (30033) | no |
| `default/ts-voice` | LoadBalancer | `192.168.6.15`<br>`fd00:6::15` | 9987/UDP/- |  | udp (1 port) | no |
| `kube-system/traefik` | LoadBalancer | `192.168.6.6`<br>`fd00:6::6` | 80/TCP/31316<br>443/TCP/30908 | 443:404<br>80:404 | unreachable-404 (443, 80) | yes |
| `lan-dns/lan-dns` | LoadBalancer | `192.168.6.30`<br>`fd00:6::30` | 53/UDP/-<br>53/TCP/- | 53:000 | non-http (53); udp (1 port) | no |
| `matrix/coturn` | LoadBalancer | `192.168.6.21`<br>`fd00:6::21` | 3478/UDP/32104<br>3478/TCP/32104<br>49152/UDP/32452<br>49153/UDP/31460<br>… 62 more | 3478:000 | non-http (3478); udp (65 ports) | no |
| `matrix/livekit-server-rtc` | LoadBalancer | `192.168.6.22`<br>`fd00:6::22` | 7881/TCP/31527<br>50000/UDP/32601 | 7881:000 | non-http (7881); udp (1 port) | no |
| `observability/loki-push-lb` | LoadBalancer | `192.168.6.24`<br>`fd00:6::24` | 3100/TCP/30108 | 3100:200 | open (3100) | yes |
| `observability/mimir-lb` | LoadBalancer | `192.168.6.23`<br>`fd00:6::23` | 8080/TCP/30674 | 8080:200 | open (8080) | yes |
| `observability/syslog-lb` | LoadBalancer | `192.168.6.25`<br>`fd00:6::25` | 514/UDP/- |  | udp (1 port) | no |
| `observability/tempo-otlp-lb` | LoadBalancer | `192.168.6.27`<br>`fd00:6::27` | 4317/TCP/31199 | 4317:000 | non-http (4317) | yes |
| `rots-prod/rots-gs-0-udp` | LoadBalancer | `192.168.6.32`<br>`fd00:6::32` | 36000/UDP/- |  | udp (1 port) | no |
| `rots-prod/rots-gs-1-udp` | LoadBalancer | `192.168.6.32`<br>`fd00:6::32` | 36001/UDP/- |  | udp (1 port) | no |
| `rots-prod/rots-gs-2-udp` | LoadBalancer | `192.168.6.32`<br>`fd00:6::32` | 36002/UDP/- |  | udp (1 port) | no |
| `rots-prod/rots-gs-3-udp` | LoadBalancer | `192.168.6.32`<br>`fd00:6::32` | 36003/UDP/- |  | udp (1 port) | no |
| `stalwart/stalwart-stalwart` | LoadBalancer | `192.168.6.13`<br>`fd00:6::13` | 25/TCP/30504<br>587/TCP/31862<br>993/TCP/31078 | 25:000<br>587:000<br>993:000 | non-http (25, 587, 993) | yes |
| `steam-lobby/coturn` | LoadBalancer | `192.168.6.14`<br>`fd00:6::14` | 3478/UDP/31211<br>3478/TCP/31211<br>45000/UDP/32272<br>45001/UDP/31096<br>… 62 more | 3478:000 | non-http (3478); udp (65 ports) | no |

## TLS/TCP/gRPC routes

| Kind | Route | Hostnames | Backends |
|---|---|---|---|
| TLSRoute | `default/temporal-grpc` | `temporal-grpc.john2143.com` | `temporal-frontend:7233` |
| TLSRoute | `matrix/livekit-turn` | `turn.john2143.com` | `livekit-server:5349` |

## In-cluster admin APIs (ClusterIP)

| Service | Ports | Ingress policed |
|---|---|---|
| `argocd/argocd-applicationset-controller` | 7000/TCP 8080/TCP | yes |
| `argocd/argocd-dex-server` | 5556/TCP 5557/TCP 5558/TCP | yes |
| `argocd/argocd-metrics` | 8082/TCP | yes |
| `argocd/argocd-notifications-controller-metrics` | 9001/TCP | yes |
| `argocd/argocd-redis` | 6379/TCP | yes |
| `argocd/argocd-repo-server` | 8081/TCP 8084/TCP | yes |
| `argocd/argocd-server` | 80/TCP 443/TCP | yes |
| `argocd/argocd-server-metrics` | 8083/TCP | yes |
| `aross-files/seafile-mariadb` | 3306/TCP | yes |
| `aross-files/seafile-memcached` | 11211/TCP | yes |
| `crowdsec/crowdsec-agent-service` | 6060/TCP | yes |
| `crowdsec/crowdsec-appsec-service` | 6060/TCP 7422/TCP | yes |
| `crowdsec/crowdsec-service` | 6060/TCP 8080/TCP | yes |
| `default/asciinema` | 80/TCP | no |
| `default/asciinema-db-r` | 5432/TCP | no |
| `default/asciinema-db-ro` | 5432/TCP | no |
| `default/asciinema-db-rw` | 5432/TCP | no |
| `default/bulwark` | 3000/TCP | no |
| `default/frigate-genai-dashboard` | 9090/TCP | no |
| `default/frigate-http` | 5000/TCP | no |
| `default/headscale` | 8080/TCP 9090/TCP | no |
| `default/home-assistant` | 80/TCP | no |
| `default/immich` | 80/TCP | n/a (no selector) |
| `default/immich-proxy` | 80/TCP | no |
| `default/litellm` | 4000/TCP | no |
| `default/litellm-db-r` | 5432/TCP | no |
| `default/litellm-db-ro` | 5432/TCP | no |
| `default/litellm-db-rw` | 5432/TCP | no |
| `default/litellm-redis` | 6379/TCP | no |
| `default/nonprod-traefik` | 443/TCP | n/a (no selector) |
| `default/nonprod-traefik-2143me` | 443/TCP | n/a (no selector) |
| `default/oauth2-proxy-seaweedfs-lan` | 4180/TCP | no |
| `default/oauth2-proxy-temporal` | 4180/TCP | no |
| `default/pelican-db-r` | 5432/TCP | no |
| `default/pelican-db-ro` | 5432/TCP | no |
| `default/pelican-db-rw` | 5432/TCP | no |
| `default/pelican-http` | 80/TCP | n/a (no pods) |
| `default/seafile` | 80/TCP | no |
| `default/seafile-mariadb` | 3306/TCP | no |
| `default/seafile-memcached` | 11211/TCP | no |
| `default/seaweedfs-filer-www` | 8888/TCP | yes, pod-scoped (`seaweedfs.yaml`) |
| `default/seaweedfs-master` | 9333/TCP 19333/TCP | yes, pod-scoped (`seaweedfs.yaml`) |
| `default/seaweedfs-s3` | 8333/TCP | yes, pod-scoped (`seaweedfs.yaml`) |
| `default/temporal-db-r` | 5432/TCP | no |
| `default/temporal-db-ro` | 5432/TCP | no |
| `default/temporal-db-rw` | 5432/TCP | no |
| `default/temporal-frontend-headless` | 7233/TCP 6933/TCP 9090/TCP | no |
| `default/temporal-history-headless` | 7234/TCP 6934/TCP 9090/TCP | no |
| `default/temporal-matching-headless` | 7235/TCP 6935/TCP 9090/TCP | no |
| `default/temporal-web` | 8080/TCP | no |
| `default/temporal-worker-headless` | 7239/TCP 6939/TCP 9090/TCP | no |
| `default/unifi-os` | 11443/TCP | n/a (no selector) |
| `default/vikunja` | 80/TCP | no |
| `keda/keda-add-ons-http-controller-manager-metrics-service` | 8443/TCP | yes |
| `keda/keda-add-ons-http-external-scaler` | 9090/TCP 2223/TCP | yes |
| `keda/keda-add-ons-http-interceptor-admin` | 9090/TCP | yes |
| `keda/keda-add-ons-http-interceptor-proxy` | 8080/TCP | yes |
| `keda/keda-admission-webhooks` | 443/TCP | yes |
| `keda/keda-operator` | 9666/TCP | yes |
| `keda/keda-operator-metrics-apiserver` | 443/TCP 8080/TCP | yes |
| `kube-system/docker-registry` | 5000/TCP | no |
| `longhorn-system/longhorn-admission-webhook` | 9502/TCP | no |
| `longhorn-system/longhorn-backend` | 9500/TCP | no |
| `longhorn-system/longhorn-frontend` | 80/TCP | no |
| `longhorn-system/longhorn-recovery-backend` | 9503/TCP | no |
| `longhorn-system/pvc-fbfe1209-d399-4135-a6c7-62e0735050c6` | 2049/TCP | no |
| `mattermost/mattermost` | 8065/TCP | n/a (no pods) |
| `mattermost/mattermost-db-r` | 5432/TCP | no |
| `mattermost/mattermost-db-ro` | 5432/TCP | no |
| `mattermost/mattermost-db-rw` | 5432/TCP | no |
| `metallb-system/frr-k8s-webhook-service` | 443/TCP | no |
| `metallb-system/metallb-webhook-service` | 443/TCP | no |
| `observability/alloy` | 12345/TCP 4317/TCP 4318/TCP 1514/UDP | yes |
| `observability/alloy-cluster` | 12345/TCP 4317/TCP 4318/TCP 1514/UDP | yes |
| `observability/grafana` | 80/TCP | yes |
| `observability/loki-backend` | 3100/TCP 9095/TCP 9096/TCP | yes |
| `observability/loki-backend-headless` | 3100/TCP 9095/TCP 9096/TCP | yes |
| `observability/loki-canary` | 3500/TCP | yes |
| `observability/loki-chunks-cache` | 11211/TCP 9150/TCP | yes |
| `observability/loki-gateway` | 80/TCP | yes |
| `observability/loki-gateway-exporter` | 4040/TCP | yes |
| `observability/loki-memberlist` | 7946/TCP | yes |
| `observability/loki-query-scheduler-discovery` | 3100/TCP 9095/TCP | yes |
| `observability/loki-read` | 3100/TCP 9095/TCP 9096/TCP | yes |
| `observability/loki-read-headless` | 3100/TCP 9095/TCP 9096/TCP | yes |
| `observability/loki-results-cache` | 11211/TCP 9150/TCP | yes |
| `observability/loki-write` | 3100/TCP 9095/TCP 9096/TCP | yes |
| `observability/loki-write-headless` | 3100/TCP 9095/TCP 9096/TCP | yes |
| `observability/mimir` | 8080/TCP 9095/TCP | yes |
| `observability/mimir-memberlist` | 7946/TCP | yes |
| `observability/tempo` | 6831/UDP 6832/UDP 3200/TCP 14268/TCP 14250/TCP 9411/TCP 55680/TCP 55681/TCP 4317/TCP 4318/TCP | yes |
| `observability/tempo-headless` | 6831/UDP 6832/UDP 3200/TCP 14268/TCP 14250/TCP 9411/TCP 55680/TCP 55681/TCP 4317/TCP 4318/TCP | yes |
| `openbao/openbao` | 8200/TCP 8201/TCP | yes |
| `openbao/openbao-active` | 8200/TCP 8201/TCP | yes |
| `openbao/openbao-eso` | 8210/TCP | yes |
| `openbao/openbao-internal` | 8200/TCP 8201/TCP | yes |
| `openbao/openbao-standby` | 8200/TCP 8201/TCP | yes |
| `pocket-id/pocket-id` | 80/TCP | no |
| `stalwart/stalwart-stalwart-headless` | 8080/TCP | no |
| `stalwart/stalwart-stalwart-web` | 443/TCP 8080/TCP | no |
| `stalwart/wkd` | 8080/TCP | no |
| `temporal-system/twc-metrics-service` | 8443/TCP | no |
| `temporal-system/twc-webhook-service` | 443/TCP | no |

## Follow-ups

- [P1] `argocd/argocd` (argocd.ts.2143.me, LAN): anonymous GET returns 200 with no password field. Check by hand whether the app has its own login; if not, put it behind oauth2-proxy per [exposing-an-unauthenticated-app.md](exposing-an-unauthenticated-app.md).
- [P1] `default/asciinema` (terminals.john2143.com, internet): anonymous GET returns 200 with no password field. Check by hand whether the app has its own login; if not, put it behind oauth2-proxy per the guide above.
- [P1] `default/frigate` (cams.ts.2143.me, LAN): anonymous GET returns 200 with no password field. Check by hand whether the app has its own login; if not, put it behind oauth2-proxy per the guide above.
- [P1] `default/frigate-genai-triggers-internal` (cameras.ts.2143.me, LAN): anonymous GET returns 200 with no password field. Check by hand whether the app has its own login; if not, put it behind oauth2-proxy per the guide above.
- [P1] `default/home-assistant` (home.ts.2143.me, LAN): anonymous GET returns 200 with no password field. Check by hand whether the app has its own login; if not, put it behind oauth2-proxy per the guide above.
- [P1] `default/immich` (immich.ts.2143.me, LAN): anonymous GET returns 200 with no password field. Check by hand whether the app has its own login; if not, put it behind oauth2-proxy per the guide above.
- [P1] `default/immich-proxy` (images.2143.me, internet): anonymous GET returns 200 with no password field. Check by hand whether the app has its own login; if not, put it behind oauth2-proxy per the guide above.
- [P1] `default/litellm` (llm.2143.me, internet): anonymous GET returns 200 with no password field. Check by hand whether the app has its own login; if not, put it behind oauth2-proxy per the guide above.
- [P1] `default/temporal-internal` (temporal.ts.2143.me, LAN): anonymous GET returns 200 with no password field. Check by hand whether the app has its own login; if not, put it behind oauth2-proxy per the guide above.
- [P1] `default/unifi-os-ts-2143` (unifi.ts.2143.me, LAN): anonymous GET returns 200 with no password field. Check by hand whether the app has its own login; if not, put it behind oauth2-proxy per the guide above.
- [P1] `default/vikunja` (tasks.2143.me, internet): anonymous GET returns 200 with no password field. Check by hand whether the app has its own login; if not, put it behind oauth2-proxy per the guide above.
- [P1] `longhorn-system/longhorn` (longhorn.ts.2143.me, LAN): anonymous GET returns 200 with no password field. Check by hand whether the app has its own login; if not, put it behind oauth2-proxy per the guide above.
- [P1] `pocket-id/pocket-id` (au.2143.me, internet): anonymous GET returns 200 with no password field. Check by hand whether the app has its own login; if not, put it behind oauth2-proxy per the guide above.
- [P1] `default/frigate` (192.168.6.26, ports 1984, 5000): anonymous HTTP 200 on the LoadBalancer. Check by hand whether it exposes an admin or write API without auth.
- [P1] `observability/loki-push-lb` (192.168.6.24, ports 3100): anonymous HTTP 200 on the LoadBalancer. Check by hand whether it exposes an admin or write API without auth.
- [P1] `observability/mimir-lb` (192.168.6.23, ports 8080): anonymous HTTP 200 on the LoadBalancer. Check by hand whether it exposes an admin or write API without auth.
- [P2] `default/frigate` (192.168.6.26, ports 8554): non-HTTP. Verify app-level auth by hand.
- [P2] `default/temporal-frontend` (192.168.6.20, ports 7233): non-HTTP. Verify app-level auth by hand.
- [P2] `observability/tempo-otlp-lb` (192.168.6.27, ports 4317): non-HTTP. Verify app-level auth by hand.
- [P2] `stalwart/stalwart-stalwart` (192.168.6.13, ports 25, 587, 993): non-HTTP. Verify app-level auth by hand.
- [P2] `default/temporal-grpc` (TLSRoute, temporal-grpc.john2143.com): non-HTTP passthrough. Verify app-level auth by hand.
- [P2] Namespace `default`, no ingress policy selects these admin-capable services, so every pod in the cluster can reach them: `asciinema`, `asciinema-db-r`, `asciinema-db-ro`, `asciinema-db-rw`, `bulwark`, `frigate-genai-dashboard`, `frigate-http`, `headscale`, `home-assistant`, `immich-proxy`, `litellm`, `litellm-db-r`, `litellm-db-ro`, `litellm-db-rw`, `litellm-redis`, `oauth2-proxy-seaweedfs-lan`, `oauth2-proxy-temporal`, `pelican-db-r`, `pelican-db-ro`, `pelican-db-rw`, `seafile`, `seafile-mariadb`, `seafile-memcached`, `temporal-db-r`, `temporal-db-ro`, `temporal-db-rw`, `temporal-frontend-headless`, `temporal-history-headless`, `temporal-matching-headless`, `temporal-web`, `temporal-worker-headless`, `vikunja`. Verify app-level auth by hand.
- [P2] Namespace `kube-system`, no ingress policy selects these admin-capable services, so every pod in the cluster can reach them: `docker-registry`. Verify app-level auth by hand.
- [P2] Namespace `longhorn-system`, no ingress policy selects these admin-capable services, so every pod in the cluster can reach them: `longhorn-admission-webhook`, `longhorn-backend`, `longhorn-frontend`, `longhorn-recovery-backend`, `pvc-fbfe1209-d399-4135-a6c7-62e0735050c6`. Verify app-level auth by hand.
- [P2] Namespace `mattermost`, no ingress policy selects these admin-capable services, so every pod in the cluster can reach them: `mattermost-db-r`, `mattermost-db-ro`, `mattermost-db-rw`. Verify app-level auth by hand.
- [P2] Namespace `metallb-system`, no ingress policy selects these admin-capable services, so every pod in the cluster can reach them: `frr-k8s-webhook-service`, `metallb-webhook-service`. Verify app-level auth by hand.
- [P2] Namespace `pocket-id`, no ingress policy selects these admin-capable services, so every pod in the cluster can reach them: `pocket-id`. Verify app-level auth by hand.
- [P2] Namespace `stalwart`, no ingress policy selects these admin-capable services, so every pod in the cluster can reach them: `stalwart-stalwart-headless`, `stalwart-stalwart-web`, `wkd`. Verify app-level auth by hand.
- [P2] Namespace `temporal-system`, no ingress policy selects these admin-capable services, so every pod in the cluster can reach them: `twc-metrics-service`, `twc-webhook-service`. Verify app-level auth by hand.
- [P3] `default/anni` (anni.2143.me): open on the internet. Confirm it is meant to be public.
- [P3] `default/aross-studio` (aross.studio): open on the internet. Confirm it is meant to be public.
- [P3] `default/balabusta` (balabusta.homes): open on the internet. Confirm it is meant to be public.
- [P3] `default/casual-docs` (docs.john2143.com): open on the internet. Confirm it is meant to be public.
- [P3] `default/chat-heorot` (chat.2143.me): open on the internet. Confirm it is meant to be public.
- [P3] `default/dino-dash` (dino.dsstar.us): open on the internet. Confirm it is meant to be public.
- [P3] `default/dino-dev` (dino-dev.dsstar.us): open on the internet. Confirm it is meant to be public.
- [P3] `default/element-web` (element.john2143.com): open on the internet. Confirm it is meant to be public.
- [P3] `default/factorio` (factorio.john2143.com): open on the internet. Confirm it is meant to be public.
- [P3] `default/how-poe-sale` (how.john2143.com, how.poe.sale): open on the internet. Confirm it is meant to be public.
- [P3] `default/how-pr-5` (how-5.john2143.com): open on the internet. Confirm it is meant to be public.
- [P3] `default/how-pr-6` (how-6.john2143.com): open on the internet. Confirm it is meant to be public.
- [P3] `default/john2143-com-i-prefix` (i.john2143.com): open on the internet. Confirm it is meant to be public.
- [P3] `default/listen-brick` (listen.2143.me): open on the internet. Confirm it is meant to be public.
- [P3] `default/matrix-tuwunel` (matrix.2143.me): open on the internet. Confirm it is meant to be public.
- [P3] `default/moss-dev` (moss-dev.dsstar.us): open on the internet. Confirm it is meant to be public.
- [P3] `default/moss-prod` (moss.dsstar.us): open on the internet. Confirm it is meant to be public.
- [P3] `default/rots-web` (rots.john2143.com): open on the internet. Confirm it is meant to be public.
- [P3] `default/status-design` (status.john2143.com): open on the internet. Confirm it is meant to be public.
- [P3] `default/status-pr-23` (status-23.john2143.com): open on the internet. Confirm it is meant to be public.
- [P3] `default/status-pr-24` (status-24.john2143.com): open on the internet. Confirm it is meant to be public.
- [P3] `default/status-pr-3` (status-3.john2143.com): open on the internet. Confirm it is meant to be public.
- [P3] `default/status-route` (status.2143.me): open on the internet. Confirm it is meant to be public.
- [P3] `default/steam-lobby` (pvp.john2143.com): open on the internet. Confirm it is meant to be public.
