#!/usr/bin/env python3
"""Drive clikae's interactive screens in a REAL pty — the layer bats cannot reach.

bats never simulates a keypress through a live key loop, and shellcheck cannot
see runtime behaviour at all. That blind spot has shipped real bugs more than
once; most recently the whole `exec … 2>/dev/null` family, which pointed the
board's stderr at /dev/null and so made three prompts invisible, muted every
error from a board-launched subcommand, and handed a dead stderr to the engine
itself — all while the gate stayed green.

So this runs in the gate now (`scripts/test.sh`), and it is hermetic: every mode
builds its own throwaway $HOME and $CLIKAE_HOME with fixture tanks, pins
CLIKAE_LANG=en-US so assertions are deterministic, and puts a stub engine on
PATH. It never reads or writes your real store, and never launches a real engine.

    python3 tests/tools/pty-smoke.py all       # what the gate runs
    python3 tests/tools/pty-smoke.py home      # board: nav keys + submenu
    python3 tests/tools/pty-smoke.py prompts   # n / a / m prompts + engine stderr
    python3 tests/tools/pty-smoke.py resume    # resume picker: keys, filter, quit

The child gets the pty as its CONTROLLING terminal (setsid + TIOCSCTTY) —
without it, /dev/tty opens fail inside the app and every sub-menu is invisible,
which reads as a false regression.
"""
import os, pty, sys, time, select, subprocess, fcntl, termios, struct, shutil, tempfile, signal

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CLIKAE = os.path.join(REPO, 'bin', 'clikae')

# A stub engine that writes to BOTH streams. The board execs through to the real
# binary, so this is how we prove the launched engine still owns its stderr.
STUB = '#!/bin/sh\necho "STUB-STDOUT"\necho "STUB-STDERR" >&2\n'

_SANDBOXES = []


