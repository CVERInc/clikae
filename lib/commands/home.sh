# shellcheck shell=bash
# lib/commands/home.sh — `clikae` with no arguments opens here: your home
# dashboard, the screen clikae wants to be the first thing you type.
#
#   have tanks -> the "tank board": every profile (tank) grouped by CLI, the one
#                 active in THIS shell marked, account + real alias name, plus an
#                 "Also available" line for relay-capable CLIs/targets you could
#                 open even without a tank yet (e.g. codex, agy), and the
#                 fuel-pool fall-through order.
#   no tanks   -> a welcome: what clikae found on this machine + the first step.
# The full command reference is one keystroke away at `clikae help`; the deep
# machine check at `clikae doctor`. All read-only.

# _home_active_for <cli>  -> the profile active for <cli> in THIS shell, or empty.
# Mirrors `clikae status`: read the adapter's live env var and resolve it back.
_home_active_for() {
  local cli="$1"
  (
    load_adapter "$cli" >/dev/null 2>&1 || exit 0
    local var strategy value
    var="$(adapter_meta_env_var)"
    [ -n "$var" ] || exit 0     # flag-strategy CLIs aren't detectable from env
    strategy="$(adapter_meta_strategy)"
    value="${!var}"
    resolve_active_profile "$cli" "$strategy" "$value"
  )
}

# _home_alias_for <cli> <profile>  -> the managed alias NAME from the shell rc,
# or empty. The block opens with `# >>> clikae:<cli>.<profile> >>>` and the alias
# line is `alias <name>=...` (zsh/bash) or `alias <name> ...` (fish).
_home_alias_for() {
  local cli="$1" profile="$2" rc id
  rc="$(detect_shell_rc)"
  [ -f "$rc" ] || return 0
  id="$cli.$profile"
  # NB: `close` is an awk built-in, so the sentinels use omark/cmark.
  awk -v omark="# >>> clikae:$id >>>" -v cmark="# <<< clikae:$id <<<" '
    $0 == omark { inb = 1; next }
    $0 == cmark { inb = 0 }
    inb && /^alias / {
      line = $0
      sub(/^alias /, "", line)
      sub(/[ =].*$/, "", line)   # name ends at the first space or =
      print line
      exit
    }
  ' "$rc"
}

