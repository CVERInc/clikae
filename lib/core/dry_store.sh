# shellcheck shell=bash
# lib/core/dry_store.sh — persist a "this tank is dry until ~X" marker that LIVE
# catchers (burn's codex-exec stdout, _switch_supervise) write the moment they see
# a limit, so the PASSIVE board (clikae home) can light a red dot and show the
# vendor's verbatim reset phrase for engines whose limit never lands in a file.
#
# Why this exists: claude writes its limit into the transcript and agy into a log
# (both scannable after the fact), so home reads them directly. codex's limit is
# exec-stdout-only and vanishes when the run ends (burn-verified 2026-06-01). burn
# ALREADY detects it (limit_output_dry, which even extracts the reset phrase) but
# had nowhere to record it — so a passive `clikae home` opened later saw nothing.
# This is that record: the "dry-until window" limit.sh gestured at but never built.
#
# Honest by construction: the vendor's reset phrase is stored VERBATIM (never
# parsed into a countdown), and a marker self-clears several ways — an explicit
# success clears it (dry_store_clear, and — R1-P1-2 — a codex transcript turn
# observed AFTER the limit, see _limit_tank_dry_raw), a conservative TTL ages an
# unretained one out, and CLIKAE_DRY_MAX_RETAIN is the hard ceiling for a
# --retain-stale marker nothing ever explicitly clears. So a stale marker can
# never pin a tank red (or yellow) forever; better to turn green early and let
# the user retry than to fake a red. Best-effort throughout: a badge is a
# nicety, not a promise, so write/read failures degrade to "not dry" rather
# than abort the caller.

# CLIKAE_DRY_TTL — how long a dry marker is trusted before it's treated as stale.
# codex's usage window is ~5h; 6h is a touch generous so we don't clear a tank
# that's still genuinely limited. Overridable (tests pin it small).
: "${CLIKAE_DRY_TTL:=21600}"   # 6h, in seconds

# CLIKAE_DRY_MAX_RETAIN — the hard ceiling on --retain-stale (R1-P1-2). A retained
# marker is meant to survive the TTL as UNVERIFIED evidence only until the next
# observed turn clears it (see _limit_tank_dry_raw); if no turn is ever observed
# — an interactive codex used entirely outside clikae, say — that would keep a
# tank pinned yellow forever. This is the second, unconditional exit: past this
# age the marker is gone even with --retain-stale, same as main's plain TTL.
# Overridable (tests pin it small).
: "${CLIKAE_DRY_MAX_RETAIN:=604800}"   # 7d, in seconds

# dry_store_path <engine> <tank> -> the marker file for this tank.
dry_store_path() { printf '%s/dry/%s/%s\n' "$CLIKAE_HOME" "$1" "$2"; }

# dry_store_mark <engine> <tank> [reset_phrase] -> record that this tank is dry as
# of NOW, carrying the vendor's verbatim reset phrase (may be empty). One line:
# "<epoch>\t<reset_phrase>". A write failure is non-fatal.
#
# Format note: this line layout is part of the $CLIKAE_HOME state schema (see
# lib/core/state_version.sh / CLIKAE_STATE_VERSION). If it ever needs a new field,
# bump the schema version and add a migration rather than parsing both shapes here.
dry_store_mark() {
  local engine="$1" tank="$2" reset="${3:-}" f now
  f="$(dry_store_path "$engine" "$tank")"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  reset="$(printf '%s' "$reset" | tr -d '\n\r')"   # keep the record one line
  now="$(date +%s 2>/dev/null || echo 0)"
  printf '%s\t%s\n' "$now" "$reset" > "$f" 2>/dev/null || true
}

