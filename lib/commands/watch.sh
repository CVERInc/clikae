# shellcheck shell=bash
# lib/commands/watch.sh — `clikae watch <engine> [<tank>] [--auto] [--to <t>]`
#                          `clikae watch github [--org <o>] [--interval <d>] [--once]`
#
# Ambient relay: watch the current session's transcript and, when it looks like
# the tank ran dry, hand off to the next tank — offering first (default), or
# automatically once you've consented (--auto). Philosophy: quietly help, then
# tell you what it did.
#
# `github` is a second SOURCE under the same verb, not a parallel command
# (#46) — it watches GitHub's search API instead of a transcript, and turns a
# reply/@mention into a wake line instead of an offer to switch tanks. Its
# flag set (--org/--interval/--once) doesn't fit the engine-watching case
# above, so it's dispatched before the shared flag parser and implemented in
# lib/commands/watch_github.sh (read that file's header for the wake-event
# design — there's no `clikae go` command and no generic wake bus, so it says
# plainly what mechanism it actually uses instead of the issue's own guess).
# shellcheck source=./watch_github.sh
source "$CLIKAE_LIB/commands/watch_github.sh"
#
# ⚠️ WHAT THIS CAN AND CANNOT SEE. An interactive CLI hitting its usage limit does
# not exit, returns no code, and fires no hook — so the only signal we can watch
# is what the limit writes into the transcript. That signal IS there for claude,
# and the matcher is no longer a guess: checked on 2026-08-12 against every
# occurrence in a real user's transcripts, 283 records carry the sentence, 194 are
# genuine limit events, and the matcher fires on 194/194 while ignoring all 89
# mentions — 10 of which are ordinary model replies discussing a limit, which text
# alone would have called a dry tank. Pinned in tests/bats/limit.bats.
#
# If a vendor rewords it, or you are on an engine whose marker we do not know, the
# override is still there:
#     clikae watch claude --check         # does the pattern fire on this session?
#     CLIKAE_LIMIT_PATTERN='...' clikae watch claude

# Limit markers, CONFIRMED against real live limits (dogfooded 2026-05-31):
#   · claude — CONFIRMED, and it IS written to the transcript (so the tail catches
#       it): a real interactive limit appears as a jsonl line with
#       "isApiErrorMessage":true and text "You've hit your session limit · resets
#       <time> (<tz>)". (The TUI also shows "/upgrade to increase your usage limit.")
#   · codex  — CONFIRMED: `codex exec --json` emits `{"type":"turn.failed",...}`
#       + `{"type":"error","message":"You've hit your usage limit. … try again at
#       <date>."}` and exits non-zero.
#   · agy/Gemini — CONFIRMED: `agy -p` hitting its limit exits 0 with EMPTY
#       stdout/stderr; the marker lands ONLY in ~/.gemini/antigravity-cli/cli.log
#       as `agent executor error: RESOURCE_EXHAUSTED (code 429): Individual quota
#       reached. … Resets in <Hh Mm>.` So agy can't be detected via exit code,
#       stdout, or a transcript — you must scan that cli.log. (Earlier guess
#       "quota exceeded" was wrong; the real text is "Individual quota reached".)
#       NOTE: `clikae watch` DOES read agy's cli.log — when the watched engine is
#       agy, the watcher tails ~/.gemini/antigravity-cli/cli.log instead of the
#       transcript and matches the RESOURCE_EXHAUSTED / "Individual quota reached"
#       marker (shipped v0.5.5, covered by bats tests).
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

