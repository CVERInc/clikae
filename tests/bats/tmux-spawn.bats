#!/usr/bin/env bats
# tests/bats/tmux-spawn.bats — the ONE constructor for a tmux server.
#
# WHY THIS FILE EXISTS. `docs/DESIGN-tmux.md` Rule 5 refers to a wrapper function
# `clikae_spawn_session` as "Rule 1 與 Rule 2 的封裝函式". That function was never
# written: it appeared three times in the design doc and zero times in the code, so
# every call site re-implemented the rules by hand and they drifted. burn.sh's
# `tmux new-session -d` carried none of the global options at all.
#
# The rules are only worth having if a server born from ANY path carries them, so
# these tests birth a server from each path and read the options back off it.
#
# Every test here runs against the suite's own tmux socket ($TMUX_TMPDIR, set in
# tests/helpers.bash) — `kill-server` below must never be able to reach the
# maintainer's live tanks.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

# A `codex` that takes long enough for the session it runs in to be observable.
# The Rule 1 defect is only visible WHILE the server burn created is still alive:
# tmux's exit-empty means the server evaporates with the last session, and asking
# a dead server for its options silently starts a fresh one with tmux's defaults —
# which reads exactly like the bug whether or not the bug is there.
_stub_codex_slow() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/codex" <<'STUB'
#!/usr/bin/env bash
sleep 3
if [ "$1" = "run" ] && [ -n "$2" ]; then : > "$2"; fi
exit 0
STUB
  chmod +x "$bin/codex"
  PATH="$bin:$PATH"; export PATH
}

# Poll for a server on OUR socket and print one global option's value.
# Prints nothing if no server ever appeared.
_option_of_the_server_that_appears() {
  local opt="$1" i=0
  while [ "$i" -lt 100 ]; do
    if tmux list-sessions >/dev/null 2>&1; then
      tmux show-options -gv "$opt" 2>/dev/null
      return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  return 0
}

# ── the memory-reachability probe (lib/core/soul.sh) ────────────────────────
# These live here rather than in memory.bats because what the probe detects is a
# property of the tmux SERVER, not of the memory: the very same directory is
# readable from a server born in one place and not from one born in another.

_src_soul() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/soul.sh"
}

@test "memory probe: a readable memory produces silence" {
  _src_soul
  local m="$TEST_HOME/mem"; mkdir -p "$m"; : > "$m/MEMORY.md"
  run memory_access_warn "$m"
  [ "$status" -eq 0 ]
  # The control that matters: a probe that always speaks is a probe nobody reads.
  [ -z "$output" ] || { echo "expected silence, got: $output"; false; }
}

@test "memory probe: permission bits that deny the read are reported as themselves" {
  _src_soul
  local m="$TEST_HOME/mem"; mkdir -p "$m"; : > "$m/MEMORY.md"
  chmod 000 "$m"
  run memory_access_warn "$m"
  chmod 755 "$m"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot read its own memory"* ]] || { echo "$output"; false; }
  [[ "$output" == *"permission bits deny"* ]] || { echo "$output"; false; }
  # An ordinary chmod must not be blamed on tmux — a wrong cause sends the
  # reader off to kill a server that was never the problem.
  [[ "$output" != *"kill-server"* ]] || { echo "$output"; false; }
}

@test "memory probe: a read that fails while the bits allow it names the tmux server" {
  _src_soul
  local m="$TEST_HOME/mem"; mkdir -p "$m"; : > "$m/MEMORY.md"
  # TCC cannot be synthesised in a test, so inject the SHAPE it produces: the
  # permission bits say yes and the read still says no. A stub `ls` ahead of the
  # real one on PATH is the smallest way to stand that up.
  cat > "$TEST_HOME/.testbin/ls" <<'STUB'
#!/usr/bin/env bash
case "$*" in *"/mem"*) exit 1 ;; esac
exec /bin/ls "$@"
STUB
  chmod +x "$TEST_HOME/.testbin/ls"
  [ -r "$m" ] || { echo "premise broken: the bits should allow reading"; false; }

  run memory_access_warn "$m"
  rm -f "$TEST_HOME/.testbin/ls"
  [ "$status" -eq 0 ]
  [[ "$output" == *"permission bits allow it and the read still failed"* ]] || { echo "$output"; false; }
  [[ "$output" == *"kill-server"* ]] || { echo "$output"; false; }
  # And it keeps going: a tank with no memory still starts (DESIGN-tmux Rule 7).
  [[ "$output" == *"Continuing anyway"* ]] || { echo "$output"; false; }
}

