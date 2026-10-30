#!/usr/bin/env python3
"""Write apps/appset-<app>.yaml from a legacy apps/<app>.yaml, verbatim.

Shape A (identical manifests in prod and nonprod): the Application spec is
copied byte-for-byte as the ApplicationSet template; only
`destination.server` becomes `{{ .server }}` and the name/label become
env-aware. Text-level transform (no YAML round-trip) so comments, ordering
and block scalars survive exactly.

Usage: scripts/legacy-to-appset.py <app>
"""
import re
import sys

app = sys.argv[1]
src = open(f"apps/{app}.yaml").read()

m = re.search(r"^spec:\n", src, re.M)
if not m:
    sys.exit("no top-level spec:")
spec = src[m.end():]
if not spec.endswith("\n"):
    spec += "\n"

n = spec.count("server: https://kubernetes.default.svc")
if n != 1:
    sys.exit(f"expected exactly one destination server line, found {n}")
spec = spec.replace("server: https://kubernetes.default.svc", "server: '{{ .server }}'")
if "{{" in spec.replace("'{{ .server }}'", ""):
    sys.exit("legacy spec already contains '{{' — would be read as a Go template; handle by hand")

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
    spec:
{body}"""
open(f"apps/appset-{app}.yaml", "w").write(out)
print(f"wrote apps/appset-{app}.yaml")
