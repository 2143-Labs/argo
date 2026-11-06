#!/usr/bin/env bash
# Every HTTPRoute rule carries an edge gate, so nothing reaches the internet by
# accident. Read docs/public-edge.md.
#
# Rules are read from HTTPRoutes in apps/ and workloads/, from every Helm chart
# that emits edge objects (rendered by scripts/lib/inventory.sh as its
# Application renders it), plus routes embedded in Helm values strings
# (.spec.source.helm.values -> extraObjects, e.g. apps/openbao.yaml). A rule is
# keyed "<namespace>/<route> <path>", where path is its first match's path value
# ("/" if absent).
#
# A. A rule whose route serves a *.ts.2143.me hostname must carry lan-only
#    (unless it is only a RequestRedirect). The name is private only in DNS:
#    the gateway serves it to anyone who sends it to the WAN address. No
#    exemptions.
# B. Every other rule carries lan-only, crowdsec-bouncer,
#    crowdsec-bouncer-noappsec, crowdsec-bouncer-game, the uploads tier
#    (uploads-rate-limit + uploads-inflight-limit, the customer file host behind
#    Anubis: docs/public-edge.md) or a RequestRedirect, or is listed in
#    scripts/route-gate-exemptions.txt with a reason.
# C. Every exemption names a rule that B would otherwise reject.
#
# Not scanned: multi-source Applications (.spec.sources[]).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

source scripts/lib/inventory.sh

exemptions=scripts/route-gate-exemptions.txt

fail=0
ri_init
ri_files || fail=1
ri_require_files
ri_apps

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
  file=$(ri_src "$file")
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

  if [[ "$refs" == *,lan-only,* || "$refs" == *,crowdsec-bouncer,* || "$refs" == *,crowdsec-bouncer-noappsec,* || "$refs" == *,crowdsec-bouncer-game,* || "$refs" == *,uploads-inflight-limit,* || "$types" == *,RequestRedirect,* ]]; then
    continue
  fi
  if [[ -n "${exempt["$key $path"]:-}" ]]; then
    used["$key $path"]=1
    continue
  fi
  hosts=${hosts#,}
  echo "::error file=$file::rule $key $path on ${hosts%,} has no edge gate; add one (docs/public-edge.md) or list it in $exemptions with a reason"
  fail=1
done < <(ri_route_stream)

[[ "$n" -gt 0 ]] || { echo "::error::scanned 0 route rules; refusing to pass"; exit 1; }

for k in "${!exempt[@]}"; do
  if [[ -z "${used[$k]:-}" ]]; then
    echo "::error file=$exemptions,line=${exempt_line[$k]}::exemption $k matches no ungated rule; delete it"
    fail=1
  fi
done

[[ "$fail" -eq 0 ]] || exit 1
echo "route gates OK: $n rules, ${#used[@]} exempt"
