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

_wait_help() {
  cat <<'EOF'
Usage: clikae wait <run_id|status-file>... [--any|--all] [--timeout <secs>]

Block until one (or every) named burn reaches a TERMINAL state — done, dry,
fail, or infra (see #41's status.json contract, documented in
docs/orchestration.md) — and print each one's status object as one JSON line
on stdout, in the order it finishes. Never greps a log.

A target is either the run id `clikae burn` printed (e.g. `burn-28186`, stable
across that burn's own reroutes and retries), a bare pid (shorthand for
`burn-<pid>`), or a path straight to a status.json.

  --any        stop as soon as ONE target reaches a terminal state (default).
  --all        wait for EVERY named target to reach a terminal state.
  --timeout <secs>   give up after this many seconds (an integer; unbounded
                     if omitted).

Exit code: 0 if at least one of the targets that finished is `done`; 2 if none
are `done` and every one that finished is `dry`; 1 otherwise (a `fail`/`infra`
among them, an unresolved target, or a timeout).

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
    case "$timeout_s" in ''|*[!0-9]*) log_fail "--timeout must be a nonnegative integer number of seconds" ;; esac
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
      case "$st" in
        done|dry|fail|infra)
          printf '%s\n' "$json"
          reported[i]=1
          terminal_count=$((terminal_count + 1))
          case "$st" in
            done) any_done=1 ;;
            dry)  any_dry=1 ;;
            *)    any_other=1 ;;
          esac
          ;;
      esac
    done

    [ "$mode" = "any" ] && [ "$terminal_count" -ge 1 ] && break
    [ "$mode" = "all" ] && [ "$terminal_count" -ge "$n" ] && break
    if [ -n "$timeout_s" ] && [ "$((SECONDS - start))" -ge "$timeout_s" ]; then
      log_err "clikae wait: timed out after ${timeout_s}s waiting for: ${targets[*]}"
      [ "$any_done" -eq 1 ] && return 0
      return 1
    fi
    sleep 1
  done

  [ "$any_done" -eq 1 ] && return 0
  [ "$any_other" -eq 0 ] && [ "$any_dry" -eq 1 ] && return 2
  return 1
}
