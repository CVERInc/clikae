# shellcheck shell=bash
# lib/commands/watch.sh — `clikae watch <engine> [<tank>] [--auto] [--to <t>]`
#
# Ambient relay: watch the current session's transcript and, when it looks like
# the tank ran dry, hand off to the next tank — offering first (default), or
# automatically once you've consented (--auto). Philosophy: quietly help, then
# tell you what it did.
#
# ⚠️ HONEST CAVEAT (read this). An interactive CLI hitting its usage limit does
# not exit, returns no code, and fires no hook — so the only signal we can watch
# is what the limit writes into the transcript. The exact marker is NOT yet
# confirmed against a real limit event (you can't force one without burning a
# tank). So the default pattern below is a BEST GUESS. Confirm/tune it the first
# time you actually get limited:
#     clikae watch claude --check         # does the pattern fire on this session?
#     CLIKAE_LIMIT_PATTERN='...' clikae watch claude
# When you learn the real marker, set $CLIKAE_LIMIT_PATTERN (or tell the project).

# Limit markers, CONFIRMED against real live limits (dogfooded 2026-05-31):
#   • claude — CONFIRMED, and it IS written to the transcript (so the tail catches
#       it): a real interactive limit appears as a jsonl line with
#       "isApiErrorMessage":true and text "You've hit your session limit · resets
#       <time> (<tz>)". (The TUI also shows "/upgrade to increase your usage limit.")
#   • codex  — CONFIRMED: `codex exec --json` emits `{"type":"turn.failed",...}`
#       + `{"type":"error","message":"You've hit your usage limit. … try again at
#       <date>."}` and exits non-zero.
#   • agy/Gemini — CONFIRMED: `agy -p` hitting its limit exits 0 with EMPTY
#       stdout/stderr; the marker lands ONLY in ~/.gemini/antigravity-cli/cli.log
#       as `agent executor error: RESOURCE_EXHAUSTED (code 429): Individual quota
#       reached. … Resets in <Hh Mm>.` So agy can't be detected via exit code,
#       stdout, or a transcript — you must scan that cli.log. (Earlier guess
#       "quota exceeded" was wrong; the real text is "Individual quota reached".)
#       NOTE: `clikae watch` does NOT yet read agy's cli.log — wiring watch to
#       scan it is an unbuilt feature; this only records the confirmed marker.
# Note "session limit" (claude) vs "usage limit" (codex) — keep both.
# This pattern is now only the TEXT GATE / fallback. Real detection for claude &
# codex is STRUCTURAL (see limit_line_is_real) — a transcript that merely
# *discusses* a limit (e.g. working on clikae itself) no longer trips them, since
# a genuine event also requires the synthetic/api-error structure. Unknown clis
# still fall back to a pure text match. Override anytime with --pattern /
# $CLIKAE_LIMIT_PATTERN.
_watch_default_pattern() {
  printf '%s' "You've hit your (session|usage) limit|session limit|usage limit|usage_limit|increase your usage limit|\"type\":\"turn.failed\"|rate_limit_error|rate_limited|RESOURCE_EXHAUSTED|Individual quota reached|quota exceeded|Approaching your usage|limit reached|5-hour limit|weekly limit|resets [0-9]|resets at"
}

# Genuine-limit detection (structural, not text) lives in lib/core/limit.sh as
# limit_line_is_real — shared with the home dashboard. See the header there.

# _watch_weekly_capture <cli> <profile> <line>  (BETA) — if a tailed line carries
# the vendor's verbatim weekly-usage notice, cache it (+ a stamp) so the home
# board can show this tank a yellow ● ("you're at N% this week"). We relay the
# engine's own words, never compute a %. Best-effort + never fatal: a no-match
# leaves the cache untouched. See docs/DESIGN-board-fuel-dots.md (yellow is BETA —
# it's not yet confirmed this notice reaches the transcript at all).
_watch_weekly_capture() {
  local cli="$1" profile="$2" line="$3" phrase cache
  phrase="$(limit_weekly_marker "$line")"
  [ -n "$phrase" ] || return 0
  cache="$CLIKAE_HOME/cache/weekly/$cli-$profile"
  mkdir -p "$(dirname "$cache")" 2>/dev/null || return 0
  { printf '%s\n' "$phrase"; date '+captured %Y-%m-%d %H:%M' 2>/dev/null; } > "$cache" 2>/dev/null || true
}

_watch_consent_file() { printf '%s\n' "$CLIKAE_HOME/auto-relay-consent"; }
_watch_has_consent()  { [ -f "$(_watch_consent_file)" ]; }
_watch_grant_consent() {
  mkdir -p "$CLIKAE_HOME"
  : > "$(_watch_consent_file)"
}

