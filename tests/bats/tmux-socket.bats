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
  # Processes this test started itself, by pid — never a name match.
  local p
  for p in ${OWN_PIDS:-}; do kill "$p" 2>/dev/null; done
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
  # pid, its start time (the incarnation — round 2), socket.
  grep -q "^$pid	$(_lstart "$pid")	$(tmux_socket_path)$" "$rec" || { cat "$rec"; false; }
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
  local sock; sock="$(tmux_socket_path)"
  ORPHAN_SOCK="$sock"
  # The rescue runs INSIDE the cockpit, as a `clikae` typed in its pane would:
  # $TMUX is the server's own, and the server is this shell's ancestor — the
  # only proof there is for a pid that has no record (round 2, finding 1).
  cat > "$TEST_HOME/inside.sh" <<EOF
while [ -S '$sock' ]; do sleep 0.05; done
. '$CLIKAE_TEST_ROOT/lib/core/log.sh'
. '$CLIKAE_TEST_ROOT/lib/core/tmux.sh'
tmux_rescue_orphans
: > '$TEST_HOME/rescued'
sleep 30
EOF
  tmux new-session -d -s clikae-claude-inside "bash '$TEST_HOME/inside.sh'"
  # No record file at all — the cockpit predates this release.
  rm -f "$CLIKAE_HOME/state/tmux/servers"
  rm -f "$sock"
  local i=0
  while [ "$i" -lt 100 ] && [ ! -e "$TEST_HOME/rescued" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$TEST_HOME/rescued" ] || { echo "the pane never ran the rescue"; false; }
  [ -S "$sock" ]
  tmux has-session -t =clikae-claude-inside
}

# ── round 2 (PR #181 review): two physical servers, every path ─────────────
#
# The class: there are TWO tmux servers a cockpit can be on (the clikae one
# under $CLIKAE_HOME/state/tmux and the pre-#176 /tmp one), and the caller can
# be sitting on either. Every path — listing, routing, the launch decision,
# the inside-tmux switch, the rescue — has to work whichever one that is.

# _lstart <pid> -> the process's start time as ps prints it (its incarnation).
_lstart() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }

@test "rescue: a live non-tmux process named tmux-helper is never signalled" {
  _src_tmux
  cd "$TEST_HOME"
  mkdir -p "$TEST_HOME/fakebin" "$CLIKAE_HOME/state/tmux"
  cp "$(command -v sleep)" "$TEST_HOME/fakebin/tmux-helper"
  "$TEST_HOME/fakebin/tmux-helper" 30 & local other=$!
  OWN_PIDS="$other"
  sleep 0.2
  printf '%s\t%s\t%s\n' "$other" "$(_lstart "$other")" "$TEST_HOME/never/default" \
    > "$CLIKAE_HOME/state/tmux/servers"
  run tmux_rescue_orphans
  [ "$status" -eq 0 ]
  # SIGUSR1's default action is to terminate: alive afterwards = not signalled.
  kill -0 "$other" 2>/dev/null || { echo "tmux-helper ($other) was signalled"; false; }
  [ ! -e "$TEST_HOME/never" ]
}

@test "rescue: a recorded pid now held by a different incarnation is never signalled" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  cd "$TEST_HOME"
  local d sock pid; d="$(mktemp -d "$TEST_HOME/reuse.XXXXXX")"; sock="$d/s"
  tmux -S "$sock" new-session -d -s clikae-claude-reuse 'sleep 30'
  pid="$(tmux -S "$sock" display-message -p '#{pid}')"
  OWN_PIDS="$pid"
  mkdir -p "$CLIKAE_HOME/state/tmux"
  # The pid on record is right, the incarnation is not: what a reused pid
  # looks like from here. Same uid, same comm — only the start time differs.
  printf '%s\t%s\t%s\n' "$pid" "Thu Jan  1 00:00:00 1970" "$sock" > "$CLIKAE_HOME/state/tmux/servers"
  rm -f "$sock"
  run tmux_rescue_orphans
  [ "$status" -eq 0 ]
  # A signalled tmux server would have re-created its socket.
  [ ! -e "$sock" ] || { echo "the server was signalled: socket is back"; false; }
  kill -0 "$pid"
  ! grep -q "^$pid	" "$CLIKAE_HOME/state/tmux/servers" || false
}

