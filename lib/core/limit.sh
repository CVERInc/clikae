# shellcheck shell=bash
# lib/core/limit.sh — shared usage-limit detection.
#
# One home for "did this tank run dry?", used by both `clikae watch` (live tail)
# and `clikae` home (the dashboard ⚠ badge). Dogfooded 2026-05-31 against a real
# Max-20x limit: a genuine Claude limit is a synthetic API-error line the client
# injects into the transcript — NOT a normal model turn — so detection is
# structural, not a text match (a session merely discussing a limit must not trip
# it). See memory clikae-limit-marker-confirmed / clikae-relay-verified.

# limit_line_is_real <cli> <line> <pat> <explicit>
# Is ONE transcript line a genuine limit event (not just text mentioning one)?
# Per-cli because each vendor's transcript shape differs. When the caller passes
# an explicit pattern (explicit=1, i.e. --pattern / $CLIKAE_LIMIT_PATTERN), that's
# a deliberate override → pure text match, skipping the structural logic (the
# escape hatch for a new vendor or a changed marker). Unknown clis fall back to
# the text pattern so detection never silently regresses.
limit_line_is_real() {
  local cli="$1" line="$2" pat="$3" explicit="${4:-0}"
  if [ "$explicit" -eq 1 ]; then
    printf '%s' "$line" | grep -qaE "$pat"; return
  fi
  case "$cli" in
    claude)
      # synthetic + api-error flag are the structural signal; the text gate keeps
      # other synthetic errors (e.g. interrupts) from counting as a limit.
      case "$line" in *'"isApiErrorMessage":true'*) ;; *) return 1 ;; esac
      case "$line" in *'"model":"<synthetic>"'*)    ;; *) return 1 ;; esac
      printf '%s' "$line" | grep -qaiE "hit your [a-z]+ limit" ;;
    codex)
      # codex exec --json emits structured failure objects alongside the message.
      # CONFIRMED by a real burn (2026-06-01): a genuine limit is a clean event in
      # the `codex exec --json` STDOUT stream —
      #   {"type":"error","message":"You've hit your usage limit. … try again at
      #    Jun 7th, 2026 2:17 PM."}
      #   {"type":"turn.failed","error":{"message":"You've hit your usage limit…"}}
      # IMPORTANT: that shape lives ONLY in the exec stdout stream. It is NEVER
      # persisted to codex's rollout transcript — verified on the burned rollout:
      # it ends in a token_count with rate_limit_reached_type:null, then a
      # task_complete with last_agent_message:null, and no structured limit line.
      # So this matcher is correct for a tail of an exec stream, but the home
      # dashboard cannot detect a codex limit from a transcript (see
      # limit_profile_dry's note).
      # Two real shapes: the `--json` failure object (keep the type gate), and —
      # burn-confirmed 2026-06-03 — a PLAIN `codex exec` line carrying codex's own
      # wording ("You've hit your usage limit. … try again at <date> <time>"). The
      # plain path leans on that distinctive phrasing so prose doesn't trip it.
      case "$line" in
        *'"type":"turn.failed"'*|*'"type":"error"'*)
          printf '%s' "$line" | grep -qaiE "hit your (usage|session) limit|usage limit|rate_limit" ;;
        *)
          printf '%s' "$line" | grep -qaiE "hit your (usage|session) limit" ;;
      esac ;;
    *)
      # Unknown transcript cli: keep the legacy whole-line text match (no regress).
      printf '%s' "$line" | grep -qaE "$pat" ;;
  esac
}

# limit_codex_reset <text> -> echo codex's verbatim reset phrase ("try again at
# <date> <time>", "resets …", or "reset at …") if the text carries one, else
# nothing. Never computes a countdown — relays the vendor's own words (same
# spirit as the other detectors). Drives a "dry-until" window so watch/auto
# don't re-pick a tank before it recovers.
#
# P2-1 (2026-09-08 round-4 review): every classifier here used to read
# `printf '%s' "$text" | grep …` — a PIPE from a forked producer to a forked
# grep. That is fine for a short line, but once P2-1's fix stopped truncating
# the haystack before classification, a genuine large capture with the match
# near its START let grep exit (`-q`/`-o … | head -n 1`) long before the
# producer had written it all; on this machine that reliably HUNG the whole
# burn (SIGPIPE from the closed pipe never unblocked the producer in this
# nested tmux-wrapper/retry-loop context — reproduced with a 100 KiB capture,
# confirmed by backgrounding the same call and `wait`-ing on it, which did
# not hang). A here-string writes the WHOLE haystack to a real fd (bash's own
# temp file, not a bounded kernel pipe) before grep ever execs, so there is no
# concurrent producer left to block. Every classifier below reads its
# haystack the same way now — this one included, since it is handed
# codex's full reply by limit_codex_output_dry.
#
# P1-1 (2026-09-08 round-5 review): this only ever recognized "try again
# at …" — but the repo's OWN 175-row real-reset-phrase corpus
# (tests/fixtures/limit-reset-phrases.tsv) is entirely "resets …" / "reset
# at …" grammar (0 rows contain "try again at"), so every one of those 175
# real phrases, prefixed with codex's own confirmed sentence, failed to
# yield a reset and limit_codex_output_dry's second gate (below) then
# discarded the whole event as not-dry. That silently closed reroute, the
# board's ONLY red dot for codex (dry_store is codex-only —
# limit_engine_detectable is false for it), and — worse — on the
# fresh-artifact path (burn.sh) let a genuine EXISTING dry marker be
# cleared, because "not dry" there means "safe to clear". Recognize the
# same three grammars claude's branch (limit_output_dry) already does:
# nothing here says codex's own vendor text is restricted to one of them.
limit_codex_reset() {
  grep -oaiE 'resets [^"]+|try again at [^."]+|reset at [^."]+' <<< "$1" | head -n 1 \
    | sed -E 's/[[:space:]]+$//' || true
}

# limit_codex_output_dry <captured-output> -> 0 (dry) if a codex exec's CAPTURED
# output shows a usage limit, echoing the reset phrase; 1 (fine) otherwise.
# For checking a dispatched headless job: `codex exec` exits 0 even when limited
# and writes no artifact (burn-confirmed 2026-06-03), so the exit code is useless —
# the output string is the signal. Pair with an artifact check at the call site
# (a dropped job = limit string seen AND/OR the expected artifact missing).
#
# P2-2 (2026-09-08 round-4 review): unlike claude's branch, this matched a bare
# "hit your (usage|session) limit" ANYWHERE in the reply, so prose merely
# talking about the limit while a task genuinely failed for an unrelated
# reason ("See docs/runbook.md for what to do once you hit your usage
# limit.") was misread as a real codex limit event — three tanks burned
# rerouting a task that was never dry. codex's own real sentence is "You've
# hit your usage limit. … try again at <date> <time>." (limit_line_is_real's
# codex comment, burn-confirmed) — anchor on the SAME direct-report prefix as
# claude's branch (tolerant of the same line-start noise and short adverb
# gap), AND require the reply to actually yield a reset phrase: a genuine
# codex event always carries "try again at …", prose about the limit rarely
# does, so the two checks close different escapes than either alone.
#
# P2-1 (2026-09-08 round-5 review): the "12 bytes of leading NON-ALPHABETIC
# noise" allowance (same class as claude's branch below) was wide enough to
# admit markdown quoting/list syntax — `>`, `#`, a leading digit + `.` — none
# of which are letters either. A real reply built around drafting a runbook
# ("The runbook I was drafting says: > You have reached your weekly
# limit.") let the blockquote marker stand in for transport noise. Narrowed
# to the noise a caller's OWN transport actually adds (whitespace and stray
# symbols), never markdown syntax a model's prose legitimately uses — see
# the claude branch below for the shared rationale.
limit_codex_output_dry() {
  local out="$1" reset
  grep -qaiE "^[^A-Za-z0-9>#\"'.-]{0,12}(ERROR:[[:space:]]*)?(you've|you’ve|you have)( [a-z]+){0,2} hit your (usage|session) limit" <<< "$out" || return 1
  reset="$(limit_codex_reset "$out")"
  [ -n "$reset" ] || return 1
  printf '%s' "$reset"
  return 0
}

