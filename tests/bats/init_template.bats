#!/usr/bin/env bats
# tests/bats/init_template.bats — #95: `clikae init` seeds a new tank from
# $CLIKAE_HOME/template/<engine>/ (theme/config files, settings.json keys).

load '../helpers'

@test "init with no template directory is silent about seeding" {
  run clikae init claude work
  [ "$status" -eq 0 ]
  [[ "$output" != *"Seeded from template"* ]] || false
}

@test "init copies a template file into a new tank" {
  mkdir -p "$CLIKAE_HOME/template/claude"
  echo '{"mode":"dark"}' > "$CLIKAE_HOME/template/claude/theme.json"

  run clikae init claude work
  [ "$status" -eq 0 ]
  [ -f "$CLIKAE_HOME/profiles/claude/work/theme.json" ]
  [ "$(cat "$CLIKAE_HOME/profiles/claude/work/theme.json")" = '{"mode":"dark"}' ]
  [[ "$output" == *"Seeded from template"* ]] || false
  [[ "$output" == *"theme.json"* ]] || false
}

@test "init never overwrites a file the tank already has, from the template" {
  # Adapters can write their own files during adapter_init; simulate that by
  # adopting a directory that already has theme.json before the template
  # step ever runs, then confirm a template copy leaves it untouched.
  mkdir -p "$CLIKAE_HOME/profiles/claude/work"
  echo '{"mode":"light"}' > "$CLIKAE_HOME/profiles/claude/work/theme.json"
  printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/work/.clikae-tank"
  mkdir -p "$CLIKAE_HOME/template/claude"
  echo '{"mode":"dark"}' > "$CLIKAE_HOME/template/claude/theme.json"

  run clikae init claude work --adopt
  [ "$status" -eq 0 ]
  [ "$(cat "$CLIKAE_HOME/profiles/claude/work/theme.json")" = '{"mode":"light"}' ]
}

@test "init merges template settings.json keys the tank is missing" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  mkdir -p "$CLIKAE_HOME/template/claude"
  cat > "$CLIKAE_HOME/template/claude/settings.json" <<'EOF'
{"outputStyle": "concise", "newKey": "fromTemplate"}
EOF

  run clikae init claude work
  [ "$status" -eq 0 ]
  [ -f "$CLIKAE_HOME/profiles/claude/work/settings.json" ]
  run jq -r '.outputStyle' "$CLIKAE_HOME/profiles/claude/work/settings.json"
  [ "$output" = "concise" ]
  run jq -r '.newKey' "$CLIKAE_HOME/profiles/claude/work/settings.json"
  [ "$output" = "fromTemplate" ]
}

@test "init never overwrites a settings.json key the tank already has" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  # Pre-seed settings.json (as though the permissions template or an
  # adapter already wrote it) with a key the file template also provides,
  # holding a DIFFERENT value, then adopt: the merge step must leave it.
  mkdir -p "$CLIKAE_HOME/profiles/claude/work"
  echo '{"outputStyle": "explanatory"}' > "$CLIKAE_HOME/profiles/claude/work/settings.json"
  printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/work/.clikae-tank"
  mkdir -p "$CLIKAE_HOME/template/claude"
  echo '{"outputStyle": "concise"}' > "$CLIKAE_HOME/template/claude/settings.json"

  run clikae init claude work --adopt
  [ "$status" -eq 0 ]
  run jq -r '.outputStyle' "$CLIKAE_HOME/profiles/claude/work/settings.json"
  [ "$output" = "explanatory" ]
}

@test "init --no-template skips seeding from the file template too" {
  mkdir -p "$CLIKAE_HOME/template/claude"
  echo '{"mode":"dark"}' > "$CLIKAE_HOME/template/claude/theme.json"

  run clikae init claude work --no-template
  [ "$status" -eq 0 ]
  [ ! -e "$CLIKAE_HOME/profiles/claude/work/theme.json" ]
  [[ "$output" != *"Seeded from template"* ]] || false
}

@test "init --no-template also skips merging template settings.json keys" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  mkdir -p "$CLIKAE_HOME/template/claude"
  echo '{"newKey": "fromTemplate"}' > "$CLIKAE_HOME/template/claude/settings.json"

  run clikae init claude work --no-template
  [ "$status" -eq 0 ]
  if [ -f "$CLIKAE_HOME/profiles/claude/work/settings.json" ]; then
    run jq -r '.newKey // "absent"' "$CLIKAE_HOME/profiles/claude/work/settings.json"
    [ "$output" = "absent" ]
  fi
}

@test "a solo tank is still seeded from the template like any other new tank" {
  mkdir -p "$CLIKAE_HOME/template/claude"
  echo '{"mode":"dark"}' > "$CLIKAE_HOME/template/claude/theme.json"

  run clikae init claude work
  [ "$status" -eq 0 ]
  run clikae solo claude work
  [ "$status" -eq 0 ]
  [ -f "$CLIKAE_HOME/profiles/claude/work/theme.json" ]
}