@test "rescue: \$TMUX names a server we are not inside -> not signalled (no record, no proof)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  local d sock pid; d="$(mktemp -d "$TEST_HOME/notours.XXXXXX")"; sock="$d/s"
  tmux -S "$sock" new-session -d -s x 'sleep 30'
  pid="$(tmux -S "$sock" display-message -p '#{pid}')"
  OWN_PIDS="$pid"
  rm -f "$sock"
  rm -f "$CLIKAE_HOME/state/tmux/servers"
  # An inherited $TMUX outlives its server; the pid in it can be anyone's now.
  TMUX="$sock,$pid,0" tmux_rescue_orphans
  [ ! -e "$sock" ] || { echo "signalled a server this process is not inside"; false; }
}

# _fake_server <var> — a live process whose comm is exactly `tmux` (a copy of
# sleep under that name: SIGUSR1 kills it, so "alive afterwards" is "not
# signalled"), recorded with its real start time and a socket that is gone.
# No tmux server involved; fakebin goes first in PATH only for the rescue,
# which asks `command -v tmux` and never runs it.
_fake_server() {
  mkdir -p "$TEST_HOME/fakebin" "$CLIKAE_HOME/state/tmux"
  [ -x "$TEST_HOME/fakebin/tmux" ] || cp "$(command -v sleep)" "$TEST_HOME/fakebin/tmux"
  # _fs_ names: printf -v below must not land on a local of the caller's name.
  "$TEST_HOME/fakebin/tmux" 30 & local _fs_pid=$!
  OWN_PIDS="${OWN_PIDS:-} $_fs_pid"
  local _fs_i=0
  while [ "$_fs_i" -lt 50 ] && [ -z "$(_lstart "$_fs_pid")" ]; do sleep 0.05; _fs_i=$((_fs_i + 1)); done
  printf '%s\t%s\t%s\n' "$_fs_pid" "$(_lstart "$_fs_pid")" "$TEST_HOME/swept-$_fs_pid/default" \
    >> "$CLIKAE_HOME/state/tmux/servers"
  printf -v "$1" '%s' "$_fs_pid"
}

# _signalled <pid> -> 0 once <pid> has died (bounded wait: the rescue's kill
# is synchronous, the death that follows is not).
_signalled() {
  local i=0
  while [ "$i" -lt 40 ] && kill -0 "$1" 2>/dev/null; do sleep 0.05; i=$((i + 1)); done
  ! kill -0 "$1" 2>/dev/null
}

@test "rescue: a recorded tmux whose uid is not ours is never signalled (and ours is — the control)" {
  _src_tmux
  local mine theirs
  _fake_server mine
  PATH="$TEST_HOME/fakebin:$PATH" tmux_rescue_orphans
  _signalled "$mine" || { echo "control: our own recorded server ($mine) was not signalled"; false; }
  rm -f "$CLIKAE_HOME/state/tmux/servers"
  # The same process shape — comm tmux, start time on record — but the uid
  # differs. A process of another uid is out of a test's reach, so the
  # comparison's other side moves instead: CLIKAE_TMUX_UID is what the check
  # compares ps's uid against.
  _fake_server theirs
  CLIKAE_TMUX_UID=$(( $(id -u) + 1 )) PATH="$TEST_HOME/fakebin:$PATH" tmux_rescue_orphans
  ! _signalled "$theirs" || { echo "a server of another uid ($theirs) was signalled"; false; }
  [ ! -e "$TEST_HOME/swept-$theirs" ] || { echo "made the socket dir of another uid's server"; false; }
}