# limit_output_dry <cli> <captured-output> -> 0 (dry) + echo the verbatim reset
# phrase if a headless run's CAPTURED output shows a usage limit; 1 otherwise.
# Per-engine (the wording differs); engines with no output signal return 1, so the
# caller treats a missing artifact as a task failure, not a dry tank. Drives
# `clikae burn`'s fall-through — exit code is NOT trusted (codex exec exits 0 dry).
#
# Built-in fragility (honest): the per-engine matchers below lean on each vendor's
# CURRENT wording. If a vendor rewords its limit line, a dry tank would be misread
# as a real task failure. $CLIKAE_LIMIT_PATTERN is the escape hatch — the SAME env
# var `clikae watch` honours (--pattern) — so a user can teach burn/conduct a new
# phrase in the field without a code change. It is a deliberate override: it is
# tried FIRST and, when it matches, wins (and even gives a signal to an engine that
# has no built-in matcher). It never relays a reset phrase (clikae doesn't know the
# new format), only the dry/not-dry verdict.
limit_output_dry() {
  local cli="$1" out="$2"
  if [ -n "${CLIKAE_LIMIT_PATTERN:-}" ]; then
    grep -qaiE "$CLIKAE_LIMIT_PATTERN" <<< "$out" && return 0
    # No override match → fall through to the built-in per-engine matchers, so the
    # pattern only ADDS coverage, never masks a hit the built-in would have caught.
  fi
  case "$cli" in
    codex)  limit_codex_output_dry "$out" ;;
    claude)
      # P2-2 (2026-09-08 review): "weekly[ -]limit (reached|exceeded)" was
      # bare — every OTHER alternative here anchors on a verb naming the
      # human ("hit your …"), but this one fired on ordinary prose that
      # merely discusses a weekly limit ("the weekly limit reached its cap
      # in July"). Anchored to the START OF A LINE instead: a genuine vendor
      # sentence IS the line (or leads it), while prose ABOUT the limit is
      # never the first thing on its line. grep matches `^`/`$` per line, not
      # per buffer, so this holds even when $out has other lines around it.
      #
      # P2-1 (2026-09-08 round-2 review): the SAME fix's own next commit
      # (a3365a9) re-added a bare "reached your … limit" alongside it —
      # unlike "hit your …", "reached your …" turns out to read naturally in
      # third-person documentation prose that also addresses the reader as
      # "you" ("The runbook covers what happens when you have reached your
      # weekly limit…", "Each seat has reached your weekly limit of five
      # reviews", round-2 PROBE D — all three FALSE-DRY). A line anchor alone
      # doesn't defend this shape either: prose can land the phrase at a
      # fresh line by pure word-wrap coincidence. What every genuine vendor
      # sentence in the corpus actually shares, that none of the false
      # positives do, is the direct report "You've " / "You have " leading
      # straight into the verb — so both verbs now require that prefix
      # (adjacent, not just present in the buffer: a wrapped "you have\n"
      # followed by "reached" on the next line does NOT satisfy it, since `.`
      # never matches the newline between them).
      #
      # P1-1 (2026-09-08 round-3 review): that "adjacent" requirement was
      # stricter than it looked — it demanded "you've"/"you have" sit
      # IMMEDIATELY before the verb, with nothing between. A real vendor
      # sentence with a curly apostrophe ("You’ve hit …") or a one-word
      # adverb ("You have already hit …", "You've just hit …") no longer
      # matched at ALL — narrower than main, which never required this
      # prefix in the first place. That is the worse failure: a genuinely
      # dry tank now reads as a hard task failure (no reroute, no dry
      # marker, no reset), exactly what `burn --help` warns "a dry tank
      # would be misread as a real task failure" means. Tolerate the ASCII
      # and curly apostrophe, and up to two words between the direct report
      # and its verb.
      #
      # P2-3 (2026-09-08 round-3 review): the prefix requirement above was
      # never anchored to the start of a line, so it still matched its OWN
      # documented counterexample — CHANGELOG.md's "the runbook covers what
      # happens when you have reached your weekly limit…" — sitting mid-
      # sentence after "I could not write the file. " walked the entire
      # reserve on a real task failure (round-3 PROBE O). "You've "/"You
      # have " leading straight into the verb is only a genuine vendor
      # report when it also LEADS its line — third-person prose that quotes
      # the reader's own words ("…when you have reached…") never does,
      # while a real vendor sentence is the line (or leads it), same
      # reasoning as the `^weekly[ -]limit` alternative just below.
      #
      # P1-1 (2026-09-08 round-4 review): "leads its line" was read as
      # "IS the first byte of the line" — a genuine vendor sentence can
      # still be prefixed by non-alphabetic transport noise a caller didn't
      # write (indentation, a tab, a leading "⚠ "), and the bare `^` anchor
      # made those invisible too, narrower than main yet again for the same
      # reason r3 already called out once. Tolerate up to 12 bytes of
      # LEADING NON-ALPHABETIC noise before the direct report — prose never
      # qualifies (it leads with more than 12 alphabetic bytes, e.g. "I could
      # not write the file. "), so the r2/r3 false-positive corpus stays
      # closed. A prefix carrying its own letters ("Error: ", "codex: ") is
      # not recovered by this — that needs a real vendor-output corpus to
      # bound safely, not another regex guess (see REPORT-clikae47-fix4.md).
      #
      # P2-1 (2026-09-08 round-5 review): "non-alphabetic" turned out to
      # include markdown syntax a model's own prose legitimately produces —
      # a blockquote marker (`>`) or a numbered-list digit + `.` — which is
      # exactly what "prose never qualifies" assumed couldn't happen. A real
      # task failure whose reply was drafting a runbook ("The runbook I was
      # drafting says: > You have reached your weekly limit.", or "1. You
      # have reached your weekly limit — explain this to the user.") walked
      # the entire reserve on both round-5 PROBEs. `main` never matched
      # either shape at all ("reached your weekly limit" isn't one of its
      # alternatives), so this was a regression this PR introduced, not a
      # pre-existing gap. The noise class is now the transport whitespace
      # and stray symbols a caller's OWN wrapper might prepend — never `>`,
      # `#`, a quote character, a digit, `.`, or `-`, all of which are
      # markdown or list syntax a model writes on purpose. The two-space/
      # tab/`⚠ ` cases the round-4 fix closed stay closed; the r2/r3 bare-
      # prose corpus stays closed too (none of those start with a letter).
      grep -qaiE "^[^A-Za-z0-9>#\"'.-]{0,12}(you've|you’ve|you have)( [a-z]+){0,2} (hit|reached) your (session|usage|weekly)[ -]limit|^weekly[ -]limit (reached|exceeded)" <<< "$out" || return 1
      # P2-3 (2026-09-08 review): "resets "/"try again at " missed a real
      # shape from the review's corpus — "Your limit will reset at 5am …"
      # (singular "reset at", no trailing s) — which silently produced
      # reset:null even though the vendor's own words were right there.
      grep -oaiE "resets [^\"]+|try again at [^.\"]+|reset at [^.\"]+" <<< "$out" | head -n 1 || true
      return 0 ;;
    *) return 1 ;;
  esac
}

