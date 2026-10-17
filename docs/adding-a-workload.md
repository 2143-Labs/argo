# Adding a New Workload

## 1. Create the Argo Application

Add `apps/<name>.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <name>
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/2143-Labs/argo.git
    targetRevision: HEAD
    path: workloads/<name>
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

The `app-of-apps` Application in `main.yaml` watches the `apps/` directory, so this is picked up automatically.

## 2. Create Workload Manifests

Add Kubernetes resources under `workloads/<name>/`. Typical files:

| File | Purpose |
|---|---|
| `deployment.yaml` | Deployment (use `strategy: Recreate` for stateful single-replica workloads) |
| `service.yaml` | ClusterIP service for in-cluster traffic; non-HTTP protocols (UDP/TCP) get a LoadBalancer service (section 5) |
| `pvc.yaml` | PersistentVolumeClaims (`storageClassName: local-path`) |
| `configmap.yaml` | Configuration (if needed) |
| `ingress.yaml` | HTTPRoute for web UIs (see below) |

No `kustomization.yaml` is needed — Argo applies all YAML in the directory.

### Node placement (do nothing)

Never add tolerations or node selectors for node network topology. Wifi-only
nodes (currently `office`) carry the taint `wifi=no-network-storage:NoSchedule`;
the cluster policy `workloads/wifi-node-policy` adds the matching toleration at
admission to every pod that mounts no network storage (no PVC, NFS, iSCSI, CSI,
ephemeral volume or hostPath) and is not a DaemonSet or hostNetwork pod. Pods
with storage stay on wired nodes automatically. A pod that tolerates the wifi
taint while mounting network storage is rejected. Wired nodes are always
preferred; wifi nodes are overflow.

## 3. Expose via HTTPS (HTTPRoute)

A LAN/tailnet name `<sub>.ts.2143.me` needs a route on the existing wildcard listener carrying `lan-only` (b) and a headscale record (c). A public name needs the route plus an edge gate instead of `lan-only` (d).

### a. Gateway Listener (`workloads/gateway/gateway.yaml`)

Usually nothing: `shared-gateway` has one listener per wildcard certificate. Pin the route to it by `sectionName`:

| Hostname | `sectionName` | Certificate |
|---|---|---|
| `<sub>.john2143.com` | `john2143-wildcard-https` | `*.john2143.com` |
| `<sub>.2143.me` | `2143-me-wildcard-https` | `*.2143.me` |
| `<sub>.ts.2143.me` | `ts-2143-me-wildcard-https` | `*.ts.2143.me` |

A route outside namespace `default` attaches only if its namespace is in that listener's `allowedRoutes` `matchExpressions` `values` list in `workloads/gateway/gateway.yaml`; add it there.

Wildcard certificates cover exactly one label: `*.2143.me` covers `anni.2143.me` but not `element.chat.2143.me`. A deeper name or a new domain needs a `Certificate` in `workloads/gateway/wildcard-certs.yaml` and its own listener. Keep `shared-gateway` at 16 listeners or fewer: Traefik writes one BackendTLSPolicy status ancestor per listener and fails every status write beyond 16. `scripts/validate-gateway-certs.sh` fails CI when a route pins no listener or a missing one, when a pinned hostname is not covered by the listener's hostname or Certificate, or when the Gateway exceeds 16 listeners. The gateway no longer uses the `cert-manager.io/cluster-issuer` annotation; certificates are separate resources.

### b. HTTPRoute (`workloads/<name>/ingress.yaml`)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <name>
  namespace: default
spec:
  parentRefs:
    - name: shared-gateway
      sectionName: ts-2143-me-wildcard-https
  hostnames:
    - <sub>.ts.2143.me
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: lan-only
      backendRefs:
        - name: <name>
          port: 80
```

**Never omit `lan-only` on a `.ts.2143.me` route.** The name is private only in DNS. The gateway serves any route whose hostname a client sends to the WAN address, so without `lan-only` the app is on the internet. (A request for `argocd.ts.2143.me` sent to the WAN IP returns 403 only because its route carries `lan-only`.) The Middleware must exist in the route's namespace; copy `workloads/gateway/lan-only-middleware.yaml` (precedents: `workloads/argocd/ingress.yaml`, `workloads/longhorn-ui/ingress.yaml`, `workloads/stalwart/security-middlewares.yaml`). CI (`scripts/validate-route-gates.sh`) rejects a `.ts` rule without it.

