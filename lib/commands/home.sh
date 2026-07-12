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

# Every renderer in this file (and in resume.sh, which sources it) reads T_*
# strings, so populate them the moment this file loads. i18n.sh no longer does
# this at its own source time — non-TUI commands never pay for the string table.
# Guarded: unit tests source this file standalone (without i18n.sh) to exercise
# pure helpers that never read T_*.
if declare -F i18n_load >/dev/null 2>&1; then i18n_load "$(clikae_lang)"; fi

# _human_age <epoch-mtime> [now-epoch] — "just now" / "5m ago" / "3h ago" /
# "2d ago". One formatter for the board's Continue list and the resume picker
# (each used to carry its own copy).
_human_age() {
  local mt="$1" now="${2:-}" d
  [ -n "$now" ] || now="$(date +%s 2>/dev/null || echo "$mt")"
  d=$(( now - mt ))
  if   [ "$d" -lt 60 ];    then printf 'just now'
  elif [ "$d" -lt 3600 ];  then printf '%dm ago' "$(( d / 60 ))"
  elif [ "$d" -lt 86400 ]; then printf '%dh ago' "$(( d / 3600 ))"
  else                          printf '%dd ago' "$(( d / 86400 ))"
  fi
}

# _home_active_for <engine>  -> the profile active for <engine> in THIS shell, or empty.
# Mirrors `clikae status`: read the adapter's live env var and resolve it back.
_home_active_for() {
  local cli="$1"
  (
    # Target-ness FIRST: a launch-only target (e.g. antigravity) resolves its
    # active slot via target_active_profile (the ~/.gemini symlink), not an env
    # var — even though it may ALSO ship a resume-only adapter file. See
    # clikae_is_target.
    if clikae_is_target "$cli"; then
      # shellcheck source=/dev/null
      source "$CLIKAE_LIB/targets/$cli.sh" 2>/dev/null || exit 0
      declare -F target_active_profile >/dev/null 2>&1 && target_active_profile
    elif [ -f "$CLIKAE_LIB/adapters/$cli.sh" ]; then
      # load_adapter exit 1s on a miss, which would kill this subshell — but the
      # file exists here. flag-strategy engines (no env var) aren't env-detectable.
      load_adapter "$cli" >/dev/null 2>&1 || exit 0
      local var strategy value
      var="$(adapter_meta_env_var)"
      [ -n "$var" ] || exit 0
      strategy="$(adapter_meta_strategy)"
      value="${!var}"
      resolve_active_profile "$cli" "$strategy" "$value"
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
# "resume" affordance never lies. Each row carries the ai-title (label) and a one-line
# RECAP (alias field) — "where you left off + next step" — fetched only for the few
# rows shown, so the listing stays cheap. Emits, newest first:
#   resume ␟ <engine> ␟ <tank> ␟ <title> ␟ <recap> ␟ ␟ <session-id>
# How many recent sessions the "continue" list surfaces.
CLIKAE_HOME_RECENT_MAX="${CLIKAE_HOME_RECENT_MAX:-10}"

_home_recent_rows() {
  local name proot tdir tank rows sid mt acc=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    ( load_adapter "$name" >/dev/null 2>&1 \
        && declare -F adapter_resume_args >/dev/null 2>&1 \
        && declare -F adapter_recent_sids >/dev/null 2>&1 ) || continue
    # The gate above proved this adapter loads cleanly, so it's safe to ALSO load
    # it here in the parent (load_adapter exit()s on a broken adapter — only the
    # subshell gate may take that risk). The parent's memo is inherited by every
    # $( … ) fork below, so the per-tank loads become instant instead of each
    # re-sourcing the adapter file (measured: 47 loads per board render before).
    load_adapter "$name" >/dev/null 2>&1
    proot="$(profiles_root)/$name"
    [ -d "$proot" ] || continue
    for tdir in "$proot"/*/; do
      [ -d "$tdir" ] || continue
      tank="${tdir%/}"; tank="${tank##*/}"
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
        age="$(_human_age "$mt")"
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
  # 1) Tanks — every profile.
  # Emitted in BURN ORDER (order_list), NOT grouped by engine — the board IS the
  # order. Engine travels in the cli field and the renderer shows it as an inline
  # tag. active is resolved per row since engines now interleave.
  # Partition by solo: fleet tanks first, solo (out-of-the-fleet) tanks last, so
  # the renderers can draw them as two sections (Tanks / Solo) while the picker's
  # row index still matches the on-screen order (no separate sort needed).
  local entry cli profile path label alias active a
  local _fleet="" _solo=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    cli="${entry%%/*}"; profile="${entry#*/}"
    # The board is the AI-session on-ramp, so its tank list holds only BURNABLE
    # session tanks: claude/codex (they define adapter_start_with_prompt) + agy.
    # Tool-CLI tanks (gh/npm/aws/kubectl/…) aren't fuel — "launching" one from here
    # just execs a bare usage screen, which reads as "nothing happened" — so they
    # live in `clikae tanks` (the full inventory), not on the board. (Real-user
    # feedback 2026-06.) The adapters stay; only their presence on the board does not.
    if [ "$cli" != "antigravity" ]; then
      ( load_adapter "$cli" >/dev/null 2>&1 \
          && declare -F adapter_start_with_prompt >/dev/null 2>&1 ) || continue
      # Gate passed → safe to load in the parent too, so the label/active forks
      # below (and later rows of the same cli) inherit the memo instead of
      # re-sourcing the adapter per row.
      load_adapter "$cli" >/dev/null 2>&1
    fi
    path="$(profile_dir "$cli" "$profile")"
    if [ "$cli" = "antigravity" ]; then
      label="$(_home_agy_email "$path")"   # signed-in Google account, from its cli.log
    elif [ -f "$CLIKAE_LIB/adapters/$cli.sh" ]; then
      label="$(load_adapter "$cli" >/dev/null 2>&1 && adapter_label "$path" || true)"
    else
      label=""
    fi
    alias="$(_home_alias_for "$cli" "$profile")"
    active="$(_home_active_for "$cli")"
    if [ -n "$active" ] && [ "$profile" = "$active" ]; then a=1; else a=0; fi
    local _row; _row="$(printf 'tank\037%s\037%s\037%s\037%s\037%d\037' "$cli" "$profile" "$label" "$alias" "$a")"
    if tank_is_solo "$cli" "$profile"; then _solo="$_solo$_row"$'\n'; else _fleet="$_fleet$_row"$'\n'; fi
  done <<EOF
$(order_list)
EOF
  [ -n "$_fleet" ] && printf '%s' "$_fleet"
  [ -n "$_solo" ] && printf '%s' "$_solo"

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
    tname="${tfile##*/}"; tname="${tname%.sh}"
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

  # 4) Resume list — this dir's most recent resumable sessions, if any.
  _home_recent_rows
}

# Which tanks/targets are currently over quota? Emit one row per DRY thing:
#   cli ␟ profile ␟ reset-phrase
# Backed by lib/core/limit.sh, which scans transcripts/logs — so compute this ONCE
# per board render, never per keypress. Two sources:
#   • every tank   — limit_tank_dry: claude via transcript, codex via the persisted
#                    dry_store (burn writes it; its limit is exec-stdout-only), and
#                    ACCOUNT CONTAGION so a sibling on the same dry account (e.g.
#                    claude/MFC the moment claude/L hits its limit) reads dry too.
#   • log-only targets — limit_log_dry scans the vendor's limit log (agy's cli.log).
# Rows key on the SAME (cli, profile) pair the renderer uses, so for a target the
# key is (binary, target-name) — matching _home_items' target row (cli=$tbin,
# profile=$tname). Anything not scannable is simply never marked dry (no guessing).
_home_dry_set() {
  local cli profile reset ep
  # limit_dry_set scans every tank's fuel ONCE (vs limit_tank_dry per tank, which
  # re-scanned same-account siblings) and emits cli␟profile␟reset for the dry ones.
  while IFS=$'\037' read -r cli profile reset; do
    [ -n "$cli" ] || continue
    # A persisted (dry_store) marker means the reset phrase is a SNAPSHOT of what
    # the engine said when we last caught it headless — annotate WHEN we observed
    # it (see dry_seen_suffix) so a stale/off-timezone time reads honestly. claude
    # has no store marker (its dry is a live transcript scan), so it's never tagged.
    if [ -n "$reset" ] && ep="$(dry_store_epoch "$cli" "$profile" 2>/dev/null)"; then
      reset="$reset$(dry_seen_suffix "$ep")"
    fi
    printf '%s\037%s\037%s\n' "$cli" "$profile" "$reset"
  done <<EOF
$(list_all_profiles | limit_dry_set)
EOF

  # Log-only targets (single-account vendors like agy): scan the limit log the
  # same once-per-render way. Gate on the binary being installed, mirroring
  # _home_items, so an uninstalled vendor's stale log can't badge a row that
  # isn't even shown.
  local tfile tname
  for tfile in "$CLIKAE_LIB"/targets/*.sh; do
    [ -f "$tfile" ] || continue
    tname="${tfile##*/}"; tname="${tname%.sh}"
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
        # Same snapshot-honesty as codex: agy's "Resets in 3h" is a relative phrase
        # frozen at its last run, so tag it with the log's mtime (when we observed it).
        local lmt
        lmt="$(stat -f '%m' "$logf" 2>/dev/null || stat -c '%Y' "$logf" 2>/dev/null || true)"
        [ -n "$tre" ] && tre="$tre$(dry_seen_suffix "$lmt")"
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

# --- The status dot is a FUEL GAUGE, not a "you are here". ----------------------
# One axis, one reading per tank (red→yellow→green→none), like a traffic light.
# See docs/DESIGN-board-fuel-dots.md for the why. "Which tank am I on" is NOT here
# — that stays with the cursor ❯, the burn-order position, and the `active` flag
# (which still drives the launch target — the on-row `← here` text label it used
# to also drive was dropped 2026-06-30, commit 9d55047: noise with many shells open).

# _home_weekly_path/_read <cli> <profile>  (BETA) — the vendor's verbatim weekly
# usage phrase, cached (first line) by watch/auto when it streams past. Read-only
# here; we never compute a %. Absent/empty cache = no yellow reading.
_home_weekly_path() { printf '%s/cache/weekly/%s-%s' "$CLIKAE_HOME" "$1" "$2"; }
_home_weekly_read() {
  local f s; f="$(_home_weekly_path "$1" "$2")"
  [ -f "$f" ] || return 1
  s="$(head -n 1 "$f" 2>/dev/null)"
  [ -n "$s" ] || return 1
  printf '%s' "$s"
}

# _home_fuel_dot <dry_set> <cli> <profile>  ->  echoes  "<colored-glyph>\037<note>"
# note carries the dry reset phrase / weekly-% string (may be empty). Priority is
# mutually exclusive: dry → weekly(BETA) → detectable-ready → no-reading.
_home_fuel_dot() {
  local dry="$1" cli="$2" profile="$3" reset wk
  if reset="$(_home_is_dry "$dry" "$cli" "$profile")"; then
    printf '%b●%b\037%s' "$__C_RED" "$__C_RESET" "${reset:-over quota}"; return 0
  fi
  if wk="$(_home_weekly_read "$cli" "$profile")"; then
    printf '%b●%b\037%s' "$__C_YELLOW" "$__C_RESET" "$wk"; return 0
  fi
  if limit_engine_detectable "$cli"; then
    printf '%b●%b\037' "$__C_GREEN" "$__C_RESET"; return 0
  fi
  printf '%b○%b\037' "$__C_DIM" "$__C_RESET"
}

# _home_chunk <word> <width> -> the word cut into space-separated chunks, each at
# most <width> DISPLAY columns. The escape hatch for text a word-wrapper cannot
# break: CJK (no interword spaces — a whole sentence is one "word") and long
# unbroken ASCII runs. Character-by-character by display width, so a fullwidth
# glyph is never split down the middle of its two columns.
_home_chunk() {
  local w="$2"
  [ "$w" -ge 2 ] || w=2
  local LC_ALL=C                 # _DW_CUT is a byte index; slice in bytes
  local s="$1" out="" cut
  while [ -n "$s" ]; do
    _dw_walk "$s" -1
    if [ "$_DW_W" -le "$w" ]; then out="$out $s"; break; fi
    _dw_walk "$s" "$w"
    cut="$_DW_CUT"; [ "$cut" -gt 0 ] || cut=1   # always make progress
    out="$out ${s:0:$cut}"
    s="${s:$cut}"
  done
  printf '%s' "${out# }"
}

# _home_wrap_prefixed <text> <prefix> <hang> <color> <reset> [extra]
# Word-wrap <text> to the live terminal width, printing the FIRST line as
# "<prefix><chunk>" and every continuation line as "<hang spaces><chunk>" — a
# hanging indent so a long recap's wrapped lines align under its first word, not
# the left margin. <color>/<reset> are %b colour codes applied per line (so the
# dim style survives the newline). <extra> is any outer indent the CALLER adds
# around this block (the interactive picker pipes through a `  ` prefix, so it
# passes 2) — subtracted from the width budget so the first line can't overflow.
# Width from _home_cols (the ONE width source: tty → $COLUMNS → 80). It used to
# read `stty size` itself, which meant `$COLUMNS` never reached it: with output
# piped, prose fell back to 80 while the rows around it correctly used the real
# (narrower) window, and any heading between 60 and 79 columns silently ran off
# the edge. Budget is by
# DISPLAY width (_dwidth, CJK = 2 cols), NOT character count — `${#}` is char-count
# in a UTF-8 locale, which under-measures CJK ~2× and let lines overflow + hard-wrap
# to column 0. (Root cause of the recap wrap bug, dogfood 2026-06-03.)
_home_wrap_prefixed() {
  local text="$1" prefix="$2" hang="$3" color="$4" reset="$5" extra="${6:-0}"
  local cols pad first=1 word line="" avail glob=0
  cols="$(_home_cols)"
  pad="$(printf '%*s' "$hang" '')"
  avail=$(( cols - hang - extra - 1 ))
  [ "$avail" -ge 12 ] || avail=$(( cols - extra - 1 ))
  # Don't let a `*` in a recap glob against the cwd while we word-split.
  case $- in *f*) ;; *) glob=1; set -f ;; esac
  # CJK has NO INTERWORD SPACES, so a Japanese/Chinese sentence is ONE "word" to
  # the splitter below and word-wrapping alone can never break it — it would run
  # off the edge no matter how much budget we computed (ja-JP's clean heading,
  # 61 cols at a 60-col terminal, was exactly this). So first hard-break any
  # single word that is wider than the whole line budget into <avail>-wide
  # chunks, by DISPLAY width; the chunks contain no spaces, so re-splitting them
  # back into the word loop is safe. ASCII runs with no spaces (a long path) get
  # the same treatment, which is also what you want.
  local _rebuilt="" _w
  for _w in $text; do
    if [ "$(_dwidth "$_w")" -gt "$avail" ]; then
      _rebuilt="$_rebuilt $(_home_chunk "$_w" "$avail")"
    else
      _rebuilt="$_rebuilt $_w"
    fi
  done
  text="$_rebuilt"
  for word in $text; do
    if [ -z "$line" ]; then
      line="$word"
    elif [ "$(_dwidth "$line $word")" -le "$avail" ]; then
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

