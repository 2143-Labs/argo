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

For UDP/TCP services (DNS, game servers, STUN, etc.), use a **NodePort** service. The same `nodePort` number can be shared across TCP and UDP.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <name>-<proto>
  labels:
    app: <name>
spec:
  type: NodePort
  selector:
    app: <name>
  ports:
    - port: 53
      targetPort: 53
      nodePort: 300XX
      protocol: UDP
      name: dns-udp
    - port: 53
      targetPort: 53
      nodePort: 300XX
      protocol: TCP
      name: dns-tcp
```

## 5. Expose as a LoadBalancer (MetalLB — preferred for non-HTTP)

Since 2026-08-04 the home cluster runs MetalLB in BGP mode (frr-k8s): every
LoadBalancer service gets a dedicated `192.168.6.x` IP announced to the router,
reachable from the LAN/WAN (dst-nat) without nodePort guessing.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <name>
  annotations:
    metallb.io/address-pool: service-subnet
    metallb.io/loadBalancerIPs: "192.168.6.2X"
spec:
  type: LoadBalancer
  selector:
    app: <name>
  ports:
    - port: 8080
      targetPort: 8080
```

Rules of thumb:
- **Pick the next free IP** in `192.168.6.10–.50` (see the table in
  `network-engineer` skill). Never reuse an in-use `.6.x`.
- The annotation (not `spec.loadBalancerIP`) is the supported path; do not set both.
- Keep the `nodePort` (default) alongside the LB IP — the NodePort path remains
  as a fallback and for node-IP access.
- **WAN access?** Add a dst-nat rule on the MikroTik pointing the WAN port at
  the `.6.x` IP (LAN-only services like mimir/loki/unifi-web need no dst-nat).
- **Zero endpoints = not announced.** MetalLB will not announce a service
  without Ready endpoints (e.g. a scaled-to-0 deployment) — allocate the IP
  anyway; it starts announcing when endpoints exist.
- Deleting a converted LB service can leave a stuck
  `service.kubernetes.io/load-balancer-cleanup` finalizer (k3s, no cloud-provider)
  — remove it via `kubectl patch svc <name> --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'`.

**NodePort (section 4) is legacy** — use it only for services that must NOT
move onto a `.6.x` IP (e.g. minecraft's bare-metal redirect).
