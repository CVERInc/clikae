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

@test "rename agy: moves the tank dir, and repoints ~/.gemini for the active one" {
  mkdir -p "$HOME/.gemini"; echo "LOGIN" > "$HOME/.gemini/auth.txt"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1   # default(active) + work
  # inactive tank: just moves
  run clikae rename agy work laptop
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/antigravity/laptop" ]
  [ ! -d "$CLIKAE_HOME/profiles/antigravity/work" ]
  # active tank: moves AND repoints the symlink
  run clikae rename agy default main
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.gemini")" = "$CLIKAE_HOME/profiles/antigravity/main" ]
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

# --- agy login on switch: log out, let agy re-OAuth (macOS) -------------------
# agy reads its account from ONE machine-wide Keychain item, ignoring which tank
# dir ~/.gemini points at (verified live 2026-06-30). So clikae doesn't carry
# tokens — on a tank switch it just LOGS OUT (clears that one item) and agy prompts
# a fresh sign-in for the new tank's account. clikae never reads/writes a token and
# keeps no per-tank Keychain slots. These use the stateful `security` stub from
# helpers.bash ($CLIKAE_TEST_KEYCHAIN, one file per service); macOS-only (on Linux
# agy stores creds in ~/.gemini, which the dir swap already isolates).

@test "agy switch to a different tank logs out so it signs in fresh" {
  [[ "$OSTYPE" == darwin* ]] || skip "agy keychain logout is macOS-only"
  _stub_agy
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1     # default(active)+work
  printf 'token-default' > "$CLIKAE_TEST_KEYCHAIN/gemini"        # signed in on default
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae agy work          # work != default → logout
  [ "$status" -eq 0 ]
  [ ! -f "$CLIKAE_TEST_KEYCHAIN/gemini" ]                         # logged out → agy re-OAuths
  [ -z "$(ls "$CLIKAE_TEST_KEYCHAIN"/clikae-agy-* 2>/dev/null)" ] # NO per-tank slots — clikae carries nothing
}

@test "agy switch to the already-active tank does NOT log out" {
  [[ "$OSTYPE" == darwin* ]] || skip "agy keychain logout is macOS-only"
  _stub_agy
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1     # default active
  printf 'token-default' > "$CLIKAE_TEST_KEYCHAIN/gemini"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae agy default       # default == active → no logout
  [ "$status" -eq 0 ]
  [ "$(cat "$CLIKAE_TEST_KEYCHAIN/gemini")" = "token-default" ]   # still signed in
}

@test "rename agy doesn't touch the Keychain (login isn't per-tank)" {
  [[ "$OSTYPE" == darwin* ]] || skip "agy keychain is macOS-only"
  _stub_agy
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1
  printf 'token' > "$CLIKAE_TEST_KEYCHAIN/gemini"                 # the one canonical login
  run clikae rename agy work laptop
  [ "$status" -eq 0 ]
  [ "$(cat "$CLIKAE_TEST_KEYCHAIN/gemini")" = "token" ]           # untouched by rename
}
