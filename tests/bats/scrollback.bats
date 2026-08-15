#!/usr/bin/env bats

load '../helpers'

bats_require_minimum_version 1.5.0

# A pty, portably. `script -q /dev/null cmd args` is the BSD form and util-linux
# rejects it outright ("unexpected number of arguments"), which is how this file
# passed on macOS and failed on ubuntu. python3's pty is on both runners and is
# what tests/tools/pty-smoke.py already uses.
_pty_run() {
  python3 - "$@" <<'PYEOF'
import os, pty, fcntl, termios, struct, sys

# 80x24 on purpose: the point of this test is that 200 lines SCROLL OFF the
# visible screen, so the pty must be a normal size. A pty left at its default
# (or 0x0) can swallow the whole run, and then `capture-pane` without -S -
# still finds line 1 — the probe passes whether the fix is there or not.
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
pid = os.fork()
if pid == 0:
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    for fd in (0, 1, 2):
        os.dup2(slave, fd)
    os.close(master); os.close(slave)
    os.environ["TERM"] = os.environ.get("CK_PTY_TERM") or "xterm-256color"
    os.execvp(sys.argv[1], sys.argv[1:])
os.close(slave)
chunks = []
while True:
    try:
        d = os.read(master, 4096)
    except OSError:
        break
    if not d:
        break
    chunks.append(d)
os.waitpid(pid, 0)
sys.stdout.write(b"".join(chunks).decode(errors="replace"))
PYEOF
}

# Does a pane's shell get a turn after the command it ran exits?
#
# The whole capture-and-replay depends on it: target_cmd runs the engine and then
# captures the pane. Measured on ubuntu tmux 3.4 (2026-08-15) the answer is no —
# the pane is torn down at that instant, hard enough that neither a following
# command, nor a backgrounded subshell, nor bash's own EXIT trap ever ran. macOS
# tmux 3.7b keeps the shell alive and the feature works there.
#
# Probe the capability rather than the platform: a version string is a proxy, and
# this is the actual question. A capability the runner does not have is a skip
# with a reason, not a red test — DESIGN-tmux Rule 2's whole position is that the
# tmux layer degrades honestly.
_pane_outlives_its_command() {
  local d; d="$(mktemp -d)"
  tmux new-session -d -s "ckprobe$$" "sh -c 'true; touch $d/after'" 2>/dev/null || { rm -rf "$d"; return 1; }
  local i
  for i in $(seq 1 60); do [ -e "$d/after" ] && break; sleep 0.05; done
  tmux kill-session -t "ckprobe$$" 2>/dev/null || true
  local ok=1; [ -e "$d/after" ] && ok=0
  rm -rf "$d"; return "$ok"
}

@test "switch scrollback capture retains 200 lines" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed (switch falls back to a direct run)"
  _pane_outlives_its_command || skip "this tmux tears the pane down when its command exits, so nothing can capture the scrollback from inside it (measured: ubuntu tmux 3.4)"
  clikae init claude scrolltest
  cat <<'INNER_EOF' > "$TEST_HOME/.testbin/claude"
#!/usr/bin/env bash
# Stage log. The marker count says the replay did not happen; it cannot say
# whether the engine ran, whether tmux rendered, or whether anyone ever
# attached — and those need different fixes. Four fixes were pushed at this
# from the count alone (2026-08-15) before the stages were written down.
_stage() { printf '%s\n' "$1" >> "${HOME:?}/scrollback-stages.log"; }
_stage "engine-started pwd=$PWD tmux=${TMUX:+yes}"
echo "SCROLLBACK_MARKER_START"
for i in {1..200}; do echo "line $i"; done
# Wait for tmux to have actually rendered the last line instead of guessing at
# how long that takes. `sleep 0.2` was enough on an idle machine and not on a
# loaded one, so this test failed only inside a full suite run — the shape of a
# timing guess, not of a defect. This runs INSIDE the pane, so capture-pane with
# no target reads the pane we just wrote to.
_rendered=no
for _ in $(seq 1 200); do
  tmux capture-pane -p -S - 2>/dev/null | grep -q "line 200" && { _rendered=yes; break; }
  sleep 0.05
done
_stage "rendered=$_rendered"
# …and then outlive the attach. What this test measures is the scrollback
# capture and its replay; the replay only runs after `tmux attach` RETURNS, so
# the engine must still be alive when the parent attaches and end afterwards.
# Nothing enforced that ordering, so the test was really racing the parent.
#
# It won that race until the suite gained a per-test tmux socket (2026-08-15,
# the isolation that stops `tmux kill-server` in roam.bats reaching live tanks).
# Every test now creates a server of its own instead of reusing one, and that
# startup landed between create and attach. macOS absorbed it; ubuntu did not,
# and CI went red for eight pushes on this one test while every other job stayed
# green. Wait for the client instead of hoping — the same lesson as the loop
# above, one layer out.
_client=no
for _ in $(seq 1 200); do
  [ -n "$(tmux list-clients 2>/dev/null)" ] && { _client=yes; break; }
  sleep 0.05
