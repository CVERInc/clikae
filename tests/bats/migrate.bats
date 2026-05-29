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

@test "migrate --keep-login --dry-run notes the saved-login carry-over (claude)" {
  seed_legacy
  run clikae migrate --keep-login --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"carry over each profile's saved login"* ]]
  # still a dry run — nothing moved
  [ -d "$TEST_HOME/.claude-acct-a" ]
}

@test "migrate --keep-login has no effect for an adapter without the hook (gh)" {
  cat > "$RC_FILE" <<'EOF'
alias gh-work='GH_CONFIG_DIR="$HOME/.gh-work" gh'
EOF
  mkdir -p "$TEST_HOME/.gh-work"
  run clikae migrate gh --keep-login --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no effect for 'gh'"* ]]
}

@test "migrate --keep-login carries the saved login to the new keychain slot (macOS, stubbed security)" {
  [[ "$OSTYPE" == darwin* ]] || skip "keychain carry-over is macOS-only"
  seed_legacy

  # Stub `security` so the test never touches the real login keychain. State
  # lives as one file per service name under $STUB_STATE.
  local stub_bin="$TEST_HOME/stubbin"
  export STUB_STATE="$TEST_HOME/keychain"
  mkdir -p "$stub_bin" "$STUB_STATE"
  cat > "$stub_bin/security" <<'STUB'
#!/usr/bin/env bash
state="$STUB_STATE"
sub="$1"; shift
svc=""; want_w=0; secret=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s) svc="$2"; shift 2 ;;
    -w) shift
        if [ "$sub" = "add-generic-password" ]; then secret="$1"; shift; else want_w=1; fi ;;
    -a|-l) shift 2 ;;
    -U) shift ;;
    *) shift ;;
  esac
done
file="$state/$svc"
case "$sub" in
  find-generic-password)
    [ -f "$file" ] || exit 1
    if [ "$want_w" -eq 1 ]; then cat "$file"; else echo '    "acct"<blob>="testacct"'; fi
    exit 0 ;;
  add-generic-password)
    printf '%s' "$secret" > "$file"; exit 0 ;;
esac
exit 1
STUB
  chmod +x "$stub_bin/security"
  PATH="$stub_bin:$PATH"; export PATH

  # Seed the OLD path's keychain slot for profile a (real shasum-derived suffix).
  local old_svc new_svc
  old_svc="Claude Code-credentials-$(printf '%s' "$TEST_HOME/.claude-acct-a" | shasum -a 256 | cut -c1-8)"
  printf 'secret-token-a' > "$STUB_STATE/$old_svc"

  run clikae migrate --keep-login --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Carried over saved login for claude/a"* ]]

  # The token now lives under the NEW path's slot, unchanged.
  new_svc="Claude Code-credentials-$(printf '%s' "$CLIKAE_HOME/profiles/claude/a" | shasum -a 256 | cut -c1-8)"
  [ -f "$STUB_STATE/$new_svc" ]
  [ "$(cat "$STUB_STATE/$new_svc")" = "secret-token-a" ]

  # Profile b had no saved login → reported as nothing to carry over.
  [[ "$output" == *"No saved login to carry over for claude/b"* ]]
}
