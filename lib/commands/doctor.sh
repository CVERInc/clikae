# shellcheck shell=bash
# lib/commands/doctor.sh — `clikae doctor`
#
# A read-only health check answering "what can clikae do on THIS machine right
# now?": which supported CLIs are installed, how many profiles each has and the
# logged-in account, plus the environment (CLIKAE_HOME, shell rc + whether a
# clikae block is loaded, clikae on PATH) and a few targeted next steps derived
# from the scan. Changes nothing — pure inspection.

# Render the scan rows (on stdin) as an aligned table. Plain cells (no colour):
# escape codes count toward printf's field width and break alignment.
_doctor_render_table() {
  printf '%b%-12s %-11s %-9s %s%b\n' "$__C_BOLD" "ENGINE" "INSTALLED" "TANKS" "LOGGED IN" "$__C_RESET"
  local cli installed binary strategy count label inst
  while IFS=$'\037' read -r cli installed binary strategy count label; do
    [ -n "$cli" ] || continue
    if [ "$installed" -eq 1 ]; then inst="yes"; else inst="no"; fi
    printf '%-12s %-11s %-9s %s\n' "$(engine_label "$cli")" "$inst" "$count" "${label:--}"
  done
}

# --- Keychain coordinates -----------------------------------------------------
# macOS keeps the LOGIN for both claude and agy in the login Keychain, not in the
# config dir clikae swaps — so clikae's whole account-isolation story rests on two
# hard-coded coordinates. Neither is verifiable by the test suite:
# `antigravity.bats` stubs `security`, so a rename on the vendor's side (a new
# service name, a different account) would pass CI and only surface to a user as
# "why am I suddenly on the wrong account".
#
# This is that check, on the real machine, read-only: it asks whether the item
# EXISTS. It deliberately never passes `-w`, because reading the secret is what
# makes the Keychain prompt for access — `doctor` must never pop a dialog — and
# because a token value has no business anywhere near a terminal. Presence only.
_doctor_keychain() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  command -v security >/dev/null 2>&1 || return 0

  # Both helpers live outside doctor's usual reach; pull them in only if needed.
  if ! declare -F _agy_kc_canon_service >/dev/null 2>&1; then
    # shellcheck source=./antigravity.sh
    source "$CLIKAE_LIB/commands/antigravity.sh"
  fi
  declare -F _claude_keychain_service >/dev/null 2>&1 || load_adapter claude 2>/dev/null || true

  log_bold "Login Keychain (read-only — presence only, never the secret)"

  # agy: ONE machine-wide slot. This is the reason agy is global/single-account,
  # so if these coordinates ever stop matching, every agy tank silently shares
  # whichever account is live.
  local svc acct
  svc="$(_agy_kc_canon_service)"; acct="$(_agy_kc_account)"
  if security find-generic-password -s "$svc" -a "$acct" >/dev/null 2>&1; then
    printf '  %-16s %s\n' "agy" "found  ($svc / $acct)"
  else
    printf '  %-16s %s\n' "agy" "absent ($svc / $acct) — not signed in, or the coordinates moved"
  fi

  # Per-tank agy logins. There is only ONE live agy slot, so switching tanks
  # works by stashing the current login under `clikae-agy-<tank>` and restoring
  # the target's. A tank with NO stash therefore can't be switched to without an
  # interactive Google sign-in — which means `clikae burn agy` can't auto-hop to
  # it either: a headless run would sit at a login prompt until --print-timeout.
  # That used to be invisible until you tried it at 2am. Now it's a line here.
  local at_name at_cli at_path stash_ok="" stash_no=""
  while IFS=$'\t' read -r at_cli at_name at_path; do
    [ "$at_cli" = "antigravity" ] || continue
    : "$at_path"
    if security find-generic-password -s "$(_agy_kc_tank_service "$at_name")" >/dev/null 2>&1; then
      stash_ok="$stash_ok $at_name"
    else
      stash_no="$stash_no $at_name"
    fi
  done <<EOF
$(list_all_profiles 2>/dev/null || true)
EOF
  if [ -n "$stash_ok$stash_no" ]; then
    printf '  %-16s %s\n' "agy tanks" "carry a saved login:${stash_ok:- (none)}"
    if [ -n "$stash_no" ]; then
      printf '  %-16s %s\n' "" "no saved login:$stash_no — burn can't auto-hop onto these"
      log_dim  "                   (sign in once with: clikae agy <tank>)"
    fi
  fi

  # claude: one slot PER TANK, keyed by a hash of that tank's config dir. A tank
  # with no slot is simply logged out — `clikae migrate` without --keep-login is
  # the usual way to orphan one.
  if declare -F _claude_keychain_service >/dev/null 2>&1; then
    local cli name path found=0 missing=""
    while IFS=$'\t' read -r cli name path; do
      [ "$cli" = "claude" ] || continue
      svc="$(_claude_keychain_service "$path" 2>/dev/null || true)"
      [ -n "$svc" ] || continue
      if security find-generic-password -s "$svc" >/dev/null 2>&1; then
        found=$((found + 1))
      else
        missing="$missing $name"
      fi
    done <<EOF
