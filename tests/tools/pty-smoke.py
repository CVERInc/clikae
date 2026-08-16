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
    for name in ('claude', 'codex'):
        p = os.path.join(binp, name)
        with open(p, 'w') as f:
            f.write(STUB)
        os.chmod(p, 0o755)
    env = dict(os.environ)
    env.update({'HOME': root, 'CLIKAE_HOME': os.path.join(root, '.clikae'),
                'CLIKAE_LANG': 'en-US', 'TERM': 'xterm-256color',
                'PATH': binp + os.pathsep + env.get('PATH', ''),
                'CLIKAE_UPDATE_CHECK': '0'})
    # Host-safety: this harness IS a terminal, so clikae takes the tmux path and
    # really does create sessions. A throwaway $HOME does not contain those — the
    # tmux socket is chosen by $TMUX / $TMUX_TMPDIR, neither of which HOME touches
    # — so without this a smoke run left `ck-*` sessions on the developer's own
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
        script = (
            'export TMUX_TMPDIR="%s"; unset TMUX TMUX_PANE\n'
            'export CLIKAE_HOME="%s"\n'
            'cd %s || exit 1\n'
            '. lib/core/log.sh 2>/dev/null\n'
            '. lib/core/tmux.sh\n'
            "tmux_spawn_session --session cksize -- 'sleep 30' >/dev/null 2>&1; echo RC=$?\n"
            'sleep 1\n'
            'echo "OUT=$(tmux display-message -p -t cksize \'#{window_width}x#{window_height}\' 2>&1)"\n'
            'tmux kill-server 2>/dev/null\n'
        ) % (tmpdir, chome, root)
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
        try:
            os.waitpid(pid, os.WNOHANG)
        except Exception:
            pass
        _sh.rmtree(tmpdir, ignore_errors=True); _sh.rmtree(chome, ignore_errors=True)
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


MODES = {'home': mode_home, 'prompts': mode_prompts, 'resume': mode_resume,
         'size': mode_size, 'resize': mode_resize}


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else 'all'
    try:
        if which == 'all':
            for name in ('home', 'prompts', 'resume', 'size', 'resize'):
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