### c. Headscale DNS (`workloads/headscale/configmap.yaml`)

Add one A record so the name resolves on the tailnet (MagicDNS). Every record points at the gateway; there are no AAAA records:

```yaml
# <sub>.ts.2143.me
- name: "<sub>.ts.2143.me"
  type: "A"
  value: "192.168.6.11"
```

Remove the record in the same commit that removes the route.

### d. Public hostname

A public hostname carries an edge gate instead of `lan-only`. Pick the gate from
[Public edge](public-edge.md). If the app has no login of its own, also follow
[Exposing an Unauthenticated App](exposing-an-unauthenticated-app.md).

### e. LAN and cluster DNS (automatic)

Nothing to do for LAN clients or pods: `lan-dns` answers every HTTPRoute/TLSRoute
hostname on `shared-gateway` with the gateway address (`192.168.6.11`) within about
a minute, as long as the hostname is inside one of its zones (`2143.me`,
`john2143.com`, `aross.studio`, `balabusta.homes`, `chess.dsstar.us`,
`mm.b.hero.rehab`). CI (`scripts/validate-lan-dns-zones.sh`) fails if it isn't.
A new domain, a non-HTTP LoadBalancer name, or a name that must resolve publicly
on the LAN each needs one extra step — see [lan-dns.md](lan-dns.md).
Tailnet clients still need 3c for `.ts.2143.me` names. Pods use lan-dns only
after stage 2 (see lan-dns.md "Status").

## 4. Expose Non-HTTP Protocols

Use the same LoadBalancer path as everything else (section 5) — UDP and TCP
ports go on the LB service (`lan-dns` 53/UDP+TCP, `mosquitto` 1883,
`coturn` 3478 are the patterns). **Do not add NodePort services.** None remain
in the repo or the cluster; a workload that needs node-IP access (hostNetwork,
mDNS) uses `hostNetwork` instead. For a LAN hostname on a non-HTTP
LoadBalancer IP, add it to the `hosts` block in `workloads/lan-dns/configmap.yaml`
([lan-dns.md](lan-dns.md)).

## 5. Expose as a LoadBalancer (MetalLB — the default)

Since 2026-08-04 the home cluster runs MetalLB in **BGP mode** (frr-k8s), and
since 2026-08-12 every LB service is **dual-stack** (v4 + v6, both
BGP-announced over MP-BGP to the MikroTik). This is the standard for exposing
anything TCP/UDP — HTTP goes through the gateway instead (section 3).

### Standard manifest

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <name>
  annotations:
    metallb.io/loadBalancerIPs: "192.168.6.2X,fd00:6::2X"
spec:
  type: LoadBalancer
  allocateLoadBalancerNodePorts: false
  ipFamilyPolicy: PreferDualStack
  ipFamilies: [IPv4, IPv6]
  selector:
    app: <name>
  ports:
    - port: 53
      targetPort: 53
      protocol: UDP
      name: dns-udp
    - port: 53
      targetPort: 53
      protocol: TCP
      name: dns-tcp
