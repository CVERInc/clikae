# shellcheck shell=bash
# lib/commands/switch.sh — the BARE SWITCH: `clikae <engine> [tank] [-- args]`.
#
# clikae's headline action, and it carries no verb of its own: the program name
# IS the verb (clikae = 切り替え, "switch"). `clikae claude work` reads "switch
# claude to work". See docs/grammar.md §3.1 / §5.
#
# This handler is reached from the dispatcher when the first argument is an
# installed engine (an adapter in lib/adapters/), not a reserved command.

# _switch_active_tank <engine>  -> the tank active for <engine> in THIS shell
# (resolved from the live env var), or empty. Mirrors `clikae status`.
_switch_active_tank() {
  local engine="$1"
  [ -f "$CLIKAE_LIB/adapters/$engine.sh" ] || return 0
  (
    load_adapter "$engine" >/dev/null 2>&1 || exit 0
    local var strategy value
    var="$(adapter_meta_env_var)"
    [ -n "$var" ] || exit 0     # flag-strategy engines aren't detectable from env
    strategy="$(adapter_meta_strategy)"
    value="${!var}"
    resolve_active_profile "$engine" "$strategy" "$value"
  )
}

# §5 dry-aware guard (option B). Only fires when the tank we're CURRENTLY on for
# this engine in this shell is over quota — the one moment a silent fresh start
# is the opposite of intent. Otherwise switching is silent and instant.
# May exec (carry); if it returns, the caller proceeds with a fresh start.
_switch_dry_guard() {
  local engine="$1" current="$2" tank="$3" cur_dir
  cur_dir="$(profile_dir "$engine" "$current")"
  limit_profile_dry "$engine" "$cur_dir" >/dev/null 2>&1 || return 0

  if [ -t 0 ] && [ -t 1 ]; then
    log_warn "$engine/$current is out of fuel right now."
    printf '  Carry this session over to %b%s%b, or start it fresh?\n' \
      "$__C_BOLD" "$tank" "$__C_RESET"
    printf '    %b[c]%b carry over (resume)   %b[f]%b start fresh   %b[q]%b cancel: ' \
      "$__C_GREEN" "$__C_RESET" "$__C_DIM" "$__C_RESET" "$__C_DIM" "$__C_RESET"
    local ans; IFS= read -r ans || ans="q"
    case "$ans" in
      # Carry: hand to `clikae to` (same engine -> relay, with its own preview +
      # confirm, so carrying is never a blind leap).
      c|C|"") exec "$CLIKAE_BIN" to "$engine" "$tank" ;;
      f|F)    return 0 ;;
      *)      log_info "Cancelled — staying on $engine/$current."; exit 0 ;;
    esac
  else
    log_dim "hint: $engine/$current is dry — to continue this session use:  clikae to $engine $tank"
    return 0
  fi
}

_switch_help() {
  cat <<'EOF'
Usage: clikae <engine> [tank] [-- args...]

The bare switch — clikae's main action. Switch <engine> to <tank> and run it.
The verb is the program name (clikae = "switch"), so none is typed.

  clikae claude work            switch claude to the 'work' tank and run it
  clikae claude                 if claude has one tank, use it; else list them
  clikae claude work -- --help  pass everything after -- straight to the engine
  clikae claude work --ephemeral  run with throwaway memory (see below)

Options:
  --ephemeral   Run with EPHEMERAL memory: this session's long-term memory goes
                to a throwaway that's discarded on exit, and the tank's real
                memory is left untouched. Login and transcripts are normal — only
                the memory store is throwaway. (Honest scope: clikae guarantees
                the memory dir is throwaway; it can't promise the engine remembers
                nothing *anywhere* — caches, shell history, etc. are out of reach.)
                Supported only for engines clikae knows the memory layout of
                (claude). Runs the engine as a child (not exec) so cleanup runs.

To carry your current session onto another tank instead of starting fresh,
use `clikae to` (see: clikae help to).
EOF
}

# _supervise_decision <level> <same-engine?1|0>  -> auto | ask | pause
# The autonomy gate, factored out so it's unit-testable. full → always auto; safe
# → auto for same-engine, pause (ask) before crossing; ask → always ask.
_supervise_decision() {
  case "$1" in
    full) printf 'auto' ;;
    safe) [ "$2" = "1" ] && printf 'auto' || printf 'pause' ;;
    *)    printf 'ask' ;;
  esac
}

