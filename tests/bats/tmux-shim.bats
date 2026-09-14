#!/usr/bin/env bats
# tests/bats/tmux-shim.bats — lib/shims/tmux, the guard clikae puts ahead of the
# real tmux on every session it launches (CVERInc/clikae#97).
#
# 🔴 WHAT THIS IS ABOUT. A process that has INHERITED $TMUX from a live server
# and runs a destructive verb naming no socket hits the inherited server, not
# whatever it thought it was isolating. Twice:
#
#   2026-09-10  a reviewer's bare `tmux kill-server` (no -L) took down the
#               operator's real server.
#   2026-09-13  a fix lane ran `TMUX_TMPDIR="$T" tmux kill-server`, believing
#               TMUX_TMPDIR isolated it — socket precedence is
#               -S > -L > $TMUX > TMUX_TMPDIR, and $TMUX (inherited from the
#               cockpit) was set, so it killed the cockpit and 14 running
#               lanes. Resumed from its own transcript, it did it again.
#
# This file's own tests must not repeat the disease they are proving a fix
# for. Every test that exercises the REFUSAL runs the shim with an explicit
# throwaway `-S` server as the "inherited" one ($TMUX points at it, never at
# the real thing) and proves that server survived by listing it before and
# after. Tests that exercise the two PASS-THROUGH shapes tmux-spawn.bats and
# ssh-agent-link.bats already rely on ($TMUX unset, TMUX_TMPDIR isolated by
# tests/helpers.bash) reuse that same, already-audited isolation rather than
# inventing a second mechanism.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

SHIM() { printf '%s/lib/shims/tmux\n' "$CLIKAE_TEST_ROOT"; }

_src_tmux() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
}

# ── the guard itself ─────────────────────────────────────────────────────────

@test "shim: bare kill-server while \$TMUX is inherited is refused (rc 86), and the real server survives" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/victim-server.sock"
  tmux -S "$sock" new-session -d -s victim 'sleep 60'
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "victim" ] || {
    echo "premise broken: the throwaway victim server did not start: $output"; false; }

  run env TMUX="$sock,99999,0" bash "$(SHIM)" kill-server
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  [[ "$output" == *"kill-server"* ]] || { echo "message doesn't name the verb: $output"; false; }
  [[ "$output" == *"$sock"* ]] || { echo "message doesn't name the socket: $output"; false; }
  [[ "$output" == *"tmux -S"* ]] || { echo "message doesn't name the legal form: $output"; false; }

  # PROOF, not inference: list the victim server again, after.
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] || { echo "the victim server did NOT survive: $output"; false; }
  [ "$output" = "victim" ] || { echo "got: $output"; false; }

  tmux -S "$sock" kill-server 2>/dev/null || true
}

@test "shim: kill-server -S <path> passes straight through" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/passthrough-server.sock"
  tmux -S "$sock" new-session -d -s pt 'sleep 60'

  # $TMUX names a DIFFERENT (nonexistent) inherited socket. Naming -S is what
  # must let this through, not the absence of an inherited $TMUX.
  run env TMUX="$TEST_HOME/not-the-real-one,1,0" bash "$(SHIM)" -S "$sock" kill-server
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }

  # Proof it reached the REAL binary, not just that the guard stayed quiet:
  # the -S target is actually gone.
  run tmux -S "$sock" list-sessions
  [ "$status" -ne 0 ] || { echo "the -S server should be dead: $output"; false; }
}

@test "shim: bare kill-session while \$TMUX is inherited is refused (rc 86), and the current session survives" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/victim-session.sock"
  tmux -S "$sock" new-session -d -s cur 'sleep 60'

  run env TMUX="$sock,99999,0" bash "$(SHIM)" kill-session
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  [[ "$output" == *"kill-session"* ]] || { echo "message doesn't name the verb: $output"; false; }
  [[ "$output" == *"$sock"* ]] || { echo "message doesn't name the socket: $output"; false; }
  [[ "$output" == *"-t"* ]] || { echo "message doesn't name the legal form: $output"; false; }

  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] || { echo "the current session did NOT survive: $output"; false; }
  [ "$output" = "cur" ] || { echo "got: $output"; false; }

  tmux -S "$sock" kill-server 2>/dev/null || true
}