```

Notes:
- `allocateLoadBalancerNodePorts: false` deallocates the service's nodePorts on
  apply — the LB IP becomes the only access path (frigate, lan-dns). Older
  LB services (mosquitto, ts-*, …) still carry auto-assigned nodePorts;
  add the flag when you touch them to reclaim the node-port exposure.
- **Keep v4 and v6 offsets identical** (`192.168.6.2X` ↔ `fd00:6::2X`) unless
  there's a collision reason (exception: traefik `::10`).

### IP allocation table (current)

| Service | v4 | v6 |
|---|---|---|
| traefik (kube-system; pinned by the k3s HelmChartConfig in dotfiles, both families) | 192.168.6.11 | fd00:6::10 |
| stalwart (smtp/submission/imaps) | 192.168.6.13 | fd00:6::13 |
| steam-lobby coturn (TURN) | 192.168.6.14 | fd00:6::14 |
| ts-voice (9987) | 192.168.6.15 | fd00:6::15 |
| ts-files (30033) | 192.168.6.16 | fd00:6::16 |
| openrct2-game | 192.168.6.17 | fd00:6::17 |
| headscale-stun | 192.168.6.18 | fd00:6::18 |
| mosquitto (1883) | 192.168.6.19 | fd00:6::19 |
| temporal-frontend | 192.168.6.20 | v4-only (chart limitation) |
| matrix coturn (3478) | 192.168.6.21 | fd00:6::21 |
| livekit-server-rtc (7881/50000) | 192.168.6.22 | fd00:6::22 |
| mimir-lb | 192.168.6.23 | fd00:6::23 |
| loki-push-lb | 192.168.6.24 | fd00:6::24 |
| syslog-lb (514/UDP → Alloy) | 192.168.6.25 | fd00:6::25 |
| frigate (5000/1984/8554/8555) | 192.168.6.26 | fd00:6::26 |
| factorio-game (34197/UDP) | 192.168.6.28 | fd00:6::28 |
| minecraft-game | 192.168.6.29 | fd00:6::29 |
| lan-dns (53 → k8s_gateway) | 192.168.6.30 | fd00:6::30 |
| seaweedfs-s3-lan (S3 8333, WireGuard/LAN) | 192.168.6.31 | fd00:6::31 |
| kubernetes-api (control-plane VIP) | 192.168.5.10 | v4-only by design |

**Free:** v4 `192.168.6.10`, `.12`, `.27` and `192.168.6.32–.200` (`.201–.254` reserved
headroom); v6 `fd00:6::11`, `::12`, `::20`, `::27`, `::2a–::2f`, `::32–::ff`. Never
reuse an in-use address; a collision surfaces as `AllocationFailed: address also
in use by <ns>/<svc>`.

### Rules of thumb

- The `metallb.io/loadBalancerIPs` annotation is the supported path; do not set
  `spec.loadBalancerIP` (deprecated; MetalLB ≥0.16 rejects v4-only values).
- `PreferDualStack`, **not** `RequireDualStack` — a family hiccup must never
  block allocation.
- **Zero Ready endpoints = not announced.** MetalLB won't announce a service
  without Ready endpoints (e.g. scaled-to-0). Allocate the IP anyway; it starts
  announcing once endpoints exist.
- Deleting a converted LB service can leave a stuck
  `service.kubernetes.io/load-balancer-cleanup` finalizer (k3s, no
  cloud-provider) — remove it via `kubectl patch svc <name> --type=json
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'`.
- **Probe with `nc`, never `ping`** — ICMP to LB VIPs always times out
  (kube-proxy DNATs TCP/UDP only). Probe from a **non-cluster host**: office and
  pite are k3s nodes, so their kube-proxy intercepts VIPs locally and their
  probes prove nothing about the router path.
- **WAN access?** Two forwards are needed: the Verizon router to `192.168.0.2`
  and a MikroTik dst-nat to the `.6.x` IP (LAN-only services need neither).
  Steps, the live port table and how to prove it from outside:
  [network-edge.md](network-edge.md).

### Pitfalls (verified 2026-08-13)

- **v4-only app behind a dual-stack service → ~50% gateway 502s.** A dual-stack
  service emits an IPv6 EndpointSlice, so traefik round-robins the pod's v6
  address. If the app binds IPv4-only (`0.0.0.0`, e.g. frigate's uvicorn), the
  v6 leg refuses and HTTPRoutes flake (~50% 502/timeout). Fix: keep the
  dual-stack LB for direct access, but back the HTTPRoute with a **v4-only
  ClusterIP** service (`frigate-http` pattern — no `ipFamilyPolicy` field).
- **App-side ACLs silently drop LAN clients.** A k8s pod's only interface is the
  overlay, so "local" listeners/ACLs bind to 10.42.x — pihole 6's FTL
  `listeningMode = "LOCAL"` answered nothing outside the pod subnet until set to
  `ALL` (`FTLCONF_dns_listeningMode=all`; the legacy `DNSMASQ_LISTENING=all` env
  is ignored by pihole 6). Always verify the service actually **answers** from a
  non-cluster host — reachability ≠ serviceability.
- **LB v6 port with a v4-bound app**: the dual-stack LB's v6 port refuses if the
  app doesn't listen on `::`. Stream/media planes that bind dual-stack (go2rtc)
  are fine; check the app before promising v6.
- **After converting a service that backs an HTTPRoute to dual-stack, hammer the
  route** (e.g. 15× curl) — the v6-endpoint 502 regression only shows up
  intermittently.
- **After any rollout, re-check the allocation table** — a restarted pod can
  land on another node and change nothing, but a new service can grab the
  lowest free IP if you didn't pin it.
