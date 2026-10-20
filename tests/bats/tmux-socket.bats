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
  # Naming the place creates nothing; the writer makes it, 0700.
  [ ! -e "$TMUX_TMPDIR" ]
  _tmux_ensure_socket_dir
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

# _lstart <pid> -> the process's start time as ps prints it (its incarnation).
_lstart() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }

# Records (round 4): one file per server under servers.d. Rounds 1-3 kept one
# shared file, state/tmux/servers; these helpers seed and read whichever the
# code under test has, so a test run against round-3 code goes red on what it
# asserts, not on a missing directory.
_rec_d() { printf '%s\n' "$CLIKAE_HOME/state/tmux/servers.d"; }

# _seed <pid> <lstart> <sock> — put a server on record, as the code would.
_seed() {
  if declare -F _tmux_rec_write >/dev/null; then
    _tmux_rec_write "$1" "$2" "$3"
  else
    mkdir -p "$CLIKAE_HOME/state/tmux"
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$CLIKAE_HOME/state/tmux/servers"
  fi
}

# _on_record <pid> -> 0 when <pid> has a record, in either layout.
_on_record() {
  local f
  for f in "$(_rec_d)/$1".*; do [ -f "$f" ] && return 0; done
  grep -q "^$1	" "$CLIKAE_HOME/state/tmux/servers" 2>/dev/null
}