# dry_store_peekv <engine> <tank> [now] -> the SAME freshness verdict as
# dry_store_read, and NOTHING ELSE: it never removes a marker, never forks
# (pass <now> to skip this function's only `date`), and sets
#
#   _DRY_PEEK      none | fresh | stale | expired
#   _DRY_PEEK_RESET  the vendor's verbatim reset phrase (may be empty)
#
# 🔴 WHY A READ-ONLY TWIN EXISTS AT ALL. dry_store_read's lazy `rm -f` is
# correct for a caller that is *asking a question once* — the board, burn, the
# watcher — but the tmux status line (lib/core/tmux.sh's tmux_status_render)
# asks it every 5 seconds, from tmux's own server process, for every session on
# screen. A measurement that deletes state is not a measurement: it would make
# "when did this marker disappear" a function of whether anyone happened to be
# looking at a status bar, and it would do the deleting from a process that is
# not the user's clikae. So the status line peeks and leaves the collecting to
# whoever actually asked.
#
# The freshness RULE itself lives here only, and dry_store_read below is
# written in terms of it — two copies of "how old is too old" is exactly the
# drift this file's own TTL/MAX_RETAIN pair would suffer first.
#
# 🔴 "NEVER FORKS" WAS NOT TRUE (P2-3, 2026-09-14 round-1 fix review): every
# call used to compute its path via `f="$(dry_store_path "$engine" "$tank")"`
# — a command substitution, which is a subshell fork, once per marker. The
# tmux status row's alert count (tmux_status_alertsv) calls this once per file
# under `$CLIKAE_HOME/dry/*/*`, so a host with N dry markers forked N times a
# render, on a 5-second timer, inside tmux's own server — exactly the class of
# cost this function's whole header promises is not there. Measured with
# `strace -f -e trace=clone,execve` on the real helper (lib/core/status_line.sh):
# 0 markers → 7 clones; 3 markers → 10; 33 markers → 40 — one clone per marker,
# burn's half of the same render adds none. docs/DESIGN-tmux.md Rule 11 §3's
# "two forks total" line was wrong the same way; fixed in the same commit.
#
# The fix inlines `dry_store_path`'s own one-line body instead of calling it
# through a forking `$( )` — the same "two literals in the same paragraph,
# not one derived from the other" tradeoff burn_status.sh's burn_status_dirs
# already makes for the identical reason (see that function's header): a
# plain `$CLIKAE_HOME/dry/$engine/$tank` costs nothing to keep in sync with
# dry_store_path's `printf` three lines up, and both are on the same screen.
# dry_store_mark/_read/_clear/_epoch keep calling dry_store_path itself — none
# of them are on a 5-second timer, so the fork there was never the problem.
# _dry_stamp_okv <stamp> -> 0 if this stamp has the SHAPE a `date +%s` writes,
# 1 if it does not. The ONE place "readable" is defined, called by both readers
# below so they cannot drift apart.
#
# 🔴 THE RULE IS CLOCK-FREE, AND THAT IS THE WHOLE POINT (P2-1, 2026-09-14
# round-4 review). Round 3 added a third condition here -- "at most 60s ahead
# of `now`" -- and so made the DELETING verdict a function of the reader's own
# clock. The reader's clock can be BEHIND the writer's: an RTC that was fast at
# boot and chrony's `makestep` correcting it backwards, a VM snapshot restore,
# a suspend/resume, or `date` simply failing (this file's own callers fall back
# to `0`). Measured against origin/main, cell for cell the opposite: a reader
# 61s / 2h / 24h behind, and a reader with no `date` at all, turned a perfectly
# honest marker written seconds ago into `expired` -- and `expired` is the arm
# that `rm -f`s the file. Three irreversible things at once: burn is told the
# tank is NOT dry and walks straight back into a rate-limited tank, the vendor's
# own reset phrase is gone until a live catcher observes it again, and the row
# drops from `!4` to `!1` without saying why.
#
# So the fail-safe direction, stated so the next change has to argue with it:
#
#   THE ONLY DELETION THIS FILE PERFORMS IS DECIDED WITHOUT LOOKING AT A CLOCK.
#   A stamp that PARSES is evidence; a clock that disagrees with it is a clock.
#   A stamp that does NOT parse is not evidence of anything and is removed.
#   When we cannot tell the time at all, we KEEP the marker and say `unknown`.
#
# Two conditions, both necessary, neither involving `now`:
#
#   all digits         the shape dry_store_mark writes (`date +%s`). `-100` and
#                      `abc` fail here; so does `0`, the sentinel dry_store_mark
#                      writes when `date` failed at WRITE time -- that one never
#                      carried a date to fail safe on.
#   9 or 10 digits     a second-epoch has been 10 digits since 2001-09-09 and
#                      stays 10 until 2286-11-20; 9 admits a pre-2001 clock.
#                      11 is the year 5138 -- no clock this code will ever meet
#                      writes it, and it is exactly the shape a doubled or
#                      truncated write makes (one extra digit on a 2026 stamp).
#                      Round 3 caught that case with the clock test; with the
#                      clock gone, LENGTH is what still catches it, so the
#                      window that used to be 9-11 is now 9-10. That keeps
#                      round 3's finding fixed (`${now}7` is still expired and
#                      still removed) without letting the reader's clock decide.
#
# What this deliberately accepts: a stamp that is 10 digits and genuinely in
# the future -- a stepped clock, or a corrupt write that happens to land inside
# the window -- now reads FRESH and is kept, where round 3 deleted it. That is
# the trade, taken on purpose: a wrong `fresh` is recoverable (the next
# successful run calls dry_store_clear, and the marker is one file a human can
# delete), a wrong `expired` destroys the evidence and sends burn into a
# rate-limited tank. Keeping evidence we cannot fully trust beats destroying
# evidence we could not read the clock for.
_dry_stamp_okv() {
  local stamp="$1"
  case "$stamp" in ''|*[!0-9]*) return 1 ;; esac
  case "${#stamp}" in 9|10) ;; *) return 1 ;; esac
  return 0
}

