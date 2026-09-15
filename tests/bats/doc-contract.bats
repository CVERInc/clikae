#!/usr/bin/env bats
# tests/bats/doc-contract.bats — the doc gate must FIRE, not just be silent.
#
# scripts/doc-names-exist.sh was written because three defects shared one shape:
# a doc naming something the code lacked. Its first version checked one of the
# three and passed the negative controls for the other two — a gate motivated by
# three bugs that caught one. Silence on clean input proves nothing; each check
# needs a deliberate break that turns it red.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_gate() { bash "$CLIKAE_TEST_ROOT/scripts/doc-names-exist.sh"; }

# Work on a COPY of the repo: these tests deliberately corrupt sources, and a
# suite that edits its own checkout is one interrupted run away from a mess.
_copy_repo() {
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  ( cd "$CLIKAE_TEST_ROOT" && tar cf - lib docs scripts AGENTS.md README.md bin ) | ( cd "$REPO" && tar xf - )
}
_gate_in_copy() { bash "$REPO/scripts/doc-names-exist.sh"; }

@test "doc gate: passes on the repo as it stands" {
  run _gate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # P3-6 (round-2 review of #102): it passed while printing two
  # "bad substitution" lines on bash 5 — the fallback and the empty-tree guard
  # were dead. A pass has to be clean.
  [[ "$output" != *"bad substitution"* ]] || { echo "$output"; false; }
}

@test "doc gate: a copy inside an unrelated git repo falls back to the files on disk" {
  # `is-inside-work-tree` says yes and `ls-files` says nothing: the fallback
  # branch is the only thing between this and an empty source list.
  _copy_repo
  git -C "$BATS_TEST_TMPDIR" init -q . 2>/dev/null || git init -q "$BATS_TEST_TMPDIR"
  run _gate_in_copy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"bad substitution"* ]] || { echo "$output"; false; }
  [[ "$output" == *"docs name nothing the code lacks"* ]] || { echo "$output"; false; }
  # …and that pass is real: the same copy still fires on a missing name. With
  # the fallback dead the source list was empty and the gate passed anyway.
  printf '\n`tmux_no_such_function` is named here.\n' >> "$REPO/docs/DESIGN-tmux.md"
  run _gate_in_copy
  [ "$status" -ne 0 ] || { echo "vacuous pass inside an unrelated repo: $output"; false; }
  [[ "$output" == *"tmux_no_such_function"* ]] || { echo "$output"; false; }
}

@test "doc gate: fires when a doc names a function that does not exist" {
  _copy_repo
  printf '\n`tmux_no_such_function` is named here.\n' >> "$REPO/docs/DESIGN-tmux.md"
  run _gate_in_copy
  [ "$status" -ne 0 ] || { echo "the gate stayed silent"; false; }
  [[ "$output" == *"tmux_no_such_function"* ]] || { echo "$output"; false; }
}

@test "doc gate: fires when a doc names a tmux user option nothing sets" {
  # `@clikae_touch_scroll` in docs/usage.md is a claim that lib/core/tmux.sh
  # sets it. The first run of #88 tripped the FUNCTION check on it instead
  # (「defined nowhere」) — a true claim reported as the wrong kind of lie.
  _copy_repo
  printf '\n`set -g @clikae_no_such_option off` is documented here.\n' >> "$REPO/docs/usage.md"
  run _gate_in_copy
  [ "$status" -ne 0 ] || { echo "the gate stayed silent"; false; }
  [[ "$output" == *"@clikae_no_such_option — named in a doc as a tmux option"* ]] || { echo "$output"; false; }
}

@test "doc gate: a tmux user option the code sets is not a missing function" {
  run _gate
  [[ "$output" != *"clikae_touch_scroll"* ]] || { echo "$output"; false; }
}

@test "doc gate: a BARE mention of an @-option's name is still checked as a function" {
  # P2-1 (2026-09 R1 review): the @-option branch's unconditional `continue`
  # let a bare, function-shaped mention of the SAME name go unchecked purely
  # because that name also occurs, elsewhere, as `@name`. Reviewer's negative
  # control: `clikae_touch_scroll` already occurs as `@clikae_touch_scroll` in
  # docs/usage.md; name it a second time, bare and backtick-wrapped, as if it
  # were a function clikae calls — it must go red for that claim, on top of
  # (not instead of) the correct @-option claim staying green. A second name,
  # `clikae_ghost_helper`, never occurs with an `@` at all and was already
  # going red before this fix — kept here so a regression narrowing the check
  # back down would still be caught.
  _copy_repo
  printf '\nThe helper calls `clikae_touch_scroll` to decide, and `clikae_ghost_helper` to log.\n' \
    >> "$REPO/docs/usage.md"
  run _gate_in_copy
  [ "$status" -ne 0 ] || { echo "the gate stayed silent"; false; }
  [[ "$output" == *"clikae_touch_scroll — named in a doc, defined nowhere"* ]] || { echo "$output"; false; }
  [[ "$output" == *"clikae_ghost_helper — named in a doc, defined nowhere"* ]] || { echo "$output"; false; }
  # The @-option claim is still true and must not be reported as broken.
  [[ "$output" != *"@clikae_touch_scroll — named in a doc as a tmux option"* ]] || { echo "$output"; false; }
}

