# shellcheck shell=bash
# lib/commands/clean.sh — `clikae clean`: free disk space by moving old session
# data (transcripts, databases, brain assets) to the Trash, across every tank.
# clean never `rm`s a session outright — a transcript is a conversation, not a
# cache; nothing regenerates it — so it moves to $HOME/.Trash and the space
# comes back only once the Trash is emptied. (Sibling product sheersweep holds
# the same line for macOS uninstalls; see its `to_trash()`.)
#
# Extracted from `resume cleanup` (shipped v0.13.1) into a first-class command:
# disk hygiene isn't a resume concern, and a capability buried under another
# command's subtree is a design smell (grammar.md §8.1 "the board is the hub").
# The board's `c` key and the resume picker's `c` key both open this screen and
# return where you came from; `clikae resume cleanup` survives as a hidden
# back-compat alias (§7) that forwards here.
#
# The zero-knowledge path: type `clikae clean`, look at ONE list in three
# sections — pre-checked where moving it out is provably safe or plainly
# overdue, unchecked where it's a judgment call — press Enter, confirm in red.
# The flags (--dry-run / --older-than / --min-size) are the power-user
# vocabulary over the same pool; none is required to see where the space went.
# A session any process still has open is never a candidate, in any section —
# `_clean_session_is_live` is the one guard every class routes through (a
# 2026-07-11 incident shipped in v0.14.0: the dedupe path checked live
# processes, the main scan loop didn't, and a still-open 612 MB session
# surfaced unchecked and got `rm`'d — unrecoverable, since Claude Code holds no
# open handle on its per-event-append transcripts for `lsof` to rescue).

# Sourcing resume.sh brings the shared session plumbing this scan rides on
# (_resume_all_sessions, _resume_session_fields) plus — through it — home.sh's
# TUI kernel and localized T_* strings: the same reuse pattern resume.sh itself
# uses for home.sh. (resume.sh never sources THIS file — its alias and `c` key
# reach clean through $CLIKAE_BIN, so there is no source loop.)
# shellcheck source=resume.sh
source "$CLIKAE_LIB/commands/resume.sh"

# The _rs_* slots are populated by resume.sh's _resume_session_fields (the
# shared path decoder). Declared here too so shellcheck — which doesn't follow
# the source above without -x — knows they're ours, not typos (SC2154).
_rs_engine=""; _rs_tank=""; _rs_sid=""

# The built-in floor for the "Big but recent — your call" section: any session
# at least this big is worth SHOWING even when no filter selects it (space
# usually lives in big RECENT sessions — nobody should need a flag to see the
# hogs). Purely informational: rows in that section always start unchecked.
CLIKAE_CLEAN_BIG_MB=20

_clean_help() {
  cat <<'EOF'
Usage: clikae clean [options]

Move old session data files (transcripts, databases, brain assets) to the Trash
to free disk space — a session transcript is a conversation, not a cache, so
clean never shreds it outright; emptying the Trash afterward is what actually
reclaims the space. This only moves session history files. It never touches
tank configurations, memory files, caches, or settings. (If the Trash itself is
unusable, a row falls back to a direct delete and says so, instead of silently
lying about where the data went.) A session a process still has open is never
offered, in any section.

The preview is ONE checkbox list in three sections, biggest first within each:

  Redundant (safe)              pre-checked. Two kinds of pure waste, offered on
                                every run regardless of the filters:
                                - stale copies: `clikae to`/relay and a cross-tank
                                  resume COPY the session into the target tank and
                                  leave the source behind. Copies of one session
                                  are grouped across all tanks and project dirs,
                                  the LARGEST copy is kept, and a copy is offered
                                  only when it is provably contained in the kept
                                  one (an exact byte prefix, or a tail of
                                  session-metadata lines only).
                                - orphaned subagent data: claude keeps a sibling
                                  `<session-id>/` directory next to each
                                  transcript; a sid directory whose transcript is
                                  already gone is pure waste. (Cleaning a
                                  transcript removes its sibling directory too.)
  Untouched for 30+ days        pre-checked. Sessions older than --older-than
                                (default 30 days).
  Big but recent — your call    UNCHECKED. Sessions of at least 20 MB that the
                                sections above didn't claim — shown so the space
                                hogs are visible with no flags — plus copies with
                                unique conversation content, labeled
                                "diverged — has unique content". Nothing here is
                                moved to the Trash unless you check it yourself.

Arrows move, space toggles a row, `a` toggles all, Enter proceeds to the final
red confirmation, q/ESC cancels. Nothing moves before that confirmation.

Options:
  -d, --dry-run             Preview what would move to the Trash (the same
                            sectioned list, with each row's default [x]/[ ]
                            state), without moving anything.
  -o, --older-than <days>   Only pre-check sessions older than <days> (default: 30).
  -m, --min-size <MB>       Only target sessions of at least <MB> MB. Given alone,
                            size is the only filter (no age cutoff); combine with
                            --older-than to require both. Stale copies and orphans
                            ignore both filters.
  -h, --help                Show this help message.

Examples:
  clikae clean
  clikae clean --older-than 7
  clikae clean --min-size 5
  clikae clean --min-size 5 --older-than 30
  clikae clean --dry-run

(`clikae resume cleanup`, where this flow first shipped, still works as a hidden
back-compat alias and forwards here.)
EOF
}

# ── Sizing helpers ──────────────────────────────────────────────────────────

# _batch_du_kb <path>... — print one "<kb>" line PER ARGUMENT, in argument order
# (0 for a missing path). ONE `du -sk` over everything (chunked for argv limits)
# instead of a `du | awk` pair per path: the per-path form made the clean scan
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

