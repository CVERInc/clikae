#!/usr/bin/env bats
# tests/bats/tmux-status.bats — the tmux status row (#77).
#
# The row it replaced was never tested because nothing was setting most of it:
# tmux derived the window list, the title and the date, and clikae contributed
# eight characters of label. This file pins the parts that are now decisions.
#
# Almost everything here renders the row WITHOUT a tmux server, because
# tmux_status_render is a pure function of its arguments plus $HOME/$CLIKAE_HOME
# — that is the whole reason it is a separate function from tmux_status_line.
# The two tests that do need a real tmux use their own socket from `mktemp -d`
# and never `kill-server` on a shared one.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/dry_store.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/burn_status.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/duration.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
}

# _usage_cache <engine> <tank> <window_pct> <weekly_pct> [age_seconds]
# #72's cache file, written by hand in the shape PR #89 writes it.
_usage_cache() {
  local engine="$1" tank="$2" w="$3" k="$4" age="${5:-0}" now
  now=$(( $(date +%s) - age ))
  mkdir -p "$CLIKAE_HOME/state/usage/$engine"
  printf '{"window_pct":%s,"weekly_pct":%s,"window_resets_at":null,"weekly_resets_at":null,"source":"vendor","cached_at":%s,"scanned_at":%s}\n' \
    "$w" "$k" "$now" "$now" > "$CLIKAE_HOME/state/usage/$engine/$tank.json"
}

# _dry_marker <engine> <tank> [age_seconds] — what the live catchers write.
_dry_marker() {
  local engine="$1" tank="$2" age="${3:-0}"
  mkdir -p "$CLIKAE_HOME/dry/$engine"
  printf '%s\tresets 3pm\n' "$(( $(date +%s) - age ))" > "$CLIKAE_HOME/dry/$engine/$tank"
}

# _burn_status <run> <state> <pid> [age_seconds] [reason] — #41's status.json
# for one run directory. `updated_at` is `now - age_seconds` (default 0 —
# freshly written), matching `_usage_cache`/`_dry_marker`'s own `[age]`
# convention in this file (P2-1, 2026-09-14 round-1 fix review: this used to
# hardcode `updated_at:2` — epoch second 2, i.e. 1970 — which every existing
# caller here got away with only because nothing read `updated_at` before
# that review; a self-clearing alert count needs a real one to age against).
# `reason` (default "") is the field that sits right before `state`/`pid` in
# the real object (`_burn_status_write`'s own field order); the writer caps it
# at 200 bytes (see burn-status.bats).
_burn_status() {
  local run="$1" state="$2" pid="$3" age="${4:-0}" reason="${5:-}" upd
  upd=$(( $(date +%s) - age ))
  mkdir -p "$HOME/.clikae/logs/$run"
  printf '{"ok":null,"engine":"claude","tank":"wrasse","artifact":"/x","artifact_bytes":null,"reason":"%s","reset":null,"rerouted_from":[],"elapsed_s":3,"run_id":"%s","state":"%s","started_at":1,"updated_at":%s,"pid":%s,"log":"/x","reset_at":null}\n' \
    "$reason" "$run" "$state" "$upd" "$pid" > "$HOME/.clikae/logs/$run/status.json"
}

# _manifest — every path under clikae's own state, with size and mtime.
#
# 🔴 SCOPED TO CLIKAE'S STATE, and the scope was measured rather than chosen.
# The first version walked the whole throwaway $HOME and went red on a real
# side effect worth knowing about: asking tmux anything (live_session_id's
# `show-options`) makes tmux CREATE its own socket directory under
# $TMUX_TMPDIR. That is tmux's housekeeping, in a directory that already exists
# in the only place this helper ever really runs (as a child of a live tmux
# server), and it is not clikae state. The claim this test defends is the one
# that matters: the row never changes anything clikae wrote.
# GNU/BSD stat both, the same two-arm form the rest of this repo uses; no
# `find -printf`, which is GNU-only and would make this whole test a no-op on
# macOS while still printing green.
_manifest() {
  local f
  find "$CLIKAE_HOME" "$HOME/.clikae" -print 2>/dev/null | sort -u | while IFS= read -r f; do
    printf '%s %s\n' "$f" \
      "$(stat -c '%Y %s' "$f" 2>/dev/null || stat -f '%m %z' "$f" 2>/dev/null)"
  done
}

# A pid that is structurally incapable of existing: above every platform's
# pid_max. Reusing a real-but-exited pid would be a test that passes until the
# machine wraps its pid space onto it.
_dead_pid() { printf '2147483647'; }

# ── the fuel segment ────────────────────────────────────────────────────────

@test "fuel: the usage cache is what the row shows, as 5h/7d percentages" {
  _src
  _usage_cache claude wrasse 42.0 65.0
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"5h 42%"* ]] || { echo "$output"; false; }
  [[ "$output" == *"7d 65%"* ]] || { echo "$output"; false; }
  # `wk` was the first wording and chodaict corrected it: both windows are
  # written as time spans, so the weekly one is `7d`.
  [[ "$output" != *"wk "* ]] || { echo "$output"; false; }
}

@test "fuel: no usage cache falls back to the dot, and never invents a number" {
  # #72 has not landed yet for most tanks, and a row that made up a percentage
  # would be worse than one that admits it has no reading.
  _src
  run tmux_status_render codex goby '' '' 120
  [[ "$output" == *"·"* ]] || { echo "$output"; false; }
  [[ "$output" != *"5h "* ]] || { echo "$output"; false; }
  [[ "$output" != *"%"* ]] || { echo "$output"; false; }
}

@test "fuel: a fresh dry marker shows the board's dry glyph, not the no-reading one" {
  _src
  _dry_marker codex goby
  run tmux_status_render codex goby '' '' 120
  [[ "$output" == *"○"* ]] || { echo "$output"; false; }
}

@test "fuel: a dry marker older than its own TTL is not shown as dry" {
  # dry_store's TTL is the one place this rule lives; the row must not carry a
  # second copy of it. 7h against a 6h TTL.
  _src
  _dry_marker codex goby 25200
  run tmux_status_render codex goby '' '' 120
  [[ "$output" != *"○"* ]] || { echo "$output"; false; }
  [[ "$output" == *"·"* ]] || { echo "$output"; false; }
}

@test "fuel: a reading older than 24h is treated as unread, not shown as current" {
  # The failure this prevents: a percentage from last Tuesday, drawn every five
  # seconds as if it were now.
  _src
  _usage_cache claude wrasse 42.0 65.0 90000
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"42%"* ]] || { echo "$output"; false; }
  [[ "$output" == *"·"* ]] || { echo "$output"; false; }
}

# P2-5 (2026-09-14 round-1 fix review): before this fix, "just now", 1h old and
# 23h old all rendered pixel-for-pixel identical — only the 24h ceiling itself
# visibly differed. Under 1h stays bare (recent enough that annotating it is
# noise); past 1h gets the board's own age formatter.
@test "fuel: a reading under 1h old carries no age suffix" {
  _src
  _usage_cache claude wrasse 42.0 65.0 1800   # 30m
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"5h 42% · 7d 65%"* ]] || { echo "$output"; false; }
  [[ "$output" != *"ago"* ]] || { echo "$output"; false; }
}

@test "fuel: a reading between 1h and 24h old carries a '· Nh ago' suffix" {
  _src
  _usage_cache claude wrasse 42.0 65.0 10800   # 3h
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"5h 42% · 7d 65% · 3h ago"* ]] || { echo "$output"; false; }
}

# P2-2 (2026-09-14 round-2 review): the row calls the fork-free `_human_agev`,
# and the board/resume still call the printing `_human_age`. One formatter, so
# the two forms must agree at every step of the ladder.
@test "fuel: _human_agev assigns exactly what _human_age prints" {
  _src
  local now=1700000000 d got want
  for d in 0 1 59 60 61 3599 3600 3601 86399 86400 86401 172800 604800; do
    want="$(_human_age "$(( now - d ))" "$now")"
    got=""; _human_agev got "$(( now - d ))" "$now"
    [ "$got" = "$want" ] || { echo "age $d: agev [$got] vs age [$want]"; false; }
  done
  # The ordinary names a caller reaches for (the old unprefixed locals among
  # them) land in the caller's variable, not in a function local.
  # `d`/`mt`/`now` are declared by the `local "$v"=""` inside the loop, which
  # is the declaration this test is about; naming `mt` again out here left it
  # assigned-but-never-read (SC2034 under the CI bats shellcheck gate), and
  # `d`/`now` were never named here in the first place.
  local v age suffix
  for v in d mt now age suffix; do
    local "$v"=""
    _human_agev "$v" 1699992800 1700000000
    [ "${!v}" = "2h ago" ] || { echo "var $v got [${!v}]"; false; }
  done
}

@test "fuel: an aged reading costs the row no extra fork" {
  # The call site must be the variable-setting form: `$(_human_age …)` is a
  # subshell per render. Asserted on the source because a fork count needs
  # strace, which CI does not have; the strace numbers are in Rule 11 §3.
  # Code lines only: the comment explaining this fix quotes the forking form.
  run grep -nE '^[^#]*\$\(_human_age' "$CLIKAE_TEST_ROOT/lib/core/tmux.sh" "$CLIKAE_TEST_ROOT/lib/core/status_line.sh"
  [ "$status" -ne 0 ] || { echo "a forking call is back on the status path: $output"; false; }
  grep -q '_human_agev suffix' "$CLIKAE_TEST_ROOT/lib/core/tmux.sh" || { echo "the row no longer calls _human_agev"; false; }
}

