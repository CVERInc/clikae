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

SESSION = "clikae-codex-roam"

def attach(cols, rows):
    """Run `clikae codex roam` on a pty of a given size, the way a terminal
    would, and hand back that pty's tty name.

    The NAME is the point. Everything below has to be able to ask tmux about
    THIS client rather than about "whatever happens to be attached" — the two
    stopped being the same thing the moment this test grew a second client."""
    master, slave = os.openpty()
    tty = os.ttyname(slave)
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
    return tty

def tmux(*a):
    return subprocess.run(["tmux", *a], capture_output=True, text=True).stdout.strip()

def width():
    return tmux("display-message", "-p", "-t", SESSION, "#{window_width}")

def clients():
    """The clients attached to THIS session, as "<tty> <cols>x<rows>" lines."""
    out = tmux("list-clients", "-t", SESSION, "-F",
               "#{client_tty} #{client_width}x#{client_height}")
    return [line for line in out.splitlines() if line]

def attached(tty):
    return any(line.startswith(tty + " ") for line in clients())

def client_width(tty):
    # -c, not -t: `-t` on display-message is a target-PANE and silently falls
    # back to the current client, which reports the OTHER client's width.
    return tmux("display-message", "-p", "-c", tty, "#{client_width}")

# Start from nothing. clikae-codex-roam lives on the shared default socket, so a
# session left by an earlier run would be ATTACHED to instead of created — and
# then the first width is whatever that run used, not ours.
tmux("kill-session", "-t", SESSION)

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

def starts():
    try:
        with open(runs) as fh:
            return fh.read().count("ENGINE_STARTED")
    except OSError:
        return 0

def state():
    """Everything a timeout message needs to be read without a rerun."""
    return "window_width=%r clients=%r engine_starts=%d sessions=%r" % (
        width(), clients() or "none", starts(), tmux("ls").replace("\n", " ; "))

def require(cond, what, secs=20):
    """wait_for, with its answer made LOAD-BEARING (#101).

    A bounded wait whose return value is dropped turns "this has not happened
    yet" into "the value is wrong": the caller went straight on to print the
    width, got the stale one, and the failure read as a broken resize. On a
    loaded host that false negative was two runs in three — precisely the shape
    that teaches a reader to explain red away instead of read it. A timeout now
    says it timed out, and says what it last saw."""
    if wait_for(cond, secs):
        return
    sys.exit("timed out after %ss waiting for %s; last observed %s"
             % (secs, what, state()))

first = attach(100, 30)
require(lambda: SESSION in tmux("ls") and started(1),
        "the tank's tmux session to exist with its engine started")
# 🔴 WAIT FOR THE CLIENT, NOT JUST FOR THE SESSION — this is #101.
# clikae creates the session DETACHED and already sized from the terminal
# (`new-session -d -x 100 -y 30`, see lib/core/tmux.sh), and only afterwards
# attaches to it. So "the session exists", "the engine started", "the window is
# 100 columns wide" and "nothing is attached" are ALL true in the gap before the
# first client lands — and on a loaded host that gap is wide. The test used to
# run its whole detach step inside it: the detach was a no-op on a session with
# no clients, the wait for `session_attached == 0` was vacuously true, the second
# client attached, and the first client arrived AFTERWARDS. Two clients, and
# under `window-size latest` the window follows the one that attached LAST — so
# it went back to 100 and stayed there for as long as the test was willing to
# look. Measured on a throwaway server under load: with a real detach the switch
# lands in 0.29s; with both clients attached the window sits at the later
# attacher's size indefinitely and returns to the other's the instant it leaves.
require(lambda: attached(first), "the first client to attach")
# …and wait for the RESIZE too, not just for the session to exist. The second
# measurement below already waits for its width; this one did not, so it raced
# tmux propagating the client size and read default-size 80 instead of 100 —
# intermittently on ubuntu CI, never on macOS. The file's own wait_for docstring
# names this shape: a timing guess, not a defect.
require(lambda: width() == "100", "the window to follow the first client (100 columns)")
print("FIRST_WIDTH", width())

tmux("detach-client", "-s", SESSION)
# THIS session, not "any session". The first version asked whether anything in
# tmux was attached, which is never false on a developer's machine — so it burned
# its whole timeout every run, and under a loaded suite that wasted time pushed
# the test past the stub engine's lifetime. The session then died, the second
# attach created a NEW one, and the "engine started exactly once" assertion
# failed for a reason that had nothing to do with roaming.
#
# The list, not `#{session_attached}`: they answer the same question, but a list
# can be PRINTED in a timeout message, and this is the step whose silence cost
# #101 six red CI runs.
require(lambda: not clients(), "every client to leave the session")
print("SURVIVED_DETACH", "yes" if SESSION in tmux("ls") else "no")

second = attach(60, 20)
require(lambda: attached(second), "the second client to attach")
require(lambda: client_width(second) == "60",
        "the second client to be the 60-column terminal we gave it")
require(lambda: width() == "60", "the window to follow the second client (60 columns)")
print("SECOND_WIDTH", width())
print("SECOND_CLIENT_WIDTH", client_width(second))

tmux("kill-session", "-t", SESSION)
PYEOF

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # The window follows whichever client is in front of you — which, under
  # `window-size latest`, means the one that attached most recently, and is only
  # unambiguous while it is the ONLY one attached. Roaming is exactly that case:
  # you left the other device behind. (Two at once is a real thing tmux supports
  # and clikae allows; what it does then is in docs/EXPECTATIONS.md, and it is
  # not what this test is about.)
  [[ "$output" == *"FIRST_WIDTH 100"* ]]  || { echo "$output"; false; }
  [[ "$output" == *"SURVIVED_DETACH yes"* ]] || { echo "$output"; false; }
  [[ "$output" == *"SECOND_WIDTH 60"* ]] || { echo "$output"; false; }
  # …and the window is 60 because the second TERMINAL is 60, not because
  # something else resized it while we were not looking.
  [[ "$output" == *"SECOND_CLIENT_WIDTH 60"* ]] || { echo "$output"; false; }
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
  [[ "$output" == *"CLIENT_ON clikae-codex-roam"* ]] || { echo "$output"; false; }
  [ "$(grep -c ENGINE_STARTED "$STUB_RUNS")" -eq 1 ] || { cat "$STUB_RUNS"; false; }
}

@test "resuming a different session opens a second screen, not the one already up" {
  # The bug, reported 2026-08-13 and reproduced before this test existed: open a
  # tank, then from the board resume a DIFFERENT past session on the same tank.
  # The tmux session was named after the tank alone, so the second launch found
  # `clikae-codex-roam2` running and attached to it — two tabs, one screen — and the
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

def starts():
    try:
        with open(runs) as fh:
            return fh.read().count("STARTED")
    except OSError:
        return 0

def require(cond, what, secs=20):
    """Same as roam's first test: a dropped bounded wait makes a timeout
    impersonate a wrong value (#101). Here it would have read as "only one
    session was created" — a real, reported bug — when the truth was that the
    second launch had not finished yet."""
    if wait_for(cond, secs):
        return
    sys.exit("timed out after %ss waiting for %s; last observed engine_starts=%d sessions=%r"
             % (secs, what, starts(),
                tmux("list-sessions", "-F", "#{session_name}").split()))

launch("codex", "roam2")
require(lambda: started(1), "the first launch's engine to start")
launch("codex", "roam2", "--", "resume", "SESSION-TWO")
require(lambda: started(2), "the second, differently-keyed launch's engine to start")

names = sorted(n for n in tmux("list-sessions", "-F", "#{session_name}").split()
               if n.startswith("clikae-codex-roam2"))
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
