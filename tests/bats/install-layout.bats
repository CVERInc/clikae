#!/usr/bin/env bats
# tests/bats/install-layout.bats — proves the shipped install layouts actually
# carry templates/ where lib/commands/settings.sh looks for them, and that a
# layout missing templates/ (the real Homebrew tap's `libexec.install "bin",
# "lib"`, drifted from this repo's own formula/install.sh) degrades instead
# of breaking `init`. See CVERInc/clikae#85 round-1 review, P1-1.

load '../helpers'

@test "a bin+lib-only prefix (the drifted tap layout) still lets init finish" {
  local prefix="$BATS_TEST_TMPDIR/tap-no-templates"
  mkdir -p "$prefix"
  cp -R "$CLIKAE_TEST_ROOT/bin" "$CLIKAE_TEST_ROOT/lib" "$prefix/"
  run "$prefix/bin/clikae" init claude worktap
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created tank: claude/worktap"* ]] || false
  [[ "$output" == *"No permissions template for engine: claude; skipping"* ]] || false
  [ -d "$CLIKAE_HOME/profiles/claude/worktap" ]
  [ ! -e "$CLIKAE_HOME/profiles/claude/worktap/settings.json" ]
}

@test "install.sh's own layout (bin+lib+templates) applies the permissions template" {
  local prefix="$BATS_TEST_TMPDIR/full-install"
  PREFIX="$prefix" "$CLIKAE_TEST_ROOT/install.sh" >/dev/null 2>&1
  [ -f "$prefix/share/clikae/templates/permissions/claude.json" ]
  run "$prefix/share/clikae/bin/clikae" init claude workfull
  [ "$status" -eq 0 ]
  [ -f "$CLIKAE_HOME/profiles/claude/workfull/settings.json" ]
  run env CLIKAE_HOME="$CLIKAE_HOME" "$prefix/share/clikae/bin/clikae" settings apply claude workfull --check
  [ "$status" -eq 0 ]
}

@test "the in-repo Homebrew formula copy still installs templates/ next to bin and lib" {
  run grep -E '^\s*libexec\.install "bin", "lib", "templates"' "$CLIKAE_TEST_ROOT/homebrew/clikae.rb"
  [ "$status" -eq 0 ]
  run grep -E '^\s*depends_on "jq"' "$CLIKAE_TEST_ROOT/homebrew/clikae.rb"
  [ "$status" -eq 0 ]
}