@test "doc gate: fires when a docstring names a caller that does not call" {
  # The shape that hid burn's missing prelaunch: an enumeration is only useful
  # if it is complete, so it is checked in both directions.
  _copy_repo
  perl -0pi -e 's{# store\? Called from [^\n]*}{# store? Called from switch.sh / lang.sh, right where}' \
    "$REPO/lib/core/fleet_mcp.sh"
  run _gate_in_copy
  [ "$status" -ne 0 ] || { echo "the gate stayed silent"; false; }
  [[ "$output" == *"lang.sh"* ]] || { echo "$output"; false; }
}

@test "doc gate: fires when a real caller is missing from the docstring" {
  _copy_repo
  perl -0pi -e 's{# store\? Called from [^\n]*}{# store? Called from switch.sh, right where}' \
    "$REPO/lib/core/fleet_mcp.sh"
  run _gate_in_copy
  [ "$status" -ne 0 ] || { echo "the gate stayed silent"; false; }
  [[ "$output" == *"does not list it"* ]] || { echo "$output"; false; }
}

@test "doc gate: fires when a tmux option a rule names is never set" {
  # window-size was described in Rule 1 for a year and set nowhere, so the
  # behaviour held on tmux 3.7b and not on 3.4.
  _copy_repo
  perl -0pi -e 's{^\s*chain\+=\(";" set-option -g window-size latest\)\n}{}m' "$REPO/lib/core/tmux.sh"
  run _gate_in_copy
  [ "$status" -ne 0 ] || { echo "the gate stayed silent"; false; }
  [[ "$output" == *"window-size"* ]] || { echo "$output"; false; }
}

# P2-5 (2026-09-14 round-2 review): the verify half matched `\bstatus-left\b`
# inside `status-left-length`, so two of the seven status options were vouched
# for by their longer siblings. Every one of the seven is deleted in turn from
# a copy, and the gate must go red NAMING that option — including the two that
# only ever exist in the source as a prefix of another option once deleted.
@test "doc gate: deleting the line that sets any status-* option turns the gate red" {
  local opt line
  for opt in status-left status-right status-left-length status-right-length \
             status-justify status-interval status-format; do
    _copy_repo
    # The exact text of the setting line, up to the option name and the
    # character after it — `status-left ` does not match `status-left-length`.
    case "$opt" in
      status-format) line="set-option -t \"=\$session:\" 'status-format[0]'" ;;
      *)             line="set-option -t \"=\$session:\" $opt " ;;
    esac
    grep -vF -- "$line" "$REPO/lib/core/tmux.sh" > "$REPO/tmux.sh.new"
    mv "$REPO/tmux.sh.new" "$REPO/lib/core/tmux.sh"
    # The copy must really have lost that line — a no-op edit would make this
    # test green for the wrong reason.
    ! grep -qE "set-option.*[\"' ]${opt}[\"' []" "$REPO/lib/core/tmux.sh" \
      || { echo "$opt: fixture edit did not remove the line"; false; }
    run _gate_in_copy
    [ "$status" -ne 0 ] || { echo "$opt: deleted, and the gate stayed green"; false; }
    [[ "$output" == *"$opt — named in DESIGN-tmux, never set"* ]] || { echo "$opt: $output"; false; }
    rm -rf "$REPO"
  done
}

@test "doc gate: fires on a name whose prefix is not in the legacy list" {
  # 🔴 Until 2026-08-16 check 1 extracted names by a hand-written prefix list —
  # a guess at what the docs name. Measured: 20 real functions were named in the
  # docs and invisible to it (tank_is_solo, next_tank, history_log, load_adapter,
  # five limit_*), and renaming one in the code left the gate green. This probe
  # is that blind spot: a backticked lowercase identifier with an underscore,
  # belonging to no listed prefix.
  _copy_repo
  printf '\n`frobnicate_widget` is named here.\n' >> "$REPO/docs/DESIGN-tmux.md"
  run _gate_in_copy
  [ "$status" -ne 0 ] || { echo "the gate stayed silent"; false; }
  [[ "$output" == *"frobnicate_widget"* ]] || { echo "$output"; false; }
}

@test "doc gate: a stray .bak must not answer for the source" {
  # The gate reads the tracked tree, not the working directory. A `sed -i.bak`
  # left the OLD definition on disk and rescued a function that no real file
  # defined any more — green on exactly the drift it exists to catch. (Same
  # copy leaks the other way too: the .bak counted as a caller, so check 2
  # demanded the docstring list `burn.sh.bak`.)
  _copy_repo
  fn="$(grep -rlE '^tank_is_solo\(\)' "$REPO/lib" | head -1)"
  [ -n "$fn" ] || skip "tank_is_solo moved; pick another predicate"
  cp "$fn" "$fn.bak"                              # the backup keeps the old name
  # shellcheck disable=SC2046  # the word split IS the argument list here
  perl -pi -e 's/\btank_is_solo\b/tank_is_private/g' $(grep -rl 'tank_is_solo' "$REPO/lib" "$REPO/bin" | grep -v '\.bak$')
  run _gate_in_copy
  [ "$status" -ne 0 ] || { echo "a .bak file answered for the source"; false; }
  [[ "$output" == *"tank_is_solo"* ]] || { echo "$output"; false; }
  [[ "$output" != *".bak"* ]] || { echo "the .bak was treated as a caller: $output"; false; }
}
