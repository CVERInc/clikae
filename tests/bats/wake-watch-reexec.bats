#!/usr/bin/env bats
# tests/bats/wake-watch-reexec.bats — #168: a running watcher keeps the code it
# was born with, and after `brew upgrade` the Cellar path it was started from
# is gone. The watcher's own tick notices (its binary carries a different
# version now, or is missing) and re-execs the installed clikae; and the
# watcher window is plumbing — never the window a human lands on.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/wake.sh"
}

# A clikae binary at <path> carrying <version>; it sleeps so a tmux window
# running it stays open.
_fake_bin() {
  local path="$1" ver="$2"
  mkdir -p "$(dirname "$path")"
  printf '#!/usr/bin/env bash\nCLIKAE_VERSION="%s"\nsleep 30\n' "$ver" > "$path"
  chmod +x "$path"
}

# The installed clikae, first on PATH — brew's shape: bin/clikae is a one-line
# wrapper that execs libexec/bin/clikae, which carries the version.
_fake_installed() {
  local ver="$1" root="$TEST_HOME/installed"
  _fake_bin "$root/libexec/bin/clikae" "$ver"
  mkdir -p "$root/bin"
  printf '#!/usr/bin/env bash\nexec "%s/libexec/bin/clikae" "$@"\n' "$root" > "$root/bin/clikae"
  chmod +x "$root/bin/clikae"
  # Not `$(…)`-captured: the PATH change has to land in the test's own shell.
  PATH="$root/bin:$PATH"; export PATH
  INST="$root/bin/clikae"
}

# A PATH with no clikae FILE on it at all (the host may have one installed).
_no_clikae_on_path() {
  mkdir -p "$TEST_HOME/emptybin"
  PATH="$TEST_HOME/emptybin:/usr/bin:/bin"; export PATH
  if type -P clikae >/dev/null 2>&1; then skip "a clikae binary lives in /usr/bin or /bin here"; fi
}

_sess() { printf 'ckwx-%s-%s' "$$" "${BATS_TEST_NUMBER:-0}"; }

teardown() {
  tmux kill-session -t "$(_sess)" 2>/dev/null || true
}

@test "wake_watch_stale_bin: our own binary now carries a different version (updated in place) -> names it" {
  _src
  _fake_bin "$TEST_HOME/own/bin/clikae" "0.2.0"
  export CLIKAE_VERSION="0.1.0" CLIKAE_BIN="$TEST_HOME/own/bin/clikae"
  run wake_watch_stale_bin
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_HOME/own/bin/clikae" ]
}

@test "wake_watch_stale_bin: own binary intact at our version -> 1, even with a newer clikae elsewhere on PATH (no re-exec loop, dev-tree safe)" {
  _src
  _fake_installed 9.9.9
  _fake_bin "$TEST_HOME/own/bin/clikae" "0.1.0"
  export CLIKAE_VERSION="0.1.0" CLIKAE_BIN="$TEST_HOME/own/bin/clikae"
  run wake_watch_stale_bin
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "wake_watch_stale_bin: own binary gone (brew upgrade removed the Cellar) -> names the installed one through its wrapper" {
  _src
  _no_clikae_on_path
  _fake_installed 0.2.0
  export CLIKAE_VERSION="0.1.0" CLIKAE_BIN="$TEST_HOME/Cellar/clikae/0.1.0/libexec/bin/clikae"
  run wake_watch_stale_bin
  [ "$status" -eq 0 ]
  [ "$output" = "$INST" ]
  run wake_installed_version "$INST"
  [ "$output" = "0.2.0" ]
}

@test "wake_watch_stale_bin: own binary gone and nothing installed on PATH -> 1 (a shell FUNCTION named clikae is not a binary)" {
  _src
  _no_clikae_on_path
  export CLIKAE_VERSION="0.1.0" CLIKAE_BIN="$TEST_HOME/nope/clikae"
  run wake_watch_stale_bin
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "wake_select_engine_window: a session parked on the watcher window is put back on the engine" {
  _src
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  tmux new-session -d -s "$(_sess)" -n claude "sleep 30"
  tmux new-window -t "=$(_sess):" -n wake "sleep 30"
  tmux select-window -t "=$(_sess):wake"
  [ "$(tmux display-message -p -t "=$(_sess):" '#{window_name}')" = "wake" ]
  wake_select_engine_window "$(_sess)"
  [ "$(tmux display-message -p -t "=$(_sess):" '#{window_name}')" = "claude" ]
}

@test "wake_attach_watcher: creating the watcher window leaves the engine window current" {
  _src
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _fake_bin "$TEST_HOME/own/bin/clikae" "0.1.0"
  tmux new-session -d -s "$(_sess)" -n claude "sleep 30"
  CLIKAE_BIN="$TEST_HOME/own/bin/clikae" wake_attach_watcher "$(_sess)" claude T1
  tmux list-windows -t "=$(_sess):" -F '#{window_name}' | grep -q '^wake$'
  [ "$(tmux display-message -p -t "=$(_sess):" '#{window_name}')" = "claude" ]
}

@test "wake_watch_leave_hint: the status line says how to get back to the engine" {
  _src
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  tmux new-session -d -s "$(_sess)" -n claude "sleep 30"
  tmux new-window -d -t "=$(_sess):" -n wake "sleep 30"
  run wake_watch_leave_hint "$(_sess)" claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"returns to claude"* ]] || false
  [[ "$output" == *"ctrl-b 0"* ]] || false
}

