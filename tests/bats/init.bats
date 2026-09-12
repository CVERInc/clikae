#!/usr/bin/env bats
# tests/bats/init.bats — `clikae init`

load '../helpers'

@test "init creates the profile directory" {
  run clikae init claude work
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work" ]
}

@test "init without --alias does not touch the rc file" {
  run clikae init claude work
  [ "$status" -eq 0 ]
  [ ! -f "$RC_FILE" ]
}

@test "init --alias creates the profile and one alias block" {
  run clikae init claude work --alias
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work" ]
  [ "$(rc_block_count claude.work)" -eq 1 ]
}

@test "init fails for an unknown CLI" {
  run clikae init nosuchcli work
  [ "$status" -ne 0 ]
  [[ "$output" == *"No built-in adapter"* ]] || false
}

@test "init fails when the profile already exists" {
  clikae init claude work
  run clikae init claude work
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]] || false
}

@test "init rejects a profile name with a leading dot" {
  run clikae init claude .hidden
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid profile name"* ]] || false
}

@test "init rejects a profile name with a slash" {
  run clikae init claude a/b
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid profile name"* ]] || false
}

@test "init accepts a dotted profile name" {
  run clikae init claude work.2
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work.2" ]
}

@test "init accepts a dashed profile name" {
  run clikae init claude work-acct
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work-acct" ]
}

@test "init applies the claude permissions template by default" {
  run clikae init claude work
  [ "$status" -eq 0 ]
  [ -f "$CLIKAE_HOME/profiles/claude/work/settings.json" ]
  [[ "$output" == *"advisory, not a sandbox"* ]] || false
}

@test "init --no-template skips the claude permissions template" {
  run clikae init claude work --no-template
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work" ]
  [ ! -e "$CLIKAE_HOME/profiles/claude/work/settings.json" ]
  [[ "$output" == *"Skipping permissions template"* ]] || false
}

@test "CLIKAE_NO_PERMISSIONS_TEMPLATE=1 skips the claude permissions template" {
  run env CLIKAE_NO_PERMISSIONS_TEMPLATE=1 "$CLIKAE_BIN" init claude work
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work" ]
  [ ! -e "$CLIKAE_HOME/profiles/claude/work/settings.json" ]
}

@test "init still creates a claude tank when jq is missing, and says so" {
  local stripped="/usr/bin:/bin"
  PATH="$stripped" command -v jq >/dev/null 2>&1 && skip "jq also lives in $stripped on this host"
  run env PATH="$stripped" "$CLIKAE_BIN" init claude work
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work" ]
  [ ! -e "$CLIKAE_HOME/profiles/claude/work/settings.json" ]
  [[ "$output" == *"requires jq"* ]] || false
}

@test "init still creates a claude tank when the template is missing, and says so" {
  local prefix="$BATS_TEST_TMPDIR/tap"
  mkdir -p "$prefix"
  cp -R "$CLIKAE_TEST_ROOT/bin" "$CLIKAE_TEST_ROOT/lib" "$prefix/"
  run "$prefix/bin/clikae" init claude work
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work" ]
  [ ! -e "$CLIKAE_HOME/profiles/claude/work/settings.json" ]
  [[ "$output" == *"No permissions template for engine: claude; skipping"* ]] || false
}

@test "init seeds an env-file adapter's config file (kubectl)" {
  run clikae init kubectl dev
  [ "$status" -eq 0 ]
  [ -f "$CLIKAE_HOME/profiles/kubectl/dev/config" ]
}

@test "init symlinks shared personal skills/commands into a new claude tank" {
  mkdir -p "$HOME/.claude/skills/recast-fidelity" "$HOME/.claude/commands"
  touch "$HOME/.claude/skills/recast-fidelity/SKILL.md"
  run clikae init claude work
  [ "$status" -eq 0 ]
  [ -L "$CLIKAE_HOME/profiles/claude/work/skills" ]
  [ -e "$CLIKAE_HOME/profiles/claude/work/skills/recast-fidelity/SKILL.md" ]
  [ -L "$CLIKAE_HOME/profiles/claude/work/commands" ]
}

@test "init does not create a skills symlink when ~/.claude/skills doesn't exist" {
  run clikae init claude work
  [ "$status" -eq 0 ]
  [ ! -e "$CLIKAE_HOME/profiles/claude/work/skills" ]
}

@test "init never clobbers a tank's own pre-existing skills dir" {
  mkdir -p "$HOME/.claude/skills"
  local d="$CLIKAE_HOME/profiles/claude/work"
  mkdir -p "$d/skills"
  touch "$d/skills/only-mine.md"
  run bash -c "source '$CLIKAE_TEST_ROOT/lib/adapters/claude.sh'; _claude_link_shared_asset '$d' skills"
  [ "$status" -eq 0 ]
  [ ! -L "$d/skills" ]
  [ -f "$d/skills/only-mine.md" ]
}

@test "init: auto-joining the machine's memory default does not hang on a real terminal (R2-P1-1)" {
  # init.sh auto-joins a new tank to the machine's default Soul group by
  # self-invoking `"$CLIKAE_BIN" memory share … >/dev/null 2>&1` — that
  # silences the CHILD's stdout+stderr but leaves its stdin alone. When a
  # discoverable legacy memory directory exists, `memory share` reaches its
  # adoption prompt and used to `read` from that same real terminal while its
  # own prompt had just gone to /dev/null: a black screen, forever. bats' own
  # `run` closes stdin, which would hide this entirely (see tests/README.md's
  # "prove it can fail") — a real pty is the only way to reproduce it.
  clikae init claude a
  clikae memory share me claude a
  mkdir -p "$HOME/.claude/projects/legacy/memory"
  printf '[x](x.md)\n' > "$HOME/.claude/projects/legacy/memory/MEMORY.md"
  printf 'legacy fact\n' > "$HOME/.claude/projects/legacy/memory/x.md"

  local out="$BATS_TEST_TMPDIR/init-b.out"
  _pty_run "$CLIKAE_BIN" init claude b > "$out" 2>&1 &
  local runner=$!

  local i finished=0
  for i in $(seq 1 40); do
    kill -0 "$runner" 2>/dev/null || { finished=1; break; }
    sleep 0.5
  done
  if [ "$finished" -eq 1 ]; then
    wait "$runner" 2>/dev/null || true
  else
    kill "$runner" 2>/dev/null || true
  fi
  [ "$finished" -eq 1 ] || { echo "init hung waiting on a prompt nobody could see (R2-P1-1)"; false; }

  local out_content; out_content="$(cat "$out")"
  [[ "$out_content" == *"Created tank: claude/b"* ]] || false
  [[ "$out_content" == *"joined the shared memory group"* || "$out_content" == *"could not join the memory group"* ]] || false
}
