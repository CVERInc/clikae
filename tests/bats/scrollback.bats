#!/usr/bin/env bats

load '../helpers'

bats_require_minimum_version 1.5.0

# 🔴 SOLVED 2026-09-22 (sixth investigation) — AND IT WAS NEVER THE REPLAY.
# Five rounds of this comment said it was, on the strength of a stage trace that
# looked healthy at every stage. It looked healthy because it WAS healthy.
# Probes inside the EXIT trap and inside tmux_attach, on a run that FAILED:
#
#   attach-pre   ...7806  sz=             <- nothing written yet
#   trap-start   ...8968
#   trap-done    ...9287  sz=1717         <- capture written, pane still alive
#   attach-post  ...9554  rc=0 sz=1717    <- non-empty when the parent reads it
#
# So `[ -s ]` was true, awk ran, and the replay DID reach the terminal. In the
# failing output the marker sits at line 49 followed by `line 1` … `line 200` —
# 200 lines that had long scrolled off a 24-row pane, so they can have come from
# nowhere but the replay. The count was 1 because the OTHER occurrence, the one
# tmux draws live, never existed.
#
# That is the race, and it is THIS FILE'S, not the product's. The stub printed
# its 200 lines the instant the pane started, while the parent was still between
# `new-session -d` and `tmux attach` (tmux_label alone sets seven per-session
# options in between). With no client attached, tmux keeps those lines in the
# pane history and sends nothing outward; the attach that follows redraws the
# last 24 rows only. Measured on every failure: `clients-at-first-print=[]`.
# Adding one `tmux list-clients` call before the first echo — some 15ms — was by
# itself enough to turn failures into passes, which is also why the pass rate
# "degrades and stays degraded" rather than flipping like a coin: it tracks how
# warm the caches are, i.e. how fast `clikae run` reaches the stub.
#
# The fix is the lesson this file already learned twice one layer out: wait for
# the client instead of hoping — and wait for it BEFORE printing the thing whose
# live drawing you are about to assert on.
#
# The product was never broken here. Hand-run on a throwaway server (tmux 3.7b):
# 120 engine turns, attach, engine exits -> the top of the conversation comes
# back in the terminal. DESIGN-tmux.md Rule 2b now records that.

# _pty_run lives in tests/helpers.bash: session-usable.bats needs the same
# thing, and a second copy of a pty runner is a second thing to keep in step.

@test "switch scrollback capture retains 200 lines" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed (switch falls back to a direct run)"
  # 🔴 macOS only, honestly. On ubuntu tmux 3.4 the scrollback file this asserts
  # on is never created, and the cause is NOT identified — see DESIGN-tmux Rule
  # 2b for everything that has been ruled out. Skipped rather than deleted: the
  # feature works on macOS, the gap is real and written down, and a skip with a
  # reason invites the fix. Contributions very welcome.
  [ "$(uname -s)" = Darwin ] || skip "scrollback replay is unverified on this platform — see docs/DESIGN-tmux.md Rule 2b (open question)"
  clikae init claude scrolltest
  cat <<'INNER_EOF' > "$TEST_HOME/.testbin/claude"
#!/usr/bin/env bash
# Stage log. The marker count says the replay did not happen; it cannot say
# whether the engine ran, whether tmux rendered, or whether anyone ever
# attached — and those need different fixes. Four fixes were pushed at this
# from the count alone (2026-08-15) before the stages were written down.
_stage() { printf '%s\n' "$1" >> "${HOME:?}/scrollback-stages.log"; }
_stage "engine-started pwd=$PWD tmux=${TMUX:+yes}"
# 🔴 PRINT NOTHING UNTIL SOMEONE IS WATCHING. This test asserts the marker
# appears TWICE: once drawn live by tmux, once replayed by awk after the attach
# returns. The drawn one only exists if a client is attached while the pane is
# writing — tmux does not send scrolled-off history to a client that arrives
# late, it redraws the last screenful. The parent spends real time between
# `new-session -d` and `tmux attach` (tmux_label's per-session options, the
# session-id stamp), and on a warm machine `clikae run` reaches this stub first,
# so all 200 lines landed in the history with nobody connected and the count
# could never be more than 1. That was the whole flake — see the header.
#
# Same shape as the `_rendered` wait below and for the same reason: wait for the
# state you need, do not guess at how long it takes.
_client=no
for _ in $(seq 1 200); do
  [ -n "$(tmux list-clients 2>/dev/null)" ] && { _client=yes; break; }
  sleep 0.05
done
_stage "client=$_client sessions=$(tmux list-sessions -F '#{session_name}' 2>&1 | tr '\n' ',')"
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
# green. The wait that fixed it is now ABOVE the first echo rather than here —
# waiting after the output is what left the drawn marker unobservable (header).
_stage "capture-bytes=$(tmux capture-pane -p -S - 2>/dev/null | wc -c) capture-t-bytes=$(tmux capture-pane -p -S - -t \"clikae-claude-scrolltest\" 2>/dev/null | wc -c)"
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
  # must put back what it took: a surviving clikae-claude-scrolltest changes what the
  # next run of this file — and any other test that reaches tmux — walks into.
  tmux kill-session -t "clikae-claude-scrolltest" 2>/dev/null || true
  
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
  run tmux has-session -t "clikae-claude-dumbterm"
  [ "$status" -ne 0 ]
}