@test "shim: kill-session -t <target> passes straight through even with \$TMUX inherited" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/target-session.sock"
  tmux -S "$sock" new-session -d -s target 'sleep 60'

  # -S here is only so the command reaches OUR throwaway server; the guard's
  # kill-session check cares about -t, not -S/-L.
  run env TMUX="$TEST_HOME/not-the-real-one,1,0" bash "$(SHIM)" -S "$sock" kill-session -t target
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }

  run tmux -S "$sock" list-sessions
  [ "$status" -ne 0 ] || { echo "the target session should be dead: $output"; false; }
}

@test "shim: \$TMUX unset never refuses, not even a bare kill-server" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # Safety premise (same one tmux-spawn.bats states and relies on): $TMUX is
  # unset and TMUX_TMPDIR is THIS TEST's own throwaway directory, so the
  # "default" socket a bare, unqualified command reaches is never the real one.
  [ -z "${TMUX:-}" ] || { echo "TMUX leaked into the test: $TMUX"; false; }
  [[ "$TMUX_TMPDIR" == "$TEST_HOME"* ]] || { echo "TMUX_TMPDIR=$TMUX_TMPDIR"; false; }

  tmux new-session -d -s isoprobe 'sleep 60'
  run env -u TMUX bash "$(SHIM)" kill-server
  [ "$status" -eq 0 ] || { echo "refused with \$TMUX unset: status=$status output=$output"; false; }

  # Proof it reached the real binary: the isolated default server is gone too.
  run tmux list-sessions
  [ "$status" -ne 0 ] || { echo "expected the isolated server to be gone: $output"; false; }
}

@test "shim: never calls itself, even with its own directory on PATH twice" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local shimdir="$CLIKAE_TEST_ROOT/lib/shims"
  # If self-skip ever breaks, the symptom is a fork bomb, not a failed
  # assertion — bound it with timeout so that reads as a failure too.
  run env -u TMUX PATH="$shimdir:$shimdir:$PATH" timeout 15 "$(SHIM)" -V
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  [[ "$output" == tmux* ]] || { echo "expected a tmux version banner, got: $output"; false; }
}

@test "shim: an unknown/no-op verb is never touched, \$TMUX set or not" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  run env TMUX="$TEST_HOME/whatever,1,0" bash "$(SHIM)" -V
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  [[ "$output" == tmux* ]] || { echo "$output"; false; }
}

# ── clikae's own launch env: the shim goes first, at the single constructor ──
#
# 🔴 P1-1 (clikae#97 review round 1): `show-environment -t` only ever reports
# what Rule 10's `-e "PATH=…"` was asked to write — it is NOT what a pane's
# real PROCESS gets (tmux hands a new pane's process the spawning CLIENT's
# live PATH instead). The two tests below still probe the `-e` table because
# staying in sync with what Rule 10 intends is worth checking, but they are
# no longer this file's proof of the actual guarantee — the "PANE PROCESS"
# section further down is.

@test "launch: tmux_spawn_session puts the shim directory first on the session's -e table (documentary, not the guarantee)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  tmux_spawn_session --session pathprobe97 -- 'sleep 30'
  run tmux show-environment -t '=pathprobe97' PATH
  tmux kill-session -t '=pathprobe97' 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  case "$output" in
    "PATH=$CLIKAE_LIB/shims:"*) : ;;
    *) echo "got: $output"; false ;;
  esac
}

@test "launch: spawning from an already-shimmed PATH does not grow the -e table" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  PATH="$CLIKAE_LIB/shims:$PATH"
  tmux_spawn_session --session pathprobe97b -- 'sleep 30'
  run tmux show-environment -t '=pathprobe97b' PATH
  tmux kill-session -t '=pathprobe97b' 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local count
  count="$(printf '%s' "$output" | grep -o "$CLIKAE_LIB/shims" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ] || { echo "shim dir appears $count times in: $output"; false; }
}

# ── P1-1: the PANE PROCESS itself, not the session table (review round 1) ──
# Linux-only: these read the pane process's real environment straight out of
# /proc, the same probe `doctor`'s `_doctor_pane_path` now uses (P1-2) — see
# lib/commands/doctor.sh for the macOS `ps eww` equivalent, not exercised
# here because bats has no portable way to inspect a process's environment
# without /proc.