# P3-4 (2026-09-14 round-2 review): a cached_at in the future renders as
# "now" — the reading, no age suffix, nothing negative, nothing huge.
@test "fuel: a cached_at in the future renders as a reading taken now" {
  _src
  local ahead
  for ahead in 30 7200 90000; do
    _usage_cache claude wrasse 42.0 65.0 "-$ahead"
    run tmux_status_render claude wrasse '' '' 120
    [[ "$output" == *"5h 42% · 7d 65%"* ]] || { echo "+${ahead}s: $output"; false; }
    [[ "$output" != *"ago"* ]] || { echo "+${ahead}s: $output"; false; }
    [[ "$output" != *"-"[0-9]* ]] || { echo "+${ahead}s negative: $output"; false; }
  done
  local v now=1700000000
  for ahead in 1 59 7200 90000 31536000; do
    _human_agev v "$(( now + ahead ))" "$now"
    [ "$v" = "just now" ] || { echo "_human_agev +${ahead}s: [$v]"; false; }
  done
}

# P3-3 (same review): a corrupt cache must not blow the row's width budget.
@test "fuel: percentages clamp to 100, a corrupt cache cannot blow the width budget" {
  _src
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  printf '{"window_pct":999999,"weekly_pct":888888,"cached_at":%s}\n' "$(date +%s)" \
    > "$CLIKAE_HOME/state/usage/claude/wrasse.json"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"5h 100% · 7d 100%"* ]] || { echo "$output"; false; }
}

# P3-2 / P2-5 (same review): `cached_at` PRESENT but not a shape this reader
# understands (an ISO string, here — a future writer's guess, since #89's own
# writer emits epoch numbers) must fail SAFE — treated as untrusted, not as
# "must be current forever". Before this fix "we cannot judge what we cannot
# read" was applied to this case too, which is backwards: the field IS there.
@test "fuel: cached_at present but unparseable (ISO string) is untrusted, not shown as current" {
  _src
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  printf '{"window_pct":42,"weekly_pct":65,"cached_at":"2026-09-14T10:00:00Z"}\n' \
    > "$CLIKAE_HOME/state/usage/claude/wrasse.json"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"42%"* ]] || { echo "$output"; false; }
  [[ "$output" == *"·"* ]] || { echo "$output"; false; }
}

# The documented decision this reader keeps: cached_at TRULY ABSENT (an older
# cache shape) is still not aged out — "we cannot judge what we cannot read"
# is correct for a field that plain isn't there.
@test "fuel: cached_at truly absent (older cache shape) is still not aged out" {
  _src
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  printf '{"window_pct":42,"weekly_pct":65,"source":"vendor"}\n' \
    > "$CLIKAE_HOME/state/usage/claude/wrasse.json"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"5h 42% · 7d 65%"* ]] || { echo "$output"; false; }
  [[ "$output" != *"ago"* ]] || { echo "$output"; false; }
}

# P3-1 (same review): `read` without `-d ''` silently drops a final line with
# no trailing newline — a cache written without one used to read as completely
# empty. `printf '%s'` below deliberately omits the trailing `\n`.
@test "fuel: a cache file with no trailing newline still reads" {
  _src
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  printf '{"window_pct":42,"weekly_pct":65,"cached_at":%s}' "$(date +%s)" \
    > "$CLIKAE_HOME/state/usage/claude/wrasse.json"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"5h 42% · 7d 65%"* ]] || { echo "$output"; false; }
}

@test "fuel: a cache with null percentages is no reading, not 0%" {
  _src
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  printf '{"window_pct":null,"weekly_pct":null,"source":"unknown"}\n' \
    > "$CLIKAE_HOME/state/usage/claude/wrasse.json"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"0%"* ]] || { echo "$output"; false; }
  [[ "$output" == *"·"* ]] || { echo "$output"; false; }
}

# _usage_expired_cache <engine> <tank> [age_seconds] — what usage_read writes
# when the vendor refused the token and the credentials can still renew it
# (#107's `usage_unknown expired-token`, plus the cache stamps usage_read adds).
_usage_expired_cache() {
  local engine="$1" tank="$2" age="${3:-0}" now
  now=$(( $(date +%s) - age ))
  mkdir -p "$CLIKAE_HOME/state/usage/$engine"
  printf '{"window_pct":null,"weekly_pct":null,"window_resets_at":null,"weekly_resets_at":null,"source":"expired","reason":"expired-token","cached_at":%s,"scanned_at":%s}\n' \
    "$now" "$now" > "$CLIKAE_HOME/state/usage/$engine/$tank.json"
}

@test "fuel: an expired token is its own state, not the no-reading dot" {
  # #107 in one line: an idle tank at 99% weekly read exactly like a tank with
  # no login at all. The cache knows which of the two this is, and the remedy
  # (run a session, or `clikae usage --wake <tank>`) is something a person can
  # act on — so the row says so with the word. No emoji on this delivery
  # surface (2026-09-22 correction — the mark used to be `⏳`, U+23F3, which
  # breached the standing no-emoji rule; scripts/signet-lint.sh's scan was too
  # narrow to catch it).
  _src
  _usage_expired_cache claude wrasse
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"expired"* ]] || { echo "$output"; false; }
  [[ "$output" != *"⏳"* ]] || { echo "the old glyph is back: $output"; false; }
  [[ "$output" != *"·"* ]] || { echo "no-reading dot alongside the word: $output"; false; }
  [[ "$output" != *"%"* ]] || { echo "$output"; false; }
}

@test "fuel: no cache is still the dot — the word is not the new default" {
  # The control for the test above. Without it, a row that drew "expired"
  # whenever it had no percentages would pass, and the two states would be
  # collapsed again in the other direction.
  _src
  run tmux_status_render codex goby '' '' 120
  [[ "$output" == *"·"* ]] || { echo "$output"; false; }
  [[ "$output" != *"expired"* ]] || { echo "$output"; false; }
}

@test "fuel: an expired reading older than 24h ages out like any other" {
  # The same ceiling a percentage gets. A remedy nobody has rechecked in nine
  # days is not news about now; "no reading" is the honest answer by then.
  _src
  _usage_expired_cache claude wrasse 90000
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"expired"* ]] || { echo "$output"; false; }
  [[ "$output" == *"·"* ]] || { echo "$output"; false; }
}

@test "fuel: the expired word is measured like any ASCII fuel string, no special case" {
  # 2026-09-22 correction: the old `⏳` glyph needed a 2-cell special case
  # (`${s//⏳/xx}`) because it is East Asian WIDE, unlike the row's other
  # glyphs. The word "expired" that replaced it is plain ASCII — 7 columns,
  # counted the same way `AB` always was, no substitution required.
  _src
  _tmux_status_colsv "expired"
  [ "$_TSTAT_COLS" = "7" ] || { echo "expired counted as $_TSTAT_COLS cell(s)"; false; }
  _tmux_status_colsv "·"
  [ "$_TSTAT_COLS" = "1" ] || { echo "· counted as $_TSTAT_COLS cell(s)"; false; }
}

@test "width ladder: the expired word is dropped whole, the way the fuel segment always is, before the alert count or clock" {
  # tmux_status_rowv treats whatever is IN the fuel slot as one segment (rung
  # 5, the floor guard) — a 7-column word costs the ladder nothing new. At a
  # width too narrow for it, it is dropped whole, exactly like a percentage
  # reading would be, and the alert count and clock survive untouched.
  _src
  tmux_status_rowv 30 '' antigravity "$(_tank 42)" '' 'expired' '' 10
  [ "$_TSTAT_ROW" = "clikae ttttt…tttt${_SEP}#[fg=red]!10#[default] " ] \
    || { echo "$_TSTAT_ROW"; false; }
  [[ "$_TSTAT_ROW" != *"expired"* ]] || { echo "expired survived rung 5: $_TSTAT_ROW"; false; }

  # Wide enough, it is shown plainly alongside the rest of the row.
  tmux_status_rowv 120 '' claude "$(_tank 8)" '' 'expired' '' 10
  [[ "$_TSTAT_ROW" == *"clikae claude $(_tank 8)${_SEP}expired${_SEP}"* ]] \
    || { echo "$_TSTAT_ROW"; false; }
}

# ── the alert segment ───────────────────────────────────────────────────────

@test "alerts: zero reds means the segment is not drawn at all" {
  # The opposite of the opening proposal's `🔴0`: chodaict's correction is that
  # silence does not need spelling out, and the emoji fails signet-lint anyway.
  _src
  run tmux_status_render claude wrasse '' '' 120
  [ "$status" -eq 0 ]
  [[ "$output" != *"!"* ]] || { echo "$output"; false; }
  [[ "$output" != *"!0"* ]] || { echo "$output"; false; }
}

@test "alerts: a tank the catchers marked dry counts as one" {
  _src
  _dry_marker codex goby
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "$output"; false; }
}

@test "alerts: a burn lane whose writer is gone counts; one still running does not" {
  _src
  _burn_status burn-1 running "$(_dead_pid)"
  _burn_status burn-2 running "$$"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "$output"; false; }
}

@test "alerts: a lane that reached a terminal state is not red" {
  # `fail` printed its reason to whoever ran it. The row is for what nobody has
  # been told — a lane that died mid-flight, not one that reported.
  _src
  _burn_status burn-1 fail "$(_dead_pid)"
  # `done` quoted: bare, shellcheck reads it as the loop keyword (SC1010).
  _burn_status burn-2 "done" "$(_dead_pid)"
  _burn_status burn-3 dry  "$(_dead_pid)"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"!"* ]] || { echo "$output"; false; }
}

@test "alerts: a waiting-reset lane whose writer is gone counts too" {
  _src
  _burn_status burn-1 waiting-reset "$(_dead_pid)"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "$output"; false; }
}

# P2-1 (2026-09-14 round-1 fix review): before this fix, nothing but the next
# `clikae burn` (7-day sweep) ever cleared this — a SIGKILLed lane pinned
# every session's row red, potentially forever. P2-3 (round-2 review) moved
# the bound from CLIKAE_DRY_TTL (6h) to the log retention (7d): `updated_at`
# is the attempt's START, so 6h hid every long lane that died. Still without
# deleting the file — only the count changes.
@test "alerts: a dead pid's !N self-clears past the log retention, even a 30-day-old dir" {
  _src
  _burn_status burn-1 running "$(_dead_pid)" 2592000   # 30 days
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"!"* ]] || { echo "$output"; false; }
  [ -f "$HOME/.clikae/logs/burn-1/status.json" ] || { echo "the status file was deleted — this fix must not touch it, only the count"; false; }
}

