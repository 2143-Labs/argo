#!/usr/bin/env bash
# Keeps Gateway TLS renewable by cert-manager.
#
# 1. No duplicate mapping keys in any manifest. A missing `---` between two
#    manifests merges them into one mapping; YAML parsers keep the last value
#    and silently drop the earlier manifest. That is how the
#    rots-2143-me-wildcard and aross-studio-tls Certificates disappeared from
#    the cluster (4610198, 1aea132) and stopped renewing.
# 2. Every Secret a Gateway listener serves is the secretName of exactly one
#    Certificate in the same namespace (metadata.namespace must be explicit).
# 3. Every listener hostname is covered by its Certificate's dnsNames (exact,
#    or a "*." wildcard one label up; wildcards don't cover deeper subdomains).
# 4. Every HTTPRoute/TLSRoute/GRPCRoute parentRef to shared-gateway pins a
#    sectionName that names one of its listeners (routes embedded in
#    Application helm values strings included, as in validate-headscale-dns.sh).
# 5. Every route hostname is served by one of its pinned listeners (Traefik's
#    hostname match), and on TLS-terminating listeners is covered by the
#    Certificate's dnsNames.
# 6. shared-gateway has at most 16 listeners: Traefik writes one
#    BackendTLSPolicy ancestor per listener and fails status writes beyond 16.
#
# Helm chart templates (*/templates/*) are not plain YAML and are skipped.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
mapfile -t files < <(git ls-files 'apps/*.yaml' 'apps/*.yml' 'workloads/*.yaml' 'workloads/*.yml' | grep -v '/templates/')

for f in "${files[@]}"; do
  dups=$(yq e -N '[.. | select(tag == "!!map") | select((keys | length) != (keys | unique | length)) | "." + (path | join("."))] | .[]' "$f")
  if [[ -n "$dups" ]]; then
    while IFS= read -r p; do
      echo "::error file=$f::duplicate mapping keys at '$p' (missing '---' between manifests?)"
    done <<<"$dups"
    fail=1
  fi
done

refs=$(yq e -N 'select(.kind == "Gateway") | .metadata.namespace as $ns | .spec.listeners[] | .tls.certificateRefs[]? | select((.kind // "Secret") == "Secret") | (.namespace // $ns) + "/" + .name' "${files[@]}" | sort -u)
certs=$(yq e -N 'select(.kind == "Certificate") | (.metadata.namespace // "<no-namespace>") + "/" + .spec.secretName' "${files[@]}" | sort)

while IFS= read -r secret; do
  [[ -z "$secret" ]] && continue
  n=$(grep -cxF "$secret" <<<"$certs" || true)
  if [[ "$n" -eq 0 ]]; then
    echo "::error::Gateway listener serves Secret $secret but no Certificate has that secretName; it will never be issued or renewed"
    fail=1
  fi
done <<<"$refs"

pairs=$(yq e -N 'select(.kind == "Gateway") | .metadata.namespace as $ns | .spec.listeners[] | select(.hostname and .tls.certificateRefs) | .hostname as $h | .tls.certificateRefs[] | select((.kind // "Secret") == "Secret") | (.namespace // $ns) + "/" + .name + " " + $h' "${files[@]}" | sort -u)
sans=$(yq e -N 'select(.kind == "Certificate") | ((.metadata.namespace // "<no-namespace>") + "/" + .spec.secretName) as $s | .spec.dnsNames[]? | $s + " " + .' "${files[@]}" | tr '[:upper:]' '[:lower:]' | sort -u)

while read -r secret host; do
  [[ -z "$secret" ]] && continue
  grep -qxF "$secret" <<<"$certs" || continue   # missing Certificate already reported above
  h=${host,,}
  if ! grep -qxF "$secret $h" <<<"$sans" && ! grep -qxF "$secret *.${h#*.}" <<<"$sans"; then
    echo "::error::listener hostname $host is not covered by any dnsName of the Certificate writing $secret; clients will get a certificate name mismatch"
    fail=1
  fi
done <<<"$pairs"

while IFS= read -r secret; do
  [[ -z "$secret" ]] && continue
  echo "::error::more than one Certificate writes Secret $secret; cert-manager refuses to issue for duplicates"
  fail=1