# limit_profile_dry <cli> <config_dir>
# Is this profile/tank currently rate-limited? Returns 0 (dry) / 1 (fine).
# When dry, prints the vendor's own reset phrase (e.g. "resets 11pm (Asia/Tokyo)")
# to stdout for display — verbatim, never parsed into a countdown (no timezone
# math to get wrong; the string the vendor wrote is the honest thing to show).
#
# Heuristic (timezone-free, self-clearing): a profile is dry iff its most recent
# GENUINE limit marker is newer than its most recent SUCCESSFUL assistant turn —
# i.e. the last thing that happened on this account is "you got limited", with no
# successful turn since. This is also the account-level fix: a Claude limit hits
# the whole account but the marker only lands in whichever session was mid-turn,
# so we scan ALL of the profile's recent sessions, not one directory. Once the
# limit resets and any session completes a real turn, the newer success timestamp
# clears the badge automatically.
#
# Only claude transcripts are scanned here. Confirmed reasons the others aren't:
#   · codex — a real limit is an exec-stdout-only event, NEVER written to the
#     rollout transcript (burn-verified 2026-06-01; see limit_line_is_real). There
#     is nothing in a transcript to scan, so codex is correctly absent.
#   · agy   — records its limit in a log file, not a transcript. That path is
#     handled separately by limit_log_dry (below), used for log-only targets.
# Any other cli returns "not dry" rather than guess.
# _limit_codex_dry <dir> -> 0 (dry) + echo the vendor's verbatim reset phrase, 1 otherwise.
#
# For a long time this project recorded that codex's usage limit was
# "exec-stdout-only — never written to a file clikae can scan", so a codex tank
# could only ever show ○ ("can't tell") and `clikae auto` stayed claude-only.
# That turned out to be false: the INTERACTIVE TUI writes the limit into its own
# rollout transcript, as a structured field, and has for a while —
#
#   {"type":"event_msg","payload":{"type":"task_complete","error":{
#      "message":"You've hit your usage limit. … try again at Aug 23rd, 2026 8:26 PM.",
#      "codex_error_info":"usage_limit_exceeded"}}}
#
# (confirmed against a real rollout whose session_meta says originator=codex-tui,
# i.e. not a headless run). We match `codex_error_info`, the machine-readable
# marker — NOT the English sentence, which is the vendor's copy and will drift.
#
# Self-clearing like claude's: an agent_message NEWER than the newest limit means
# the account recovered. Codex limits can run for weeks (the reset above is a
# month out), so the scan window is far wider than claude's 5h rolling one — but
# still bounded, because a tank nobody has touched in a week showing ○ is the
# honest answer, not a lie.
_limit_codex_dry() {
  local dir="$1"
  local sess_root="$dir/sessions"
  [ -d "$sess_root" ] || return 1

  local files
  files="$(find "$sess_root" -name 'rollout-*.jsonl' -mmin -10080 2>/dev/null)"
  [ -n "$files" ] || return 1

  local out maxL maxS reset
  out="$(printf '%s\n' "$files" | while IFS= read -r f; do
      [ -n "$f" ] && transcript_tail "$f"
    done | awk '
      function ts(s,   t) {
        if (match(s, /"timestamp": *"[^"]*"/)) {
          t = substr(s, RSTART, RLENGTH); sub(/.*"timestamp": *"/, "", t); sub(/".*/, "", t)
          return t
        }
        return ""
      }
      /"codex_error_info": *"usage_limit_exceeded"/ {
        t = ts($0)
        if (t != "" && (maxL == "" || t > maxL)) {
          maxL = t; reset = ""
          if (match($0, /try again at [^".]*/)) reset = substr($0, RSTART, RLENGTH)
        }
        next
      }
      /"type": *"agent_message"/ {
        t = ts($0); if (t != "" && (maxS == "" || t > maxS)) maxS = t
      }
      END { printf "%s\037%s\037%s\n", maxL, maxS, reset }
    ')"
  IFS=$'\037' read -r maxL maxS reset <<EOF
$out
EOF
  [ -n "$maxL" ] || return 1

  if [ -n "$maxS" ]; then
    local newer
    newer="$(printf '%s\n%s\n' "$maxL" "$maxS" | sort | tail -n 1)"
    # rc=2, not 1: this is POSITIVE evidence of recovery (a real turn after the
    # limit), not merely "nothing found here". _limit_tank_dry_raw tells the two
    # apart (R1-P1-2) — rc=1 still falls to dry_store for codex (a headless run
    # may have hit a limit this transcript never saw). rc=2 echoes maxS (the
    # recovery's own timestamp) when asked, so the caller can weigh it against
    # a persisted marker's OWN timestamp (R2-P1-3): this transcript recovering
    # days ago must not outrank a headless marker burn wrote moments ago — only
    # a recovery NEWER than the marker is grounds to clear it.
    if [ "$newer" = "$maxS" ] && [ "$maxS" != "$maxL" ]; then
      [ "${_LIMIT_WITH_STAMP:-0}" = 1 ] && printf '%s' "$maxS"
      return 2
    fi
  fi

  printf '%s' "$reset"
  [ "${_LIMIT_WITH_STAMP:-0}" = 1 ] && printf '\037%s' "$maxL"
  return 0
}

limit_profile_dry() {
  local cli="$1" dir="$2"
  # codex keeps its own shape of transcript in its own place; claude's scan below
  # would find nothing there. See _limit_codex_dry for why this is possible at all.
  [ "$cli" = "codex" ] && { _limit_codex_dry "$dir"; return $?; }
  [ "$cli" = "claude" ] || return 1
  local proj_root="$dir/projects"
  [ -d "$proj_root" ] || return 1

  # Only sessions touched in the last ~5h (the rolling session window): a limit
  # older than that has reset, and scanning stale transcripts just costs time.
  local files
  files="$(find "$proj_root" -name '*.jsonl' -mmin -300 2>/dev/null)"
  [ -n "$files" ] || return 1

  # Find, in ONE awk pass over the bounded tails, three things at once:
  #   maxL  — newest GENUINE-limit timestamp (synthetic + isApiErrorMessage)
  #   maxS  — newest SUCCESSFUL-turn timestamp (type:assistant, NOT synthetic)
  #   reset — the vendor's verbatim "resets …" phrase from the NEWEST limit line
  # Folding all three into one awk (vs the old per-file grep|grep|grep|sed ×2 +
  # a separate reset scan) cuts the home board's per-tank fork count ~10× — the
  # last remaining hot spot after the tail-bounding (dogfood 2026-06-29). ISO-8601
  # stamps compare lexicographically, so awk tracks the max by string compare; the
  # structural matches tolerate optional whitespace after each colon (`: *`) so a
  # pretty-printed JSONL can't silently break detection. Reads only the TAIL of
  # each (100+ MB) transcript — the newest limit/success are the most-recent lines.
  local out maxL maxS reset
  out="$(printf '%s\n' "$files" | while IFS= read -r f; do
      [ -n "$f" ] && transcript_tail "$f"
    done | awk '
      function ts(s,   t) {
        if (match(s, /"timestamp": *"[^"]*"/)) {
          t = substr(s, RSTART, RLENGTH); sub(/.*"timestamp": *"/, "", t); sub(/".*/, "", t)
          return t
        }
        return ""
      }
      /"model": *"<synthetic>"/ && /"isApiErrorMessage": *true/ {
        t = ts($0)
        if (t != "" && (maxL == "" || t > maxL)) {
          maxL = t; reset = ""
          if (match($0, /[Rr]esets [^"]*/)) reset = substr($0, RSTART, RLENGTH)
        }
        next
      }
      /"type": *"assistant"/ && $0 !~ /"model": *"<synthetic>"/ {
        t = ts($0); if (t != "" && (maxS == "" || t > maxS)) maxS = t
      }
      END { printf "%s\037%s\037%s\n", maxL, maxS, reset }
    ')"
  # \037 (Unit Separator), NOT a tab: tab is IFS-whitespace, so `read` would
  # COLLAPSE the empty maxS field between two tabs and shift reset into maxS
  # (the exact footgun status.sh's delimiter comment warns about).
  IFS=$'\037' read -r maxL maxS reset <<EOF
$out
EOF
  [ -n "$maxL" ] || return 1

  # Dry only if nothing succeeded AFTER the newest limit (self-clearing). ISO
  # stamps sort lexicographically, so a later success sorting last cleared it.
  if [ -n "$maxS" ]; then
    local newer
    newer="$(printf '%s\n%s\n' "$maxL" "$maxS" | sort | tail -n 1)"
    [ "$newer" = "$maxS" ] && [ "$maxS" != "$maxL" ] && return 1
  fi

  # Dry: echo the vendor's own reset phrase (captured above from the newest limit
  # line), verbatim — never parsed into a countdown.
  printf '%s' "$reset"
  [ "${_LIMIT_WITH_STAMP:-0}" = 1 ] && printf '\037%s' "$maxL"
  return 0
}

# _limit_iso_epoch <stamp> <fallback> -> epoch seconds for a transcript's
# ISO-8601 timestamp (e.g. "2026-08-23T20:26:00.000Z") or a bare epoch already;
# <fallback> is returned for anything else (an unparseable stamp, or a shape
# neither GNU nor BSD `date` understands). Shared by the store-observation
# anchor (_limit_tank_dry_self) and the transcript-recovery-vs-marker compare
# (R2-P1-3) so both read a codex/claude transcript timestamp the same way.
_limit_iso_epoch() {
  local stamp="$1" fallback="$2"
  case "$stamp" in
    *T*)
      stamp="${stamp%%.*}"; stamp="${stamp%Z}"
      date -u -d "${stamp}Z" +%s 2>/dev/null ||
        date -u -j -f '%Y-%m-%dT%H:%M:%S' "$stamp" +%s 2>/dev/null ||
        printf '%s' "$fallback" ;;
    ''|*[!0-9]*) printf '%s' "$fallback" ;;
    *) printf '%s' "$stamp" ;;
  esac
}

# _limit_tank_dry_raw <engine> <tank> -> 0 + phrase and optional observation stamp
# if THIS tank's own signal says it's out of fuel; 1 otherwise. Two sources:
#   · claude  — limit_profile_dry scans the tank's transcripts (account-level
#     WITHIN this config dir: all its recent sessions).
#   · any engine — a persisted dry marker (dry_store), written by the live catcher
#     (burn / supervise) for engines whose limit never lands in a scannable file.
# Self-only: factored out so limit_tank_dry's account contagion can't recurse.
_limit_tank_dry_raw() {
  local engine="$1" tank="$2" dir reset pd_rc
  dir="$(profile_dir "$engine" "$tank")"
  # A transcript signal is always preferred: it self-clears the moment the account
  # succeeds again, so it can never claim a tank is dry after it has recovered.
  # claude and codex both persist their limit (codex's was long believed
  # exec-stdout-only — see _limit_codex_dry for the evidence that it isn't).
  if [ "$engine" = "claude" ] || [ "$engine" = "codex" ]; then
    reset="$(limit_profile_dry "$engine" "$dir" 2>/dev/null)"; pd_rc=$?
    if [ "$pd_rc" -eq 0 ]; then
      printf '%s' "$reset"; return 0
    fi
    # claude stops here on purpose: NEVER consult dry_store for it, or a stale 6h
    # marker masks a real recovery. codex falls through — a headless `codex exec`
    # can hit the limit in a shape the rollout doesn't carry, and burn persists
    # that; the store has its own TTL.
    [ "$engine" = "claude" ] && return 1
    # rc=2 is POSITIVE evidence the account recovered (a real turn after the
    # limit), not just "this scanner found nothing". R1-P1-2: falling through
    # to the store here let a real recovery sit next to an unrelated stale
    # marker (e.g. from an earlier headless run) and the marker would never
    # clear — the interactive transcript's own success IS the successful turn
    # dry_store_clear exists for, so use it instead of only relying on burn's
    # exec-stdout path or the TTL below.
    #
    # R2-P1-3: but only when that recovery is NEWER than the marker's own
    # timestamp. A headless `codex exec` limit never reaches the transcript
    # (see burn.sh's dry_store_mark call) — "transcript shows a recovery" and
    # "the marker says dry again" are independent facts, and a recovery from
    # days ago must not erase a marker burn wrote moments ago. Unconditionally
    # trusting rc=2 let exactly that happen: the marker's own TTL / the 7-day
    # CLIKAE_DRY_MAX_RETAIN cap is what should govern instead, so fall through
    # to the store branch below rather than clearing.
    if [ "$pd_rc" -eq 2 ]; then
      local _mk _recovery_epoch
      _mk="$(dry_store_epoch "$engine" "$tank" 2>/dev/null || echo 0)"
      if [ -z "$_mk" ] || [ "$_mk" = 0 ]; then
        dry_store_clear "$engine" "$tank"
        return 1
      fi
      _recovery_epoch="$(_limit_iso_epoch "$reset" 0)"
      if [ "$_recovery_epoch" -gt "$_mk" ]; then
        dry_store_clear "$engine" "$tank"
        return 1
      fi
      # else: the marker outdates the observed recovery — fall through, its
      # own TTL / CLIKAE_DRY_MAX_RETAIN cap governs like any other marker.
    fi
  fi
  if reset="$(dry_store_read "$engine" "$tank" --retain-stale 2>/dev/null)"; then
    printf '%s\037%s' "$reset" "$(dry_store_epoch "$engine" "$tank")"; return 0
  fi
  return 1
}

# Classify retained evidence once, for both the batch board and burn selector.
# Keep the observation timestamp: undated phrases mean the next reset AFTER
# that observation, not after each redraw (which would roll them forward forever).
# A successful transcript turn still removes the evidence in the raw scanner.
LIMIT_RESET_UNVERIFIED='reset passed · unverified'
_limit_tank_dry_self() {
  local raw reset stamp now at anchor
  local _LIMIT_WITH_STAMP=1
  raw="$(_limit_tank_dry_raw "$1" "$2")" || return 1
  reset="${raw%%$'\037'*}"; stamp="${raw#*$'\037'}"
  now="$(date +%s)"; anchor="$now"
  [ "$stamp" != "$raw" ] && anchor="$(_limit_iso_epoch "$stamp" "$now")"
  if at="$(limit_reset_epoch "$reset" "$anchor")" && [ "$at" -lt "$now" ]; then
    printf '%s' "$LIMIT_RESET_UNVERIFIED"
  else
    # Preserve the store's existing TTL for evidence whose reset did not expire.
    case "$stamp" in
      ''|*[!0-9]*) ;;
      *) dry_store_read "$1" "$2" >/dev/null || return 1 ;;
    esac
    printf '%s' "$reset"
  fi
}

# _limit_tank_account <engine> <tank> -> this tank's account label (e.g. the
# logged-in email) via the adapter, or empty. Run in a subshell so loading the
# adapter here can't clobber whichever adapter the caller already has loaded.
_limit_tank_account() {
  local engine="$1" tank="$2" dir
  dir="$(profile_dir "$engine" "$tank")"
  ( load_adapter "$engine" >/dev/null 2>&1 || exit 0
    declare -F adapter_account_label >/dev/null 2>&1 || exit 0
    adapter_account_label "$dir" 2>/dev/null )
}

# limit_tank_dry <engine> <tank> -> 0 (dry) + echo the verbatim reset phrase if
# this tank has NO usable fuel right now; 1 (fine) otherwise. The account- and
# store-aware unifier that BOTH the board (clikae home) and the carry-onward
# selector (next_tank) call, so a dry reading means the same thing everywhere:
#   1. the tank's OWN signal (_limit_tank_dry_self), then
#   2. ACCOUNT CONTAGION — a usage limit hits the whole account, not one tank, so a
#      sibling on the SAME account (same adapter_account_label) being dry makes THIS
#      tank dry too, even with no marker of its own. This is why claude/MFC reads
#      dry the moment claude/L does: same login, one shared quota. The sibling's
#      reset phrase is borrowed for display. Skipped when the account is unknown
#      (empty label) — we never guess a shared quota we can't see.
limit_tank_dry() {
  local engine="$1" tank="$2" reset acct sib_e sib_t _p sib_acct
  if reset="$(_limit_tank_dry_self "$engine" "$tank")" && [ "$reset" != "$LIMIT_RESET_UNVERIFIED" ]; then
    printf '%s' "$reset"; return 0
  fi
  acct="$(_limit_tank_account "$engine" "$tank")"
  [ -n "$acct" ] || return 1
  while IFS=$'\t' read -r sib_e sib_t _p; do
    [ -n "$sib_e" ] || continue
    [ "$sib_e" = "$engine" ] || continue
    [ "$sib_t" = "$tank" ] && continue
    sib_acct="$(_limit_tank_account "$sib_e" "$sib_t")"
    [ -n "$sib_acct" ] && [ "$sib_acct" = "$acct" ] || continue
    if reset="$(_limit_tank_dry_self "$sib_e" "$sib_t")" && [ "$reset" != "$LIMIT_RESET_UNVERIFIED" ]; then
      printf '%s' "$reset"; return 0
    fi
  done <<EOF
$(list_all_profiles)
EOF
  return 1
}

# limit_dry_set — the BATCH form of limit_tank_dry for the whole board. Reads a
# profile list (engine<TAB>tank<TAB>path per line) on stdin and emits one row
#   engine␟tank␟reset
# per tank that is out of fuel (--include-unverified also emits reset cautions).
# Same verdict as calling limit_tank_dry on each
# tank, but it computes each tank's OWN signal (_limit_tank_dry_self) EXACTLY ONCE
# and then resolves account contagion from that cache — so a board with several
# same-account tanks (e.g. claude C+MFC) doesn't re-scan the same transcripts N
# times (the board's last hot spot; dogfood 2026-06-29). Indexed arrays only (no
# associative arrays — bash 3.2).
limit_dry_set() {
  local include_unverified="${1:-}"
  local -a _e=() _t=() _a=() _sd=() _sr=()   # engine, tank, account, self-dry(0/1), self-reset
  local cli profile path sreset
  # Pass 1 — each tank's OWN signal + account, computed ONCE.
  while IFS=$'\t' read -r cli profile path; do
    [ -n "$cli" ] || continue
    : "$path"
    if sreset="$(_limit_tank_dry_self "$cli" "$profile")"; then
      _sd+=(1); _sr+=("$sreset")
    else
      _sd+=(0); _sr+=("")
    fi
    _e+=("$cli"); _t+=("$profile")
    _a+=("$(_limit_tank_account "$cli" "$profile")")
  done

  # Pass 2 — dry if self-dry, else a same-account same-engine sibling is self-dry
  # (contagion). A sibling hit counts even when its reset phrase is empty.
  local i j n="${#_e[@]}" hit reset
  for ((i = 0; i < n; i++)); do
    if [ "${_sd[i]}" = "1" ] && [ "${_sr[i]}" != "$LIMIT_RESET_UNVERIFIED" ]; then
      printf '%s\037%s\037%s\n' "${_e[i]}" "${_t[i]}" "${_sr[i]}"
      continue
    fi
    hit="${_sd[i]}"; reset="${_sr[i]}"
    if [ -n "${_a[i]}" ]; then   # unknown account -> never guess a shared quota
      for ((j = 0; j < n; j++)); do
        [ "$j" -ne "$i" ] || continue
        [ "${_sd[j]}" = "1" ] || continue
        [ "${_e[j]}" = "${_e[i]}" ] || continue
        [ "${_a[j]}" = "${_a[i]}" ] || continue
        hit=1; reset="${_sr[j]}"
        [ "$reset" = "$LIMIT_RESET_UNVERIFIED" ] || break
      done
    fi
    if [ "$reset" = "$LIMIT_RESET_UNVERIFIED" ] && [ "$include_unverified" != --include-unverified ]; then continue; fi
    [ "$hit" = "1" ] && printf '%s\037%s\037%s\n' "${_e[i]}" "${_t[i]}" "$reset"
  done
  return 0
}

# limit_log_dry <logfile>
# Is a log-only target's CURRENT limit log showing a genuine quota event?
# Returns 0 (dry) and echoes the vendor's verbatim reset phrase, or 1 (fine).
#
# For single-account vendors (antigravity/agy) whose limit lands ONLY in a log,
# never a transcript: `agy -p` hitting its Gemini quota exits 0 with empty output
# — the sole signal is an E-level line in cli.log. CONFIRMED against a real limit
# (dogfooded 2026-05-31, re-verified from the rotated logs 2026-06-01):
#   RESOURCE_EXHAUSTED (code 429): Individual quota reached. … Resets in 3h32m48s.
# The path passed in is agy's cli.log SYMLINK, which agy repoints to a fresh
# per-run file each invocation — so its content IS the latest run's state. A
# marker present = the most recent run hit the limit; it self-clears when the next
# run rotates in a clean log (no timezone math, same spirit as limit_profile_dry).
# RESOURCE_EXHAUSTED alone is NOT a quota verdict. Three variants were pulled out
# of real logs on 2026-08-11, and only two of them mean the tank is spent:
#   E … stream_handler: RESOURCE_EXHAUSTED (429): Individual quota reached. …
#   E … stream_handler: RESOURCE_EXHAUSTED (429): You have exhausted your capacity
#                                                 on this model. …
#   W … Cache(userInfo): Singleflight refresh failed: RESOURCE_EXHAUSTED (429):
#       Resource has been exhausted (e.g. check quota).      <- a cache refresh
# The third is a warning from an unrelated background fetch; matching the bare
# token turned it into "this tank ran dry" and sent burn off to reroute. Match the
# vendor's quota sentences instead of the error class.
LIMIT_AGY_DRY_RE='Individual quota reached|exhausted your capacity on this model'

limit_log_dry() {
  local logf="$1"
  [ -n "$logf" ] && [ -e "$logf" ] || return 1
  grep -qaE "$LIMIT_AGY_DRY_RE" "$logf" 2>/dev/null || return 1
  # Echo the vendor's own reset phrase verbatim (never a computed countdown); the
  # LAST occurrence is this run's most recent limit line. Guard the no-match so it
  # never aborts the caller under `set -eo pipefail`.
  grep -aoE 'Resets in [0-9hdms]+' "$logf" 2>/dev/null | tail -n 1 || true
  return 0
}

# limit_engine_detectable <cli> -> 0 if clikae can read this engine's fuel state
# from disk at all, 1 if not. This is what splits a real traffic-light reading
# (red/yellow/green) from an honest ○ "no reading". claude (transcript markers)
# and antigravity (cli.log) are detectable; codex is PROVEN un-detectable from any
# transcript (see limit_profile_dry's notes), so it — and any engine without a
# detector — stays ○ rather than being shown a guessed green.
limit_engine_detectable() {
  case "$1" in
    claude|antigravity) return 0 ;;
    *) return 1 ;;
  esac
}