# _records -> every record line, either layout (for failure output and greps).
_records() {
  local f
  for f in "$(_rec_d)"/* "$CLIKAE_HOME/state/tmux/servers"; do
    [ -f "$f" ] && cat "$f"
  done
  return 0
}

# _clear_records — no record of any kind, as on a machine before this release.
_clear_records() { rm -rf "$(_rec_d)" "$CLIKAE_HOME/state/tmux/servers"; }

# _sockfile <var> — a real socket file nobody listens on: a record pointing at
# it has its socket, so the rescue never signals that server.
_sockfile() {
  local _sf; _sf="$(mktemp -d "$TEST_HOME/sock.XXXXXX")/s"
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$_sf"
  [ -S "$_sf" ] || { echo "control: no socket file at $_sf"; return 1; }
  printf -v "$1" '%s' "$_sf"
}

# _fake_tmux_proc <var> — a live process whose comm is exactly `tmux` (a copy
# of sleep under that name: SIGUSR1 kills it, so "alive afterwards" is "not
# signalled"). Waits until ps can see its start time.
_fake_tmux_proc() {
  mkdir -p "$TEST_HOME/fakebin"
  [ -x "$TEST_HOME/fakebin/tmux" ] || cp "$(command -v sleep)" "$TEST_HOME/fakebin/tmux"
  # _ft_ names: printf -v below must not land on a local of the caller's name.
  "$TEST_HOME/fakebin/tmux" 30 & local _ft_pid=$!
  OWN_PIDS="${OWN_PIDS:-} $_ft_pid"
  local _ft_i=0
  while [ "$_ft_i" -lt 50 ] && [ -z "$(_lstart "$_ft_pid")" ]; do sleep 0.05; _ft_i=$((_ft_i + 1)); done
  printf -v "$1" '%s' "$_ft_pid"
}

# _dead_pid <var> — a pid that has certainly exited.
_dead_pid() {
  sh -c 'exit 0' & local _dp=$!
  wait "$_dp" || true
  printf -v "$1" '%s' "$_dp"
}

@test "orphan: a server born through clikae is on record (pid + socket)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  export CLIKAE_SESS_PREFIX="clikae-"
  tmux_spawn_session --session clikae-claude-rec -- 'sleep 30'
  local pid; pid="$(tmux display-message -p '#{pid}')"
  _on_record "$pid" || { echo "no record of $pid under $(_rec_d)"; _records; false; }
  # pid, its start time (the incarnation — round 2), socket.
  _records | grep -q "^$pid	$(_lstart "$pid")	$(tmux_socket_path)$" || { _records; false; }
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
  local dead; _dead_pid dead
  _seed "$dead" "Thu Jan  1 00:00:00 1970" "$TEST_HOME/never/default"
  run tmux_rescue_orphans
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_HOME/never" ]
  ! _on_record "$dead" || { _records; false; }
}

@test "orphan: a live pid that is not tmux is left alone" {
  _src_tmux
  sleep 30 & local other=$!
  OWN_PIDS="$other"
  _seed "$other" "$(_lstart "$other")" "$TEST_HOME/never/default"
  run tmux_rescue_orphans
  [ "$status" -eq 0 ]
  kill -0 "$other" 2>/dev/null || { echo "signalled $other"; false; }
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
  # No record at all — the cockpit predates this release.
  _clear_records
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

@test "rescue: a live non-tmux process named tmux-helper is never signalled" {
  _src_tmux
  cd "$TEST_HOME"
  mkdir -p "$TEST_HOME/fakebin"
  cp "$(command -v sleep)" "$TEST_HOME/fakebin/tmux-helper"
  "$TEST_HOME/fakebin/tmux-helper" 30 & local other=$!
  OWN_PIDS="$other"
  sleep 0.2
  _seed "$other" "$(_lstart "$other")" "$TEST_HOME/never/default"
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
  # The pid on record is right, the incarnation is not: what a reused pid
  # looks like from here. Same uid, same comm — only the start time differs.
  _seed "$pid" "Thu Jan  1 00:00:00 1970" "$sock"
  rm -f "$sock"
  run tmux_rescue_orphans
  [ "$status" -eq 0 ]
  # A signalled tmux server would have re-created its socket.
  [ ! -e "$sock" ] || { echo "the server was signalled: socket is back"; false; }
  kill -0 "$pid"
  ! _on_record "$pid" || { _records; false; }
}

@test "rescue: \$TMUX names a server we are not inside -> not signalled (no record, no proof)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  local d sock pid; d="$(mktemp -d "$TEST_HOME/notours.XXXXXX")"; sock="$d/s"
  tmux -S "$sock" new-session -d -s x 'sleep 30'
  pid="$(tmux -S "$sock" display-message -p '#{pid}')"
  OWN_PIDS="$pid"
  rm -f "$sock"
  _clear_records
  # An inherited $TMUX outlives its server; the pid in it can be anyone's now.
  TMUX="$sock,$pid,0" tmux_rescue_orphans
  [ ! -e "$sock" ] || { echo "signalled a server this process is not inside"; false; }
}

# _fake_server <var> — a fake tmux process (_fake_tmux_proc) recorded with its
# real start time and a socket that is gone. No tmux server involved; fakebin
# goes first in PATH only for the rescue, which asks `command -v tmux` and
# never runs it.
_fake_server() {
  local _fs_pid
  _fake_tmux_proc _fs_pid
  _seed "$_fs_pid" "$(_lstart "$_fs_pid")" "$TEST_HOME/swept-$_fs_pid/default"
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
  _clear_records
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

@test "record: recording the same server twice leaves one record" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  tmux new-session -d -s clikae-claude-twice 'sleep 30'
  tmux_server_record
  tmux_server_record
  local pid; pid="$(tmux display-message -p '#{pid}')"
  [ "$(_records | grep -c "^$pid	")" -eq 1 ] || { _records; false; }
}

# ── round 4: one file per server, no lock (PR #181 r3 review, P2) ──────────
#
# Rounds 2 and 3 serialized writers of ONE shared file with a shell lock, and
# recovering a dead holder's lock raced (r3: a second stealer moved the new
# holder's lock aside, a third writer got in, and a record was lost). Now
# nothing is shared: each server's record is its own file, published by a
# rename, and only a server proven dead loses its file.

# _publish_barrier — in this shell and its subshells, the FIRST `mv` each
# writer makes (its publish) drops "$GATE/at.$GATE_ID" and waits until
# $GATE_N writers are there, so every writer is between "ready" and
# "published" at the same instant. Bounded at 10s, past round 3's 5s lock
# timeout: a writer held behind a lock waits the whole of it.
_publish_barrier() {
  mv() {
    if [ -z "${_PB_DONE:-}" ]; then
      _PB_DONE=1
      : > "$GATE/at.$GATE_ID"
      local n=0 c f
      while [ "$n" -lt 200 ]; do
        c=0; for f in "$GATE"/at.*; do [ -e "$f" ] && c=$((c + 1)); done
        [ "$c" -ge "$GATE_N" ] && break
        command sleep 0.05; n=$((n + 1))
      done
    fi
    command mv "$@"
  }
}

@test "record: writers A, B and C publish at the same instant, and every record survives" {
  _src_tmux
  local sock; _sockfile sock
  local a b c p
  _fake_tmux_proc a; _fake_tmux_proc b; _fake_tmux_proc c
  GATE="$(mktemp -d "$TEST_HOME/gate.XXXXXX")"; GATE_N=3
  local -a jobs=()
  for p in "$a" "$b" "$c"; do
    (
      GATE_ID="$p"; _publish_barrier
      # Stand-in for the server answering "who are you": this pid, that socket.
      # (Not named $sock: the stub runs inside tmux_server_record, whose own
      # `local sock` would shadow it — bash scope is dynamic.)
      _w_sock="$sock"
      tmux() {
        case "$*" in
          *'#{pid}'*) echo "$p" ;;
          *'#{socket_path}'*) echo "$_w_sock" ;;
          *) command tmux "$@" ;;
        esac
      }
      tmux_server_record
    ) & jobs+=($!)
  done
  for p in "${jobs[@]}"; do wait "$p" || true; done
  local missing=""
  for p in "$a" "$b" "$c"; do _on_record "$p" || missing="$missing $p"; done
  [ -z "$missing" ] || { echo "lost:$missing"; _records; false; }
  # Control: the three really were at their publish together.
  local n=0 f
  for f in "$GATE"/at.*; do [ -e "$f" ] && n=$((n + 1)); done
  [ "$n" -eq 3 ] || { echo "control: $n of 3 writers reached the publish"; false; }
  # Each record is whole, and no temp file is left behind.
  for p in "$a" "$b" "$c"; do
    [ "$(cat "$(_rec_d)/$p".*)" = "$p	$(_lstart "$p")	$sock" ] || { _records; false; }
  done
  for f in "$(_rec_d)"/* "$(_rec_d)"/.[!.]*; do
    [ -e "$f" ] || continue
    case "${f##*/}" in "$a".*|"$b".*|"$c".*) ;; *) echo "left behind: $f"; false ;; esac
  done
}

