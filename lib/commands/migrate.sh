# shellcheck shell=bash
# lib/commands/migrate.sh — `clikae migrate [<engine>] [--dry-run] [--force]`
#
# Adopts a hand-rolled "config dir + shell alias" setup into clikae. The classic
# case is Claude dual accounts created by setup-claude-dual-accounts.sh:
#
#   # >>> claude dual accounts (managed by setup-claude-dual-accounts.sh) >>>
#   alias claude-a='CLAUDE_CONFIG_DIR="$HOME/.claude-acct-a" claude'
#   alias claude-b='CLAUDE_CONFIG_DIR="$HOME/.claude-acct-b" claude'
#   # <<< claude dual accounts <<<
#
# For each such alias we MOVE its config dir under ~/.clikae/profiles/<engine>/<p>/
# and rewrite the alias into clikae's sentinel format. Everything is previewed
# and confirmed first; the rc file is backed up once; nothing is overwritten.

# Resolve a config-dir value lifted from an alias line into an absolute path.
# Handles "$HOME/...", '${HOME}/...', '~/...', and already-absolute paths.
_migrate_resolve_dir() {
  local val="$1"
  # The '~' patterns below match a literal tilde lifted from an alias value;
  # we expand it ourselves. They are not attempts at shell tilde expansion.
  # shellcheck disable=SC2088
  case "$val" in
    '$HOME'*)   printf '%s\n' "$HOME${val#\$HOME}" ;;
    '${HOME}'*) printf '%s\n' "$HOME${val#\$\{HOME\}}" ;;
    '~/'*)      printf '%s\n' "$HOME${val#\~}" ;;
    '~')        printf '%s\n' "$HOME" ;;
    *)          printf '%s\n' "$val" ;;
  esac
}

# Pull the env-var value out of an alias body, given the env var name.
# e.g. line=...CLAUDE_CONFIG_DIR="$HOME/.claude-acct-a" claude  ->  $HOME/.claude-acct-a
_migrate_extract_value() {
  local line="$1" envvar="$2" rest
  rest="${line#*${envvar}=}"
  case "$rest" in
    \"*) rest="${rest#\"}"; printf '%s\n' "${rest%%\"*}" ;;
    \'*) rest="${rest#\'}"; printf '%s\n' "${rest%%\'*}" ;;
    *)   printf '%s\n' "${rest%% *}" ;;
  esac
}

# Derive a clikae profile name from an alias name (strip a leading "<engine>-/_").
_migrate_profile_from_alias() {
  local cli="$1" name="$2"
  case "$name" in
    "$cli"-*) printf '%s\n' "${name#"$cli"-}" ;;
    "$cli"_*) printf '%s\n' "${name#"$cli"_}" ;;
    *)        printf '%s\n' "$name" ;;
  esac
}

cmd_migrate() {
  local cli="claude" dry_run=0 force=0 keep_login=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--dry-run)   dry_run=1; shift ;;
      -f|--force)     force=1; shift ;;
      -k|--keep-login) keep_login=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: clikae migrate [<engine>] [--dry-run] [--force] [--keep-login]

Adopt a hand-rolled "config dir + shell alias" setup into clikae.

clikae scans your shell rc for aliases that set the CLI's config env var (e.g.
CLAUDE_CONFIG_DIR) and invoke the CLI. For each one it will:
  1. move the referenced config directory under ~/.clikae/profiles/<engine>/<p>/
  2. rewrite the alias into clikae's managed sentinel block

Arguments:
  <engine>        CLI to migrate (must have an adapter). Default: claude.

Options:
  -n, --dry-run     Show the plan without changing anything.
  -f, --force       Skip the confirmation prompt.
  -k, --keep-login  Carry over each profile's saved login so you don't have to
                    log in again (macOS/claude only — claude stores its token in
                    the Keychain keyed by the config-dir path, which the move
                    changes). Off by default; without it, expect a one-time
                    re-login per migrated profile.

