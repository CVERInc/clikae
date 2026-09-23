#!/usr/bin/env bats
# tests/bats/adapters/claude-stable-path.bats — #59: claude launches through a
# clikae-owned hard link so a macOS file-access grant survives auto-updates.

load '../../helpers'

# Two fake installed versions behind a repointable ~/.local/bin/claude symlink,
# mirroring Claude Code's own layout. Each prints $0 so a test can see which
# path the engine was actually launched through.
_fake_versions() {
  local v="$HOME/.local/share/claude/versions"
  mkdir -p "$v" "$HOME/.local/bin"
  printf '#!/bin/sh\necho "v1 $0"\n' > "$v/1.0.0"
  printf '#!/bin/sh\necho "v2 $0"\n' > "$v/2.0.0"
  chmod +x "$v/1.0.0" "$v/2.0.0"
  ln -sfn "$v/1.0.0" "$HOME/.local/bin/claude"
  export PATH="$HOME/.local/bin:$PATH"
}

_load() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
}

_prep() {
  export CLIKAE_CLAUDE_STABLE_PATH=1
  _fake_versions
  _load
}

@test "stable path is a hard link to the installed version (not a symlink)" {
  _prep
  run _claude_launch_bin
  [ "$status" -eq 0 ]
  [ "$output" = "$CLIKAE_HOME/bin/claude" ]
  [ ! -L "$CLIKAE_HOME/bin/claude" ]
  [ "$CLIKAE_HOME/bin/claude" -ef "$HOME/.local/share/claude/versions/1.0.0" ]
}

@test "stable path is refreshed when the installed binary moves" {
  _prep
  _claude_launch_bin >/dev/null
  ln -sfn "$HOME/.local/share/claude/versions/2.0.0" "$HOME/.local/bin/claude"
  run _claude_launch_bin
  [ "$output" = "$CLIKAE_HOME/bin/claude" ]
  [ "$CLIKAE_HOME/bin/claude" -ef "$HOME/.local/share/claude/versions/2.0.0" ]
  run "$CLIKAE_HOME/bin/claude"
  [ "$output" = "v2 $CLIKAE_HOME/bin/claude" ]
}

@test "copy fallback when the hard link fails" {
  _prep
  mkdir -p "$HOME/failbin"
  printf '#!/bin/sh\nexit 1\n' > "$HOME/failbin/ln"; chmod +x "$HOME/failbin/ln"
  PATH="$HOME/failbin:$PATH" run _claude_launch_bin
  [ "$output" = "$CLIKAE_HOME/bin/claude" ]
  [ ! -L "$CLIKAE_HOME/bin/claude" ]
  [ ! "$CLIKAE_HOME/bin/claude" -ef "$HOME/.local/share/claude/versions/1.0.0" ]
  cmp -s "$CLIKAE_HOME/bin/claude" "$HOME/.local/share/claude/versions/1.0.0"
  # A copy that already matches is left alone; a moved source replaces it.
  ln -sfn "$HOME/.local/share/claude/versions/2.0.0" "$HOME/.local/bin/claude"
  PATH="$HOME/failbin:$PATH" run _claude_launch_bin
  cmp -s "$CLIKAE_HOME/bin/claude" "$HOME/.local/share/claude/versions/2.0.0"
}

@test "opt-out leaves the launch on the bare PATH name and creates nothing" {
  _prep
  CLIKAE_CLAUDE_STABLE_PATH=0 run _claude_launch_bin
  [ "$output" = "claude" ]
  [ ! -e "$CLIKAE_HOME/bin/claude" ]
  clikae init claude work
  CLIKAE_CLAUDE_STABLE_PATH=0 run clikae claude work
  [[ "$output" == *"v1 $HOME/.local/bin/claude"* ]] || false
  [ ! -e "$CLIKAE_HOME/bin/claude" ]
}

@test "clikae claude <tank> launches through the stable path" {
  _prep
  clikae init claude work
  run clikae claude work
  [[ "$output" == *"v1 $CLIKAE_HOME/bin/claude"* ]] || false
}

@test "doctor: not created yet, up to date, then STALE after an update — read-only" {
  _prep
  run clikae doctor
  [[ "$output" =~ claude\ path\ +$CLIKAE_HOME/bin/claude\ —\ not\ created\ yet ]] || false
  _claude_launch_bin >/dev/null
  run clikae doctor
  [[ "$output" =~ claude\ path\ +$CLIKAE_HOME/bin/claude\ →\ version\ 1\.0\.0\ —\ up\ to\ date ]] || false
  ln -sfn "$HOME/.local/share/claude/versions/2.0.0" "$HOME/.local/bin/claude"
  before="$(ls -li "$CLIKAE_HOME/bin")"
  run clikae doctor
  [[ "$output" == *"version 1.0.0 — STALE — installed claude moved to "*"/.local/share/claude/versions/2.0.0"* ]] || false
  [ "$before" = "$(ls -li "$CLIKAE_HOME/bin")" ]
}

@test "doctor: opt-out is reported" {
  _prep
  CLIKAE_CLAUDE_STABLE_PATH=0 run clikae doctor
  [[ "$output" == *"claude path"*"stable path off"* ]] || false
}
