# shellcheck shell=bash
# lib/commands/resume.sh — `clikae resume [session-id] [-- args]`: reopen a SPECIFIC
# past session by id, wherever it lives.
#
# The problem this solves: clikae gives each tank its own config dir, so a session
# transcript lives under that tank — NOT the engine's default home. So a bare
#   claude --resume <id>
# in a fresh shell fails with "No conversation found": the engine looked in its
# default home and the session is in a tank. clikae knows the tanks, so resume is
# clikae's job. `clikae resume <id>` scans every tank, finds the owner, cd's to the
# directory the session was in, and resumes it under that tank's config — no need
# to know (or type) which tank, and no UUID copy-paste when you run it with no id.
#
# This differs from `to`/`relay`/`continue`, which carry your CURRENT shell's live
# session FORWARD onto another tank. `resume` reaches BACKWARD to a named session.

_resume_help() {
  cat <<'EOF'
Usage: clikae resume [session-id] [-- args...]

Reopen a specific past session by id, in whichever tank owns it — without having
to know which tank that is. Fixes the bare `<engine> --resume <id>` failure: each
clikae tank has its own config dir, so the session isn't in the engine's default
home; clikae finds the tank and resumes it there.

  clikae resume <id>        find the tank holding <id> and resume it
  clikae resume             no id → pick from recent sessions across ALL tanks
                            (by title, newest first — no UUID to copy)
  clikae resume <id> -- -p "…"   forward extra args to the engine after --

clikae cd's to the directory the session was recorded in, so the engine resolves
it in its own project. Only engines that can resume by id (e.g. claude) take part.
EOF
}

# _resume_engines -> the engines whose adapter can resume by id AND look a session
# up by id (defines adapter_resume_args + adapter_find_session). One name per line.
_resume_engines() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    (
      load_adapter "$name" >/dev/null 2>&1 || exit 0
      declare -F adapter_resume_args  >/dev/null 2>&1 || exit 0
      declare -F adapter_find_session >/dev/null 2>&1 || exit 0
      printf '%s\n' "$name"
    )
  done <<EOF
$(list_adapters)
EOF
}

# _resume_locate <sid> -> "engine\ttank\tdir\tpath" for every tank holding <sid>.
# A session id is globally unique, but a relay can copy one into a second tank, so
# more than one line is possible; the caller picks the newest.
_resume_locate() {
  local sid="$1" engine cli profile dir
  while IFS= read -r engine; do
    [ -n "$engine" ] || continue
    while IFS=$'\t' read -r cli profile dir; do
      [ "$cli" = "$engine" ] || continue
      (
        load_adapter "$engine" >/dev/null 2>&1 || exit 0
        local p
        p="$(adapter_find_session "$dir" "$sid" 2>/dev/null || true)"
        [ -n "$p" ] && printf '%s\t%s\t%s\t%s\n' "$engine" "$profile" "$dir" "$p"
      )
    done <<EOF
$(list_all_profiles)
EOF
  done <<EOF
$(_resume_engines)
EOF
}

# _resume_exec <engine> <tank> <dir> <sid> [-- passthru...] — cd into the session's
# recorded directory, then exec the engine's resume under <dir>'s config. Replaces
# the process (never returns on success).
_resume_exec() {
  local engine="$1" tank="$2" dir="$3" sid="$4"; shift 4
  local -a passthru=()
  [ "${1:-}" = "--" ] && { shift; passthru=("$@"); }

  load_adapter "$engine"

  # cd to where the session lived so the engine finds it in its own project.
  local cwd="" found
  found="$(adapter_find_session "$dir" "$sid" 2>/dev/null || true)"
  [ -n "$found" ] && cwd="$(adapter_session_cwd "$found" 2>/dev/null || true)"
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    cd "$cwd" || log_warn "Couldn't cd to $cwd — resuming from $PWD instead."
  elif [ -n "$cwd" ]; then
    log_warn "The session's directory ($cwd) no longer exists — resuming from $PWD."
  fi

  # Build the engine's resume argv (e.g. --resume <sid>), one item per line.
  local -a rargs=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rargs+=("$line")
  done <<EOF
$(adapter_resume_args "$sid")
EOF

  log_ok "Resuming $engine/$tank · session ${sid%%-*}…"
  [ -n "$cwd" ] && log_dim "in $cwd"
  history_log "resume: $engine/$tank ${sid%%-*}"
  adapter_run "$dir" "${rargs[@]}" "${passthru[@]}"
}