@test "rescue: identity is checked again after the socket dir is made, right before the kill" {
  _src_tmux
  local pid
  _fake_server pid
  # What changes between the check and the kill is out of a test's reach (a
  # pid recycled in that gap), so the mkdir in the gap makes the identity
  # answer change instead: after it, the process no longer passes as ours.
  # shellcheck disable=SC2034  # read by _tmux_is_our_server, sourced above
  mkdir() {
    case "$*" in *"/swept-$pid"*) CLIKAE_TMUX_UID=$(( $(id -u) + 1 )) ;; esac
    command mkdir "$@"
  }
  PATH="$TEST_HOME/fakebin:$PATH" tmux_rescue_orphans
  unset -f mkdir
  [ -d "$TEST_HOME/swept-$pid" ] || { echo "control: the rescue never reached the socket dir"; false; }
  ! _signalled "$pid" || { echo "signalled on an identity checked before the mkdir ($pid)"; false; }
}

@test "record: recording the same server twice leaves one line" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  tmux new-session -d -s clikae-claude-twice 'sleep 30'
  tmux_server_record
  tmux_server_record
  local pid; pid="$(tmux display-message -p '#{pid}')"
  [ "$(grep -c "^$pid	" "$CLIKAE_HOME/state/tmux/servers")" -eq 1 ] \
    || { cat "$CLIKAE_HOME/state/tmux/servers"; false; }
}

# ── round 3: the record's lock (PR #181 r2 review, P2) ─────────────────────
#
# _tmux_rec_update is read-modify-write. Its awk is the read; the barriers
# below split that awk in two — the snapshot is taken, then held until the
# test says go — so "a writer is between its read and its rename" is a state
# the test puts a writer in, not one it hopes the scheduler produces.

# _gate_wait_for <file> — wait (bounded, a deadlock guard only) for a marker.
_gate_wait_for() {
  local n=0
  while [ ! -e "$1" ] && [ "$n" -lt 400 ]; do command sleep 0.05; n=$((n + 1)); done
  [ -e "$1" ]
}

# _gated_awk — in this shell and its subshells, the record's awk (and only
# it) reads its snapshot, drops "$GATE/read.$GATE_ID", runs _gate_hold, then
# writes the snapshot out. Set GATE, GATE_ID and define _gate_hold first.
_gated_awk() {
  awk() {
    case "$*" in *CLIKAE_TMUX_DROP*) ;; *) command awk "$@"; return ;; esac
    command awk "$@" > "$GATE/buf.$GATE_ID"
    : > "$GATE/read.$GATE_ID"
    _gate_hold
    cat "$GATE/buf.$GATE_ID"
  }
}

# _rec_lock <rec> -> the lock path (the round-2 code had no helper: its
# `$rec.lock` directory is the fallback, so these tests run red on it).
_rec_lock() { _tmux_rec_lock_path 2>/dev/null || printf '%s.lock\n' "$1"; }

@test "record lock: a writer that times out never steals a LIVE holder's lock (no tmux)" {
  _src_tmux
  local dir="$CLIKAE_HOME/state/tmux"; mkdir -p "$dir"
  local rec="$dir/servers"
  printf '1\tL1\t/s1\n' > "$rec"
  GATE="$(mktemp -d "$TEST_HOME/gate.XXXXXX")"
  # A takes the lock, reads {1}, and is held there — past B's whole timeout.
  _gate_hold() { _gate_wait_for "$GATE/go"; }
  ( GATE_ID=A; _gated_awk; _tmux_rec_update "" $'2\tL2\t/s2' ) & local a=$!
  OWN_PIDS="$a"
  _gate_wait_for "$GATE/read.A" || { echo "control: A never reached its read"; false; }
  local lock; lock="$(_rec_lock "$rec")"
  # B: its fifty 0.1s waits made instant, so the timeout arrives while A is
  # alive and mid-update — the review's suspended writer, on purpose.
  local out
  out="$( sleep() { :; }; _tmux_rec_update "" $'3\tL3\t/s3' 2>&1 )"
  local a_lock_kept=0
  { [ -e "$lock" ] || [ -L "$lock" ]; } && a_lock_kept=1
  : > "$GATE/go"
  wait "$a" || true
  grep -q '^1	' "$rec" && grep -q '^2	' "$rec" || { echo "A's update lost:"; cat "$rec"; false; }
  if ! grep -q '^3	' "$rec"; then
    [[ "$out" == *"not updated"* ]] \
      || { echo "B's record lost and nothing said so (B printed: $out)"; cat "$rec"; false; }
  fi
  [ "$a_lock_kept" -eq 1 ] || { echo "B removed A's live lock"; false; }
  # A released its own lock on the way out.
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || { ls -la "$dir"; false; }
}

