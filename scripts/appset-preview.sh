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
got = prod[0]["spec"]
if got != want:
    print("FAIL: spec differs")
    print("live:", json.dumps(want, indent=1, sort_keys=True))
    print("gen: ", json.dumps(got, indent=1, sort_keys=True))
    sys.exit(1)
print(f"ok: generated {names}; prod spec identical to live")
PY
