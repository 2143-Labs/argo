#!/usr/bin/env bash
# The booking host must NEVER IP-ban a potential client (workloads/odoo serves
# book.aross.studio since 2026-11-09; 2143 Labs takes no bookings, so book.2143.me
# is gone). Every rule serving book.aross.studio is gated by lan-only or
# crowdsec-bouncer-appsec-only (AppSec 403s single requests, never consults the
# ban list), and by no stream-mode bouncer, which would enforce LAPI bans, the
# CAPI community blocklist and bans earned on other hosts. RequestRedirect rules
# (http->https) are skipped: they never reach a backend.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

source scripts/lib/inventory.sh
ri_init
fail=0
ri_files || fail=1
ri_require_files
ri_apps

hosts_re='(^|,)book[.]aross[.]studio(,|$)'
declare -A served=()
n=0
while IFS=$'\t' read -r file key path hosts refs types; do
  [[ "$hosts" =~ $hosts_re ]] || continue
  [[ "$types" == *,RequestRedirect,* ]] && continue
  n=$((n + 1))
  file=$(ri_src "$file")
  for h in book.aross.studio; do
    [[ "$hosts" == *,"$h",* ]] && served[$h]=1
  done
  if [[ "$refs" != *,lan-only,* && "$refs" != *,crowdsec-bouncer-appsec-only,* ]]; then
    echo "::error file=$file::rule $key $path (filters ${refs}) has neither lan-only nor crowdsec-bouncer-appsec-only"
    fail=1
  fi
  for banning in crowdsec-bouncer crowdsec-bouncer-noappsec crowdsec-bouncer-game; do
    if [[ "$refs" == *,"$banning",* ]]; then
      echo "::error file=$file::rule $key $path (filters ${refs}) uses $banning, which IP-bans clients; booking hosts must use crowdsec-bouncer-appsec-only"
      fail=1
    fi
  done
done < <(ri_route_stream)

for h in book.aross.studio; do
  if [[ -z "${served[$h]:-}" ]]; then
    echo "::error::no route rule serves $h; refusing to pass"
    fail=1
  fi
done
[[ "$n" -gt 0 ]] || { echo "::error::scanned 0 booking rules; refusing to pass"; exit 1; }
[[ "$fail" -eq 0 ]] || exit 1
echo "booking never-ban OK: $n rules"
