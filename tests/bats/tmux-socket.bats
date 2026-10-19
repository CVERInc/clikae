#!/usr/bin/env bats
# tests/bats/tmux-socket.bats — where the cockpit's tmux socket lives (#176).
#
# 2026-10-17, reefbox: a /tmp sweep removed /tmp/tmux-1002. The cockpit inside
# (a two-day-old `claude --resume` in a tmux session) kept running, but with
# its socket gone the board could not list it, nothing could attach to it, a
# resume of the same transcript started a SECOND engine on the same session
# id, and `clikae burn` died with "error creating /tmp/tmux-1002/default".
#
# The class is "the socket lives somewhere clikae does not own". Four parts:
#   1. the socket directory defaults to $CLIKAE_HOME/state/tmux — the same
#      home as every other state file, which no /tmp sweep reaches;
#   2. an explicit TMUX_TMPDIR (or an inherited $TMUX) is respected — this
#      suite's own isolation relies on exactly that;
#   3. the board reads BOTH the clikae socket and the legacy /tmp one, so a
#      cockpit started by an older clikae is still listed and attachable
#      until it is restarted (a tmux session cannot move between servers);
#   4. a server whose socket file was deleted is recovered: tmux re-creates
#      its socket on SIGUSR1, and clikae remembers each server's pid at birth.
#
# Every tmux here runs on a throwaway socket under $TEST_HOME. The "legacy"
# socket is pointed at a SECOND throwaway via CLIKAE_TMUX_LEGACY_SOCKET —
# never at the real /tmp/tmux-<uid>, which may host the maintainer's tanks.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src_tmux() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/live.sh"
}

# A second, independent tmux server standing in for the legacy /tmp one.
_legacy_up() {
  LEGACY_DIR="$TEST_HOME/legacy"
  mkdir -p "$LEGACY_DIR"
  env -u TMUX TMUX_TMPDIR="$LEGACY_DIR" tmux new-session -d -s "$1" 'sleep 30'
  LEGACY_SOCK="$LEGACY_DIR/tmux-$(id -u)/default"
  [ -S "$LEGACY_SOCK" ] || { echo "legacy server did not come up"; false; }
  export CLIKAE_TMUX_LEGACY_SOCKET="$LEGACY_SOCK"
}

# Every kill names its socket with -S — never a bare kill-server, which a host
# guard (and the shim under test) rightly refuses when clikae- sessions exist.
teardown() {
  if command -v tmux >/dev/null 2>&1; then
    tmux -S "$TMUX_TMPDIR/tmux-$(id -u)/default" kill-server 2>/dev/null
  fi
  [ -n "${LEGACY_SOCK:-}" ] && tmux -S "$LEGACY_SOCK" kill-server 2>/dev/null
  [ -n "${ORPHAN_SOCK:-}" ] && tmux -S "$ORPHAN_SOCK" kill-server 2>/dev/null
  [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
  return 0
}

# ── 1 + 2: where the socket goes ───────────────────────────────────────────

@test "socket dir: with no override, TMUX_TMPDIR is \$CLIKAE_HOME/state/tmux (mode 700)" {
  _src_tmux
  unset TMUX_TMPDIR
  tmux_socket_init
  [ "$TMUX_TMPDIR" = "$CLIKAE_HOME/state/tmux" ]
  [ -d "$TMUX_TMPDIR" ]
  local mode; mode="$(stat -c %a "$TMUX_TMPDIR" 2>/dev/null || stat -f %Lp "$TMUX_TMPDIR")"
  [ "$mode" = "700" ]
}

@test "socket dir: an explicit TMUX_TMPDIR is respected, not replaced" {
  _src_tmux
  export TMUX_TMPDIR="$TEST_HOME/mine"
  tmux_socket_init
  [ "$TMUX_TMPDIR" = "$TEST_HOME/mine" ]
  # And nothing was created in the default place behind the caller's back.
  [ ! -e "$CLIKAE_HOME/state/tmux" ]
}

@test "socket dir: a server born by the real binary lives under \$CLIKAE_HOME/state/tmux" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nsleep 3\n[ "$1" = run ] && : > "$2"\nexit 0\n' > "$bin/codex"
  chmod +x "$bin/codex"; PATH="$bin:$PATH"; export PATH
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  # The suite isolates via TMUX_TMPDIR; take that away so the binary decides.
  # $TMUX is already unset by helpers.bash, so the only thing left to decide
  # the socket is clikae itself.
  env -u TMUX_TMPDIR "$CLIKAE_BIN" burn codex T1 --artifact "$A" -- run "$A" &
  local burn_pid=$!
  ORPHAN_SOCK="$CLIKAE_HOME/state/tmux/tmux-$(id -u)/default"
  local i=0 seen=""
  while [ "$i" -lt 100 ]; do
    if tmux -S "$ORPHAN_SOCK" list-sessions >/dev/null 2>&1; then seen=1; break; fi
    sleep 0.1; i=$((i + 1))
  done
  wait "$burn_pid" 2>/dev/null || true
  [ -n "$seen" ] || { echo "no server appeared on $ORPHAN_SOCK"; ls -la "$CLIKAE_HOME/state" 2>&1; false; }
  # And NOT on the suite's socket — the binary did not fall back to the inherited one.
  ! tmux list-sessions >/dev/null 2>&1 || false
}

