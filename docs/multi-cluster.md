# Multi-cluster: prod + the bigp nonprod cluster

Prod Argo manages two clusters:

| Cluster Secret (`argocd` ns) | Label `env` | Server | Defined in |
|---|---|---|---|
| `in-cluster` | `prod` | `https://kubernetes.default.svc` | `bootstrap/argocd/cluster-in-cluster.yaml` (applied by hand once) |
| `nonprod` | `nonprod` | `https://192.168.7.2:6443` | written by `~/repos/bigp-tofu/bin/register-cluster.sh` on every rebuild |

Nonprod is three disposable NixOS guests on bigp, rebuilt weekly from scratch
(`~/repos/bigp-tofu`, see its README). It holds no data worth keeping. Its
purpose is to validate a change to `workloads/` before it reaches prod.

`apps/default-project.yaml` lists both servers (plus `https://192.168.5.40:6443`,
used while a fresh nonprod is bootstrapping, before its API VIP exists).

## Which apps run where

An app runs in nonprod only if it has an `apps/appset-<app>.yaml`. Every other
`apps/<app>.yaml` is a prod-only Application. Exception: `appset-longhorn`
selects only nonprod — prod Longhorn stays on the legacy `apps/longhorn.yaml`
because the chart's helm pre-delete hook (Job `longhorn-uninstall`) makes Argo
pin PreDelete finalizers, and deleting that Application (cutover commit B)
would run the uninstall Job against prod.

Generated names: `<app>` on prod (unchanged from the legacy Application, so
resources re-adopt via the `argocd.argoproj.io/tracking-id` annotation) and
`<app>-nonprod`. Every generated Application carries label `env`.

## The two ApplicationSet shapes

Both use a `clusters` generator selecting `env In [prod, nonprod]`,
`goTemplate`, `applicationsSync: create-update` and
`preserveResourcesOnDeletion: true`.

- **Shape A — identical manifests.** The legacy spec verbatim, only
  `destination.server: '{{ .server }}'`. Example: `apps/appset-reloader.yaml`.
- **Shape B — per-env values.**
  - In-repo directory: converted to a chart in place (`Chart.yaml`,
    `templates/`, `values.yaml` = prod defaults, `values-prod.yaml`,
    `values-nonprod.yaml`); the template adds
    `helm.valueFiles: ['values-{{ index .metadata.labels "env" }}.yaml']`.
    Example: `workloads/metallb/`, `apps/appset-metallb-config.yaml`.
  - Upstream chart: multi-source; values at
    `workloads/<app>/values-<env>.yaml` (no `Chart.yaml`) read through a
    `ref: values` source. Example: `apps/appset-alloy.yaml`.
- Env-only Application-spec differences go in `templatePatch` so the prod spec
  stays byte-identical (`apps/appset-network-policies.yaml`,
  `apps/appset-crowdsec.yaml`).

## Converting another app

Run from the repo root, one app at a time, never batched. The tooling enforces
the gates; read `scripts/appset-cutover.sh` before the first use.

1. **Commit A — content only.** For Shape B, make the chart / values files
   with prod output unchanged. Prove it:
   - in-repo chart: `KUBECONFIG=<closet-as-admin, namespace argocd> nix shell nixpkgs#kubernetes-helm -c argocd --core app diff <app> --local workloads/<app> --local-repo-root .` prints nothing;
   - upstream chart: `scripts/legacy-to-appset.py <app> --extract-values workloads/<app>` then `scripts/chart-values-equiv.sh <app> workloads/<app>`.
   Commit, push, confirm the app is still `Synced Healthy` with no resource changed.
2. **Generate the ApplicationSet:** `scripts/legacy-to-appset.py <app>`
   (Shape A), `--values` (in-repo chart) or `--chart-values workloads/<app>`
   (upstream chart). Leave it uncommitted.
3. **Preview:** `scripts/appset-preview.sh <app>` must report the generated
   prod spec identical to the live one.
4. **Commits B + C:** `scripts/appset-cutover.sh <app>`. It refuses apps with
   pre/post-delete finalizers, records every tracked resource's uid, strips
   the resources finalizer, deletes `apps/<app>.yaml` (B), waits for the
   Application to disappear, commits the ApplicationSet (C), and checks the
   new owner, `Synced Healthy`, and identical uids. If B succeeded but C did
   not run, resume with `scripts/appset-cutover.sh <app> --resume-c`.
5. **Rollback** if a gate fails: revert C, then revert B; once the legacy app
   is back and `Synced`, re-add `resources-finalizer.argocd.argoproj.io`.
   Never fix a failed gate by deleting workloads or by a pruning sync.

Then check the nonprod side:
`kubectl --context closet-as-admin -n argocd get application <app>-nonprod`.
Anything that names a prod-only namespace, IP, hostname or Secret needs a
nonprod value or a `templatePatch`.

## Prod-side pieces that exist for nonprod

- `workloads/gateway/templates/dev-route.yaml` + listener
  `dev-john2143-wildcard-https`: `*.dev.john2143.com` and `au-dev.2143.me` →
  `192.168.7.7`, re-encrypted, validated against `nonprod-dev-ca.yaml`.
- `workloads/observability/lb-services.yaml` `tempo-otlp-lb` (`.6.27:4317`)
  and the np1-3 rule in `workloads/network-policies/observability.yaml`.
- Prod alert rules select prod series only: Mimir `cluster=""`, Loki
  `cluster="home"` (`workloads/observability/grafana-dashboards/*-alerts.yaml`,
  `alert-rules.yaml`). Keep that filter on any new rule.
