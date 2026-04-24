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
        name: <sub>-ts-2143-me-tls
  allowedRoutes:
    namespaces:
      from: Same
```

The gateway has the `cert-manager.io/cluster-issuer: letsencrypt-prod` annotation, so cert-manager **automatically** creates the TLS certificate for each listener. You do **not** need to add a `Certificate` resource in `workloads/cert-manager/certificates.yaml` unless the hostname is not on the gateway (e.g. `serverkvm`).

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