# --- usage polling heartbeat (#132, redirected) ----------------------------
#
# The issue as filed assumed clikae had no non-interactive way to ask a vendor
# "how much quota is left" — wrong for claude: lib/core/usage.sh's usage_read
# already calls the vendor's own OAuth usage API (adapter_usage in
# lib/adapters/claude.sh, eb58aab / #72 / #89). So this is NOT a keystroke
# prober: it never sends a single key into any pane, live or otherwise. It is
# a periodic HEARTBEAT bolted onto `clikae watch`'s existing tail loop — the
# loop already sits idle on `read <&3` between transcript lines, so a timeout
# on that same read is a free place to also refresh the usage cache, on a
# schedule, so `clikae`'s board (home.sh's usage_board_fields) has a fresher
# number to show than "whatever the last manual `clikae usage` happened to
# leave behind". Nothing here computes a percentage or talks to a vendor
# directly — usage_read remains the only thing that does either.
#
# Cadence: every tank gets its OWN next-poll time and its OWN backoff, kept in
# parallel arrays (bash 3.2 — macOS's shipped bash — has no associative
# arrays; every other per-tank memo in this codebase, e.g. home.sh's
# _FUEL_MEMO_*, uses the same shape). A tank whose last poll came back as a
# real reading (source vendor/transcript) polls again after the base interval
# (CLIKAE_WATCH_USAGE_INTERVAL, default: the usage cache's own TTL — polling
# faster than the cache refreshes buys nothing). A tank whose last poll came
# back anything else DOUBLES its own interval, capped at
# CLIKAE_WATCH_USAGE_MAX_BACKOFF (default 1800s/30min) — so a vendor outage
# does not get hammered once per loop tick forever. A success resets the tank
# straight back to the base interval. #136 carved two cases out of that
# doubling; see the next paragraph.
#
# #136 REPLACES the paragraph that used to stand here ("what this does NOT try
# to do, on purpose: distinguish a 429 from any other transport failure").
# adapter_usage now says which kind of failure it was, so this loop stops
# treating three different situations as one:
#
#   rate-limited   HTTP 429. The next poll for THAT tank is the vendor's own
#                  `Retry-After`, clamped to [base, max] — not a doubling.
#                  The LOWER clamp is not politeness, it is correctness:
#                  usage_read has its own TTL cache (default 120s = the base
#                  interval), so a poll scheduled sooner than the base would
#                  re-read the cached rate-limited reading, learn nothing, and
#                  reschedule off it forever. The upper clamp is the existing
#                  CLIKAE_WATCH_USAGE_MAX_BACKOFF. No usable Retry-After (the
#                  header absent, negative, zero, non-numeric, an HTTP-date,
#                  or past 86400 — all already dropped by the adapter) falls
#                  back to the doubling below, unchanged.
#   auth           `expired-token` or `no-credentials`. Neither will start
#                  working because we waited a little longer, so there is no
#                  ramp to climb: the tank goes STRAIGHT to the max interval
#                  and is marked, instead of walking a doubling sequence that
#                  spends calls on a question already answered. The trade,
#                  stated plainly: after a session refreshes an expired token,
#                  this loop notices up to one max interval later (30 min by
#                  default) rather than up to ~4 min. The board does not wait
#                  for it — a cached "expired" reading is shown as
#                  `⏳ expired · usage --wake <tank>` the moment it lands
#                  (#107, lib/commands/home.sh), and `clikae usage` is always
#                  a fresh read away.
#   transient      everything else (no connection, a timeout, a 5xx, an
#                  unparseable body). Doubles, capped — exactly as before.
#
# The per-tank class lands in _WATCH_USAGE_POLL_STATE, a fourth parallel array
# (bash 3.2: no associative arrays, same shape as the three beside it).
_WATCH_USAGE_POLL_TANK=(); _WATCH_USAGE_POLL_NEXT=(); _WATCH_USAGE_POLL_BACKOFF=()
_WATCH_USAGE_POLL_STATE=()

# _watch_usage_poll_interval -> the base seconds between polls of one tank.
_watch_usage_poll_interval() {
  local v="${CLIKAE_WATCH_USAGE_INTERVAL:-}"
  case "$v" in ''|*[!0-9]*) v="${CLIKAE_USAGE_TTL:-120}" ;; esac
  case "$v" in ''|*[!0-9]*) v=120 ;; esac
  [ "$v" -ge 10 ] 2>/dev/null || v=10
  printf '%s\n' "$v"
}

# _watch_usage_poll_max_backoff -> the ceiling a failing tank's interval never
# grows past (seconds).
_watch_usage_poll_max_backoff() {
  local v="${CLIKAE_WATCH_USAGE_MAX_BACKOFF:-1800}"
  case "$v" in ''|*[!0-9]*) v=1800 ;; esac
  printf '%s\n' "$v"
}

# _watch_usage_poll_indexv <cli> <tank> -> $_WUPI, its slot in the parallel
# arrays above, or -1 if this tank has never been polled by THIS process.
_watch_usage_poll_indexv() {
  local key="$1/$2" n="${#_WATCH_USAGE_POLL_TANK[@]}" i
  _WUPI=-1
  for (( i = 0; i < n; i++ )); do
    if [ "${_WATCH_USAGE_POLL_TANK[i]}" = "$key" ]; then _WUPI=$i; return 0; fi
  done
}