# shellcheck disable=SC2034  # _DRY_PEEK / _DRY_PEEK_RESET are output slots, read
# by lib/core/tmux.sh's status-line composer, which shellcheck analyses as a
# separate file. Same shape as tmux.sh's CLIKAE_TMUX_SESS_EXISTS.
dry_store_peekv() {
  local engine="$1" tank="$2" now="${3:-}" f line stamp age
  _DRY_PEEK=none; _DRY_PEEK_RESET=""
  # dry_store_path's own body, inlined — see above. P3-3 (2026-09-14 round-2
  # review): with the SAME default tmux_status_alertsv enumerates markers
  # with; a bare `$CLIKAE_HOME` here meant an unset CLIKAE_HOME found every
  # marker in the enumeration and opened none of them (unbound under set -u).
  f="${CLIKAE_HOME:-$HOME/.clikae}/dry/$engine/$tank"
  [ -f "$f" ] || return 1
  # P3-2 (2026-09-14 round-2 review): `read` returns non-zero on a last line
  # with no trailing newline even though it filled `line`, and this used to
  # `return 1` on that — a marker written without `\n` was not counted at all.
  # Same fix tmux.sh's two status.json/usage readers got in round 1: keep what
  # was read, fail only when nothing was.
  line=""
  IFS= read -r line < "$f" 2>/dev/null || [ -n "$line" ] || return 1
  stamp="${line%%$'\t'*}"
  _DRY_PEEK_RESET="${line#*$'\t'}"
  [ "$_DRY_PEEK_RESET" = "$line" ] && _DRY_PEEK_RESET=""   # no TAB in the line → no phrase
  # 🔴 P2-4 (2026-09-14 round-2 review), completed by P2-2 (round-3): an
  # unreadable stamp used to become 0, and both ageing arms below required
  # `stamp > 0`, so it fell through to `fresh` — FOREVER. Measured: a
  # non-numeric stamp, an empty one, a line with no TAB at all each pinned `!1`
  # on every tmux session's status row (and a dry dot on the board) until
  # someone deleted the file by hand. A truncated write, an interrupted `mv`, a
  # future writer's format: any one of them was a permanent red. A stamp this
  # reader cannot date cannot be judged fresh, so it is `expired` — the same
  # "present but unreadable ⇒ untrusted" rule tmux_status_fuelv applies to
  # `cached_at`. What counts as readable is _dry_stamp_okv above, and it is a
  # SHAPE test — all digits, 9 or 10 of them — not just "is it a number":
  # round 2 shipped only "is it a number", round 3 added a clock test that had
  # to come back out (P2-1, round-4: see _dry_stamp_okv's header).
  # SHAPE FIRST, and it is the only thing that can lead to a removal below.
  # Whether this reader can tell the time never decides whether a file dies.
  _dry_stamp_okv "$stamp" || { _DRY_PEEK=expired; return 0; }
  case "$now" in ''|*[!0-9]*) now="$(date +%s 2>/dev/null)" ;; esac
  # No usable clock -- `date` failed, or a caller passed the `0` its own
  # fallback produces. The marker parsed, so it IS evidence; we simply cannot
  # age it. `unknown` is a verdict no caller deletes on: the row still counts
  # it, burn still treats the tank as dry, and nothing is lost while the host
  # has no clock.
  case "$now" in ''|*[!0-9]*|0) _DRY_PEEK=unknown; return 0 ;; esac
  age=$(( now - 10#$stamp ))   # 10#: a zero-padded stamp is not octal (`08` would be an error)
  # A stamp from the future is this reader's clock running behind the writer's,
  # not a marker that is wrong -- clamp to "recorded now", the same decision
  # tmux_status_fuelv already makes for a future `cached_at`. Never a removal.
  [ "$age" -lt 0 ] && age=0
  if [ "$age" -ge "$CLIKAE_DRY_MAX_RETAIN" ]; then
    _DRY_PEEK=expired
  elif [ "$age" -ge "$CLIKAE_DRY_TTL" ]; then
    _DRY_PEEK=stale
  else
    _DRY_PEEK=fresh
  fi
  return 0
}

# dry_store_read <engine> <tank> -> 0 (dry) + echo the verbatim reset phrase if a
# FRESH marker exists; 1 otherwise. A marker older than CLIKAE_DRY_TTL is stale →
# lazily removed and reported not-dry (turn green early rather than pin red).
# --retain-stale is internal to the shared verdict: expired parseable evidence
# must survive the TTL as unverified until a successful run clears it — but even
# retained, a marker older than CLIKAE_DRY_MAX_RETAIN is unconditionally gone
# (R1-P1-2): --retain-stale is not a promise to keep evidence forever.
dry_store_read() {
  local engine="$1" tank="$2"
  dry_store_peekv "$engine" "$tank" || return 1
  case "$_DRY_PEEK" in
    expired) rm -f "$(dry_store_path "$engine" "$tank")" 2>/dev/null || true; return 1 ;;
    # P2-1 (round-4): no clock, so no ageing -- but the marker parsed. Report
    # DRY with its phrase and touch nothing. The harm this avoids is specific:
    # answering "not dry" here sends burn back into a tank that really is rate
    # limited, and the old code additionally deleted the phrase on the way.
    unknown) ;;
    stale)
      if [ "${3:-}" != --retain-stale ]; then
        rm -f "$(dry_store_path "$engine" "$tank")" 2>/dev/null || true
        return 1
      fi
      ;;
  esac
  printf '%s' "$_DRY_PEEK_RESET"
  return 0
}

