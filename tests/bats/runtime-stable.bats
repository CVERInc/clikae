#!/usr/bin/env bats
# tests/bats/runtime-stable.bats — the stable lib/ copy under
# $CLIKAE_HOME/runtime (clikae#146), and every place that now spells it.
#
# Why it exists: on a brew install $CLIKAE_LIB is inside the versioned Cellar,
# and `brew upgrade` deletes it. Every path clikae had written into a live
# session for later use then exited 127 (touch scrolling, measured
# 2026-09-24). Sibling precedent: #59's $CLIKAE_HOME/bin/claude.
#
# The site assertions read what was actually WRITTEN (the pane's start
# command, `list-keys`, the session's status-left, settings.json), never the
# source text.

load '../helpers'

_src_rt() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
}

RT() { printf '%s/runtime/lib' "$CLIKAE_HOME"; }

# ── runtime_sync ────────────────────────────────────────────────────────────

@test "runtime_sync: the first call copies a complete lib/ tree and writes VERSION" {
  _src_rt
  CLIKAE_VERSION=9.9.1 runtime_sync
  [ "$(head -n1 "$CLIKAE_HOME/runtime/VERSION")" = "9.9.1" ]
  local f bad=""
  for f in hooks/cockpit-guard.sh shims/tmux core/touch_scroll.sh core/status_line.sh core/runtime.sh; do
    [ -f "$(RT)/$f" ] || { bad="$bad missing:$f"; continue; }
    # Executable exactly where the source is.
    if [ -x "$CLIKAE_TEST_ROOT/lib/$f" ]; then
      [ -x "$(RT)/$f" ] || bad="$bad not-exec:$f"
    fi
  done
  [ -z "$bad" ] || { echo "$bad"; false; }
  # The whole tree, not a hand-picked list: same file count as the source.
  [ "$(find "$CLIKAE_TEST_ROOT/lib" -type f | wc -l)" -eq "$(find -L "$(RT)" -type f | wc -l)" ]
  [ "$(runtime_lib)" = "$(RT)" ]
}

@test "runtime_sync: same version is a no-op (a probe file survives)" {
  _src_rt
  CLIKAE_VERSION=9.9.1 runtime_sync
  : > "$(RT)/probe"
  CLIKAE_VERSION=9.9.1 runtime_sync
  [ -e "$(RT)/probe" ]
}

@test "runtime_sync: a source file newer than the copy re-copies at the same version (dev checkout)" {
  _src_rt
  cp -R "$CLIKAE_TEST_ROOT/lib" "$BATS_TEST_TMPDIR/srclib"
  export CLIKAE_LIB="$BATS_TEST_TMPDIR/srclib"
  CLIKAE_VERSION=9.9.1 runtime_sync
  : > "$(RT)/probe"
  sleep 1.1
  printf '# edited\n' >> "$CLIKAE_LIB/core/touch_scroll.sh"
  CLIKAE_VERSION=9.9.1 runtime_sync
  [ ! -e "$(RT)/probe" ] || { echo "stale copy kept after a source edit"; false; }
  grep -q '^# edited$' "$(RT)/core/touch_scroll.sh"
}

@test "runtime_sync: a different version re-copies, and keeps the previous tree for a hook mid-run" {
  _src_rt
  CLIKAE_VERSION=9.9.1 runtime_sync
  : > "$(RT)/probe"
  local old; old="$(cd -P "$(RT)" && pwd)"
  CLIKAE_VERSION=9.9.2 runtime_sync
  [ ! -e "$(RT)/probe" ]
  [ "$(head -n1 "$CLIKAE_HOME/runtime/VERSION")" = "9.9.2" ]
  # The physical tree cockpit-guard.sh resolves with `cd -P` is still there.
  [ -f "$old/hooks/cockpit-guard.sh" ]
  # A third sync prunes the oldest, so trees/ does not grow without bound.
  CLIKAE_VERSION=9.9.3 runtime_sync
  [ ! -e "$old" ]
  [ "$(find "$CLIKAE_HOME/runtime/trees" -mindepth 1 -maxdepth 1 | wc -l)" -eq 2 ]
}

@test "runtime_sync: a missing tree with a matching VERSION is re-copied" {
  _src_rt
  CLIKAE_VERSION=9.9.1 runtime_sync
  rm -rf "$CLIKAE_HOME/runtime/trees"
  CLIKAE_VERSION=9.9.1 runtime_sync
  [ -x "$(RT)/shims/tmux" ]
}

@test "CLIKAE_RUNTIME_STABLE=0: runtime_lib prints CLIKAE_LIB and sync writes nothing" {
  _src_rt
  CLIKAE_RUNTIME_STABLE=0 runtime_sync
  [ ! -e "$CLIKAE_HOME/runtime" ]
  [ "$(CLIKAE_RUNTIME_STABLE=0 runtime_lib)" = "$CLIKAE_LIB" ]
}

