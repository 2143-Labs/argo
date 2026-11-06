#!/usr/bin/env bash
# Shared manifest inventory for the CI validators in scripts/validate-*.sh.
#
# Callers get RI_FILES: repo YAML (apps/, workloads/, minus */templates/) plus
# one rendered manifest per Helm chart that emits edge objects. Charts are
# rendered the way the Application/ApplicationSet that owns them renders them
# (helm.parameters, helm.valueFiles, inline helm.values), with {{ index
# .metadata.labels "env" }} resolved to prod.
#
# Usage:
#   source scripts/lib/inventory.sh
#   ri_init
#   fail=0; ri_files || fail=1
#   ri_require_files
#   ... yq over "${RI_FILES[@]}" ... file=$(ri_src "$f") ...
#
# Not scanned: multi-source Applications (.spec.sources[]) and ApplicationSets
# whose generators are pullRequest (their values do not exist in the repo).
# Those charts are reported in the skip note; ri_require_files still fails if
# nothing at all is found.

ri_init() {
  RI_TMP=$(mktemp -d)
  RI_FAIL=0
  trap 'rm -rf "$RI_TMP"' EXIT
  declare -gA RI_CHART_SRC=()
}

ri_env_subst() { sed -e 's/{{ *index \.metadata\.labels "env" *}}/prod/g'; }

ri_src() {
  if [[ -n "${RI_CHART_SRC[$1]:-}" ]]; then printf '%s\n' "${RI_CHART_SRC[$1]}"; else printf '%s\n' "$1"; fi
}

ri_rendered_for() {
  local f
  for f in "${RI_FILES[@]}"; do
    [[ "${RI_CHART_SRC[$f]:-}" == "$1/templates" ]] && printf '%s\n' "$f"
  done
}

ri_files() {
  RI_FILES=()
  mapfile -t RI_FILES < <(git ls-files 'apps/*.yaml' 'apps/*.yml' 'workloads/*.yaml' 'workloads/*.yml' | grep -v '/templates/')

  local appf path name ns args vf f pn pv
  while IFS= read -r appf; do
    path=$(yq e -N '.spec.source.path // .spec.template.spec.source.path // ""' "$appf")
    [[ -n "$path" && -f "$path/Chart.yaml" ]] || continue
    grep -qE '^kind: (Gateway|HTTPRoute|TLSRoute|GRPCRoute|Middleware|Certificate)$' "$path"/templates/*.yaml 2>/dev/null || continue
    if [[ "$(yq e -N '[.spec.generators[]? | select(has("pullRequest"))] | length' "$appf")" != "0" ]]; then
      echo "note: $appf skipped: pullRequest generator, chart values come from PR metadata"
      continue
    fi

    name=$(basename "$appf" .yaml)
    ns=$(yq e -N '.spec.destination.namespace // .spec.template.spec.destination.namespace // "default"' "$appf")
    args=(--namespace "$ns")

    while IFS=$'\t' read -r pn pv pfs; do
      [[ -z "$pn" ]] && continue
      pv=$(ri_env_subst <<<"$pv")
      if [[ "$pfs" == "true" ]]; then
        args+=(--set-string "$pn=$pv")
      else
        args+=(--set "$pn=$pv")
      fi
    done < <(yq e -N '(.spec.source.helm.parameters // .spec.template.spec.source.helm.parameters // [])[] | .name + "\t" + .value + "\t" + (.forceString // false | tostring)' "$appf")

    while IFS= read -r vf; do
      [[ -z "$vf" ]] && continue
      vf=$(ri_env_subst <<<"$vf")
      case "$vf" in
        \$values/*) f="workloads/${vf#\$values/}" ;;
        /*) f="$vf" ;;
        *) f="$path/$vf" ;;
      esac
      if [[ -f "$f" ]]; then
        args+=(-f "$f")
      else
        echo "::error file=$appf::helm value file $vf not found"
        RI_FAIL=1
      fi
    done < <(yq e -N '(.spec.source.helm.valueFiles // .spec.template.spec.source.helm.valueFiles // [])[]' "$appf")

    yq e -N '(.spec.source.helm.values // .spec.template.spec.source.helm.values // "") as $v | select($v != "") | $v' "$appf" >"$RI_TMP/$name.inline-values.yaml"
    if [[ -s "$RI_TMP/$name.inline-values.yaml" ]]; then
      args+=(-f "$RI_TMP/$name.inline-values.yaml")
    fi

    if helm template "$name" "$path" --dependency-update "${args[@]}" >"$RI_TMP/$name.yaml" 2>"$RI_TMP/$name.err"; then
      RI_FILES+=("$RI_TMP/$name.yaml")
      RI_CHART_SRC["$RI_TMP/$name.yaml"]="$path/templates"
    else
      echo "::error file=$appf::helm template $path failed: $(head -1 "$RI_TMP/$name.err")"
      RI_FAIL=1
    fi
  done < <(git ls-files 'apps/*.yaml' 'apps/*.yml')

  return "$RI_FAIL"
}

ri_apps() { mapfile -t RI_APPS < <(git ls-files 'apps/*.yaml' 'apps/*.yml'); }

# Route projection shared by validate-route-gates.sh and validate-policies.sh:
# file \t ns/name \t path \t hosts(csv) \t refs(csv) \t types(csv). The yq
# expression's $file variable is defined by the wrapper, not by this string.
RI_ROUTE_BODY='.metadata.namespace as $ns | .metadata.name as $n | ("," + (.spec.hostnames // [] | join(",")) + ",") as $h | .spec.rules[] | ((.matches // [{}])[0].path.value // "/") as $p | ("," + ([.filters[]? | select(.type == "ExtensionRef") | .extensionRef.name] | join(",")) + ",") as $f | ("," + ([.filters[]? | .type] | join(",")) + ",") as $t | $file + "\t" + ($ns // "") + "/" + $n + "\t" + $p + "\t" + $h + "\t" + $f + "\t" + $t'

# One line per rule over rendered/repo manifests plus routes embedded in
# Application helm.values. Call ri_apps first.
ri_route_stream() {
  yq e -N "select(.kind == \"HTTPRoute\") | filename as \$file | $RI_ROUTE_BODY" "${RI_FILES[@]}"
  yq e -N "filename as \$file | select(.kind == \"Application\") | (.spec.source.helm.values // \"\") | select(. != \"\") | from_yaml | .extraObjects[]? | select(.kind == \"HTTPRoute\") | $RI_ROUTE_BODY" "${RI_APPS[@]}"
}

ri_require_files() {
  if [[ ${#RI_FILES[@]} -eq 0 ]]; then
    echo "::error::scanned no manifests at all; refusing to pass"
    exit 1
  fi
}