# ── Display width: the ONE measuring stick ──────────────────────────────────
#
# Everything that lays out a row measures in DISPLAY COLUMNS (a CJK ideograph is
# 2, an ASCII letter is 1). The truncators below therefore also CUT by display
# columns — not by characters. That distinction is the whole ballgame:
#
#   `_home_trunc "$title" 40` used to cut to 40 CHARACTERS, but every budget
#   handed to it is in COLUMNS. For Latin text the two coincide (40 chars = 40
#   cols), so it looked right forever — and a fixture of Latin titles can never
#   catch it. A 40-char CJK title renders 80 COLUMNS, so a "budgeted" row blew
#   through an 80-col terminal by 40+ columns on the maintainer's real store.
#   Units must agree end to end: budget in columns -> truncate in columns.
#
# _dw_walk <str> <maxcols> — the shared UTF-8 scanner. Walks <str> one character
# at a time, summing display width. With <maxcols> >= 0 it STOPS before the
# character that would exceed the budget. Sets:
#   _DW_W    the display width actually consumed
#   _DW_CUT  the BYTE index it stopped at (-1 = the whole string fit)
#
# ⚠ CONTRACT: the CALLER must already be in the C locale (`local LC_ALL=C`), so
# `${#s}` and `${s:i:1}` are BYTES and we can decode UTF-8 by hand. The four
# public entry points (_dwidth, _home_trunc, _home_trunc_mid, _home_chunk) each
# do that ONCE for the whole call — bash re-runs setlocale on the assignment and
# restores it on return, and setlocale (not the loop) is what this costs. Doing
# it per scanner call instead made a truncation ~3x more expensive; this runs per
# row, per keypress, in the redraw path.
#
# No `wc`, no `iconv`, no subprocess at all — the heuristic this replaced forked
# `printf | wc -c` on every single call.
_dw_walk() {
  local s="$1" max="$2"
  local i=0 n=${#s} v b2 b3 cp len cw w=0
  _DW_CUT=-1
  while [ "$i" -lt "$n" ]; do
    printf -v v '%d' "'${s:i:1}"
    [ "$v" -lt 0 ] && v=$(( v + 256 ))
    if [ "$v" -lt 128 ]; then len=1; cw=1
    elif [ "$v" -lt 224 ]; then len=2; cw=1          # Latin-1/Greek/Cyrillic…: 1 col
    elif [ "$v" -lt 240 ]; then
      len=3
      printf -v b2 '%d' "'${s:i+1:1}"; [ "$b2" -lt 0 ] && b2=$(( b2 + 256 ))
      printf -v b3 '%d' "'${s:i+2:1}"; [ "$b3" -lt 0 ] && b3=$(( b3 + 256 ))
      cp=$(( ((v - 224) << 12) | ((b2 - 128) << 6) | (b3 - 128) ))
      # Unicode East Asian Wide/Fullwidth. Everything else in the 3-byte space —
      # the box glyphs, arrows, "…", "·", "❯" this TUI is built from — is 1 col.
      # NB U+FF61-U+FFDC (HALFwidth katakana, e.g. the ja-JP wordmark ｷﾘｶｴ) is
      # deliberately NOT in the FF00-FF60 fullwidth range: it measures 1.
      cw=1
      if   [ "$cp" -ge 4352 ]  && [ "$cp" -le 4447 ];  then cw=2   # 1100-115F Hangul Jamo
      elif [ "$cp" -ge 11904 ] && [ "$cp" -le 12350 ]; then cw=2   # 2E80-303E CJK radicals/punct
      elif [ "$cp" -ge 12353 ] && [ "$cp" -le 13311 ]; then cw=2   # 3041-33FF kana, CJK compat
      elif [ "$cp" -ge 13312 ] && [ "$cp" -le 19903 ]; then cw=2   # 3400-4DBF ext-A
      elif [ "$cp" -ge 19968 ] && [ "$cp" -le 40959 ]; then cw=2   # 4E00-9FFF unified
      elif [ "$cp" -ge 40960 ] && [ "$cp" -le 42191 ]; then cw=2   # A000-A4CF Yi
      elif [ "$cp" -ge 44032 ] && [ "$cp" -le 55203 ]; then cw=2   # AC00-D7A3 Hangul syllables
      elif [ "$cp" -ge 63744 ] && [ "$cp" -le 64255 ]; then cw=2   # F900-FAFF CJK compat ideographs
      elif [ "$cp" -ge 65040 ] && [ "$cp" -le 65049 ]; then cw=2   # FE10-FE19 vertical forms
      elif [ "$cp" -ge 65072 ] && [ "$cp" -le 65135 ]; then cw=2   # FE30-FE6F CJK compat forms
      elif [ "$cp" -ge 65280 ] && [ "$cp" -le 65376 ]; then cw=2   # FF00-FF60 fullwidth forms
      elif [ "$cp" -ge 65504 ] && [ "$cp" -le 65510 ]; then cw=2   # FFE0-FFE6 fullwidth signs
      fi
    else len=4; cw=2                                  # emoji / CJK ext-B+: 2 cols
    fi
    if [ "$max" -ge 0 ] && [ $(( w + cw )) -gt "$max" ]; then _DW_CUT=$i; break; fi
    w=$(( w + cw )); i=$(( i + len ))
  done
  _DW_W=$w
}

# _dw_skip <str> <cols> — the mirror of _dw_walk for the TAIL: the byte index
# after consuming AT LEAST <cols> display columns, so `${str:idx}` (in C locale)
# is the widest suffix costing at most width-<cols>. Used by _home_trunc_mid to
# keep a path's meaningful tail. Never lands mid-glyph.
_dw_skip() {
  local s="$1" want="$2"
  local i=0 n=${#s} v b2 b3 cp len cw w=0
  while [ "$i" -lt "$n" ] && [ "$w" -lt "$want" ]; do
    printf -v v '%d' "'${s:i:1}"
    [ "$v" -lt 0 ] && v=$(( v + 256 ))
    if [ "$v" -lt 128 ]; then len=1; cw=1
    elif [ "$v" -lt 224 ]; then len=2; cw=1
    elif [ "$v" -lt 240 ]; then
      len=3
      printf -v b2 '%d' "'${s:i+1:1}"; [ "$b2" -lt 0 ] && b2=$(( b2 + 256 ))
      printf -v b3 '%d' "'${s:i+2:1}"; [ "$b3" -lt 0 ] && b3=$(( b3 + 256 ))
      cp=$(( ((v - 224) << 12) | ((b2 - 128) << 6) | (b3 - 128) ))
      cw=1
      if   [ "$cp" -ge 4352 ]  && [ "$cp" -le 4447 ];  then cw=2
      elif [ "$cp" -ge 11904 ] && [ "$cp" -le 12350 ]; then cw=2
      elif [ "$cp" -ge 12353 ] && [ "$cp" -le 13311 ]; then cw=2
      elif [ "$cp" -ge 13312 ] && [ "$cp" -le 19903 ]; then cw=2
      elif [ "$cp" -ge 19968 ] && [ "$cp" -le 40959 ]; then cw=2
      elif [ "$cp" -ge 40960 ] && [ "$cp" -le 42191 ]; then cw=2
      elif [ "$cp" -ge 44032 ] && [ "$cp" -le 55203 ]; then cw=2
      elif [ "$cp" -ge 63744 ] && [ "$cp" -le 64255 ]; then cw=2
      elif [ "$cp" -ge 65040 ] && [ "$cp" -le 65049 ]; then cw=2
      elif [ "$cp" -ge 65072 ] && [ "$cp" -le 65135 ]; then cw=2
      elif [ "$cp" -ge 65280 ] && [ "$cp" -le 65376 ]; then cw=2
      elif [ "$cp" -ge 65504 ] && [ "$cp" -le 65510 ]; then cw=2
      fi
    else len=4; cw=2
    fi
    w=$(( w + cw )); i=$(( i + len ))
  done
  _DW_CUT=$i
}

# _dwidth <str> -> the string's DISPLAY width in terminal columns (CJK = 2).
_dwidth() { local LC_ALL=C; _dw_walk "$1" -1; printf '%s' "$_DW_W"; }

# _dw_atleast <str> <n> — "is <str> at least <n> columns wide?" without scanning
# the whole string: stops at <n>. Sets _DW_W to the width consumed and returns 0
# when the string reaches <n> columns, 1 when it ran out first (then _DW_W is its
# TRUE full width). The point is the early exit — deciding "is this title longer
# than 24 columns?" must not cost a full walk of a 400-column runaway ai-title,
# because it happens per row in the redraw path.
_dw_atleast() {
  local LC_ALL=C
  _dw_walk "$1" "$2"
  [ "$_DW_CUT" -ge 0 ]
}

# _home_truncv <str> <maxcols> — _home_trunc without the `$(...)` subshell: the
# result lands in $_TRUNC. Same column semantics (see _home_trunc). Used by the
# per-row render paths, where a fork per row is ~1.5ms of pure latency.
_home_truncv() {
  local LC_ALL=C
  local s="$1" n="$2"
  [ "$n" -ge 1 ] || n=1
  _dw_walk "$s" "$n"
  if [ "$_DW_CUT" -lt 0 ]; then _TRUNC="$s"; return; fi
  _dw_walk "$s" $(( n - 1 ))
  _TRUNC="${s:0:$_DW_CUT}…"
}

# _home_lpadv <str> <width> — _home_lpad without the subshell; result in $_LPAD.
_home_lpadv() {
  local s="$1" w="$2" pad
  _dwv "$s"
  pad=$(( w - _DW_W )); [ "$pad" -lt 0 ] && pad=0
  printf -v _LPAD '%s%*s' "$s" "$pad" ''
}

# _dwv <str> — the FORK-FREE _dwidth: leaves the answer in $_DW_W instead of
# echoing it, so a caller in the redraw path can read a width without paying for
# a `$(...)` subshell (~1.5ms each on macOS). Use this, not `w=$(_dwidth …)`, in
# any loop that runs per row or per frame; use _dwidth where you just need a
# value inline and the call is not hot.
_dwv() { local LC_ALL=C; _dw_walk "$1" -1; }

# _home_trunc <str> <maxcols> -> <str> guaranteed to render in AT MOST <maxcols>
# DISPLAY COLUMNS, with a trailing "…" when it had to shorten. The ellipsis's own
# column is INSIDE the budget (so the caller's arithmetic is simply "this cell is
# <maxcols> wide"), and a fullwidth glyph is never split down the middle of its
# two columns.
#
# 🔴 This used to cut by CHARACTERS (`${#s}` / `${s:0:$n}`) while every caller
# passed a budget in COLUMNS. Latin text hid it (1 char = 1 col); a CJK title cut
# to 40 "chars" rendered 80 columns and blew an 80-col terminal wide open. Any
# future truncator MUST measure in the same unit its budget is expressed in.
_home_trunc() {
  local LC_ALL=C          # ONE setlocale for the whole call (see _dw_walk)
  local s="$1" n="$2"
  [ "$n" -ge 1 ] || n=1
  # Walk only as far as the BUDGET — never the whole string. A runaway 4000-column
  # ai-title then costs the same as a 40-column one, which matters because this
  # runs per row, per keypress in the redraw path. _DW_CUT == -1 means the string
  # ran out before the budget did, i.e. it fits whole and is returned untouched.
  _dw_walk "$s" "$n"
  [ "$_DW_CUT" -ge 0 ] || { printf '%s' "$s"; return; }
  _dw_walk "$s" $(( n - 1 ))          # reserve exactly 1 column for the "…"
  printf '%s…' "${s:0:$_DW_CUT}"      # _DW_CUT is a BYTE index; we are in C locale
}

# _home_engine_label <cli> -> the display name for an engine tag. The antigravity
# target is shown as its canonical short name "agy" everywhere.
_home_engine_label() { case "$1" in antigravity) printf 'agy' ;; *) printf '%s' "$1" ;; esac; }