# _home_items  -> one canonical launchable row per "thing you can open", fields
# separated by ASCII Unit Separator (\037):
#   kind ␟ cli ␟ profile ␟ label ␟ alias ␟ active(1|0) ␟ note
# kind ∈ tank (a profile) | agent (a relay-capable CLI with no tank yet, e.g.
# codex) | target (a single-account launch-only target, e.g. agy). Tanks come
# first, sorted by CLI then profile, so the renderer can group as it reads.
_home_items() {
  # 1) Tanks — every profile.
  local cli profile path label alias active cur_cli="" active_for="" a
  while IFS=$'\t' read -r cli profile path; do
    [ -n "$cli" ] || continue
    if [ "$cli" != "$cur_cli" ]; then
      cur_cli="$cli"
      active_for="$(_home_active_for "$cli")"
    fi
    label="$(load_adapter "$cli" >/dev/null 2>&1 && adapter_label "$path" || true)"
    alias="$(_home_alias_for "$cli" "$profile")"
    if [ -n "$active_for" ] && [ "$profile" = "$active_for" ]; then a=1; else a=0; fi
    printf 'tank\037%s\037%s\037%s\037%s\037%d\037\n' "$cli" "$profile" "$label" "$alias" "$a"
  done <<EOF
$(list_all_profiles)
EOF

  # 2) Agents — installed adapters with NO profile that are relay-capable (they
  #    define adapter_start_with_prompt, i.e. interactive agent CLIs you'd hand a
  #    session to: codex). gh/npm/etc. are tools, not session tanks, so excluded.
  local name root
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    root="$(profiles_root)/$name"
    [ -d "$root" ] && [ -n "$(ls -A "$root" 2>/dev/null)" ] && continue   # has a tank already
    (
      load_adapter "$name" >/dev/null 2>&1 || exit 0
      declare -F adapter_start_with_prompt >/dev/null 2>&1 || exit 0
      command -v "$(adapter_meta_cli_binary)" >/dev/null 2>&1 || exit 0
      printf 'agent\037%s\037\037\037\0370\037no tank yet — opens default\n' "$name"
    )
  done <<EOF
$(list_adapters)
EOF

  # 3) Targets — installed single-account launch-only targets. Displayed by the
  #    binary you'd type (agy); the profile field carries the target name
  #    (antigravity) so a launcher can resolve it back.
  local tfile tname
  for tfile in "$CLIKAE_LIB"/targets/*.sh; do
    [ -f "$tfile" ] || continue
    tname="$(basename "$tfile" .sh)"
    (
      # shellcheck source=/dev/null
      source "$tfile" 2>/dev/null || exit 0
      declare -F target_meta_binary >/dev/null 2>&1 || exit 0
      local tbin; tbin="$(target_meta_binary)"
      command -v "$tbin" >/dev/null 2>&1 || exit 0
      printf 'target\037%s\037%s\037\037\0370\037single-account\n' "$tbin" "$tname"
    )
  done
}

# Render the launchable items (passed as $1) as the static tank board.
_home_render_static() {
  local items="$1"
  local n_tanks n_clis
  n_tanks="$(printf '%s\n' "$items" | awk -F'\037' '$1=="tank"' | grep -c .)"
  n_clis="$(printf '%s\n' "$items" | awk -F'\037' '$1=="tank"{print $2}' | sort -u | grep -c .)"
  printf '%bclikae  ｷﾘｶｴ%b  %b·  %s tank%s across %s CLI%s%b\n\n' \
    "$__C_BOLD" "$__C_RESET" "$__C_DIM" \
    "$n_tanks" "$([ "$n_tanks" = 1 ] || echo s)" \
    "$n_clis"  "$([ "$n_clis" = 1 ] || echo s)" "$__C_RESET"

  local kind cli profile label alias active note cur_cli="" cli_count also=""
  local launch_cli="" launch_profile="" launch_alias=""
  while IFS=$'\037' read -r kind cli profile label alias active note; do
    [ -n "$kind" ] || continue
    case "$kind" in
      tank)
        if [ "$cli" != "$cur_cli" ]; then
          cur_cli="$cli"
          cli_count="$(printf '%s\n' "$items" | awk -F'\037' -v c="$cli" '$1=="tank" && $2==c' | grep -c .)"
          printf '  %b%s%b %b(%s)%b\n' "$__C_BOLD" "$cli" "$__C_RESET" "$__C_DIM" "$cli_count" "$__C_RESET"
        fi
        if [ "$active" = "1" ]; then
          printf '    %b●%b %-10s %b%-24s%b %b%s%b  %b← active here%b\n' \
            "$__C_GREEN" "$__C_RESET" "$profile" "$__C_DIM" "${label:--}" "$__C_RESET" \
            "$__C_DIM" "$alias" "$__C_RESET" "$__C_GREEN" "$__C_RESET"
          launch_cli="$cli"; launch_profile="$profile"; launch_alias="$alias"
        else
          printf '    %b○%b %-10s %b%-24s%b %b%s%b\n' \
            "$__C_DIM" "$__C_RESET" "$profile" "$__C_DIM" "${label:--}" "$__C_RESET" "$__C_DIM" "$alias" "$__C_RESET"
          if [ -z "$launch_cli" ]; then launch_cli="$cli"; launch_profile="$profile"; launch_alias="$alias"; fi
        fi
        ;;
      agent|target)
        also="$also$(printf '    %b·%b %-12s %b%s%b' "$__C_DIM" "$__C_RESET" "$cli" "$__C_DIM" "$note" "$__C_RESET")"$'\n'
        ;;
    esac
  done <<EOF
$items
EOF

  if [ -n "$also" ]; then
    printf '\n  %bAlso available%b\n' "$__C_BOLD" "$__C_RESET"
    printf '%s' "$also"
  fi
  echo ""

  local pool
  pool="$(pool_list | awk 'NR>1{printf " → "} {printf "%s", $0} END{ if (NR) print "" }')"
  [ -n "$pool" ] && printf '  %-9s %s\n' "fuel pool" "$pool"

  if [ -n "$launch_cli" ]; then
    # Colour via %b args, never embedded in a %s string (the codes are literal
    # \033 sequences and only printf %b interprets them).
    if [ -n "$launch_alias" ]; then
      printf '  %-9s clikae run %s %s   %b(or your alias: %s)%b\n' \
        "launch" "$launch_cli" "$launch_profile" "$__C_DIM" "$launch_alias" "$__C_RESET"
    else
      printf '  %-9s clikae run %s %s\n' "launch" "$launch_cli" "$launch_profile"
    fi
  fi
  printf '  %-9s %s\n' "more" "clikae status · clikae doctor · clikae demo · clikae help"
}

# The welcome screen, shown when there are no profiles yet.
_home_welcome() {
  log_bold "clikae  ｷﾘｶｴ  ·  one CLI, many accounts — swap the tank, keep burning"
  echo ""
  local installed="" total=0 cli inst binary strategy count label
  while IFS=$'\037' read -r cli inst binary strategy count label; do
    [ -n "$cli" ] || continue
    : "$binary" "$strategy" "$count" "$label"
    total=$((total + 1))
    if [ "$inst" -eq 1 ]; then
      [ -n "$installed" ] && installed="$installed · $cli" || installed="$cli"
    fi
  done <<EOF
$(scan_clis)
EOF

  local example="claude"
  if [ -n "$installed" ]; then
    printf '  No tanks yet. clikae supports %d CLIs; installed on this machine:\n' "$total"
    printf '    %b%s%b\n' "$__C_GREEN" "$installed" "$__C_RESET"
    example="$(printf '%s' "$installed" | awk '{print $1}')"
  else
    printf '  No tanks yet. clikae supports %d CLIs (none of them detected on PATH here).\n' "$total"
  fi
  echo ""
  log_bold "  Fill your first tank (pick a CLI you use):"
  log_dim  "    clikae init $example work --alias     # then: source your rc, run $example-work"
  echo ""
  log_dim "  Curious first?  clikae demo   (a 30-second sandbox tour — touches nothing)"
}

# ---------------------------------------------------------------------------
# Interactive launcher (only on a real TTY; pipes/scripts/tests get the static
# board). Uses the alternate screen buffer so the user's scrollback is intact.

_home_tty_leave() { printf '\033[?25h\033[?1049l'; }   # show cursor, leave alt screen

# Resolve and EXEC the launch for one item row (replaces this process).
#   tank   -> clikae run <cli> <profile>   (applies the profile env, then execs)
#   agent  -> the CLI's own binary, default config (no tank)
#   target -> the target's binary (already in the cli field)
_home_launch() {
  local kind cli profile label alias active note
  IFS=$'\037' read -r kind cli profile label alias active note <<EOF
$1
EOF
  : "$label" "$alias" "$active" "$note"
  case "$kind" in
    tank)   exec "$CLIKAE_BIN" run "$cli" "$profile" ;;
    agent)  local bin; bin="$(load_adapter "$cli" >/dev/null 2>&1 && adapter_meta_cli_binary)"; exec "$bin" ;;
    target) exec "$cli" ;;
  esac
}

# Guided new-tank flow (the `n` key). Line-mode prompts, then init --alias.
_home_new_tank() {
  local def_cli="$1" cli profile
  printf '\nNew tank.\n'
  read -rp "  CLI [${def_cli:-claude}]: " cli || return 0
  cli="${cli:-${def_cli:-claude}}"
  read -rp "  Profile name: " profile || return 0
  [ -n "$profile" ] || { printf '  Cancelled.\n'; return 0; }
  exec "$CLIKAE_BIN" init "$cli" "$profile" --alias
}

# Draw the menu (full redraw) with row index $2 highlighted, from items in $1.
_home_pick_draw() {
  local items="$1" sel="$2"
  printf '\033[H\033[2J'
  printf '%bclikae  ｷﾘｶｴ%b  %b· pick a tank    ↑↓ move · ⏎ open · n new · q quit%b\n\n' \
    "$__C_BOLD" "$__C_RESET" "$__C_DIM" "$__C_RESET"
  local kind cli profile label alias active note idx=0 cur_cli="" printed_also=0 mark dot
  while IFS=$'\037' read -r kind cli profile label alias active note; do
    [ -n "$kind" ] || continue
    if [ "$idx" -eq "$sel" ]; then mark="${__C_GREEN}❯${__C_RESET}"; else mark=" "; fi
    case "$kind" in
      tank)
        if [ "$cli" != "$cur_cli" ]; then cur_cli="$cli"; printf '  %b%s%b\n' "$__C_BOLD" "$cli" "$__C_RESET"; fi
        if [ "$active" = "1" ]; then dot="${__C_GREEN}●${__C_RESET}"; else dot="${__C_DIM}○${__C_RESET}"; fi
        if [ "$idx" -eq "$sel" ]; then
          printf '  %b %b %b%-10s %-24s %s%b\n' "$mark" "$dot" "$__C_BOLD" "$profile" "${label:--}" "$alias" "$__C_RESET"
        else
          printf '  %b %b %-10s %b%-24s %s%b\n' "$mark" "$dot" "$profile" "$__C_DIM" "${label:--}" "$alias" "$__C_RESET"
        fi
        ;;
      agent|target)
        if [ "$printed_also" -eq 0 ]; then printed_also=1; printf '  %bAlso available%b\n' "$__C_BOLD" "$__C_RESET"; fi
        if [ "$idx" -eq "$sel" ]; then
          printf '  %b %b· %-12s %s%b\n' "$mark" "$__C_BOLD" "$cli" "$note" "$__C_RESET"
        else
          printf '  %b · %-12s %b%s%b\n' "$mark" "$cli" "$__C_DIM" "$note" "$__C_RESET"
        fi
        ;;
    esac
    idx=$((idx + 1))
  done <<EOF
$items
EOF
}

_home_pick() {
  local items="$1"
  local n; n="$(printf '%s\n' "$items" | grep -c .)"
  [ "$n" -gt 0 ] || { _home_render_static "$items"; return 0; }

  # Restore the terminal on any abnormal exit.
  trap '_home_tty_leave' EXIT
  trap '_home_tty_leave; exit 130' INT TERM
  printf '\033[?1049h\033[?25l'   # enter alt screen, hide cursor

  local sel=0 key rest sel_cli
  while :; do
    _home_pick_draw "$items" "$sel"
    IFS= read -rsn1 key || { key="q"; }
    case "$key" in
      $'\e')
        # Arrow keys arrive as ESC [ A/B; a lone ESC (1s integer timeout) quits.
        if IFS= read -rsn2 -t 1 rest; then
          case "$rest" in
            '[A') sel=$(( (sel - 1 + n) % n )) ;;
            '[B') sel=$(( (sel + 1) % n )) ;;
          esac
        else
          break
        fi
        ;;
      k) sel=$(( (sel - 1 + n) % n )) ;;
      j) sel=$(( (sel + 1) % n )) ;;
      q) break ;;
      n)
        sel_cli="$(printf '%s\n' "$items" | sed -n "$((sel + 1))p" | cut -d$'\037' -f2)"
        _home_tty_leave; trap - EXIT INT TERM
        _home_new_tank "$sel_cli"
        return 0
        ;;
      ''|$'\n'|$'\r')
        _home_tty_leave; trap - EXIT INT TERM
        _home_launch "$(printf '%s\n' "$items" | sed -n "$((sel + 1))p")"
        return 0
        ;;
    esac
  done

  _home_tty_leave; trap - EXIT INT TERM
  # On quit, leave the static board in the normal scrollback.
  _home_render_static "$items"
}

cmd_home() {
  case "${1:-}" in
    -h|--help)
      cat <<'EOF'
Usage: clikae            (no arguments)

Opens the home dashboard — your "tank board". On a real terminal it's an
interactive launcher: ↑/↓ (or j/k) to move, Enter to open the selected tank,
`n` to create a new one, `q`/Esc to quit (leaving the board on screen). It lists
every profile grouped by CLI (the one active in this shell marked, with account
and alias name) plus an "Also available" section of relay-capable CLIs/targets
you can open without a tank (codex, agy), and the fuel-pool order.

When output isn't a terminal (a pipe, a script, the GUI), it prints the same
board as plain text instead. With no profiles yet it welcomes you and points at
the first step.

The full command reference is at `clikae help`; the machine check at
`clikae doctor`.
EOF
      return 0 ;;
    "") : ;;
    *) log_fail "Unexpected argument: $1  (try: clikae help)" ;;
  esac

  # Welcome only when there are genuinely no tanks (profiles).
  if [ -z "$(list_all_profiles || true)" ]; then
    _home_welcome
    return 0
  fi

  local items; items="$(_home_items)"
  # Interactive only on a real TTY (both stdin and stdout); otherwise plain text.
  if [ -t 0 ] && [ -t 1 ] && [ -z "${CLIKAE_NO_INTERACTIVE:-}" ]; then
    _home_pick "$items"
  else
    _home_render_static "$items"
  fi
}