@test "record lock: a holder's cleanup removes only its own lock, never a successor's" {
  _src_tmux
  local dir="$CLIKAE_HOME/state/tmux"; mkdir -p "$dir"
  local rec="$dir/servers"
  : > "$rec"
  GATE="$(mktemp -d "$TEST_HOME/gate.XXXXXX")"
  local lock; lock="$(_rec_lock "$rec")"
  # While A is between read and rename, its lock is taken over: A's moved
  # aside and a successor's planted at the path, the same kind of entry.
  _gate_hold() {
    if [ -L "$lock" ]; then
      mv "$lock" "$GATE/a-lock" && ln -s '1|successor|tok' "$lock"
    else
      mv "$lock" "$GATE/a-lock" && mkdir "$lock"
    fi
  }
  ( GATE_ID=A; _gated_awk; _tmux_rec_update "" $'2\tL2\t/s2' )
  [ -e "$GATE/a-lock" ] || [ -L "$GATE/a-lock" ] || { echo "control: A held no lock to move"; false; }
  [ -e "$lock" ] || [ -L "$lock" ] || { echo "A's cleanup removed the successor's lock"; false; }
}

@test "record lock: a lock whose holder is dead is recovered, and the update lands" {
  _src_tmux
  local dir="$CLIKAE_HOME/state/tmux"; mkdir -p "$dir"
  local rec="$dir/servers"
  printf '1\tL1\t/s1\n' > "$rec"
  sh -c 'exit 0' & local dead=$!; wait "$dead" || true
  local lock; lock="$(_tmux_rec_lock_path)"
  ln -s "$dead|Thu Jan  1 00:00:00 1970|tok" "$lock"
  local out
  out="$( sleep() { :; }; _tmux_rec_update "" $'2\tL2\t/s2' 2>&1 )"
  grep -q '^2	' "$rec" || { echo "not recovered (printed: $out)"; cat "$rec"; false; }
  grep -q '^1	' "$rec"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || { echo "lock left behind"; ls -la "$dir"; false; }
}