def sandbox(tanks=(('claude', 'alpha'), ('claude', 'beta'), ('codex', 'gamma')),
            seed_session=False):
    """A throwaway HOME + CLIKAE_HOME with fixture tanks and a stub `claude`."""
    root = tempfile.mkdtemp(prefix='clikae-pty-')
    _SANDBOXES.append(root)
    for engine, tank in tanks:
        os.makedirs(os.path.join(root, '.clikae', 'profiles', engine, tank), exist_ok=True)
    # Answer the wake question up front. A launch asks once, on a terminal, and
    # this harness IS a terminal — so without this every launched-engine check
    # would sit at that prompt and report the engine's output as missing, which
    # is exactly how it failed the first time.
    os.makedirs(os.path.join(root, '.clikae'), exist_ok=True)
    with open(os.path.join(root, '.clikae', 'wake-on-reset'), 'w') as f:
        f.write('off\n')
    if seed_session:
        d = os.path.join(root, '.clikae', 'profiles', 'claude', 'alpha', 'projects', '-w')
        os.makedirs(d, exist_ok=True)
        sid = 'aaaaaaaa-1111-2222-3333-444444444444'
        with open(os.path.join(d, sid + '.jsonl'), 'w') as f:
            f.write('{"type":"ai-title","aiTitle":"a seeded session","sessionId":"%s"}\n' % sid)
            for i in range(1, 40):
                f.write('{"type":"user","cwd":"/tmp/w","message":'
                        '{"role":"user","content":"line %d"}}\n' % i)
    binp = os.path.join(root, 'bin')
    os.makedirs(binp, exist_ok=True)
    # 🔴 HOST SAFETY. agy's per-tank login carry shells out to `security`, so a
    # pty run without this stub reads, WRITES and DELETES the maintainer's real
    # `gemini` Keychain item. bats has had this guard since the day it cost
    # somebody a live login; this harness did not, and any agy test added here
    # without it would corrupt a real credential to make itself pass.
    # Same file bats uses — one stub, no drifting second copy.
    # Same host-independence problem, different tool: agy's "is a session
    # running?" guard is `pgrep -x agy`, so on a machine with a real Antigravity
    # open the guard fires against the DEVELOPER's session and the test skips —
    # which is how this one first reported "could not init an agy tank" while
    # the code was working exactly as designed.
    with open(os.path.join(binp, 'pgrep'), 'w') as f:
        f.write('#!/usr/bin/env bash\nexit 1\n')
    os.chmod(os.path.join(binp, 'pgrep'), 0o755)

    kc = os.path.join(root, '.testkeychain')
    os.makedirs(kc, exist_ok=True)
    shutil.copy(os.path.join(REPO, 'tests', 'stubs', 'security'),
                os.path.join(binp, 'security'))
    os.chmod(os.path.join(binp, 'security'), 0o755)
    # 🔴 The tmux isolation below is only as good as the DIRECTORY it points at.
    # A deleted $TMUX_TMPDIR makes tmux fall back to /tmp — the developer's own
    # socket — with no error at all, so an isolation that reads correctly can be
    # absent at runtime. This guard refuses that one case and execs the real tmux
    # otherwise. It is on PATH rather than in the test bodies because clikae
    # resolves tmux through PATH too, and the engine's own internal calls are the
    # half that auditing the test sources cannot see.
    shutil.copy(os.path.join(REPO, 'tests', 'stubs', 'tmux-guard'),
                os.path.join(binp, 'tmux'))
    os.chmod(os.path.join(binp, 'tmux'), 0o755)

    for name in ('claude', 'codex', 'agy'):
        p = os.path.join(binp, name)
        with open(p, 'w') as f:
            f.write(STUB)
        os.chmod(p, 0o755)
    env = dict(os.environ)
    env.update({'HOME': root, 'CLIKAE_HOME': os.path.join(root, '.clikae'),
                'CLIKAE_LANG': 'en-US', 'TERM': 'xterm-256color',
                'PATH': binp + os.pathsep + env.get('PATH', ''),
                # 🔴 The opt-out is CLIKAE_NO_UPDATE_CHECK (lib/core/update_check.sh
                # :67, :104). This said CLIKAE_UPDATE_CHECK=0, which NOTHING reads —
                # so every pty-smoke run has been making a live `curl` to the GitHub
                # releases API, on the pre-board path, with a 5s timeout. A gate that
                # depends on the network is not a gate; it is a flake generator.
                'CLIKAE_TEST_KEYCHAIN': kc,
                'CLIKAE_NO_UPDATE_CHECK': '1'})
    # Host-safety: this harness IS a terminal, so clikae takes the tmux path and
    # really does create sessions. A throwaway $HOME does not contain those — the
    # tmux socket is chosen by $TMUX / $TMUX_TMPDIR, neither of which HOME touches
    # — so without this a smoke run left clikae's own sessions on the developer's
    # server, and anything that later swept them would sweep live tanks with them.
    # $TMUX must be REMOVED rather than overridden: a tmux client prefers it over
    # TMUX_TMPDIR, so setting only the latter changes nothing when the suite is
    # run from inside tmux, which is the normal way to run it here.
    env.pop('TMUX', None)
    env.pop('TMUX_PANE', None)
    env['TMUX_TMPDIR'] = os.path.join(root, 'tmux')
    os.makedirs(env['TMUX_TMPDIR'], exist_ok=True)
    return env


def drive(cmd, keys, env, timeout=25, settle=None, per_key=None):
    """Send `keys` to `cmd` on a pty, returning (exit status, everything drawn).

    Pacing is IDLE-BASED, not fixed sleeps: after each key we read until the
    child has been quiet for `idle` seconds (capped), because a TUI goes silent
    once it has finished drawing a frame. Fixed sleeps made this ~4x slower for
    no extra reliability, and slow gates get skipped. `settle`/`per_key` are
    accepted as per-call caps for the rare screen that needs longer.
    """
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 110, 0, 0))

    def make_ctty():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    p = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                         preexec_fn=make_ctty, env=env, close_fds=True)
    os.close(slave)
    out = b''

    def pump(cap, idle=0.30):
        """Read until `idle` seconds of silence, or `cap` seconds total."""
        nonlocal out
        end = time.time() + cap
        last = time.time()
        while time.time() < end:
            r, _, _ = select.select([master], [], [], 0.05)
            if r:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    return
                if not chunk:
                    return
                out += chunk
                last = time.time()
            elif time.time() - last >= idle:
                return
            if p.poll() is not None:
                return

    pump(settle or 4.0)
    for k in keys:
        if p.poll() is not None:
            break
        try:
            os.write(master, k.encode())
        except OSError:
            break
        pump(per_key or 4.0)
    end = time.time() + timeout
    while p.poll() is None and time.time() < end:
        pump(0.4)
    rc = p.returncode if p.poll() is not None else 'TIMEOUT'
    if rc == 'TIMEOUT':
        p.kill()
    try:
        os.close(master)
    except OSError:
        pass
    return rc, out.decode('utf-8', 'replace')


