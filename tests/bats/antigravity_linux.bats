#!/usr/bin/env bats
# tests/bats/antigravity_linux.bats — #96: the Linux backend of the agy login
# carry. `uname` is stubbed to Linux; agy's login there is the single file
# ~/.gemini/antigravity-cli/antigravity-oauth-token, which lives inside each
# tank dir and moves with the ~/.gemini symlink. FAKE token values only.

load '../helpers'

TOK_REL="antigravity-cli/antigravity-oauth-token"

setup_linux() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\necho Linux\n' > "$BATS_TEST_TMPDIR/bin/uname"
  printf '#!/usr/bin/env bash\ntrue\n' > "$BATS_TEST_TMPDIR/bin/agy"
  # A `security` that fails loudly if the Linux path ever reaches for Keychain.
  printf '#!/usr/bin/env bash\necho "security called: $*" >> "%s/security.log"\nexit 1\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/security"
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

_fake_login() {  # <dir> <value>
  mkdir -p "$1/antigravity-cli"
  printf '%s' "$2" > "$1/$TOK_REL"; chmod 600 "$1/$TOK_REL"
}
_mode() { if stat -c %a "$1" >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
_slot() { printf '%s\n' "$CLIKAE_HOME/profiles/antigravity/$1"; }

@test "linux agy: takeover keeps the login file in the adopted tank, 0600" {
  setup_linux
  _fake_login "$HOME/.gemini" "FAKE-A"
  printf 'y\n' | clikae init agy b >/dev/null 2>&1
  [ "$(cat "$(_slot default)/$TOK_REL")" = "FAKE-A" ]
  [ "$(cat "$HOME/.gemini/$TOK_REL")" = "FAKE-A" ]
  [ "$(_mode "$(_slot default)/$TOK_REL")" = "600" ]
}

@test "linux agy: switch saves the outgoing login and restores the incoming one (round trip)" {
  setup_linux
  _fake_login "$HOME/.gemini" "FAKE-A"
  printf 'y\n' | clikae init agy b >/dev/null 2>&1
  _fake_login "$(_slot b)" "FAKE-B"
  run clikae agy b
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.gemini/$TOK_REL")" = "FAKE-B" ]
  printf 'FAKE-B-REFRESHED' > "$HOME/.gemini/$TOK_REL"   # agy refreshes on use
  run clikae agy default
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.gemini/$TOK_REL")" = "FAKE-A" ]
  [ "$(cat "$(_slot b)/$TOK_REL")" = "FAKE-B-REFRESHED" ]   # saved with its tank
  [ "$(_mode "$(_slot b)/$TOK_REL")" = "600" ]
  [ ! -e "$BATS_TEST_TMPDIR/security.log" ]                  # Keychain never touched
}

@test "linux agy: a switch tightens a loosened token back to 0600" {
  setup_linux
  _fake_login "$HOME/.gemini" "FAKE-A"
  printf 'y\n' | clikae init agy b >/dev/null 2>&1
  _fake_login "$(_slot b)" "FAKE-B"; chmod 644 "$(_slot b)/$TOK_REL"
  clikae agy b >/dev/null 2>&1
  [ "$(_mode "$(_slot b)/$TOK_REL")" = "600" ]
}

@test "linux agy: switching to a tank with no login is reported, not a crash" {
  setup_linux
  _fake_login "$HOME/.gemini" "FAKE-A"
  printf 'y\n' | clikae init agy b >/dev/null 2>&1
  run clikae agy b
  [ "$status" -eq 0 ]
  [[ "$output" == *"no saved login"* ]] || false
  [ "$(readlink "$HOME/.gemini")" = "$(_slot b)" ]
  [ "$(cat "$(_slot default)/$TOK_REL")" = "FAKE-A" ]         # outgoing login intact
}

@test "linux agy: rename carries the login file" {
  setup_linux
  _fake_login "$HOME/.gemini" "FAKE-A"
  printf 'y\n' | clikae init agy b >/dev/null 2>&1
  _fake_login "$(_slot b)" "FAKE-B"
  run clikae rename agy b r
  [ "$status" -eq 0 ]
  [ "$(cat "$(_slot r)/$TOK_REL")" = "FAKE-B" ]
  [ "$(_mode "$(_slot r)/$TOK_REL")" = "600" ]
  run clikae agy r
  [ "$(cat "$HOME/.gemini/$TOK_REL")" = "FAKE-B" ]
}

@test "linux agy: remove drops only that tank's login" {
  setup_linux
  _fake_login "$HOME/.gemini" "FAKE-A"
  printf 'y\n' | clikae init agy b >/dev/null 2>&1
  _fake_login "$(_slot b)" "FAKE-B"
  run clikae remove agy b
  [ "$status" -eq 0 ]
  [ ! -e "$(_slot b)" ]
  [ "$(cat "$HOME/.gemini/$TOK_REL")" = "FAKE-A" ]
}

@test "linux agy: doctor names the file backend and which tanks carry a login" {
  setup_linux
  _fake_login "$HOME/.gemini" "FAKE-A"
  printf 'y\n' | clikae init agy b >/dev/null 2>&1
  run clikae doctor
  [[ "$output" == *"backend"*"file ("* ]] || false
  [[ "$output" == *"carry a saved login: default"* ]] || false
  [[ "$output" == *"no saved login: b"* ]] || false
  [[ "$output" != *"FAKE-A"* ]] || false                         # never the secret
  [[ "$output" != *"Login Keychain"* ]] || false
}