@test "alerts: a dead pid under the TTL still counts (the self-clear has a floor)" {
  _src
  _burn_status burn-1 running "$(_dead_pid)" 60   # 1 minute — nowhere near 6h
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "$output"; false; }
}

# P2-3 (2026-09-14 round-2 review): `updated_at` for `running`/`waiting-reset`
# is when the attempt STARTED — burn does not rewrite it while the engine runs.
# Round 1 aged a dead pid out at 6h on that stamp, so a lane that ran 7h and
# then died, or a waiting-reset lane killed a day into its sleep, was never
# reported. Liveness decides; age only bounds it at the 7-day log retention.
@test "alerts: a lane that ran 7h and then died is red; the same lane alive is not" {
  _src
  _burn_status burn-1 running "$(_dead_pid)" 25200   # attempt started 7h ago
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "dead after 7h not reported: $output"; false; }

  _burn_status burn-1 running "$$" 25200             # same age, writer alive
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"!"* ]] || { echo "a live lane was counted: $output"; false; }
}

@test "alerts: a waiting-reset lane killed a day into its sleep is red" {
  _src
  _burn_status burn-1 waiting-reset "$(_dead_pid)" 86400
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "$output"; false; }
}

@test "alerts: a dead lane stays red until the log retention, and not past it" {
  _src
  _burn_status burn-1 running "$(_dead_pid)" $(( 7 * 86400 - 60 ))
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "just under 7d: $output"; false; }
  _burn_status burn-1 running "$(_dead_pid)" $(( 7 * 86400 + 60 ))
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"!"* ]] || { echo "just over 7d: $output"; false; }
  # The bound IS the sweep's own knob, not a second copy of the number.
  # Exported, not a bare assignment: `tmux_status_render` runs in this shell so
  # either reaches it, but only the export tells shellcheck the value is read
  # somewhere (SC2034 under the CI bats shellcheck gate).
  export CLIKAE_BURN_LOG_RETENTION_DAYS=30
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "retention 30d: $output"; false; }
}

# P3-1 (2026-09-14 round-1 fix review): the alerts loop reads status.json with
# the same `read`-without-`-d ''` shape the fuel loop had; a file with no
# trailing newline used to silently read as empty here too — which would have
# UNDERCOUNTED a real dead lane, the unsafe direction for a row that must
# never cry wolf but also must not go quiet on a real one.
@test "alerts: a status.json with no trailing newline still counts" {
  _src
  _burn_status burn-1 running "$(_dead_pid)"
  # _burn_status's printf ends in \n; strip it to reproduce the P3-1 shape.
  printf '%s' "$(cat "$HOME/.clikae/logs/burn-1/status.json")" \
    > "$HOME/.clikae/logs/burn-1/status.json.tmp"
  mv "$HOME/.clikae/logs/burn-1/status.json.tmp" "$HOME/.clikae/logs/burn-1/status.json"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "$output"; false; }
}

# P2-4 (2026-09-14 round-2 review): an unreadable dry stamp used to become 0,
# which neither ageing arm accepts, so it read `fresh` forever — a permanent
# `!1` on every session from one truncated write.
@test "alerts: a dry marker whose stamp cannot be read is not red, and never was fresh" {
  _src
  mkdir -p "$CLIKAE_HOME/dry/codex"
  local body
  for body in 'garbage\tresets 3pm' '\tresets 3pm' 'no tab at all' '0\tresets 3pm'; do
    printf "$body\n" > "$CLIKAE_HOME/dry/codex/goby"
    dry_store_peekv codex goby "$(date +%s)" || { echo "[$body] peek rc!=0"; false; }
    [ "$_DRY_PEEK" = expired ] || { echo "[$body] peek=$_DRY_PEEK"; false; }
    run tmux_status_render claude wrasse '' '' 120
    [[ "$output" != *"!"* ]] || { echo "[$body] $output"; false; }
    run tmux_status_render codex goby '' '' 120
    [[ "$output" != *"○"* ]] || { echo "[$body] shown dry: $output"; false; }
  done
  # The control: the same file with a real stamp is still red.
  printf '%s\tresets 3pm\n' "$(date +%s)" > "$CLIKAE_HOME/dry/codex/goby"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "control: $output"; false; }
  # A zero-padded stamp is decimal, not an arithmetic error.
  printf '0%s\tresets 3pm\n' "$(date +%s)" > "$CLIKAE_HOME/dry/codex/goby"
  run dry_store_peekv codex goby "$(date +%s)"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "padded: rc=$status $output"; false; }
}

# P3-1 (2026-09-14 round-3 review): `kill -0` returns 1 for BOTH "no such
# process" and "that process is not yours", so a `running` lane whose pid had
# been recycled onto another USER's process counted as dead — while the header
# claimed the only error this function can make is to under-report. Measured as
# an ordinary user: `kill -0 1` (init) rc=1, indistinguishable from a pid that
# does not exist.
@test "alerts: a pid that is alive but owned by someone else is never counted dead" {
  _src
  # pid 1 is init: it exists on every unix and belongs to root. As an ordinary
  # user `kill -0 1` is EPERM; as root it succeeds. Either way it is ALIVE, so
  # this assertion holds for whoever runs the suite.
  _burn_status burn-1 running 1
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"!"* ]] || { echo "a live foreign pid was called dead: $output"; false; }

  # The control, same file, same state: a pid that really is gone is still red.
  _burn_status burn-1 running "$(_dead_pid)"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "control: $output"; false; }
}

# 🔴 P3-3 (2026-09-14 round-4 review): the round-3 fix made the header claim
# "undercount is now the ONLY direction it misses in". It is not, when `ps`
# cannot answer — `/proc` mounted `hidepid=2` (Proxmox's default, and plenty of
# hardened multi-user hosts) makes an ordinary user's `ps -p <a stranger's pid>`
# exit 1, exactly like a pid that does not exist, and the lane is then counted
# as dead. This pins the behaviour the header now describes, so the sentence and
# the code cannot drift apart again: with `ps` unable to answer, a live FOREIGN
# pid overcounts — one lane reported unattended that is somebody else's running
# process — and nothing is ever LOST that way.
@test "alerts: when ps cannot answer, a live foreign pid overcounts (hidepid, stated)" {
  _src
  _burn_status burn-1 running 1          # init: alive, and not ours
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"!"* ]] || { echo "control (ps works): $output"; false; }

  # `ps` answering the way it does under hidepid=2 for another user's pid.
  ps() { return 1; }
  run tmux_status_render claude wrasse '' '' 120
  unset -f ps
  [[ "$output" == *"!1"* ]] \
    || { echo "with ps unable to answer the header's overcount did not happen: $output"; false; }

  # …and the direction that is NOT affected: a real dead lane is still red.
  _burn_status burn-1 running "$(_dead_pid)"
  ps() { return 1; }
  run tmux_status_render claude wrasse '' '' 120
  unset -f ps
  [[ "$output" == *"!1"* ]] || { echo "a dead lane stopped counting: $output"; false; }
}

# P3-2 (2026-09-14 round-3 review): a `running` status.json whose pid is
# present but unreadable was silently skipped — `{"state":"running","pid":"x"}`
# counted `!0`. That made this the third reader of "present but unreadable" in
# one render and the only one treating it as "nothing to see".
@test "alerts: a running lane with no readable pid is counted, not shrugged off" {
  _src
  mkdir -p "$HOME/.clikae/logs/burn-torn"
  local now; now="$(date +%s)"
  # The exact shape the review measured, plus the other two ways a torn write
  # loses the pid: an absent field and a truncated object.
  printf '{"state":"running","pid":"x","updated_at":%s}\n' "$now" \
    > "$HOME/.clikae/logs/burn-torn/status.json"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "unreadable pid: $output"; false; }

  printf '{"state":"running","updated_at":%s}\n' "$now" \
    > "$HOME/.clikae/logs/burn-torn/status.json"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "absent pid: $output"; false; }

  # …and it is still BOUNDED by the same retention window as every other red
  # here: a torn file older than the sweep's own horizon stops counting.
  printf '{"state":"running","pid":"x","updated_at":%s}\n' "$(( now - 8 * 86400 ))" \
    > "$HOME/.clikae/logs/burn-torn/status.json"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"!"* ]] || { echo "an 8-day-old torn file still counts: $output"; false; }

  # A lane that reached a terminal state is still not news, torn pid or not:
  # `state` is read and switched on before `pid` is ever touched.
  printf '{"state":"fail","pid":"x","updated_at":%s}\n' "$now" \
    > "$HOME/.clikae/logs/burn-torn/status.json"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"!"* ]] || { echo "a failed lane counted: $output"; false; }
}

