# shellcheck shell=bash
# lib/core/burn_status.sh — read side of #41's machine-readable burn status file.
#
# lib/commands/burn.sh writes `status.json` into its own run directory
# ($HOME/.clikae/logs/burn-<pid>/status.json) at every transition (see
# _burn_status_write there for the writer and the field contract, mirrored in
# docs/orchestration.md). This file is the READ side, used by `clikae wait`
# (#37), which polls one or more of these files for a terminal state instead
# of a hand-rolled `until [ -e DONE ]` loop.
#
# Purpose-built, not a general JSON parser: the only JSON these functions ever
# read is the flat, single-line object _burn_status_write itself produces (no
# nesting except the `rerouted_from` array, no field value ever contains a
# literal `"`), so a small grep/sed extractor is honest here where it would be
# a trap on arbitrary JSON.

# burn_status_field <json> <field> -> the RAW JSON-encoded value for <field>
# (a quoted string, `null`, `true`/`false`, a bare number, or a `[...]`
# array) — or nothing if the field is absent or the object doesn't match the
# one shape this reads.
burn_status_field() {
  local json="$1" field="$2"
  printf '%s' "$json" \
    | grep -oE "\"$field\":(\"[^\"]*\"|null|true|false|-?[0-9]+|\[[^]]*\])" \
    | head -n 1 | sed -E "s/^\"$field\"://"
}

# burn_status_str <json> <field> -> <field>'s value with quotes stripped, or
# empty for `null`/absent. For string fields (engine, tank, state, run_id, …).
burn_status_str() {
  local v; v="$(burn_status_field "$1" "$2")"
  [ -n "$v" ] && [ "$v" != null ] || return 0
  v="${v#\"}"; v="${v%\"}"
  printf '%s' "$v"
}

# burn_status_state <json> -> the `state` field (running|done|dry|fail|infra),
# or empty if unreadable.
burn_status_state() { burn_status_str "$1" state; }

# burn_status_dir <run_id> -> the run directory burn wrote for <run_id>
# (matches lib/commands/burn.sh's own `run_dir="$HOME/.clikae/logs/burn-$$"`
# — hardcoded to $HOME, like the rest of burn's own log/state paths, not
# $CLIKAE_HOME: the two agree by default but a caller overriding $CLIKAE_HOME
# alone would otherwise read from a directory burn never wrote to).
burn_status_dir() { printf '%s/.clikae/logs/%s\n' "$HOME" "$1"; }

# burn_status_resolve <run_id|status-file> -> echo the status.json PATH to
# read, or return 1 if none can be found. Accepts, in order:
#   - an existing file path, used verbatim (the "…|status-file" half of
#     `clikae wait`'s contract);
#   - a run id as burn itself prints it, e.g. `burn-28186` (the top-level
#     invocation's id — stable across a whole burn's reroutes/retries, unlike
#     the per-attempt `run_id` in `--json`'s own output);
#   - a bare pid, e.g. `28186` (shorthand for `burn-28186`);
#   - anything else is tried as a literal run-directory name, so a caller who
#     already knows burn's layout is never second-guessed.
burn_status_resolve() {
  local arg="$1" p
  [ -n "$arg" ] || return 1
  if [ -f "$arg" ]; then printf '%s' "$arg"; return 0; fi
  case "$arg" in
    burn-*)        p="$(burn_status_dir "$arg")/status.json" ;;
    ''|*[!0-9]*)   p="$(burn_status_dir "$arg")/status.json" ;;
    *)             p="$(burn_status_dir "burn-$arg")/status.json" ;;
  esac
  [ -f "$p" ] || return 1
  printf '%s' "$p"
}