$(list_all_profiles 2>/dev/null || true)
EOF
    if [ "$found" -gt 0 ] || [ -n "$missing" ]; then
      printf '  %-16s %s\n' "claude" "$found tank(s) with a saved login${missing:+; no slot for:$missing}"
    fi
  fi

  echo ""
}

# Name the "why is this tank suddenly logged out?" case instead of leaving it a
# mystery. clikae does not own the OAuth refresh — Claude Code does, in its own
# daemon — but that daemon writes its log INSIDE the tank clikae manages, so the
# aftermath is readable even though the mechanism isn't ours to fix.
#
# The failure it names: Claude's OAuth uses ROTATING refresh tokens, so when
# several sessions on one tank refresh at once, the loser gets `invalid_grant`,
# treats it as "logged out", and clears the Keychain entry the winner just wrote.
# One race, escalated into a whole-tank logout with no silent recovery. A user
# sees only that a working account stopped working.
#
# Read-only, bounded to the log's tail. We report only when the newest auth event
# is a FAILURE — a later success means it recovered and there is nothing to say.
_doctor_auth_dropouts() {
  local cli name path out bad ok
  while IFS=$'\t' read -r cli name path; do
    [ "$cli" = "claude" ] || continue
    [ -f "$path/daemon.log" ] || continue
    out="$(tail -c 200000 "$path/daemon.log" 2>/dev/null | awk '
      function ts(s,   t) {
        if (match(s, /^\[[0-9TZ:.-]+\]/)) { t = substr(s, RSTART+1, RLENGTH-2); return t }
        return ""
      }
      /auth: (proactive refresh failed|no token found|headless daemon cannot complete)/ {
        t = ts($0); if (t != "" && (bad == "" || t > bad)) bad = t; next
      }
      # "scheduling" counts as HEALTHY on purpose: the daemon only schedules a
      # refresh when it has a token to refresh — a tank with none says so with
      # "no token found" instead. Leaving it out produced a false positive on a
      # tank that had failed once, been re-logged-in, and been quietly fine for
      # a week (caught by reading the log instead of trusting the first draft).
      /auth: (proactive refresh succeeded|token still valid|scheduling proactive refresh)/ {
        t = ts($0); if (t != "" && (ok == "" || t > ok)) ok = t
      }
      END { printf "%s\037%s\n", bad, ok }
    ')"
    IFS=$'\037' read -r bad ok <<EOF
$out
EOF
    [ -n "$bad" ] || continue
    if [ -n "$ok" ]; then
      local newer; newer="$(printf '%s\n%s\n' "$bad" "$ok" | sort | tail -n 1)"
      [ "$newer" = "$ok" ] && continue      # recovered since
    fi
    printf '  %-16s %s\n' "claude/$name" "signed out by a token-refresh failure at ${bad%%.*} — fix: clikae claude $name, then /login"
    log_dim  "                   (concurrent sessions on one tank can race Claude's rotating refresh token; not something clikae can prevent)"
  done <<EOF
$(list_all_profiles 2>/dev/null || true)
EOF
}

# _doctor_legacy_prefix -> say something ONLY when pre-0.28.3 names are still
# around. Silence is the answer for everyone except the person deciding when the
# legacy read paths can be deleted, and for them silence IS the reading: zero.
#
# A line that always printed "0 legacy sessions" would be a number nobody can act
# on, on a screen that exists to tell you what to do next.
_doctor_legacy_prefix() {
  local sess=0 files=0
  [ -n "${CLIKAE_SESS_PREFIX_LEGACY:-}" ] || return 0
  if command -v tmux >/dev/null 2>&1; then
    sess="$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
      | grep -c "^${CLIKAE_SESS_PREFIX_LEGACY}" || true)"
  fi
  local _f
  for _f in "$HOME/.clikae/state/${CLIKAE_SESS_PREFIX_LEGACY}"*; do
    [ -e "$_f" ] && files=$((files + 1))
  done
  [ "${sess:-0}" -gt 0 ] || [ "${files:-0}" -gt 0 ] || return 0
  printf '  %-16s %s\n' "old names" \
    "$sess session(s), $files state file(s) still named ${CLIKAE_SESS_PREFIX_LEGACY}*"
  log_dim "    Sessions are renamed the next time clikae launches into them;"
  log_dim "    orphaned state files go on the next \`clikae clean\`."
  return 0
}