# limit_weekly_marker <line>  (BETA) -> echo the vendor's own weekly-usage phrase
# if this streamed line carries one (e.g. "used 85% of your weekly limit"), else
# nothing. Same spirit as the dry detectors: we RELAY the engine's verbatim words,
# we never COMPUTE a percentage (disk has token tallies but no weekly denominator
# or window boundary — computing it would be a guess). The caller (watch/auto)
# caches whatever this returns, stamped, to drive the board's yellow dot.
#
# ⚠️ BETA: the pattern below is a BEST GUESS — it is NOT yet confirmed that Claude
# serialises this notice into the transcript / `-p` stream at all (it may be
# TUI-render-only). Confirm against a real sighting before trusting yellow; refine
# the regex there. Until then yellow simply never lights, which is the safe default.
limit_weekly_marker() {
  printf '%s\n' "$1" \
    | grep -oiE "[0-9]+% of your (weekly|week)[a-z ]*limit" 2>/dev/null \
    | head -n 1 || true
}

# ---------------------------------------------------------------------------
# Turning the vendor's reset phrase into an instant.
#
# Everywhere above, a reset phrase is RELAYED verbatim and never parsed — the
# honest thing to show a human. This section is for the one caller that needs a
# number instead of a sentence: waking a limited tank up when the limit lifts.
# It stays separate, and it stays a pure function, so the display path cannot
# start depending on a computation that might be wrong.
#
# Two grammars, and that is all there is — measured against 262 genuine limit
# events across five accounts on 2026-08-12, of which 262 carried a phrase:
#     resets 3:50am (Asia/Tokyo)          undated: the NEXT such time
#     resets Jul 27 at 5am (Asia/Tokyo)   dated, with no year
# 🔴 The grammar does NOT follow the limit type: a weekly limit was seen in both
# forms, so branching on "session vs weekly" would be wrong.
#
# `now` is a PARAMETER, never read from the clock in here. The thing this feeds
# fires once every several hours, so a version that consults the real clock is a
# version nobody can test — and an untested waiter is worse than none.

# _limit_date_kind -> gnu | bsd  (cached; `date -d` is GNU-only)
_LIMIT_DATE_KIND=""
_limit_date_kind() {
  if [ -z "$_LIMIT_DATE_KIND" ]; then
    if date -d @0 +%s >/dev/null 2>&1; then _LIMIT_DATE_KIND=gnu; else _LIMIT_DATE_KIND=bsd; fi
  fi
  printf '%s' "$_LIMIT_DATE_KIND"
}

# _limit_local <tz> <epoch> <fmt> -> that instant rendered in that zone
_limit_local() {
  if [ "$(_limit_date_kind)" = gnu ]; then TZ="$1" date -d "@$2" "+$3" 2>/dev/null
  else TZ="$1" date -r "$2" "+$3" 2>/dev/null; fi
}

