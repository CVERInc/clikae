# shellcheck shell=bash
# lib/commands/mcp.sh — `clikae mcp <share|unshare|list>` (docs/mcp-share.md).
#
#   share <name> [<engine> <tank>]   promote an already-added MCP server fleet-wide
#   unshare <name> [<engine>]        stop offering it to tanks (doesn't strip it
#                                    back out of tanks that already picked it up)
#   list [<engine>]                  what's in <engine>'s fleet-wide MCP store
#
# Path helpers, the jq requirement, and the merge itself live in
# lib/core/fleet_mcp.sh (always sourced by bin/clikae) — this file is just the
# CLI surface. Defaults: engine = claude; tank = whichever this shell is
# switched to (same resolution `clikae memory` uses).
#
# Every non-solo tank of <engine> gets the shared list merged into its own
# config automatically at its next launch (fleet_mcp_prelaunch, wired into
# switch.sh / run.sh) — no per-tank opt-in, unlike `clikae memory`. `share`
# additionally backfills every EXISTING non-solo tank right now, so you don't
# have to wait for each one's next launch.

cmd_mcp() {
  local sub=""
  [ $# -gt 0 ] && { sub="$1"; shift; }
  case "$sub" in
    ""|-h|--help|help)
      cat <<'EOF'
Usage: clikae mcp <share|unshare|list> [options]

Fleet-wide MCP server sharing. A tank you put in the tanks list is there so
work continues seamlessly across it — unlike long-term memory, an MCP server
isn't identity data, so it's shared by default with every tank that ISN'T
solo (no per-tank opt-in to remember).

  clikae mcp share <name> [<engine> <tank>]   share an already-added server fleet-wide
  clikae mcp unshare <name> [<engine>]        stop offering it (existing copies untouched)
  clikae mcp list [<engine>]                  show what's shared for <engine>

Defaults: engine = claude; tank = whichever this shell is switched to.

`share` reads the server's config from a tank that already has it — add it
there first with the engine's own CLI:
  clikae run claude work -- mcp add --transport http stripe https://mcp.stripe.com/ -s user
  clikae mcp share stripe

🔴 Requires `jq` (safely merging one JSON key without touching the rest of the
tank's config — oauthAccount, projects, caches — needs a real JSON parser).
🔴 Solo tanks are refused as a share SOURCE and never targeted by the fan-out —
same fleet exclusion `clikae memory`/`to`/`watch`/`burn` already honor.
Merge is additive-only: a key the tank's config already has is never
overwritten. To pick up a changed shared definition, remove that server from
the tank first (claude mcp remove <name>), then it re-fills at next launch.
EOF
      return 0 ;;
    share)   _mcp_share "$@" ;;
    unshare) _mcp_unshare "$@" ;;
    list)    _mcp_list "$@" ;;
    *) log_fail "mcp: unknown subcommand '$sub' (try: share | unshare | list)" ;;
  esac
}

# Resolve <engine>/<tank> (tank defaults to this shell's active one) into
# MCP_TANK / MCP_CFG / MCP_TARGET. Fails loudly if the engine has no
# adapter_mcp_config_file hook (fleet_mcp.sh) or the tank has never been
# launched (no config file yet to read from).
_mcp_resolve_tank() {
  local engine="$1" tank="$2"
  load_adapter "$engine" >/dev/null 2>&1 || log_fail "mcp: no adapter for '$engine'."
  declare -F adapter_mcp_config_file >/dev/null 2>&1 \
    || log_fail "mcp: '$engine' has no known MCP config layout yet."
  if [ -z "$tank" ]; then
    local var value
    var="$(adapter_meta_env_var)"
    value="${!var}"
    tank="$(resolve_active_profile "$engine" "$(adapter_meta_strategy)" "$value")"
    [ -n "$tank" ] || log_fail "mcp: no $engine tank active in this shell — name one: clikae mcp share <name> $engine <tank>"
  fi
  profile_exists "$engine" "$tank" || log_fail "mcp: no such tank: $engine/$tank"
  MCP_TANK="$tank"
  MCP_CFG="$(profile_dir "$engine" "$tank")"
  MCP_TARGET="$(adapter_mcp_config_file "$MCP_CFG")"
  [ -n "$MCP_TARGET" ] && [ -f "$MCP_TARGET" ] \
    || log_fail "mcp: $engine/$tank has no config file yet ($MCP_TARGET) — launch it once first: clikae run $engine $tank -- --help"
}

# Ensure <engine>'s fleet store file exists (seeded with "{}"); print its path.
_mcp_ensure_store() {
  local engine="$1" store
  store="$(fleet_mcp_store_path "$engine")"
  mkdir -p "$(fleet_mcp_root)"
  [ -s "$store" ] || printf '{}\n' > "$store"
  printf '%s\n' "$store"
}