# _doctor_pane_path <pid> -> the PATH value from that PROCESS's real
# environment (P1-2, clikae#97 review round 1). NOT tmux's session table:
# `tmux_spawn_session` (lib/core/tmux.sh, Rule 10) writes the shim dir into
# the session table via `-e` AND wraps the pane's own start command with
# `env PATH=…` — but a pane's real process gets the SPAWNING CLIENT's live
# PATH, which `-e` never touches, so reading `show-environment -t` back only
# ever proves what was ASKED for, never what the process actually got. The
# original version of this probe did exactly that, and structurally could
# not have gone red for a session spawned through `tmux_spawn_session`,
# guard present or not: it always read back its own `-e` write.
#
# Linux reads /proc directly. macOS has no /proc; `ps eww` (BSD ps: e = show
# environment, ww = don't truncate) is the documented fallback — it appends
# "KEY=value" pairs after the command, space-separated, which is unambiguous
# for PATH except in the (unsupported) case of a PATH entry that itself
# contains a space.
#
# 🔴 THE LAST `PATH=` TOKEN, NOT THE FIRST (P2-4, clikae#97 review round 2).
# `ps eww` prints the COMMAND first, the ENVIRONMENT after — and Rule 10's own
# pane start command is `env PATH=<shim dir>:... <cmd>` (lib/core/tmux.sh),
# so a pane's command line legitimately CONTAINS the literal text "PATH=…"
# before its real environment's own "PATH=…" ever appears. `head -n1` took
# the FIRST match — the command line's own text, not what the process
# actually got — which is exactly the write-and-read-back-the-same-pipe bug
# P1-2 fixed for `show-environment`, reopened here for a platform nothing
# local can exercise (see below). `tail -n1` takes the real one.
_doctor_pane_path() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  # 🔴 NONZERO MEANS "COULD NOT READ", NEVER "NO GUARD" (P3-4, clikae#97
  # review round 3). The caller reports the two differently, so every way
  # this can fail to see the process returns 1 instead of printing nothing:
  # a pid that exited between `list-panes` and here, an environ that reads
  # back empty (a zombie), `ps` failing or printing no PATH. Only a process
  # whose environment WAS read gets rc 0, even if it has no PATH at all.
  local env_dump=""
  if [ -r "/proc/$pid/environ" ]; then
    env_dump="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null)" || return 1
    [ -n "$env_dump" ] || return 1
    printf '%s\n' "$env_dump" | sed -n 's/^PATH=//p' | head -n1
    return 0
  fi
  case "$(uname -s 2>/dev/null)" in
    # `|| true` is LOAD-BEARING, same reason as lib/core/proc.sh:35-40: on a
    # locked-down host `ps eww` can exit non-zero, and under doctor's own
    # `set -eo pipefail` (bin/clikae) a leaked failure here would abort the
    # WHOLE health check, not just this one probe.
    Darwin)
      env_dump="$(ps eww -p "$pid" -o command= 2>/dev/null | tr ' ' '\n' | sed -n 's/^PATH=//p' | tail -n1)" || true
      [ -n "$env_dump" ] || return 1
      printf '%s\n' "$env_dump"
      ;;
    *) return 1 ;;
  esac
}

# _doctor_tmux_guard -> say something ONLY when a live clikae session's PANE
# PROCESS does not have the tmux guard shim first on its real PATH
# (CVERInc/clikae#97, lib/shims/tmux — refuses a bare kill-server/kill-session
# while $TMUX is inherited, rc 86).
#
# 🔴 FIRST, not just present. `tmux_spawn_session` is the only place that
# arranges it, and a session captures its creating client's PATH once, at
# birth (DESIGN-tmux Rule 8) — nothing repaints it later. So a session
# started before the guard shipped, or one whose spawn path drifted around
# Rule 10, is silently unprotected for its whole life; the only way to know
# is to ask THAT session's own pane process what its PATH actually is
# (`_doctor_pane_path`, above), not this process's, and not tmux's table.
_doctor_tmux_guard() {
  command -v tmux >/dev/null 2>&1 || return 0
  # P3 (clikae#97 review round 1): this is DOCTOR's own process's
  # $CLIKAE_LIB, compared against sessions doctor did not necessarily spawn.
  # Two copies of clikae on one machine (a release install plus a checkout
  # like this review's own worktree) can each spawn sessions from a
  # different $CLIKAE_LIB, and this only ever matches its OWN. A known,
  # narrow blind spot — not fixed here — rather than a claim this covers
  # every install on the machine.
  local shim_dir="$CLIKAE_LIB/shims"
  local sess created attached pid pane_path missing="" unknown=""
  while IFS=$'\t' read -r sess created attached; do
    [ -n "$sess" ] || continue
    : "$created" "$attached"
    # `|| true` / `if !`: doctor runs under `set -eo pipefail` (bin/clikae),
    # and neither failure here is this whole command's business to abort on
    # (P2-4, clikae#97 review round 2, mirroring lib/core/proc.sh:35-40).
    #
    # 🔴 "COULD NOT READ" IS ITS OWN ANSWER (P3-4, clikae#97 review round 3).
    # `list-panes` on a session that ended between the listing above and
    # here, a pane pid that is already gone, or an environment this user
    # cannot read all used to land in `missing`, printing "not first on
    # PATH" and "restart the tank" about a session nobody actually looked
    # at. Measured for all three. They go to `unknown` now, which says only
    # that the guard could not be verified.
    pid="$(tmux list-panes -t "=$sess" -F '#{pane_pid}' 2>/dev/null | head -n1)" || true
    if [ -z "$pid" ]; then
      unknown="$unknown $sess"
      continue
    fi
    if ! pane_path="$(_doctor_pane_path "$pid")"; then
      unknown="$unknown $sess"
      continue
    fi
    case "$pane_path" in
      "$shim_dir:"*|"$shim_dir") continue ;;
      *) missing="$missing $sess" ;;
    esac
  done <<EOF