# _limit_at <tz> <YYYY-MM-DD> <HH:MM> -> epoch, or nothing if that date is not real.
#
# The platforms disagree here and only one of them says so: GNU `date -d` rejects
# 2027-02-29, while BSD `date -j -f` SILENTLY normalises it to 2027-03-01 and
# exits 0 (probed 2026-08-12). Year inference below tries candidate years, so on
# macOS a bad candidate would quietly become a real — and wrong — answer. We read
# the date back out and require it to be the date we asked for; that check costs
# one fork and makes both platforms behave the same way.
#
# Seconds are spelled out for the same family of reason: BSD `date -j -f` fills
# any field the format does not mention from the CURRENT time, so a '%H:%M'
# format yields a different epoch every second it is called. Pinning ':00' makes
# the function deterministic — which is the whole point of taking `now` as an
# argument in the first place.
_limit_at() {
  local tz="$1" d="$2" hm="$3" ep hh
  if ep="$(_limit_at_exact "$tz" "$d" "$hm")"; then printf '%s' "$ep"; return 0; fi
  # The wall-clock time does not exist on that date in that zone — the hour a
  # spring-forward deletes. There is no right answer, only a consistent one, and
  # the platforms disagree about it on their own: BSD hands back the same instant
  # an hour later, GNU refuses. Both are made to agree by asking for that hour
  # explicitly. (An hour is the size of every DST jump in the tz database.)
  hh="${hm%%:*}"
  [ "$((10#$hh))" -lt 23 ] || return 1
  hm="$(printf '%02d:%s' "$(( 10#$hh + 1 ))" "${hm##*:}")"
  _limit_at_exact "$tz" "$d" "$hm"
}

# _limit_at_exact — resolve, then require the calendar to read back EXACTLY what
# was asked for. Both halves of that read-back earn their keep:
#   the date  — BSD turns 2027-02-29 into 2027-03-01 and exits 0 where GNU
#               refuses, so year inference could pick an impossible date and
#               look confident about it.
#   the time  — a wall-clock time inside a DST gap comes back as a DIFFERENT
#               time, which is the only portable way to notice it happened.
#
# ⚠️ The TIME half cannot be verified on macOS: BSD's own answer for a gap time is
# already the instant the fall-forward would produce, so deleting this check
# leaves the suite green here and only goes red on Linux. CI is the ruler for
# that one — do not read a local green as coverage of it.
_limit_at_exact() {
  local tz="$1" d="$2" hm="$3" ep back
  if [ "$(_limit_date_kind)" = gnu ]; then ep="$(TZ="$tz" date -d "$d $hm:00" +%s 2>/dev/null)"
  else ep="$(TZ="$tz" date -j -f '%Y-%m-%d %H:%M:%S' "$d $hm:00" +%s 2>/dev/null)"; fi
  [ -n "$ep" ] || return 1
  back="$(_limit_local "$tz" "$ep" '%Y-%m-%d %H:%M')"
  [ "$back" = "$d $hm" ] || return 1
  printf '%s' "$ep"
}

# _limit_shift_day <tz> <YYYY-MM-DD> <+n> -> YYYY-MM-DD
_limit_shift_day() {
  if [ "$(_limit_date_kind)" = gnu ]; then TZ="$1" date -d "$2 + $3 day" '+%Y-%m-%d' 2>/dev/null
  else TZ="$1" date -j -v"+${3}d" -f '%Y-%m-%d' "$2" '+%Y-%m-%d' 2>/dev/null; fi
}

# _limit_month_num <Jan..Dec> -> 01..12 (empty if not a month)
_limit_month_num() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    jan) printf '01' ;; feb) printf '02' ;; mar) printf '03' ;; apr) printf '04' ;;
    may) printf '05' ;; jun) printf '06' ;; jul) printf '07' ;; aug) printf '08' ;;
    sep) printf '09' ;; oct) printf '10' ;; nov) printf '11' ;; dec) printf '12' ;;
  esac
}

# limit_reset_epoch <phrase> <now_epoch> -> 0 + echo the epoch of the reset, or
# 1 and NOTHING when the phrase carries no reset this function understands.
#
# Failing loudly matters: a caller that gets a silent 0 would schedule a wake-up
# for 1970 and fire immediately. There is no fallback guess here on purpose — an
# unparsed phrase means "don't schedule anything", which is the safe answer.
limit_reset_epoch() {
  local phrase="$1" now="$2"
  [ -n "$phrase" ] && [ -n "$now" ] || return 1

  # The zone is written in the phrase and is authoritative. Reading $TZ instead
  # would agree with it on the maintainer's machine and disagree on a traveller's.
  # Extracted once up top because BOTH grammars below (codex's and claude's)
  # need it: a zone suffix, when present, wins over any fallback.
  local tz
  tz="$(printf '%s' "$phrase" | sed -nE 's/.*\(([A-Za-z_]+\/[A-Za-z_+-]+|UTC|GMT)\).*/\1/p')"

  # Codex's two known reset shapes (undated "H:MM AM/PM" and dated "Mon Dst,
  # YYYY H:MM AM/PM"; see limit_codex_reset). Neither is confirmed to ever carry
  # a zone suffix — codex has so far only been observed rendering in the
  # machine's OWN local timezone — but if the phrase names one anyway, R1-P1-1
  # says that MUST win for the same reason it wins below: agreeing with the
  # phrase on the maintainer's machine and disagreeing on a traveller's is
  # exactly the bug a zone suffix exists to prevent. Only fall back to the
  # observer's ambient zone when the phrase names none.
  local codex_zone="${tz:-${TZ:-/etc/localtime}}"
  local codex_dated_re='[Tt]ry again at ([A-Z][a-z][a-z]) ([0-9]{1,2})(st|nd|rd|th)?,? ([0-9]{4})[,]? ([0-9]{1,2}):([0-9]{2})[[:space:]]*([APap][Mm])'
  local codex_plain_re='[Tt]ry again at ([0-9]{1,2}):([0-9]{2})[[:space:]]*([APap][Mm])'
  if [[ "$phrase" =~ $codex_dated_re ]]; then
    local cmon="${BASH_REMATCH[1]}" cday="${BASH_REMATCH[2]}" cyr="${BASH_REMATCH[4]}" \
          ch="${BASH_REMATCH[5]}" cm="${BASH_REMATCH[6]}" meridian="${BASH_REMATCH[7]}"
    local mnum; mnum="$(_limit_month_num "$cmon")"
    [ -n "$mnum" ] && [ "$ch" -ge 1 ] && [ "$ch" -le 12 ] && [ "$((10#$cm))" -lt 60 ] || return 1
    ch=$((10#$ch % 12))
    case "$meridian" in PM|pm) ch=$((ch + 12)) ;; esac
    local d0 ct candidate
    d0="$(printf '%04d-%s-%02d' "$((10#$cyr))" "$mnum" "$((10#$cday))")"
    ct="$(printf '%02d:%02d' "$ch" "$((10#$cm))")"
    candidate="$(_limit_at "$codex_zone" "$d0" "$ct")" || return 1
    printf '%s' "$candidate"; return 0
  fi
  if [[ "$phrase" =~ $codex_plain_re ]]; then
    local ch="${BASH_REMATCH[1]}" cm="${BASH_REMATCH[2]}" meridian="${BASH_REMATCH[3]}" cd ct candidate
    [ "$ch" -ge 1 ] && [ "$ch" -le 12 ] && [ "$((10#$cm))" -lt 60 ] || return 1
    ch=$((10#$ch % 12))
    case "$meridian" in PM|pm) ch=$((ch + 12)) ;; esac
    ct="$(printf '%02d:%02d' "$ch" "$((10#$cm))")"
    cd="$(_limit_local "$codex_zone" "$now" '%Y-%m-%d')" || return 1
    candidate="$(_limit_at "$codex_zone" "$cd" "$ct")" || return 1
    if [ "$candidate" -le "$now" ]; then
      cd="$(_limit_shift_day "$codex_zone" "$cd" 1)" || return 1
      candidate="$(_limit_at "$codex_zone" "$cd" "$ct")" || return 1
    fi
    printf '%s' "$candidate"; return 0
  fi

  [ -n "$tz" ] || return 1

  local re_dated='[Rr]esets[[:space:]]+([A-Z][a-z][a-z])[[:space:]]+([0-9]{1,2})[[:space:]]+at[[:space:]]+([0-9]{1,2})(:([0-9]{2}))?(am|pm|AM|PM)'
  local re_plain='[Rr]esets[[:space:]]+([0-9]{1,2})(:([0-9]{2}))?(am|pm|AM|PM)'

  local mon="" day="" hr="" min="" mer=""
  if [[ "$phrase" =~ $re_dated ]]; then
    mon="${BASH_REMATCH[1]}"; day="${BASH_REMATCH[2]}"
    hr="${BASH_REMATCH[3]}";  min="${BASH_REMATCH[5]}"; mer="${BASH_REMATCH[6]}"
  elif [[ "$phrase" =~ $re_plain ]]; then
    hr="${BASH_REMATCH[1]}";  min="${BASH_REMATCH[3]}"; mer="${BASH_REMATCH[4]}"
  else
    return 1
  fi
  [ -n "$hr" ] || return 1
  [ -n "$min" ] || min="00"

  # 12-hour -> 24-hour. 12am is 00, 12pm is 12; the modulo does both.
  local h24=$(( 10#$hr % 12 ))
  case "$mer" in pm|PM) h24=$(( h24 + 12 )) ;; esac
  [ "$h24" -ge 0 ] && [ "$h24" -le 23 ] || return 1
  local hm; hm="$(printf '%02d:%02d' "$h24" "$((10#$min))")"

  local today cand
  today="$(_limit_local "$tz" "$now" '%Y-%m-%d')"
  [ -n "$today" ] || return 1

  if [ -n "$mon" ]; then
    # Dated, no year. Try this year, then next, then last, and take the first
    # candidate that is not already well in the past — the same rule a human
    # applies reading "Jul 27" on a December screen.
    local mnum yr y d0
    mnum="$(_limit_month_num "$mon")"; [ -n "$mnum" ] || return 1
    yr="$(_limit_local "$tz" "$now" '%Y')"
    for y in "$yr" "$((yr + 1))" "$((yr - 1))"; do
      d0="$(printf '%04d-%s-%02d' "$y" "$mnum" "$((10#$day))")"
      cand="$(_limit_at "$tz" "$d0" "$hm")" || continue
      [ "$cand" -ge "$((now - 86400))" ] && { printf '%s' "$cand"; return 0; }
    done
    return 1
  fi

  # Undated: the next occurrence of that wall-clock time. Adding 86400 would be
  # wrong across a DST boundary, so we ask the calendar for tomorrow's date and
  # resolve the wall-clock time on THAT day instead.
  cand="$(_limit_at "$tz" "$today" "$hm")" || return 1
  if [ "$cand" -le "$now" ]; then
    local tmr
    tmr="$(_limit_shift_day "$tz" "$today" 1)" || return 1
    [ -n "$tmr" ] || return 1
    cand="$(_limit_at "$tz" "$tmr" "$hm")" || return 1
  fi
  printf '%s' "$cand"
  return 0
}

# limit_reset_phrase <line> -> the vendor's "resets …" phrase carried by a
# transcript line, or nothing. The counterpart to limit_reset_epoch: that one
# turns a phrase into an instant, this one finds the phrase in the wild. Split
# so the parser can be tested on phrases without a transcript in sight.
limit_reset_phrase() {
  printf '%s' "$1" | grep -oaiE '[Rr]esets [^"\\]*' | head -n 1 \
    | sed -E 's/[[:space:]]+$//' || true
}

# ---------------------------------------------------------------------------
# codex's OWN proactive usage status — the 5h/weekly windows it renders
# itself (its `/status` panel shows e.g. "5h limit:  [████] 100% left
# (resets 05:14)" and "Weekly limit: [████] 95% left (resets 22:12 on 15
# Sep)"). Unlike everything above (which only ever fires once a tank has
# ALREADY run dry), this is a proactive reading: codex reports the SAME two
# numbers (% left, reset time) whether the tank is healthy or not, and
# clikae had no light for it at all — `clikae burn codex … --json` always
# printed `"reset": null` on a run that never hit a hard limit, even though
# codex knew perfectly well when the window resets.
#
# Source: codex's own `rate_limits` object, persisted into the rollout
# transcript (see docs/DESIGN-board-fuel-dots.md). Every codex session —
# headless `codex exec` included, confirmed on this machine's own rollouts
# (originator "codex_exec") — persists a `token_count` event whose
# `rate_limits.primary`/`.secondary` carry a `used_percent` and an ABSOLUTE
# `resets_at` epoch, both already resolved by the SERVER (no local-time
# guessing at all — clikae only relays them). `limit_codex_status` /
# `limit_codex_status_cached` are the two entry points; see the header above
# each for which callers want which.
#
# (Round-1 review, 2026-09-12: an earlier revision of this file also shipped
# a text-shape parser for the RENDERED status line, for a captured line where
# the structured source doesn't reach. It had no real caller anywhere in
# lib/bin/scripts — only its own tests exercised it — so it was deleted
# rather than kept as permanently-untested dead code. If a real caller shows
# up (a burn-log scraper, a `$CLIKAE_LIMIT_PATTERN`-style paste path), it can
# be rebuilt against this same contract.)
#
# 🔴 Do NOT assume primary=5h / secondary=weekly BY POSITION. A real
# free-tier sample on this machine (2026-09-10) showed `limit_id:"codex"`
# with a `window_minutes:43200` (30 days) rider living in `primary` and
# `secondary` always null — nothing like the 5h/weekly split the ticket's
# `/status` example came from (a different plan tier). Position is not the
# contract; `window_minutes` is — each side is labelled by ITS OWN window
# length (_limit_codex_window_label), never by which JSON key it arrived in.
#
# 🔴 TIME VALIDITY (P1-1, 2026-09-12 round-1 review). `resets_at` is an
# ABSOLUTE epoch the server computed at the moment it wrote that event — it
# does not update itself afterwards. Once `now` passes it, the window has
# REFILLED server-side and the `used_percent` sitting next to it is a stale
# reading of a quota that no longer exists. A tank that burned to 100% at
# 08:00 and reset at 12:00 must NOT still show red/"0% left" at 16:00 just
# because that is the newest `token_count` event on disk — it must show
# green/"100% left", the honest current state. _limit_codex_window_expired
# is the single place that decides "is this side's number still current",
# with a 60s tolerance for ordinary clock skew between this machine and the
# server (the same tolerance _limit_codex_render_reset's own short/dated
# split already used, now factored into one function both call).
#
# Percent LEFT is the canonical unit here (matching the vendor's own "N%
# left" wording); `used_percent` is converted once, at the boundary
# (_limit_codex_left).

# _limit_codex_local — the SAME date arithmetic as _limit_local above, but
# never force a TZ override. claude's phrases always carry an explicit zone
# to resolve against; codex's status/rate_limits carry none, because codex
# always renders/resolves in the machine's own local wall-clock — this reads
# that ambient zone (whatever $TZ/the system already resolves to) instead of
# one named in the text. Kept as a separate function, not a `tz=""` branch
# bolted onto the claude one, so the claude path stays byte-for-byte what it
# was — nothing here can regress it by accident.
_limit_codex_local() {
  local ep="$1" fmt="$2"
  if [ "$(_limit_date_kind)" = gnu ]; then date -d "@$ep" "+$fmt" 2>/dev/null
  else date -r "$ep" "+$fmt" 2>/dev/null; fi
}

# _limit_month_abbr <01..12> -> Jan..Dec (the reverse of _limit_month_num).
_limit_month_abbr() {
  case "$1" in
    01) printf 'Jan' ;; 02) printf 'Feb' ;; 03) printf 'Mar' ;; 04) printf 'Apr' ;;
    05) printf 'May' ;; 06) printf 'Jun' ;; 07) printf 'Jul' ;; 08) printf 'Aug' ;;
    09) printf 'Sep' ;; 10) printf 'Oct' ;; 11) printf 'Nov' ;; 12) printf 'Dec' ;;
  esac
}

# _limit_codex_window_expired <resets_at_epoch> <now> -> 0 if that window's
# own reset instant is already more than 60s behind `now` (P1-1: the window
# has REFILLED server-side and its `used_percent` no longer applies), 1
# otherwise (still ahead of `now`, within the 60s clock-skew tolerance, or
# not a number clikae can judge at all — never guess expiry on bad input).
# The 60s tolerance matches ordinary clock skew between this machine and
# codex's server, not a display choice — see the P1-1 note above.
_limit_codex_window_expired() {
  local ep="$1" now="$2"
  case "$ep" in ''|*[!0-9]*) return 1 ;; esac
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((ep - now))" -lt -60 ]
}