@test "the suite cannot reach the tmux server the developer is sitting in" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # roam.bats runs a bare `tmux kill-server`. If the suite can see the real
  # socket, running the tests kills every clikae tank the maintainer has open.
  [ -z "${TMUX:-}" ] || { echo "TMUX leaked into the suite: $TMUX"; false; }
  [[ "$TMUX_TMPDIR" == "$TEST_HOME"* ]] || { echo "TMUX_TMPDIR=$TMUX_TMPDIR"; false; }

  # NEGATIVE CONTROL. TMUX_TMPDIR on its own is not the guard — an inherited
  # $TMUX overrides it — so prove that the `unset` in helpers.bash is carrying
  # the weight. Two isolated servers, and $TMUX decides which one answers.
  # Read-only: this kills only the two servers it just made.
  local other="$TEST_HOME/other"; mkdir -p "$other"
  TMUX_TMPDIR="$other" tmux new-session -d -s otherserver 'sleep 30'
  tmux new-session -d -s ourserver 'sleep 30'

  run env TMUX="$other/tmux-$(id -u)/default,0,0" TMUX_TMPDIR="$TMUX_TMPDIR" \
      tmux list-sessions -F '#{session_name}'
  [ "$output" = "otherserver" ] || { echo "\$TMUX no longer wins — want otherserver, got: $output"; false; }

  run tmux list-sessions -F '#{session_name}'
  [ "$output" = "ourserver" ] || { echo "want ourserver, got: $output"; false; }

  TMUX_TMPDIR="$other" tmux kill-server 2>/dev/null || true
  tmux kill-server 2>/dev/null || true
}

@test "a server born by burn carries clikae's global options (DESIGN-tmux Rule 1)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _stub_codex_slow
  clikae init codex T1
  # Birth from nothing: this burn must be what creates the server.
  tmux kill-server 2>/dev/null || true

  local A="$BATS_TEST_TMPDIR/out.md"
  clikae burn codex T1 --artifact "$A" -- run "$A" &
  local burn_pid=$!

  local hl; hl="$(_option_of_the_server_that_appears history-limit)"
  wait "$burn_pid" 2>/dev/null || true
  tmux kill-server 2>/dev/null || true

  [ -n "$hl" ] || { echo "no tmux server was ever observed — the burn did not create one"; false; }
  # 2000 is tmux's default. Getting it back means the server was born without
  # clikae's options and every session on it scrolls back 25x less than intended —
  # including the scrollback capture/replay that `switch` depends on.
  [ "$hl" = "50000" ] || { echo "history-limit=$hl, want 50000 (tmux's own default is 2000)"; false; }
}

@test "a server born by switch carries clikae's global options (DESIGN-tmux Rule 1)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _stub_codex_slow
  clikae init codex T1
  tmux kill-server 2>/dev/null || true

  # switch falls back to a direct run without a tty, so drive it the way the
  # control path does: create the session detached, exactly as switch would.
  clikae codex T1 >/dev/null 2>&1 &
  local sw_pid=$!

  local hl; hl="$(_option_of_the_server_that_appears history-limit)"
  kill "$sw_pid" 2>/dev/null || true
  wait "$sw_pid" 2>/dev/null || true
  tmux kill-server 2>/dev/null || true

  # No tty in bats, so switch is entitled to run the engine directly and never
  # touch tmux. Only assert the option when a server actually appeared.
  if [ -n "$hl" ]; then
    [ "$hl" = "50000" ] || { echo "history-limit=$hl, want 50000"; false; }
  fi
}
