#!/usr/bin/env bats
load '../helpers'
bats_require_minimum_version 1.5.0

# Every fixture drives the real CLI in helpers.bash's throwaway HOME.
_review_settings() {
  [ -d "$CLIKAE_HOME/profiles/claude/A" ] || clikae init claude A >/dev/null
  REVIEW_FILE="$CLIKAE_HOME/profiles/claude/A/settings.json"
  cat > "$REVIEW_FILE"
  cp "$REVIEW_FILE" "$BATS_TEST_TMPDIR/before.json"
  printf 'claude/A\n' > "$CLIKAE_HOME/state/cockpit"
}

_review_unchanged() { cmp "$BATS_TEST_TMPDIR/before.json" "$REVIEW_FILE"; }
_review_off() { [ ! -e "$CLIKAE_HOME/state/cockpit" ]; }

@test "246 argument_only: a guard path argument does not make the audit executable ours" {
  _review_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"/example/audit.sh --label /example/hooks/cockpit-guard.sh"}]}]}}
JSON
  run clikae cockpit --off
  # Kept, never deleted; reported (r2 P2-1), since the audit may run it.
  [ "$status" -eq 1 ]
  _review_unchanged
  _review_off
  [[ "$output" == *'claude/A: hook entry left for you to check: "/example/audit.sh --label /example/hooks/cockpit-guard.sh"'* ]] || false
  [[ "$output" != *'cockpit: off'* ]] || false
}

@test "246 different_matcher: a deliberate Read matcher is preserved" {
  _review_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"/example/hooks/cockpit-guard.sh"}]}]}}
JSON
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  _review_unchanged
  _review_off
}

@test "246 mixed_group: only the legacy command is removed, retaining its sibling and matcher" {
  _review_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"/example/hooks/cockpit-guard.sh"},{"type":"command","command":"/example/audit.sh"}]}]}}
JSON
  jq -n '{hooks:{PreToolUse:[{matcher:"Agent",hooks:[{type:"command",command:"/example/audit.sh"}]}]}}' > "$BATS_TEST_TMPDIR/expected.json"
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/expected.json" "$REVIEW_FILE"
  [[ "$output" == *'claude/A: cockpit guard removed (1 entry)'* ]] || false
  _review_off
}

@test "246 nested_quotes: bash -c is preserved and reported with tank and command" {
  _review_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"bash -c \"'/example/old checkout/hooks/cockpit-guard.sh'\""}]}]}}
JSON
  run clikae cockpit --off
  [ "$status" -eq 1 ]
  _review_unchanged
  _review_off
  local command
  command="$(jq -c '.hooks.PreToolUse[0].hooks[0].command' "$REVIEW_FILE")"
  [[ "$output" == *"claude/A: hook entry left for you to check: $command"* ]] || false
  [[ "$output" == *'cockpit: state cleared; hook entries remain for you to check: claude/A'* ]] || false
  [[ "$output" != *'cockpit: off'* ]] || false
}

@test "246 split_quotes: quoted fragments of the plain executable are removed" {
  _review_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"/example/hooks/\"cockpit-guard.sh\""}]}]}}
JSON
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  printf '{}\n' > "$BATS_TEST_TMPDIR/expected.json"
  cmp "$BATS_TEST_TMPDIR/expected.json" "$REVIEW_FILE"
  _review_off
}

@test "246 trailing_space: a quoted plain executable with trailing whitespace is removed" {
  _review_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"'/example/hooks/cockpit-guard.sh' "}]}]}}
JSON
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  printf '{}\n' > "$BATS_TEST_TMPDIR/expected.json"
  cmp "$BATS_TEST_TMPDIR/expected.json" "$REVIEW_FILE"
  _review_off
}

@test "246 malformed and malformed_escaped: neither spelling establishes absence in broken JSON" {
  local fixture
  for fixture in '/example/hooks/cockpit-guard.sh' '\/example\/hooks\/cockpit-guard.sh'; do
    _review_settings <<JSON
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"command":"$fixture"}]}]} BROKEN
JSON
    run clikae cockpit --off
    [ "$status" -eq 1 ]
    _review_unchanged
    _review_off
    [[ "$output" == *'claude/A: skipped — settings.json is not valid JSON'* ]] || false
    [[ "$output" != *'cockpit: off'* ]] || false
  done
}