$(live_session_names 2>/dev/null || true)
EOF
  if [ -n "$missing" ]; then
    printf '  %-16s %s\n' "tmux guard" "not first on PATH:$missing"
    log_dim "                   (started before the guard, or outside tmux_spawn_session — reattach won't fix it, restart the tank to pick it up)"
  fi
  if [ -n "$unknown" ]; then
    printf '  %-16s %s\n' "tmux guard" "unknown, could not verify:$unknown"
    log_dim "                   (couldn't read that session's pane process — it may have just ended, or its environment isn't readable by this user)"
  fi
  return 0
}

# _doctor_memory -> say something ONLY when a Soul store cannot be read.
#
# 🔴 WHY DOCTOR AND NOT JUST THE LAUNCH WARNING. memory_access_warn fires when a
# tank starts, which is the moment you can least act on it — you are already on
# your way into a session, and the engine that goes on to read nothing has no
# idea anything is wrong. This is the same question asked when you came looking
# for an answer.
#
# It runs the real read, not `[ -r ]`: access(2) consults the permission bits and
# so answers "yes" to exactly the failure worth catching. That read may raise a
# TCC prompt on macOS — and unlike doctor's Keychain check, which refuses to
# prompt because reading a secret is not its business, here the prompt IS the
# repair. A dialog you can click beats the silence a background daemon gets.
#
# Silent when every store reads. A permanent "memory: fine" line on a screen
# built to tell you what to do next is a number nobody can act on.
_doctor_memory() {
  local root store group members engines
  root="$(souls_root 2>/dev/null || true)"
  [ -n "$root" ] && [ -d "$root" ] || return 0
  for store in "$root"/*/memory; do
    [ -e "$store" ] || continue
    ls "$store" >/dev/null 2>&1 && continue

    group="$(basename "$(dirname "$store")")"
    printf '  %-16s %s\n' "memory" "the '$group' Soul cannot be read"
    printf '  %-16s %s\n' "" "$store"

    # Which engines share this brain — the diagnosis names an identity, and a
    # Soul is deliberately vendor-neutral, so there can be more than one.
    members="$(soul_members_file "$group" 2>/dev/null || true)"
    engines=""
    if [ -f "$members" ]; then
      engines="$(cut -f1 "$members" 2>/dev/null | cut -d/ -f1 | sort -u | tr '\n' ' ')"
    fi
    # The same answer the launch warning gives, in this screen's column. Not a
    # second copy of the reasoning: doctor's first cut had its own `[ -r ]`
    # branch and its own wording, and its lines landed two spaces out of true —
    # which no substring assertion could see, only running it.
    # shellcheck disable=SC2086  # a space-separated engine list, deliberately split
    _memory_denied_why '                   ' "$store" $engines
  done
  return 0
}

# _doctor_stray_dirs [pairs] -> name directories sitting where a tank would be —
# directly inside a recognised engine's profiles dir — that list_all_profiles
# does NOT (and, on the fingerprint it can see right now, would not adopt
# either): no `.clikae-tank` marker, and no content the engine itself would
# have written there. #61 round-1 P1-3's reproduction (`mkdir zzempty` next to
# real tanks) is exactly this. Deliberately reuses list_all_profiles's own
# output as the source of truth (diff against what's on disk) rather than
# re-deriving tank-ness with a second copy of tank_dir_is_tank/adoption — the
# "ONE ENUMERATOR, REALLY" rule applies to reads too, not just writes.
#
# With the argument `pairs` it prints ONE MACHINE-READABLE LINE per stray
# instead — "<cli>\t<name>\t<1 if it holds engine-shaped content, else 0>" —
# for `doctor --adopt` below. #61 round-5 P3-4: that caller used to re-parse
# the HUMAN rows with `awk '{print $1}'`, which cut `claude/my tank` down to
# `claude/my` and then named a DIFFERENT, real directory in its suggestion.
# A name is never reconstructed from formatted output; the walk hands it over
# whole.
_doctor_stray_dirs() {
  local mode="${1:-report}"
  local root cli_dir cli tdir name printed=0 known known_real="" real p
  root="$(profiles_root)"
  [ -d "$root" ] || return 0
  known="$(list_all_profiles 2>/dev/null | cut -f1,2)"
  for cli_dir in "$root"/*/; do
    [ -d "$cli_dir" ] || continue
    cli="${cli_dir%/}"; cli="${cli##*/}"
    tank_engine_known "$cli" || continue
    for tdir in "$cli_dir"*/; do
      [ -d "$tdir" ] || continue
      name="${tdir%/}"; name="${name##*/}"
      case $'\n'"$known"$'\n' in
        *$'\n'"$cli"$'\t'"$name"$'\n'*) continue ;;
      esac
      # #61 round-2 P2-2: a symlink ALIAS for a real, already-adopted tank
      # has no marker of its own by design (dedupe prefers the real
      # directory — _tank_candidates) and must not be reported as stray on
      # that account; it is not a gap, it is a name that already resolves to
      # one. Silence any candidate whose REALPATH matches a known tank's,
      # not just its own name. $known_real is built LAZILY, on the first
      # name-mismatch found — a store with zero strays (the common case)
      # then pays zero extra `cd && pwd -P` forks for this check at all.
      if [ -z "$known_real" ]; then
        known_real=$'\n'
        while IFS= read -r p; do
          [ -n "$p" ] || continue
          real="$(cd "$p" 2>/dev/null && pwd -P)" || continue
          known_real="$known_real$real"$'\n'
        done <<EOF
