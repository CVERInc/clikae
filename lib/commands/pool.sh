# shellcheck shell=bash
# lib/commands/pool.sh — `clikae pool [list|add|remove] …`
#
# Manage the fuel pool: the ordered list of tanks `clikae watch` falls through to
# when one runs dry. See lib/core/pool.sh for the file format and semantics.

cmd_pool() {
  local sub="${1:-list}"
  case "$sub" in
    -h|--help|help)
      cat <<EOF
Usage: clikae pool [list]
       clikae pool add <target>
       clikae pool remove <target>

The fuel pool is your ordered list of tanks (top = most preferred). When a tank
runs dry, \`clikae watch\` hands off to the next one down the list. Targets use the
same grammar as \`handoff --to\`: <cli>/<profile> (e.g. claude/a, codex/work) or a
launch-only target (e.g. antigravity).

Stored as a plain text file you can also edit by hand:
  $(pool_file)

Examples:
  clikae pool add claude/a
  clikae pool add claude/b
  clikae pool add codex/work
  clikae pool list
  clikae pool remove codex/work
EOF
      return 0 ;;
    list)
      shift || true
      local entries; entries="$(pool_list)"
      if [ -z "$entries" ]; then
        log_info "The fuel pool is empty."
        log_dim "Add tanks in priority order:  clikae pool add claude/a"
        return 0
      fi
      log_bold "Fuel pool (priority order):"
      local n=0 line
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        n=$((n + 1))
        printf '  %d. %s\n' "$n" "$line"
      done <<EOF
$entries
EOF
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
      log_fail "Unknown subcommand: $sub  (try: list, add, remove)" ;;
  esac
}
