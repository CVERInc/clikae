#!/usr/bin/env python3
"""Drive clikae's interactive pickers in a REAL pty — the smoke layer bats can't
reach (bats never simulates keypresses through the live key loops, which is
exactly where the board regressed in dogfood more than once).

Usage:
    python3 tests/tools/pty-smoke.py resume   # picker: arrows/paging/filter/quit
    python3 tests/tools/pty-smoke.py home     # board: nav keys, submenu, quit

Needs a real session store under ~/.clikae (it drives the actual binary), so
it's a developer tool, not CI. Only ever sends navigation/cancel/quit keys —
never Enter on a row (that would launch an engine).

The child gets the pty as its CONTROLLING terminal (setsid + TIOCSCTTY) — without
that, /dev/tty opens fail inside the app and every sub-menu (_home_choose) is
invisible, which reads as a false regression.
"""
import os, pty, sys, time, select, subprocess, fcntl, termios, struct

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

def drive(cmd, keys, env_extra=None, timeout=25):
    env = dict(os.environ)
    if env_extra: env.update(env_extra)
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 32, 100, 0, 0))
    def make_ctty():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    p = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                         preexec_fn=make_ctty, env=env, close_fds=True)
    os.close(slave)
    out = b''
    def pump(dur):
        nonlocal out
        end = time.time() + dur
        while time.time() < end:
            r, _, _ = select.select([master], [], [], 0.05)
            if r:
                try: out += os.read(master, 65536)
                except OSError: return
            if p.poll() is not None: return
    pump(2.0)
    for k in keys:
        if p.poll() is not None: break
        os.write(master, k.encode())
        pump(0.4)
    end = time.time() + timeout
    while p.poll() is None and time.time() < end: pump(0.2)
    rc = p.returncode if p.poll() is not None else 'TIMEOUT'
    if rc == 'TIMEOUT': p.kill()
    try: os.close(master)
    except OSError: pass
    return rc, out.decode('utf-8', 'replace')

def check(name, ok):
    print(('ok   ' if ok else 'FAIL ') + name)
    return ok

def main():
    which = sys.argv[1] if len(sys.argv) > 1 else 'resume'
    clikae = os.path.join(REPO, 'bin', 'clikae')
    good = True
    if which == 'resume':
        import tempfile
        dbg = tempfile.mktemp(prefix='clikae-pty-dbg-')
        keys = ['\x1b[B', '\x1b[B', '\x1b[A', '\x1b[6~', '\x1b[5~', '\x1b[F', '\x1b[H',
                'j', 'k', 'G', 'g', '5', '\x1bOB', 'q']
        rc, _ = drive([clikae, 'resume'], keys, {'CLIKAE_RESUME_DEBUG': dbg})
        good &= check('picker exits 0 after full key traversal', rc == 0)
        log = open(dbg).read() if os.path.exists(dbg) else ''
        for sym in ('key=down', 'key=up', 'key=pgdn', 'key=pgup', 'key=end',
                    'key=home', 'key=G', 'key=5', 'key=q'):
            good &= check('debug log saw ' + sym, sym in log)
        if os.path.exists(dbg): os.unlink(dbg)
        # lone ESC quits
        rc, _ = drive([clikae, 'resume'], ['\x1b'])
        good &= check('lone ESC quits the picker', rc == 0)
        # filter round-trip: match, then no-match notice, then quit
        rc, out = drive([clikae, 'resume'],
                        ['/', 'claude\r', 'j', '/', 'zzzznomatch\r', 'q', 'q'])
        good &= check('filter flow exits 0', rc == 0)
        good &= check('no-match notice shown',
                      ('no matches' in out) or ('無相符項目' in out) or ('一致なし' in out))
    elif which == 'home':
        rc, out = drive([clikae, 'home'],
                        ['j', 'k', '\x1b[B', '\x1b[A', '\x1b[6~', '\x1b[5~', '\t', '\x1b[Z', 'q'])
        good &= check('board exits 0 after nav keys', rc == 0)
        good &= check('board rendered', ('Tanks' in out) or ('油箱' in out) or ('タンク' in out))
        rc, out = drive([clikae, 'home'], ['l', '\x1b[B', 'q', 'j', 'q'])
        good &= check('language submenu opens + cancel returns to a live board',
                      rc == 0 and ('en-US' in out and 'ja-JP' in out))
    sys.exit(0 if good else 1)

if __name__ == '__main__':
    main()
