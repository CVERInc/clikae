#!/usr/bin/env bats
# tests/bats/doctor.bats — `clikae doctor` read-only health check.

load '../helpers'

@test "doctor reports environment + a row per supported CLI" {
  run clikae doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"clikae doctor"* ]] || false
  [[ "$output" == *"CLIKAE_HOME"* ]] || false
  [[ "$output" == *"$CLIKAE_HOME"* ]] || false
  [[ "$output" == *"INSTALLED"* ]] || false
  [[ "$output" == *"TANKS"* ]] || false
}

@test "doctor lists ALL adapters including the last one (vercel)" {
  # Regression: $(scan_clis) strips the trailing newline, so a naive
  # `printf '%s' | while read` drops the final CLI. vercel must be present.
  run clikae doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"vercel"* ]] || false
  [[ "$output" == *"claude"* ]] || false
  [[ "$output" == *"codex"* ]] || false
}

@test "doctor counts a created profile and suggests the next step" {
  clikae init claude work
  run clikae doctor
  [ "$status" -eq 0 ]
  # claude row now shows a non-zero profile count.
  [[ "$output" =~ claude[[:space:]]+(yes|no)[[:space:]]+1 ]] || false
}

@test "doctor changes nothing on disk (read-only)" {
  before="$(find "$CLIKAE_HOME" 2>/dev/null | sort)"
  run clikae doctor
  [ "$status" -eq 0 ]
  after="$(find "$CLIKAE_HOME" 2>/dev/null | sort)"
  [ "$before" = "$after" ]
}

@test "doctor rejects unexpected arguments" {
  run clikae doctor bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unexpected argument"* ]] || false
}

# --- auth dropout reporting ---------------------------------------------------
# clikae does not own Claude's OAuth refresh, but that daemon writes its log
# inside the tank clikae manages, so the AFTERMATH of a refresh-race logout is
# readable. Report only when the newest auth event is still a failure.
_seed_daemon_log() {
  local tank="$1"; shift
  local d="$CLIKAE_HOME/profiles/claude/$tank"
  mkdir -p "$d"
  clikae settings apply claude "$tank" >/dev/null
  local l; : > "$d/daemon.log"
  for l in "$@"; do printf '%s\n' "$l" >> "$d/daemon.log"; done
}

@test "doctor names a tank left signed out by a refresh failure" {
  _seed_daemon_log dropped \
    "[2026-07-01T00:00:00.000Z] [supervisor] auth: proactive refresh succeeded" \
    "[2026-07-19T02:58:26.100Z] [supervisor] auth: proactive refresh failed, signalling re-auth required" \
    "[2026-07-19T02:58:27.000Z] [supervisor] auth: no token found, will re-check keychain every 60s"
  run clikae doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude/dropped"* ]] || false
  [[ "$output" == *"token-refresh failure"* ]] || false
}

@test "doctor stays quiet once the tank was logged back in" {
  # "scheduling" is the healthy signal: the daemon only schedules a refresh when
  # it HAS a token. Treating it as neutral produced a false positive on a tank
  # that had recovered a week earlier.
  _seed_daemon_log recovered \
    "[2026-07-19T02:58:26.100Z] [supervisor] auth: proactive refresh failed, signalling re-auth required" \
    "[2026-07-26T04:17:49.420Z] [supervisor] auth: scheduling proactive refresh in 14388s"
  run clikae doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"claude/recovered"* ]] || false
}

@test "doctor says nothing about a tank with no daemon log" {
  clikae init claude quiet
  run clikae doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"claude/quiet"* ]] || false
}

# --- per-tank agy login stashes ----------------------------------------------
# agy has ONE live Keychain slot, so a tank switch stashes the current login
# under clikae-agy-<tank> and restores the target's. A tank with no stash can't
# be switched to without an interactive Google sign-in — so `clikae burn agy`
# can't auto-hop onto it either, and a headless run would sit at a login prompt
# until --print-timeout. That was invisible until you hit it; doctor says it now.
@test "doctor separates agy tanks that carry a login from those that don't" {
  [ "$(uname -s)" = "Darwin" ] || skip "keychain section is macOS-only"
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/haslogin"
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/nologin"
  # Stub `security` so the test never touches the real login keychain: only the
  # 'haslogin' tank's stash is reported present.
  local stub="$TEST_HOME/bin"; mkdir -p "$stub"
  cat > "$stub/security" <<'STUB'
#!/bin/sh
case "$*" in
  *clikae-agy-haslogin*) exit 0 ;;
  *clikae-agy-*)         exit 1 ;;
  *)                     exit 1 ;;