# P2-2 (2026-09-14 round-3 review): round 2 implemented "unreadable => expired"
# as "NON-NUMERIC => expired", and a truncated or doubled write is usually
# still digits. An 11-digit stamp dates to the year 2537; `age` is hugely
# negative; neither ageing arm fires; the marker is `fresh` FOREVER, on the row,
# on the board, and in burn's real dry verdict.
#
# P2-1 (2026-09-14 round-4 review) rewrote HOW that is caught: round 3 caught it
# with a clock test ("no more than 60s ahead of now"), which made the DELETING
# verdict depend on the reader's clock. The rule is now a pure SHAPE test — all
# digits, 9 or 10 of them (lib/core/dry_store.sh's _dry_stamp_okv) — so the
# extra-digit case is still expired and still removed, by its LENGTH, while a
# clock that disagrees can no longer remove anything. This is that table: every
# stamp below is rejected without consulting `now` at all, which is why the same
# rows hold for a reader whose clock is hours off (the test after next).
@test "alerts: a dry stamp that is digits but not a date is expired, not fresh forever" {
  _src
  mkdir -p "$CLIKAE_HOME/dry/codex"
  local now stamp
  now="$(date +%s)"
  # stamp | what it is
  for stamp in \
    "${now}7"           `# one extra digit — a doubled/truncated write, year 2537` \
    "${now}${now}"      `# the stamp written twice (20 digits)` \
    "12345678"          `# eight digits — not a length date +%s ever produced` \
    "0"                 `# what dry_store_mark writes when date itself failed` \
    ; do
    printf '%s\tresets 3pm\n' "$stamp" > "$CLIKAE_HOME/dry/codex/goby"
    dry_store_peekv codex goby "$now" || { echo "[$stamp] peek rc!=0"; false; }
    [ "$_DRY_PEEK" = expired ] || { echo "[$stamp] peek=$_DRY_PEEK"; false; }
    # …and the SAME verdict from a reader whose clock is two hours behind and
    # from one whose clock is two hours ahead: the shape test never asks.
    dry_store_peekv codex goby "$(( now - 7200 ))"
    [ "$_DRY_PEEK" = expired ] || { echo "[$stamp] behind: peek=$_DRY_PEEK"; false; }
    dry_store_peekv codex goby "$(( now + 7200 ))"
    [ "$_DRY_PEEK" = expired ] || { echo "[$stamp] ahead: peek=$_DRY_PEEK"; false; }
    run tmux_status_render claude wrasse '' '' 120
    [[ "$output" != *"!"* ]] || { echo "[$stamp] counted red: $output"; false; }
  done

  # A NEGATIVE stamp is not a number this reader takes either (the `-` fails the
  # digit test).
  printf -- '-100\tresets 3pm\n' > "$CLIKAE_HOME/dry/codex/goby"
  dry_store_peekv codex goby "$now" || { echo "negative: peek rc!=0"; false; }
  [ "$_DRY_PEEK" = expired ] || { echo "negative: peek=$_DRY_PEEK"; false; }

  # …and the direction round 4 flipped, stated as a test so it cannot flip back
  # by accident: a stamp with a LEGAL shape that sits in the future is a clock
  # that moved, not a marker that is wrong. Readable, fresh, counted, KEPT.
  local ahead
  for ahead in 30 61 7200 315360000; do
    printf '%s\tresets 3pm\n' "$(( now + ahead ))" > "$CLIKAE_HOME/dry/codex/goby"
    dry_store_peekv codex goby "$now" || { echo "+${ahead}s: peek rc!=0"; false; }
    [ "$_DRY_PEEK" = fresh ] || { echo "+${ahead}s: peek=$_DRY_PEEK"; false; }
    [ -f "$CLIKAE_HOME/dry/codex/goby" ] || { echo "+${ahead}s: marker gone"; false; }
    run tmux_status_render claude wrasse '' '' 120
    [[ "$output" == *"!1"* ]] || { echo "+${ahead}s: $output"; false; }
  done
}

# 🔴 P2-1 (2026-09-14 round-4 review). The regression this pins is not
# hypothetical and not cosmetic: round 3's "at most 60s in the future" made the
# READER's clock decide whether a file is deleted. A reader can be behind a
# writer they share a host with — an RTC fast at boot and chrony's `makestep`
# correcting backwards, a VM snapshot restore, suspend/resume — and the marker
# it then judges "from the future" is a perfectly honest one written seconds
# ago. Measured against origin/main at the time, cell for cell the opposite:
# 61s / 2h / 24h behind each turned DRY+phrase+file-kept into not-dry+file-GONE.
# Deleted is the part that does not come back: burn walks straight back into a
# rate-limited tank, and the vendor's own reset phrase is gone until a live
# catcher observes one again.
@test "dry: a reader whose clock is BEHIND the writer keeps the marker and stays dry" {
  _src
  mkdir -p "$CLIKAE_HOME/dry/codex"
  local marker now skew; marker="$CLIKAE_HOME/dry/codex/goby"; now="$(date +%s)"
  for skew in 61 7200 86400; do
    printf '%s\tresets 3pm\n' "$now" > "$marker"
    dry_store_peekv codex goby "$(( now - skew ))" || { echo "[-${skew}s] peek rc!=0"; false; }
    [ "$_DRY_PEEK" = fresh ] || { echo "[-${skew}s] peek=$_DRY_PEEK"; false; }

    # …and through the reader that actually decides, which reads its own clock:
    # a `date` shim reporting the local time minus the skew.
    date() { case "$1" in +%s) printf '%s\n' "$(( now - skew ))" ;; *) command date "$@" ;; esac; }
    run dry_store_read codex goby
    run_status="$status"; run_output="$output"
    run dry_store_epoch codex goby
    epoch_status="$status"; epoch_output="$output"
    unset -f date

    [ "$run_status" -eq 0 ] || { echo "[-${skew}s] burn was told NOT dry (rc=$run_status)"; false; }
    [ "$run_output" = "resets 3pm" ] || { echo "[-${skew}s] phrase lost: [$run_output]"; false; }
    [ -f "$marker" ] || { echo "[-${skew}s] THE MARKER WAS DELETED"; false; }
    [ "$epoch_status" -eq 0 ] && [ "$epoch_output" = "$now" ] \
      || { echo "[-${skew}s] epoch: rc=$epoch_status [$epoch_output]"; false; }
  done
}

# The other half of the same finding: `date` not answering AT ALL. Both readers
# fall back to `0` for "now", which is not a time — so there is nothing to age
# against. The answer is `unknown`: keep the file, keep counting it, tell burn
# the tank is dry. A host that cannot say what time it is must not lose its
# evidence over it.
@test "dry: a failing date deletes nothing and drops nothing from the row" {
  _src
  mkdir -p "$CLIKAE_HOME/dry/codex" "$CLIKAE_HOME/dry/claude"
  local m1 m2 now; m1="$CLIKAE_HOME/dry/codex/goby"; m2="$CLIKAE_HOME/dry/claude/wrasse"
  now="$(date +%s)"
  printf '%s\tresets 3pm\n' "$now" > "$m1"
  printf '%s\tresets 4pm\n' "$now" > "$m2"

  date() { return 1; }
  dry_store_peekv codex goby '' || { echo "peek rc!=0"; false; }
  peek="$_DRY_PEEK"
  run dry_store_read codex goby
  read_status="$status"; read_output="$output"
  run tmux_status_alertsv
  alerts_status="$status"
  tmux_status_alertsv
  alerts="$_TSTAT_ALERTS"
  unset -f date

  [ "$peek" = unknown ] || { echo "peek=$peek (want unknown)"; false; }
  [ "$read_status" -eq 0 ] || { echo "burn was told NOT dry with a broken clock"; false; }
  [ "$read_output" = "resets 4pm" ] || [ "$read_output" = "resets 3pm" ] \
    || { echo "phrase lost: [$read_output]"; false; }
  [ -f "$m1" ] && [ -f "$m2" ] || { echo "a marker was deleted by a broken clock"; false; }
  [ "$alerts_status" -eq 0 ] || { echo "alertsv rc=$alerts_status"; false; }
  [ "$alerts" = 2 ] || { echo "the row dropped markers when date failed: !$alerts (want !2)"; false; }
}

# The same rule, through the readers that are NOT decoration: dry_store_read is
# what `clikae burn` asks before it decides a tank is dry, and dry_store_epoch
# feeds the board's "seen HH:MM" annotation. An unreadable stamp must never
# keep a tank marked dry — and only `expired` gets the file removed, so a
# stamp that stayed `fresh` was one nothing would ever clean up.
@test "dry: an unreadable stamp never keeps a tank dry, and the marker is removed" {
  _src
  mkdir -p "$CLIKAE_HOME/dry/codex"
  local marker now; marker="$CLIKAE_HOME/dry/codex/goby"; now="$(date +%s)"

  printf '%s7\tresets 3pm\n' "$now" > "$marker"
  run dry_store_read codex goby
  [ "$status" -eq 1 ] || { echo "burn was told the tank is dry: rc=$status $output"; false; }
  [ ! -f "$marker" ] || { echo "the unreadable marker survived the read"; false; }

  printf '%s7\tresets 3pm\n' "$now" > "$marker"
  run dry_store_epoch codex goby
  [ "$status" -eq 1 ] || { echo "epoch accepted a year-2537 stamp: $output"; false; }

  # The control, same two readers: a real stamp is still dry, with its phrase.
  printf '%s\tresets 3pm\n' "$now" > "$marker"
  run dry_store_read codex goby
  [ "$status" -eq 0 ] && [ "$output" = "resets 3pm" ] || { echo "control: rc=$status [$output]"; false; }
  run dry_store_epoch codex goby
  [ "$status" -eq 0 ] && [ "$output" = "$now" ] || { echo "control epoch: rc=$status [$output]"; false; }
}

# P3-2 (2026-09-14 round-2 review): dry_store_peekv kept `read ... || return 1`
# after round 1 fixed the same shape in tmux.sh — a marker with no trailing
# newline returned 1 and was silently not counted (the under-report direction).
@test "alerts: a dry marker with no trailing newline still counts, with its phrase" {
  _src
  mkdir -p "$CLIKAE_HOME/dry/codex"
  printf '%s\tresets 3pm' "$(date +%s)" > "$CLIKAE_HOME/dry/codex/goby"
  dry_store_peekv codex goby "$(date +%s)" || { echo "peek rc=1 on a marker with no newline"; false; }
  [ "$_DRY_PEEK" = fresh ] || { echo "peek=$_DRY_PEEK"; false; }
  [ "$_DRY_PEEK_RESET" = "resets 3pm" ] || { echo "phrase=[$_DRY_PEEK_RESET]"; false; }
  run dry_store_epoch codex goby
  [ "$status" -eq 0 ] && [ -n "$output" ] || { echo "epoch: rc=$status [$output]"; false; }
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "$output"; false; }
  # An empty file is still no marker.
  : > "$CLIKAE_HOME/dry/codex/goby"
  run dry_store_peekv codex goby "$(date +%s)"
  [ "$status" -eq 1 ] || { echo "empty file: rc=$status"; false; }
}