cmd_watch() {
  local cli="" profile="" got_profile=0 to="" auto=0 check=0 pattern="" pattern_explicit=0
  local -a positionals=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage: clikae watch <engine> [<tank>] [--to <target>] [--auto] [--check]
                     [--pattern <regex>]

Watch the current directory's session and, when it looks like the tank ran dry,
hand off to the next tank. By default it OFFERS (asks first); with --auto it
switches automatically after a one-time consent. The brief + handoff reuse
`clikae handoff` under the hood, so a switchable target continues on its quota.

Where it goes next:
  --to <target>   explicit target (<engine>/<tank> or a launch-only target).
  (otherwise)     the next tank of the SAME engine — your tanks ARE the reserve,
                  nothing to configure. Cross-engine needs an explicit --to.

Launch-only targets (single-account vendors, e.g. antigravity): clikae watches
their LOG instead of a transcript (agy writes its quota error only to
~/.gemini/antigravity-cli/cli.log; `agy -p` exits 0 with empty output, so the
log is the only signal). Because such a vendor can't be a handoff *source* (no
brief can be summarised from it), watching it ALERTS you that the tank is dry
and names your next tank — it does not auto-relay.

Detecting "ran dry" — IMPORTANT: an interactive CLI hitting its limit gives no
exit code and fires no hook, so we can only scan the transcript, and the exact
marker isn't confirmed yet. The pattern is a best guess; verify/tune it:
  --check             scan the current session now and report if it would fire,
                      then exit (no watching, no handoff). Use this to confirm
                      the pattern the first time you actually hit a limit.
  --pattern <regex>   override the match (also via $CLIKAE_LIMIT_PATTERN).

Options:
  --auto    Switch automatically on detection (asks once for consent, then
            remembers). Without it, you're asked each time.

Examples:
  clikae watch claude                     # offer to fall through to the next tank
  clikae watch claude --to codex/work     # offer to switch to a specific tank
  clikae watch claude --auto              # auto-switch (after one-time consent)
  clikae watch claude --check             # would the limit pattern fire right now?
  clikae watch antigravity                # alert when agy's tank runs dry (log-watch)
  clikae watch antigravity --check        # is agy's tank already dry?
