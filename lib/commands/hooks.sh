# shellcheck shell=bash
# lib/commands/hooks.sh — `clikae hooks <share|unshare|list>` (#141).
#
#   share <event> <command> [<engine>]   run <command> on <event> in every tank
#   unshare <event> <command> [<engine>] stop offering it (doesn't strip it back
#                                        out of tanks that already picked it up)
#   list [<engine>]                      what's in <engine>'s fleet-wide hook list
#
# The twin of lib/commands/mcp.sh: same verbs, same defaults, same additive
# merge. Path helpers, the jq requirement and the merge itself live in
# lib/core/fleet_hooks.sh (always sourced by bin/clikae) — this file is just
# the CLI surface. Default engine: claude.
#
# One deliberate difference from `clikae mcp share`: there is no source tank.
# An MCP server is a block of config you add with the engine's own CLI and
# then promote; a hook is one command line, so it is typed here directly and
# there is nothing to read out of a tank first.
#
# Every non-solo tank of <engine> gets the shared list merged into its own
# settings.json at `clikae init` and at every launch (fleet_hooks_prelaunch).
# `share` additionally backfills every EXISTING non-solo tank right now, so
# you don't have to wait for each one's next launch.

cmd_hooks() {
  local sub=""
  [ $# -gt 0 ] && { sub="$1"; shift; }
  case "$sub" in
    ""|-h|--help|help)
      cat <<'EOF'
Usage: clikae hooks <share|unshare|list> [options]

Fleet-wide hook sharing. A hook is dev-environment config, not identity — so
it is shared by default with every tank that ISN'T solo, exactly like an MCP
server, and a tank created or recreated later picks it up for free.

  clikae hooks share <event> <command> [<engine>]     run it in every tank
  clikae hooks unshare <event> <command> [<engine>]   stop offering it
  clikae hooks list [<engine>]                        show what's shared

Default engine: claude.

  clikae hooks share Stop "$HOME/bin/snapshot-memory.sh"
  clikae hooks list

A tank that is renamed or recreated keeps nothing you have not shared: its
hooks live in its own settings.json. `clikae doctor` names every non-solo
tank missing a shared hook or MCP server, so a hook that stopped running is
something you read rather than something you notice days later.

Requires: `jq` (settings.json also holds your permissions and any other
engine config — merging one key of it needs a real JSON parser).
Never: solo tanks are never targeted by the fan-out — the same fleet
exclusion `clikae memory`/`mcp`/`to`/`watch`/`burn` already honor.
Merge is additive-only and keyed on the COMMAND: a command a tank already
runs for that event is never added twice, and nothing it already has is ever
removed. To stop a hook running in a tank, edit that tank's settings.json.
EOF
      return 0 ;;
    share)   _hooks_share "$@" ;;
    unshare) _hooks_unshare "$@" ;;
    list)    _hooks_list "$@" ;;
    *) log_fail "hooks: unknown subcommand '$sub' (try: share | unshare | list)" ;;
  esac
}

# Ensure <engine>'s fleet store file exists (seeded with "{}"); print its path.
_hooks_ensure_store() {
  local engine="$1" store
  store="$(fleet_hooks_store_path "$engine")"
  mkdir -p "$(fleet_hooks_root)"
  [ -s "$store" ] || printf '{}\n' > "$store"
  printf '%s\n' "$store"
}

# Refuse an engine whose adapter has no hooks layout, rather than writing a
# store nothing will ever read (`clikae hooks share Stop … codex` used to be
# indistinguishable from a working share).
_hooks_require_engine() {
  local engine="$1"
  load_adapter "$engine" >/dev/null 2>&1 || log_fail "hooks: no adapter for '$engine'."
  declare -F adapter_hooks_config_file >/dev/null 2>&1 \
    || log_fail "hooks: '$engine' has no known hook config layout yet."
}

# Fan the store into every EXISTING non-solo tank of <engine> (mirrors
# _mcp_share's eager backfill) — no need to wait for each tank's next launch.
_hooks_backfill() {
  local engine="$1" fanned=0 e t path
  while IFS=$'\t' read -r e t path; do
    [ -n "$e" ] || continue
    [ "$e" = "$engine" ] || continue
    tank_is_solo "$e" "$t" && continue
    fleet_hooks_prelaunch "$e" "$t" "$path" && fanned=$((fanned + 1))
  done <<EOF
$(list_all_profiles)
EOF
  [ "$fanned" -gt 0 ] && log_dim "Backfilled into $fanned existing non-solo $engine tank(s)."
  return 0
}

