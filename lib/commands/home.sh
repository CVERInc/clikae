# shellcheck shell=bash
# lib/commands/home.sh — `clikae` with no arguments opens here: your home
# dashboard, the screen clikae wants to be the first thing you type.
#
#   have tanks -> the "tank board": every profile (tank) grouped by CLI, the one
#                 active in THIS shell marked, account + real alias name, plus an
#                 "Also available" line for relay-capable CLIs/targets you could
#                 open even without a tank yet (e.g. codex, agy).
#   no tanks   -> a welcome: what clikae found on this machine + the first step.
# The full command reference is one keystroke away at `clikae help`; the deep
# machine check at `clikae doctor`. All read-only.

# _home_active_for <engine>  -> the profile active for <engine> in THIS shell, or empty.
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

# _home_alias_for <engine> <tank>  -> the managed alias NAME from the shell rc,
# or empty. The block opens with `# >>> clikae:<engine>.<tank> >>>` and the alias
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

# _home_recent_rows -> the "continue" list: THIS directory's most recent sessions
# (newest first, capped at CLIKAE_HOME_RECENT_MAX) across ALL engines+tanks — but
# only for engines that can RESUME a session by id (adapter_resume_args), so the
# "接回" affordance never lies. Each row carries the ai-title (label) and a one-line
# RECAP (alias field) — "where you left off + next step" — fetched only for the few
# rows shown, so the listing stays cheap. Emits, newest first:
#   resume ␟ <engine> ␟ <tank> ␟ <title> ␟ <recap> ␟ ␟ <session-id>
# How many recent sessions the "continue" list surfaces.
CLIKAE_HOME_RECENT_MAX="${CLIKAE_HOME_RECENT_MAX:-3}"