@test "record: pruning removes exactly the dead — pid gone, pid reused — and nothing live" {
  _src_tmux
  local sock; _sockfile sock
  local live reused dead
  _fake_tmux_proc live; _fake_tmux_proc reused; _dead_pid dead
  _seed "$live" "$(_lstart "$live")" "$sock"
  _seed "$reused" "Thu Jan  1 00:00:00 1970" "$sock"
  _seed "$dead" "Thu Jan  1 00:00:00 1970" "$sock"
  PATH="$TEST_HOME/fakebin:$PATH" tmux_rescue_orphans
  ! _on_record "$dead" || { echo "the dead server's record was kept"; _records; false; }
  ! _on_record "$reused" || { echo "the reused pid's old record was kept"; _records; false; }
  _on_record "$live" || { echo "a live server's record was removed"; _records; false; }
  # Its socket is there: nothing to rescue, nothing signalled.
  kill -0 "$live" 2>/dev/null || { echo "signalled $live"; false; }
}

@test "record: a live server's record is never removed, even when it cannot be signalled" {
  _src_tmux
  # Two live processes, each on record with its real start time and a swept
  # socket, that the rescue must NOT signal: one whose comm is not tmux, one
  # whose uid is not ours. Neither is proven dead, so neither loses its record
  # (rounds 1-3 dropped any record that failed the identity check).
  local plain theirs
  sleep 30 & plain=$!
  OWN_PIDS="$plain"
  _fake_tmux_proc theirs
  _seed "$plain" "$(_lstart "$plain")" "$TEST_HOME/swept-$plain/default"
  _seed "$theirs" "$(_lstart "$theirs")" "$TEST_HOME/swept-$theirs/default"
  CLIKAE_TMUX_UID=$(( $(id -u) + 1 )) PATH="$TEST_HOME/fakebin:$PATH" tmux_rescue_orphans
  kill -0 "$plain" 2>/dev/null && kill -0 "$theirs" 2>/dev/null || { echo "control: signalled"; false; }
  _on_record "$plain" || { echo "the live non-tmux record ($plain) was removed"; _records; false; }
  _on_record "$theirs" || { echo "the live other-uid record ($theirs) was removed"; _records; false; }
  # And a second rescue still leaves them: nothing about them changed.
  CLIKAE_TMUX_UID=$(( $(id -u) + 1 )) PATH="$TEST_HOME/fakebin:$PATH" tmux_rescue_orphans
  _on_record "$plain" && _on_record "$theirs" || { _records; false; }
}

