# shellcheck shell=bash
# lib/commands/relay.sh — `clikae relay <cli> [<from>] <to> [-- args...]`
#
# "Swap the fuel tank and keep burning." When one profile hits its usage limit
# mid-task, hand the *current* conversation/session over to another profile and
# keep going on that profile's separate quota.
#
# What carry-over means is adapter-specific: an adapter may define an optional
#   adapter_relay <from_dir> <to_dir> [args...]
# hook that transfers session state (for Claude Code: the current directory's
# latest transcript) and then exec's the CLI resuming it. Adapters without the
# hook simply start fresh under <to> — relay still works, there's just no
# conversation to carry.
#
# Non-destructive: the source profile is never modified; carry-over copies.

# Render the relay preview card: which session, which direction, what it costs —
# shown before anything moves so a relay is never a blind leap.
_relay_preview_card() {
  local cli="$1" from="$2" to="$3" sid="$4" last="$5" msgs="$6" title="$7"
  printf '\n  %brelay%b  %b換油箱・接力%b\n\n' "$__C_BOLD" "$__C_RESET" "$__C_DIM" "$__C_RESET"
  printf '    %-9s%b%s%b  %b%s%b  %b──▶%b  %b%s%b\n' \
    "tanks" "$__C_DIM" "$cli" "$__C_RESET" "$__C_BOLD" "$from" "$__C_RESET" \
    "$__C_DIM" "$__C_RESET" "$__C_GREEN" "$to" "$__C_RESET"
  printf '    %-9s%s  %b· ≈%s msgs · last active %s%b\n' \
    "session" "${sid%%-*}" "$__C_DIM" "$msgs" "$last" "$__C_RESET"
  printf '    %-9s%b%s%b\n' "carrying" "$__C_DIM" "$title" "$__C_RESET"
  printf '    %-9snew turns burn %b%s%b · %s untouched %b✓%b\n\n' \
    "quota" "$__C_BOLD" "$to" "$__C_RESET" "$from" "$__C_GREEN" "$__C_RESET"
}

cmd_relay() {
  local cli="" from="" to="" got_from=0 assume_yes=0 want_fresh=0
  local -a positionals=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage: clikae relay <cli> [<from>] <to> [-- args...]

Hand the current session over to another profile and continue on its quota —
for when the profile you're on hits its usage limit mid-task.

With one profile name, <from> is auto-detected from the CLI's live env var
(e.g. $CLAUDE_CONFIG_DIR in this shell). Give both to be explicit.

Arguments after `--` are passed straight through to the CLI.

For Claude Code, relay copies the *current directory's* most recent transcript
from <from> into <to>, then resumes it — so the conversation continues, but the
new turns burn <to>'s quota. The original session is left intact.

Examples:
  clikae relay claude b           # from = whatever this shell is on, to = b
  clikae relay claude a b         # explicit: from a, to b
  clikae relay claude a b -- --model opus
EOF
        return 0
        ;;
      -y|--yes) assume_yes=1; shift ;;
      --fresh) want_fresh=1; shift ;;
      --) shift; break ;;
      -*) log_fail "Unknown flag: $1" ;;
      *)
        positionals+=("$1")
        shift
        ;;
    esac
  done

  # First positional is always the CLI.
  [ "${#positionals[@]}" -ge 1 ] || log_fail "Missing <cli>. See: clikae relay --help"
  cli="${positionals[0]}"
  validate_name cli "$cli"

  case "${#positionals[@]}" in
    1) log_fail "Missing target profile. Usage: clikae relay $cli [<from>] <to>" ;;
    2) to="${positionals[1]}" ;;
    3) from="${positionals[1]}"; to="${positionals[2]}"; got_from=1 ;;
    *) log_fail "Too many arguments. Usage: clikae relay $cli [<from>] <to>" ;;
  esac

  load_adapter "$cli"

  # Auto-detect <from> from this shell's live env var when not given explicitly.
  if [ "$got_from" -eq 0 ]; then
    local var strategy value
    var="$(adapter_meta_env_var)"
    strategy="$(adapter_meta_strategy)"
    value="${!var}"
    from="$(resolve_active_profile "$cli" "$strategy" "$value")"
    if [ -z "$from" ]; then
      log_err "Couldn't tell which profile '$cli' is currently on (\$$var is unset or not a clikae profile)."
      log_dim "Name the source explicitly:  clikae relay $cli <from> $to"
      exit 1
    fi
    log_dim "Detected current profile: $from  (\$$var)"
  fi

  validate_name profile "$from"
  validate_name profile "$to"
  [ "$from" != "$to" ] || log_fail "Source and target are the same profile ('$from'). Nothing to relay."

  local from_dir to_dir
  from_dir="$(ensure_profile --require "$cli" "$from")"
  to_dir="$(ensure_profile --require "$cli" "$to")"

  # --fresh means: switch tanks but start a NEW conversation — don't carry the old
  # session. The deliberate "different account, clean slate" path, kept distinct
  # from relay's carry so the two intents never get muddled.
  if [ "$want_fresh" -eq 1 ]; then
    log_info "Opening $cli fresh under '$to' (no session carried over)."
    adapter_run "$to_dir" "$@"   # execs
  fi

  # If the adapter knows how to carry session state, let it. It exec's on
  # success; a non-zero return means "couldn't carry over" → fall through to a
  # plain start under <to>.
  if declare -F adapter_relay >/dev/null; then
    # Preview + confirm: show exactly what's about to be carried, where, and what
    # it costs — before anything moves. Skipped with --yes, with no TTY to ask on
    # (automation), or when there's no session to describe.
    if declare -F adapter_session_meta >/dev/null; then
      local meta="" m_sid m_last m_msgs m_title
      meta="$(adapter_session_meta "$from_dir" 2>/dev/null || true)"
      if [ -n "$meta" ]; then
        IFS=$'\037' read -r m_sid m_last m_msgs m_title <<EOF
$meta
EOF
        _relay_preview_card "$cli" "$from" "$to" "$m_sid" "$m_last" "$m_msgs" "$m_title"
        if [ "$assume_yes" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
          local ans=""
          printf '  %bcarry to %s?%b  [%by%b] carry · [%bf%b] fresh · [%bN%b] cancel  ' \
            "$__C_BOLD" "$to" "$__C_RESET" \
            "$__C_GREEN" "$__C_RESET" "$__C_BOLD" "$__C_RESET" "$__C_DIM" "$__C_RESET"
          IFS= read -r ans </dev/tty || ans=""
          printf '\n'
          case "$ans" in
            y|Y|yes|YES) : ;;
            f|F|fresh|FRESH)
              log_info "Opening $cli fresh under '$to' (no session carried over)."
              adapter_run "$to_dir" "$@" ;;   # execs
            *)
              log_dim "Cancelled — nothing carried, no quota spent."
              return 0 ;;
          esac
        fi
      fi
    fi
    log_info "Relaying $cli: $from → $to"
    adapter_relay "$from_dir" "$to_dir" "$@" || true
    log_warn "No session was carried over; starting $cli fresh under '$to'."
  else
    log_info "$cli has no session carry-over; starting fresh under '$to'."
  fi
  adapter_run "$to_dir" "$@"
}
