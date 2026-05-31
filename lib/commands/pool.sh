# shellcheck shell=bash
# lib/commands/pool.sh — `clikae pool [list|add|remove] …`
#
# Manage the fuel pool: the ordered list of tanks `clikae watch` falls through to
# when one runs dry. See lib/core/pool.sh for the file format and semantics.
#
# `pool list` has two renderers off ONE canonical row (like status/list):
#   human (default) — a numbered priority list for the terminal
#   --json          — machine-readable, for the menu-bar GUI / scripts
# The row producer emits US-delimited fields and never formats for a human, so
# the two renderers can't drift. JSON helpers live in lib/core/json.sh.

# _pool_rows  -> one canonical row per pool entry, in priority order, fields
# separated by ASCII Unit Separator (\037), record terminated by newline:
#   position ␟ target ␟ cli ␟ profile
# For a launch-only target (no "/", e.g. antigravity) the profile field is empty.
# (A non-whitespace delimiter is deliberate: tab is IFS-whitespace, so `read`
# would collapse consecutive empty fields and shift every column.)
_pool_rows() {
  local n=0 target cli profile
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    n=$((n + 1))
    cli="${target%%/*}"
    case "$target" in
      */*) profile="${target#*/}" ;;
      *)   profile="" ;;
    esac
    printf '%d\037%s\037%s\037%s\n' "$n" "$target" "$cli" "$profile"
  done <<EOF
$(pool_list)
EOF
}

# Render the canonical rows (on stdin) as a numbered human list.
_pool_render_table() {
  local position target cli profile
  while IFS=$'\037' read -r position target cli profile; do
    [ -n "$position" ] || continue
    printf '  %d. %s\n' "$position" "$target"
  done
}

# Render the canonical rows (on stdin) as a JSON array.
_pool_render_json() {
  local position target cli profile first=1
  printf '['
  while IFS=$'\037' read -r position target cli profile; do
    [ -n "$position" ] || continue
    [ "$first" -eq 1 ] && first=0 || printf ','
    printf '\n  {"position":%d,"target":%s,"cli":%s,"profile":%s}' \
      "$position" "$(json_str "$target")" "$(json_str "$cli")" "$(json_or_null "$profile")"
  done
  [ "$first" -eq 1 ] && printf ']\n' || printf '\n]\n'
}

cmd_pool() {
  local sub="${1:-list}"
  case "$sub" in
    -h|--help|help)
      cat <<EOF
Usage: clikae pool [list] [--json]
       clikae pool seed [<cli>]
       clikae pool add <target>
       clikae pool remove <target>

The fuel pool is your ordered list of tanks (top = most preferred). When a tank
runs dry, \`clikae watch\` hands off to the next one down the list. Targets use the
same grammar as \`handoff --to\`: <cli>/<profile> (e.g. claude/a, codex/work) or a
launch-only target (e.g. antigravity).

\`pool seed\` fills an empty pool fast: it adds every existing switchable profile
(optionally just one cli's) in name order, so \`watch\` has somewhere to fall
through to. Reorder afterwards by editing the file or with add/remove.

Stored as a plain text file you can also edit by hand:
  $(pool_file)

Options:
  --json  Emit a JSON array instead of the numbered list — one object per entry
          {position, target, cli, profile} in priority order (profile is null for
          a launch-only target like antigravity). For the menu-bar GUI / scripts.

Examples:
  clikae pool seed              # add every existing profile (all clis)
  clikae pool seed claude       # add just claude's profiles
  clikae pool add claude/a
  clikae pool add claude/b
  clikae pool add codex/work
  clikae pool list
  clikae pool list --json
  clikae pool remove codex/work
EOF
      return 0 ;;
    list|--json)
      # `clikae pool --json` (no subcommand) and `clikae pool list [--json]`.
      local as_json=0
      [ "$sub" = "--json" ] && as_json=1
      shift || true
      while [ $# -gt 0 ]; do
        case "$1" in
          --json) as_json=1; shift ;;
          *) log_fail "Unexpected argument: $1" ;;
        esac
      done
      local entries; entries="$(pool_list)"
      if [ -z "$entries" ]; then
        [ "$as_json" -eq 1 ] && { printf '[]\n'; return 0; }
        log_info "The fuel pool is empty."
        log_dim "Fill it fast:  clikae pool seed   (or add one:  clikae pool add claude/a)"
        return 0
      fi
      if [ "$as_json" -eq 1 ]; then
        _pool_rows | _pool_render_json
      else
        log_bold "Fuel pool (priority order):"
        _pool_rows | _pool_render_table
      fi
      ;;
    seed)
      shift
      local only_cli=""
      if [ $# -ge 1 ]; then only_cli="$1"; validate_name cli "$only_cli"; shift; fi
      [ $# -eq 0 ] || log_fail "Usage: clikae pool seed [<cli>]"
      local rows scli sprofile spath added=0
      rows="$(list_all_profiles || true)"
      if [ -z "$rows" ]; then
        log_info "No profiles to seed from. Create one with:  clikae init <cli> <profile>"
        return 0
      fi
      # Add every discovered SWITCHABLE profile (one with an adapter) not already
      # pooled, in list_all_profiles' sorted order. Launch-only targets (e.g.
      # antigravity) have no profile dir, so add those by hand.
      while IFS=$'\t' read -r scli sprofile spath; do
        [ -n "$scli" ] || continue
        : "$spath"   # 3rd column consumed only to keep the read aligned
        [ -z "$only_cli" ] || [ "$scli" = "$only_cli" ] || continue
        [ -f "$CLIKAE_LIB/adapters/$scli.sh" ] || continue
        pool_list | grep -qxF "$scli/$sprofile" && continue
        pool_add "$scli/$sprofile" && added=$((added + 1))
      done <<EOF
$rows
EOF
      if [ "$added" -eq 0 ]; then
        log_info "Nothing to add — the pool already covers your profiles."
      else
        log_dim "Reorder anytime (top = preferred): edit $(pool_file), or pool add/remove."
      fi
      ;;
    add)
      shift
      [ $# -ge 1 ] || log_fail "Usage: clikae pool add <target>"
      pool_add "$1" ;;
    remove|rm)
      shift
      [ $# -ge 1 ] || log_fail "Usage: clikae pool remove <target>"
      pool_remove "$1" ;;
    *)
      log_fail "Unknown subcommand: $sub  (try: list, seed, add, remove)" ;;
  esac
}
