# shellcheck shell=bash
# lib/commands/burn.sh — `clikae burn <engine> <tank> --artifact <path> -- <cmd...>`
#
# Run a HEADLESS task on a tank, but actually KNOW whether it finished — and if the
# tank ran dry mid-task, keep burning the next tank in your reserve. This closes the
# 2026-06-03 burn-writeup gap: `codex exec` exits 0 even when it hit its usage limit
# and wrote nothing, so the exit code lies. burn judges by two honest signals: the
# limit string in the captured output (lib/core/limit.sh) AND the expected artifact.
#
# Scope on purpose: burn is the SINGLE-task unit an orchestrator fans out and
# re-fires — batch/parallelism stays the orchestrator's job (that's how the real
# burn ran: claude dispatched in parallel and reviewed). "Your tanks are the
# reserve" (docs/grammar.md — why `pool` was removed), so auto-reroute walks THIS
# engine's other tanks; --to forces an explicit next hop (may cross engines, warned).

_burn_help() {
  cat <<'EOF'
Usage: clikae burn <engine> <tank> --artifact <path> [--to <target>]
                   [--timeout <secs>] [--no-reroute] -- <engine command...>

Run a headless engine command on <tank>, verify it by the ARTIFACT it should
produce (never the exit code — codex exec exits 0 even when it hit its limit and
wrote nothing), and if the tank ran dry, re-fire the SAME command on the next
tank in your reserve.

  --artifact <path>   the file the task must produce; its presence = success.
  --to <target>       explicit next hop on a dry tank (<engine>/<tank> or a bare
                      tank of this engine). Otherwise burn walks this engine's
                      other tanks. A cross-engine --to runs the SAME command under
                      that engine — only sensible if the command is engine-agnostic.
  --timeout <secs>    bound the run (uses `timeout`/`gtimeout` if present).
  --no-reroute        run once; on a dry tank, stop instead of falling through.

Outcomes: artifact present -> done (exit 0); dry on every reachable tank -> fail;
no artifact but no limit -> a real task failure (NOT rerouted — it'd fail the same
on every tank).

Examples:
  clikae burn codex M --artifact /tmp/out.md -- exec -C /tmp -s workspace-write \
      "read /tmp/in.txt, write /tmp/out.md"
  clikae burn codex M --artifact /tmp/out.md --to codex/H -- exec ... "<task>"

burn is the headless sibling of the interactive switch: pre-stage inputs to /tmp
(never hand a tank slow iCloud-backed I/O), and make tasks idempotent + artifact-
checked so a dropped one just re-fires elsewhere.
EOF
}

# This engine's tanks not in <tried>, in listing order — the same-engine reserve.
_burn_next_same_engine() {
  local cli="$1" tried="$2" t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case " $tried " in *" $cli/$t "*) continue ;; esac
    printf '%s\n' "$t"; return 0
  done <<EOF
$(list_all_profiles | awk -F'\t' -v c="$cli" '$1==c{print $2}')
EOF
}

