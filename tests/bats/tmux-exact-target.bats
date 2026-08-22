#!/usr/bin/env bats
# tests/bats/tmux-exact-target.bats — every tmux target names ONE session.
#
# 🔴 THE DEFECT. tmux's `-t` is not an exact match. Given only `ck-claude-x-1492`
# on the server, `tmux has-session -t ck-claude-x` answers YES, because tmux
# falls back to prefix matching. Every target in this codebase was written that
# way, and the digest suffix — added so a resumed conversation gets its own
# session — is exactly what makes one clikae session name a prefix of another.
#
# So on a machine with a resumed session open (the maintainer has five such
# scrollback files on disk right now):
#
#   clikae claude x
#     -> has-session -t ck-claude-x   -> YES  (it matched ck-claude-x-1492)
#     -> so nothing is spawned
#     -> attach -t ck-claude-x        -> lands in the RESUMED conversation
#
# You asked for the tank and got someone else's chat, silently. The same
# mismatch reaches `kill-session` in clean.sh, which is not a wrong window but a
# destroyed one, and `send-keys` in wake.sh, which types into it.
#
# The fix is tmux's own exact-match syntax: `=name` for a session target and
# `=name:` for a window or pane target. The disease is proved first — without
# that control this file only shows that tmux can find things.

load '../helpers'

_iso() {                       # a server of our own, so nothing here can reach a real tank
  ISO="$TEST_HOME/exact-sock"; mkdir -p "$ISO"
  _t() { env -u TMUX TMUX_TMPDIR="$ISO" tmux "$@"; }
}

teardown() {
  [ -n "${ISO:-}" ] && env -u TMUX TMUX_TMPDIR="$ISO" tmux kill-server 2>/dev/null
  [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
  return 0
}

@test "exact target: the DISEASE is real — a bare -t matches by prefix" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _iso
  _t new-session -d -s 'ck-claude-x-1492' 'sleep 30'

  # There is no session called ck-claude-x. tmux says there is.
  run _t has-session -t 'ck-claude-x'
  [ "$status" -eq 0 ] || { echo "tmux stopped prefix-matching; this file's premise is gone"; false; }

  # …and with `=` it tells the truth.
  run _t has-session -t '=ck-claude-x'
  [ "$status" -ne 0 ] || { echo "an exact target matched a session that does not exist"; false; }
}

@test "exact target: kill-session with a bare -t destroys the WRONG session" {
  # The reason this file exists rather than a comment. Same control, but on the
  # command whose mistake cannot be undone.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _iso
  _t new-session -d -s 'ck-codex-work-77' 'sleep 30'

  run _t kill-session -t 'ck-codex-work'          # a session that does not exist
  [ "$status" -eq 0 ] || { echo "expected the prefix kill to succeed (the defect)"; false; }
  run _t has-session -t '=ck-codex-work-77'
  [ "$status" -ne 0 ] || { echo "the bare kill did not reach it; premise gone"; false; }

  # With `=`, the bystander lives.
  _t new-session -d -s 'ck-codex-work-77' 'sleep 30'
  run _t kill-session -t '=ck-codex-work'
  [ "$status" -ne 0 ]
  run _t has-session -t '=ck-codex-work-77'
  [ "$status" -eq 0 ] || { echo "an exact kill took out a session it did not name"; false; }
}

@test "exact target: tmux_label leaves a longer-named neighbour alone" {
  # Real product code, not a demonstration: tmux_label sets status-left, renames
  # the window and turns automatic-rename off. Bare targets aimed all three at
  # whichever session merely STARTED with the name.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _iso
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"

  _t new-session -d -s 'ck-claude-x-1492' -n 'claude' 'sleep 30'
  _t set-option -t '=ck-claude-x-1492:' status-left '[UNTOUCHED] '

  # Label a session that DOES NOT EXIST. Nothing should happen to the neighbour.
  TMUX_TMPDIR="$ISO" env -u TMUX bash -c '
    . "'"$CLIKAE_TEST_ROOT"'/lib/core/log.sh" 2>/dev/null || true
    . "'"$CLIKAE_TEST_ROOT"'/lib/core/tmux.sh"
    tmux_label "ck-claude-x" "claude" "x"
  ' >/dev/null 2>&1 || true

  local left; left="$(_t show-options -v -t '=ck-claude-x-1492:' status-left 2>/dev/null)"
  [ "$left" = "[UNTOUCHED] " ] || {
    echo "tmux_label relabelled a session it did not name: status-left is now '$left'"; false; }
}

@test "exact target: every session target in lib/ is exact" {
  # 🔴 A CONVENTION NOTHING ENFORCES IS A CONVENTION THAT DRIFTS BACK. This one
  # is invisible when it regresses: a bare target works perfectly until the day
  # two session names share a prefix, which is the day a digest suffix appears.
  #
  # Two kinds of target legitimately do not start with `=` here, and both are
  # named rather than pattern-matched, so the exception cannot widen by accident:
  #
  #   $TMUX_PANE            a pane ID (`%3`), not a name — IDs are already exact
  #   $_WT_SESS/$_WT_PANE   wake.sh's resolver already put the `=` in. It exists
  #                         because wake's parameter is session-OR-target, and
  #                         the first version of this very change produced
  #                         `=sess:2:` by rewriting on the variable's name. The
  #                         exactness moved into the variable; this lint has to
  #                         be told, or it flags the correct shape — which it
  #                         did, on the run that added it.
  local bad=""
  local subs='has-session|kill-session|attach|attach-session|switch-client|list-clients'
  subs="$subs|display-message|set-option|set-window-option|rename-window"
  subs="$subs|list-windows|capture-pane|send-keys|new-window"

  while IFS= read -r line; do
    case "$line" in
      *TMUX_PANE*|*'$_WT_SESS'*|*'$_WT_PANE'*) continue ;;
    esac
    bad="$bad$line"$'\n'
  done < <(grep -rnE "tmux (${subs})\b[^\"]*-t \"[^=]" "$CLIKAE_TEST_ROOT/lib" 2>/dev/null || true)

  [ -z "$bad" ] || { echo "these tmux targets are not exact:"; echo "$bad"; false; }
}

@test "exact target: that lint actually fires" {
  # The check above passes on a clean tree, which is also what a broken check
  # does. Hand it a file with the old shape and require it to notice.
  local d="$TEST_HOME/lintcheck"; mkdir -p "$d"
  printf 'tmux has-session -t "$session" 2>/dev/null\n' > "$d/bad.sh"
  run grep -rnE 'tmux (has-session|kill-session)\b[^"]*-t "[^=]' "$d"
  [ "$status" -eq 0 ] || { echo "the lint pattern does not match the old shape"; false; }

  printf 'tmux has-session -t "=$session" 2>/dev/null\n' > "$d/good.sh"
  run grep -rnE 'tmux (has-session|kill-session)\b[^"]*-t "[^=]' "$d/good.sh"
  [ "$status" -ne 0 ] || { echo "the lint flags the FIXED shape too"; false; }
}
