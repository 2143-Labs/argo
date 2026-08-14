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
| `service.yaml` | ClusterIP service for in-cluster traffic; add a second NodePort service for non-HTTP protocols (UDP/TCP) |
| `pvc.yaml` | PersistentVolumeClaims (`storageClassName: local-path`) |
| `configmap.yaml` | Configuration (if needed) |
| `ingress.yaml` | HTTPRoute for web UIs (see below) |

No `kustomization.yaml` is needed — Argo applies all YAML in the directory.

## 3. Expose via HTTPS (HTTPRoute)

Three things are needed to expose a service at `<sub>.ts.2143.me` (or another domain):

### a. Gateway Listener (`workloads/gateway/gateway.yaml`)

Add a new listener entry to `shared-gateway`:

```yaml
- name: <sub>-ts-2143-https
  protocol: HTTPS
  port: 8443
  hostname: <sub>.ts.2143.me
  tls:
    mode: Terminate
    certificateRefs:
      - kind: Secret
        name: ts-2143-me-wildcard-tls
  allowedRoutes:
    namespaces:
      from: Same
```

Wildcard certificates cover all subdomains. There are 4 wildcard certs managed in `workloads/gateway/wildcard-certs.yaml` — you do **not** need to add a `Certificate` resource. The gateway no longer uses the `cert-manager.io/cluster-issuer` annotation; certificates are separate resources.

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
      sectionName: <sub>-ts-2143-https
  hostnames:
    - <sub>.ts.2143.me
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: <name>
          port: 80
```

### c. Headscale DNS (`workloads/headscale/configmap.yaml`)

Add A and AAAA `extra_records` so the hostname resolves over Tailscale:

```yaml
- name: "<sub>.ts.2143.me"
  type: "A"
  value: "100.64.0.2"
- name: "<sub>.ts.2143.me"
  type: "AAAA"
  value: "fd7a:115c:a1e0::2"
```

## 4. Expose Non-HTTP Protocols

Use the same LoadBalancer path as everything else (section 5) — UDP and TCP
ports go on the LB service (`pihole-dns` 53/UDP+TCP, `mosquitto` 1883,
`coturn` 3478 are the patterns). **NodePort is legacy**: since the 2026-08-13
migration it is used by exactly one service — `matter-server-nodeport`
(hostNetwork + mDNS/multicast requires node-IP access). Only reach for NodePort
if a workload genuinely needs node-IP access.

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
  apply — the LB IP becomes the only access path (frigate, pihole-dns). Older
  LB services (mosquitto, unifi, ts-*, …) still carry auto-assigned nodePorts;
  add the flag when you touch them to reclaim the node-port exposure.
- **Keep v4 and v6 offsets identical** (`192.168.6.2X` ↔ `fd00:6::2X`) unless
  there's a collision reason (exceptions: traefik `::10`, unifi-inform `::30`).

### IP allocation table (current)

| Service | v4 | v6 |
|---|---|---|
| unifi-inform | 192.168.6.10 | fd00:6::30 |
| traefik (kube-system, manual) | 192.168.6.11 | fd00:6::10 |
| unifi-discovery | 192.168.6.12 | fd00:6::12 |
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
| unifi-web | 192.168.6.25 | fd00:6::25 |
| frigate (5000/1984/8554/8555) | 192.168.6.26 | fd00:6::26 |
| pihole-dns (53) | 192.168.6.27 | fd00:6::27 |
| factorio-game (34197/UDP) | 192.168.6.28 | fd00:6::28 |
| kubernetes-api (control-plane VIP) | 192.168.5.10 | v4-only by design |

**Free:** v4 `192.168.6.28–.200` (`.201–.254` reserved headroom); v6
`fd00:6::11`, `::20`, `::28`, `::29`, `::31–::ff`. Never reuse an in-use
address; a collision surfaces as `AllocationFailed: address also in use by
<ns>/<svc>`.

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
- **WAN access?** Add a dst-nat on the MikroTik pointing the WAN port at the
  `.6.x` IP (LAN-only services need none).

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
