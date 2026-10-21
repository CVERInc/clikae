# shellcheck shell=bash
# Shared, atomic usage cache. Only normalized public readings reach disk.
# P3-5 (round-6 review), #107 and #179: a reading with no numbers may carry a
# `reason`. SEVEN values, and nothing else is ever emitted or cached:
#   needs-refresh   the access token is past its expiry (by the vendor's 401/
#                   403, or by the credentials' own recorded expiry) AND a
#                   refresh token is beside it. The login is fine; the token
#                   needs the refresh a session does. A reader that is ALLOWED
#                   to spend does that refresh itself before it ever prints
#                   this word (see `usage_read` below, and #177): this reason
#                   only reaches disk from a reader that may not spend (the
#                   board's refresh-on-open, a live session's wake window,
#                   burn's ranking) or whose refresh was refused by burn's own
#                   gates (the recorded cockpit, a running burn). It is never
#                   "this tank cannot be used".
#   relogin-required the refresh was ATTEMPTED — the engine ran one trivial
#                   prompt — and the vendor still refused the token. Only
#                   this needs a person (`clikae claude <tank>`, then /login).
#                   #177: the two words exist so that "needs a session" and
#                   "needs a person" can never look alike again; the old
#                   single word `expired` is retired.
#   keychain-denied the Keychain read itself was REFUSED (macOS: no ACL for
#                   this process, interaction not allowed, a locked keychain
#                   — exactly what a tmux-hosted wake window gets). Nothing is
#                   known about the login either way, so this reason NEVER
#                   overwrites a cache that holds numbers: `usage_read` serves
#                   the last reading, with its age, and writes nothing.
#   no-credentials  no usable token was found at all (no credentials file, no
#                   Keychain entry, one that does not parse), or the vendor
#                   refused one that has no refresh token to renew it with.
#   network         the call did not complete usably for a transport or
#                   server reason: no connection, a timeout, a 5xx. Up to
#                   #136 this also swallowed every 429.
#   rate-limited    (#136) HTTP 429. May carry ONE more key, `retry_after`:
#                   the vendor's own `Retry-After` header, and only when it
#                   was delta-seconds in 1..86400 — absent for a missing,
#                   negative, zero, non-numeric, HTTP-date or out-of-range
#                   header, so a caller that sees the key can trust it
#                   without re-validating, and one that does not see it falls
#                   back to its own backoff.
#   unparseable     the call answered 200 and the body was not one usable
#                   reading (malformed, several documents, over the byte cap).
# The key is ABSENT (not null) when the reason is unknown, and absent on
# every vendor/transcript reading, so no existing output shape moves — with
# one public exception: a keychain-denied read that is serving the LAST
# reading carries `reason:"keychain-denied"` beside those numbers, so the
# caller knows the numbers are old and why (that shape is public only; the
# cache file is untouched).
#
# THE AUTH CLASS IS TWO WORDS, NOT ONE. #136 asked for a single `reauth`;
# `relogin-required` and `no-credentials` are that class, split by the one
# fact that changes the remedy (is there a refresh token?). A caller that
# wants "this will never succeed on its own" asks for either word — see
# lib/commands/watch.sh's `_watch_usage_poll_one`. `needs-refresh` is NOT in
# that class: a session (or the next `clikae usage`) clears it.
#
# #179: the two human labels for the two quotas, defined ONCE. The board, the
# tmux status row and `clikae usage`'s summary all print these; the JSON
# keys stay `window_pct` / `weekly_pct` (a contract, not a label). chodaict
# 2026-10-18 chose the vendor's own durations over abstract words — change
# them here, together, if the vendor's windows ever change.
# shellcheck disable=SC2034  # read by home.sh, tmux.sh, limit.sh, usage.sh
USAGE_LABEL_WINDOW="5h"
# shellcheck disable=SC2034
USAGE_LABEL_WEEKLY="7d"

# #177: may THIS reader refresh an expired token by running the engine for
# one trivial prompt (through `clikae burn`, the same way `--wake` does)? On
# by default — `clikae usage` and `clikae watch` are a person or a cockpit
# asking, and an eleven-second refresh is cheaper than a wrong reroute. A
# reader that must never spend quota sets CLIKAE_USAGE_AUTO_WAKE=0: the
# board's refresh-on-open (home.sh), a live session's own wake window
# (wake.sh — the session IS the refresh), burn's run-end and reroute-ranking
# reads (burn.sh — the burn is the session). The wake child inherits 0 so a
# refresh can never recurse into another refresh.
_usage_auto_wake_allowed() {
  case "${CLIKAE_USAGE_AUTO_WAKE:-1}" in 0|off|no|false) return 1 ;; esac
  [ -n "${CLIKAE_BIN:-}" ] && [ -x "${CLIKAE_BIN:-}" ] || return 1
  return 0
}

# #107: the ceiling on a wake's one-prompt burn, whole seconds. Passed to
# burn's own --timeout, so it bounds the engine run the way every other burn
# is bounded (timeout/gtimeout/perl, or an honest warning with none of them).
_USAGE_WAKE_TIMEOUT_SEC=60

# usage_wake_burn <engine> <tank> [force_cockpit] -> rc of the burn.
# Refresh a tank's token the only way clikae knows how without touching the
# vendor's OAuth flow itself: run the engine headless for one trivial prompt,
# through `clikae burn` — the same process, the same cockpit gate, the same
# running-burn lock and tmux session. A child process, not cmd_burn in this
# shell: burn owns fd 1/2 redirection, EXIT traps and `exit`, none of which
# may leak into the caller. Burn's own words (progress, refusals) go to
# stderr; stdout is left alone for the reading. Used by `clikae usage --wake`
# and by usage_read's own refresh-before-measure (#177).
usage_wake_burn() {
  local e="$1" t="$2" force="${3:-0}" work rc=0 fc="" skip_git=""
  [ "$force" != 1 ] || fc=--force-cockpit
  [ "$e" != codex ] || skip_git=--codex-skip-git-check
  work="$(mktemp -d "${TMPDIR:-/tmp}/clikae-wake.XXXXXX")" || { log_err "wake: could not create a temp directory"; return 1; }
  # The artifact is the proof the engine actually answered. The prompt names
  # it verbatim; nothing else is asked for.
  CLIKAE_USAGE_AUTO_WAKE=0 "$CLIKAE_BIN" burn "$e" "$t" --no-reroute --infra-retries 0 \
    --timeout "$_USAGE_WAKE_TIMEOUT_SEC" \
    --artifact "$work/wake-ok" --add-dir "$work" \
    --prompt "Write the single word ok into the file $work/wake-ok and do nothing else." \
    ${skip_git:+"$skip_git"} ${fc:+"$fc"} 1>&2 || rc=$?
  rm -rf "$work"
  return "$rc"
}
#
# #137: a VENDOR reading may carry one extra key, `models` — an array of
# `{name, pct, resets_at}`, the vendor's own per-model weekly rows. Read by
# `clikae usage` only; no ranking, dot or backoff looks at it. See
# lib/adapters/claude.sh's `adapter_usage` for where it comes from and
# docs/usage.md for why the board's dot stays all-models.
#
# #107: an auth failure is cached for at most _USAGE_AUTH_FAIL_TTL_SEC, not
# the full CLIKAE_USAGE_TTL — the next read after a session refreshes the
# token must see the fresh number, not a minute-old "expired".
_USAGE_AUTH_FAIL_TTL_SEC=60

