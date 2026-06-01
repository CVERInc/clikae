#!/usr/bin/env bats
# tests/bats/antigravity.bats — Antigravity (agy) folded into the standard
# grammar (docs/grammar.md §6): init/agy<tank>/remove/--release, no subcommand
# tree. All runs against the isolated $HOME/$CLIKAE_HOME from helpers.bash, so it
# never touches a real ~/.gemini.

load '../helpers'

# Put a no-op `agy` on PATH so the exec at the end of a switch succeeds cleanly.
_stub_agy() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\ntrue\n' > "$BATS_TEST_TMPDIR/bin/agy"
  chmod +x "$BATS_TEST_TMPDIR/bin/agy"
}

@test "agy: no tanks by default, points at init" {
  run clikae agy
  [ "$status" -eq 0 ]
  [[ "$output" == *"No agy tanks yet"* ]] || false
  [[ "$output" == *"clikae init agy"* ]] || false
}

@test "init agy: first time takes ~/.gemini over into a 'default' tank + makes the tank" {
  mkdir -p "$HOME/.gemini"
  echo "LOGIN" > "$HOME/.gemini/auth.txt"
  run bash -c "printf 'y\n' | '$CLIKAE_BIN' init agy work"
  [ "$status" -eq 0 ]
  [ -L "$HOME/.gemini" ]                                              # now a symlink
  [ -f "$CLIKAE_HOME/profiles/antigravity/default/auth.txt" ]         # login migrated
  [ -d "$CLIKAE_HOME/profiles/antigravity/work" ]                     # new tank made
  [ -f "$CLIKAE_HOME/antigravity-multi-consent" ]                     # consent recorded
  ls "$HOME"/.gemini.clikae.bak.* >/dev/null                          # backup alongside
  [ "$(cat "$HOME/.gemini/auth.txt")" = "LOGIN" ]                     # login still readable
}

@test "init agy: declined (answer N) changes nothing" {
  mkdir -p "$HOME/.gemini"
  run bash -c "printf 'n\n' | '$CLIKAE_BIN' init agy work"
  [ "$status" -eq 0 ]
  [ ! -L "$HOME/.gemini" ]                                            # untouched
  [ ! -d "$CLIKAE_HOME/profiles/antigravity/work" ]
  [ ! -f "$CLIKAE_HOME/antigravity-multi-consent" ]
}

@test "init agy: second tank is a plain mkdir, no ceremony" {
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1
  # No stdin piped: if it tried to confirm again it would block/fail, not pass.
  run clikae init agy personal
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/antigravity/personal" ]
  [[ "$output" == *"Created agy tank: personal"* ]] || false
}

@test "agy <tank> repoints the active symlink" {
  _stub_agy
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae agy work
  [ "$(readlink "$HOME/.gemini")" = "$CLIKAE_HOME/profiles/antigravity/work" ]
  [[ "$output" == *"agy is now on tank: work"* ]] || false
}

@test "agy <tank> rejects an unknown tank" {
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1
  run clikae agy nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"No such agy tank"* ]] || false
}

@test "agy --release restores a real ~/.gemini from the active tank, keeps tanks, clears consent" {
  mkdir -p "$HOME/.gemini"
  echo "LOGIN" > "$HOME/.gemini/auth.txt"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1
  run clikae agy --release
  [ "$status" -eq 0 ]
  [ ! -L "$HOME/.gemini" ]
  [ -d "$HOME/.gemini" ]
  [ "$(cat "$HOME/.gemini/auth.txt")" = "LOGIN" ]                     # login preserved
  [ ! -f "$CLIKAE_HOME/antigravity-multi-consent" ]
  [ -d "$CLIKAE_HOME/profiles/antigravity/default" ]                  # tanks kept
}

@test "remove agy: removing the LAST tank restores ~/.gemini and ends multi-account" {
  mkdir -p "$HOME/.gemini"
  echo "LOGIN" > "$HOME/.gemini/auth.txt"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1
  clikae remove agy work -f >/dev/null 2>&1                           # leaves only 'default' (active)
  run bash -c "printf 'y\n' | '$CLIKAE_BIN' remove agy default"
  [ "$status" -eq 0 ]
  [ ! -L "$HOME/.gemini" ]
  [ -d "$HOME/.gemini" ]
  [ "$(cat "$HOME/.gemini/auth.txt")" = "LOGIN" ]                     # login preserved
  [ ! -f "$CLIKAE_HOME/antigravity-multi-consent" ]
}

@test "remove agy refuses the active tank while others remain" {
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1          # default active, work exists
  run clikae remove agy default -f
  [ "$status" -ne 0 ]
  [[ "$output" == *"active agy tank"* ]] || false
}

@test "clikae tanks lists agy tanks without crashing (no adapter regression)" {
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1
  run clikae tanks
  [ "$status" -eq 0 ]
  [[ "$output" == *"agy"* ]]          # canonical engine name, not 'antigravity'
  [[ "$output" == *"work"* ]] || false
}
