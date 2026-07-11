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

# Sourcing home.sh to reuse its TUI terminal routines and localized translations.
# shellcheck source=home.sh
source "$CLIKAE_LIB/commands/home.sh"

_resume_help() {
  cat <<'EOF'
Usage: clikae resume [session-id | cleanup | ask-tank] [-- args...]

Reopen a specific past session by id, in whichever tank owns it — without having
to know which tank that is. Fixes the bare `<engine> --resume <id>` failure: each
clikae tank has its own config dir, so the session isn't in the engine's default
home; clikae finds the tank and resumes it there.

  clikae resume <id>        find the tank holding <id> and resume it
  clikae resume             no id → pick from recent sessions across ALL tanks
                            (by title, newest first — no UUID to copy). Picking
                            one asks "Resume on which tank?" whenever the engine
                            has more than one; pick a different tank and the
                            session is carried there (a real cross-tank resume,
                            not a fresh start). Press `c` in the picker to jump
                            straight into cleanup (same as `clikae resume cleanup`
                            below).
  clikae resume <id> -- -p "…"   forward extra args to the engine after --
  clikae resume cleanup     clean up old session data to free disk space
                            (runs interactively by default, asks before deleting)
  clikae resume ask-tank [always|dry-only]
                            show or set whether resuming from the home board
                            asks which tank too (default: always — same as the
                            standalone picker above). dry-only asks only when
                            the tank you're resuming is actually dry, the
                            quieter older behavior.

clikae cd's to the directory the session was recorded in, so the engine resolves
it in its own project. Only engines that can resume by id (e.g. claude) take part.
EOF
}

# ── Shared session-row plumbing ─────────────────────────────────────────────
# A picker row packs one session as:  engine ␟ tank ␟ sid ␟ file ␟ mtime.
# _resume_split <row> unpacks it into _rs_engine/_rs_tank/_rs_sid/_rs_f/_rs_mt.
# Six call sites used to hand-roll the same ${row%%$'\x1f'*} chain and could
# drift on field order; this is the one decoder.
_resume_split() {
  local tmp="$1"
  _rs_engine="${tmp%%$'\x1f'*}"; tmp="${tmp#*$'\x1f'}"
  _rs_tank="${tmp%%$'\x1f'*}";   tmp="${tmp#*$'\x1f'}"
  _rs_sid="${tmp%%$'\x1f'*}";    tmp="${tmp#*$'\x1f'}"
  _rs_f="${tmp%%$'\x1f'*}"
  _rs_mt="${tmp##*$'\x1f'}"
}

# _resume_session_fields <path> — derive _rs_engine/_rs_tank/_rs_sid from a raw
# transcript path (…/profiles/<engine>/<tank>/…; each engine encodes the sid in
# its path differently). Shared by the picker's array build and cleanup's
# candidate scan, which used to duplicate the whole chain.
_resume_session_fields() {
  local f="$1" rel rest filename
  rel="${f#*/profiles/}"
  _rs_engine="${rel%%/*}"
  rest="${rel#*/}"
  _rs_tank="${rest%%/*}"
  filename="${f##*/}"
  if [ "$_rs_engine" = "antigravity" ]; then
    _rs_sid="${f%/.system_generated/*}"; _rs_sid="${_rs_sid##*/}"
  elif [ "$_rs_engine" = "codex" ]; then
    _rs_sid="${filename%.jsonl}"; _rs_sid="${_rs_sid##*-}"
  else # claude
    _rs_sid="${filename%.jsonl}"
  fi
}