# _kb_compact <kb> — the SQUEEZED size ("512K" / "21M" / "2.3G"): the same number
# with the space and the second unit letter dropped. Step 2 of the row's
# progressive disclosure (_clean_row_fit) — a size still worth showing, in ~half
# the columns, before we give up on showing it at all.
_kb_compact() {
  local kb="$1" v
  if [ "$kb" -lt 1024 ]; then
    printf '%dK' "$kb"
  elif [ "$kb" -lt 1048576 ]; then
    v=$(( (kb * 10 + 512) / 1024 ))
    if [ $((v % 10)) -eq 0 ] || [ $((v / 10)) -ge 10 ]; then printf '%dM' $((v / 10))
    else printf '%d.%dM' $((v / 10)) $((v % 10)); fi
  else
    v=$(( (kb * 10 + 524288) / 1048576 ))
    printf '%d.%dG' $((v / 10)) $((v % 10))
  fi
}

# _clean_row_fit <avail> <ident_w> <title> <age> <size_kb> <lbl> — decide WHAT a
# candidate row can afford to show in <avail> display columns, and set
#   _CR_TITLE  (truncated to what's left)
#   _CR_AGE    (the age string, or "" = dropped)
#   _CR_SIZE   (full / compact / "" = dropped)
#   _CR_WRAP   (1 = the label did not fit on line 1; caller puts it on a
#               continuation line)
#
# PROGRESSIVE DISCLOSURE BY IMPORTANCE. A row that cannot fit must DROP its
# least valuable column, never overflow the terminal. The sacrifice order is a
# product decision, not an arbitrary one: this is a DELETION list, so the two
# things that must survive to the last column are
#   * the LABEL — it carries the safety semantics ("stale copy (kept: b)",
#     fr "copie obsolète (celle de %s est gardée)"). NEVER truncated. In some
#     languages it is legitimately long; the render adapts, the words don't.
#   * the TITLE — you must be able to RECOGNIZE the session you're about to
#     delete. That is the whole reason this list exists, so the title does not
#     merely survive: it gets FIRST CLAIM on the columns. Age and size may only
#     spend what's left once the title has _CR_TITLE_GOOD columns; below that
#     they are sacrificed to buy the title room, and only when the title still
#     can't reach _CR_TITLE_GOOD do we settle for a title as small as
#     _CR_TITLE_MIN. (A 12-column title is a last resort, not a target — a row
#     that shows "0d ago · (20 KB)" next to "Refactor the …" spends its columns
#     on exactly the wrong things, which is how the incident happened.)
# Age and size are merely nice-to-have, so they go first, in this order:
#   1. age            (dropped outright)
#   2. size           (compressed "21.0 MB" -> "21M", then dropped)
#   3. title          (truncated, floor _CR_TITLE_MIN)
#   4. still doesn't fit -> the label moves to its own continuation line
#      (_CR_WRAP=1), which frees line 1 to show age/size again.
# <lbl> is passed WITH its " · " separator already attached (so an absent label
# is simply the empty string and costs 0 columns).
_CR_TITLE_MIN=12
_CR_TITLE_GOOD=24
_clean_row_fit() {
  local avail="$1" ident_w="$2" title="$3" age="$4" size_kb="$5" lbl="$6"
  local title_w lbl_w base cfg age_on size_s over budget need want
  title_w="$(_dwidth "$title")"
  lbl_w="$(_dwidth "$lbl")"
  # Always-present chrome around the variable pieces: " · " before the title,
  # the title's two quotes, and 1 more column for the "…" `_home_trunc` appends
  # when it DOES truncate (its <n> argument is the pre-ellipsis length, so a
  # truncated title actually renders <n>+1 columns wide — forgetting that is a
  # silent off-by-one that puts every truncated row 1 column over the terminal).
  base=$(( ident_w + 3 + 2 + 1 ))
  local sz_full sz_comp
  sz_full="$(_kb_human "$size_kb")"
  sz_comp="$(_kb_compact "$size_kb")"

  # TWO passes over the sacrifice ladder. Pass 1 demands the title reach
  # _CR_TITLE_GOOD (or fit whole) — so a config that would show age/size while
  # squeezing the title to a stub is REJECTED, and we drop age/size instead.
  # Only if nothing on the ladder can give the title a good width does pass 2
  # relax the demand to _CR_TITLE_MIN. `1`/`0` = age shown/dropped.
  local try_lbl_w="$lbl_w" wrap=0
  while :; do
    for want in "$_CR_TITLE_GOOD" "$_CR_TITLE_MIN"; do
      need="$want"; [ "$title_w" -lt "$need" ] && need="$title_w"
      for cfg in "1:$sz_full" "0:$sz_full" "0:$sz_comp" "0:"; do
        age_on="${cfg%%:*}"; size_s="${cfg#*:}"
        over=$(( base + try_lbl_w ))
        [ "$age_on" = "1" ] && over=$(( over + 3 + $(_dwidth "$age") ))
        [ -n "$size_s" ] && over=$(( over + 5 + $(_dwidth "$size_s") ))
        budget=$(( avail - over ))
        if [ "$budget" -ge "$need" ]; then
          _CR_TITLE="$(_home_trunc "$title" "$budget")"
          [ "$age_on" = "1" ] && _CR_AGE="$age" || _CR_AGE=""
          _CR_SIZE="$size_s"
          _CR_WRAP="$wrap"
          return 0
        fi
      done
    done
    # Nothing fit even with age AND size gone. If the label is still on line 1,
    # move it to a continuation line and retry — that's what frees the room.
    if [ "$wrap" -eq 0 ] && [ "$lbl_w" -gt 0 ]; then
      wrap=1; try_lbl_w=0; continue
    fi
    # No label to move (or already moved) and STILL too narrow: an absurdly
    # narrow terminal. Show the title at its floor and nothing else — the row
    # may exceed `avail` here, but only because `avail` is smaller than
    # ident + a 12-col title, which no column-dropping can fix.
    _CR_TITLE="$(_home_trunc "$title" "$_CR_TITLE_MIN")"
    _CR_AGE=""; _CR_SIZE=""; _CR_WRAP="$wrap"
    return 0
  done
}