@test "record: the rounds 1-3 single file is converted to per-server files once, then removed" {
  _src_tmux
  local sock; _sockfile sock
  local live dead
  _fake_tmux_proc live; _dead_pid dead
  local old="$CLIKAE_HOME/state/tmux/servers"
  mkdir -p "${old%/*}"
  {
    printf '%s\t%s\t%s\n' "$live" "$(_lstart "$live")" "$sock"
    printf '%s\t%s\t%s\n' "$dead" "Thu Jan  1 00:00:00 1970" "$sock"
    printf '%s\t%s\n' 4242 "$TEST_HOME/round-1-format/default"
  } > "$old"
  PATH="$TEST_HOME/fakebin:$PATH" tmux_rescue_orphans
  [ ! -e "$old" ] || { echo "the old single file is still there:"; cat "$old"; false; }
  local f n=0
  for f in "$(_rec_d)"/* "$(_rec_d)"/.[!.]*; do [ -e "$f" ] && n=$((n + 1)); done
  [ "$n" -eq 1 ] || { echo "expected only the live server's file:"; ls -la "$(_rec_d)"; false; }
  [ "$(cat "$(_rec_d)/$live".*)" = "$live	$(_lstart "$live")	$sock" ] || { _records; false; }
  # Once: a second pass changes nothing.
  PATH="$TEST_HOME/fakebin:$PATH" tmux_rescue_orphans
  [ ! -e "$old" ] && _on_record "$live" || { _records; false; }
}

# ── round 5: what a writer may delete, and who may prune (PR #181 r4 review) ─
#
# r4 named a temp file after `${BASHPID:-$$}` expanded INSIDE `$(mktemp …)` —
# the command substitution's own pid, gone before the write was published —
# so any reader's pruning deleted a write in progress. And a writer removed
# every other file of its pid, which deletes the NEW incarnation's record when
# the writer itself is the stale one.

# _hold_first_mv <name> [after] — in this shell, the FIRST `mv` (a publish, or
# r4's migration claim) drops "$GATE/held.<name>" and waits for
# "$GATE/go.<name>" (bounded at 10s): before that mv runs, or with `after`,
# right after it.
_hold_first_mv() {
  _HF_NAME="$1"; _HF_AFTER="${2:-}"
  mv() {
    local _hf_rc=0
    [ -z "$_HF_AFTER" ] || command mv "$@" || _hf_rc=$?
    if [ -z "${_HF_DONE:-}" ]; then
      _HF_DONE=1
      : > "$GATE/held.$_HF_NAME"
      local n=0
      while [ "$n" -lt 200 ] && [ ! -e "$GATE/go.$_HF_NAME" ]; do command sleep 0.05; n=$((n + 1)); done
    fi
    [ -n "$_HF_AFTER" ] || command mv "$@" || _hf_rc=$?
    return "$_hf_rc"
  }
}

# _await <file> — wait (bounded at 10s) until <file> exists.
_await() {
  local n=0
  while [ "$n" -lt 200 ] && [ ! -e "$1" ]; do sleep 0.05; n=$((n + 1)); done
  [ -e "$1" ] || { echo "control: $1 never appeared"; return 1; }
}

# _reader_script — a reader as the real launch path runs it: `set -e`, then the
# rescue, then a statement that must be reached. Holds at its first mv when
# HOLD is set.
_reader_script() {
  cat > "$TEST_HOME/reader.sh" <<EOF
set -e
. "$CLIKAE_TEST_ROOT/lib/core/log.sh"
. "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
$(declare -f _hold_first_mv)
[ -z "\${HOLD:-}" ] || _hold_first_mv "\$HOLD" "\${HOLD_AFTER:-}"
tmux_rescue_orphans
echo reached
EOF
}

@test "record (r5): a reader's pruning never removes a write in progress" {
  _src_tmux
  local sock; _sockfile sock
  local p; _fake_tmux_proc p
  GATE="$(mktemp -d "$TEST_HOME/gate.XXXXXX")"
  # Writer A has its temp file written and is about to publish it…
  ( _hold_first_mv A; rc=0; _tmux_rec_write "$p" "$(_lstart "$p")" "$sock" || rc=$?; echo "$rc" > "$GATE/rc.A" ) &
  local a=$!
  _await "$GATE/held.A"
  local t n=0
  for t in "$(_rec_d)"/.[!.]*; do [ -f "$t" ] && n=$((n + 1)); done
  [ "$n" -eq 1 ] || { echo "control: A's temp file is not there"; ls -la "$(_rec_d)"; false; }
  # …when reader B prunes.
  PATH="$TEST_HOME/fakebin:$PATH" tmux_rescue_orphans
  : > "$GATE/go.A"; wait "$a" || true
  [ "$(cat "$GATE/rc.A")" -eq 0 ] || { echo "A's publish failed (rc $(cat "$GATE/rc.A"))"; false; }
  _on_record "$p" || { echo "the pruner deleted A's write in progress"; ls -la "$(_rec_d)"; false; }
}

@test "record (r5): a temp file is pruned only when abandoned (old), and a failed publish says so" {
  _src_tmux
  local sock; _sockfile sock
  local d; d="$(_rec_d)"; mkdir -p "$d"
  # Abandoned (a writer killed between mktemp and mv, long ago) vs fresh — the
  # fresh one is named after a pid that is certainly dead, which r4 read as
  # "abandoned".
  local dead; _dead_pid dead
  : > "$d/.tmp.old"; touch -t 200001010000 "$d/.tmp.old"
  : > "$d/.$dead.fresh"
  tmux_rescue_orphans
  [ ! -e "$d/.tmp.old" ] || { echo "an abandoned temp file was kept"; false; }
  [ -e "$d/.$dead.fresh" ] || { echo "a fresh temp file was pruned"; false; }
  # A publish whose mv fails is a failure, and leaves nothing behind.
  rm -f "$d/.$dead.fresh"
  mv() { return 1; }
  local rc=0
  _tmux_rec_write 4242 "Thu Jan  1 00:00:00 1970" "$sock" || rc=$?
  unset -f mv
  [ "$rc" -ne 0 ] || { echo "a failed publish returned 0"; false; }
  local f
  for f in "$d"/* "$d"/.[!.]*; do
    [ -e "$f" ] && { echo "left behind: $f"; false; }
  done
  return 0
}

@test "record (r5): a delayed old-incarnation writer never deletes the new incarnation's record" {
  _src_tmux
  local sock; _sockfile sock
  local p; _fake_tmux_proc p
  local s1="Thu Jan  1 00:00:00 1970" s2; s2="$(_lstart "$p")"
  local old new
  old="$(_rec_d)/$p.$(_tmux_rec_key "$s1")"; new="$(_rec_d)/$p.$(_tmux_rec_key "$s2")"
  GATE="$(mktemp -d "$TEST_HOME/gate.XXXXXX")"
  # A sampled pid P when it was incarnation S1 and pauses before publishing…
  ( _hold_first_mv A; _tmux_rec_write "$p" "$s1" "$sock" ) & local a=$!
  _await "$GATE/held.A"
  # …that server exits, P is reused (S2), and B records the live server.
  _tmux_rec_write "$p" "$s2" "$sock"
  [ -f "$new" ] || { echo "control: B's record is not there"; false; }
  : > "$GATE/go.A"; wait "$a" || true
  [ -f "$new" ] || { echo "the delayed old-incarnation writer deleted the live server's record"; ls -la "$(_rec_d)"; false; }
  # Retiring the stale one is the reader's job, and it can prove it dead.
  PATH="$TEST_HOME/fakebin:$PATH" tmux_rescue_orphans
  [ ! -e "$old" ] || { echo "the stale incarnation's record was kept"; false; }
  [ -f "$new" ] || { echo "the reader removed the live record"; false; }
}

@test "record (r5): a stale migration entry for a reused pid never deletes the live record" {
  _src_tmux
  local sock; _sockfile sock
  local p; _fake_tmux_proc p
  local new; new="$(_rec_d)/$p.$(_tmux_rec_key "$(_lstart "$p")")"
  _tmux_rec_write "$p" "$(_lstart "$p")" "$sock"
  [ -f "$new" ] || { echo "control: no live record"; false; }
  local old="$CLIKAE_HOME/state/tmux/servers"
  printf '%s\t%s\t%s\n' "$p" "Thu Jan  1 00:00:00 1970" "$sock" > "$old"
  PATH="$TEST_HOME/fakebin:$PATH" tmux_rescue_orphans
  [ ! -e "$old" ] || { echo "the old single file is still there"; false; }
  [ -f "$new" ] || { echo "migrating a stale entry deleted the live record"; ls -la "$(_rec_d)"; false; }
  [ "$(cat "$(_rec_d)/$p".*)" = "$p	$(_lstart "$p")	$sock" ] || { _records; false; }
}

@test "record (r5): a record that disappears between the check and the read is skipped under set -e" {
  _src_tmux
  local sock; _sockfile sock
  local dead; _dead_pid dead
  _tmux_rec_write "$dead" "Thu Jan  1 00:00:00 1970" "$sock"
  local victim; victim="$(echo "$(_rec_d)/$dead".*)"
  [ -f "$victim" ] || { echo "control: no record to race on"; false; }
  _reader_script
  # Reader B removes the record right after reader A has seen it exist.
  run env VICTIM="$victim" bash -c '
    [() { builtin [ "$@"; local r=$?
      if builtin [ "$1" = -f ] && builtin [ "$2" = "$VICTIM" ] && builtin [ "$r" -eq 0 ]; then rm -f "$VICTIM"; fi
      return "$r"; }
    . "$1"' _ "$TEST_HOME/reader.sh"
  [ "$status" -eq 0 ] && [ "${lines[${#lines[@]}-1]}" = reached ] \
    || { echo "the reader aborted (rc $status): $output"; false; }
  [ ! -e "$victim" ] || { echo "control: the race never removed the record"; false; }
}

@test "record (r5): two readers migrating at once — both finish under set -e and nothing live is lost" {
  _src_tmux
  local sock; _sockfile sock
  local live dead
  _fake_tmux_proc live; _dead_pid dead
  local old="$CLIKAE_HOME/state/tmux/servers"
  mkdir -p "${old%/*}"
  {
    printf '%s\t%s\t%s\n' "$live" "$(_lstart "$live")" "$sock"
    printf '%s\t%s\t%s\n' "$dead" "Thu Jan  1 00:00:00 1970" "$sock"
  } > "$old"
  GATE="$(mktemp -d "$TEST_HOME/gate.XXXXXX")"; export GATE
  _reader_script
  # A stops right after its first mv — r4: its claim of `servers`; now: the
  # publish of the first converted record — while B runs from start to finish.
  HOLD=A HOLD_AFTER=1 PATH="$TEST_HOME/fakebin:$PATH" bash "$TEST_HOME/reader.sh" > "$GATE/out.A" 2>&1 & local a=$!
  _await "$GATE/held.A"
  run env PATH="$TEST_HOME/fakebin:$PATH" bash "$TEST_HOME/reader.sh"
  [ "$status" -eq 0 ] && [ "${lines[${#lines[@]}-1]}" = reached ] || { echo "B aborted: $output"; false; }
  : > "$GATE/go.A"
  local rc=0; wait "$a" || rc=$?
  [ "$rc" -eq 0 ] && [ "$(tail -n 1 "$GATE/out.A")" = reached ] || { echo "A aborted (rc $rc):"; cat "$GATE/out.A"; false; }
  [ ! -e "$old" ] || { echo "the old single file is still there"; false; }
  _on_record "$live" || { echo "the live server's record was lost"; ls -la "$(_rec_d)"; false; }
  ! _on_record "$dead" || { echo "the dead server's record was kept"; false; }
  local f
  for f in "$(_rec_d)"/* "$(_rec_d)"/.[!.]*; do
    [ -e "$f" ] || continue
    case "${f##*/}" in "$live".*) ;; *) echo "left behind: $f"; false ;; esac
  done
}