# _watch_usage_poll_one <cli> <tank> <now> — refresh one tank's usage cache
# via the existing usage_read (never a new vendor call site), IF this tank's
# own cadence says it's due; otherwise a no-op. usage_read has its own TTL
# cache and is safe to call every tick — this function's whole job is to also
# widen the gap between calls when a tank is failing, which usage_read's flat
# TTL alone doesn't do.
_watch_usage_poll_one() {
  local cli="$1" tank="$2" now="$3" base max idx
  base="$(_watch_usage_poll_interval)"; max="$(_watch_usage_poll_max_backoff)"
  _watch_usage_poll_indexv "$cli" "$tank"; idx="$_WUPI"
  if [ "$idx" -lt 0 ]; then
    idx="${#_WATCH_USAGE_POLL_TANK[@]}"
    _WATCH_USAGE_POLL_TANK[idx]="$cli/$tank"
    _WATCH_USAGE_POLL_NEXT[idx]=0
    _WATCH_USAGE_POLL_BACKOFF[idx]="$base"
    _WATCH_USAGE_POLL_STATE[idx]=""
  fi
  [ "$now" -ge "${_WATCH_USAGE_POLL_NEXT[idx]:-0}" ] || return 0
  local reading source reason retry facts
  reading="$(usage_read "$cli" "$tank" 2>/dev/null)"
  # One jq fork per due poll, same as before #136 — three facts out of it, not
  # three calls. @tsv on three strings always yields two tabs, so `read` fills
  # all three names even when the last two are empty.
  facts="$(printf '%s' "$reading" | jq -r '
    [(.source // ""), (.reason // ""),
     (if (.retry_after|type) == "number" then (.retry_after|floor|tostring) else "" end)]
    | @tsv' 2>/dev/null)"
  IFS=$'\t' read -r source reason retry <<< "$facts"
  local cur="${_WATCH_USAGE_POLL_BACKOFF[idx]:-$base}" delay state
  case "$source" in
    vendor|transcript)
      state=ok; cur="$base"; delay="$base" ;;
    *)
      case "$reason" in
        rate-limited)
          state=rate-limited
          case "$retry" in
            ''|*[!0-9]*|??????*)
              cur=$(( cur * 2 )); [ "$cur" -le "$max" ] || cur="$max"; delay="$cur" ;;
            *)
              delay="$retry"
              [ "$delay" -ge "$base" ] || delay="$base"
              [ "$delay" -le "$max" ] || delay="$max"
              cur="$delay" ;;
          esac ;;
        expired-token|no-credentials)
          state=auth; cur="$max"; delay="$max" ;;
        *)
          state=transient
          cur=$(( cur * 2 )); [ "$cur" -le "$max" ] || cur="$max"; delay="$cur" ;;
      esac ;;
  esac
  _WATCH_USAGE_POLL_BACKOFF[idx]="$cur"
  _WATCH_USAGE_POLL_STATE[idx]="$state"
  _WATCH_USAGE_POLL_NEXT[idx]=$(( now + delay ))
}

# _watch_usage_poll_tick — one heartbeat: refresh every KNOWN tank's usage
# cache, each on its own cadence above. Best-effort and silent: no jq, no
# tanks, or an engine with no adapter_usage just means nothing to do this
# tick, same as any other quiet redraw miss on the board side.
_watch_usage_poll_tick() {
  command -v jq >/dev/null 2>&1 || return 0
  declare -F usage_read >/dev/null || return 0
  declare -F list_all_profiles >/dev/null || return 0
  local now; now="$(date +%s 2>/dev/null || echo 0)"
  local cli tank
  while IFS=$'\t' read -r cli tank _; do
    if [ -z "$cli" ] || [ -z "$tank" ]; then continue; fi
    [ -f "$CLIKAE_LIB/adapters/$cli.sh" ] || continue
    declare -F load_adapter >/dev/null && load_adapter "$cli" 2>/dev/null
    declare -F adapter_usage >/dev/null || continue
    _watch_usage_poll_one "$cli" "$tank" "$now"
  done < <(list_all_profiles 2>/dev/null)
  return 0
}

_watch_consent_file() { printf '%s\n' "$CLIKAE_HOME/auto-relay-consent"; }
_watch_has_consent()  { [ -f "$(_watch_consent_file)" ]; }
_watch_grant_consent() {
  mkdir -p "$CLIKAE_HOME"
  : > "$(_watch_consent_file)"
}