done < <(uniq -d <<<"$certs")

gw=workloads/gateway/gateway.yaml
route_kinds='.kind == "HTTPRoute" or .kind == "TLSRoute" or .kind == "GRPCRoute"'
mapfile -t apps < <(git ls-files 'apps/*.yaml' 'apps/*.yml')

n_listeners=$(yq e -N 'select(.kind == "Gateway" and .metadata.name == "shared-gateway") | .spec.listeners | length' "$gw")
if [[ "$n_listeners" -gt 16 ]]; then
  echo "::error file=$gw::shared-gateway has $n_listeners listeners; Traefik fails BackendTLSPolicy status writes above 16 (one ancestor per listener)"
  fail=1
fi

declare -A lhost=() lsecret=()
while read -r name host secret; do
  [[ -z "$name" ]] && continue
  lhost["$name"]=$host
  lsecret["$name"]=$secret
done < <(yq e -N 'select(.kind == "Gateway" and .metadata.name == "shared-gateway") | .spec.listeners[] | .name + " " + (.hostname // "-") + " " + (.tls.certificateRefs[0].name // "-")' "$gw")

# Traefik's findMatchingHostname: exact, or a "*." listener whose suffix the route hostname ends with.
served() { local l=$1 h=$2; [[ "$l" == "-" || "$l" == "$h" ]] && return 0; [[ "$l" == "*."* && "$h" == *"${l#\*}" ]]; }

# One line per (route parentRef to shared-gateway) x (route hostname): file route section host
route_refs=$(
  yq e -N "select($route_kinds) | filename as \$f | .metadata.name as \$n | (.spec.hostnames // [\"-\"]) as \$hs | .spec.parentRefs[]? | select(.name == \"shared-gateway\") | (.sectionName // \"-\") as \$s | \$hs[] | \$f + \" \" + \$n + \" \" + \$s + \" \" + ." "${files[@]}"
  yq e -N "filename as \$f | select(.kind == \"Application\") | (.spec.source.helm.values // \"\") | select(. != \"\") | from_yaml | .extraObjects[]? | select($route_kinds) | .metadata.name as \$n | (.spec.hostnames // [\"-\"]) as \$hs | .spec.parentRefs[]? | select(.name == \"shared-gateway\") | (.sectionName // \"-\") as \$s | \$hs[] | \$f + \" \" + \$n + \" \" + \$s + \" \" + ." "${apps[@]}"
)

declare -A seen=() ok=()
n_routes=0
while read -r f n s h; do
  [[ -z "$f" ]] && continue
  n_routes=$((n_routes + 1))
  key="$f $n $h"
  seen["$key"]=1
  if [[ "$s" == "-" ]]; then
    echo "::error file=$f::route $n has a shared-gateway parentRef without sectionName; pin one listener"
    fail=1; ok["$key"]=1; continue
  fi
  if [[ -z "${lhost[$s]+x}" ]]; then
    echo "::error file=$f::route $n pins sectionName $s, which is not a shared-gateway listener"
    fail=1; ok["$key"]=1; continue
  fi
  served "${lhost[$s]}" "$h" || continue
  ok["$key"]=1
  sec=${lsecret[$s]}
  [[ "$sec" == "-" || "$h" == "-" ]] && continue
  hl=${h,,}
  if ! grep -qxF "default/$sec $hl" <<<"$sans" && ! grep -qxF "default/$sec *.${hl#*.}" <<<"$sans"; then
    echo "::error file=$f::route $n hostname $h is served by listener $s, but Certificate default/$sec does not cover it; clients get a certificate name mismatch"
    fail=1
  fi
done <<<"$route_refs"

for key in "${!seen[@]}"; do
  if [[ -z "${ok[$key]:-}" ]]; then
    read -r f n h <<<"$key"
    echo "::error file=$f::route $n hostname $h matches none of its pinned shared-gateway listeners; it is never served"
    fail=1
  fi
done

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "gateway certs OK: $(grep -c . <<<"$refs") listener secrets, each backed by one Certificate; $(grep -c . <<<"$pairs") listener hostnames covered; $n_routes shared-gateway route hostnames pinned and covered; $n_listeners/16 shared-gateway listeners"
