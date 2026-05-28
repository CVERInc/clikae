# shellcheck shell=bash
# lib/commands/init.sh — `clikae init <cli> <profile> [--alias]`

cmd_init() {
  local with_alias=0 cli="" profile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --alias) with_alias=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: clikae init <cli> <profile> [--alias]

Create a new profile for a CLI tool.

Arguments:
  <cli>      CLI tool name (must have an adapter). Run `clikae adapters` to list.
  <profile>  Profile name. A-Z a-z 0-9 . _ - allowed.

Options:
  --alias    Also add a shell alias to your shell rc:
               <cli>-<profile>   (e.g. claude-work)

Example:
  clikae init claude work --alias
EOF
        return 0
        ;;
      --) shift; break ;;
      -*) log_fail "Unknown flag: $1" ;;
      *)
        if [ -z "$cli" ]; then cli="$1"
        elif [ -z "$profile" ]; then profile="$1"
        else log_fail "Unexpected argument: $1"
        fi
        shift
        ;;
    esac
  done

  [ -n "$cli" ]     || log_fail "Missing <cli>. See: clikae init --help"
  [ -n "$profile" ] || log_fail "Missing <profile>. See: clikae init --help"
  validate_name cli "$cli"
  validate_name profile "$profile"

  load_adapter "$cli"

  if profile_exists "$cli" "$profile"; then
    log_fail "Profile already exists: $cli/$profile  ($(profile_dir "$cli" "$profile"))"
  fi

  local d
  d="$(ensure_profile --create "$cli" "$profile")"
  log_ok "Created profile dir: $d"

  if declare -F adapter_init >/dev/null; then
    adapter_init "$d"
  fi

  if [ "$with_alias" -eq 1 ]; then
    # alias.sh isn't auto-sourced by the dispatcher; load it on demand.
    # shellcheck source=./alias.sh
    source "$CLIKAE_LIB/commands/alias.sh"
    cmd_alias "$cli" "$profile"
  else
    log_info "No alias added. Run \`clikae alias $cli $profile\` to add one."
  fi

  echo ""
  log_bold "Next steps:"
  echo "  clikae run $cli $profile           # try it now"
  echo "  clikae app $cli $profile           # generate a macOS .app launcher"
  echo "  clikae alias $cli $profile         # add a shell alias"
}
