# Auto-instrumentation + WAN-IP aliasing fix (2026-08-10)

## Incident timeline

1. **S3 bucket access (files.john2143.com):** LAN clients posting objects to
   seaweedfs-s3 were flagged by CrowdSec's AppSec out-of-band CRS (rule 901340,
   body-keyword blacklist — S3 object keys matched attack signatures).

2. **LLM prompts (llm.2143.me):** Code/SQL embedded in litellm chat completion
   bodies triggered the same CRS rules.

3. **Household-wide ban:** Both incidents banned the shared WAN IP
   `108.56.153.222`, taking down every public host for ALL household users.

**Root cause:** internal traffic (LAN clients + pods) resolving public
`*.2143.me` hostnames hairpins through the router and is masqueraded to the
WAN IP `108.56.153.222`. Traefik reports `ClientHost: 108.56.153.222`, and
CrowdSec AppSec bans the shared IP — affecting ALL hosts, not just the one
triggering the false positive.

## Fix overview — three layers

### Layer 1: Trust the WAN IP (immediate)

`clientTrustedIps: [108.56.153.222/32]` on the `crowdsec-bouncer` plugin bypasses
ALL CrowdSec checks (ban + AppSec) for the hairpinned internal traffic. Added to
the bouncer in default, pocket-id, and stalwart namespaces.

- `workloads/gateway/security-middlewares.yaml` — both `crowdsec-bouncer` and
  `crowdsec-bouncer-noappsec`
- `workloads/pocket-id/security-middlewares.yaml`
- `workloads/stalwart/security-middlewares.yaml`

**Belt-and-suspenders:** this whitelist stays permanent as a safety net for
hard-coded public-IP references (e.g. the mc-mirror script). Update if the WAN
IP changes (`curl -s https://api.ipify.org`).

### Layer 2: API routes → no-appsec bouncer

AppSec body-scanning is fundamentally incompatible with APIs that accept
arbitrary payloads (S3 objects, LLM prompts, webhooks). Any machine/API route
must use `crowdsec-bouncer-noappsec` — IP banning still works via the bouncer's
LAPI stream; only the out-of-band CRS body inspection is disabled.

- `workloads/llm-proxy/httproute.yaml` — litellm route filter changed from
  `crowdsec-bouncer` to `crowdsec-bouncer-noappsec`
- SeaweedFS S3 route already used `crowdsec-bouncer-noappsec`

