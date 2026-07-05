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
                            not a fresh start).
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

# Draw the resume menu with row index $2 highlighted, from items in $1.
_resume_pick_draw() {
  local sel="$1"
  local n=${#filtered[@]}

  # Begin Synchronized Update — terminal buffers all output until ESU,
  # then renders the entire frame atomically in one pass. This prevents
  # the terminal from sampling intermediate cursor positions during drawing.
  printf '\033[?2026h'

  # Use terminal size and viewport from inherited max_visible
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

  local idx s_idx item engine tank sid label rage cwd mark rdot active_p
  printf '\033[H\033[K\n'   # home + one blank top-margin line

  printf '  %b%s%b  %b· ↑↓/Tab %s · ⏎ %s · / %s · q %s%b\033[K\n\n' \
    "$__C_BOLD" "clikae resume" "$__C_RESET" "$__C_DIM" \
    "$T_K_MOVE" "$T_RESUME" "$T_K_FILTER" "$T_K_QUIT" "$__C_RESET"

  # Top overflow indicator
  if [ "$start_idx" -gt 0 ]; then
    printf '    %b▲ ... %d more sessions above ...%b\033[K\n' "$__C_DIM" "$start_idx" "$__C_RESET"
  fi

  for ((idx=start_idx; idx<=end_idx; idx++)); do
    s_idx="${filtered[idx]}"
    _lazy_parse "$s_idx"
    item="${sessions[s_idx]}"
    engine="${item%%$'\x1f'*}"
    local tmp="${item#*$'\x1f'}"
    tank="${tmp%%$'\x1f'*}"
    tmp="${tmp#*$'\x1f'}"
    sid="${tmp%%$'\x1f'*}"
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
      _lazy_parse_cwd "$s_idx"
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

  printf '\033[J'   # erase any leftover lines

  # Park the cursor at the bottom-left corner of the window
  local target_rows="${lines:-24}"
  printf '\033[%d;1H' "$target_rows"

  # End Synchronized Update — terminal now renders the buffered frame atomically
  printf '\033[?2026l'
}

_lazy_parse() {
  local idx="$1"
  [ -n "${cached_title[idx]}" ] && return 0

  local item="${sessions[idx]}"
  local engine="${item%%$'\x1f'*}"
  local tmp="${item#*$'\x1f'}"
  local tank="${tmp%%$'\x1f'*}"
  tmp="${tmp#*$'\x1f'}"
  local sid="${tmp%%$'\x1f'*}"
  tmp="${tmp#*$'\x1f'}"
  local f="${tmp%%$'\x1f'*}"
  local mt="${tmp##*$'\x1f'}"

  load_adapter "$engine" >/dev/null 2>&1 || true

  local first_line=""
  if [ -f "$f" ]; then
    read -r first_line < "$f" 2>/dev/null || first_line=""
  fi

  local stitle=""
  if [ "$engine" = "claude" ]; then
    local line_in idx_in=0 max_lines_in=100 title_in="" user_msg_in=""
    while IFS= read -r line_in; do
      idx_in=$((idx_in + 1))
      [ "$idx_in" -gt "$max_lines_in" ] && break
      if [[ "$line_in" == *'"aiTitle"'* ]]; then
        local t_part="${line_in#*\"aiTitle\":\"}"
        title_in="${t_part%%\"*}"
        break
      fi
      if [ -z "$user_msg_in" ] && [[ "$line_in" == *'"role":"user"'* ]]; then
        if [[ "$line_in" == *'"text":"'* ]]; then
          local content_part="${line_in#*\"text\":\"}"
          user_msg_in="${content_part%%\"*}"
        elif [[ "$line_in" == *'"content":"'* ]]; then
          local content_part="${line_in#*\"content\":\"}"
          user_msg_in="${content_part%%\"*}"
        fi
      fi
    done < "$f" 2>/dev/null
    stitle="$title_in"
    [ -n "$stitle" ] || stitle="$user_msg_in"
    stitle="${stitle//\\n/ }"
    stitle="${stitle//\\t/ }"
    stitle="${stitle//\\\"/\"}"
  elif [ "$engine" = "codex" ]; then
    stitle="$(adapter_session_title "$(profile_dir "$engine" "$tank")" "$sid" 2>/dev/null || true)"
  elif [ "$engine" = "antigravity" ]; then
    local c_part="${first_line#*\"content\":\"}"
    stitle="${c_part%%\"*}"
    if [[ "$stitle" == *"<USER_REQUEST>"* ]]; then
      stitle="${stitle#*<USER_REQUEST>}"
      stitle="${stitle%%</USER_REQUEST>*}"
    fi
    stitle="${stitle//\\n/ }"
    stitle="${stitle//\\t/ }"
    stitle="${stitle//\\\"/\"}"
  fi

  [ -n "$stitle" ] || stitle="(no preview)"
  cached_title[idx]="$stitle"

  # Format age
  local now; now=$(date +%s 2>/dev/null || echo "$mt")
  local diff=$((now - mt))
  local rage
  if [ "$diff" -lt 60 ]; then rage="just now"
  elif [ "$diff" -lt 3600 ]; then rage="$((diff / 60))m ago"
  elif [ "$diff" -lt 86400 ]; then rage="$((diff / 3600))h ago"
  else rage="$((diff / 86400))d ago"; fi
  cached_age[idx]="$rage"
}

_lazy_parse_cwd() {
  local idx="$1"
  [ -n "${cached_cwd[idx]}" ] && return 0

  local item="${sessions[idx]}"
  local engine="${item%%$'\x1f'*}"
  local tmp="${item#*$'\x1f'}"
  local tank="${tmp%%$'\x1f'*}"
  tmp="${tmp#*$'\x1f'}"
  local sid="${tmp%%$'\x1f'*}"
  tmp="${tmp#*$'\x1f'}"
  local f="${tmp%%$'\x1f'*}"

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

  local exit_loop=0 trigger_filter=0 trigger_select=0

  _handle_key() {
    local k="$1"
    case "$k" in
      $'\e')
        if IFS= read -rsn1 -t 1 char1 <&3 && [ "$char1" = "[" ]; then
          if IFS= read -rsn1 -t 1 char2 <&3; then
            local max_visible_in="$max_visible"
            # Debug probe (opt-in): CLIKAE_RESUME_DEBUG=<file> logs each escape
            # sequence's bytes + the paging step, so a "broken arrow" report can be
            # diagnosed from a real run instead of guessed. No-op when unset.
            [ -n "${CLIKAE_RESUME_DEBUG:-}" ] && \
              printf 'ESC char1=%q char2=%q max_visible_in=[%s] sel=%s n=%s\n' \
                "${char1:-}" "${char2:-}" "$max_visible_in" "$sel" "$n" >> "$CLIKAE_RESUME_DEBUG" 2>/dev/null
            case "$char2" in
              A) # Up Arrow
                 sel=$(( (sel - 1 + n) % n )) ;;
              B) # Down Arrow
                 sel=$(( (sel + 1) % n )) ;;
              D) # Left Arrow -> Page Up
                 sel=$(( sel - max_visible_in ))
                 [ "$sel" -lt 0 ] && sel=0
                 ;;
              C) # Right Arrow -> Page Down
                 sel=$(( sel + max_visible_in ))
                 [ "$sel" -ge "$n" ] && sel=$(( n - 1 ))
                 ;;
              Z) # Shift-Tab
                 sel=$(( (sel - 1 + n) % n )) ;;
              5) # Page Up
                 IFS= read -rsn1 -t 1 _ <&3 # consume the '~'
                 sel=$(( sel - max_visible_in ))
                 [ "$sel" -lt 0 ] && sel=0
                 ;;
              6) # Page Down
                 IFS= read -rsn1 -t 1 _ <&3 # consume the '~'
                 sel=$(( sel + max_visible_in ))
                 [ "$sel" -ge "$n" ] && sel=$(( n - 1 ))
                 ;;
              H|1) # Home key
                 [ "$char2" = "1" ] && IFS= read -rsn1 -t 1 _ <&3
                 sel=0
                 ;;
              F|4) # End key
                 [ "$char2" = "4" ] && IFS= read -rsn1 -t 1 _ <&3
                 sel=$(( n - 1 ))
                 ;;
            esac
          fi
        else
          exit_loop=1
        fi
        ;;
      $'\t') sel=$(( (sel + 1) % n )) ;;
      k) sel=$(( (sel - 1 + n) % n )) ;;
      j) sel=$(( (sel + 1) % n )) ;;
      g) sel=0 ;;
      G) sel=$(( n - 1 )) ;;
      [1-9])
        sel=$(( k - 1 )); [ "$sel" -ge "$n" ] && sel=$(( n - 1 )) ;;
      q) exit_loop=1 ;;
      /) trigger_filter=1 ;;
      ''|$'\n'|$'\r') trigger_select=1 ;;
    esac
    # MUST end with success: a branch whose last command is `[ cond ] && assign`
    # (the paging clamps) returns non-zero when cond is false. _handle_key is called
    # bare in the loop, so under `set -eo pipefail` that non-zero return crashed the
    # whole picker (dogfood 2026-06-29: → / PgDn exited clikae). Never let it leak.
    return 0
  }

  local sel=0 key n filter="" i last_filter="--initial--"
  while :; do
    if [ "$filter" != "$last_filter" ]; then
      local -a filtered=()
      for ((i=0; i<${#sessions[@]}; i++)); do
        if [ -n "$filter" ]; then
          _lazy_parse "$i"
          local item="${sessions[i]}"
          local engine="${item%%$'\x1f'*}"
          local tmp="${item#*$'\x1f'}"
          local tank="${tmp%%$'\x1f'*}"
          local title="${cached_title[i]}"
          shopt -s nocasematch
          if [[ "$engine/$tank $title" == *"$filter"* ]]; then
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
      IFS= read -rsn1 key <&3 || key="q"
      case "$key" in
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

    # Block-read ONE key from the dedicated tty fd, handle it, redraw. No `-t 0`
    # typeahead drain: it read from bare stdin and swallowed stray feedback bytes
    # as keystrokes (the paging-reset bug). One key per frame + the synchronized
    # flicker-free redraw is plenty smooth, and correct.
    IFS= read -rsn1 key <&3 || { key="q"; }
    [ -n "${CLIKAE_RESUME_DEBUG:-}" ] && \
      printf 'READ key=%q sel(before)=%s n=%s max_visible=%s\n' "$key" "$sel" "$n" "$max_visible" >> "$CLIKAE_RESUME_DEBUG" 2>/dev/null

    exit_loop=0
    trigger_filter=0
    trigger_select=0

    _handle_key "$key"
    [ -n "${CLIKAE_RESUME_DEBUG:-}" ] && \
      printf '  -> sel(after)=%s exit=%s filt=%s sel_trig=%s\n' "$sel" "$exit_loop" "$trigger_filter" "$trigger_select" >> "$CLIKAE_RESUME_DEBUG" 2>/dev/null

    if [ "$exit_loop" -eq 1 ]; then
      break
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
      local sel_s_idx="${filtered[sel]}"
      local sel_item="${sessions[sel_s_idx]}"
      local sel_engine="${sel_item%%$'\x1f'*}"
      local sel_tmp="${sel_item#*$'\x1f'}"
      local sel_tank="${sel_tmp%%$'\x1f'*}"
      sel_tmp="${sel_tmp#*$'\x1f'}"
      local sel_sid="${sel_tmp%%$'\x1f'*}"
      # (the 4th field — transcript path — isn't needed here; _resume_exec and the
      # cross-tank copy below re-derive it via adapter_find_session.)

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
  files="$(sessions_by_mtime \
            "$CLIKAE_HOME"/profiles/claude/*/projects/*/*.jsonl \
            "$CLIKAE_HOME"/profiles/codex/*/sessions/*/*/*/rollout-*.jsonl \
            "$CLIKAE_HOME"/profiles/antigravity/*/antigravity-cli/brain/*/.system_generated/logs/transcript.jsonl)"

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

  local mt f rel engine rest tank sid filename without_ext brain_part
  while read -r mt f; do
    [ -n "$f" ] || continue
    rel="${f#*/profiles/}"
    engine="${rel%%/*}"
    rest="${rel#*/}"
    tank="${rest%%/*}"
    filename="${f##*/}"
    if [ "$engine" = "antigravity" ]; then
      brain_part="${f%/.system_generated/*}"
      sid="${brain_part##*/}"
    elif [ "$engine" = "codex" ]; then
      without_ext="${filename%.jsonl}"
      sid="${without_ext##*-}"
    else # claude
      sid="${filename%.jsonl}"
    fi
    sessions+=("$engine"$'\x1f'"$tank"$'\x1f'"$sid"$'\x1f'"$f"$'\x1f'"$mt")
  done <<EOF
$files
EOF

  if [ "${#sessions[@]}" -eq 0 ]; then
    log_err "No resumable sessions found in any tank."
    exit 1
  fi

  if [ ! -t 0 ] || [ ! -t 1 ] || [ -n "${CLIKAE_NO_INTERACTIVE:-}" ]; then
    log_bold "Recent sessions across your tanks (showing top 50):"
    local idx=0 limit=50 item engine_t tank_t sid_t label_t rage_t cwd_t
    [ "${#sessions[@]}" -lt "$limit" ] && limit=${#sessions[@]}
    for ((idx=0; idx<limit; idx++)); do
      _lazy_parse "$idx"
      item="${sessions[idx]}"
      engine_t="${item%%$'\x1f'*}"
      local tmp="${item#*$'\x1f'}"
      tank_t="${tmp%%$'\x1f'*}"
      tmp="${tmp#*$'\x1f'}"
      sid_t="${tmp%%$'\x1f'*}"
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

_get_path_size_kb() {
  local path="$1"
  [ -e "$path" ] || { echo 0; return; }
  local val
  val="$(du -sk "$path" 2>/dev/null | awk '{print $1}')"
  echo "${val:-0}"
}

_resume_cleanup_help() {
  cat <<'EOF'
Usage: clikae resume cleanup [options]

Delete old session data files (transcripts, databases, brain assets) to free disk space.
This only deletes session history files. It never deletes tank configurations, memory files,
caches, or settings.

Options:
  -d, --dry-run             Preview what will be deleted and how much space freed, without deleting.
  -o, --older-than <days>   Only target sessions older than <days> (default: 30).
  -h, --help                Show this help message.

Examples:
  clikae resume cleanup
  clikae resume cleanup --older-than 7
  clikae resume cleanup --dry-run
EOF
}

_resume_cleanup() {
  local dry_run=0
  local older_than=30
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) _resume_cleanup_help; return 0 ;;
      -d|--dry-run) dry_run=1; shift ;;
      -o|--older-than)
        if [ -z "${2:-}" ] || [[ ! "$2" =~ ^[0-9]+$ ]]; then
          log_fail "Error: --older-than requires a numeric number of days."
        fi
        older_than="$2"
        shift 2
        ;;
      *)
        log_fail "Unknown cleanup argument: $1"
        ;;
    esac
  done

  local files
  files="$(sessions_by_mtime \
            "$CLIKAE_HOME"/profiles/claude/*/projects/*/*.jsonl \
            "$CLIKAE_HOME"/profiles/codex/*/sessions/*/*/*/rollout-*.jsonl \
            "$CLIKAE_HOME"/profiles/antigravity/*/antigravity-cli/brain/*/.system_generated/logs/transcript.jsonl)"

  if [ -z "$files" ]; then
    log_ok "No session files found to clean."
    return 0
  fi

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

  local mt f rel engine rest tank sid filename without_ext brain_part
  local size_kb title age_str files_to_del db_file conversations_dir
  local total_size_kb=0

  while read -r mt f; do
    [ -n "$f" ] || continue
    # Filter by age
    if [ "$mt" -gt "$cutoff" ]; then
      continue
    fi

    rel="${f#*/profiles/}"
    engine="${rel%%/*}"
    rest="${rel#*/}"
    tank="${rest%%/*}"
    filename="${f##*/}"

    # Determine session ID and files to delete
    if [ "$engine" = "antigravity" ]; then
      brain_part="${f%/.system_generated/*}"
      sid="${brain_part##*/}"
      conversations_dir="${brain_part%/brain/*}/conversations"
      db_file="$conversations_dir/$sid.db"
      # Calculate total size of brain folder + db file
      local b_sz; b_sz="$(_get_path_size_kb "$brain_part")"
      local d_sz; d_sz="$(_get_path_size_kb "$db_file")"
      size_kb=$((b_sz + d_sz))
      files_to_del="$brain_part;$db_file;$db_file-shm;$db_file-wal"
    elif [ "$engine" = "codex" ]; then
      without_ext="${filename%.jsonl}"
      sid="${without_ext##*-}"
      size_kb="$(_get_path_size_kb "$f")"
      files_to_del="$f"
    else # claude
      sid="${filename%.jsonl}"
      size_kb="$(_get_path_size_kb "$f")"
      files_to_del="$f"
    fi

    # Get title cheaply
    load_adapter "$engine" >/dev/null 2>&1 || true
    local dir
    dir="$(profile_dir "$engine" "$tank")"
    if declare -F adapter_session_title >/dev/null 2>&1; then
      title="$(adapter_session_title "$dir" "$sid" 2>/dev/null || true)"
    else
      title="$(adapter_session_meta "$dir" "$sid" 2>/dev/null | cut -d$'\037' -f4 || true)"
    fi
    [ -n "$title" ] || title="(no preview)"

    # Format age string
    local _d=$(( now - mt ))
    age_str="$(( _d / 86400 ))d ago"

    # Add to candidates
    candidates+=("$f")
    cand_engine+=("$engine")
    cand_tank+=("$tank")
    cand_sid+=("$sid")
    cand_size_kb+=("$size_kb")
    cand_title+=("$title")
    cand_age_str+=("$age_str")
    cand_files_to_delete+=("$files_to_del")

    total_size_kb=$((total_size_kb + size_kb))
  done <<EOF
$files
EOF

  if [ "${#candidates[@]}" -eq 0 ]; then
    log_ok "No sessions found older than $older_than days (0 files to clean)."
    return 0
  fi

  log_bold "The following sessions are older than $older_than days and will be deleted:"
  echo
  local i
  for ((i=0; i<${#candidates[@]}; i++)); do
    local eng="${cand_engine[i]}"
    local tnk="${cand_tank[i]}"
    local sz_kb="${cand_size_kb[i]}"
    local ttl="${cand_title[i]}"
    local ag="${cand_age_str[i]}"
    local sz_str; sz_str="$(awk -v k="$sz_kb" 'BEGIN { if (k < 1024) printf "%d KB", k; else printf "%.1f MB", k/1024 }')"

    printf "  %b%s/%s%b · %s · %s · %b(%s)%b\n" \
      "$__C_BOLD" "$eng" "$tnk" "$__C_RESET" \
      "\"$(_home_trunc "$ttl" 40)\"" \
      "$ag" \
      "$__C_DIM" "$sz_str" "$__C_RESET"
  done
  echo
  local total_sz_str; total_sz_str="$(awk -v k="$total_size_kb" 'BEGIN { if (k < 1024) printf "%d KB", k; else if (k < 1048576) printf "%.1f MB", k/1024; else printf "%.2f GB", k/1048576 }')"
  log_bold "Total sessions to clean: ${#candidates[@]}"
  log_bold "Estimated space to free: $total_sz_str"
  echo

  if [ "$dry_run" -eq 1 ]; then
    log_dim "Dry-run mode: no files were deleted."
    return 0
  fi

  # Never delete without a live confirmation: in a pipe / non-TTY there's no one to
  # press Enter, so refuse rather than proceed on EOF (clikae principle: never
  # silently destroy). --dry-run above is the safe way to preview non-interactively.
  if [ ! -t 0 ]; then
    log_fail "Refusing to delete without an interactive confirmation — re-run in a terminal (or use --dry-run to preview)."
  fi
  printf "%bAre you sure you want to permanently delete these sessions?%b\n" "$__C_RED" "$__C_RESET"
  printf "Press %bEnter%b to proceed, or %bCtrl-C%b to cancel: " "$__C_BOLD" "$__C_RESET" "$__C_BOLD" "$__C_RESET"
  read -r _ || log_fail "No confirmation received — nothing deleted."

  log_dim "Deleting session files..."
  local deleted_kb=0
  for ((i=0; i<${#candidates[@]}; i++)); do
    local files_str="${cand_files_to_delete[i]}"
    local sz_kb="${cand_size_kb[i]}"
    IFS=';' read -ra path_list <<< "$files_str"
    local p
    for p in "${path_list[@]}"; do
      if [ -d "$p" ]; then
        rm -rf "$p"
      elif [ -f "$p" ]; then
        rm -f "$p"
      fi
    done
    deleted_kb=$((deleted_kb + sz_kb))
  done

  local deleted_sz_str; deleted_sz_str="$(awk -v k="$deleted_kb" 'BEGIN { if (k < 1024) printf "%d KB", k; else if (k < 1048576) printf "%.1f MB", k/1024; else printf "%.2f GB", k/1048576 }')"
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