# usage_auth_hintv <engine> <tank> <reason> -> $_UEH, the one line a person
# reads next to a reading with no numbers for an auth reason (`clikae usage`
# text, the board's note). The words are the remedy, not a diagnosis. Empty
# for any other reason. A `…v` setter so the board's redraw pays no subshell.
usage_auth_hintv() {
  case "${3:-}" in
    needs-refresh)    _UEH="token lapsed, not the login — a session refreshes it, or 'clikae usage $1 --wake $2'" ;;
    relogin-required) _UEH="refresh failed — relogin: 'clikae $1 $2', then /login" ;;
    keychain-denied)  _UEH="this process may not read the Keychain — showing the last reading; 'clikae usage $1 $2' from a terminal reads it" ;;
    *) _UEH="" ;;
  esac
}
# usage_unknown [reason] [retry_after]
# $2 is honoured for `rate-limited` only, and only as an integer in 1..86400
# — same bound, same digit-count guard against arithmetic overflow, as the
# adapter's own `_claude_usage_rate_limited`. Two gates on purpose: the
# adapter is one of several possible producers, this is the only writer.
usage_unknown() {
  local _u_retry=""
  case "${2:-}" in
    ''|*[!0-9]*|??????*) ;;
    *) if [ "$2" -ge 1 ] && [ "$2" -le 86400 ]; then _u_retry=",\"retry_after\":$2"; fi ;;
  esac
  case "${1:-}" in
    rate-limited)
      printf '{"window_pct":null,"weekly_pct":null,"window_resets_at":null,"weekly_resets_at":null,"source":"unknown","reason":"rate-limited"%s}\n' "$_u_retry" ;;
    needs-refresh|relogin-required|keychain-denied|no-credentials|network|unparseable)
      printf '{"window_pct":null,"weekly_pct":null,"window_resets_at":null,"weekly_resets_at":null,"source":"unknown","reason":"%s"}\n' "$1" ;;
    *)
      printf '%s\n' '{"window_pct":null,"weekly_pct":null,"window_resets_at":null,"weekly_resets_at":null,"source":"unknown"}' ;;
  esac
}

# _USAGE_NUMERIC_RECORD_JQ — a cache record that is a usable last reading: an
# object from a live source, stamped, with at least one percentage and none
# out of range. The Keychain fallback below serves ONLY this; anything else on
# disk (a retired `source:"expired"` record, a failure record, a malformed
# file) is not a reading to stand on.
_USAGE_NUMERIC_RECORD_JQ='type == "object"
  and (.source == "vendor" or .source == "transcript" or .source == "quota-api")
  and (.cached_at|type) == "number"
  and ([.window_pct, .weekly_pct] | any(type == "number"))
  and ([.window_pct, .weekly_pct] | all(. == null or (type == "number" and . >= 0 and . <= 100)))'

usage_read() (
  local engine="$1" tank="$2" fresh="${3:-0}" cache now ttl reading tmp
  local adapter_out="" adapter_reason="" adapter_retry="" measured_at="" measured_seen="" can_wake=0 wake_rc
  _usage_auto_wake_allowed && can_wake=1
  cache="$CLIKAE_HOME/state/usage/$engine/$tank.json"
  now="$(date +%s)"; ttl="${CLIKAE_USAGE_TTL:-120}"
  case "$ttl" in ''|*[!0-9]*) ttl=120 ;; esac
  command -v jq >/dev/null 2>&1 || { usage_unknown; return; }
  # P3 (round-2 review, "codex reading gets a TTL like claude's"): the
  # cache-hit check below used to key off `cached_at` alone — fine for a
  # vendor reading (cached_at IS the fetch time) but wrong for codex's
  # transcript readings, whose `cached_at` is the EVENT's own timestamp
  # (P2-4, round-1 review — deliberate, so a stale reading is never lied
  # about as fresh). Since codex only writes a token_count event
  # occasionally, `cached_at` is almost always older than $ttl, so this
  # check never hit and `clikae usage codex` re-scanned the ENTIRE rollout
  # store on every call (measured: 85ms/82ms back-to-back, zero cache hits).
  # `scanned_at` is the wall-clock time of the last actual scan, separate
  # from the reading's own evidentiary timestamp — that's what a cache-hit
  # check should mean, the same thing it already means for a vendor read
  # (where the two coincide). `// .cached_at` falls back for any cache file
  # written before this field existed.
  # #107: an auth-failure reading gets the shorter of the two TTLs.
  # #179: a cache written by a previous version with source:"expired" is the
  # retired word — it is read as "unknown, refresh first" and never served.
  # #177 (review of #184, finding 2): a cached `needs-refresh` is never the
  # FINAL answer for a reader that may refresh it. It was most likely written
  # by one that may not (the board, a wake window, burn's ranking) — serving
  # it here would print the failure without attempting the refresh this
  # reader exists to do. Readers that may not spend still hit it as before.
  if [ "$fresh" != 1 ] && [ -f "$cache" ] &&
     jq -e --argjson now "$now" --argjson ttl "$ttl" --argjson authttl "$_USAGE_AUTH_FAIL_TTL_SEC" --argjson canwake "$can_wake" \
       '(.scanned_at // .cached_at) as $s
        | (if (.reason == "needs-refresh" or .reason == "relogin-required") and $authttl < $ttl then $authttl else $ttl end) as $t
        | .source != "expired" and $s <= $now and ($now - $s < $t)
          and (.reason != "needs-refresh" or $canwake == 0)' "$cache" >/dev/null 2>&1; then
    _usage_public "$engine" "$tank" "$now" < "$cache"; return
  fi
  reading=""
  if [ -f "$CLIKAE_LIB/adapters/$engine.sh" ]; then
    load_adapter "$engine"
    if declare -F adapter_usage >/dev/null; then
      _usage_adapter_call "$engine" "$tank"
      # #177: REFRESH BEFORE MEASURE. The access token is past its expiry and
      # a refresh token sits beside it — the one state that used to be printed
      # as the terminal word `expired`. Run the engine for one trivial prompt
      # (the same burn `--wake` runs; its cockpit gate and running-burn lock
      # apply unchanged), then ask again. Only a refresh that RAN and still
      # left the vendor refusing is `relogin-required`; a refresh that could
      # not run (gated, no engine, timed out) leaves `needs-refresh`, which
      # says what it is: stale, not broken.
      # Review of #184, finding 1: the burn's exit code says whether the
      # BURN worked (engine answered, artifact written), not whether the
      # CREDENTIALS were renewed — a run that renewed them can still end in a
      # limit (rc 2) or a missing artifact, and a refusal because another
      # burn holds the tank (rc 1/2) is usually that other burn renewing
      # them. So every wake, whatever its rc, is followed by one more
      # measurement — never by a second wake — and only that measurement
      # decides. The pre-wake `needs-refresh` is never published as is.
      if [ "$adapter_reason" = needs-refresh ] && [ "$can_wake" = 1 ]; then
        # stderr: this function's stdout IS the reading, captured by callers.
        declare -F log_info >/dev/null && log_info "$engine/$tank: access token lapsed — refreshing it (one trivial prompt, ≤${_USAGE_WAKE_TIMEOUT_SEC}s)" >&2
        wake_rc=0
        usage_wake_burn "$engine" "$tank" || wake_rc=$?
        _usage_adapter_call "$engine" "$tank"
        if [ "$adapter_reason" = needs-refresh ]; then
          if [ "$wake_rc" = 0 ]; then
            adapter_reason=relogin-required
          else
            declare -F log_warn >/dev/null && log_warn "$engine/$tank: the refresh did not complete (burn rc $wake_rc) and the token still reads lapsed — reading stays needs-refresh (a session on the tank refreshes it)"
          fi
        fi
      elif [ "$adapter_reason" = needs-refresh ] && [ "${_CLIKAE_USAGE_AFTER_WAKE:-0}" = 1 ]; then
        # `clikae usage --wake` re-reading after ITS burn completed: the
        # engine ran and the vendor still refuses — this is the failed case.
        adapter_reason=relogin-required
      fi
      # The Keychain read was refused, not empty: nothing is known about the
      # login either way, so the last reading stands, with its age, and the
      # cache is NOT touched (a tmux-hosted wake window on a Mac gets this
      # every five minutes; it must not launder the numbers into
      # no-credentials — the finding on #179).
      # Review of #184, finding 3: "the cache file exists" is not "the cache
      # holds a reading". Only a record that passes _USAGE_NUMERIC_RECORD_JQ
      # is served (with its own cached_at, so its own age). Anything else —
      # a retired `source:"expired"` record, a failure record, a malformed
      # file — falls through to the ordinary finish, which writes
      # unknown/keychain-denied and carries any last_good forward.
      if [ "$adapter_reason" = keychain-denied ] && [ -f "$cache" ] &&
         jq -e "$_USAGE_NUMERIC_RECORD_JQ" "$cache" >/dev/null 2>&1; then
        jq -c '. + {reason:"keychain-denied"}' "$cache" 2>/dev/null | _usage_public "$engine" "$tank" "$now"
        return
      fi
    fi
  fi
  _usage_read_finish "$engine" "$tank" "$cache" "$now"
)