# _resume_all_sessions — "<mtime> <path>" for EVERY tank's sessions, newest
# first. The ONE home of the three-engine glob list (it appeared verbatim in
# both the picker and cleanup); a new resumable engine's glob goes here only.
_resume_all_sessions() {
  sessions_by_mtime \
    "$CLIKAE_HOME"/profiles/claude/*/projects/*/*.jsonl \
    "$CLIKAE_HOME"/profiles/codex/*/sessions/*/*/*/rollout-*.jsonl \
    "$CLIKAE_HOME"/profiles/antigravity/*/antigravity-cli/brain/*/.system_generated/logs/transcript.jsonl
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
  soul_prelaunch "$engine" "$tank" "$dir"   # member tank → fan this dir into its Soul
  fleet_mcp_prelaunch "$engine" "$tank" "$dir"   # non-solo tank → fan in the shared MCP list
  adapter_run "$dir" "${rargs[@]}" "${passthru[@]}"
}

# Draw the resume menu with row index $1 highlighted, from the inherited
# `filtered`/`sessions` arrays. Split like the home board's draw: the wrapper
# computes the viewport, warms the lazy caches (cache writes must happen in THIS
# process — a $( ) body would lose them), composes the frame via the body, and
# emits it as ONE printf between BSU/ESU. The old per-line printf stream between
# the synchronized-update markers still flickered on terminals that ignore
# ?2026 — the same fix the board's _home_pick_draw documents.
_resume_pick_draw() {
  local sel="$1"
  local n=${#filtered[@]}

  # Viewport from the inherited max_visible, centred on the selection.
  local start_idx=0 end_idx=$(( n - 1 ))
  if [ "$n" -gt "$max_visible" ]; then
    start_idx=$(( sel - (max_visible / 2) ))
    [ "$start_idx" -lt 0 ] && start_idx=0
    end_idx=$(( start_idx + max_visible - 1 ))
    if [ "$end_idx" -ge "$n" ]; then
      end_idx=$(( n - 1 ))
      start_idx=$(( end_idx - max_visible + 1 ))
    fi
  fi

  # Warm the caches for every visible row here, in the parent (the body runs in
  # a command-substitution subshell, where cache writes would evaporate and
  # every frame would re-parse every visible transcript).
  local idx
  for ((idx=start_idx; idx<=end_idx; idx++)); do
    _lazy_parse "${filtered[idx]}"
  done
  _lazy_parse_cwd "${filtered[sel]}"

  local _frame
  _frame="$(_resume_pick_draw_body "$sel" "$start_idx" "$end_idx" "$n")"
  # BSU → whole frame → park the cursor bottom-left → ESU: one write, atomic.
  printf '\033[?2026h%s\033[%d;1H\033[?2026l' "$_frame" "${lines:-24}"
}

_resume_pick_draw_body() {
  local sel="$1" start_idx="$2" end_idx="$3" n="$4"
  local idx s_idx engine tank sid label rage cwd mark rdot active_p
  printf '\033[H\033[K\n'   # home + one blank top-margin line

  printf '  %b%s%b  %b· ↑↓/Tab %s · ⏎ %s · / %s · c %s · q %s%b\033[K\n\n' \
    "$__C_BOLD" "clikae resume" "$__C_RESET" "$__C_DIM" \
    "$T_K_MOVE" "$T_RESUME" "$T_K_FILTER" "$T_K_CLEANUP" "$T_K_QUIT" "$__C_RESET"

  # Top overflow indicator
  if [ "$start_idx" -gt 0 ]; then
    printf '    %b▲ ... %d more sessions above ...%b\033[K\n' "$__C_DIM" "$start_idx" "$__C_RESET"
  fi

  for ((idx=start_idx; idx<=end_idx; idx++)); do
    s_idx="${filtered[idx]}"
    _resume_split "${sessions[s_idx]}"
    engine="$_rs_engine"; tank="$_rs_tank"; sid="$_rs_sid"
    label="${cached_title[s_idx]}"
    rage="${cached_age[s_idx]}"

    if [ "$idx" -eq "$sel" ]; then mark="${__C_GREEN}❯${__C_RESET}"; else mark=" "; fi

    active_p=""
    if [ "$engine" = "claude" ]; then active_p="$active_claude"
    elif [ "$engine" = "codex" ]; then active_p="$active_codex"
    elif [ "$engine" = "antigravity" ]; then active_p="$active_antigravity"
    fi
    if [ "$tank" = "$active_p" ]; then rdot="${__C_GREEN}●${__C_RESET}"; else rdot="${__C_DIM}○${__C_RESET}"; fi

    # Same columns as the home board — dot · name · engine — then the title and age.
    local _rnm _ren; _rnm="$(_home_lpad "$tank" 7)"; _ren="$(_home_lpad "$(_home_engine_label "$engine")" 8)"
    if [ "$idx" -eq "$sel" ]; then
      cwd="${cached_cwd[s_idx]}"
      printf '    %b %b %b%s%b %b%s%b %b"%s"%b  %b(%s)%b\033[K\n' "$mark" "$rdot" "$__C_BOLD" "$_rnm" "$__C_RESET" "$__C_DIM" "$_ren" "$__C_RESET" "$__C_DIM" "$(_home_trunc "$label" 56)" "$__C_RESET" "$__C_DIM" "$rage" "$__C_RESET"
      printf '          %bdir: %s · id: %s · %s%b\033[K\n' "$__C_DIM" "${cwd:-?}" "$sid" "$T_ENTER_RESUME" "$__C_RESET"
    else
      printf '    %b %b %s %b%s%b %b"%s"%b  %b(%s)%b\033[K\n' "$mark" "$rdot" "$_rnm" "$__C_DIM" "$_ren" "$__C_RESET" "$__C_DIM" "$(_home_trunc "$label" 56)" "$__C_RESET" "$__C_DIM" "$rage" "$__C_RESET"
    fi
  done

  # Bottom overflow indicator
  if [ "$end_idx" -lt $(( n - 1 )) ]; then
    printf '    %b▼ ... %d more sessions below ...%b\033[K\n' "$__C_DIM" "$(( n - 1 - end_idx ))" "$__C_RESET"
  fi

  printf '\033[J'   # erase any leftover lines from a taller previous frame
}

_lazy_parse() {
  local idx="$1"
  [ -n "${cached_title[idx]}" ] && return 0

  _resume_split "${sessions[idx]}"
  local engine="$_rs_engine" f="$_rs_f" mt="$_rs_mt"

  load_adapter "$engine" >/dev/null 2>&1 || true

  # One extractor per engine, owned by the adapter (adapter_title_for_file) —
  # this used to re-implement claude's and antigravity's parsing inline, and the
  # antigravity copy had drifted (it skipped the whitespace collapse, so the
  # picker titled a session differently than the home board did).
  local stitle=""
  if declare -F adapter_title_for_file >/dev/null 2>&1; then
    stitle="$(adapter_title_for_file "$f" 2>/dev/null || true)"
  fi

  [ -n "$stitle" ] || stitle="(no preview)"
  cached_title[idx]="$stitle"

  cached_age[idx]="$(_human_age "$mt")"
}

_lazy_parse_cwd() {
  local idx="$1"
  [ -n "${cached_cwd[idx]}" ] && return 0

  _resume_split "${sessions[idx]}"
  local engine="$_rs_engine" sid="$_rs_sid" f="$_rs_f"

  load_adapter "$engine" >/dev/null 2>&1 || true

  local scwd=""
  if [ "$engine" = "claude" ]; then
    scwd="$(adapter_session_cwd "$f" 2>/dev/null || true)"
  elif [ "$engine" = "codex" ]; then
    scwd="$(_codex_meta_field "$f" cwd)"
  elif [ "$engine" = "antigravity" ]; then
    local bdir; bdir="$(dirname "$(dirname "$(dirname "$(dirname "$f")")")")"
    scwd="$(grep -F "$sid" "$bdir/history.jsonl" 2>/dev/null \
      | grep -oE '"workspace"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 \
      | sed -E 's/^"workspace"[[:space:]]*:[[:space:]]*"//; s/"$//' || true)"
    [ -n "$scwd" ] || scwd="$HOME"
  fi
  [ -n "$scwd" ] || scwd="?"
  cached_cwd[idx]="$scwd"
}

_resume_pick() {
  local -a passthru=()
  [ "${1:-}" = "--" ] && { shift; passthru=("$@"); }

  trap '_home_tty_leave' EXIT
  trap '_home_tty_leave; exit 130' INT TERM
  stty -echo 2>/dev/null || true # Permanent no-echo for TUI
  printf '\033[?1049h\033[?25l'
  # Read keys from a DEDICATED /dev/tty fd (like _home_pick/_home_choose), never
  # bare stdin. The board draws escape sequences to stdout; on stdin those can come
  # back as stray bytes that a bare read would treat as keystrokes (the old `-t 0`
  # drain did exactly this — it silently swallowed a digit/letter that reset `sel`,
  # so paging "didn't work"). fd 3 isolates input from that feedback.
  exec 3</dev/tty 2>/dev/null || exec 3<&0

  # Query terminal size ONCE at startup to avoid TTY driver ioctl overhead during scrolling
  local lsz lines max_visible=15
  lsz="$( { stty size </dev/tty; } 2>/dev/null || true )"
  if [ -n "$lsz" ]; then
    lines="${lsz%% *}"
    max_visible=$(( lines - 7 ))
    [ "$max_visible" -lt 5 ] && max_visible=5
  fi

  local exit_loop=0 trigger_filter=0 trigger_select=0 trigger_cleanup=0

  # Keys arrive pre-decoded by tui_read_key (lib/core/tui.sh) as symbolic names
  # — the byte-level ESC state machine that used to live here (and regressed
  # twice in dogfood) is now the shared, unit-tested kernel.
  _handle_key() {
    case "$1" in
      up|k|shift-tab)   sel=$(( (sel - 1 + n) % n )) ;;
      down|j|tab)       sel=$(( (sel + 1) % n )) ;;
      left|pgup)        sel=$(( sel - max_visible )); [ "$sel" -lt 0 ] && sel=0 ;;
      right|pgdn)       sel=$(( sel + max_visible )); [ "$sel" -ge "$n" ] && sel=$(( n - 1 )) ;;
      home|g)           sel=0 ;;
      end|G)            sel=$(( n - 1 )) ;;
      [1-9])            sel=$(( $1 - 1 )); [ "$sel" -ge "$n" ] && sel=$(( n - 1 )) ;;
      q|esc)            exit_loop=1 ;;
      /)                trigger_filter=1 ;;
      c)                trigger_cleanup=1 ;;
      enter)            trigger_select=1 ;;
    esac
    # MUST end with success: a branch whose last command is `[ cond ] && assign`
    # (the paging clamps) returns non-zero when cond is false; called bare under
    # `set -eo pipefail`, that leak crashed the picker (dogfood 2026-06-29).
    return 0
  }

  local sel=0 n filter="" i last_filter="--initial--"
  while :; do
    if [ "$filter" != "$last_filter" ]; then
      local -a filtered=()
      for ((i=0; i<${#sessions[@]}; i++)); do
        if [ -n "$filter" ]; then
          _lazy_parse "$i"
          _resume_split "${sessions[i]}"
          local title="${cached_title[i]}"
          shopt -s nocasematch
          if [[ "$_rs_engine/$_rs_tank $title" == *"$filter"* ]]; then
            filtered+=("$i")
          fi
          shopt -u nocasematch
        else
          filtered+=("$i")
        fi
      done
      last_filter="$filter"
      sel=0
    fi

    n=${#filtered[@]}
    if [ "$n" -le 0 ]; then
      printf '\033[H\033[2J  %b%s%b  %b(/ %s · q %s)%b\n' \
        "$__C_DIM" "$T_FILTER_NONE" "$__C_RESET" "$__C_DIM" "$T_K_FILTER" "$T_K_QUIT" "$__C_RESET"
      tui_read_key 3 || TUI_KEY="q"
      case "$TUI_KEY" in
        /) _home_tty_leave; printf '%b%s%b' "$__C_BOLD" "$T_FILTER_PROMPT" "$__C_RESET"
           IFS= read -r filter <&3 || filter=""
           stty -echo 2>/dev/null || true
           printf '\033[?1049h\033[?25l'; sel=0; continue ;;
        *) [ -n "$filter" ] && { filter=""; sel=0; continue; }; break ;;
      esac
    fi

    [ "$sel" -ge "$n" ] && sel=$((n - 1))
    [ "$sel" -lt 0 ] && sel=0
    _resume_pick_draw "$sel"

    # Block-read ONE decoded key from the dedicated tty fd, handle it, redraw.
    # (No `-t 0` typeahead drain — see tui.sh's decode notes for the history.)
    tui_read_key 3 || TUI_KEY="q"
    [ -n "${CLIKAE_RESUME_DEBUG:-}" ] && \
      printf 'READ key=%q sel(before)=%s n=%s max_visible=%s\n' "$TUI_KEY" "$sel" "$n" "$max_visible" >> "$CLIKAE_RESUME_DEBUG" 2>/dev/null

    exit_loop=0
    trigger_filter=0
    trigger_select=0
    trigger_cleanup=0

    _handle_key "$TUI_KEY"
    [ -n "${CLIKAE_RESUME_DEBUG:-}" ] && \
      printf '  -> sel(after)=%s exit=%s filt=%s sel_trig=%s\n' "$sel" "$exit_loop" "$trigger_filter" "$trigger_select" >> "$CLIKAE_RESUME_DEBUG" 2>/dev/null

    if [ "$exit_loop" -eq 1 ]; then
      break
    fi

    if [ "$trigger_cleanup" -eq 1 ]; then
      # Cleanup deletes session files the picker has already cached — don't try to
      # resume the TUI afterward with a now-stale `sessions` array; drop to the
      # normal screen, run the same interactive flow as `clikae resume cleanup`,
      # and return to the shell (matches the trigger_select exit pattern below).
      exec 3>&- 2>/dev/null || true
      _home_tty_leave; trap - EXIT INT TERM
      echo
      _resume_cleanup
      unset -f _handle_key
      return 0
    fi

    if [ "$trigger_filter" -eq 1 ]; then
      _home_tty_leave
      printf '%b%s%b' "$__C_BOLD" "$T_FILTER_PROMPT" "$__C_RESET"
      IFS= read -r filter <&3 || filter=""
      stty -echo 2>/dev/null || true
      printf '\033[?1049h\033[?25l'; sel=0
      # Reset filter cache to re-trigger scan
      last_filter="--initial--"
      continue
    fi

    if [ "$trigger_select" -eq 1 ]; then
      _resume_split "${sessions[${filtered[sel]}]}"
      # Plain copies: the block below crosses other function calls, so don't
      # lean on the shared _rs_* slots staying untouched. (The transcript-path
      # field isn't needed here; _resume_exec and the cross-tank copy below
      # re-derive it via adapter_find_session.)
      local sel_engine="$_rs_engine" sel_tank="$_rs_tank" sel_sid="$_rs_sid"

      _home_tty_leave; trap - EXIT INT TERM
      local cands target_tank cand_n
      cands="$(list_all_profiles | awk -F'\t' -v c="$sel_engine" '$1==c{print $2}')"
      cand_n="$(printf '%s\n' "$cands" | grep -c . || true)"
      if [ "$cand_n" -gt 1 ]; then
        target_tank="$(_home_choose "$T_RESUME_WHICH_TANK" "$cands" "$sel_tank")" || {
          trap '_home_tty_leave' EXIT; trap '_home_tty_leave; exit 130' INT TERM
          stty -echo 2>/dev/null || true
          printf '\033[?1049h\033[?25l'; continue
        }
      else
        target_tank="$sel_tank"
      fi

      local d; d="$(profile_dir "$sel_engine" "$target_tank")"
      if [ "$target_tank" != "$sel_tank" ]; then
        _resume_carry_session "$sel_engine" "$sel_tank" "$target_tank" "$sel_sid"
      fi

      exec 3>&- 2>/dev/null || true   # don't leak the tty fd into the resumed engine
      if [ "${#passthru[@]}" -gt 0 ]; then
        _resume_exec "$sel_engine" "$target_tank" "$d" "$sel_sid" -- "${passthru[@]}"
      else
        _resume_exec "$sel_engine" "$target_tank" "$d" "$sel_sid"
      fi
      unset -f _handle_key
      return 0
    fi
  done
  exec 3>&- 2>/dev/null || true
  unset -f _handle_key
}

_resume_picker() {
  _home_tty_leave; trap - EXIT INT TERM
  local -a passthru=()
  [ "${1:-}" = "--" ] && { shift; passthru=("$@"); }

  # Cache active profiles once at startup with pure Bash / minimal readlink (1 process total)
  local active_claude="" active_codex="" active_antigravity=""
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [[ "$CLAUDE_CONFIG_DIR" == "$CLIKAE_HOME/profiles/claude/"* ]]; then
    local suffix="${CLAUDE_CONFIG_DIR#$CLIKAE_HOME/profiles/claude/}"
    active_claude="${suffix%%/*}"
  fi
  if [ -n "${CODEX_HOME:-}" ] && [[ "$CODEX_HOME" == "$CLIKAE_HOME/profiles/codex/"* ]]; then
    local suffix="${CODEX_HOME#$CLIKAE_HOME/profiles/codex/}"
    active_codex="${suffix%%/*}"
  fi
  local link="$HOME/.gemini" target
  if [ -L "$link" ]; then
    target="$(readlink "$link" 2>/dev/null || true)"
    local slots="$CLIKAE_HOME/profiles/antigravity"
    if [[ "$target" == "$slots/"* ]]; then
      active_antigravity="${target#$slots/}"
      active_antigravity="${active_antigravity%%/*}"
    fi
  fi

  # 1. Scan + sort ALL tanks' sessions by recency in ~2 processes (sessions_by_mtime,
  #    the shared kernel; ~30ms for 500+ files). all-dirs scope = bare project globs.
  local files
  files="$(_resume_all_sessions)"

  if [ -z "$files" ]; then
    log_err "No resumable sessions found in any tank."
    log_dim "Resume-capable engines: $(_resume_engines | paste -sd , - | sed 's/,/, /g')"
    exit 1
  fi

  # 2. Build indexed array in Bash (zero process spawn)
  local -a sessions=()
  local -a cached_title=()
  local -a cached_age=()
  local -a cached_cwd=()

  local mt f
  while read -r mt f; do
    [ -n "$f" ] || continue
    _resume_session_fields "$f"
    sessions+=("$_rs_engine"$'\x1f'"$_rs_tank"$'\x1f'"$_rs_sid"$'\x1f'"$f"$'\x1f'"$mt")
  done <<EOF
$files
EOF

  if [ "${#sessions[@]}" -eq 0 ]; then
    log_err "No resumable sessions found in any tank."
    exit 1
  fi

  if [ ! -t 0 ] || [ ! -t 1 ] || [ -n "${CLIKAE_NO_INTERACTIVE:-}" ]; then
    log_bold "Recent sessions across your tanks (showing top 50):"
    local idx=0 limit=50 engine_t tank_t sid_t label_t rage_t cwd_t
    [ "${#sessions[@]}" -lt "$limit" ] && limit=${#sessions[@]}
    for ((idx=0; idx<limit; idx++)); do
      _lazy_parse "$idx"
      _resume_split "${sessions[idx]}"
      engine_t="$_rs_engine"; tank_t="$_rs_tank"; sid_t="$_rs_sid"
      label_t="${cached_title[idx]}"
      rage_t="${cached_age[idx]}"
      _lazy_parse_cwd "$idx"
      cwd_t="${cached_cwd[idx]}"
      printf '  %2d) %s/%s · "%s" (%s)\n' "$((idx+1))" "$engine_t" "$tank_t" "$label_t" "$rage_t"
      # Non-interactive list is for scripting/copy-paste — surface the id so it's
      # actionable (`clikae resume <id>`); there's no cursor to select a row here.
      log_dim "       id: $sid_t · dir: ${cwd_t:-?}"
    done
    return 0
  fi

  if [ "${#passthru[@]}" -gt 0 ]; then
    _resume_pick "${passthru[@]}"
  else
    _resume_pick
  fi
}

# _batch_du_kb <path>... — print one "<kb>" line PER ARGUMENT, in argument order
# (0 for a missing path). ONE `du -sk` over everything (chunked for argv limits)
# instead of a `du | awk` pair per path: the per-path form made `resume cleanup`
# fork-bound (~7s on a 2300-session store; sys time dominated). du emits existing
# args in the order given on both BSD and GNU, so filtering to existing paths
# first keeps the output aligned with the input.
_batch_du_kb() {
  local -a ex=() exidx=() out=()
  local i=0 p n=$#
  for p in "$@"; do
    out[i]=0
    if [ -e "$p" ]; then ex+=("$p"); exidx+=("$i"); fi
    i=$((i+1))
  done
  local j=0 start kb rest
  for ((start=0; start<${#ex[@]}; start+=1000)); do
    while IFS=$'\t' read -r kb rest; do
      [ -n "$kb" ] || continue
      # Re-attach by PATH, not by blind position: a file deleted between our -e
      # check and the du exec (live stores rotate mid-scan) gets NO output line,
      # and a positional pointer would shift every later size onto the wrong
      # candidate — wrong numbers on a delete-confirmation screen (caught by the
      # 2026-07-11 ephemeral red-team review). Skip forward past vanished paths
      # (their size stays 0) until this line's path matches.
      while [ "$j" -lt "${#ex[@]}" ] && [ "$rest" != "${ex[j]}" ]; do
        j=$((j+1))
      done
      [ "$j" -lt "${#ex[@]}" ] || break
      out[${exidx[j]}]="$kb"
      j=$((j+1))
    done <<EOF
$(du -sk "${ex[@]:start:1000}" 2>/dev/null || true)
EOF
  done
  [ "$n" -gt 0 ] && printf '%s\n' "${out[@]}"
  return 0
}

# _kb_human <kb> — "512 KB" / "1.5 MB" / "2.32 GB", pure bash (no awk fork; the
# per-row awk added one fork per listed candidate).
_kb_human() {
  local kb="$1" v
  if [ "$kb" -lt 1024 ]; then
    printf '%d KB' "$kb"
  elif [ "$kb" -lt 1048576 ]; then
    v=$(( (kb * 10 + 512) / 1024 ))
    printf '%d.%d MB' $((v / 10)) $((v % 10))
  else
    v=$(( (kb * 100 + 524288) / 1048576 ))
    printf '%d.%02d GB' $((v / 100)) $((v % 100))
  fi
}

_resume_cleanup_help() {
  cat <<'EOF'
Usage: clikae resume cleanup [options]

Delete old session data files (transcripts, databases, brain assets) to free disk space.
This only deletes session history files. It never deletes tank configurations, memory files,
caches, or settings.

Besides the age/size filters, every run also offers two kinds of pure waste:

  - stale copies: `clikae to`/relay and a cross-tank resume COPY the session into
    the target tank and leave the source behind. Copies of the same session are
    grouped across all tanks and project dirs, the LARGEST copy is kept, and a
    copy is offered only when it is provably contained in the kept one (an exact
    byte prefix, or a tail of session-metadata lines only). A copy with unique
    conversation content is listed as "diverged — not auto-selected" and starts
    unchecked; sessions with a live process are skipped entirely.
  - orphaned subagent data: claude keeps a sibling `<session-id>/` directory next
    to each transcript (subagent/workflow transcripts). Orphans — a sid directory
    whose transcript is already gone — are offered for deletion, and cleaning a
    transcript now removes its sibling directory too.

The preview is a checkbox list, biggest first: arrows move, space toggles a row,
`a` toggles all, Enter proceeds to the final confirmation, q/ESC cancels.

Options:
  -d, --dry-run             Preview what will be deleted and how much space freed, without deleting.
  -o, --older-than <days>   Only target sessions older than <days> (default: 30).
  -m, --min-size <MB>       Only target sessions of at least <MB> MB. Given alone, size is the
                            only filter (no age cutoff); combine with --older-than to require
                            both. Stale copies and orphans ignore both filters.
  -h, --help                Show this help message.

Examples:
  clikae resume cleanup
  clikae resume cleanup --older-than 7
  clikae resume cleanup --min-size 5
  clikae resume cleanup --min-size 5 --older-than 30
  clikae resume cleanup --dry-run
EOF
}

# _file_bytes <path> — the file's exact byte size (0 if missing). du prices
# candidates for the preview, but picking WHICH copy of a duplicated session to
# keep needs exact bytes, not blocks: the kept copy must be the byte-superset.
_file_bytes() {
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null || echo 0
  return 0
}

# _resume_stale_copy_check <kept> <candidate> — is <candidate> safe to delete
# given <kept> survives? Safe means no conversation content exists only in the
# candidate, verified on BYTES (never mtime — on a real store the newest copy was
# NOT always the byte-superset; one group's older copy was 552 B larger):
#   1. the candidate is an exact byte-prefix of <kept> (a relay copy never
#      touched again), or
#   2. it diverges only within its last 4096 bytes AND every candidate line from
#      the divergence on is a session-metadata line (types mode / permission-mode
#      / ai-title / last-prompt / agent-name / pr-link / summary) — the metadata
#      write-back an engine does on open, no conversation content.
# The prefix test is `head -c | cmp`, NEVER `cmp -n`: BSD `cmp -s -n <sz>` exits
# 1 ("EOF") when the second file is exactly <sz> bytes, so every byte-identical
# copy would read as diverged.
_resume_stale_copy_check() {
  local kept="$1" cand="$2" csz ksz
  csz="$(_file_bytes "$cand")"; ksz="$(_file_bytes "$kept")"
  [ "$csz" -le "$ksz" ] || return 1
  [ "$csz" -gt 0 ] || return 0
  if head -c "$csz" "$kept" 2>/dev/null | cmp -s - "$cand" 2>/dev/null; then
    return 0
  fi
  # Not a clean prefix — locate the divergence. cmp reports the first differing
  # byte and line as "differ: char N, line L" (GNU may say "byte" for N).
  local report off line
  report="$(LC_ALL=C cmp "$kept" "$cand" 2>/dev/null || true)"
  off="$(printf '%s\n' "$report" | awk '{for(i=1;i<NF;i++) if($i=="char"||$i=="byte"){gsub(/,/,"",$(i+1)); print $(i+1); exit}}')"
  line="$(printf '%s\n' "$report" | awk '{for(i=1;i<NF;i++) if($i=="line"){gsub(/,/,"",$(i+1)); print $(i+1); exit}}')"
  case "$off" in ''|*[!0-9]*) return 1 ;; esac
  case "$line" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( csz - (off - 1) )) -le 4096 ] || return 1
  # Every candidate line from the first differing one must be metadata-only.
  tail -n +"$line" "$cand" 2>/dev/null | LC_ALL=C awk '
    /^[[:space:]]*$/ { next }
    $0 !~ /"type"[[:space:]]*:[[:space:]]*"(mode|permission-mode|ai-title|last-prompt|agent-name|pr-link|summary)"/ { exit 1 }
  '
}

# _resume_cleanup_add_candidate <file> <mtime> <class> <label> — push one row
# onto the caller's parallel cand_* arrays (bash-3.2 dynamic scoping;
# _resume_cleanup owns the arrays). Owns the per-engine map of "what does
# deleting this session mean", including claude's sibling `<sid>/` directory
# (subagent/workflow transcripts) — the old cleanup deleted only the transcript
# and leaked those directories. Sizing is deferred: paths pile up in sz_paths and
# ONE batched du prices them after the scan. Titles are deferred too (filled only
# for rows that survive the filters) — a --min-size scan visits EVERY session,
# and a title parse per session would make the loop fork-bound again.
_resume_cleanup_add_candidate() {
  local f="$1" mt="$2" cls="$3" lbl="$4"
  local files_to_del brain_part conversations_dir db_file sdir checked=1
  _resume_session_fields "$f"
  if [ "$_rs_engine" = "antigravity" ]; then
    brain_part="${f%/.system_generated/*}"
    conversations_dir="${brain_part%/brain/*}/conversations"
    db_file="$conversations_dir/$_rs_sid.db"
    sz_paths+=("$brain_part" "$db_file"); cand_nsz+=(2)
    files_to_del="$brain_part;$db_file;$db_file-shm;$db_file-wal"
  elif [ "$_rs_engine" = "claude" ] && [ -d "${f%.jsonl}" ]; then
    sdir="${f%.jsonl}"   # the sibling sid dir travels (and is priced) with its transcript
    sz_paths+=("$f" "$sdir"); cand_nsz+=(2)
    files_to_del="$f;$sdir"
  else # codex / claude without a sid dir: the transcript file is the session
    sz_paths+=("$f"); cand_nsz+=(1)
    files_to_del="$f"
  fi
  [ "$cls" = "diverged" ] && checked=0
  candidates+=("$f")
  cand_engine+=("$_rs_engine")
  cand_tank+=("$_rs_tank")
  cand_sid+=("$_rs_sid")
  cand_title+=("")
  cand_age_str+=("$(( (now - mt) / 86400 ))d ago")
  cand_files_to_delete+=("$files_to_del")
  cand_class+=("$cls")
  cand_label+=("$lbl")
  cand_checked+=("$checked")
  return 0
}

# _resume_cleanup_dedupe_flush — close out one (engine, session) group of the
# dedupe walk (g_engine/g_sid/g_f/g_mt, dynamically scoped from _resume_cleanup).
# With two or more copies of one session, keep the LARGEST (see
# _resume_stale_copy_check on why not the newest) and offer every copy the safety
# check proves redundant. A copy that fails the check is surfaced as "diverged"
# instead of being silently skipped — or worse, silently deleted.
_resume_cleanup_dedupe_flush() {
  if [ "${#g_f[@]}" -lt 2 ]; then return 0; fi
  # Never dedupe under a live session: if any process still carries this sid
  # (e.g. a `--resume <sid>` in another terminal), the session may be mid-write.
  # Same best-effort ps read as lib/core/proc.sh, snapshotted once per cleanup.
  local live_sid="$g_sid"
  if [ "$g_engine" = "codex" ] && [ "${#g_sid}" -gt 36 ]; then
    live_sid="${g_sid:$(( ${#g_sid} - 36 ))}"   # rollout-<ts>-<uuid> → the uuid
  fi
  case "$live_procs" in *"$live_sid"*) return 0 ;; esac

  local i kept=0 kept_sz sz kept_tank
  kept_sz="$(_file_bytes "${g_f[0]}")"
  for ((i=1; i<${#g_f[@]}; i++)); do
    sz="$(_file_bytes "${g_f[i]}")"
    # Strictly greater: g_f is sorted newest first, so a size tie keeps the
    # newest copy (a deterministic, least-surprising tie-break).
    if [ "$sz" -gt "$kept_sz" ]; then kept="$i"; kept_sz="$sz"; fi
  done
  _resume_session_fields "${g_f[kept]}"
  kept_tank="$_rs_tank"
  for ((i=0; i<${#g_f[@]}; i++)); do
    if [ "$i" -eq "$kept" ]; then continue; fi
    if _resume_stale_copy_check "${g_f[kept]}" "${g_f[i]}"; then
      _resume_cleanup_add_candidate "${g_f[i]}" "${g_mt[i]}" stale "stale copy (kept: $kept_tank)"
    else
      _resume_cleanup_add_candidate "${g_f[i]}" "${g_mt[i]}" diverged "diverged — not auto-selected"
    fi
    dedupe_claimed="$dedupe_claimed"$'\n'"${g_f[i]}"
  done
  return 0
}

# _resume_cleanup_scan_orphans — claude sid dirs whose transcript is already
# gone. Cleanup used to delete only `<sid>.jsonl` and leave the sibling `<sid>/`
# directory of subagent/workflow transcripts behind; a sid dir with no matching
# top-level transcript in the same project dir is pure waste.
_resume_cleanup_scan_orphans() {
  local d base mt
  for d in "$CLIKAE_HOME"/profiles/claude/*/projects/*/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    base="${d##*/}"
    case "$base" in
      ????????-????-????-????-????????????) ;;   # uuid-shaped sid dirs only
      *) continue ;;
    esac
    [ -f "$d.jsonl" ] && continue
    mt="$(stat -c '%Y' "$d" 2>/dev/null || stat -f '%m' "$d" 2>/dev/null || echo 0)"
    _resume_session_fields "$d"    # engine/tank from the path; sid = the dir name
    sz_paths+=("$d"); cand_nsz+=(1)
    candidates+=("$d")
    cand_engine+=("$_rs_engine")
    cand_tank+=("$_rs_tank")
    cand_sid+=("$_rs_sid")
    cand_title+=("(no transcript)")
    cand_age_str+=("$(( (now - mt) / 86400 ))d ago")
    cand_files_to_delete+=("$d")
    cand_class+=(orphan)
    cand_label+=("orphaned subagent data")
    cand_checked+=(1)
  done
  return 0
}

