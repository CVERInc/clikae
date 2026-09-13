# shellcheck shell=bash
# lib/commands/wait.sh — `clikae wait <run_id|status-file>… [--any|--all] [--timeout <s>]`
#
# The cockpit-hand-rolled version of this was `until [ -e DONE ]; do sleep 60;
# done`, plus a separate grep of the burn log for "ran dry" / "[ FAIL ]" — and
# that grep is exactly what #41 closed, because a burn's own PROMPT can contain
# either phrase. `wait` reads #41's status.json files instead, so "what counts
# as a finished burn" has one definition, in one place, that a cockpit can block
# on rather than reinvent per session.
#
# shellcheck source=../core/burn_status.sh
source "$CLIKAE_LIB/core/burn_status.sh"
# shellcheck source=../core/duration.sh
source "$CLIKAE_LIB/core/duration.sh"

# _wait_resolve_latest <prefix> -> the status.json path of the NEWEST
# (by mtime, not by name — no assumption about epoch digit width) run
# directory under $HOME/.clikae/logs matching <prefix>*, or 1 if none has a
# status.json yet (P2-3, 2026-09-13 fix-round-2 review: a cockpit knows a
# watch-github run's PREFIX — `watch-github-<org>` — but not the epoch
# suffix a not-yet-run poll will pick; this is the "no epoch needed" entry
# point burn_status_resolve's own literal/`burn-*`/pid forms don't cover).
_wait_resolve_latest() {
  local prefix="$1" base="$HOME/.clikae/logs" d f m best="" best_m=-1
  [ -n "$prefix" ] && [ -d "$base" ] || return 1
  for d in "$base/$prefix"*; do
    [ -d "$d" ] || continue
    f="$d/status.json"
    [ -f "$f" ] || continue
    m="$(file_mtime "$f")"
    case "$m" in ''|*[!0-9]*) continue ;; esac
    if [ "$m" -gt "$best_m" ]; then best="$f"; best_m="$m"; fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