EOF
        return 0 ;;
      --to)      shift; [ $# -gt 0 ] || log_fail "--to needs a target"; to="$1"; shift ;;
      --pattern) shift; [ $# -gt 0 ] || log_fail "--pattern needs a regex"; pattern="$1"; shift ;;
      --auto)    auto=1; shift ;;
      --check)   check=1; shift ;;
      --) shift; break ;;
      -*) log_fail "Unknown flag: $1" ;;
      *) positionals+=("$1"); shift ;;
    esac
  done

  [ "${#positionals[@]}" -ge 1 ] || log_fail "Missing <engine>. See: clikae watch --help"
  cli="${positionals[0]}"; validate_name cli "$cli"
  case "${#positionals[@]}" in
    1) ;;
    2) profile="${positionals[1]}"; got_profile=1 ;;
    *) log_fail "Too many arguments. Usage: clikae watch $cli [<tank>]" ;;
  esac

  # An explicit pattern (--pattern flag or $CLIKAE_LIMIT_PATTERN) is a deliberate
  # override → pure text match. Only the built-in default triggers structural
  # detection (see limit_line_is_real).
  if [ -n "$pattern" ]; then
    pattern_explicit=1
  elif [ -n "${CLIKAE_LIMIT_PATTERN:-}" ]; then
    pattern="$CLIKAE_LIMIT_PATTERN"; pattern_explicit=1
  else
    pattern="$(_watch_default_pattern)"
  fi

  # Launch-only targets (single-account vendors like antigravity) have no adapter
  # and no per-dir transcript — their only limit signal is a log file. If <engine>
  # resolves to such a target, watch that log instead of an adapter transcript.
  if [ ! -f "$CLIKAE_LIB/adapters/$cli.sh" ] && [ -f "$CLIKAE_LIB/targets/$cli.sh" ]; then
    [ "$got_profile" -eq 0 ] || log_fail "'$cli' is a single-account target — drop the <tank>."
    _watch_target "$cli" "$pattern" "$check" "$to"
    return
  fi

  load_adapter "$cli"

  # codex writes its usage limit ONLY to the exec STDOUT stream, never to the
  # rollout transcript (burn-confirmed 2026-06-03; the rollout ends in a
  # token_count with rate_limit_reached_type:null). Since `watch` tails a
  # transcript, it physically cannot catch a codex limit — so say so plainly
  # rather than tail a file that will never carry the marker (codex DID gain
  # adapter_transcript_path for the board's resume list, which would otherwise
  # make this path look falsely supported). Detection for codex happens at
  # DISPATCH time: capture the exec output and check it (lib/core/limit.sh
  # limit_codex_output_dry — the "You've hit your usage limit" line + a missing
  # artifact, since codex exec exits 0 even when limited).
  if [ "$cli" = "codex" ]; then
    log_warn "codex records its usage limit in the exec output, not the session transcript."
    log_dim  "So \`clikae watch codex\` (a transcript tail) can't catch a codex limit."
    log_dim  "Detect it at dispatch time: capture the codex output and check it for"
    log_dim  "\"You've hit your usage limit\" (codex exec exits 0 even when limited)."
    return 1
  fi

  if ! declare -F adapter_transcript_path >/dev/null; then
    log_fail "'$cli' has no transcripts clikae can watch (no adapter_transcript_path)."
  fi

  # Resolve the profile we're watching (from the env var if not named).
  if [ "$got_profile" -eq 0 ]; then
    local var strategy value
    var="$(adapter_meta_env_var)"; strategy="$(adapter_meta_strategy)"; value="${!var}"
    profile="$(resolve_active_profile "$cli" "$strategy" "$value")"
    [ -n "$profile" ] || log_fail "Couldn't tell which '$cli' tank this shell is on; name it: clikae watch $cli <tank>"
    log_dim "Watching current tank: $profile  (\$$var)"
  fi
  validate_name profile "$profile"

  local dir transcript
  dir="$(ensure_profile --require "$cli" "$profile")"
  transcript="$(adapter_transcript_path "$dir" || true)"
  [ -n "$transcript" ] || log_fail "No session for this directory under '$cli/$profile' (nothing to watch)."

  # --check: report whether a GENUINE limit marker fires on the session so far.
  # Line-by-line via the structured matcher, so a transcript that merely discusses
  # a limit (the old whole-file grep's classic false positive) no longer trips it.
  if [ "$check" -eq 1 ]; then
    local found=0 line sid
    sid="$(basename "$transcript" .jsonl)"
    while IFS= read -r line; do
      limit_line_is_real "$cli" "$line" "$pattern" "$pattern_explicit" || continue
      if [ "$found" -eq 0 ]; then
        log_warn "A genuine limit marker IS present (session ${sid%%-*}…)."
        found=1
      fi
      # Show a snippet of what matched: the limit phrase if present, else the
      # custom pattern's hit. Guard every grep so a no-match never aborts under
      # the caller's pipefail (the display is cosmetic, not control flow).
      local snip
      snip="$(printf '%s' "$line" | grep -aoiE "hit your [a-z]+ limit[^\"]*" | head -n 1 || true)"
      [ -n "$snip" ] || snip="$(printf '%s' "$line" | grep -aoE "$pattern" | head -n 1 || true)"
      [ -z "$snip" ] || printf '  matched: %s\n' "$snip"
    done < "$transcript"
    if [ "$found" -eq 0 ]; then
      log_ok "No genuine limit marker found in the current session."
      log_dim "(claude requires isApiErrorMessage + model:<synthetic>; override with --pattern / \$CLIKAE_LIMIT_PATTERN)"
    fi
    return 0
  fi

  # Resolve where we'd go on a dry tank: the next tank in your BURN ORDER (your
  # tanks are the reserve — no pool to set up). May cross engines if your order
  # says so; --to overrides.
  local target="$to"
  if [ -z "$target" ]; then
    local _nt; _nt="$(next_tank "$cli" "$profile" | tr '\t' '/')"
    [ -n "$_nt" ] || log_fail "Nothing after $cli/$profile in your burn order. Add a tank (clikae init $cli <tank>) or give --to <target>."
    target="$_nt"
  fi
  validate_handoff_target "$target"

  log_info "Watching $cli/$profile for a dry tank → next: $target"
  [ "$auto" -eq 1 ] && log_dim "Auto mode: will switch on detection." \
                    || log_dim "Will ask before switching (use --auto to switch automatically)."
  log_dim "Pattern is a best guess; if it never fires, see \`clikae watch --help\`. Ctrl-C to stop."

  # Tail only NEW lines; stop at the first GENUINE limit line (structured match).
  local line=""
  while IFS= read -r line; do
    # BETA: relay the vendor's verbatim weekly-usage % to the board's yellow dot,
    # independent of the dry trigger below (a weekly warning is caution, not dry).
    _watch_weekly_capture "$cli" "$profile" "$line"
    limit_line_is_real "$cli" "$line" "$pattern" "$pattern_explicit" || continue
    echo
    log_warn "Looks like $cli/$profile hit its limit."
    _watch_do_handoff "$cli" "$profile" "$target" "$auto"
    # _watch_do_handoff execs on success; if it returns, the user declined.
    log_dim "Staying on $cli/$profile. Still watching… (Ctrl-C to stop)"
  done < <(tail -n0 -f "$transcript")
}