@test "launch: the pane PROCESS itself gets the shim first on PATH, not just the -e table" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  [ -r /proc/self/environ ] || skip "no /proc on this platform"
  _src_tmux
  tmux_spawn_session --session pathprocprobe97 -- 'sleep 30'
  local pid; pid="$(tmux list-panes -t '=pathprocprobe97' -F '#{pane_pid}' | head -n1)"
  # tr NUL->newline INSIDE the run'd command, not after: bats captures `run`
  # output via command substitution, which silently DROPS embedded NUL bytes
  # (bash's own behaviour) — by the time that happened to a raw `cat` of
  # /proc/…/environ, every "KEY=value" pair had already run together with no
  # separator left to split on.
  run bash -c "tr '\\0' '\\n' < /proc/$pid/environ"
  tmux kill-session -t '=pathprocprobe97' 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "could not read /proc/$pid/environ: $output"; false; }
  local pane_path
  pane_path="$(printf '%s\n' "$output" | sed -n 's/^PATH=//p')"
  case "$pane_path" in
    "$CLIKAE_LIB/shims:"*) : ;;
    *) echo "pane process PATH: $pane_path"; false ;;
  esac
}

@test "launch: a CHILD of the pane process inherits the shim on PATH too" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  [ -r /proc/self/environ ] || skip "no /proc on this platform"
  _src_tmux
  local outfile="$TEST_HOME/child-path.out"
  tmux_spawn_session --session pathchildprobe97 -- \
    "bash -c 'printenv PATH > $outfile; sleep 30'"
  local i=0
  while [ ! -s "$outfile" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  tmux kill-session -t '=pathchildprobe97' 2>/dev/null || true
  [ -s "$outfile" ] || { echo "the nested child never wrote its PATH"; false; }
  case "$(cat "$outfile")" in
    "$CLIKAE_LIB/shims:"*) : ;;
    *) echo "child PATH: $(cat "$outfile")"; false ;;
  esac
}

# ── P2-1: the hop counter must not leak into the pane's own environment
# (review round 2). A real `tmux_spawn_session` whose PATH is
# shim -> a wrapper SCRIPT -> the real tmux binary: the shim's own cycle
# counter has to survive its exec into that wrapper (it might leapfrog back
# into the shim), but the wrapper has no obligation to scrub it before
# reaching the real binary — measured with `~/.local/bin/tmux` reaching a
# real server that way. If that unwitnessed client happens to be the one that
# forks a fresh server, every future pane on it is born believing it is
# already mid-cycle.

@test "launch: the hop counter never reaches the pane process, even through an intermediate wrapper script" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  [ -r /proc/self/environ ] || skip "no /proc on this platform"
  _src_tmux
  local real_tmux; real_tmux="$(command -v tmux)"
  mkdir -p "$TEST_HOME/.wrapperbin"
  local bash_bin; bash_bin="$(command -v bash)"
  cat > "$TEST_HOME/.wrapperbin/tmux" <<EOF
#!$bash_bin
exec "$real_tmux" "\$@"
EOF
  chmod +x "$TEST_HOME/.wrapperbin/tmux"
  # A wrapper script sits ahead of the real tmux; tmux_spawn_session then
  # prepends the shim ahead of THAT, giving exactly shim -> wrapper -> real.
  PATH="$TEST_HOME/.wrapperbin:$PATH"
  tmux_spawn_session --session hopsleakprobe97 -- 'sleep 30'
  local pid; pid="$(tmux list-panes -t '=hopsleakprobe97' -F '#{pane_pid}' | head -n1)"
  run bash -c "tr '\\0' '\\n' < /proc/$pid/environ"
  tmux kill-session -t '=hopsleakprobe97' 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "could not read /proc/$pid/environ: $output"; false; }
  case "$output" in
    *_CLIKAE_TMUX_SHIM_HOPS=*)
      echo "pane process inherited the hop counter:"; printf '%s\n' "$output"; false ;;
  esac
}

