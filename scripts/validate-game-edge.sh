#!/usr/bin/env bash
# Every game Application carries the `edge.2143.me/class: game` tag and depends on
# helm_modules/game-edge, and nothing else does. Read docs/public-edge.md.
#
# The tag is the machine-readable statement that an app is a browser game; the
# library supplies its route gates, Anubis policy (with the link-preview payload),
# WebSocket check and the `game-` route-name prefix the CrowdSec agent keys on
# (workloads/crowdsec-agent/agent-game-hosts.yaml). This check keeps the two in
# step, so a new game cannot take the tag without the library, or the library
# without the tag.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

tag='edge.2143.me/class'
games=0
fail=0

for f in apps/*.yaml apps/*.yml; do
  [[ -e "$f" ]] || continue
  kind=$(yq -r '.kind // ""' "$f")
  case "$kind" in
    Application)
      cls=$(yq -r ".metadata.labels.\"$tag\" // \"\"" "$f")
      path=$(yq -r '.spec.source.path // ""' "$f")
      ;;
    ApplicationSet)
      cls=$(yq -r ".spec.template.metadata.labels.\"$tag\" // \"\"" "$f")
      path=$(yq -r '.spec.template.spec.source.path // ""' "$f")
      ;;
    *) continue ;;
  esac
  # Multi-source apps have no single chart path; they cannot be games.
  [[ -n "$path" ]] || continue

  deps=$(yq -r '.dependencies[]?.name // ""' "$path/Chart.yaml" 2>/dev/null || true)
  has=0
  if grep -qx 'game-edge' <<<"$deps"; then
    has=1
  fi

  if [[ "$cls" == game && "$has" -eq 0 ]]; then
    echo "::error file=$f::$path is tagged $tag=game but its Chart.yaml does not depend on helm_modules/game-edge"
    fail=1
  elif [[ "$cls" != game && "$has" -eq 1 ]]; then
    echo "::error file=$f::$path depends on helm_modules/game-edge but is not tagged $tag=game"
    fail=1
  fi
  if [[ "$cls" == game ]]; then
    games=$((games + 1))
  fi
done

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "game edge OK: $games game apps"
