#!/usr/bin/env bash
# check-gitignore-paths.sh -- guard against .gitignore rot (issue #100).
#
# The 2026-09-18 Docker/ bucket split left .gitignore lines on pre-bucket paths, which silently stopped matching,
# and secrets got committed for a month. This fails when:
#   1. a path-style .gitignore line (contains a /) points into a directory that doesn't exist any more, or
#   2. a file git tracks is matched by .gitignore (ignored-but-tracked = a secret probably slipped in).
#
#   Scripts/check-gitignore-paths.sh          # run by hand
#   ln -sf ../../Scripts/check-gitignore-paths.sh .git/hooks/pre-commit   # install as pre-commit hook
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
bad=0

while IFS= read -r line; do
  case "$line" in ''|'#'*|'!'*) continue ;; esac
  p="${line%/}"
  [[ "$p" == */* ]] || continue               # bare patterns like *.env apply anywhere
  dir="$(dirname "$p")"
  [[ "$dir" == *[\*\?\[]* ]] && continue      # globbed directory part: can't check
  if [[ ! -d "$dir" ]]; then
    echo "stale .gitignore line (no directory '$dir'): $line"
    bad=1
  fi
done < .gitignore

tracked_ignored=$(git ls-files -ci --exclude-standard)
if [[ -n "$tracked_ignored" ]]; then
  echo "tracked files that .gitignore says to ignore (git rm --cached them?):"
  echo "$tracked_ignored" | sed 's/^/  /'
  bad=1
fi

[[ $bad -eq 0 ]] || { echo "check-gitignore-paths: FAILED"; exit 1; }