$(list_all_profiles 2>/dev/null | cut -f3)
EOF
      fi
      real="$(cd "$tdir" 2>/dev/null && pwd -P)" || real=""
      if [ -n "$real" ]; then
        case "$known_real" in *$'\n'"$real"$'\n'*) continue ;; esac
      fi
      # #61 round-2: _tank_fingerprint_match is no longer a precondition for
      # adoption, but it is still a useful READ-ONLY signal here — it tells
      # you WHY a directory looks like it used to be a tank.
      local has=0
      _tank_fingerprint_match "$cli" "${tdir%/}" 2>/dev/null && has=1
      if [ "$mode" = pairs ]; then
        printf '%s\t%s\t%s\n' "$cli" "$name" "$has"
        continue
      fi
      if [ "$printed" -eq 0 ]; then
        log_bold "Not a tank directory (no .clikae-tank marker):"
        printed=1
      fi
      if [ "$has" -eq 1 ]; then
        printf '  %-16s %s\n' "$cli/$name" "${tdir%/}  (has $cli-shaped content)"
      else
        printf '  %-16s %s\n' "$cli/$name" "${tdir%/}"
      fi
    done
  done
  if [ "$printed" -eq 1 ]; then
    # #61 round-2 P3: an actionable next step, not just a name — clikae never
    # re-adopts after the one-time sweep, and `init` refuses an existing
    # directory, so there is genuinely no automatic way back for these.
    # #61 round-3 P2-1: this used to name `clikae init <engine> <name>`,
    # which ALWAYS fails here — `init` refuses any existing directory,
    # marker or not — leaving no automatic way back, contradicted by the
    # `(has … content)` line right above it inviting exactly that read.
    # `init --adopt` is a real command: it refuses unless the directory
    # looks like that engine's own content (the same signal this row's
    # "(has $cli-shaped content)" suffix reports), so it's safe to name
    # unconditionally — a directory with no recognisable content gets a
    # true refusal instead of a false promise.
    log_dim "    Next: if this looks like real <engine> content, \`clikae init <engine> <name> --adopt\` marks it a tank without touching it (refuses anything that doesn't look like <engine>). Otherwise move what you want to keep, then \`clikae init <engine> <name>\` to start fresh."
    echo ""
  fi
  return 0
}

# _doctor_cockpit -> say something ONLY when the recorded cockpit and the
# guard actually on disk disagree (#63 round-4 review, P3-7 + the other half
# of P2-1). Nothing else checks this: `clikae cockpit` (_cockpit_show) only
# asks whether the NAMED tank exists, never whether it's armed, so a state
# write that races a guard write (P2-1) — or any other cause of drift, a
# hand-edited settings.json, a `--off` that died partway through — left a
# cockpit that reported healthy and stayed silent forever after. Read-only:
# this names the mismatch, it does not repair it (`clikae cockpit --off`
# sweeps every guard regardless of what state says).
_doctor_cockpit() {
  declare -F _cockpit_state_file >/dev/null 2>&1 || {
    # shellcheck source=./cockpit.sh
    source "$CLIKAE_LIB/commands/cockpit.sh"
  }
  local state_file; state_file="$(_cockpit_state_file)"
  # #63 round-5 P2-3: this used to return right here when state was absent or
  # empty — exactly the state a crash mid-write left behind (both tanks
  # guarded, nothing recorded), so doctor said nothing. The guard scan below
  # now always runs; only the "is the recorded tank armed" half needs a record.
  if ! _cockpit_state_path_ok; then
    printf '  %-16s %s\n' "cockpit" "state file $state_file (or its directory) is a symlink or not a regular file — it is ignored, and clikae cockpit refuses to change the role until it is removed"
  fi
  # #63 round-5 P2-4: a transition killed while holding the settings lock
  # leaves it behind, and every later `clikae cockpit` refuses — name it here.
  local lock="$CLIKAE_HOME/state/settings.lock" lock_pid
  if [ -d "$lock" ]; then
    lock_pid="$(head -n 1 "$lock/pid" 2>/dev/null || true)"
    if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
      printf '  %-16s %s\n' "cockpit" "stale settings lock $lock (pid $lock_pid is not running) — a cockpit/settings change died mid-way; check the lines below, then: rm -rf '$lock'"
    elif [ -z "$lock_pid" ]; then
      # #63 round-6 P3-3: a crash between the `mkdir` and the pid-file write
      # leaves a lock dir with no pid file at all — the check above requires
      # a NON-EMPTY dead pid to speak up, so this shape went unreported:
      # every waiting command silently timed out (CLIKAE_SETTINGS_LOCK_WAIT_S,
      # default 20s) and said "in progress (pid unknown)" with no hint doctor
      # already knew something was wrong.
      printf '  %-16s %s\n' "cockpit" "settings lock $lock has no pid file — a cockpit/settings change likely died between taking the lock and recording its pid; every waiting command times out until it clears. If nothing is actually mid-transition: rm -rf '$lock'"
    fi
  fi
  local cur; cur="$(_cockpit_state_read)"
  local cur_engine="" cur_tank=""
  case "$cur" in
    '') ;;
    */*) cur_engine="${cur%%/*}"; cur_tank="${cur#*/}" ;;
    *) printf '  %-16s %s\n' "cockpit" "state file $state_file does not name an <engine>/<tank> (reads: $cur) — fix: clikae cockpit --off"
       cur="" ;;
  esac

  local cli profile path
  local named_exists=0 named_has_guard=0 strays=""
  while IFS=$'\t' read -r cli profile path; do
    [ -n "$cli" ] || continue
    if [ -n "$cur" ] && [ "$cli" = "$cur_engine" ] && [ "$profile" = "$cur_tank" ]; then
      named_exists=1
    fi
    [ -f "$path/settings.json" ] || continue
    grep -q '"_clikae"[[:space:]]*:[[:space:]]*"cockpit-guard"' "$path/settings.json" 2>/dev/null || continue
    if [ -n "$cur" ] && [ "$cli" = "$cur_engine" ] && [ "$profile" = "$cur_tank" ]; then
      named_has_guard=1
    else
      strays="$strays $cli/$profile"
    fi
  done <<EOF
