# shellcheck shell=bash
# lib/commands/run.sh — `clikae run <cli> <profile> [-- args...]`

cmd_run() {
  local cli="" profile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage: clikae run <cli> <profile> [-- args...]

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

  [ -n "$cli" ]     || log_fail "Missing <cli>. See: clikae run --help"
  [ -n "$profile" ] || log_fail "Missing <profile>. See: clikae run --help"
  validate_name cli "$cli"
  validate_name profile "$profile"

  load_adapter "$cli"
  local d
  d="$(ensure_profile --require "$cli" "$profile")"

  adapter_run "$d" "$@"
}
