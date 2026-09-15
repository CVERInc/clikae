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
# the role installs it on the new tank FIRST and only removes it from the
# old tank once the new one is armed and recorded (#63 P2-1, round-4
# review) — the guard lives with the ROLE, never hand-copied into a profile.
#
# State: $CLIKAE_HOME/state/cockpit — one line, "<engine>/<tank>" (absent =
# no cockpit). The settings.json edit itself rides #76/#85's write mechanism
# (_settings_write_file, lib/commands/settings.sh) — union merge onto the
# tank's hooks.PreToolUse array, identified by a marker key ("_clikae":
# "cockpit-guard") on OUR array entry so a human's own hooks (any entry
# without that marker, any other hook event) are never touched.

_cockpit_state_file() { printf '%s/state/cockpit\n' "$CLIKAE_HOME"; }
_cockpit_allow_file() { printf '%s/state/cockpit-allow\n' "$CLIKAE_HOME"; }

# _cockpit_state_path_ok -> 0 when the state file is safe to read and replace:
# neither it nor its directory is a symlink, and it is a regular file if it
# exists at all. #63 round-5 P2-3: a state path symlinked at B's settings.json
# used to be followed by `printf > "$f"`, replacing B's freshly guarded JSON
# with the text "claude/B" — rc=0, state named B, B unguarded and invalid.
_cockpit_state_path_ok() {
  local f d; f="$(_cockpit_state_file)"; d="${f%/*}"
  [ ! -L "$d" ] && [ ! -L "$f" ] || return 1
  [ ! -e "$f" ] || [ -f "$f" ]
}

# _cockpit_state_read -> "<engine>/<tank>" from the state file, or nothing —
# nothing, too, when the path is not safe (_cockpit_state_path_ok): a symlink
# is never followed to read someone else's bytes as the cockpit's name.
_cockpit_state_read() {
  local f; f="$(_cockpit_state_file)"
  _cockpit_state_path_ok || return 0
  [ -f "$f" ] || return 0
  head -n 1 "$f" 2>/dev/null | tr -d '\n' || true
}

# _cockpit_state_unparseable -> 0 when the state PATH exists (regular file,
# symlink, or unreadable) but does not read back as a clean "<engine>/<tank>"
# record; 1 when it simply does not exist at all (ordinary "no cockpit" —
# unchanged) or does parse cleanly.
#
# #63 round-6 P3-2: mode 000, a symlink, or content with a stray CR
# (`codex/H\r\n`, e.g. hand-edited on Windows) all make _cockpit_state_read
# return EMPTY — read failure and "no cockpit" produce the identical empty
# string. _cockpit_is_recorded then can't tell a corrupt record from an
# absent one, and every burn gate (_burn_cockpit_gate) waved launches
# straight through onto the very tank the file was failing to protect. A
# state file that exists but cannot be read is a reason to refuse every
# burn, not a reason to open the gate — this predicate is that distinction.
_cockpit_state_unparseable() {
  local f raw
  f="$(_cockpit_state_file)"
  { [ -e "$f" ] || [ -L "$f" ]; } || return 1   # no path at all -> ordinary "no cockpit"
  _cockpit_state_path_ok || return 0            # symlink (file or dir) -> unparseable
  raw="$(cat "$f" 2>/dev/null)" || return 0     # unreadable (e.g. mode 000) -> unparseable
  printf '%s' "$raw" | LC_ALL=C grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' && return 1
  return 0                                      # extra bytes, CR, no '/', etc -> unparseable
}

# _cockpit_state_names <engine/tank or empty> -> 0 when the committed state,
# re-read from disk, says exactly that ("" = no cockpit: absent or empty).
_cockpit_state_names() {
  _cockpit_state_path_ok || return 1
  [ "$(_cockpit_state_read)" = "$1" ]
}

