#!/usr/bin/env bats
# tests/bats/sess-prefix.bats — the session-name prefix, and the migration off
# the old one.
#
# 🔴 WHY THE OLD PREFIX IS STILL READ. `ck-` was clikae's session prefix from v0.4
# to 0.28.2 — an abbreviation nobody chose, in no README, no formula and no
# alias, living only in the one place a user reads it. Renaming it to `clikae-`
# is not a string edit, it is a MIGRATION: at the moment of upgrade there are
# sessions running under the old name and state files written with it. Drop the
# old prefix and those sessions vanish from the board, refuse to be attached, and
# get spawned over with a duplicate that splits the tank in two.
#
# So the tests that matter here are the ones about what was ALREADY there.

load '../helpers'

_iso() {
  ISO="$TEST_HOME/pfx-sock"; mkdir -p "$ISO"
  _t() { env -u TMUX TMUX_TMPDIR="$ISO" tmux "$@"; }
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/live.sh"
  export TMUX_TMPDIR="$ISO"; unset TMUX
}

teardown() {
  [ -n "${ISO:-}" ] && env -u TMUX TMUX_TMPDIR="$ISO" tmux kill-server 2>/dev/null
  [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
  return 0
}

@test "prefix: the new name is what gets created" {
  _iso
  local CLIKAE_TMUX_SESS CLIKAE_TMUX_SESS_EXISTS
  tmux_sessv "claude-x"
  [ "$CLIKAE_TMUX_SESS" = "clikae-claude-x" ] || { echo "got '$CLIKAE_TMUX_SESS'"; false; }
  [ "$CLIKAE_TMUX_SESS_EXISTS" -eq 0 ]
}

@test "prefix: a session under the OLD name is RENAMED, not duplicated" {
  # The migration guarantee, and the reason it is a rename rather than a second
  # name to answer to: upgrading mid-session must not start a second tmux session
  # for a tank you are already sitting in, and must not leave the old name
  # around for something else to have to know about later.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _iso
  _t new-session -d -s 'ck-claude-x' 'sleep 30'

  local CLIKAE_TMUX_SESS CLIKAE_TMUX_SESS_EXISTS
  tmux_sessv "claude-x"
  [ "$CLIKAE_TMUX_SESS_EXISTS" -eq 1 ] || { echo "did not see the legacy session"; false; }
  [ "$CLIKAE_TMUX_SESS" = "clikae-claude-x" ] || {
    echo "answered to '$CLIKAE_TMUX_SESS' instead of renaming"; false; }

  # …and the server agrees: one session, under the new name.
  run _t has-session -t '=clikae-claude-x'
  [ "$status" -eq 0 ] || { echo "the new name does not exist on the server"; false; }
  run _t has-session -t '=ck-claude-x'
  [ "$status" -ne 0 ] || { echo "the old name is still there — it was copied, not renamed"; false; }
}

@test "prefix: renaming does not disturb a neighbour with a longer name" {
  # `rename-session -t ck-claude-x` without an exact target would rename
  # ck-claude-x-1492 when the plain one is absent — the prefix-matching defect,
  # arriving through a new door.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _iso
  _t new-session -d -s 'ck-claude-x-1492' 'sleep 30'

  local CLIKAE_TMUX_SESS CLIKAE_TMUX_SESS_EXISTS
  tmux_sessv "claude-x"
  [ "$CLIKAE_TMUX_SESS_EXISTS" -eq 0 ] || { echo "matched a session it does not name"; false; }
  run _t has-session -t '=ck-claude-x-1492'
  [ "$status" -eq 0 ] || { echo "the neighbour was renamed out from under itself"; false; }
}

@test "prefix: the new name wins when both exist" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _iso
  _t new-session -d -s 'ck-claude-x' 'sleep 30'
  _t new-session -d -s 'clikae-claude-x' 'sleep 30'

  local CLIKAE_TMUX_SESS CLIKAE_TMUX_SESS_EXISTS
  tmux_sessv "claude-x"
  [ "$CLIKAE_TMUX_SESS" = "clikae-claude-x" ] || { echo "got '$CLIKAE_TMUX_SESS'"; false; }
}

@test "prefix: a digest-suffixed neighbour is not mistaken for the tank" {
  # The prefix change does not re-open the exact-target defect: ck-claude-x-1492
  # must not answer for claude-x under either name.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _iso
  _t new-session -d -s 'clikae-claude-x-1492' 'sleep 30'

  local CLIKAE_TMUX_SESS CLIKAE_TMUX_SESS_EXISTS
  tmux_sessv "claude-x"
  [ "$CLIKAE_TMUX_SESS_EXISTS" -eq 0 ] || {
    echo "matched the digest session; tmux_sessv is not using exact targets"; false; }
}