_home_recent_rows() {
  local name proot tdir tank rows sid mt acc=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    ( load_adapter "$name" >/dev/null 2>&1 \
        && declare -F adapter_resume_args >/dev/null 2>&1 \
        && declare -F adapter_recent_sids >/dev/null 2>&1 ) || continue
    proot="$(profiles_root)/$name"
    [ -d "$proot" ] || continue
    for tdir in "$proot"/*/; do
      [ -d "$tdir" ] || continue
      tank="$(basename "$tdir")"
      # CHEAP: just epoch-mtime + sid per recent session (no content reads).
      rows="$( load_adapter "$name" >/dev/null 2>&1 && adapter_recent_sids "${tdir%/}" "$CLIKAE_HOME_RECENT_MAX" 2>/dev/null || true )"
      [ -n "$rows" ] || continue
      while IFS=$'\037' read -r mt sid; do
        [ -n "$sid" ] || continue
        acc="$acc$mt"$'\037'"$name"$'\037'"$tank"$'\037'"$sid"$'\n'
      done <<INNER
$rows
INNER
    done
  done <<EOF
$(list_adapters)
EOF
  [ -n "$acc" ] || return 0
  # Rank newest-first by epoch mtime, keep top N, and only THEN read each one's
  # title + recap (the only content greps — bounded to the few rows actually shown).
  printf '%s' "$acc" | sort -t$'\037' -k1,1 -rn | head -n "$CLIKAE_HOME_RECENT_MAX" \
    | while IFS=$'\037' read -r mt engine tank sid; do
        [ -n "$sid" ] || continue
        local dir title recap age now _d aflag _act
        dir="$(profile_dir "$engine" "$tank")"
        load_adapter "$engine" >/dev/null 2>&1 || true
        if declare -F adapter_session_title >/dev/null 2>&1; then
          title="$(adapter_session_title "$dir" "$sid" 2>/dev/null || true)"
        else
          title="$(adapter_session_meta "$dir" "$sid" 2>/dev/null | cut -d$'\037' -f4 || true)"
        fi
        recap="$(adapter_session_recap "$dir" "$sid" 2>/dev/null || true)"
        # Human age (epoch mtime -> "5m / 3h / 2d"), the hover detail when a session
        # has no recap, so the expand is always visible.
        now="$(date +%s 2>/dev/null || echo "$mt")"; _d=$(( now - mt ))
        if   [ "$_d" -lt 60 ];    then age="just now"
        elif [ "$_d" -lt 3600 ];  then age="$(( _d / 60 ))m ago"
        elif [ "$_d" -lt 86400 ]; then age="$(( _d / 3600 ))h ago"
        else                           age="$(( _d / 86400 ))d ago"; fi
        # Is this session on the tank you're currently using? (● vs ○). Packed into
        # the active field as "<flag> <age>" so the draw has both.
        aflag="0"; _act="$(_home_active_for "$engine" 2>/dev/null || true)"
        [ -n "$_act" ] && [ "$_act" = "$tank" ] && aflag="1"
        printf 'resume\037%s\037%s\037%s\037%s\037%s %s\037%s\n' "$engine" "$tank" "$title" "$recap" "$aflag" "$age" "$sid"
      done
}

# _home_items  -> one canonical launchable row per "thing you can open", fields
# separated by ASCII Unit Separator (\037):
#   kind ␟ cli ␟ profile ␟ label ␟ alias ␟ active(1|0) ␟ note
# kind ∈ tank (a profile) | agent (a relay-capable CLI with no tank yet, e.g.
# codex) | target (a single-account launch-only target, e.g. agy). Tanks come
# first, sorted by CLI then profile, so the renderer can group as it reads.
_home_items() {
  # 0) Continue list — this dir's most recent resumable sessions, if any.
  _home_recent_rows

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
      printf 'agent\037%s\037\037\037\0370\037%s\n' "$name" "$T_NO_TANK_DEFAULT"
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

# Is <engine>/<tank> in the dry set ($1)? Prints its reset phrase (maybe empty)
# and returns 0 when dry, 1 when not — so:  if r="$(_home_is_dry "$dry" c p)"; then
_home_is_dry() {
  printf '%s\n' "$1" | awk -F'\037' -v c="$2" -v p="$3" \
    '$1==c && $2==p{print $3; found=1} END{exit !found}'
}

# _home_wrap_prefixed <text> <prefix> <hang> <color> <reset> [extra]
# Word-wrap <text> to the live terminal width, printing the FIRST line as
# "<prefix><chunk>" and every continuation line as "<hang spaces><chunk>" — a
# hanging indent so a long recap's wrapped lines align under its first word, not
# the left margin. <color>/<reset> are %b colour codes applied per line (so the
# dim style survives the newline). <extra> is any outer indent the CALLER adds
# around this block (the interactive picker pipes through a `  ` prefix, so it
# passes 2) — subtracted from the width budget so the first line can't overflow.
# Width via `stty size </dev/tty` (works inside $()); 80 fallback. Byte-length
# math, so CJK recaps wrap a touch early — acceptable, never overflows.
_home_wrap_prefixed() {
  local text="$1" prefix="$2" hang="$3" color="$4" reset="$5" extra="${6:-0}"
  local cols pad first=1 word line="" avail glob=0
  cols="$( { stty size </dev/tty | awk '{print $2}'; } 2>/dev/null || true )"
  case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
  [ "$cols" -ge 30 ] || cols=80
  pad="$(printf '%*s' "$hang" '')"
  avail=$(( cols - hang - extra - 1 ))
  [ "$avail" -ge 12 ] || avail=$(( cols - extra - 1 ))
  # Don't let a `*` in a recap glob against the cwd while we word-split.
  case $- in *f*) ;; *) glob=1; set -f ;; esac
  for word in $text; do
    if [ -z "$line" ]; then
      line="$word"
    elif [ "$(( ${#line} + 1 + ${#word} ))" -le "$avail" ]; then
      line="$line $word"
    else
      if [ "$first" -eq 1 ]; then printf '%b%s%s%b\n' "$color" "$prefix" "$line" "$reset"; first=0
      else printf '%b%s%s%b\n' "$color" "$pad" "$line" "$reset"; fi
      line="$word"
    fi
  done
  if [ -n "$line" ]; then
    if [ "$first" -eq 1 ]; then printf '%b%s%s%b\n' "$color" "$prefix" "$line" "$reset"
    else printf '%b%s%s%b\n' "$color" "$pad" "$line" "$reset"; fi
  fi
  [ "$glob" -eq 1 ] && set +f
  return 0
}

# _dwidth <str> -> the string's DISPLAY width in terminal columns, counting CJK /
# fullwidth glyphs as 2. Heuristic but bash-3.2-safe and dependency-free: in a
# UTF-8 locale `${#s}` is the CHARACTER count and `wc -c` the BYTE count, so the
# 3-byte (CJK) chars contribute (bytes-chars)/2 extra columns. In a C/POSIX locale
# `${#s}` already equals bytes, so this collapses to the byte count — i.e. it
# degrades gracefully to the old %-Ns behaviour, never worse.
_dwidth() {
  local s="$1" chars bytes
  chars=${#s}
  bytes=$(printf '%s' "$s" | wc -c); bytes=${bytes//[^0-9]/}
  printf '%s' "$(( chars + (bytes - chars) / 2 ))"
}

# _home_lpad <str> <width> -> <str> right-padded with spaces to <width> DISPLAY
# columns (so a CJK label lines up the same as an ASCII one). The drop-in for a
# `%-<width>s` that would otherwise mis-measure multibyte text.
_home_lpad() {
  local s="$1" w="$2" dw pad
  dw="$(_dwidth "$s")"
  pad=$(( w - dw )); [ "$pad" -lt 0 ] && pad=0
  printf '%s%*s' "$s" "$pad" ''
}

# Render the launchable items (passed as $1) as the static tank board. The dry
# set ($2, from _home_dry_set) badges over-quota tanks with !.
_home_render_static() {
  local items="$1" dry="$2" any_dry=""
  local n_tanks n_clis
  n_tanks="$(printf '%s\n' "$items" | awk -F'\037' '$1=="tank"' | grep -c .)"
  n_clis="$(printf '%s\n' "$items" | awk -F'\037' '$1=="tank"{print $2}' | sort -u | grep -c .)"
  printf '%b%s%b  %b·  %s%b\n\n' \
    "$__C_BOLD" "$T_WORDMARK" "$__C_RESET" "$__C_DIM" "$(i18n_summary "$n_tanks" "$n_clis")" "$__C_RESET"

  local kind cli profile label alias active note cur_cli="" cli_count also="" printed_resume=0 rdot
  local launch_cli="" launch_profile="" launch_alias=""
  while IFS=$'\037' read -r kind cli profile label alias active note; do
    [ -n "$kind" ] || continue
    case "$kind" in
      resume)
        # The "continue" list: this dir's recent resumable sessions, each with its
        # ai-title and a one-line recap when present.
        if [ "$printed_resume" -eq 0 ]; then printed_resume=1; printf '  %b%s%b\n' "$__C_BCYAN" "$T_CONTINUE" "$__C_RESET"; fi
        if [ "${active%% *}" = "1" ]; then rdot="${__C_GREEN}●${__C_RESET}"; else rdot="${__C_DIM}○${__C_RESET}"; fi
        printf '    %b %b%s/%s%b · %b"%s"%b\n' "$rdot" "$__C_BOLD" "$cli" "$profile" "$__C_RESET" "$__C_DIM" "$label" "$__C_RESET"
        # recap (carried in the alias field): word-wrapped with a hanging indent so
        # long recaps align under their first word instead of spilling to column 0.
        [ -n "$alias" ] && _home_wrap_prefixed "$alias" "        -> " 11 "$__C_DIM" "$__C_RESET"
        ;;
      tank)
        if [ "$cli" != "$cur_cli" ]; then
          [ -z "$cur_cli" ] && [ "$printed_resume" -eq 1 ] && printf '\n'
          cur_cli="$cli"
          cli_count="$(printf '%s\n' "$items" | awk -F'\037' -v c="$cli" '$1=="tank" && $2==c' | grep -c .)"
          printf '  %b%s%b %b(%s)%b\n' "$__C_BOLD" "$cli" "$__C_RESET" "$__C_DIM" "$cli_count" "$__C_RESET"
        fi
        local _reset
        if _reset="$(_home_is_dry "$dry" "$cli" "$profile")"; then
          # Over quota: ! badge + the vendor's own reset phrase (a poor relay target).
          printf '    %b!%b %-10s %b%-28s%b %b%s%b  %b%s%b\n' \
            "$__C_YELLOW" "$__C_RESET" "$profile" "$__C_DIM" "${label:--}" "$__C_RESET" \
            "$__C_DIM" "$alias" "$__C_RESET" "$__C_YELLOW" "${_reset:-over quota}" "$__C_RESET"
          any_dry=1
          if [ "$active" = "1" ] || [ -z "$launch_cli" ]; then launch_cli="$cli"; launch_profile="$profile"; launch_alias="$alias"; fi
        elif [ "$active" = "1" ]; then
          printf '    %b●%b %-10s %b%-28s%b %b%s%b  %b← %s%b\n' \
            "$__C_GREEN" "$__C_RESET" "$profile" "$__C_DIM" "${label:--}" "$__C_RESET" \
            "$__C_DIM" "$alias" "$__C_RESET" "$__C_GREEN" "$T_ACTIVE_HERE" "$__C_RESET"
          launch_cli="$cli"; launch_profile="$profile"; launch_alias="$alias"
        else
          printf '    %b○%b %-10s %b%-28s%b %b%s%b\n' \
            "$__C_DIM" "$__C_RESET" "$profile" "$__C_DIM" "${label:--}" "$__C_RESET" "$__C_DIM" "$alias" "$__C_RESET"
          if [ -z "$launch_cli" ]; then launch_cli="$cli"; launch_profile="$profile"; launch_alias="$alias"; fi
        fi
        ;;
      target)
        # Its own group: a single-account launch target (e.g. agy). Badge it ! +
        # the vendor's verbatim reset phrase when its limit log says it's dry.
        local _treset
        if _treset="$(_home_is_dry "$dry" "$cli" "$profile")"; then
          printf '\n  %b%s%b\n    %b!%b %b%s%b  %b%s%b\n' \
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
    printf '\n  %b%s%b\n' "$__C_BOLD" "$T_ALSO_AVAILABLE" "$__C_RESET"
    printf '%s' "$also"
  fi
  echo ""

  if [ -n "$any_dry" ]; then
    printf '  %b! %s%b — %s\n' \
      "$__C_YELLOW" "$T_OVER_QUOTA" "$__C_RESET" "$T_OVER_QUOTA_HINT"
  fi

  if [ -n "$launch_cli" ]; then
    # Colour via %b args, never embedded in a %s string (the codes are literal
    # \033 sequences and only printf %b interprets them).
    if [ -n "$launch_alias" ]; then
      printf '  %s clikae %s %s   %b(%s: %s)%b\n' \
        "$(_home_lpad "$T_LAUNCH" 9)" "$launch_cli" "$launch_profile" "$__C_DIM" "$T_OR_ALIAS" "$launch_alias" "$__C_RESET"
    else
      printf '  %s clikae %s %s\n' "$(_home_lpad "$T_LAUNCH" 9)" "$launch_cli" "$launch_profile"
    fi
  fi
  printf '  %s %s\n' "$(_home_lpad "$T_MORE" 9)" "clikae status · clikae doctor · clikae demo · clikae help"
}

# The welcome screen, shown when there are no tanks yet. RESPONSIVE (like a web
# page reflowing): on a wide terminal the logo sits on the LEFT with the copy
# beside it on the RIGHT (filling the logo's empty side); on a narrow terminal or
# a pipe it stacks. The copy is one styled line per element (short enough to sit
# beside the logo). Colour codes are literal \033 strings → printed with %b.
_home_welcome() {
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
  [ -n "$installed" ] && example="$(printf '%s' "$installed" | awk '{print $1}')"

  local -a BODY=()
  BODY+=("${__C_BOLD}${T_WORDMARK}${__C_RESET}")
  BODY+=("${T_TAGLINE1}")
  BODY+=("${__C_DIM}${T_TAGLINE2}${__C_RESET}")
  BODY+=("")
  if [ -n "$installed" ]; then
    BODY+=("${__C_BOLD}${T_NO_TANKS_YET}${__C_RESET} · ${total} ${T_ENGINES_HERE}")
    BODY+=("  ${__C_GREEN}${installed}${__C_RESET}")
  else
    BODY+=("${__C_BOLD}${T_NO_TANKS_YET}${__C_RESET} · ${total} ${T_ENGINES_SUPPORTED}")
    BODY+=("  ${__C_DIM}${T_NONE_DETECTED}${__C_RESET}")
  fi
  BODY+=("")
  BODY+=("${__C_BOLD}${T_FILL_FIRST}${__C_RESET}")
  BODY+=("  clikae init ${example} work --alias")
  BODY+=("")
  BODY+=("${__C_DIM}${T_CURIOUS_DEMO}${__C_RESET}")

  # Wide TTY → side-by-side; else stacked. (BODY is visible to the renderers via
  # bash's dynamic scope.)
  # Live terminal width. NB: `tput cols` inside $(...) reads its piped stdout, not
  # the tty, so it returns the terminfo default (usually 80) regardless of the
  # real window — useless here. `stty size </dev/tty` reads the controlling
  # terminal directly, so it's correct even inside a command substitution.
  local logo="$CLIKAE_ROOT/assets/logo.txt" cols
  # Only measure width when actually on a terminal (a pipe is stacked anyway, and
  # reading /dev/tty off a pipe just errors). NB: `stty size </dev/tty` — NOT
  # `tput cols`, which returns the terminfo default (80) when its stdout is the
  # command-substitution pipe, so it can't see a narrow window. Group-redirect
  # stderr so a missing /dev/tty stays silent; `|| true` so set -e can't abort.
  if [ -t 1 ] && [ -f "$logo" ]; then
    cols="$( { stty size </dev/tty | awk '{print $2}'; } 2>/dev/null || true )"
    [ -n "$cols" ] || cols="$(tput cols 2>/dev/null || echo 80)"
    if [ "${cols:-0}" -ge 76 ]; then
      _home_welcome_beside "$logo"
      return
    fi
  fi
  _home_welcome_stacked "$logo"
}

# Logo on top, copy below (also the no-logo / piped / narrow fallback).
_home_welcome_stacked() {
  local logo="$1" i
  if [ -f "$logo" ]; then
    printf '%b' "$__C_BCYAN"; cat "$logo"; printf '%b\n\n' "$__C_RESET"
  fi
  for ((i = 0; i < ${#BODY[@]}; i++)); do
    printf '  %b\n' "${BODY[i]}"
  done
}

# Logo on the LEFT, copy on the RIGHT — placed with absolute cursor-column moves
# (\033[<col>G), so no multibyte-width padding math is needed. Wide TTY only.
_home_welcome_beside() {
  local logo="$1" line i j start
  local -a L=()
  while IFS= read -r line || [ -n "$line" ]; do L+=("$line"); done < "$logo"
  local lh=${#L[@]} bh=${#BODY[@]}
  start=$(( (lh - bh) / 2 )); [ "$start" -lt 0 ] && start=0
  echo ""
  for ((i = 0; i < lh; i++)); do
    printf '%b%s%b' "$__C_BCYAN" "${L[i]}" "$__C_RESET"
    j=$(( i - start ))
    if [ "$j" -ge 0 ] && [ "$j" -lt "$bh" ]; then
      printf '\033[42G%b' "${BODY[j]}"
    fi
    printf '\n'
  done
  echo ""
}

# ---------------------------------------------------------------------------
# Interactive launcher (only on a real TTY; pipes/scripts/tests get the static
# board). Uses the alternate screen buffer so the user's scrollback is intact.

_home_tty_leave() { printf '\033[?25h\033[?1049l'; }   # show cursor, leave alt screen

# Resolve and EXEC the launch for one item row (replaces this process).
#   tank   -> clikae <engine> <tank>   (the bare switch: applies env, then execs)
#   agent  -> the CLI's own binary, default config (no tank)
#   target -> the target's binary (already in the cli field)
_home_launch() {
  local kind cli profile label alias active note
  IFS=$'\037' read -r kind cli profile label alias active note <<EOF
$1
EOF
  : "$label" "$alias" "$active" "$note"
  case "$kind" in
    resume)
      # Reopen this dir's most recent session: clikae <engine> <tank> -- <resume-args>.
      # note carries the session id; the engine's adapter_resume_args turns it into
      # the right flags (Claude: --resume <sid>). cmd_switch forwards everything
      # after `--` straight to the engine.
      local -a _rargs=(); local _ra
      while IFS= read -r _ra; do [ -n "$_ra" ] && _rargs+=("$_ra"); done <<EOF
$(load_adapter "$cli" >/dev/null 2>&1 && adapter_resume_args "$note" 2>/dev/null || true)
EOF
      if [ "${#_rargs[@]}" -gt 0 ]; then
        exec "$CLIKAE_BIN" "$cli" "$profile" -- "${_rargs[@]}"
      else
        exec "$CLIKAE_BIN" "$cli" "$profile"
      fi
      ;;
    tank)
      # antigravity tanks aren't env-switchable: `clikae agy <tank>` repoints the
      # symlink and execs agy. Everything else is the bare switch.
      if [ "$cli" = "antigravity" ]; then
        exec "$CLIKAE_BIN" agy "$profile"
      else
        exec "$CLIKAE_BIN" "$cli" "$profile"
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
    printf 'agy is global single-account — `to` carries a live session between tanks of\n'
    printf 'the same engine, which agy cannot do. Switch tanks instead:\n'
    printf '  clikae agy %s\n' "$profile"
    return 0
  fi
  local from
  from="$(printf '%s\n' "$items" | awk -F'\037' -v c="$cli" '$1=="tank" && $2==c && $6=="1"{print $3; exit}')"
  if [ -z "$from" ]; then
    printf 'No active %s session in this shell to relay from.\n' "$cli"
    printf 'Open one first (its alias, or `clikae %s <tank>`), then relay.\n' "$cli"
    return 0
  fi
  if [ "$from" = "$profile" ]; then
    printf '%s/%s is already the session you are on — nothing to relay.\n' "$cli" "$profile"
    return 0
  fi
  exec "$CLIKAE_BIN" relay "$cli" "$from" "$profile"
}

# Rename the selected TANK (the `a` key): type a new name, then
# `clikae rename <engine> <old> <new>` — the powerful rename that moves the tank
# dir, rewrites the managed alias, AND carries the saved login across. Per the
# v0.5.3 design, `a` is "rename" (the whole tank); alias-only tweaks live at
# `clikae alias` on the CLI. agy/antigravity tanks are a global ~/.gemini symlink
# target, not a per-shell engine, so rename doesn't apply to them.
_home_rename_tank() {
  local kind cli profile label alias active note
  IFS=$'\037' read -r kind cli profile label alias active note <<EOF
$1
EOF
  : "$label" "$alias" "$active" "$note"
  [ "$kind" = "tank" ] || return 0
  if [ "$cli" = "antigravity" ]; then
    printf '\n  %s\n' "$T_RENAME_NO_AGY"
    return 0
  fi
  printf '\n%s  %s/%s\n' "$T_RENAME_FOR" "$cli" "$profile"
  local newname
  read -rp "  $T_RENAME_NEW" newname || return 0
  [ -n "$newname" ] || { printf '  %s\n' "$T_RENAME_CANCEL"; return 0; }
  "$CLIKAE_BIN" rename "$cli" "$profile" "$newname" || true
}

# Enter on a 續上次 / Continue row → a tiny submenu (v0.5.3 item 5): resume the
# exact session, or just switch to that tank with a fresh session. Both choices
# exec; cancel (q) returns 1 so the caller can re-enter the picker.
_home_resume_action() {
  local row="$1" kind cli profile rest
  IFS=$'\037' read -r kind cli profile rest <<EOF
$row
EOF
  : "$rest"
  local opts choice
  opts="$(printf '%s\n%s' "$T_RESUME_OPT_RESUME" "$T_RESUME_OPT_SWITCH")"
  choice="$(_home_choose "$T_RESUME_TITLE  ($cli/$profile)" "$opts" "$T_RESUME_OPT_RESUME")" || return 1
  if [ "$choice" = "$T_RESUME_OPT_SWITCH" ]; then
    # 換油箱開新局: bare switch, no --resume.
    if [ "$cli" = "antigravity" ]; then exec "$CLIKAE_BIN" agy "$profile"
    else exec "$CLIKAE_BIN" "$cli" "$profile"; fi
  else
    _home_launch "$row"   # 接回: the resume path (kind=resume → --resume <sid>)
  fi
}

# Guided new-tank flow (the `n` key): pick a CLI with the arrow keys, then type
# the tank name, then `clikae init <engine> <tank> --alias`.
_home_new_tank() {
  local def_cli="$1" cli profile
  cli="$(_home_choose "$T_NEWTANK_TITLE    $T_PICKER_HINT" "$(list_adapters)" "$def_cli")" \
    || { printf '%s\n' "$T_NEWTANK_CANCEL"; return 0; }
  [ -n "$cli" ] || return 0
  printf '\n'
  read -rp "$(printf "$T_NEWTANK_PROFILE" "$cli")" profile || return 0
  [ -n "$profile" ] || { printf '%s\n' "$T_NEWTANK_NONAME"; return 0; }
  "$CLIKAE_BIN" init "$cli" "$profile" --alias || true
}

# _home_filter <items> <query> — keep only rows whose text contains <query>
# (case-insensitive, literal). Empty query → everything. Group headers in the
# renderer are derived from the surviving rows, so filtering lines is enough.
_home_filter() {
  local items="$1" q="$2"
  [ -n "$q" ] || { printf '%s' "$items"; return 0; }
  printf '%s\n' "$items" | grep -i -F -- "$q" || true
}

# _home_help_row <keys> <description> — one aligned line in the help overlay.
_home_help_row() { printf '    %b%-16s%b %s\n' "$__C_BOLD" "$1" "$__C_RESET" "$2"; }

# The `?` key: a full, localised key legend drawn over the board (alt screen is
# already active). Any key dismisses it; the loop then repaints the board.
_home_help_overlay() {
  printf '\033[H\033[2J'
  printf '  %b%s%b\n\n' "$__C_BOLD" "$T_HELP_TITLE" "$__C_RESET"
  _home_help_row "↑ ↓  j k  Tab" "$T_K_MOVE"
  _home_help_row "g / G"         "$T_K_TOPBOTTOM"
  _home_help_row "1-9"           "$T_K_JUMP"
  _home_help_row "⏎ Enter"       "$T_K_OPEN"
  _home_help_row "r"             "$T_K_RELAY"
  _home_help_row "x"             "$T_K_INCOGNITO"
  _home_help_row "n"             "$T_K_NEW"
  _home_help_row "a"             "$T_K_RENAME"
  _home_help_row "d"             "$T_K_DELETE"
  _home_help_row "/"             "$T_K_FILTER"
  _home_help_row "h"             "$T_K_LANG"
  _home_help_row "q / Esc"       "$T_K_QUIT"
  printf '\n  %b%s%b' "$__C_DIM" "$T_HELP_DISMISS" "$__C_RESET"
  local _k; IFS= read -rsn1 _k || true
}

# Draw the menu (full redraw) with row index $2 highlighted, from items in $1.
_home_pick_draw() {
  # Single-write flicker fix: _home_pick_draw_body composes the whole frame via
  # printf to a captured string; we then write it to the terminal in ONE printf.
  # Repainting line-by-line (a write per row) is what still flickered.
  local _frame
  _frame="$(_home_pick_draw_body "$@")"
  printf '%s' "$_frame"
}
_home_pick_draw_body() {
  local items="$1" sel="$2" dry="$3"
  # Flicker-free paint: home the cursor and overwrite in place — NO `\033[2J`
  # full-screen clear (the momentary blank frame is exactly what flickered on
  # each keypress). Leftover lines from a taller previous frame are erased with
  # `\033[J` after the content, and the logo is drawn LAST (below) so that erase
  # can't clip it. Row widths are stable frame-to-frame, so no per-line erase yet.
  local kind cli profile label alias active note idx=0 cur_cli="" printed_also=0 printed_resume=0 mark dot _reset tdot _line rdot rage
  printf '\033[H\033[K\n'   # home + one blank top-margin line
  # Repaint the whole frame, clearing each line to end-of-line (\033[K) so a row
  # that COLLAPSES when the cursor moves away (hover → fewer chars) leaves no stale
  # tail. The logo is drawn AFTER this, so the full-width erase here can't clip it.
  # (Vars are declared above, outside this pipe's subshell, so no `local` here.)
  {
  # Compact footer: the everyday keys + a pointer to `?` for the full, localised
  # legend (relay / incognito / new / rename / delete / jump). Keeps the board
  # clean while every action stays discoverable.
  printf '%b%s%b  %b· ↑↓/Tab %s · ⏎ %s · / %s · ? %s · h %s · q %s%b\n\n' \
    "$__C_BOLD" "$T_WORDMARK" "$__C_RESET" "$__C_DIM" \
    "$T_K_MOVE" "$T_K_OPEN" "$T_K_FILTER" "$T_K_HELP" "$T_K_LANG" "$T_K_QUIT" "$__C_RESET"
  while IFS=$'\037' read -r kind cli profile label alias active note; do
    [ -n "$kind" ] || continue
    if [ "$idx" -eq "$sel" ]; then mark="${__C_GREEN}❯${__C_RESET}"; else mark=" "; fi
    case "$kind" in
      resume)
        # The "continue" list — recent resumable sessions; Enter reopens the
        # selected one. Title is Claude's ai-title; the selected row also shows a
        # one-line recap ("where you left off + next step").
        if [ "$printed_resume" -eq 0 ]; then printed_resume=1; printf '  %b%s%b\n' "$__C_BCYAN" "$T_CONTINUE" "$__C_RESET"; fi
        # active field is "<flag> <age>": flag 1 = this session is on the tank you're
        # using now (●), else ○. Age is the hover fallback when there's no recap.
        if [ "${active%% *}" = "1" ]; then rdot="${__C_GREEN}●${__C_RESET}"; else rdot="${__C_DIM}○${__C_RESET}"; fi
        rage="${active#* }"
        if [ "$idx" -eq "$sel" ]; then
          printf '  %b %b %b%s/%s%b · "%s"\n' "$mark" "$rdot" "$__C_BOLD" "$cli" "$profile" "$__C_RESET" "$label"
          if [ -n "$alias" ]; then
            # recap, wrapped with a hanging indent. extra=2 for the wrapper's `  ` prefix.
            _home_wrap_prefixed "$alias" "        -> " 11 "$__C_DIM" "$__C_RESET" 2
          else
            printf '        %b%s · %s%b\n' "$__C_DIM" "$rage" "$T_ENTER_RESUME" "$__C_RESET"
          fi
        else
          printf '  %b %b %b%s/%s · "%s"%b\n' "$mark" "$rdot" "$__C_DIM" "$cli" "$profile" "$label" "$__C_RESET"
        fi
        ;;
      tank)
        if [ "$cli" != "$cur_cli" ]; then
          [ -z "$cur_cli" ] && [ "$printed_resume" -eq 1 ] && printf '\n'
          cur_cli="$cli"; printf '  %b%s%b\n' "$__C_BOLD" "$cli" "$__C_RESET"
        fi
        if _reset="$(_home_is_dry "$dry" "$cli" "$profile")"; then dot="${__C_YELLOW}!${__C_RESET}"
        elif [ "$active" = "1" ]; then dot="${__C_GREEN}●${__C_RESET}"; _reset=""
        else dot="${__C_DIM}○${__C_RESET}"; _reset=""; fi
        if [ "$idx" -eq "$sel" ]; then
          # Selected → EXPANDED: account label, alias, and any reset time (hover detail).
          printf '  %b %b %b%-10s %-28s %s%b  %b%s%b\n' "$mark" "$dot" "$__C_BOLD" "$profile" "${label:--}" "$alias" "$__C_RESET" "$__C_YELLOW" "$_reset" "$__C_RESET"
        elif [ -n "$_reset" ]; then
          # Unselected but DRY → collapsed name + reset time (the warning still shows).
          printf '  %b %b %s  %b%s%b\n' "$mark" "$dot" "$profile" "$__C_YELLOW" "$_reset" "$__C_RESET"
        else
          # Unselected → COLLAPSED: just the status dot + tank name. Hover to expand.
          printf '  %b %b %s\n' "$mark" "$dot" "$profile"
        fi
        ;;
      target)
        printf '  %b%s%b\n' "$__C_BOLD" "$cli" "$__C_RESET"
        if _reset="$(_home_is_dry "$dry" "$cli" "$profile")"; then tdot="${__C_YELLOW}!${__C_RESET}"
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
  } | while IFS= read -r _line || [ -n "$_line" ]; do printf '  %s\033[K\n' "$_line"; done
  printf '\033[J'   # erase any leftover lines from a previous, taller frame

  # Logo LAST, pinned top-RIGHT when wide enough — drawn AFTER the \033[J erase so
  # it's never clipped, and on the alt screen so absolute positioning is safe.
  # Width read live via `stty size </dev/tty` (works inside $()), recomputed each
  # draw so a resize reflows it. Skipped on narrow terminals (would crowd tanks).
  local _llogo="$CLIKAE_ROOT/assets/logo.txt" _lsz _lrows _lcols _lh=14
  _lsz="$( { stty size </dev/tty; } 2>/dev/null || true )"
  _lrows="${_lsz%% *}"; _lcols="${_lsz##* }"
  # Logo pinned BOTTOM-right with a small margin. RWD: shown only when the window
  # is wide AND tall enough to hold it clear of the board — otherwise omitted.
  if [ -f "$_llogo" ] && [ "${_lcols:-0}" -ge 100 ] && [ "${_lrows:-0}" -ge 28 ]; then
    local _ll _lr=$(( _lrows - _lh )) _lc=$(( _lcols - 41 ))
    while IFS= read -r _ll || [ -n "$_ll" ]; do
      printf '\033[%d;%dH%b%s%b' "$_lr" "$_lc" "$__C_BCYAN" "$_ll" "$__C_RESET"
      _lr=$(( _lr + 1 ))
    done < "$_llogo"
  fi
  printf '\033[H'   # park the cursor home
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

  # `view` is the (possibly filtered) list actually shown + indexed; `filter` is
  # the live `/` query. Everything navigational works on `view`; relay still reads
  # the FULL `items` so it can find the active source tank even when filtered out.
  local sel=0 key rest n sel_row sel_kind sel_cli filter="" view
  view="$items"
  while :; do
    view="$(_home_filter "$items" "$filter")"
    n="$(printf '%s\n' "$view" | grep -c .)"
    if [ "$n" -le 0 ]; then
      # Filter matched nothing (or everything's gone): show a tiny notice, let the
      # user clear the filter or quit. Never get stuck on an empty board.
      printf '\033[H\033[2J  %b%s%b  %b(/ %s · q %s)%b\n' \
        "$__C_DIM" "$T_FILTER_NONE" "$__C_RESET" "$__C_DIM" "$T_K_FILTER" "$T_K_QUIT" "$__C_RESET"
      IFS= read -rsn1 key || key="q"
      case "$key" in
        /) _home_tty_leave; printf '%b%s%b' "$__C_BOLD" "$T_FILTER_PROMPT" "$__C_RESET"
           IFS= read -r filter || filter=""; printf '\033[?1049h\033[?25l'; sel=0; continue ;;
        *) [ -n "$filter" ] && { filter=""; sel=0; continue; }; break ;;
      esac
    fi
    [ "$sel" -ge "$n" ] && sel=$((n - 1))    # clamp after a delete/filter
    [ "$sel" -lt 0 ] && sel=0
    _home_pick_draw "$view" "$sel" "$dry"
    IFS= read -rsn1 key || { key="q"; }
    sel_row="$(printf '%s\n' "$view" | sed -n "$((sel + 1))p")"
    sel_kind="$(printf '%s' "$sel_row" | cut -d$'\037' -f1)"
    sel_cli="$(printf '%s' "$sel_row" | cut -d$'\037' -f2)"
    case "$key" in
      $'\e')
        # Arrow keys arrive as ESC [ A/B; Shift-Tab as ESC [ Z; a lone ESC (1s
        # integer timeout) quits.
        if IFS= read -rsn2 -t 1 rest; then
          case "$rest" in
            '[A') sel=$(( (sel - 1 + n) % n )) ;;
            '[B') sel=$(( (sel + 1) % n )) ;;
            '[Z') sel=$(( (sel - 1 + n) % n )) ;;   # Shift-Tab → previous
          esac
        else
          break
        fi
        ;;
      $'\t') sel=$(( (sel + 1) % n )) ;;            # Tab → next
      k) sel=$(( (sel - 1 + n) % n )) ;;
      j) sel=$(( (sel + 1) % n )) ;;
      g) sel=0 ;;                                    # top
      G) sel=$(( n - 1 )) ;;                         # bottom
      [1-9])
        # Jump to the Nth row (clamped). Fast access on a long board.
        sel=$(( key - 1 )); [ "$sel" -ge "$n" ] && sel=$(( n - 1 )) ;;
      q) break ;;

      /)
        # Live filter: drop to the normal screen, read a query, re-enter.
        _home_tty_leave
        printf '%b%s%b' "$__C_BOLD" "$T_FILTER_PROMPT" "$__C_RESET"
        IFS= read -r filter || filter=""
        printf '\033[?1049h\033[?25l'; sel=0
        ;;
      '?')
        _home_help_overlay   # full key legend; any key dismisses, then redraw
        ;;
      h)
        # Flip the interface language live (en-US → ja-JP → zh-TW → …). Regenerate
        # items so adapter notes re-localise; the T_* strings update in place.
        i18n_cycle >/dev/null
        items="$(_home_items)"; dry="$(_home_dry_set)"
        ;;

      # --- leave actions: these launch a CLI, so exiting the picker is expected
      ''|$'\n'|$'\r')
        if [ "$sel_kind" = "resume" ]; then
          # Continue row → submenu (resume vs switch-fresh). Cancel returns here.
          _home_tty_leave; trap - EXIT INT TERM
          _home_resume_action "$sel_row" || {
            trap '_home_tty_leave' EXIT; trap '_home_tty_leave; exit 130' INT TERM
            printf '\033[?1049h\033[?25l'; continue
          }
          return 0
        fi
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
      x)
        # 無痕 / Incognito — open the selected tank with throwaway memory
        # (--ephemeral). A clean, amnesiac session: this run's long-term memory
        # evaporates on exit.
        if [ "$sel_kind" = "tank" ]; then
          _home_tty_leave; trap - EXIT INT TERM
          exec "$CLIKAE_BIN" "$sel_cli" "$(printf '%s' "$sel_row" | cut -d$'\037' -f3)" --ephemeral
        fi
        ;;

      # --- stay actions: mutate, then return to the live menu ---
      n)
        _home_stay _home_new_tank "$sel_cli"
        items="$(_home_items)"; dry="$(_home_dry_set)"
        ;;
      a)
        # v0.5.3: `a` renames the TANK (carries alias + login); alias-only edits
        # are at `clikae alias` on the CLI.
        if [ "$sel_kind" = "tank" ]; then
          _home_stay _home_rename_tank "$sel_row"
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
  # On quit, leave the static board (unfiltered) in the normal scrollback.
  _home_render_static "$items" "$dry"
}

cmd_home() {
  case "${1:-}" in
    -h|--help)
      cat <<'EOF'
Usage: clikae            (no arguments)

Opens the home dashboard — your "tank board". On a real terminal it's an
interactive launcher. Keys (press `?` in the board for the full, localised
legend):
  ↑/↓ · j/k · Tab/Shift-Tab   move          g / G          jump top / bottom
  1-9                         jump to row    ⏎ Enter        open the selection
  r   relay this shell's session into it     x   open it incognito (--ephemeral)
  n   new tank                a   rename the tank (carries alias + login)
  d   delete a tank (asks)    /   filter     h   cycle language   q/Esc  quit

On a Continue row, Enter offers a small menu: resume that exact session, or just
switch to its tank with a fresh one. The board lists every tank grouped by CLI
(the one active in this shell marked, with account and alias name) plus an "Also
available" section of relay-capable CLIs/targets you can open without a tank
(codex, agy).

Interface language (en-US / ja-JP / zh-TW) follows `clikae lang`; the `h` key
flips it live. When output isn't a terminal (a pipe, a script, the GUI), it
prints the same board as plain text. With no tanks yet it welcomes you and
points at the first step.

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
