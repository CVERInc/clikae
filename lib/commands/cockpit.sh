# shellcheck shell=bash
# lib/commands/cockpit.sh — `clikae cockpit <tank>`: mark the tank that STEERS
# (the coordinating session dispatching build/review lanes to worker tanks via
# `clikae burn`), and install/remove the guard that enforces it (#63).
#
# Why: a coordinating session that spawns build/review lanes through its own
# in-session Agent tool spends ITS OWN weekly budget on work meant for a
# worker tank — the rule "dispatch, don't spawn" lived only in memory, and
# broke exactly when the session was busiest (2026-09-10: four sonnet/opus
# lanes spawned in-session from the cockpit tank). This makes the rule the
# machine's problem: `clikae cockpit <tank>` installs a PreToolUse hook
# (lib/hooks/cockpit-guard.sh) on that ONE tank's settings.json, and moving
# the role removes it from the old tank and installs it on the new one — the
# guard lives with the ROLE, never hand-copied into a profile.
#
# State: $CLIKAE_HOME/state/cockpit — one line, "<engine>/<tank>" (absent =
# no cockpit). The settings.json edit itself rides #76/#85's write mechanism
# (_settings_write_file, lib/commands/settings.sh) — union merge onto the
# tank's hooks.PreToolUse array, identified by a marker key ("_clikae":
# "cockpit-guard") on OUR array entry so a human's own hooks (any entry
# without that marker, any other hook event) are never touched.

_cockpit_state_file() { printf '%s/state/cockpit\n' "$CLIKAE_HOME"; }
_cockpit_allow_file() { printf '%s/state/cockpit-allow\n' "$CLIKAE_HOME"; }

# _cockpit_state_read -> "<engine>/<tank>" from the state file, or nothing.
_cockpit_state_read() {
  local f; f="$(_cockpit_state_file)"
  [ -f "$f" ] || return 0
  head -n 1 "$f" 2>/dev/null | tr -d '\n' || true
}

_cockpit_state_write() {
  local f; f="$(_cockpit_state_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || { log_err "Could not create $(dirname "$f")"; return 1; }
  printf '%s/%s\n' "$1" "$2" > "$f" || { log_err "Could not write $f"; return 1; }
}

_cockpit_state_clear() { rm -f "$(_cockpit_state_file)" 2>/dev/null || true; }

