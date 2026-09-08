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

_wait_help() {
  cat <<'EOF'
Usage: clikae wait <run_id|status-file>... [--any|--all] [--timeout <dur>]

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
EOF
}

cmd_wait() {
  local mode="any" timeout_s=""
  local -a targets=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)  _wait_help; return 0 ;;
      --any)      mode="any"; shift ;;
      --all)      mode="all"; shift ;;
      --timeout)  shift; [ $# -gt 0 ] || log_fail "--timeout needs seconds"; timeout_s="$1"; shift ;;
      -*)         log_fail "Unknown flag: $1  (try: clikae wait --help)" ;;
      *)          targets+=("$1"); shift ;;
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

  local -a paths=()
  local t p
  for t in "${targets[@]}"; do
    p="$(burn_status_resolve "$t")" || log_fail "no status file for: $t  (has the burn started yet? see docs/orchestration.md)"
    paths+=("$p")
  done

  local n="${#paths[@]}"
  local -a reported=()
  local i
  for ((i = 0; i < n; i++)); do reported[i]=0; done

  local start=$SECONDS terminal_count=0 any_done=0 any_dry=0 any_other=0
  while :; do
    for ((i = 0; i < n; i++)); do
      [ "${reported[i]}" -eq 0 ] || continue
      [ -f "${paths[i]}" ] || continue
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
