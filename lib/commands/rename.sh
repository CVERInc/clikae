# shellcheck shell=bash
# lib/commands/rename.sh — `clikae rename <engine> <old> <new>`
#
# Rename a profile (e.g. the meaningless "a" → "cver"). This is a mini-migrate:
# it MOVES the profile directory, rewrites the managed shell alias, and — for
# adapters that store their login outside the config dir keyed by its path (macOS
# claude's Keychain) — carries the saved login across so you don't re-login.
#
# Non-destructive guards: the source must exist, the target must not, and it
# refuses to move a directory the CLI is currently using in this shell.

# Extract the alias name from a clikae block in the rc file, if present.
_rename_alias_name() {
  local rc_file="$1" id="$2"
  [ -f "$rc_file" ] || return 0
  awk -v id="$id" '
    $0 == "# >>> clikae:" id " >>>" { inb = 1; next }
    $0 == "# <<< clikae:" id " <<<" { inb = 0 }
    inb && /^[[:space:]]*alias / {
      line = $0
      sub(/^[[:space:]]*alias /, "", line)
      sub(/=.*/, "", line)
      print line
      exit
    }
  ' "$rc_file"
}

cmd_rename() {
  local cli="" old="" new="" force=0
  local -a positionals=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force) force=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: clikae rename <engine> <old> <new> [--force]

Rename a tank: move its directory, rewrite its managed shell alias, and (for
claude on macOS) carry the saved Keychain login across so you don't re-login.

Give your tanks meaningful names instead of a/b — e.g.:
  clikae rename claude a cver
  clikae rename claude b personal

Options:
  -f, --force   Skip the confirmation prompt.

Refuses if <new> already exists, or if the engine is currently using <old> in
this shell (run it from a fresh shell with that engine idle). The rc file is
backed up
before editing. A pre-existing `.app` launcher for <old> is left alone but
flagged — regenerate it with `clikae app <engine> <new>`.
EOF
        return 0
        ;;
      -*) log_fail "Unknown flag: $1" ;;
      *) positionals+=("$1"); shift ;;
    esac
  done

  [ "${#positionals[@]}" -eq 3 ] || log_fail "Usage: clikae rename <engine> <old> <new>. See --help."
  cli="${positionals[0]}"; old="${positionals[1]}"; new="${positionals[2]}"
  validate_name cli "$cli"
  validate_name profile "$old"
  validate_name profile "$new"
  [ "$old" != "$new" ] || log_fail "Old and new names are the same ('$old')."

  # agy is a symlink-managed target, not an env adapter: rename moves the slot dir
  # and repoints ~/.gemini if it's the active one. (No alias/Keychain to carry.)
  if [ "$cli" = "agy" ] || [ "$cli" = "antigravity" ]; then
    # shellcheck source=./antigravity.sh
    source "$CLIKAE_LIB/commands/antigravity.sh"
    _agy_rename "$old" "$new"
    return $?
  fi

  load_adapter "$cli"
  local envvar binary old_dir new_dir
  envvar="$(adapter_meta_env_var)"
  binary="$(adapter_meta_cli_binary)"
  old_dir="$(ensure_profile --require "$cli" "$old")"
  new_dir="$(profile_dir "$cli" "$new")"
  [ ! -e "$new_dir" ] || log_fail "Target tank already exists: $cli/$new ($new_dir)."

  # In-use guard (not bypassable by --force — a data-integrity guard, like
  # migrate). If the live env var points at the dir we're about to move, bail.
  if [ -n "$envvar" ]; then
    local live_dir="${!envvar:-}"
    if [ -n "$live_dir" ] && [ "${live_dir%/}" = "${old_dir%/}" ]; then
      log_err "\$$envvar currently points at the tank you're renaming:"
      log_err "    $live_dir"
      log_fail "Open a fresh shell with $binary idle (and \$$envvar unset), then retry."
    fi
  fi
  # ...and a session open in ANOTHER terminal / a background worker (the phantom-
  # tank bug: the old guard saw only this shell). Hard-fails on a live TUI.
  assert_dir_free "$old_dir" "$envvar" "$binary" "rename"

  log_bold "Rename $cli/$old → $cli/$new"
  printf '  move dir : %s\n         -> %s\n' "$old_dir" "$new_dir"
  local rc_file old_alias new_alias
  rc_file="$(detect_shell_rc)"
  if rc_has_block "$rc_file" "$cli.$old"; then
    old_alias="$(_rename_alias_name "$rc_file" "$cli.$old")"
    if [ "$old_alias" = "${cli}-${old}" ]; then
      new_alias="${cli}-${new}"
    else
      new_alias="$old_alias"   # keep a custom alias name as-is
    fi
    printf '  alias    : %s → %s (in %s)\n' "$old_alias" "$new_alias" "$rc_file"
  fi
  if declare -f adapter_migrate_credentials >/dev/null 2>&1; then
    printf '  login    : will try to carry the saved login across\n'
  fi
  echo ""

  if [ "$force" -eq 0 ]; then
    confirm "Proceed?" || { log_info "Aborted."; return 0; }
  fi

  # 1) Move the directory.
  mkdir -p "$(dirname "$new_dir")"
  mv "$old_dir" "$new_dir"
  log_ok "Moved $old_dir -> $new_dir"

  # 2) Carry over the saved login (best-effort, adapter-specific).
  if declare -f adapter_migrate_credentials >/dev/null 2>&1; then
    local mc_rc=0
    adapter_migrate_credentials "$old_dir" "$new_dir" || mc_rc=$?
    case "$mc_rc" in
      0) log_ok "Carried over the saved login." ;;
      2) log_warn "Couldn't carry over the login — open $cli/$new once to log in." ;;
      *) : ;;  # nothing to carry over
    esac
  fi

  # 3) Rewrite the alias block, if one existed.
  if [ -n "${new_alias:-}" ]; then
    rc_remove_block "$rc_file" "$cli.$old"
    local cmd
    cmd="$(adapter_command "$new_dir")"
    rc_add_block "$rc_file" "$cli.$new" <<EOF
alias ${new_alias}='${cmd}'
EOF
    log_ok "Updated alias '$new_alias' in $rc_file"
  fi

  # 4) Flag a now-stale .app launcher (we don't touch the user's launchers).
  local old_app
  for old_app in "$HOME/Applications/$cli ($old).app" "$HOME/Desktop/$cli ($old).app"; do
    if [ -e "$old_app" ]; then
      log_warn "Launcher still points at the old path: $old_app"
      log_dim "  Recreate it:  clikae app $cli $new   (then delete the old one)"
    fi
  done

  echo ""
  if [ -n "${new_alias:-}" ]; then
    log_dim "Run \`source $rc_file\` or open a new shell to pick up the renamed alias."
  fi
}
