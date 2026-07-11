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
#
# agy is adapter-less (global single-account, no per-shell env), so it can't go
# through the adapter-driven loop below — it gets its own loop, _agy_burn.
# shellcheck source=./antigravity.sh
source "$CLIKAE_LIB/commands/antigravity.sh"

_burn_help() {
  cat <<'EOF'
Usage: clikae burn <engine> <tank> --artifact <path>
                   ( --prompt-file <f> | --prompt <str> | -- <engine command...> )
                   [--add-dir <dir>]... [--to <target>] [--timeout <secs>]
                   [--no-reroute] [--allow-active] [--fresh]

Run a headless engine task on <tank>, verify it by the ARTIFACT it should
produce (never the exit code — codex exec exits 0 even when it hit its limit and
wrote nothing), and if the tank ran dry, re-fire the SAME task on the next tank
in your reserve.

Give the task in one of two ways:
  • the easy way — --prompt-file <f> / --prompt <str>: clikae fills in each
    engine's own headless-write flags (claude's -p / codex's exec …) from its
    adapter, so you never hand-assemble them and a cross-engine reroute stays
    sound (the flags are regenerated for the new engine).
  • the power-user way — -- <engine command...>: pass the raw engine argv yourself.

  --prompt-file <f>   read the task prompt from a file (no quoting hell).
  --prompt <str>      inline prompt, for one-liners. (Mutually exclusive with the above.)
  --add-dir <dir>     a directory the engine may write in. Defaults to the
                      artifact's parent. Repeatable. (codex uses the first as its cwd.)
  --artifact <path>   the file the task must produce. Success = it appears, or (if
                      it already existed) its timestamp changes — a STALE file from
                      a previous run is NOT counted as success.
  --fresh             delete <artifact> before running, for a clean slate.
  --to <target>       explicit next hop on a dry tank (<engine>/<tank> or a bare
                      tank of this engine). Otherwise burn walks this engine's
                      other tanks. A cross-engine --to runs the SAME command under
                      that engine — only sensible if the command is engine-agnostic.
  --timeout <secs>    bound the run. Uses `timeout`/`gtimeout` (coreutils) if present,
                      else a `perl` alarm (SIGALRM, direct child only). With none of
                      the three on PATH the run is NOT bounded and a warning is printed.
  --no-reroute        run once; on a dry tank, stop instead of falling through.
  --allow-active      let auto-reroute use a tank an interactive session is on.
                      By default the reserve SKIPS such tanks (rerouting a headless
                      job onto the tank you're mid-conversation on would silently
                      burn that quota) and tanks sharing an already-dry account.

Outcomes: artifact present -> done (exit 0); dry on every reachable tank -> fail;
no artifact but no limit -> a real task failure (NOT rerouted — it'd fail the same
on every tank).

Examples:
  clikae burn claude L --artifact out/core.test.cjs \
      --prompt-file task.txt --add-dir "$PWD"      # the easy way
  clikae burn codex M --artifact /tmp/out.md \
      --prompt-file task.txt --add-dir /tmp        # same task, different engine, no flag changes
  clikae burn codex M --artifact /tmp/out.md -- exec -C /tmp -s workspace-write \
      "read /tmp/in.txt, write /tmp/out.md"        # the power-user way (raw argv)

burn is the headless sibling of the interactive switch: pre-stage inputs to /tmp
(never hand a tank slow iCloud-backed I/O), and make tasks idempotent + artifact-
checked so a dropped one just re-fires elsewhere.

Boundary: burn only fits tasks whose success is a FILE you can name — codegen,
analysis, transforms. It CANNOT judge work whose proof is runtime behaviour (a UI
renders, a server answers); that still needs a human to verify.

Dry-detection leans on each vendor's CURRENT limit wording. If a vendor rewords
it, a dry tank would be misread as a real task failure (no reroute). Set
$CLIKAE_LIMIT_PATTERN='<regex>' to teach burn a new phrase (same override clikae
watch honours).

Re-firing the same task on another account sits in the vendors' terms gray
zone — where the line is, with the actual policy language and dates:
docs/terms-and-your-accounts.md (shown once before your first carry).
EOF
}