# _cockpit_state_write <engine> <tank> -> commit the record atomically.
#
# #63 round-5 P2-3: this used to be `printf … > "$f"` straight onto the live
# file. The redirection truncates before a byte is written, so a crash there
# left an EMPTY state (the review killed it mid-write: no cockpit recorded,
# both tanks guarded, doctor silent), and a short write left a PREFIX (an
# 8-byte RLIMIT_FSIZE made "claude/B\n" into "claude/B" — a valid name for a
# tank the rollback then disarmed). Now: refuse an unsafe path, write a fresh
# file in the same directory, check it holds every byte, and rename it over
# the old one. Any failure leaves the previous committed state untouched.
_cockpit_state_write() {
  local f d tmp want="$1/$2" size
  f="$(_cockpit_state_file)"; d="${f%/*}"
  mkdir -p "$d" 2>/dev/null || { log_err "Could not create $d"; return 1; }
  _cockpit_state_path_ok || { log_err "Refusing to write $f: it, or $d, is a symlink or not a regular file"; return 1; }
  tmp="$(mktemp "$d/.cockpit.XXXXXX" 2>/dev/null)" || { log_err "Could not create a temp file in $d"; return 1; }
  if ! printf '%s/%s\n' "$1" "$2" > "$tmp"; then
    rm -f "$tmp"; log_err "Could not write $f"; return 1
  fi
  size="$(wc -c < "$tmp" 2>/dev/null | tr -d ' ')"
  if [ "$size" != "$(( ${#want} + 1 ))" ] || [ "$(head -n 1 "$tmp")" != "$want" ]; then
    rm -f "$tmp"; log_err "Could not write $f (short write)"; return 1
  fi
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; log_err "Could not replace $f"; return 1; }
  _cockpit_state_names "$want" || { log_err "$f does not read back as $want"; return 1; }
  # #63 round-6 P3-3: a SIGKILL between this mktemp and the mv above leaves a
  # `.cockpit.XXXXXX` scratch file behind in $d forever — harmless, but
  # nobody sweeps it. Our own tmp is already gone (renamed to $f above), so
  # any ".cockpit.*" still here is a stray from an earlier crashed write;
  # clean it up now that we know THIS write landed successfully.
  find "$d" -maxdepth 1 -name '.cockpit.*' -exec rm -f {} + 2>/dev/null || true
}

_cockpit_state_clear() { rm -f "$(_cockpit_state_file)" 2>/dev/null || true; }

# _cockpit_is_recorded <engine> <tank> -> 0 when <engine>/<tank> IS the
# recorded cockpit: by name (agy and antigravity are one engine), or by the
# physical identity of the tank directory (`-ef`: a symlink alias of the
# cockpit is still the cockpit). The one predicate every launch path asks —
# `clikae burn`'s explicit target, its reroute hops, agy's walk (#63 round-5
# P2-1) — so none of them can disagree about what "the cockpit" means.
_cockpit_is_recorded() {
  local e="$1" t="$2" cur ce ct
  cur="$(_cockpit_state_read)"
  [ -n "$cur" ] || return 1
  ce="${cur%%/*}"; ct="${cur#*/}"
  [ "$ce" = agy ] && ce=antigravity
  [ "$e" = agy ] && e=antigravity
  [ "$ce" = "$e" ] && [ "$ct" = "$t" ] && return 0
  _cockpit_same_physical_tank "$e" "$t" "$ce" "$ct"
}

# _cockpit_same_physical_tank <e1> <t1> <e2> <t2> -> 0 when two tank NAMES
# reach the same bytes on disk: the tank directories are one directory
# (`-ef` compares device+inode after following symlinks — a symlink alias, a
# symlinked parent), or their settings.json are one file (a hard link, or a
# symlink the install check would refuse anyway). #63 round-5 P2-2: the move
# used to compare names only, while install and remove act on the physical
# file — so moving A to a symlink alias of A "installed" idempotently and then
# removed the only guard.
_cockpit_same_physical_tank() {
  local a b
  a="$(profile_dir "$1" "$2")"; b="$(profile_dir "$3" "$4")"
  [ -d "$a" ] && [ -d "$b" ] || return 1
  [ "$a" -ef "$b" ] && return 0
  [ -e "$a/settings.json" ] && [ -e "$b/settings.json" ] && [ "$a/settings.json" -ef "$b/settings.json" ]
}

