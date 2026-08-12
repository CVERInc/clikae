# shellcheck shell=bash
# lib/core/wake.sh — nudging a rate-limited tank back to work when its fuel
# returns.
#
# The whole feature is one keystroke, automated. When Claude says "you've hit
# your session limit · resets 3:50am", the session is not gone: it is sitting at
# its prompt with the conversation intact, and typing anything ("go") continues
# it. That is what a human does at 3:50am, and it is NOT a re-dispatch — there is
# no prompt being replayed, so no side effect happens twice.
#
# tmux is what makes it possible at all: at 3:50am nobody's terminal is open, but
# the session is still there. Without the tmux layer there would be nothing to
# type into.
#
# Design constraint, from the maintainer (2026-08-12): the verdict does not come
# from remembering whether a tank has fuel, it comes from the moment you hit the
# wall. So there is no daemon, no ~/.clikae/pending/*.json, no long-lived model
# of anyone's quota — the waiter lives inside the tmux session that got limited,
# and dies with it. If the session is gone there is nothing to resume anyway.

# WAKE_NUDGE — what gets typed. Deliberately not configurable: it only has to be
# a token that continues the conversation, and every candidate ("go", "thx",
# "continue") does the same thing. A knob here would be a setting nobody can
# have an opinion about.
WAKE_NUDGE="go"

# WAKE_BUFFER_SECONDS — how long after the stated reset to wait before typing.
#
# Measured, not guessed: across 194 real session-limit events, 116 of the outage
# windows contained no successful turn at all, and in those the earliest success
# after the stated reset was +30 SECONDS — six separate times. So the vendor's
# time is accurate to the second and is not a floor that has been rounded down;
# 60s is that margin doubled, not a hedge against unknown rounding.
WAKE_BUFFER_SECONDS=60

# WAKE_RETRY_MAX / WAKE_RETRY_BACKOFF — the reset instant is a lower bound on
# when the server agrees. A nudge that lands a moment early is refused and burns
# nothing but a turn, so we retry a few times and then stop, visibly. Retrying
# forever would turn a helper into something knocking on a door all night.
WAKE_RETRY_MAX=3
WAKE_RETRY_BACKOFF=120

# wake_pane_idle <session> [settle_seconds] -> 0 when it is safe to type into it.
#
# Typing blind is the failure this prevents. When a human does this at 3:50am
# their eyes check something first — that there IS a prompt, and that the engine
# is not mid-something. A script has no eyes, and a nudge delivered into a
# running tool call or a dead pane goes somewhere nobody intended.
#
# The check is deliberately about MECHANISM, not about what the screen says. A
# matcher for the engine's prompt would be reading vendor copy: it would pass
# review, work today, and quietly stop recognising the prompt after a redesign —
# and its failure mode is to type into whatever replaced it. Three questions
# instead, none of which any vendor can reword:
#
#   1. does the session still exist?      (tmux has-session)
#   2. is anything still alive in it?     (#{pane_dead})
#   3. has the screen stopped moving?     (identical captures, settle apart)
#
# (3) is the real content of "idle": an engine rendering output, a spinner, or a
# streaming reply changes the pane between captures. A quiescent screen is not a
# PROOF that the prompt is waiting — a genuinely hung process also sits still —
# but it is the strongest claim available without guessing at anyone's UI, and it
# is conservative in the right direction: when in doubt we do not type.
wake_pane_idle() {
  local session="$1" settle="${2:-2}" a b dead
  [ -n "$session" ] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "$session" 2>/dev/null || return 1

  dead="$(tmux display-message -p -t "$session" '#{pane_dead}' 2>/dev/null || printf '1')"
  [ "$dead" = "0" ] || return 1

  a="$(tmux capture-pane -p -t "$session" 2>/dev/null)" || return 1
  sleep "$settle"
  # The session can end during the settle; re-ask rather than compare against a
  # capture of something that is no longer there.
  tmux has-session -t "$session" 2>/dev/null || return 1
  b="$(tmux capture-pane -p -t "$session" 2>/dev/null)" || return 1

  [ "$a" = "$b" ]
}

# wake_send <session> [text] -> type the nudge and press Enter.
#
# Split from the gate on purpose: the gate is what has judgement, and a caller
# that wants to send without asking (a test, a human) should have to say so.
# `-l` sends the text literally, so a nudge is never interpreted as a tmux key
# name.
wake_send() {
  local session="$1" text="${2:-$WAKE_NUDGE}"
  [ -n "$session" ] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "$session" 2>/dev/null || return 1
  tmux send-keys -t "$session" -l "$text" 2>/dev/null || return 1
  tmux send-keys -t "$session" Enter 2>/dev/null || return 1
  return 0
}

