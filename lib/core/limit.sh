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
      case "$line" in *'"type":"turn.failed"'*|*'"type":"error"'*) ;; *) return 1 ;; esac
      printf '%s' "$line" | grep -qaiE "hit your (usage|session) limit|usage limit|rate_limit" ;;
    *)
      # Unknown transcript cli: keep the legacy whole-line text match (no regress).
      printf '%s' "$line" | grep -qaE "$pat" ;;
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

  # Newest GENUINE-limit timestamp and newest SUCCESSFUL-turn timestamp, across
  # ALL recent sessions (account-level). ISO-8601 stamps sort lexicographically,
  # so `sort | tail -1` is the max — portable across grep/shell quirks, and no
  # bracket class fancier than [^"] (some greps, e.g. ugrep, reject [^"\\]).
  local max_lim max_suc
  max_lim="$(printf '%s\n' "$files" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      grep -a '"model":"<synthetic>"' "$f" 2>/dev/null \
        | grep -a '"isApiErrorMessage":true' \
        | grep -oaE '"timestamp":"[^"]*"'
    done | sort | tail -n 1)"
  [ -n "$max_lim" ] || return 1

  max_suc="$(printf '%s\n' "$files" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      grep -a '"type":"assistant"' "$f" 2>/dev/null \
        | grep -av '"model":"<synthetic>"' \
        | grep -oaE '"timestamp":"[^"]*"'
    done | sort | tail -n 1)"

  # Dry only if nothing succeeded AFTER the newest limit. Pick the later of the
  # two by sort: if a success sorts last (and isn't the same stamp), it cleared.
  if [ -n "$max_suc" ]; then
    local newer
    newer="$(printf '%s\n%s\n' "$max_lim" "$max_suc" | sort | tail -n 1)"
    [ "$newer" = "$max_suc" ] && [ "$max_suc" != "$max_lim" ] && return 1
  fi

  # Dry: echo the vendor's own reset phrase from the NEWEST limit line (matched by
  # its timestamp), verbatim — never parsed into a countdown.
  local ts_val="${max_lim#\"timestamp\":\"}"; ts_val="${ts_val%\"}"
  printf '%s\n' "$files" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      grep -aF "$ts_val" "$f" 2>/dev/null \
        | grep -a '"isApiErrorMessage":true' \
        | grep -oaiE 'resets [^"]+'
    done | head -n 1
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