# _file_bytes <path> — the file's exact byte size (0 if missing). du prices
# candidates for the preview, but picking WHICH copy of a duplicated session to
# keep needs exact bytes, not blocks: the kept copy must be the byte-superset.
_file_bytes() {
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null || echo 0
  return 0
}

# ── The live-session guard ──────────────────────────────────────────────────

# _clean_session_is_live <path-or-sid> <ps-snapshot> — is a process still bound
# to this session? <ps-snapshot> is one `ps -axo command=` read (best-effort,
# taken once per run by the caller — see live_procs below); an empty/unreadable
# snapshot means "can't tell", and this must NEVER manufacture a false skip from
# that, only ever suppress a true one when the evidence is actually there.
#
# The ONE session-id derivation every candidate class shares, so a live session
# can never slip through as a candidate under a class this guard forgot to call
# (2026-07-11 incident: the dedupe path checked live_procs, the main scan loop
# never did, so a still-open session surfaced unchecked under "Big but recent"
# — one keypress from deletion):
#   - antigravity: the transcript sits at .../brain/<sid>/.system_generated/…,
#     so the sid is the brain/<sid>/ directory name, not the filename.
#   - claude: the sid IS the transcript's basename minus `.jsonl`.
#   - codex: the rollout file is `rollout-<ts>-<uuid>.jsonl`; `ps` only ever
#     shows the bare uuid a live `codex --resume` was given, never the
#     timestamp-prefixed filename, so once what's left after stripping the
#     directory and extension is longer than a uuid (36 chars), keep only its
#     trailing 36 — this also makes a bare sid string (as `_clean_dedupe_flush`
#     already has post-grouping, for both engines) a valid input as-is.
_clean_session_is_live() {
  local raw="$1" snap="$2" sid
  [ -n "$snap" ] || return 1
  [ -n "$raw" ] || return 1
  case "$raw" in
    */.system_generated/*)
      sid="${raw%/.system_generated/*}"; sid="${sid##*/}" ;;
    *)
      sid="${raw##*/}"      # drop any directory part
      sid="${sid%.jsonl}"   # drop the transcript extension, if present
      if [ "${#sid}" -gt 36 ]; then
        sid="${sid:$(( ${#sid} - 36 ))}"
      fi
      ;;
  esac
  [ -n "$sid" ] || return 1
  case "$snap" in *"$sid"*) return 0 ;; esac
  return 1
}

# ── The Trash move ──────────────────────────────────────────────────────────

# _clean_to_trash <path> — move <path> into $HOME/.Trash instead of destroying
# it: a session transcript is a CONVERSATION, not a cache — nothing regenerates
# it, so `rm` is never the right tool here (2026-07-11 incident: a live 612 MB,
# 6-day-old transcript was `rm -rf`'d; Claude Code holds no open handle on its
# per-event-append transcripts, so there was no inode left for `lsof` to rescue,
# and `rm` never reaches the Trash in the first place — unrecoverable).
# Collision-safe: two tanks can hold same-named copies of one session id, so a
# name clash gets a " (1)", " (2)", … suffix — an existing Trash entry is NEVER
# clobbered. Sets on return:
#   CLEAN_TRASH_DEST      the path it landed at (empty if <path> didn't exist)
#   CLEAN_TRASH_FELL_BACK 1 if the Trash was unusable (no $HOME, missing/
#                          unwritable .Trash, or the mv itself failed) and
#                          <path> was rm'd directly instead — the caller MUST
#                          say so on that row; a silent fallback would be a lie
#                          about where the data went.
_clean_to_trash() {
  local item="$1" tdir base dest i
  CLEAN_TRASH_DEST=""
  CLEAN_TRASH_FELL_BACK=0
  [ -e "$item" ] || return 0
  if [ -n "${HOME:-}" ]; then
    tdir="$HOME/.Trash"
    # bin/clikae runs the whole tree under `set -eo pipefail`: a bare `mkdir`
    # as the last command of a `||` statement would abort the ENTIRE clikae
    # process on failure instead of falling through to the rm fallback below
    # (mid-deletion-loop, after some rows already moved — worse than the bug
    # this closes). `|| true` inside the `if` body keeps this graceful.
    if [ ! -d "$tdir" ]; then mkdir -p "$tdir" 2>/dev/null || true; fi
    if [ -d "$tdir" ] && [ -w "$tdir" ]; then
      base="$(basename "$item")"
      dest="$tdir/$base"
      if [ -e "$dest" ]; then
        i=1
        while [ -e "$tdir/$base ($i)" ]; do i=$((i + 1)); done
        dest="$tdir/$base ($i)"
      fi
      if mv "$item" "$dest" 2>/dev/null; then
        # shellcheck disable=SC2034  # read by the caller / test harness, not this file
        CLEAN_TRASH_DEST="$dest"
        return 0
      fi
    fi
  fi
  # Trash unusable, or the mv itself failed (cross-device, permissions, …):
  # fall back to rm rather than leaving the row stuck — but CLEAN_TRASH_FELL_BACK
  # tells the caller to say so. `|| true` on both: same set -e note as above —
  # this fallback must never itself take the whole process down.
  CLEAN_TRASH_FELL_BACK=1
  if [ -d "$item" ]; then
    rm -rf "$item" 2>/dev/null || true
  elif [ -f "$item" ]; then
    rm -f "$item" 2>/dev/null || true
  fi
  return 0
}