# _limit_codex_render_reset <resets_at_epoch> <now> -> codex's own phrase
# grammar rendered FROM an absolute epoch — local time, short form ("resets
# HH:MM") when the reset lands within the next ~20h (the shape codex's own
# 5h-window line always takes, since that window can never be more than 5h
# out), dated form otherwise (the shape its weekly/longer windows take once
# the reset is more than a day away).
#
# P1-1: an `ep` more than 60s behind `now` is EXPIRED (_limit_codex_window_expired)
# and this returns 1 + nothing for it, full stop — it is never handed to the
# dated branch below. Before this fix, a past `ep` fell through the old
# short-form window check into the dated `else` and was rendered as if it
# were a future date ("resets 14:20 on 10 Sep" printed at 16:40 on 10 Sep,
# two hours after that exact instant already passed) — the vendor never
# renders a reset that has already happened, so clikae must not either.
#
# P3-3 (2026-09-12 round-1 review, decided not to change): the dated form
# has no year, matching codex's OWN grammar exactly — codex's `/status`
# never shows one either. That is only unambiguous because `ep` here is
# always `resets_at` from a live `rate_limits` reading, which is bounded by
# that window's own length — the longest observed in practice is a 30-day
# window (see the 🔴 free-tier note above), so `ep` is never more than a
# few weeks past `now` and "D Mon" alone always reads as the next such date.
# A synthetic epoch far beyond that (a test fixture landing in the year
# 2100, say) would print a year-less date that LOOKS like next month rather
# than 74 years out — but no real `resets_at` can ever be that far away, so
# this is a property of test fixtures, not a reachable production bug.
_limit_codex_render_reset() {
  local ep="$1" now="$2" hm mon day
  [ -n "$ep" ] && [ -n "$now" ] || return 1
  case "$ep" in ''|*[!0-9]*) return 1 ;; esac
  _limit_codex_window_expired "$ep" "$now" && return 1
  hm="$(_limit_codex_local "$ep" '%H:%M')"
  [ -n "$hm" ] || return 1
  if [ $(( ep - now )) -lt 72000 ]; then
    printf 'resets %s' "$hm"
    return 0
  fi
  mon="$(_limit_codex_local "$ep" '%m')"
  day="$(_limit_codex_local "$ep" '%d')"
  [ -n "$mon" ] && [ -n "$day" ] || return 1
  printf 'resets %s on %d %s' "$hm" "$((10#$day))" "$(_limit_month_abbr "$mon")"
}

# _limit_codex_left <used_percent> -> percent LEFT (100 - used), or 1 +
# nothing when <used_percent> is empty/not a number. The one place a
# structured-source used_percent (e.g. "99.0") is converted to the same
# "% left" unit the vendor's own text uses everywhere else here.
#
# P3-1 (2026-09-12 round-1 review): a bare truncation of the decimal part
# (`${1%%.*}`) rounds towards ZERO USED — i.e. optimistic on the thing that
# decides red/yellow/green. "99.5" truncated to "99" reads 1% left (yellow),
# never red, until the vendor's own number hits exactly "100.0". When the
# reading decides whether a tank looks safe to burn, the conservative
# direction is to round USED up (ceiling) — any non-zero fractional part
# bumps used to the next whole percent, so "99.5" reads 0% left (red) same
# as "100.0" does, and only a used_percent that is a clean whole number (or
# whose fraction is all zeros, "40.00") keeps its own truncated value.
_limit_codex_left() {
  local raw="$1" ip dp u
  case "$raw" in ''|*[!0-9.]*) return 1 ;; esac
  case "$raw" in
    *.*)
      ip="${raw%%.*}"; dp="${raw#*.}"
      case "$ip" in ''|*[!0-9]*) return 1 ;; esac
      case "$dp" in *[!0-9]*) return 1 ;; esac
      case "$dp" in *[!0]*) u=$((10#$ip + 1)) ;; *) u=$((10#$ip)) ;; esac
      ;;
    *)
      case "$raw" in ''|*[!0-9]*) return 1 ;; esac
      u=$((10#$raw)) ;;
  esac
  [ "$u" -le 100 ] || u=100
  printf '%d' "$((100 - u))"
}

# _limit_codex_pct_light <pct_left> -> red|yellow|green, or 1 + nothing when
# <pct_left> is empty/not a number — an unknown reading is never a guessed
# colour. Thresholds: 0% left is red (the same "can't burn now" meaning as
# every other red dot on the board); under 15% left is yellow (a caution,
# same spirit as claude's weekly-warn BETA); anything else is green.
_limit_codex_pct_light() {
  local left="$1"
  case "$left" in ''|*[!0-9]*) return 1 ;; esac
  if   [ "$left" -le 0 ];  then printf 'red'
  elif [ "$left" -lt 15 ]; then printf 'yellow'
  else printf 'green'; fi
}

# limit_codex_status_light <primary_used_percent> <secondary_used_percent>
# -> red|yellow|green, or 1 + nothing when BOTH are empty. "Light = the
# tighter one": whichever window is CLOSER to being exhausted decides the
# colour — a tank at "5h: 90% left, weekly: 2% left" must show red, because
# the weekly window is the one about to actually stop you.
limit_codex_status_light() {
  local pu="$1" su="$2" l worst="" got=0
  if l="$(_limit_codex_left "$pu" 2>/dev/null)"; then
    got=1; { [ -z "$worst" ] || [ "$l" -lt "$worst" ]; } && worst="$l"
  fi
  if l="$(_limit_codex_left "$su" 2>/dev/null)"; then
    got=1; { [ -z "$worst" ] || [ "$l" -lt "$worst" ]; } && worst="$l"
  fi
  [ "$got" -eq 1 ] || return 1
  _limit_codex_pct_light "$worst"
}

# _limit_codex_window_label <window_minutes> -> "5h" | "weekly" | "<N>d" |
# "usage" (empty/unrecognised window). Labels by the window's OWN length,
# never by which JSON key (primary/secondary) it arrived in — see the
# 🔴 note at the top of this section for why position is not trustworthy.
#
# P3-2 (2026-09-12 round-1 review): the old upper bound for "weekly" was
# 20160 minutes (14 DAYS), not codex's actual 7-day/10080-minute weekly
# window — so a genuine 8..14-day window would have been mislabelled
# "weekly" too. Tightened to the real boundary; anything longer falls
# through to the "<N>d" form instead of a wrong, more specific-sounding name.
_limit_codex_window_label() {
  local win="$1"
  case "$win" in ''|*[!0-9]*) printf 'usage'; return ;; esac
  if   [ "$win" -le 360 ];   then printf '5h'
  elif [ "$win" -le 10080 ]; then printf 'weekly'
  else printf '%dd' "$((win / 1440))"; fi
}

