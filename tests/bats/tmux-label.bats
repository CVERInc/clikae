#!/usr/bin/env bats
# tests/bats/tmux-label.bats — what the status bar says.
#
# That corner is on screen for the entire session, and for a long time it showed
# `[ck-claude-x:bash]`: an internal identifier plus the name of the shell that
# launched the engine rather than the engine. Nothing tested it because nothing
# was setting it — tmux was deriving it, and a default nobody chose is exactly
# the kind of thing that never gets looked at.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src_switch() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/commands/switch.sh"
}
_src_wake() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/wake.sh"
}

_sess() { printf 'cklbl-%s-%s' "$$" "${BATS_TEST_NUMBER:-0}"; }

teardown() {
  tmux kill-session -t "$(_sess)" 2>/dev/null || true
  [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
  return 0
}

@test "label: the bar names the tank in clikae's words, not the session id" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_switch
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  _switch_tmux_label "$(_sess)" claude work
  run tmux show-options -t "$(_sess)" status-left
  [[ "$output" == *"claude/work"* ]] || false
  # And the internal prefix is gone from what a person reads.
  [[ "$output" != *"ck-"* ]] || false
}

@test "label: the window is named after the engine, not the shell that starts it" {
  # The defect this replaces: three tanks open meant three windows called `bash`,
  # because the launch command is literally `bash -c …`.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_switch
  tmux new-session -d -s "$(_sess)" -n claude 'bash -c "sleep 30"'
  # Turn automatic-rename ON first. tmux ships with it on, but this machine's
  # config has it off — so without this line the assertion below passed with our
  # own `automatic-rename off` deleted, i.e. it was measuring the environment's
  # default and not the code. Set the condition the user actually has.
  tmux set-window-option -t "$(_sess)" automatic-rename on
  _switch_tmux_label "$(_sess)" claude work
  # `-n` alone does not hold: tmux renames a window after whatever is running in
  # it, so the name only survives because automatic-rename is turned off. Forcing
  # a respawn is what makes that visible in under a second — without it this test
  # passed with the option deleted, which is to say it was watching nothing.
  tmux respawn-pane -k -t "$(_sess)" 'sleep 30'
  sleep 1
  run tmux list-windows -t "$(_sess)" -F '#{window_name}'
  [ "$output" = "claude" ]
  [[ "$output" != *bash* ]] || false
  [[ "$output" != *sh ]] || false
}

@test "label: relabelling an existing session is safe to repeat" {
  # It runs on attach as well as on create, so a session started by an older
  # clikae picks the label up too.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_switch
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  _switch_tmux_label "$(_sess)" claude work
  _switch_tmux_label "$(_sess)" claude work
  run tmux show-options -t "$(_sess)" status-left
  [[ "$output" == *"claude/work"* ]] || false
}

@test "label: a session that is gone does not fail the caller" {
  # Cosmetics must never fail a launch — this runs right after the engine starts.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_switch
  run _switch_tmux_label "cklbl-nope-$$" claude work
  [ "$status" -eq 0 ]
}

@test "wake: the countdown reaches the window name, not just its own pane" {
  # Otherwise "it will resume itself" is invisible from the window you are in.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  WAKE_BUFFER_SECONDS=1
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  tmux new-window -d -t "$(_sess)" -n wake 'sleep 30'
  wake_sit "$(_sess)" "$(( $(date +%s) + 40 ))" >/dev/null &
  local sitter=$!
  sleep 2
  run tmux list-windows -t "$(_sess)" -F '#{window_name}'
  { kill "$sitter"; wait "$sitter"; } 2>/dev/null || true
  [[ "$output" == *"wake "* ]] || false      # "wake 39s", not bare "wake"
}

@test "keys: a clikae-made session forwards Shift+Enter instead of flattening it" {
  # tmux defaults to `extended-keys off`, which drops the modifier before the
  # application sees it — so Shift+Enter arrives as a plain Enter and an engine
  # that treats Enter as "send" submits instead of inserting a newline. Reported
  # 2026-08-13; the tmux layer had put a translator in the middle of the keyboard.
  #
  # A PRIVATE tmux server via TMUX_TMPDIR: these are SERVER options, and flipping
  # them on the shared one would reach into whatever the person running the suite
  # has open. It also makes the assertion honest — a default server may already
  # carry the setting from a previous session, so a pass would prove nothing.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init codex keys
  cat <<'INNER_EOF' > "$TEST_HOME/.testbin/codex"
#!/usr/bin/env bash
sleep 30
INNER_EOF
  chmod +x "$TEST_HOME/.testbin/codex"
  # A SHORT path, not $BATS_TEST_TMPDIR: a unix socket path is capped near 104
  # bytes on macOS and bats' per-test directory alone eats most of that, so the
  # server came back "File name too long" and the test read that as a failed
  # assertion rather than as a broken fixture.
  local sock="/tmp/ckkeys$$"; mkdir -p "$sock"

  # `-u TMUX` on every call. The suite may itself be running INSIDE tmux, and a
  # tmux client prefers $TMUX over TMUX_TMPDIR — so without this the assertions
  # would quietly interrogate the developer's own server instead of the private
  # one, which is how the first version of this test "failed" against a baseline
  # that was really somebody else's setting.
  #
  # Baseline on this fresh server: off, which is what makes the after-state mean
  # something.
  run env -u TMUX TMUX_TMPDIR="$sock" tmux start-server \; show -s extended-keys
  [[ "$output" == *off* ]] || { echo "$output"; false; }

  run python3 - "$CLIKAE_BIN" "$sock" <<'PYEOF'
import os, pty, fcntl, termios, struct, sys, time
clikae, sock = sys.argv[1], sys.argv[2]
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
pid = os.fork()
if pid == 0:
    os.setsid(); fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    for fd in (0, 1, 2): os.dup2(slave, fd)
    os.close(master); os.close(slave)
    os.environ["TERM"] = "xterm-256color"
    os.environ["TMUX_TMPDIR"] = sock
    os.environ.pop("TMUX", None)          # talk to the private server, not ours
    os.environ.pop("TMUX_PANE", None)
    os.execv(clikae, [clikae, "codex", "keys"])
os.close(slave)
time.sleep(4)
PYEOF

  run env -u TMUX TMUX_TMPDIR="$sock" tmux show -s extended-keys
  [[ "$output" == *on* ]] || { echo "$output"; false; }
  run env -u TMUX TMUX_TMPDIR="$sock" tmux show -sg terminal-features
  [[ "$output" == *extkeys* ]] || { echo "$output"; false; }
  env -u TMUX TMUX_TMPDIR="$sock" tmux kill-server 2>/dev/null || true
  rm -rf "$sock"
}
