#!/usr/bin/env bats
load '../helpers'
bats_require_minimum_version 1.5.0

# Second review of #246. Every fixture drives the real CLI in helpers.bash's
# throwaway HOME; the settings are the reviewer's own inputs.
_r2_settings() {
  [ -d "$CLIKAE_HOME/profiles/claude/A" ] || clikae init claude A >/dev/null
  R2_FILE="$CLIKAE_HOME/profiles/claude/A/settings.json"
  cat > "$R2_FILE"
  cp "$R2_FILE" "$BATS_TEST_TMPDIR/before.json"
  printf 'claude/A\n' > "$CLIKAE_HOME/state/cockpit"
}

_r2_unchanged() { [ -n "${R2_FILE:-}" ] && cmp "$BATS_TEST_TMPDIR/before.json" "$R2_FILE"; }

# _r2_expect_review <json-encoded command> -> --off kept the file byte for
# byte, named the command, failed, and never claimed to be off (twice over).
_r2_expect_review() {
  local _
  for _ in 1 2; do
    run clikae cockpit --off
    [ "$status" -eq 1 ]
    _r2_unchanged
    [ ! -e "$CLIKAE_HOME/state/cockpit" ]
    [[ "$output" == *"claude/A: hook entry left for you to check: $1"* ]] || false
    [[ "$output" == *'cockpit: state cleared; hook entries remain for you to check: claude/A'* ]] || false
    [[ "$output" != *'cockpit: off'* ]] || false
    [[ "$output" != *'already off'* ]] || false
  done
}

# _r2_expect_user -> --off left the file alone and reported a clean off.
_r2_expect_user() {
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  _r2_unchanged
  [[ "$output" == *'cockpit: off'* ]] || false
  [[ "$output" != *'left for you to check'* ]] || false
}

@test "246 r2 P2-1 guard_args, command_prefix, timeout_prefix, double_slash: a working guard copy is review, not a clean off" {
  local command
  for command in '/ex/hooks/cockpit-guard.sh --x' 'command /ex/hooks/cockpit-guard.sh' \
                 'timeout 5 /ex/hooks/cockpit-guard.sh' '/ex/hooks//cockpit-guard.sh'; do
    _r2_settings < <(jq -nc --arg c "$command" '{hooks:{PreToolUse:[{matcher:"Agent",hooks:[{type:"command",command:$c}]}]}}')
    _r2_expect_review "$(jq -nc --arg c "$command" '$c')"
  done
}

@test "246 r2 P2-1 matcher_regex, matcher_star, matcher_space, no_matcher: a group that runs on Agent is review" {
  local matcher
  # "missing" drops the key; the rest are the reviewer's matcher strings.
  for matcher in 'Agent|Task' '*' 'Agent ' missing; do
    _r2_settings < <(jq -nc --arg m "$matcher" '{hooks:{PreToolUse:[{matcher:$m,hooks:[{type:"command",command:"/ex/hooks/cockpit-guard.sh"}]}
      | if $m == "missing" then del(.matcher) else . end]}}')
    _r2_expect_review '"/ex/hooks/cockpit-guard.sh"'
  done
}

@test "246 r2 P2-1 move: a --verbose guard copy on the old cockpit is reported, and the move still lands" {
  clikae init claude A >/dev/null
  clikae init claude B >/dev/null
  clikae cockpit claude A >/dev/null
  local f="$CLIKAE_HOME/profiles/claude/A/settings.json"
  jq '.hooks.PreToolUse += [{"matcher":"Agent","hooks":[{"type":"command","command":"/ex/hooks/cockpit-guard.sh --verbose"}]}]' "$f" > "$BATS_TEST_TMPDIR/n"
  cat "$BATS_TEST_TMPDIR/n" > "$f"
  run clikae cockpit claude B
  [ "$status" -eq 0 ]
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "claude/B" ]
  [[ "$output" == *'claude/A: cockpit guard removed (1 entry)'* ]] || false
  [[ "$output" == *'claude/A: hook entry left for you to check: "/ex/hooks/cockpit-guard.sh --verbose"'* ]] || false
  [[ "$output" == *'cockpit: the guard clikae installed on the old cockpit (claude/A) is gone; hook entries there were left for you to check (listed above).'* ]] || false
  [[ "$output" != *'could not clean up'* ]] || false
  [ "$(jq -c '.hooks.PreToolUse' "$f")" = '[{"matcher":"Agent","hooks":[{"type":"command","command":"/ex/hooks/cockpit-guard.sh --verbose"}]}]' ]
}