# _switch_supervise <engine> <tank> <dir> [engine-args...]  (BETA, claude-only)
# Run the engine as a CHILD (so clikae stays the parent), and when it exits, if
# THIS tank just hit its limit, carry onward to the next tank in the burn order
# per the autonomy level. Same-engine → seamless resume (relay); cross-engine →
# a written brief (handoff). One hop per run (the carry execs); relaunch to keep
# going. A no-dry exit behaves exactly like a plain run.
_switch_supervise() {
  local engine="$1" tank="$2" dir="$3"; shift 3
  # Parent ignores INT so Ctrl-C reaches the engine; we resume after it exits.
  trap '' INT
  ( trap - INT; adapter_run "$dir" "$@" ) || true
  trap - INT

  # Only act if THIS tank is genuinely dry as of now (self-clears if it recovered).
  # NB: claude's dry state lives in its transcript (scannable + self-clearing on
  # the next successful turn), so we deliberately do NOT also write dry_store here —
  # a 6h store marker would mask a real recovery. dry_store is for engines whose
  # limit is NOT in a transcript (codex, via burn).
  limit_profile_dry "$engine" "$dir" >/dev/null 2>&1 || return 0

  local _next ne nt
  _next="$(next_tank "$engine" "$tank")"
  if [ -z "$_next" ]; then
    log_warn "$engine/$tank is out of fuel — and nothing follows it in your burn order."
    log_dim  "Add a tank (clikae init …) or reorder on the board (clikae)."
    return 0
  fi
  IFS=$'\t' read -r ne nt <<EOF
$_next
EOF
  local same=0; [ "$ne" = "$engine" ] && same=1
  local level decision; level="$(autonomy_get)"; decision="$(_supervise_decision "$level" "$same")"

  if [ "$decision" != "auto" ]; then
    if [ -t 0 ] && [ -t 1 ]; then
      printf '\n'; log_warn "$engine/$tank hit its limit."
      if [ "$decision" = "pause" ]; then
        printf '  Next in your order is %b%s/%s%b — a different engine (a fresh brief, not a resume).\n' "$__C_BOLD" "$ne" "$nt" "$__C_RESET"
      else
        printf '  Carry on to %b%s/%s%b?\n' "$__C_BOLD" "$ne" "$nt" "$__C_RESET"
      fi
      printf '    %b[y]%b once   %b[a]%b always   %b[N]%b stop: ' \
        "$__C_GREEN" "$__C_RESET" "$__C_GREEN" "$__C_RESET" "$__C_DIM" "$__C_RESET"
      local ans; IFS= read -r ans </dev/tty || ans="N"
      case "$ans" in
        y|Y) : ;;
        a|A) autonomy_set safe ;;
        *)   log_dim "Stopped on $engine/$tank. Continue later:  clikae to"; return 0 ;;
      esac
    else
      log_dim "$engine/$tank is dry. Continue:  clikae to"
      return 0
    fi
  fi

  history_log "auto: $engine/$tank dry → $ne/$nt"
  printf '%b↻ %s/%s hit its limit — carrying on to %s/%s%b\n' "$__C_GREEN" "$engine" "$tank" "$ne" "$nt" "$__C_RESET"
  if [ "$same" = "1" ]; then
    exec "$CLIKAE_BIN" relay "$engine" "$tank" "$nt" -y
  else
    exec "$CLIKAE_BIN" handoff "$engine" "$tank" --to "$ne/$nt"
  fi
}