@test "prefix: the board lists ONE prefix, and leaves the human's sessions alone" {
  # 🔴 An old name is deliberately NOT listed here, and that is only safe because
  # the v1->v2 migration renames every one of them on first run — see the sweep
  # test below. Reading both here was the earlier design; it was dropped because
  # carrying two names forever is what the rename was meant to end.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _iso
  _t new-session -d -s 'clikae-codex-new' 'sleep 30'
  _t new-session -d -s 'someone-elses-work' 'sleep 30'

  run live_session_names
  [[ "$output" == *"clikae-codex-new"* ]] || { echo "lost the new session: $output"; false; }
  [[ "$output" != *"someone-elses-work"* ]] || { echo "claimed a session it did not start"; false; }
}

@test "prefix: the v1->v2 migration renames EVERY legacy session on the machine" {
  # 🔴 THE REASON A PER-ID RENAME IS NOT ENOUGH. tmux_sessv renames a session when
  # something launches into that tank — which never happens for a tank you are not
  # using today. That session would stay under the old name, and with the board
  # reading one prefix it would be alive but invisible, with `clikae <tank>`
  # starting a second one beside it. A per-machine sweep reaches it; it only has
  # to run once.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _iso
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/state_version.sh"
  _t new-session -d -s 'ck-claude-untouched' 'sleep 30'
  _t new-session -d -s 'ck-codex-alsoold' 'sleep 30'
  _t new-session -d -s 'not-ours' 'sleep 30'

  _state_migrate_1

  run _t has-session -t '=clikae-claude-untouched'
  [ "$status" -eq 0 ] || { echo "a tank nobody launched into was left behind"; false; }
  run _t has-session -t '=clikae-codex-alsoold'
  [ "$status" -eq 0 ] || { echo "the sweep stopped after one"; false; }
  run _t has-session -t '=ck-claude-untouched'
  [ "$status" -ne 0 ] || { echo "the old name is still there"; false; }
  # …and it is a sweep of CLIKAE's sessions, not of the server.
  run _t has-session -t '=not-ours'
  [ "$status" -eq 0 ] || { echo "renamed a session clikae does not own"; false; }
}

@test "prefix: the migration leaves a legacy session alone when the new name is taken" {
  # Losing one of two sessions is worse than carrying an old name for another
  # hour. tmux_sessv prefers the new one; this stays visible until it ends.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _iso
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/state_version.sh"
  _t new-session -d -s 'ck-claude-both' 'sleep 30'
  _t new-session -d -s 'clikae-claude-both' 'sleep 30'

  _state_migrate_1

  run _t has-session -t '=ck-claude-both'
  [ "$status" -eq 0 ] || { echo "the collision was resolved by destroying one"; false; }
  run _t has-session -t '=clikae-claude-both'
  [ "$status" -eq 0 ] || { echo "the new one is gone"; false; }
}

@test "prefix: live_split reads engine and tank from the current name" {
  # live_split resolves the tank against the DISK, so it needs the profile store
  # as well as the prefixes.
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/live.sh"
  clikae init claude pfxtank
  run live_split "clikae-claude-pfxtank"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* && "$output" == *"pfxtank"* ]] || { echo "$output"; false; }

  # An old name is not this function's business any more: by the time anything
  # asks, the migration has renamed it.
  run live_split "ck-claude-pfxtank"
  [ "$status" -ne 0 ] || { echo "still splitting a name nothing should produce"; false; }
}

@test "prefix: an orphan under the OLD name is still swept — the sweep ignores prefixes" {
  # State files outlive sessions. A lock this loop never visits is never released
  # and never deleted — it would sit in the state dir forever.
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tui.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/commands/clean.sh"

  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  local dead=999996
  kill -0 "$dead" 2>/dev/null && skip "pid $dead is somehow alive here"
  : > "$sdir/ck-claude-old-$dead.scrollback"
  _clean_scrollback_gc 0
  [ ! -f "$sdir/ck-claude-old-$dead.scrollback" ] || {
    echo "the legacy orphan survived — the sweep is keying on the prefix"; false; }
}

@test "prefix: an UNSET prefix refuses loudly instead of doing nothing" {
  # 🔴 Both failure modes are silent, and they differ in direction, so both are
  # pinned. In the GC an empty prefix globs nothing (a no-op reported as success);
  # in live_session_names it builds `^(|)`, which matches EVERY line — the board
  # would claim every tmux session on the machine, including the human's own.
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/live.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tui.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/commands/clean.sh"

  CLIKAE_SESS_PREFIX="" CLIKAE_SESS_PREFIX_LEGACY="" run _clean_tmux_gc 0
  [ "$status" -ne 0 ] || { echo "GC ran with no prefix and reported success"; false; }

  CLIKAE_SESS_PREFIX="" CLIKAE_SESS_PREFIX_LEGACY="" run live_session_names
  [ -z "$output" ] || { echo "the board claimed sessions with no prefix set: $output"; false; }
}
