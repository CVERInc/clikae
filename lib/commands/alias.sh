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

The block is written to your shell's rc file (zsh/bash/fish auto-detected). For
fish it uses fish syntax (`alias <name> 'env <vars> <binary>'`, since fish has
no inline VAR=val). `clikae remove` will clean it up regardless of shell.
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

  # Build the full command (env prefix + binary + any flag suffix) from the
  # adapter — handles env-dir/env-file/env-var and flag strategies uniformly.
  # fish needs both a different command form (no inline VAR=val) and a different
  # alias syntax, so branch on the shell family.
  local cmd shell_kind alias_line
  shell_kind="$(detect_shell_kind)"
  if [ "$shell_kind" = "fish" ]; then
    cmd="$(adapter_command_fish "$d")"
    alias_line="alias ${name} '${cmd}'"
  else
    cmd="$(adapter_command "$d")"
    alias_line="alias ${name}='${cmd}'"
  fi

  local rc_file rc_id
  rc_file="$(detect_shell_rc)"
  rc_id="$cli.$profile"

  if rc_has_block "$rc_file" "$rc_id"; then
    log_info "Existing alias block found, replacing."
    rc_remove_block "$rc_file" "$rc_id"
  fi

  rc_add_block "$rc_file" "$rc_id" <<EOF
${alias_line}
EOF

  log_ok "Added alias '${name}' to $rc_file"
  log_dim "  $cmd"
  log_info "Run \`source $rc_file\` or open a new shell to use it."
}