_wait_help() {
  cat <<'EOF'
Usage: clikae wait <run_id|status-file>... [--any|--all] [--timeout <dur>]
       clikae wait --latest <prefix> [--any|--all] [--timeout <dur>]

Block until one (or every) named burn reaches a TERMINAL state — done, dry,
fail, infra, or stale (a `running`/`waiting-reset` row whose recorded pid is
no longer alive, synthesized here at read time, never written to disk — see
#41's status.json contract, documented in docs/orchestration.md) — and print
each one's status object as one JSON line on stdout, in the order it
finishes. Never greps a log.

A target is either the run id `clikae burn` printed (e.g. `burn-28186`, stable
across that burn's own reroutes and retries), `--json`'s own per-attempt
run_id (e.g. `codex-T1-burn-28186`, resolved to the top-level id it came
from), a bare pid (shorthand for `burn-<pid>`), or a path straight to a
status.json. A target's status file not existing YET is a normal race (see
`clikae burn ... & clikae wait "burn-$!"` below) — resolution waits up to
$CLIKAE_WAIT_RESOLVE_TIMEOUT_S seconds (default 10) for it to appear before
refusing.

  --any        stop as soon as ONE target reaches a terminal state (default).
  --all        wait for EVERY named target to reach a terminal state.
  --latest <prefix>  resolve to the NEWEST run directory under
                    $HOME/.clikae/logs whose name starts with <prefix> that
                    already has a status.json — for a caller who knows the
                    prefix (e.g. `watch-github-CVERInc`) but not the epoch
                    suffix a not-yet-finished poll will pick. May be given
                    more than once, and mixed with plain targets. If nothing
                    matches yet and --timeout was given, this WAITS for a
                    match to appear (re-checked every poll, same as a plain
                    target's own startup race) instead of refusing outright;
                    with no --timeout, an unresolved prefix still refuses
                    immediately, the same as before.
  --timeout <dur>   give up after this long — a bare integer of seconds, or
                    with a trailing s/m/h/d (e.g. 90, 90s, 20m, 2h); unbounded
                    if omitted.

Exit code — 0 only when the REQUESTED condition is met:
  --any (default): 0 if at least one target is done; 2 if none are done and
                   every one that finished is dry; 1 otherwise (a
                   fail/infra/stale among them, an unresolved target, or a
                   timeout).
  --all:           0 only if EVERY target is done; 2 only if EVERY target is
                   dry; 1 otherwise (a done+dry mix, a fail/infra/stale
                   among them, an unresolved target, or a timeout).
A timeout is always 1, in both modes, even if some other target was done.

Examples:
  clikae burn claude L --artifact out.md --prompt-file t.md --json &
  clikae wait "burn-$!" --timeout 20m && echo "L finished"

  clikae wait burn-111 burn-222 burn-333 --all --timeout 30m

  clikae wait --latest watch-github-CVERInc --timeout 20m
EOF
}

cmd_wait() {
  local mode="any" timeout_s=""
  local -a targets=()       # human-readable, for the timeout error message
  local -a target_kind=()   # "target" | "latest", parallel to targets
  # P2-1 (2026-09-13 fix-round-3 review — read before re-inlining this):
  # `--latest <prefix>` used to resolve INLINE, the instant the flag was
  # parsed — which meant it always failed for a run that hadn't started
  # yet, REGARDLESS of a `--timeout` given later on the same command line
  # (`_burn_parse_duration`'s own value wasn't even known yet at that
  # point). `--latest` is precisely the case where the caller does NOT
  # know the file exists yet (that's the whole reason it exists — no epoch
  # to name a literal target with) — so parse ALL flags first, and defer
  # `--latest` resolution to AFTER the polling loop below is built, where
  # `$timeout_s` is fully known.
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)  _wait_help; return 0 ;;
      --any)      mode="any"; shift ;;
      --all)      mode="all"; shift ;;
      --latest)   shift; [ $# -gt 0 ] || log_fail "--latest needs a prefix"
                  target_kind+=("latest"); targets+=("$1"); shift ;;
      --timeout)  shift; [ $# -gt 0 ] || log_fail "--timeout needs seconds"; timeout_s="$1"; shift ;;
      -*)         log_fail "Unknown flag: $1  (try: clikae wait --help)" ;;
      *)          target_kind+=("target"); targets+=("$1"); shift ;;
    esac
  done
  [ "${#targets[@]}" -ge 1 ] || log_fail "clikae wait needs at least one <run_id|status-file>  (try: clikae wait --help)"
  if [ -n "$timeout_s" ]; then
    # P1-4a (2026-09-09 round-1 review): both published examples of this
    # command (--help above and docs/orchestration.md) use `20m`/`30m` —
    # accept the same s/m/h/d grammar `--wait-for-reset` already does,
    # instead of rejecting every one of them and requiring bare seconds.
    local _parsed_timeout
    _parsed_timeout="$(_burn_parse_duration "$timeout_s")" \
      || log_fail "--timeout: not a duration: $timeout_s  (use e.g. 30, 30s, 5m, 2h, or a bare integer of seconds)"
    timeout_s="$_parsed_timeout"
  fi

  # P2-1: a "target" resolves now (as always — burn_status_resolve has its
  # own short bounded wait, $CLIKAE_WAIT_RESOLVE_TIMEOUT_S, for the
  # ordinary `burn … & wait "burn-$!"` startup race). A "latest" prefix
  # ALSO tries now — the common case (the run already exists) still returns
  # immediately, no behaviour change there. It resolves later than "now"
  # ONLY when a `--timeout` was actually given: with no timeout, an
  # unresolved `--latest` still refuses immediately (unbounded waiting on
  # a target the caller gave no time budget for is not this feature's
  # job) — unchanged from before for that case, so `clikae wait --latest
  # nonexistent-prefix` (no --timeout) keeps refusing right away.
  local n="${#targets[@]}"
  local -a paths=()
  local -a target_arg=("${targets[@]}")
  local i
  for ((i = 0; i < n; i++)); do
    if [ "${target_kind[i]}" = "latest" ]; then
      local _lp
      if _lp="$(_wait_resolve_latest "${target_arg[i]}")"; then
        paths[i]="$_lp"
      elif [ -n "$timeout_s" ]; then
        paths[i]=""   # not yet — retried each poll in the loop below
      else
        log_fail "no status file matches: ${target_arg[i]}*  (try: clikae wait --help)"
      fi
    else
      paths[i]="$(burn_status_resolve "${target_arg[i]}")" \
        || log_fail "no status file for: ${target_arg[i]}  (has the burn started yet? see docs/orchestration.md)"
    fi
  done

  local -a reported=()
  for ((i = 0; i < n; i++)); do reported[i]=0; done

  local start=$SECONDS terminal_count=0 any_done=0 any_dry=0 any_other=0
  while :; do
    for ((i = 0; i < n; i++)); do
      [ "${reported[i]}" -eq 0 ] || continue
      if [ "${target_kind[i]}" = "latest" ] && [ -z "${paths[i]:-}" ]; then
        local _lp2
        _lp2="$(_wait_resolve_latest "${target_arg[i]}")" && paths[i]="$_lp2"
      fi
      [ -n "${paths[i]:-}" ] && [ -f "${paths[i]}" ] || continue
      local json st
      json="$(cat "${paths[i]}" 2>/dev/null)" || continue
      st="$(burn_status_state "$json")"

      # P1-1 (2026-09-09 round-1 review): a burn that dies without ever
      # writing a terminal state (burn.sh's own EXIT/INT/TERM/HUP trap now
      # closes that gap for NEW burns, but a status file from before that
      # fix, or one an older clikae wrote, can still say `running` with
      # nobody left alive to ever change it) must not hang `wait` forever.
      # `running` (and #38/P1-2's `waiting-reset`) with a DEAD pid is
      # reclassified here, at READ time, as the synthetic state `stale` —
      # never written to disk, only ever shown to a `wait` caller — and
      # treated as a `fail`-equivalent terminal outcome below.
      case "$st" in
        running|waiting-reset)
          local pid; pid="$(burn_status_str "$json" pid)"
          case "$pid" in
            ''|*[!0-9]*) : ;;   # no usable pid recorded — can't judge, keep polling
            *)
              if ! kill -0 "$pid" 2>/dev/null; then
                json="${json/\"state\":\"$st\"/\"state\":\"stale\"}"
                st="stale"
              fi
              ;;
          esac
          ;;
      esac

      case "$st" in
        done|dry|fail|infra|stale)
          printf '%s\n' "$json"
          reported[i]=1
          terminal_count=$((terminal_count + 1))
          case "$st" in
            done) any_done=1 ;;
            dry)  any_dry=1 ;;
            *)    any_other=1 ;;   # fail, infra, stale
          esac
          ;;
      esac
    done

    [ "$mode" = "any" ] && [ "$terminal_count" -ge 1 ] && break
    [ "$mode" = "all" ] && [ "$terminal_count" -ge "$n" ] && break
    if [ -n "$timeout_s" ] && [ "$((SECONDS - start))" -ge "$timeout_s" ]; then
      log_err "clikae wait: timed out after ${timeout_s}s waiting for: ${targets[*]}"
      # P1-3 (2026-09-09 round-1 review): a timeout is a timeout, full stop —
      # `--help`/docs say "1 … or --timeout expired first", unconditionally.
      # Checking any_done here used to let `clikae wait A B --all --timeout
      # 30m && ship` ship on a timeout whenever A merely happened to already
      # be done while B never finished.
      return 1
    fi
    sleep 1
  done

  # P2-3 (2026-09-09 round-1 review): the exit-code contract is PER-MODE, not
  # "any done anywhere wins". Under `--all` the caller explicitly asked about
  # EVERY target, so a done+fail (or done+dry) mix must not read as success
  # just because one of them finished clean — `0` only when the REQUESTED
  # condition is actually met.
  if [ "$mode" = "all" ]; then
    [ "$any_other" -eq 0 ] && [ "$any_dry" -eq 0 ] && [ "$any_done" -eq 1 ] && return 0
    [ "$any_other" -eq 0 ] && [ "$any_done" -eq 0 ] && [ "$any_dry" -eq 1 ] && return 2
    return 1
  fi

  # --any: at least one done is the whole ask.
  [ "$any_done" -eq 1 ] && return 0
  [ "$any_other" -eq 0 ] && [ "$any_dry" -eq 1 ] && return 2
  return 1
}
