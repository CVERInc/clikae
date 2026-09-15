# shellcheck shell=bash
# lib/commands/run.sh — `clikae run <engine> <tank> [-- args...]`

cmd_run() {
  local cli="" profile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage: clikae run <engine> <tank> [-- args...]

Run a CLI with a given profile, without needing an alias.

Arguments after `--` are passed straight through to the CLI.

Example:
  clikae run claude work
  clikae run claude work -- --help
EOF
        return 0
        ;;
      --) shift; break ;;
      -*) log_fail "Unknown flag: $1" ;;
      *)
        if [ -z "$cli" ]; then cli="$1"
        elif [ -z "$profile" ]; then profile="$1"
        else break
        fi
        shift
        ;;
    esac
  done

  [ -n "$cli" ]     || log_fail "Missing <engine>. See: clikae run --help"
  [ -n "$profile" ] || log_fail "Missing <tank>. See: clikae run --help"
  validate_name cli "$cli"
  validate_name profile "$profile"

  load_adapter "$cli"
  local d
  d="$(ensure_profile --require "$cli" "$profile")"

  soul_prelaunch "$cli" "$profile" "$d"   # member tank → fan this dir into its Soul
  fleet_mcp_prelaunch "$cli" "$profile" "$d"   # non-solo tank → fan in the shared MCP list
  # 2026-09-12 round-1 fix review, P2-1/P2-2: this used to wrap adapter_run in
  # a subshell so a board_state_refresh could run AFTER the engine exited —
  # which meant clikae stayed a resident parent for the whole session (no more
  # bare `exec`: different signal delivery, `$PPID`, and a `128+N` exit code
  # instead of WIFSIGNALED) and paid a full tank scan synchronously on EVERY
  # launch and EVERY exit, on the machine issue #62 was filed against. Neither
  # refresh is needed anymore: board_generation (lib/core/board_state.sh) now
  # rebuilds a stale tank inline, right when a render actually reads it, so
  # there is nothing left for a boundary call here to buy. adapter_run ends in
  # `exec`, so this is the tail call — nothing after it ever runs.
  adapter_run "$d" "$@"
}