# ── The stale-copy safety check ─────────────────────────────────────────────

# _clean_stale_copy_check <kept> <candidate> — is <candidate> safe to delete
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
_clean_stale_copy_check() {
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

# ── Candidate collection ────────────────────────────────────────────────────
# One candidate = one deletable session, carried in parallel cand_* arrays
# (bash-3.2 dynamic scoping; cmd_clean owns the arrays). Classes and the
# sections they land in:
#   stale / orphan → section 1 "Redundant (safe)"        — pre-checked
#   regular        → section 2 "Untouched for N+ days"    — pre-checked
#                    (or the --min-size pool when that stands alone)
#   big / diverged → section 3 "Big but recent — your call" — unchecked

# _clean_add_candidate <file> <mtime> <class> <label> — push one row onto the
# caller's cand_* arrays. Owns the per-engine map of "what does deleting this
# session mean", including claude's sibling `<sid>/` directory (subagent/
# workflow transcripts) — the pre-v0.13.1 flow deleted only the transcript and
# leaked those directories. Sizing is deferred: paths pile up in sz_paths and
# ONE batched du prices them after the scan. Titles are deferred too (filled
# only for rows that survive the filters) — the scan visits EVERY session, and
# a title parse per session would make the loop fork-bound again.
_clean_add_candidate() {
  local f="$1" mt="$2" cls="$3" lbl="$4"
  local files_to_del brain_part conversations_dir db_file sdir checked=1 sect=2
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
  case "$cls" in
    stale|orphan)  sect=1 ;;
    regular)       sect=2 ;;
    big|diverged)  sect=3; checked=0 ;;
  esac
  candidates+=("$f")
  cand_engine+=("$_rs_engine")
  cand_tank+=("$_rs_tank")
  cand_sid+=("$_rs_sid")
  cand_title+=("")
  # shellcheck disable=SC2059
  cand_age_str+=("$(printf "$T_CLEAN_AGE_AGO" "$(( (now - mt) / 86400 ))")")
  cand_files_to_delete+=("$files_to_del")
  cand_class+=("$cls")
  cand_label+=("$lbl")
  cand_checked+=("$checked")
  cand_section+=("$sect")
  return 0
}

# _clean_dedupe_flush — close out one (engine, session) group of the dedupe
# walk (g_sid/g_f/g_mt, dynamically scoped from cmd_clean). With two
# or more copies of one session, keep the LARGEST (see _clean_stale_copy_check
# on why not the newest) and offer every copy the safety check proves
# redundant. A copy that fails the check is surfaced as "diverged — has unique
# content" (section 3, unchecked) instead of being silently skipped — or
# worse, silently deleted.
_clean_dedupe_flush() {
  if [ "${#g_f[@]}" -lt 2 ]; then return 0; fi
  # Never dedupe under a live session: if any process still carries this sid
  # (e.g. a `--resume <sid>` in another terminal), the session may be mid-write.
  # One guard, one truth — same call the main scan loop makes below.
  _clean_session_is_live "$g_sid" "$live_procs" && return 0

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
  local stale_lbl
  # shellcheck disable=SC2059
  stale_lbl="$(printf "$T_CLEAN_LBL_STALE" "$kept_tank")"
  for ((i=0; i<${#g_f[@]}; i++)); do
    if [ "$i" -eq "$kept" ]; then continue; fi
    if _clean_stale_copy_check "${g_f[kept]}" "${g_f[i]}"; then
      _clean_add_candidate "${g_f[i]}" "${g_mt[i]}" stale "$stale_lbl"
    else
      _clean_add_candidate "${g_f[i]}" "${g_mt[i]}" diverged "$T_CLEAN_LBL_DIVERGED"
    fi
    dedupe_claimed="$dedupe_claimed"$'\n'"${g_f[i]}"
  done
  return 0
}

# _clean_scan_orphans — claude sid dirs whose transcript is already gone. The
# old flow deleted only `<sid>.jsonl` and left the sibling `<sid>/` directory
# of subagent/workflow transcripts behind; a sid dir with no matching top-level
# transcript in the same project dir is pure waste.
_clean_scan_orphans() {
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
    cand_title+=("$T_CLEAN_NO_TRANSCRIPT")
    # shellcheck disable=SC2059
    cand_age_str+=("$(printf "$T_CLEAN_AGE_AGO" "$(( (now - mt) / 86400 ))")")
    cand_files_to_delete+=("$d")
    cand_class+=(orphan)
    cand_label+=("$T_CLEAN_LBL_ORPHAN")
    cand_checked+=(1)
    cand_section+=(1)
  done
  return 0
}

# ── The sectioned preview ───────────────────────────────────────────────────

# _clean_section_header <1|2|3> — the localized heading for one section of the
# preview. Section 2's wording follows the active filters (older_than /
# min_size_mb / apply_age, dynamically scoped from cmd_clean): the default and
# --older-than paths say "Untouched for N+ days"; a lone --min-size says
# "M MB or larger"; both flags together say both.
_clean_section_header() {
  case "$1" in
    1) printf '%s' "$T_CLEAN_SECT_REDUNDANT" ;;
    2)
      if [ -n "$min_size_mb" ] && [ "$apply_age" -eq 0 ]; then
        # shellcheck disable=SC2059
        printf "$T_CLEAN_SECT_MIN" "$min_size_mb"
      elif [ -n "$min_size_mb" ]; then
        # shellcheck disable=SC2059
        printf "$T_CLEAN_SECT_OLD" "$older_than"; printf ' · '; printf "$T_CLEAN_SECT_MIN" "$min_size_mb"
      else
        # shellcheck disable=SC2059
        printf "$T_CLEAN_SECT_OLD" "$older_than"
      fi ;;
    3) printf '%s' "$T_CLEAN_SECT_BIG" ;;
  esac
}