_mcp_share() {
  local name="" engine="" tank=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) cmd_mcp --help; return 0 ;;
      -*) log_fail "mcp share: unknown flag: $1" ;;
      *) if [ -z "$name" ]; then name="$1"
         elif [ -z "$engine" ]; then engine="$1"
         elif [ -z "$tank" ]; then tank="$1"
         else log_fail "mcp share: unexpected argument: $1"; fi
         shift ;;
    esac
  done
  [ -n "$name" ] || log_fail "mcp share: name a server:  clikae mcp share <name> [<engine> <tank>]"
  [ -n "$engine" ] || engine="claude"
  _fleet_mcp_require_jq
  _mcp_resolve_tank "$engine" "$tank"

  # 🔴 A SOLO tank is deliberately out of the fleet — refuse it as a source,
  # same guard `clikae memory share` applies to its group argument.
  if tank_is_solo "$engine" "$MCP_TANK"; then
    log_err "$engine/$MCP_TANK is SOLO (standalone, out of the fleet) — refusing to share from it."
    log_fail "If you really mean it: clikae solo $engine $MCP_TANK --off"
  fi

  local val
  val="$(jq --arg n "$name" '.mcpServers[$n] // empty' "$MCP_TARGET" 2>/dev/null || true)"
  [ -n "$val" ] || log_fail "mcp share: no server named '$name' in $engine/$MCP_TANK's config. Add it there first:  clikae run $engine $MCP_TANK -- mcp add --transport http $name <url> -s user"

  local store updated
  store="$(_mcp_ensure_store "$engine")"
  updated="$(jq --argjson v "$val" --arg n "$name" '.[$n] = $v' "$store")" \
    || log_fail "mcp share: failed to update the fleet store."
  printf '%s\n' "$updated" > "$store.tmp" && mv "$store.tmp" "$store"

  log_ok "Shared '$name' fleet-wide for $engine — every non-solo tank gets it from here on."

  # Eager backfill into every EXISTING non-solo tank (mirrors memory share's
  # eager pass over already-existing directories) — no need to wait for each
  # tank's next launch.
  local fanned=0
  while IFS=$'\t' read -r e t path; do
    [ -n "$e" ] || continue
    [ "$e" = "$engine" ] || continue
    tank_is_solo "$e" "$t" && continue
    fleet_mcp_prelaunch "$e" "$t" "$path" && fanned=$((fanned + 1))
  done <<EOF
$(list_all_profiles)
EOF
  [ "$fanned" -gt 0 ] && log_dim "Backfilled into $fanned existing non-solo $engine tank(s)."
}

_mcp_unshare() {
  local name="" engine=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) cmd_mcp --help; return 0 ;;
      -*) log_fail "mcp unshare: unknown flag: $1" ;;
      *) if [ -z "$name" ]; then name="$1"
         elif [ -z "$engine" ]; then engine="$1"
         else log_fail "mcp unshare: unexpected argument: $1"; fi
         shift ;;
    esac
  done
  [ -n "$name" ] || log_fail "mcp unshare: name a server:  clikae mcp unshare <name> [<engine>]"
  [ -n "$engine" ] || engine="claude"
  _fleet_mcp_require_jq

  local store; store="$(fleet_mcp_store_path "$engine")"
  [ -s "$store" ] || log_fail "mcp unshare: no fleet MCP store for '$engine' yet."
  jq -e --arg n "$name" 'has($n)' "$store" >/dev/null 2>&1 \
    || log_fail "mcp unshare: '$name' isn't in $engine's fleet store."

  local updated
  updated="$(jq --arg n "$name" 'del(.[$n])' "$store")"
  printf '%s\n' "$updated" > "$store.tmp" && mv "$store.tmp" "$store"
  log_ok "Removed '$name' from $engine's fleet-wide MCP store."
  log_dim "Tanks that already picked it up keep their own copy — remove it per-tank if you need it gone (claude mcp remove $name)."
}

_mcp_list() {
  local engine="${1:-claude}"
  _fleet_mcp_require_jq
  local store; store="$(fleet_mcp_store_path "$engine")"
  if [ ! -s "$store" ] || [ "$(jq 'keys | length' "$store" 2>/dev/null)" = "0" ]; then
    log_info "No fleet-wide MCP servers shared yet for '$engine'."
    return 0
  fi
  log_info "Fleet-wide MCP servers for '$engine':"
  jq -r 'keys[]' "$store" | while IFS= read -r n; do
    [ -n "$n" ] && printf '  %s\n' "$n"
  done
}
