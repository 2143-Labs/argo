# Ingress + observability hardening (planned 2026-10-05, executed 2026-10-06)

**Status: COMPLETE. Two checks need a browser, and one change waits on a closet rebuild.**
Tracked as card **#8** on the `2143 Labs AI Tasks` board.

Six defects measured on 2026-10-03/05 are fixed, and node journals plus router logs now reach Loki:

1. CrowdSec no longer buckets, alerts on or reports the household WAN IP to CAPI.
2. Edge rate limits key on each client's IP instead of one shared bucket per route.
3. Tempo's metrics-generator runs, so the Traces Drilldown rate views work.
4. Grafana goes straight to Pocket ID, hides its local form, locks out per IP, and moved to the `content-*` tier.
5. Grafana sends Loki's tenant header.
6. The router answers every Traefik hostname with `192.168.6.11`.

Still open:
- Owner, in a browser: one Pocket ID sign-in, and Drilldown → Logs to confirm `drilldown-limits` returns 200 from Grafana.
- V11 (CoreDNS) runs after `~/dotfiles` `3ed234f` is pushed and closet is rebuilt.

Execution overlapped an unrelated storage outage on nas (§4). Because of it, Tempo ingested no traces from 06:19 to about 18:47 UTC.

## 1. Changes

| commit | repo | message | content |
|---|---|---|---|
| `0fb047c` | argo | fix(crowdsec): whitelist the household WAN IP in the agent parser chain | new `workloads/crowdsec-agent/agent-whitelists.yaml` (s02-enrich `ip:` whitelist, `john2143/home-wan-whitelist`), subPath-mounted into `/etc/crowdsec/parsers/s02-enrich/` by `agent-daemonset.yaml` |
| `f8188db` | argo | fix(gateway): key rate limits on RemoteAddr; move grafana to the content tier | `excludedIPs` removed from all five `*-rate-limit` copies (gateway ×2, pocket-id, stalwart, openbao); `grafana-route.yaml` → `content-rate-limit`/`content-inflight-limit`; header comments, Vikunja comment, `2026-08-09-ingress-hardening.md` |
| `38101b2` | argo | fix(gateway): omit rateLimit sourceCriterion; SSA rejected ipStrategy: {} | fix-forward of `f8188db`, see §3 |
| `7a0143f` | argo | feat(tempo): enable metrics-generator local-blocks for TraceQL metrics | `apps/tempo.yaml`: `metricsGenerator` (storage + traces_storage paths, `local_blocks.flush_to_storage`, `remoteWriteUrl` → Mimir), `overrides.defaults.metrics_generator.processors: [local-blocks]`, memory request 1Gi → 3Gi |
| `65ba45e` | argo | feat(grafana): OIDC auto-login, hide local form, per-IP lockout; send Loki tenant header | `apps/grafana.yaml`: `auto_login`, `auth.disable_login_form`, `security.disable_ip_address_login_protection: false`; Loki datasource `X-Scope-OrgID: fake` |
| `5332e27` | argo | feat(alloy): ship node journald and MikroTik syslog to Loki | `apps/alloy.yaml` journal + syslog components, mounts, UDP 1514 port; `syslog-lb` (`192.168.6.25,fd00:6::25`, 514/UDP, no nodePort) in `workloads/observability/lb-services.yaml`; IP table + free list in `docs/adding-a-workload.md` (also adds the missing `minecraft-game` row); netpol comment |
| `b5a0dd8` | argo | fix(alloy): set journal job label via relabel rule | fix-forward of `5332e27`, see §3 |
| `3ed234f` | dotfiles | fix(k3s): add missing split-horizon names to coredns-custom | 13 in-zone names added to `hosts.split-horizon` in `nixos/closet-configuration.nix`. **Committed locally, not pushed** |

Router (RB5009, `HKG0AWJZPCK`, RouterOS 7.19.6):
- `/system logging action` `loki`: remote `192.168.6.25:514`, src `192.168.5.1`, `remote-log-format=syslog`, `bsd-syslog`, `local0`.
- Four `/system logging` rules (`info`, `warning`, `error`, `critical` → `loki`).
- 18 `/ip dns static` A records → `192.168.6.11`, with comment `split-horizon 2026-10-05`.

## 2. Before / after

| check | before | after |
|---|---|---|
| CrowdSec alerts on `108.56.153.222` | 2026-09-25 (4× `http-crawl-non_statics`), 10-03 (`http-probing`), 10-04 22:09 (`LePresidente/http-generic-401-bf`, alert 15320), each followed by a CAPI signal push | 15 distinct-path `404`s hairpinned through the WAN IP produced **0 alerts, 0 decisions**; 0 alerts for that IP over the following 13 h. The closet agent showed 894 events whitelisted by `john2143/home-wan-whitelist` within 40 min |
| shared rate-limit bucket (`status.2143.me`) | during a 900-request burst from office (156 `200` / 744 `429`), nas, which had sent nothing, got `429 429 200 200 429 200` | same burst (155 / 745); nas got `200 200 200 200 200 200` |
| Grafana `429`s | Drilldown fan-out tripped `public-*` | 0 `429` in 305 Grafana requests since the route change; 300 concurrent `/api/health` returned `300 200` |
| Tempo `/metrics-generator/ring` | `{"shards":null}`, Drilldown `empty ring` | `tempo-0` `ACTIVE`; `{} \| rate()` returns series (~400–730 spans/s) |
| Grafana `/login` | `200` with the local form | `307` → `/login/generic_oauth`; form `POST` → `400 auth.client.notConfigured`; dashboard sidecar reload `200 OK` (basic auth intact) |
| Loki `drilldown-limits` | `401 no org id` | at loki-gateway, `401` without `X-Scope-OrgID` and `200` with `fake`. Grafana's datasource now sends `fake` (browser confirmation pending) |
| node journals in Loki | none | `{job="node-journal"}` from arch, big, closet and nas; `unit="k3s.service"` present |
| router logs in Loki | none | `:log info "loki-syslog-test-20261005"` arrived once in `{job="mikrotik", host="router"}`; ~21 lines / 5 min |
| router split-horizon | 18 Traefik names missing; `*.ts.2143.me` resolved publicly to dead `174.138.108.28` | `dig @192.168.5.1` returns `192.168.6.11` for `tasks.2143.me`, `openbao.ts.2143.me`, `aross.studio`, `mm.b.hero.rehab`, `factorio.john2143.com` |

