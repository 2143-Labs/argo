#!/usr/bin/env bash
# The out-of-band CRS rule set must never be configured again. It scores every request
# with CRS defaults (tx.allowed_methods = GET HEAD POST OPTIONS), and six ordinary
# PATCH/PUT saves in 30 s become a 4 h IP ban on every stream-gated host, created by a
# component nobody can observe from home. Measured 2026-11-28: 41 bans in 7 days, 37
# redundant, 2 real people. docs/public-edge.md; board #606, plan #4 Step 3.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

shopt -s nullglob
files=(workloads/crowdsec/values-*.yaml)
[[ ${#files[@]} -gt 0 ]] || { echo "::error::no workloads/crowdsec/values-*.yaml found; refusing to pass"; exit 1; }

fail=0
n=0
for f in "${files[@]}"; do
  while IFS= read -r name; do
    [[ -z "$name" || "$name" == "null" ]] && continue
    n=$((n + 1))
    count=$(yq e -N ".appsec.configs[\"$name\"]" "$f" | yq e -N '.outofband_rules | length' -)
    if [[ "$count" != "0" ]]; then
      echo "::error file=$f::appsec config $name defines outofband_rules ($count); CRS out-of-band bans real clients"
      fail=1
    fi
  done < <(yq e -N '.appsec.configs | keys | .[]' "$f")
done

[[ "$n" -gt 0 ]] || { echo "::error::scanned 0 appsec configs; refusing to pass"; exit 1; }
[[ "$fail" -eq 0 ]] || exit 1
echo "appsec-no-outofband OK: $n configs"