# --- the preference: on by default, but asked once ---------------------------
#
# Decided 2026-08-12: automatically waking a limited tank is ON, but the FIRST
# time it would happen clikae asks, and remembers the answer. The reasoning cuts
# both ways and both halves matter — typing into someone's live session is a
# power, and clikae's rule for powers is explicit consent (informed-consent);
# but the person this is for already types "go" by hand at 3am, so defaulting to
# off would make them opt in to a thing they are already doing manually.
#
# Asking once is the resolution: the friction is paid a single time, by a person
# who is right there watching a limit banner, and never again. A prompt shown on
# every limit would be answered without reading within a week.
#
# 🔴 This file persists a PREFERENCE (what the human wants), never a tank's fuel
# state. Nothing here may grow into a record of who is dry — that is the model
# this feature was explicitly designed not to keep.

wake_pref_file() { printf '%s\n' "$CLIKAE_HOME/wake-on-reset"; }

# wake_pref_get -> on | off | unset  ("unset" is what triggers the one-time ask;
# anything unrecognised is treated as unset rather than guessed into on, so a
# corrupt file re-asks instead of silently acting.)
wake_pref_get() {
  local v=""
  [ -f "$(wake_pref_file)" ] && v="$(tr -d '[:space:]' < "$(wake_pref_file)" 2>/dev/null)"
  case "$v" in on|off) printf '%s' "$v" ;; *) printf 'unset' ;; esac
}

# wake_pref_set <on|off> -> persist. Returns 1 on an unknown value.
wake_pref_set() {
  case "$1" in on|off) : ;; *) return 1 ;; esac
  mkdir -p "$CLIKAE_HOME" 2>/dev/null || true
  printf '%s\n' "$1" > "$(wake_pref_file)" 2>/dev/null || true
}

# wake_pref_label <value> -> a short human description for status/help.
wake_pref_label() {
  case "$1" in
    on)    printf 'resume automatically when the limit lifts' ;;
    off)   printf 'never resume automatically' ;;
    unset) printf 'ask the first time it comes up' ;;
    *)     printf 'unknown' ;;
  esac
}

# wake_enabled -> 0 when a waiter should be attached without asking anything.
# $CLIKAE_WAKE is the one-shot override (on/off), tried first, and is never
# persisted — a flag for one run must not silently answer the question forever.
wake_enabled() {
  case "${CLIKAE_WAKE:-}" in
    on)  return 0 ;;
    off) return 1 ;;
  esac
  [ "$(wake_pref_get)" = "on" ]
}

# --- the waiter --------------------------------------------------------------

# wake_sit <session> <reset_epoch> -> 0 if the nudge was delivered, 1 if it gave
# up. This is the body that runs inside the tmux window; it blocks for hours.
#
# It reads the real clock on purpose — it IS the sleeper. What makes it testable
# anyway is that the instant it waits for is an argument: a test passes a target
# two seconds out and watches the whole path run for real, rather than mocking
# the one thing that could be wrong.
wake_sit() {
  local session="$1" reset="$2"
  [ -n "$session" ] && [ -n "$reset" ] || return 1
  local target=$(( reset + WAKE_BUFFER_SECONDS ))
  local attempt=0 now left

  while :; do
    now="$(date +%s)"
    if [ "$now" -lt "$target" ]; then
      left=$(( target - now ))
      printf '\r\033[K⏳ %s — resuming in %s (sends: %s)' \
        "$session" "$(wake_human_left "$left")" "$WAKE_NUDGE"
      # Also put it in the window NAME, so the status bar carries the countdown
      # without anyone switching to this window. An automatic action nobody can
      # see is the kind most worth showing: from the engine's own window you can
      # tell it is waiting, and roughly for how long.
      tmux rename-window -t "$session:wake" "wake $(wake_human_left "$left")" 2>/dev/null || true
      # Wake up often enough that the countdown is not a lie, but not so often
      # that a machine asleep for eight hours spins. 30s is under the resolution
      # anybody reads a countdown at.
      if [ "$left" -gt 30 ]; then sleep 30; else sleep "$left"; fi
      continue
    fi

    if wake_pane_idle "$session" 2; then
      if wake_send "$session"; then
        # The countdown line is overwritten in place, so clear it first and then
        # let the badge speak: sending the nudge changed something, which is the
        # question `[ DONE ]` answers.
        printf '\r\033[K'
        log_done "$(printf '%s — sent "%s" at %s' "$session" "$WAKE_NUDGE" "$(date '+%H:%M:%S')")"
        return 0
      fi
    fi

    attempt=$(( attempt + 1 ))
    if [ "$attempt" -ge "$WAKE_RETRY_MAX" ]; then
      # Stop visibly. A waiter that quietly disappears leaves someone believing
      # their work resumed; the window stays with the reason written in it.
      printf '\r\033[K'
      log_warn "$(printf '%s — gave up after %s attempt(s).' "$session" "$attempt")"
      printf '   The pane was not ready to type into (busy, or the engine exited).\n'
      printf '   Nothing was sent. Attach and continue by hand.\n'
      return 1
    fi
    printf '\r\033[K… %s — not ready (attempt %s/%s), retrying in %ss\n' \
      "$session" "$attempt" "$WAKE_RETRY_MAX" "$WAKE_RETRY_BACKOFF"
    target=$(( now + WAKE_RETRY_BACKOFF ))
  done
}