**Rule:** any future API/webhook/S3 route → `crowdsec-bouncer-noappsec`. Web UIs
keep the full `crowdsec-bouncer` (they don't trigger body-keyword rules).

### Layer 3: Split-horizon DNS (durable fix)

Internal traffic resolves public hostnames to the internal traefik LB
`192.168.6.11` instead of the public IP. No hairpin, no masquerade, traefik
sees real per-client IPs (not all `108.56.153.222`).

#### 3a — LAN clients (MikroTik)

37 static DNS entries on the router (`192.168.5.1`, DHCP dns-server for all
LAN clients). Mapping derived from the k8s HTTPRoute table cross-referenced
against live dst-nat port-forwards:

| Group | IP | Count | Examples |
|-------|-----|-------|---------|
| HTTP via traefik | `192.168.6.11` | 33 | llm.2143.me, net.2143.me, rots.2143.me, … |
| Mail | `192.168.6.13` | 2 | imap.m.2143.me, smtp.m.2143.me |
| Temporal gRPC | `192.168.6.20` | 1 | temporal-grpc.john2143.com |
| Webmail | `192.168.6.11` | 1 | m.2143.me |

Full mapping: `docs/2026-08-10-split-horizon-mapping.md`

**Note:** the mail subdomains (`imap.m.2143.me`, `smtp.m.2143.me`) do NOT yet
have public DNS records. They must be added at deSEC (ns1.desec.io) as A
records → `108.56.153.222` so mail apps work off-LAN too. Until then, LAN
mail apps pointing at these hostnames work (split-horizon), but off-LAN mail
will fail to resolve.

#### 3b — Pods (CoreDNS)

`dotfiles/nixos/closet-configuration.nix` — a `coredns-custom` ConfigMap manifest
drops a hosts-format zone file into `/etc/coredns/custom/` (k3s mounts it
optionally), plus a `.server` Corefile fragment that creates per-zone server
blocks pointing at the hosts file.

**Requires closet rebuild to land:**
```bash
ssh closet.local 'git -C ~/dotfiles pull && sudo nixos-rebuild switch --flake ~/dotfiles#closet'
# then coredns must restart to import the new fragment:
ssh closet.local 'kubectl rollout restart deploy/coredns -n kube-system'
```

After the restart, pods resolve public hostnames to internal IPs. Verify:
```bash
kubectl exec -n default deploy/litellm -- nslookup llm.2143.me
# → 192.168.6.11
```

#### Public DNS state (2026-08-10)

`*.2143.me` has a wildcard CNAME → apex `2143.me` → `174.138.108.28` (Hetzner,
DEAD — no TLS response). Explicitly-listed subdomains override the wildcard
with A → `108.56.153.222`. All `*.john2143.com` → `108.56.153.222`.

| Zone | WAN resolution | Status |
|------|---------------|--------|
| `*.ts.2143.me` | CNAME 2143.me → 174.138.108.28 | DEAD — Hetzner endpoint returns nothing |
| `rots.2143.me`, `prod.rots.2143.me` | CNAME 2143.me → 174.138.108.28 | DEAD |
| `au`, `chat`, `images`, `llm`, `m`, `matrix`, `net`, `status` (2143.me) | 108.56.153.222 | OK |
| All `*.john2143.com` | 108.56.153.222 | OK |

The `.ts.*` and `rots.*` endpoints are served by the HOME cluster (200 via
`.6.11`, confirmed). The dead Hetzner wildcard is a separate issue (probably
a leftover from a migration attempt). Tailnet MagicDNS already resolves
`*.ts.2143.me` → `.6.11` via headscale `extra_records`.

## Beyla eBPF auto-instrumentation

### Deployment

`apps/beyla.yaml` — ArgoCD Application (Grafana Helm chart `beyla`, v1.16.10,
appVersion 3.25.0). DaemonSet, privileged, `ClusterFirstWithHostNet`. OTLP
export to `alloy.observability.svc:4317` (gRPC) for both traces and metrics.

**Scope:** all namespaces except kube-system/argocd/observability (filtered
via `k8s_dst_owner_name` and `k8s_src_owner_name` not-match patterns).
Beyla auto-disables when an app already emits OTLP (e.g. traefik).

**Node coverage:** 4/6 nodes (arch, closet, nas, big). Office excluded
(wifi taint, eBPF unreliable over wifi). Pite excluded (`pi=true` taint,
arm64 — expected per plan contingency; could be added if toleration configured).

### Alloy metrics branch

`apps/alloy.yaml` — added `metrics` output path from the OTLP receiver:
- `otelcol.receiver.otlp "traces"` → now emits `traces` AND `metrics`
- New `otelcol.processor.batch "metrics"` → `otelcol.exporter.otlp "mimir"`
- Mimir OTLP endpoint: `mimir.observability.svc:8080/otlp` (HTTP, insecure)

### Verification

```bash
# Beyla DaemonSet (expect 4 Running)
kubectl get pods -n observability -l app.kubernetes.io/name=beyla

# RED metrics in Mimir
kubectl port-forward -n observability svc/mimir 19090:8080
curl 'http://localhost:19090/prometheus/api/v1/query' \
  --data-urlencode 'query=count({__name__=~"http_server.*|beyla.*"})'
# → non-empty (observed: 53 metrics at deploy time)

# Traces in Tempo — non-traefik services
kubectl port-forward -n observability svc/tempo 13200:3200
curl "http://localhost:13200/api/search?limit=10&start=<now-10m>&end=<now>"
# Look for rootServiceName: litellm, headscale, mattermost, …
```

## API-vs-webUI bouncer routing rule

| Type | Middleware | When |
|------|-----------|------|
| Web UI (Pocket ID, Home Assistant, Grafana, …) | `crowdsec-bouncer` | Human browsers — AppSec body scanning is appropriate |
| API routes (LLM, S3, webhooks, gRPC, machine clients) | `crowdsec-bouncer-noappsec` | Arbitrary payloads — AppSec body scanning always false-positives |
| Internal/admin (argocd, longhorn, …) | `crowdsec-bouncer` or none | Protected by IP whitelist or LAN-only middleware |

Both bouncers share the same LAPI stream — IP ban decisions apply globally
regardless of which middleware the route uses.

## Operational commands

```bash
# Clear a ban on a specific IP
kubectl exec -n crowdsec deploy/crowdsec-lapi -- cscli decisions delete --ip <IP>

# List active decisions
kubectl exec -n crowdsec deploy/crowdsec-lapi -- cscli decisions list

# Check AppSec alert history
kubectl exec -n crowdsec deploy/crowdsec-lapi -- cscli alerts list

# CrowdSec metrics
kubectl exec -n crowdsec deploy/crowdsec-lapi -- cscli metrics
```

## WAN IP change contingency

If the WAN IP changes (ISP DHCP):

1. Read new IP: `curl -s https://api.ipify.org`
2. Update `clientTrustedIps` in all three `security-middlewares.yaml` files
3. Update MikroTik dns static entries (if any pointed to the WAN IP — they don't, all point to internal IPs)
4. Update public DNS A records for explicit subdomains at deSEC

The split-horizon DNS (Layer 3) is not affected — all entries resolve to
internal IPs independent of the WAN IP.
