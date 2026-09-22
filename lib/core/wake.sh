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

# --- the trace ----------------------------------------------------------------
#
# 🔴 WHY A FILE, IN A FEATURE WHOSE WHOLE DESIGN IS "NO STATE FILE". The waiter
# lives in a tmux window and dies with the session, which is right — and it took
# everything it ever said with it. Measured over 21 days of one tank's
# transcripts: 24 limit events, and the nudge appeared once. Nobody could name a
# single one of the other 23 outcomes, because the only record was text on a
# screen in a window nobody had open at 3:50am.
#
# So this writes down what HAPPENED, never what is TRUE NOW. That distinction is
# the whole reason the no-state-file rule exists: a record of who is dry would be
# a model of someone's quota that goes stale and then lies. A line saying "at
# 03:51 this waiter typed go" is an event; it cannot rot, and deleting the whole
# directory costs nothing but the history.
WAKE_LOG_MAX=200

wake_log_dir() { printf '%s' "$CLIKAE_HOME/state/wake"; }

# wake_stamp <epoch> -> that instant in UTC ISO-8601. BSD spells it `-r`, GNU
# spells it `-d @…`, and neither accepts the other's flag; the bare epoch is the
# honest answer on anything that accepts neither.
wake_stamp() {
  date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
    date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
    printf 'epoch %s' "$1"
}

# wake_log_file <engine> <tank> <session> -> the per-tank log path. One file per
# TANK, not per session: a usage limit hits the account, so every session on that
# tank has the same outage, and reading them interleaved in one place is what
# makes "what happened at the last reset" a single question.
wake_log_file() {
  local engine="$1" tank="$2" session="$3" name
  if [ -n "$engine" ] && [ -n "$tank" ]; then name="$engine-$tank"; else name="session-$session"; fi
  printf '%s/%s.log' "$(wake_log_dir)" "${name//[^A-Za-z0-9._-]/_}"
}

# wake_trace <engine> <tank> <session> <event> [detail] -> append one line.
#
# Never fails the caller: a waiter that aborted because its log was unwritable
# would have traded the outcome for the record of it. Tab-separated so the
# summary below can read it back without a parser, and capped at 2×WAKE_LOG_MAX
# lines so a tank that goes dry every day for a year still costs a few KB.
wake_trace() {
  local engine="$1" tank="$2" session="$3" event="$4" detail="${5:-}" f n
  [ -n "${CLIKAE_HOME:-}" ] || return 0
  f="$(wake_log_file "$engine" "$tank" "$session")"
  mkdir -p "$(wake_log_dir)" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$session" "$event" "$detail" >> "$f" 2>/dev/null || return 0
  n="$(wc -l < "$f" 2>/dev/null | tr -d '[:space:]')" || return 0
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$n" -gt $(( WAKE_LOG_MAX * 2 )) ]; then
    tail -n "$WAKE_LOG_MAX" "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null
  fi
  return 0
}

# wake_trace_summary [max] -> the LAST outcome of each tank's log, newest first,
# as "<tank-label>\037<stamp>\037<event>\037<detail>". Returns 1 when there is
# nothing recorded, so a caller can stay silent rather than print a header over
# an empty list.
wake_trace_summary() {
  local max="${1:-5}" dir f label line stamp sess event detail rows=""
  dir="$(wake_log_dir)"
  [ -d "$dir" ] || return 1
  for f in "$dir"/*.log; do
    [ -f "$f" ] || continue
    line="$(tail -n 1 "$f" 2>/dev/null)"
    [ -n "$line" ] || continue
    IFS=$'\t' read -r stamp sess event detail <<EOF
$line
EOF
    : "$sess"
    label="${f##*/}"; label="${label%.log}"
    rows="$rows$stamp"$'\037'"$label"$'\037'"$event"$'\037'"$detail"$'\n'
  done
  [ -n "$rows" ] || return 1
  # Sorted by the stamp that leads each row, not by file mtime: the stamp is what
  # the reader is being shown, and a log touched by a rotation is not news.
  printf '%s' "$rows" | sort -r | head -n "$max"
}

