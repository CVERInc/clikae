# shellcheck shell=bash
# lib/commands/switch.sh — the BARE SWITCH: `clikae <engine> [tank] [-- args]`.
#
# clikae's headline action, and it carries no verb of its own: the program name
# IS the verb (clikae = kirikae, "switch"). `clikae claude work` reads "switch
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

# The tmux layer — session creation, the status bar, attach-or-fall-back — lives
# in lib/core/tmux.sh. It used to live here, which is why burn.sh had to write its
# own and got it wrong. DESIGN-tmux.md Rule 2 asked for one shared set of exits;
# this file is now one of its callers rather than its owner.

_switch_run_tmux_wrapped() {
  local engine="$1" tank="$2" d="$3"; shift 3
  local tank_id="${engine}-${tank}"

  # The tmux session is keyed on WHAT WAS ASKED FOR, not just on the tank.
  #
  # Keying it on the tank alone was a real regression, reproduced 2026-08-13: open
  # `clikae claude x`, then from the board resume a DIFFERENT past session on the
  # same tank, and the second launch found `ck-claude-x` already running and
  # attached to it. Two tabs, one screen — and the `--resume <sid>` was dropped in
  # silence, because nothing was started to receive it.
  #
  # A bare `clikae <engine> <tank>` means "take me to my tank" and must keep the
  # stable name, so leaving and coming back lands in the same place. Passing
  # anything after `--` means "run the engine with THESE arguments", which a
  # session started with different ones cannot satisfy. So the argv gets a short
  # digest appended.
  #
  # Identical requests still collide on purpose: resuming the same session id
  # twice attaches to it, which is exactly the desired answer.
  #
  # cksum, not shasum/md5: POSIX, present everywhere, and this is a namespacing
  # digest — nothing here is a security boundary.
  local sess_id="$tank_id"
  if [ "$#" -gt 0 ]; then
    local _argsum
    _argsum="$(printf '%s\0' "$@" | cksum 2>/dev/null | cut -d' ' -f1)"
    [ -n "$_argsum" ] && sess_id="$tank_id-$_argsum"
  fi

  # What crosses into the session. tmux copies only its `update-environment` list
  # and inherits everything else from the SERVER's process environment — whoever
  # started it, not us — so anything the engine needs is named here explicitly.
  # The SSH agent socket is deliberately NOT in this list: tmux_spawn_session
  # injects clikae's stable symlink for every caller (DESIGN-tmux Rule 4).
  local -a spawn_env=(--env "CLIKAE_TANK_NAME=$tank_id" --env "HOME=$HOME")
  if [ -n "$CLIKAE_HOME" ]; then
    spawn_env+=(--env "CLIKAE_HOME=$CLIKAE_HOME")
  fi

  mkdir -p "$HOME/.clikae/state"

  local target_cmd scrollback_file="$HOME/.clikae/state/ck-$sess_id-$$.scrollback"
  target_cmd="$(printf '%q ' "$CLIKAE_BIN" run "$engine" "$tank" -- "$@")"
  # No -t. This runs INSIDE the pane it is capturing, so the target is implicit —
  # and naming the SESSION here was silently wrong on tmux 3.4: measured on ubuntu
  # CI, `capture-pane -p -S - -t <session>` returned 0 bytes while the same
  # command with no target returned 1717. The scrollback file was therefore empty,
  # `[ -s ]` was false, and the replay this whole feature exists for never ran on
  # Linux — for as long as the feature has existed. macOS (3.7b) resolves a
  # session target to its active pane and hid it completely.
  target_cmd="trap 'tmux capture-pane -p -S - > \"$scrollback_file\" 2>/dev/null' EXIT; $target_cmd"

  # No tmux, or no terminal to attach one to -> run the engine directly. tmux is a
  # convenience layer over `clikae run`, never a dependency: a machine without it
  # (a CI runner, a stripped container) must still switch tanks. Shipped without
  # this check on 2026-08-11 and CI caught it — with tmux shadowed by a stub that
  # exits 127, pty-smoke's "launched engine keeps stdout" and "keeps STDERR" both
  # fail, because the launch went through a tmux that was not there.
  if ! tmux_usable; then
    while IFS= read -r kv; do [ -n "$kv" ] && export "${kv%%=*}"="${kv#*=}"; done <<KV
$(adapter_export_env "$d")
KV
    exec "$CLIKAE_BIN" run "$engine" "$tank" -- "$@"
  fi

  # Settle the wake preference here, while a human is demonstrably present — they
  # just typed the command. Asking at limit time was the original design and it
  # could not work: the question would be posed by a watcher in another window,
  # where nobody would ever see it.
  wake_ask_once "$engine" "$tank"

  if [ -n "$TMUX" ]; then
    local current_pane_session
    current_pane_session="$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null || true)"
    [ -z "$current_pane_session" ] && current_pane_session="$(tmux display-message -p '#S' 2>/dev/null || true)"
    
    tmux has-session -t "ck-$sess_id" 2>/dev/null || \
      tmux_spawn_session "${spawn_env[@]}" \
        --session "ck-$sess_id" --window "$engine" -- "bash -c \"$target_cmd\""
    tmux_label "ck-$sess_id" "$engine" "$tank"
    wake_enabled && wake_attach_watcher "ck-$sess_id" "$engine" "$tank"
    
    local clients
    clients="$(tmux list-clients -t "$current_pane_session" 2>/dev/null || true)"
    if [ -n "$clients" ]; then
      exec tmux switch-client -t "ck-$sess_id"
    fi
  else
    local started_here=0
    if ! tmux has-session -t "ck-$sess_id" 2>/dev/null; then
      tmux_spawn_session "${spawn_env[@]}" \
        --session "ck-$sess_id" --window "$engine" -- "bash -c \"$target_cmd\""
      tmux_label "ck-$sess_id" "$engine" "$tank"
      wake_enabled && wake_attach_watcher "ck-$sess_id" "$engine" "$tank"
      started_here=1
    fi

    # Whether this terminal can host tmux is tmux's call, not ours. `new-session -d`
    # happily succeeds under a TERM tmux cannot draw on (TERM=dumb: "open terminal
    # failed: terminal does not support clear") and only the attach fails — by which
    # point the engine is already running detached, invisible, spending quota. Ask by
    # attaching, and if that is refused put back exactly what we started.
    # An earlier version pre-flighted with `tput clear`, which is a PROXY for tmux's
    # answer: PineNote's ssh sessions arrive as TERM=dumb, so that guard would have
    # quietly taken roaming away from the one device this feature exists for.
    if ! tmux_attach "ck-$sess_id" "$started_here" "$scrollback_file"; then
      while IFS= read -r kv; do [ -n "$kv" ] && export "${kv%%=*}"="${kv#*=}"; done <<KV
$(adapter_export_env "$d")
KV
      exec "$CLIKAE_BIN" run "$engine" "$tank" -- "$@"
    fi
  fi
}

