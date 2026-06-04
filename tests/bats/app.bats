#!/usr/bin/env bats
# tests/bats/app.bats — `clikae app` (macOS only; skipped elsewhere)

load '../helpers'

macos_only() { [ "$(uname -s)" = "Darwin" ] || skip "clikae app is macOS-only"; }

@test "app generates a .app bundle" {
  macos_only
  clikae init claude work
  run clikae app claude work --out "$TEST_HOME/Apps"
  [ "$status" -eq 0 ]
  [ -d "$TEST_HOME/Apps/claude (work).app" ]
}

@test "app refuses to overwrite an existing .app without --force" {
  macos_only
  clikae init claude work
  clikae app claude work --out "$TEST_HOME/Apps"
  run clikae app claude work --out "$TEST_HOME/Apps"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]] || false
}

@test "app overwrites an existing .app with --force" {
  macos_only
  clikae init claude work
  clikae app claude work --out "$TEST_HOME/Apps"
  run clikae app claude work --out "$TEST_HOME/Apps" --force
  [ "$status" -eq 0 ]
  [ -d "$TEST_HOME/Apps/claude (work).app" ]
}

@test "app embeds the --global-config flag for a flag-strategy adapter (vercel)" {
  macos_only
  clikae init vercel prod
  run clikae app vercel prod --out "$TEST_HOME/Apps"
  [ "$status" -eq 0 ]
  [ -d "$TEST_HOME/Apps/vercel (prod).app" ]
  run osadecompile "$TEST_HOME/Apps/vercel (prod).app"
  [[ "$output" == *"vercel --global-config"* ]] || false
  [[ "$output" == *"profiles/vercel/prod"* ]] || false
}

@test "app fails for a missing profile" {
  macos_only
  run clikae app claude ghost --out "$TEST_HOME/Apps"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Profile not found"* ]] || false
}

@test "app rejects an unknown --terminal target" {
  macos_only
  clikae init claude work
  run clikae app claude work --terminal bogus --out "$TEST_HOME/Apps"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown --terminal"* ]] || false
}

@test "app --terminal ghostty uses a trusted config file, not -e (no Allow dialog)" {
  macos_only
  [ -d "/Applications/Ghostty.app" ] || [ -d "$HOME/Applications/Ghostty.app" ] || skip "Ghostty not installed"
  clikae init claude work
  run clikae app claude work --terminal ghostty --out "$TEST_HOME/Apps"
  [ "$status" -eq 0 ]
  local app="$TEST_HOME/Apps/claude (work).app"
  [ -d "$app" ]
  # The launcher goes through `open … --config-file=`, NEVER `-e` (which pops
  # Ghostty's "Allow Ghostty to execute…?" dialog and looks like an empty shell).
  run osadecompile "$app"
  [[ "$output" == *"open -na Ghostty.app --args --config-file="* ]] || false
  [[ "$output" != *"-e /bin/zsh"* ]] || false   # the old, dialog-triggering form
  # Title + command live in the trusted conf the script reads via `path to me`.
  run cat "$app/Contents/Resources/clikae-ghostty.conf"
  [[ "$output" == *"title = claude (work)"* ]] || false
  [[ "$output" == *"command = /bin/zsh -lc"* ]] || false
  [[ "$output" == *"claude"* ]] || false
}

@test "app --board makes a clikae.app that opens the board (Terminal)" {
  macos_only
  run clikae app --board --out "$TEST_HOME/Apps"
  [ "$status" -eq 0 ]
  [ -d "$TEST_HOME/Apps/clikae.app" ]
  run osadecompile "$TEST_HOME/Apps/clikae.app"
  [[ "$output" == *"clikae; exec zsh -i"* ]] || false
}

@test "app --board with ghostty puts the board command in the conf" {
  macos_only
  [ -d "/Applications/Ghostty.app" ] || [ -d "$HOME/Applications/Ghostty.app" ] || skip "Ghostty not installed"
  run clikae app --board --terminal ghostty --out "$TEST_HOME/Apps"
  [ "$status" -eq 0 ]
  run cat "$TEST_HOME/Apps/clikae.app/Contents/Resources/clikae-ghostty.conf"
  [[ "$output" == *"title = clikae"* ]] || false
  [[ "$output" == *"clikae; exec zsh -i"* ]] || false
}

@test "app --board rejects an engine/tank argument" {
  macos_only
  run clikae app --board claude work
  [ "$status" -ne 0 ]
  [[ "$output" == *"board"* ]] || false
}

@test "app respects \$CLIKAE_TERMINAL as the default target" {
  macos_only
  [ -d "/Applications/Ghostty.app" ] || [ -d "$HOME/Applications/Ghostty.app" ] || skip "Ghostty not installed"
  clikae init claude work
  CLIKAE_TERMINAL=ghostty run clikae app claude work --out "$TEST_HOME/Apps"
  [ "$status" -eq 0 ]
  run osadecompile "$TEST_HOME/Apps/claude (work).app"
  [[ "$output" == *"open -na Ghostty.app"* ]] || false
}

@test "app --terminal iterm2 errors clearly when iTerm2 is absent" {
  macos_only
  [ -d "/Applications/iTerm.app" ] && skip "iTerm2 is installed; this test asserts the not-found path"
  [ -d "$HOME/Applications/iTerm.app" ] && skip "iTerm2 is installed; this test asserts the not-found path"
  clikae init claude work
  run clikae app claude work --terminal iterm2 --out "$TEST_HOME/Apps"
  [ "$status" -ne 0 ]
  [[ "$output" == *"iTerm2 not found"* ]] || false
}
