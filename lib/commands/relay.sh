# shellcheck shell=bash
# lib/commands/relay.sh — `clikae relay <engine> [<from>] <to> [-- args...]`
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

# Generic arrow-key menu drawn on /dev/tty. Args: <title> then one label per
# remaining arg. Echoes the selected index (0-based) and returns 0, or returns 1
# if cancelled — stdout stays clean for the result. Both relay pickers (which
# session, which target) build a parallel value array and map the index back, so
# the terminal handling lives in exactly one place.
_relay_menu() {
  local title="$1"; shift
  local -a opts=("$@")
  local n=${#opts[@]}
  [ "$n" -gt 0 ] || return 1
  # Read-write fd so we can both draw to and read keys from the terminal.
  exec 3<>/dev/tty 2>/dev/null || return 1
  local sel=0 i key rest
  printf '\033[?1049h\033[?25l' >&3
  # shellcheck disable=SC2064
  trap "printf '\033[?25h\033[?1049l' >&3 2>/dev/null; exec 3>&- 2>/dev/null" RETURN
  while :; do
    {
      printf '\033[H\033[2J'
      printf '%b%s%b\n\n' "$__C_BOLD" "$title" "$__C_RESET"
      for ((i = 0; i < n; i++)); do
        if [ "$i" -eq "$sel" ]; then printf '  %b❯ %s%b\n' "$__C_GREEN" "${opts[$i]}" "$__C_RESET"
        else printf '    %b%s%b\n' "$__C_DIM" "${opts[$i]}" "$__C_RESET"; fi
      done
    } >&3
    IFS= read -rsn1 key <&3 || break
    case "$key" in
      $'\e')
        if IFS= read -rsn2 -t 1 rest <&3; then
          case "$rest" in '[A') sel=$(((sel - 1 + n) % n)) ;; '[B') sel=$(((sel + 1) % n)) ;; esac
        else break; fi ;;
      k) sel=$(((sel - 1 + n) % n)) ;;
      j) sel=$(((sel + 1) % n)) ;;
      q) break ;;
      ''|$'\n'|$'\r')
        printf '\033[?25h\033[?1049l' >&3; exec 3>&-; trap - RETURN
        printf '%s\n' "$sel"
        return 0 ;;
    esac
  done
  printf '\033[?25h\033[?1049l' >&3; exec 3>&-; trap - RETURN
  return 1
}

# Chooser for WHICH session to carry — the cure for the home-dir slug ambiguity
# (everything you run from ~ shares one slug, so "newest" is a guess). Lists
# recent sessions under <from_dir>; echoes the chosen session id, or nonzero if
# cancelled.
_relay_pick_session() {
  local from_dir="$1"
  declare -F adapter_list_sessions >/dev/null || return 1
  local rows
  rows="$(adapter_list_sessions "$from_dir" 10 2>/dev/null || true)"
  [ -n "$rows" ] || return 1

  local -a sids=() labels=()
  local sid last msgs title
  while IFS=$'\037' read -r sid last msgs title; do
    [ -n "$sid" ] || continue
    sids+=("$sid")
    labels+=("$(printf '%-44s  %s msgs · %s' "$title" "$msgs" "$last")")
  done <<EOF
$rows
EOF
  [ "${#sids[@]}" -gt 0 ] || return 1
  local idx
  idx="$(_relay_menu "Pick a session to carry   ↑↓ move · ⏎ select · q cancel" "${labels[@]}" || true)"
  [ -n "$idx" ] || return 1
  printf '%s\n' "${sids[$idx]}"
}