done
_stage "client=$_client sessions=$(tmux list-sessions -F '#{session_name}' 2>&1 | tr '\n' ',')"
_stage "capture-bytes=$(tmux capture-pane -p -S - 2>/dev/null | wc -c) capture-t-bytes=$(tmux capture-pane -p -S - -t \"ck-claude-scrolltest\" 2>/dev/null | wc -c)"
_stage "parent=$(ps -o comm= -p $PPID 2>/dev/null | tr -d ' ')"
# Outlive the engine. If the pane's shell gets to run the capture that follows
# `clikae run` in target_cmd, this subshell is alive to see the file appear; if
# the whole pane is torn down the instant the engine exits, nothing below is ever
# written and that is the answer.
( sleep 2
  _stage "post-exit file=$(ls "$HOME/.clikae/state/"*.scrollback 2>&1 | tail -1)"
) >/dev/null 2>&1 &
_stage "exiting"
INNER_EOF
  chmod +x "$TEST_HOME/.testbin/claude"
  
  # Watch for the scrollback file. tmux_attach removes it on BOTH paths — after
  # replaying it, and after a refused attach — so by assertion time it is always
  # gone and its absence proves nothing. Record its size while it exists; that is
  # the one link in the chain nothing has observed.
  ( for _ in $(seq 1 3000); do
      for f in "$TEST_HOME/.clikae/state/"*.scrollback; do
        [ -e "$f" ] || continue
        printf '%s=%s\n' "${f##*/}" "$(wc -c < "$f" | tr -d ' ')" >> "$TEST_HOME/scrollback-trace.txt"
      done
      sleep 0.01
    done ) & _watcher=$!

  run _pty_run "$CLIKAE_BIN" claude scrolltest
  kill "$_watcher" 2>/dev/null || true
  # This test drives the REAL tmux server (switch has no socket override), so it
  # must put back what it took: a surviving ck-claude-scrolltest changes what the
  # next run of this file — and any other test that reaches tmux — walks into.
  tmux kill-session -t "ck-claude-scrolltest" 2>/dev/null || true
  
  # strip all carriage returns and terminal escapes
  cleaned=$(echo "$output" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' | tr -d '\r' | sed -E 's/[^a-zA-Z0-9_ -]//g')
  
  # It should appear twice: once when drawn, once when dumped by awk at the end.
  count=$(echo "$cleaned" | grep -o "SCROLLBACK_MARKER_START" | wc -l | awk '{print $1}')
  
  if [ "$count" -lt 2 ]; then
    echo "Expected at least 2 occurrences of SCROLLBACK_MARKER_START, found $count"
    # What the marker count cannot tell you is WHY. One occurrence means the
    # replay never happened, and that has several causes which look identical
    # from here: the session was never created, it died before the attach, the
    # attach was refused, or the capture wrote nothing. Three wrong guesses were
    # made from the count alone (2026-08-15) before anyone printed the state.
    echo "--- scrollback trace:  $(sort -u "$TEST_HOME/scrollback-trace.txt" 2>/dev/null | tr '\n' '|' || echo NEVER-EXISTED)"
    echo "--- state dir:         $(ls -la "$TEST_HOME/.clikae/state/" 2>&1 | tail -4 | tr '\n' '|')"
    echo "--- stages:            $(cat "$TEST_HOME/scrollback-stages.log" 2>&1 | tr '\n' '|')"
    echo "--- tmux version:      $(tmux -V 2>&1)"
    echo "--- TMUX_TMPDIR:       ${TMUX_TMPDIR:-<unset>}"
    echo "--- sessions now:      $(tmux list-sessions 2>&1 | tr '\n' '|')"
    echo "--- scrollback file:   $(ls -l "$TEST_HOME/.clikae/state/"*.scrollback 2>&1 | tr '\n' '|')"
    echo "--- server options:    history-limit=$(tmux show-options -gv history-limit 2>&1) mouse=$(tmux show-options -gv mouse 2>&1) clip=$(tmux show-options -sv set-clipboard 2>&1)"
    echo "--- overrides:         $(tmux show-options -g terminal-overrides 2>&1 | tr '\n' '|')"
    echo "Output was:"
    echo "$output"
    false
  fi
}

@test "switch still runs the engine when tmux cannot attach, and leaves nothing behind" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init claude dumbterm
  cat <<'INNER_EOF' > "$TEST_HOME/.testbin/claude"
#!/usr/bin/env bash
echo "ENGINE_RAN_ANYWAY"
INNER_EOF
  chmod +x "$TEST_HOME/.testbin/claude"

  # TERM=dumb is what an ssh session from the PineNote arrives as. tmux can start a
  # detached session on it but cannot attach — so the engine must still run in the
  # foreground, its output must reach the user, and no orphan session may survive
  # spending quota where nobody is looking.
  CK_PTY_TERM=dumb run _pty_run "$CLIKAE_BIN" claude dumbterm
  [[ "$output" == *"ENGINE_RAN_ANYWAY"* ]] || { echo "$output"; false; }
  run tmux has-session -t "ck-claude-dumbterm"
  [ "$status" -ne 0 ]
}