# _resume_cleanup_tally — recount the checked set (dynamically scoped ord/cand_*
# from _resume_cleanup) into sel_n / sel_kb / unsel_n. Called once for the static
# preview and again after the interactive picker, so the confirm and the final
# "freed" number always describe what is actually selected.
_resume_cleanup_tally() {
  sel_n=0; sel_kb=0; unsel_n=0
  local i idx
  for ((i=0; i<${#ord[@]}; i++)); do
    idx="${ord[i]}"
    if [ "${cand_checked[idx]}" -eq 1 ]; then
      sel_n=$((sel_n + 1)); sel_kb=$((sel_kb + ${cand_size_kb[idx]}))
    else
      unsel_n=$((unsel_n + 1))
    fi
  done
  return 0
}

# _resume_cleanup_print_list — the non-interactive preview (--dry-run and the
# no-TTY refusal path): the same rows the checkbox picker shows, biggest first,
# each with its default selection state.
_resume_cleanup_print_list() {
  local i idx box lbl
  for ((i=0; i<${#ord[@]}; i++)); do
    idx="${ord[i]}"
    if [ "${cand_checked[idx]}" -eq 1 ]; then box="x"; else box=" "; fi
    lbl=""
    [ -n "${cand_label[idx]}" ] && lbl=" · ${cand_label[idx]}"
    printf "  [%s] %b%s/%s%b · %s · %s · %b(%s)%b%b%s%b\n" \
      "$box" \
      "$__C_BOLD" "${cand_engine[idx]}" "${cand_tank[idx]}" "$__C_RESET" \
      "\"$(_home_trunc "${cand_title[idx]}" 40)\"" \
      "${cand_age_str[idx]}" \
      "$__C_DIM" "$(_kb_human "${cand_size_kb[idx]}")" "$__C_RESET" \
      "$__C_DIM" "$lbl" "$__C_RESET"
  done
  return 0
}

# One frame of the checkbox picker (viewport + header tally), composed in a
# command substitution and emitted by the caller as ONE printf between BSU/ESU —
# the same anti-flicker split _resume_pick_draw documents.
_resume_cleanup_select_body() {
  local sel="$1" n="$2" max_visible="$3"
  local start_idx=0 end_idx=$(( n - 1 ))
  if [ "$n" -gt "$max_visible" ]; then
    start_idx=$(( sel - (max_visible / 2) ))
    [ "$start_idx" -lt 0 ] && start_idx=0
    end_idx=$(( start_idx + max_visible - 1 ))
    if [ "$end_idx" -ge "$n" ]; then
      end_idx=$(( n - 1 ))
      start_idx=$(( end_idx - max_visible + 1 ))
    fi
  fi

  local sel_n=0 sel_kb=0 unsel_n=0
  _resume_cleanup_tally

  printf '\033[H\033[K\n'   # home + one blank top-margin line
  printf '  %b%s%b  %b· ↑↓ move · space toggle · a all · ⏎ delete selected · q cancel%b\033[K\n' \
    "$__C_BOLD" "clikae resume cleanup" "$__C_RESET" "$__C_DIM" "$__C_RESET"
  printf '  %bselected: %d of %d · %s to free%b\033[K\n\n' \
    "$__C_DIM" "$sel_n" "$n" "$(_kb_human "$sel_kb")" "$__C_RESET"

  if [ "$start_idx" -gt 0 ]; then
    printf '    %b▲ ... %d more above ...%b\033[K\n' "$__C_DIM" "$start_idx" "$__C_RESET"
  fi
  local i idx mark box lbl row
  for ((i=start_idx; i<=end_idx; i++)); do
    idx="${ord[i]}"
    if [ "$i" -eq "$sel" ]; then mark="${__C_GREEN}❯${__C_RESET}"; else mark=" "; fi
    if [ "${cand_checked[idx]}" -eq 1 ]; then box="[x]"; else box="[ ]"; fi
    lbl=""
    [ -n "${cand_label[idx]}" ] && lbl=" · ${cand_label[idx]}"
    row="$(printf '%s · "%s" · %s · (%s)%s' \
      "$(_home_lpad "${cand_engine[idx]}/${cand_tank[idx]}" 16)" \
      "$(_home_trunc "${cand_title[idx]}" 36)" \
      "${cand_age_str[idx]}" "$(_kb_human "${cand_size_kb[idx]}")" "$lbl")"
    if [ "$i" -eq "$sel" ]; then
      printf '    %b %s %b%s%b\033[K\n' "$mark" "$box" "$__C_BOLD" "$row" "$__C_RESET"
    else
      printf '    %b %s %b%s%b\033[K\n' "$mark" "$box" "$__C_DIM" "$row" "$__C_RESET"
    fi
  done
  if [ "$end_idx" -lt $(( n - 1 )) ]; then
    printf '    %b▼ ... %d more below ...%b\033[K\n' "$__C_DIM" "$(( n - 1 - end_idx ))" "$__C_RESET"
  fi
  printf '\033[J'   # erase any leftover lines from a taller previous frame
  return 0
}

# _resume_cleanup_select — the checkbox picker over the ord/cand_* arrays:
# arrows/j/k move (PgUp/PgDn/Home/End page), space toggles a row, `a` toggles
# everything, Enter hands the checked set to the caller's red confirm, q/ESC
# cancels. Same /dev/tty isolation + tui_read_key decode as _resume_pick and
# _relay_menu. Returns 0 to proceed, 1 on cancel, 2 when no TTY could be opened
# (the caller falls back to the printed list + all-or-nothing confirm).
_resume_cleanup_select() {
  exec 3<>/dev/tty 2>/dev/null || return 2
  stty -echo 2>/dev/null || true
  printf '\033[?1049h\033[?25l' >&3
  trap '_home_tty_leave' EXIT
  trap '_home_tty_leave; exit 130' INT TERM

  local lsz lines=24 max_visible=15
  lsz="$( { stty size </dev/tty; } 2>/dev/null || true )"
  if [ -n "$lsz" ]; then
    lines="${lsz%% *}"
    max_visible=$(( lines - 8 ))
    [ "$max_visible" -lt 5 ] && max_visible=5
  fi

  local n=${#ord[@]} sel=0 rc=1 _frame idx all v i
  while :; do
    _frame="$(_resume_cleanup_select_body "$sel" "$n" "$max_visible")"
    printf '\033[?2026h%s\033[%d;1H\033[?2026l' "$_frame" "$lines" >&3
    tui_read_key 3 || TUI_KEY="q"
    case "$TUI_KEY" in
      up|k|shift-tab)   sel=$(( (sel - 1 + n) % n )) ;;
      down|j|tab)       sel=$(( (sel + 1) % n )) ;;
      left|pgup)        sel=$(( sel - max_visible )); [ "$sel" -lt 0 ] && sel=0 ;;
      right|pgdn)       sel=$(( sel + max_visible )); [ "$sel" -ge "$n" ] && sel=$(( n - 1 )) ;;
      home|g)           sel=0 ;;
      end|G)            sel=$(( n - 1 )) ;;
      ' ')
        idx="${ord[sel]}"
        cand_checked[idx]=$(( 1 - ${cand_checked[idx]} ))
        ;;
      a)
        # All checked → uncheck all; anything unchecked → check all.
        all=1
        for ((i=0; i<n; i++)); do
          if [ "${cand_checked[${ord[i]}]}" -eq 0 ]; then all=0; break; fi
        done
        v=1; [ "$all" -eq 1 ] && v=0
        for ((i=0; i<n; i++)); do cand_checked[${ord[i]}]="$v"; done
        ;;
      enter) rc=0; break ;;
      q|esc) rc=1; break ;;
    esac
  done
  trap - EXIT INT TERM
  printf '\033[?25h\033[?1049l' >&3
  stty echo 2>/dev/null || true
  exec 3>&- 2>/dev/null || true
  return "$rc"
}

