# Matrix homeserver remediation: media storage, GitOps ownership, chat.2143.me, voice

**Date:** 2026-09-15
**Context:** a health check of `matrix.2143.me` (Tuwunel, chart `conduwuit` 2.1.0, namespace `matrix`) found four defects. This records what they were, what changed, the two further defects execution uncovered, and the one check that still needs a human.

## 1. Findings (pre-fix state, reproduced live)

1. **Media storage was dead.** The pod booted with `Failed to connect to storage provider … Error performing PUT http://169.254.169.254/latest/api/token` — the S3 client had no static credentials and fell back to EC2 IMDS — followed by `service "storage" aborted`. The `tuwunel-media` bucket at `files.john2143.com` held 0 objects. Cause: the `storage_provider.seaweedfs.s3` block declared an S3 provider, and the two credentials meant to feed it were named `TUWUNEL_GLOBAL__STORAGE_PROVIDER__…__ACCESS_KEY/SECRET_KEY`. Tuwunel env names use the `TUWUNEL_` prefix with `__` for nesting and the `[global]` prefix is **implicit** (`docs/configuration.md`), so the correct names are `TUWUNEL_STORAGE_PROVIDER__…`; as written they parsed as an unknown root key `global` and were ignored. The declared access key `john` also exists in no live SeaweedFS identity, so nothing could have authenticated even with the right name.
2. **Git was not authoritative for the homeserver.** `apps/` had no `tuwunel.yaml`, so the app-of-apps did not manage the `tuwunel` Application — it had been applied by hand. It ran `v1.8.0` while `workloads/tuwunel/application.yaml` declared `v1.9.1`, so the 2026-09-13 bump (`ac8294b`) never shipped.
3. **`chat.2143.me` returned 503** (`no available server`). HTTPRoute `chat-heorot` targeted Service `heorot`, whose Deployment was pinned at `replicas: 0` with no KEDA `ScaledObject`/`InterceptorRoute`.
4. **Voice was advertised but dead.** `livekit-server`, `coturn` and `heorot-voice-relay` were all at `replicas: 0`, while `/.well-known/matrix/client` still advertised a LiveKit focus and both `https://livekit.john2143.com/` and `https://matrix.2143.me/voice` returned 503. The TURN settings were inert for a second reason: `[global.turn]` does not exist at either v1.8.0 or v1.9.1 — the real keys are the flat `turn_uris` and `turn_secret_file` — so `/_matrix/client/v3/voip/turnServer` returned 404.

## 2. What changed