# _usage_adapter_call <engine> <tank> — one adapter_usage call, into the
# caller's `reading` / `adapter_reason` / `adapter_retry` (bash dynamic scope;
# only usage_read calls this). Split out so #177's refresh-then-ask-again is
# the same code path as the first ask.
_usage_adapter_call() {
  local engine="$1" tank="$2" adapter_out=""
  reading=""; adapter_reason=""; adapter_retry=""
  # When this measurement started (the reading's evidentiary time), and the
  # record on disk at that moment: _usage_read_finish uses both to tell a
  # record another reader published while this one was in flight from one
  # that was already there.
  measured_seen="$(cat "$cache" 2>/dev/null)" || measured_seen=""
  measured_at="$(date +%s)"
      # P3-3 (codex security review, round-5): this used to be `2>/dev/null`,
      # which hid EVERY adapter's own diagnostics from the public `clikae
      # usage` path — including claude.sh's honest "running WITHOUT a time
      # bound" warning (lib/core/timeout_bin.sh) when a Keychain read can't
      # be bounded (no timeout/gtimeout/perl on PATH), silently leaving an
      # unbounded, possibly-hanging read with no way for anyone to know why.
      # Every adapter_usage implementation already redirects its OWN
      # vendor-body/secret-bearing subcalls internally (curl, jq, `security`
      # all pipe through their own `2>/dev/null` above this call) — nothing
      # but that kind of safe diagnostic ever reaches this level to leak.
      # P3-5 (round-6 review): a FAILED adapter_usage still gets its stdout
      # looked at — but only ever through the enum below, never as a
      # reading. "Never cache a vendor error body" (the whitelist further
      # down) stays exactly as strict: at most one of three fixed words
      # survives this, and anything else is discarded with the body.
      if adapter_out="$(adapter_usage "$(profile_dir "$engine" "$tank")")"; then
        reading="$adapter_out"
      else
        reading=""
        adapter_reason="$(printf '%s' "$adapter_out" | jq -r '
          if .reason == "needs-refresh" or .reason == "keychain-denied"
             or .reason == "no-credentials"
             or .reason == "network" or .reason == "unparseable"
             or .reason == "rate-limited"
          then .reason else empty end' 2>/dev/null)"
        # #136: the ONE extra fact a failed call may carry out. Read only for
        # the reason that defines it, and only as a whole number of seconds —
        # `usage_unknown` re-checks the range anyway (a producer is not the
        # writer), but a non-integer must not reach it as `30.5`.
        if [ "$adapter_reason" = rate-limited ]; then
          adapter_retry="$(printf '%s' "$adapter_out" | jq -r '
            if (.retry_after|type) == "number" and .retry_after >= 1
               and .retry_after <= 86400 and (.retry_after|floor) == .retry_after
            then (.retry_after|tostring) else empty end' 2>/dev/null)"
        fi
      fi
}

