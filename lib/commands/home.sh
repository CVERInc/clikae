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
    # Gate on the adapter FILE existing — load_adapter exit 1s on a miss, which
    # would kill this subshell before the target branch could run.
    if [ -f "$CLIKAE_LIB/adapters/$cli.sh" ]; then
      load_adapter "$cli" >/dev/null 2>&1 || exit 0
      local var strategy value
      var="$(adapter_meta_env_var)"
      [ -n "$var" ] || exit 0     # flag-strategy CLIs aren't detectable from env
      strategy="$(adapter_meta_strategy)"
      value="${!var}"
      resolve_active_profile "$cli" "$strategy" "$value"
    elif [ -f "$CLIKAE_LIB/targets/$cli.sh" ]; then
      # Opt-in target tanks (e.g. antigravity multi-account) expose their active
      # slot via target_active_profile rather than an env var.
      # shellcheck source=/dev/null
      source "$CLIKAE_LIB/targets/$cli.sh" 2>/dev/null || exit 0
      declare -F target_active_profile >/dev/null 2>&1 && target_active_profile
    fi
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
    if [ -f "$CLIKAE_LIB/adapters/$cli.sh" ]; then
      label="$(load_adapter "$cli" >/dev/null 2>&1 && adapter_label "$path" || true)"
    else
      label=""   # target-backed tanks (e.g. antigravity) have no adapter label
    fi
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
  local tfile tname troot
  for tfile in "$CLIKAE_LIB"/targets/*.sh; do
    [ -f "$tfile" ] || continue
    tname="$(basename "$tfile" .sh)"
    # If the target has clikae profiles (opt-in multi-account mode), it's shown
    # as tanks above — don't also list it as a single-account launch target.
    troot="$(profiles_root)/$tname"
    [ -d "$troot" ] && [ -n "$(ls -A "$troot" 2>/dev/null)" ] && continue
    (
      # shellcheck source=/dev/null
      source "$tfile" 2>/dev/null || exit 0
      declare -F target_meta_binary >/dev/null 2>&1 || exit 0
      local tbin note; tbin="$(target_meta_binary)"
      command -v "$tbin" >/dev/null 2>&1 || exit 0
      note="single-account"
      declare -F target_meta_note >/dev/null 2>&1 && note="$(target_meta_note)"
      printf 'target\037%s\037%s\037\037\0370\037%s\n' "$tbin" "$tname" "$note"
    )
  done
}

# Which tanks/targets are currently over quota? Emit one row per DRY thing:
#   cli ␟ profile ␟ reset-phrase
# Backed by lib/core/limit.sh, which scans transcripts/logs — so compute this ONCE
# per board render, never per keypress. Two sources:
#   • claude tanks    — limit_profile_dry scans transcripts (codex can't: its limit
#                       is exec-stdout-only, never persisted — see limit.sh).
#   • log-only targets — limit_log_dry scans the vendor's limit log (agy's cli.log).
# Rows key on the SAME (cli, profile) pair the renderer uses, so for a target the
# key is (binary, target-name) — matching _home_items' target row (cli=$tbin,
# profile=$tname). Anything not scannable is simply never marked dry (no guessing).
_home_dry_set() {
  local cli profile path reset
  while IFS=$'\t' read -r cli profile path; do
    [ -n "$cli" ] || continue
    [ "$cli" = "claude" ] || continue
    if reset="$(limit_profile_dry "$cli" "$path")"; then
      printf '%s\037%s\037%s\n' "$cli" "$profile" "$reset"
    fi
  done <<EOF
$(list_all_profiles)
EOF

  # Log-only targets (single-account vendors like agy): scan the limit log the
  # same once-per-render way. Gate on the binary being installed, mirroring
  # _home_items, so an uninstalled vendor's stale log can't badge a row that
  # isn't even shown.
  local tfile tname
  for tfile in "$CLIKAE_LIB"/targets/*.sh; do
    [ -f "$tfile" ] || continue
    tname="$(basename "$tfile" .sh)"
    (
      # shellcheck source=/dev/null
      source "$tfile" 2>/dev/null || exit 0
      declare -F target_limit_log_path >/dev/null 2>&1 || exit 0
      declare -F target_meta_binary    >/dev/null 2>&1 || exit 0
      local tbin logf tre
      tbin="$(target_meta_binary)"
      command -v "$tbin" >/dev/null 2>&1 || exit 0
      logf="$(target_limit_log_path)"
      if tre="$(limit_log_dry "$logf")"; then
        printf '%s\037%s\037%s\n' "$tbin" "$tname" "$tre"
      fi
    )
  done
}

# Is <cli>/<profile> in the dry set ($1)? Prints its reset phrase (maybe empty)
# and returns 0 when dry, 1 when not — so:  if r="$(_home_is_dry "$dry" c p)"; then
_home_is_dry() {
  printf '%s\n' "$1" | awk -F'\037' -v c="$2" -v p="$3" \
    '$1==c && $2==p{print $3; found=1} END{exit !found}'
}

# Render the launchable items (passed as $1) as the static tank board. The dry
# set ($2, from _home_dry_set) badges over-quota tanks with ⚠.
_home_render_static() {
  local items="$1" dry="$2" any_dry=""
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
        local _reset
        if _reset="$(_home_is_dry "$dry" "$cli" "$profile")"; then
          # Over quota: ⚠ badge + the vendor's own reset phrase (a poor relay target).
          printf '    %b⚠%b %-10s %b%-28s%b %b%s%b  %b%s%b\n' \
            "$__C_YELLOW" "$__C_RESET" "$profile" "$__C_DIM" "${label:--}" "$__C_RESET" \
            "$__C_DIM" "$alias" "$__C_RESET" "$__C_YELLOW" "${_reset:-over quota}" "$__C_RESET"
          any_dry=1
          if [ "$active" = "1" ] || [ -z "$launch_cli" ]; then launch_cli="$cli"; launch_profile="$profile"; launch_alias="$alias"; fi
        elif [ "$active" = "1" ]; then
          printf '    %b●%b %-10s %b%-28s%b %b%s%b  %b← active here%b\n' \
            "$__C_GREEN" "$__C_RESET" "$profile" "$__C_DIM" "${label:--}" "$__C_RESET" \
            "$__C_DIM" "$alias" "$__C_RESET" "$__C_GREEN" "$__C_RESET"
          launch_cli="$cli"; launch_profile="$profile"; launch_alias="$alias"
        else
          printf '    %b○%b %-10s %b%-28s%b %b%s%b\n' \
            "$__C_DIM" "$__C_RESET" "$profile" "$__C_DIM" "${label:--}" "$__C_RESET" "$__C_DIM" "$alias" "$__C_RESET"
          if [ -z "$launch_cli" ]; then launch_cli="$cli"; launch_profile="$profile"; launch_alias="$alias"; fi
        fi
        ;;
      target)
        # Its own group: a single-account launch target (e.g. agy). Badge it ⚠ +
        # the vendor's verbatim reset phrase when its limit log says it's dry.
        local _treset
        if _treset="$(_home_is_dry "$dry" "$cli" "$profile")"; then
          printf '\n  %b%s%b\n    %b⚠%b %b%s%b  %b%s%b\n' \
            "$__C_BOLD" "$cli" "$__C_RESET" "$__C_YELLOW" "$__C_RESET" \
            "$__C_DIM" "$note" "$__C_RESET" "$__C_YELLOW" "${_treset:-over quota}" "$__C_RESET"
          any_dry=1
        else
          printf '\n  %b%s%b\n    %b◈%b %b%s%b\n' \
            "$__C_BOLD" "$cli" "$__C_RESET" "$__C_DIM" "$__C_RESET" "$__C_DIM" "$note" "$__C_RESET"
        fi
        ;;
      agent)
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

  if [ -n "$any_dry" ]; then
    printf '  %b⚠ over quota%b — a dry tank is a poor relay target. Open a %b○%b tank, or relay your session onto a fresh one (%bclikae relay%b / the %br%b key).\n' \
      "$__C_YELLOW" "$__C_RESET" "$__C_DIM" "$__C_RESET" "$__C_DIM" "$__C_RESET" "$__C_BOLD" "$__C_RESET"
  fi

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
    tank)
      # antigravity tanks aren't env-switchable: select the slot, then run agy.
      if [ "$cli" = "antigravity" ]; then
        "$CLIKAE_BIN" antigravity use "$profile" && exec agy
      else
        exec "$CLIKAE_BIN" run "$cli" "$profile"
      fi
      ;;
    agent)  local bin; bin="$(load_adapter "$cli" >/dev/null 2>&1 && adapter_meta_cli_binary)"; exec "$bin" ;;
    target) exec "$cli" ;;
  esac
}

# _home_choose <title> <newline-options> [preselect]  -> echo the chosen option
# to stdout (return 0), or return 1 if cancelled. An arrow-key sub-menu drawn on
# the controlling terminal (/dev/tty), so stdout stays clean for the result —
# call as:  choice="$(_home_choose ...)".
_home_choose() {
  local title="$1" optstr="$2" pre="${3:-}"
  local -a opts=()
  local o
  while IFS= read -r o; do [ -n "$o" ] && opts+=("$o"); done <<EOF
$optstr
EOF
  local n=${#opts[@]}
  [ "$n" -gt 0 ] || return 1
  # Read-write (<>) so we can both draw to and read keys from the terminal; a
  # write-only (3>) fd would EOF on the first read and cancel instantly.
  exec 3<>/dev/tty 2>/dev/null || return 1

  local sel=0 i key rest
  for ((i = 0; i < n; i++)); do [ "${opts[$i]}" = "$pre" ] && sel=$i; done

  printf '\033[?1049h\033[?25l' >&3
  # shellcheck disable=SC2064
  trap "printf '\033[?25h\033[?1049l' >&3 2>/dev/null; exec 3>&- 2>/dev/null" EXIT INT TERM
  while :; do
    {
      printf '\033[H\033[2J'
      printf '%b%s%b\n\n' "$__C_BOLD" "$title" "$__C_RESET"
      for ((i = 0; i < n; i++)); do
        if [ "$i" -eq "$sel" ]; then printf '  %b❯ %s%b\n' "$__C_GREEN" "${opts[$i]}" "$__C_RESET"
        else printf '    %s\n' "${opts[$i]}"; fi
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
        printf '\033[?25h\033[?1049l' >&3; trap - EXIT INT TERM; exec 3>&-
        printf '%s\n' "${opts[$sel]}"
        return 0 ;;
    esac
  done
  printf '\033[?25h\033[?1049l' >&3; trap - EXIT INT TERM; exec 3>&-
  return 1
}

# Delete a selected TANK (the `d` key): clikae remove prompts to confirm itself.
# Runs (not exec) so the launcher can resume afterwards.
_home_remove_tank() {
  local kind cli profile rest
  IFS=$'\037' read -r kind cli profile rest <<EOF
$1
EOF
  : "$rest"
  [ "$kind" = "tank" ] || return 0
  "$CLIKAE_BIN" remove "$cli" "$profile" || true
}

# Relay THIS shell's live session of the selected tank's CLI INTO that tank (the
# `r` key). The source is whichever profile of that CLI is active here (we marked
# it on the board); with nothing active there's no session to carry, so say so.
_home_relay() {
  local items="$1"
  local kind cli profile rest
  IFS=$'\037' read -r kind cli profile rest <<EOF
$2
EOF
  : "$rest"
  [ "$kind" = "tank" ] || return 0
  if [ "$cli" = "antigravity" ]; then
    printf 'agy is single-account — relay carries a live session between accounts of\n'
    printf 'the same CLI, which agy cannot do. Switch slots instead:\n'
    printf '  clikae antigravity use %s\n' "$profile"
    return 0
  fi
  local from
  from="$(printf '%s\n' "$items" | awk -F'\037' -v c="$cli" '$1=="tank" && $2==c && $6=="1"{print $3; exit}')"
  if [ -z "$from" ]; then
    printf 'No active %s session in this shell to relay from.\n' "$cli"
    printf 'Open one first (its alias, or `clikae run %s <profile>`), then relay.\n' "$cli"
    return 0
  fi
  if [ "$from" = "$profile" ]; then
    printf '%s/%s is already the session you are on — nothing to relay.\n' "$cli" "$profile"
    return 0
  fi
  exec "$CLIKAE_BIN" relay "$cli" "$from" "$profile"
}

# Rename the shell alias for a selected tank row (the `a` key): type a new name,
# then `clikae alias <cli> <profile> --name <new>` (which replaces the old block).
_home_rename_alias() {
  local kind cli profile label alias active note
  IFS=$'\037' read -r kind cli profile label alias active note <<EOF
$1
EOF
  : "$label" "$active" "$note"
  [ "$kind" = "tank" ] || return 0   # only tanks have a managed alias
  printf '\nRename alias for %s/%s' "$cli" "$profile"
  [ -n "$alias" ] && printf ' (currently: %s)' "$alias"
  printf '\n'
  local newname
  read -rp "  New alias name: " newname || return 0
  [ -n "$newname" ] || { printf '  Cancelled — alias unchanged.\n'; return 0; }
  "$CLIKAE_BIN" alias "$cli" "$profile" --name "$newname" || true
}

# Guided new-tank flow (the `n` key): pick a CLI with the arrow keys, then type
# the profile name, then `clikae init <cli> <profile> --alias`.
_home_new_tank() {
  local def_cli="$1" cli profile
  cli="$(_home_choose "New tank — pick a CLI    ↑↓ move · ⏎ select · q cancel" "$(list_adapters)" "$def_cli")" \
    || { printf 'Cancelled — no tank created.\n'; return 0; }
  [ -n "$cli" ] || return 0
  printf '\n'
  read -rp "Profile name for ${cli} (e.g. work, personal): " profile || return 0
  [ -n "$profile" ] || { printf 'Cancelled — no name given.\n'; return 0; }
  "$CLIKAE_BIN" init "$cli" "$profile" --alias || true
}

# Draw the menu (full redraw) with row index $2 highlighted, from items in $1.
_home_pick_draw() {
  local items="$1" sel="$2" dry="$3"
  printf '\033[H\033[2J'
  printf '%bclikae  ｷﾘｶｴ%b  %b· ↑↓ move · ⏎ open · r relay · n new · a alias · d delete · q quit%b\n\n' \
    "$__C_BOLD" "$__C_RESET" "$__C_DIM" "$__C_RESET"
  local kind cli profile label alias active note idx=0 cur_cli="" printed_also=0 mark dot _reset
  while IFS=$'\037' read -r kind cli profile label alias active note; do
    [ -n "$kind" ] || continue
    if [ "$idx" -eq "$sel" ]; then mark="${__C_GREEN}❯${__C_RESET}"; else mark=" "; fi
    case "$kind" in
      tank)
        if [ "$cli" != "$cur_cli" ]; then cur_cli="$cli"; printf '  %b%s%b\n' "$__C_BOLD" "$cli" "$__C_RESET"; fi
        if _reset="$(_home_is_dry "$dry" "$cli" "$profile")"; then dot="${__C_YELLOW}⚠${__C_RESET}"
        elif [ "$active" = "1" ]; then dot="${__C_GREEN}●${__C_RESET}"; _reset=""
        else dot="${__C_DIM}○${__C_RESET}"; _reset=""; fi
        if [ "$idx" -eq "$sel" ]; then
          printf '  %b %b %b%-10s %-28s %s%b  %b%s%b\n' "$mark" "$dot" "$__C_BOLD" "$profile" "${label:--}" "$alias" "$__C_RESET" "$__C_YELLOW" "$_reset" "$__C_RESET"
        else
          printf '  %b %b %-10s %b%-28s %s%b  %b%s%b\n' "$mark" "$dot" "$profile" "$__C_DIM" "${label:--}" "$alias" "$__C_RESET" "$__C_YELLOW" "$_reset" "$__C_RESET"
        fi
        ;;
      target)
        printf '  %b%s%b\n' "$__C_BOLD" "$cli" "$__C_RESET"
        local tdot
        if _reset="$(_home_is_dry "$dry" "$cli" "$profile")"; then tdot="${__C_YELLOW}⚠${__C_RESET}"
        else tdot="${__C_DIM}◈${__C_RESET}"; _reset=""; fi
        if [ "$idx" -eq "$sel" ]; then
          printf '  %b %b %b%s %b%s%b\n' "$mark" "$tdot" "$__C_BOLD" "$note" "$__C_YELLOW" "$_reset" "$__C_RESET"
        else
          printf '  %b %b %b%s%b %b%s%b\n' "$mark" "$tdot" "$__C_DIM" "$note" "$__C_RESET" "$__C_YELLOW" "$_reset" "$__C_RESET"
        fi
        ;;
      agent)
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

# Run a non-launching action (rename/new/delete) in the NORMAL screen, then wait
# for Enter and resume the picker — so a single op doesn't drop you back to the
# shell. The EXIT trap stays armed throughout; we only leave/re-enter the alt
# screen around the action's own prompts.
_home_stay() {
  _home_tty_leave                 # drop to the normal screen for prompts/output
  "$@" || true
  printf '\n  %b↵ back to clikae%b ' "$__C_DIM" "$__C_RESET"
  local _discard; IFS= read -r _discard || true
  printf '\033[?1049h\033[?25l'   # re-enter alt screen, hide cursor
}

_home_pick() {
  local items="$1" dry="$2"

  # Restore the terminal on any abnormal exit.
  trap '_home_tty_leave' EXIT
  trap '_home_tty_leave; exit 130' INT TERM
  printf '\033[?1049h\033[?25l'   # enter alt screen, hide cursor

  local sel=0 key rest n sel_row sel_kind sel_cli
  while :; do
    n="$(printf '%s\n' "$items" | grep -c .)"
    [ "$n" -gt 0 ] || break                 # nothing left to pick
    [ "$sel" -ge "$n" ] && sel=$((n - 1))    # clamp after a delete
    [ "$sel" -lt 0 ] && sel=0
    _home_pick_draw "$items" "$sel" "$dry"
    IFS= read -rsn1 key || { key="q"; }
    sel_row="$(printf '%s\n' "$items" | sed -n "$((sel + 1))p")"
    sel_kind="$(printf '%s' "$sel_row" | cut -d$'\037' -f1)"
    sel_cli="$(printf '%s' "$sel_row" | cut -d$'\037' -f2)"
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

      # --- leave actions: these launch a CLI, so exiting the picker is expected
      ''|$'\n'|$'\r')
        _home_tty_leave; trap - EXIT INT TERM
        _home_launch "$sel_row"
        return 0
        ;;
      r)
        if [ "$sel_kind" = "tank" ]; then
          _home_tty_leave; trap - EXIT INT TERM
          _home_relay "$items" "$sel_row"
          return 0
        fi
        ;;

      # --- stay actions: mutate, then return to the live menu ---
      n)
        _home_stay _home_new_tank "$sel_cli"
        items="$(_home_items)"; dry="$(_home_dry_set)"
        ;;
      a)
        if [ "$sel_kind" = "tank" ]; then
          _home_stay _home_rename_alias "$sel_row"
          items="$(_home_items)"; dry="$(_home_dry_set)"
        fi
        ;;
      d)
        if [ "$sel_kind" = "tank" ]; then
          _home_stay _home_remove_tank "$sel_row"
          items="$(_home_items)"; dry="$(_home_dry_set)"
        fi
        ;;
    esac
  done

  _home_tty_leave; trap - EXIT INT TERM
  # On quit, leave the static board in the normal scrollback.
  _home_render_static "$items" "$dry"
}

cmd_home() {
  case "${1:-}" in
    -h|--help)
      cat <<'EOF'
Usage: clikae            (no arguments)

Opens the home dashboard — your "tank board". On a real terminal it's an
interactive launcher: ↑/↓ (or j/k) to move, Enter to open the selected tank,
`r` to relay this shell's session to it, `n` to create a new tank, `a` to rename
a tank's alias, `d` to delete a tank (asks first), `q`/Esc to quit (leaving the
board on screen). It lists
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

  local items dry; items="$(_home_items)"; dry="$(_home_dry_set)"
  # Interactive only on a real TTY (both stdin and stdout); otherwise plain text.
  if [ -t 0 ] && [ -t 1 ] && [ -z "${CLIKAE_NO_INTERACTIVE:-}" ]; then
    _home_pick "$items" "$dry"
  else
    _home_render_static "$items" "$dry"
  fi
}