# wake_ident <session> [engine] [tank] -> "<engine>\037<tank>".
#
# The waiter is handed its tank explicitly by everything that starts it today.
# The fallback reads the SESSION NAME, because that name is built from exactly
# these two fields (`<prefix><engine>-<tank>` plus an optional all-digit argv
# digest) — so a waiter left behind by an older binary, whose `--sit` call
# carries only the session, still lands in the right log and still gets its
# no-double-nudge check. Unknown is answered with two empty fields rather than a
# guess; the caller degrades, it does not invent a tank.
wake_ident() {
  local session="$1" engine="${2:-}" tank="${3:-}" rest
  if [ -n "$engine" ] && [ -n "$tank" ]; then
    printf '%s\037%s' "$engine" "$tank"; return 0
  fi
  local prefix="${CLIKAE_SESS_PREFIX:-clikae-}"
  case "$session" in
    "$prefix"?*) rest="${session#"$prefix"}" ;;
    *) printf '\037'; return 0 ;;
  esac
  # A trailing ALL-DIGIT field is the argv digest, not part of the tank name —
  # the same rule, and the same residual ambiguity for a tank literally called
  # `x-2`, that wake_sessions_for's `(-[0-9]+)?$` already lives with.
  case "$rest" in
    *-*) case "${rest##*-}" in ''|*[!0-9]*) : ;; *) rest="${rest%-*}" ;; esac ;;
  esac
  case "$rest" in
    ?*-?*) printf '%s\037%s' "${rest%%-*}" "${rest#*-}" ;;
    *) printf '\037' ;;
  esac
}

# wake_tank_recovered <engine> <tank> -> 0 when the transcript carries POSITIVE
# evidence that this account already came back: a successful turn, or the
# vendor's own `auto-continuation` line, newer than the newest limit.
#
# 🔴 Only rc=2 counts. limit_profile_dry's rc=1 means "found nothing", which is
# also what a tank whose transcripts fell out of the 5h window looks like — and
# that is precisely the case the nudge exists for. Treating "no evidence" as
# "recovered" would turn this guard into the silence it was added to remove.
wake_tank_recovered() {
  local engine="$1" tank="$2" dir rc=0
  [ -n "$engine" ] && [ -n "$tank" ] || return 1
  declare -F limit_profile_dry >/dev/null 2>&1 || return 1
  declare -F profile_dir >/dev/null 2>&1 || return 1
  dir="$(profile_dir "$engine" "$tank" 2>/dev/null)" || return 1
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  limit_profile_dry "$engine" "$dir" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

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
# but it is the strongest claim available without guessing at anyone's UI.
#
# 🔴 AND (3) IS NO LONGER A VETO AFTER THE RESET INSTANT. It was, and the cost
# was measured: over 21 days of one tank's transcripts, 24 limit events and ONE
# nudge. "Conservative in the right direction" only holds while a moving screen
# can mean a turn is running — and on a tank that is still dry, no turn can be
# running, because the API is refusing them. What a limited engine actually puts
# on screen is a banner with a live countdown in it, and a countdown re-renders
# every second forever. Verified against the mechanism rather than assumed: a
# pane whose ONLY change is one ticking line fails this check on every capture
# pair, while the SAME banner text held still passes it — so the waiter spent
# its three attempts, gave up inside five minutes of the reset, and said so into
# a window that dies with the session. wake_sit keeps calling this, for the
# settle delay and for the chance of a clean answer, but it acts on the tank's
# dryness instead (see wake_sit).

# 🔴 SESSION-OR-TARGET, RESOLVED ONCE. Both public functions below take either a
# bare session (`ck-claude-x`) or one with a window (`ck-claude-x:2`, which is
# what wake_engine_target returns so the nudge misses the waiter's own pane).
# tmux needs the two spelled differently — `=sess` for a session target, `=sess:2`
# or `=sess:` for a pane one — and reading the parameter's NAME rather than its
# contract is what broke four wake tests the day every target was made exact.
# Sets two variables instead of forking a subshell for each call.
_wake_targetsv() {
  _WT_SESS="=${1%%:*}"
  case "$1" in
    *:*) _WT_PANE="=$1"  ;;
    *)   _WT_PANE="=$1:" ;;
  esac
}


