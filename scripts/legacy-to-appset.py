#!/usr/bin/env python3
"""Write apps/appset-<app>.yaml from a legacy apps/<app>.yaml, verbatim.

Shape A (identical manifests in prod and nonprod): the Application spec is
copied byte-for-byte as the ApplicationSet template; only
`destination.server` becomes `{{ .server }}` and the name/label become
env-aware. Text-level transform (no YAML round-trip) so comments, ordering
and block scalars survive exactly.

Shape B (--values): the app is a chart in-repo (dir -> chart) whose
`source.path` gains `helm.valueFiles: [values-<env>.yaml]`. Requires a
single `source:` with `path:` and no existing `helm:` block.

Shape B for upstream charts (--chart-values <dir>): the legacy single
`source:` (chart/repoURL/targetRevision/helm.releaseName + inline values)
becomes multi-source: the chart source with
`helm.valueFiles: [$values/<dir>/values-<env>.yaml]` (inline `values:` dropped)
plus a `ref: values` source for this repo. <dir>/values-prod.yaml must hold the
legacy inline values verbatim (extract_values() writes it).

Usage: scripts/legacy-to-appset.py <app> [--values | --chart-values <dir> | --extract-values <dir>]
"""
import re
import sys

app = sys.argv[1]
shape_b = "--values" in sys.argv[2:]
chart_dir = sys.argv[sys.argv.index("--chart-values") + 1] if "--chart-values" in sys.argv else None
extract_dir = sys.argv[sys.argv.index("--extract-values") + 1] if "--extract-values" in sys.argv else None
src = open(f"apps/{app}.yaml").read()

m = re.search(r"^spec:\n", src, re.M)
if not m:
    sys.exit("no top-level spec:")
spec = src[m.end():]
if not spec.endswith("\n"):
    spec += "\n"

def inline_values(spec):
    """Return (start, end, dedented text) of `      values: |` block in the single source."""
    vm = re.search(r"^      values: \|\n((?:(?:        .*)?\n)+)", spec, re.M)
    if not vm:
        sys.exit("no inline `values: |` block at source.helm.values")
    lines = vm.group(1).splitlines(keepends=True)
    # trailing blank lines belong to the YAML gap, not the values
    while lines and not lines[-1].strip():
        lines.pop()
    text = "".join(l[8:] if l.strip() else "\n" for l in lines)
    return vm.start(), vm.start() + len("      values: |\n") + sum(len(l) for l in lines), text

if extract_dir:
    _, _, text = inline_values(spec)
    open(f"{extract_dir}/values-prod.yaml", "w").write(text)
    print(f"wrote {extract_dir}/values-prod.yaml ({len(text.splitlines())} lines)")
    sys.exit(0)

if chart_dir:
    if spec.count("  source:\n") != 1:
        sys.exit("--chart-values needs exactly one source:")
    a, b, _ = inline_values(spec)
    spec = spec[:a] + f"      valueFiles:\n        - '$values/{chart_dir}/values-{{{{ index .metadata.labels \"env\" }}}}.yaml'\n" + spec[b:]
    sm = re.search(r"^  source:\n((?:    .*\n|\s*\n)*?)(?=^  \S)", spec, re.M)
    block = sm.group(1)
    bl = block.splitlines(keepends=True)
    # first line "    chart: x" -> "    - chart: x"; the rest gain two spaces of indent
    bl = ["    - " + bl[0][4:]] + [("  " + l if l.strip() else l) for l in bl[1:]]
    block = "".join(bl)
    ref = "    - repoURL: https://github.com/2143-Labs/argo.git\n      targetRevision: HEAD\n      ref: values\n"
    spec = spec[:sm.start()] + "  sources:\n" + block + ref + spec[sm.end():]

n = spec.count("server: https://kubernetes.default.svc")
if n != 1:
    sys.exit(f"expected exactly one destination server line, found {n}")
spec = spec.replace("server: https://kubernetes.default.svc", "server: '{{ .server }}'")
if "{{" in re.sub(r"'[^'\n]*values-\{\{ index \.metadata\.labels \"env\" \}\}\.yaml'", "", spec).replace("'{{ .server }}'", ""):
    sys.exit("legacy spec already contains '{{' — would be read as a Go template; handle by hand")

# metadata.annotations (e.g. sync-wave) carry over verbatim into the template.
ann = ""
am = re.search(r"^  annotations:\n((?:    .*\n|\s*\n)+)", src[:m.start()], re.M)
if am:
    ann = "      annotations:\n" + "".join("    " + l if l.strip() else "\n" for l in am.group(1).splitlines(keepends=True))

if shape_b:
    if spec.count("source:") != 1 or "helm:" in spec:
        sys.exit("--values needs exactly one source: and no helm: block")
    pm = re.search(r"^(  source:\n(?:    .*\n)*?)(    path: (\S+)\n)", spec, re.M)
    if not pm:
        sys.exit("--values: no source.path")
    spec = spec[:pm.end()] + "    helm:\n      valueFiles:\n        - 'values-{{ index .metadata.labels \"env\" }}.yaml'\n" + spec[pm.end():]

body = "".join("    " + line if line.strip() else "\n" for line in spec.splitlines(keepends=True))

out = f"""# Converted from apps/{app}.yaml (bigp nonprod plan, Step 6.0); spec verbatim.
# One Application per cluster labelled env=prod|nonprod: `{app}` on prod
# (name unchanged, re-adopts via tracking-id) and `{app}-nonprod`.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: appset-{app}
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  syncPolicy:
    applicationsSync: create-update
    preserveResourcesOnDeletion: true
  generators:
    - clusters:
        selector:
          matchExpressions:
            - key: env
              operator: In
              values: [prod, nonprod]
  template:
    metadata:
      name: '{app}{{{{ if ne (index .metadata.labels "env") "prod" }}}}-{{{{ index .metadata.labels "env" }}}}{{{{ end }}}}'
      labels:
        env: '{{{{ index .metadata.labels "env" }}}}'
{ann}    spec:
{body}"""
open(f"apps/appset-{app}.yaml", "w").write(out)
print(f"wrote apps/appset-{app}.yaml")