# _usage_read_finish <engine> <tank> <cache> <now> — whitelist the reading in
# the caller's `reading` (plus `adapter_reason` / `adapter_retry`), carry the
# last good numbers forward, write the cache atomically, print the public
# form. The tail of usage_read, in its own function only so the refresh
# branch above can `return` early without duplicating it.
_usage_read_finish() {
  local engine="$1" tank="$2" cache="$3" now="$4" tmp
  [ -n "$reading" ] || reading="$(usage_unknown "$adapter_reason" "$adapter_retry")"
  # P2-4 (round-1 review): a reading can be honest evidence without a LIVE
  # vendor call behind it (codex's is derived from a rollout transcript it
  # already wrote) — pull out the event's own timestamp BEFORE whitelisting
  # discards it, so the cache can be stamped with when the reading actually
  # happened, not "now". Only trusted for source:"transcript"; a vendor
  # reading's cached_at is always the fetch time (the two coincide there).
  local event_epoch=""
  event_epoch="$(printf '%s' "$reading" | jq -r '
    if .source == "transcript" and (.event_epoch|type) == "number"
    then .event_epoch else empty end' 2>/dev/null)"
  # Whitelist fields: never cache a vendor error body or credentials.
  reading="$(printf '%s' "$reading" | jq -ce '
    def pct: if type == "number" and . >= 0 and . <= 100 then . else null end;
    def stamp: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9]{2}:[0-9]{2})$") then . else null end;
    (if .reason == "needs-refresh" or .reason == "relogin-required"
        or .reason == "keychain-denied" or .reason == "no-credentials"
        or .reason == "network" or .reason == "unparseable" or .reason == "rate-limited"
     then .reason else null end) as $reason |
    # #136: `retry_after` exists only beside `rate-limited`, only as a whole
    # number of seconds in 1..86400. Anything else is dropped here, so a
    # reader that finds the key never has to re-validate it.
    (if .reason == "rate-limited" and (.retry_after|type) == "number"
        and .retry_after >= 1 and .retry_after <= 86400
        and (.retry_after|floor) == .retry_after
     then (.retry_after|floor) else null end) as $retry |
    # #137: the per-model weekly rows, whitelisted field by field
    # like everything else that reaches this cache — a bounded array of
    # at most 8 `{name, pct, resets_at}` with a name of at most 40 characters,
    # a percentage in 0..100 and a timestamp of the one shape `stamp` accepts.
    # Never carried on a non-vendor reading.
    (if (.models|type) == "array" then
       [ .models[] | select(type == "object") |
         {name: .name, pct: .pct, resets_at: (.resets_at|stamp)} |
         select((.name|type) == "string" and (.name|length) > 0 and (.name|length) <= 40) |
         select((.pct|type) == "number" and .pct >= 0 and .pct <= 100) ] | .[0:8]
     else [] end) as $models |
    # #151: agy quota groups, each its own quota, whitelisted like $models.
    def gname: if type == "string" and test("^[a-z0-9_]{1,20}$") then . else null end;
    (if .source == "quota-api" and (.groups|type) == "array" then
       [ .groups[] | select(type == "object") |
         {name: (.name|gname), window_pct: (.window_pct|pct), weekly_pct: (.weekly_pct|pct),
          window_resets_at: (.window_resets_at|stamp), weekly_resets_at: (.weekly_resets_at|stamp),
          disabled: (.disabled == true)} | select(.name != null) ] | .[0:8]
     else [] end) as $groups |
    (.headline_group | gname) as $head |
    # #179: an auth reason never carries a number — whatever else an adapter
    # put beside it is dropped here (the same rule #107 gave `expired`).
    if $reason == "needs-refresh" or $reason == "relogin-required" or $reason == "keychain-denied" then
      {window_pct:null,weekly_pct:null,window_resets_at:null,weekly_resets_at:null,
       source:"unknown",reason:$reason}
    else
    {window_pct:(.window_pct|pct),weekly_pct:(.weekly_pct|pct),
     window_resets_at:(.window_resets_at|stamp),weekly_resets_at:(.weekly_resets_at|stamp),
     source:(if .source == "vendor" or .source == "transcript" or .source == "quota-api" then .source else "unknown" end)} |
    if .source == "unknown" and $reason != null then . + {reason:$reason} else . end |
    if .source == "unknown" and $reason == "rate-limited" and $retry != null
    then . + {retry_after:$retry} else . end |
    if (.source == "vendor" or .source == "quota-api") and ($models|length) > 0 then . + {models:$models} else . end |
    if .source == "quota-api" and ($groups|length) > 0 then
      . + {groups:$groups} + (if $head != null then {headline_group:$head} else {} end)
    else . end
    end')" || { reading="$(usage_unknown)"; event_epoch=""; }
  # #149: a reading with no numbers never overwrites the last one that had
  # them. The previous cache's numbers (or the `last_good` it already carried
  # forward) ride along as `last_good: {window_pct, weekly_pct, at}`, `at`
  # being that reading's own `cached_at` — so `clikae usage` and the board
  # can print "weekly 85%, 5h ago" beside the reason instead of a blank.
  # Review of #184, finding 1: the reading is stamped with when its
  # measurement STARTED, not when this read began (a read that waited out a
  # wake is minutes older than its measurement), and it is published only if
  # nothing NEWER reached the cache while it was in flight. Two readers that
  # both found a lapsed token: A refreshes and publishes the vendor's numbers;
  # B, whose measurement predates A's refresh, must not then bury them under
  # its obsolete `needs-refresh`. Compare-and-write runs under a short lock so
  # the comparison is still true at the rename. Only a record that APPEARED
  # during this measurement can outrank it (one already on disk when the
  # measurement started is older by construction, whatever its stamp says —
  # so a future stamp from clock skew or a copied cache never pins the file),
  # and then only if its stamp is not behind this one's. Stamps are whole
  # seconds: on a tie, a reading with numbers beats one without.
  local stamp="${measured_at:-$now}" prev="{}" record locked=0 appeared=false
  # Before the lock: taking it may be what creates the cache directory, and
  # that directory is private like every file written into it.
  umask 077
  _usage_cache_lock "$cache" && locked=1
  now="$(date +%s)"
  if [ -n "$measured_at" ] && [ -f "$cache" ] && [ "$(cat "$cache" 2>/dev/null)" != "$measured_seen" ]; then
    appeared=true
  fi
  [ -f "$cache" ] && prev="$(jq -c 'if type == "object" then . else {} end' "$cache" 2>/dev/null)"
  [ -n "$prev" ] || prev="{}"
  if [ "$appeared" = true ] &&
     printf '%s' "$reading" | jq -e --argjson prev "$prev" --argjson stamp "$stamp" --argjson now "$now" '
       def has_pct: (.window_pct|type) == "number" or (.weekly_pct|type) == "number";
       ($prev.scanned_at // $prev.cached_at) as $s
       | ($s|type) == "number" and $s <= $now
         and ($prev.source == "vendor" or $prev.source == "transcript"
              or $prev.source == "quota-api" or $prev.source == "unknown")
         and ($s > $stamp or ($s == $stamp and ($prev|has_pct) and (has_pct|not)))' >/dev/null 2>&1; then
    [ "$locked" = 0 ] || _usage_cache_unlock "$cache"
    printf '%s\n' "$prev" | _usage_public "$engine" "$tank" "$now"
    return
  fi
  record="$(printf '%s' "$reading" | jq -c --argjson now "$stamp" --arg ev "$event_epoch" --argjson prev "$prev" '
    def num: type == "number";
    . + {cached_at:(if $ev == "" then $now else ($ev|tonumber) end), scanned_at:$now} |
    if (.window_pct == null and .weekly_pct == null) then
      (if (($prev.window_pct|num) or ($prev.weekly_pct|num)) and ($prev.cached_at|num)
       then {window_pct:$prev.window_pct, weekly_pct:$prev.weekly_pct, at:$prev.cached_at}
       elif ($prev.last_good|type) == "object" then $prev.last_good
       else null end) as $lg |
      if $lg != null then . + {last_good:$lg} else . end
    else . end' 2>/dev/null)" || record=""
  if [ "$locked" = 0 ]; then
    # Review of #184 r3: no lock, no write. Another reader is still
    # publishing (or the directory is unwritable), and a comparison made
    # outside the lock may be false by the rename. This caller still gets its
    # answer (the comparison above only ever READ the cache); the next read
    # publishes again.
    declare -F log_warn >/dev/null && log_warn "$engine/$tank: usage cache not updated — ${_USAGE_LOCK_HOLDER:+another clikae (pid $_USAGE_LOCK_HOLDER) is still writing it}${_USAGE_LOCK_HOLDER:-its lock could not be taken}; this reading is returned, not cached"
  elif [ -n "$record" ] && mkdir -p "${cache%/*}" && tmp="$(mktemp "$cache.XXXXXX")"; then
    if printf '%s\n' "$record" > "$tmp"; then
      mv -f "$tmp" "$cache"
    else rm -f "$tmp"; fi
  fi
  [ "$locked" = 0 ] || _usage_cache_unlock "$cache"
  if [ -n "$record" ]; then
    printf '%s\n' "$record" | _usage_public "$engine" "$tank" "$now"
  else
    printf '%s\n' "$reading"
  fi
}