# _home_agy_email <tank_dir> -> the Google account this agy tank is signed in as,
# or empty. agy has no clean account field, but its CLI logs the signed-in account
# ("email=<x>") under <tank>/antigravity-cli/log — the same log family clikae
# already watches for limits. An un-logged-in tank has no log → empty (shows "-").
_home_agy_email() { agy_email "$1"; }   # shared with `clikae list`, see lib/core/scan.sh

# _home_lpad <str> <width> -> <str> right-padded with spaces to <width> DISPLAY
# columns (so a CJK label lines up the same as an ASCII one). The drop-in for a
# `%-<width>s` that would otherwise mis-measure multibyte text.
_home_lpad() {
  local s="$1" w="$2" dw pad
  dw="$(_dwidth "$s")"
  pad=$(( w - dw )); [ "$pad" -lt 0 ] && pad=0
  printf '%s%*s' "$s" "$pad" ''
}

# _home_cols -> the live terminal COLUMN width, via `stty size </dev/tty`
# (works inside $(), unlike `tput cols` which reads its piped stdout — see the
# NB in _home_welcome). Falls back to 80 when not a real terminal, unreadable,
# or implausibly narrow (<30) — same floor _home_wrap_prefixed already uses.
_home_cols() {
  local cols
  cols="$( { stty size </dev/tty | awk '{print $2}'; } 2>/dev/null || true )"
  # No /dev/tty (piped, redirected, CI) — the terminal is still THERE, we just
  # can't ask it. $COLUMNS is what the shell knows, so honour it before the
  # floor: `clikae clean --dry-run > file` in an 60-column window must still
  # produce rows that fit that window, and it makes the width testable without
  # a PTY.
  case "$cols" in ''|*[!0-9]*) cols="${COLUMNS:-}" ;; esac
  case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
  [ "$cols" -ge 30 ] || cols=80
  printf '%s' "$cols"
}

# _home_row_budget <cols> <overhead> [min] -> how many DISPLAY columns are left
# for a row's variable text (a title, a label…) after subtracting <overhead> —
# the DISPLAY width of everything else on the row: fixed chrome (dots, padded
# name/engine columns, separators, quotes) PLUS any other already-known
# variable pieces on the same row (age, size, a localized label…), which the
# caller measures with `_dwidth` and folds into <overhead> before calling this.
# Floors at [min] (default 12) so a narrow/odd terminal, or a row whose OTHER
# pieces already eat most of the width, can't drive the budget negative or
# unusably tiny. Pure arithmetic (cols passed in, not read here) so it's
# trivially unit-testable without a tty. This is the fix for the bug where a
# fixed `_home_trunc "$x" 56`-style cap ignored the row's own prefix/suffix
# against the terminal's actual budget and could overflow on its own.
_home_row_budget() {
  local cols="$1" overhead="$2" min="${3:-12}" b
  case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
  b=$(( cols - overhead ))
  [ "$b" -ge "$min" ] || b="$min"
  printf '%s' "$b"
}

# _home_trunc_mid <str> <maxcols> -> <str> unchanged if it already fits within
# <maxcols> DISPLAY COLUMNS; otherwise middle-ellipsised — head kept short, TAIL
# kept long (a path's meaningful part, the leaf dir, sits at the end) — so the
# whole result (head + "…" + tail) is AT MOST <maxcols> columns.
#
# Columns, NOT characters (see _home_trunc's red note): a cwd can absolutely
# contain CJK (`~/Developer/専案/…`), and cutting it by character count would
# render up to 2x its budget. Both ends land on character boundaries, so a
# fullwidth glyph is never sliced in half.
_home_trunc_mid() {
  local LC_ALL=C          # ONE setlocale; _DW_* indices are BYTE offsets
  local s="$1" n="$2" total head_cols tail_cols hcut tcut
  _dw_walk "$s" -1; total="$_DW_W"
  [ "$total" -gt "$n" ] || { printf '%s' "$s"; return; }
  [ "$n" -ge 4 ] || n=4
  # 1 column for the "…"; the rest split 1/3 head, 2/3 tail.
  head_cols=$(( (n - 1) / 3 )); tail_cols=$(( n - 1 - head_cols ))
  _dw_walk "$s" "$head_cols"; hcut="$_DW_CUT"; [ "$hcut" -ge 0 ] || hcut=0
  _dw_skip "$s" $(( total - tail_cols )); tcut="$_DW_CUT"
  [ "$tcut" -ge "$hcut" ] || tcut="$hcut"      # never let the two halves overlap
  printf '%s…%s' "${s:0:$hcut}" "${s:$tcut}"
}

