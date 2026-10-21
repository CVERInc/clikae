#!/usr/bin/env bats
load '../helpers'

# Real inventory and command dispatch, fake normalized usage readings.
reading() {
  local engine="$1" tank="$2" weekly="$3" window="$4" hours="$5"
  clikae init "$engine" "$tank" >/dev/null
  mkdir -p "$CLIKAE_HOME/state/usage/$engine"
  jq -cn --argjson now "$(date +%s)" --argjson weekly "$weekly" \
    --argjson window "$window" --argjson hours "$hours" '
    {weekly_pct:$weekly,window_pct:$window,
     weekly_resets_at:(($now+$hours*3600)|todateiso8601),
     window_resets_at:(($now+$hours*3600)|todateiso8601),
     source:"vendor",cached_at:$now,scanned_at:$now}' \
    > "$CLIKAE_HOME/state/usage/$engine/$tank.json"
}

@test "available JSON explains each skip reason and keeps eligible scores" {
  reading claude unreadable null null 48
  reading claude weekly 90 20 48
  reading claude near 98 20 12
  reading claude window 20 95 48
  reading claude seat 10 10 48
  reading claude ready 89 94 48
  printf 'claude/seat\n' > "$CLIKAE_HOME/state/cockpit"
  run clikae tanks --available claude --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    (map({key:.tank,value:.reason})|from_entries) ==
    {unreadable:"unreadable",weekly:"quota",near:"quota",window:"window",seat:"cockpit",ready:null}'
  echo "$output" | jq -e 'map(select(.available)) | length == 1 and .[0].score > 0'
}

@test "available orders remaining quota per hour and relaxes only under 24 hours" {
  reading claude slow 10 0 100
  reading claude fast 50 0 10
  reading claude near 97 0 1
  reading claude boundary 90 0 25
  run clikae tanks --available claude --order expiring
  [ "$status" -eq 0 ]
  [ "$output" = $'fast\nnear\nslow' ]
}

@test "available single window uses its own reset and has no separate 95 percent gate" {
  reading codex one null 97 1
  reading codex dry null 98 1
  reading codex distant null 90 48
  run clikae tanks --available codex --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'map(select(.available)) | length == 1 and .[0].tank == "one" and .[0].score >= 3'
}

@test "available includes cockpit on request and compares full engine identity" {
  reading claude seat 10 0 48
  reading codex seat null 10 48
  printf 'claude/seat\n' > "$CLIKAE_HOME/state/cockpit"
  run clikae tanks --available --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'map(select(.available)) | length == 1 and .[0].engine == "codex"'
  run clikae tanks --available claude --include-cockpit
  [ "$status" -eq 0 ]
  [ "$output" = seat ]
}

@test "available reads inventory anew and handles an empty inventory" {
  run clikae tanks --available --json
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
  reading claude newtank 0 0 48
  run clikae tanks --available
  [ "$status" -eq 0 ]
  [ "$output" = newtank ]
}

@test "available rejects missing resets and malformed readings without guessing" {
  reading claude missing 20 0 48
  reading claude malformed 20 0 48
  reading claude invalid 20 0 48
  local cache="$CLIKAE_HOME/state/usage/claude"
  jq '.weekly_resets_at=null' "$cache/missing.json" > "$TEST_HOME/r"
  mv "$TEST_HOME/r" "$cache/missing.json"
  jq '.weekly_resets_at="not-a-date"' "$cache/malformed.json" > "$TEST_HOME/r"
  mv "$TEST_HOME/r" "$cache/malformed.json"
  jq '.weekly_pct="20"' "$cache/invalid.json" > "$TEST_HOME/r"
  mv "$TEST_HOME/r" "$cache/invalid.json"
  run clikae tanks --available --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 3 and all(.[]; .available == false and .reason == "unreadable" and .score == null)'
}

@test "available normalizes reset offsets and floors elapsed reset hours" {
  reading claude elapsed 20 0 -1
  reading claude offset 20 0 48
  local cache="$CLIKAE_HOME/state/usage/claude/offset.json"
  jq '.weekly_resets_at |= (sub("Z$";".123456+00:00"))' "$cache" > "$TEST_HOME/r"
  mv "$TEST_HOME/r" "$cache"
  run clikae tanks --available --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].tank == "elapsed" and .[0].score == 160 and .[1].available == true'
}