_failed = []


def skip(name, why):
    """A check this run could not perform. NOT a pass and NOT a failure.

    🔴 mode_size needs tmux, and GitHub's macos-latest runner does not have it.
    Without this the gate turned CI red for a missing tool rather than a defect
    — which is how a real red gets ignored. Two other scripts written the same
    day carry this rule in their headers; this file was the one that did not.
    """
    print('skip ' + name + '  (' + why + ')')


def check(name, ok, detail=''):
    print(('ok   ' if ok else 'FAIL ') + name)
    if not ok:
        _failed.append(name)
        if detail:
            print('       ' + detail.replace('\n', '\n       ')[:1500])
    return ok


# --------------------------------------------------------------------------- #

def mode_home():
    env = sandbox()
    rc, out = drive([CLIKAE, 'home'],
                    ['j', 'k', '\x1b[B', '\x1b[A', '\x1b[6~', '\x1b[5~', '\t', '\x1b[Z', 'q'],
                    env)
    check('board exits 0 after nav keys', rc == 0, out[-600:])
    check('board rendered', 'Tanks' in out, out[-600:])
    rc, out = drive([CLIKAE, 'home'], ['l', '\x1b[B', 'q', 'j', 'q'], env)
    check('language submenu opens, cancel returns to a live board',
          rc == 0 and 'en-US' in out and 'ja-JP' in out, out[-600:])
    rc, out = drive([CLIKAE, 'home'], ['?', ' ', 'q'], env)
    check('help overlay opens and dismisses', rc == 0, out[-600:])

    # A filter matching NOTHING must show the notice and leave the board alive.
    # `grep -c .` exits 1 on zero matches, and under the board's `set -eo
    # pipefail` that killed the process: rc=1, blank screen, no message — so
    # T_FILTER_NONE had never rendered once, in any of the nine locales.
    # TWO `q`s: in the no-match state any non-`/` key CLEARS the filter and
    # returns to the board; the second one quits. With one `q` this times out.
    rc, out = drive([CLIKAE, 'home'], ['/', 'zzzznomatch\r', 'q', 'q'],
                    env, per_key=2.0)
    check('no-match filter shows the notice', 'no matches' in out.lower(), out[-600:])
    check('no-match filter does not kill the board', rc == 0, out[-600:])

    # …and the state is escapable by re-filtering, not only by quitting.
    rc, out = drive([CLIKAE, 'home'], ['/', 'zzzznomatch\r', '/', 'alpha\r', 'q'],
                    env, per_key=2.0)
    check('re-filtering out of the empty state works',
          rc == 0 and 'no matches' in out.lower(), out[-600:])

    # NB the Resume-footer defect (_home_total_sessions returning "N\n0", so
    # printf died with `invalid number` and the board printed "0 sessions total"
    # above the sessions it had just listed) is NOT asserted here on purpose:
    # this sandbox seeds no sessions, so the footer never renders and the check
    # would pass on the broken code — decoration, not a gate. It is pinned in
    # tests/bats/home.bats instead, where the fixture can seed transcripts and
    # the test sets `set -o pipefail` itself (the bug does not exist without it).