# Render the launchable items (passed as $1) as the static tank board. The dry
# set ($2, from _home_dry_set) badges over-quota tanks with !.
_home_render_static() {
  local items="$1" dry="$2" any_dry=""
  local n_tanks n_clis
  # `grep -c .` exits 1 when the count is 0 — under `set -eo pipefail` that would
  # abort the whole render. The board can legitimately have 0 fuel tanks now (e.g.
  # only tool-CLI tanks, which the board filters out), so guard with `|| true`.
  n_tanks="$(printf '%s\n' "$items" | awk -F'\037' '$1=="tank"' | grep -c . || true)"
  n_clis="$(printf '%s\n' "$items" | awk -F'\037' '$1=="tank"{print $2}' | sort -u | grep -c . || true)"
  printf '%b%s%b  %b·  %s%b\n\n' \
    "$__C_BOLD" "$T_WORDMARK" "$__C_RESET" "$__C_DIM" "$(i18n_summary "$n_tanks" "$n_clis")" "$__C_RESET"

  local kind cli profile label alias active note cur_sect="" also="" printed_resume=0 rdot
  local launch_cli="" launch_profile=""
  # Title budget, in DISPLAY COLUMNS: cols minus this row's own fixed chrome
  # (4-space lead + dot + space + 7-col name + space + 8-col engine + space + 2
  # quotes = 25). No extra column for the "…" — _home_trunc keeps its ellipsis
  # INSIDE the budget it's given. Computed ONCE (the chrome is identical on
  # every resume row) rather than per row.
  local _resume_title_budget; _resume_title_budget="$(_home_row_budget "$(_home_cols)" 25 20)"
  while IFS=$'\037' read -r kind cli profile label alias active note; do
    [ -n "$kind" ] || continue
    case "$kind" in
      resume)
        # The "continue" list: this dir's recent resumable sessions, each with its
        # ai-title and a one-line recap when present.
        if [ "$printed_resume" -eq 0 ]; then printed_resume=1; printf '  %b%s%b\n' "$__C_BCYAN" "$T_CONTINUE" "$__C_RESET"; fi
        rdot="$(_home_fuel_dot "$dry" "$cli" "$profile")"; rdot="${rdot%%$'\037'*}"
        # Same columns as a Tank row — dot · name · engine — then the session title
        # where a tank's account would sit, so the two sections read as one grid.
        local _rnm _ren; _rnm="$(_home_lpad "$profile" 7)"; _ren="$(_home_lpad "$(_home_engine_label "$cli")" 8)"
        printf '    %b %s %b%s%b %b"%s"%b\n' "$rdot" "$_rnm" "$__C_DIM" "$_ren" "$__C_RESET" "$__C_DIM" "$(_home_trunc "$label" "$_resume_title_budget")" "$__C_RESET"
        # recap (carried in the alias field): word-wrapped with a hanging indent so
        # long recaps align under their first word instead of spilling to column 0.
        [ -n "$alias" ] && _home_wrap_prefixed "$alias" "        -> " 11 "$__C_DIM" "$__C_RESET"
        ;;
      tank)
        # Two sections in burn order: fleet tanks under "Tanks", solo (out-of-the-
        # fleet) tanks under "Solo" — the section IS the badge (no per-row 🔒). Soul
        # sharing isn't shown: in the fleet, a shared brain is the NORMAL state (that's
        # what relay/`to` are for), so it's not worth shouting. _home_items emits fleet
        # first then solo, so a section change is just a header.
        if tank_is_solo "$cli" "$profile"; then
          if [ "$cur_sect" != "solo" ]; then printf '\n  %b%s%b\n' "$__C_BCYAN" "$T_SOLO_SECTION" "$__C_RESET"; cur_sect="solo"; fi
        elif [ "$cur_sect" != "fleet" ]; then
          [ "$printed_resume" -eq 1 ] && printf '\n'
          printf '  %b%s%b\n' "$__C_BCYAN" "$T_TANKS" "$__C_RESET"; cur_sect="fleet"
        fi
        local _reset _eng _fd _dot; _eng="$(_home_engine_label "$cli")"
        # Dot = fuel state (red dry / yellow weekly-BETA / green ready / ○ no read),
        # decoupled from `active`. `active` still picks the launch target (the
        # on-row "← here" label it also used to drive was dropped, see above).
        _fd="$(_home_fuel_dot "$dry" "$cli" "$profile")"; _dot="${_fd%%$'\037'*}"; _reset="${_fd#*$'\037'}"
        if _home_is_dry "$dry" "$cli" "$profile" >/dev/null; then any_dry=1; fi
        if [ "$active" = "1" ]; then launch_cli="$cli"; launch_profile="$profile"
        elif [ -z "$launch_cli" ]; then launch_cli="$cli"; launch_profile="$profile"; fi
        # Aligned columns (display-width padded, CJK-safe): name · engine · account,
        # then a right gutter that holds the reset time when the tank is dry. (We don't
        # mark "this shell's tank": with many tanks open at once across terminals, the
        # current-shell tank is an artifact of where you typed clikae, not useful info.)
        local _nm _en _ac _tail="" _sep=""
        _nm="$(_home_lpad "$profile" 7)"; _en="$(_home_lpad "$_eng" 8)"; _ac="$(_home_lpad "${label:--}" 22)"
        if [ -n "$_reset" ]; then _tail="$(printf '%b%s%b' "$__C_YELLOW" "$_reset" "$__C_RESET")"; fi
        [ -n "$_tail" ] && _sep="  "
        printf '    %b %s %b%s%b %b%s%b%s%s\n' \
          "$_dot" "$_nm" "$__C_DIM" "$_en" "$__C_RESET" "$__C_DIM" "$_ac" "$__C_RESET" "$_sep" "$_tail"
        ;;
      target)
        # A single-account launch target (e.g. agy) lives under "Also available",
        # NOT a floating group of its own. Enter launches it single-account; to make
        # it a tank, `n` → agy runs the SU takeover. Dry → ! + reset phrase inline.
        # The `note` is a full localized sentence ("single account · global
        # login (one account, every shell)" — 83-90 cols in es/fr at 80), so it
        # WRAPS with a hanging indent under its own column rather than running
        # off the edge. Column 19 = 4 lead + dot + space + 12-wide engine + space.
        local _treset _tnote
        if _treset="$(_home_is_dry "$dry" "$cli" "$profile")"; then
          _tnote="$note  ${_treset:-over quota}"
          also="$also$(_home_wrap_prefixed "$_tnote" \
            "$(printf '    %b●%b %-12s ' "$__C_RED" "$__C_RESET" "$cli")" 19 "$__C_DIM" "$__C_RESET")"$'\n'
          any_dry=1
        else
          also="$also$(_home_wrap_prefixed "$note" \
            "$(printf '    %b·%b %-12s ' "$__C_DIM" "$__C_RESET" "$cli")" 19 "$__C_DIM" "$__C_RESET")"$'\n'
        fi
        ;;
      agent)
        also="$also$(_home_wrap_prefixed "$note" \
          "$(printf '    %b·%b %-12s ' "$__C_DIM" "$__C_RESET" "$cli")" 19 "$__C_DIM" "$__C_RESET")"$'\n'
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
    # The tank's NAME is the way to launch it (alias retired from the board). agy
    # shown by its short name. Colour via %b only (codes are literal \033).
    local _leng; _leng="$(_home_engine_label "$launch_cli")"
    printf '  %s clikae %s %s\n' "$(_home_lpad "$T_LAUNCH" 9)" "$_leng" "$launch_profile"
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
  # T_ENGINES_HERE/T_ENGINES_SUPPORTED carry the count as a %s placeholder
  # (not prepended by the render pattern): "${total} ${T_STRING}" put an ASCII
  # space between the number and the word unconditionally, which is wrong
  # typography for a Chinese/Korean classifier ("14 個引擎" / "14 개 엔진"
  # should be "14個引擎" / "14개 엔진" — the classifier attaches directly to
  # the number). Each locale now owns its own spacing inside the string.
  if [ -n "$installed" ]; then
    # shellcheck disable=SC2059
    BODY+=("${__C_BOLD}${T_NO_TANKS_YET}${__C_RESET} · $(printf "$T_ENGINES_HERE" "$total")")
    BODY+=("  ${__C_GREEN}${installed}${__C_RESET}")
  else
    # shellcheck disable=SC2059
    BODY+=("${__C_BOLD}${T_NO_TANKS_YET}${__C_RESET} · $(printf "$T_ENGINES_SUPPORTED" "$total")")
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
  # Only measure width when actually on a terminal (a pipe is stacked anyway).
  if [ -t 1 ] && [ -f "$logo" ]; then
    cols="$(_home_cols)"
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

_home_tty_leave() { stty echo 2>/dev/null || true; printf '\033[?25h\033[?1049l'; }   # show cursor, leave alt screen

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

  local sel=0 i
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
    tui_read_key 3 || break
    case "$TUI_KEY" in
      up|k|shift-tab) sel=$(((sel - 1 + n) % n)) ;;
      down|j|tab)     sel=$(((sel + 1) % n)) ;;
      home|pgup)      sel=0 ;;
      end|pgdn)       sel=$((n - 1)) ;;
      q|esc) break ;;
      enter)
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
  history_log "board: relay $cli/$from → $cli/$profile"
  exec "$CLIKAE_BIN" relay "$cli" "$from" "$profile"
}

# Rename the selected TANK (the `a` key): type a new name, then
# `clikae rename <engine> <old> <new>` — the powerful rename that moves the tank
# dir, rewrites the managed alias, AND carries the saved login across. Per the
# v0.5.3 design, `a` is "rename" (the whole tank); alias-only tweaks live at
# `clikae alias` on the CLI. agy tanks rename too (cmd_rename routes them to
# _agy_rename: move the slot + repoint ~/.gemini if active).
_home_rename_tank() {
  local kind cli profile label alias active note
  IFS=$'\037' read -r kind cli profile label alias active note <<EOF
$1
EOF
  : "$label" "$active" "$note"
  [ "$kind" = "tank" ] || return 0
  printf '\n%s  %s/%s\n' "$T_RENAME_FOR" "$(_home_engine_label "$cli")" "$profile"
  # If this tank still has a legacy shell alias, offer it as the default new name
  # (adopt the alias as the tank's name — alias is retiring into the name).
  local newname def="$alias"
  [ -n "$def" ] && [ "$def" != "$profile" ] || def=""
  if [ -n "$def" ]; then
    read -rp "  $T_RENAME_NEW($def) " newname || return 0
    [ -n "$newname" ] || newname="$def"
  else
    read -rp "  $T_RENAME_NEW" newname || return 0
    [ -n "$newname" ] || { printf '  %s\n' "$T_RENAME_CANCEL"; return 0; }
  fi
  "$CLIKAE_BIN" rename "$cli" "$profile" "$newname" || true
}

