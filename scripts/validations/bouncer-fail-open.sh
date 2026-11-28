#!/usr/bin/env bash
# Every CrowdSec bouncer Middleware must fail open when the LAPI is unreachable: the
# plugin's updateMaxFailure default (0) flips a package-global health flag on the first
# failed stream poll, and every stream-gated host then answers 403 until a poll succeeds
# (measured 2026-11-27 08:36-08:42: ~77 requests on three hosts). One copy left at 0
# keeps the wall, so the number of copies is asserted too.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

files=(
  workloads/gateway/templates/security-middlewares.yaml
  workloads/pocket-id/templates/security-middlewares.yaml
  workloads/stalwart/security-middlewares.yaml
)

emit() { # emit <file> <yq path to the documents>
  yq e -N "$2 | select(.kind == \"Middleware\") | select(.spec.plugin.bouncer) \
    | .metadata.name + \"\t\" + (.spec.plugin.bouncer.updateMaxFailure // \"unset\" | tostring)" "$1"
}

fail=0
n=0
for f in "${files[@]}"; do
  [[ -f "$f" ]] || { echo "::error file=$f::missing"; fail=1; continue; }
  while IFS=$'\t' read -r name v; do
    [[ -z "$name" ]] && continue
    n=$((n + 1))
    [[ "$v" == "-1" ]] || { echo "::error file=$f::Middleware $name has updateMaxFailure=$v, want -1"; fail=1; }
  done < <(emit "$f" '.')
done

while IFS=$'\t' read -r name v; do
  [[ -z "$name" ]] && continue
  n=$((n + 1))
  [[ "$v" == "-1" ]] || { echo "::error file=apps/openbao.yaml::Middleware $name has updateMaxFailure=$v, want -1"; fail=1; }
done < <(emit apps/openbao.yaml '.spec.source.helm.values | from_yaml | .extraObjects[]')

[[ "$n" -eq 7 ]] || { echo "::error::found $n CrowdSec bouncer Middlewares, expected 7"; fail=1; }
[[ "$fail" -eq 0 ]] || exit 1
echo "bouncer-fail-open OK: $n middlewares"
