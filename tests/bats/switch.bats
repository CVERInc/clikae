#!/usr/bin/env bats
# tests/bats/switch.bats — the bare switch (`clikae <engine> <tank>`) when the
# engine's binary isn't installed. clikae switches accounts; it doesn't install
# the CLI, so a missing binary should fail HELPFULLY (with a per-engine install
# hint when the adapter has one), not with a bare "exec: <bin>: not found".
# (Real-user launcher-journey friction.) `[[ … ]]` carry `|| false`; see tests/README.md.

load '../helpers'

bats_require_minimum_version 1.5.0   # for `run -<expected-code>`

# Run a switch with a PATH that has clikae's own deps (/usr/bin, /bin) but NOT the
# engine binary, so `command -v <bin>` fails deterministically regardless of host.
@test "switch fails helpfully with an install hint when claude isn't installed" {
  clikae init claude work
  PATH="/usr/bin:/bin" run -127 clikae claude work
  [[ "$output" == *"claude/work"* ]] || false
  [[ "$output" == *"isn't installed"* ]] || false
  [[ "$output" == *"npm install -g @anthropic-ai/claude-code"* ]] || false
}

@test "switch's not-installed message is generic for an engine with no hint (vercel)" {
  # vercel (a flag-strategy adapter, no install hint) is never in /usr/bin — gh
  # would be, on Ubuntu CI runners, so it'd slip past the restricted PATH.
  clikae init vercel work
  PATH="/usr/bin:/bin" run -127 clikae vercel work
  [[ "$output" == *"isn't installed"* ]] || false
  [[ "$output" == *"install 'vercel' and retry"* ]] || false
}

# The tmux pane command is `bash -c <target>`, ultimately run by tmux via `sh -c`.
# The old shape wrapped <target> in `"..."`, so sh EXPANDED a passthrough arg that
# carried a $, backtick, or double-quote — and a backtick / $(…) was EXECUTED.
# _switch_shquote single-quotes it so the built command survives byte-for-byte.
# Proven-fails-on-broken: the pre-fix `bash -c "$target_cmd"` mangles all three
# of these args (and runs the backtick), where this passes them through intact.
@test "_switch_shquote: a passthrough arg with \$, backtick, and quotes survives sh -c" {
  # _switch_shquote lives in core/tmux.sh now — three commands need it, and
  # sourcing the whole switch command just to reach one quoting helper hid that.
  source "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
  local prog="$BATS_TEST_TMPDIR/echoargs"
  printf '#!/usr/bin/env bash\nprintf "[%%s]" "$@"\n' > "$prog"
  chmod +x "$prog"
  # Exactly how switch.sh builds it: %q-quote the argv, then hand the whole thing
  # to `bash -c` as ONE shquoted word, then let `sh -c` run that (tmux's shell).
  local target_cmd
  target_cmd="$(printf '%q ' "$prog" 'say "hi"' '$HOME' 'a`b`c')"
  run sh -c "bash -c $(_switch_shquote "$target_cmd")"
  [ "$status" -eq 0 ]
  [ "$output" = '[say "hi"][$HOME][a`b`c]' ] || false
}

# 2026-09-12 round-1 review, the reviewer's concrete design (R1's "真正的修法"):
# claude accepts `--session-id <uuid>` up front (verified live: `claude --help`
# lists it), so a bare "start fresh" launch no longer has to wait for the
# engine to pick its own id before clikae can name it exactly.
@test "switch: a bare claude launch is stamped with a fresh uuid, handed to the engine as --session-id" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local tank="uu$$"
  local sess="clikae-claude-$tank"
  clikae init claude "$tank"
  cat <<'INNER_EOF' > "$TEST_HOME/.testbin/claude"
#!/usr/bin/env bash
printf '%s\n' "$@" > "${HOME:?}/claude-argv.log"
INNER_EOF
  chmod +x "$TEST_HOME/.testbin/claude"

  run _pty_run "$CLIKAE_BIN" claude "$tank"
  tmux kill-session -t "$sess" 2>/dev/null || true

  local stampfile="$TEST_HOME/.clikae/state/${sess}.session_id"
  [ -f "$stampfile" ] || { echo "no stamp written. output: $output"; ls -la "$TEST_HOME/.clikae/state/" 2>&1; false; }
  local sid; sid="$(cat "$stampfile")"
  [[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || { echo "stamp is not a v4-shaped uuid: '$sid'"; false; }

  [ -f "$TEST_HOME/claude-argv.log" ] || { echo "engine never ran. output: $output"; false; }
  grep -qx -- '--session-id' "$TEST_HOME/claude-argv.log" \
    || { echo "engine argv missing --session-id:"; cat "$TEST_HOME/claude-argv.log"; false; }
  grep -qFx -- "$sid" "$TEST_HOME/claude-argv.log" \
    || { echo "engine argv missing the stamped uuid:"; cat "$TEST_HOME/claude-argv.log"; false; }
}

# 2026-09-12 round-1 review, R1-P1-2: CLIKAE_LAUNCH_SID was an EXPORTED
# environment variable, never unset, so a tmux server born under it handed it
# to every session that server spawned afterwards — stamping a completely
# bare launch with a foreign sid, and (because that counted as "has recorded
# identity") with no "?" to say so. The mechanism is gone entirely now (argv
# is read directly via adapter_sid_from_args, never an env var), but an old
# shell profile or a leftover export from a prior clikae version could still
# put a variable of this name in someone's environment — prove a bare launch
# ignores it outright, rather than trusting the deletion alone.
@test "switch: an ambient CLIKAE_LAUNCH_SID-shaped variable does not leak into a bare launch's stamp" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local tank="uu2$$"
  local sess="clikae-claude-$tank"
  clikae init claude "$tank"
  cat <<'INNER_EOF' > "$TEST_HOME/.testbin/claude"
#!/usr/bin/env bash
: > "${HOME:?}/claude-ran"
INNER_EOF
  chmod +x "$TEST_HOME/.testbin/claude"

  # `env VAR=x _pty_run` would not work: _pty_run is a shell FUNCTION, not an
  # external command, and `env` cannot see it at all. A var=val prefix on the
  # call itself is exported into the environment for that one command,
  # functions included — no `env` needed.
  CLIKAE_LAUNCH_SID=sidFOREIGN run _pty_run "$CLIKAE_BIN" claude "$tank"
  tmux kill-session -t "$sess" 2>/dev/null || true

  [ -f "$TEST_HOME/claude-ran" ] || { echo "engine never ran. output: $output"; false; }
  local stampfile="$TEST_HOME/.clikae/state/${sess}.session_id"
  if [ -f "$stampfile" ]; then
    local sid; sid="$(cat "$stampfile")"
    [ "$sid" != "sidFOREIGN" ] || { echo "an ambient CLIKAE_LAUNCH_SID leaked into the stamp"; false; }
  fi
}
