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
# <date> <time>") if the text carries one, else nothing. Never computes a
# countdown — relays the vendor's own words (same spirit as the other detectors).
# Drives a "dry-until" window so watch/auto don't re-pick a tank before it recovers.
limit_codex_reset() {
  printf '%s\n' "$1" | grep -oaiE "try again at [^.\"]+" | head -n 1 \
    | sed -E 's/[[:space:]]+$//' || true
}

# limit_codex_output_dry <captured-output> -> 0 (dry) if a codex exec's CAPTURED
# output shows a usage limit, echoing the reset phrase; 1 (fine) otherwise.
# For checking a dispatched headless job: `codex exec` exits 0 even when limited
# and writes no artifact (burn-confirmed 2026-06-03), so the exit code is useless —
# the output string is the signal. Pair with an artifact check at the call site
# (a dropped job = limit string seen AND/OR the expected artifact missing).
limit_codex_output_dry() {
  printf '%s' "$1" | grep -qaiE "hit your (usage|session) limit" || return 1
  limit_codex_reset "$1"
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
    printf '%s' "$out" | grep -qaiE "$CLIKAE_LIMIT_PATTERN" && return 0
    # No override match → fall through to the built-in per-engine matchers, so the
    # pattern only ADDS coverage, never masks a hit the built-in would have caught.
  fi
  case "$cli" in
    codex)  limit_codex_output_dry "$out" ;;
    claude)
      printf '%s' "$out" | grep -qaiE "hit your (session|usage) limit" || return 1
      printf '%s' "$out" | grep -oaiE "resets [^\"]+|try again at [^.\"]+" | head -n 1 || true
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
#   • codex — a real limit is an exec-stdout-only event, NEVER written to the
#     rollout transcript (burn-verified 2026-06-01; see limit_line_is_real). There
#     is nothing in a transcript to scan, so codex is correctly absent.
#   • agy   — records its limit in a log file, not a transcript. That path is
#     handled separately by limit_log_dry (below), used for log-only targets.
# Any other cli returns "not dry" rather than guess.
limit_profile_dry() {
  local cli="$1" dir="$2"
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
  return 0
}

# _limit_tank_dry_self <engine> <tank> -> 0 (dry) + echo the verbatim reset phrase
# if THIS tank's own signal says it's out of fuel; 1 otherwise. Two sources:
#   • claude  — limit_profile_dry scans the tank's transcripts (account-level
#     WITHIN this config dir: all its recent sessions).
#   • any engine — a persisted dry marker (dry_store), written by the live catcher
#     (burn / supervise) for engines whose limit never lands in a scannable file.
# Self-only: factored out so limit_tank_dry's account contagion can't recurse.
_limit_tank_dry_self() {
  local engine="$1" tank="$2" dir reset
  dir="$(profile_dir "$engine" "$tank")"
  if [ "$engine" = "claude" ]; then
    # claude's dry state is its transcript ONLY (scannable + self-clearing on the
    # next successful turn). We NEVER consult dry_store for claude, so a stale 6h
    # marker can't mask a real recovery — the store is strictly for engines whose
    # limit isn't persisted to a transcript (codex).
    reset="$(limit_profile_dry "$engine" "$dir" 2>/dev/null)" || return 1
    printf '%s' "$reset"; return 0
  fi
  if reset="$(dry_store_read "$engine" "$tank" 2>/dev/null)"; then
    printf '%s' "$reset"; return 0
  fi
  return 1
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
  if reset="$(_limit_tank_dry_self "$engine" "$tank")"; then
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
    if reset="$(_limit_tank_dry_self "$sib_e" "$sib_t")"; then
      printf '%s' "$reset"; return 0
    fi
  done <<EOF
$(list_all_profiles)
EOF
  return 1
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
limit_log_dry() {
  local logf="$1"
  [ -n "$logf" ] && [ -e "$logf" ] || return 1
  grep -qaE 'RESOURCE_EXHAUSTED|Individual quota reached' "$logf" 2>/dev/null || return 1
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