The rate-limit baseline needed a 900-request burst. Traefik runs 3 replicas, each with its own in-memory
bucket, so 120 requests split across them stays under `burst: 50` per replica.

## 3. What differed from the plan

- **`ipStrategy: {}` cannot replace `excludedIPs` under server-side apply.** `gateway` and `openbao` sync
  with `ServerSideApply=true`. Turning `ipStrategy: {excludedIPs: [...]}` into `ipStrategy: {}` was sent as
  `ipStrategy: null`, and the Middleware CRD rejected it, so both apps sat OutOfSync for ~5 min. The old
  specs stayed live, so nothing broke. `38101b2` drops `sourceCriterion` from every `rateLimit` (Traefik's
  default is the socket RemoteAddr) after server-side dry-runs as `argocd-controller` passed. pocket-id and
  stalwart (client-side apply) had already taken `{}`, and the fix-forward made all four identical. The
  `inFlightReq` middlewares keep `ipStrategy: {}` because they never had children to remove. The header
  comments in the three `security-middlewares.yaml` files say this.
- **`loki.source.journal` ignores `job` in `labels`.** In Alloy v1.19.2 (`tailer.go:59-61`) the component
  sets `job` to its own id after applying `labels`, so the first ~10 min of entries landed as
  `job="loki.source.journal.node"`. `alloy validate` cannot catch this. `b5a0dd8` sets `job` in the relabel
  rules, which run last.
- **`remote-log-format=syslog`** was flagged unverified on 7.19.6. RouterOS accepted it, so the plan's
  `raw` fallback was not needed.
- **Dotfiles anchor drift.** `closet-configuration.nix` had a newer commit (`a1c1cfb`) than the plan's
  baseline; the hosts lines were located by text (now lines 239/240).

## 4. Storage outage on nas (not caused by this work, but it hit Tempo)

At 06:11:51 UTC a `nixos-rebuild switch` on nas (to the `20261005` generation) restarted k3s. Longhorn's
instance-manager came back at a new pod IP. The kernel kept its iSCSI sessions to the old portal
(`10.42.3.220`) in `transport-offline`, so every re-attach looped on
`failed to stop iSCSI device: failed to logout target`. The three single-replica volumes on nas stayed
detached: `seaweedfs-filer-data` (S3 `files.john2143.com` → `503`), `litellm-db-1` and
`litellm-db-1-wal`. nas also held ten older stale sessions from two earlier restarts (portals
`10.42.3.10` and `10.42.3.31`).

Step 3 restarted `tempo-0` at 06:19. Tempo lists its bucket at startup, so the restart turned "S3 down" into
"Tempo down" (148 crash-loops). The old pod had started before the outage and would have kept running.
**No traces were ingested from 06:19 to ~18:47 UTC.** The owner rebooted nas at ~18:45, which cleared the
sessions: all 56 attached volumes are `healthy`, S3 answers `403` (anonymous) again, and the generator ring
registered at 18:47:32.

Next time: drain nas, or at least let Longhorn detach its volumes, before a switch that restarts k3s.
Before restarting a workload that depends on S3, check `curl https://files.john2143.com/` returns `403`.

## 5. Rollback

- Any commit: `git revert <sha> && git push`. Argo `selfHeal`/`prune` applies it.
  - Reverting `0fb047c` re-exposes the WAN IP to CAPI.
  - Reverting `65ba45e` restores the Grafana login form, which is the break-glass path if Pocket ID is down.
    Basic-auth API calls keep working regardless.
- Router logging: `mikrotik-connect r '/system logging remove [find action=loki]'`, then
  `mikrotik-connect r '/system logging action remove [find name="loki"]'`.
- Router DNS: `mikrotik-connect r '/ip dns static remove [find comment="split-horizon 2026-10-05"]'`.
- CoreDNS: `git -C ~/dotfiles revert 3ed234f` (or reset it before pushing).

## 6. Watch items

- **Static WAN IP.** If Verizon changes `108.56.153.222`, update the whitelist in
  `workloads/crowdsec-agent/agent-whitelists.yaml` and the five `clientTrustedIps` entries (gateway ×2,
  pocket-id, stalwart, `apps/openbao.yaml` `crowdsec-bouncer-noappsec`) in one commit.
- **Journald covers 4 of 6 nodes.** office and pite are tainted and Alloy does not tolerate them.
- **Tempo memory.** `tempo-0` ran at ~1.7 GiB against the new 3 GiB request right after recovery. If
  Drilldown returns a range-too-long error, add `queryFrontend: {metrics: {max_duration: 24h}}` under
  `tempo:`.
- **Hairpinning devices share one bucket.** LAN clients that resolve public DNS (tailnet devices, browsers
  with DoH) still arrive as the WAN IP and share that IP's per-client bucket. The router now answers
  every Traefik name locally, so devices that use it get their own bucket. The draft plan for card #4
  (`public-edge-reputation-primary-gating`) would remove the per-IP counters entirely; this change does not
  conflict with it.