# _cockpit_hook_install <engine> <tank> -> install OUR PreToolUse block on
# this tank's settings.json (union merge, backup, idempotent — see
# lib/commands/settings.sh's _settings_write_file). Prints one status line.
_cockpit_hook_install() {
  local engine="$1" tank="$2" file input new changed
  # shellcheck source=./settings.sh
  source "$CLIKAE_LIB/commands/settings.sh"
  file="$(profile_dir "$engine" "$tank")/settings.json"
  if [ -L "$file" ] || { [ -e "$file" ] && [ ! -f "$file" ]; }; then
    printf '%s/%s: skipped — settings.json is not a regular, unlinked file\n' "$engine" "$tank"
    return 1
  fi
  input="$file"; [ -e "$file" ] || input=/dev/null
  if ! new="$(jq -n --arg cmd "$CLIKAE_LIB/hooks/cockpit-guard.sh" --slurpfile current "$input" '
      def valid: type == "object";
      if ($current | length) > 1 or (($current | length) == 1 and ($current[0] | valid | not))
        then error("invalid settings") else . end |
      ($current[0] // {}) as $old |
      ($old.hooks.PreToolUse // []) as $pre |
      ($pre | map(select((._clikae // "") != "cockpit-guard"))) as $rest |
      (($pre | map(select((._clikae // "") == "cockpit-guard"))) as $ours |
        (($ours | length) == 1
         and ($ours[0].matcher == "Agent")
         and (($ours[0].hooks // [])[0].command == $cmd)
         and (($ours[0].hooks // [])[0].timeout == 5))) as $already |
      { changed: ($already | not),
        settings: ($old | .hooks.PreToolUse =
          ($rest + [{matcher: "Agent",
                     hooks: [{type: "command", command: $cmd, timeout: 5}],
                     _clikae: "cockpit-guard"}])) }
    ' 2>/dev/null)"; then
    printf '%s/%s: skipped — invalid JSON in settings.json\n' "$engine" "$tank"
    return 1
  fi
  changed="$(printf '%s' "$new" | jq -r .changed)"
  if [ "$changed" = "false" ]; then
    printf '%s/%s: cockpit guard already installed (unchanged)\n' "$engine" "$tank"
    return 0
  fi
  # #63 P2-4: check the jq substitution's OWN exit status before handing its
  # output to the writer — command substitution swallows a failing jq's exit
  # code otherwise, and `_settings_write_file` would just see an empty string.
  local settings_out
  settings_out="$(printf '%s' "$new" | jq '.settings')" || {
    printf '%s/%s: jq failed while preparing settings.json\n' "$engine" "$tank" >&2
    return 1
  }
  _settings_write_file "$file" "$settings_out" "$engine/$tank" || return 1
  # #63 P3-12: the hook command written above is $CLIKAE_LIB's OWN resolved
  # path (bin/clikae's `__resolve_self`) — for a real install (install.sh,
  # Homebrew) that's a stable location, but running `clikae` straight out of
  # a git checkout or worktree bakes THAT checkout's path in instead. Remove
  # or garbage-collect the checkout later and the guard goes permanently,
  # silently silent (command not found -> non-2 exit -> fail-open) with
  # nothing — not even `clikae doctor` — ever noticing. One line at install
  # time beats nothing noticing at all.
  if [ -e "$CLIKAE_LIB/../.git" ]; then
    printf '%s/%s: warning — installing from a git checkout (%s); the guard goes silent if that checkout is ever removed. A real install (install.sh or Homebrew) keeps a stable path.\n' \
      "$engine" "$tank" "$CLIKAE_LIB" >&2
  fi
  printf '%s/%s: cockpit guard installed\n' "$engine" "$tank"
}

# _cockpit_hook_remove <engine> <tank> -> remove ONLY our marked block. Empties
# `hooks.PreToolUse` (and `hooks` itself) rather than leaving a dangling `[]`
# when nothing else used them — so a tank that had no hooks before we visited
# it comes back exactly as it was. Prints one status line.
_cockpit_hook_remove() {
  local engine="$1" tank="$2" file new changed
  # shellcheck source=./settings.sh
  source "$CLIKAE_LIB/commands/settings.sh"
  file="$(profile_dir "$engine" "$tank")/settings.json"
  if [ ! -f "$file" ]; then
    printf '%s/%s: cockpit guard not installed here (unchanged)\n' "$engine" "$tank"
    return 0
  fi
  if [ -L "$file" ]; then
    printf '%s/%s: skipped — settings.json is a symlink\n' "$engine" "$tank"
    return 1
  fi
  if ! new="$(jq '
      ((.hooks.PreToolUse // []) | map(select((._clikae // "") == "cockpit-guard"))) as $ours |
      if ($ours | length) == 0 then
        { changed: false, settings: . }
      else
        ((.hooks.PreToolUse // []) | map(select((._clikae // "") != "cockpit-guard"))) as $rest |
        ( if ($rest | length) == 0 then
            ( if has("hooks") then
                (.hooks |= del(.PreToolUse)) |
                (if (.hooks | length) == 0 then del(.hooks) else . end)
              else . end )
          else
            (.hooks.PreToolUse = $rest)
          end
        ) as $out |
        { changed: true, settings: $out }
      end
    ' "$file" 2>/dev/null)"; then
    printf '%s/%s: skipped — invalid JSON in settings.json\n' "$engine" "$tank"
    return 1
  fi
  changed="$(printf '%s' "$new" | jq -r .changed)"
  if [ "$changed" = "false" ]; then
    printf '%s/%s: cockpit guard not installed here (unchanged)\n' "$engine" "$tank"
    return 0
  fi
  # #63 P2-4: see _cockpit_hook_install's matching comment.
  local settings_out
  settings_out="$(printf '%s' "$new" | jq '.settings')" || {
    printf '%s/%s: jq failed while preparing settings.json\n' "$engine" "$tank" >&2
    return 1
  }
  _settings_write_file "$file" "$settings_out" "$engine/$tank" || return 1
  printf '%s/%s: cockpit guard removed\n' "$engine" "$tank"
}

_cockpit_show() {
  local cur; cur="$(_cockpit_state_read)"
  if [ -z "$cur" ]; then
    printf 'No cockpit set.\n'
    printf 'clikae cockpit <tank>  marks the tank that dispatches build/review lanes via `clikae burn` instead of spawning them in-session — see clikae help cockpit.\n'
  else
    printf 'cockpit: %s\n' "$cur"
    # #63 P3-8: the move path already warns when the RECORDED cockpit no
    # longer exists (cockpit.sh, _cockpit_move); bare `clikae cockpit` never
    # did, so a tank deleted out from under the role showed as if nothing
    # were wrong. `--off` is the fix either way (it sweeps every tank, not
    # just this stale record), so name it.
    local cur_engine="${cur%%/*}" cur_tank="${cur#*/}"
    if ! profile_exists "$cur_engine" "$cur_tank" 2>/dev/null; then
      printf 'warning: %s no longer exists; run `clikae cockpit --off` to clear the stale state.\n' "$cur" >&2
    fi
  fi
}

# _cockpit_resolve <args...> -> echo "engine\ttank", or log_fail/exit 1.
# One arg: resolved across engines the way bare `clikae <name>` is (bin/clikae)
# — unique tank name across all engines wins, ambiguous asks to qualify. Two
# args: engine + tank, explicit.
_cockpit_resolve() {
  case "$#" in
    1)
      local matches n
      matches="$(resolve_tank_name "$1" 2>/dev/null || true)"
      n="$(printf '%s\n' "$matches" | grep -c . || true)"
      if [ "$n" -eq 0 ]; then
        log_fail "Unknown tank: $1"
      elif [ "$n" -gt 1 ]; then
        log_err "Ambiguous tank name: $1  (exists in more than one engine)"
        printf '%s\n' "$matches" | while IFS=$'\t' read -r e t; do
          [ -n "$e" ] && log_dim "  clikae cockpit $e $t"
        done
        exit 1
      fi
      printf '%s\n' "$matches"
      ;;
    2) printf '%s\t%s\n' "$1" "$2" ;;
    *) log_fail "Usage: clikae cockpit [<engine>] <tank>  |  --off  |  --allow-agents <dur>" ;;
  esac
}

_cockpit_move() {
  local resolved engine tank
  resolved="$(_cockpit_resolve "$@")"
  engine="$(printf '%s' "$resolved" | cut -f1)"
  tank="$(printf '%s' "$resolved" | cut -f2)"
  validate_name cli "$engine"
  validate_name profile "$tank"
  profile_exists "$engine" "$tank" || log_fail "Tank does not exist: $engine/$tank"
  command -v jq >/dev/null 2>&1 || log_fail "cockpit requires jq to edit settings.json"

  local cur cur_engine="" cur_tank=""
  cur="$(_cockpit_state_read)"
  if [ -n "$cur" ]; then
    cur_engine="${cur%%/*}"; cur_tank="${cur#*/}"
  fi

  if [ "$cur_engine" = "$engine" ] && [ "$cur_tank" = "$tank" ]; then
    # Already the cockpit — repair a drifted install (e.g. hand-edited
    # settings.json) but otherwise this is the idempotent no-op.
    _cockpit_hook_install "$engine" "$tank"
    return 0
  fi

  # #63 P2-2 (round-2 review): this used to be a bare `_cockpit_hook_remove`
  # call. `bin/clikae` runs under `set -eo pipefail`, so ANY failure here (a
  # hand-edited settings.json with invalid JSON, a symlinked settings.json —
  # the exact shapes `--off`'s own P1-3 fix already learned to sweep past)
  # aborted the whole move before it ever reached `_cockpit_hook_install`
  # below: the operator asked to move the role, got one stdout line naming
  # the OLD tank's problem, rc=1, and the role hadn't moved at all — no new
  # guard, no state write, no hint what to do next. Same lesson as `--off`:
  # collect the failure, warn, and keep going. rc=1 is reserved for the one
  # failure that actually matters here — the NEW tank couldn't be armed.
  if [ -n "$cur_engine" ] && profile_exists "$cur_engine" "$cur_tank"; then
    _cockpit_hook_remove "$cur_engine" "$cur_tank" || log_warn "cockpit: could not clean up the old cockpit ($cur_engine/$cur_tank) — its guard was NOT removed; run \`clikae cockpit --off\` to clear it."
  elif [ -n "$cur_engine" ]; then
    log_warn "cockpit: recorded cockpit $cur_engine/$cur_tank no longer exists; dropping the record."
  fi
  _cockpit_hook_install "$engine" "$tank" || log_fail "cockpit: could not install the guard on $engine/$tank"
  _cockpit_state_write "$engine" "$tank"
}

# --off sweeps every tank (not just the one the state file names) so a state
# file left stale by a crash mid-move can never leave a guard stranded behind.
# #63 P1-3: this is the escape hatch of last resort — the sweep must never
# abort partway through. `bin/clikae` runs under `set -eo pipefail`, so a bare
# `_cockpit_hook_remove` call that fails (invalid JSON, a symlink, …) on the
# FIRST tank `list_all_profiles`' `| sort` puts in front of a real cockpit
# tank used to kill the whole loop before it ever reached that tank — the
# guard stayed installed, and the operator's one way out did nothing and
# printed a message about some OTHER tank. `|| failed="…"` below turns every
# per-tank failure into bookkeeping instead of an abort; state and the timed
# allowance are always cleared regardless, and a non-zero rc (P3-14) names
# exactly which tanks still need attention rather than staying silent about it.
_cockpit_off() {
  command -v jq >/dev/null 2>&1 || log_fail "cockpit requires jq to edit settings.json"
  local cli profile path any=0 had_state=0 failed=""
  [ -f "$(_cockpit_state_file)" ] && had_state=1
  while IFS=$'\t' read -r cli profile path; do
    [ -n "$cli" ] || continue
    [ -f "$path/settings.json" ] || continue
    grep -q '"_clikae"[[:space:]]*:[[:space:]]*"cockpit-guard"' "$path/settings.json" 2>/dev/null || continue
    any=1
    _cockpit_hook_remove "$cli" "$profile" || failed="$failed $cli/$profile"
  done <<EOF
$(list_all_profiles)
EOF
  _cockpit_state_clear
  rm -f "$(_cockpit_allow_file)" 2>/dev/null || true
  if [ -n "$failed" ]; then
    log_err "cockpit: --off could not clean up:$failed — fix their settings.json and run --off again"
    return 1
  fi
  if [ "$any" -eq 0 ] && [ "$had_state" -eq 0 ]; then
    printf 'cockpit: already off (unchanged)\n'
  else
    printf 'cockpit: off\n'
  fi
}

_cockpit_allow_agents() {
  local dur="$1" secs exp hhmm f
  secs="$(_burn_parse_duration "$dur")" || log_fail "Not a duration: $dur (e.g. 30m, 4h, 1d)"
  exp=$(( $(date +%s 2>/dev/null || echo 0) + secs ))
  f="$(_cockpit_allow_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || log_fail "Could not create $(dirname "$f")"
  printf '%s\n' "$exp" > "$f" || log_fail "Could not write $f"
  hhmm="$(date -d "@$exp" '+%H:%M' 2>/dev/null || date -r "$exp" '+%H:%M' 2>/dev/null)"
  printf 'cockpit: agent spawns allowed until %s\n' "${hhmm:-$exp}"
}

_cockpit_help() {
  cat <<'EOF'
Usage: clikae cockpit                     show the current cockpit (or none)
       clikae cockpit [<engine>] <tank>   mark this tank as the cockpit
       clikae cockpit --off               remove the guard everywhere
       clikae cockpit --allow-agents <dur>  temporarily allow in-session Agent
                                          spawns (e.g. 30m, 4h, 1d)

The cockpit is the tank that STEERS: it dispatches build/review lanes to
worker tanks with `clikae burn` instead of spawning them in its own session
(which would spend the cockpit's own weekly budget on work meant for a
worker). Marking a tank installs a PreToolUse hook there that refuses an
in-session Agent spawn that reads as a build/review lane; moving the role
removes the hook from the old tank and installs it on the new one.

A bare tank name resolves the way `clikae <name>` does: unique across every
engine wins, ambiguous asks you to qualify it (clikae cockpit <engine> <tank>).

The prompt heuristic is a tripwire, not a classifier: an innocuous prompt
that merely mentions "worktree", "commit", "push", "review", etc. can still
get refused. That's expected — use --allow-agents below, not a bug report.
See docs/usage.md's cockpit section for the measured hit rate.

Installing/removing the guard round-trips settings.json through jq: key
order gets normalized and CRLF becomes LF. Content survives intact; exact
byte-for-byte formatting does not.

Escape hatch — the operator sometimes rules "burn the cockpit tank tonight":
CLIKAE_COCKPIT_ALLOW_AGENTS=1 in the environment, or a timed allowance from
--allow-agents, lift the guard without removing it. --off clears both the
guard (everywhere, sweeping every tank without aborting on a broken one) and
any live --allow-agents allowance.
EOF
}

cmd_cockpit() {
  case "${1:-}" in
    -h|--help) _cockpit_help; return 0 ;;
    --off)     shift; [ $# -eq 0 ] || log_fail "Unexpected argument: $1"; _cockpit_off ;;
    --allow-agents)
      shift; [ $# -eq 1 ] || log_fail "--allow-agents needs exactly one duration (e.g. 4h)"
      _cockpit_allow_agents "$1" ;;
    '') _cockpit_show ;;
    *) _cockpit_move "$@" ;;
  esac
}