# _burn_next_same_engine <cli> <tried> <dried_accts> <envvar> <allow_active>
# The next same-engine tank to reroute a dry burn onto, in listing order — but the
# reserve is no longer naive (the 2026-06-04 "burn-out" dogfood):
#   • P0 — SKIP a tank an INTERACTIVE session is live on (live_dir_users finds a proc
#     holding <envvar>=<tank dir>). Rerouting a headless job onto the tank you're
#     using right now silently burns the quota you're mid-conversation on. Pass
#     allow_active=1 to override.
#   • P1 — SKIP a tank whose ACCOUNT is one we already dried (<dried_accts>, newline-
#     joined): same login = same quota = already dry, so hopping there is wasted.
# Echoes the tank name, or nothing when the reserve is exhausted. Note: log_warn
# writes to stderr, so a skip notice can't corrupt this function's captured stdout.
_burn_next_same_engine() {
  local cli="$1" tried="$2" dried_accts="$3" envvar="$4" allow_active="$5" t tdir tacct
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case " $tried " in *" $cli/$t "*) continue ;; esac
    tank_is_solo "$cli" "$t" && continue   # solo tanks are out of the fleet — never an auto-reroute target
    tdir="$(profile_dir "$cli" "$t")"
    if [ "$allow_active" != "1" ] && [ -n "$envvar" ] \
       && [ -n "$(live_dir_users "$tdir" "$envvar" 2>/dev/null)" ]; then
      log_warn "skipping $cli/$t — an interactive session is using it (burn would spend that quota; --allow-active to override)."
      continue
    fi
    if [ -n "$dried_accts" ]; then
      tacct="$(_limit_tank_account "$cli" "$t" 2>/dev/null || true)"
      if [ -n "$tacct" ] && printf '%s\n' "$dried_accts" | grep -qxF "$tacct"; then
        log_warn "skipping $cli/$t — same account as a tank already dry (shared quota)."
        continue
      fi
    fi
    printf '%s\n' "$t"; return 0
  done <<EOF
$(list_all_profiles | awk -F'\t' -v c="$cli" '$1==c{print $2}')
EOF
}

# _burn_timeout_bin -> echo `timeout` or `gtimeout` if one is on PATH; otherwise echo
# NOTHING and warn that the run will be UNBOUNDED. Factored out so the "no tool →
# honest warning, still runs" contract is unit-testable (stock macOS ships neither).
_burn_timeout_bin() {
  if command -v timeout  >/dev/null 2>&1; then printf 'timeout';  return 0; fi
  if command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout'; return 0; fi
  if command -v perl     >/dev/null 2>&1; then printf 'perl';     return 0; fi
  log_warn "--timeout needs \`timeout\`/\`gtimeout\` (coreutils) or \`perl\` on PATH — running WITHOUT a time bound."
  return 0
}

# Artifact freshness uses _clikae_mtime (lib/core/adapter_loader.sh) — epoch mtime,
# 0 if absent, GNU-stat-first for Linux portability — so a STALE file from a prior
# run can't be mistaken for this run's success (2026-06-06 tugtile dogfood #2).
# Whole-second resolution; a same-second overwrite is invisible (--fresh sidesteps it).

# _burn_size <path> -> byte count, or "?" if absent (for the summary line).
_burn_size() {
  if [ -e "$1" ]; then wc -c < "$1" 2>/dev/null | tr -d ' '; else printf '?'; fi
}

