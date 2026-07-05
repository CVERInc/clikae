#!/usr/bin/env bats
# tests/bats/fleet-mcp.bats — `clikae mcp <share|unshare|list>` and
# fleet_mcp_prelaunch (docs/mcp-share.md). Needs `jq`; skipped elsewhere.
# (NB: `[[ … ]]` assertions carry `|| false` — see tests/README.md.)

load '../helpers'

jq_only() { command -v jq >/dev/null 2>&1 || skip "clikae mcp needs jq"; }

# Write a tank's .claude.json with a given mcpServers object (raw JSON string).
_stamp_mcp() {
  local tank="$1" servers="$2" dir
  dir="$CLIKAE_HOME/profiles/claude/$tank"
  mkdir -p "$dir"
  printf '{"oauthAccount":{"emailAddress":"%s@example.com"},"mcpServers":%s}\n' \
    "$tank" "$servers" > "$dir/.claude.json"
}

_mcp_of() {
  jq -c '.mcpServers // {}' "$CLIKAE_HOME/profiles/claude/$1/.claude.json"
}

@test "mcp share: promotes a tank's server into the fleet store" {
  jq_only
  clikae init claude a
  _stamp_mcp a '{"stripe":{"type":"http","url":"https://mcp.stripe.com/"}}'
  run clikae mcp share stripe claude a
  [ "$status" -eq 0 ]
  run jq -c '.stripe' "$CLIKAE_HOME/fleet-mcp/claude.json"
  [[ "$output" == *'"url":"https://mcp.stripe.com/"'* ]] || false
}

@test "mcp share: fails clearly when the named server isn't in that tank's config" {
  jq_only
  clikae init claude a
  _stamp_mcp a '{}'
  run clikae mcp share stripe claude a
  [ "$status" -ne 0 ]
  [[ "$output" == *"no server named 'stripe'"* ]] || false
}

@test "mcp share: backfills an existing non-solo tank, keeping its own server untouched" {
  jq_only
  clikae init claude a
  clikae init claude b
  _stamp_mcp a '{"stripe":{"type":"http","url":"https://mcp.stripe.com/"}}'
  _stamp_mcp b '{"custom":{"type":"stdio"}}'
  clikae mcp share stripe claude a
  run _mcp_of b
  [[ "$output" == *'"custom"'* ]] || false     # kept
  [[ "$output" == *'"stripe"'* ]] || false     # backfilled
}

@test "mcp share: never overwrites a tank's own differently-configured entry of the same name" {
  jq_only
  clikae init claude a
  clikae init claude b
  _stamp_mcp a '{"stripe":{"type":"http","url":"https://mcp.stripe.com/"}}'
  _stamp_mcp b '{"stripe":{"type":"http","url":"https://MY-OWN-OVERRIDE/"}}'
  clikae mcp share stripe claude a
  run jq -r '.mcpServers.stripe.url' "$CLIKAE_HOME/profiles/claude/b/.claude.json"
  [ "$output" = "https://MY-OWN-OVERRIDE/" ]
}

@test "mcp share: refuses a SOLO tank as the source" {
  jq_only
  clikae init claude a
  _stamp_mcp a '{"stripe":{"type":"http","url":"https://mcp.stripe.com/"}}'
  clikae solo claude a
  run clikae mcp share stripe claude a
  [ "$status" -ne 0 ]
  [[ "$output" == *"SOLO"* ]] || false
}

@test "mcp share: never backfills a SOLO tank" {
  jq_only
  clikae init claude a
  clikae init claude b
  _stamp_mcp a '{"stripe":{"type":"http","url":"https://mcp.stripe.com/"}}'
  _stamp_mcp b '{}'
  clikae solo claude b
  clikae mcp share stripe claude a
  run _mcp_of b
  [[ "$output" == "{}" ]] || false
}

@test "fleet_mcp_prelaunch (via clikae run): a non-solo tank picks up the shared server at launch" {
  jq_only
  clikae init claude a
  clikae init claude b
  _stamp_mcp a '{"stripe":{"type":"http","url":"https://mcp.stripe.com/"}}'
  clikae mcp share stripe claude a
  clikae init claude c
  _stamp_mcp c '{}'
  clikae run claude c -- --version
  run _mcp_of c
  [[ "$output" == *'"stripe"'* ]] || false
}

@test "mcp unshare: removes from the fleet store but leaves tanks that already got it alone" {
  jq_only
  clikae init claude a
  clikae init claude b
  _stamp_mcp a '{"stripe":{"type":"http","url":"https://mcp.stripe.com/"}}'
  _stamp_mcp b '{}'
  clikae mcp share stripe claude a
  run _mcp_of b
  [[ "$output" == *'"stripe"'* ]] || false
  run clikae mcp unshare stripe claude
  [ "$status" -eq 0 ]
  run jq 'has("stripe")' "$CLIKAE_HOME/fleet-mcp/claude.json"
  [ "$output" = "false" ]
  run _mcp_of b
  [[ "$output" == *'"stripe"'* ]] || false   # b's own copy is untouched
}

@test "mcp list: reports nothing shared, then the shared name after share" {
  jq_only
  clikae init claude a
  _stamp_mcp a '{"stripe":{"type":"http","url":"https://mcp.stripe.com/"}}'
  run clikae mcp list claude
  [[ "$output" == *"No fleet-wide MCP servers"* ]] || false
  clikae mcp share stripe claude a
  run clikae mcp list claude
  [[ "$output" == *"stripe"* ]] || false
}

@test "mcp share: fails clearly without jq" {
  local jq_path; jq_path="$(command -v jq || true)"
  [ -n "$jq_path" ] || skip "jq not installed (nothing to hide)"
  local stripped="/usr/bin:/bin"
  PATH="$stripped" command -v jq >/dev/null 2>&1 && skip "jq also lives in $stripped on this host"
  clikae init claude a
  _stamp_mcp a '{"stripe":{"type":"http","url":"https://mcp.stripe.com/"}}'
  run env PATH="$stripped" "$CLIKAE_BIN" mcp share stripe claude a
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq"* ]] || false
}