_resume_cleanup() {
  local dry_run=0
  local older_than=30 older_given=0
  local min_size_mb=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) _resume_cleanup_help; return 0 ;;
      -d|--dry-run) dry_run=1; shift ;;
      -o|--older-than)
        if [ -z "${2:-}" ] || [[ ! "$2" =~ ^[0-9]+$ ]]; then
          log_fail "Error: --older-than requires a numeric number of days."
        fi
        older_than="$2"; older_given=1
        shift 2
        ;;
      -m|--min-size)
        if [ -z "${2:-}" ] || [[ ! "$2" =~ ^[0-9]+$ ]]; then
          log_fail "Error: --min-size requires a numeric number of megabytes."
        fi
        min_size_mb="$2"
        shift 2
        ;;
      *)
        log_fail "Unknown cleanup argument: $1"
        ;;
    esac
  done

  # Which filters gate the REGULAR candidates. --min-size alone means size is the
  # only axis (space lives in big recent files, not old ones); age applies by
  # default, or when --older-than was explicitly given alongside --min-size.
  # Stale copies and orphaned sid dirs are pure waste and bypass both filters.
  local apply_age=1
  if [ -n "$min_size_mb" ] && [ "$older_given" -eq 0 ]; then apply_age=0; fi

  # NB: an empty session list is NOT an early exit — orphaned sid dirs are
  # precisely what remains after every transcript is gone, so the orphan sweep
  # below must still run over a transcript-less store.
  local files
  files="$(_resume_all_sessions)"

  local now; now="$(date +%s)"
  local limit_secs=$((older_than * 86400))
  local cutoff=$((now - limit_secs))

  local -a candidates=()
  local -a cand_engine=()
  local -a cand_tank=()
  local -a cand_sid=()
  local -a cand_size_kb=()
  local -a cand_title=()
  local -a cand_age_str=()
  local -a cand_files_to_delete=()
  local -a cand_class=()     # regular | stale | diverged | orphan
  local -a cand_label=()     # extra preview note ("stale copy (kept: b)", …)
  local -a cand_checked=()   # the checkbox state; diverged copies start unchecked
  local -a sz_paths=()    # every path to size, flat — one batched du after the scan
  local -a cand_nsz=()    # how many sz_paths entries belong to candidate i

  # ── 1. Stale-copy reclaim ─────────────────────────────────────────────────
  # `clikae to`/relay and a cross-tank resume COPY the transcript into the target
  # tank and never GC the source, so the same session piles up across tanks (and
  # across project dirs after a rename — group by session, not by path). On a
  # real store this was 686 MB of redundant copies. One ps snapshot feeds the
  # live-session guard in _resume_cleanup_dedupe_flush.
  local live_procs
  live_procs="$(ps -axo command= 2>/dev/null || true)"

  # Sorted so copies of one session are adjacent, newest first within the group
  # ($files is mtime-sorted globally, not per session). LC_ALL=C: BSD sort
  # mangles CJK otherwise. codex groups by the FULL rollout basename — two
  # copies of one session share it verbatim, while _rs_sid (the last uuid
  # segment) could collide across sessions. NB the $( ) body stays heredoc- and
  # apostrophe-free: bash 3.2 mis-scans both inside a quoted substitution.
  local us=$'\037' mt f gsid dedupe_sorted
  dedupe_sorted="$(
    printf '%s\n' "$files" | while read -r mt f; do
      [ -n "$f" ] || continue
      _resume_session_fields "$f"
      gsid="$_rs_sid"
      if [ "$_rs_engine" = "codex" ]; then
        gsid="${f##*/}"; gsid="${gsid%.jsonl}"
      fi
      printf '%s\037%s\037%s\037%s\n' "$_rs_engine" "$gsid" "$mt" "$f"
    done | LC_ALL=C sort -t "$us" -k1,1 -k2,2 -k3,3rn
  )"

  local dedupe_claimed=""
  local cur_key="" key g_engine="" g_sid="" eng_l sid_l mt_l f_l
  local -a g_mt=() g_f=()
  while IFS="$us" read -r eng_l sid_l mt_l f_l; do
    [ -n "$f_l" ] || continue
    key="$eng_l$us$sid_l"
    if [ "$key" != "$cur_key" ]; then
      _resume_cleanup_dedupe_flush
      g_mt=(); g_f=(); cur_key="$key"; g_engine="$eng_l"; g_sid="$sid_l"
    fi
    g_mt+=("$mt_l"); g_f+=("$f_l")
  done <<EOF2
