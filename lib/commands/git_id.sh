# shellcheck shell=bash
# lib/commands/git_id.sh — `clikae git-id <engine> <tank> [--name N --email E | --unset]`
#
# Give a tank an OPTIONAL intended git commit identity. Once set, `eval "$(clikae
# env <engine> <tank>)"` also exports GIT_AUTHOR_* / GIT_COMMITTER_*, so commits
# made in that shell are stamped with the identity you MEANT — not whatever the
# engine's account email happens to be. (issue #22 / HANDOFF §13: a headless run
# once authored 9 commits under the wrong GitHub account; this prevents the NEXT
# mis-stamp.)
#
# Honest limits (kept in the help so we never oversell):
#   • git precedence is `-c` flag > GIT_* env > git config. This pins the env-var
#     path (the common case) but does NOT beat an engine that commits with an
#     explicit `git -c user.email=… commit`.
#   • per-shell only (like `env`); you must eval the env into the shell first.
#   • it only ever influences FUTURE commits — it cannot fix attribution on
#     commits already made (that needs a history rewrite + force-push).

cmd_git_id() {
  local cli="" tank="" name="" email="" do_unset=0 name_set=0 email_set=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage:
  clikae git-id <engine> <tank>                      # show this tank's git identity
  clikae git-id <engine> <tank> --name N --email E   # set it
  clikae git-id <engine> <tank> --unset              # remove it

Give a tank an optional git commit identity. When set, `eval "$(clikae env
<engine> <tank>)"` also exports GIT_AUTHOR_NAME/EMAIL + GIT_COMMITTER_NAME/EMAIL,
so commits made in that shell are stamped with the identity you intended —
regardless of what the engine would otherwise inject.

  eval "$(clikae env claude work)"   # now this shell is on the tank AND its git id
  git commit -m "…"                  # authored as the tank's name/email

Honest limits:
  • git precedence: `-c` flag > GIT_* env > git config. This wins over the
    global-config commit path (the usual case), but NOT over an engine that
    commits with an explicit `git -c user.email=… commit`.
  • per-shell only — it lives in the shell that eval'd `clikae env`.
  • only future commits — it cannot re-map commits already made.
EOF
        return 0 ;;
      --name)   shift; [ $# -gt 0 ] || log_fail "--name needs a value"; name="$1"; name_set=1; shift ;;
      --email)  shift; [ $# -gt 0 ] || log_fail "--email needs a value"; email="$1"; email_set=1; shift ;;
      --unset)  do_unset=1; shift ;;
      --)       shift; break ;;
      -*)       log_fail "Unknown flag: $1  (try: clikae git-id --help)" ;;
      *)        if [ -z "$cli" ]; then cli="$1"
                elif [ -z "$tank" ]; then tank="$1"
                else log_fail "Unexpected argument: $1"; fi
                shift ;;
    esac
  done

  [ -n "$cli" ]  || log_fail "Missing <engine>. Usage: clikae git-id <engine> <tank> --name N --email E"
  [ -n "$tank" ] || log_fail "Missing <tank>."
  validate_name cli "$cli"
  validate_name profile "$tank"
  # Require the tank to exist (don't silently create metadata for a typo'd tank).
  profile_exists "$cli" "$tank" || log_fail "No such tank: $cli/$tank  (create it with: clikae init $cli $tank)"

  local f; f="$(git_identity_file "$cli" "$tank")"

  # --unset: remove the identity file.
  if [ "$do_unset" -eq 1 ]; then
    [ "$name_set" -eq 1 ] || [ "$email_set" -eq 1 ] \
      && log_fail "--unset takes no --name/--email."
    if [ -f "$f" ]; then rm -f "$f" && log_ok "Cleared git identity for $cli/$tank."
    else log_info "No git identity set for $cli/$tank — nothing to clear."; fi
    return 0
  fi

  # Bare form (no --name/--email): show the current value.
  if [ "$name_set" -eq 0 ] && [ "$email_set" -eq 0 ]; then
    local cur; cur="$(git_identity_read "$cli" "$tank")"
    if [ -n "$cur" ]; then
      printf '%s <%s>\n' "${cur%%$'\t'*}" "${cur#*$'\t'}"
    else
      log_info "No git identity set for $cli/$tank."
      log_dim "Set one:  clikae git-id $cli $tank --name \"Your Name\" --email you@example.com"
    fi
    return 0
  fi

  # Set form: both fields required (a half identity stamps confusingly).
  [ "$name_set" -eq 1 ]  || log_fail "Setting a git identity needs --name (and --email)."
  [ "$email_set" -eq 1 ] || log_fail "Setting a git identity needs --email (and --name)."
  [ -n "$name" ]  || log_fail "--name must not be empty."
  [ -n "$email" ] || log_fail "--email must not be empty."
  # No tabs/newlines — the store is one TAB-separated line.
  case "$name$email" in
    *$'\t'*|*$'\n'*) log_fail "--name/--email must not contain tabs or newlines." ;;
  esac

  mkdir -p "$(dirname "$f")"
  printf '%s\t%s\n' "$name" "$email" > "$f" \
    || log_fail "Could not write git identity to $f"
  log_ok "Set git identity for $cli/$tank: $name <$email>"
  log_dim "Active when you  eval \"\$(clikae env $cli $tank)\"  (then commits in that shell use it)."
}
