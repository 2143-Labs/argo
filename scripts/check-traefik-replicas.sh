#!/usr/bin/env bash
# Checks that every Traefik replica serves the same routes.
#
# Why: each replica builds its own configuration from its own Kubernetes
# informer caches. If a replica starts while the API server is churning it can
# come up with an incomplete cache and build a configuration that is missing
# routers; nothing later re-triggers a rebuild for objects it never cached, so
# the bad config is sticky until that pod restarts. It is invisible in
# Kubernetes objects: Traefik increments a listener's AttachedRoutes before it
# checks whether the listener is Attached, and a listener whose TLS secret
# failed to load merges no routers while still reporting Accepted=True
# (pkg/provider/kubernetes/gateway/httproute.go, kubernetes.go).
#
# How: for one HTTPRoute hostname per HTTPS listener of shared-gateway, ask
# every replica directly (pod IP, not the Service) and compare. A replica that
# answers Traefik's own "404 page not found" while the others route the
# hostname is stale. Backend 404s, 5xx and timeouts are not compared, so a
# flaky app cannot trigger a false alarm.
#
# Usage: ./scripts/check-traefik-replicas.sh [namespace]   (needs kubectl + curl)
# Run after any control-plane churn, node reboot, or Traefik rollout.
set -uo pipefail
ns=${1:-default}
K=(kubectl --context "${KUBE_CONTEXT:-closet-as-admin}")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ROUTED: a router answered (any status, including a backend 404 or a redirect).
# TRAEFIK_404: Traefik's own no-route response. UNKNOWN: no response at all.
classify() { # host ip port
  local out code body
  out=$(curl -s --max-time 8 -w '\n%{http_code}' --resolve "$1:$3:$2" "https://$1:$3/" 2>/dev/null)
  code=${out##*$'\n'}
  body=${out%$'\n'*}
  if [[ "$code" == "000" ]]; then echo UNKNOWN
  elif [[ "$code" == "404" && "$body" == "404 page not found"* ]]; then echo TRAEFIK_404
  else echo ROUTED
  fi
}

"${K[@]}" -n kube-system get pods -l app.kubernetes.io/name=traefik -o json \
  | jq -r '.items[] | "\(.metadata.name) \(.status.podIP) \(.spec.nodeName) \(.status.containerStatuses[0].ready)"' > "$tmp/pods"
"${K[@]}" -n "$ns" get gateway shared-gateway -o json > "$tmp/gateway"
jq -r '.spec.listeners[] | select(.protocol == "HTTPS") | .name' "$tmp/gateway" > "$tmp/listeners"
# The VIP moves with the MetalLB pool; read it from the Gateway, never hardcode it.
vip=$(jq -r '[.status.addresses[]? | select(.type == "IPAddress" and (.value | contains(":") | not)) | .value] | first // empty' "$tmp/gateway")
[[ -n $vip ]] || { echo "::error::shared-gateway reports no IPv4 address in .status.addresses" >&2; exit 1; }
"${K[@]}" get httproute -A -o json > "$tmp/routes"

# One (listener, hostname) pair per HTTPS listener: a hostname that answers
# through the gateway, so a replica that does not know its route stands out.
: > "$tmp/canaries"
while read -r l; do
  mapfile -t cands < <(jq -r --arg l "$l" '
    [.items[] | select(any(.spec.parentRefs[]?; .name == "shared-gateway" and .sectionName == $l)) | .spec.hostnames[]?]
    | unique | .[]' "$tmp/routes")
  chosen=""
  for h in "${cands[@]}"; do
    [[ "$(classify "$h" "$vip" 443)" == "ROUTED" ]] && { chosen=$h; break; }
  done
  if [[ -n "$chosen" ]]; then
    echo "$l $chosen" >> "$tmp/canaries"
  elif [[ ${#cands[@]} -gt 0 ]]; then
    echo "::warning::listener $l has no hostname that answers through the gateway; using ${cands[0]} (a stale replica may go unnoticed)"
    echo "$l ${cands[0]}" >> "$tmp/canaries"
  else
    echo "::warning::listener $l has no HTTPRoute; skipped"
  fi
done < "$tmp/listeners"

fail=0
: > "$tmp/results"
while read -r pod ip node ready; do
  [[ "$ready" == "true" ]] || { echo "::error::traefik pod $pod ($node) is not ready"; fail=1; }
  while read -r l host; do
    echo "$pod $host $(classify "$host" "$ip" 8443) $l" >> "$tmp/results"
  done < "$tmp/canaries"
done < "$tmp/pods"

# Divergence: a hostname routed by at least one replica but not by another.
while read -r host; do
  routed=$(awk -v h="$host" '$2 == h && $3 == "ROUTED"' "$tmp/results" | wc -l)
  missing=$(awk -v h="$host" '$2 == h && $3 == "TRAEFIK_404" {print $1}' "$tmp/results" | tr '\n' ' ')
  if [[ "$routed" -gt 0 && -n "${missing// /}" ]]; then
    listener=$(awk -v h="$host" '$2 == h {print $4; exit}' "$tmp/results")
    echo "::error::hostname $host (listener $listener) is routed by some replicas but not by: $missing"
    fail=1
  fi
done < <(awk '{print $2}' "$tmp/results" | sort -u)

echo "vip $vip; checked $(wc -l < "$tmp/pods") replicas x $(wc -l < "$tmp/canaries") listeners ($(awk '{print $2}' "$tmp/canaries" | tr '\n' ' '))"
[[ "$fail" -eq 0 ]] && echo "traefik replicas agree on every checked hostname"
exit "$fail"
