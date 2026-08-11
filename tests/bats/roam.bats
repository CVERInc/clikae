#!/usr/bin/env bats
# tests/bats/roam.bats — the promise the tmux layer exists for: walk away from one
# device, pick the same session up on another. Nothing here needs a network hop —
# what is at risk is clikae's create-or-attach logic and the resize that follows,
# not ssh. Two ptys of different sizes stand in for the two machines.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

@test "a second client attaches to the running tank instead of starting it again" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init codex roam
  cat <<'INNER_EOF' > "$TEST_HOME/.testbin/codex"
#!/usr/bin/env bash
echo ENGINE_STARTED >> "$STUB_RUNS"
echo HELLO_FROM_ENGINE
sleep 90
INNER_EOF
  chmod +x "$TEST_HOME/.testbin/codex"
  export STUB_RUNS="$BATS_TEST_TMPDIR/runs.log"

  run python3 - "$CLIKAE_BIN" <<'PYEOF'
import os, fcntl, termios, struct, sys, time, subprocess

clikae = sys.argv[1]

def attach(cols, rows):
    """Run `clikae codex roam` on a pty of a given size, the way a terminal would."""
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    pid = os.fork()
    if pid == 0:
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        for fd in (0, 1, 2):
            os.dup2(slave, fd)
        os.close(master); os.close(slave)
        # A real terminal has a TERM tmux can draw on; CI runs with it unset or
        # dumb, where switch correctly falls back to a direct run — and then there
        # is no session to roam onto and this test measures the fallback instead.
        os.environ["TERM"] = "xterm-256color"
        os.execv(clikae, [clikae, "codex", "roam"])
    os.close(slave)
    return pid

def tmux(*a):
    return subprocess.run(["tmux", *a], capture_output=True, text=True).stdout.strip()

def width():
    return tmux("display-message", "-p", "-t", "ck-codex-roam", "#{window_width}")

attach(100, 30); time.sleep(4)
print("FIRST_WIDTH", width())

tmux("detach-client", "-s", "ck-codex-roam"); time.sleep(2)
print("SURVIVED_DETACH", "yes" if "ck-codex-roam" in tmux("ls") else "no")

attach(60, 20); time.sleep(4)
print("SECOND_WIDTH", width())

tmux("kill-session", "-t", "ck-codex-roam")
PYEOF

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # The window follows whichever client is in front of you (window-size latest).
  [[ "$output" == *"FIRST_WIDTH 100"* ]]  || { echo "$output"; false; }
  [[ "$output" == *"SURVIVED_DETACH yes"* ]] || { echo "$output"; false; }
  [[ "$output" == *"SECOND_WIDTH 60"* ]] || { echo "$output"; false; }
  # The point of the whole feature: coming back is picking the work up, not
  # relaunching it. A second engine here would mean a second conversation and a
  # second bite out of the account's quota.
  [ "$(grep -c ENGINE_STARTED "$STUB_RUNS")" -eq 1 ] || { cat "$STUB_RUNS"; false; }
}

@test "called from inside tmux, switch moves the client instead of nesting" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init codex roam
  cat <<'INNER_EOF' > "$TEST_HOME/.testbin/codex"
#!/usr/bin/env bash
echo ENGINE_STARTED >> "$STUB_RUNS"
sleep 60
INNER_EOF
  chmod +x "$TEST_HOME/.testbin/codex"
  export STUB_RUNS="$BATS_TEST_TMPDIR/runs.log"

  run python3 - "$CLIKAE_BIN" <<'PYEOF'
import os, fcntl, termios, struct, sys, time, subprocess

clikae = sys.argv[1]
def tmux(*a):
    return subprocess.run(["tmux", *a], capture_output=True, text=True).stdout.strip()

tmux("kill-server")
tmux("new-session", "-d", "-x", "100", "-y", "30", "-s", "outer", "bash --noprofile --norc")

# switch-client needs a client to move, so attach a real one.
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
if os.fork() == 0:
    os.setsid(); fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    for fd in (0, 1, 2): os.dup2(slave, fd)
    os.close(master); os.close(slave)
    os.environ["TERM"] = "xterm-256color"
    os.execvp("tmux", ["tmux", "attach", "-t", "outer"])
os.close(slave); time.sleep(2)

tmux("send-keys", "-t", "outer", "%s codex roam" % clikae, "Enter"); time.sleep(6)
print("CLIENT_ON", tmux("list-clients", "-F", "#{client_session}"))
tmux("kill-server")
PYEOF

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # Running `tmux attach` inside tmux is refused ("sessions should be nested with
  # care"); the client has to be MOVED. If this regresses the client stays on
  # 'outer' and the tank runs where nobody is looking.
  [[ "$output" == *"CLIENT_ON ck-codex-roam"* ]] || { echo "$output"; false; }
  [ "$(grep -c ENGINE_STARTED "$STUB_RUNS")" -eq 1 ] || { cat "$STUB_RUNS"; false; }
}
