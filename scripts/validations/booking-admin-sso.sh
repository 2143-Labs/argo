#!/usr/bin/env bash
# The Easy!Appointments admin paths (everything on book.aross.studio except the
# public booking paths) must be gated twice: lan-only, and - when the
# Application sets sso true - a Pocket ID session for group "booking" checked by
# booking-oauth2-proxy. Easy!Appointments was retired on 2026-11-09 (no data
# existed) and book.aross.studio now serves Odoo's booking page, so this file
# has nothing to check until a restore adds an Application for
# workloads/booking again; the loop below then applies unchanged. Losing either gate silently reopens the admin surface,
# so this is an imperative check: policies/edge.yaml cannot express it, because
# its `auth:` assertions cover every rule of the host and the public booking
# rule must stay unauthenticated.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

source scripts/lib/inventory.sh
ri_init
fail=0
ri_files || fail=1
ri_require_files
ri_apps

n=0
while IFS=$'\t' read -r appf id want; do
  [[ -z "$id" ]] && continue
  n=$((n + 1))
  found=0
  # The admin rule is the only one matching a single PathPrefix "/" (the public
  # rule lists every booking path). Both rules report path "/" to
  # ri_route_stream, so select on the matches array instead.
  while IFS=$'\t' read -r file backend refs; do
    [[ -z "$backend" ]] && continue
    found=1
    file=$(ri_src "$file")
    if [[ "$refs" != *,lan-only,* ]]; then
      echo "::error file=$file::admin rule of $id lost lan-only; it is reachable from the internet"
      fail=1
    fi
    if [[ "$want" == "true" && "$backend" != "booking-oauth2-proxy" ]]; then
      echo "::error file=$file::sso=true but the admin rule of $id sends traffic to $backend instead of booking-oauth2-proxy"
      fail=1
    fi
    if [[ "$want" != "true" && "$backend" != "booking" ]]; then
      echo "::error file=$file::sso=$want but the admin rule of $id sends traffic to $backend instead of booking"
      fail=1
    fi
  done < <(yq e -N "filename as \$f | select(.kind == \"HTTPRoute\" and .metadata.namespace == \"default\" and .metadata.name == \"book-$id\") | .spec.rules[] | select((.matches | length) == 1 and .matches[0].path.type == \"PathPrefix\" and .matches[0].path.value == \"/\") | \$f + \"\t\" + (.backendRefs[0].name // \"-\") + \"\t\" + (\",\" + ([.filters[]? | select(.type == \"ExtensionRef\") | .extensionRef.name] | join(\",\")) + \",\")" "${RI_FILES[@]}")
  if [[ "$found" -eq 0 ]]; then
    echo "::error file=$appf::no admin rule (single PathPrefix /) found for book-$id"
    fail=1
  fi
done < <(
  for a in "${RI_APPS[@]}"; do
    [[ "$(yq e -N '.spec.source.path // ""' "$a")" == "workloads/booking" ]] || continue
    id=$(yq e -N '[(.spec.source.helm.parameters // [])[] | select(.name == "id")][0].value // ""' "$a")
    sso=$(yq e -N '[(.spec.source.helm.parameters // [])[] | select(.name == "sso")][0].value // ""' "$a")
    printf '%s\t%s\t%s\n' "$a" "$id" "$sso"
  done
)

# Deliberately not an error while Easy!Appointments is retired: the surface
# this guards does not exist. Re-adding an Application for workloads/booking
# brings the checks back automatically.
[[ "$n" -gt 0 ]] || { echo "booking admin sso: no workloads/booking application, nothing to check"; exit 0; }
[[ "$fail" -eq 0 ]] || exit 1
echo "booking admin sso OK: $n apps"