@test "record: concurrent recorders and a rescue lose no server (barrier: every writer reads before any writes, unless serialized)" {
  command -v python3 >/dev/null 2>&1 || skip "python3 needed to make a socket file"
  _src_tmux
  local dir="$CLIKAE_HOME/state/tmux"; mkdir -p "$dir"
  local rec="$dir/servers"
  # One socket file every record points at, so the rescue leaves them all be.
  local shared_sock; shared_sock="$(mktemp -d "$TEST_HOME/sock.XXXXXX")/s"
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$shared_sock"
  [ -S "$shared_sock" ] || { echo "control: no socket file"; false; }
  # Eight live "servers": copies of sleep under the name tmux, our own pids.
  mkdir -p "$TEST_HOME/fakebin"
  cp "$(command -v sleep)" "$TEST_HOME/fakebin/tmux"
  local -a pids=(); local i p n=8
  for i in $(seq 1 "$n"); do "$TEST_HOME/fakebin/tmux" 30 & pids+=($!); done
  OWN_PIDS="${pids[*]}"
  # And one dead one on record, which the rescue drops — making it a writer too.
  sh -c 'exit 0' & local dead=$!; wait "$dead" || true
  printf '%s\t%s\t%s\n' "$dead" "Thu Jan  1 00:00:00 1970" "$shared_sock" > "$rec"
  GATE="$(mktemp -d "$TEST_HOME/gate.XXXXXX")"
  local lock; lock="$(_tmux_rec_lock_path)"
  # The barrier: a writer that has read waits until all n+1 writers have
  # read — unless the lock is held, i.e. by itself, i.e. the writes are
  # serialized and the others cannot be reading. Without the lock every
  # writer reads the same {dead} snapshot before any rename: all but the
  # last rename are lost, on every run.
  _gate_hold() {
    local w=0 f c
    while [ "$w" -lt 400 ]; do
      [ -e "$lock" ] || [ -L "$lock" ] && return 0
      c=0; for f in "$GATE"/read.*; do [ -e "$f" ] && c=$((c + 1)); done
      [ "$c" -ge $((n + 1)) ] && return 0
      command sleep 0.02; w=$((w + 1))
    done
  }
  local -a jobs=()
  for p in "${pids[@]}"; do
    (
      GATE_ID="$p"; _gated_awk
      # Stand-in for the server answering "who are you": this pid, that socket.
      # (Not named $sock: the stub runs inside tmux_server_record, whose own
      # `local sock` would shadow it — bash scope is dynamic.)
      tmux() {
        case "$*" in
          *'#{pid}'*) echo "$p" ;;
          *'#{socket_path}'*) echo "$shared_sock" ;;
          *) command tmux "$@" ;;
        esac
      }
      tmux_server_record
    ) & jobs+=($!)
  done
  # fakebin first: the rescue only asks `command -v tmux`, never runs it.
  ( GATE_ID=rescue; _gated_awk; PATH="$TEST_HOME/fakebin:$PATH" tmux_rescue_orphans ) & jobs+=($!)
  for p in "${jobs[@]}"; do wait "$p" || true; done
  # Control: every writer really went through the gated read.
  local c=0 f
  for f in "$GATE"/read.*; do [ -e "$f" ] && c=$((c + 1)); done
  [ "$c" -eq $((n + 1)) ] || { echo "control: $c of $((n + 1)) writers read"; false; }
  local missing=""
  for p in "${pids[@]}"; do grep -q "^$p	" "$rec" || missing="$missing $p"; done
  [ -z "$missing" ] || { echo "lost:$missing"; cat "$rec"; false; }
  ! grep -q "^$dead	" "$rec" || { echo "the rescue's drop was lost"; cat "$rec"; false; }
  [ "$(wc -l < "$rec" | tr -d ' ')" -eq "$n" ] || { cat "$rec"; false; }
  # No temp file or lock left behind by any writer.
  for f in "$dir"/*; do
    case "${f##*/}" in servers|tmux-*) ;; *) echo "left behind: $f"; false ;; esac
  done
}

@test "endpoints: inside an OLD-server cockpit, the board and the launch still find the new server" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  export CLIKAE_SESS_PREFIX="clikae-" CLIKAE_SESS_PREFIX_LEGACY="ck-"
  tmux new-session -d -s clikae-claude-newb 'sleep 30'
  local home; home="$(tmux_socket_path)"
  _legacy_up clikae-claude-olda
  local lpid; lpid="$(tmux -S "$LEGACY_SOCK" display-message -p '#{pid}')"
  # Cockpit A is on the /tmp server and this shell is inside it.
  export TMUX="$LEGACY_SOCK,$lpid,0"
  run live_session_names
  [[ "$output" == *"clikae-claude-olda"* ]] || { echo "$output"; false; }
  [[ "$output" == *"clikae-claude-newb"* ]] || { echo "new server hidden: $output"; false; }
  run tmux_on clikae-claude-newb display-message -p -t =clikae-claude-newb '#{socket_path}'
  [ "$output" = "$home" ]
  tmux_sessv claude-newb
  [ "$CLIKAE_TMUX_SESS_EXISTS" -eq 1 ]
  [ "$CLIKAE_TMUX_SESS" = "clikae-claude-newb" ]
  [ "$CLIKAE_TMUX_SESS_SOCK" = "$home" ]
  # Current server first: a name on both resolves to the one $TMUX is on.
  tmux -S "$LEGACY_SOCK" new-session -d -s clikae-claude-newb 'sleep 30'
  tmux_sessv claude-newb
  [ "$CLIKAE_TMUX_SESS_SOCK" = "$LEGACY_SOCK" ]
}