# _usage_cache_lock <cache> — take `<cache>.lck` for _usage_read_finish's
# compare-and-write; 0 = held (release with _usage_cache_unlock), 1 = not.
# Review of #184 r3: round 2's mkdir lock was reaped by AGE (> 10 s) and a
# waiter that gave up after ~3 s wrote anyway, so a holder merely slow
# between its comparison and its rename — alive the whole time — put its
# older failure back over the waiter's fresh numbers. Same rule as the tmux
# record lock (#181): the lock is a symlink made by `ln -s`, atomic WITH its
# content, naming its holder `pid|start time|token`. A live holder keeps it
# however old it is; after ~3 s a waiter takes it only from a holder proven
# gone (pid dead, or a different process on that pid). A waiter that still
# cannot get it returns 1 and the caller SKIPS publication — never an
# unlocked write.
# Review of #184 r4: a lock is never PUT BACK. Round 3 renamed the judged lock
# aside and restored whatever it had moved if that was not the one it judged —
# but the holder it moved may have finished meanwhile, found no lock to
# release, and lived on (a watcher): the restored lock named a live process
# that held nothing, and every later writer timed out for that process's
# lifetime. Now the waiter re-reads the lock and takes it away only while it
# still names the exact owner judged dead; anything else is left alone and this
# write is skipped. If another stealer replaced it inside that narrow window,
# the displaced lock is dropped, not restored — the accepted cost is a rare
# lost cache update (two writers overlap once), which the next measurement
# repairs; a lock nobody holds would never be repaired.
_usage_cache_lock() {
  local lock="$1.lck" i=0 again=0 owner held priv
  _USAGE_LOCK_HOLDER=""
  mkdir -p "${1%/*}" 2>/dev/null || return 1
  # The pid is the process that HOLDS the lock: in a subshell $$ is the parent
  # (often a long-lived watcher), so a dead subshell's lock would look alive
  # for as long as the watcher runs. $BASHPID is bash 4+; on 3.2 a fresh sh's
  # $PPID is this (sub)shell — `exec` makes the sh the `$(…)` child itself
  # (measured: without it, a redirection on the line costs the implicit exec
  # and $PPID names that child instead). The token (a fresh unique name) tells
  # siblings apart on release.
  _USAGE_LOCK_ME="${BASHPID:-}"
  [ -n "$_USAGE_LOCK_ME" ] || _USAGE_LOCK_ME="$(exec sh -c 'echo $PPID')"
  case "$_USAGE_LOCK_ME" in ''|*[!0-9]*) _USAGE_LOCK_ME=$$ ;; esac
  priv="$(mktemp -u "$1.XXXXXX" 2>/dev/null)" || priv="$1.$_USAGE_LOCK_ME.$i"
  _USAGE_LOCK_ME="$_USAGE_LOCK_ME|$(_usage_proc_lstart "$_USAGE_LOCK_ME")|${priv##*/}"
  while ! ln -s "$_USAGE_LOCK_ME" "$lock" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 30 ]; then
      owner="$(readlink "$lock" 2>/dev/null)" || owner=""
      if [ "$again" = 0 ] && ! _usage_lock_holder_alive "$owner"; then
        # Judged dead — take it away only while it still names that owner.
        held="$(readlink "$lock" 2>/dev/null)" || held=""
        if [ "$held" != "$owner" ]; then
          _USAGE_LOCK_HOLDER="${held%%|*}"
          return 1
        fi
        if mv "$lock" "$priv.stale" 2>/dev/null; then
          held="$(readlink "$priv.stale" 2>/dev/null)" || held=""
          rm -f "$priv.stale" 2>/dev/null
          if [ "$held" != "$owner" ]; then
            _USAGE_LOCK_HOLDER="${held%%|*}"
            return 1
          fi
        fi
        again=1; i=0
        continue
      fi
      _USAGE_LOCK_HOLDER="${owner%%|*}"
      return 1
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
}

# _usage_cache_unlock <cache> — remove `<cache>.lck` only while it names us.
_usage_cache_unlock() {
  [ "$(readlink "$1.lck" 2>/dev/null)" != "$_USAGE_LOCK_ME" ] || rm -f "$1.lck" 2>/dev/null
}

# _usage_lock_holder_alive <owner> -> 0 while the lock's holder (pid|start
# time|token) is still that same process. An empty start time (ps had no
# answer when the lock was taken) falls back to liveness alone — towards
# "alive". Empty or malformed -> not alive: there is no holder to protect.
_usage_lock_holder_alive() {
  local pid="${1%%|*}" rest want
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  rest="${1#*|}"; want="${rest%%|*}"
  kill -0 "$pid" 2>/dev/null || return 1
  [ -z "$want" ] || [ "$(_usage_proc_lstart "$pid")" = "$want" ]
}

# _usage_proc_lstart <pid> -> that process's start time as `ps` prints it
# (compared as a string, never parsed), or nothing.
_usage_proc_lstart() {
  local s
  s="$(ps -o lstart= -p "$1" 2>/dev/null)" || return 0
  printf '%s' "$s" | tr -s ' ' | sed 's/^ //; s/ $//'
}

# _usage_mtime <file> -> epoch mtime, or nothing. GNU's `stat -c` first: on a
# GNU box `stat -f` means --file-system, so the BSD form may only ever be the
# fallback (see _clikae_statv in profile_store.sh for that history).
_usage_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# usage_agy_last_used <tank> -> epoch of the newest file in that agy tank's own
# log directory (<tank>/antigravity-cli/log/ — agy writes one cli-*.log per
# launch and appends while it runs), or nothing. The only per-tank trace of
# agy activity on disk: agy has one global login and no usage signal at all.
usage_agy_last_used() {
  local d newest
  d="$(profile_dir antigravity "$1" 2>/dev/null)/antigravity-cli/log"
  [ -d "$d" ] || return 1
  newest="$(ls -t "$d" 2>/dev/null | head -n 1)"
  [ -n "$newest" ] || return 1
  _usage_mtime "$d/$newest"
}