# _cockpit_hook_install <engine> <tank> -> install OUR PreToolUse block on
# this tank's settings.json (union merge, backup, idempotent — see
# lib/commands/settings.sh's _settings_write_file). Prints one status line.
#
# A subshell, like _settings_tank: _settings_snapshot (#63 round-5 P3-3)
# owns this subshell's EXIT trap for its snapshot directory.
_cockpit_hook_install() (
  local engine="$1" tank="$2" file input new changed
  # shellcheck source=./settings.sh
  source "$CLIKAE_LIB/commands/settings.sh"
  _settings_snapshot "$(profile_dir "$engine" "$tank")" "$engine/$tank" || return 1
  file="$_SETTINGS_FILE"
  input="${_SETTINGS_SNAP:-/dev/null}"
  if ! new="$(jq -n --arg cmd "$CLIKAE_LIB/hooks/cockpit-guard.sh" --slurpfile current "$input" '
      def valid: type == "object";
      if ($current | length) > 1 or (($current | length) == 1 and ($current[0] | valid | not))
        then error("invalid settings") else . end |
      ($current[0] // {}) as $old |
      # #63 round-5 P3-1: Claude Code runs `command` through a shell, so the
      # path is stored single-quoted (@sh): an install under a directory
      # with a space in it used to split there and exit 127 — non-blocking,
      # i.e. every spawn allowed. An older unquoted entry reads as drift and
      # is rewritten on the next `clikae cockpit <tank>`.
      ($cmd | @sh) as $cmd |
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
  _settings_write_file "$file" "$settings_out" "$engine/$tank" "$_SETTINGS_SNAP" || return 1
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
)

# _cockpit_hook_remove <engine> <tank> -> remove ONLY our marked block. Empties
# `hooks.PreToolUse` (and `hooks` itself) rather than leaving a dangling `[]`
# when nothing else used them — so a tank that had no hooks before we visited
# it comes back exactly as it was. Prints one status line.
_cockpit_hook_remove() (
  local engine="$1" tank="$2" file new changed
  # shellcheck source=./settings.sh
  source "$CLIKAE_LIB/commands/settings.sh"
  _settings_snapshot "$(profile_dir "$engine" "$tank")" "$engine/$tank" || return 1
  file="$_SETTINGS_FILE"
  if [ -z "$_SETTINGS_SNAP" ]; then
    printf '%s/%s: cockpit guard not installed here (unchanged)\n' "$engine" "$tank"
    return 0
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
    ' "$_SETTINGS_SNAP" 2>/dev/null)"; then
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
  _settings_write_file "$file" "$settings_out" "$engine/$tank" "$_SETTINGS_SNAP" || return 1
  printf '%s/%s: cockpit guard removed\n' "$engine" "$tank"
)

_cockpit_show() {
  local cur; cur="$(_cockpit_state_read)"
  if ! _cockpit_state_path_ok; then
    printf 'warning: %s (or its directory) is a symlink or not a regular file; it is ignored — see clikae doctor.\n' "$(_cockpit_state_file)" >&2
  fi
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
  # #63 round-6 P3-4: _cockpit_move runs as the RHS of `_cockpit_locked`'s
  # `"$@" || rc=$?` — being an operand of `||` suppresses errexit for this
  # function's ENTIRE body, so a plain `var="$(failing_cmd)"` here does NOT
  # abort the way it would anywhere else in this codebase (log_fail's `exit
  # 1` only ends the command-substitution SUBSHELL). Without this `|| exit
  # 1`, an unknown or ambiguous name left $resolved empty and move fell
  # through to validate_name for the real error — printing its own
  # "cli name is empty" / "Invalid cli name: '  clikae cockpit …'" line
  # first (the latter swallowing log_dim's suggestion text as a bogus
  # "name"). State and the lock were never at risk (validate_name always
  # caught it before anything was written) — but the next bare command
  # substitution added to this function will no longer be so lucky.
  resolved="$(_cockpit_resolve "$@")" || exit 1
  engine="$(printf '%s' "$resolved" | cut -f1)"
  tank="$(printf '%s' "$resolved" | cut -f2)"
  validate_name cli "$engine"
  validate_name profile "$tank"
  profile_exists "$engine" "$tank" || log_fail "Tank does not exist: $engine/$tank"
  command -v jq >/dev/null 2>&1 || log_fail "cockpit requires jq to edit settings.json"

  # #63 round-5 P2-3: an unsafe state path is refused before any guard write.
  _cockpit_state_path_ok || log_fail "cockpit: $(_cockpit_state_file) (or its directory) is a symlink or not a regular file — refusing to change the role; nothing was changed. Remove it (clikae doctor names it), then run clikae cockpit again."

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

  # #63 round-5 P2-2: different NAMES can still be one tank on disk. Install
  # on the alias is an idempotent no-op on the shared settings.json, and the
  # cleanup below would then remove the only guard while state names the
  # alias. Refuse before anything is written.
  if [ -n "$cur_engine" ] && _cockpit_same_physical_tank "$engine" "$tank" "$cur_engine" "$cur_tank"; then
    log_fail "cockpit: $engine/$tank is the same physical tank as the current cockpit $cur_engine/$cur_tank (a symlink or hard-link alias) — refusing to move the role onto itself; $cur_engine/$cur_tank is still the cockpit, unchanged."
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
  #
  # #63 P2-1 (round-3 review): install the NEW tank's guard FIRST, and only
  # disarm the OLD one after that succeeds. The order above used to remove
  # the old guard unconditionally and THEN try the install — when install
  # failed, the old cockpit was already unarmed, state still pointed at it,
  # and every later command (`clikae cockpit`, `clikae doctor`) reported a
  # healthy cockpit that had no guard at all. Different tanks, so installing
  # before removing has no interaction; the same-tank repair case already
  # returned above at :218. A failed install now leaves the old guard, the
  # old state, and the new tank all exactly as they were — a true no-op.
  _cockpit_hook_install "$engine" "$tank" || log_fail "cockpit: could not install the guard on $engine/$tank"

  # #63 P2-1 (round-4 review): write the state HERE — right after the new
  # tank's guard is armed, before the old tank is touched at all — not after
  # both guard writes. The order above (install, then remove, then state)
  # put the state write third: if it failed (state file mode 444, or
  # symlinked to an unwritable path — the round-4 reproductions), both guard
  # writes had already happened and nothing rolled them back. That left
  # exactly the shape this whole feature exists to prevent — state still
  # naming the OLD tank, the OLD tank's guard already removed, the NEW
  # tank's guard installed and unrecorded — and both `clikae cockpit` (which
  # only checks the named tank EXISTS, not that it's armed) and `clikae
  # doctor` (no cockpit awareness at all before this round) stayed silent.
  # Doing the write before the old guard is removed means a state-write
  # failure can only ever leave the OLD cockpit intact; the one new failure
  # mode it introduces — the new tank's guard now installed but unrecorded —
  # is rolled back below rather than left as an unlisted stray.
  #
  # #63 round-5 P2-3: the rollback below disarms the NEW tank, so it runs only
  # when the state file, re-read from disk, still names the OLD cockpit (or
  # still names none, when there was none). Anything else — the write landed
  # after all, or the file now says something unexpected — keeps the new
  # guard: over-guarded is recoverable, an unguarded recorded cockpit is not.
  if ! _cockpit_state_write "$engine" "$tank"; then
    if ! _cockpit_state_names "$cur"; then
      log_fail "cockpit: could not confirm the new cockpit record ($engine/$tank), and the state file no longer reads as ${cur:-empty} — $engine/$tank's guard was KEPT (over-guarded is the safe direction). Run \`clikae doctor\` to see what is guarded, then \`clikae cockpit --off\` and mark the right tank."
    fi
    local rollback_msg="its guard was rolled back"
    _cockpit_hook_remove "$engine" "$tank" >/dev/null 2>&1 \
      || rollback_msg="its guard could NOT be rolled back either — run \`clikae cockpit --off\` to clear it"
    if [ -n "$cur_engine" ]; then
      log_fail "cockpit: could not record the new cockpit ($engine/$tank) — $rollback_msg; $cur_engine/$cur_tank is still the cockpit, unchanged"
    else
      log_fail "cockpit: could not record the new cockpit ($engine/$tank) — $rollback_msg; no cockpit is set, unchanged"
    fi
  fi

  if [ -n "$cur_engine" ] && profile_exists "$cur_engine" "$cur_tank"; then
    _cockpit_hook_remove "$cur_engine" "$cur_tank" || log_warn "cockpit: could not clean up the old cockpit ($cur_engine/$cur_tank) — its guard was NOT removed; run \`clikae cockpit --off\` to clear it."
  elif [ -n "$cur_engine" ]; then
    log_warn "cockpit: recorded cockpit $cur_engine/$cur_tank no longer exists; dropping the record."
  fi
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
#
# 🔴 #61 round-6 P2-2: and it must never ask "is this a tank?" to decide. It
# used to sweep `list_all_profiles`, which is the answer to a DIFFERENT
# question — what clikae NAMES as a tank. The moment a guarded tank lost its
# `.clikae-tank` marker (a restored backup, a sync tool, a stray `rm` — the
# very state this PR's `doctor` warns about) it dropped out of that list, the
# sweep could not see it, and `--off` printed `cockpit: off`, returned 0, and
# cleared `state/cockpit` with the hook still installed and nothing left on
# disk pointing at it. That is worse than #63 P1-3's abort: the escape hatch
# did nothing AND said it succeeded, without so much as a warning.
#
# So this function asks "where might a hook be installed?" instead, twice
# over and from two independent directions:
#
#   1. the tank the state file NAMES, resolved straight through profile_dir —
#      no enumeration, no marker, no adapter gate. If its directory is gone
#      the record is still cleared, but we SAY so rather than implying the
#      guard went with it.
#   2. every `<engine>/<tank>/settings.json` under profiles_root that
#      actually carries our `"_clikae": "cockpit-guard"` marker. Reading a
#      settings.json and finding OUR marker in it is a far tighter gate than
#      "is a tank" — a directory clikae never named cannot have acquired that
#      marker except from a `clikae cockpit` run that named it.
#
# Everything else in clikae that walks the store goes through the one
# enumerator (#61 P2-6) and must keep doing so. This is the documented
# exception, and the reason is in the two questions above: an enumerator that
# correctly EXCLUDES something is exactly what an escape hatch must not
# inherit.
_cockpit_off() {
  command -v jq >/dev/null 2>&1 || log_fail "cockpit requires jq to edit settings.json"
  local cli profile path any=0 had_state=0 failed="" d
  local rec="" rec_engine="" rec_tank="" rec_dir="" rec_phys="" phys
  [ -f "$(_cockpit_state_file)" ] && had_state=1
  rec="$(_cockpit_state_read)"
  case "$rec" in
    ?*/?*) rec_engine="${rec%%/*}"; rec_tank="${rec#*/}" ;;
  esac
  if [ -n "$rec_engine" ] && [ -n "$rec_tank" ]; then
    rec_dir="$(profile_dir "$rec_engine" "$rec_tank")"
    if [ -d "$rec_dir" ]; then
      rec_phys="$(cd -P "$rec_dir" 2>/dev/null && pwd -P)" || rec_phys=""
      if [ -f "$rec_dir/settings.json" ] \
         && grep -q '"_clikae"[[:space:]]*:[[:space:]]*"cockpit-guard"' "$rec_dir/settings.json" 2>/dev/null; then
        any=1
        _cockpit_hook_remove "$rec_engine" "$rec_tank" || failed="$failed $rec_engine/$rec_tank"
      fi
    else
      log_warn "cockpit: recorded cockpit $rec_engine/$rec_tank no longer exists ($rec_dir) — nothing to unguard there; the record is cleared. If that directory comes back with a guard still installed, run \`clikae cockpit --off\` again."
    fi
  fi
  for d in "$(profiles_root)"/*/*/; do
    [ -d "$d" ] || continue
    path="${d%/}"
    profile="${path##*/}"
    cli="${path%/*}"; cli="${cli##*/}"
    [ -n "$cli" ] && [ -n "$profile" ] || continue
    [ -f "$path/settings.json" ] || continue
    grep -q '"_clikae"[[:space:]]*:[[:space:]]*"cockpit-guard"' "$path/settings.json" 2>/dev/null || continue
    # Already done above, by name or by physical identity (a symlink alias of
    # the recorded tank is the same settings.json, and removing twice would
    # print a second, contradictory "not installed here" line).
    if [ -n "$rec_phys" ]; then
      phys="$(cd -P "$path" 2>/dev/null && pwd -P)" || phys=""
      [ -n "$phys" ] && [ "$phys" = "$rec_phys" ] && continue
    fi
    any=1
    _cockpit_hook_remove "$cli" "$profile" || failed="$failed $cli/$profile"
  done
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
installs the hook on the new tank FIRST and only removes it from the old
tank once the new one is armed and recorded — so a failure partway through
never leaves you with no cockpit guarded at all.

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

# _cockpit_locked [--break-stale-lock] <fn> [args…] -> run one role
# transition while holding the settings lock (#63 round-5 P2-4: read state,
# install, record, disarm is ONE transaction; a second `clikae cockpit`
# waits, then refuses). Released on every exit, log_fail and signals
# included; a SIGKILL leaves a lock whose pid is gone, which the next run
# names instead of silently breaking — UNLESS --break-stale-lock is passed
# (#63 round-6 P3-3, used only by `clikae cockpit --off`: see
# _settings_lock_acquire's break_stale doc for why that one caller is the
# exception).
_cockpit_locked() {
  # shellcheck source=./settings.sh
  source "$CLIKAE_LIB/commands/settings.sh"
  local break_stale=0
  if [ "${1:-}" = --break-stale-lock ]; then break_stale=1; shift; fi
  _settings_lock_acquire "$break_stale" || exit 1
  trap '_settings_lock_release' EXIT
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
  local rc=0
  "$@" || rc=$?
  _settings_lock_release
  trap - EXIT HUP INT TERM
  return "$rc"
}

cmd_cockpit() {
  case "${1:-}" in
    -h|--help) _cockpit_help; return 0 ;;
    --off)     shift; [ $# -eq 0 ] || log_fail "Unexpected argument: $1"; _cockpit_locked --break-stale-lock _cockpit_off ;;
    --allow-agents)
      shift; [ $# -eq 1 ] || log_fail "--allow-agents needs exactly one duration (e.g. 4h)"
      _cockpit_allow_agents "$1" ;;
    '') _cockpit_show ;;
    *) _cockpit_locked _cockpit_move "$@" ;;
  esac
}