# wake_human_left <seconds> -> "13h38m" / "7m" / "45s"
wake_human_left() {
  local s="$1"
  if   [ "$s" -ge 3600 ]; then printf '%dh%02dm' "$(( s / 3600 ))" "$(( (s % 3600) / 60 ))"
  elif [ "$s" -ge 60   ]; then printf '%dm' "$(( s / 60 ))"
  else                         printf '%ds' "$s"; fi
}

# wake_attach <session> <reset_epoch> -> open the waiter as a window INSIDE the
# limited session, and print what it will do.
#
# Inside, not beside: the waiter has no life of its own, no state file, and no
# way to outlive the thing it is waiting for. Killing the session kills it, which
# is the correct behaviour — if the session is gone there is nothing to resume.
wake_attach() {
  local session="$1" reset="$2" bin="${CLIKAE_BIN:-clikae}"
  [ -n "$session" ] && [ -n "$reset" ] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "$session" 2>/dev/null || return 1
  # One waiter per session. A second limit banner while one is already counting
  # down must not stack up two things typing into the same pane.
  if tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -qx 'wake'; then
    return 0
  fi
  tmux new-window -d -t "$session" -n wake \
    "'$bin' wake --sit '$session' '$reset'" 2>/dev/null || return 1
  return 0
}

# wake_sessions_for <engine> <tank> -> the live tmux sessions belonging to this
# tank, one per line.
#
# There can be more than one. Since 2026-08-13 a session's name carries a digest
# of the argv it was started with, so `clikae claude x` and a resumed
# conversation on the same tank are separate sessions — which is the point: they
# are separate conversations. A usage limit hits the ACCOUNT, so every one of
# them is stuck, and each needs its own waiter typing into its own pane.
#
# The digest is always digits, which is what makes this safe for a tank whose
# name contains a hyphen: `ck-claude-my-tank` matches, `ck-claude-my` does not
# swallow it, and only a trailing all-digit field is read as a digest.
wake_sessions_for() {
  local engine="$1" tank="$2" base
  command -v tmux >/dev/null 2>&1 || return 0
  base="ck-$engine-$tank"
  tmux list-sessions -F '#{session_name}' 2>/dev/null \
    | grep -E "^${base}(-[0-9]+)?$" || true
}

# wake_offer <engine> <tank> <reset-phrase> -> attach a waiter, asking once the
# first time. Shared by the two places a limit is noticed: `clikae watch` tailing
# a transcript, and the supervised launch noticing on the way out.
#
# The user's own framing, and it is the right one: staying put is staying put,
# and being asked where to go next belongs to LEAVING. So this is offered
# alongside the carry rather than instead of it — they are not alternatives, and
# nobody has to choose.
#
# Silent when there is nothing to attach to. Chiefly: the supervised path runs
# after the engine has exited, and an exited engine took its session with it —
# there is no conversation left to resume, so there is nothing to wait for. A
# detach leaves the session alive, and that is the case this is for.
wake_offer() {
  local cli="$1" profile="$2" reset="$3" epoch now
  # Two `local`s on purpose: a variable assigned earlier in the SAME `local` is
  # not yet visible, so folding this in would build "ck--" and then quietly find
  # no session — a waiter that never attaches and never says why.
  local sessions
  sessions="$(wake_sessions_for "$cli" "$profile")"
  [ -n "$sessions" ] || return 0

  [ -n "$reset" ] || return 0
  now="$(date +%s)"
  epoch="$(limit_reset_epoch "$reset" "$now")" || return 0

  case "$(wake_pref_get)" in
    off) return 0 ;;
    unset)
      if confirm "Resume $cli/$profile automatically when the limit lifts ($reset)?"; then
        wake_pref_set on
      else
        wake_pref_set off
        log_dim "Won't ask again. Turn it on later with: clikae wake on"
        return 0
      fi
      ;;
  esac

  local session attached=0
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    wake_attach "$session" "$epoch" && attached=$((attached + 1))
  done <<EOF
$sessions
EOF
  if [ "$attached" -gt 0 ]; then
    log_done "Will resume $cli/$profile — $reset (+$((WAKE_BUFFER_SECONDS))s)"
    log_dim "  Watch or cancel it in that session's 'wake' window."
  fi
  return 0
}
