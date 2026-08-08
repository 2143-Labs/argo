# KEDA HTTP Add-on scale-to-zero POC for aross.studio — execution log (2026-08-07)

**Status: COMPLETE and verified.** aross.studio now runs behind the KEDA HTTP Add-on: 1 pod under traffic, **0 pods when idle (~2 min)**, cold-starting in ~3.5–4s on the first request. Two full idle→0→curl→1 cycles verified identically; ArgoCD reads `friend-aross` **Synced/Healthy** at 0 replicas.

## 1. Commits (pushed to origin/main, in order)

| commit | message | content |
|---|---|---|
| `7aee270` | feat(argo): install keda-http-addon 0.15.0 + interceptor ReferenceGrant | `apps/keda-http-addon.yaml` (chart app, releaseName `keda-add-ons-http`, values: interceptor min 1 + readinessTimeout "30s", scaler 1), `apps/keda-http-addon-manifests.yaml`, `workloads/keda-http-addon/referencegrant.yaml` |
| `992c6fa` | feat(workloads): aross interceptorroute + drop managed replicas | `workloads/friends/aross/interceptorroute.yaml`; deployment.yaml: deleted `replicas: 1` |
| `9af6411` | feat(workloads): route aross.studio via keda interceptor proxy | ingress.yaml backendRefs → `keda-add-ons-http-interceptor-proxy:8080` (ns keda, cross-namespace) |
| `8e89617` | feat(workloads): aross scale-to-zero scaledobject (external-push) | `workloads/friends/aross/scaledobject.yaml` (min 0 / max 1, cooldown 60, stabilization 60) |
| this doc | docs(argo): record keda http add-on scale-to-zero poc | — |

**Cluster ops:** `ssh closet.local kubectl ...` (admin; workstation kubeconfig SA `developer` cannot GET `interceptorroutes`/CRD resources). Remote shell is **fish**: no heredocs; validate manifests with `cat file | ssh closet.local "kubectl apply --dry-run=server -f -"`. Sync pattern: `kubectl -n argocd annotate application app-of-apps argocd.argoproj.io/refresh=hard --overwrite` then `kubectl -n argocd patch application <child> --type merge -p '{"operation":{"sync":{"revision":"HEAD","prune":true}}}'` (children only exist after app-of-apps itself syncs).

## 2. Request path (verified live)

```
public/LAN → Traefik shared-gateway (listener aross-studio-https, LB 192.168.6.11, TLS term)
  → HTTPRoute aross-studio (backendRef keda-add-ons-http-interceptor-proxy:8080, ns keda
     — allowed by ReferenceGrant allow-httproute-to-interceptor in keda ns)
  → interceptor (keda ns): Host-based routing via InterceptorRoute aross-studio → aross-studio:80 (default ns)
  → aross pod (nginx)
```

## 3. How the mechanism actually works (differs from plan assumptions — verified live)

- **The add-on operator drives 0↔1 itself.** When the target goes idle it sets `Deployment.spec.replicas=0` directly and patches the HPA status with `ScalingActive: False` — message: **"scaling is disabled since the replica count of the target is zero"** — so the HPA controller doesn't fight it. On traffic, the interceptor buffers the request (30s `readinessTimeout`) while the operator scales back to 1.
- **HPA minReplicas is 1, not 0.** This cluster's KEDA operator runs **without `--enable-scale-to-zero`** (args checked), so `minReplicaCount: 0` in the ScaledObject is floored to HPA min 1 — same as the frigate-genai worker HPAs. This is irrelevant to the add-on's zero-scaling (the operator manages it), but do not expect `hpa.spec.minReplicas=0` here.
- **`spec.hpaBehavior` is NOT a valid ScaledObject field on KEDA 2.20.1** — the CRD rejected it (strict decode error). Correct path: `spec.advanced.horizontalPodAutoscalerConfig.behavior.scaleDown.stabilizationWindowSeconds: 60` (verified in the CRD schema and accepted; the HPA carries `behavior.scaleDown.stabilizationWindowSeconds: 60`).
- **ArgoCD does not fight the operator**: with `replicas:` absent from the Deployment manifest, `friend-aross` reads Synced/Healthy at 0 replicas (same precedent as frigate-genai).