@test "246 install and repair preserve argument-only, different-matcher and mixed-group user hooks" {
  _review_settings <<'JSON'
{"env":{"KEEP":"yes"},"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"/example/audit.sh --label /example/hooks/cockpit-guard.sh"}]},{"matcher":"Read","hooks":[{"type":"command","command":"/example/hooks/cockpit-guard.sh"}]},{"matcher":"Agent","hooks":[{"type":"command","command":"/example/hooks/cockpit-guard.sh"},{"type":"command","command":"/example/audit.sh"}]}]}}
JSON
  # Fixed expectation for the user's surviving content; the only variable is
  # the installed runtime path in the one new, marked guard entry.
  jq 'del(.hooks.PreToolUse[2].hooks[0])' "$REVIEW_FILE" > "$BATS_TEST_TMPDIR/expected.json"
  rm "$CLIKAE_HOME/state/cockpit"
  run clikae cockpit claude A
  [ "$status" -eq 0 ]
  jq 'del(.hooks.PreToolUse[] | select(._clikae == "cockpit-guard"))' "$REVIEW_FILE" > "$BATS_TEST_TMPDIR/actual.json"
  cmp "$BATS_TEST_TMPDIR/expected.json" "$BATS_TEST_TMPDIR/actual.json"
  # Repair a legacy guard added to an already-marked cockpit, then repeat.
  jq '.hooks.PreToolUse[2].hooks += [{type:"command",command:"/example/old/hooks/cockpit-guard.sh"}]' "$REVIEW_FILE" > "$REVIEW_FILE.new"
  mv "$REVIEW_FILE.new" "$REVIEW_FILE"
  run clikae cockpit claude A
  [ "$status" -eq 0 ]
  jq 'del(.hooks.PreToolUse[] | select(._clikae == "cockpit-guard"))' "$REVIEW_FILE" > "$BATS_TEST_TMPDIR/actual.json"
  cmp "$BATS_TEST_TMPDIR/expected.json" "$BATS_TEST_TMPDIR/actual.json"
  cp "$REVIEW_FILE" "$BATS_TEST_TMPDIR/repaired.json"
  run clikae cockpit claude A
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/repaired.json" "$REVIEW_FILE"
}

@test "246 command ownership requires type and no arguments, even in marked groups" {
  _review_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","_clikae":"cockpit-guard","hooks":[{"type":"command","command":"/example/hooks/cockpit-guard.sh"},{"type":"command","command":"/example/audit.sh"},{"type":"command","command":"/example/hooks/cockpit-guard.sh --user-option"},{"command":"/example/hooks/cockpit-guard.sh"},{"type":"prompt","command":"/example/hooks/cockpit-guard.sh"}]}]}}
JSON
  # r2 P2-3: the marker leaves with the command it named.
  jq 'del(.hooks.PreToolUse[0].hooks[0]) | del(.hooks.PreToolUse[0]._clikae)' "$REVIEW_FILE" > "$BATS_TEST_TMPDIR/expected.json"
  run clikae cockpit --off
  # r2 P2-1: the --user-option copy still runs the guard: kept and reported.
  [ "$status" -eq 1 ]
  cmp "$BATS_TEST_TMPDIR/expected.json" "$REVIEW_FILE"
  [[ "$output" == *'claude/A: hook entry left for you to check: "/example/hooks/cockpit-guard.sh --user-option"'* ]] || false
  # Install and repair may remove only the one new command they own, too.
  run clikae cockpit claude A
  [ "$status" -eq 0 ]
  jq 'del(.hooks.PreToolUse[-1])' "$REVIEW_FILE" > "$BATS_TEST_TMPDIR/actual.json"
  cmp "$BATS_TEST_TMPDIR/expected.json" "$BATS_TEST_TMPDIR/actual.json"
  run clikae cockpit claude A
  [ "$status" -eq 0 ]
  [[ "$output" == *'cockpit guard already installed (unchanged)'* ]] || false
  run clikae cockpit --off
  [ "$status" -eq 1 ]
  cmp "$BATS_TEST_TMPDIR/expected.json" "$REVIEW_FILE"
}

@test "246 literal shell words cover quote concatenation, escaped spaces, quotes and backslashes" {
  _review_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"  /example/old\\ checkout/hooks/cockpit-guard.sh\t"},{"type":"command","command":"'/example/it'\\''s here/hooks/cockpit-guard.sh'"},{"type":"command","command":"\"/example/a\\q/hooks/cockpit-guard.sh\""},{"type":"command","command":"\"/example/\\$literal/hooks/cockpit-guard.sh\""},{"type":"command","command":"hooks/cockpit-guard.sh"}]}]}}
JSON
  # r2 P3: the relative path may be a project script: kept and reported.
  jq '.hooks.PreToolUse[0].hooks |= [.[-1]]' "$REVIEW_FILE" > "$BATS_TEST_TMPDIR/expected.json"
  run clikae cockpit --off
  [ "$status" -eq 1 ]
  cmp "$BATS_TEST_TMPDIR/expected.json" "$REVIEW_FILE"
  [[ "$output" == *'cockpit guard removed (4 entries)'* ]] || false
  [[ "$output" == *'claude/A: hook entry left for you to check: "hooks/cockpit-guard.sh"'* ]] || false
}