@test "attach (r5): a legacy server that dies during the attach is told by ITS socket, not the home server's" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  export CLIKAE_SESS_PREFIX="clikae-"
  # Home server A, alive, with an unrelated session; the cockpit is on B.
  tmux new-session -d -s unrelated 'sleep 30'
  _legacy_up clikae-codex-L
  local lsock="$LEGACY_SOCK"
  # B dies during the attach.
  tmux() {
    if [ "$1" = -S ] && [ "$2" = "$lsock" ] && [ "$3" = attach ]; then
      command tmux -S "$lsock" kill-server; return 1
    fi
    command tmux "$@"
  }
  local rc=0; tmux_attach clikae-codex-L 0 "$TEST_HOME/sb" || rc=$?
  tmux list-sessions >/dev/null 2>&1 || { echo "control: home server A is down"; false; }
  [ "$rc" -eq 2 ] || { echo "rc $rc: B's death was read off home server A"; false; }
  # Control: B alive, the attach merely refused (a TERM tmux cannot draw) -> 1.
  _legacy_up clikae-codex-L
  tmux() {
    if [ "$1" = -S ] && [ "$2" = "$lsock" ] && [ "$3" = attach ]; then return 1; fi
    command tmux "$@"
  }
  rc=0; tmux_attach clikae-codex-L 0 "$TEST_HOME/sb" || rc=$?
  unset -f tmux
  [ "$rc" -eq 1 ] || { echo "control: a refused attach on a live B returned $rc"; false; }
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