@test "launch: tmux_sessv rescues a swept server BEFORE deciding the session is not there" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  export CLIKAE_SESS_PREFIX="clikae-"
  tmux_spawn_session --session clikae-claude-direct -- 'sleep 30'
  local sock; sock="$(tmux_socket_path)"
  ORPHAN_SOCK="$sock"
  rm -rf "$(dirname "$sock")"
  # No board in between: straight to the launch decision.
  tmux_sessv claude-direct
  [ "$CLIKAE_TMUX_SESS_EXISTS" -eq 1 ] || { echo "would spawn a twin"; false; }
  [ -S "$sock" ]
}

# Shared by the two binary-level cases: a codex tank whose engine leaves a
# mark if it is ever started, and no first-run question to block a pty.
_codex_tank_marking() {
  local bin="$TEST_HOME/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\n: > "%s/engine-started"\nsleep 30\n' "$TEST_HOME" > "$bin/codex"
  chmod +x "$bin/codex"; PATH="$bin:$PATH"; export PATH
  clikae init codex T1 >/dev/null
  printf 'off\n' > "$CLIKAE_HOME/wake-on-reset"
}

@test "launch: direct \`clikae codex T1\` after a sweep reaches the live cockpit, no twin" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  command -v python3 >/dev/null 2>&1 || skip "python3 needed for a pty"
  _src_tmux
  _codex_tank_marking
  # The cockpit, born through clikae (so it is on record). Its "engine" ends
  # on its own so the attach below returns — late enough to outlive the
  # launch's own startup, which a 3s one did not.
  tmux_spawn_session --session clikae-codex-T1 -- 'sleep 10'
  local sock; sock="$(tmux_socket_path)"
  ORPHAN_SOCK="$sock"
  rm -rf "$(dirname "$sock")"
  run _pty_run "$CLIKAE_BIN" codex T1
  [ ! -e "$TEST_HOME/engine-started" ] || { echo "a second engine was started: $output"; false; }
}

@test "switch: inside a cockpit on one server, launching a tank whose cockpit is on the OTHER lands there, no twin" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  command -v python3 >/dev/null 2>&1 || skip "python3 needed for a pty"
  _src_tmux
  _codex_tank_marking
  local home; home="$(tmux_socket_path)"
  # The tank's cockpit lives on the /tmp (legacy) server…
  _legacy_up clikae-codex-T1
  # …and the human is attached to a cockpit on the clikae server, where they
  # type `clikae codex T1`.
  local go="$TEST_HOME/go"
  tmux new-session -d -s outer -x 80 -y 24 \
    "while [ ! -e '$go' ]; do sleep 0.1; done; '$CLIKAE_BIN' codex T1; sleep 30"
  _pty_run tmux -S "$home" attach -t =outer >/dev/null 2>&1 & OWN_PIDS="$!"
  local i=0
  while [ "$i" -lt 50 ] && [ -z "$(tmux list-clients -t =outer 2>/dev/null)" ]; do sleep 0.1; i=$((i + 1)); done
  [ -n "$(tmux list-clients -t =outer 2>/dev/null)" ] || { echo "control: no client on outer"; false; }
  : > "$go"
  i=0
  while [ "$i" -lt 100 ] && [ -z "$(tmux -S "$LEGACY_SOCK" list-clients -t =clikae-codex-T1 2>/dev/null)" ]; do
    sleep 0.1; i=$((i + 1))
  done
  [ -n "$(tmux -S "$LEGACY_SOCK" list-clients -t =clikae-codex-T1 2>/dev/null)" ] \
    || { echo "never landed in the existing cockpit"; tmux capture-pane -p -t =outer: 2>&1; false; }
  ! tmux has-session -t =clikae-codex-T1 2>/dev/null || { echo "twin on the clikae server"; false; }
  [ ! -e "$TEST_HOME/engine-started" ] || { echo "a second engine was started"; false; }
}
