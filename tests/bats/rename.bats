#!/usr/bin/env bats
# tests/bats/rename.bats — `clikae rename`

load '../helpers'

@test "rename moves the dir and rewrites the alias" {
  clikae init claude a
  clikae alias claude a
  run clikae rename claude a cver --force
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/cver" ]
  [ ! -d "$CLIKAE_HOME/profiles/claude/a" ]
  grep -qF "alias claude-cver=" "$RC_FILE"
  ! grep -qF "alias claude-a=" "$RC_FILE"
}

@test "rename points the new alias at the new directory" {
  clikae init claude a
  clikae alias claude a
  clikae rename claude a cver --force
  grep -qF "CLAUDE_CONFIG_DIR=\"$CLIKAE_HOME/profiles/claude/cver\"" "$RC_FILE"
}

@test "rename works without an alias (dir only)" {
  clikae init claude a
  run clikae rename claude a cver --force
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/cver" ]
}

@test "rename carries the burn-order entry across (tank keeps its board position)" {
  clikae init claude a
  clikae init claude b
  clikae init claude c
  # Materialise an explicit order with 'a' pinned at the TOP.
  printf 'claude/a\nclaude/c\nclaude/b\n' > "$CLIKAE_HOME/order"
  clikae rename claude a cver --force
  # The order file now names the new tank, in the SAME position (first line).
  run head -n 1 "$CLIKAE_HOME/order"
  [ "$output" = "claude/cver" ] || false
  ! grep -qxF "claude/a" "$CLIKAE_HOME/order"
}

@test "rename carries the dry marker across (red badge follows the new name)" {
  clikae init claude a
  mkdir -p "$CLIKAE_HOME/dry/claude"
  printf '%s\tresets 11pm\n' "$(date +%s)" > "$CLIKAE_HOME/dry/claude/a"
  clikae rename claude a cver --force
  [ ! -f "$CLIKAE_HOME/dry/claude/a" ]
  [ -f "$CLIKAE_HOME/dry/claude/cver" ]
  grep -qF "resets 11pm" "$CLIKAE_HOME/dry/claude/cver"
}

@test "rename refuses when the target already exists" {
  clikae init claude a
  clikae init claude cver
  run clikae rename claude a cver --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]] || false
}

@test "rename refuses when the source is missing" {
  run clikae rename claude ghost cver --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || false
}

@test "rename refuses the same name" {
  clikae init claude a
  run clikae rename claude a a --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"same"* ]] || false
}

@test "rename refuses to move a profile in use in this shell" {
  clikae init claude a
  run env CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" "$CLIKAE_BIN" rename claude a cver --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"currently points"* ]] || false
  # nothing moved
  [ -d "$CLIKAE_HOME/profiles/claude/a" ]
}

@test "rename keeps a custom alias name (only swaps the default pattern)" {
  clikae init claude a
  clikae alias claude a --name myclaude
  clikae rename claude a cver --force
  grep -qF "alias myclaude=" "$RC_FILE"
}

@test "list shows the logged-in account label for claude" {
  clikae init claude a
  printf '{"oauthAccount":{"emailAddress":"hi@cver.net"}}' > "$CLIKAE_HOME/profiles/claude/a/.claude.json"
  run clikae list
  [ "$status" -eq 0 ]
  [[ "$output" == *"hi@cver.net"* ]] || false
}

@test "list reads the account label from pretty-printed .claude.json (real format)" {
  # Real Claude Code writes the file with whitespace after the colon; the label
  # extractor must tolerate it, and a profile whose file lacks the field must not
  # crash list (the no-match grep must not propagate under set -eo pipefail).
  clikae init claude a
  clikae init claude b
  printf '{\n  "oauthAccount": {\n    "emailAddress": "spaced@cver.net"\n  }\n}\n' \
    > "$CLIKAE_HOME/profiles/claude/a/.claude.json"
  printf '{\n  "numStartups": 3\n}\n' > "$CLIKAE_HOME/profiles/claude/b/.claude.json"
  run clikae list
  [ "$status" -eq 0 ]
  [[ "$output" == *"spaced@cver.net"* ]] || false
}