# _usage_public <engine> <tank> <now>  (record on stdin) -> the public reading.
# Strips the cache's own bookkeeping (cached_at, scanned_at, last_good), adds
# to EVERY reading (#174):
#   age_sec          how old the reading's evidence is: now minus `cached_at`
#                    (a vendor reading's fetch time; a codex transcript's own
#                    event time), never negative. A cache hit served 100
#                    minutes after the fetch says 6000 here, not 0.
#   window_reset_passed, weekly_reset_passed
#                    present (true) only when that axis's own `resets_at` is
#                    already behind `now`: the percentage beside it is from
#                    BEFORE a reset and says nothing about the current window.
#                    Absent otherwise, so no existing shape moves.
# and, on a reading with no numbers ONLY (#149):
#   gap              one word: why there is no number. The auth reasons name
#                    themselves ("needs-refresh", "relogin-required",
#                    "keychain-denied" — see the enum at the top of this file),
#                    else "no-probe" (clikae has nothing it can ask for this
#                    tank: codex with no rollout reading and its live probe off
#                    or absent) or "no-signal" (asked and got nothing usable,
#                    or — agy — the engine exposes no usage signal at all).
#   last_window_pct, last_weekly_pct, last_at, last_age_sec
#                    the last reading that HAD numbers, its epoch and age in
#                    seconds; all null when there never was one.
#   dry_marked_at    epoch of this tank's dry_store marker (the last burn that
#                    hit a limit), or null.
#   last_used_at     antigravity only: usage_agy_last_used, or null.
_usage_public() {
  local engine="$1" tank="$2" now="$3" dry_at="" used_at="" _t
  if [ -f "$CLIKAE_HOME/dry/$engine/$tank" ]; then
    IFS=$'\t' read -r dry_at _t < "$CLIKAE_HOME/dry/$engine/$tank" || true
    case "$dry_at" in ''|*[!0-9]*) dry_at="" ;; esac
  fi
  [ "$engine" != antigravity ] || used_at="$(usage_agy_last_used "$tank")" || used_at=""
  jq -c --arg engine "$engine" --argjson now "$now" --arg dry "$dry_at" --arg used "$used_at" "$_USAGE_NORM_STAMP_JQ"'
    . as $r | del(.cached_at, .scanned_at, .last_good) |
    . + {age_sec:(if ($r.cached_at|type) == "number" then ([$now - $r.cached_at, 0]|max) else null end)} |
    (if (.window_pct != null) and (.window_resets_at|expired) then . + {window_reset_passed:true} else . end) |
    (if (.weekly_pct != null) and (.weekly_resets_at|expired) then . + {weekly_reset_passed:true} else . end) |
    if (.window_pct == null and .weekly_pct == null) then
      . + {gap:(if .reason == "needs-refresh" or .reason == "relogin-required" or .reason == "keychain-denied" then .reason
                elif $engine == "antigravity" then "no-signal"
                elif $engine == "codex" and (.reason == null) then "no-probe"
                else "no-signal" end),
           last_window_pct:($r.last_good.window_pct // null),
           last_weekly_pct:($r.last_good.weekly_pct // null),
           last_at:($r.last_good.at // null),
           last_age_sec:(if ($r.last_good.at|type) == "number"
                         then ([$now - $r.last_good.at, 0]|max) else null end),
           dry_marked_at:(if $dry == "" then null else ($dry|tonumber) end)}
      | if $engine == "antigravity"
        then . + {last_used_at:(if $used == "" then null else ($used|tonumber) end)}
        else . end
    else . end'
}

# --- who writes this cache, and who honours what (P2-1, round-2 review) ---
#
# (a) `burn` refreshes the LAUNCHED tank's reading at run END — one vendor
#     call, off the launch path (launching itself still pays zero — P1-2..
#     P1-4), fired after the run's artifact check so it can never delay
#     judging that run's own outcome. See lib/commands/burn.sh's cmd_burn;
#     agy (#151) refreshes in _agy_burn with the run's --model as the hint.
# (b) when the named tank is dry and burn must reroute, `_burn_next_same_
#     engine` ranks every surviving candidate once on whatever is already on
#     disk, then spends its live-call budget (`_BURN_REROUTE_REFRESH_CAP`,
#     default 3) refreshing only the top candidates off THAT snapshot —
#     never all of them, and never before the snapshot ranking runs (bounded
#     to candidates only, reusing the adapter's own existing --max-time — no
#     new bound invented). A refresh that fails to read back may only rank
#     that candidate the SAME or WORSE than the on-disk evidence, never
#     better (round-5 review P2-1, round-6 review P3-1): a known-<90%
#     candidate becomes unknown (it can never win on the stale number it
#     just failed to reproduce), a known->=90% one KEEPS its reading rather
#     than being laundered into an "unknown" that outranks it.
# (c) the board NEVER fetches (usage_cache_peek/usage_board_fields below are
#     cache-only, always) and shows the reading's age next to the dot once
#     it is older than the TTL ("3h ago"), or "unknown" once it is older
#     than 24h — see lib/commands/home.sh's _home_fuel_dotv_compute.
# (d) `usage_cache_peek` (burn's ranking) and `usage_board_fields` (the
#     board's display) both honour the reading's OWN window_resets_at /
#     weekly_resets_at: a window whose reset instant has already passed
#     reads as 0% used, not as whatever stale percentage the last fetch
#     happened to record — a tank that ran dry at 15:00Z must not still be
#     ranked (or shown) at its old 100% two hours after its window reset.
#     This "reset passed -> 0%" rule only applies to `usage_cache_peek`
#     WITHIN its own `_USAGE_CACHE_PEEK_MAX_AGE_SEC` age ceiling (900s,
#     below) — past that ceiling the reading is "unknown", never "0%",
#     because a reading too old to trust is also too old to know it hasn't
#     drifted past a LATER reset it never recorded. `usage_board_fields`
#     carries no such ceiling: it honours the same reset-passed rule at any
#     age, on its own 24h "unknown" cutoff (`home.sh`) instead — the two
#     callers do not share one ruler (round-5 review P3-5).
#
# (e) a LIVE SESSION refreshes its own tank, from the `wake` window it
#     already has: one `usage_read` at launch (wake_usage_prime, called from
#     lib/commands/switch.sh for a session it just spawned) and one every
#     WAKE_USAGE_INTERVAL from wake_watch's loop (lib/core/wake.sh). Added
#     2026-09-22 because (a)-(d) between them left the refresh UNOWNED on a
#     machine that never burns: measured, a nine-day-old cache and a tmux
#     status row showing the "no reading" glyph forever, while a machine
#     burning all day showed live numbers. It goes through this same function,
#     so it honours CLIKAE_USAGE_TTL like every other caller and keeps nothing
#     a `clikae usage` run would not have written.
#
# (f) `clikae watch`'s usage-poll heartbeat (#133) walks every tank through
#     this same function on its own schedule. (e) and (f) overlap on purpose:
#     (f) needs a person running `clikae watch`, (e) needs nothing but a live
#     session — and because both go through the TTL below, a tank both of them
#     touch costs a cache hit, not a second vendor call.
#
# Nothing else writes or refreshes this cache. `usage_read` above is the
# ONLY writer in the whole repo (`clikae usage`, plus (a)/(b)/(e)/(f) above
# calling it the same way); a cache file with no `clikae usage`/burn/live-session run
# behind it simply does not exist yet, and one that stops being refreshed simply
# ages in place — (c) is how the board says so instead of staying silent.
#
# `scanned_at` vs `cached_at` (P3, round-2 review): a vendor reading's
# `cached_at` IS the fetch time — the two never differ. A transcript
# (codex) reading's `cached_at` is the underlying EVENT's own timestamp
# (P2-4, round-1 review, deliberate: never lie about how old the FACT is),
# which can be old even in a cache written moments ago. `scanned_at` is
# always "when `usage_read` last actually looked" — that is what a
# cache-hit/TTL check means everywhere else, so codex gets the same TTL
# behaviour claude already had instead of a check that almost never fires.
# `cached_at` keeps meaning "how old is this NUMBER", used by (c)'s age
# display and (d)'s reset-instant guard — unchanged by this.

# P2-3 (round-1 review) / P3-12 (round-2 review): the vendor's real reset
# instant is "2026-09-13T14:50:00.189940+00:00" — microseconds AND a UTC
# offset, never the bare "…Z" jq's fromdateiso8601 requires. norm_stamp
# drops the fractional seconds, then parses ANY "±HH:MM" offset (not just
# "+00:00"/"-00:00", the round-1 fix's shape) and converts to an epoch by
# arithmetic: the naive local time read as if it were already UTC, then
# shifted by the offset (subtract for "+", add for "-"). A stamp that
# doesn't match this shape at all still fails to parse — the caller's own
# `catch` decides what that means (both uses below fail OPEN: treat as not
# yet expired, same as before this fix, and still no real vendor sends a
# shape this doesn't parse).
_USAGE_NORM_STAMP_JQ='
  def norm_stamp:
    sub("\\.[0-9]+";"") as $s
    | if ($s | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$")) then
        ($s | capture("^(?<naive>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<off>Z|[+-][0-9]{2}:[0-9]{2})$")) as $c
        | ($c.naive + "Z" | fromdateiso8601) as $base
        | if $c.off == "Z" then $base
          elif ($c.off[0:1]) == "+" then $base - (($c.off[1:3]|tonumber)*3600 + ($c.off[4:6]|tonumber)*60)
          else $base + (($c.off[1:3]|tonumber)*3600 + ($c.off[4:6]|tonumber)*60)
          end
      else error("norm_stamp: unrecognized timestamp shape")
      end;
  def expired: if . == null then false else ((try norm_stamp catch ($now+1)) <= $now) end;
'

# P2 (round-4 review), corrected P2-2 (codex security review, round-5): how
# old a reading can be and still be trusted for burn's ranking, named once
# and used at usage_cache_peek's one call site below. Age is `cached_at` —
# the EVIDENCE's own timestamp, never `scanned_at` (round-4's original
# choice): `scanned_at` is "when usage_read last actually LOOKED", which for
# a vendor reading coincides with `cached_at` but for a codex transcript
# reading does not — a rollout's `cached_at` is deliberately the underlying
# EVENT's own old timestamp (P2-4, round-1 review), while `scanned_at` is
# whenever something last re-read that same unchanged rollout off disk.
# Ranking by `scanned_at` let a THREE-DAY-OLD rollout stay ranking-eligible
# forever, just by being rescanned — no new evidence from the vendor, only a
# fresh look at old evidence, renewing a claim that should have expired. That
# reproduced exactly: a synthetic 3-day-old rollout with both percentages at
# 100 and both resets already past kept scoring an eligible reading (and,
# combined with the reset-passed branch below, one that read as a
# suspiciously perfect 0% used) after every rescan. Ranking by `cached_at`
# instead means a codex candidate this stale correctly falls out of
# eligibility (empty output, "unknown") regardless of how recently anything
# rescanned it — the trade the round-4 comment warned about (codex
# candidates going unknown more often) is the point, not a regression: an
# unrefreshed reading's trustworthiness is about how old the FACT is, not how
# recently something looked at the file that holds it. 15 minutes is a small
# fraction of the 5-hour window burn ranks against (P2-3's "the 5-hour clock
# a burn starting now actually runs against") — long enough that a tank
# refreshed by a recent `clikae usage`, burn's own run-end refresh (a), or a
# reroute's Pass 4 candidate refresh (b, lib/commands/burn.sh's
# `_burn_next_same_engine`) still counts, short enough that the
# reset-instant-passed branch below can't be won by a reading old enough to
# predate the reset it's claiming to know about.
# P3-6 (round-5 review): a non-numeric override made every `--argjson
# max_age` call below fail to even start (jq errors out on a non-numeric
# arg), so every peek — cache-hit or not — silently read as "unknown", with
# no stderr at all (`usage_cache_peek`'s own `2>/dev/null`). This knob
# controls whether burn's ranking ever trusts ANY cached reading; a loud,
# named warning plus a safe default beats going quietly blind.
_USAGE_CACHE_PEEK_MAX_AGE_SEC=${_USAGE_CACHE_PEEK_MAX_AGE_SEC:-900}
# The unset/empty case above already resolved to the default and is never
# "invalid" — only a value that's actually SET to something non-numeric
# reaches this check (same shape as _BURN_REROUTE_REFRESH_CAP's, burn.sh).
# P3-4 (round-6 review): the digit-count bound is that shape too, and for
# this knob the overflow failure is the QUIETER of the two — an all-digit
# `99999999999999999999` sails through as a jq --argjson number, turning the
# age ceiling into 1e20 and making every reading trusted forever (the review
# measured a 3000-second-old reading accepted), with no warning at all.
# Nine digits is 31 years of ceiling; nothing legitimate is refused here.
case "$_USAGE_CACHE_PEEK_MAX_AGE_SEC" in
  *[!0-9]*|??????????*)
    declare -F log_warn >/dev/null && log_warn "_USAGE_CACHE_PEEK_MAX_AGE_SEC=\"$_USAGE_CACHE_PEEK_MAX_AGE_SEC\" is not a non-negative integer of at most 9 digits — using the default (900). Every cached usage reading silently reads as unknown otherwise."
    _USAGE_CACHE_PEEK_MAX_AGE_SEC=900
    ;;
esac

# Cache-only peek: never calls the vendor, never forks the adapter, never
# writes. burn's candidate ranking needs a headroom number to order tanks by
# — but burn's launch/reroute path must not pay a vendor round-trip just to
# pick one (that bound is (b) above's job, done once per reroute, not here).
# A reading up to _USAGE_CACHE_PEEK_MAX_AGE_SEC old is still returned here
# (stale-but-recent headroom beats no headroom for ranking purposes) —
# EXCEPT a window/weekly whose own reset instant has already passed, which
# reads as 0% used, never as its last stale reading (P2-1(d) above). Past
# the age ceiling the reading is "unknown", not "0% used because the reset
# passed": P2 (round-4 review) — a reading old enough to be unverifiable is
# also old enough to have crossed a reset instant it never recorded, and an
# unrefreshed candidate's number only gets systematically MORE flattering
# with age (window/weekly readings only fall or reset, never rise), so
# trusting an old "0%" here is exactly backwards from what "stale beats
# nothing" was meant to buy. Only a missing cache, missing jq, a reading
# older than the ceiling, or a non-vendor/incomplete reading is "unknown":
# empty stdout, rc=4 (jq -er's exit status when the pipeline produces no
# output at all, not rc=1 — rc=1 is "last value was false/null", which
# never happens here since select() either produces a value or nothing).
# P3-7 (round-6 review): CLOCK SKEW. A `cached_at` in the FUTURE (a cache
# written while the host clock was ahead, or copied from a machine that was)
# counts as AGE 0 — here and on the board, one rule, both rulers. This used
# to `select($evidence <= $now)`, i.e. reject the reading outright, while
# lib/commands/home.sh clamped the same case (`[ "$age" -ge 0 ] || age=0`):
# a cache stamped 30 seconds ahead read as UNKNOWN for burn ranking while
# the board showed its percentages as freshly read. The three age clocks in
# docs/DESIGN-board-fuel-dots.md are deliberately reconciled-not-unified
# about how LONG a reading stays good; they were never meant to disagree
# about what a NEGATIVE age means. Age 0 rather than rejection, because the
# reading is real evidence carrying a skewed stamp, and rejecting it would
# punish the tank for its host clock. A skewed stamp cannot make a reading
# look OLDER than it is, only younger, so this can never resurrect a reading
# the ceiling would otherwise have discarded.
usage_cache_peek() {
  local cache="$CLIKAE_HOME/state/usage/$1/$2.json" now="${3:-}"
  [ -f "$cache" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ -n "$now" ] || now="$(date +%s)"
  jq -er --argjson now "$now" --argjson max_age "$_USAGE_CACHE_PEEK_MAX_AGE_SEC" "$_USAGE_NORM_STAMP_JQ"'
    select(.source == "vendor" or .source == "transcript" or .source == "quota-api") |
    select(.window_pct != null and .weekly_pct != null) |
    (.cached_at) as $evidence |
    select($evidence != null) |
    # P3-7 (round-6 review): one clock-skew rule, shared with the board.
    # A timestamp in the FUTURE counts as age 0. See this function header.
    (if ($now - $evidence) < 0 then 0 else ($now - $evidence) end) as $age |
    select($age <= $max_age) |
    (if (.window_resets_at|expired) then 0 else .window_pct end) as $w |
    (if (.weekly_resets_at|expired) then 0 else .weekly_pct end) as $k |
    [$w,$k,([$w,$k]|max)] | @tsv' "$cache" 2>/dev/null
}

# P3-4 (round-5 review): does a candidate have ANY on-disk numeric reading at
# all, ignoring `_USAGE_CACHE_PEEK_MAX_AGE_SEC` entirely — used ONLY to decide
# burn's Pass-4 refresh PRIORITY (lib/commands/burn.sh's `_burn_next_same_
# engine`), never for ranking. Before this existed, a candidate whose only
# on-disk reading was older than the ceiling was indistinguishable, at
# refresh-priority time, from a candidate with NO reading at all — both
# collapsed to the same "unknown" bucket and lost the budget race to any
# candidate with a merely FRESH confident number, even when that stale
# reading (a tank the board itself still shows a percentage for, aged) was
# plausibly the actual best headroom in the fleet. This never returns a
# NUMBER (see usage_cache_peek for that, ceiling-bounded and reset-aware) —
# only whether refreshing this candidate is worth doing ahead of a blank one.
usage_cache_has_reading() {
  local cache="$CLIKAE_HOME/state/usage/$1/$2.json"
  [ -f "$cache" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '(.source == "vendor" or .source == "transcript" or .source == "quota-api") and .window_pct != null and .weekly_pct != null' \
    "$cache" >/dev/null 2>&1
}

# Board reads, up to 24h old (P2-1(c) above): never does network I/O during a
# redraw (cache-only, same file usage_cache_peek reads), but unlike
# usage_cached_fields below does NOT stop returning a reading once it is
# older than the TTL — it returns the reading PLUS its age (epoch
# `cached_at`, 4th column) so the caller can show "3h ago" instead of
# nothing. Same window/weekly reset-instant guard as usage_cache_peek (P2-1
# (d)): an expired window reads as 0%, not a stale ≥90%. The caller (home.sh)
# is the one that draws the 24h line and prints "unknown" past it — this
# function itself has no upper bound, same as usage_cache_peek.
usage_board_fields() {
  local cache="$CLIKAE_HOME/state/usage/$1/$2.json" now="${3:-}"
  [ -f "$cache" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ -n "$now" ] || now="$(date +%s)"
  jq -er --argjson now "$now" "$_USAGE_NORM_STAMP_JQ"'
    select(.source == "vendor" or .source == "transcript" or .source == "quota-api") |
    select(.window_pct != null or .weekly_pct != null) |
    # #149: one axis may be absent (a codex free plan has a single 30-day
    # window, read as weekly). "-" marks it — never 0, and never an empty
    # field: tab is IFS whitespace, so the reader would collapse it.
    (if .window_pct == null then "-" elif (.window_resets_at|expired) then 0 else .window_pct end) as $w |
    (if .weekly_pct == null then "-" elif (.weekly_resets_at|expired) then 0 else .weekly_pct end) as $k |
    # #149: the vendor'"'"'s own per-model rows that BIND — a row whose pct is
    # higher than the tank-level weekly — go in a 5th column as
    # "<name>:<pct>" joined by ",", else "-". Driven entirely by `models[]`
    # (no model name is known here): the all-models number can read 87%
    # while one model is at 100% (measured on a real tank), and the board
    # says so instead of looking healthy. A row below the tank value, or no
    # `models[]` at all, adds nothing.
    ([(.models // [])[] | select(.pct > ($k | numbers // -1)) | select((.resets_at|expired) | not)
      | "\(.name):\(.pct)"] | join(",")) as $bind |
    [$w,$k,([$w,$k]|map(numbers)|max),.cached_at,(if $bind == "" then "-" else $bind end)] | @tsv' "$cache" 2>/dev/null
}

# Board reads, fresh only (within the TTL): never do network I/O during a
# redraw. `now` may be passed in (epoch seconds) so a caller doing several
# lookups in one redraw forks `date` once, not once per lookup (P2-1, round-1
# review) — see lib/commands/home.sh's _home_fuel_dotv memoization. Same
# window/weekly reset-instant guard as usage_cache_peek/usage_board_fields
# above (P2-1(d)). Superseded as the board's PRIMARY read by
# usage_board_fields (P2-1(c), round-2 review: a 120s TTL made the vendor
# cache invisible to the board within a couple of minutes of the last
# `clikae usage`) but kept — same contract, same tests — for anything that
# genuinely only wants "fresh or nothing".
usage_cached_fields() {
  local cache="$CLIKAE_HOME/state/usage/$1/$2.json" ttl="${CLIKAE_USAGE_TTL:-120}" now="${3:-}"
  [ -f "$cache" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  case "$ttl" in ''|*[!0-9]*) ttl=120 ;; esac
  [ -n "$now" ] || now="$(date +%s)"
  jq -er --argjson now "$now" --argjson ttl "$ttl" "$_USAGE_NORM_STAMP_JQ"'
    (.scanned_at // .cached_at) as $scanned |
    select((.source == "vendor" or .source == "transcript" or .source == "quota-api") and $scanned <= $now and ($now-$scanned < $ttl)) |
    select(.window_pct != null and .weekly_pct != null) |
    select(all(.window_resets_at, .weekly_resets_at; expired | not)) |
    [.window_pct,.weekly_pct,([.window_pct,.weekly_pct]|max)] | @tsv' "$cache" 2>/dev/null
}
