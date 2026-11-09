# CI validations: what each check protects, and how to add one

Seven GitHub Actions workflows check this repo. Each one runs a script under
`scripts/` in the flake shell (`nix develop --fallback -c ./scripts/<name>.sh`),
and each job is its own workflow so a red check names the thing that is wrong.

They are **advisory**: required status checks are a GitHub repository setting,
not a file here. Treat a red check as a bug in the change that caused it, not as
a formality to re-run.

Every check that scans manifests renders the Helm charts too (see
[The inventory](#the-inventory)). Before this, three checks skipped
`*/templates/`, and the seven renderable route-bearing charts — 32 HTTPRoutes,
98 rules — were invisible to CI.

## The checks

| Workflow / job | Script | What it protects | Scans today | Cannot see |
|---|---|---|---|---|
| Validate doc links / Links, anchors and guide paths resolve | `scripts/validate-doc-links.sh` | Every relative link and `#anchor` in `docs/*.md` resolves; every inline-code repo path in a guide under "## Guides" exists | All tracked `docs/*.md` (no paths filter) | Links inside fenced code blocks (they are examples, not links) |
| Validate gateway certs / Listener secrets backed by Certificates | `scripts/validate-gateway-certs.sh` | A listener's Secret is written by exactly one Certificate; every listener hostname is covered by that Certificate's dnsNames; every route parentRef pins a real `sectionName`; every route hostname is served by a pinned listener; no BackendTLSPolicy exists | Plain `apps/` + `workloads/` manifests and every rendered edge chart | Multi-source Applications, charts generated per pull request |
| Validate route gates / Every HTTPRoute rule carries an edge gate | `scripts/validate-route-gates.sh` | No rule reaches the internet ungated: `.ts.2143.me` rules carry `lan-only`, every other rule carries a bouncer or the uploads tier, and each line of `scripts/route-gate-exemptions.txt` still names an ungated rule | Plain manifests, rendered charts, and routes embedded in Application `helm.values` | Multi-source Applications, charts generated per pull request |
| Validate route gates / Every game app is tagged and uses the game-edge library | `scripts/validate-game-edge.sh` | The `edge.2143.me/class: game` tag and the `helm_modules/game-edge` dependency are never carried one without the other | `apps/*.yaml` and the `Chart.yaml` dependencies they name | Not a manifest check: it renders nothing |
| Validate LAN DNS zones / Route hostnames inside lan-dns zones | `scripts/validate-lan-dns-zones.sh` | Every route hostname is inside a `lan-dns` zone, or the route carries `k8s-gateway.dns/ignore: "true"`; the Corefile's zone line and its k8s_gateway line agree | Plain manifests and rendered charts | Routes embedded in Application `helm.values` strings |
| Validate headscale DNS / Tailnet records match .ts routes | `scripts/validate-headscale-dns.sh` | Every `*.ts.2143.me` route hostname has an `extra_records` entry, every entry names a route hostname (public ones allowed: the booking sites), each `type A` at the shared-gateway address | Plain manifests, rendered charts, routes in `helm.values` | Multi-source Applications |
| Validate VPN endpoints / Render and validate chart | `scripts/validate-vpn-endpoints.sh` | The `vpn-endpoints` chart renders deterministically (two byte-identical renders per replica state) and only the expected objects, with narrow RBAC and no secrets in env | Its own chart, rendered with the ApplicationSet's parameters | It is single-purpose; it does not scan the repo |
| Validate policies / Declared edge policy holds | `scripts/validate-policies.sh` | Every assertion in `policies/*.yaml` holds for every route that lists a matching hostname, and every imperative check in scripts/validations/ passes | Plain manifests, rendered charts, routes in `helm.values`, and every Middleware in those | Multi-source Applications, charts generated per pull request |

## The inventory

`scripts/lib/inventory.sh` is the one place that decides what "a manifest" means.
Nothing else may call `helm template`.

```
source scripts/lib/inventory.sh
ri_init                      # tmpdir + trap; declares RI_CHART_SRC
ri_files || fail=1           # fills RI_FILES (repo YAML + one render per chart), RI_FAIL
ri_apps                      # fills RI_APPS (apps/*.yaml)
ri_require_files             # exits 1 if RI_FILES is empty
```

- `RI_FILES` — tracked `apps/` and `workloads/` YAML minus `*/templates/`, plus
  one rendered manifest per Helm chart that emits a `Gateway`, `HTTPRoute`,
  `TLSRoute`, `GRPCRoute`, `Middleware` or `Certificate`.
- `ri_src <file>` — the file to print in an annotation: a render maps back to
  its chart's `workloads/<chart>/templates`, so an `::error file=` never points
  at `/tmp`.
- `ri_rendered_for <chart-path>` — the rendered manifest(s) of one chart.
- `ri_route_stream` — one line per HTTPRoute rule over `RI_FILES` plus routes
  embedded in Application `helm.values`: file, `ns/name`, path, hostnames,
  ExtensionRef names, filter types (comma-wrapped, never empty). Call `ri_apps`
  first.

The render contract: a chart is rendered **the way the Application or
ApplicationSet that owns it renders it** — its `helm.parameters` (as `--set`,
or `--set-string` when the parameter sets `forceString: true`, which is Argo
CD's own rule), its `helm.valueFiles` (relative to the chart, `$values/` from
the repo root), and its inline `helm.values`. `{{ index .metadata.labels "env"
}}` resolves to `prod`, so `appset-gateway.yaml`'s
`values-{{ index .metadata.labels "env" }}.yaml` becomes `values-prod.yaml`.
`--dependency-update` is load-bearing: `workloads/*/charts/` is gitignored, so a
fresh checkout has no vendored `game-edge`, and all four game charts pull it from
`file://../../helm_modules/game-edge` (no network).

Not rendered, and reported in a `note:` line: ApplicationSets whose generators
include `pullRequest` (five of them — their values come from PR metadata), and
multi-source Applications (`.spec.sources[]`).

A validator **must** call `ri_require_files`, and should floor its own counts on
top of that. Three checks used to be able to pass while scanning nothing: a
move of a file, or a deleted path, turned them green. Every check now fails
loudly when its scan is empty:

| Script | Floor |
|---|---|
| `scripts/validate-route-gates.sh` | at least one route rule |
| `scripts/validate-lan-dns-zones.sh` | at least one route hostname |
| `scripts/validate-headscale-dns.sh` | at least one `.ts` route hostname |
| `scripts/validate-gateway-certs.sh` | the gateway chart rendered, and `shared-gateway` has listeners |
| `scripts/validate-vpn-endpoints.sh` | the expected element inventory is not empty |
| `scripts/validate-doc-links.sh` | at least one link and one guide path |
| `scripts/validate-policies.sh` | at least one assertion file, and a chart render for every chart that fails to render is an error |

## Add a declarative check

Most "this site must…" rules belong in `policies/edge.yaml`. One assertion is a
`hosts` list of bash case patterns (case-insensitive) plus any of:

| Key | Means |
|---|---|
| `exposure: private` | every matching rule references Middleware `lan-only` |
| `gates: [names]` | every matching rule references each of these Middlewares |
| `gates_any: [names]` | every matching rule references at least one of them |
| `auth: [spec keys]` | every matching rule references a Middleware that resolves in the rule's namespace (they are namespace-local) and whose spec has one of these keys |

Rules whose filters include `RequestRedirect` are skipped: they never reach a
backend. **An assertion that matches no route hostname is an error** — a policy
that silently stops applying is worse than no policy. Delete the assertion when
the hostname is gone; never soften it to get green.

Two recipes:

```yaml
  # This site must have auth: either a basic-auth htpasswd file or an
  # oauth2-proxy forwardAuth.
  - hosts: ["sites.john2143.com"]
    auth: [basicAuth, forwardAuth]

  # This site must not be public: only LAN and tailnet clients may reach it.
  - hosts: ["nas.john2143.com"]
    exposure: private
```

Run `./scripts/validate-policies.sh` after editing; the failure message names
the route, the rule and the missing filter.

## Add an imperative check

Anything a declarative assertion cannot express (a count, a rendered-object
shape, a cross-file set equality) goes in a script under
scripts/validations/. The evaluator runs every non-underscore `*.sh` there and
counts its exit status; a missing directory is not an error, and there is no
registration step. A leading `_` excludes a file (drafts, helpers).

```bash
#!/usr/bin/env bash
# Why this exists, and which invariant it protects.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

source scripts/lib/inventory.sh
ri_init
fail=0
ri_files || fail=1
ri_require_files

n=0
while read -r f name; do
  [[ -z "$name" ]] && continue
  n=$((n + 1))
  # ... assert something about $f ...
done < <(yq e -N 'select(.kind == "HTTPRoute") | .metadata.name as $n | filename + " " + $n' "${RI_FILES[@]}")

[[ "$n" -gt 0 ]] || { echo "::error::scanned 0 routes; refusing to pass"; exit 1; }
[[ "$fail" -eq 0 ]] || exit 1
echo "OK: $n routes"
```

Rules for the script: source `scripts/lib/inventory.sh` instead of calling
`helm template`; print the source with `$(ri_src "$f")` in every `::error
file=…` annotation; floor its own count; exit non-zero on failure. CI picks it up
through `Validate policies` — remember to widen that workflow's `paths:` filter
if the check reads files outside `apps/`, `workloads/`, `policies/` and
`scripts/`.

## Before you push

```
nix develop -c ./scripts/validate-all.sh
```

One command, every check, one `ok`/`FAIL` line each. It runs the same scripts CI
runs (CI adds the nix layer and a separate job per check).

The rule behind all of this: **a check whose scan finds nothing must fail.**
Adding a check that can silently pass is how a green build stops meaning
anything.