# Decide + perform the handoff. Execs `clikae handoff` on go; returns if declined.
_watch_do_handoff() {
  local cli="$1" profile="$2" target="$3" auto="$4"

  if [ "$auto" -eq 1 ]; then
    if ! _watch_has_consent; then
      log_warn "Auto-switch needs your consent once."
      if confirm "Allow clikae to auto-switch tanks when you hit a limit, from now on?"; then
        _watch_grant_consent
        log_dim "Consent saved ($(_watch_consent_file)). Delete that file to revoke."
      else
        log_info "No consent given; asking for this switch instead."
        confirm "Switch $cli/$profile → $target now?" || return 1
      fi
    fi
    log_ok "Auto-switching: $cli/$profile → $target"
  else
    confirm "Switch $cli/$profile → $target now?" || return 1
    log_ok "Switching: $cli/$profile → $target"
  fi

  exec "$CLIKAE_ROOT/bin/clikae" handoff "$cli" "$profile" --to "$target"
}

# Watch a launch-only target's limit LOG (e.g. antigravity's cli.log).
# These are single-account vendors with no transcript clikae can read, so they
# CAN'T be a handoff source — we can't carry a brief off them. Hence this path
# only NOTICES a dry tank and tells you to switch; it does not auto-relay.
# (Wiring an auto-relay would need extracting a brief from the vendor's session
# store — agy's is opaque binary .pb — so that's a separate, unbuilt feature.)
_watch_target() {
  local cli="$1" pattern="$2" check="$3" to="$4"
  # shellcheck source=/dev/null
  source "$CLIKAE_LIB/targets/$cli.sh"
  if ! declare -F target_limit_log_path >/dev/null; then
    log_fail "'$cli' is a launch-only target with no watchable limit log (no target_limit_log_path)."
  fi
  local name logf
  name="$(target_meta_name)"
  logf="$(target_limit_log_path)"
  [ -n "$logf" ] || log_fail "'$cli' gave no limit-log path to watch."

  # --check: scan the current log once and report whether the marker is present.
  if [ "$check" -eq 1 ]; then
    if [ -e "$logf" ] && grep -qaE "$pattern" "$logf"; then
      log_warn "A limit-like marker IS present in $name's log."
      log_dim "(log: $logf)"
      grep -aoE "$pattern" "$logf" | sort -u | sed 's/^/  matched: /'
      return 0
    fi
    log_ok "No limit marker found in $name's log."
    log_dim "(log: ${logf}${logf:+ — }looked for the confirmed RESOURCE_EXHAUSTED / Individual quota reached marker)"
    return 0
  fi

  [ -e "$logf" ] || log_fail "Nothing to watch yet at $logf — has $(target_meta_binary) run?"

  local nxt="$to"   # only an explicit --to; agy is single-account, nothing to auto-pick

  log_info "Watching $name for a dry tank: $logf"
  log_dim "$name is single-account — clikae can't summarise a brief FROM it, so on a"
  log_dim "dry tank it ALERTS you to switch rather than auto-relaying. Ctrl-C to stop."
  [ -n "$nxt" ] && log_dim "On a dry tank, switch to: $nxt"

  # tail -F (follow by NAME): agy repoints cli.log to a fresh file each run, so an
  # inode-following `tail -f` would go stale. -n0 = only lines written from now on.
  local line=""
  while IFS= read -r line; do
    printf '%s' "$line" | grep -qaE "$pattern" || continue
    echo
    log_warn "$name hit its limit — this tank is dry."
    printf '%s' "$line" | grep -aoE "$pattern" | sort -u | sed 's/^/  matched: /'
    if [ -n "$nxt" ]; then
      log_info "Switch to: $nxt  (start it with your alias / \`clikae run\`)."
    else
      log_dim "Pick a tank to switch to — open \`clikae\` or use your aliases."
    fi
    return 0
  done < <(tail -n0 -F "$logf" 2>/dev/null)
}