@test "launch: a bare kill-server run AS the pane's own process is refused (rc 86), the throwaway server survives" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  [ -r /proc/self/environ ] || skip "no /proc on this platform"
  _src_tmux
  tmux_spawn_session --session pathkillprobe97 -- 'sleep 30'
  local pid; pid="$(tmux list-panes -t '=pathkillprobe97' -F '#{pane_pid}' | head -n1)"
  local pane_path pane_tmux
  pane_path="$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^PATH=//p')"
  pane_tmux="$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^TMUX=//p')"
  [ -n "$pane_tmux" ] || { echo "premise broken: the pane process has no \$TMUX"; false; }
  # Reconstruct exactly what the pane's own process would run: its own real
  # PATH and $TMUX, nothing inherited from this bats process.
  run env -i PATH="$pane_path" TMUX="$pane_tmux" HOME="$TEST_HOME" bash -c 'tmux kill-server'
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux list-sessions -F '#{session_name}'
  tmux kill-session -t '=pathkillprobe97' 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "the throwaway server did NOT survive: $output"; false; }
  [[ "$output" == *"pathkillprobe97"* ]] || { echo "got: $output"; false; }
}

# ── P2-1: verb resolution beyond the literal string (review round 1) ───────
# tmux itself is far more permissive than an exact "kill-server"/"kill-session"
# string: it accepts an unambiguous PREFIX of a command name, a value-taking
# GLOBAL OPTION can push the verb out of argv[1], and a `\;` COMMAND LIST runs
# every segment as its own command. Each row measured as a real bypass — a
# disposable server actually killed — under the old literal check.

@test "shim: an unambiguous prefix of kill-server (kill-serv) is refused exactly like the verb" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/bypass-serv.sock"
  tmux -S "$sock" new-session -d -s bypassserv 'sleep 60'
  run env TMUX="$sock,1,0" bash "$(SHIM)" kill-serv
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "bypassserv" ] || { echo "did not survive: $output"; false; }
  tmux -S "$sock" kill-server 2>/dev/null || true
}

@test "shim: an unambiguous prefix of kill-session (kill-ses) is refused exactly like the verb" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/bypass-ses.sock"
  tmux -S "$sock" new-session -d -s bypassses 'sleep 60'
  run env TMUX="$sock,1,0" bash "$(SHIM)" kill-ses
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "bypassses" ] || { echo "did not survive: $output"; false; }
  tmux -S "$sock" kill-server 2>/dev/null || true
}

@test "shim: a value-taking global option ahead of the verb (-f /dev/null kill-server) does not hide it" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/bypass-f.sock"
  tmux -S "$sock" new-session -d -s bypassf 'sleep 60'
  run env TMUX="$sock,1,0" bash "$(SHIM)" -f /dev/null kill-server
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "bypassf" ] || { echo "did not survive: $output"; false; }
  tmux -S "$sock" kill-server 2>/dev/null || true
}

@test 'shim: a `\;` command list checks EVERY segment, not just the first' {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/bypass-list.sock"
  tmux -S "$sock" new-session -d -s bypasslist 'sleep 60'
  run env TMUX="$sock,1,0" bash "$(SHIM)" list-sessions \; kill-server
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "bypasslist" ] || { echo "did not survive: $output"; false; }
  tmux -S "$sock" kill-server 2>/dev/null || true
}

# ── P2-2: the option scan is per-SEGMENT, not per-argv (review round 2) ────
# Each row measured as a real bypass — a disposable server actually killed —
# under the old check, which scanned -S/-L/-t/-a once over the whole argv
# before the verb loop ran at all.

@test 'shim: a `;` glued onto the previous word (ls\; kill-server, no space) still ends the segment' {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/bypass-glued.sock"
  tmux -S "$sock" new-session -d -s bypassglued 'sleep 60'
  # No space before the backslash: the shell hands the shim ONE token, "ls;".
  run env TMUX="$sock,1,0" bash "$(SHIM)" ls\; kill-server
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "bypassglued" ] || { echo "did not survive: $output"; false; }
  tmux -S "$sock" kill-server 2>/dev/null || true
}

@test "shim: another command's -S (capture-pane -S <line>) does not satisfy kill-server's socket check" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/bypass-capS.sock"
  tmux -S "$sock" new-session -d -s bypasscaps 'sleep 60'
  # capture-pane's `-S -3` is a start LINE, not a socket — it belongs to a
  # DIFFERENT segment than kill-server and must not satisfy its guard.
  run env TMUX="$sock,1,0" bash "$(SHIM)" capture-pane -S -3 -p \; kill-server
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "bypasscaps" ] || { echo "did not survive: $output"; false; }
  tmux -S "$sock" kill-server 2>/dev/null || true
}