# P3-3 (2026-09-14 round-2 review): the marker enumeration defaulted an unset
# CLIKAE_HOME to $HOME/.clikae, dry_store_peekv used it bare — so every marker
# the loop found, the peek could not open, and nothing was counted (unbound
# under set -u).
@test "alerts: with CLIKAE_HOME unset, the markers the row finds are the markers it reads" {
  _src
  mkdir -p "$HOME/.clikae/dry/codex"
  printf '%s\tresets 3pm\n' "$(date +%s)" > "$HOME/.clikae/dry/codex/goby"
  run env -u CLIKAE_HOME bash -uc '
    . "$1/lib/core/dry_store.sh"; . "$1/lib/core/burn_status.sh"
    . "$1/lib/core/duration.sh"; . "$1/lib/core/tmux.sh"
    tmux_status_render codex goby "" "" 120' _ "$CLIKAE_TEST_ROOT"
  [ "$status" -eq 0 ] || { echo "rc=$status: $output"; false; }
  [[ "$output" == *"!1"* ]] || { echo "not counted: $output"; false; }
  [[ "$output" == *"○"* ]] || { echo "fuel did not see it dry: $output"; false; }
  [[ "$output" != *"unbound"* ]] || { echo "$output"; false; }
}

@test "alerts: they add up across both sources" {
  _src
  _dry_marker codex goby
  _dry_marker claude hi
  _burn_status burn-1 running "$(_dead_pid)"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!3"* ]] || { echo "$output"; false; }
}

# ── the reconnect command ───────────────────────────────────────────────────

@test "reconnect: a known session id becomes an 8-character resume command" {
  _src
  run tmux_status_render claude wrasse 'a52bdc12-1111-2222-3333-444455556666' '' 120
  [[ "$output" == *"clikae resume a52bdc12"* ]] || { echo "$output"; false; }
  # …and the other 28 characters do not get to own the row.
  [[ "$output" != *"a52bdc12-1111"* ]] || { echo "$output"; false; }
}

@test "reconnect: no session id gives the command that reattaches the tank" {
  # codex and antigravity bare launches record no sid (tmux_set_session_id).
  # A bare `clikae resume` would open a picker rather than come back HERE.
  _src
  run tmux_status_render codex goby '' '' 120
  [[ "$output" == *"clikae codex goby"* ]] || { echo "$output"; false; }
  [[ "$output" != *"clikae resume "* ]] || { echo "$output"; false; }
}

@test "reconnect: a session id that is not one is ignored rather than printed" {
  # It arrives from a tmux user option, which a human can set by hand.
  _src
  run tmux_status_render codex goby 'not a; session id' '' 120
  [[ "$output" == *"clikae codex goby"* ]] || { echo "$output"; false; }
  [[ "$output" != *"not a"* ]] || { echo "$output"; false; }
}

# ── the width rule ──────────────────────────────────────────────────────────

@test "width: at 120 columns the whole row is there, ssh prefix included" {
  _src
  _usage_cache claude wrasse 42.0 65.0
  run tmux_status_render claude wrasse 'a52bdc12-1111-2222-3333-444455556666' reefbox 120
  [[ "$output" == *"ssh reefbox -t clikae resume a52bdc12"* ]] || { echo "$output"; false; }
  [[ "$output" == *"5h 42%"* ]] || { echo "$output"; false; }
}

@test "width: 100 columns is the floor, not the first casualty" {
  _src
  run tmux_status_render claude wrasse 'a52bdc12-1111-2222-3333-444455556666' reefbox 100
  [[ "$output" == *"ssh reefbox -t clikae resume a52bdc12"* ]] || { echo "$output"; false; }
}

@test "width: below 100 the ssh prefix is dropped, and nothing else is" {
  # It is dropped rather than cut: half a hostname is not a command. What is
  # left is exactly right on the host where the row is being read.
  _src
  _usage_cache claude wrasse 42.0 65.0
  _dry_marker codex goby
  run tmux_status_render claude wrasse 'a52bdc12-1111-2222-3333-444455556666' reefbox 80
  [[ "$output" != *"ssh "* ]] || { echo "$output"; false; }
  [[ "$output" == *"clikae resume a52bdc12"* ]] || { echo "$output"; false; }
  [[ "$output" == *"5h 42%"* ]] || { echo "$output"; false; }
  [[ "$output" == *"!1"* ]] || { echo "$output"; false; }
}

@test "width: the whole row fits 120 columns, and still fits 80" {
  # The acceptance criterion, measured on the row rather than argued about:
  # tmux styles are not columns, so they come out before counting.
  _src
  _usage_cache claude wrasse 100.0 100.0
  _dry_marker codex goby
  _burn_status burn-1 running "$(_dead_pid)"
  local plain w
  for w in 120 100 80; do
    run tmux_status_render claude wrasse 'a52bdc12-1111-2222-3333-444455556666' \
      a-rather-long-hostname "$w"
    plain="$(printf '%s' "$output" | sed 's/#\[[^]]*\]//g')"
    # 6 columns reserved for the clock at the right edge.
    [ "${#plain}" -le "$(( w - 6 ))" ] || {
      echo "at $w columns the row is ${#plain} wide: $plain"; false; }
  done
}

# P2-1 (2026-09-14 round-2 review): the fuel age made the rest of the row
# variable-width, and at 100 columns a 30-character hostname plus `· 23h ago`
# pushed the row into the clock — tmux cut the CLOCK (measured `!10 8:31` on a
# real tmux 3.4), not the prefix. The prefix must yield exactly when it would
# cost the clock: 29 characters still fits at 100 (measured `!10 18:32`), 30
# does not. Glyphs become one ASCII byte each so the count is columns under
# any locale.
_row_cols() {
  local p
  p="$(printf '%s' "$1" | sed 's/#\[[^]]*\]//g')"
  # 🔴 never `~` as a replacement: bash 5.2 tilde-expands it into $HOME.
  p="${p//·/.}"; p="${p//│/|}"; p="${p//○/o}"; p="${p//…/.}"
  printf '%s' "${#p}"
}

# _tank <n> — an n-character tank name. `validate_name`
# (lib/core/profile_store.sh) caps a tank name's character set, not its length,
# which is the whole reason the ladder below has rungs 3 and 4.
_tank() { printf '%0*d' "$1" 0 | tr 0 t; }

# The dim separator tmux_status_rowv puts between segments, spelled once here
# so the ladder table can assert whole rows verbatim.
_SEP=' #[fg=colour244]│#[default] '

@test "width: at 100 columns the ssh prefix yields to the fuel age, never the clock" {
  _src
  _usage_cache claude wrasse 100.0 100.0 82800   # 23h: the widest suffix
  local d; for d in 1 2 3 4 5 6 7 8 9 10; do _dry_marker codex "t$d"; done   # !10
  local h29 h30
  h29="$(printf '%029d' 0 | tr 0 h)"; h30="${h29}h"

  run tmux_status_render claude wrasse '' "$h30" 100
  [[ "$output" != *"ssh "* ]] || { echo "prefix kept at 30 chars: $output"; false; }
  [[ "$output" == *"clikae claude wrasse"*"23h ago"*"!10"* ]] || { echo "$output"; false; }
  [ "$(_row_cols "$output")" -le 94 ] || { echo "row is $(_row_cols "$output") cols: $output"; false; }

  run tmux_status_render claude wrasse '' "$h29" 100
  [[ "$output" == *"ssh $h29 -t clikae claude wrasse"* ]] || { echo "prefix dropped although it fits: $output"; false; }
  [ "$(_row_cols "$output")" -le 94 ] || { echo "row is $(_row_cols "$output") cols: $output"; false; }

  # Without the suffix the same 30-character host fits again — it is the
  # measured width that decides, not the hostname alone.
  _usage_cache claude wrasse 100.0 100.0 0
  run tmux_status_render claude wrasse '' "$h30" 100
  [[ "$output" == *"ssh $h30 -t "* ]] || { echo "$output"; false; }
}

# ── the yield ladder (P2-1, 2026-09-14 round-3 review) ──────────────────────
#
# Round 2 fixed the ssh prefix and left `clikae <engine> <tank>` — the THIRD
# variable-width element — unmentioned. Measured on real tmux 3.4 at 80 columns
# with a 23h-old cache, on 25a35ff: a 24-character claude tank cut the CLOCK
# (`!10 1:43`), and a 27-character antigravity tank cut the ALERT COUNT itself
# (`!10` → `!`, clock gone). tmux_status_rowv is the ladder that fixes it, and
# it is a PURE function — no file, no clock, no tmux — so the ladder is a table
# here rather than a story about a terminal.
#
# The order is fixed and the table asserts each rung in turn. Delete any rung
# from lib/core/tmux.sh and a row of this table goes red at 80 columns.

