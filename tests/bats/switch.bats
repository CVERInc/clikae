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
  source "$CLIKAE_TEST_ROOT/lib/commands/switch.sh"
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
