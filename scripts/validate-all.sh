#!/usr/bin/env bash
# Runs every validator. In CI each one has its own job; locally this is the one
# command to run before pushing: nix develop -c ./scripts/validate-all.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0
for s in validate-doc-links validate-gateway-certs validate-route-gates validate-lan-dns-zones validate-headscale-dns validate-vpn-endpoints validate-policies; do
  if "./scripts/$s.sh"; then printf 'ok   %s\n' "$s"; else printf 'FAIL %s\n' "$s"; fail=1; fi
done
exit "$fail"