# _burn_compose <prompt> <post_cmd_count> <post_cmd...> -- <add_dir...>
# Build the full engine argv into the global array BURN_ARGV: the per-engine
# headless-write flags from adapter_burn_flags (which must be defined for the
# CURRENTLY-loaded adapter), followed by any verbatim post-`--` argv. Called once
# per engine so a cross-engine reroute regenerates the flags for the NEW engine
# (fixing the old "ship claude's -p flags to codex" unsoundness). Newline-per-item
# read keeps a multi-line prompt with spaces intact.
_burn_compose() {
  local prompt="$1"; shift
  local n="$1"; shift
  local -a post=(); local i
  for ((i=0; i<n; i++)); do post+=("$1"); shift; done
  shift   # drop the literal "--" separator
  BURN_ARGV=()
  local line
  # NUL-delimited read so a multi-line prompt survives as a single argv item.
  while IFS= read -r -d '' line; do BURN_ARGV+=("$line"); done < <(adapter_burn_flags "$prompt" "$@")
  BURN_ARGV+=("${post[@]}")
}

# _agy_burn <starting-tank> <prompt> <artifact> <timeout_s> <fresh> <add_dirs...>
# agy's own burn loop. agy has no adapter (no per-shell env; one global
# ~/.gemini symlink), so it can't go through cmd_burn's adapter-driven engine
# loop below — this is a dedicated SEQUENTIAL dry→next-tank loop, reusing the
# read-only headless recipe + cli.log dry-detection from
# lib/commands/conduct.sh's _conduct_one_agy, and the Keychain carry from
# lib/commands/antigravity.sh (now that a tank switch is non-interactive, this
# can drive it programmatically instead of refusing outright — see 32507a8's
# revert). Only sequential: agy can't run two tanks in parallel (one global
# active tank), so unlike other engines' burn there's no cross-terminal safety
# concern from an interactive session being mid-use on a DIFFERENT tank — this
# still moves the ONE global active tank, same as `clikae agy <tank>` always has.
_agy_burn() {
  local start_tank="$1" prompt="$2" artifact="$3" timeout_s="$4" fresh="$5" reroute="$6"; shift 6
  local -a add_dirs=("$@")

  if [ "$fresh" -eq 1 ] && [ -e "$artifact" ]; then
    rm -f "$artifact" 2>/dev/null
    if [ -e "$artifact" ]; then log_warn "--fresh could not remove $artifact (judging by timestamp instead)."
    else log_info "--fresh: cleared $artifact"; fi
  elif [ -e "$artifact" ]; then
    log_warn "artifact already exists: $artifact — judging success by a timestamp change (use --fresh for a clean slate)."
  fi
  local art_pre; art_pre="$(_clikae_mtime "$artifact")"
  local t0=$SECONDS

  local cur="$start_tank" tank_count; tank_count="$(_agy_tank_names | grep -c . || true)"
  local -a agy_tried=("$start_tank")
  while :; do
    [ -d "$(_agy_slots)/$cur" ] || log_fail "No such agy tank: $cur  (create it:  clikae init agy $cur)"
    if [ "$cur" != "$(_agy_active)" ]; then
      log_info "burn agy/$cur → switching (Keychain carry, no OAuth needed since 2026-07-05)"
      _agy_assert_not_running
      local active; active="$(_agy_active)"
      [ -n "$active" ] && _agy_kc_stash "$active"
      _agy_kc_restore "$cur"
      _agy_kc_verify_restore "$cur"
      rm -f "$(_agy_link)"; ln -s "$(_agy_slots)/$cur" "$(_agy_link)"
    fi
    log_info "burn agy/$cur → agy -p ..."

    local -a gen=(-p "$prompt") d
    for d in "${add_dirs[@]}"; do gen+=(--add-dir "$d"); done
    local -a runner=()
    if [ -n "$timeout_s" ]; then
      local tb; tb="$(_burn_timeout_bin)"
      case "$tb" in
        timeout|gtimeout) runner=("$tb" "$timeout_s") ;;
        perl)             runner=(perl -e 'alarm shift; exec @ARGV or exit 127' "$timeout_s") ;;
      esac
    fi
    local out; out="$("${runner[@]}" agy "${gen[@]}" </dev/null 2>&1)" || true

    local logf reset; logf="$(_agy_link)/antigravity-cli/cli.log"
    if reset="$(limit_log_dry "$logf")"; then
      log_warn "agy/$cur ran dry${reset:+  — }${reset}"
    elif [ -e "$artifact" ] && [ "$(_clikae_mtime "$artifact")" != "$art_pre" ]; then
      log_ok "Done on agy/$cur — artifact present: $artifact"
      log_info "summary: tank=agy/$cur  reroutes=$((${#agy_tried[@]} - 1))  elapsed=$((SECONDS - t0))s  artifact=$(_burn_size "$artifact")B"
      return 0
    else
      log_err "agy/$cur produced no fresh artifact and shows no limit — a real task failure, not a dry tank."
      printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /'
      log_info "summary: tank=agy/$cur  reroutes=$((${#agy_tried[@]} - 1))  elapsed=$((SECONDS - t0))s  artifact=none"
      return 1
    fi

    [ "$reroute" -eq 1 ] || { log_info "Dry, and --no-reroute is set. Stopping."; return 1; }
    # `|| true`: under `set -e -o pipefail`, grep exiting 1 (every tank already
    # tried — nothing left to select) would otherwise abort the script here
    # instead of falling through to the "all dry" log_fail below.
    local nxt; nxt="$(_agy_tank_names | grep -vxF -f <(printf '%s\n' "${agy_tried[@]}") | head -1)" || true
    [ -n "$nxt" ] || log_fail "All $tank_count agy tank(s) are dry — nothing left after: ${agy_tried[*]}. Add a tank (clikae init agy <name>) or wait for a reset."
    agy_tried+=("$nxt")
    cur="$nxt"
    log_info "Rerouting (dry) → agy/$cur"
  done
}

