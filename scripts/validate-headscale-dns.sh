#!/usr/bin/env bash
# Every *.ts.2143.me route hostname needs a headscale extra_records entry, and
# every entry needs a route. Tailnet clients resolve .ts names only through
# headscale MagicDNS (docs/adding-a-workload.md §3c): a missing record makes
# the app unreachable on the tailnet, and a record without a route is stale.
#
# 1. Records: dns.extra_records in the config.yaml of ConfigMap
#    headscale-config. Each must be type A with the shared-gateway address.
# 2. Route hostnames ending in .ts.2143.me, from HTTPRoute/TLSRoute/GRPCRoute
#    in apps/ and workloads/, plus routes embedded in Helm values strings
#    (.spec.source.helm.values -> extraObjects, e.g. apps/openbao.yaml).
# 3. The two sets must be identical.
#
# Not scanned: multi-source Applications (.spec.sources[]).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# The shared-gateway (traefik) LoadBalancer address: the traefik row of the IP
# allocation table in docs/adding-a-workload.md §5.
gateway_ip=192.168.6.11
cm=workloads/headscale/configmap.yaml
route_kinds='.kind == "HTTPRoute" or .kind == "TLSRoute" or .kind == "GRPCRoute"'

config=$(yq e -N 'select(.kind == "ConfigMap" and .metadata.name == "headscale-config") | .data."config.yaml"' "$cm")
if [[ -z "$config" ]]; then
  echo "::error file=$cm::ConfigMap headscale-config has no config.yaml"
  exit 1
fi

fail=0
declare -A records=()
while read -r name type value; do
  [[ -z "$name" ]] && continue
  records["$name"]=1
  if [[ "$type" != "A" || "$value" != "$gateway_ip" ]]; then
    echo "::error file=$cm::headscale record $name must be type A with value $gateway_ip (the shared-gateway address)"
    fail=1
  fi
done < <(yq e -N '.dns.extra_records[]? | .name + " " + .type + " " + .value' - <<<"$config")

mapfile -t files < <(git ls-files 'apps/*.yaml' 'apps/*.yml' 'workloads/*.yaml' 'workloads/*.yml' | grep -v '/templates/')
mapfile -t apps < <(git ls-files 'apps/*.yaml' 'apps/*.yml')

declare -A routes=()
while read -r f h; do
  [[ "$h" == *.ts.2143.me && "$h" != \** ]] || continue
  [[ -n "${routes[$h]:-}" ]] || routes["$h"]=$f
done < <(
  yq e -N "select($route_kinds) | .spec.hostnames[]? as \$h | filename + \" \" + \$h" "${files[@]}"
  yq e -N "filename as \$f | select(.kind == \"Application\") | (.spec.source.helm.values // \"\") | select(. != \"\") | from_yaml | .extraObjects[]? | select($route_kinds) | .spec.hostnames[]? as \$h | \$f + \" \" + \$h" "${apps[@]}"
)

for h in "${!routes[@]}"; do
  if [[ -z "${records[$h]:-}" ]]; then
    echo "::error file=${routes[$h]}::route hostname $h has no headscale extra_records entry; tailnet clients cannot resolve it"
    fail=1
  fi
done
for h in "${!records[@]}"; do
  if [[ -z "${routes[$h]:-}" ]]; then
    echo "::error file=$cm::headscale record $h has no route; remove it"
    fail=1
  fi
done

[[ "$fail" -eq 0 ]] || exit 1
echo "headscale DNS OK: ${#records[@]} records match ${#routes[@]} .ts route hostnames"