@test "socket path: tmux_socket_path follows \$TMUX first, then TMUX_TMPDIR" {
  _src_tmux
  export TMUX_TMPDIR="$TEST_HOME/tmux"
  export TMUX="$TEST_HOME/other/tmux-1/default,123,0"
  [ "$(tmux_socket_path)" = "$TEST_HOME/other/tmux-1/default" ]
  unset TMUX
  [ "$(tmux_socket_path)" = "$TEST_HOME/tmux/tmux-$(id -u)/default" ]
}

# ── 3: the board reads both sockets ────────────────────────────────────────

@test "legacy socket: the board lists a cockpit on the old socket next to the new one" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  export CLIKAE_SESS_PREFIX="clikae-"
  tmux new-session -d -s clikae-claude-new 'sleep 30'
  _legacy_up clikae-claude-old
  run live_session_names
  [ "$status" -eq 0 ]
  [[ "$output" == *"clikae-claude-new"* ]] || { echo "$output"; false; }
  [[ "$output" == *"clikae-claude-old"* ]] || { echo "missing legacy row: $output"; false; }
  # Still only OUR sessions: a hand-made one on the legacy server stays invisible.
  tmux -S "$LEGACY_SOCK" new-session -d -s theirs 'sleep 30'
  run live_session_names
  ! grep -q "theirs" <<<"$output" || false
}

@test "legacy socket: the same name on both servers is one row, the new server's" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  export CLIKAE_SESS_PREFIX="clikae-"
  _legacy_up clikae-claude-same
  sleep 1
  tmux new-session -d -s clikae-claude-same 'sleep 30'
  run live_session_names
  [ "$(grep -c "clikae-claude-same" <<<"$output")" -eq 1 ]
  local created_new created_old
  created_new="$(tmux list-sessions -F '#{session_created}' 2>/dev/null)"
  created_old="$(tmux -S "$LEGACY_SOCK" list-sessions -F '#{session_created}' 2>/dev/null)"
  [ "$created_new" != "$created_old" ] || { echo "control failed: both servers report $created_new"; false; }
  [[ "$output" == "clikae-claude-same	$created_new	"* ]] || { echo "want created=$created_new, got: $output"; false; }
}

@test "legacy socket: nothing listed twice and nothing lost when the legacy socket is the current one" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  export CLIKAE_SESS_PREFIX="clikae-"
  tmux new-session -d -s clikae-claude-only 'sleep 30'
  CLIKAE_TMUX_LEGACY_SOCKET="$(tmux_socket_path)"; export CLIKAE_TMUX_LEGACY_SOCKET
  run live_session_names
  [ "$(grep -c "clikae-claude-only" <<<"$output")" -eq 1 ]
}

