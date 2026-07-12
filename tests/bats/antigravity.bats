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

# --- agy login on switch: carry the Keychain token per tank (macOS) ----------
# agy reads its account from ONE machine-wide Keychain item, ignoring which tank
# dir ~/.gemini points at (verified live 2026-06-30). So clikae carries that login
# WITH the tank: on switch it stashes the outgoing tank's login into a
# clikae-namespaced slot and restores the incoming tank's (or logs out cleanly if
# the incoming tank has never logged in) — then VERIFIES the restore actually
# took before handing off to agy (2026-07-05: the fix for the 2026-06-30 trust bug
# where a silent no-op restore left agy on the wrong account with zero warning).
# These use the stateful `security` stub from helpers.bash ($CLIKAE_TEST_KEYCHAIN,
# one file per service); macOS-only (on Linux agy stores creds in ~/.gemini, which
# the dir swap already isolates).

@test "agy switch to a different tank stashes outgoing, restores incoming" {
  [[ "$OSTYPE" == darwin* ]] || skip "agy keychain carry is macOS-only"
  _stub_agy
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1     # default(active)+work
  printf 'token-default' > "$CLIKAE_TEST_KEYCHAIN/gemini"        # signed in on default
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae agy work          # work != default → carry
  [ "$status" -eq 0 ]
  [ "$(cat "$CLIKAE_TEST_KEYCHAIN/clikae-agy-default")" = "token-default" ]  # outgoing stashed
  [ ! -f "$CLIKAE_TEST_KEYCHAIN/gemini" ]                          # work has no stash yet → logged out clean
}

@test "agy switch to a tank with a prior stash restores its own token" {
  [[ "$OSTYPE" == darwin* ]] || skip "agy keychain carry is macOS-only"
  _stub_agy
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1
  printf 'token-work' > "$CLIKAE_TEST_KEYCHAIN/clikae-agy-work"   # work already has a stash
  printf 'token-default' > "$CLIKAE_TEST_KEYCHAIN/gemini"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae agy work
  [ "$status" -eq 0 ]
  [ "$(cat "$CLIKAE_TEST_KEYCHAIN/gemini")" = "token-work" ]       # restored work's own token
  [ "$(cat "$CLIKAE_TEST_KEYCHAIN/clikae-agy-default")" = "token-default" ]  # default's stash kept
}

@test "agy switch to the already-active tank does NOT touch the Keychain" {
  [[ "$OSTYPE" == darwin* ]] || skip "agy keychain carry is macOS-only"
  _stub_agy
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1     # default active
  printf 'token-default' > "$CLIKAE_TEST_KEYCHAIN/gemini"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae agy default       # default == active → no-op
  [ "$status" -eq 0 ]
  [ "$(cat "$CLIKAE_TEST_KEYCHAIN/gemini")" = "token-default" ]   # still signed in, untouched
}

@test "agy switch to the already-active tank is a no-op even with a live agy process (headless-on-active)" {
  [[ "$OSTYPE" == darwin* ]] || skip "agy keychain carry is macOS-only"
  _stub_agy
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1      # 'default' is the active tank
  printf 'token-default' > "$CLIKAE_TEST_KEYCHAIN/gemini"
  # Simulate a LIVE agy session: pgrep -x agy reports a match.
  printf '#!/usr/bin/env bash\n[ "$1" = "-x" ] && [ "$2" = "agy" ] && exit 0\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/pgrep"
  chmod +x "$BATS_TEST_TMPDIR/bin/pgrep"
  # Switching to the tank you're ALREADY on repoints nothing, so it must NOT be
  # refused — this is how you drive agy headless on the active account.
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae agy default
  [ "$status" -eq 0 ]
  [[ "$output" != *"Quit it first"* ]] || false                  # NOT the not-running refusal
  [ "$(cat "$CLIKAE_TEST_KEYCHAIN/gemini")" = "token-default" ]   # login untouched
  [ "$(readlink "$HOME/.gemini")" = "$CLIKAE_HOME/profiles/antigravity/default" ]  # symlink intact
}

@test "agy switch to a DIFFERENT tank still refuses while an agy process is live" {
  [[ "$OSTYPE" == darwin* ]] || skip "agy keychain carry is macOS-only"
  _stub_agy
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1      # 'default' active, 'work' exists
  printf '#!/usr/bin/env bash\n[ "$1" = "-x" ] && [ "$2" = "agy" ] && exit 0\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/pgrep"
  chmod +x "$BATS_TEST_TMPDIR/bin/pgrep"
  # A REAL switch (work != default) WOULD yank ~/.gemini out from under the live
  # session — the guard must still block it.
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae agy work
  [ "$status" -ne 0 ]
  [[ "$output" == *"Quit it first"* ]] || false
}

@test "agy switch refuses to proceed if the restore doesn't verify" {
  [[ "$OSTYPE" == darwin* ]] || skip "agy keychain carry is macOS-only"
  _stub_agy
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1
  printf 'token-work' > "$CLIKAE_TEST_KEYCHAIN/clikae-agy-work"
  printf 'token-default' > "$CLIKAE_TEST_KEYCHAIN/gemini"
  # Sabotage the stub mid-flight: make add-generic-password a silent no-op, so
  # the restore's copy "succeeds" (exit 0) but the canonical item never changes —
  # exactly the failure mode that caused the 2026-06-30 incident.
  cat > "$BATS_TEST_TMPDIR/bin/security" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "add-generic-password" ]; then exit 0; fi
exec "$TEST_HOME/.testbin/security" "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/security"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae agy work
  [ "$status" -ne 0 ]
  [[ "$output" == *"didn't verify"* ]] || false
  [ "$(cat "$CLIKAE_TEST_KEYCHAIN/gemini")" = "token-default" ]   # canonical left as-is, NOT silently trusted
}

@test "rename agy carries the tank's Keychain slot across" {
  [[ "$OSTYPE" == darwin* ]] || skip "agy keychain carry is macOS-only"
  _stub_agy
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1
  printf 'token-work' > "$CLIKAE_TEST_KEYCHAIN/clikae-agy-work"  # work's stashed login
  run clikae rename agy work laptop
  [ "$status" -eq 0 ]
  [ "$(cat "$CLIKAE_TEST_KEYCHAIN/clikae-agy-laptop")" = "token-work" ]  # carried to the new slot name
  [ ! -f "$CLIKAE_TEST_KEYCHAIN/clikae-agy-work" ]                       # old slot name gone
}
