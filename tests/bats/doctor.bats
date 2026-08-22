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