# Chooser for the TARGET tank when `clikae relay <engine>` is run without a target —
# so a relay never dead-ends on "missing target", it just asks. Lists the cli's
# other profiles (the source is excluded), annotated with the logged-in account
# when the adapter can tell. Echoes the chosen profile name, or nonzero/cancel.
_relay_pick_target() {
  local cli="$1" from="$2"
  local base="$CLIKAE_HOME/profiles/$cli"
  [ -d "$base" ] || return 1
  local -a names=() labels=()
  local d name lbl
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    [ "$name" = "$from" ] && continue
    lbl=""
    if declare -F adapter_account_label >/dev/null; then
      lbl="$(adapter_account_label "${d%/}" 2>/dev/null || true)"
    fi
    names+=("$name")
    if [ -n "$lbl" ]; then labels+=("$(printf '%-12s %s' "$name" "$lbl")")
    else labels+=("$name"); fi
  done
  [ "${#names[@]}" -gt 0 ] || return 1
  local idx
  idx="$(_relay_menu "Relay $cli from '$from' — pick a target tank   ↑↓ · ⏎ · q cancel" "${labels[@]}" || true)"
  [ -n "$idx" ] || return 1
  printf '%s\n' "${names[$idx]}"
}

cmd_relay() {
  local cli="" from="" to="" got_from=0 assume_yes=0 want_fresh=0 chosen_sid=""
  local -a positionals=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage: clikae relay <engine> [<from>] <to> [-- args...]

Hand the current session over to another tank and continue on its quota —
for when the tank you're on hits its usage limit mid-task.

(Hidden alias — the canonical verb is `clikae to`.) With one tank name, <from> is
auto-detected from the engine's live env var (e.g. $CLAUDE_CONFIG_DIR in this
shell). Give both to be explicit. With no tank at all, you pick the target from
an arrow-key list (a TTY is required; scripts must name the target).

Arguments after `--` are passed straight through to the engine.

For Claude Code, relay copies the *current directory's* most recent transcript
from <from> into <to>, then resumes it — so the conversation continues, but the
new turns burn <to>'s quota. The original session is left intact.

Before anything moves it shows a preview (which session, from ──▶ to, the quota
note) and asks to confirm:  [y] carry · [s] pick another session · [f] fresh ·
[N] cancel.  `s` opens an arrow-key picker of recent sessions — handy when you
work from one directory and several conversations share it.