cmd_switch() {
  local engine="$1"; shift || true
  local tank="" ephemeral=0
  local -a passthru=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --)          shift; passthru=("$@"); break ;;
      -h|--help)   _switch_help; return 0 ;;
      --ephemeral) ephemeral=1; shift ;;
      -*)          log_fail "Unknown flag: $1  (engine flags go after --)" ;;
      *)           if [ -z "$tank" ]; then tank="$1"; shift; else break; fi ;;
    esac
  done

  validate_name cli "$engine"

  # No tank: 0 -> offer to create; 1 -> use it; many -> list and ask.
  if [ -z "$tank" ]; then
    local tanks count
    tanks="$(list_all_profiles | awk -F'\t' -v e="$engine" '$1==e{print $2}')"
    count="$(printf '%s\n' "$tanks" | grep -c . || true)"
    if [ "$count" -eq 0 ]; then
      log_info "No $engine tanks yet."
      log_dim  "Create one:  clikae init $engine <tank>"
      return 0
    elif [ "$count" -eq 1 ]; then
      tank="$tanks"
    else
      log_info "$engine has several tanks — pick one:"
      printf '%s\n' "$tanks" | while IFS= read -r t; do
        [ -n "$t" ] && printf '    clikae %s %s\n' "$engine" "$t"
      done
      return 0
    fi
  fi

  validate_name profile "$tank"
  profile_exists "$engine" "$tank" \
    || log_fail "No such tank: $engine/$tank  (create it:  clikae init $engine $tank)"

  # §5: only nags when the current tank is dry; otherwise silent.
  local current
  current="$(_switch_active_tank "$engine")"
  if [ -n "$current" ] && [ "$current" != "$tank" ]; then
    _switch_dry_guard "$engine" "$current" "$tank"
  fi

  # Fresh switch: apply the tank's env and run the engine.
  local d
  d="$(ensure_profile --require "$engine" "$tank")"
  load_adapter "$engine"

  if [ "$ephemeral" -eq 1 ]; then
    _switch_run_ephemeral "$engine" "$tank" "$d" "${passthru[@]}"
    return $?
  fi

  # BETA supervised launch: when launched through clikae, watch THIS tank and, on a
  # dry limit, carry onward per `clikae auto`. claude-only for now — its limit is
  # detectable from the transcript; other engines exec unchanged. (docs/DESIGN-runtime)
  if [ "$engine" = "claude" ]; then
    _switch_require_binary "$engine" "$tank"
    _switch_supervise "$engine" "$tank" "$d" "${passthru[@]}"
    return $?
  fi

  _switch_require_binary "$engine" "$tank"
  adapter_run "$d" "${passthru[@]}"   # execs
}

# clikae switches accounts; it does NOT install the engine. If the binary isn't on
# PATH, the run paths would die with a bare "exec: <bin>: not found" (the #1
# first-run confusion — see the launcher journey). Say so helpfully, with a
# per-engine install hint when the adapter defines one. Call this right before a
# run path execs — AFTER flag validation (e.g. --ephemeral support) so the more
# specific error wins. Requires the adapter to be loaded.
_switch_require_binary() {
  local engine="$1" tank="$2" bin
  bin="$(adapter_meta_cli_binary)"
  command -v "$bin" >/dev/null 2>&1 && return 0
  log_err "Switched to $engine/$tank, but '$bin' isn't installed (not on your PATH)."
  if declare -F adapter_install_hint >/dev/null 2>&1; then
    log_dim "Install it, then retry:  $(adapter_install_hint)"
  else
    log_dim "clikae switches accounts; it doesn't install the CLI — install '$bin' and retry."
  fi
  exit 127
}

# Run the engine with EPHEMERAL memory: point its memory dir at a throwaway that's
# discarded on exit; the tank's real memory is stashed aside and restored. Unlike
# the normal switch we DON'T exec — clikae stays as the parent so cleanup can run
# when the engine quits. See docs/grammar.md §10.4.
_switch_run_ephemeral() {
  local engine="$1" tank="$2" d="$3"; shift 3
  declare -F adapter_memory_dir >/dev/null \
    || log_fail "--ephemeral isn't supported for '$engine' (clikae doesn't know its memory layout)."
  _switch_require_binary "$engine" "$tank"   # after the --ephemeral support check, before we run
  local mem stash throwaway
  mem="$(adapter_memory_dir "$d")"
  [ -n "$mem" ] || log_fail "--ephemeral: '$engine' reported no memory dir for this directory."
  stash="$mem.clikae-ephemeral-stash"

  mkdir -p "$(dirname "$mem")"
  # Self-heal a crashed prior run: a leftover symlink + a stash holding the real
  # memory. Remove the dangling link and put the real memory back first.
  [ -L "$mem" ] && rm -f "$mem"
  [ -d "$stash" ] && [ ! -e "$mem" ] && mv "$stash" "$mem"
  # Stash the real memory (if any) and point at a throwaway.
  [ -e "$mem" ] && [ ! -L "$mem" ] && mv "$mem" "$stash"
  throwaway="$(mktemp -d "${TMPDIR:-/tmp}/clikae-ephemeral.XXXXXX")"
  ln -s "$throwaway" "$mem"

  # Cleanup on exit, with literal paths captured now (survives scope). The parent
  # ignores INT so Ctrl-C reaches the engine; cleanup fires on the parent's exit.
  # shellcheck disable=SC2064
  trap "rm -f '$mem'; [ -d '$stash' ] && mv '$stash' '$mem'; rm -rf '$throwaway'" EXIT
  trap '' INT

  log_dim "ephemeral: this session's memory is a throwaway — nothing here is remembered."
  log_dim "(login & transcript are normal; the tank's real memory is untouched.)"
  # Run as a CHILD (subshell exec), so the parent resumes and the EXIT trap fires.
  ( adapter_run "$d" "$@" ) || true
}
