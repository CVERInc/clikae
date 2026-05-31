# shellcheck shell=bash
# lib/commands/watch.sh — `clikae watch <cli> [<profile>] [--auto] [--to <t>]`
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
#   • agy/Gemini — best-guess (RESOURCE_EXHAUSTED / quota) until captured live.
# Note "session limit" (claude) vs "usage limit" (codex) — keep both.
# Caveat: these are text matches, so a transcript that merely *discusses* a limit
# (e.g. working on clikae itself) can trip them. Override anytime with --pattern /
# $CLIKAE_LIMIT_PATTERN.
_watch_default_pattern() {
  printf '%s' "You've hit your (session|usage) limit|session limit|usage limit|usage_limit|increase your usage limit|\"type\":\"turn.failed\"|rate_limit_error|rate_limited|RESOURCE_EXHAUSTED|quota exceeded|Approaching your usage|limit reached|5-hour limit|weekly limit|resets [0-9]|resets at"
}

_watch_consent_file() { printf '%s\n' "$CLIKAE_HOME/auto-relay-consent"; }
_watch_has_consent()  { [ -f "$(_watch_consent_file)" ]; }
_watch_grant_consent() {
  mkdir -p "$CLIKAE_HOME"
  : > "$(_watch_consent_file)"
}

cmd_watch() {
  local cli="" profile="" got_profile=0 to="" auto=0 check=0 pattern=""
  local -a positionals=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage: clikae watch <cli> [<profile>] [--to <target>] [--auto] [--check]
                     [--pattern <regex>]

Watch the current directory's session and, when it looks like the tank ran dry,
hand off to the next tank. By default it OFFERS (asks first); with --auto it
switches automatically after a one-time consent. The brief + handoff reuse
`clikae handoff` under the hood, so a switchable target continues on its quota.

Where it goes next:
  --to <target>   explicit target (<cli>/<profile> or a launch-only target).
  (otherwise)     the next tank down your fuel pool — see `clikae pool`.

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
  clikae watch claude                     # offer to fall through the pool
  clikae watch claude --to codex/work     # offer to switch to a specific tank
  clikae watch claude --auto              # auto-switch (after one-time consent)
  clikae watch claude --check             # would the limit pattern fire right now?
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

  [ "${#positionals[@]}" -ge 1 ] || log_fail "Missing <cli>. See: clikae watch --help"
  cli="${positionals[0]}"; validate_name cli "$cli"
  case "${#positionals[@]}" in
    1) ;;
    2) profile="${positionals[1]}"; got_profile=1 ;;
    *) log_fail "Too many arguments. Usage: clikae watch $cli [<profile>]" ;;
  esac

  [ -n "$pattern" ] || pattern="${CLIKAE_LIMIT_PATTERN:-$(_watch_default_pattern)}"

  load_adapter "$cli"
  if ! declare -F adapter_transcript_path >/dev/null; then
    log_fail "'$cli' has no transcripts clikae can watch (no adapter_transcript_path)."
  fi

  # Resolve the profile we're watching (from the env var if not named).
  if [ "$got_profile" -eq 0 ]; then
    local var strategy value
    var="$(adapter_meta_env_var)"; strategy="$(adapter_meta_strategy)"; value="${!var}"
    profile="$(resolve_active_profile "$cli" "$strategy" "$value")"
    [ -n "$profile" ] || log_fail "Couldn't tell which '$cli' profile this shell is on; name it: clikae watch $cli <profile>"
    log_dim "Watching current profile: $profile  (\$$var)"
  fi
  validate_name profile "$profile"

  local dir transcript
  dir="$(ensure_profile --require "$cli" "$profile")"
  transcript="$(adapter_transcript_path "$dir" || true)"
  [ -n "$transcript" ] || log_fail "No session for this directory under '$cli/$profile' (nothing to watch)."

  # --check: just report whether the pattern fires on the session so far.
  if [ "$check" -eq 1 ]; then
    if grep -qaE "$pattern" "$transcript"; then
      log_warn "A limit-like marker IS present in the current session."
      log_dim "(pattern: $pattern)"
      grep -aoE "$pattern" "$transcript" | sort -u | sed 's/^/  matched: /'
      return 0
    fi
    log_ok "No limit marker found in the current session."
    log_dim "(pattern: $pattern — unconfirmed; tune with --pattern / \$CLIKAE_LIMIT_PATTERN)"
    return 0
  fi

  # Resolve where we'd go on a dry tank.
  local target="$to"
  if [ -z "$target" ]; then
    target="$(pool_next "$cli/$profile")"
    [ -n "$target" ] || log_fail "No next tank: give --to <target>, or add tanks with \`clikae pool add\`."
  fi
  validate_handoff_target "$target"

  log_info "Watching $cli/$profile for a dry tank → next: $target"
  [ "$auto" -eq 1 ] && log_dim "Auto mode: will switch on detection." \
                    || log_dim "Will ask before switching (use --auto to switch automatically)."
  log_dim "Pattern is a best guess; if it never fires, see \`clikae watch --help\`. Ctrl-C to stop."

  # Tail only NEW lines; stop at the first limit-looking line.
  local line=""
  while IFS= read -r line; do
    printf '%s' "$line" | grep -qaE "$pattern" || continue
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
