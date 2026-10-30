#!/usr/bin/env bash
# Cut one legacy app-of-apps Application over to its ApplicationSet without
# touching its workloads (bigp nonprod plan, Step 6.0, commits B and C).
#
# Preconditions (checked): apps/<app>.yaml exists, apps/appset-<app>.yaml
# exists and is uncommitted, the working tree is otherwise clean.
#
#   B: strip resources-finalizer from the live Application, verify it is gone,
#      `git rm apps/<app>.yaml`, push, wait until the Application is NotFound.
#   C: commit+push apps/appset-<app>.yaml, wait until the Application exists
#      again, owned by ApplicationSet/appset-<app>, Synced+Healthy.
# Every managed resource's uid is recorded before B and must be identical
# after C. Any failure stops with instructions; nothing is auto-rolled back.
#
# Usage: scripts/appset-cutover.sh <app> [--resume-c]
#   --resume-c: B already succeeded (legacy file deleted on main, Application
#   NotFound, uids recorded); run only C against the recorded uids.
# Env: CTX (default closet-as-admin)
set -euo pipefail
app="$1"
resume_c="${2:-}"
ctx="${CTX:-closet-as-admin}"
k=(kubectl --context "$ctx")
cd "$(git rev-parse --show-toplevel)"
legacy="apps/$app.yaml"
appset="apps/appset-$app.yaml"
state="/tmp/appset-cutover-$app"
mkdir -p "$state"

if [ "$resume_c" = "--resume-c" ]; then
  [ ! -f "$legacy" ] || { echo "--resume-c but $legacy still exists" >&2; exit 1; }
  [ -s "$state/uids.before" ] || { echo "--resume-c but no $state/uids.before" >&2; exit 1; }
else
[ -f "$legacy" ] || { echo "no $legacy" >&2; exit 1; }
fi
[ -f "$appset" ] || { echo "no $appset" >&2; exit 1; }
[ -z "$(git status --porcelain -- . ":!$appset")" ] || { echo "working tree not clean apart from $appset" >&2; exit 1; }

app_json() { "${k[@]}" -n argocd get application "$app" -o json; }
resources_uids() { # kind/ns/name uid for every resource the app tracks
  app_json | python3 -c '
import json,sys
for r in json.load(sys.stdin)["status"].get("resources",[]):
    print("|".join([r.get("group",""), r["kind"], r.get("namespace",""), r["name"]]))' |
  while IFS='|' read -r group kind ns name; do
    res="$kind${group:+.$group}"
    uid="$("${k[@]}" get "$res" "$name" ${ns:+-n "$ns"} -o jsonpath='{.metadata.uid}' 2>/dev/null || echo MISSING)"
    echo "$res/$ns/$name $uid"
  done | sort
}
wait_for() { # wait_for <seconds> <description> <command...>
  local t="$1" d="$2"; shift 2
  local end=$((SECONDS + t))
  until "$@"; do
    [ $SECONDS -lt $end ] || { echo "TIMEOUT: $d" >&2; return 1; }
    sleep 5
  done
}
refresh_root() { "${k[@]}" -n argocd annotate application app-of-apps argocd.argoproj.io/refresh=normal --overwrite >/dev/null; }

ssh-add -l >/dev/null 2>&1 || { echo "ssh agent has no identities — git push would fail mid-cutover" >&2; exit 1; }
if [ "$resume_c" != "--resume-c" ]; then
echo "== $app: pre-flight"
st="$(app_json | python3 -c 'import json,sys;s=json.load(sys.stdin)["status"];print(s["sync"]["status"], s["health"]["status"])')"
[ "$st" = "Synced Healthy" ] || { echo "$app is '$st', not 'Synced Healthy' — fix first" >&2; exit 1; }
resources_uids > "$state/uids.before"
grep -q MISSING "$state/uids.before" && { echo "a tracked resource is missing before cutover:" >&2; grep MISSING "$state/uids.before" >&2; exit 1; }
echo "   $(wc -l < "$state/uids.before") tracked resources recorded in $state/uids.before"

echo "== $app: commit B (release legacy owner)"
"${k[@]}" -n argocd patch application "$app" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
fin="$("${k[@]}" -n argocd get application "$app" -o jsonpath='{.metadata.finalizers}')"
[ -z "$fin" ] || { echo "finalizer still present: $fin — STOP" >&2; exit 1; }
git rm -q "$legacy"
git commit -q -m "argo: release $app from app-of-apps (ApplicationSet cutover B)" -- "$legacy"
fin="$("${k[@]}" -n argocd get application "$app" -o jsonpath='{.metadata.finalizers}')"
[ -z "$fin" ] || { echo "finalizer reappeared before push: $fin — reset HEAD~1, STOP" >&2; exit 1; }
git pull -q --rebase origin main
git push -q origin HEAD:main
refresh_root
wait_for 300 "legacy $app deleted" bash -c "! kubectl --context $ctx -n argocd get application $app >/dev/null 2>&1"
resources_after_b() { while read -r ref uid; do
    IFS=/ read -r res ns name <<<"$ref"
    now="$("${k[@]}" get "$res" "$name" ${ns:+-n "$ns"} -o jsonpath='{.metadata.uid}' 2>/dev/null || echo MISSING)"
    echo "$ref $now"
  done < "$state/uids.before"; }
resources_after_b > "$state/uids.afterB"
diff "$state/uids.before" "$state/uids.afterB" || { echo "GATE B FAILED: workloads changed. Roll back: git revert HEAD && push" >&2; exit 1; }
echo "   gate B ok: Application gone, all uids unchanged"
fi
resources_after_b() { while read -r ref uid; do
    IFS=/ read -r res ns name <<<"$ref"
    now="$("${k[@]}" get "$res" "$name" ${ns:+-n "$ns"} -o jsonpath='{.metadata.uid}' 2>/dev/null || echo MISSING)"
    echo "$ref $now"
  done < "$state/uids.before"; }

echo "== $app: commit C (add ApplicationSet)"
git add "$appset"
git commit -q -m "argo: $app via ApplicationSet appset-$app (prod + nonprod) (cutover C)" -- "$appset"
git pull -q --rebase origin main
git push -q origin HEAD:main
refresh_root
wait_for 300 "$app recreated by appset" bash -c "kubectl --context $ctx -n argocd get application $app >/dev/null 2>&1"
owner="$("${k[@]}" -n argocd get application "$app" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}')"
[ "$owner" = "ApplicationSet/appset-$app" ] || { echo "GATE C FAILED: owner is '$owner'" >&2; exit 1; }
"${k[@]}" -n argocd annotate application "$app" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
wait_for 600 "$app Synced+Healthy" bash -c "[ \"\$(kubectl --context $ctx -n argocd get application $app -o jsonpath='{.status.sync.status} {.status.health.status}')\" = 'Synced Healthy' ]"
resources_after_b > "$state/uids.afterC"
diff "$state/uids.before" "$state/uids.afterC" || { echo "GATE C FAILED: uids changed. Roll back: revert C, then B" >&2; exit 1; }
n="$(app_json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["status"].get("resources",[])))')"
[ "$n" = "$(wc -l < "$state/uids.before")" ] || { echo "GATE C FAILED: tracked resource count $n differs" >&2; exit 1; }
echo "   gate C ok: owner $owner, Synced Healthy, same $n resources, uids unchanged"
