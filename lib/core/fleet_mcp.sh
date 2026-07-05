# shellcheck shell=bash
# lib/core/fleet_mcp.sh — fleet-wide MCP server sharing (docs/mcp-share.md).
#
# Unlike Soul memory (opt-in, per-tank, never auto-crosses — see soul.sh), an MCP
# server isn't identity/personal data: it's dev-environment config, and a tank
# only exists to be put in the tanks list so work continues seamlessly across
# it. So the default is the opposite of Soul's: every tank NOT marked solo
# shares ONE canonical per-engine MCP list automatically — no `share` needed per
# tank, and a newly created fleet tank picks it up on its first launch for free.
# `clikae solo` is still the escape hatch for a tank that must stay untouched.
#
# The canonical store is a plain JSON object shaped exactly like the
# `mcpServers` value Claude Code itself writes (name -> server config):
#   $CLIKAE_HOME/fleet-mcp/<engine>.json
#
# `clikae mcp share <engine> <name>` populates it from a server you already
# added to one tank (via `claude mcp add ... -s user`); `fleet_mcp_prelaunch`
# (called from every non-ephemeral launch path, same shape as soul_prelaunch)
# merges the store into the CURRENT tank's own config at every launch.
#
# Merge is additive-only: a key the tank's config already has — fanned in
# before, or hand-added — is never overwritten. Same "existing entry =
# deliberate override, never touched" rule the skills/commands symlink follows
# (lib/adapters/claude.sh). To pick up a changed shared definition, remove that
# server from the tank (`claude mcp remove <name>`, or edit its .claude.json)
# and it re-fills at the next launch.
#
# Requires `jq` — safely merging a JSON object's keys without clobbering
# unrelated fields (oauthAccount, projects, caches all live in the same file)
# isn't something grep/sed can do responsibly. Every entry point degrades to a
# silent no-op (prelaunch) or a clear error (share/list) when jq is missing.
#
# Edge case, by construction: prelaunch runs BEFORE the engine starts, so a
# tank's very first-ever launch (no .claude.json written yet) has nothing to
# merge into and is silently skipped. It self-heals from that tank's SECOND
# launch onward — same self-heal shape the skills/commands symlink already
# uses for a tank created before that existed.

fleet_mcp_root()       { printf '%s/fleet-mcp\n' "$CLIKAE_HOME"; }
fleet_mcp_store_path() { printf '%s/%s.json\n' "$(fleet_mcp_root)" "$1"; }

_fleet_mcp_require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  log_err "clikae mcp needs 'jq' to safely merge MCP server config (not installed)."
  log_dim "Install it, then retry:  brew install jq"
  exit 1
}

# Path to <engine>'s per-tank config file that holds mcpServers, or non-zero if
# the engine (adapter) doesn't expose one. One place so both `mcp share` and
# `fleet_mcp_prelaunch` agree on it.
_fleet_mcp_config_file() {
  local cfg="$1"
  declare -F adapter_mcp_config_file >/dev/null 2>&1 || return 1
  adapter_mcp_config_file "$cfg"
}

# Optional hook: does every non-solo <engine> launch merge in the fleet-wide MCP
# store? Called from switch.sh / run.sh right where soul_prelaunch is called.
# No-op (and never fails the launch) when: the tank is solo, the store is
# empty/absent, jq isn't installed, or the engine has no adapter_mcp_config_file
# hook (nothing to merge into).
fleet_mcp_prelaunch() {
  local engine="$1" tank="$2" cfg="$3"
  tank_is_solo "$engine" "$tank" && return 0
  local store; store="$(fleet_mcp_store_path "$engine")"
  [ -s "$store" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local target; target="$(_fleet_mcp_config_file "$cfg" 2>/dev/null || true)"
  [ -n "$target" ] && [ -f "$target" ] || return 0

  local merged
  merged="$(jq -n --slurpfile shared "$store" --slurpfile target "$target" '
    ($shared[0]) as $s | ($target[0]) as $t |
    ($t.mcpServers // {}) as $existing |
    ($s | to_entries | map(select(.key as $k | ($existing | has($k)) | not)) | from_entries) as $new |
    $t + {mcpServers: ($existing + $new)}
  ' 2>/dev/null)" || return 0
  [ -n "$merged" ] || return 0

  # Skip the write if nothing would actually change (avoid needless mtime churn
  # on a file every launch touches).
  printf '%s' "$merged" | cmp -s - "$target" 2>/dev/null && return 0
  printf '%s\n' "$merged" > "$target.tmp" && mv "$target.tmp" "$target"
}