## 4. Measured behavior (aross.studio only)

| event | observation |
|---|---|
| traffic → 1 pod | instant (operator scale-up, no HPA wait) |
| idle → 0 pods | **~2 min** (cooldown 60s + stabilization 60s; first-ever drop happened ~40s after ScaledObject creation) |
| cold start | curl at 0 pods → **HTTP 200 in 3.4s / 4.0s** (two cycles), pod 0→1 both times |
| HPA metric | `external s0-http_aross-studio_concurrency`, target avg 10; reads `0/10 (avg)` when idle |
| ArgoCD at 0 pods | `friend-aross` Synced/Healthy |

## 5. Opting a future friend site into scale-to-zero (4 manifest changes)

1. Deployment: delete `replicas:` (stop ArgoCD from owning the field).
2. Add `interceptorroute.yaml`: `http.keda.sh/v1beta1`, name `<site>`, `spec.target.service/port` → the site's Service, `spec.rules[].hosts` → its hostnames, `scalingMetric.concurrency.targetValue: 10`.
3. HTTPRoute: change `backendRefs` to `name: keda-add-ons-http-interceptor-proxy, namespace: keda, port: 8080` (needs the ReferenceGrant — already in `keda` ns, scope `from: default ns HTTPRoutes`).
4. Add `scaledobject.yaml`: `keda.sh/v1alpha1`, `scaleTargetRef.name: <deployment>`, min 0 / max 1, cooldown 60, `advanced.horizontalPodAutoscalerConfig.behavior.scaleDown.stabilizationWindowSeconds: 60`, trigger `external-push` with `scalerAddress: keda-add-ons-http-external-scaler.keda:9090` + `interceptorRoute: <name>`.

Order matters when converting a **live** site: the ScaledObject must land only **after** the InterceptorRoute exists (else the HPA falls back to a CPU metric and scale-up from 0 breaks until KEDA re-reconciles) and **after** traffic flows through the interceptor (else the scaler reports idle and the operator drops the live site to 0 → 502s until it scales back). **For a brand-new site with no traffic, a single commit with all 4 changes is acceptable**: the CPU-metric race self-heals in ~30–60s (worst case one re-sync of the child app), and immediate scale-to-0 on deploy is the designed behavior — the first real visit cold-starts it (~4s). Verify after sync either way: curl → wait ~2 min → 0 pods → curl again (200, pod 0→1).

## 6. Tuning knobs

- `interceptor.readinessTimeout: "30s"` (chart value) — **load-bearing**: since v0.14.0 the default is 0 (disabled), which would NOT buffer requests during cold start.
- `cooldownPeriod: 60` + `stabilizationWindowSeconds: 60` — idle→0 ≈ 2 min instead of the ~10 min defaults.
- `scalingMetric.concurrency.targetValue: 10` (InterceptorRoute) — request count that drives scale-up.
- No `coldStart.placeholder` / `fallback` configured: first request is served, not placeholder'd.

## 7. Rollback (one-commit revert per step, reverse order, sync after each)

`git revert 8e89617` (removes ScaledObject/HPA; Deployment unscaled mid-rollback is fine) → revert `9af6411` (traffic back to aross-studio directly) → revert `992c6fa` (restores `replicas: 1`) → revert `7aee270` (removes both apps + chart + CRDs; CRs already gone, so CRD prune is clean). Final check: curl 200, pod 1/1, no ScaledObject.

## 8. Pre-existing issue (out of scope, recorded per user decision)

`design.aross.studio` and `portfolio.aross.studio` **fail TLS at the home cluster at baseline**: Certificate `aross-studio-tls` (`workloads/gateway/wildcard-certs.yaml`) covers only `aross.studio`, but all three Gateway listeners (`gateway.yaml` lines 583–618) serve secret `aross-studio-wildcard-tls`. Public DNS: design → CNAME `amandaross.design` (external Fastly hosting — never served from this cluster), portfolio → **no DNS records**. POC verified **aross.studio only** (per user decision); the two subdomains remain in the HTTPRoute/InterceptorRoute manifests unchanged. Fixing the cert was explicitly not taken (design is externally hosted; portfolio is not public).

