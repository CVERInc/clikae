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
echo ENGINE_STARTED >> "$HOME/runs.log"
echo HELLO_FROM_ENGINE
sleep 600
INNER_EOF
  chmod +x "$TEST_HOME/.testbin/codex"
    # $HOME, not an exported variable: tmux passes only its `update-environment`
  # list into a session, and everything else is inherited from the SERVER's
  # process environment — which is whoever started the server, not us. So an
  # exported STUB_RUNS reached the stub only when this test happened to start the
  # server itself, and vanished whenever one was already running. That is the
  # whole story of this test's intermittency. clikae passes HOME explicitly with
  # `-e`, so a path under it is one the engine can always find.
  export STUB_RUNS="$TEST_HOME/runs.log"

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

# Start from nothing. ck-codex-roam lives on the shared default socket, so a
# session left by an earlier run would be ATTACHED to instead of created — and
# then the first width is whatever that run used, not ours.
tmux("kill-session", "-t", "ck-codex-roam")

def wait_for(cond, secs=20):
    """Wait for the thing, do not guess how long it takes.

    These used to be fixed sleeps. They were long enough on an idle machine and
    not on a loaded one, so this test failed intermittently in a full-suite run
    while passing 3/3 on its own — the classic shape of a timing guess rather
    than a defect. The conditions below are the states the assertions actually
    depend on."""
    end = time.time() + secs
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.25)
    return False

runs = os.environ.get("STUB_RUNS", "")

def started(n):
    try:
        with open(runs) as fh:
            return fh.read().count("ENGINE_STARTED") >= n
    except OSError:
        return False

attach(100, 30)
wait_for(lambda: "ck-codex-roam" in tmux("ls") and started(1))
print("FIRST_WIDTH", width())

tmux("detach-client", "-s", "ck-codex-roam")
# THIS session, not "any session". The first version asked whether anything in
# tmux was attached, which is never false on a developer's machine — so it burned
# its whole timeout every run, and under a loaded suite that wasted time pushed
# the test past the stub engine's lifetime. The session then died, the second
# attach created a NEW one, and the "engine started exactly once" assertion
# failed for a reason that had nothing to do with roaming.
wait_for(lambda: tmux("display-message", "-p", "-t", "ck-codex-roam",
                      "#{session_attached}").strip() == "0")
print("SURVIVED_DETACH", "yes" if "ck-codex-roam" in tmux("ls") else "no")

attach(60, 20)
wait_for(lambda: width() == "60")
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
echo ENGINE_STARTED >> "$HOME/runs.log"
sleep 60
INNER_EOF
  chmod +x "$TEST_HOME/.testbin/codex"
    # $HOME, not an exported variable: tmux passes only its `update-environment`
  # list into a session, and everything else is inherited from the SERVER's
  # process environment — which is whoever started the server, not us. So an
  # exported STUB_RUNS reached the stub only when this test happened to start the
  # server itself, and vanished whenever one was already running. That is the
  # whole story of this test's intermittency. clikae passes HOME explicitly with
  # `-e`, so a path under it is one the engine can always find.
  export STUB_RUNS="$TEST_HOME/runs.log"

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

@test "resuming a different session opens a second screen, not the one already up" {
  # The bug, reported 2026-08-13 and reproduced before this test existed: open a
  # tank, then from the board resume a DIFFERENT past session on the same tank.
  # The tmux session was named after the tank alone, so the second launch found
  # `ck-codex-roam2` running and attached to it — two tabs, one screen — and the
  # `--resume <sid>` was dropped in silence, because nothing was started to take
  # it. A session is now keyed on what was asked for, so a different request is a
  # different session.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init codex roam2
  cat <<'INNER_EOF' > "$TEST_HOME/.testbin/codex"
#!/usr/bin/env bash
echo "STARTED [$*]" >> "$HOME/runs.log"
echo "SCREEN [$*]"
sleep 90
INNER_EOF
  chmod +x "$TEST_HOME/.testbin/codex"
    # $HOME, not an exported variable: tmux passes only its `update-environment`
  # list into a session, and everything else is inherited from the SERVER's
  # process environment — which is whoever started the server, not us. So an
  # exported STUB_RUNS reached the stub only when this test happened to start the
  # server itself, and vanished whenever one was already running. That is the
  # whole story of this test's intermittency. clikae passes HOME explicitly with
  # `-e`, so a path under it is one the engine can always find.
  export STUB_RUNS="$TEST_HOME/runs.log"

  run python3 - "$CLIKAE_BIN" <<'PYEOF'
import os, fcntl, termios, struct, sys, time, subprocess

clikae = sys.argv[1]

def launch(*args):
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    pid = os.fork()
    if pid == 0:
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        for fd in (0, 1, 2):
            os.dup2(slave, fd)
        os.close(master); os.close(slave)
        os.environ["TERM"] = "xterm-256color"
        os.execv(clikae, [clikae] + list(args))
    os.close(slave)
    return pid

def tmux(*a):
    return subprocess.run(["tmux", *a], capture_output=True, text=True).stdout

runs = os.environ["STUB_RUNS"]
def started(n):
    try:
        with open(runs) as fh:
            return fh.read().count("STARTED") >= n
    except OSError:
        return False

def wait_for(cond, secs=20):
    end = time.time() + secs
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.25)
    return False

launch("codex", "roam2")
wait_for(lambda: started(1))
launch("codex", "roam2", "--", "resume", "SESSION-TWO")
wait_for(lambda: started(2))

names = sorted(n for n in tmux("list-sessions", "-F", "#{session_name}").split()
               if n.startswith("ck-codex-roam2"))
print("SESSIONS", len(names))
for n in names:
    first = (tmux("capture-pane", "-p", "-t", n).strip().splitlines() or [""])[0]
    print("PANE", first)
    tmux("kill-session", "-t", n)
PYEOF

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # Two engines, not one: the second launch must not have been answered by the
  # first session. This is the assertion the old behaviour failed.
  [ "$(grep -c STARTED "$STUB_RUNS")" -eq 2 ] || { cat "$STUB_RUNS"; false; }
  [[ "$output" == *"SESSIONS 2"* ]] || { echo "$output"; false; }
  # And they are showing different things — the point of the whole report.
  [[ "$output" == *"PANE SCREEN []"* ]] || { echo "$output"; false; }
  [[ "$output" == *"PANE SCREEN [resume SESSION-TWO]"* ]] || { echo "$output"; false; }
}
