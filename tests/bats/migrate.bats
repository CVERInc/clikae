#!/usr/bin/env bats
# tests/bats/migrate.bats — `clikae migrate`

load '../helpers'

# Build a synthetic legacy "claude dual accounts" setup in the test HOME.
seed_legacy() {
  mkdir -p "$TEST_HOME/.claude-acct-a" "$TEST_HOME/.claude-acct-b"
  echo "creds-a" > "$TEST_HOME/.claude-acct-a/.claude.json"
  echo "creds-b" > "$TEST_HOME/.claude-acct-b/.claude.json"
  cat > "$RC_FILE" <<'EOF'
export EDITOR=vim
# >>> claude dual accounts (managed by setup-claude-dual-accounts.sh) >>>
alias claude-a='CLAUDE_CONFIG_DIR="$HOME/.claude-acct-a" claude'
alias claude-b='CLAUDE_CONFIG_DIR="$HOME/.claude-acct-b" claude'
# <<< claude dual accounts <<<
alias ll='ls -la'
EOF
}

@test "migrate --dry-run shows a plan and changes nothing" {
  seed_legacy
  run clikae migrate --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Migration plan"* ]]
  [[ "$output" == *"Dry run"* ]]
  # untouched
  [ -d "$TEST_HOME/.claude-acct-a" ]
  [ ! -d "$CLIKAE_HOME/profiles/claude/a" ]
  grep -q "claude dual accounts" "$RC_FILE"
}

@test "migrate --force moves the dirs and creates the profiles" {
  seed_legacy
  run clikae migrate --force
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/a" ]
  [ -d "$CLIKAE_HOME/profiles/claude/b" ]
  [ ! -d "$TEST_HOME/.claude-acct-a" ]
  [ ! -d "$TEST_HOME/.claude-acct-b" ]
}

@test "migrate preserves the moved config data" {
  seed_legacy
  clikae migrate --force
  [ "$(cat "$CLIKAE_HOME/profiles/claude/a/.claude.json")" = "creds-a" ]
  [ "$(cat "$CLIKAE_HOME/profiles/claude/b/.claude.json")" = "creds-b" ]
}

@test "migrate rewrites aliases into clikae blocks pointing at the new dirs" {
  seed_legacy
  clikae migrate --force
  [ "$(rc_block_count claude.a)" -eq 1 ]
  [ "$(rc_block_count claude.b)" -eq 1 ]
  grep -qF "alias claude-a='CLAUDE_CONFIG_DIR=\"$CLIKAE_HOME/profiles/claude/a\" claude'" "$RC_FILE"
}

@test "migrate removes the legacy block and sentinels" {
  seed_legacy
  clikae migrate --force
  ! grep -q "claude dual accounts" "$RC_FILE"
}

@test "migrate preserves unrelated rc content" {
  seed_legacy
  clikae migrate --force
  grep -qF "export EDITOR=vim" "$RC_FILE"
  grep -qF "alias ll='ls -la'" "$RC_FILE"
}

@test "migrate backs up the rc file" {
  seed_legacy
  clikae migrate --force
  [ "$(rc_backup_count)" -ge 1 ]
}

@test "migrate is idempotent" {
  seed_legacy
  clikae migrate --force
  run clikae migrate --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"no"*"aliases to migrate"* ]] || [[ "$output" == *"No migratable"* ]]
  [ "$(rc_block_count claude.a)" -eq 1 ]
}

@test "migrate reports nothing to do when there is no rc file" {
  run clikae migrate --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to migrate"* ]]
}

@test "migrate does not clobber an existing clikae profile" {
  seed_legacy
  clikae init claude a            # pre-existing profile 'a'
  run clikae migrate --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  # The pre-existing 'a' profile dir must remain (not overwritten by the move).
  [ -d "$CLIKAE_HOME/profiles/claude/a" ]
  # 'b' still migrates.
  [ -d "$CLIKAE_HOME/profiles/claude/b" ]
}

@test "migrate creates an empty profile when the source dir is missing" {
  cat > "$RC_FILE" <<'EOF'
alias claude-gone='CLAUDE_CONFIG_DIR="$HOME/.claude-acct-gone" claude'
EOF
  run clikae migrate --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing"* ]]
  [ -d "$CLIKAE_HOME/profiles/claude/gone" ]
}
