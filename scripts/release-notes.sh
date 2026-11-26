#!/bin/bash
# Assembles the release notes for a tag: the curated CHANGELOG.md section
# first, then an appendix listing the commits in the range grouped by
# Conventional Commits type.
#
# The same text feeds both the GitHub Release body and, as AltTab.md next to
# the DMG, the Sparkle update window. GitHub's own --generate-notes produces
# nothing useful here: this repo commits straight to main, and that feature
# only fills in from merged pull requests.
#
# Usage: scripts/release-notes.sh <tag> [end-ref] [output-file]
#   v0.2.0     the tag being released — selects `## [0.2.0]` in CHANGELOG.md,
#              or the `## [Unreleased]` section when not stamped yet
#   HEAD       optional: where to end the commit range (default: the tag's
#              own commit; pass HEAD to preview before tagging)
#   notes.md   optional: write there instead of stdout
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=${1:?usage: release-notes.sh <tag> [end-ref] [output-file]}
END=${2:-$TAG}
OUT=${3:-}
VERSION=${TAG#v}

[[ -f CHANGELOG.md ]] || { echo "release-notes: no CHANGELOG.md at the repo root" >&2; exit 2; }
git rev-parse -q --verify "$END^{commit}" >/dev/null \
  || { echo "release-notes: unknown ref '$END' (pass the release tag, or HEAD to preview)" >&2; exit 2; }

# Previous release tag: newest v* tag that is an ancestor of the end ref and
# is not the tag being released. Empty when there is none (rebuilt history).
PREV=$(git tag --merged "$END" --sort=-v:refname -l 'v*' | grep -vx "$TAG" | head -1 || true)
RANGE=$END
[[ -n "$PREV" ]] && RANGE="$PREV..$END"

emit() { if [[ -n "$OUT" ]]; then cat >"$OUT"; else cat; fi; }

{
  # 1. Curated section: the body of the matching CHANGELOG heading, verbatim.
  awk -v v="$VERSION" '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) if (line[i] ~ ("^## \\[" v "\\]")) { start = i; break }
      if (!start) for (i = 1; i <= NR; i++) if (line[i] == "## [Unreleased]") { start = i; break }
      if (!start) exit 0
      for (i = start + 1; i <= NR && line[i] !~ /^## \[/; i++) buf[++k] = line[i]
      while (k > 0 && buf[k] == "") k--
      for (i = 1; i <= k; i++) print buf[i]
    }
  ' CHANGELOG.md

  # 2. Commit appendix.
  echo
  echo "### Commits"
  if [[ -n "$PREV" ]]; then
    echo
    echo "Since \`$PREV\`:"
  fi
  echo
  git log --no-merges --format='%h%x09%s' "$RANGE" | awk -F'\t' '
    BEGIN {
      n = split("Features Fixes Performance Refactoring Docs Build CI Tests Maintenance Reverts", names, " ")
      map["feat"] = "Features";      map["fix"] = "Fixes"
      map["perf"] = "Performance";   map["refactor"] = "Refactoring"
      map["docs"] = "Docs";          map["build"] = "Build"
      map["ci"] = "CI";              map["test"] = "Tests"
      map["chore"] = "Maintenance";  map["style"] = "Maintenance"
      map["revert"] = "Reverts"
      for (i = 1; i <= n; i++) canon[names[i]] = 1
    }
    {
      # Bookkeeping commits never appear here: chore(changelog): … is the
      # marker written by the session-end changelog recorder, and
      # docs(changelog): … is the release workflow stamping a version.
      if ($2 ~ /^(chore|docs)\(changelog\)!?: /) next
      sha = $1; t = "Other"; subj = $2
      if ($2 ~ /^[a-z]+(\([^)]*\))?!?: /) {
        typ = $2; sub(/[(:!].*/, "", typ)
        subj = $2; sub(/^[a-z]+/, "", subj)
        sub(/^\([^)]*\)/, "", subj); sub(/^!?: /, "", subj)
        t = (typ in map) ? map[typ] : "Other"
      }
      lines[t, ++cnt[t]] = "- " sha " " subj
      if (!(t in seen)) { seen[t] = 1; extra[++g] = t }
    }
    END {
      for (i = 1; i <= n; i++) if (names[i] in cnt) print_group(names[i])
      for (i = 1; i <= g; i++) if (!(extra[i] in canon)) print_group(extra[i])
    }
    function print_group(t,  j) {
      print "**" t "**"
      for (j = 1; j <= cnt[t]; j++) print lines[t, j]
      print ""
    }
  '
} | emit