# ── the sites: what tmux / the engine is actually told ───────────────────────

@test "site 1+3+4: a spawned session's pane PATH, touch bindings and status row all name the runtime copy" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_rt
  local sess="clikae-codex-rt$$"
  tmux_spawn_session --session "$sess" -- 'sleep 30'
  tmux_status_line "$sess" codex T1
  local start keys left
  start="$(tmux list-panes -t "=$sess" -F '#{pane_start_command}' | head -n1)"
  keys="$(tmux list-keys 2>/dev/null | grep touch_scroll || true)"
  left="$(tmux show-options -v -t "=$sess:" status-left 2>/dev/null)"
  tmux kill-session -t "=$sess" 2>/dev/null || true
  # 1: the pane's own first exec carries the stable shim dir first.
  [[ "$start" == *"PATH=$(RT)/shims:"* ]] || { echo "start: $start"; false; }
  # 3: every touch binding (if this tmux is new enough to get them) uses it.
  if [ -n "$keys" ]; then
    [ "$(printf '%s\n' "$keys" | grep -cF "'$(RT)/core/touch_scroll.sh'")" -eq "$(printf '%s\n' "$keys" | wc -l)" ] ||
      { echo "$keys"; false; }
  fi
  # 4: the status row's #() command.
  [[ "$left" == *"'$(RT)/core/status_line.sh'"* ]] || { echo "status-left: $left"; false; }
  [[ "$left" != *"$CLIKAE_LIB/core/status_line.sh"* ]] || false
}

@test "site 5: clikae cockpit writes the runtime hook path into settings.json" {
  clikae init claude L
  run clikae cockpit claude L
  [ "$status" -eq 0 ]
  local cmd
  cmd="$(jq -r '.hooks.PreToolUse[] | select(._clikae == "cockpit-guard") | .hooks[0].command' "$CLIKAE_HOME/profiles/claude/L/settings.json")"
  [ "$cmd" = "'$(RT)/hooks/cockpit-guard.sh'" ] || { echo "$cmd"; false; }
  [ -x "$(RT)/hooks/cockpit-guard.sh" ]
}

# ── doctor names the cause ──────────────────────────────────────────────────

@test "site 6 + doctor: a session whose recorded shim dir is gone is named as a moved install" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sess="clikae-codex-gone$$" gone="$BATS_TEST_TMPDIR/Cellar/0.31.0/lib/shims"
  tmux new-session -d -s "$sess" "env PATH=$gone:/usr/bin:/bin sleep 60"
  run clikae doctor
  tmux kill-session -t "=$sess" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"$sess: installed version moved (dir $gone is gone); restart the session"* ]] || { echo "$output"; false; }
  [[ "$output" == *"reattaching does not repair it"* ]] || false
}

@test "doctor control: a session whose shim dir exists says nothing about a moved install" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sess="clikae-codex-here$$" here="$BATS_TEST_TMPDIR/Cellar/0.32.0/lib/shims"
  mkdir -p "$here"
  tmux new-session -d -s "$sess" "env PATH=$here:/usr/bin:/bin sleep 60"
  run clikae doctor
  tmux kill-session -t "=$sess" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" != *"installed version moved"* ]] || { echo "$output"; false; }
}

@test "doctor: a spawned session with the runtime shim first counts as guarded" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_rt
  local sess="clikae-codex-rtok$$"
  tmux_spawn_session --session "$sess" -- 'sleep 60'
  run clikae doctor
  tmux kill-session -t "=$sess" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" != *"tmux guard"* ]] || { echo "$output"; false; }
}

@test "doctor: a key binding running a script from a deleted dir is named, with the server-wide repair" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local sess="clikae-codex-keys$$" gone="$BATS_TEST_TMPDIR/Cellar/0.31.0/lib/core"
  tmux new-session -d -s "$sess" 'sleep 60'
  tmux bind-key -T root F12 run-shell "bash '$gone/touch_scroll.sh' x"
  run clikae doctor
  local control_rc control_out
  tmux bind-key -T root F12 run-shell "bash '$CLIKAE_LIB/core/touch_scroll.sh' x"
  control_out="$("$CLIKAE_BIN" doctor 2>&1)"; control_rc=$?
  tmux kill-session -t "=$sess" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed version moved (dir $gone is gone); 1 binding(s) still run from it"* ]] || { echo "$output"; false; }
  [[ "$output" == *"creating any new clikae session re-writes them"* ]] || false
  [ "$control_rc" -eq 0 ]
  [[ "$control_out" != *"tmux bindings"* ]] || { echo "$control_out"; false; }
}

@test "doctor reports the runtime copy and its version" {
  _src_rt
  CLIKAE_VERSION=0.0.1 runtime_sync
  run clikae doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"runtime"*"stale: $(RT) is 0.0.1"* ]] || { echo "$output"; false; }
}