## 9. Deployed sites (2026-08-08 rollout)

The pattern is now live on three sites (element-web, webserver; aross from the POC). heorot was attempted and **reverted** — see §9.4.

### 9.1 Live sites

| site | hostnames | ns (InterceptorRoute + ScaledObject) | commits |
|---|---|---|---|
| aross | aross.studio | default | POC commits §1 |
| element-web | element.john2143.com | matrix | `c478101` (app + interceptor + route flip), `6213125` (ScaledObject) |
| webserver | rots.2143.me, prod.rots.2143.me | default | `137a2a5` (app re-enable + flip), `685f5ee` (runAsUser fix) |

All three verified: idle→0 in ~2 min, cold start HTTP 200 in ~3.4–3.8s (warm image), ArgoCD app Synced/Healthy at 0 replicas.

### 9.2 The namespace rule (load-bearing, verified live)

`InterceptorRoute.spec.target` has **no namespace field** — it resolves in the InterceptorRoute's own namespace. So **InterceptorRoutes + ScaledObjects live in the target's namespace** (matrix for heorot/element-web, default for aross/webserver), while the HTTPRoutes stay in `default` and are covered by the existing keda ReferenceGrant (`from: default` → interceptor). The interceptor's routing table is **cluster-wide** — the add-on operator watches `InterceptorRoute` in all namespaces by default (`operator.watchNamespace` unset in our chart values), confirmed against the keda.sh docs 2026-08-08 and proven live by element-web (matrix ns) routing through the interceptor.

### 9.3 Fixes folded into the rollout

- **element-web was an orphaned workload**: live resources in `matrix` with no Argo app managing them (a manual Aug 3 scale-up of a manifest pinned at `replicas: 0`). Fixed by creating `apps/element-web.yaml` (mirror of `apps/heorot.yaml`); the live Deployment keeps its manual `replicas: 1` through the flip (ArgoCD doesn't touch the absent field), then the operator drives it to 0.
- **webserver was disabled**: app commented out in `15f0b3c` "webserer off"; restored verbatim in `137a2a5`.
- **webserver deployment was broken as-committed**: `runAsNonRoot: true` with an image whose default user is root → kubelet refused to create the container (`CreateContainerConfigError`). Fixed with `runAsUser: 101` (aross precedent) in `685f5ee`. The site had never run, so the bug predates the rollout.

### 9.4 heorot (chat.2143.me) — reverted, blocked by node registry config

heorot's flip commit (`281d2b4`) was **reverted** (`ace9a06`); the site is back to its pre-change 503. The interceptor mechanism worked (request triggered 0→1 through the matrix-ns InterceptorRoute), but the pod hit `ErrImagePull` on `10.43.114.59:5000/heorot-web:v0.1.0`: **"server gave HTTP response to HTTPS client"**. Only the `closet` node carries `/etc/rancher/k3s/registries.yaml` mapping `10.43.114.59:5000` → plain HTTP; **`big` and `pite` have no such file** (heorot's preferred node is `big`). The site last ran on closet before `ccaa274` scaled it to 0, so the gap went unnoticed.

**To enable heorot:** add the `registries.yaml` insecure-registry config to `big` and `pite` (node provisioning — outside the argo repo), then re-run the single-commit flip (4 changes: drop `replicas: 0`, InterceptorRoute + ScaledObject in `matrix`, chat-heorot HTTPRoute backendRef → interceptor).

### 9.5 element-web cold-start note

`vectorim/element-web:latest` (default pull policy `Always`) made the first cold start 20.9s (15s image pull on a node without the cache; absorbed by the 30s interceptor buffer). **Pinned in `8e25bc2`/`a52a7e8`** to `vectorim/element-web:v1.12.25` + `imagePullPolicy: IfNotPresent` (aross precedent). The pin is content-identical to the `latest` that was running (same digest `sha256:ac50d4ee…`, verified against Docker Hub 2026-08-08), so no functional change. Result: first pull of the pinned tag reuses cached layers (412ms), subsequent cold starts have **zero pull events** and serve in **~3.9s** (verified two consecutive cycles: 4.48s, 3.95s, no `Pulling` events). `:latest` moves on each release; the pin makes cold-start latency deterministic.
