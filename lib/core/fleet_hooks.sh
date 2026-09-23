# shellcheck shell=bash
# lib/core/fleet_hooks.sh — fleet-wide engine hook sharing (#141).
#
# The twin of lib/core/fleet_mcp.sh, for the OTHER half of a tank's per-tank
# engine config. An MCP server and a hook are the same kind of thing — dev
# environment, not identity — so the rule is the same one fleet_mcp.sh states
# at length: every tank NOT marked solo shares ONE canonical per-engine list
# automatically, with `clikae solo` as the escape hatch.
#
# 🔴 WHY THIS EXISTS AT ALL (#141). An MCP server that vanishes looks like a
# server that is down, and somebody investigates. A hook that vanishes looks
# like nothing whatsoever: the tank runs normally, only without the automation.
# Recorded on one machine: tanks recreated under new names had no `Stop` hook,
# the snapshot it ran stopped running, and the shared memory it wrote fell 102
# commits behind over five days before an unrelated symptom gave it away.
# `clikae mcp share` already closed the MCP half; this closes the hook half,
# and `clikae doctor` (lib/commands/doctor.sh) is where either half is noticed
# on day one instead of day five.
#
# The canonical store is a plain JSON object shaped exactly like the `hooks`
# value Claude Code itself writes (event -> array of hook groups):
#   $CLIKAE_HOME/fleet-hooks/<engine>.json
#   {"Stop":[{"hooks":[{"type":"command","command":"<cmd>"}]}]}
#
# `clikae hooks share <event> <command>` populates it; fleet_hooks_prelaunch
# merges it into a tank's own settings.json at every launch AND at `clikae
# init` — unlike MCP, which has to wait for the engine to write .claude.json
# first, settings.json is clikae's own file and exists from the moment a tank
# does, so a brand-new tank is covered before its first run.
#
# Merge is additive-only and identified BY THE COMMAND STRING: a command the
# tank's settings already run for that event — fanned in before, or the user's
# own — is never appended twice, and nothing the tank had is ever removed or
# rewritten. There is deliberately no marker key on our entries: a hook is
# identified by what it RUNS, so a user who added the same command by hand is
# already covered and must not get a second copy of it.
#
# Requires `jq`, for the reason fleet_mcp.sh gives: settings.json holds
# permissions, cockpit guards and anything else the user put there, and
# merging one key of it without touching the rest is not a job for sed. Every
# entry point degrades to a silent no-op (prelaunch) or a clear error (the
# `clikae hooks` verbs) when jq is missing.

fleet_hooks_root()       { printf '%s/fleet-hooks\n' "$CLIKAE_HOME"; }
fleet_hooks_store_path() { printf '%s/%s.json\n' "$(fleet_hooks_root)" "$1"; }

_fleet_hooks_require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  log_err "clikae hooks needs 'jq' to safely merge hook config (not installed)."
  log_dim "Install it, then retry:  brew install jq"
  exit 1
}

# Path to <engine>'s per-tank config file that holds `hooks`, or non-zero if
# the engine (adapter) doesn't expose one. One place so `clikae hooks`,
# fleet_hooks_prelaunch and doctor all agree on it.
_fleet_hooks_config_file() {
  local cfg="$1"
  declare -F adapter_hooks_config_file >/dev/null 2>&1 || return 1
  adapter_hooks_config_file "$cfg"
}

# fleet_hooks_event_ok <event> -> 0 when <event> is a plausible hook event name.
#
# 🔴 A SHAPE, NOT A LIST. An allowlist of today's events (Stop, SessionStart,
# PreToolUse, …) is a ruler that rots: the vendor adds an event, clikae refuses
# to share a hook for it, and the refusal reads like the event does not exist.
# The engine validates its own event names; clikae only refuses shapes that
# could not be one (empty, spaces, punctuation, a leading digit).
fleet_hooks_event_ok() {
  case "${1:-}" in
    ""|*[!A-Za-z0-9]*) return 1 ;;
    [A-Za-z]*) return 0 ;;
    *) return 1 ;;
  esac
}

