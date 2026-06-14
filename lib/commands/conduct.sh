# shellcheck shell=bash
# lib/commands/conduct.sh — `clikae conduct` (BETA): fan ONE prompt across N
# accounts in parallel, collect each leg's FULL output, and tabulate which tanks
# produced a result vs ran dry. The "vertical orchestration" primitive: a fleet of
# AI CLIs each burning its OWN subscription, none eating your main budget.
#
# What it is NOT: clikae does not JUDGE the outputs — it stays a pure switcher.
# It hands you N full result files (and an honest dry/captured table); you (or the
# session model acting as conductor) pick the winner. That brain/muscle split is
# the point: clikae is the muscle (accounts, dry-detection, parallel routing); the
# conductor (a human, or a Claude/codex session) is the brain.
#
# Read-only by design (each leg runs headless READ-ONLY via adapter_audit_flags),
# so N legs can't clobber a shared working tree — the safe, common best-of-N case
# (audits, analyses, design proposals). Write/impl tournaments that need isolated
# worktrees stay an orchestrator's job (see the conductor skill's Heavy mode).

# Reuse burn's timeout-tool resolver (timeout/gtimeout/perl-or-warn).
# shellcheck source=./burn.sh
source "$CLIKAE_LIB/commands/burn.sh"

_conduct_help() {
  cat <<'EOF'
Usage: clikae conduct ( --prompt-file <f> | --prompt <str> )
                      --leg <engine>/<tank> [--leg <engine>/<tank>]...
                      [--add-dir <dir>]... [--out-dir <dir>] [--timeout <secs>]

Fan ONE prompt across several accounts IN PARALLEL — each leg runs the prompt
headless and READ-ONLY on its own tank (its own subscription quota) — then
collect every leg's full output and print a captured/dry table. You pick the
winner; clikae never judges. (BETA — the vertical-orchestration primitive.)

  --prompt-file <f>   the task prompt (self-contained — each leg is a blind run).
  --prompt <str>      inline prompt (mutually exclusive with --prompt-file).
  --leg <engine>/<tank>   a leg to fan to. Repeatable. Engine must support a
                          read-only headless recipe (claude, codex). Same prompt,
                          different account — different perspective / spare quota.
  --add-dir <dir>     extra read root for every leg (default: $PWD). Repeatable.
  --out-dir <dir>     where to collect <engine>-<tank>.txt results
                      (default: a fresh mktemp dir, printed at the end).
  --timeout <secs>    bound each leg (coreutils timeout/gtimeout, else a perl alarm).

Each leg's outcome is judged by its OUTPUT, never the exit code (a headless agent
exits 0 even when it hit its limit). Outcomes per leg: captured / dry (with the
vendor's reset phrase) / empty (a real failure — auth/sandbox/no answer).

Example — best-of-N audit across three accounts:
  clikae conduct --prompt-file review.md \
    --leg codex/H --leg codex/i --leg claude/C --add-dir "$PWD"
EOF
}

# _conduct_one <engine> <tank> <prompt> <outfile> <statusfile> <timeout_s> <add_dirs...>
# One leg, meant to run in the background. Loads its OWN adapter (a background
# subshell has a private copy of the function table, so parallel legs don't clash),
# runs the read-only headless recipe with the tank's env + stdin closed, captures
# combined output to <outfile>, and writes a one-word verdict to <statusfile>:
#   DRY <reset> | CAPTURED | EMPTY | NORECIPE | NOPATH | NOTANK
_conduct_one() {
  local engine="$1" tank="$2" prompt="$3" outfile="$4" statusfile="$5" tmo="$6"; shift 6
  local -a add_dirs=("$@")

  load_adapter "$engine" 2>/dev/null || { printf 'NOTANK\n' > "$statusfile"; return 0; }
  declare -F adapter_audit_flags >/dev/null || { printf 'NORECIPE\n' > "$statusfile"; return 0; }
  local binary; binary="$(adapter_meta_cli_binary)"
  command -v "$binary" >/dev/null 2>&1 || { printf 'NOPATH\n' > "$statusfile"; return 0; }
  local dir; dir="$(profile_dir "$engine" "$tank")"
  [ -d "$dir" ] || { printf 'NOTANK\n' > "$statusfile"; return 0; }

  local -a gen=(); local line
  # NUL-delimited read so a multi-line prompt survives as a single argv item.
  while IFS= read -r -d '' line; do gen+=("$line"); done < <(adapter_audit_flags "$prompt" "${add_dirs[@]}")

  local -a runner=()
  if [ -n "$tmo" ]; then
    local tb; tb="$(_burn_timeout_bin)"
    case "$tb" in
      timeout|gtimeout) runner=("$tb" "$tmo") ;;
      perl)             runner=(perl -e 'alarm shift; exec @ARGV or exit 127' "$tmo") ;;
    esac
  fi

  # `|| true`: the engine's exit code is meaningless (a headless agent exits 0 on
  # a limit, non-zero on a real failure) — we judge by the OUTPUT. Without this,
  # `set -e` (inherited by this background subshell) would abort a non-zero leg
  # BEFORE it writes its .status file, dropping a real failure into "unknown"
  # instead of EMPTY (independent-audit catch, 2026-06-13).
  local out
  out="$(
    while IFS= read -r kv; do [ -n "$kv" ] && export "${kv%%=*}"="${kv#*=}"; done <<KV