# wake_pane_live <session-or-target> -> 0 when there is still something to type
# INTO: the session exists and the pane is not a corpse. Questions (1) and (2)
# above, split out from (3).
#
# 🔴 The split is the point, not tidiness. Those two are about the TARGET
# EXISTING and can never be waived; (3) is about the target being BUSY, and
# after a reset on a dry tank "busy" cannot mean what it means the rest of the
# time (see wake_sit). Folded into one boolean they were waived or enforced
# together, and the only way to stop vetoing on a moving screen was to stop
# checking for a dead pane too.
wake_pane_live() {
  local session="$1" dead
  [ -n "$session" ] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  local _WT_SESS _WT_PANE; _wake_targetsv "$session"
  tmux has-session -t "$_WT_SESS" 2>/dev/null || return 1
  dead="$(tmux display-message -p -t "$_WT_PANE" '#{pane_dead}' 2>/dev/null || printf '1')"
  [ "$dead" = "0" ]
}

wake_pane_idle() {
  local session="$1" settle="${2:-2}" a b
  wake_pane_live "$session" || return 1
  local _WT_SESS _WT_PANE; _wake_targetsv "$session"

  a="$(tmux capture-pane -p -t "$_WT_PANE" 2>/dev/null)" || return 1
  sleep "$settle"
  # The session can end during the settle; re-ask rather than compare against a
  # capture of something that is no longer there.
  tmux has-session -t "$_WT_SESS" 2>/dev/null || return 1
  b="$(tmux capture-pane -p -t "$_WT_PANE" 2>/dev/null)" || return 1

  [ "$a" = "$b" ]
}

# wake_engine_target <session> -> a tmux target for the session's ENGINE pane:
# its first non-`wake` window, as `<session>:<index>`.
#
# 🔴 The nudge must not land in the waiter's OWN pane. The waiter lives in a
# `wake` window, and the user is explicitly told to "watch or cancel it in that
# session's wake window" — so at reset time that window may well be the session's
# ACTIVE one. A bare `-t <session>` resolves to the CURRENT window, so the nudge
# would be typed into the countdown pane and the engine would never resume.
# Targeting the engine window by index removes the dependency on what is focused.
# Falls back to the bare session when it can't tell (older tmux, or the only
# window is the engine's) — which is the previous behaviour, now the exception.
wake_engine_target() {
  local session="$1" idx
  command -v tmux >/dev/null 2>&1 || { printf '%s' "$session"; return 0; }
  idx="$(tmux list-windows -t "=$session:" -F '#{window_index} #{window_name}' 2>/dev/null \
    | awk '{ i=$1; $1=""; n=substr($0,2); if (n!="wake" && n !~ /^wake /) { print i; exit } }')"
  if [ -n "$idx" ]; then printf '%s:%s' "$session" "$idx"; else printf '%s' "$session"; fi
}

