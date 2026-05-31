#!/usr/bin/env bats
# tests/bats/antigravity.bats — `clikae antigravity`, the opt-in symlink-swap
# multi-account power mode. All runs against the isolated $HOME/$CLIKAE_HOME from
# helpers.bash, so it never touches a real ~/.gemini.

load '../helpers'

@test "antigravity status is OFF by default" {
  run clikae antigravity
  [ "$status" -eq 0 ]
  [[ "$output" == *"OFF"* ]]
  [[ "$output" == *"clikae antigravity enable"* ]]
}

@test "enable backs up + migrates ~/.gemini into a 'default' slot symlink" {
  mkdir -p "$HOME/.gemini"
  echo "LOGIN" > "$HOME/.gemini/auth.txt"
  run bash -c "printf 'y\n' | '$CLIKAE_BIN' antigravity enable"
  [ "$status" -eq 0 ]
  [ -L "$HOME/.gemini" ]                                              # now a symlink
  [ -f "$CLIKAE_HOME/profiles/antigravity/default/auth.txt" ]         # login migrated
  [ -f "$CLIKAE_HOME/antigravity-multi-consent" ]                     # consent recorded
  # The backup exists alongside.
  ls "$HOME"/.gemini.clikae.bak.* >/dev/null
  # Login still readable through the symlink.
  [ "$(cat "$HOME/.gemini/auth.txt")" = "LOGIN" ]
}

@test "enable does nothing without consent (answer N)" {
  mkdir -p "$HOME/.gemini"
  run bash -c "printf 'n\n' | '$CLIKAE_BIN' antigravity enable"
  [ "$status" -eq 0 ]
  [ ! -L "$HOME/.gemini" ]                                            # untouched
  [ ! -f "$CLIKAE_HOME/antigravity-multi-consent" ]
}

@test "add + use repoint the active slot" {
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" antigravity enable >/dev/null 2>&1
  clikae antigravity add work
  [ -d "$CLIKAE_HOME/profiles/antigravity/work" ]
  clikae antigravity use work
  [ "$(readlink "$HOME/.gemini")" = "$CLIKAE_HOME/profiles/antigravity/work" ]
  run clikae antigravity status
  [[ "$output" == *"● work  (active)"* ]] || [[ "$output" == *"work  (active)"* ]]
}

@test "use rejects an unknown slot" {
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" antigravity enable >/dev/null 2>&1
  run clikae antigravity use nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"No such slot"* ]]
}

@test "disable restores a real ~/.gemini from the active slot and clears consent" {
  mkdir -p "$HOME/.gemini"
  echo "LOGIN" > "$HOME/.gemini/auth.txt"
  printf 'y\n' | "$CLIKAE_BIN" antigravity enable >/dev/null 2>&1
  run clikae antigravity disable
  [ "$status" -eq 0 ]
  [ ! -L "$HOME/.gemini" ]
  [ -d "$HOME/.gemini" ]
  [ "$(cat "$HOME/.gemini/auth.txt")" = "LOGIN" ]                     # login preserved
  [ ! -f "$CLIKAE_HOME/antigravity-multi-consent" ]
}

@test "add/use require enabling first" {
  run clikae antigravity add work
  [ "$status" -ne 0 ]
  [[ "$output" == *"Enable first"* ]]
}