# Enter on a Continue row → a tiny submenu. The options DEPEND on whether
# the tank still has fuel ($2 = the dry set from _home_dry_set):
#   • has fuel → by default (resume_ask_tank_get = always), FIRST ask which tank
#     to resume on — same "Resume on which tank?" question and default as
#     `clikae resume`'s own standalone picker, so the two entry points behave
#     identically. Keeping the default (this tank) falls through to the original
#     two choices (resume here / open here fresh); picking a different tank
#     carries the session there directly (switching tanks IS the carry — no
#     separate "are you sure" needed). `clikae resume ask-tank dry-only` skips
#     this and restores the older behavior below.
#   • DRY → resuming or opening fresh both dead-end on the same exhausted quota, so
#     instead lead with "carry onward" — relay this session to the ring's next
#     fuelled tank (next_tank) — and keep "force-resume anyway" as an escape hatch.
# Both choices exec; cancel (q) returns 1 so the caller can re-enter the picker.
_home_resume_action() {
  local row="$1" dry="$2" kind cli profile label alias active note
  IFS=$'\037' read -r kind cli profile label alias active note <<EOF
$row
EOF
  : "$label" "$alias" "$active"
  if [ -n "$dry" ] && _home_is_dry "$dry" "$cli" "$profile" >/dev/null; then
    _home_resume_dry_action "$cli" "$profile" "$note" "$row"
    return $?
  fi
  local cands has_other=""
  cands="$(list_all_profiles | awk -F'\t' -v c="$cli" '$1==c{print $2}')"
  has_other="$(printf '%s\n' "$cands" | grep -vxF "$profile" | head -1)"
  if [ -n "$has_other" ] && [ "$(resume_ask_tank_get)" = "always" ]; then
    local target
    target="$(_home_choose "$T_RESUME_WHICH_TANK" "$cands" "$profile")" || return 1
    if [ -n "$target" ] && [ "$target" != "$profile" ]; then
      history_log "board: carry $cli/$profile → $cli/$target"
      [ -n "$note" ] && _resume_carry_session "$cli" "$profile" "$target" "$note"
      _home_launch "$kind"$'\037'"$cli"$'\037'"$target"$'\037'"$label"$'\037'"$alias"$'\037'"$active"$'\037'"$note"
      return $?
    fi
  fi
  # Two choices when staying on this tank: resume here, or open here fresh. The
  # third, older "Carry this session to another tank" menu item is kept for
  # `ask-tank dry-only` users, who skip the upfront question above entirely.
  local opts choice
  opts="$(printf '%s\n%s' "$T_RESUME_OPT_RESUME" "$T_RESUME_OPT_SWITCH")"
  if [ -n "$has_other" ] && [ "$(resume_ask_tank_get)" = "dry-only" ]; then
    opts="$(printf '%s\n%s' "$opts" "$T_RESUME_OPT_CARRY")"
  fi
  choice="$(_home_choose "$T_RESUME_TITLE  ($cli/$profile)" "$opts" "$T_RESUME_OPT_RESUME")" || return 1
  case "$choice" in
    "$T_RESUME_OPT_SWITCH")
      # Same tank, fresh session: bare switch, no --resume.
      if [ "$cli" = "antigravity" ]; then exec "$CLIKAE_BIN" agy "$profile"
      else exec "$CLIKAE_BIN" "$cli" "$profile"; fi ;;
    "$T_RESUME_OPT_CARRY")
      _home_carry_action "$cli" "$profile" "$note" || _home_launch "$row" ;;
    *)
      _home_launch "$row" ;;   # resume: the resume path (kind=resume → --resume <sid>)
  esac
}

# "Carry this session onto another tank" (the dry-only mode's buried 3rd choice,
# and the dry submenu's fallback): pick a target from this engine's OTHER tanks,
# copy the session there (_resume_carry_session — shared with `clikae resume`'s
# own picker, covers claude/codex/antigravity), then resume it there directly.
# Returns 1 (caller falls back to plain resume) if there's nothing to pick or the
# user cancels.
_home_carry_action() {
  local cli="$1" from="$2" sid="$3" cands target
  cands="$(list_all_profiles | awk -F'\t' -v c="$cli" -v f="$from" '$1==c && $2!=f{print $2}')"
  [ -n "$cands" ] || return 1
  target="$(_home_choose "$(printf "$T_RESUME_CARRY_PICK" "$cli/$from")" "$cands" "")" || return 1
  [ -n "$target" ] || return 1
  history_log "board: carry $cli/$from → $cli/$target"
  [ -n "$sid" ] && _resume_carry_session "$cli" "$from" "$target" "$sid"
  _home_launch "resume"$'\037'"$cli"$'\037'"$target"$'\037'""$'\037'""$'\037'""$'\037'"$sid"
}

# Dry-tank submenu (see _home_resume_action). <sid> is the session to carry; <row>
# is kept for the force-resume fall-through. The carry target comes from next_tank
# (same-engine first → a real resume; cross-engine → a cold brief), so it never
# offers a tank that's also dry. When the WHOLE ring is dry, next_tank returns
# nothing and only the force-resume escape hatch is shown.
_home_resume_dry_action() {
  local cli="$1" profile="$2" sid="$3" row="$4"
  local nxt ne nt label_relay="" label_force opts choice
  nxt="$(next_tank "$cli" "$profile")"
  if [ -n "$nxt" ]; then
    IFS=$'\t' read -r ne nt <<EOF
$nxt
EOF
    label_relay="$(printf "$T_RESUME_OPT_RELAY" "$ne/$nt")"
  fi
  label_force="$(printf "$T_RESUME_OPT_FORCE" "$cli/$profile")"
  if [ -n "$label_relay" ]; then opts="$(printf '%s\n%s' "$label_relay" "$label_force")"
  else opts="$label_force"; fi
  choice="$(_home_choose "$(printf "$T_RESUME_DRY_TITLE" "$cli/$profile")" "$opts" "${opts%%$'\n'*}")" || return 1
  if [ -n "$label_relay" ] && [ "$choice" = "$label_relay" ]; then
    history_log "board: dry-relay $cli/$profile → $ne/$nt"
    if [ "$ne" = "$cli" ]; then
      # Same engine → real resume of THIS session onto the fuelled tank.
      exec "$CLIKAE_BIN" relay "$cli" "$profile" "$nt" ${sid:+--session "$sid"}
    else
      # Cross engine → that engine can't resume a foreign session; hand it a brief.
      exec "$CLIKAE_BIN" handoff "$cli" "$profile" --to "$ne/$nt"
    fi
  else
    _home_launch "$row"   # force-resume: resume the dry tank anyway (will hit the limit)
  fi
}

# _home_newtank_choices -> the `n` picker list, GROUPED: AI engines first (the ones
# you can burn as a tank — they define adapter_start_with_prompt, i.e. claude /
# codex), then agy (AI · power), then the dev-tool CLIs (account-switchers only:
# aws, docker, gh, …). Each line is annotated "(AI)" / "(tool)"; the caller takes
# the first token as the engine name.
_home_newtank_choices() {
  local name ai="" tools=""
  # Classify by whether the adapter FILE defines adapter_start_with_prompt — the
  # session-handoff hook only AI engines have. NB: a runtime `declare -F` check is
  # unreliable here (load_adapter provides a default stub, so it's always defined);
  # the file is the ground truth.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if grep -qE '^[[:space:]]*adapter_start_with_prompt[[:space:]]*\(\)' "$CLIKAE_LIB/adapters/$name.sh" 2>/dev/null; then
      ai="$ai$name"$'\n'
    else
      tools="$tools$name"$'\n'
    fi
  done <<EOF
$(list_adapters)
EOF
  printf '%s' "$ai"    | while IFS= read -r n; do [ -n "$n" ] && printf '%s  (AI)\n' "$n"; done
  printf 'agy  (AI · power · takes over ~/.gemini)\n'
  printf '%s' "$tools" | while IFS= read -r n; do [ -n "$n" ] && printf '%s  (tool)\n' "$n"; done
}

# Guided new-tank flow (the `n` key): pick an engine with the arrow keys, then type
# the tank name. The list is grouped AI vs tool (see _home_newtank_choices). agy is
# offered (flagged power): picking it routes to `clikae init agy`, whose first run
# runs the SU takeover of ~/.gemini (asks first) — so "add agy" = same keystroke,
# just gated by that consent.
_home_new_tank() {
  local def_cli="$1" cli profile
  cli="$(_home_choose "$T_NEWTANK_TITLE    $T_PICKER_HINT" "$(_home_newtank_choices)" "$def_cli")" \
    || { printf '%s\n' "$T_NEWTANK_CANCEL"; return 0; }
  [ -n "$cli" ] || return 0
  # Take the engine name (first token), dropping the (AI)/(tool)/power annotation.
  cli="${cli%% *}"
  printf '\n'
  read -rp "$(printf "$T_NEWTANK_PROFILE" "$cli")" profile || return 0
  [ -n "$profile" ] || { printf '%s\n' "$T_NEWTANK_NONAME"; return 0; }
  if [ "$cli" = "agy" ]; then
    "$CLIKAE_BIN" init agy "$profile" || true       # SU takeover (asks first)
  else
    "$CLIKAE_BIN" init "$cli" "$profile" --alias || true
  fi
}

# _home_filter <items> <query> — keep only rows whose text contains <query>
# (case-insensitive, literal). Empty query → everything. Group headers in the
# renderer are derived from the surviving rows, so filtering lines is enough.
_home_filter() {
  local items="$1" q="$2"
  [ -n "$q" ] || { printf '%s' "$items"; return 0; }
  printf '%s\n' "$items" | grep -i -F -- "$q" || true
}

