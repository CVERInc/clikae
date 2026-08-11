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

@test "switch scrollback capture retains 200 lines" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed (switch falls back to a direct run)"
  clikae init claude scrolltest
  cat <<'INNER_EOF' > "$TEST_HOME/.testbin/claude"
#!/usr/bin/env bash
echo "SCROLLBACK_MARKER_START"
for i in {1..200}; do echo "line $i"; done
sleep 0.2
INNER_EOF
  chmod +x "$TEST_HOME/.testbin/claude"
  
  run _pty_run "$CLIKAE_BIN" claude scrolltest
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