esac
STUB
  chmod +x "$stub/security"
  PATH="$stub:$PATH" run clikae doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"carry a saved login: haslogin"* ]] || false
  [[ "$output" == *"no saved login: nologin"* ]] || false
}

@test "doctor: says nothing about old names when there are none" {
  # 🔴 Silence IS the reading. A line that always printed "0 legacy sessions"
  # would be a number nobody can act on, on the screen whose whole job is to say
  # what to do next — and for the person deciding when the legacy read paths can
  # be deleted, "doctor says nothing" is the zero they are waiting for.
  run clikae doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"old names"* ]] || { echo "reported leftovers in a clean home: $output"; false; }
}

@test "doctor: counts state files still carrying the old prefix" {
  local sdir="$HOME/.clikae/state"; mkdir -p "$sdir"
  : > "$sdir/ck-claude-x-4242.scrollback"
  : > "$sdir/ck-ephem-claude-x-99.lock"
  run clikae doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"old names"* ]] || { echo "did not notice two ck-* files: $output"; false; }
  [[ "$output" == *"2 state file(s)"* ]] || { echo "wrong count: $output"; false; }
  # …and says what will happen to them, because a count with no next step is noise.
  [[ "$output" == *"clikae clean"* ]] || { echo "no action offered: $output"; false; }
}

# ── the memory-reachability row ─────────────────────────────────────────────
# 🔴 WHY DOCTOR ASKS AT ALL. memory_access_warn fires when a tank starts — the
# moment you can least act on it, already on your way into a session, while the
# engine that goes on to read nothing has no idea. And on a background session
# nobody even sees it: a TCC denial there is silent (2026-08-22, three memory
# files written with the index unwritable and no error anywhere). doctor is the
# same question asked when you came looking for the answer.

@test "doctor: a readable Soul store says nothing" {
  # Silence is the contract. A permanent "memory: fine" line on a screen built to
  # tell you what to do next is a number nobody can act on.
  mkdir -p "$CLIKAE_HOME/souls/t/memory"
  : > "$CLIKAE_HOME/souls/t/memory/MEMORY.md"
  run clikae doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"Soul cannot be read"* ]] || { echo "$output"; false; }
}

@test "doctor: an unreadable Soul store is reported, with the engines that share it" {
  mkdir -p "$CLIKAE_HOME/souls/t/memory"
  : > "$CLIKAE_HOME/souls/t/memory/MEMORY.md"
  printf 'claude/x\tx@example.com\t%s\n' "$CLIKAE_HOME/souls/t/memory" \
    > "$CLIKAE_HOME/souls/t/members"
  # The shape TCC produces, which cannot be synthesised directly: the permission
  # bits say yes and the read still says no.
  cat > "$TEST_HOME/.testbin/ls" <<STUB
#!/usr/bin/env bash
case "\$*" in *"souls/t/memory"*) exit 1 ;; esac
exec /bin/ls "\$@"
STUB
  chmod +x "$TEST_HOME/.testbin/ls"
  run clikae doctor
  rm -f "$TEST_HOME/.testbin/ls"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Soul cannot be read"* ]] || { echo "$output"; false; }
  [[ "$output" == *"'t' Soul"* ]] || { echo "did not name the group: $output"; false; }
}

@test "doctor: an ordinary chmod on a Soul store is reported as itself" {
  mkdir -p "$CLIKAE_HOME/souls/t/memory"
  chmod 000 "$CLIKAE_HOME/souls/t/memory"
  run clikae doctor
  chmod 755 "$CLIKAE_HOME/souls/t/memory"
  [ "$status" -eq 0 ]
  [[ "$output" == *"permission bits deny"* ]] || { echo "$output"; false; }
}