@test "legacy socket: tmux_on routes a per-session command to the server that has it" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  export CLIKAE_SESS_PREFIX="clikae-"
  tmux new-session -d -s clikae-claude-new 'sleep 30'
  _legacy_up clikae-claude-old
  run tmux_on clikae-claude-old display-message -p -t =clikae-claude-old '#{socket_path}'
  [ "$status" -eq 0 ]
  [ "$output" = "$LEGACY_SOCK" ]
  run tmux_on clikae-claude-new display-message -p -t =clikae-claude-new '#{socket_path}'
  [ "$status" -eq 0 ]
  [ "$output" = "$(tmux_socket_path)" ]
  # live.sh's per-session readers go through the same door.
  tmux -S "$LEGACY_SOCK" set-option -t =clikae-claude-old: @clikae_session_id sid-old
  [ "$(live_session_id clikae-claude-old)" = "sid-old" ]
  run live_engine_alive clikae-claude-old
  [ "$status" -eq 0 ]
}

@test "legacy socket: tmux_sessv finds the cockpit on the old socket, so a launch attaches instead of spawning a twin" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  export CLIKAE_SESS_PREFIX="clikae-" CLIKAE_SESS_PREFIX_LEGACY="ck-"
  _legacy_up clikae-claude-h
  tmux_sessv claude-h
  [ "$CLIKAE_TMUX_SESS_EXISTS" -eq 1 ]
  [ "$CLIKAE_TMUX_SESS" = "clikae-claude-h" ]
  # Negative control: a name on neither server is still "not there".
  tmux_sessv claude-nowhere
  [ "$CLIKAE_TMUX_SESS_EXISTS" -eq 0 ]
}

# ── 4: a server whose socket was swept ─────────────────────────────────────

@test "orphan: a server born through clikae is on record (pid + socket)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  export CLIKAE_SESS_PREFIX="clikae-"
  tmux_spawn_session --session clikae-claude-rec -- 'sleep 30'
  local rec="$CLIKAE_HOME/state/tmux/servers"
  [ -f "$rec" ] || { echo "no record at $rec"; false; }
  local pid; pid="$(tmux display-message -p '#{pid}')"
  grep -q "^$pid	$(tmux_socket_path)$" "$rec" || { cat "$rec"; false; }
}

@test "orphan: a recorded server whose socket is gone gets it back, and the board sees it again" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  export CLIKAE_SESS_PREFIX="clikae-"
  tmux_spawn_session --session clikae-claude-orphan -- 'sleep 30'
  local sock; sock="$(tmux_socket_path)"
  ORPHAN_SOCK="$sock"
  # The sweep: the whole socket directory, as on reefbox.
  rm -rf "$(dirname "$sock")"
  ! tmux list-sessions >/dev/null 2>&1 || false
  run live_session_names
  [[ "$output" == *"clikae-claude-orphan"* ]] || { echo "not recovered: $output"; false; }
  [ -S "$sock" ]
  tmux has-session -t =clikae-claude-orphan
}

@test "orphan: the record of a dead server is dropped, never signalled" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  mkdir -p "$CLIKAE_HOME/state/tmux"
  # A pid that has certainly exited.
  sh -c 'exit 0' & local dead=$!; wait "$dead" || true
  printf '%s\t%s\n' "$dead" "$TEST_HOME/never/default" > "$CLIKAE_HOME/state/tmux/servers"
  run tmux_rescue_orphans
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_HOME/never" ]
  [ ! -s "$CLIKAE_HOME/state/tmux/servers" ]
}

@test "orphan: a live pid that is not tmux is left alone" {
  _src_tmux
  mkdir -p "$CLIKAE_HOME/state/tmux"
  sleep 30 & local other=$!
  printf '%s\t%s\n' "$other" "$TEST_HOME/never/default" > "$CLIKAE_HOME/state/tmux/servers"
  run tmux_rescue_orphans
  kill "$other" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_HOME/never" ]
}

@test "orphan: inside a cockpit whose socket vanished, \$TMUX alone is enough to recover it" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  tmux new-session -d -s clikae-claude-inside 'sleep 30'
  local sock pid; sock="$(tmux_socket_path)"; pid="$(tmux display-message -p '#{pid}')"
  ORPHAN_SOCK="$sock"
  rm -f "$sock"
  # No record file at all — the cockpit predates this release.
  rm -f "$CLIKAE_HOME/state/tmux/servers"
  TMUX="$sock,$pid,0" tmux_rescue_orphans
  [ -S "$sock" ]
  tmux has-session -t =clikae-claude-inside
}