The rc file is backed up to <rc>.clikae.bak.<timestamp> before editing, and an
existing clikae profile is never overwritten.
EOF
        return 0
        ;;
      --) shift; break ;;
      -*) log_fail "Unknown flag: $1" ;;
      *)  cli="$1"; shift ;;
    esac
  done

  validate_name cli "$cli"
  load_adapter "$cli"
  local envvar binary
  envvar="$(adapter_meta_env_var)"
  binary="$(adapter_meta_cli_binary)"

  local rc_file
  rc_file="$(detect_shell_rc)"
  if [ ! -f "$rc_file" ]; then
    log_info "No shell rc file at $rc_file — nothing to migrate."
    return 0
  fi

  # Scan the rc file for candidate alias lines, skipping clikae-managed blocks.
  local in_clikae=0 line trimmed name val old_dir profile new_dir
  local -a c_name c_old c_profile c_new
  local skipped=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "# >>> clikae:"*) in_clikae=1; continue ;;
      "# <<< clikae:"*) in_clikae=0; continue ;;
    esac
    [ "$in_clikae" -eq 0 ] || continue

    # Trim leading whitespace, then require an `alias NAME=...` referencing both
    # the env var and the binary.
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      alias\ *) ;;
      *) continue ;;
    esac
    case "$trimmed" in
      *"${envvar}="*"${binary}"*) ;;
      *) continue ;;
    esac

    name="${trimmed#alias }"
    name="${name%%=*}"
    val="$(_migrate_extract_value "$trimmed" "$envvar")"
    old_dir="$(_migrate_resolve_dir "$val")"
    profile="$(_migrate_profile_from_alias "$cli" "$name")"

    # Skip names we can't turn into a valid profile.
    if ! printf '%s' "$profile" | LC_ALL=C grep -Eq '^[A-Za-z0-9._-]+$'; then
      log_warn "Skipping alias '$name': can't derive a valid profile name."
      skipped=$((skipped + 1))
      continue
    fi

    new_dir="$(profile_dir "$cli" "$profile")"

    # Don't clobber an existing clikae profile.
    if [ "$old_dir" != "$new_dir" ] && [ -e "$new_dir" ]; then
      log_warn "Skipping '$name': target profile already exists ($cli/$profile)."
      skipped=$((skipped + 1))
      continue
    fi
    if [ "$old_dir" = "$new_dir" ]; then
      log_dim "Already migrated: $name ($cli/$profile) — skipping."
      continue
    fi

    c_name+=("$name")
    c_old+=("$old_dir")
    c_profile+=("$profile")
    c_new+=("$new_dir")
  done < "$rc_file"

  local n=${#c_name[@]}
  if [ "$n" -eq 0 ]; then
    if [ "$skipped" -gt 0 ]; then
      log_info "No migratable aliases (skipped $skipped). See warnings above."
    else
      log_info "Found no '$cli' aliases to migrate in $rc_file."
    fi
    return 0
  fi

  # Preview.
  log_bold "Migration plan ($cli) from $rc_file:"
  echo ""
  local i
  for ((i = 0; i < n; i++)); do
    printf '  %s  (profile: %s)\n' "${c_name[$i]}" "${c_profile[$i]}"
    if [ -d "${c_old[$i]}" ]; then
      printf '    move dir : %s\n' "${c_old[$i]}"
      printf '            -> %s\n' "${c_new[$i]}"
    else
      printf '    dir      : %s (missing — will create an empty profile)\n' "${c_old[$i]}"
    fi
    printf '    alias    : rewrite into clikae block "clikae:%s.%s"\n' "$cli" "${c_profile[$i]}"
    echo ""
  done
  log_dim "The rc file will be backed up to ${rc_file}.clikae.bak.<timestamp>."
  if grep -q '^# >>> claude dual accounts' "$rc_file"; then
    log_dim "The legacy 'claude dual accounts' sentinel comments will be removed."
  fi
  if [ "$keep_login" -eq 1 ]; then
    if declare -f adapter_migrate_credentials >/dev/null 2>&1; then
      log_dim "Will try to carry over each profile's saved login (--keep-login)."
    else
      log_dim "--keep-login has no effect for '$cli' (no saved-login carry-over)."
    fi
  fi
  echo ""

  if [ "$dry_run" -eq 1 ]; then
    log_info "Dry run — no changes made."
    return 0
  fi

  # Safety guard: refuse to move a dir the CLI is *currently* using in this
  # shell. If $<ENVVAR> points at one of the dirs slated to move, migrating now
  # pulls the dir out from under the live process — which can recreate an empty
  # dir at the old path, leaving split state. Bail with instructions to retry
  # from a fresh shell. (--force does not override this — it is a data-integrity
  # guard, not a confirmation. Dry runs never reach here; nothing moves.)
  local live_dir="${!envvar:-}" live_norm
  if [ -n "$live_dir" ]; then
    live_norm="${live_dir%/}"
    for ((i = 0; i < n; i++)); do
      if [ "${c_old[$i]%/}" = "$live_norm" ]; then
        log_err "\$$envvar is set to a directory slated to move:"
        log_err "    $live_dir"
        log_err "Moving it now would pull it out from under a running $binary (→ split state)."
        log_fail "Open a fresh shell with $binary idle (and \$$envvar unset), then retry."
      fi
    done
  fi

  if [ "$force" -eq 0 ]; then
    confirm "Proceed with migration?" || { log_info "Aborted."; return 0; }
  fi

  # 1) Move (or create) the profile directories.
  for ((i = 0; i < n; i++)); do
    mkdir -p "$(dirname "${c_new[$i]}")"
    if [ -d "${c_old[$i]}" ]; then
      mv "${c_old[$i]}" "${c_new[$i]}"
      log_ok "Moved ${c_old[$i]} -> ${c_new[$i]}"
    else
      mkdir -p "${c_new[$i]}"
      log_warn "Source dir ${c_old[$i]} was missing; created empty ${c_new[$i]}."
    fi
  done

  # 1b) Optionally carry over each profile's saved login (adapter-specific, e.g.
  #     claude's macOS keychain token, which is keyed by the config-dir path).
  if [ "$keep_login" -eq 1 ] && declare -f adapter_migrate_credentials >/dev/null 2>&1; then
    for ((i = 0; i < n; i++)); do
      [ -d "${c_new[$i]}" ] || continue
      local mc_rc=0
      adapter_migrate_credentials "${c_old[$i]}" "${c_new[$i]}" || mc_rc=$?
      case "$mc_rc" in
        0) log_ok "Carried over saved login for $cli/${c_profile[$i]}." ;;
        2) log_warn "Couldn't carry over login for $cli/${c_profile[$i]} — open it once to log in." ;;
        *) log_dim "No saved login to carry over for $cli/${c_profile[$i]}." ;;
      esac
    done
  fi

  # 2) Rewrite the rc file in one pass (single backup), then append clikae blocks.
  cp "$rc_file" "$rc_file.clikae.bak.$(date +%Y%m%d-%H%M%S)"
  local names=""
  for ((i = 0; i < n; i++)); do names="$names ${c_name[$i]}"; done

  local tmp
  tmp="$(mktemp)"
  awk -v names="$names" '
    BEGIN { nn = split(names, a, " "); for (k = 1; k <= nn; k++) if (a[k] != "") drop[a[k]] = 1 }
    /^# >>> claude dual accounts/ { next }
    /^# <<< claude dual accounts/ { next }
    {
      probe = $0
      sub(/^[ \t]+/, "", probe)
      if (probe ~ /^alias [A-Za-z0-9._-]+=/) {
        an = probe
        sub(/^alias /, "", an)
        sub(/=.*/, "", an)
        if (an in drop) next
      }
      print
    }
  ' "$rc_file" > "$tmp"

  for ((i = 0; i < n; i++)); do
    local env_prefix
    env_prefix="$(adapter_env_prefix "${c_new[$i]}")"
    printf "alias %s='%s %s'\n" "${c_name[$i]}" "$env_prefix" "$binary" \
      | rc_wrap_block "$cli.${c_profile[$i]}" >> "$tmp"
  done
  mv "$tmp" "$rc_file"
  log_ok "Rewrote $rc_file ($n alias(es) now clikae-managed)."

  echo ""
  log_bold "Done. Next steps:"
  echo "  source $rc_file        # pick up the rewritten aliases"
  echo "  clikae list            # confirm your migrated profiles"
}