$dedupe_sorted
EOF2
  _resume_cleanup_dedupe_flush

  # ── 2. Orphaned claude sid dirs (subagent/workflow data left behind) ──────
  _resume_cleanup_scan_orphans

  # ── 3. Regular candidates, gated by the age/size filters ─────────────────
  while read -r mt f; do
    [ -n "$f" ] || continue
    case $'\n'"$dedupe_claimed"$'\n' in
      *$'\n'"$f"$'\n'*) continue ;;   # already offered as a stale/diverged copy
    esac
    if [ "$apply_age" -eq 1 ] && [ "$mt" -gt "$cutoff" ]; then
      continue
    fi
    _resume_cleanup_add_candidate "$f" "$mt" regular ""
  done <<EOF
$files
EOF

  # ── 4. Price everything in one pass ───────────────────────────────────────
  # _batch_du_kb prints one kb per sz_paths entry (in order), so a walking
  # pointer re-attaches each candidate's cand_nsz sizes (per-candidate du made
  # this loop fork-bound — 7s+ on a real store).
  local -a all_kb=()
  local kb_line size_kb
  if [ "${#sz_paths[@]}" -gt 0 ]; then
    while IFS= read -r kb_line; do
      all_kb+=("${kb_line:-0}")
    done <<EOF
$(_batch_du_kb "${sz_paths[@]}")
EOF
  fi
  local ci p=0 k
  for ((ci=0; ci<${#candidates[@]}; ci++)); do
    size_kb=0
    for ((k=0; k<${cand_nsz[ci]}; k++)); do
      size_kb=$((size_kb + ${all_kb[p]:-0}))
      p=$((p+1))
    done
    cand_size_kb[ci]="$size_kb"
  done

  # ── 5. Apply --min-size (needs the du prices) and order biggest first ─────
  local -a ord=()
  local min_kb=0 oline ordered
  [ -n "$min_size_mb" ] && min_kb=$(( min_size_mb * 1024 ))
  ordered="$(
    for ((ci=0; ci<${#candidates[@]}; ci++)); do
      if [ "${cand_class[ci]}" = "regular" ] && [ "${cand_size_kb[ci]}" -lt "$min_kb" ]; then
        continue
      fi
      printf '%s %s\n' "${cand_size_kb[ci]}" "$ci"
    done | sort -rn -k1,1
  )"
  while read -r _ oline; do
    [ -n "$oline" ] || continue
    ord+=("$oline")
  done <<EOF
$ordered
EOF

  if [ "${#ord[@]}" -eq 0 ]; then
    if [ -n "$min_size_mb" ] && [ "$apply_age" -eq 0 ]; then
      log_ok "No sessions of at least ${min_size_mb} MB found (0 files to clean)."
    elif [ -n "$min_size_mb" ]; then
      log_ok "No sessions older than $older_than days and at least ${min_size_mb} MB found (0 files to clean)."
    else
      log_ok "No sessions found older than $older_than days (0 files to clean)."
    fi
    return 0
  fi

  # ── 6. Titles, only for rows that survived the filters ───────────────────
  # From the transcript FILE, not (dir, sid): adapter_session_title derives its
  # path from $PWD's project, so every session outside the current directory
  # listed as "(no preview)" here.
  local oi idx title
  for ((oi=0; oi<${#ord[@]}; oi++)); do
    idx="${ord[oi]}"
    if [ -n "${cand_title[idx]}" ]; then continue; fi
    load_adapter "${cand_engine[idx]}" >/dev/null 2>&1 || true
    title=""
    if declare -F adapter_title_for_file >/dev/null 2>&1; then
      title="$(adapter_title_for_file "${candidates[idx]}" 2>/dev/null || true)"
    fi
    [ -n "$title" ] || title="(no preview)"
    cand_title[idx]="$title"
  done

  local sel_n=0 sel_kb=0 unsel_n=0

  if [ "$dry_run" -eq 1 ] || [ ! -t 0 ]; then
    log_bold "Session data that can be cleaned up (biggest first):"
    echo
    _resume_cleanup_print_list
    echo
    _resume_cleanup_tally
    log_bold "Total sessions to clean: $sel_n"
    log_bold "Estimated space to free: $(_kb_human "$sel_kb")"
    [ "$unsel_n" -gt 0 ] && log_dim "$unsel_n row(s) not selected by default (a diverged copy keeps unique tail content)."
    echo
    if [ "$dry_run" -eq 1 ]; then
      log_dim "Dry-run mode: no files were deleted."
      return 0
    fi
    # Never delete without a live confirmation: in a pipe / non-TTY there's no
    # one to press Enter, so refuse rather than proceed on EOF (clikae principle:
    # never silently destroy). --dry-run is the safe non-interactive preview.
    log_fail "Refusing to delete without an interactive confirmation — re-run in a terminal (or use --dry-run to preview)."
  fi

  # Interactive: pick WHAT to delete on a checkbox list, then the red confirm.
  local sel_rc=0
  _resume_cleanup_select && sel_rc=0 || sel_rc=$?
  if [ "$sel_rc" -eq 2 ]; then
    # No /dev/tty to draw the picker on — fall back to the printed list with its
    # default selection and the all-or-nothing confirm below.
    log_bold "Session data that can be cleaned up (biggest first):"
    echo
    _resume_cleanup_print_list
    echo
  elif [ "$sel_rc" -ne 0 ]; then
    log_ok "Cancelled — nothing deleted."
    return 0
  fi

  _resume_cleanup_tally
  if [ "$sel_n" -eq 0 ]; then
    log_ok "Nothing selected — nothing deleted."
    return 0
  fi

  log_bold "Selected sessions to clean: $sel_n"
  log_bold "Estimated space to free: $(_kb_human "$sel_kb")"
  echo
  printf "%bAre you sure you want to permanently delete these sessions?%b\n" "$__C_RED" "$__C_RESET"
  printf "Press %bEnter%b to proceed, or %bCtrl-C%b to cancel: " "$__C_BOLD" "$__C_RESET" "$__C_BOLD" "$__C_RESET"
  read -r _ || log_fail "No confirmation received — nothing deleted."

  log_dim "Deleting session files..."
  local deleted_kb=0 pth
  local -a path_list=()
  for ((oi=0; oi<${#ord[@]}; oi++)); do
    idx="${ord[oi]}"
    [ "${cand_checked[idx]}" -eq 1 ] || continue
    IFS=';' read -ra path_list <<< "${cand_files_to_delete[idx]}"
    for pth in "${path_list[@]}"; do
      if [ -d "$pth" ]; then
        rm -rf "$pth"
      elif [ -f "$pth" ]; then
        rm -f "$pth"
      fi
    done
    deleted_kb=$((deleted_kb + ${cand_size_kb[idx]}))
  done

  local deleted_sz_str; deleted_sz_str="$(_kb_human "$deleted_kb")"
  log_ok "Cleanup complete. Freed approximately $deleted_sz_str."
}

cmd_resume() {
  if [ "${1:-}" = "cleanup" ]; then
    shift
    _resume_cleanup "$@"
    return 0
  fi

  if [ "${1:-}" = "ask-tank" ]; then
    shift
    if [ -z "${1:-}" ]; then
      local cur; cur="$(resume_ask_tank_get)"
      log_info "Resume ask-tank: $cur — $(resume_ask_tank_label "$cur")"
      log_dim  "Choices:  always · dry-only    (set with: clikae resume ask-tank <choice>)"
      return 0
    fi
    if resume_ask_tank_set "$1"; then
      log_ok "Resume ask-tank: $1 — $(resume_ask_tank_label "$1")"
    else
      log_fail "Unknown choice: $1  (use: always | dry-only)"
    fi
    return 0
  fi

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
