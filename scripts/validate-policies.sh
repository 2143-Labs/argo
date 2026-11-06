#!/usr/bin/env bash
# Declarative edge policy: every assertion in policies/*.yaml is checked against
# every HTTPRoute rule on shared-gateway, then every imperative check in
# scripts/validations/ is run. Read docs/ci-validations.md.
#
# An assertion applies to every rule of every route that lists a hostname
# matching one of its `hosts` globs (bash case patterns, case-insensitive).
# Redirect-only rules (RequestRedirect) never reach a backend and are skipped,
# but their hostnames count as matched. Keys:
#
#   exposure: private   the rule references Middleware lan-only
#   gates: [names]      the rule references each of these Middlewares
#   gates_any: [names]  the rule references at least one of these Middlewares
#   auth: [spec keys]   the rule references a Middleware that resolves in the
#                       rule's namespace (Middleware ExtensionRefs are
#                       namespace-local) and whose spec has one of these keys
#
# An assertion that matches no route hostname at all is an error: a policy that
# silently stops applying is worse than no policy.
#
# POLICY_DIR overrides policies/ (the negative test in docs/ci-validations.md
# points it at a throwaway directory).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

policy_dir=${POLICY_DIR:-policies}

source scripts/lib/inventory.sh

ri_init
fail=0
ri_files || fail=1
ri_apps
ri_require_files

# Rule inventory: file, ns/name, path, hostnames, ExtensionRef names, filter
# types. Same projection as validate-route-gates.sh.
mapfile -t rules < <(ri_route_stream)

# Middleware index: ns/name -> comma list of spec keys.
declare -A MTYPE=()
while read -r mkey mkeys; do
  [[ -z "$mkey" ]] && continue
  if [[ -n "${MTYPE[$mkey]:-}" ]]; then MTYPE[$mkey]+=",$mkeys"; else MTYPE[$mkey]=$mkeys; fi
done < <(
  yq e -N "select(.kind == \"Middleware\") | (.metadata.namespace // \"default\") + \"/\" + .metadata.name + \" \" + ([.spec | keys[]] | join(\",\"))" "${RI_FILES[@]}"
  yq e -N "filename as \$f | select(.kind == \"Application\") | (.spec.source.helm.values // \"\") | select(. != \"\") | from_yaml | .extraObjects[]? | select(.kind == \"Middleware\") | (.metadata.namespace // \"default\") + \"/\" + .metadata.name + \" \" + ([.spec | keys[]] | join(\",\"))" "${RI_APPS[@]}"
)

# First hostname of a rule (comma list, possibly with a leading comma) matching
# any of the patterns; non-zero when none matches.
match_host() {
  local list=${1//,/ } h pat
  shift
  for h in $list; do
    for pat in "$@"; do
      case "${h,,}" in ${pat,,}) printf '%s\n' "$h"; return 0;; esac
    done
  done
  return 1
}

shopt -s nullglob
policy_files=("$policy_dir"/*.yaml)
shopt -u nullglob
if [[ ${#policy_files[@]} -eq 0 ]]; then
  echo "::error::no assertions: $policy_dir/*.yaml is missing or empty"
  exit 1
fi

n_assertions=0
for pf in "${policy_files[@]}"; do
  # "|"-joined: read(1) treats tab as IFS whitespace, which would collapse the
  # empty exposure column of an assertion that has no exposure and shift the rest.
  assertions=$(yq e -o=json -I=0 '.assertions // []' "$pf" | jq -r '.[] | [(.hosts // [] | join(",")), (.exposure // ""), (.gates // [] | join(",")), (.gates_any // [] | join(",")), (.auth // [] | join(","))] | join("|")')
  [[ -z "$assertions" ]] && continue
  while IFS='|' read -r ahosts aexposure agates agates_any aauth; do
    if [[ -z "$ahosts" ]]; then
      echo "::error file=$pf::assertion has no hosts; every assertion needs at least one pattern"
      fail=1
      continue
    fi
    n_assertions=$((n_assertions + 1))
    IFS=',' read -ra pats <<<"$ahosts"

    matched=0
    for line in "${rules[@]}"; do
      [[ -z "$line" ]] && continue
      IFS=$'\t' read -r file key path hosts refs types <<<"$line"
      if ! h=$(match_host "$hosts" "${pats[@]}"); then continue; fi
      matched=$((matched + 1))
      if [[ "$types" == *",RequestRedirect,"* ]]; then continue; fi
      src=$(ri_src "$file")

      if [[ "$aexposure" == "private" && "$refs" != *,lan-only,* ]]; then
        echo "::error file=$src::host $h is declared private but rule $key $path has no lan-only middleware"
        fail=1
      fi

      if [[ -n "$agates" ]]; then
        IFS=',' read -ra gate_names <<<"$agates"
        for name in "${gate_names[@]}"; do
          if [[ "$refs" != *",$name,"* ]]; then
            echo "::error file=$src::host $h requires gate $name on rule $key $path"
            fail=1
          fi
        done
      fi

      if [[ -n "$agates_any" ]]; then
        IFS=',' read -ra any_names <<<"$agates_any"
        gated=0
        for name in "${any_names[@]}"; do
          if [[ "$refs" == *",$name,"* ]]; then gated=1; fi
        done
        if [[ "$gated" -eq 0 ]]; then
          echo "::error file=$src::host $h requires one of [$agates_any] on rule $key $path"
          fail=1
        fi
      fi

      if [[ -n "$aauth" ]]; then
        IFS=',' read -ra wanted_keys <<<"$aauth"
        mns=${key%%/*}
        [[ -z "$mns" ]] && mns=default
        authed=0
        IFS=',' read -ra ref_names <<<"${refs#,}"
        for ref in "${ref_names[@]}"; do
          [[ -z "$ref" ]] && continue
          spec_keys=${MTYPE["$mns/$ref"]:-}
          [[ -z "$spec_keys" ]] && continue
          for want in "${wanted_keys[@]}"; do
            if [[ ",$spec_keys," == *",$want,"* ]]; then authed=1; fi
          done
        done
        if [[ "$authed" -eq 0 ]]; then
          echo "::error file=$src::host $h requires a middleware with one of [$aauth] on rule $key $path"
          fail=1
        fi
      fi
    done

    if [[ "$matched" -eq 0 ]]; then
      echo "::error file=$pf::assertion hosts=[$ahosts] matches no route hostname; delete it or fix the pattern"
      fail=1
    fi
  done <<<"$assertions"
done

# Imperative checks: every non-underscore script in scripts/validations/ runs and
# its exit status counts. A missing directory is not an error.
if [[ -d scripts/validations ]]; then
  shopt -s nullglob
  for v in scripts/validations/*.sh; do
    [[ "$(basename "$v")" == _* ]] && continue
    bash "$v" || fail=1
  done
  shopt -u nullglob
fi

[[ "$fail" -eq 0 ]] || exit 1
echo "policies OK: $n_assertions assertions, ${#rules[@]} route rules, ${#MTYPE[@]} middleware definitions"
