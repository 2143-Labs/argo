#!/usr/bin/env bash
# Gate A for upstream-chart apps: rendering the chart with the legacy inline
# values and with <dir>/values-prod.yaml must yield identical manifests.
# Usage: scripts/chart-values-equiv.sh <app> <dir>   (run before git rm of apps/<app>.yaml)
set -euo pipefail
app="$1"; dir="$2"
py=/tmp/pyy/bin/python3
[ -x "$py" ] || nix build --impure --expr 'with import <nixpkgs> {}; python3.withPackages (p: [p.pyyaml])' -o /tmp/pyy >/dev/null
src="$(git show "HEAD:apps/$app.yaml" 2>/dev/null || cat "apps/$app.yaml")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '%s' "$src" | "$py" -c '
import sys, yaml
s = yaml.safe_load(sys.stdin)["spec"]["source"]
open(sys.argv[1] + "/meta", "w").write("\n".join([s["repoURL"], s["chart"], s["targetRevision"], s.get("helm", {}).get("releaseName", s["chart"])]))
open(sys.argv[1] + "/inline.yaml", "w").write(s.get("helm", {}).get("values", ""))
' "$tmp"
mapfile -t m < "$tmp/meta"
ns="$(printf '%s' "$src" | "$py" -c 'import sys,yaml;print(yaml.safe_load(sys.stdin)["spec"]["destination"]["namespace"])')"
export HELM_CONFIG_HOME="$tmp/hc" HELM_CACHE_HOME="$tmp/hcache" HELM_DATA_HOME="$tmp/hd"
H=(nix shell nixpkgs#kubernetes-helm -c helm)
"${H[@]}" template "${m[3]}" "${m[1]}" --repo "${m[0]}" --version "${m[2]}" -n "$ns" -f "$tmp/inline.yaml" > "$tmp/a.yaml"
"${H[@]}" template "${m[3]}" "${m[1]}" --repo "${m[0]}" --version "${m[2]}" -n "$ns" -f "$dir/values-prod.yaml" > "$tmp/b.yaml"
"$py" - "$tmp/a.yaml" "$tmp/b.yaml" <<'PY'
import sys, yaml
def load(p):
    return sorted((d for d in yaml.safe_load_all(open(p)) if d), key=lambda d: (d.get("kind", ""), d.get("metadata", {}).get("namespace", ""), d.get("metadata", {}).get("name", "")))
a, b = load(sys.argv[1]), load(sys.argv[2])
if a != b:
    sys.exit(f"FAIL: renders differ ({len(a)} vs {len(b)} objects)")
print(f"ok: {len(a)} objects, inline values == values-prod.yaml")
PY