Options:
  -y, --yes            skip the preview/confirm (also auto-skipped with no TTY)
      --session <id>   carry a specific session instead of the newest
      --fresh          switch tanks but start a NEW conversation (don't carry)

Examples:
  clikae relay claude                # pick the target tank from a list
  clikae relay claude b              # from = whatever this shell is on, to = b
  clikae relay claude a b            # explicit: from a, to b
  clikae relay claude a b --fresh    # open b on a clean slate (no carry)
  clikae relay claude a b -y         # carry the newest, no prompt
  clikae relay claude a b -- --model opus
EOF
        return 0
        ;;
      -y|--yes) assume_yes=1; shift ;;
      --fresh) want_fresh=1; shift ;;
      --session)
        [ $# -ge 2 ] || log_fail "--session needs a session id"
        chosen_sid="$2"; shift 2 ;;
      --) shift; break ;;
      -*) log_fail "Unknown flag: $1" ;;
      *)
        positionals+=("$1")
        shift
        ;;
    esac
  done

  # First positional is always the CLI.
  [ "${#positionals[@]}" -ge 1 ] || log_fail "Missing <engine>. See: clikae relay --help"
  cli="${positionals[0]}"
  validate_name cli "$cli"

  case "${#positionals[@]}" in
    1) to="" ;;   # target omitted — picked interactively below (or errors if no TTY)
    2) to="${positionals[1]}" ;;
    3) from="${positionals[1]}"; to="${positionals[2]}"; got_from=1 ;;
    *) log_fail "Too many arguments. Usage: clikae relay $cli [<from>] <to>" ;;
  esac

  load_adapter "$cli"

  # Auto-detect <from> when not given explicitly: first this shell's live env var,
  # then (the common case — the switch/alias/.app never export it) the tank with
  # this directory's most recent transcript.
  if [ "$got_from" -eq 0 ]; then
    local var strategy value
    var="$(adapter_meta_env_var)"
    strategy="$(adapter_meta_strategy)"
    value="${!var}"
    from="$(resolve_active_profile "$cli" "$strategy" "$value")"
    if [ -n "$from" ]; then
      log_dim "Detected current tank: $from  (\$$var)"
    else
      from="$(newest_transcript_tank "$cli" | cut -f1 || true)"
      if [ -n "$from" ]; then
        log_dim "Detected from this directory's most recent $cli session: $from"
      else
        log_err "Couldn't tell which tank '$cli' is currently on (\$$var is unset, and no $cli session here)."
        log_dim "Name the source explicitly:  clikae relay $cli <from> $to"
        exit 1
      fi
    fi
  fi

  # No target given → ask, rather than dead-ending on an error. Needs a TTY;
  # scripts must still name the target explicitly (preserves the old contract).
  if [ -z "$to" ]; then
    if [ -t 0 ] && [ -t 1 ]; then
      to="$(_relay_pick_target "$cli" "$from" || true)"
      [ -n "$to" ] || { log_dim "Cancelled — no target tank chosen."; return 0; }
    else
      log_fail "Missing target tank. Usage: clikae relay $cli [<from>] <to>"
    fi
  fi

  validate_name profile "$from"
  validate_name profile "$to"
  [ "$from" != "$to" ] || log_fail "Source and target are the same tank ('$from'). Nothing to relay."

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
    # (automation), or when there's no session to describe. The loop lets `s` swap
    # which session is carried (the picker) and redraw without restarting relay.
    if declare -F adapter_session_meta >/dev/null; then
      local meta="" m_sid m_last m_msgs m_title ans="" picked=""
      while :; do
        if [ -n "$chosen_sid" ]; then
          meta="$(adapter_session_meta "$from_dir" "$chosen_sid" 2>/dev/null || true)"
        else
          meta="$(adapter_session_meta "$from_dir" 2>/dev/null || true)"
        fi
        [ -n "$meta" ] || break
        IFS=$'\037' read -r m_sid m_last m_msgs m_title <<EOF
$meta
EOF
        _relay_preview_card "$cli" "$from" "$to" "$m_sid" "$m_last" "$m_msgs" "$m_title"
        # Non-interactive (or --yes): accept the shown session and carry it.
        if [ "$assume_yes" -eq 1 ] || [ ! -t 0 ] || [ ! -t 1 ]; then break; fi
        printf '  %bcarry to %s?%b  [%by%b] carry · [%bs%b] pick · [%bf%b] fresh · [%bN%b] cancel  ' \
          "$__C_BOLD" "$to" "$__C_RESET" \
          "$__C_GREEN" "$__C_RESET" "$__C_BOLD" "$__C_RESET" \
          "$__C_BOLD" "$__C_RESET" "$__C_DIM" "$__C_RESET"
        IFS= read -r ans </dev/tty || ans=""
        printf '\n'
        case "$ans" in
          y|Y|yes|YES) break ;;
          s|S|pick)
            picked="$(_relay_pick_session "$from_dir" || true)"
            [ -n "$picked" ] && chosen_sid="$picked"
            continue ;;
          f|F|fresh|FRESH)
            log_info "Opening $cli fresh under '$to' (no session carried over)."
            adapter_run "$to_dir" "$@" ;;   # execs
          *)
            log_dim "Cancelled — nothing carried, no quota spent."
            return 0 ;;
        esac
      done
    fi
    log_info "Relaying $cli: $from → $to"
    # sid is a UUID (no spaces); the conditional expansion passes --session only
    # when a specific session was chosen, else relay carries the newest.
    # shellcheck disable=SC2086
    adapter_relay "$from_dir" "$to_dir" ${chosen_sid:+--session "$chosen_sid"} "$@" || true
    log_warn "No session was carried over; starting $cli fresh under '$to'."
  else
    log_info "$cli has no session carry-over; starting fresh under '$to'."
  fi
  adapter_run "$to_dir" "$@"
}