@test "246 uncertain syntax is never executed or deleted and does not prevent removing known guards" {
  _review_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"/example/hooks/cockpit-guard.sh"},{"type":"command","command":"$(touch \"$HOME/executed\")/hooks/cockpit-guard.sh"},{"type":"command","command":"/example/hooks/cockpit-guard.sh; touch \"$HOME/executed\""},{"type":"command","command":"\"${HOME}/hooks/cockpit-guard.sh\""},{"type":"command","command":"'/example/hooks/cockpit-guard.sh"},{"type":"command","command":"bash -c \"'/example/hooks/cockpit-guard.sh'\""}]}]}}
JSON
  jq 'del(.hooks.PreToolUse[0].hooks[0])' "$REVIEW_FILE" > "$BATS_TEST_TMPDIR/expected.json"
  run clikae cockpit --off
  [ "$status" -eq 1 ]
  cmp "$BATS_TEST_TMPDIR/expected.json" "$REVIEW_FILE"
  [ ! -e "$HOME/executed" ]
  [ "$(printf '%s\n' "$output" | grep -c 'claude/A: hook entry left for you to check:')" -eq 5 ]
  [[ "$output" == *'cockpit guard removed (1 entry)'* ]] || false
  _review_off
  run clikae cockpit claude A
  [ "$status" -eq 0 ]
  jq 'del(.hooks.PreToolUse[-1])' "$REVIEW_FILE" > "$BATS_TEST_TMPDIR/actual.json"
  cmp "$BATS_TEST_TMPDIR/expected.json" "$BATS_TEST_TMPDIR/actual.json"
  [ ! -e "$HOME/executed" ]
  [ "$(printf '%s\n' "$output" | grep -c 'claude/A: hook entry left for you to check:')" -eq 5 ]
}

@test "246 a quoted newline after the guard filename is a different executable" {
  _review_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"'/example/hooks/cockpit-guard.sh\n'"}]}]}}
JSON
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  _review_unchanged
}

@test "246 malformed settings without a recognizable guard still report uncertainty and stay untouched" {
  local fixture action
  for fixture in '' $'{}\n{}' '{"unrelated": BROKEN'; do
    _review_settings <<< "$fixture"
    for action in --off A; do
      run clikae cockpit "$action"
      [ "$status" -eq 1 ]
      _review_unchanged
      [[ "$output" == *'claude/A: skipped — settings.json is not valid JSON'* ]] || false
      [[ "$output" != *'cockpit: off'* ]] || false
    done
  done
}

@test "246 unreadable settings leave bytes intact in off and install" {
  if [ "$(id -u)" -eq 0 ]; then skip 'root can read a mode-000 file'; fi
  _review_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"/example/hooks/cockpit-guard.sh"}]}]}}
JSON
  local action
  for action in --off A; do
    chmod 000 "$REVIEW_FILE"
    run clikae cockpit "$action"
    chmod 600 "$REVIEW_FILE"
    [ "$status" -eq 1 ]
    _review_unchanged
    [[ "$output" == *'claude/A: failed to read settings.json'* ]] || false
    [[ "$output" != *'cockpit: off'* ]] || false
  done
  _review_off
}

@test "246 entry shape: a user map of hooks is not the installer's hook array" {
  _review_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":{"custom":{"type":"command","command":"/example/hooks/cockpit-guard.sh"}}}]}}
JSON
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  _review_unchanged
  _review_off
  run clikae cockpit claude A
  [ "$status" -eq 0 ]
  jq 'del(.hooks.PreToolUse[-1])' "$REVIEW_FILE" > "$BATS_TEST_TMPDIR/actual.json"
  jq . "$BATS_TEST_TMPDIR/before.json" > "$BATS_TEST_TMPDIR/expected.json"
  cmp "$BATS_TEST_TMPDIR/expected.json" "$BATS_TEST_TMPDIR/actual.json"
}

@test "246 line_continuation: an escaped newline does not create an empty argument" {
  _review_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"\\\n '/example/hooks/cockpit-guard.sh'"}]}]}}
JSON
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  printf '{}\n' > "$BATS_TEST_TMPDIR/expected.json"
  cmp "$BATS_TEST_TMPDIR/expected.json" "$REVIEW_FILE"
  _review_off
  # An explicitly quoted empty executable is different: the guard is an argument.
  _review_settings <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"'' /example/hooks/cockpit-guard.sh"}]}]}}
JSON
  # Not ours, so never deleted; it names the guard path, so it is reported.
  run clikae cockpit --off
  [ "$status" -eq 1 ]
  _review_unchanged
  [[ "$output" == *"claude/A: hook entry left for you to check: \"'' /example/hooks/cockpit-guard.sh\""* ]] || false
}