@test "width ladder: rung by rung, at a width that forces exactly that rung" {
  _src
  # 24 and 42 are the two widths the rungs below exercise; a 27-char tank was
  # built and never used (SC2034 under the CI bats shellcheck gate).
  local t24 t42 row
  t24="$(_tank 24)"; t42="$(_tank 42)"

  # rung 0 — nothing gives: 120 columns, prefix included.
  tmux_status_rowv 120 reefbox claude "$t24" '' '5h 100% · 7d 100%' '23h ago' 10
  [ "$_TSTAT_ROW" = "ssh reefbox -t clikae claude ${t24}${_SEP}5h 100% · 7d 100% · 23h ago${_SEP}#[fg=red]!10#[default] " ] \
    || { echo "rung0: $_TSTAT_ROW"; false; }

  # rung 1 — the ssh prefix, dropped whole (it is never even offered under 100).
  tmux_status_rowv 100 a-rather-long-hostname claude "$t24" '' '5h 100% · 7d 100%' '23h ago' 10
  [[ "$_TSTAT_ROW" != *"ssh "* ]] || { echo "rung1: $_TSTAT_ROW"; false; }
  [[ "$_TSTAT_ROW" == *"23h ago"* ]] || { echo "rung1 gave too much: $_TSTAT_ROW"; false; }

  # rung 2 — the fuel AGE suffix. The percentages stay.
  tmux_status_rowv 80 '' claude "$t24" '' '5h 100% · 7d 100%' '23h ago' 10
  [[ "$_TSTAT_ROW" != *"23h ago"* ]] || { echo "rung2: $_TSTAT_ROW"; false; }
  [[ "$_TSTAT_ROW" == *"clikae claude $t24"*"5h 100% · 7d 100%"*"!10"* ]] || { echo "rung2: $_TSTAT_ROW"; false; }

  # rung 3 — the tank name, elided from the MIDDLE, with a visible `…`.
  tmux_status_rowv 80 '' antigravity "$t42" '' '5h 100% · 7d 100%' '23h ago' 10
  [[ "$_TSTAT_ROW" == *"clikae antigravity tttttttttttttt…ttttttttttttt "* ]] || { echo "rung3: $_TSTAT_ROW"; false; }
  [[ "$_TSTAT_ROW" == *"5h 100% · 7d 100%"*"!10"* ]] || { echo "rung3: $_TSTAT_ROW"; false; }

  # rung 4 — the engine word. The seven columns it frees go BACK to the tank
  # name (P3-1, round-4 review): rung 3 sized the name while the engine was
  # still in the row, and a ladder yields only as much as the next rung needs.
  tmux_status_rowv 50 '' antigravity "$t42" '' '5h 100% · 7d 100%' '23h ago' 10
  [[ "$_TSTAT_ROW" == "clikae ttttt…tttt"* ]] || { echo "rung4: $_TSTAT_ROW"; false; }
  [[ "$_TSTAT_ROW" == *"5h 100% · 7d 100%"*"!10"* ]] || { echo "rung4: $_TSTAT_ROW"; false; }

  # rung 5 — the fuel segment, whole. The floor guard. Its columns go back to
  # the name too: 20 of them here, not the 8-column floor.
  tmux_status_rowv 40 '' antigravity "$t42" '' '5h 100% · 7d 100%' '23h ago' 10
  [ "$_TSTAT_ROW" = "clikae tttttttttt…ttttttttt${_SEP}#[fg=red]!10#[default] " ] \
    || { echo "rung5: $_TSTAT_ROW"; false; }
}

# 🔴 P3-1 (2026-09-14 round-4 review): the ladder over-yielded below 80 columns.
# `tshow` was computed at rung 3, against a row that still had the engine word
# (7 columns) and the fuel segment in it; rungs 4 and 5 then removed those and
# nothing gave the freed columns back. Measured on real tmux 3.4: claude with a
# 12-character tank at 40 columns drew `clikae tttt…ttt │ !10` — 22 columns of
# the 33 available, while the WHOLE name needed only 4 more; a 24-character tank
# was cut to 8 where 20 fit. The spec's "at least 8 columns of tank name" was
# never violated, which is why this is P3 and not P2 — but eliding a name that
# fits is exactly the "reads as a DIFFERENT tank" hazard rung 3 exists to bound.
@test "width ladder: columns freed by a later rung go back to the tank name" {
  _src
  # The two cells the review measured, at the width it measured them.
  tmux_status_rowv 40 '' claude "$(_tank 12)" '' '5h 100% · 7d 100%' '23h ago' 10
  [ "$_TSTAT_ROW" = "clikae $(_tank 12)${_SEP}#[fg=red]!10#[default] " ] \
    || { echo "12-char name still elided at w=40: $_TSTAT_ROW"; false; }
  [[ "$_TSTAT_ROW" != *"…"* ]] || { echo "a name that FITS was elided: $_TSTAT_ROW"; false; }

  tmux_status_rowv 40 '' claude "$(_tank 24)" '' '5h 100% · 7d 100%' '23h ago' 10
  [ "$_TSTAT_ROW" = "clikae tttttttttt…ttttttttt${_SEP}#[fg=red]!10#[default] " ] \
    || { echo "24-char name did not get the freed columns: $_TSTAT_ROW"; false; }

  # The general form, and the reason this is safe: after the freed columns are
  # handed back, every cell still fits (the giving-back happens AFTER rung 5, so
  # it can never be why something else was dropped), and no name is elided while
  # it would fit whole.
  local w n row plain vis
  for w in 28 40 50 60 80 100 120; do
    for n in 8 12 20 24 27 42 90; do
      tmux_status_rowv "$w" '' claude "$(_tank "$n")" '' '5h 100% · 7d 100%' '23h ago' 10
      row="$_TSTAT_ROW"
      [ "$(_row_cols "$row")" -le "$(( w - 6 ))" ] \
        || { echo "w=$w n=$n overflowed: $(_row_cols "$row") cols"; false; }
      plain="${row%%"$_SEP"*}"          # `clikae [engine ]<name>`
      vis="${plain##* }"                # the name as drawn
      case "$vis" in
        *…*) # elided — then the row must be using every column it was given
          [ "$(_row_cols "$row")" -ge "$(( w - 7 ))" ] \
            || { echo "w=$w n=$n elided with $(( w - 6 - $(_row_cols "$row") )) columns to spare: $row"; false; } ;;
        *) [ "${#vis}" -eq "$n" ] || { echo "w=$w n=$n drew a bare prefix: $row"; false; } ;;
      esac
    done
  done
}

@test "width ladder: the alert count and the clock are never cut, at any width or name length" {
  # The invariant the ladder exists for, asserted mechanically instead of
  # trusted: every cell keeps the WHOLE `!N` and leaves the clock its 6
  # columns. The arithmetic floor is `26 + ${#alerts}` — 28 for the `!10` used
  # here (P3-2, round-4 review: it is a formula, not the constant 28, which is
  # a two-digit count written down as if it were all of them). The spec only
  # promises 80.
  _src
  local w n row plain floor
  for w in 28 40 60 80 100 120; do
    for n in 3 8 20 24 27 42 90; do
      tmux_status_rowv "$w" a-rather-long-hostname antigravity "$(_tank "$n")" '' \
        '5h 100% · 7d 100%' '23h ago' 10
      row="$_TSTAT_ROW"
      [[ "$row" == *"!10#[default] " ]] || { echo "w=$w n=$n lost the count: $row"; false; }
      [ "$(_row_cols "$row")" -le "$(( w - 6 ))" ] \
        || { echo "w=$w n=$n is $(_row_cols "$row") cols: $row"; false; }
      # …and at least 8 columns of the tank name survive (all of it, when the
      # name is shorter than the floor).
      floor="$n"; [ "$floor" -gt 8 ] && floor=8
      plain="${row%%"$_SEP"*}"
      [ "${#plain}" -ge "$(( 7 + floor ))" ] || { echo "w=$w n=$n left no tank: $row"; false; }
    done
  done
}

