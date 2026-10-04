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

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "gateway certs OK: $(grep -c . <<<"$refs") listener secrets, each backed by one Certificate; $(grep -c . <<<"$pairs") listener hostnames covered"