# _resume_picker [-- passthru...] — no id given: list recent sessions across all
# tanks (newest first, by title) and resume the chosen one. Interactive.
_resume_picker() {
  local -a passthru=()
  [ "${1:-}" = "--" ] && { shift; passthru=("$@"); }

  # Gather "<epoch>\037<engine>\037<tank>\037<sid>\037<cwd>\037<title>" rows.
  local rows engine cli profile dir
  rows="$(
    while IFS= read -r engine; do
      [ -n "$engine" ] || continue
      while IFS=$'\t' read -r cli profile dir; do
        [ "$cli" = "$engine" ] || continue
        (
          load_adapter "$engine" >/dev/null 2>&1 || exit 0
          declare -F adapter_recent_sessions >/dev/null 2>&1 || exit 0
          local e="$engine" t="$profile"
          adapter_recent_sessions "$dir" 8 | while IFS=$'\037' read -r mt sid scwd title; do
            [ -n "$sid" ] || continue
            printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$mt" "$e" "$t" "$sid" "$scwd" "$title"
          done
        )
      done <<INNER
$(list_all_profiles)
INNER
    done <<OUTER
$(_resume_engines)
OUTER
  )"

  if [ -z "$rows" ]; then
    log_err "No resumable sessions found in any tank."
    log_dim "Resume-capable engines: $(_resume_engines | paste -sd , - | sed 's/,/, /g')"
    exit 1
  fi

  # Sort by epoch desc, keep the newest 12.
  local sorted
  sorted="$(printf '%s\n' "$rows" | sort -t$'\037' -k1,1nr | head -n 12)"

  log_bold "Recent sessions across your tanks:"
  local i=0 mt engine2 tank sid scwd title when
  local -a pick_engine=() pick_tank=() pick_sid=()
  while IFS=$'\037' read -r mt engine2 tank sid scwd title; do
    [ -n "$sid" ] || continue
    i=$((i+1))
    pick_engine+=("$engine2"); pick_tank+=("$tank"); pick_sid+=("$sid")
    when="$(date -r "$mt" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$mt" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
    printf '  %2d) %s/%s · %s\n' "$i" "$engine2" "$tank" "$title"
    log_dim "       $when · ${sid%%-*}… · ${scwd:-?}"
  done <<EOF
$sorted
EOF

  [ "$i" -gt 0 ] || { log_err "No resumable sessions found."; exit 1; }

  printf 'Resume which? [1-%d, or q to quit]: ' "$i" >&2
  local choice; read -r choice
  case "$choice" in
    q|Q|"")  log_dim "Cancelled."; exit 0 ;;
    *[!0-9]*) log_fail "Not a number: $choice" ;;
  esac
  [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ] || log_fail "Out of range: $choice"

  local idx=$((choice-1))
  local e="${pick_engine[$idx]}" t="${pick_tank[$idx]}" s="${pick_sid[$idx]}"
  local d; d="$(profile_dir "$e" "$t")"
  if [ "${#passthru[@]}" -gt 0 ]; then
    _resume_exec "$e" "$t" "$d" "$s" -- "${passthru[@]}"
  else
    _resume_exec "$e" "$t" "$d" "$s"
  fi
}

cmd_resume() {
  local sid=""
  local -a passthru=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) _resume_help; return 0 ;;
      --)        shift; passthru=("$@"); break ;;
      -*)        log_fail "Unknown flag: $1  (clikae resume [session-id] [-- args])" ;;
      *)         [ -z "$sid" ] || log_fail "Too many arguments. Usage: clikae resume [session-id]"
                 sid="$1"; shift ;;
    esac
  done

  # No id → interactive picker across all tanks.
  if [ -z "$sid" ]; then
    if [ "${#passthru[@]}" -gt 0 ]; then _resume_picker -- "${passthru[@]}"; else _resume_picker; fi
    return 0
  fi

  # Locate the session across all tanks.
  local matches
  matches="$(_resume_locate "$sid")"
  local n
  n="$(printf '%s\n' "$matches" | grep -c . || true)"

  if [ "$n" -eq 0 ]; then
    log_err "No session '$sid' in any tank."
    log_dim "Looked across: $(list_all_profiles | awk -F'\t' 'NF>=2{print $1"/"$2}' | paste -sd , - | sed 's/,/, /g')"
    log_dim "Browse recent sessions instead:  clikae resume"
    exit 1
  fi

  local engine tank dir
  if [ "$n" -gt 1 ]; then
    # Same id in multiple tanks (a relay copied it) — pick the most recently used.
    local best="" best_mt=0 e t d p mt
    while IFS=$'\t' read -r e t d p; do
      [ -n "$p" ] || continue
      mt="$(stat -c '%Y' "$p" 2>/dev/null || stat -f '%m' "$p" 2>/dev/null || echo 0)"
      if [ "$mt" -gt "$best_mt" ]; then best_mt="$mt"; best="$e"$'\t'"$t"$'\t'"$d"$'\t'"$p"; fi
    done <<EOF
$matches
EOF
    IFS=$'\t' read -r engine tank dir _ <<EOF
$best
EOF
    log_warn "Session '${sid%%-*}…' exists in more than one tank — resuming the most recent ($engine/$tank)."
  else
    IFS=$'\t' read -r engine tank dir _ <<EOF
$matches
EOF
  fi

  if [ "${#passthru[@]}" -gt 0 ]; then
    _resume_exec "$engine" "$tank" "$dir" "$sid" -- "${passthru[@]}"
  else
    _resume_exec "$engine" "$tank" "$dir" "$sid"
  fi
}