# _home_reorder <engine> <tank> <delta>  — move a tank up (-1) / down (+1) in the
# BURN ORDER, materialising the full order into $CLIKAE_HOME/order and swapping
# with its neighbour. The board IS the order, so this is how you arrange it. Returns
# 0 if it moved, 1 if it was already at the edge (caller leaves selection put).
_home_reorder() {
  local engine="$1" tank="$2" delta="$3" target="$1/$2"
  local -a list=(); local l
  while IFS= read -r l; do [ -n "$l" ] && list+=("$l"); done <<EOF
$(order_list)
EOF
  local i idx=-1
  for ((i = 0; i < ${#list[@]}; i++)); do [ "${list[$i]}" = "$target" ] && idx=$i; done
  [ "$idx" -ge 0 ] || return 1
  local j=$(( idx + delta ))
  [ "$j" -ge 0 ] && [ "$j" -lt "${#list[@]}" ] || return 1   # at an edge
  local tmp="${list[$idx]}"; list[$idx]="${list[$j]}"; list[$j]="$tmp"
  mkdir -p "$CLIKAE_HOME" 2>/dev/null || true
  local f; f="$(order_file)"; : > "$f"
  for ((i = 0; i < ${#list[@]}; i++)); do printf '%s\n' "${list[$i]}" >> "$f"; done
  return 0
}

# _home_help_row <keys> <description> — one aligned line in the help overlay.
# The description STARTS at an ABSOLUTE column (\033[24G) rather than padding
# the key with %-16s: keys like "↑ ↓  j k  Tab" / "⏎ Enter" contain multibyte
# glyphs, and printf field width counts bytes, not display columns, so %-16s
# misaligns them. That jump was always column-correct — the bug was that a
# LONG description (T_K_SOLO/T_K_MEMORY are full sentences, 82-92 cols in
# es/de/fr/pt) just ran off the right edge unwrapped. Reuses
# _home_wrap_prefixed (the same helper the recap text wraps with): the first
# line's "prefix" is the bold key plus a literal \033[24G (an escape sequence
# the wrapper never measures — it only sizes the WRAPPED text against the
# budget, so embedding it here is safe), continuation lines hang-indent with
# 24 literal spaces so they land under the same column.
_home_help_row() {
  local keys="$1" desc="$2" prefix
  prefix="$(printf '    %b%s%b\033[24G' "$__C_BOLD" "$keys" "$__C_RESET")"
  _home_wrap_prefixed "$desc" "$prefix" 24 "" ""
}

# The `?` key: a full, localised key legend drawn over the board (alt screen is
# already active). Any key dismisses it; the loop then repaints the board.
_home_help_overlay() {
  printf '\033[H\033[2J'
  printf '  %b%s%b\n\n' "$__C_BOLD" "$T_HELP_TITLE" "$__C_RESET"
  _home_help_row "↑ ↓  j k  Tab" "$T_K_MOVE"
  _home_help_row "g / G"         "$T_K_TOPBOTTOM"
  _home_help_row "1-9"           "$T_K_JUMP"
  _home_help_row "[ / ]"         "$T_K_REORDER"
  _home_help_row "⏎ Enter"       "$T_K_OPEN"
  _home_help_row "r"             "$T_K_RELAY"
  _home_help_row "x"             "$T_K_INCOGNITO"
  _home_help_row "n"             "$T_K_NEW"
  _home_help_row "a"             "$T_K_RENAME"
  _home_help_row "d"             "$T_K_DELETE"
  _home_help_row "s"             "$T_K_SOLO"
  _home_help_row "m"             "$T_K_MEMORY"
  _home_help_row "c"             "$T_K_CLEAN"
  _home_help_row "/"             "$T_K_FILTER"
  _home_help_row "A"             "$T_K_AUTO (ask/safe/full · BETA)"
  _home_help_row "l"             "$T_K_LANG"
  _home_help_row "q / Esc"       "$T_K_QUIT"
  # The status dot is a fuel gauge, not "you are here" (docs/DESIGN-board-fuel-dots.md).
  # Was one unwrapped line (T_DOTS_TITLE + all four dot labels concatenated):
  # 87-97 cols in es/de/fr/pt. Same wrap treatment as the recap text: each
  # "●label" pair is pre-coloured into one chunk (so per-dot colour survives a
  # wrap), joined with " · " into one text blob, then wrapped with a hanging
  # indent under the title (whose OWN display width — CJK-safe via _dwidth —
  # sets the hang column, since "Dots = fuel:" isn't a fixed width across locales).
  local _dots_prefix _dots_hang _dots_legend
  _dots_prefix="$(printf '  %b%s:%b  ' "$__C_BOLD" "$T_DOTS_TITLE" "$__C_RESET")"
  _dots_hang=$(( 5 + $(_dwidth "$T_DOTS_TITLE") ))
  _dots_legend="$(printf '%b●%b %s · %b●%b %s · %b●%b %s · %b○%b %s' \
    "$__C_GREEN"  "$__C_RESET" "$T_DOT_READY" \
    "$__C_RED"    "$__C_RESET" "$T_DOT_DRY" \
    "$__C_YELLOW" "$__C_RESET" "$T_DOT_WEEK" \
    "$__C_DIM"    "$__C_RESET" "$T_DOT_NONE")"
  printf '\n'
  _home_wrap_prefixed "$_dots_legend" "$_dots_prefix" "$_dots_hang" "" ""
  # T_HELP_AGY is a full sentence (109 cols even in en-US) that used to be
  # printf'd raw with no wrap at all.
  printf '\n'
  _home_wrap_prefixed "$T_HELP_AGY" "  " 2 "$__C_DIM" "$__C_RESET"
  printf '  %b%s%b' "$__C_DIM" "$T_HELP_DISMISS" "$__C_RESET"
  local _k; IFS= read -rsn1 _k || true
}

# Draw the menu (full redraw) with row index $2 highlighted, from items in $1.
_home_pick_draw() {
  # Single-write flicker fix: _home_pick_draw_body composes the whole frame via
  # printf to a captured string; we then write it to the terminal in ONE printf.
  # Repainting line-by-line (a write per row) is what still flickered.
  local _frame
  _frame="$(_home_pick_draw_body "$@")"
  local _lsz _lrows
  _lsz="$( { stty size </dev/tty; } 2>/dev/null || true )"
  _lrows="${_lsz%% *}"
  [ -n "$_lrows" ] || _lrows=24
  # Synchronized Output: BSU → frame → park cursor → ESU
  printf '\033[?2026h%s\033[%d;1H\033[?2026l' "$_frame" "$_lrows"
}
_home_total_sessions() {
  local chome="${CLIKAE_HOME:-$HOME/.clikae}"
  ( ls -1 "$chome"/profiles/claude/*/projects/*/*.jsonl \
          "$chome"/profiles/codex/*/sessions/*/*/*/rollout-*.jsonl \
          "$chome"/profiles/antigravity/*/antigravity-cli/brain/*/.system_generated/logs/transcript.jsonl 2>/dev/null | wc -l | tr -d ' ' ) 2>/dev/null || echo 0
}

_home_pick_draw_body() {
  local items="$1" sel="$2" dry="$3"
  # Flicker-free paint: home the cursor and overwrite in place — NO `\033[2J`
  # full-screen clear (the momentary blank frame is exactly what flickered on
  # each keypress). Leftover lines from a taller previous frame are erased with
  # `\033[J` after the content, and the logo is drawn LAST (below) so that erase
  # can't clip it. Row widths are stable frame-to-frame, so no per-line erase yet.
  local kind cli profile label alias active note idx=0 cur_cli="" printed_also=0 printed_resume=0 mark dot _reset tdot _line rdot rage
  # Same fixed-chrome accounting as _home_render_static's resume row (25 cols:
  # 2-space lead + mark + space + dot + space + 7-col name + space + 8-col
  # engine + space + 2 quotes). The "…" lives inside _home_trunc's budget, so
  # no extra column here. Computed ONCE, not per row.
  local _resume_title_budget; _resume_title_budget="$(_home_row_budget "$(_home_cols)" 25 20)"
  printf '\033[H\033[K\n'   # home + one blank top-margin line
  # Repaint the whole frame, clearing each line to end-of-line (\033[K) so a row
  # that COLLAPSES when the cursor moves away (hover → fewer chars) leaves no stale
  # tail. The logo is drawn AFTER this, so the full-width erase here can't clip it.
  # (Vars are declared above, outside this pipe's subshell, so no `local` here.)
  {
  # Compact footer: the everyday keys + a pointer to `?` for the full, localised
  # legend (relay / incognito / new / rename / delete / jump). Keeps the board
  # clean while every action stays discoverable.
  # WRAPPED, not shortened: the localized key labels are correct Apple-register
  # words and de/fr/es legitimately need more columns than en (es-ED measured 90
  # at 80 cols) — the render adapts to the terminal, the words don't shrink.
  # Hangs under the wordmark (whose display width is locale-dependent — ja's
  # katakana wordmark is not 6 columns — so it's measured, not assumed).
  # extra=2: this whole block is piped through the `printf '  %s'` indenter at the
  # END of this function, so every line it emits lands 2 columns right of where it
  # was composed. The wrapper cannot see that outer indent, so it must be TOLD —
  # the same reason the recap call below passes 2. Without it the keybar wraps 2
  # columns too late and overruns a 60-col terminal by 1.
  _home_wrap_prefixed \
    "· ↑↓/Tab $T_K_MOVE · ⏎ $T_K_OPEN · [ ] $T_K_REORDER · / $T_K_FILTER · ? $T_K_HELP · q $T_K_QUIT" \
    "$(printf '%b%s%b  ' "$__C_BOLD" "$T_WORDMARK" "$__C_RESET")" \
    "$(( $(_dwidth "$T_WORDMARK") + 2 ))" "$__C_DIM" "$__C_RESET" 2
  printf '%b%s: %s · [A] change (BETA, claude)%b\n\n' "$__C_DIM" "$T_K_AUTO" "$(autonomy_get)" "$__C_RESET"
  while IFS=$'\037' read -r kind cli profile label alias active note; do
    [ -n "$kind" ] || continue
    if [ "$idx" -eq "$sel" ]; then mark="${__C_GREEN}❯${__C_RESET}"; else mark=" "; fi
    case "$kind" in
      resume)
        # The Resume list — recent resumable sessions
        if [ "$printed_resume" -eq 0 ]; then
          printed_resume=1
          if [ -n "$cur_cli" ] || [ "$printed_also" -gt 0 ]; then printf '\n'; fi
          printf '  %b%s%b\n' "$__C_BCYAN" "$T_CONTINUE" "$__C_RESET"
        fi
        # active field is "<flag> <age>": flag 1 = this session is on the tank you're
        # using now (●), else ○. Age is the hover fallback when there's no recap.
        rdot="$(_home_fuel_dot "$dry" "$cli" "$profile")"; rdot="${rdot%%$'\037'*}"
        rage="${active#* }"
        # Same columns as a Tank row — dot · name · engine — then the session title.
        local _rnm _ren; _rnm="$(_home_lpad "$profile" 7)"; _ren="$(_home_lpad "$(_home_engine_label "$cli")" 8)"
        if [ "$idx" -eq "$sel" ]; then
          printf '  %b %b %b%s%b %b%s%b %b"%s"%b\n' "$mark" "$rdot" "$__C_BOLD" "$_rnm" "$__C_RESET" "$__C_DIM" "$_ren" "$__C_RESET" "$__C_DIM" "$(_home_trunc "$label" "$_resume_title_budget")" "$__C_RESET"
          if [ -n "$alias" ]; then
            # recap, wrapped with a hanging indent. extra=2 for the wrapper's `  ` prefix.
            _home_wrap_prefixed "$alias" "        -> " 11 "$__C_DIM" "$__C_RESET" 2
          else
            printf '        %b%s · %s%b\n' "$__C_DIM" "$rage" "$T_ENTER_RESUME" "$__C_RESET"
          fi
        else
          printf '  %b %b %s %b%s%b %b"%s"%b\n' "$mark" "$rdot" "$_rnm" "$__C_DIM" "$_ren" "$__C_RESET" "$__C_DIM" "$(_home_trunc "$label" "$_resume_title_budget")" "$__C_RESET"
        fi
        ;;
      tank)
        # Two sections in burn order: fleet under "Tanks", solo (out-of-the-fleet)
        # under "Solo" — the section IS the badge (no per-row 🔒). Soul sharing isn't
        # shown: in the fleet a shared brain is the normal state. cur_cli doubles as
        # the current-section marker ("fleet"/"solo"); other cases test it for "any
        # tank printed yet".
        if tank_is_solo "$cli" "$profile"; then
          if [ "$cur_cli" != "solo" ]; then printf '\n  %b%s%b\n' "$__C_BCYAN" "$T_SOLO_SECTION" "$__C_RESET"; cur_cli="solo"; fi
        elif [ "$cur_cli" != "fleet" ]; then
          printf '  %b%s%b\n' "$__C_BCYAN" "$T_TANKS" "$__C_RESET"; cur_cli="fleet"
        fi
        local _eng; _eng="$(_home_engine_label "$cli")"
        local _fd; _fd="$(_home_fuel_dot "$dry" "$cli" "$profile")"
        dot="${_fd%%$'\037'*}"; _reset="${_fd#*$'\037'}"
        # Aligned columns (display-width padded): name · engine · account, then a
        # right gutter holding the reset time when the tank is dry. (No "this shell"
        # marker — see _home_render_static: with many tanks open at once it's noise.)
        local _nm _en _ac _tail="" _sep=""
        _nm="$(_home_lpad "$profile" 7)"; _en="$(_home_lpad "$_eng" 8)"; _ac="$(_home_lpad "${label:--}" 22)"
        if [ -n "$_reset" ]; then _tail="$(printf '%b%s%b' "$__C_YELLOW" "$_reset" "$__C_RESET")"; fi
        [ -n "$_tail" ] && _sep="  "
        if [ "$idx" -eq "$sel" ]; then
          printf '  %b %b %b%s%b %b%s%b %b%s%b%s%s\n' \
            "$mark" "$dot" "$__C_BOLD" "$_nm" "$__C_RESET" "$__C_DIM" "$_en" "$__C_RESET" "$__C_DIM" "$_ac" "$__C_RESET" "$_sep" "$_tail"
        else
          printf '  %b %b %s %b%s%b %b%s%b%s%s\n' \
            "$mark" "$dot" "$_nm" "$__C_DIM" "$_en" "$__C_RESET" "$__C_DIM" "$_ac" "$__C_RESET" "$_sep" "$_tail"
        fi
        ;;
      target)
        # Under "Also available" (not a floating group). Enter launches it
        # single-account; `n` → agy makes it a tank (SU takeover).
        if [ "$printed_also" -eq 0 ]; then
          printed_also=1
          [ -n "$cur_cli" ] && printf '\n'
          printf '  %b%s%b\n' "$__C_BOLD" "$T_ALSO_AVAILABLE" "$__C_RESET"
        fi
        if _reset="$(_home_is_dry "$dry" "$cli" "$profile")"; then tdot="${__C_RED}●${__C_RESET}"
        else tdot="${__C_DIM}·${__C_RESET}"; _reset=""; fi
        # Same wrap as the static board's "Also available" row: the note is a
        # full localized sentence, so it hangs under column 19 (2 lead + mark +
        # space + dot + space + 12-wide engine + space) instead of overflowing.
        _line="$note"; [ -n "$_reset" ] && _line="$note $_reset"
        if [ "$idx" -eq "$sel" ]; then
          _home_wrap_prefixed "$_line" \
            "$(printf '  %b %b %b%-12s%b ' "$mark" "$tdot" "$__C_BOLD" "$cli" "$__C_RESET")" 19 "$__C_DIM" "$__C_RESET" 2
        else
          _home_wrap_prefixed "$_line" \
            "$(printf '  %b %b %-12s ' "$mark" "$tdot" "$cli")" 19 "$__C_DIM" "$__C_RESET" 2
        fi
        ;;
      agent)
        if [ "$printed_also" -eq 0 ]; then
          printed_also=1
          [ -n "$cur_cli" ] && printf '\n'
          printf '  %b%s%b\n' "$__C_BOLD" "$T_ALSO_AVAILABLE" "$__C_RESET"
        fi
        if [ "$idx" -eq "$sel" ]; then
          _home_wrap_prefixed "$note" \
            "$(printf '  %b %b· %-12s ' "$mark" "$__C_BOLD" "$cli")" 19 "$__C_BOLD" "$__C_RESET" 2
        else
          _home_wrap_prefixed "$note" \
            "$(printf '  %b · %-12s ' "$mark" "$cli")" 19 "$__C_DIM" "$__C_RESET" 2
        fi
        ;;
    esac
    idx=$((idx + 1))
  done <<EOF
$items
EOF
  if [ "$printed_resume" -eq 1 ]; then
    local total_s; total_s="$(_home_total_sessions)"
    printf '    %b%s%b\n' "$__C_DIM" "$(printf "$T_RESUME_FOOTER" "$total_s")" "$__C_RESET"
  fi
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
  stty -echo 2>/dev/null || true
  printf '\033[?1049h\033[?25l'   # re-enter alt screen, hide cursor
}

# Toggle the solo marker on a tank — instant + silent (the picker redraws the badge
# itself). solo = out of the fleet: no relay/`to`, skipped by burn/watch, `memory
# share` refuses it. The CLI face is `clikae solo`; this is the board's one-key form.
_home_toggle_solo() {
  local f; f="$(solo_marker_file "$1" "$2")"
  if [ -f "$f" ]; then rm -f "$f"; else mkdir -p "$(dirname "$f")"; : > "$f"; fi
}

# The memory dial on the selected TANK (the `m` key): point its long-term memory at
# a shared "Soul" group, restore its own, or show the sharing state. Routes through
# `clikae memory`, which resolves the per-engine strategy (claude fans its memory DIR
# in; codex/agy get a pointer note). Runs in the NORMAL screen (it prompts for a group
# name and may ask to confirm crossing accounts), so the caller wraps it in _home_stay.
# The CLI face is `clikae memory`; this is the board's one-key door to the same verbs.
_home_memory() {
  local kind cli profile rest
  IFS=$'\037' read -r kind cli profile rest <<EOF
$1
EOF
  : "$rest"
  [ "$kind" = "tank" ] || return 0
  # `clikae memory` takes the engine name; for an agy tank the board's cli field is
  # already the canonical "antigravity", which memory.sh maps internally — pass it through.
  local opts choice
  opts="$(printf '%s\n%s\n%s' "$T_MEM_OPT_SHARE" "$T_MEM_OPT_ISOLATE" "$T_MEM_OPT_STATUS")"
  choice="$(_home_choose "$T_MEM_TITLE  ($(_home_engine_label "$cli")/$profile)" "$opts" "$T_MEM_OPT_SHARE")" || return 0
  case "$choice" in
    "$T_MEM_OPT_SHARE")
      local group
      printf '\n%s  %s/%s\n' "$T_MEM_SHARE_FOR" "$(_home_engine_label "$cli")" "$profile"
      read -rp "  $T_MEM_GROUP_PROMPT" group || return 0
      [ -n "$group" ] || { printf '  %s\n' "$T_MEM_NOGROUP"; return 0; }
      "$CLIKAE_BIN" memory share "$group" "$cli" "$profile" || true
      ;;
    "$T_MEM_OPT_ISOLATE")
      "$CLIKAE_BIN" memory isolate "$cli" "$profile" || true
      ;;
    "$T_MEM_OPT_STATUS")
      "$CLIKAE_BIN" memory status "$cli" "$profile" || true
      ;;
  esac
}

_home_pick() {
  local items="$1" dry="$2"

  # Restore the terminal on any abnormal exit.
  trap '_home_tty_leave' EXIT
  trap '_home_tty_leave; exit 130' INT TERM
  stty -echo 2>/dev/null || true
  printf '\033[?1049h\033[?25l'   # enter alt screen, hide cursor
  # Keys come from a DEDICATED /dev/tty fd, never bare stdin — the same isolation
  # _home_choose and the resume picker already had (this board was the straggler;
  # stray stdout feedback bytes read as keystrokes on some terminals).
  exec 3</dev/tty 2>/dev/null || exec 3<&0

  # `view` is the (possibly filtered) list actually shown + indexed; `filter` is
  # the live `/` query. Everything navigational works on `view`; relay still reads
  # the FULL `items` so it can find the active source tank even when filtered out.
  local sel=0 n sel_row sel_kind sel_cli filter="" view
  view="$items"
  while :; do
    view="$(_home_filter "$items" "$filter")"
    n="$(printf '%s\n' "$view" | grep -c .)"
    if [ "$n" -le 0 ]; then
      # Filter matched nothing (or everything's gone): show a tiny notice, let the
      # user clear the filter or quit. Never get stuck on an empty board.
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
    [ "$sel" -ge "$n" ] && sel=$((n - 1))    # clamp after a delete/filter
    [ "$sel" -lt 0 ] && sel=0
    _home_pick_draw "$view" "$sel" "$dry"
    # One decoded key per frame from the tty fd (tui_read_key, lib/core/tui.sh);
    # a lone ESC quits, PgUp/Home jump top, PgDn/End jump bottom (the board has
    # no viewport, so page = jump).
    tui_read_key 3 || TUI_KEY="q"
    sel_row="$(printf '%s\n' "$view" | sed -n "$((sel + 1))p")"
    sel_kind="$(printf '%s' "$sel_row" | cut -d$'\037' -f1)"
    sel_cli="$(printf '%s' "$sel_row" | cut -d$'\037' -f2)"
    case "$TUI_KEY" in
      up|k|shift-tab) sel=$(( (sel - 1 + n) % n )) ;;
      down|j|tab)     sel=$(( (sel + 1) % n )) ;;
      home|pgup|g) sel=0 ;;                          # top
      end|pgdn|G)  sel=$(( n - 1 )) ;;               # bottom
      [1-9])
        # Jump to the Nth row (clamped). Fast access on a long board.
        sel=$(( TUI_KEY - 1 )); [ "$sel" -ge "$n" ] && sel=$(( n - 1 )) ;;
      '[')
        # Move the selected tank UP in the burn order (the board IS the order).
        if [ "$sel_kind" = "tank" ] && _home_reorder "$sel_cli" "$(printf '%s' "$sel_row" | cut -d$'\037' -f3)" -1; then
          items="$(_home_items)"; sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=0
        fi ;;
      ']')
        # Move the selected tank DOWN in the burn order.
        if [ "$sel_kind" = "tank" ] && _home_reorder "$sel_cli" "$(printf '%s' "$sel_row" | cut -d$'\037' -f3)" 1; then
          items="$(_home_items)"; sel=$(( sel + 1 ))
        fi ;;
      q|esc) break ;;
      /)
        _home_tty_leave
        printf '%b%s%b' "$__C_BOLD" "$T_FILTER_PROMPT" "$__C_RESET"
        IFS= read -r filter <&3 || filter=""
        stty -echo 2>/dev/null || true
        printf '\033[?1049h\033[?25l'; sel=0
        ;;
      '?')
        _home_help_overlay   # full key legend; any key dismisses, then redraw
        ;;
      l)
        _home_tty_leave; trap - EXIT INT TERM
        local _lang
        _lang="$(_home_choose "$T_LANG_PICK    $T_PICKER_HINT" "$(_i18n_locales)" "$(clikae_lang)")" || _lang=""
        [ -n "$_lang" ] && i18n_set "$_lang"
        trap '_home_tty_leave' EXIT; trap '_home_tty_leave; exit 130' INT TERM
        stty -echo 2>/dev/null || true
        printf '\033[?1049h\033[?25l'
        items="$(_home_items)"; dry="$(_home_dry_set)"
        ;;
      A)
        # Cycle autonomy ask → safe → full → ask (consumed by the BETA supervised
        # launch). Shown live on the board's autonomy line.
        case "$(autonomy_get)" in
          ask)  autonomy_set safe ;;
          safe) autonomy_set full ;;
          *)    autonomy_set ask ;;
        esac
        ;;

      # --- leave actions: these launch a CLI, so exiting the picker is expected
      # (each closes fd 3 first so the tty fd never leaks into the engine).
      enter)
        if [ "$sel_kind" = "resume" ]; then
          # Continue row → submenu (resume vs switch-fresh). Cancel returns here.
          _home_tty_leave; trap - EXIT INT TERM
          exec 3<&- 2>/dev/null || true
          _home_resume_action "$sel_row" "$dry" || {
            trap '_home_tty_leave' EXIT; trap '_home_tty_leave; exit 130' INT TERM
            stty -echo 2>/dev/null || true
            printf '\033[?1049h\033[?25l'
            exec 3</dev/tty 2>/dev/null || exec 3<&0
            continue
          }
          return 0
        fi
        _home_tty_leave; trap - EXIT INT TERM
        exec 3<&- 2>/dev/null || true
        _home_launch "$sel_row"
        return 0
        ;;
      r)
        if [ "$sel_kind" = "tank" ]; then
          _home_tty_leave; trap - EXIT INT TERM
          exec 3<&- 2>/dev/null || true
          _home_relay "$items" "$sel_row"
          return 0
        fi
        ;;
      R)
        # Open the full cross-tank resume picker. exec the dispatcher (the same
        # idiom every other launch in this board uses): cmd_resume lives in
        # resume.sh, which isn't sourced in the home process — and can't be sourced
        # at home.sh's top, since resume.sh sources home.sh (mutual-source loop).
        _home_tty_leave; trap - EXIT INT TERM
        exec 3<&- 2>/dev/null || true
        exec "$CLIKAE_BIN" resume
        ;;
      x)
        # Incognito — open the selected tank with throwaway memory
        # (--ephemeral). A clean, amnesiac session: this run's long-term memory
        # evaporates on exit.
        if [ "$sel_kind" = "tank" ]; then
          _home_tty_leave; trap - EXIT INT TERM
          exec 3<&- 2>/dev/null || true
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
      s)
        # Toggle SOLO on the selected tank — instant, no drop to the shell. A solo
        # tank is out of the fleet (no relay/burn/share), so it moves between the
        # Tanks and Solo sections: rebuild items so the row re-partitions, and follow
        # it by name so the cursor stays on the tank you just toggled.
        if [ "$sel_kind" = "tank" ]; then
          local _sp; _sp="$(printf '%s' "$sel_row" | cut -d$'\037' -f3)"
          _home_toggle_solo "$sel_cli" "$_sp"
          items="$(_home_items)"
          local _vv _i=0 _row2
          _vv="$(_home_filter "$items" "$filter")"
          while IFS= read -r _row2; do
            [ "$(printf '%s' "$_row2" | cut -d$'\037' -f1)" = "tank" ] \
              && [ "$(printf '%s' "$_row2" | cut -d$'\037' -f2)" = "$sel_cli" ] \
              && [ "$(printf '%s' "$_row2" | cut -d$'\037' -f3)" = "$_sp" ] && { sel=$_i; break; }
            _i=$(( _i + 1 ))
          done <<EOF
$_vv
EOF
        fi
        ;;
      m)
        # Memory dial on the selected tank: share into a Soul group / isolate /
        # status. Prompts + may confirm a cross-account merge, so it runs in the
        # normal screen via _home_stay, then the board refreshes.
        if [ "$sel_kind" = "tank" ]; then
          _home_stay _home_memory "$sel_row"
          items="$(_home_items)"; dry="$(_home_dry_set)"
        fi
        ;;
      c)
        # Free disk space: open `clikae clean` (its own screen, its own red
        # confirm), then come back to the board — every capability gets a
        # first-class key from the hub, and an adjacent screen returns where
        # you came from (grammar §8.1). Row-independent, like `n`.
        _home_stay "$CLIKAE_BIN" clean
        items="$(_home_items)"; dry="$(_home_dry_set)"
        ;;
    esac
  done

  exec 3<&- 2>/dev/null || true
  _home_tty_leave; trap - EXIT INT TERM
  # On quit, leave the static board (unfiltered) in the normal scrollback.
  _home_render_static "$items" "$dry"
}

# Shown once, BEFORE the board, when a newer clikae is out (the codex-style startup
# notice — see lib/core/update_check.sh). Interactive/TTY-only; the caller already
# gated that. Returns 0 to continue into the board, or 10 when an upgrade just ran
# (home should stop so the user relaunches on the new binary).
_home_update_prompt() {
  update_check_refresh
  local latest; latest="$(update_check_pending)" || return 0
  local cmd; cmd="$(update_upgrade_command)"
  # The ✨ banner doubles as the menu title (_home_choose prints the title above the
  # options, codex-style). Release-notes link on its own line.
  local title opt1 opts choice
  title="$(printf '%b✨ %s%b  clikae %s → %s\n%b%s %s%b' \
    "$__C_YELLOW" "$T_UPDATE_AVAIL" "$__C_RESET" "$CLIKAE_VERSION" "$latest" \
    "$__C_DIM" "$T_UPDATE_NOTES" "https://github.com/CVERInc/clikae/releases/latest" "$__C_RESET")"
  if [ -n "$cmd" ]; then opt1="$(printf "$T_UPDATE_NOW" "$cmd")"; else opt1="$T_UPDATE_SHOW"; fi
  opts="$(printf '1. %s\n2. %s\n3. %s' "$opt1" "$T_UPDATE_SKIP" "$T_UPDATE_SKIP_VER")"
  choice="$(_home_choose "$title" "$opts" "1. $opt1")" || return 0   # cancel/q = skip this time
  case "$choice" in
    "1. $opt1")
      if [ -n "$cmd" ]; then
        printf '\n  %b$ %s%b\n\n' "$__C_DIM" "$cmd" "$__C_RESET"
        if eval "$cmd"; then
          printf '\n  %b✓ %s%b\n\n' "$__C_GREEN" "$T_UPDATE_DONE" "$__C_RESET"
        else
          log_warn "$T_UPDATE_FAILED"
        fi
        return 10   # stop home; relaunch picks up the new binary
      fi
      # Unknown install method → only show the command + release page, never guess-run.
      printf '\n  %s\n    %s\n\n' "$T_UPDATE_MANUAL" "https://github.com/CVERInc/clikae/releases/latest"
      return 10
      ;;
    "3. $T_UPDATE_SKIP_VER") update_check_skip "$latest" ;;   # quiet until something newer ships
    *) : ;;                                                   # 2. Skip (or cancel) → just continue
  esac
  return 0
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
  [ / ]   move the tank up/down (the board IS your burn order)
  r   relay this shell's session into it     x   open it incognito (--ephemeral)
  n   new tank                a   rename the tank (carries alias + login)
  d   delete a tank (asks)    s   solo (out of the fleet)   m   memory (Soul)
  c   clean up session data — free disk space (opens `clikae clean`, comes back)
  /   filter                  A   autonomy (BETA)           l   language
  q/Esc  quit

On a Continue row, Enter offers a small menu: resume that exact session, or just
switch to its tank with a fresh one. The board is a single flat list in your BURN
ORDER (not grouped by engine; engine shown as an inline tag) — arrange it with
[ / ]. It also has an "Also available" section of relay-capable CLIs/targets you
can open without a tank (codex, agy).

Interface language follows `clikae lang` (bare `clikae lang` lists the
choices); the `l` key opens a language picker. When output isn't a terminal (a pipe, a script, the GUI), it
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
    # A newer clikae out? Offer it first (codex-style), before the board. If an
    # upgrade ran (return 10), stop so the user relaunches on the new binary.
    local _u=0; _home_update_prompt || _u=$?
    [ "$_u" -eq 10 ] && return 0
    _home_pick "$items" "$dry"
  else
    _home_render_static "$items" "$dry"
  fi
}