@test "list shows a dash when no account is detectable" {
  clikae init gh personal
  run clikae list
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh"*"personal"*"-"* ]] || false
}

# #74 round-1 P2-2: the burn sidecar is out-of-dir state keyed by tank NAME —
# rename_tank_state's twin for burn-order/the dry marker, added here too.
@test "rename carries the burn sidecar across (a renamed tank's burn sessions stay hidden under the new name)" {
  clikae init claude a
  mkdir -p "$CLIKAE_HOME/state/burn-sessions/claude"
  printf 'aaaaaaaa-1111-4111-8111-111111111111\trun\t1700000000\n' > "$CLIKAE_HOME/state/burn-sessions/claude/a"
  clikae rename claude a cver --force
  [ ! -f "$CLIKAE_HOME/state/burn-sessions/claude/a" ]
  [ -f "$CLIKAE_HOME/state/burn-sessions/claude/cver" ]
  grep -qF "aaaaaaaa-1111-4111-8111-111111111111" "$CLIKAE_HOME/state/burn-sessions/claude/cver"
}

@test "rename with no burn sidecar on record is a no-op (no file created)" {
  clikae init claude a
  clikae rename claude a cver --force
  [ ! -d "$CLIKAE_HOME/state/burn-sessions" ]
}

# ── the tank's own engine config across a rename (#141) ─────────────────────
# 🔴 THIS IS A VERIFICATION, NOT A FEATURE. A tank's hooks (settings.json) and
# its user-scope MCP servers (.claude.json) live INSIDE the directory rename
# moves, so they were always carried — the defect reported in #141 was that
# nobody could tell. Adding code to "carry" them would have been a second
# mover racing the `mv`. So the carry is asserted here, and cmd_rename only
# says out loud what it did.

@test "rename carries the tank's hooks and MCP servers across, and says so" {
  command -v jq >/dev/null 2>&1 || skip "needs jq to write the fixtures"
  clikae init claude a
  local old="$CLIKAE_HOME/profiles/claude/a"
  jq '.hooks.Stop = [{hooks: [{type: "command", command: "/bin/echo snapshot"}]}]' \
    "$old/settings.json" > "$old/settings.json.x" && mv "$old/settings.json.x" "$old/settings.json"
  printf '{"oauthAccount":{"emailAddress":"a@example.com"},"mcpServers":{"stripe":{"type":"http","url":"https://mcp.stripe.com/"}}}\n' \
    > "$old/.claude.json"

  run clikae rename claude a cver --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Carried the tank's own config across"* ]] || false
  [[ "$output" == *"hooks (settings.json)"* ]] || false
  [[ "$output" == *"MCP servers (.claude.json)"* ]] || false

  local new="$CLIKAE_HOME/profiles/claude/cver"
  run jq -r '.hooks.Stop[0].hooks[0].command' "$new/settings.json"
  [ "$output" = "/bin/echo snapshot" ]
  run jq -r '.mcpServers.stripe.url' "$new/.claude.json"
  [ "$output" = "https://mcp.stripe.com/" ]
  [ ! -e "$old" ]
}

@test "rename says nothing about carried config when the tank has none" {
  # The negative control: the line must describe what is there, not appear
  # unconditionally — a caption that is always printed states nothing.
  clikae init claude a --no-template
  rm -f "$CLIKAE_HOME/profiles/claude/a/settings.json"
  run clikae rename claude a cver --force
  [ "$status" -eq 0 ]
  [[ "$output" != *"Carried the tank's own config across"* ]] || false
}

@test "rename carries the solo marker, so a solo tank is not re-fleeted by a new name" {
  clikae init claude a
  clikae solo claude a
  clikae rename claude a cver --force
  [ -f "$CLIKAE_HOME/profiles/claude/cver/clikae-meta/solo" ]
}
