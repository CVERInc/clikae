#!/usr/bin/env bats
# tests/bats/list.bats — `clikae list`

load '../helpers'

@test "list reports nothing when there are no profiles" {
  run clikae list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tanks yet"* ]]
}

@test "list shows created profiles" {
  clikae init claude work
  clikae init gh personal
  run clikae list
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"work"* ]]
  [[ "$output" == *"gh"* ]]
  [[ "$output" == *"personal"* ]]
}

@test "list -p includes the profile path" {
  clikae init claude work
  run clikae list -p
  [ "$status" -eq 0 ]
  [[ "$output" == *"$CLIKAE_HOME/profiles/claude/work"* ]]
}

@test "list output is sorted" {
  clikae init claude zzz
  clikae init claude aaa
  run clikae list
  [ "$status" -eq 0 ]
  # aaa must appear before zzz
  [[ "$output" == *aaa*zzz* ]]
}

# --- --json: machine-readable output for the GUI / scripts --------------------

@test "list --json: no profiles emits an empty array" {
  run clikae list --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "list --json: a profile carries cli/profile/path; account null when unknown" {
  clikae init claude work
  run clikae list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"cli":"claude"'* ]]
  [[ "$output" == *'"profile":"work"'* ]]
  [[ "$output" == *"\"path\":\"$CLIKAE_HOME/profiles/claude/work\""* ]]
  [[ "$output" == *'"account":null'* ]]      # not logged in in the test env
}

@test "list --json: account label appears when logged in" {
  clikae init claude work
  printf '{\n  "oauthAccount": { "emailAddress": "me@example.com" }\n}\n' \
    > "$CLIKAE_HOME/profiles/claude/work/.claude.json"
  run clikae list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"account":"me@example.com"'* ]]
}

@test "list --json output parses as valid JSON" {
  clikae init claude work
  clikae init gh personal
  if command -v python3 >/dev/null; then
    clikae list --json | python3 -m json.tool >/dev/null
  else
    skip "python3 not available to validate JSON"
  fi
}