# fleet_hooks_missing <engine> <tank dir> -> one `<event>\t<command>` line per
# fleet-shared hook this tank does NOT run. Read-only: it opens the tank's
# config file and nothing else, so `clikae doctor` stays a pure inspection.
# Prints nothing (rc 0) when jq is missing, the store is empty, or the engine
# has no hooks config layout — the same no-ops prelaunch takes.
fleet_hooks_missing() {
  local engine="$1" cfg="$2" store target
  command -v jq >/dev/null 2>&1 || return 0
  store="$(fleet_hooks_store_path "$engine")"
  [ -s "$store" ] || return 0
  target="$(_fleet_hooks_config_file "$cfg" 2>/dev/null || true)"
  [ -n "$target" ] || return 0
  # An absent settings.json means every shared hook is missing, which is the
  # honest answer: unlike .claude.json, nothing but clikae writes this file,
  # so there is no "wait for the engine to create it" case to be quiet about.
  [ -f "$target" ] || target=/dev/null
  jq -rn --slurpfile shared "$store" --slurpfile current "$target" '
    def entry_cmds: [ (.hooks // [])[] | .command? // empty ];
    ($shared[0] // {}) as $s |
    ($current[0] // {}) as $t |
    if ($s | type) != "object" or ($t | type) != "object" then empty
    else
      ($t.hooks // {}) as $th |
      $s | to_entries[] |
      .key as $event |
      ([ ($th[$event] // [])[] | entry_cmds ] | flatten) as $have |
      .value[]? | entry_cmds[] |
      # `. as $c` FIRST: inside `$have | index(.)` the dot is $have, not the
      # command — the filter then always finds itself and reports nothing
      # missing. Same rebinding trap in the merge below.
      . as $c | select(($have | index($c)) == null) |
      "\($event)\t\($c)"
    end
  ' 2>/dev/null || true
}

# Optional hook: does every non-solo <engine> launch merge in the fleet-wide
# hook list? Called from switch.sh / run.sh / relay.sh / burn.sh / init.sh / hooks.sh — the four launch
# paths, right where fleet_mcp_prelaunch is called; init.sh, because a tank
# gets its hooks the moment it is created rather than at its first launch;
# and hooks.sh, which fans the store into existing tanks rather than
# launching one.
#
# 🔴 Keep this list true — see scripts/doc-names-exist.sh check 2, and the
# stale fleet_mcp_prelaunch docstring that motivated it.
#
# No-op (and never fails the launch) when: the tank is solo, the store is
# empty/absent, jq isn't installed, or the engine has no
# adapter_hooks_config_file hook (nothing to merge into).
#
# A subshell, like _cockpit_hook_install: _settings_snapshot installs this
# subshell's EXIT trap for the snapshot directory it creates.
fleet_hooks_prelaunch() (
  local engine="$1" tank="$2" cfg="$3"
  tank_is_solo "$engine" "$tank" && return 0
  local store; store="$(fleet_hooks_store_path "$engine")"
  [ -s "$store" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local target; target="$(_fleet_hooks_config_file "$cfg" 2>/dev/null || true)"
  [ -n "$target" ] || return 0

  # shellcheck source=../commands/settings.sh
  source "$CLIKAE_LIB/commands/settings.sh"
  _settings_snapshot "$cfg" "$engine/$tank" >/dev/null 2>&1 || return 0

  # _settings_snapshot is THE one place a settings.json is located and written
  # (lib/commands/settings.sh), and it derives the path from the tank
  # directory. Refuse to write when that is not the file the adapter named: an
  # engine whose hooks live somewhere else needs its own writer, not this one
  # silently editing a file it was never told about.
  local phys_target
  phys_target="$(cd -P "$(dirname "$target")" 2>/dev/null && pwd -P)/${target##*/}" || return 0
  [ "$phys_target" = "$_SETTINGS_FILE" ] || return 0

  # Decide the no-op INSIDE jq, exactly as fleet_mcp_prelaunch does: emit
  # nothing when every shared command is already run for its event, so a tank
  # whose settings are already correct is not rewritten (and its inode not
  # replaced) on every single launch, racing a live session on the same tank.
  local merged
  merged="$(jq -n --slurpfile shared "$store" --slurpfile current "${_SETTINGS_SNAP:-/dev/null}" '
    def entry_cmds: [ (.hooks // [])[] | .command? // empty ];
    ($shared[0] // {}) as $s |
    ($current[0] // {}) as $old |
    if ($s | type) != "object" or ($old | type) != "object"
      then error("invalid hooks config") else . end |
    (reduce ($s | to_entries[]) as $ev ({h: ($old.hooks // {}), added: 0};
       (.h[$ev.key] // []) as $existing |
       ([ $existing[] | entry_cmds ] | flatten) as $have |
       ([ $ev.value[]?
          | select([ entry_cmds[] | . as $c | select(($have | index($c)) == null) ] | length > 0) ]) as $new |
       if ($new | length) == 0 then .
       else .h = (.h + {($ev.key): ($existing + $new)}) | .added = (.added + ($new | length))
       end)) as $r |
    if $r.added == 0 then empty else ($old | .hooks = $r.h) end
  ' 2>/dev/null)" || return 0
  [ -n "$merged" ] || return 0   # nothing new to add (or jq failed) → leave the file

  _settings_write_file "$_SETTINGS_FILE" "$merged" "$engine/$tank" "$_SETTINGS_SNAP" || return 0
  return 0
)