@test "doctor: the memory block's labels line up with the rows above it" {
  # 🔴 A DEFECT EVERY SUBSTRING ASSERTION MISSED. The hint text was written for
  # the launch warning, whose gutter sits under `[ WARN ] `; doctor writes in a
  # 16-wide label field. Both printed all the right words, and the continuation
  # lines landed two spaces out of true — invisible to `[[ $output == *x* ]]`,
  # obvious the instant it ran on a real machine. So this measures COLUMNS.
  mkdir -p "$CLIKAE_HOME/souls/t/memory"
  : > "$CLIKAE_HOME/souls/t/memory/MEMORY.md"
  cat > "$TEST_HOME/.testbin/ls" <<STUB
#!/usr/bin/env bash
case "\$*" in *"souls/t/memory"*) exit 1 ;; esac
exec /bin/ls "\$@"
STUB
  chmod +x "$TEST_HOME/.testbin/ls"
  run clikae doctor
  rm -f "$TEST_HOME/.testbin/ls"
  [ "$status" -eq 0 ]

  # The column doctor's own rows use, taken from a row rather than hard-coded:
  # a test that restates the constant would agree with the code and with nothing
  # else.
  local head_indent label_indent seen=0
  head_indent="$(printf '%s\n' "$output" | sed -n "s/^\\( *\\)memory  *the 't' Soul.*/\\1/p" | head -1)"
  head_indent=$(( ${#head_indent} + 16 + 1 ))

  while IFS= read -r line; do
    case "$line" in
      *"bits:   "*|*"maybe:  "*|*"fix:    "*|*"cause:  "*) : ;;
      *) continue ;;
    esac
    label_indent="$(printf '%s' "$line" | sed -n 's/^\( *\)[a-z].*/\1/p')"
    label_indent=${#label_indent}
    [ "$label_indent" -eq "$head_indent" ] || {
      echo "label at column $label_indent, rows at $head_indent:"
      printf '%s\n' "$line"; false; }
    seen=$((seen + 1))
  done <<EOF
$output
EOF
  # Without this the loop could match nothing and pass in silence.
  [ "$seen" -ge 2 ] || { echo "found $seen label lines to check"; printf '%s\n' "$output"; false; }
}

@test "doctor reports permissions drift once per tank" {
  clikae init claude drifted
  local f="$CLIKAE_HOME/profiles/claude/drifted/settings.json"
  printf '{}\n' > "$f"
  cp "$f" "$TEST_HOME/before"
  run clikae doctor
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'claude/drifted: permissions drift')" -eq 1 ]
  cmp "$f" "$TEST_HOME/before"
}

@test "doctor names a missing permissions template instead of blaming settings.json" {
  clikae init claude a --no-template
  local prefix="$BATS_TEST_TMPDIR/tap"
  mkdir -p "$prefix"
  cp -R "$CLIKAE_TEST_ROOT/bin" "$CLIKAE_TEST_ROOT/lib" "$prefix/"
  run "$prefix/bin/clikae" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude: permissions template missing (installation incomplete)"* ]] || false
  [[ "$output" != *"invalid JSON"* ]] || false
}

# --- tmux guard shim reporting (CVERInc/clikae#97) -----------------------------
# The guard (lib/shims/tmux) only protects a session whose PANE PROCESS has it
# FIRST on its real PATH — tmux_spawn_session (Rule 10, lib/core/tmux.sh) is
# the only place that arranges that, and a session's PATH is fixed at birth
# (DESIGN-tmux Rule 8), so a session spawned some other way, or before the
# guard shipped, stays unprotected for its whole life.
#
# 🔴 P1-2 (clikae#97 review round 1): this used to construct both the "with"
# and "without" cases via `tmux new-session -e "PATH=…"` and read
# `show-environment -t` back — the same write-and-read-back-the-same-table
# loop `_doctor_pane_path` replaced doctor's own probe to stop doing. That
# probe could not structurally go red for a real `tmux_spawn_session`
# session, guarded or not: it only ever proved what `-e` had been asked to
# write. These two now use the actual code paths — a bare `tmux new-session`
# (no guard, the pre-#97 shape) and the real `tmux_spawn_session` (the
# guard, as clikae itself spawns it) — and read the PANE PROCESS back via
# `/proc`, the same probe doctor itself now uses.

_tg_tank() { printf 'tg%s%s' "$$" "${BATS_TEST_NUMBER:-0}"; }

@test "doctor reports a live session whose PANE PROCESS lacks the guard on PATH" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sess; sess="clikae-codex-$(_tg_tank)"
  # A bare `tmux new-session`, not tmux_spawn_session — the shape of a
  # session that predates the guard, or whose spawn path drifted around
  # Rule 10. Its pane process never gets the shim.
  tmux new-session -d -s "$sess" 'sleep 60'
  run clikae doctor
  tmux kill-session -t "=$sess" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux guard"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$sess"* ]] || { echo "$output"; false; }
}

