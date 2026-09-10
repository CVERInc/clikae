# shellcheck shell=bash
# lib/core/live.sh — the sessions that are running RIGHT NOW.
#
# tmux created a state the board had no category for. Before it, "what is running"
# was always "whatever is in front of me", so it did not need a section: closing
# the window ended it. Now it can be several conversations, on a machine you are
# not looking at, and the board's three sections answered neither "what is alive"
# nor "how do I get back into it" — a real gap, reported 2026-08-13 by someone who
# ssh'd in, ran `clikae`, and could not see the session they had left running.
#
# Only THIS machine's sessions. tmux is local, so a board on the tablet shows the
# tablet's. That is not a limitation to apologise for: it is the truth about where
# a session lives, and seeing it stated makes the mental model right.

# live_session_names -> the clikae-owned tmux sessions, newest first, one per line
# as: name <TAB> created-epoch <TAB> attached(0/1)
#
# Everything clikae starts is `ck-<engine>-<tank>` with an optional `-<digits>`
# suffix (a digest of the argv, so a resumed conversation is its own session).
# Anything else in the user's tmux is theirs and is left alone.
live_session_names() {
  command -v tmux >/dev/null 2>&1 || return 0
  # 🔴 An unset prefix here is WORSE than a no-op: `^(|)` matches every line, so
  # the board would claim every tmux session on the machine — including the ones
  # the human made by hand, which the prefix exists to leave alone. Refuse.
  [ -n "${CLIKAE_SESS_PREFIX:-}" ] || return 0
  tmux list-sessions -F '#{session_name}	#{session_created}	#{session_attached}' 2>/dev/null \
    | grep -E "^${CLIKAE_SESS_PREFIX}[^	]+	" \
    | sort -t'	' -k2,2 -rn || true
}

# live_split <session-name> -> "engine<TAB>tank", or nothing if it names no tank
# that actually exists.
#
# The parse is ambiguous on its own — a tank may contain hyphens, and so may the
# digest suffix — so it is RESOLVED AGAINST THE DISK rather than guessed. Ask the
# filesystem which reading is real:
#
#   ck-claude-my-tank-123   -> tank `my-tank` with digest 123, or tank `my-tank-123`?
#
# Both are legal names. Trying the stripped form first and falling back to the
# whole thing means the answer is whichever tank you actually have, and a session
# whose tank has been removed simply drops off the board instead of drawing a row
# that cannot be opened.
live_split() {
  local name="$1" rest engine tank
  case "$name" in
    "$CLIKAE_SESS_PREFIX"*) rest="${name#"$CLIKAE_SESS_PREFIX"}" ;;
    *) return 1 ;;
  esac
  engine="${rest%%-*}"
  tank="${rest#*-}"
  [ -n "$engine" ] && [ -n "$tank" ] && [ "$engine" != "$rest" ] || return 1

  local stripped="$tank"
  case "$tank" in *-[0-9]*) stripped="${tank%-*}" ;; esac
  case "${tank##*-}" in
    ''|*[!0-9]*) stripped="$tank" ;;      # the trailing field is not a digest
  esac

  for try in "$stripped" "$tank"; do
    [ -n "$try" ] || continue
    if [ -d "$(profile_dir "$engine" "$try" 2>/dev/null)" ]; then
      printf '%s\t%s\n' "$engine" "$try"
      return 0
    fi
  done
  return 1
}

# live_wake_note <session-name> -> what the waiter in this session is counting
# down to, or nothing.
#
# The waiter carries its remaining time in its own window NAME (`wake 13h38m`),
# which is what lets the status bar show it without switching windows — and lets
# the board read it with one call and no state of its own.
live_wake_note() {
  local name="$1" w
  command -v tmux >/dev/null 2>&1 || return 0
  w="$(tmux list-windows -t "=$name:" -F '#{window_name}' 2>/dev/null | grep -E '^wake( |$)' | head -n 1)"
  [ -n "$w" ] || return 0
  # `wake 13h38m` -> `13h38m`; a bare `wake` has not started counting yet.
  case "$w" in wake\ *) printf '%s' "${w#wake }" ;; esac
}

# live_session_id <session-name> -> the transcript session id THIS tmux session
# was launched to drive, or nothing.
#
# Set by lib/core/tmux.sh's tmux_set_session_id, at launch, whenever the
# identity is knowable before or at the moment the engine starts: a RESUME of
# a SPECIFIC past session by id (`clikae resume`, the board's own "resume"
# row, or a hand-typed `--resume <sid>`), or — for an engine whose adapter
# defines adapter_new_session_args (claude: `--session-id <uuid>`) — a bare
# "start fresh" launch too, since clikae can mint the id itself and hand it to
# the engine before it ever runs (see switch.sh's identity block). Only an
# engine with NEITHER of those (codex, antigravity today) leaves a bare launch
# with nothing recorded: this returns nothing for those sessions, on purpose,
# and the caller (_home_live_rows) falls back to the tank-scoped guess and
# marks it as one, rather than this function inventing an answer it does not
# have.
#
# Reads the tmux option first (what a live board actually queries, and the
# copy that goes away with the session) and falls back to the mirrored state
# file — written at the same moment, see tmux_set_session_id — for a caller
# with no tmux on PATH at all, or a session whose option vanished from under
# it. The tmux check below guards only the FIRST read: returning early for
# "no tmux" instead would skip the state file too, defeating the one case it
# exists for.
live_session_id() {
  local name="$1" v=""
  if command -v tmux >/dev/null 2>&1; then
    v="$(tmux show-options -t "=$name:" -v '@clikae_session_id' 2>/dev/null || true)"
  fi
  if [ -z "$v" ]; then
    v="$(cat "$HOME/.clikae/state/${name}.session_id" 2>/dev/null || true)"
  fi
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}