# _limit_codex_rate_limits <config_dir> -> "<p_used>\037<p_window_min>\037
# <p_resets_at>\037<s_used>\037<s_window_min>\037<s_resets_at>", from the
# NEWEST `token_count` event (by its own timestamp) across this tank's
# rollouts that carries a non-null primary or secondary — or 1 + nothing if
# none ever did. Every field here is the VENDOR's own number (percent and an
# ABSOLUTE epoch the server computed), never something clikae derives — same
# "relay, don't guess" rule as every other reset in this file.
#
# P1-2 (2026-09-12 round-1 review): this used to read `transcript_tail`'s
# fixed 512 KiB window — fine for a small rollout, but a codex session
# commonly exceeds 1 MB, and the moment >512 KiB of tool output lands AFTER
# the last `token_count` event, that event falls entirely outside the tail
# and a strictly OLDER (possibly already-expired) event from another file
# silently wins the `maxT` comparison instead — a false reading with no
# error anywhere. `transcript_tail_scan` (lib/core/profile_store.sh) grows
# the tail window until it actually contains a `token_count` line (or has
# read the whole file), so the newest one is never dropped just because
# something large was appended after it.
# _limit_codex_rate_limits_from_files <file>... -> "<pu>\037<pw>\037<pr>\037
# <su>\037<sw>\037<sr>\037<ts>" from the NEWEST `token_count` event (by its
# own timestamp) across the GIVEN files that carries a non-null primary or
# secondary, or 1 + nothing if none ever did. The shared scan+awk core: both
# `_limit_codex_rate_limits` (every rollout in the store, uncached — one call
# per burn) and `_limit_codex_rate_limits_1file` (a SINGLE rollout, cached
# per file — see P2-2 below) build on this; only the file LIST differs. `ts`
# (the winning event's own timestamp) rides along as a 7th field so a caller
# combining several already-scanned files (the per-file cache) can pick the
# newest across them without re-parsing anything.
_limit_codex_rate_limits_from_files() {
  local out
  out="$(for f in "$@"; do
      [ -n "$f" ] && transcript_tail_scan "$f" '"type": *"token_count"'
    done | awk '
      function ts(s,   t) {
        if (match(s, /"timestamp": *"[^"]*"/)) {
          t = substr(s, RSTART, RLENGTH); sub(/.*"timestamp": *"/, "", t); sub(/".*/, "", t)
          return t
        }
        return ""
      }
      function side(s, key,   re) {
        re = "\"" key "\": *\\{[^}]*\\}"
        if (match(s, re)) return substr(s, RSTART, RLENGTH)
        return ""
      }
      function field(obj, name,   re, v) {
        re = "\"" name "\": *[0-9.]+"
        if (match(obj, re)) {
          v = substr(obj, RSTART, RLENGTH)
          sub(/^"[a-zA-Z_]+": */, "", v)
          return v
        }
        return ""
      }
      /"type": *"token_count"/ && /"rate_limits"/ {
        if (!match($0, /"rate_limits": *\{/)) next
        rl = substr($0, RSTART)
        p = side(rl, "primary"); s = side(rl, "secondary")
        if (p == "" && s == "") next
        t = ts($0)
        if (t != "" && (maxT == "" || t > maxT)) {
          maxT = t
          pu = field(p, "used_percent"); pw = field(p, "window_minutes"); pr = field(p, "resets_at")
          su = field(s, "used_percent"); sw = field(s, "window_minutes"); sr = field(s, "resets_at")
        }
      }
      END { printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\n", pu, pw, pr, su, sw, sr, maxT }
    ')"
  local pu pw pr su sw sr ts
  IFS=$'\037' read -r pu pw pr su sw sr ts <<EOF
$out
EOF
  [ -n "$pu" ] || [ -n "$su" ] || return 1
  printf '%s\037%s\037%s\037%s\037%s\037%s\037%s' "$pu" "$pw" "$pr" "$su" "$sw" "$sr" "$ts"
}

_limit_codex_rate_limits() {
  local dir="$1"
  local sess_root="$dir/sessions"
  [ -d "$sess_root" ] || return 1

  local files
  files="$(find "$sess_root" -name 'rollout-*.jsonl' -mmin -10080 2>/dev/null)"
  [ -n "$files" ] || return 1
  local -a filearr=()
  while IFS= read -r f; do [ -n "$f" ] && filearr+=("$f"); done <<EOF
$files
EOF

  local out pu pw pr su sw sr ts
  out="$(_limit_codex_rate_limits_from_files "${filearr[@]}")" || return 1
  IFS=$'\037' read -r pu pw pr su sw sr ts <<EOF
$out
EOF
  : "$ts"
  printf '%s\037%s\037%s\037%s\037%s\037%s' "$pu" "$pw" "$pr" "$su" "$sw" "$sr"
}

# limit_codex_status_note <p_used> <p_window_min> <p_resets_at> <s_used>
# <s_window_min> <s_resets_at> <now_epoch> -> a human line exposing BOTH
# windows, e.g. "5h 12% left (resets 05:14) · weekly 5% left (resets 22:12
# on 15 Sep)" — only the sides that have data appear. The percentage IS the
# vendor's own (never computed); the reset phrase is rendered from the
# vendor's own absolute epoch (_limit_codex_render_reset).
limit_codex_status_note() {
  local pu="$1" pw="$2" pr="$3" su="$4" sw="$5" sr="$6" now="$7"
  local note="" label left phrase
  if [ -n "$pu" ]; then
    label="$(_limit_codex_window_label "$pw")"
    left="$(_limit_codex_left "$pu" 2>/dev/null || true)"
    phrase="$(_limit_codex_render_reset "$pr" "$now" 2>/dev/null || true)"
    note="${label} ${left:-?}% left${phrase:+ (${phrase})}"
  fi
  if [ -n "$su" ]; then
    label="$(_limit_codex_window_label "$sw")"
    left="$(_limit_codex_left "$su" 2>/dev/null || true)"
    phrase="$(_limit_codex_render_reset "$sr" "$now" 2>/dev/null || true)"
    [ -n "$note" ] && note="$note · "
    note="${note}${label} ${left:-?}% left${phrase:+ (${phrase})}"
  fi
  printf '%s' "$note"
}

# _limit_codex_status_render <p_used> <p_window_min> <p_resets_at> <s_used>
# <s_window_min> <s_resets_at> <now_epoch> -> "<light>\037<note>\037
# <reset phrase>", or 1 + nothing when both sides are empty. The PURE part of
# limit_codex_status/limit_codex_status_cached: turns already-fetched raw
# vendor fields into the light/note/reset triple. No file I/O, so it is cheap
# to call on every redraw even when the raw fields came from a cache that
# this call did not itself refresh — which matters because P1-1's
# window-expiry check depends on `now`, not on when the fields were fetched.
#
# P1-1 (2026-09-12 round-1 review): before comparing anything, drop a side
# whose OWN resets_at has already passed (_limit_codex_window_expired) —
# that window has REFILLED server-side, so its used_percent is stale and
# must never drive the light or be shown as "N% left (resets …)". Treated as
# fully refilled (0 used / 100% left, no reset text), not discarded outright,
# so "the other window is still exhausted" still wins the light correctly,
# and "both windows expired" correctly reads green/100%/no-reset rather than
# an honest-sounding but wrong red held over from hours ago.
_limit_codex_status_render() {
  local pu="$1" pw="$2" pr="$3" su="$4" sw="$5" sr="$6" now="$7"
  local light note reset pl sl other
  # P3 (2026-09-12 round-2 review): a side can carry a `resets_at` with NO
  # `used_percent` at all (codex sent a reset instant but no reading for that
  # window yet) — the OLD guard here was `[ -n "$pr" ]` alone, so an expired
  # `resets_at` on a side clikae never actually had a percentage for still
  # got "refilled" to a FABRICATED 0-used/100%-left reading. Every field in
  # this file is supposed to be the vendor's own number (see
  # _limit_codex_rate_limits' header) — a side that never reported a
  # used_percent must stay absent, not be invented. Require `pu`/`su`
  # themselves to already be non-empty before refilling them.
  if [ -n "$pu" ] && [ -n "$pr" ] && _limit_codex_window_expired "$pr" "$now"; then pu="0"; pr=""; fi
  if [ -n "$su" ] && [ -n "$sr" ] && _limit_codex_window_expired "$sr" "$now"; then su="0"; sr=""; fi
  light="$(limit_codex_status_light "$pu" "$su")" || return 1
  note="$(limit_codex_status_note "$pu" "$pw" "$pr" "$su" "$sw" "$sr" "$now")"
  pl="$(_limit_codex_left "$pu" 2>/dev/null || printf 101)"
  sl="$(_limit_codex_left "$su" 2>/dev/null || printf 101)"
  if [ -n "$su" ] && [ "$sl" -le "$pl" ]; then
    reset="$(_limit_codex_render_reset "$sr" "$now" 2>/dev/null || true)"; other="$pr"
  else
    reset="$(_limit_codex_render_reset "$pr" "$now" 2>/dev/null || true)"; other="$sr"
  fi
  # P3-4: the TIGHTER side may have no reset of its own (just refilled above,
  # or simply missing on disk) while the OTHER side still has a real one —
  # fall back to it rather than reporting an empty reset when one exists.
  [ -n "$reset" ] || reset="$(_limit_codex_render_reset "$other" "$now" 2>/dev/null || true)"
  printf '%s\037%s\037%s' "$light" "$note" "$reset"
}

# limit_codex_status <config_dir> <now_epoch> -> "<light>\037<note>\037
# <reset phrase>", or 1 + nothing when this tank has never reported usage —
# the same honest "no reading" as limit_engine_detectable's ○, never a
# guessed green. <reset phrase> is the TIGHTER window's own rendered reset
# (the single value burn --json's "reset" field and the board's fuel-dot
# note fall back on); the full picture (both windows) is in <note>. Scans
# the rollout store fresh every call — burn.sh's only caller runs this once
# per burn, not per redraw, so the cost is a non-issue there. The redraw path
# (home.sh) calls limit_codex_status_cached instead — see its header.
limit_codex_status() {
  local dir="$1" now="$2" fields pu pw pr su sw sr
  fields="$(_limit_codex_rate_limits "$dir" 2>/dev/null)" || return 1
  IFS=$'\037' read -r pu pw pr su sw sr <<EOF
$fields
EOF
  _limit_codex_status_render "$pu" "$pw" "$pr" "$su" "$sw" "$sr" "$now"
}

# _limit_codex_cache_mtime <config_dir> -> a short string identifying the
# CURRENT state of this tank's rollout store: the count of files in the
# 7-day scan window, the newest one's mtime, and the store's TOTAL byte size
# — cheap (one `find`, one `stat` via sessions_by_mtime, one `wc -c` over the
# already-known file list; no file CONTENT read), unlike
# _limit_codex_rate_limits' tail+awk scan. The count guards the case where a
# brand new rollout happens to share its predecessor's mtime second (same
# burn, same wall-clock second) — an added file must still bust the cache
# even if "newest mtime" alone did not change.
#
# P1-1 (2026-09-12 round-2 review): mtime alone (even with the file-count
# guard above) is SECOND-resolution, and codex appends to the SAME rollout
# file rather than opening a new one per event — file count never changes on
# an append. So a second `token_count` write landing in the same wall-clock
# second as the read that populated the cache was INVISIBLE to the old key:
# `stat`'s mtime read back identical, the cache looked "still valid", and the
# board kept serving the stale reading — reproduced 3/3 against a real
# `bin/clikae` board (persistent false green on a tank already at 0% left,
# never self-corrected). A byte-count is added to the key because an append
# ALWAYS changes the store's total size, even when it lands in the same
# second as the previous read — the one thing that is guaranteed to move
# every time content that could change the reading actually changes.
_limit_codex_cache_mtime() {
  local dir="$1" sess_root
  sess_root="$dir/sessions"
  [ -d "$sess_root" ] || { printf 'none'; return 0; }
  local -a files=()
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done <<EOF
$(find "$sess_root" -name 'rollout-*.jsonl' -mmin -10080 2>/dev/null)
EOF
  [ "${#files[@]}" -gt 0 ] || { printf 'none'; return 0; }
  local newest total
  newest="$(sessions_by_mtime "${files[@]}" 2>/dev/null | head -n 1 | awk '{print $1}')"
  total="$(wc -c "${files[@]}" 2>/dev/null | awk 'END{print $1+0}')"
  printf '%d:%s:%s' "${#files[@]}" "$newest" "$total"
}

# _limit_codex_file_state <file> -> "<mtime>:<size>", a cheap per-FILE
# identity string (one `stat`, one `wc -c`) — the invalidation key for that
# file's own cache entry (_limit_codex_rate_limits_1file_cached below). Same
# size-plus-mtime reasoning as _limit_codex_cache_mtime's header: mtime alone
# is second-resolution and blind to a same-second append; size always moves
# when the file's content actually changes.
_limit_codex_file_state() {
  local f="$1" mt sz
  mt="$(file_mtime "$f" 2>/dev/null)"; [ -n "$mt" ] || mt=0
  sz="$(wc -c < "$f" 2>/dev/null || echo 0)"
  sz="${sz//[[:space:]]/}"
  case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
  printf '%s:%s' "$mt" "$sz"
}

# _limit_codex_rate_limits_1file <file> -> same 7-field output as
# _limit_codex_rate_limits_from_files, scoped to ONE rollout file.
_limit_codex_rate_limits_1file() {
  _limit_codex_rate_limits_from_files "$1"
}

# _limit_codex_rate_limits_1file_cached <file> <cache_dir> [precomputed_key]
# -> same output as _limit_codex_rate_limits_1file, memoized per FILE under
# <cache_dir> (one small file per rollout, named by the rollout's own
# basename — rollout filenames are already unique per session), invalidated
# by that file's own mtime:size identity. A file with no rate_limits event
# caches a "none" marker too, so a tank that never reports usage doesn't
# re-scan every one of its rollouts on every redraw either (see P2-2 below).
# <precomputed_key> lets a caller iterating MANY files pass in a key it
# already batch-computed (files_mtime_size, one stat for every file — see
# _limit_codex_rate_limits_cached) instead of paying this function's own
# _limit_codex_file_state fork PER file; omitted, it computes its own (this
# function stays independently correct/callable on its own).
#
# P2-2 (2026-09-12 round-2 review): the round-1 cache was keyed on the WHOLE
# store (_limit_codex_cache_mtime) — correct for an IDLE tank, but the moment
# any one rollout changes (a burn in progress, appending every few seconds)
# the aggregate key changes too, and round-1's cache-miss path re-scanned
# EVERY file in the store again, which — combined with P2-1's SIGPIPE bug —
# measured MORE expensive per redraw than the pre-cache code (2.83s vs the
# old 1.68s on a 120-rollout store). Caching per file means a redraw during
# activity only ever re-scans the ONE rollout that actually changed; every
# other file's cache entry is still valid and costs (batched) one stat plus
# one small read, matching this codebase's own "fork-free" cache philosophy
# (docs/DESIGN-board-fuel-dots.md's Cache section).
_limit_codex_rate_limits_1file_cached() {
  local f="$1" cache_dir="$2" key="$3" cache_f cached_key cached_fields tmp
  [ -n "$key" ] || key="$(_limit_codex_file_state "$f")"
  cache_f="$cache_dir/${f##*/}"
  if [ -f "$cache_f" ]; then
    { IFS= read -r cached_key; IFS= read -r cached_fields; } < "$cache_f" 2>/dev/null
    if [ "$cached_key" = "$key" ]; then
      [ "$cached_fields" = "none" ] && return 1
      [ -n "$cached_fields" ] && { printf '%s' "$cached_fields"; return 0; }
    fi
  fi
  mkdir -p "$cache_dir" 2>/dev/null
  tmp="$cache_f.tmp.$$"
  local fields
  if fields="$(_limit_codex_rate_limits_1file "$f" 2>/dev/null)"; then
    { printf '%s\n' "$key"; printf '%s\n' "$fields"; } > "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$cache_f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    printf '%s' "$fields"
    return 0
  fi
  { printf '%s\n' "$key"; printf 'none\n'; } > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$cache_f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 1
}

# _limit_codex_rate_limits_cached <config_dir> <cache_file> -> same 6-field
# output as _limit_codex_rate_limits, memoized. Two layers:
#   1. a whole-store fast path (<cache_file> itself, keyed by
#      _limit_codex_cache_mtime) — an IDLE tank costs one `find` + one `stat`
#      + one `wc -c` and nothing else, same shape as round-1's cache.
#   2. on a whole-store miss, a PER-FILE fast path
#      (_limit_codex_rate_limits_1file_cached, keyed per rollout) — an
#      ACTIVE tank only re-scans the file(s) that actually changed, not
#      every rollout in the store (P2-2).
#
# P2-1 (2026-09-12 round-1 review): _home_fuel_dotv's own header promises the
# redraw path is "fork-free" for a value that "cannot change between two
# keypresses" — but the codex branch called limit_codex_status straight
# through to _limit_codex_rate_limits' tail+awk scan of EVERY rollout file in
# the 7-day window, on every single redraw. Measured on a synthetic
# 120-rollout (~62 MB) store: ~1.5s per call, vs ~0.002s for the weekly
# cache's plain `read < file` (see docs/DESIGN-board-fuel-dots.md's Cache
# section and REPORT-codex-light-fix1.md for the exact before/after numbers).
# Deliberately caches only the raw vendor fields, never light/note/reset —
# those depend on `now` (P1-1), so the caller always recomputes them fresh
# even on a cache hit.
_limit_codex_rate_limits_cached() {
  local dir="$1" cache="$2" key cached_key cached_fields
  key="$(_limit_codex_cache_mtime "$dir")"
  if [ "$key" != "none" ] && [ -f "$cache" ]; then
    { IFS= read -r cached_key; IFS= read -r cached_fields; } < "$cache" 2>/dev/null
    if [ "$cached_key" = "$key" ]; then
      [ "$cached_fields" = "none" ] && return 1
      [ -n "$cached_fields" ] && { printf '%s' "$cached_fields"; return 0; }
    fi
  fi

  local sess_root="$dir/sessions"
  [ -d "$sess_root" ] || return 1
  local -a files=()
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done <<EOF
$(find "$sess_root" -name 'rollout-*.jsonl' -mmin -10080 2>/dev/null)
EOF
  [ "${#files[@]}" -gt 0 ] || return 1

  local files_cache_dir="${cache}.d"
  # Batch every file's own mtime:size in ONE `stat` call (files_mtime_size,
  # profile_store.sh) instead of forking `stat`+`wc` per file inside the loop
  # below — 120 rollouts would otherwise cost ~240 forks just to find out
  # WHICH files changed, before ever reading one. Positional: index i here
  # lines up with files[i].
  local -a mtimes=() sizes=()
  while IFS=' ' read -r _mt _sz; do
    mtimes+=("${_mt:-0}"); sizes+=("${_sz:-0}")
  done < <(files_mtime_size "${files[@]}")

  local f pf maxT="" pu pw pr su sw sr _pu _pw _pr _su _sw _sr _ts i=0
  for f in "${files[@]}"; do
    pf="$(_limit_codex_rate_limits_1file_cached "$f" "$files_cache_dir" "${mtimes[i]:-0}:${sizes[i]:-0}" 2>/dev/null)"
    i=$((i + 1))
    [ -n "$pf" ] || continue
    IFS=$'\037' read -r _pu _pw _pr _su _sw _sr _ts <<EOF
$pf
EOF
    if [ -n "$_ts" ] && { [ -z "$maxT" ] || [[ "$_ts" > "$maxT" ]]; }; then
      maxT="$_ts"; pu="$_pu"; pw="$_pw"; pr="$_pr"; su="$_su"; sw="$_sw"; sr="$_sr"
    fi
  done

  mkdir -p "$(dirname "$cache")" 2>/dev/null
  local tmp="$cache.tmp.$$"
  if [ -n "$pu" ] || [ -n "$su" ]; then
    local fields; fields="$(printf '%s\037%s\037%s\037%s\037%s\037%s' "$pu" "$pw" "$pr" "$su" "$sw" "$sr")"
    { printf '%s\n' "$key"; printf '%s\n' "$fields"; } > "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    printf '%s' "$fields"
    return 0
  fi
  { printf '%s\n' "$key"; printf 'none\n'; } > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 1
}

# limit_codex_status_cached <config_dir> <now_epoch> <cache_file> -> same
# contract as limit_codex_status, but sourced via
# _limit_codex_rate_limits_cached so a redraw that has seen no new codex
# activity since the last call never re-scans rollout content. This is what
# _home_fuel_dotv/_home_codex_status_readv call — see P2-1 above.
limit_codex_status_cached() {
  local dir="$1" now="$2" cache="$3" fields pu pw pr su sw sr
  fields="$(_limit_codex_rate_limits_cached "$dir" "$cache" 2>/dev/null)" || return 1
  IFS=$'\037' read -r pu pw pr su sw sr <<EOF
$fields
EOF
  _limit_codex_status_render "$pu" "$pw" "$pr" "$su" "$sw" "$sr" "$now"
}
