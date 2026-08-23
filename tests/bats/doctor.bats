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