# _switch_supervise <engine> <tank> <dir> [engine-args...]  (BETA, claude + codex)
# Run the engine as a CHILD (so clikae stays the parent), and when it exits, if
# THIS tank just hit its limit, carry onward to the next tank in the burn order
# per the autonomy level. Same-engine → seamless resume (relay); cross-engine →
# a written brief (handoff). One hop per run (the carry execs); relaunch to keep
# going. A no-dry exit behaves exactly like a plain run.
_switch_supervise() {
  local engine="$1" tank="$2" dir="$3"; shift 3
  # Parent ignores INT so Ctrl-C reaches the engine; we resume after it exits.
  trap '' INT
  ( trap - INT; _switch_run_tmux_wrapped "$engine" "$tank" "$dir" "$@" ) || true
  trap - INT

  # Only act if THIS tank is genuinely dry as of now (self-clears if it recovered).
  # NB: both engines' dry state lives in their own transcript (scannable +
  # self-clearing on the next successful turn), so we deliberately do NOT also
  # write dry_store here — a store marker would mask a real recovery. dry_store
  # stays for what a transcript can't cover (a headless codex exec, via burn).
  local reset=""
  reset="$(limit_profile_dry "$engine" "$dir" 2>/dev/null)" || return 0

  # Offered before the carry, because the two answer different questions and the
  # user only ever gets asked the second one: staying put is staying put, being
  # asked where to go next belongs to leaving. Silent unless the session is still
  # alive — this path also runs after the engine EXITED, and an exited engine
  # took its conversation with it, so there is nothing left to resume.
  wake_offer "$engine" "$tank" "$reset"

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
    local target_cmd scrollback_file="$HOME/.clikae/state/ck-$tank_id-$$.scrollback"
    target_cmd="$(printf '%q ' "$CLIKAE_BIN" relay "$engine" "$tank" "$nt" -y)"
  # No -t. This runs INSIDE the pane it is capturing, so the target is implicit —
  # and naming the SESSION here was silently wrong on tmux 3.4: measured on ubuntu
  # CI, `capture-pane -p -S - -t <session>` returned 0 bytes while the same
  # command with no target returned 1717. The scrollback file was therefore empty,
  # `[ -s ]` was false, and the replay this whole feature exists for never ran on
  # Linux — for as long as the feature has existed. macOS (3.7b) resolves a
  # session target to its active pane and hid it completely.
    target_cmd="trap 'tmux capture-pane -p -S - > \"$scrollback_file\" 2>/dev/null' EXIT; $target_cmd"
    
    local -a relay_env=(--env "CLIKAE_TANK_NAME=$tank_id" --env "HOME=$HOME")
    if [ -n "$CLIKAE_HOME" ]; then
      relay_env+=(--env "CLIKAE_HOME=$CLIKAE_HOME")
    fi
    # No SSH_AUTH_SOCK here any more. This site used to pass the symlink path
    # WITHOUT the `ln -sf` that creates it — the interactive path did both, the
    # carry path only the second half, so a carried session could be handed a
    # socket that was never linked. tmux_spawn_session does both, for everyone.

    # The carry runs unattended by definition — the tank went dry mid-session — so
    # every guard the plain switch path grew applies here too, and this site had
    # none of them: no tmux check, a capture without -S - (last screen only), and
    # an attach with nothing to catch its refusal.
    #
    # It is also the path most likely to CREATE the server, precisely because
    # nobody is watching. That is how a server ends up born from a context holding
    # no file-access grant, which no later call can repair (DESIGN-tmux Rule 7).
    if tmux_usable; then
      local started_here=0
      if ! tmux has-session -t "ck-$tank_id" 2>/dev/null; then
        tmux_spawn_session "${relay_env[@]}" \
          --session "ck-$tank_id" --window "$engine" -- "bash -c \"$target_cmd\""
        tmux_label "ck-$tank_id" "$engine" "$tank"
        started_here=1
      fi
      tmux_attach "ck-$tank_id" "$started_here" "$scrollback_file" && return 0
    fi
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

  # Soul: a member tank shares its WHOLE brain — make sure this directory's
  # memory slot is fanned into the store before the engine starts (lib/core/
  # soul.sh; no-op for non-members, solo tanks, pointer engines).
  soul_prelaunch "$engine" "$tank" "$d"
  # Fleet MCP: unlike Soul, this is default-on for every non-solo tank — no
  # per-tank opt-in (lib/core/fleet_mcp.sh; no-op for solo tanks, an empty
  # store, or engines without an adapter_mcp_config_file hook).
  fleet_mcp_prelaunch "$engine" "$tank" "$d"

  # BETA supervised launch: when launched through clikae, watch THIS tank and, on a
  # dry limit, carry onward per `clikae auto`. claude and codex only: both
  # persist their limit to a transcript, so after the engine exits we can tell
  # whether THIS tank is genuinely out of fuel rather than guessing. agy has no
  # per-tank signal to read (one global login), so it is not supervised.
  if [ "$engine" = "claude" ] || [ "$engine" = "codex" ]; then
    _switch_require_binary "$engine" "$tank"
    _switch_supervise "$engine" "$tank" "$d" "${passthru[@]}"
    return $?
  fi

  _switch_require_binary "$engine" "$tank"
  _switch_run_tmux_wrapped "$engine" "$tank" "$d" "${passthru[@]}"   # execs
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
  local mem stash throwaway soul_tgt=""
  mem="$(adapter_memory_dir "$d")"
  [ -n "$mem" ] || log_fail "--ephemeral: '$engine' reported no memory dir for this directory."
  stash="$mem.clikae-ephemeral-stash"

  mkdir -p "$(dirname "$mem")"

  # 🔴 ONE EPHEMERAL PER MEMORY SLOT, and the slot is keyed on $PWD.
  #
  # Two ephemeral runs in the same directory target the same <mem> path, and the
  # second does not merely fail to link: its self-heal step below reads the FIRST
  # run's symlink as a crashed leftover, removes it, and moves the stash back —
  # out from under a live engine. That is the 2026-07-19 incident, and parallel
  # dispatch reaches it on purpose rather than by accident.
  #
  # Measured 2026-08-15: two cold reads launched together in one directory, one
  # died with a bare `ln:` error and no explanation. Three launched in three
  # directories all succeeded, left no residue, and wrote no transcript — which
  # is the shape agents should use, so the failure has to say that rather than
  # leak the first shell error that happened to surface.
  #
  # Same lock mechanism as burn's GC (DESIGN-tmux Rule 6): an fd, held for the
  # life of the process, never unlinked.
  local slot_lock
  slot_lock="${TMPDIR:-/tmp}/ck-ephem-slot-$(printf '%s' "$mem" | cksum | cut -d' ' -f1).lock"
  # 🔴 `lockf -k`. Without -k the lock does not lock: measured 2026-08-15, two
  # processes both got rc=0 from `lockf -t 0 <fd>` on the same file. -k keeps the
  # file on release, and the second holder then gets 75 (EX_TEMPFAIL) — which is
  # what DESIGN-tmux Rule 6 already wrote down after burn's GC hit the same
  # thing. A lock written without it is a guard that is silent on every input.
  local _lrc=0
  exec 8>"$slot_lock"
  if command -v flock >/dev/null 2>&1; then
    flock -n 8 2>/dev/null || _lrc=$?
  else
    lockf -k -t 0 8 2>/dev/null || _lrc=$?
  fi
  if [ "$_lrc" -ne 0 ]; then
    log_fail "--ephemeral: another ephemeral run already holds this directory's memory slot.
         Parallel cold reads need ONE WORKING DIRECTORY EACH — the slot is keyed on \$PWD,
         so runs sharing a directory fight over the same memory link.
         Give each run its own scratch dir (see AGENTS.md § dispatching cold readers)."
  fi

  # A Soul-shared slot is a symlink INTO $CLIKAE_HOME/souls — remember its target
  # so the exit trap can re-link it. (Without this, an ephemeral run on a shared
  # tank silently un-shared this directory: the link read as a crashed run's
  # leftover, got removed, and nothing put it back.)
  if [ -L "$mem" ]; then
    case "$(readlink "$mem" 2>/dev/null || true)" in
      "$(souls_root)"/*) soul_tgt="$(readlink "$mem")" ;;
    esac
  fi
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
  # Restore order: stashed own memory first; else re-link a Soul-shared slot.
  # shellcheck disable=SC2064
  trap "rm -f '$mem'; if [ -d '$stash' ]; then mv '$stash' '$mem'; elif [ -n '$soul_tgt' ]; then ln -s '$soul_tgt' '$mem'; fi; rm -rf '$throwaway'" EXIT
  # A hard terminal close (SIGHUP) or a SIGTERM would otherwise kill the parent
  # WITHOUT running the EXIT trap, leaving memory pointed at the throwaway we're
  # about to delete (dangling) and the real memory stranded in the stash — the
  # 2026-07-19 incident. Re-raise both as a normal exit so the EXIT trap restores.
  # (A SIGKILL or power loss still can't be caught — soul_prelaunch's
  # memory_heal_ephemeral repairs that leftover on the tank's next launch.)
  trap 'exit 129' HUP
  trap 'exit 143' TERM
  trap '' INT

  # Memory was only ever ONE of the channels a session inherits. Ask the adapter
  # for the per-run flags that close the others (skills, the fleet's MCP servers,
  # and — headless only — writing a transcript at all). Per-run on purpose: the
  # alternative, temporarily rewiring the tank's own skills symlink, would mutate
  # a tank another session may be live on, which is the `memory isolate` mistake.
  local -a eph=()
  if declare -F adapter_ephemeral_flags >/dev/null 2>&1; then
    # Claude Code only honours --no-session-persistence with --print, so tell the
    # adapter which shape this run is.
    local headless=0 a
    for a in "$@"; do case "$a" in -p|--print) headless=1; break ;; esac; done
    while IFS= read -r -d '' a; do eph+=("$a"); done < <(adapter_ephemeral_flags "$headless")
    if [ "$headless" -eq 1 ]; then
      log_dim "ephemeral: throwaway memory · no skills · no shared MCP · no transcript written."
    else
      log_dim "ephemeral: throwaway memory · no skills · no shared MCP."
      log_dim "(login is normal, and an INTERACTIVE run still writes a transcript to the tank — incognito here means it doesn't know you, not that it never happened.)"
    fi
  else
    log_dim "ephemeral: this session's memory is a throwaway — nothing here is remembered."
    log_dim "(login & transcript are normal; the tank's real memory is untouched.)"
  fi
  # Run as a CHILD (subshell exec), so the parent resumes and the EXIT trap fires.
  ( adapter_run "$d" "${eph[@]}" "$@" ) || true
}
