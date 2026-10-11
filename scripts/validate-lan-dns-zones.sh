#!/usr/bin/env bash
# Every Gateway API route hostname must be inside a lan-dns zone, so LAN
# clients and pods resolve it to the gateway instead of hairpinning through
# the WAN. Read docs/lan-dns.md.
#
# 1. The zone line after "# lan-dns-zones" in the lan-dns Corefile and the
#    zones on its k8s_gateway line must be identical.
# 2. Every hostname of an HTTPRoute/TLSRoute/GRPCRoute in apps/ or workloads/
#    is one of those zones or a subdomain of one, unless the route carries
#    k8s-gateway.dns/ignore: "true" (it is meant to resolve publicly).
#
# Not checkable here: the router FWD entries and dotfiles coredns-custom must
# carry the same zones (docs/lan-dns.md, "Adding a new domain"). Routes embedded
# as strings in Helm values (e.g. apps/openbao.yaml) are not seen.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

cm=workloads/lan-dns/configmap.yaml
corefile=$(yq e -N 'select(.kind == "ConfigMap" and .metadata.name == "lan-dns-corefile") | .data.Corefile' "$cm")
header=$(awk '/^# lan-dns-zones/{getline; gsub(/:1053/, ""); gsub(/[{]/, ""); print; exit}' <<<"$corefile" | xargs -n1 | sort -u)
plugin=$(awk '$1 == "k8s_gateway" {for (i = 2; i <= NF; i++) if ($i != "{") print $i; exit}' <<<"$corefile" | sort -u)

fail=0
if [[ -z "$header" ]]; then
  echo "::error file=$cm::no zone line after '# lan-dns-zones' in the Corefile"
  exit 1
fi
if [[ "$header" != "$plugin" ]]; then
  echo "::error file=$cm::the zone line after '# lan-dns-zones' and the k8s_gateway line list different zones"
  fail=1
fi
mapfile -t zones <<<"$header"

mapfile -t files < <(git ls-files 'apps/*.yaml' 'apps/*.yml' 'workloads/*.yaml' 'workloads/*.yml' | grep -v '/templates/')
n=0
while read -r f h; do
  [[ -z "$h" || "$h" == \** ]] && continue
  n=$((n + 1))
  ok=0
  for z in "${zones[@]}"; do
    if [[ "$h" == "$z" || "$h" == *".$z" ]]; then ok=1; break; fi
  done
  if [[ "$ok" -eq 0 ]]; then
    echo "::error file=$f::route hostname $h is not inside any lan-dns zone; LAN clients and pods would hairpin through the WAN. Add the zone as described in docs/lan-dns.md, or label the route k8s-gateway.dns/ignore: \"true\" if it must resolve publicly"
    fail=1
  fi
done < <(yq e -N 'select(.kind == "HTTPRoute" or .kind == "TLSRoute" or .kind == "GRPCRoute") | select((.metadata.labels."k8s-gateway.dns/ignore" // "") != "true") | .spec.hostnames[]? as $h | filename + " " + $h' "${files[@]}")

[[ "$fail" -eq 0 ]] || exit 1
echo "lan-dns zones OK: ${#zones[@]} zones cover $n route hostnames"