$(list_all_profiles 2>/dev/null || true)
EOF

  if [ -z "$cur" ]; then
    if [ -n "$strays" ]; then
      printf '  %-16s %s\n' "cockpit" "guard found on tank(s) but no cockpit is recorded:$strays"
      log_dim "                   fix: clikae cockpit --off, then clikae cockpit <the right tank>"
    fi
    return 0
  fi

  if [ "$named_exists" -eq 0 ]; then
    printf '  %-16s %s\n' "cockpit" "recorded cockpit $cur no longer exists — fix: clikae cockpit --off"
  elif [ "$named_has_guard" -eq 0 ]; then
    printf '  %-16s %s\n' "cockpit" "recorded cockpit $cur has NO guard installed — the in-session dispatch rule is NOT being enforced"
    log_dim "                   fix: clikae cockpit $cur_engine $cur_tank"
  fi
  if [ -n "$strays" ]; then
    printf '  %-16s %s\n' "cockpit" "guard also found on tank(s) that are not the recorded cockpit:$strays"
    log_dim "                   fix: clikae cockpit --off, then clikae cockpit <the right tank>"
  fi
  return 0
}

# _doctor_fleet_config -> say something ONLY when a non-solo tank is missing
# something the fleet shares: a hook (lib/core/fleet_hooks.sh) or an MCP
# server (lib/core/fleet_mcp.sh).
#
# 🔴 WHY THIS IS THE REAL FIX FOR #141. Both halves of a tank's own engine
# config are silent when they go missing. An absent MCP server reads as a
# server that is down. An absent hook reads as nothing at all: the tank works
# normally, only without the automation — which is how a memory-snapshot
# `Stop` hook, lost when tanks were recreated under new names, stopped running
# for five days and 102 commits before an unrelated symptom gave it away. The
# merge (at init and at every launch) prevents the next one; this is where an
# existing one is found on the day it happens, by someone who came here to ask
# what is wrong.
#
# Silent when every non-solo tank has everything. Per _doctor_memory's rule: a
# permanent "fleet config: fine" line on a screen built to tell you what to do
# next is a line nobody can act on.
_doctor_fleet_config() {
  command -v jq >/dev/null 2>&1 || return 0
  local f e engines=""
  # Only engines that actually share something — one `ls` of two directories,
  # and on the common install both are absent and this whole section is free.
  for f in "$(fleet_hooks_root)"/*.json "$(fleet_mcp_root)"/*.json; do
    [ -f "$f" ] || continue
    e="${f##*/}"; e="${e%.json}"
    case " $engines " in *" $e "*) ;; *) engines="$engines $e" ;; esac
  done
  [ -n "$engines" ] || return 0
  # One SUBSHELL per engine. adapter_loader.sh's unset list is what actually
  # stops adapter_hooks_config_file leaking from claude onto the next engine
  # in this loop (it is in that list, and a test holds it there) — this keeps
  # the loading itself out of doctor's own process, so the sections AFTER this
  # one see the adapter state they saw before it ran.
  for e in $engines; do
    ( _doctor_fleet_config_engine "$e" ) || true
  done
  return 0
}

# _doctor_fleet_config_engine <engine> -> the per-engine half of the above.
# Runs in a subshell (see its loop) because it loads an adapter.
_doctor_fleet_config_engine() {
  local engine="$1" tank dir event command name said=0
  load_adapter "$engine" >/dev/null 2>&1 || return 0
  while IFS= read -r tank; do
    [ -n "$tank" ] || continue
    tank_is_solo "$engine" "$tank" && continue
    dir="$(profile_dir "$engine" "$tank")"
    while IFS=$'\t' read -r event command; do
      [ -n "$event" ] || continue
      printf '  %-16s %s\n' "fleet config" "$engine/$tank does not run the shared $event hook: $command"
      said=1
    done <<HOOKS
$(fleet_hooks_missing "$engine" "$dir" 2>/dev/null || true)
HOOKS
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      printf '  %-16s %s\n' "fleet config" "$engine/$tank does not have the shared MCP server: $name"
      said=1
    done <<SERVERS
$(fleet_mcp_missing "$engine" "$dir" 2>/dev/null || true)
SERVERS
  done <<EOF
$(tanks_for_engine "$engine" 2>/dev/null || true)
EOF
  if [ "$said" -eq 1 ]; then
    log_dim "                   each is merged at that tank's next launch — or now: clikae hooks share <event> <command> / clikae mcp share <name>"
    log_dim "                   (clikae hooks list / clikae mcp list show what every non-solo tank should have)"
  fi
  return 0
}

