#!/usr/bin/env bash
# Every HTTPRoute rule carries an edge gate, so nothing reaches the internet by
# accident. Read docs/public-edge.md.
#
# Rules are read from HTTPRoutes in apps/ and workloads/, plus routes embedded
# in Helm values strings (.spec.source.helm.values -> extraObjects, e.g.
# apps/openbao.yaml). A rule is keyed "<namespace>/<route> <path>", where path
# is its first match's path value ("/" if absent).
#
# A. A rule whose route serves a *.ts.2143.me hostname must carry lan-only
#    (unless it is only a RequestRedirect). The name is private only in DNS:
#    the gateway serves it to anyone who sends it to the WAN address. No
#    exemptions.
# B. Every other rule carries lan-only, crowdsec-bouncer,
#    crowdsec-bouncer-noappsec or a RequestRedirect, or is listed in
#    scripts/route-gate-exemptions.txt with a reason.
# C. Every exemption names a rule that B would otherwise reject.
#
# Not scanned: multi-source Applications (.spec.sources[]).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

exemptions=scripts/route-gate-exemptions.txt

# One line per rule: file, ns/name, path, then hostnames, ExtensionRef names and
# filter types as ",a,b," lists (never empty, so tab splitting keeps columns).
body='.metadata.namespace as $ns | .metadata.name as $n | ("," + (.spec.hostnames // [] | join(",")) + ",") as $h | .spec.rules[] | ((.matches // [{}])[0].path.value // "/") as $p | ("," + ([.filters[]? | select(.type == "ExtensionRef") | .extensionRef.name] | join(",")) + ",") as $f | ("," + ([.filters[]? | .type] | join(",")) + ",") as $t | $file + "\t" + ($ns // "") + "/" + $n + "\t" + $p + "\t" + $h + "\t" + $f + "\t" + $t'

mapfile -t files < <(git ls-files 'apps/*.yaml' 'apps/*.yml' 'workloads/*.yaml' 'workloads/*.yml' | grep -v '/templates/')
mapfile -t apps < <(git ls-files 'apps/*.yaml' 'apps/*.yml')

fail=0
declare -A exempt=() exempt_line=() used=()
ln=0
while IFS= read -r line || [[ -n "$line" ]]; do
  ln=$((ln + 1))
  [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
  read -r ens epath reason <<<"$line"
  if [[ -z "${epath:-}" || -z "${reason:-}" ]]; then
    echo "::error file=$exemptions,line=$ln::exemption line needs '<namespace>/<route> <path> <reason>'"
    fail=1
    continue
  fi
  exempt["$ens $epath"]=1
  exempt_line["$ens $epath"]=$ln
done <"$exemptions"

declare -A no_ns=()
n=0
while IFS=$'\t' read -r file key path hosts refs types; do
  n=$((n + 1))
  if [[ "$key" == /* && -z "${no_ns[$key]:-}" ]]; then
    no_ns["$key"]=1
    echo "::error file=$file::HTTPRoute ${key#/} has no metadata.namespace"
    fail=1
  fi

  ts=0
  IFS=',' read -ra hs <<<"${hosts#,}"
  for h in "${hs[@]}"; do
    [[ "$h" == *.ts.2143.me ]] && ts=1
  done

  if [[ "$ts" -eq 1 && "$types" != ",RequestRedirect," ]]; then
    if [[ "$refs" != *,lan-only,* ]]; then
      echo "::error file=$file::rule $key $path serves a .ts.2143.me name without lan-only; it is reachable from the internet"
      fail=1
    fi
    continue
  fi

  if [[ "$refs" == *,lan-only,* || "$refs" == *,crowdsec-bouncer,* || "$refs" == *,crowdsec-bouncer-noappsec,* || "$types" == *,RequestRedirect,* ]]; then
    continue
  fi
  if [[ -n "${exempt["$key $path"]:-}" ]]; then
    used["$key $path"]=1
    continue
  fi
  hosts=${hosts#,}
  echo "::error file=$file::rule $key $path on ${hosts%,} has no edge gate; add one (docs/public-edge.md) or list it in $exemptions with a reason"
  fail=1
done < <(
  yq e -N "select(.kind == \"HTTPRoute\") | filename as \$file | $body" "${files[@]}"
  yq e -N "filename as \$file | select(.kind == \"Application\") | (.spec.source.helm.values // \"\") | select(. != \"\") | from_yaml | .extraObjects[]? | select(.kind == \"HTTPRoute\") | $body" "${apps[@]}"
)

for k in "${!exempt[@]}"; do
  if [[ -z "${used[$k]:-}" ]]; then
    echo "::error file=$exemptions,line=${exempt_line[$k]}::exemption $k matches no ungated rule; delete it"
    fail=1
  fi
done

[[ "$fail" -eq 0 ]] || exit 1
echo "route gates OK: $n rules, ${#used[@]} exempt"