@test "246 r2 P2-2 marker_unquoted_space: fc3ffe4's unquoted guard in a marked group is the installer's" {
  _r2_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"/ex dir/hooks/cockpit-guard.sh","timeout":5}],"_clikae":"cockpit-guard"}]}}
JSON
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  [[ "$output" == *'claude/A: cockpit guard removed (1 entry)'* ]] || false
  [[ "$output" == *'cockpit: off'* ]] || false
  printf '{}\n' > "$BATS_TEST_TMPDIR/expected.json"
  cmp "$BATS_TEST_TMPDIR/expected.json" "$R2_FILE"
  run clikae doctor
  [[ "$output" != *'guard found on tank(s)'* ]] || false
  # Install repairs it in place: one marked group, not a second one.
  cp "$BATS_TEST_TMPDIR/before.json" "$R2_FILE"
  rm -f "$CLIKAE_HOME/state/cockpit"
  run clikae cockpit claude A
  [ "$status" -eq 0 ]
  [ "$(jq '[.hooks.PreToolUse[] | select(._clikae == "cockpit-guard")] | length' "$R2_FILE")" -eq 1 ]
  [ "$(jq '.hooks.PreToolUse | length' "$R2_FILE")" -eq 1 ]
}

@test "246 r2 P2-3 marker_sibling_plain, marker_sibling_bash: the marker leaves with the guard, the sibling stays" {
  _r2_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"/ex/hooks/cockpit-guard.sh"},{"type":"command","command":"/ex/audit.sh"}],"_clikae":"cockpit-guard"}]}}
JSON
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  [[ "$output" == *'cockpit: off'* ]] || false
  jq -n '{hooks:{PreToolUse:[{matcher:"Agent",hooks:[{type:"command",command:"/ex/audit.sh"}]}]}}' > "$BATS_TEST_TMPDIR/expected.json"
  cmp "$BATS_TEST_TMPDIR/expected.json" "$R2_FILE"
  run clikae doctor
  [[ "$output" != *'guard found on tank(s)'* ]] || false

  _r2_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"/ex/hooks/cockpit-guard.sh"},{"type":"command","command":"bash -c \"echo hi\""}],"_clikae":"cockpit-guard"}]}}
JSON
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  [[ "$output" == *'cockpit: off'* ]] || false
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  [[ "$output" == *'cockpit: already off (unchanged)'* ]] || false
  [ "$(jq -c '.hooks.PreToolUse' "$R2_FILE")" = '[{"matcher":"Agent","hooks":[{"type":"command","command":"bash -c \"echo hi\""}]}]' ]

  # Install moves the marker the same way: the user's group comes out unmarked.
  _r2_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"/ex/hooks/cockpit-guard.sh"},{"type":"command","command":"/ex/audit.sh"}],"_clikae":"cockpit-guard"}]}}
JSON
  rm -f "$CLIKAE_HOME/state/cockpit"
  run clikae cockpit claude A
  [ "$status" -eq 0 ]
  [ "$(jq -c '.hooks.PreToolUse[0]' "$R2_FILE")" = '{"matcher":"Agent","hooks":[{"type":"command","command":"/ex/audit.sh"}]}' ]
  [ "$(jq '[.hooks.PreToolUse[] | select(._clikae == "cockpit-guard")] | length' "$R2_FILE")" -eq 1 ]
}

@test "246 r2 P2-4 redirect_mention, nonexec_bash, comment: a hook that only names the file is the user's" {
  local command
  for command in '/ex/audit.sh > /tmp/cockpit-guard.sh.log' 'bash /ex/hooks/cockpit-guard.sh.disabled' \
                 '/ex/audit.sh 2>/dev/null # cockpit-guard.sh'; do
    _r2_settings < <(jq -nc --arg c "$command" '{hooks:{PreToolUse:[{matcher:"Agent",hooks:[{type:"command",command:$c}]}]}}')
    _r2_expect_user
  done
}