@test "shim: another command's -t (list-panes -t x) does not satisfy kill-session's target check" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/bypass-listt.sock"
  tmux -S "$sock" new-session -d -s bypasslistt 'sleep 60'
  # list-panes' `-t x` names ITS target, not kill-session's — a DIFFERENT
  # segment's -t must not satisfy kill-session's guard.
  run env TMUX="$sock,1,0" bash "$(SHIM)" list-panes -t x \; kill-session
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ] && [ "$output" = "bypasslistt" ] || { echo "did not survive: $output"; false; }
  tmux -S "$sock" kill-server 2>/dev/null || true
}

@test "shim: kill-session -t =<name> is still allowed (naming the target is the whole ask)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sock="$TEST_HOME/allowed-eqtarget.sock"
  tmux -S "$sock" new-session -d -s x 'sleep 60'
  run env TMUX="$TEST_HOME/not-the-real-one,1,0" bash "$(SHIM)" -S "$sock" kill-session -t =x
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  run tmux -S "$sock" list-sessions
  [ "$status" -ne 0 ] || { echo "the target session should be dead: $output"; false; }
}

# ── P2-2: the REFUSAL decision needs no real tmux at all (review round 1) ──
# lib/shims/tmux checks argv + $TMUX and can exit 86 before ever resolving a
# real tmux, so these run identically whether or not tmux is installed —
# unlike every test above this line, gated on `command -v tmux` because they
# also have to prove a REAL server survived or died. This is what actually
# closes the macOS CI gap: GitHub's macos bats runner ships no tmux at all,
# so ALL of the tests above (P2-1's new bypass coverage included) silently
# skipped there. These do not.

# A "real tmux" that only records what reached it, never installed as `tmux`
# anywhere a refusal should stop the call reaching it first. `#!<absolute
# path>` rather than `#!/usr/bin/env bash`: the recorder's own exec must not
# depend on the restricted PATH being handed to the shim under test.
_tg_recorder() {
  mkdir -p "$TEST_HOME/.recorderbin"
  local bash_bin; bash_bin="$(command -v bash)"
  cat > "$TEST_HOME/.recorderbin/tmux" <<EOF
#!$bash_bin
printf 'ARGV:%s\n' "\$*" >> "$TEST_HOME/recorder.log"
exit 0
EOF
  chmod +x "$TEST_HOME/.recorderbin/tmux"
}

@test "shim: kill-server is refused without ever needing a real tmux on PATH" {
  _tg_recorder
  # Absolute path for bash itself: `env PATH=<restricted> bash …` would make
  # env resolve "bash" through that SAME restricted PATH and fail to find it
  # — nothing to do with the shim under test, just env's own lookup.
  local bash_bin; bash_bin="$(command -v bash)"
  run env TMUX="$TEST_HOME/fake,1,0" PATH="$CLIKAE_LIB/shims:$TEST_HOME/.recorderbin" "$bash_bin" "$(SHIM)" kill-server
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  [ ! -e "$TEST_HOME/recorder.log" ] || { echo "reached the recorder — should have refused first"; false; }
}

@test "shim: kill-serv (bypass prefix) is refused without ever needing a real tmux on PATH" {
  _tg_recorder
  local bash_bin; bash_bin="$(command -v bash)"
  run env TMUX="$TEST_HOME/fake,1,0" PATH="$CLIKAE_LIB/shims:$TEST_HOME/.recorderbin" "$bash_bin" "$(SHIM)" kill-serv
  [ "$status" -eq 86 ] || { echo "status=$status output=$output"; false; }
  [ ! -e "$TEST_HOME/recorder.log" ] || { echo "reached the recorder — should have refused first"; false; }
}

@test "shim: an allowed call reaches whatever is on PATH with argv and PATH intact, real tmux or not" {
  _tg_recorder
  local bash_bin; bash_bin="$(command -v bash)"
  run env -u TMUX PATH="$CLIKAE_LIB/shims:$TEST_HOME/.recorderbin" "$bash_bin" "$(SHIM)" -V
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  [ -f "$TEST_HOME/recorder.log" ] || { echo "the recorder was never reached"; false; }
  grep -qF -- '-V' "$TEST_HOME/recorder.log" || { echo "argv not forwarded: $(cat "$TEST_HOME/recorder.log")"; false; }
}