# dry_store_clear <engine> <tank> -> forget this tank's dry marker (a successful
# run recovered it). Silent if there was none.
dry_store_clear() {
  rm -f "$(dry_store_path "$1" "$2")" 2>/dev/null || true
}

# dry_store_epoch <engine> <tank> -> echo the epoch this marker was recorded, or
# return 1 if there's no usable marker. Feeds dry_seen_suffix for the board annotation.
dry_store_epoch() {
  local f line stamp; f="$(dry_store_path "$1" "$2")"
  [ -f "$f" ] || return 1
  line=""
  IFS= read -r line < "$f" 2>/dev/null || [ -n "$line" ] || return 1   # P3-2: a last line with no `\n` still counts
  stamp="${line%%$'\t'*}"
  # P2-2 (round-3 review): the SAME readability rule dry_store_peekv uses —
  # this reader used to accept `0` and any number of digits, including a
  # timestamp from the year 2537. Its callers fail safe on a refusal
  # (lib/core/limit.sh clears the marker, lib/commands/home.sh drops the
  # annotation), so refusing is the right direction here too.
  # P2-1 (round-4): and it no longer forks `date` — the rule is a shape test,
  # and this function's contract ("when was this recorded") never needed to
  # know what time it is now. One less way for a broken clock to matter.
  _dry_stamp_okv "$stamp" || return 1
  printf '%s' "$stamp"
}

# dry_seen_suffix <epoch> -> "  · seen HH:MM" (localised) for the LOCAL time a frozen
# observation was captured, or empty for a bad/empty epoch. Shared by every reset
# that is a SNAPSHOT rather than a live reading — codex (its dry_store marker) and
# agy (its limit log's mtime) — so they annotate consistently. The point: those
# engines report a time we can't trust as live (codex gives UTC for whichever limit
# window the headless run hit; agy gives a relative "Resets in 3h" frozen at its last
# run), so stating WHEN we observed it frames the number honestly. claude is exempt —
# its dry is re-read live each render and its phrase is already absolute + timezoned.
# We only ever stamp our OWN observation time; we never parse or convert the vendor's.
dry_seen_suffix() {
  local stamp="${1:-}" hm
  case "$stamp" in ''|*[!0-9]*) return 0 ;; esac
  # GNU form FIRST (same rule as stat -c/-f everywhere else): on Linux,
  # `date -r <digits>` means "that FILE's mtime" — if a file named e.g.
  # 1718000000 exists in $PWD it SUCCEEDS with garbage instead of failing to
  # the fallback. GNU's -d fails cleanly on BSD/macOS, whose -r then runs.
  hm="$(date -d "@$stamp" '+%H:%M' 2>/dev/null || date -r "$stamp" '+%H:%M' 2>/dev/null)" || return 0
  [ -n "$hm" ] && printf '  · %s' "$(printf "$T_DRY_SEEN" "$hm")"
}