# --- #183 review round 2: exec is irreversible, so only a replacement that
# resolves and reads coherently is ever exec'd; otherwise the running watcher
# stays, and says why.

@test "wake_watch_stale_bin: own binary gone and the wrapper on PATH execs a target that is not installed -> refuses, names nothing" {
  _src
  _no_clikae_on_path
  _fake_installed 0.2.0
  rm -f "$TEST_HOME/installed/libexec/bin/clikae"   # mid-upgrade: the target is gone
  export CLIKAE_VERSION="0.1.0" CLIKAE_BIN="$TEST_HOME/Cellar/clikae/0.1.0/libexec/bin/clikae"
  run wake_watch_stale_bin
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "wake_watch_stale_bin: own binary gone and the wrapper's target carries no readable version -> refuses" {
  _src
  _no_clikae_on_path
  _fake_installed 0.2.0
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$TEST_HOME/installed/libexec/bin/clikae"
  export CLIKAE_VERSION="0.1.0" CLIKAE_BIN="$TEST_HOME/Cellar/clikae/0.1.0/libexec/bin/clikae"
  run wake_watch_stale_bin
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "wake_watch_stale_bin: own binary rewritten in place but not executable / not parseable yet -> refuses" {
  _src
  local own="$TEST_HOME/own/bin/clikae"
  _fake_bin "$own" "0.2.0"
  export CLIKAE_VERSION="0.1.0" CLIKAE_BIN="$own"
  # Half-written: the version line landed, the rest is cut mid-statement.
  printf '#!/usr/bin/env bash\nCLIKAE_VERSION="0.2.0"\nif [ -n "$x" ]; then\n' > "$own"
  run wake_watch_stale_bin
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # Complete but not executable.
  _fake_bin "$own" "0.2.0"
  chmod -x "$own"
  run wake_watch_stale_bin
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "wake_watch_reload_target: a broken install keeps the running watcher and says why — once, not every tick" {
  _src
  _no_clikae_on_path
  _fake_installed 0.2.0
  rm -f "$TEST_HOME/installed/libexec/bin/clikae"
  export CLIKAE_VERSION="0.1.0" CLIKAE_BIN="$TEST_HOME/Cellar/clikae/0.1.0/libexec/bin/clikae"
  local err="$BATS_TEST_TMPDIR/err" out="$BATS_TEST_TMPDIR/out" rc1=0 rc2=0
  # Both ticks in THIS shell (as wake_watch calls it), so the "already said
  # it" memory carries from one to the next.
  wake_watch_reload_target >"$out" 2>>"$err" || rc1=$?
  wake_watch_reload_target >>"$out" 2>>"$err" || rc2=$?
  [ "$rc1" -ne 0 ] && [ "$rc2" -ne 0 ]
  [ ! -s "$out" ]
  cat "$err"
  grep -q "keeping this watcher" "$err"
  [ "$(grep -c "keeping this watcher" "$err")" -eq 1 ]
}

@test "wake_watch_reload_target: a coherent install is returned for exec" {
  _src
  _no_clikae_on_path
  _fake_installed 0.2.0
  export CLIKAE_VERSION="0.1.0" CLIKAE_BIN="$TEST_HOME/Cellar/clikae/0.1.0/libexec/bin/clikae"
  run wake_watch_reload_target
  [ "$status" -eq 0 ]
  [ "$output" = "$INST" ]
}