@test "doctor stays silent when the live session's PANE PROCESS actually has the guard first on PATH" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
  local sess; sess="clikae-codex-$(_tg_tank)"
  # The real production spawn path (Rule 10) — this is what actually gives
  # the pane process the guard, per P1-1.
  tmux_spawn_session --session "$sess" -- 'sleep 60'
  run clikae doctor
  tmux kill-session -t "=$sess" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" != *"tmux guard"* ]] || { echo "$output"; false; }
}

@test "doctor changes nothing on disk when checking the tmux guard (read-only)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sess; sess="clikae-codex-$(_tg_tank)"
  tmux new-session -d -e "PATH=/usr/bin:/bin" -s "$sess" 'sleep 60'
  before="$(find "$CLIKAE_HOME" 2>/dev/null | sort)"
  run clikae doctor
  after="$(find "$CLIKAE_HOME" 2>/dev/null | sort)"
  tmux kill-session -t "=$sess" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "$before" = "$after" ]
}

# --- macOS pane-path fallback + set -eo pipefail survival (P2-4, review round 2) --
# `_doctor_pane_path`'s Darwin branch (`ps eww`) and its two callers were never
# exercised anywhere: GitHub's macos bats runner has no tmux at all (the guard
# probe's own `command -v tmux` short-circuits before either is ever reached),
# and every Linux run takes the `/proc` branch instead. These probe the two
# code paths directly rather than waiting for a platform this suite cannot run.

@test "_doctor_pane_path (macOS ps eww fallback) reads the LAST PATH= token, not the command line's own" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/commands/doctor.sh"
  mkdir -p "$TEST_HOME/.osbin"
  printf '#!/bin/sh\necho Darwin\n' > "$TEST_HOME/.osbin/uname"
  chmod +x "$TEST_HOME/.osbin/uname"
  # Simulates BSD `ps eww -o command=`: the pane's own COMMAND legitimately
  # contains "PATH=..." (Rule 10's `env PATH=... <cmd>`, lib/core/tmux.sh)
  # BEFORE its real ENVIRONMENT's own PATH= is appended after it.
  cat > "$TEST_HOME/.osbin/ps" <<'STUB'
#!/bin/sh
printf 'env PATH=/SHIM/intended:/usr/bin sleep 60 PATH=/REAL/env:/usr/bin OTHER=1\n'
STUB
  chmod +x "$TEST_HOME/.osbin/ps"
  PATH="$TEST_HOME/.osbin:$PATH" run _doctor_pane_path 999999999
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  [ "$output" = "/REAL/env:/usr/bin" ] || { echo "got: $output"; false; }
}

@test "doctor's tmux guard check survives list-panes failing on a vanished session (set -eo pipefail)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # A session name live_session_names claims exists but tmux does not: the
  # shape of the race between the listing and the -F probe two lines later.
  cat > "$TEST_HOME/probe.sh" <<EOF
set -eo pipefail
CLIKAE_LIB="$CLIKAE_LIB"
# shellcheck source=/dev/null
. "$CLIKAE_TEST_ROOT/lib/core/log.sh"
# shellcheck source=/dev/null
. "$CLIKAE_TEST_ROOT/lib/commands/doctor.sh"
live_session_names() { printf 'clikae-codex-ghost97\tx\ty\n'; }
_doctor_tmux_guard
echo AFTER-GUARD-CHECK
EOF
  run bash "$TEST_HOME/probe.sh"
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  [[ "$output" == *"AFTER-GUARD-CHECK"* ]] || { echo "aborted before completing: $output"; false; }
}

@test "doctor's tmux guard check survives an unreadable pane environment (set -eo pipefail)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sess; sess="clikae-codex-$(_tg_tank)"
  tmux new-session -d -s "$sess" 'sleep 60'
  cat > "$TEST_HOME/probe2.sh" <<EOF
set -eo pipefail
CLIKAE_LIB="$CLIKAE_LIB"
# shellcheck source=/dev/null
. "$CLIKAE_TEST_ROOT/lib/core/log.sh"
# shellcheck source=/dev/null
. "$CLIKAE_TEST_ROOT/lib/commands/doctor.sh"
# Simulates an unreadable /proc/<pid>/environ (or a failing macOS ps eww):
# the real, per-pid probe returning nonzero, not just an empty string.
_doctor_pane_path() { return 1; }
live_session_names() { printf '$sess\tx\ty\n'; }
_doctor_tmux_guard
echo AFTER-GUARD-CHECK
EOF
  run bash "$TEST_HOME/probe2.sh"
  tmux kill-session -t "=$sess" 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  [[ "$output" == *"AFTER-GUARD-CHECK"* ]] || { echo "aborted before completing: $output"; false; }
}