# 🔴 P3-2 (2026-09-14 round-4 review): the arithmetic floor is a FORMULA. The
# doc (and this file's own comment above) said "28 columns", which is the floor
# for a two-digit count and one column short for `!100` — measured on real tmux
# 3.4 with 100 fresh dry markers at 28 columns: the helper produced 23 columns
# against a 22-column limit and the CLOCK was cut to `0:51`. This is the third
# time the same three-digit blind spot has been written down (round 3 retired
# "at most 59 columns for the rest", which was 60 at `!100`, and the same
# paragraph gained a new constant carrying the same assumption), so the floor is
# pinned here as arithmetic rather than as a number:
#
#   `clikae ` 7 + tank floor 8 + ` │ !` 4 + digits + clock 6 + trailing 1
#   = 26 + ${#alerts}  →  27 / 28 / 29 for one / two / three digits.
@test "width ladder: the arithmetic floor is 26 + the alert count's digits" {
  _src
  local n w floor
  for n in 7 10 100; do
    floor=$(( 26 + ${#n} ))
    # AT the floor the whole row fits, count and clock intact.
    tmux_status_rowv "$floor" '' claude "$(_tank 42)" '' '5h 100% · 7d 100%' '23h ago' "$n"
    [[ "$_TSTAT_ROW" == *"!$n#[default] " ]] || { echo "!$n at $floor: $_TSTAT_ROW"; false; }
    [ "$(_row_cols "$_TSTAT_ROW")" -le "$(( floor - 6 ))" ] \
      || { echo "!$n at $floor is $(_row_cols "$_TSTAT_ROW") cols, over $(( floor - 6 ))"; false; }
    # One column BELOW it, the row can no longer be drawn without eating into
    # the clock's six columns — which is what makes this the floor and not a
    # preference. (The row itself never cuts the count; it overflows instead,
    # and tmux gives the overrun to the clock.)
    tmux_status_rowv "$(( floor - 1 ))" '' claude "$(_tank 42)" '' '5h 100% · 7d 100%' '23h ago' "$n"
    [ "$(_row_cols "$_TSTAT_ROW")" -gt "$(( floor - 1 - 6 ))" ] \
      || { echo "!$n fits at $(( floor - 1 )) — the floor is not $floor"; false; }
  done
}

@test "width ladder: an elided name is marked, and a resume row has nothing to elide" {
  _src
  # 42 characters down to the 8-column floor: 4 + `…` + 3, never a bare
  # prefix that would read as a DIFFERENT tank that exists.
  tmux_status_rowv 40 '' claude "$(_tank 42)" '' '' '' 1
  [[ "$_TSTAT_ROW" == *"…"* ]] || { echo "elided without a mark: $_TSTAT_ROW"; false; }

  # A session id makes the command fixed-width: rungs 3 and 4 have no subject,
  # and the row must not invent one.
  tmux_status_rowv 40 '' claude "$(_tank 42)" a52bdc12 '5h 1% · 7d 2%' '23h ago' 7
  [ "$_TSTAT_ROW" = "clikae resume a52bdc12${_SEP}#[fg=red]!7#[default] " ] || { echo "$_TSTAT_ROW"; false; }
}

@test "width ladder: at 80 columns the review's own two tanks keep the count and the clock" {
  # The exact cells REVIEW-status77-r3.md measured red on 25a35ff, through the
  # whole render (cache 23h old, ten dry markers) rather than the pure function.
  _src
  _usage_cache claude "$(_tank 24)" 100.0 100.0 82800
  _usage_cache antigravity "$(_tank 27)" 100.0 100.0 82800
  local d; for d in 1 2 3 4 5 6 7 8 9 10; do _dry_marker codex "t$d"; done
  run tmux_status_render claude "$(_tank 24)" '' '' 80
  [ "$status" -eq 0 ]
  [[ "$output" == *"!10"* ]] || { echo "claude/24 lost the count: $output"; false; }
  [ "$(_row_cols "$output")" -le 74 ] || { echo "claude/24 is $(_row_cols "$output") cols: $output"; false; }

  run tmux_status_render antigravity "$(_tank 27)" '' '' 80
  [ "$status" -eq 0 ]
  [[ "$output" == *"!10"* ]] || { echo "antigravity/27 lost the count: $output"; false; }
  [ "$(_row_cols "$output")" -le 74 ] || { echo "antigravity/27 is $(_row_cols "$output") cols: $output"; false; }
}

@test "width: a width tmux could not tell us is not a crash" {
  _src
  run tmux_status_render claude wrasse '' reefbox ''
  [ "$status" -eq 0 ]
  [[ "$output" == *"clikae claude wrasse"* ]] || { echo "$output"; false; }
}

# ── what the row deliberately does NOT say ──────────────────────────────────

@test "row: there is no fleet segment" {
  # The proposal's `reefbox x● hi● l○` was withdrawn in the issue's own thread:
  # per-tank fleet fuel lives on the board, which is where it can be read.
  # This test exists so re-adding it is a decision somebody makes on purpose.
  _src
  clikae init claude other >/dev/null 2>&1 || true
  _usage_cache claude wrasse 42.0 65.0
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"/3"* ]] || { echo "$output"; false; }
  [[ "$output" != *"●"* ]] || { echo "$output"; false; }
  [[ "$output" != *"other"* ]] || { echo "$output"; false; }
}

@test "row: no emoji reaches the screen" {
  # scripts/signet-lint.sh fails any printed emoji (the ❯ cursor excepted), and
  # this string is printed. Asserted on the RENDERED row, not on the source, so
  # a glyph that arrives from state rather than from a literal is caught too.
  command -v perl >/dev/null 2>&1 || skip "perl not installed"
  _src
  _dry_marker codex goby
  _burn_status burn-1 running "$(_dead_pid)"
  _usage_cache claude wrasse 42.0 65.0
  run tmux_status_render claude wrasse 'a52bdc12-1111-2222-3333-444455556666' reefbox 120
  # Same ranges as scripts/signet-lint.sh, including the clock/hourglass code
  # points (U+231A-231B, U+23E9-23FA) that ⏳ hid in until 2026-09-22 — the
  # row rendered that glyph for a whole release while this very test stayed
  # green, because its ruler was a narrower copy of the lint's.
  run bash -c "printf '%s' \"\$1\" | perl -CSD -ne 'exit(/[\x{2600}-\x{27BF}\x{1F300}-\x{1FAFF}\x{2B00}-\x{2BFF}\x{FE0F}\x{231A}-\x{231B}\x{23E9}-\x{23FA}]/ ? 1 : 0)'" _ "$output"
  [ "$status" -eq 0 ] || { echo "an emoji reached the row: $output"; false; }
}

@test "row: no date, and the clock is not in the left segment" {
  _src
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"%H"* ]] || { echo "$output"; false; }
  [[ "$output" != *"-26"* ]] || { echo "$output"; false; }
}

# ── the helper, as tmux actually runs it ────────────────────────────────────

@test "helper: it never calls the network, and never calls clikae" {
  # A status line that could make a network call would make one every five
  # seconds, per client, forever — from inside tmux's server, where nobody
  # would see it fail. Loud stubs, and a tripwire file that must not appear.
  local bin="$TEST_HOME/.testbin"
  local trip="$TEST_HOME/tripwire"
  local t
  for t in curl wget jq clikae ssh nc; do
    cat > "$bin/$t" <<INNER
#!/usr/bin/env bash
printf '%s\n' "$t" >> "$trip"
echo "$t must never be called from the status line" >&2
exit 99
INNER
    chmod +x "$bin/$t"
  done
  _usage_cache claude wrasse 42.0 65.0
  run bash "$CLIKAE_TEST_ROOT/lib/core/status_line.sh" \
    "$HOME" "$CLIKAE_HOME" claude wrasse clikae-claude-wrasse '' 120
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"5h 42%"* ]] || { echo "$output"; false; }
  [ ! -f "$trip" ] || { echo "the helper called: $(cat "$trip")"; false; }
}

@test "helper: it reads the session id from the mirror when tmux cannot answer" {
  mkdir -p "$HOME/.clikae/state"
  printf 'a52bdc12-1111-2222-3333-444455556666\n' \
    > "$HOME/.clikae/state/clikae-claude-wrasse.session_id"
  run bash "$CLIKAE_TEST_ROOT/lib/core/status_line.sh" \
    "$HOME" "$CLIKAE_HOME" claude wrasse clikae-claude-wrasse '' 120
  [[ "$output" == *"clikae resume a52bdc12"* ]] || { echo "$output"; false; }
}

@test "helper: it writes nothing, anywhere" {
  # 🔴 A measurement that deletes state is not a measurement. dry_store_read's
  # lazy collection of a stale marker is correct for a caller asking once, and
  # would make "when did this marker disappear" a function of whether anyone
  # was looking at a status bar. Every state shape the row reads is here,
  # including the stale ones it is entitled to be tempted by.
  _usage_cache claude wrasse 42.0 65.0 90000
  _dry_marker codex goby 25200
  _dry_marker claude hi
  _burn_status burn-1 running "$(_dead_pid)"
  mkdir -p "$HOME/.clikae/state"
  printf 'a52bdc12-1111-2222-3333-444455556666\n' \
    > "$HOME/.clikae/state/clikae-claude-wrasse.session_id"

  local before after
  before="$(_manifest)"
  run bash "$CLIKAE_TEST_ROOT/lib/core/status_line.sh" \
    "$HOME" "$CLIKAE_HOME" claude wrasse clikae-claude-wrasse '' 120
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  after="$(_manifest)"
  [ -n "$before" ] || { echo "the manifest itself is empty — this test proves nothing"; false; }
  [ "$before" = "$after" ] || {
    echo "the status line changed state:"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true
    false; }
}

@test "helper: it costs far less than a redraw budget" {
  # Not a benchmark — a tripwire. The real measured cost is ~14 ms per call on
  # the development host (docs/DESIGN-tmux.md Rule 11); the threshold here is
  # an order of magnitude above that, so it catches "somebody added a call that
  # blocks" and never catches "CI was busy".
  _usage_cache claude wrasse 42.0 65.0
  local t0 t1 i
  t0="$(date +%s)"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    bash "$CLIKAE_TEST_ROOT/lib/core/status_line.sh" \
      "$HOME" "$CLIKAE_HOME" claude wrasse clikae-claude-wrasse '' 120 >/dev/null
  done
  t1="$(date +%s)"
  [ "$(( t1 - t0 ))" -le 3 ] || {
    echo "10 renders took $(( t1 - t0 ))s — something in the row is blocking"; false; }
}

# ── against a real tmux server (its own socket, never a shared one) ─────────

_sock() { printf '%s/s' "$CK_SOCKDIR"; }
_t() { env -u TMUX tmux -S "$(_sock)" "$@"; }

@test "tmux: the options land on this session, and the window list is gone" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  CK_SOCKDIR="$(mktemp -d)"
  local sess="ckst-$$-${BATS_TEST_NUMBER:-0}"
  _t new-session -d -s "$sess" 'sleep 30'
  _t new-window -d -t "=$sess:" -n wake 'sleep 30'

  # tmux_status_line talks to whatever `tmux` resolves to, so point the real
  # binary at this socket for the duration of the call.
  #
  # 🔴 `command` FIRST, not `env -u TMUX command tmux`: `command` is a shell
  # builtin and `env` cannot exec one ("env: 'command': No such file or
  # directory", rc=127). Written the other way round this override failed on
  # every call, tmux_status_line's own `|| true` swallowed all seven failures,
  # and the assertion below read as "the product does not set status-left".
  tmux() { command env -u TMUX tmux -S "$(_sock)" "$@"; }
  tmux_status_line "$sess" claude wrasse
  unset -f tmux

  run _t show-options -v -t "=$sess:" status-left
  [[ "$output" == *"status_line.sh"* ]] || { echo "$output"; false; }
  [[ "$output" == *"client_width"* ]] || { echo "$output"; false; }

  run _t show-options -v -t "=$sess:" status-right
  [ "$output" = '%H:%M ' ] || { echo "got '$output'"; false; }

  run _t show-options -v -t "=$sess:" status-interval
  [ "$output" = "5" ] || { echo "got '$output'"; false; }

  # The window list is gone because status-format[0] replaces the whole row —
  # not because window-status-format was blanked, which would have reached
  # every session on the server (or only this session's current window).
  run _t show-options -v -t "=$sess:" 'status-format[0]'
  [[ "$output" == *"status-left"* ]] || { echo "$output"; false; }
  [[ "$output" == *"status-right"* ]] || { echo "$output"; false; }
  [[ "$output" != *"window-status"* ]] || { echo "$output"; false; }
  [[ "$output" != *"window_flags"* ]] || { echo "$output"; false; }

  _t kill-session -t "=$sess" 2>/dev/null || true
  _t kill-server 2>/dev/null || true
  rm -rf "$CK_SOCKDIR"
}

