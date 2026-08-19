#!/usr/bin/env bats
# tests/bats/order-list.bats — order_list IS the burn order and the board's row
# order, so a rewrite of it has to be provably output-identical, not merely
# plausible. The reference implementation below is the pre-rewrite body, kept
# verbatim; every case runs both and compares byte for byte.

load '../helpers'

# NOT a setup() — helpers.bash owns that, and overriding it here would drop the
# host-safety it installs (throwaway $HOME, stubbed `security`, unset $GIT_DIR).
_boot() {
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
}

# The ORIGINAL, fork-per-line implementation. Do not "tidy" this — its whole job
# is to be the thing the fast one is measured against.
order_list_reference() {
  local f all listed line
  all="$(list_all_profiles | awk -F'\t' 'NF>=2{print $1"/"$2}' | while IFS= read -r _e; do
    [ -n "$_e" ] || continue
    tank_is_solo "${_e%%/*}" "${_e#*/}" || printf '%s\n' "$_e"
  done)"
  [ -n "$all" ] || return 0
  f="$(order_file)"
  listed=""
  if [ -f "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="$(printf '%s' "$line" | tr -d '[:space:]')"
      [ -n "$line" ] || continue
      printf '%s\n' "$all" | grep -qxF "$line" || continue
      printf '%s\n' "$listed" | grep -qxF "$line" && continue
      printf '%s\n' "$line"
      listed="$listed$line"$'\n'
    done < "$f"
  fi
  printf '%s\n' "$all" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$listed" | grep -qxF "$line" && continue
    printf '%s\n' "$line"
  done
}

_same_as_reference() {
  local fast ref
  fast="$(order_list)"
  ref="$(order_list_reference)"
  if [ "$fast" != "$ref" ]; then
    echo "order_list diverged from the reference"
    echo "--- fast ---"; printf '%s\n' "$fast"
    echo "--- reference ---"; printf '%s\n' "$ref"
    return 1
  fi
  printf '%s\n' "$fast"
}

@test "order_list: no order file at all — every tank, default order" {
  _boot
  clikae init claude alpha
  clikae init claude beta
  clikae init codex gamma
  run _same_as_reference
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "claude/alpha" ] || false
  [ "${lines[1]}" = "claude/beta" ] || false
  [ "${lines[2]}" = "codex/gamma" ] || false
}

@test "order_list: comments, blank lines and stray whitespace" {
  _boot
  clikae init claude alpha
  clikae init claude beta
  printf '# the fleet, top first\n\n  codex/nope  \nclaude/beta\t\n\n# trailing note\nclaude/alpha\n' \
    > "$(order_file)"
  run _same_as_reference
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "claude/beta" ] || false   # file order wins
  [ "${lines[1]}" = "claude/alpha" ] || false
  [ "${#lines[@]}" -eq 2 ] || false            # codex/nope does not exist
}

@test "order_list: a duplicated entry is emitted once" {
  _boot
  clikae init claude alpha
  clikae init claude beta
  printf 'claude/beta\nclaude/alpha\nclaude/beta\n' > "$(order_file)"
  run _same_as_reference
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ] || false
  [ "${lines[0]}" = "claude/beta" ] || false
}

@test "order_list: a solo tank holds no position, even if the file names it" {
  _boot
  clikae init claude alpha
  clikae init claude solo1
  clikae init claude beta
  clikae solo claude solo1
  printf 'claude/solo1\nclaude/beta\n' > "$(order_file)"
  run _same_as_reference
  [ "$status" -eq 0 ]
  [[ "$output" != *"solo1"* ]] || false
  [ "${lines[0]}" = "claude/beta" ] || false
  [ "${lines[1]}" = "claude/alpha" ] || false  # unlisted tanks follow, in default order
}

@test "order_list: a file entry that is only a SUFFIX of a real tank is not honoured" {
  _boot
  # The membership test used to be `grep -qxF`, which anchors both ends. The fast
  # path matches inside one long string instead, so each entry is fenced with
  # newlines — without the fence, this typo'd line would match "claude/work" and
  # order_list would emit a tank that does not exist. Nothing downstream checks
  # that its rows are real, so it would surface as a row that cannot be opened.
  clikae init claude work
  clikae init claude other
  printf 'ude/work\nclaude/other\n' > "$(order_file)"
  run _same_as_reference
  [ "$status" -eq 0 ]
  # Count, not a substring test: "claude/work" itself CONTAINS "ude/work", so
  # `!= *ude/work*` can never hold. Losing the fence adds a third row.
  [ "${#lines[@]}" -eq 2 ] || false
  [ "${lines[0]}" = "claude/other" ] || false
  [ "${lines[1]}" = "claude/work" ] || false
}

@test "order_list: every tank solo — empty, not the whole fleet" {
  _boot
  clikae init claude only
  clikae solo claude only
  run _same_as_reference
  [ "$status" -eq 0 ]
  [ -z "$output" ] || false
}

@test "solo_list and order_list partition the tanks exactly" {
  _boot
  clikae init claude a
  clikae init claude b
  clikae init codex c
  clikae solo claude b
  local both
  both="$(order_list; solo_list)"
  [ "$(printf '%s\n' "$both" | sort)" = "$(printf 'claude/a\nclaude/b\ncodex/c\n' | sort)" ] || false
}