$(adapter_export_env "$dir")
KV
    "${runner[@]}" "$binary" "${gen[@]}" </dev/null 2>&1
  )" || true
  printf '%s\n' "$out" > "$outfile"

  # Classify by the captured OUTPUT, not the file size: printf '%s\n' "$out" always
  # writes a trailing newline, so an empty leg yields a 1-byte file — `-s` would
  # wrongly call that CAPTURED. Key off $out being non-empty instead.
  local reset
  if reset="$(limit_output_dry "$engine" "$out")"; then
    printf 'DRY %s\n' "$reset" > "$statusfile"
  elif [ -n "$out" ]; then
    printf 'CAPTURED\n' > "$statusfile"
  else
    printf 'EMPTY\n' > "$statusfile"
  fi
}

cmd_conduct() {
  local prompt="" prompt_file="" prompt_set=0 out_dir="" timeout_s=""
  local -a legs=() add_dirs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)     _conduct_help; return 0 ;;
      --prompt)      shift; [ $# -gt 0 ] || log_fail "--prompt needs a string"; prompt="$1"; prompt_set=1; shift ;;
      --prompt-file) shift; [ $# -gt 0 ] || log_fail "--prompt-file needs a path"; prompt_file="$1"; shift ;;
      --leg)         shift; [ $# -gt 0 ] || log_fail "--leg needs <engine>/<tank>"; legs+=("$1"); shift ;;
      --add-dir)     shift; [ $# -gt 0 ] || log_fail "--add-dir needs a path"; add_dirs+=("$1"); shift ;;
      --out-dir)     shift; [ $# -gt 0 ] || log_fail "--out-dir needs a path"; out_dir="$1"; shift ;;
      --timeout)     shift; [ $# -gt 0 ] || log_fail "--timeout needs seconds"; timeout_s="$1"; shift ;;
      -*)            log_fail "Unknown flag: $1  (try: clikae conduct --help)" ;;
      *)             log_fail "Unexpected argument: $1  (legs go via --leg <engine>/<tank>)" ;;
    esac
  done

  [ "$prompt_set" -eq 1 ] && [ -n "$prompt_file" ] && log_fail "Use either --prompt or --prompt-file, not both."
  if [ -n "$prompt_file" ]; then
    [ -r "$prompt_file" ] || log_fail "--prompt-file not readable: $prompt_file"
    prompt="$(cat "$prompt_file")"; prompt_set=1
  fi
  [ "$prompt_set" -eq 1 ]    || log_fail "Give a prompt: --prompt-file <f> or --prompt <str>."
  [ "${#legs[@]}" -ge 1 ]    || log_fail "Give at least one --leg <engine>/<tank> to fan to."
  [ "${#add_dirs[@]}" -ge 1 ] || add_dirs=("$PWD")

  if [ -z "$out_dir" ]; then
    out_dir="$(mktemp -d "${TMPDIR:-/tmp}/clikae-conduct.XXXXXX")" \
      || log_fail "Could not create a temp out-dir; pass --out-dir <dir>."
  else
    mkdir -p "$out_dir" || log_fail "Could not create --out-dir: $out_dir"
  fi

  log_info "conduct: fanning 1 prompt across ${#legs[@]} legs (read-only, parallel) → $out_dir"

  # Launch every leg in the background (each burns its own account's quota).
  local -a pids=() tags=() outs=() stats=()
  local leg engine tank slug
  for leg in "${legs[@]}"; do
    case "$leg" in
      */*) engine="${leg%%/*}"; tank="${leg#*/}" ;;
      *)   log_warn "skipping malformed --leg '$leg' (want <engine>/<tank>)"; continue ;;
    esac
    slug="${engine}-${tank}"
    local of="$out_dir/$slug.txt" sf="$out_dir/$slug.status"
    _conduct_one "$engine" "$tank" "$prompt" "$of" "$sf" "$timeout_s" "${add_dirs[@]}" &
    pids+=("$!"); tags+=("$engine/$tank"); outs+=("$of"); stats+=("$sf")
    log_dim "  → leg $engine/$tank launched (pid $!)"
  done
  [ "${#pids[@]}" -ge 1 ] || log_fail "No valid legs to run."

  local p; for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done

  # Tabulate. Outcome is judged by each leg's OUTPUT/status, never its exit code.
  local i captured=0 dry=0 other=0 verdict rest
  log_info "conduct results ($out_dir):"
  for i in "${!tags[@]}"; do
    verdict="$(cut -d' ' -f1 < "${stats[$i]}" 2>/dev/null || echo '?')"
    rest="$(cut -s -d' ' -f2- < "${stats[$i]}" 2>/dev/null || true)"
    case "$verdict" in
      CAPTURED) captured=$((captured+1)); log_ok   "  ✔ ${tags[$i]} — captured ($(_burn_size "${outs[$i]}")B) → ${outs[$i]}" ;;
      DRY)      dry=$((dry+1));           log_warn "  ⛽ ${tags[$i]} — ran dry${rest:+  ($rest)}" ;;
      EMPTY)    other=$((other+1));       log_err  "  ✖ ${tags[$i]} — no output (auth / sandbox / no answer)" ;;
      NORECIPE) other=$((other+1));       log_err  "  ✖ ${tags[$i]} — engine has no read-only recipe (adapter_audit_flags)" ;;
      NOPATH)   other=$((other+1));       log_err  "  ✖ ${tags[$i]} — engine binary not on PATH" ;;
      NOTANK)   other=$((other+1));       log_err  "  ✖ ${tags[$i]} — no such tank (clikae tanks to list)" ;;
      *)        other=$((other+1));       log_err  "  ✖ ${tags[$i]} — unknown outcome" ;;
    esac
  done
  log_info "summary: ${captured} captured · ${dry} dry · ${other} other  →  read them in $out_dir, then pick the winner."
  [ "$captured" -ge 1 ]
}
