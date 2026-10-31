#!/usr/bin/env bash
# Gate before cutover C: the ApplicationSet must generate a prod Application
# named exactly <app> whose spec equals the live legacy Application's spec.
# Usage: scripts/appset-preview.sh <app>
set -euo pipefail
app="$1"
ctx="${CTX:-closet-as-admin}"
kc="$(mktemp)"; trap 'rm -f "$kc" /tmp/appset-preview-$app.*' EXIT
kubectl config view --minify --flatten --context "$ctx" > "$kc"
KUBECONFIG="$kc" kubectl config set-context --current --namespace=argocd >/dev/null
KUBECONFIG="$kc" argocd --core appset generate "apps/appset-$app.yaml" -o json > "/tmp/appset-preview-$app.gen"
kubectl --context "$ctx" -n argocd get application "$app" -o json > "/tmp/appset-preview-$app.live"
python3 - "$app" "/tmp/appset-preview-$app.gen" "/tmp/appset-preview-$app.live" <<'PY'
import json, sys
app, gen, live = sys.argv[1], json.load(open(sys.argv[2])), json.load(open(sys.argv[3]))
items = gen if isinstance(gen, list) else gen.get("items", [gen])
names = [i["metadata"]["name"] for i in items]
prod = [i for i in items if i["metadata"]["name"] == app]
if len(prod) != 1:
    sys.exit(f"FAIL: generated {names}, expected exactly one '{app}'")
want = live["spec"]
got = json.loads(json.dumps(prod[0]["spec"]))
# Shape B: the only permitted difference is helm.valueFiles == [values-prod.yaml]
# (values-prod.yaml must equal the chart's values.yaml — gate A checked that).
src = got.get("source", {})
if src.get("helm", {}).get("valueFiles") == ["values-prod.yaml"] and "helm" not in want.get("source", {}):
    src["helm"].pop("valueFiles")
    if not src["helm"]:
        src.pop("helm")
    print("note: ignoring the Shape B helm.valueFiles [values-prod.yaml]")
# Upstream-chart Shape B: sources[0] is the legacy source with inline values
# replaced by $values/<dir>/values-prod.yaml (equivalence proven by
# chart-values-equiv.sh), sources[1] is the `ref: values` repo.
if "sources" in got and "source" in want:
    s0, s1 = got["sources"]
    if s1 != {"repoURL": "https://github.com/2143-Labs/argo.git", "targetRevision": "HEAD", "ref": "values"}:
        sys.exit(f"FAIL: unexpected second source {s1}")
    vf = s0.get("helm", {}).pop("valueFiles", [])
    if len(vf) != 1 or not vf[0].startswith("$values/") or not vf[0].endswith("/values-prod.yaml"):
        sys.exit(f"FAIL: unexpected valueFiles {vf}")
    w = json.loads(json.dumps(want))
    w["source"].get("helm", {}).pop("values", None)
    if not w["source"].get("helm"):
        w["source"].pop("helm", None)
    if not s0.get("helm"):
        s0.pop("helm", None)
    got.pop("sources"); got["source"] = s0
    want = w
    print(f"note: multi-source; compared sources[0] minus {vf[0]} against legacy source minus inline values")
# Go omitempty drops `group: ""` in generated ignoreDifferences; an empty and
# an absent group are the same (core API group) to Argo's diff normaliser.
def norm(spec):
    spec = json.loads(json.dumps(spec))
    for d in spec.get("ignoreDifferences", []):
        if d.get("group") == "":
            d.pop("group")
    return spec
got, want = norm(got), norm(want)
if got != want:
    print("FAIL: spec differs")
    print("live:", json.dumps(want, indent=1, sort_keys=True))
    print("gen: ", json.dumps(got, indent=1, sort_keys=True))
    sys.exit(1)
print(f"ok: generated {names}; prod spec identical to live")
PY