cmd_burn() {
  local cli="" tank="" artifact="" to="" timeout_s="" reroute=1
  local -a cmd=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)    _burn_help; return 0 ;;
      --artifact)   shift; [ $# -gt 0 ] || log_fail "--artifact needs a path"; artifact="$1"; shift ;;
      --to)         shift; [ $# -gt 0 ] || log_fail "--to needs a target"; to="$1"; shift ;;
      --timeout)    shift; [ $# -gt 0 ] || log_fail "--timeout needs seconds"; timeout_s="$1"; shift ;;
      --no-reroute) reroute=0; shift ;;
      --)           shift; cmd=("$@"); break ;;
      -*)           log_fail "Unknown flag: $1  (try: clikae burn --help)" ;;
      *)            if [ -z "$cli" ]; then cli="$1"
                    elif [ -z "$tank" ]; then tank="$1"
                    else log_fail "Unexpected argument: $1  (put the engine command after --)"; fi
                    shift ;;
    esac
  done

  [ -n "$cli" ]      || log_fail "Missing <engine>. Usage: clikae burn <engine> <tank> --artifact <path> -- <cmd...>"
  [ -n "$tank" ]     || log_fail "Missing <tank>."
  [ -n "$artifact" ] || log_fail "Missing --artifact <path> — burn verifies completion by the artifact, never the exit code."
  [ "${#cmd[@]}" -ge 1 ] || log_fail "Missing the engine command after --  (e.g. -- exec -C /tmp \"<task>\")."
  validate_name cli "$cli"
  validate_name profile "$tank"
  case "$cli" in
    agy|antigravity) log_fail "agy is global/single-account — it can't be burned per-tank headlessly. Use codex/claude tanks." ;;
  esac
  load_adapter "$cli"
  local binary; binary="$(adapter_meta_cli_binary)"
  command -v "$binary" >/dev/null 2>&1 || log_fail "'$binary' is not on PATH."

  local cur="$tank" tried="" reset out rc
  while :; do
    validate_name profile "$cur"
    local dir; dir="$(ensure_profile --require "$cli" "$cur")"
    log_info "burn $cli/$cur → $binary ${cmd[*]}"

    # Run headless with the tank's env, stdin CLOSED (the burn-writeup hang lesson:
    # a headless codex can't interrupt its own child if stdin is open), capturing
    # combined output. Optional time bound if a timeout tool is available.
    local -a runner=()
    if [ -n "$timeout_s" ]; then
      if   command -v timeout  >/dev/null 2>&1; then runner=(timeout  "$timeout_s")
      elif command -v gtimeout >/dev/null 2>&1; then runner=(gtimeout "$timeout_s")
      else log_warn "No timeout/gtimeout on PATH — running without a time bound."; fi
    fi
    rc=0
    out="$(
      while IFS= read -r kv; do [ -n "$kv" ] && export "${kv%%=*}"="${kv#*=}"; done <<KV
$(adapter_export_env "$dir")
KV
      "${runner[@]}" "$binary" "${cmd[@]}" </dev/null 2>&1
    )" || rc=$?

    # Judge by limit-string + artifact, never the exit code.
    if reset="$(limit_output_dry "$cli" "$out")"; then
      log_warn "$cli/$cur ran dry${reset:+  — }${reset}"
      # Persist what we just caught LIVE so the passive board (clikae home) can
      # light this tank red + show the reset phrase — codex's limit lives only in
      # this stdout and would otherwise vanish. Only for engines whose dry state is
      # NOT already scannable from disk (claude=transcript, agy=log self-clear);
      # writing a store marker for those would mask their real recovery.
      limit_engine_detectable "$cli" || dry_store_mark "$cli" "$cur" "$reset"
    elif [ -e "$artifact" ]; then
      dry_store_clear "$cli" "$cur"   # a real success recovered this tank
      log_ok "Done on $cli/$cur — artifact present: $artifact"
      return 0
    else
      log_err "$cli/$cur produced no artifact and shows no limit — a real task failure (rc=$rc), not a dry tank."
      printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /'
      return 1
    fi

    # Dry → fall through to the next tank in the reserve.
    [ "$reroute" -eq 1 ] || { log_info "Dry, and --no-reroute is set. Stopping."; return 1; }
    tried="$tried $cli/$cur"
    local nxt=""
    if [ -n "$to" ]; then
      nxt="$to"; to=""                       # explicit hop, consumed once
    else
      nxt="$(_burn_next_same_engine "$cli" "$tried")"
    fi
    [ -n "$nxt" ] || log_fail "All reachable tanks are dry — nothing left after$tried. Add a tank or wait for a reset."

    # Resolve the next hop. A bare name = a tank of the same engine; engine/tank =
    # possibly cross-engine (the same command then runs under that engine — warned).
    local nx_cli nx_tank
    case "$nxt" in
      */*) nx_cli="${nxt%%/*}"; nx_tank="${nxt#*/}" ;;
      *)   nx_cli="$cli";       nx_tank="$nxt" ;;
    esac
    if [ "$nx_cli" != "$cli" ]; then
      log_warn "Cross-engine reroute → $nx_cli: the SAME command runs under $nx_cli (only sound if it's engine-agnostic)."
      cli="$nx_cli"; load_adapter "$cli"; binary="$(adapter_meta_cli_binary)"
      command -v "$binary" >/dev/null 2>&1 || log_fail "Reroute engine '$binary' is not on PATH."
    fi
    cur="$nx_tank"
    log_info "Rerouting (dry) → $cli/$cur"
  done
}