cmd_doctor() {
  case "${1:-}" in
    -h|--help)
      cat <<'EOF'
Usage: clikae doctor [--adopt]

A read-only health check: which supported engines are installed and logged in,
how many tanks each has, and what to do next. It changes nothing on disk,
with the one documented exception of --adopt.

--adopt   Retry the one-time tank-adoption sweep (#61) for a store whose
          adoption flag (state/tanks-adopted-v1) is missing — most likely
          because the store was read-only the first time anything walked it.
          Harmless to run when the store is already adopted.
EOF
      return 0 ;;
    --adopt)
      # #61 round-2 P1-1: the "retry" button named in `Next:` below. Calls the
      # SAME function every command's first tank walk already calls — its
      # flag-present check is the guarantee that must hold here too: an
      # ALREADY-adopted store must never sweep again (that would readmit a
      # directory like `zzempty` created after the one-time window closed).
      # So this only ever does real work on a store whose flag genuinely
      # never persisted (a read-only store), where it retries that write.
      _tank_adoption_ensure
      local _adopt_flag; _adopt_flag="$(tanks_adopted_flag_path)"
      if [ "$_CLIKAE_ADOPT_LAST_FLAG_OK" -eq 1 ]; then
        if [ "$_CLIKAE_ADOPT_LAST_COUNT" -gt 0 ]; then
          log_done "Tank adoption flag written: $_adopt_flag ($_CLIKAE_ADOPT_LAST_COUNT tank(s) newly adopted)."
        else
          # #61 round-4 P3-7: the flag being present only means the ONE-TIME
          # sweep already ran (or, the very first time, had nothing to do) —
          # it does NOT mean every directory that looks like real content
          # still has its marker (one lost to a restored backup, say). Saying
          # "Already adopted — nothing to do" while _doctor_stray_dirs below
          # would name that very directory two lines later is the
          # contradiction this closes: reuse the SAME enumerator (never a
          # second copy of the stray-detection logic) and, if it found
          # anything with recognisable content, point at the per-directory
          # fix instead of claiming there's nothing to do.
          local _strays
          _strays="$(_doctor_stray_dirs pairs 2>/dev/null | awk -F'\t' '$3 == 1')" || true
          if [ -n "$_strays" ]; then
            log_warn "Adoption flag is set, but at least one directory looks like real content with no marker (a restored backup?) — the one-time sweep won't revisit it:"
            # #61 round-5 P3-4: print the command that WORKS, or say plainly
            # that none does. The same round's own P3-2 taught `init --adopt`
            # to refuse a lock/sidecar-shaped name outright, and validate_name
            # has always refused a name with a space or a leading dot — this
            # used to suggest `init --adopt` for those anyway, a line the
            # operator could only ever watch fail.
            local _c _n _has
            while IFS="$(printf '\t')" read -r _c _n _has; do
              [ -n "$_c" ] || continue
              if _tank_shape_excluded "$_n"; then
                printf '    %s/%s — a lock/sidecar-suffixed name can never be a tank; rename the directory first, then: clikae init %s <new-name> --adopt\n' "$_c" "$_n" "$_c"
              elif ! ( validate_name profile "$_n" ) >/dev/null 2>&1; then
                printf '    %s/%s — that name can never be a tank (allowed: A-Z a-z 0-9 . _ -, no leading dot); rename the directory first, then: clikae init %s <new-name> --adopt\n' "$_c" "$_n" "$_c"
              else
                printf '    clikae init %s %s --adopt\n' "$_c" "$_n"
              fi
            done <<EOF
