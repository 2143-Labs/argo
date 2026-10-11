#!/usr/bin/env bash
# What does a resolver answer for every name lan-dns is responsible for, versus
# what it should answer? Read docs/lan-dns.md.
#
#   nix develop -c ./scripts/check-lan-dns.sh [RESOLVER]
#
# RESOLVER: 192.168.5.1 (default; the router = what LAN clients see),
#           192.168.6.30 (lan-dns itself), 10.43.0.10 (kube-dns = what pods see).
# Needs kubectl (context $KUBE_CONTEXT, default closet-as-admin), yq-go and dig.
# Expected answers: route hostname -> shared-gateway's IPv4 status address;
# route labelled k8s-gateway.dns/ignore -> whatever 1.1.1.1 answers; name in the
# Corefile hosts block -> that IP. Route hostnames outside the zones: UNCOVERED.
# Exit 0 only if every row is OK.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
R="${1:-192.168.5.1}"
CTX="${KUBE_CONTEXT:-closet-as-admin}"
a() { dig +short +time=2 +tries=1 "@$1" "$2" A | grep -E '^[0-9.]+$' | tail -1; }

corefile=$(yq e -N 'select(.kind == "ConfigMap" and .metadata.name == "lan-dns-corefile") | .data.Corefile' workloads/lan-dns/configmap.yaml)
read -r -a zones <<<"$(awk '/^# lan-dns-zones/{getline; gsub(/:1053/, ""); gsub(/[{]/, ""); print; exit}' <<<"$corefile")"
hosts=$(awk '/^ *hosts *\{/{f=1; next} f && /^ *\}/{f=0} f && $1 ~ /^[0-9.]+$/ {for (i = 2; i <= NF; i++) print $i " " $1}' <<<"$corefile")
gw=$(kubectl --context "$CTX" -n default get gateway shared-gateway -o jsonpath='{range .status.addresses[*]}{.value}{"\n"}{end}' | grep -E '^[0-9.]+$' | head -1)
[[ -n "$gw" ]] || { echo "shared-gateway has no IPv4 status address" >&2; exit 2; }
routes=$(kubectl --context "$CTX" get httproute,tlsroute,grpcroute -A -o yaml \
  | yq e -N '.items[] | (.metadata.labels."k8s-gateway.dns/ignore" // "false") as $i | .spec.hostnames[]? | . + " " + $i' - | sort -u)

fail=0
row() { printf '%-40s %-16s %-16s %s\n' "$@"; }
check() { local got; got=$(a "$R" "$1"); if [[ "$got" == "$2" ]]; then row "$1" "$2" "${got:--}" OK; else row "$1" "$2" "${got:--}" MISMATCH; fail=1; fi; }
in_zone() { local z; for z in "${zones[@]}"; do [[ "$1" == "$z" || "$1" == *".$z" ]] && return 0; done; return 1; }
in_hosts() { awk -v h="$1" '$1 == h {f = 1} END {exit !f}' <<<"$hosts"; }

echo "resolver $R, gateway $gw, zones: ${zones[*]}"
row NAME EXPECTED GOT RESULT
while read -r h ign; do
  [[ -z "$h" || "$h" == \** ]] && continue
  in_hosts "$h" && continue
  if ! in_zone "$h"; then row "$h" - - UNCOVERED; fail=1; continue; fi
  if [[ "$ign" == true ]]; then check "$h" "$(a 1.1.1.1 "$h")"; else check "$h" "$gw"; fi
done <<<"$routes"
while read -r h ip; do [[ -n "$h" ]] && check "$h" "$ip"; done <<<"$hosts"
exit "$fail"
