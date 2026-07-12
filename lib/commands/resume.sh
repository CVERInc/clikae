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
Usage: clikae resume [session-id | ask-tank] [-- args...]

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
                            not a fresh start). Press `c` in the picker to free
                            disk space (opens `clikae clean`, then comes back).
  clikae resume <id> -- -p "…"   forward extra args to the engine after --
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
# its path differently). Shared by the picker's array build and `clikae clean`'s
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
# both the picker and `clikae clean`); a new resumable engine's glob goes here
# only.
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
  local _cols; _cols="$(_home_cols)"
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
    # Title budget: cols minus this row's fixed chrome (4-lead+mark+dot+space
    # +7-col name+space+8-col engine+space+2 quotes+2 spaces+parens = 31) minus
    # the trailing age string's OWN width (variable per row) minus 1 more for
    # `_home_trunc`'s trailing "…".
    local _title_budget; _title_budget="$(_home_row_budget "$_cols" "$(( 31 + $(_dwidth "$rage") + 1 ))" 20)"
    if [ "$idx" -eq "$sel" ]; then
      cwd="${cached_cwd[s_idx]}"
      printf '    %b %b %b%s%b %b%s%b %b"%s"%b  %b(%s)%b\033[K\n' "$mark" "$rdot" "$__C_BOLD" "$_rnm" "$__C_RESET" "$__C_DIM" "$_ren" "$__C_RESET" "$__C_DIM" "$(_home_trunc "$label" "$_title_budget")" "$__C_RESET" "$__C_DIM" "$rage" "$__C_RESET"
      # The hanging line used to print the full 36-char UUID plus an
      # UNTRUNCATED cwd (85 cols in en-US baseline, worse with a real absolute
      # path). Short id = the same "${sid%%-*}…" form used elsewhere in this
      # file (line ~166/~644) when announcing a session, not the raw UUID; the
      # cwd is middle-ellipsised (head kept short, tail — the meaningful leaf
      # dir — kept long) to whatever's left of the row's budget.
      local _short_sid _dir_budget
      _short_sid="${sid%%-*}…"
      _dir_budget="$(_home_row_budget "$_cols" "$(( 25 + $(_dwidth "$_short_sid") + $(_dwidth "$T_ENTER_RESUME") ))" 15)"
      printf '          %bdir: %s · id: %s · %s%b\033[K\n' "$__C_DIM" "$(_home_trunc_mid "${cwd:-?}" "$_dir_budget")" "$_short_sid" "$T_ENTER_RESUME" "$__C_RESET"
    else
      printf '    %b %b %s %b%s%b %b"%s"%b  %b(%s)%b\033[K\n' "$mark" "$rdot" "$_rnm" "$__C_DIM" "$_ren" "$__C_RESET" "$__C_DIM" "$(_home_trunc "$label" "$_title_budget")" "$__C_RESET" "$__C_DIM" "$rage" "$__C_RESET"
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

  local exit_loop=0 trigger_filter=0 trigger_select=0 trigger_clean=0

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
      c)                trigger_clean=1 ;;
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
    trigger_clean=0

    _handle_key "$TUI_KEY"
    [ -n "${CLIKAE_RESUME_DEBUG:-}" ] && \
      printf '  -> sel(after)=%s exit=%s filt=%s sel_trig=%s\n' "$sel" "$exit_loop" "$trigger_filter" "$trigger_select" >> "$CLIKAE_RESUME_DEBUG" 2>/dev/null

    if [ "$exit_loop" -eq 1 ]; then
      break
    fi

    if [ "$trigger_clean" -eq 1 ]; then
      # `c` opens the clean screen and comes BACK here (screens cross-link and
      # return where you came from — grammar §8.1). It runs as a child process:
      # clean.sh sources this file, so an in-process call would source-loop.
      # Clean deletes session files this picker has already cached, so instead
      # of redrawing a stale list we signal _resume_picker to rescan the store
      # and re-enter the picker fresh.
      exec 3>&- 2>/dev/null || true
      _home_tty_leave; trap - EXIT INT TERM
      "$CLIKAE_BIN" clean || true
      unset -f _handle_key
      _RESUME_PICK_AGAIN=1
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

  # Scan → build → pick, in a loop: the picker's `c` key runs `clikae clean`
  # (which deletes session files) and sets _RESUME_PICK_AGAIN so we rescan the
  # store and re-enter the picker fresh — never redraw over a stale list.
  while :; do
    _RESUME_PICK_AGAIN=0

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
    [ "${_RESUME_PICK_AGAIN:-0}" -eq 1 ] || break
  done
}

cmd_resume() {
  if [ "${1:-}" = "cleanup" ]; then
    # Hidden back-compat alias (grammar §7): the flow moved to `clikae clean`.
    shift
    exec "$CLIKAE_BIN" clean "$@"
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