$_strays
EOF
          else
            log_pass "Already adopted: $_adopt_flag — nothing to do."
          fi
        fi
      else
        log_warn "Could not write the adoption flag: $_adopt_flag — store is read-only. Tanks are still recognised in memory each run (fix permissions to make it permanent)."
      fi
      return 0 ;;
    "") : ;;
    *) log_fail "Unexpected argument: $1" ;;
  esac

  # #61 round-2 P2-4: warm the per-process tank cache BEFORE anything below
  # walks the store — scan_clis alone fans out to one subshell per adapter
  # (15), each re-deriving the same rows via tanks_for_engine; every one of
  # them inherits this via ordinary fork/copy instead of re-walking.
  profiles_cache_warm

  local rc rc_loaded="no" on_path="no"
  rc="$(detect_shell_rc)"
  [ -f "$rc" ] && grep -qF "# >>> clikae:" "$rc" 2>/dev/null && rc_loaded="yes"
  command -v clikae >/dev/null 2>&1 && on_path="yes"

  log_bold "clikae doctor — what clikae can do on this machine"
  echo ""
  printf '  %-16s %s\n' "clikae"       "$CLIKAE_VERSION  ($CLIKAE_ROOT)"
  printf '  %-16s %s\n' "CLIKAE_HOME"  "$CLIKAE_HOME"
  # #61 round-2 P1-1: the two states a store can be in, named plainly. Before
  # this the only way to learn a store's tanks had silently stopped being
  # recognised (a fingerprint gap, or a flag write that failed) was to notice
  # the count drop somewhere else on this same screen.
  if [ -f "$(tanks_adopted_flag_path)" ]; then
    printf '  %-16s %s\n' "tank adoption" "done — legacy tanks recognised once; new ones only via init (or agy's own)"
  else
    printf '  %-16s %s\n' "tank adoption" "not persisted (read-only store?) — recognised in memory each run; clikae doctor --adopt to retry"
  fi
  if [ "$on_path" = "yes" ]; then
    printf '  %-16s %s\n' "on PATH"    "yes"
  else
    printf '  %-16s %s\n' "on PATH"    "no — add the install bin dir to your PATH (see docs/installation.md)"
  fi
  if [ "$rc_loaded" = "yes" ]; then
    printf '  %-16s %s\n' "shell rc"   "$rc  (clikae aliases present)"
  else
    printf '  %-16s %s\n' "shell rc"   "$rc  (no clikae aliases yet)"
  fi
  # #109 P3-6: jq is clikae's ONE runtime dependency, and only the cockpit
  # guard needs it — at HOOK EXECUTION TIME, where a missing jq refuses every
  # Agent spawn on the cockpit tank (fail closed) with no other symptom. The
  # PATH the hook runs under is the tank's, not necessarily this shell's, so
  # this line names the path it found rather than just saying "yes".
  local jq_path; jq_path="$(command -v jq 2>/dev/null || true)"
  if [ -n "$jq_path" ]; then
    printf '  %-16s %s\n' "jq"         "$jq_path  (needed by the cockpit guard; nothing else uses it)"
  else
    printf '  %-16s %s\n' "jq"         "not found — clikae cockpit cannot install its guard, and an installed guard refuses every Agent spawn"
  fi
  echo ""

  # Trailing newline matters: $(...) strips it, and a final line with no newline
  # is read into the loop vars but its body never runs — dropping the last CLI.
  local rows; rows="$(scan_clis)"
  printf '%s\n' "$rows" | _doctor_render_table
  echo ""
  _doctor_stray_dirs
  _doctor_legacy_prefix
  _doctor_tmux_guard
  _doctor_memory
  _doctor_cockpit
  _doctor_fleet_config
  # shellcheck source=./settings.sh
  source "$CLIKAE_LIB/commands/settings.sh"
  local claude_template="$CLIKAE_ROOT/templates/permissions/claude.json"
  if [ -f "$claude_template" ]; then
    # #61 round-1 P2-6: used to be its own `for … in profiles_root/claude/*`
    # — so a stray non-tank directory (e.g. `zzempty`, reported above by
    # _doctor_stray_dirs) got its own "permissions drift" line here too,
    # inviting `clikae settings apply claude zzempty` right into it. Routed
    # through tanks_for_engine so doctor's drift report only ever names real
    # tanks — the same set `_doctor_stray_dirs` above excludes.
    local settings_tank
    while IFS= read -r settings_tank; do
      [ -n "$settings_tank" ] || continue
      _settings_tank claude "$settings_tank" doctor "$claude_template" || true
    done <<EOF
$(tanks_for_engine claude)
EOF
  else
    printf 'claude: permissions template missing (installation incomplete); skipping\n'
  fi

  _doctor_keychain
  # NOT inside _doctor_keychain: that one returns early off macOS, and reading a
  # log file has nothing to do with the Keychain.
  _doctor_auth_dropouts

  # Targeted next steps, derived from the scan. We only need cli/installed/count;
  # binary/strategy/label are read to reach the right columns.
  local installed_no_profile="" any_profiles=0 total_profiles=0
  local cli installed binary strategy count label
  while IFS=$'\037' read -r cli installed binary strategy count label; do
    [ -n "$cli" ] || continue
    : "$binary" "$strategy" "$label"   # consumed only to position $count
    [ "$count" -gt 0 ] && any_profiles=1
    total_profiles=$((total_profiles + count))
    if [ "$installed" -eq 1 ] && [ "$count" -eq 0 ] && [ -z "$installed_no_profile" ]; then
      installed_no_profile="$cli"
    fi
  done <<EOF
$rows
EOF

  log_bold "Next:"
  if [ -n "$installed_no_profile" ]; then
    log_dim "  · $installed_no_profile is installed with no tank yet:  clikae init $installed_no_profile work --alias"
  fi
  if [ "$rc_loaded" = "no" ] && [ "$any_profiles" -eq 1 ]; then
    log_dim "  · aliases aren't loaded in this shell yet:  source $rc"
  fi
  if [ "$total_profiles" -ge 2 ]; then
    log_dim "  · when a tank runs dry, carry on to the next one:  clikae to"
  fi
  log_dim "  · See your tanks at a glance:  clikae"
  log_dim "  · Take a risk-free tour:       clikae demo"
}
