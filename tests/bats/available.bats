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

# agy_reading <tank> <gemini weekly|null> <claude weekly|null> [age seconds]
agy_reading() {
  local t="$1" gem="$2" cla="$3" age="${4:-0}" d="$CLIKAE_HOME/profiles/antigravity/$1"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.testbin/agy"; chmod +x "$TEST_HOME/.testbin/agy"
  mkdir -p "$d/antigravity-cli" "$CLIKAE_HOME/state/usage/antigravity"
  printf 'antigravity\n' > "$d/.clikae-tank"
  jq -cn --argjson now "$(date +%s)" --argjson gem "$gem" --argjson cla "$cla" --argjson age "$age" '
    (($now+100*3600)|todateiso8601) as $rs |
    {weekly_pct:$gem,window_pct:null,weekly_resets_at:$rs,source:"quota-api",headline_group:"gemini",
     cached_at:($now-$age),scanned_at:($now-$age),
     groups:[{name:"claude",weekly_pct:$cla,window_pct:null,weekly_resets_at:$rs,disabled:false},
             {name:"gemini",weekly_pct:$gem,window_pct:null,weekly_resets_at:$rs,disabled:false}],
     models:[{name:"claude weekly",pct:$cla},{name:"gemini weekly",pct:$gem}]}' \
    > "$CLIKAE_HOME/state/usage/antigravity/$t.json"
}

@test "available agy: each group has its own verdict and order, and one group never gates the other" {
  agy_reading gemfull 95 10
  agy_reading clafull 10 95
  agy_reading both 50 50
  run clikae tanks --available agy
  [ "$status" -eq 0 ]
  [ "$output" = $'gemini  clafull both\nclaude  gemfull both' ] || { echo "$output"; false; }
  run clikae tanks --available agy --group claude
  [ "$output" = $'gemfull\nboth' ] || { echo "$output"; false; }
  run clikae tanks --available agy --json
  echo "$output" | jq -e '
    (map({key:.tank,value:.reason})|from_entries) == {gemfull:"quota",clafull:null,both:null}
    and (.[] | select(.tank == "gemfull") | .groups | map({key:.name,value:.reason}) | from_entries)
        == {claude:null,gemini:"quota"}'
}

@test "available agy: --group needs agy and one of the two names" {
  run clikae tanks --available claude --group gemini
  [ "$status" -ne 0 ]
  run clikae tanks --available agy --group gpt
  [ "$status" -ne 0 ]
  run clikae tanks --group gemini
  [ "$status" -ne 0 ]
}

@test "available: a model share over the weekly number gates the tank, for claude" {
  reading claude capped 65 0 48
  reading claude open 65 0 48
  local f="$CLIKAE_HOME/state/usage/claude/capped.json"
  jq '.models = [{name:"Fable",pct:97}]' "$f" > "$f.new" && mv "$f.new" "$f"
  f="$CLIKAE_HOME/state/usage/claude/open.json"
  jq '.models = [{name:"Fable",pct:40}]' "$f" > "$f.new" && mv "$f.new" "$f"
  run clikae tanks --available claude --json
  echo "$output" | jq -e '(map({key:.tank,value:.reason})|from_entries) == {capped:"quota",open:null}'
}

@test "available: a reading over six hours old is stale, not a number to act on" {
  reading codex old null 10 48
  reading codex recent null 10 48
  local f="$CLIKAE_HOME/state/usage/codex/old.json" at
  at=$(( $(date +%s) - 21700 ))
  jq --argjson a "$at" '.cached_at = $a | .scanned_at = $a' "$f" > "$f.new" && mv "$f.new" "$f"
  CLIKAE_USAGE_TTL=999999 run clikae tanks --available codex --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(map({key:.tank,value:.reason})|from_entries) == {old:"stale",recent:null}'
}