cmd_watch() {
  # `github` is a source, not an engine — its own flag set (--org/--interval/
  # --once) doesn't fit the loop below, so hand off before any of it runs.
  # Mirrors clikae_is_target's "target-ness wins" precedence check further
  # down: a keyword this command itself defines is resolved before ever
  # treating the first argument as an engine name.
  if [ "${1:-}" = "github" ]; then
    shift
    cmd_watch_github "$@"
    return $?
  fi

  local cli="" profile="" got_profile=0 to="" auto=0 check=0 pattern="" pattern_explicit=0
  local -a positionals=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage: clikae watch <engine> [<tank>] [--to <target>] [--auto] [--check]
                     [--pattern <regex>]
       clikae watch github [--org <org>] [--interval <dur>] [--once]

A different source: `clikae watch github` polls GitHub's search API for
replies/@mentions instead of watching a tank's transcript. See:
  clikae watch github --help

Watch the current directory's session and, when it looks like the tank ran dry,
hand off to the next tank. By default it OFFERS (asks first); with --auto it
switches automatically after a one-time consent. The brief + handoff reuse
`clikae handoff` under the hood, so a switchable target continues on its quota.

Where it goes next:
  --to <target>   explicit target (<engine>/<tank> or a launch-only target).
  (otherwise)     the next fuelled tank in your burn order — same-engine first (a
                  real resume), then a cross-engine cold brief if every same-engine
                  tank is dry. Your tanks ARE the reserve; nothing to configure.

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

  # Launch-only targets (single-account vendors like antigravity) have no per-dir
  # transcript — their only limit signal is a log file. If <engine> resolves to
  # such a target, watch that log instead of an adapter transcript. (Target-ness
  # wins over a resume-only adapter file — see clikae_is_target.)
  if clikae_is_target "$cli"; then
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

  # --check: report whether a GENUINE limit marker fires in the session's recent
  # tail. Line-by-line via the structured matcher, so a transcript that merely
  # discusses a limit (the old whole-file grep's classic false positive) no longer
  # trips it. BOUNDED to transcript_tail, never the whole file: reading a 100+ MB
  # transcript line-by-line in bash took tens of seconds, and the question --check
  # answers — "is this session limited NOW?" — is decided by the newest marker
  # anyway (the same tail-slice rule every other limit reader follows; see
  # profile_store.sh's bounded-reads kernel).
  if [ "$check" -eq 1 ]; then
    local found=0 line sid
    sid="${transcript##*/}"; sid="${sid%.jsonl}"
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
    done <<EOF
$(transcript_tail "$transcript")
EOF
    if [ "$found" -eq 0 ]; then
      log_pass "No genuine limit marker found in the current session's recent tail."
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
  #
  # 🔴 The tail is read on fd 3, NOT stdin. This loop's body asks the user
  # questions — wake_offer's one-time "resume automatically?", _watch_do_handoff's
  # "switch now?" / auto-consent — via confirm(), which reads STDIN. If the tail
  # fed stdin (the naive `done < <(tail …)`), every one of those prompts would read
  # its answer off the NEXT TRANSCRIPT LINE instead of the keyboard, and the
  # `exec clikae handoff` would hand the tail pipe to the started engine as its
  # stdin. Keeping the tail on fd 3 leaves stdin as the terminal for all of them.
  # #132: the tail loop already sits idle on this read between transcript
  # lines — a timeout on the SAME read is where the usage-polling heartbeat
  # (above) gets its cadence, no separate timer/process needed. `read -t`
  # returns a status > 128 on a timeout specifically (bash's own contract,
  # not a heuristic) — never on the pipe closing (that's a plain nonzero
  # <=128, handled the same way this loop always handled EOF: fall out).
  local line="" _poll_interval _rc
  _poll_interval="$(_watch_usage_poll_interval)"
  while :; do
    IFS= read -r -t "$_poll_interval" line <&3; _rc=$?
    if [ "$_rc" -gt 128 ]; then
      _watch_usage_poll_tick
      continue
    fi
    [ "$_rc" -eq 0 ] || break
    # BETA: relay the vendor's verbatim weekly-usage % to the board's yellow dot,
    # independent of the dry trigger below (a weekly warning is caution, not dry).
    _watch_weekly_capture "$cli" "$profile" "$line"
    limit_line_is_real "$cli" "$line" "$pattern" "$pattern_explicit" || continue
    echo
    log_warn "Looks like $cli/$profile hit its limit."
    # Offered BEFORE the handoff, because the two are not alternatives: carrying
    # on elsewhere now and having this tank pick itself back up later are both
    # things you want. Silently does nothing when there is no tmux session to
    # type into — which is the honest answer, not a failure worth a message.
    wake_offer "$cli" "$profile" "$(limit_reset_phrase "$line")"
    _watch_do_handoff "$cli" "$profile" "$target" "$auto"
    # _watch_do_handoff execs on success; if it returns, the user declined.
    log_dim "Staying on $cli/$profile. Still watching… (Ctrl-C to stop)"
  done 3< <(tail -n0 -f "$transcript")
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
    log_done "Auto-switching: $cli/$profile → $target"
  else
    confirm "Switch $cli/$profile → $target now?" || return 1
    log_done "Switching: $cli/$profile → $target"
  fi

  # Close the watcher's tail-pipe fd (open in the caller's loop) so the engine we
  # exec into doesn't inherit it as an extra open descriptor.
  { exec 3<&-; } 2>/dev/null || true
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
    log_pass "No limit marker found in $name's log."
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
