# shellcheck shell=bash
# lib/commands/alias.sh — `clikae alias <cli> <profile>`

cmd_alias() {
  local cli="" profile="" name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      -h|--help)
        cat <<'EOF'
Usage: clikae alias <cli> <profile> [--name <alias_name>]

Write a shell alias to your shell rc file so you can invoke the CLI with the
given profile in one word.

By default the alias is named "<cli>-<profile>" (e.g. claude-work). Override
with --name.

The alias is wrapped in a sentinel block:
  # >>> clikae:<cli>.<profile> >>>
  alias <name>='<env vars> <binary>'
  # <<< clikae:<cli>.<profile> <<<

`clikae remove` will clean it up.
EOF
        return 0
        ;;
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

  [ -n "$cli" ]     || log_fail "Missing <cli>. See: clikae alias --help"
  [ -n "$profile" ] || log_fail "Missing <profile>. See: clikae alias --help"
  validate_name cli "$cli"
  validate_name profile "$profile"
  [ -n "$name" ] || name="${cli}-${profile}"

  load_adapter "$cli"
  local d
  d="$(ensure_profile --require "$cli" "$profile")"
  local binary
  binary="$(adapter_meta_cli_binary)"

  # Build the env-var prefix string from adapter_export_env. Each line is KEY=VALUE.
  local env_prefix=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local key="${line%%=*}" val="${line#*=}"
    # Quote the value safely for shell.
    env_prefix="$env_prefix $key=\"$val\""
  done < <(adapter_export_env "$d")
  env_prefix="${env_prefix# }"  # trim leading space

  local rc_file rc_id
  rc_file="$(detect_shell_rc)"
  rc_id="$cli.$profile"

  if rc_has_block "$rc_file" "$rc_id"; then
    log_info "Existing alias block found, replacing."
    rc_remove_block "$rc_file" "$rc_id"
  fi

  rc_add_block "$rc_file" "$rc_id" <<EOF
alias ${name}='${env_prefix} ${binary}'
EOF

  log_ok "Added alias '${name}' to $rc_file"
  log_dim "  $env_prefix $binary"
  log_info "Run \`source $rc_file\` or open a new shell to use it."
}
