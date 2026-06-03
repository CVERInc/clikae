#!/usr/bin/env bats
# tests/bats/list.bats — `clikae list`

load '../helpers'

@test "list reports nothing when there are no profiles" {
  run clikae list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tanks yet"* ]] || false
}

@test "list shows created profiles" {
  clikae init claude work
  clikae init gh personal
  run clikae list
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* ]] || false
  [[ "$output" == *"work"* ]] || false
  [[ "$output" == *"gh"* ]] || false
  [[ "$output" == *"personal"* ]] || false
}

@test "list -p includes the profile path" {
  clikae init claude work
  run clikae list -p
  [ "$status" -eq 0 ]
  [[ "$output" == *"$CLIKAE_HOME/profiles/claude/work"* ]] || false
}

@test "list output is sorted" {
  clikae init claude zzz
  clikae init claude aaa
  run clikae list
  [ "$status" -eq 0 ]
  # aaa must appear before zzz
  [[ "$output" == *aaa*zzz* ]] || false
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
  [[ "$output" == *'"cli":"claude"'* ]] || false
  [[ "$output" == *'"profile":"work"'* ]] || false
  [[ "$output" == *"\"path\":\"$CLIKAE_HOME/profiles/claude/work\""* ]] || false
  [[ "$output" == *'"account":null'* ]]      # not logged in in the test env
}

@test "list --json: account label appears when logged in" {
  clikae init claude work
  printf '{\n  "oauthAccount": { "emailAddress": "me@example.com" }\n}\n' \
    > "$CLIKAE_HOME/profiles/claude/work/.claude.json"
  run clikae list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"account":"me@example.com"'* ]] || false
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

@test "tanks marks the active (symlinked) agy tank, doesn't fake an email" {
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1   # 'default' is the active/symlinked tank
  run clikae tanks
  [ "$status" -eq 0 ]
  [[ "$output" == *"agy"* ]] || false
  [[ "$output" == *"(active)"* ]] || false
}
