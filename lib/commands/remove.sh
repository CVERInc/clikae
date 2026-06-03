# shellcheck shell=bash
# lib/commands/remove.sh — `clikae remove <engine> <tank> [--force] [--keep-data]`

cmd_remove() {
  local force=0 keep_data=0 cli="" profile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force) force=1; shift ;;
      --keep-data) keep_data=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: clikae remove <engine> <tank> [--force] [--keep-data]

Remove a tank. By default removes the tank directory, the shell alias block
(if any), and the macOS launcher .app (if any).

Options:
  -f, --force      Don't prompt for confirmation.
  --keep-data      Don't delete the tank directory; only remove alias + .app.
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

  [ -n "$cli" ]     || log_fail "Missing <engine>. See: clikae remove --help"
  [ -n "$profile" ] || log_fail "Missing <tank>. See: clikae remove --help"
  validate_name cli "$cli"
  validate_name profile "$profile"

  # agy tanks aren't env profiles — they're symlink-swapped dirs. Removing the
  # last one also tears down the takeover. See docs/grammar.md §6.
  if [ "$cli" = "agy" ] || [ "$cli" = "antigravity" ]; then
    # shellcheck source=./antigravity.sh
    source "$CLIKAE_LIB/commands/antigravity.sh"
    _agy_remove "$profile" "$force"
    return $?
  fi

  local d
  d="$(profile_dir "$cli" "$profile")"

  # In-use guard (data integrity, NOT --force-able): refuse to delete a tank dir a
  # live session is still bound to — this shell OR another terminal / a background
  # worker (the phantom-tank bug, HANDOFF §11). Only when actually deleting data,
  # and only if the adapter resolves an env var to scan for.
  if [ "$keep_data" -eq 0 ] && [ -f "$CLIKAE_LIB/adapters/$cli.sh" ]; then
    local _rm_ev
    _rm_ev="$(load_adapter "$cli" >/dev/null 2>&1 && adapter_meta_env_var || true)"
    if [ -n "$_rm_ev" ]; then
      local _rm_live="${!_rm_ev:-}"
      if [ -n "$_rm_live" ] && [ "${_rm_live%/}" = "${d%/}" ]; then
        log_err "\$$_rm_ev currently points at the tank you're removing:"
        log_err "    $_rm_live"
        log_fail "Open a fresh shell with $cli idle (and \$$_rm_ev unset), then retry."
      fi
      assert_dir_free "$d" "$_rm_ev" "$cli" "removal"
    fi
  fi

  local rc_file
  rc_file="$(detect_shell_rc)"
  local rc_id="$cli.$profile"
  local app_path="$HOME/Applications/${cli} (${profile}).app"

  echo "About to remove:"
  [ "$keep_data" -eq 0 ] && [ -d "$d" ] && echo "  - tank dir    : $d"
  rc_has_block "$rc_file" "$rc_id" && echo "  - shell alias : block 'clikae:$rc_id' in $rc_file"
  [ -d "$app_path" ] && echo "  - launcher    : $app_path"
  echo ""

  if [ "$force" -eq 0 ]; then
    confirm "Proceed?" || { log_info "Aborted."; return 0; }
  fi

  if [ "$keep_data" -eq 0 ] && [ -d "$d" ]; then
    rm -rf "$d"
    log_ok "Removed tank dir."
    # If the cli dir under profiles/ is now empty, clean it up.
    local cli_dir
    cli_dir="$(dirname "$d")"
    rmdir "$cli_dir" 2>/dev/null && log_dim "  (also cleaned empty $cli_dir)"
  fi

  if rc_has_block "$rc_file" "$rc_id"; then
    rc_remove_block "$rc_file" "$rc_id"
    log_ok "Removed alias block from $rc_file"
  fi

  if [ -d "$app_path" ]; then
    rm -rf "$app_path"
    log_ok "Removed launcher: $app_path"
  fi
}