@test "246 r2 P2-4 move: the old cockpit's guard is removed and a mention is not called a failure" {
  clikae init claude A >/dev/null
  clikae init claude B >/dev/null
  clikae cockpit claude A >/dev/null
  local f="$CLIKAE_HOME/profiles/claude/A/settings.json"
  jq '.hooks.PreToolUse += [{"matcher":"Agent","hooks":[{"type":"command","command":"/ex/audit.sh 2>/dev/null # cockpit-guard.sh"}]}]' "$f" > "$BATS_TEST_TMPDIR/n"
  cat "$BATS_TEST_TMPDIR/n" > "$f"
  run clikae cockpit claude B
  [ "$status" -eq 0 ]
  [[ "$output" == *'claude/A: cockpit guard removed (1 entry)'* ]] || false
  [[ "$output" != *'could not clean up'* ]] || false
  [[ "$output" != *'left for you to check'* ]] || false
  [ "$(jq -c '.hooks.PreToolUse' "$f")" = '[{"matcher":"Agent","hooks":[{"type":"command","command":"/ex/audit.sh 2>/dev/null # cockpit-guard.sh"}]}]' ]
}

@test "246 r2 P2-4 rollback: entries kept on the new tank do not turn a rolled-back guard into a failed one" {
  clikae init claude A >/dev/null
  clikae init claude B >/dev/null
  clikae cockpit claude A >/dev/null
  local b="$CLIKAE_HOME/profiles/claude/B/settings.json"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"/ex/hooks/cockpit-guard.sh --verbose"}]}]}}' > "$b"
  # Fail exactly the state record's write; every other write stays real.
  cat > "$BATS_TEST_TMPDIR/fail-state.sh" <<'ENV'
printf() {
  if [ "$#" -eq 3 ] && [ "$1" = '%s/%s\n' ]; then return 1; fi
  builtin printf "$@"
}
ENV
  BASH_ENV="$BATS_TEST_TMPDIR/fail-state.sh" run clikae cockpit claude B
  [ "$status" -eq 1 ]
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "claude/A" ]
  [[ "$output" == *'claude/B: hook entry left for you to check: "/ex/hooks/cockpit-guard.sh --verbose"'* ]] || false
  [[ "$output" == *'cockpit: could not record the new cockpit (claude/B) — its guard was rolled back; hook entries there were left for you to check (listed above); claude/A is still the cockpit, unchanged'* ]] || false
  [[ "$output" != *'could NOT be rolled back'* ]] || false
  [ "$(jq -c '.hooks.PreToolUse' "$b")" = '[{"matcher":"Agent","hooks":[{"type":"command","command":"/ex/hooks/cockpit-guard.sh --verbose"}]}]' ]
}

@test "246 r2 P2-5 dangling_symlink: an unrelated tank's dead settings.json link is skipped" {
  clikae init claude A >/dev/null
  clikae init claude B >/dev/null
  local b="$CLIKAE_HOME/profiles/claude/B/settings.json"
  rm -f "$b"
  ln -s /nonexistent/x.json "$b"
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  [[ "$output" == *'cockpit: already off (unchanged)'* ]] || false
  [[ "$output" != *'could not clean up'* ]] || false
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  [ -L "$b" ]
  [ "$(readlink "$b")" = /nonexistent/x.json ]
  # With a real guard elsewhere, the sweep still removes it and says off.
  clikae cockpit claude A >/dev/null
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  [[ "$output" == *'claude/A: cockpit guard removed (1 entry)'* ]] || false
  [[ "$output" == *'cockpit: off'* ]] || false
  [ -L "$b" ]
}

@test "246 r2 P3 relative: hooks/cockpit-guard.sh may be a project script, so it is kept and reported" {
  _r2_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"hooks/cockpit-guard.sh"}]}]}}
JSON
  _r2_expect_review '"hooks/cockpit-guard.sh"'
  # Install keeps it too, and names it.
  rm -f "$CLIKAE_HOME/state/cockpit"
  run clikae cockpit claude A
  [ "$status" -eq 0 ]
  [[ "$output" == *'claude/A: hook entry left for you to check: "hooks/cockpit-guard.sh"'* ]] || false
  [ "$(jq -c '.hooks.PreToolUse[0]' "$R2_FILE")" = '{"matcher":"Agent","hooks":[{"type":"command","command":"hooks/cockpit-guard.sh"}]}' ]
}