# wake_send <session-or-target> [text] -> type the nudge and press Enter.
#
# Split from the gate on purpose: the gate is what has judgement, and a caller
# that wants to send without asking (a test, a human) should have to say so.
# `-l` sends the text literally, so a nudge is never interpreted as a tmux key
# name. The target may be a bare session (current window) or `<session>:<win>`;
# wake_sit passes the engine window so the nudge never hits the waiter's own pane.
wake_send() {
  local target="$1" text="${2:-$WAKE_NUDGE}"
  [ -n "$target" ] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  local _WT_SESS _WT_PANE; _wake_targetsv "$target"
  tmux has-session -t "$_WT_SESS" 2>/dev/null || return 1
  tmux send-keys -t "$_WT_PANE" -l "$text" 2>/dev/null || return 1
  tmux send-keys -t "$_WT_PANE" Enter 2>/dev/null || return 1
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

# wake_sit <session> <reset_epoch> [engine] [tank] -> 0 if the nudge was
# delivered (or deliberately skipped), 1 if it gave up. This is the body that
# runs inside the tmux window; it blocks for hours.
#
# It reads the real clock on purpose — it IS the sleeper. What makes it testable
# anyway is that the instant it waits for is an argument: a test passes a target
# two seconds out and watches the whole path run for real, rather than mocking
# the one thing that could be wrong.
#
# 🔴 THE ORDER OF THE THREE QUESTIONS IT ASKS AT THE RESET, and why it is this
# order:
#
#   1. Did the vendor already continue this conversation by itself?  -> skip.
#      Claude Code now writes its own "usage limit has reset, continue" line
#      within a minute of some resets. Typing into that is a second "go" landing
#      in a conversation that is already working, which is the one way this
#      feature can do harm. So it is asked FIRST, and asked again HERE rather
#      than trusted from when the waiter was attached hours ago.
#   2. Is there still something to type into?  (session, pane not dead) -> else
#      retry, then give up.
#   3. Has the screen stopped moving? -> a SETTLE, not a veto. On a tank that is
#      still dry no turn can be running, so a moving screen is a countdown
#      re-rendering, not work in flight. Vetoing on it is what made this feature
#      fire once in 24 limits.
#
# Every one of those outcomes is written to the tank's trace (wake_trace), because
# the previous version's whole account of itself was text in a window that dies
# with the session.
wake_sit() {
  local session="$1" reset="$2" engine="${3:-}" tank="${4:-}"
  [ -n "$session" ] && [ -n "$reset" ] || return 1
  local _id; _id="$(wake_ident "$session" "$engine" "$tank")"
  engine="${_id%%$'\037'*}"; tank="${_id#*$'\037'}"
  local target=$(( reset + WAKE_BUFFER_SECONDS ))
  local attempt=0 now left
  wake_trace "$engine" "$tank" "$session" "attached" \
    "reset $(wake_stamp "$reset") +${WAKE_BUFFER_SECONDS}s"

  while :; do
    # Two different endings, and they are not the same event.
    #
    # The session vanishing under us is abnormal — something killed it — and the
    # caller has always been told so with a non-zero exit. Keep that.
    if ! tmux has-session -t "=$session" 2>/dev/null; then
      wake_trace "$engine" "$tank" "$session" "session-gone" "nothing left to type into"
      return 1
    fi
    # Being the LAST window is normal: the engine finished. We are the reason the
    # session is still alive, so staying means counting down in front of someone
    # who cannot leave — the failure being fixed. Leave cleanly.
    tmux list-windows -t "=$session:" -F '#{window_name}' 2>/dev/null \
      | grep -qvE '^wake( |$)' || return 0
    now="$(date +%s)"
    if [ "$now" -lt "$target" ]; then
      left=$(( target - now ))
      printf '\r\033[K⏳ %s — resuming in %s (sends: %s)' \
        "$session" "$(wake_human_left "$left")" "$WAKE_NUDGE"
      # Also put it in the window NAME, so the status bar carries the countdown
      # without anyone switching to this window. An automatic action nobody can
      # see is the kind most worth showing: from the engine's own window you can
      # tell it is waiting, and roughly for how long.
      tmux rename-window -t "=$session:wake" "wake $(wake_human_left "$left")" 2>/dev/null || true
      # Wake up often enough that the countdown is not a lie, but not so often
      # that a machine asleep for eight hours spins. 30s is under the resolution
      # anybody reads a countdown at.
      if [ "$left" -gt 30 ]; then sleep 30; else sleep "$left"; fi
      continue
    fi

    # (1) The vendor may have continued by itself while we counted down. Asked
    # here, at the last possible moment, because the answer only becomes true in
    # the minute we are about to act in.
    if wake_tank_recovered "$engine" "$tank"; then
      printf '\r\033[K'
      wake_trace "$engine" "$tank" "$session" "skipped" "vendor auto-continued; nothing typed"
      log_done "$(printf '%s — %s/%s resumed on its own; nothing sent.' "$session" "$engine" "$tank")"
      return 0
    fi

    # Target the ENGINE window, not whatever window is focused — the waiter's own
    # `wake` window may be the active one (the user was told to watch it here).
    local _etgt; _etgt="$(wake_engine_target "$session")"
    # (2) Something to type into. Not waivable, and the only thing the retries
    # below are still for.
    if wake_pane_live "$_etgt"; then
      # (3) Settle — and only a settle. wake_pane_idle sleeps for the settle
      # window either way; its VERDICT is now a note in the trace rather than a
      # gate, because a dry tank cannot be mid-turn (see its header).
      local _bypassed=0
      wake_pane_idle "$_etgt" 2 || _bypassed=1
      if wake_send "$_etgt"; then
        # The countdown line is overwritten in place, so clear it first and then
        # let the badge speak: sending the nudge changed something, which is the
        # question `[ DONE ]` answers.
        printf '\r\033[K'
        if [ "$_bypassed" = 1 ]; then
          wake_trace "$engine" "$tank" "$session" "typed" \
            "\"$WAKE_NUDGE\" — screen still moving, idle check bypassed (tank still dry)"
          log_done "$(printf '%s — sent "%s" at %s' "$session" "$WAKE_NUDGE" "$(date '+%H:%M:%S')")"
          log_dim "  The screen was still moving (a limit banner counts down); the tank was still dry, so it was sent anyway."
        else
          wake_trace "$engine" "$tank" "$session" "typed" "\"$WAKE_NUDGE\" — pane idle"
          log_done "$(printf '%s — sent "%s" at %s' "$session" "$WAKE_NUDGE" "$(date '+%H:%M:%S')")"
        fi
        return 0
      fi
    fi

    attempt=$(( attempt + 1 ))
    wake_trace "$engine" "$tank" "$session" "attempt" \
      "$attempt/$WAKE_RETRY_MAX — no live pane to type into"
    if [ "$attempt" -ge "$WAKE_RETRY_MAX" ]; then
      # Stop visibly. A waiter that quietly disappears leaves someone believing
      # their work resumed; the window stays with the reason written in it — and
      # now the trace keeps it after the window is gone.
      printf '\r\033[K'
      wake_trace "$engine" "$tank" "$session" "gave-up" \
        "no live pane after $attempt attempt(s); nothing sent"
      log_warn "$(printf '%s — gave up after %s attempt(s).' "$session" "$attempt")"
      printf '   The pane was not there to type into (the engine exited, or it died).\n'
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
  local session="$1" reset="$2" engine="${3:-}" tank="${4:-}" bin="${CLIKAE_BIN:-clikae}"
  [ -n "$session" ] && [ -n "$reset" ] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "=$session" 2>/dev/null || return 1
  # One waiter per session. A second limit banner while one is already counting
  # down must not stack up two things typing into the same pane.
  # Prefix, not an exact name: the waiter renames its own window to carry the
  # countdown (`wake 9m`), so an exact `wake` stops matching seconds after it
  # starts. That guard would then let a SECOND waiter attach, and two of them
  # type into the same pane. Found by CI on Linux, where the rename won the race
  # that macOS lost — the test that caught it was watching this exact promise.
  if tmux list-windows -t "=$session:" -F '#{window_name}' 2>/dev/null \
     | grep -qE '^wake( |$)'; then
    return 0
  fi
  # The tank travels with the waiter so the trace lands in the right log and the
  # no-double-nudge re-check has something to ask about. Both are optional in
  # wake_sit (it falls back to reading the session name), so a waiter started by
  # an older binary still works — it just spells its own identity out loud here.
  tmux new-window -d -t "=$session:" -n wake \
    "'$bin' wake --sit '$session' '$reset' '$engine' '$tank'" 2>/dev/null || return 1
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
# name contains a hyphen: `clikae-claude-my-tank` matches, `clikae-claude-my`
# does not swallow it, and only a trailing all-digit field is read as a digest.
#
# 🔴 ONE PREFIX, because by the time anything calls this there is only one. The
# v1→v2 state migration renames every session off the old name on first run, and
# tmux_sessv renames any straggler an older binary makes. This briefly matched
# both, and the reason is worth keeping: a usage limit hits the ACCOUNT, so a
# session under any name clikae owns is just as stuck, and missing one means no
# waiter, no 3:50am nudge, and nothing said about it.
wake_sessions_for() {
  local engine="$1" tank="$2" base
  command -v tmux >/dev/null 2>&1 || return 0
  [ -n "${CLIKAE_SESS_PREFIX:-}" ] || return 0
  base="${CLIKAE_SESS_PREFIX}$engine-$tank"
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
    wake_attach "$session" "$epoch" "$cli" "$profile" && attached=$((attached + 1))
  done <<EOF
$sessions
EOF
  if [ "$attached" -gt 0 ]; then
    log_done "Will resume $cli/$profile — $reset (+$((WAKE_BUFFER_SECONDS))s)"
    log_dim "  Watch or cancel it in that session's 'wake' window."
  fi
  return 0
}

# --- the watcher: the half that was missing -----------------------------------
#
# WHY THIS EXISTS. The waiter worked; nothing ever started it. Detection lived in
# `clikae watch` (nobody starts a watcher in order to be interrupted later) and in
# the supervised launch, which only runs once the engine has EXITED. Sitting in a
# live session that hits its limit — the ordinary case, and the only one that
# matters at 3am — reached neither. Confirmed against a real limit on 2026-08-13:
# the tank went dry at 21:57 with "resets 12am (Asia/Tokyo)", the phrase parsed
# correctly to midnight, and no waiter was ever attached because nothing looked.
#
# So the session watches itself. Same shape as everything else here: it lives
# inside the tmux session, dies with it, and keeps no record of anyone's quota —
# it asks `limit_tank_dry`, which reads the transcript and self-clears, every time
# it wakes up.
#
# ONE WINDOW, TWO PHASES. The watcher IS the waiter's window, named `wake` from
# the start: while it is watching the name is bare, and once it is counting down
# the countdown rides in the name. That keeps a session to one extra window
# instead of two, and it means the "only one waiter per session" guard — which
# matches `^wake( |$)` — already covers the watching phase.

# WAKE_WATCH_INTERVAL — how often to ask whether this tank has gone dry.
#
# 60s, because the thing being waited for is measured in hours: a limit noticed a
# minute late costs nothing, while a tighter loop pays limit_tank_dry's transcript
# scan (the board's old hot spot) for no benefit anybody can perceive.
WAKE_WATCH_INTERVAL=60

# WAKE_ALONE_INTERVAL — how often the CHEAP question gets asked.
#
# 🔴 TWO QUESTIONS, TWO COSTS, AND THEY WERE SHARING A CLOCK. "Has this tank hit
# a limit?" is expensive (limit_tank_dry scans a transcript), and 60s is right for
# it — a limit noticed a minute late costs nothing. "Am I the only window left?"
# is one `tmux list-windows`, and 60s is badly wrong for it: that is exactly how
# long a human can sit looking at a countdown in a session whose engine has
# already gone, wondering where their work went. Reported that way.
#
# So the cheap one gets its own tick inside the long sleep. Not a shorter poll —
# the same two questions, each asked at the rate its answer decays.
WAKE_ALONE_INTERVAL=2

# wake_watch <engine> <tank> <session> -> watch until this tank runs dry, then
# hand over to the countdown. Returns non-zero only if it cannot start.
wake_watch() {
  local engine="$1" tank="$2" session="$3" reset epoch now
  [ -n "$engine" ] && [ -n "$tank" ] && [ -n "$session" ] || return 1

  while :; do
    # 🔴 Do NOT ask whether the session is alive. We are a window IN it, so we
    # are the reason it is alive — the condition can never become true, and the
    # loop runs forever. Reported 2026-08-15: the engine's window closed, this
    # window was the only one left, and the user was stranded on "watching for a
    # limit" with no way out but closing the terminal.
    #
    # Session gone entirely: so are we, and that has always been a clean exit.
    tmux has-session -t "=$session" 2>/dev/null || return 0
    # Ask about the ENGINE too: when no window other than ours remains, the work
    # is over and staying is what keeps a dead session on screen.
    #
    # 🔴 This guard shipped 2026-08-15 for exactly the symptom above and NEVER
    # FIRED ONCE, because it was written with the inside-single-quotes escape
    # idiom at the TOP level of the line:
    #     -F '"'"'#{window_name}'"'"'   →  tmux got  "'#{window_name}'"
    #     grep -qvE '"'"'^wake( |$)'"'"' →  grep got  "'^wake( |$)'"
    # So tmux emitted `'wake'` (quotes included) and grep was handed a pattern
    # whose `^` sits mid-string and can therefore never match anything — making
    # `grep -qv` succeed on EVERY input. The guard's condition was constant-true,
    # so the watcher kept looping after the engine window closed, the session it
    # lives in never died, and the NEXT launch onto that same session name found
    # `tmux has-session` true, started no engine, and dropped the user into a
    # window showing "watching for a limit" with nothing to type into. That is
    # the "sometimes it just hangs" report — the very failure this guard was
    # added to stop. Verified against real tmux; pinned by wake-sit.bats.
    tmux list-windows -t "=$session:" -F '#{window_name}' 2>/dev/null \
      | grep -qvE '^wake( |$)' || return 0

    if reset="$(limit_tank_dry "$engine" "$tank" 2>/dev/null)"; then
      if [ -n "$reset" ]; then
        now="$(date +%s)"
        if epoch="$(limit_reset_epoch "$reset" "$now")"; then
          printf '\r\033[K'
          log_info "$engine/$tank — $reset"
          # Hand over in place. wake_sit renames this same window as it counts.
          wake_sit "$session" "$epoch" "$engine" "$tank"
          return $?
        fi
        # A phrase with no time in it: say so once and keep watching, rather than
        # scheduling something at a guessed moment.
        printf '\r\033[K'
        log_warn "$engine/$tank is dry, but \"$reset\" carries no time to wait for."
      fi
    fi

    printf '\r\033[K%s/%s — watching for a limit' "$engine" "$tank"
    # Sleep in slices, asking the cheap question between them: if the engine's
    # window closes while we wait, leave NOW rather than at the end of the minute.
    local _slept=0
    while [ "$_slept" -lt "$WAKE_WATCH_INTERVAL" ]; do
      sleep "$WAKE_ALONE_INTERVAL"
      _slept=$((_slept + WAKE_ALONE_INTERVAL))
      tmux has-session -t "=$session" 2>/dev/null || return 0
      tmux list-windows -t "=$session:" -F '#{window_name}' 2>/dev/null \
        | grep -qvE '^wake( |$)' || return 0
    done
  done
}

# wake_attach_watcher <session> <engine> <tank> -> put the watching window in the
# session. Same one-per-session rule as the waiter, because it is the same window.
wake_attach_watcher() {
  local session="$1" engine="$2" tank="$3" bin="${CLIKAE_BIN:-clikae}"
  [ -n "$session" ] && [ -n "$engine" ] && [ -n "$tank" ] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "=$session" 2>/dev/null || return 1
  if tmux list-windows -t "=$session:" -F '#{window_name}' 2>/dev/null \
     | grep -qE '^wake( |$)'; then
    return 0
  fi
  tmux new-window -d -t "=$session:" -n wake \
    "'$bin' wake --watch '$engine' '$tank' '$session'" 2>/dev/null || return 1
  return 0
}

# wake_ask_once <engine> <tank> -> settle the preference, once, AT LAUNCH.
#
# The one-time ask used to happen when a limit was hit. That was the wrong
# moment, and the real limit on 2026-08-13 proved it twice over: the question
# would have been asked by a watcher in another window, where nobody would see
# it — and there was no watcher, because the preference had never been settled.
# A question nobody can answer is not consent, it is a deadlock.
#
# Launch is the right moment because a human is demonstrably there: they just
# typed the command. The friction is still paid exactly once.
#
# Silent whenever there is nobody to ask (a pipe, CI, a headless run) — and then
# nothing is scheduled either, which is the safe direction: this feature types
# into a live session, so an unanswered question means no.
wake_ask_once() {
  local engine="$1" tank="$2"
  [ "$(wake_pref_get)" = "unset" ] || return 0
  [ -t 0 ] && [ -t 1 ] || return 0
  command -v tmux >/dev/null 2>&1 || return 0

  if confirm "When $engine/$tank hits its usage limit, resume it automatically once the limit lifts?"; then
    wake_pref_set on
    log_dim "  It will type \"$WAKE_NUDGE\" into the session, ${WAKE_BUFFER_SECONDS}s after the vendor's reset time."
  else
    wake_pref_set off
    log_dim "  Won't ask again. Turn it on later with: clikae wake on"
  fi
  return 0
}