@test "tmux: a neighbouring session keeps its own row" {
  # Same exact-target rule the rest of this layer lives under: `-t "=name:"`.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  CK_SOCKDIR="$(mktemp -d)"
  local sess="ckst-$$-${BATS_TEST_NUMBER:-0}"
  _t new-session -d -s "$sess" 'sleep 30'
  _t new-session -d -s "${sess}-neighbour" 'sleep 30'
  _t set-option -t "=${sess}-neighbour:" status-left '[UNTOUCHED] '

  tmux() { command env -u TMUX tmux -S "$(_sock)" "$@"; }
  tmux_status_line "$sess" claude wrasse
  unset -f tmux

  run _t show-options -v -t "=${sess}-neighbour:" status-left
  [ "$output" = '[UNTOUCHED] ' ] || { echo "got '$output'"; false; }

  _t kill-server 2>/dev/null || true
  rm -rf "$CK_SOCKDIR"
}

@test "tmux: a session that is gone does not fail the caller" {
  # Cosmetics never fail a launch — this runs right after the engine starts.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  CK_SOCKDIR="$(mktemp -d)"
  tmux() { command env -u TMUX tmux -S "$(_sock)" "$@"; }
  run tmux_status_line "ckst-nope-$$" claude wrasse
  unset -f tmux
  [ "$status" -eq 0 ]
  rm -rf "$CK_SOCKDIR"
}

# ── the other half: `clikae resume <prefix>` ────────────────────────────────

_two_sessions_sharing_a_prefix() {
  # 🔴 A STUB, because the real `claude` is on the developer's PATH and this
  # test ends in an exec. Without it the assertions would be about whatever a
  # real engine did with a fabricated transcript, and the suite would launch a
  # vendor CLI on every run.
  cat > "$TEST_HOME/.testbin/claude" <<'INNER'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${HOME:?}/claude-argv.log"
INNER
  chmod +x "$TEST_HOME/.testbin/claude"
  clikae init claude alpha >/dev/null 2>&1
  clikae init claude beta  >/dev/null 2>&1
  mkdir -p "$CLIKAE_HOME/profiles/claude/alpha/projects/-tmp-p" \
           "$CLIKAE_HOME/profiles/claude/beta/projects/-tmp-p"
  printf '{"cwd":"/tmp"}\n' \
    > "$CLIKAE_HOME/profiles/claude/alpha/projects/-tmp-p/a52bdc12-1111-2222-3333-444455556666.jsonl"
  printf '{"cwd":"/tmp"}\n' \
    > "$CLIKAE_HOME/profiles/claude/alpha/projects/-tmp-p/a52bdc12-9999-8888-7777-666655554444.jsonl"
  printf '{"cwd":"/tmp"}\n' \
    > "$CLIKAE_HOME/profiles/claude/beta/projects/-tmp-p/b0000000-1111-2222-3333-444455556666.jsonl"
}

@test "resume: a unique 8-character prefix resolves to the whole id" {
  # This is what makes the status row's left segment honest: it shows eight
  # characters because those eight characters are a command that works.
  _two_sessions_sharing_a_prefix
  run env CLIKAE_NO_INTERACTIVE=1 "$CLIKAE_BIN" resume b0000000
  [[ "$output" == *"claude/beta"* ]] || { echo "$output"; false; }
  # 🔴 The claim is not "it said something about beta" — it is that the ENGINE
  # was handed the WHOLE id. A resolver that passed the prefix through would
  # print exactly the same line and then fail in the vendor.
  [ -f "$TEST_HOME/claude-argv.log" ] || { echo "the engine never ran: $output"; false; }
  grep -qx 'b0000000-1111-2222-3333-444455556666' "$TEST_HOME/claude-argv.log" || {
    echo "engine argv was:"; cat "$TEST_HOME/claude-argv.log"; false; }
}

@test "resume: an ambiguous prefix is refused, with the candidates" {
  # Picking the newest would be the same shape as resuming a conversation the
  # operator did not name.
  _two_sessions_sharing_a_prefix
  run "$CLIKAE_BIN" resume a52bdc12
  [ "$status" -ne 0 ] || { echo "an ambiguous prefix was accepted: $output"; false; }
  [[ "$output" == *"matches 2 sessions"* ]] || { echo "$output"; false; }
  [[ "$output" == *"a52bdc12-1111-2222-3333-444455556666"* ]] || { echo "$output"; false; }
  [[ "$output" == *"a52bdc12-9999-8888-7777-666655554444"* ]] || { echo "$output"; false; }
}

# P3-5 (2026-09-14 round-1 fix review): session ids are always lowercase, but
# a human copying one from somewhere else won't always match case — an
# uppercase-typed prefix used to match nothing and read as "no such session".
@test "resume: an uppercase-typed prefix still resolves" {
  _two_sessions_sharing_a_prefix
  run env CLIKAE_NO_INTERACTIVE=1 "$CLIKAE_BIN" resume B0000000
  [[ "$output" == *"claude/beta"* ]] || { echo "$output"; false; }
  [ -f "$TEST_HOME/claude-argv.log" ] || { echo "the engine never ran: $output"; false; }
  grep -qx 'b0000000-1111-2222-3333-444455556666' "$TEST_HOME/claude-argv.log" || {
    echo "engine argv was:"; cat "$TEST_HOME/claude-argv.log"; false; }
}

# P3-4 (2026-09-14 round-1 fix review): an uncapped candidate list scrolls the
# "matches N sessions" header itself off an 80-column terminal — the one line
# that says what to do next was the first thing lost. 12 candidates, one
# shared prefix, all in one tank (only the count and the cap are under test).
_twelve_sessions_sharing_a_prefix() {
  clikae init claude solo >/dev/null 2>&1
  mkdir -p "$CLIKAE_HOME/profiles/claude/solo/projects/-tmp-p"
  local i suffix
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    suffix="$(printf '%04d' "$i")"
    printf '{"cwd":"/tmp"}\n' \
      > "$CLIKAE_HOME/profiles/claude/solo/projects/-tmp-p/c0000000-$suffix-2222-3333-444455556666.jsonl"
  done
}

@test "resume: an ambiguous prefix's candidate list caps at 10, with a count for the rest" {
  _twelve_sessions_sharing_a_prefix
  run "$CLIKAE_BIN" resume c0000000
  [ "$status" -ne 0 ] || { echo "an ambiguous prefix was accepted: $output"; false; }
  [[ "$output" == *"matches 12 sessions"* ]] || { echo "$output"; false; }
  local shown; shown="$(grep -c 'clikae resume c0000000-' <<<"$output")"
  [ "$shown" -eq 10 ] || { echo "printed $shown full candidates, want 10:"; echo "$output"; false; }
  [[ "$output" == *"and 2 more"* ]] || { echo "$output"; false; }
}

# P3-7 (2026-09-14 round-2 review): the cut hides the OLDEST candidates, and
# the "… and N more" line did not say so or how to reach them.
@test "resume: the capped list hides the oldest, and says how to reach them" {
  _twelve_sessions_sharing_a_prefix
  local i suffix
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    suffix="$(printf '%04d' "$i")"
    touch -t "2026010112$(printf '%02d' "$i")" \
      "$CLIKAE_HOME/profiles/claude/solo/projects/-tmp-p/c0000000-$suffix-2222-3333-444455556666.jsonl"
  done
  run "$CLIKAE_BIN" resume c0000000
  [ "$status" -ne 0 ] || false
  [[ "$output" != *"c0000000-0001-"* ]] || { echo "the oldest was shown: $output"; false; }
  [[ "$output" != *"c0000000-0002-"* ]] || { echo "the second oldest was shown: $output"; false; }
  [[ "$output" == *"c0000000-0012-"* ]] || { echo "the newest was cut: $output"; false; }
  [[ "$output" == *"and 2 more, older"* ]] || { echo "$output"; false; }
  [[ "$output" == *"type more of the id"* ]] || { echo "$output"; false; }
  [[ "$output" == *'`clikae resume --all`'* ]] || { echo "$output"; false; }
}

@test "resume: the same id in two tanks is ONE candidate, not an ambiguity" {
  # A relay copies a session into a second tank. That is one conversation, and
  # _resume_locate already knows how to choose between the copies.
  _two_sessions_sharing_a_prefix
  cp "$CLIKAE_HOME/profiles/claude/alpha/projects/-tmp-p/a52bdc12-1111-2222-3333-444455556666.jsonl" \
     "$CLIKAE_HOME/profiles/claude/beta/projects/-tmp-p/"
  rm "$CLIKAE_HOME/profiles/claude/alpha/projects/-tmp-p/a52bdc12-9999-8888-7777-666655554444.jsonl"
  run env CLIKAE_NO_INTERACTIVE=1 "$CLIKAE_BIN" resume a52bdc12
  [[ "$output" != *"matches"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Resuming"* ]] || { echo "$output"; false; }
}

@test "resume: a full id is never re-read as a prefix" {
  _two_sessions_sharing_a_prefix
  run env CLIKAE_NO_INTERACTIVE=1 "$CLIKAE_BIN" resume a52bdc12-1111-2222-3333-444455556666
  [[ "$output" != *"matches"* ]] || { echo "$output"; false; }
  [[ "$output" == *"claude/alpha"* ]] || { echo "$output"; false; }
}

@test "resume: a prefix that matches nothing still says so plainly" {
  _two_sessions_sharing_a_prefix
  run "$CLIKAE_BIN" resume zzzzzzzz
  [ "$status" -ne 0 ]
  [[ "$output" == *"No session 'zzzzzzzz'"* ]] || { echo "$output"; false; }
}