_hooks_share() {
  local event="" command="" engine=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) cmd_hooks --help; return 0 ;;
      --) shift
          # Everything after `--` is the command, verbatim: a hook command
          # can legitimately start with a dash, and guessing is how it would
          # be eaten by the flag parser above.
          if [ -z "$event" ]; then log_fail "hooks share: name an event first:  clikae hooks share <event> <command>"; fi
          [ $# -gt 0 ] || log_fail "hooks share: nothing after --."
          command="$1"; shift ;;
      -*) log_fail "hooks share: unknown flag: $1" ;;
      *) if [ -z "$event" ]; then event="$1"
         elif [ -z "$command" ]; then command="$1"
         elif [ -z "$engine" ]; then engine="$1"
         else log_fail "hooks share: unexpected argument: $1"; fi
         shift ;;
    esac
  done
  [ -n "$event" ] || log_fail "hooks share: name an event and a command:  clikae hooks share <event> <command> [<engine>]"
  [ -n "$command" ] || log_fail "hooks share: name the command to run on $event:  clikae hooks share $event <command>"
  fleet_hooks_event_ok "$event" \
    || log_fail "hooks share: '$event' is not a hook event name (letters and digits, starting with a letter — e.g. Stop, SessionStart, PreToolUse)."
  [ -n "$engine" ] || engine="claude"
  _fleet_hooks_require_jq
  _hooks_require_engine "$engine"

  local store updated
  store="$(_hooks_ensure_store "$engine")"
  # Idempotent in the STORE too, not only in the merge: sharing the same
  # command twice must not grow the list it fans out.
  updated="$(jq --arg e "$event" --arg c "$command" '
    def entry_cmds: [ (.hooks // [])[] | .command? // empty ];
    (.[$e] // []) as $existing |
    if ([ $existing[] | entry_cmds ] | flatten | index($c)) != null then .
    else .[$e] = ($existing + [{hooks: [{type: "command", command: $c}]}]) end
  ' "$store")" || log_fail "hooks share: failed to update the fleet store."
  printf '%s\n' "$updated" > "$store.tmp" && mv "$store.tmp" "$store"

  log_done "Shared a $event hook fleet-wide for $engine — every non-solo tank runs it from here on."
  log_dim "  $command"
  _hooks_backfill "$engine"
}

_hooks_unshare() {
  local event="" command="" engine=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) cmd_hooks --help; return 0 ;;
      --) shift
          [ $# -gt 0 ] || log_fail "hooks unshare: nothing after --."
          command="$1"; shift ;;
      -*) log_fail "hooks unshare: unknown flag: $1" ;;
      *) if [ -z "$event" ]; then event="$1"
         elif [ -z "$command" ]; then command="$1"
         elif [ -z "$engine" ]; then engine="$1"
         else log_fail "hooks unshare: unexpected argument: $1"; fi
         shift ;;
    esac
  done
  [ -n "$event" ] && [ -n "$command" ] \
    || log_fail "hooks unshare: name an event and a command:  clikae hooks unshare <event> <command> [<engine>]"
  [ -n "$engine" ] || engine="claude"
  _fleet_hooks_require_jq

  local store; store="$(fleet_hooks_store_path "$engine")"
  [ -s "$store" ] || log_fail "hooks unshare: no fleet hook store for '$engine' yet."
  jq -e --arg e "$event" --arg c "$command" '
    def entry_cmds: [ (.hooks // [])[] | .command? // empty ];
    ([ (.[$e] // [])[] | entry_cmds ] | flatten | index($c)) != null
  ' "$store" >/dev/null 2>&1 \
    || log_fail "hooks unshare: $engine shares no $event hook running that command."

  local updated
  updated="$(jq --arg e "$event" --arg c "$command" '
    def entry_cmds: [ (.hooks // [])[] | .command? // empty ];
    .[$e] = [ (.[$e] // [])[] | select((entry_cmds | index($c)) == null) ] |
    if (.[$e] | length) == 0 then del(.[$e]) else . end
  ' "$store")" || log_fail "hooks unshare: failed to update the fleet store."
  printf '%s\n' "$updated" > "$store.tmp" && mv "$store.tmp" "$store"
  log_done "Removed that $event hook from $engine's fleet-wide hook list."
  log_dim "Tanks that already picked it up keep it — remove it per-tank by editing that tank's settings.json."
}

_hooks_list() {
  local engine="${1:-claude}"
  case "$engine" in
    -h|--help) cmd_hooks --help; return 0 ;;
    -*) log_fail "hooks list: unknown flag: $engine" ;;
  esac
  _fleet_hooks_require_jq
  local store; store="$(fleet_hooks_store_path "$engine")"
  if [ ! -s "$store" ] || [ "$(jq 'keys | length' "$store" 2>/dev/null)" = "0" ]; then
    log_info "No fleet-wide hooks shared yet for '$engine'."
    return 0
  fi
  log_info "Fleet-wide hooks for '$engine':"
  # Same `if`-not-`&&` shape _mcp_list explains: this loop is the function's
  # last statement, reached bare from the dispatch under `set -e`.
  jq -r '
    def entry_cmds: [ (.hooks // [])[] | .command? // empty ];
    to_entries[] | .key as $e | .value[]? | entry_cmds[] | "\($e)\t\(.)"
  ' "$store" | while IFS=$'\t' read -r event command; do
    if [ -n "$event" ]; then
      printf '  %-16s %s\n' "$event" "$command"
    fi
  done
  return 0
}