cmd_burn() {
  local cli="" tank="" artifact="" to="" timeout_s="" reroute=1 allow_active=0 fresh=0
  local prompt="" prompt_file="" prompt_set=0
  local -a cmd=() add_dirs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)    _burn_help; return 0 ;;
      --artifact)   shift; [ $# -gt 0 ] || log_fail "--artifact needs a path"; artifact="$1"; shift ;;
      --to)         shift; [ $# -gt 0 ] || log_fail "--to needs a target"; to="$1"; shift ;;
      --timeout)    shift; [ $# -gt 0 ] || log_fail "--timeout needs seconds"; timeout_s="$1"; shift ;;
      --prompt)     shift; [ $# -gt 0 ] || log_fail "--prompt needs a string"; prompt="$1"; prompt_set=1; shift ;;
      --prompt-file) shift; [ $# -gt 0 ] || log_fail "--prompt-file needs a path"; prompt_file="$1"; shift ;;
      --add-dir)    shift; [ $# -gt 0 ] || log_fail "--add-dir needs a path"; add_dirs+=("$1"); shift ;;
      --no-reroute) reroute=0; shift ;;
      --allow-active) allow_active=1; shift ;;
      --fresh)      fresh=1; shift ;;
      --)           shift; cmd=("$@"); break ;;
      -*)           log_fail "Unknown flag: $1  (try: clikae burn --help)" ;;
      *)            if [ -z "$cli" ]; then cli="$1"
                    elif [ -z "$tank" ]; then tank="$1"
                    else log_fail "Unexpected argument: $1  (put the engine command after --)"; fi
                    shift ;;
    esac
  done

  [ -n "$cli" ]      || log_fail "Missing <engine>. Usage: clikae burn <engine> <tank> --artifact <path> (--prompt-file <f> | -- <cmd...>)"
  [ -n "$tank" ]     || log_fail "Missing <tank>."
  [ -n "$artifact" ] || log_fail "Missing --artifact <path> — burn verifies completion by the artifact, never the exit code."

  # Convenience surface (--prompt / --prompt-file): clikae fills each engine's
  # headless-write flags from its adapter, so the task is just "a prompt + the
  # file it must produce" (2026-06-06 tugtile burn-writeup friction #1).
  [ "$prompt_set" -eq 1 ] && [ -n "$prompt_file" ] \
    && log_fail "Use either --prompt or --prompt-file, not both."
  if [ -n "$prompt_file" ]; then
    [ -r "$prompt_file" ] || log_fail "--prompt-file not readable: $prompt_file"
    prompt="$(cat "$prompt_file")"; prompt_set=1
  fi
  if [ "$prompt_set" -eq 1 ]; then
    # Default the writable dir to the artifact's parent, so the engine can always
    # at least write the file you asked for.
    [ "${#add_dirs[@]}" -ge 1 ] || add_dirs=("$(dirname "$artifact")")
  else
    [ "${#cmd[@]}" -ge 1 ] || log_fail "Give a task: --prompt-file <f> / --prompt <str>, or the explicit -- <cmd...> form."
  fi
  validate_name cli "$cli"
  validate_name profile "$tank"
  # Fall-through armed (the default) means a dry tank re-fires this task on the
  # next account — the cross-account carry case the one-time note is for.
  [ "$reroute" -eq 1 ] && carry_notice_once
  case "$cli" in
    agy|antigravity)
      _agy_enabled || log_fail "agy multi-account isn't set up yet. Create a tank first:  clikae init agy $tank"
      [ "$prompt_set" -eq 1 ] || log_fail "agy burn only supports the --prompt / --prompt-file form (agy has no adapter to fill in a raw '-- <cmd...>')."
      [ -z "$to" ] || log_fail "--to isn't supported for agy — it walks its own tanks (clikae init agy <name> to add more)."
      _agy_burn "$tank" "$prompt" "$artifact" "$timeout_s" "$fresh" "$reroute" "${add_dirs[@]}"
      return $?
      ;;
  esac
  # Keep the verbatim post-`--` argv aside; in --prompt mode it's appended after
  # the engine's generated flags (an escape hatch for extra per-engine args).
  local -a post_cmd=("${cmd[@]}")
  load_adapter "$cli"
  local binary; binary="$(adapter_meta_cli_binary)"
  command -v "$binary" >/dev/null 2>&1 || log_fail "'$binary' is not on PATH."
  local envvar; envvar="$(adapter_meta_env_var 2>/dev/null || true)"   # for the in-use guard
  if [ "$prompt_set" -eq 1 ]; then
    declare -F adapter_burn_flags >/dev/null \
      || log_fail "$cli has no headless-write recipe (adapter defines no adapter_burn_flags). Use the explicit '-- <cmd...>' form."
    _burn_compose "$prompt" "${#post_cmd[@]}" "${post_cmd[@]}" -- "${add_dirs[@]}"
    cmd=("${BURN_ARGV[@]}")
  fi

  # #2 (tugtile dogfood): snapshot the artifact so a STALE file from a prior run
  # isn't mistaken for success. --fresh clears it; otherwise warn + judge by mtime.
  if [ "$fresh" -eq 1 ] && [ -e "$artifact" ]; then
    rm -f "$artifact" 2>/dev/null
    if [ -e "$artifact" ]; then log_warn "--fresh could not remove $artifact (judging by timestamp instead)."
    else log_info "--fresh: cleared $artifact"; fi
  elif [ -e "$artifact" ]; then
    log_warn "artifact already exists: $artifact — judging success by a timestamp change (use --fresh for a clean slate)."
  fi
  local art_pre; art_pre="$(_clikae_mtime "$artifact")"   # 0 when absent
  local t0=$SECONDS

  local cur="$tank" tried="" dried_accts="" reset out rc
  while :; do
    validate_name profile "$cur"
    local dir; dir="$(ensure_profile --require "$cli" "$cur")"
    log_info "burn $cli/$cur → $binary ${cmd[*]}"

    # Run headless with the tank's env, stdin CLOSED (the burn-writeup hang lesson:
    # a headless codex can't interrupt its own child if stdin is open), capturing
    # combined output. Optional time bound if a timeout tool is available.
    local -a runner=()
    if [ -n "$timeout_s" ]; then
      local _tbin; _tbin="$(_burn_timeout_bin)"
      case "$_tbin" in
        timeout|gtimeout) runner=("$_tbin" "$timeout_s") ;;
        perl)             runner=(perl -e 'alarm shift; exec @ARGV or exit 127' "$timeout_s") ;;
      esac
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
      # Remember this dried tank's account so the reserve skips its same-quota siblings (P1).
      local _acct; _acct="$(_limit_tank_account "$cli" "$cur" 2>/dev/null || true)"
      [ -n "$_acct" ] && dried_accts="${dried_accts}${_acct}"$'\n'
    elif [ -e "$artifact" ] && [ "$(_clikae_mtime "$artifact")" != "$art_pre" ]; then
      dry_store_clear "$cli" "$cur"   # a real success recovered this tank
      log_ok "Done on $cli/$cur — artifact present: $artifact"
      log_info "summary: tank=$cli/$cur  reroutes=$(printf '%s' "$tried" | wc -w | tr -d ' ')  elapsed=$((SECONDS - t0))s  artifact=$(_burn_size "$artifact")B"
      return 0
    else
      log_err "$cli/$cur produced no fresh artifact and shows no limit — a real task failure (rc=$rc), not a dry tank."
      printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /'
      log_info "summary: tank=$cli/$cur  reroutes=$(printf '%s' "$tried" | wc -w | tr -d ' ')  elapsed=$((SECONDS - t0))s  artifact=none"
      return 1
    fi

    # Dry → fall through to the next tank in the reserve.
    [ "$reroute" -eq 1 ] || { log_info "Dry, and --no-reroute is set. Stopping."; return 1; }
    tried="$tried $cli/$cur"
    local nxt=""
    if [ -n "$to" ]; then
      nxt="$to"; to=""                       # explicit hop, consumed once (user's call)
    else
      nxt="$(_burn_next_same_engine "$cli" "$tried" "$dried_accts" "$envvar" "$allow_active")"
    fi
    [ -n "$nxt" ] || log_fail "All reachable tanks are dry (or in interactive use / share a dry account) — nothing left after$tried. Add a tank, wait for a reset, or --allow-active / --to <tank>."

    # Resolve the next hop. A bare name = a tank of the same engine; engine/tank =
    # possibly cross-engine (the same command then runs under that engine — warned).
    local nx_cli nx_tank
    case "$nxt" in
      */*) nx_cli="${nxt%%/*}"; nx_tank="${nxt#*/}" ;;
      *)   nx_cli="$cli";       nx_tank="$nxt" ;;
    esac
    if [ "$nx_cli" != "$cli" ]; then
      cli="$nx_cli"; load_adapter "$cli"; binary="$(adapter_meta_cli_binary)"
      envvar="$(adapter_meta_env_var 2>/dev/null || true)"   # in-use guard tracks the new engine's var
      command -v "$binary" >/dev/null 2>&1 || log_fail "Reroute engine '$binary' is not on PATH."
      if [ "$prompt_set" -eq 1 ]; then
        # Regenerate the headless flags for the NEW engine — a cross-engine reroute
        # of a --prompt task is sound (codex's flags differ from claude's, and the
        # prompt is engine-agnostic). Without a recipe for the new engine, stop.
        declare -F adapter_burn_flags >/dev/null \
          || log_fail "Cross-engine reroute → $nx_cli, which has no headless-write recipe (no adapter_burn_flags)."
        _burn_compose "$prompt" "${#post_cmd[@]}" "${post_cmd[@]}" -- "${add_dirs[@]}"
        cmd=("${BURN_ARGV[@]}")
        log_warn "Cross-engine reroute → $nx_cli: re-running the same prompt under $nx_cli's headless flags."
      else
        log_warn "Cross-engine reroute → $nx_cli: the SAME command runs under $nx_cli (only sound if it's engine-agnostic)."
      fi
    fi
    cur="$nx_tank"
    log_info "Rerouting (dry) → $cli/$cur"
  done
}