def mode_prompts():
    """The regression net for the invisible-prompt / dead-stderr class.

    Every assertion here is about something REACHING THE TERMINAL. bash writes
    `read -p` prompts to stderr, so each of these went blank when the board's
    stderr was pointed at /dev/null — with the process still alive and still
    accepting input, which is why it read as a hang rather than a crash.
    """
    env = sandbox()

    # `n` — pick the first engine, then the tank-name prompt must be VISIBLE.
    # An empty name cancels, so nothing is created.
    rc, out = drive([CLIKAE, 'home'], ['n', '\r', '\r', '\r', 'q'], env, per_key=1.0)
    check('n: engine picker renders', 'New tank' in out, out[-800:])
    check('n: tank-name prompt is visible', 'Tank name for' in out, out[-800:])

    # `a` — rename prompt on the selected tank. Empty input cancels.
    rc, out = drive([CLIKAE, 'home'], ['a', '\r', '\r', 'q'], env, per_key=1.0)
    check('a: rename prompt is visible', 'New name' in out, out[-800:])

    # `m` — the memory (Soul) dial. Its submenu is a picker preselected on
    # "share", so Enter lands on the group-name prompt. Assert the PROMPT, not
    # just the menu: the menu draws on its own /dev/tty fd and stayed visible
    # even when stderr was dead, so a menu-only assertion catches nothing.
    rc, out = drive([CLIKAE, 'home'], ['m', '\r', '\r', '\r', 'q'], env, per_key=1.0)
    check('m: memory dial renders', 'Memory (Soul)' in out, out[-800:])
    check('m: group-name prompt is visible', 'Group name:' in out, out[-800:])

    # The worst symptom: the engine launched from the board inherits fd 2.
    rc, out = drive([CLIKAE, 'home'], ['\r'], env, per_key=1.5)
    check('launched engine keeps stdout', 'STUB-STDOUT' in out, out[-800:])
    check('launched engine keeps STDERR', 'STUB-STDERR' in out, out[-800:])

    # An error from a board-launched subcommand must be readable. Creating a
    # tank that already exists makes `clikae init` log_fail on stderr.
    rc, out = drive([CLIKAE, 'home'], ['n', '\r', 'alpha\r', '\r', 'q'], env, per_key=1.2)
    check('board-launched subcommand errors are visible',
          'already exists' in out, out[-800:])


def mode_resume():
    env = sandbox(seed_session=True)
    dbg = tempfile.mktemp(prefix='clikae-pty-dbg-')
    env = dict(env, CLIKAE_RESUME_DEBUG=dbg)
    keys = ['\x1b[B', '\x1b[B', '\x1b[A', '\x1b[6~', '\x1b[5~', '\x1b[F', '\x1b[H',
            'j', 'k', 'G', 'g', '5', '\x1bOB', 'q']
    rc, out = drive([CLIKAE, 'resume'], keys, env)
    check('picker exits 0 after full key traversal', rc == 0, out[-600:])
    log = open(dbg).read() if os.path.exists(dbg) else ''
    for sym in ('key=down', 'key=up', 'key=pgdn', 'key=pgup', 'key=end',
                'key=home', 'key=G', 'key=5', 'key=q'):
        check('debug log saw ' + sym, sym in log)
    if os.path.exists(dbg):
        os.unlink(dbg)
    rc, _ = drive([CLIKAE, 'resume'], ['\x1b'], env)
    check('lone ESC quits the picker', rc == 0)
    rc, out = drive([CLIKAE, 'resume'],
                    ['/', 'seeded\r', 'j', '/', 'zzzznomatch\r', 'q', 'q'], env)
    check('filter flow exits 0', rc == 0, out[-600:])
    check('no-match notice shown', 'no matches' in out.lower(), out[-600:])