# _clean_tally — recount the checked set (dynamically scoped ord/cand_* from
# cmd_clean) into sel_n / sel_kb / unsel_n. Called once for the static preview
# and again after the interactive picker, so the confirm and the final "freed"
# number always describe what is actually selected.
_clean_tally() {
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

# _clean_print_list — the non-interactive preview (--dry-run and the no-TTY
# refusal path): the same sectioned rows the checkbox picker shows, biggest
# first within each section, each with its default selection state. Only
# non-empty sections print a heading.
_clean_print_list() {
  local i idx box lbl sect last_sect="" cols
  cols="$(_home_cols)"
  for ((i=0; i<${#ord[@]}; i++)); do
    idx="${ord[i]}"
    sect="${cand_section[idx]}"
    if [ "$sect" != "$last_sect" ]; then
      [ -n "$last_sect" ] && printf '\n'
      printf '  %b%s%b\n' "$__C_BOLD" "$(_clean_section_header "$sect")" "$__C_RESET"
      last_sect="$sect"
    fi
    if [ "${cand_checked[idx]}" -eq 1 ]; then box="x"; else box=" "; fi
    lbl=""
    [ -n "${cand_label[idx]}" ] && lbl=" · ${cand_label[idx]}"
    # What this row can afford, in importance order (see _clean_row_fit): the
    # label is never truncated, the title never drops below _CR_TITLE_MIN, and
    # age/size are sacrificed — in that order — to buy the room. The lead
    # chrome is "  [x] " = 6 columns.
    local _ident
    _ident="${cand_engine[idx]}/${cand_tank[idx]}"
    _clean_row_fit "$(( cols - 6 ))" "$(_dwidth "$_ident")" \
      "${cand_title[idx]}" "${cand_age_str[idx]}" "${cand_size_kb[idx]}" "$lbl"
    local _mid=""
    [ -n "$_CR_AGE" ]  && _mid="$_mid · $_CR_AGE"
    [ -n "$_CR_SIZE" ] && _mid="$_mid · ($_CR_SIZE)"
    if [ "$_CR_WRAP" -eq 1 ]; then
      # The label didn't fit beside the rest: give it its own line, indented
      # under the row it belongs to. It is the safety semantics — it is shown
      # in full, always.
      printf '  [%s] %b%s%b · "%s"%b%s%b\n' \
        "$box" "$__C_BOLD" "$_ident" "$__C_RESET" "$_CR_TITLE" "$__C_DIM" "$_mid" "$__C_RESET"
      printf '      %b%s%b\n' "$__C_DIM" "${lbl# }" "$__C_RESET"
    else
      printf '  [%s] %b%s%b · "%s"%b%s%s%b\n' \
        "$box" "$__C_BOLD" "$_ident" "$__C_RESET" "$_CR_TITLE" "$__C_DIM" "$_mid" "$lbl" "$__C_RESET"
    fi
  done
  return 0
}

# _clean_prose <color> <text> — one line of clean's prose (the list heading, the
# totals, the unchecked hint, the dry-run note), WRAPPED to the terminal instead
# of running off the edge. These are full localized sentences: German's list
# heading alone measures 78 columns, so at 60 it must wrap. Drop-in for
# log_bold/log_dim here (they are plain `printf '%b%s%b\n'`, no prefix of their
# own, so wrapping loses nothing).
_clean_prose() {
  _home_wrap_prefixed "$2" "" 0 "$1" "$__C_RESET"
}

# _clean_row_h <cols> -> the height, in LINES, of EVERY candidate row in this
# frame: 2 if any candidate's label has to wrap onto a continuation line at
# <cols>, else 1. One height for all rows (not per-row) on purpose: the
# picker's viewport arithmetic is a plain row count, so a variable-height row
# would let the frame grow past the terminal's last line and scroll the alt
# screen. Reads the ord/cand_* arrays dynamically scoped from cmd_clean.
_clean_row_h() {
  local cols="$1" i idx lbl
  for ((i=0; i<${#ord[@]}; i++)); do
    idx="${ord[i]}"
    lbl=""
    [ -n "${cand_label[idx]}" ] && lbl=" · ${cand_label[idx]}"
    [ -n "$lbl" ] || continue
    _clean_row_fit "$(( cols - 10 ))" 16 \
      "${cand_title[idx]}" "${cand_age_str[idx]}" "${cand_size_kb[idx]}" "$lbl"
    [ "$_CR_WRAP" -eq 1 ] && { printf '2'; return 0; }
  done
  printf '1'
}

# One frame of the checkbox picker (viewport + header tally + section
# headings), composed in a command substitution and emitted by the caller as
# ONE printf between BSU/ESU — the same anti-flicker split _resume_pick_draw
# documents.
_clean_select_body() {
  local sel="$1" n="$2" max_visible="$3"
  local start_idx=0 end_idx=$(( n - 1 )) _cols row_h
  _cols="$(_home_cols)"
  row_h="$(_clean_row_h "$_cols")"
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
  _clean_tally

  printf '\033[H\033[K\n'   # home + one blank top-margin line
  # Hint WRAPPED, not shortened — same treatment as the board/resume keybars.
  _home_wrap_prefixed "$T_CLEAN_PICKER_HINT" \
    "$(printf '  %b%s%b  ' "$__C_BOLD" "clikae clean" "$__C_RESET")" 16 "$__C_DIM" "$__C_RESET"
  # shellcheck disable=SC2059
  printf '  %b%s%b\033[K\n\n' \
    "$__C_DIM" "$(printf "$T_CLEAN_TALLY" "$sel_n" "$n" "$(_kb_human "$sel_kb")")" "$__C_RESET"

  if [ "$start_idx" -gt 0 ]; then
    # shellcheck disable=SC2059
    printf '    %b%s%b\033[K\n' "$__C_DIM" "$(printf "$T_CLEAN_MORE_ABOVE" "$start_idx")" "$__C_RESET"
  fi
  local i idx mark box lbl row sect prev_sect=""
  for ((i=start_idx; i<=end_idx; i++)); do
    idx="${ord[i]}"
    sect="${cand_section[idx]}"
    # A section heading before the first visible row (so a scrolled viewport
    # still says where you are) and whenever the section changes.
    if [ "$i" -gt "$start_idx" ]; then prev_sect="${cand_section[${ord[i-1]}]}"; else prev_sect=""; fi
    if [ "$sect" != "$prev_sect" ]; then
      printf '  %b%s%b\033[K\n' "$__C_BCYAN" "$(_clean_section_header "$sect")" "$__C_RESET"
    fi
    if [ "$i" -eq "$sel" ]; then mark="${__C_GREEN}❯${__C_RESET}"; else mark=" "; fi
    if [ "${cand_checked[idx]}" -eq 1 ]; then box="[x]"; else box="[ ]"; fi
    lbl=""
    [ -n "${cand_label[idx]}" ] && lbl=" · ${cand_label[idx]}"
    # Same progressive disclosure as _clean_print_list (_clean_row_fit): label
    # never truncated, title never below _CR_TITLE_MIN, age then size dropped
    # to buy the room. Lead chrome here is "    " + mark + " " + box + " " = 10
    # columns; the engine/tank stays lpad'd to 16 so the columns still line up.
    _clean_row_fit "$(( _cols - 10 ))" 16 \
      "${cand_title[idx]}" "${cand_age_str[idx]}" "${cand_size_kb[idx]}" "$lbl"
    local _mid=""
    [ -n "$_CR_AGE" ]  && _mid="$_mid · $_CR_AGE"
    [ -n "$_CR_SIZE" ] && _mid="$_mid · ($_CR_SIZE)"
    # UNIFORM ROW HEIGHT: `row_h` (2 when ANY candidate's label had to wrap) is
    # decided once per frame by the caller, so every row occupies exactly the
    # same number of lines. That keeps the viewport arithmetic (max_visible,
    # start/end idx) a plain row count — a variable-height row would let a
    # frame grow taller than the terminal and scroll the alt-screen.
    row="$(printf '%s · "%s"%s' \
      "$(_home_lpad "${cand_engine[idx]}/${cand_tank[idx]}" 16)" "$_CR_TITLE" "$_mid")"
    if [ "$row_h" -eq 1 ]; then row="$row$lbl"; fi
    if [ "$i" -eq "$sel" ]; then
      printf '    %b %s %b%s%b\033[K\n' "$mark" "$box" "$__C_BOLD" "$row" "$__C_RESET"
    else
      printf '    %b %s %b%s%b\033[K\n' "$mark" "$box" "$__C_DIM" "$row" "$__C_RESET"
    fi
    if [ "$row_h" -eq 2 ]; then
      # The label's own line — shown in full, never truncated (safety
      # semantics). A row with no label still prints an (empty) second line, so
      # all rows keep the same height.
      printf '          %b%s%b\033[K\n' "$__C_DIM" "${lbl# }" "$__C_RESET"
    fi
  done
  if [ "$end_idx" -lt $(( n - 1 )) ]; then
    # shellcheck disable=SC2059
    printf '    %b%s%b\033[K\n' "$__C_DIM" "$(printf "$T_CLEAN_MORE_BELOW" "$(( n - 1 - end_idx ))")" "$__C_RESET"
  fi
  printf '\033[J'   # erase any leftover lines from a taller previous frame
  return 0
}

# _clean_select — the checkbox picker over the ord/cand_* arrays: arrows/j/k
# move (PgUp/PgDn/Home/End page), space toggles a row, `a` toggles everything,
# Enter hands the checked set to the caller's red confirm, q/ESC cancels. Same
# /dev/tty isolation + tui_read_key decode as _resume_pick and _relay_menu.
# Returns 0 to proceed, 1 on cancel, 2 when no TTY could be opened (the caller
# falls back to the printed list + all-or-nothing confirm).
_clean_select() {
  exec 3<>/dev/tty 2>/dev/null || return 2
  stty -echo 2>/dev/null || true
  printf '\033[?1049h\033[?25l' >&3
  trap '_home_tty_leave' EXIT
  trap '_home_tty_leave; exit 130' INT TERM

  local lsz lines=24 max_visible=15 _rh
  # Every row is _clean_row_h lines tall (2 when a long localized label has to
  # wrap), so the number of rows that FIT is the line budget divided by that
  # height — otherwise a wrapped frame would be twice as tall as the viewport
  # thinks and scroll the alt screen.
  _rh="$(_clean_row_h "$(_home_cols)")"
  lsz="$( { stty size </dev/tty; } 2>/dev/null || true )"
  if [ -n "$lsz" ]; then
    lines="${lsz%% *}"
    max_visible=$(( (lines - 11) / _rh ))   # 8 rows of chrome + up to 3 section headings
    [ "$max_visible" -lt 5 ] && max_visible=5
  fi

  local n=${#ord[@]} sel=0 rc=1 _frame idx all v i
  while :; do
    _frame="$(_clean_select_body "$sel" "$n" "$max_visible")"
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

cmd_clean() {
  local dry_run=0
  local older_than=30 older_given=0
  local min_size_mb=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) _clean_help; return 0 ;;
      -d|--dry-run) dry_run=1; shift ;;
      -o|--older-than)
        if [ -z "${2:-}" ] || [[ ! "$2" =~ ^[0-9]+$ ]]; then
          log_fail "$T_CLEAN_ERR_OLDER_THAN"
        fi
        older_than="$2"; older_given=1
        shift 2
        ;;
      -m|--min-size)
        if [ -z "${2:-}" ] || [[ ! "$2" =~ ^[0-9]+$ ]]; then
          log_fail "$T_CLEAN_ERR_MIN_SIZE"
        fi
        min_size_mb="$2"
        shift 2
        ;;
      *)
        # shellcheck disable=SC2059
        log_fail "$(printf "$T_CLEAN_ERR_UNKNOWN_ARG" "$1")"
        ;;
    esac
  done

  # Which filters gate the section-2 pool. --min-size alone means size is the
  # only axis (space lives in big recent files, not old ones); age applies by
  # default, or when --older-than was explicitly given alongside --min-size.
  # Stale copies and orphaned sid dirs are pure waste and bypass both filters;
  # the big-but-recent section has its own built-in floor.
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
  local -a cand_class=()     # regular | stale | diverged | orphan | big
  local -a cand_label=()     # extra preview note ("stale copy (kept: b)", …)
  local -a cand_checked=()   # the checkbox state; section 3 starts unchecked
  local -a cand_section=()   # 1 redundant · 2 filtered pool · 3 big-but-recent
  local -a sz_paths=()    # every path to size, flat — one batched du after the scan
  local -a cand_nsz=()    # how many sz_paths entries belong to candidate i

  # ── 1. Stale-copy reclaim ─────────────────────────────────────────────────
  # `clikae to`/relay and a cross-tank resume COPY the transcript into the target
  # tank and never GC the source, so the same session piles up across tanks (and
  # across project dirs after a rename — group by session, not by path). On a
  # real store this was 686 MB of redundant copies. One ps snapshot feeds the
  # live-session guard in _clean_dedupe_flush.
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
  local cur_key="" key g_sid="" eng_l sid_l mt_l f_l
  local -a g_mt=() g_f=()
  while IFS="$us" read -r eng_l sid_l mt_l f_l; do
    [ -n "$f_l" ] || continue
    key="$eng_l$us$sid_l"
    if [ "$key" != "$cur_key" ]; then
      _clean_dedupe_flush
      g_mt=(); g_f=(); cur_key="$key"; g_sid="$sid_l"
    fi
    g_mt+=("$mt_l"); g_f+=("$f_l")
  done <<EOF2
$dedupe_sorted
EOF2
  _clean_dedupe_flush

  # ── 2. Orphaned claude sid dirs (subagent/workflow data left behind) ──────
  _clean_scan_orphans

  # ── 3. The filtered pool + the big-but-recent sweep ──────────────────────
  # A session the active filters select is class "regular" (section 2, checked):
  # old enough by default, big enough when --min-size stands alone, both when
  # both flags are given. A RECENT session the age filter passes over is still
  # scanned as a potential "big but recent" row (section 3, unchecked) — seeing
  # the space hogs must never require a flag. Sizes aren't known yet, so the
  # class is provisional and step 5 drops whatever falls under its floor.
  while read -r mt f; do
    [ -n "$f" ] || continue
    case $'\n'"$dedupe_claimed"$'\n' in
      *$'\n'"$f"$'\n'*) continue ;;   # already offered as a stale/diverged copy
    esac
    # Same live-session guard as the dedupe path above (§1): a session a
    # process still holds must never become a candidate in ANY class. Skip it
    # silently — an unchecked row under "Big but recent" is still one keypress
    # from deletion, which is exactly the 2026-07-11 incident this closes.
    _clean_session_is_live "$f" "$live_procs" && continue
    if [ "$apply_age" -eq 1 ] && [ "$mt" -gt "$cutoff" ]; then
      _clean_add_candidate "$f" "$mt" big ""
    else
      _clean_add_candidate "$f" "$mt" regular ""
    fi
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

  # ── 5. Apply the size floors (they need the du prices) and order the list ─
  # Section first, biggest first within each: [1] redundant, [2] the filtered
  # pool, [3] big-but-recent + diverged. A "regular" row must clear an explicit
  # --min-size; a "big" row must clear the built-in floor.
  local -a ord=()
  local min_kb=0 oline ordered
  local big_kb=$(( CLIKAE_CLEAN_BIG_MB * 1024 ))
  [ -n "$min_size_mb" ] && min_kb=$(( min_size_mb * 1024 ))
  ordered="$(
    for ((ci=0; ci<${#candidates[@]}; ci++)); do
      if [ "${cand_class[ci]}" = "regular" ] && [ "${cand_size_kb[ci]}" -lt "$min_kb" ]; then
        continue
      fi
      if [ "${cand_class[ci]}" = "big" ] && [ "${cand_size_kb[ci]}" -lt "$big_kb" ]; then
        continue
      fi
      printf '%s %s %s\n' "${cand_section[ci]}" "${cand_size_kb[ci]}" "$ci"
    done | sort -k1,1n -k2,2rn
  )"
  while read -r _ _ oline; do
    [ -n "$oline" ] || continue
    ord+=("$oline")
  done <<EOF
$ordered
EOF

  if [ "${#ord[@]}" -eq 0 ]; then
    if [ -n "$min_size_mb" ] && [ "$apply_age" -eq 0 ]; then
      # shellcheck disable=SC2059
      log_ok "$(printf "$T_CLEAN_NONE_MINSIZE" "$min_size_mb")"
    elif [ -n "$min_size_mb" ]; then
      # shellcheck disable=SC2059
      log_ok "$(printf "$T_CLEAN_NONE_AGE_MINSIZE" "$older_than" "$min_size_mb")"
    else
      # shellcheck disable=SC2059
      log_ok "$(printf "$T_CLEAN_NONE_ALL" "$older_than" "$CLIKAE_CLEAN_BIG_MB")"
    fi
    return 0
  fi

  # ── 6. Titles, only for rows that survived the filters ───────────────────
  # From the transcript FILE, not (dir, sid): adapter_session_title derives its
  # path from $PWD's project, so every session outside the current directory
  # listed as T_CLEAN_NO_PREVIEW here.
  local oi idx title
  for ((oi=0; oi<${#ord[@]}; oi++)); do
    idx="${ord[oi]}"
    if [ -n "${cand_title[idx]}" ]; then continue; fi
    load_adapter "${cand_engine[idx]}" >/dev/null 2>&1 || true
    title=""
    if declare -F adapter_title_for_file >/dev/null 2>&1; then
      title="$(adapter_title_for_file "${candidates[idx]}" 2>/dev/null || true)"
    fi
    [ -n "$title" ] || title="$T_CLEAN_NO_PREVIEW"
    cand_title[idx]="$title"
  done

  local sel_n=0 sel_kb=0 unsel_n=0

  if [ "$dry_run" -eq 1 ] || [ ! -t 0 ]; then
    _clean_prose "$__C_BOLD" "$T_CLEAN_LIST_HEADING"
    echo
    _clean_print_list
    echo
    _clean_tally
    # shellcheck disable=SC2059
    _clean_prose "$__C_BOLD" "$(printf "$T_CLEAN_TOTAL" "$sel_n")"
    # shellcheck disable=SC2059
    _clean_prose "$__C_BOLD" "$(printf "$T_CLEAN_SPACE_TO_FREE" "$(_kb_human "$sel_kb")")"
    # shellcheck disable=SC2059
    [ "$unsel_n" -gt 0 ] && _clean_prose "$__C_DIM" "$(printf "$T_CLEAN_UNCHECKED_HINT" "$unsel_n")"
    echo
    if [ "$dry_run" -eq 1 ]; then
      _clean_prose "$__C_DIM" "$T_CLEAN_DRYRUN_NOTE"
      return 0
    fi
    # Never delete without a live confirmation: in a pipe / non-TTY there's no
    # one to press Enter, so refuse rather than proceed on EOF (clikae principle:
    # never silently destroy). --dry-run is the safe non-interactive preview.
    log_fail "$T_CLEAN_REFUSE_NONINTERACTIVE"
  fi

  # Interactive: pick WHAT to delete on the sectioned checkbox list, then the
  # red confirm.
  local sel_rc=0
  _clean_select && sel_rc=0 || sel_rc=$?
  if [ "$sel_rc" -eq 2 ]; then
    # No /dev/tty to draw the picker on — fall back to the printed list with its
    # default selection and the all-or-nothing confirm below.
    _clean_prose "$__C_BOLD" "$T_CLEAN_LIST_HEADING"
    echo
    _clean_print_list
    echo
  elif [ "$sel_rc" -ne 0 ]; then
    log_ok "$T_CLEAN_CANCELLED"
    return 0
  fi

  _clean_tally
  if [ "$sel_n" -eq 0 ]; then
    log_ok "$T_CLEAN_NOTHING_SELECTED"
    return 0
  fi

  # shellcheck disable=SC2059
  log_bold "$(printf "$T_CLEAN_SELECTED" "$sel_n")"
  # shellcheck disable=SC2059
  log_bold "$(printf "$T_CLEAN_SPACE_TO_FREE" "$(_kb_human "$sel_kb")")"
  echo
  printf "%b%s%b\n" "$__C_RED" "$T_CLEAN_CONFIRM_Q" "$__C_RESET"
  printf "%b%s%b" "$__C_BOLD" "$T_CLEAN_CONFIRM_PROMPT" "$__C_RESET"
  read -r _ || log_fail "$T_CLEAN_NO_CONFIRM"

  log_dim "$T_CLEAN_DELETING"
  local deleted_kb=0 pth
  local -a path_list=()
  for ((oi=0; oi<${#ord[@]}; oi++)); do
    idx="${ord[oi]}"
    [ "${cand_checked[idx]}" -eq 1 ] || continue
    IFS=';' read -ra path_list <<< "${cand_files_to_delete[idx]}"
    for pth in "${path_list[@]}"; do
      _clean_to_trash "$pth"
      if [ "$CLEAN_TRASH_FELL_BACK" -eq 1 ]; then
        # A silent rm fallback would lie about where the data went — say so on
        # this row, every time it happens.
        # shellcheck disable=SC2059
        log_warn "$(printf "$T_CLEAN_TRASH_UNAVAILABLE" "$pth")"
      fi
    done
    deleted_kb=$((deleted_kb + ${cand_size_kb[idx]}))
  done

  local deleted_sz_str; deleted_sz_str="$(_kb_human "$deleted_kb")"
  # shellcheck disable=SC2059
  log_ok "$(printf "$T_CLEAN_DONE" "$deleted_sz_str")"
}