| Commit | Change |
|---|---|
| `85518ff` | `apps/tuwunel.yaml` created (byte-identical to the hand-applied Application except `image.tag`, which stayed `v1.8.0` so the first sync was a no-op), and five orphan files deleted from `workloads/tuwunel/`: `application.yaml`, `tuwunel-values.yaml`, `livekit-values.yaml`, `livekit-rtc-svc.yaml`, `backup-job.yaml`. The app-of-apps now owns the Application. |
| `a8dd50d` | Media moved to the implicit local provider (deleting `storage_provider.seaweedfs.s3` and the two `extraEnv` credentials). Dead blocks removed: `matrix_rtc`, `federation.whitelist`, `max_concurrent_requests`. TURN rewritten with the real flat keys. |
| `c61a8aa` | `image.tag` → `v1.9.1` — the newest upstream release (2026-09-12); the schema is 17 at both tags, so the one-time migration is a no-op gate that passes. |
| `6779264` | heorot restored: `InterceptorRoute` + `ScaledObject` (copying the `element-web` precedent exactly) and `chat-heorot`'s backend hop moved to the KEDA interceptor. `replicas: 0` deleted from the Deployment so selfHeal cannot revert the operator's scale-up. |
| `0967dfa` | Voice brought up: `livekit-server`, `coturn` and `heorot-voice-relay` to `replicas: 1`; LiveKit's `rtc:` block switched from `use_external_ip: true` + a 50001-60000 ICE range to `use_external_ip: false` + `node_ip: 192.168.6.22`; coturn given `external-ip=192.168.6.21` and a 64-port relay window (49152-49215) published by its Service; the relay's hardcoded LiveKit ClusterIP replaced with `http://livekit-server.matrix.svc.cluster.local:7880`. |
| `75f2cc0` | `argocd.argoproj.io/sync-options: Force=true,Replace=true` on the coturn Service — see §4. |
| `9941843` | coturn's REST secret rendered into its config by a `render-auth` init container — see §4. |
| `5c455be` | Public path plumbed: `Gateway` listener `turn-john2143-passthrough` (TLS passthrough on 8443, SNI `turn.john2143.com`, routes from namespace `matrix`), `TLSRoute/livekit-turn` → `livekit-server:5349`, the port added to that Service, and `Certificate/livekit-turn` (Let's Encrypt, DNS-01 via the existing deSEC webhook) — see §3. |
| `8706af3` | LiveKit's embedded TURN enabled: `turn.enabled: true`, `domain: turn.john2143.com`, `tls_port: 5349`, `external_tls: false` with the cert mounted at `/etc/livekit/turn`, relay range 50001-50064. |

Media now lives at `/data/db/media` on the existing 4 Gi `longhorn-3` volume, so it is covered by the same nightly Longhorn backup as the database.

## 3. Media addressing: LAN direct, internet over TURN/TLS 443

Two independent paths exist, and each client picks whichever works:

**Direct (LAN and Tailscale).** Media uses the `192.168.6.x` MetalLB VIPs: LiveKit `node_ip: 192.168.6.22` on 7881/TCP + 50000/UDP, and TURN `external-ip=192.168.6.21` with relay UDP 49152-49215. Reachable on the home LAN, and on the tailnet via the existing `192.168.6.0/24` subnet route.

**Public (the open internet).** LiveKit's embedded TURN server is enabled (`turn:` in `workloads/livekit/configmap.yaml`) and serves TURN over TLS on the public port 443:

```
off-LAN client ──TCP 443──> MikroTik dst-nat ──> MetalLB 192.168.6.11 (Traefik)
  SNI turn.john2143.com ── TLSRoute passthrough ──> livekit-server:5349 (LiveKit terminates TLS)
  TURN allocation ──> relay sockets on node_ip:50001-50064 ──> local SFU
```

- LiveKit always advertises `turns:turn.john2143.com:443?transport=tcp` (that port is hardcoded in `pkg/service/roommanager.go:1069`), so the public 443 is the entire surface. **No router configuration and no inbound UDP are needed**, and a DHCP WAN-IP change cannot break it because nothing advertises the WAN address.
- `turn.external_tls: false` makes LiveKit terminate TLS itself, which is why the gateway listener is a **TLS passthrough** (`turn-john2143-passthrough`) rather than an HTTPS one, and why `workloads/livekit/certificate.yaml` issues its own cert for the name — the `*.john2143.com` wildcard lives in namespace `default` and cannot be mounted into `matrix`. The same mechanism already carries `temporal-grpc.john2143.com`.
- The embedded TURN is advertised to *every* participant in `JoinResponse.ICEServers`, but relay candidates have the lowest ICE priority, so LAN clients keep direct UDP.
- `workloads/coturn` stays LAN-only: it is the fallback the homeserver advertises through `turn_uris`, useful on-LAN, and needed for neither Heorot voice channels nor Element calls — both run on LiveKit, which `/.well-known/matrix/client` advertises as the `rtc_foci`.

Verified:

- From the LAN: STUN binding to `192.168.6.21:3478/UDP` → Binding Success through the VIP; a TURN client inside the cluster completed a full allocation (permissions, channel binds, 20/20 messages relayed, 0 lost).
- `turn.john2143.com:443` and `192.168.6.11:443` both complete a TLS handshake presenting a valid Let's Encrypt cert for `turn.john2143.com`, and a TURN Allocate over that TLS session returns `Allocate Error Response 401` with `realm "livekit"` and a nonce — LiveKit's TURN server answering TURN on 443.
- The public path was exercised through the WAN address `108.56.153.222` (hairpin from the LAN), the same router path an off-LAN client takes.

## 4. Two further defects that execution uncovered

**coturn's REST secret was a path, not a value.** `static-auth-secret` takes a *literal string* (`mainrelay.c` → `add_to_secrets_list`, `userdb.c:296`); pointing it at `/etc/coturn/secrets/turn_secret` made the secret the path string itself, so every credential worked out by Tuwunel — which reads the file and trims it (`src/core/config/mod.rs:2152-2161`, HMAC-SHA1 over `"<expiry>:<user>"` in `src/api/client/voip.rs:49-53`) — was rejected with `credentials of user <…> are wrong`. Fixed with the `workloads/steam-lobby` pattern: the ConfigMap holds a base config with no secret, and a `render-auth` busybox init container appends `static-auth-secret=$(cat /etc/coturn/secrets/turn_secret)` to a config rendered on an emptyDir. The live TURN allocation test above was run *after* this fix and passes; the same test failed before it.

**ArgoCD cannot patch this Service.** A three-way merge of a port list whose entries share the merge key (`3478` appears as both UDP and TCP) produced `error when patching … duplicate nodePort: {TCP 31001}` — the sync failed while the Deployment kept running. The steam-lobby Service does not hit this because it was created with all 66 ports at once. Fixed with the repo's existing escape hatch (`workloads/storage/longhorn-*-sc.yaml`): `sync-options: Force=true,Replace=true` on the Service. The replacement preserves the pinned MetalLB VIPs.

Also worth knowing: removing `extraEnv` in `a8dd50d` changed the pod template, so that sync rolled the pod and applied the new config **before** the `v1.9.1` bump (`c61a8aa`) — about 25 seconds of API downtime at 04:10Z, during which the PVC also had to re-attach (`Multi-Attach error` for one retry). The upgrade itself cost roughly 15 seconds of 503s at 04:20Z. Neither is a failure mode to expect from config-only edits of this chart going forward, but the chart's `extraEnv` lives in the pod template and so does drive rollouts.

## 5. Operational notes

- **Homeserver:** `ghcr.io/matrix-construct/tuwunel:v1.9.1`, serving `matrix.2143.me`. `/_matrix/client/versions` → 200, SSO redirect → 302, `/_matrix/client/v3/voip/turnServer` → 401 (configured; 404 would mean `turn_uris` is missing). Uploaded media grows the Longhorn volume; the image is distroless, so `/data/db/media` cannot be inspected with `kubectl exec`.
- **chat.2143.me (heorot):** KEDA scale-to-zero. Cold start measured at 3.7 s (request → 200); warm responses ~46 ms; the Deployment returns to 0 after ~30 minutes idle (`cooldownPeriod: 1800`, `scaleDown.stabilizationWindowSeconds: 600`).
- **Voice:** `livekit-server`, `coturn`, `heorot-voice-relay` all serve 1/1; `coturn` publishes 66 ports on `192.168.6.21`; `matrix.2143.me/voice/healthz` → 200. LiveKit is pinned at `v1.13.6` (v1.13.7 exists, published 2026-09-14, and is a separate unverified bump). LiveKit's TURN/TLS is reachable at `turn.john2143.com:443` for off-LAN clients; its cert renews through cert-manager, and the `reloader` annotation on the Deployment restarts the pod when the Secret rotates.
- **Rotating the TURN secret** means updating the Secret and restarting coturn (`render-auth` reads the file at pod start) — Tuwunel picks the new value up on its next request.
- **Restore point used for the upgrade:** Longhorn snapshot `nightly--4f5af78f-…` (2026-09-14T07:08:33Z) plus its nightly backup, on volume `pvc-2fb820a3-351e-443d-93d3-97392b431a19`. The upgrade rolled back to the same volume, unchanged.

## 6. Supersedes

`docs/2026-08-07-keda-http-addon-poc.md` §9.4 ("heorot reverted, blocked by node registry config") no longer applies: the plain-HTTP mirror in `certs.d/10.43.114.59:5000` is present on all general nodes, and heorot runs from `10.43.114.59:5000/heorot-web:v0.1.0`.

## 7. Left for a human

Two checks need a logged-in client and so could not be driven from this session: upload an image in Element (`https://element.john2143.com`, PocketID login) and confirm it renders, and place a call between two sessions confirming **two-way audio and a working screenshare**. Do at least one of those calls from a phone on cellular data (Wi-Fi off, Tailscale off) — that is the only way to prove the public path end to end, since every check in this document was run from inside the LAN.