def mode_size():
    """A tmux session must be born at the TERMINAL's size, not tmux's default.

    `tmux new-session -d` is detached, and a detached session has no client to
    take its size from, so tmux uses `default-size` — 80x24. The engine paints
    its first frame for 80 columns; only afterwards do we attach and tmux
    resizes the window. Nothing repaints (there is no SIGWINCH handling in
    clikae), so the first screen you see was laid out for a terminal you are
    not using.

    Reported 2026-08-16 from a PineNote over ssh. Measured against the code
    before the fix: 80x24 at every pty width tried. This is a pty test and not
    a bats one because the size comes from `stty size </dev/tty`, and bats has
    no controlling terminal — there, the check would pass by not looking.
    """
    import tempfile as _tf, shutil as _sh, select as _sel, time as _t
    if not shutil.which('tmux'):
        skip('session born at the terminal size', 'tmux is not installed here')
        return
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    for cols, rows in ((60, 30), (140, 40)):
        tmpdir = _tf.mkdtemp(); chome = _tf.mkdtemp()
        # This mode builds its own environment rather than going through
        # sandbox(), so it needs the guard installed explicitly — and it is the
        # mode that was MEASURED killing the developer's server, so leaving it
        # as the one uncovered path would defeat the point.
        gbin = _tf.mkdtemp()
        _sh.copy(os.path.join(root, 'tests', 'stubs', 'tmux-guard'),
                 os.path.join(gbin, 'tmux'))
        os.chmod(os.path.join(gbin, 'tmux'), 0o755)
        script = (
            'export PATH="%s:$PATH"\n'
            'export TMUX_TMPDIR="%s"; unset TMUX TMUX_PANE\n'
            'export CLIKAE_HOME="%s"\n'
            'cd %s || exit 1\n'
            '. lib/core/log.sh 2>/dev/null\n'
            '. lib/core/tmux.sh\n'
            "tmux_spawn_session --session cksize -- 'sleep 30' >/dev/null 2>&1; echo RC=$?\n"
            'sleep 1\n'
            'echo "OUT=$(tmux display-message -p -t cksize \'#{window_width}x#{window_height}\' 2>&1)"\n'
            'tmux kill-server 2>/dev/null\n'
        ) % (gbin, tmpdir, chome, root)
        pid, fd = pty.fork()
        if pid == 0:
            os.execvp('bash', ['bash', '-c', script])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
        out = b''; t0 = _t.time()
        while _t.time() - t0 < 30:
            r, _, _ = _sel.select([fd], [], [], 0.5)
            if r:
                try:
                    c = os.read(fd, 4096)
                except OSError:
                    break
                if not c:
                    break
                out += c
            if b'OUT=' in out:
                break
        # 🔴 WAIT FOR THE CHILD BEFORE DELETING ITS SANDBOX. This was WNOHANG —
        # "look, don't wait" — so the parent returned the instant it had read
        # OUT= and deleted $TMUX_TMPDIR while the child had NOT yet reached its
        # own `tmux kill-server` line. tmux answers a missing TMUX_TMPDIR by
        # silently falling back to /tmp (see tests/stubs/tmux-guard), so that
        # kill landed on the maintainer's real server: four live tanks, twice in
        # one afternoon. The race is also why it looked intermittent — under
        # load the child lags further behind the parent, which is exactly when
        # the gate is running.
        deadline = _t.time() + 10
        while _t.time() < deadline:
            try:
                if os.waitpid(pid, os.WNOHANG)[0] == pid:
                    break
            except Exception:
                break
            _t.sleep(0.05)
        else:
            try:
                os.kill(pid, 9); os.waitpid(pid, 0)
            except Exception:
                pass
        _sh.rmtree(tmpdir, ignore_errors=True); _sh.rmtree(chome, ignore_errors=True)
        _sh.rmtree(gbin, ignore_errors=True)
        txt = out.decode(errors='replace').replace('\r', '')
        want = '%dx%d' % (cols, rows)
        check('session born at the terminal size (%s)' % want,
              ('OUT=' + want) in txt,
              'wanted OUT=%s, got:\n%s' % (want, txt))



