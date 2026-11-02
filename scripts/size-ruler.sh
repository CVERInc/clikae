#!/usr/bin/env bash
# scripts/size-ruler.sh [base]: warn when a change grows a file that is already
# large, naming the file and the growth. Warns only; it never fails the build, and a
# large file left alone or shrunk says nothing, so the warning always has an action.
set -u
base="${1:-origin/main}"
limit="${CLIKAE_SIZE_LIMIT:-1500}"
git diff --numstat "$base...HEAD" -- bin lib | while read -r added removed file; do
  case "$added$removed" in *[!0-9]*) continue ;; esac
  [ -f "$file" ] || continue
  grown=$((added - removed))
  [ "$grown" -gt 0 ] || continue
  lines="$(wc -l < "$file" | tr -d ' ')"
  [ "$lines" -gt "$limit" ] || continue
  printf '::warning file=%s::%s is %s lines (over %s) and this change adds %s. Can it shrink something too?\n' \
    "$file" "$file" "$lines" "$limit" "$grown"
done
exit 0
