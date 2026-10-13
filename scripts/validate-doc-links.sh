#!/usr/bin/env bash
# Docs drift because nothing checks them; see docs/README.md. For every
# tracked docs/*.md:
#
# 1. Every relative Markdown link outside code resolves to a tracked file or
#    directory (URLs with a scheme are skipped).
# 2. A link's #anchor into a .md file matches one of that file's heading slugs
#    (GitHub's algorithm, ASCII only).
# 3. In the guides (the "## Guides" list in docs/README.md), every inline-code
#    path under apps/, workloads/, scripts/, docs/, plans/, charts/,
#    bootstrap/, roles/ or .github/ exists. Placeholders (<, >, *, ...) are
#    skipped. Records (dated docs) describe the past and are not path-checked.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

mapfile -t docs < <(git ls-files 'docs/*.md')

declare -A tracked=() dirs=()
while IFS= read -r f; do tracked["$f"]=1; done < <(git ls-files)
while IFS= read -r d; do dirs["$d"]=1; done < <(git ls-files | LC_ALL=C awk -F/ '{p = $1; for (i = 2; i <= NF; i++) { print p; p = p "/" $i }}' | sort -u)

exists() { [[ -n "${tracked[$1]:-}" || -n "${dirs[$1]:-}" ]]; }

# Heading slugs of a Markdown file, one per line.
slugs() {
  LC_ALL=C awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    /^#{1,6} / {
      h = $0
      sub(/^#+ +/, "", h); sub(/[ \t]+#+[ \t]*$/, "", h); sub(/[ \t]+$/, "", h)
      h = tolower(h)
      gsub(/[^a-z0-9 _-]/, "", h)
      gsub(/ /, "-", h)
      if (h in seen) { print h "-" seen[h]; seen[h]++ } else { print h; seen[h] = 1 }
    }
  ' "$1"
}

# Markdown link targets outside fenced blocks and inline code: "line<TAB>target".
links() {
  LC_ALL=C awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    {
      line = $0
      gsub(/`[^`]*`/, "", line)
      while (match(line, /\]\([^) \t]+/)) {
        print FNR "\t" substr(line, RSTART + 2, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

# Inline-code repo paths outside fenced blocks: "line<TAB>path".
code_paths() {
  LC_ALL=C awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    {
      line = $0
      while (match(line, /`(apps|workloads|scripts|docs|plans|charts|bootstrap|roles|\.github)\/[A-Za-z0-9._\/-]+`/)) {
        print FNR "\t" substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

fail=0
declare -A slug_cache=()
nlinks=0 nanchors=0 npaths=0

for doc in "${docs[@]}"; do
  while IFS=$'\t' read -r ln target; do
    [[ "$target" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*: ]] && continue
    nlinks=$((nlinks + 1))
    path=${target%%#*}
    anchor=""
    [[ "$target" == *"#"* ]] && anchor=${target#*#}
    if [[ -z "$path" ]]; then
      dest=$doc
    elif [[ "$path" == /* ]]; then
      dest=$(realpath -m --relative-to=. ".$path")
    else
      dest=$(realpath -m --relative-to=. "$(dirname "$doc")/$path")
    fi
    if ! exists "$dest"; then
      echo "::error file=$doc,line=$ln::link target $target does not exist"
      fail=1
      continue
    fi
    if [[ -n "$anchor" && "$dest" == *.md ]]; then
      nanchors=$((nanchors + 1))
      if [[ -z "${slug_cache[$dest]+set}" ]]; then
        slug_cache["$dest"]=$'\n'"$(slugs "$dest")"$'\n'
      fi
      if [[ "${slug_cache[$dest]}" != *$'\n'"$anchor"$'\n'* ]]; then
        echo "::error file=$doc,line=$ln::anchor #$anchor not found in $dest"
        fail=1
      fi
    fi
  done < <(links "$doc")
done

mapfile -t guides < <(LC_ALL=C awk '
  /^## / { in_guides = ($0 == "## Guides"); next }
  in_guides && /^- \[[^]]*\]\([^)]+\.md\)/ { sub(/^- \[[^]]*\]\(/, ""); sub(/\).*$/, ""); print "docs/" $0 }
' docs/README.md)
if [[ "${#guides[@]}" -eq 0 ]]; then
  echo "::error file=docs/README.md::no '- [title](file.md)' entries under '## Guides'"
  exit 1
fi

for guide in "${guides[@]}"; do
  while IFS=$'\t' read -r ln p; do
    p=${p%/}
    [[ "$p" == *"..."* ]] && continue
    npaths=$((npaths + 1))
    if ! exists "$p"; then
      echo "::error file=$guide,line=$ln::$p named in a guide does not exist"
      fail=1
    fi
  done < <(code_paths "$guide")
done

[[ "$fail" -eq 0 ]] || exit 1
echo "doc links OK: $nlinks links, $nanchors anchors in ${#docs[@]} docs; $npaths paths in ${#guides[@]} guides"