def mode_resize():
    """The board must reflow when the terminal is resized, without a keypress.

    tui_read_key blocks on `read -rsn1 -u 3` — the argument is a file
    descriptor, not a timeout — so the loop sits there until a key arrives.
    Every layout figure is read per draw, so the board could always reflow;
    nothing asked it to. A trap on WINCH makes the blocking read return, and
    the loop repaints instead of quitting.

    Assertion: start wide, shrink, and require that the LAST frame drawn has no
    line wider than the new width. Measured against the code before the fix,
    the frame stayed at its wide layout until a key was pressed.
    """
    import time as _t, select as _sel, re as _re
    env = sandbox()
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 120, 0, 0))

    def make_ctty():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    p = subprocess.Popen([CLIKAE, 'home'], stdin=slave, stdout=slave, stderr=slave,
                         preexec_fn=make_ctty, env=env, close_fds=True)
    os.close(slave)

    def pump(seconds):
        buf = b''
        t0 = _t.time()
        while _t.time() - t0 < seconds:
            r, _, _ = _sel.select([master], [], [], 0.2)
            if r:
                try:
                    c = os.read(master, 8192)
                except OSError:
                    break
                if not c:
                    break
                buf += c
        return buf

    _first = pump(2.0)                          # first frame, at 120 columns
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 52, 0, 0))
    os.kill(p.pid, signal.SIGWINCH)
    after = pump(2.5)                           # whatever it repaints, at 52
    try:
        os.write(master, b'q')
        p.wait(timeout=8)
    except Exception:
        p.kill()
    os.close(master)

    if os.environ.get('PTY_DEBUG'):
        import re as _dre
        _strip = lambda b: _dre.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', b.decode(errors='replace')).replace('\r', '')
        sys.stderr.write('--- before (%d bytes) ---\n%s\n' % (len(_first), _strip(_first)[:500]))
        sys.stderr.write('--- after  (%d bytes) ---\n%s\n' % (len(after), _strip(after)[:500]))
    txt = after.decode(errors='replace').replace('\r', '')
    txt = _re.sub(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07', '', txt)
    lines = [l for l in txt.split('\n') if l.strip()]
    check('the board repainted after the resize', bool(lines),
          'nothing was drawn after SIGWINCH')
    over = [l for l in lines if len(l) > 52]
    check('no line wider than the new width after resize', not over,
          'widest: %r' % (max(over, key=len)[:120] if over else ''))




def mode_height():
    """The board must fit the terminal's HEIGHT, and keep the selection on screen.

    0.28.0 made every row fit the terminal's WIDTH. Nothing ever made the frame
    fit its HEIGHT: measured on a real store, the board emitted the same 21 lines
    at every terminal height from 12 to 40. On anything shorter the top scrolled
    away — the wordmark, the keybar that teaches the keys, and the first rows —
    and the selection cursor could sit off-screen entirely, so `↑` moved a
    highlight nobody could see.

    Three assertions, and the third is the one that keeps the fix honest:
      1. on a SHORT terminal the frame never exceeds it,
      2. jumping to the last row keeps the cursor visible,
      3. on a TALL terminal the board is drawn WHOLE, with no window indicator —
         a viewport that engages when it is not needed would be a regression
         dressed as a feature, and every existing board fits.
    """
    import time as _t, select as _sel, re as _re
    tanks = tuple(('claude', 'tank%02d' % i) for i in range(1, 15))
    env = sandbox(tanks=tanks)

    def frame_at(rows, cols, keys=b''):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

        def make_ctty():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        p = subprocess.Popen([CLIKAE, 'home'], stdin=slave, stdout=slave, stderr=slave,
                             preexec_fn=make_ctty, env=env, close_fds=True)
        os.close(slave)

        # 🔴 WAIT FOR THE FRAME, DON'T WAIT A FIXED 2.5 SECONDS. Measured
        # 2026-08-21, on a machine that had just rebooted: the FIRST board in a
        # fresh sandbox returned 0 bytes inside 2.5s and a complete 13-line
        # frame inside 8s. Cold, this mode reported two failures; warm, the same
        # commit was green — the code never changed, only the clock.
        #
        # Worse than flaky: `nl <= ROWS - 1` and `'⋯' not in ttxt` are both
        # SATISFIED BY AN EMPTY CAPTURE, so a timeout did not just lose the two
        # loud checks, it turned three quiet ones green for having seen nothing.
        # Hence a deadline that is a cap rather than a wait, plus the emptiness
        # assertions below.
        #
        # 🔴 AND SETTLING ON SILENCE IS NOT ENOUGH — settling on VISIBLE output
        # is. Measured timeline for one cold board:
        #
        #   1.02s  +22 bytes   0 printable   <- cursor/mode escapes
        #          ~2.2s of SILENCE while the board computes
        #   3.23s  +698 bytes  335 printable <- the actual frame
        #
        # A plain idle-settle returns inside that gap with nothing but escape
        # codes, which `strip()` reduces to '' — indistinguishable from a board
        # that drew nothing. This is the second time that gap has broken a pty
        # helper here, so the condition is written against what we came to read
        # rather than against a silence long enough to hope it is over.
        def pump(seconds, settle=0.4):
            buf = b''
            t0 = _t.time()
            last = None
            while _t.time() - t0 < seconds:
                r, _, _ = _sel.select([master], [], [], 0.2)
                if r:
                    try:
                        c = os.read(master, 8192)
                    except OSError:
                        break
                    if not c:
                        break
                    buf += c
                    last = _t.time()
                elif last is not None and (_t.time() - last) >= settle \
                        and strip(buf).strip():
                    break                      # drew something, then went quiet
            return buf

        first = pump(20)
        after = b''
        if keys:
            os.write(master, keys)
            after = pump(10)
        try:
            os.write(master, b'q')
            p.wait(timeout=8)
        except Exception:
            p.kill()
        os.close(master)
        return first, after

    def strip(b):
        t = b.decode(errors='replace').replace('\r', '')
        return _re.sub(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07', '', t)

    # --- 1. a short terminal ------------------------------------------------
    ROWS = 14
    first, _ = frame_at(ROWS, 100)
    txt = strip(first)
    # 🔴 NON-VACUITY, and it belongs before everything else. Both checks below
    # pass on an empty string, so a capture that timed out used to be reported
    # as a board that fits. A check that cannot tell "correct" from "absent" is
    # not a check.
    check('the short-terminal board drew a frame at all', txt.strip() != '',
          'captured nothing from `clikae home` on a %d-row pty' % ROWS)
    # The frame homes the cursor and advances one line per newline, so it must
    # carry at most rows-1 of them or the screen scrolls.
    nl = txt.count('\n')
    check('the board fits a %d-row terminal' % ROWS, nl <= ROWS - 1,
          'frame carries %d newlines, budget %d' % (nl, ROWS - 1))
    check('a windowed board says how many rows it is holding back', '⋯' in txt,
          'no ⋯ indicator in a frame that cannot show every row')

    # --- 2. the selection stays inside the window ---------------------------
    _f, after = frame_at(ROWS, 100, keys=b'G')
    gtxt = strip(after) or strip(_f)
    check('jumping to the last row keeps the cursor on screen', '❯' in gtxt,
          'no cursor mark after G')
    check('jumping to the last row scrolls the last tank into view',
          'tank14' in gtxt, 'tank14 not drawn after G')

    # --- 3. control: a TALL terminal is untouched ---------------------------
    tall, _ = frame_at(60, 100)
    ttxt = strip(tall)
    check('the tall-terminal board drew a frame at all', ttxt.strip() != '',
          'captured nothing from `clikae home` on a 60-row pty')
    check('a board that fits is drawn whole, with no window indicator',
          '⋯' not in ttxt, 'the viewport engaged on a 60-row terminal')
    missing = [t for _e, t in tanks if t not in ttxt]
    check('a board that fits shows every tank', not missing,
          'missing from a 60-row frame: %s' % (', '.join(missing[:5])))


def mode_agy():
    """`clikae agy <tank>` must land in a clikae-* tmux session, like every engine does.

    agy is a launch-only TARGET, and tmux is spawned in switch.sh's ENGINE path —
    targets never got it. `_agy_switch` ends in a bare `exec agy "$@"`, so an agy
    session is bound to the terminal tab that started it: invisible to the board's
    Live section, unreachable from another machine, and dead when the tab closes.
    Measured on the maintainer's Mac — four terminal tabs, two in tmux (both
    claude, launched through clikae), two outside it (one agy, one hand-launched).

    🔴 This is NOT about policing concurrency. agy is a single global login and
    several sessions can share it; that limit is the vendor's and clikae does not
    get a vote. The defect is only that the session never enters tmux at all.

    Assertion: after `clikae agy <tank>` on a real pty, a session named
    clikae-antigravity-<tank> exists on the sandbox's own tmux server.
    """
    import time as _t, subprocess as _sp
    if not shutil.which('tmux'):
        skip('agy lands in a tmux session', 'tmux is not installed here')
        return

    # NO pre-made tank dir. `clikae init agy` performs a takeover — it creates the
    # slots and the ~/.gemini link — and handing it an existing bare directory
    # leaves that half-done, so the pane dies on launch and the tmux session is
    # gone before the assertion looks. Let init build the whole thing.
    env = sandbox(tanks=())
    # The tank dir alone is not a set-up agy takeover; `clikae init agy` is what
    # creates the slots and the ~/.gemini link, and it asks before managing it.
    # 🔴 The shared STUB prints two lines and EXITS. A pane whose command exits
    # takes its tmux session with it, so the session this test is looking for was
    # created and gone before the assertion ran — the probe was killing its own
    # subject. agy must stay alive here, exactly as tmux-spawn.bats keeps a slow
    # codex around for the same reason.
    with open(os.path.join(os.path.dirname(env['PATH'].split(os.pathsep)[0]), 'bin', 'agy'), 'w') as f:
        f.write('#!/bin/sh\nsleep 30\n')
    os.chmod(os.path.join(os.path.dirname(env['PATH'].split(os.pathsep)[0]), 'bin', 'agy'), 0o755)

    init = _sp.run([CLIKAE, 'init', 'agy', 'g'], input='y\n', text=True,
                   capture_output=True, env=env)
    if init.returncode != 0:
        skip('agy lands in a tmux session',
             'could not init an agy tank in the sandbox: ' + (init.stderr or '')[:120])
        return

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 110, 0, 0))

    def make_ctty():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    p = subprocess.Popen([CLIKAE, 'agy', 'g'], stdin=slave, stdout=slave, stderr=slave,
                         preexec_fn=make_ctty, env=env, close_fds=True)
    os.close(slave)
    # Drain whatever the launch prints so the pty buffer never blocks the child;
    # what is asserted below is the tmux session's existence, not this output.
    _drain_end = _t.time() + 6
    while _t.time() < _drain_end:
        r, _, _ = select.select([master], [], [], 0.3)
        if not r:
            continue
        try:
            if not os.read(master, 65536):
                break
        except OSError:
            break

    def sessions():
        r = _sp.run(['tmux', 'ls'], capture_output=True, text=True, env=env)
        return (r.stdout or '') + (r.stderr or '')

    # Give the spawn a moment; the assertion is the session's existence, not its speed.
    found = ''
    for _ in range(10):
        found = sessions()
        if 'clikae-antigravity-g' in found:
            break
        _t.sleep(0.5)

    try:
        os.write(master, b'q')
        p.wait(timeout=5)
    except Exception:
        p.kill()
    try:
        _sp.run(['tmux', 'kill-server'], capture_output=True, env=env)
        os.close(master)
    except Exception:
        pass

    check('clikae agy lands in a clikae-* tmux session', 'clikae-antigravity-g' in found,
          'tmux sessions were: %r' % found.strip()[:200])


MODES = {'home': mode_home, 'prompts': mode_prompts, 'resume': mode_resume,
         'size': mode_size, 'resize': mode_resize, 'height': mode_height,
         'agy': mode_agy}


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else 'all'
    try:
        if which == 'all':
            # Derived from MODES, not a second hand-kept list. The literal that
            # used to live here silently excluded any mode added after it, which
            # is a test that exists and never runs — the same shape as a guard
            # that cannot fire, and just as invisible. MODES preserves insertion
            # order, so the run order is still the declared one.
            for name in MODES:
                print('--- ' + name)
                MODES[name]()
        elif which in MODES:
            MODES[which]()
        else:
            print('unknown mode: ' + which, file=sys.stderr)
            sys.exit(2)
    finally:
        for root in _SANDBOXES:
            shutil.rmtree(root, ignore_errors=True)
    if _failed:
        print('\n%d check(s) failed: %s' % (len(_failed), ', '.join(_failed)))
        sys.exit(1)
    sys.exit(0)


if __name__ == '__main__':
    main()
