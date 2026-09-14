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

cmd_doctor() {
  case "${1:-}" in
    -h|--help)
      cat <<'EOF'
Usage: clikae doctor

A read-only health check: which supported engines are installed and logged in,
how many tanks each has, and what to do next. It changes nothing on disk.
EOF
      return 0 ;;
    "") : ;;
    *) log_fail "Unexpected argument: $1" ;;
  esac

  local rc rc_loaded="no" on_path="no"
  rc="$(detect_shell_rc)"
  [ -f "$rc" ] && grep -qF "# >>> clikae:" "$rc" 2>/dev/null && rc_loaded="yes"
  command -v clikae >/dev/null 2>&1 && on_path="yes"

  log_bold "clikae doctor — what clikae can do on this machine"
  echo ""
  printf '  %-16s %s\n' "clikae"       "$CLIKAE_VERSION  ($CLIKAE_ROOT)"
  printf '  %-16s %s\n' "CLIKAE_HOME"  "$CLIKAE_HOME"
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
  echo ""

  # Trailing newline matters: $(...) strips it, and a final line with no newline
  # is read into the loop vars but its body never runs — dropping the last CLI.
  local rows; rows="$(scan_clis)"
  printf '%s\n' "$rows" | _doctor_render_table
  echo ""
  _doctor_legacy_prefix
  _doctor_tmux_guard
  _doctor_memory
  # shellcheck source=./settings.sh
  source "$CLIKAE_LIB/commands/settings.sh"
  local claude_template="$CLIKAE_ROOT/templates/permissions/claude.json"
  if [ -f "$claude_template" ]; then
    local settings_dir
    for settings_dir in "$(profiles_root)/claude"/*; do
      [ -d "$settings_dir" ] || continue
      _settings_tank claude "${settings_dir##*/}" doctor "$claude_template" || true
    done
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
