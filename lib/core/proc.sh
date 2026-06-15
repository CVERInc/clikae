# shellcheck shell=bash
# lib/core/proc.sh — detect live processes still bound to a tank's config dir, so
# rename/migrate/remove never move or delete a dir out from under a running engine.
#
# WHY: the old in-use guard checked only the env var of the shell running clikae.
# An engine open in ANOTHER terminal — or a background daemon/spare — kept writing
# to the old path and regenerated a "phantom tank" (HANDOFF §11, hit live). This
# scans ALL of the current user's processes. Pure ps/awk/grep, bash 3.2, BSD- and
# Linux-safe. Best-effort: if process environments can't be read it returns
# nothing rather than blocking the user's work.
#
# PLATFORM LIMIT (honest): on macOS `ps` can only read the ENVIRONMENT of
# tty-attached processes. So this catches an interactive session in another
# Terminal — the case that actually regenerates a phantom tank (HANDOFF §11) — but
# NOT a no-tty background daemon/spare (its env is invisible to `ps` there), so the
# daemon→soft-warn path effectively only fires on Linux, where /proc/<pid>/environ
# is readable regardless of tty. Verified 2026-06-04: `ps eww` surfaces a live
# tty-bound claude's CLAUDE_CONFIG_DIR; a no-tty `sleep` with the same env is listed
# but its env is not. The interactive case is the one that matters; don't claim
# daemon detection on macOS.

# live_dir_users <dir> <envvar> — print one line per OTHER same-uid process whose
# environment binds <envvar> to <dir> (a trailing slash is tolerated):
#   <pid><TAB><command line>
# Excludes clikae's own process ($$); the current shell is guarded separately by
# each caller's live-env-var check.
live_dir_users() {
  local dir="$1" envvar="$2" want self="$$"
  [ -n "$dir" ] && [ -n "$envvar" ] || return 0
  want="${dir%/}"
  case "$OSTYPE" in
    darwin*)
      # `ps eww` appends each process's environment to the command column. Tokenise
      # the line and match an EXACT `VAR=dir` env token (an env value containing a
      # space would split across fields — acceptable: clikae profile dirs have none).
      # The trailing `|| true` is LOAD-BEARING: on a locked-down host (CI runners,
      # some sandboxes) `ps eww` can exit non-zero, and under the caller's
      # `set -eo pipefail` a leaked failure would abort rename/migrate/remove
      # entirely (HANDOFF §11: this MUST be best-effort — no reading ⇒ no users,
      # never a hard error).
      ps eww -o pid=,command= 2>/dev/null | awk -v self="$self" -v var="$envvar" -v want="$want" '
        {
          if ($1 == self) next
          for (i = 2; i <= NF; i++) {
            if ($i == var "=" want || $i == var "=" want "/") {
              line = $0; sub(/^[ \t]*[0-9]+[ \t]+/, "", line)
              printf "%s\t%s\n", $1, line
              break
            }
          }
        }' || true
      ;;
    linux*)
      local envf pid cmd
      for envf in /proc/[0-9]*/environ; do
        [ -r "$envf" ] && [ -O "$envf" ] || continue       # readable + same uid
        pid="${envf#/proc/}"; pid="${pid%/environ}"
        [ "$pid" = "$self" ] && continue
        if tr '\0' '\n' < "$envf" 2>/dev/null | grep -qxF "$envvar=$want" \
        || tr '\0' '\n' < "$envf" 2>/dev/null | grep -qxF "$envvar=$want/"; then
          cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
          printf '%s\t%s\n' "$pid" "$cmd"
        fi
      done
      ;;
  esac
  return 0   # best-effort producer: empty output = nobody, never a hard error
}

# _proc_is_background <cmdline> — true if the command looks like a background
# daemon / spare / pty-host rather than an interactive session (HANDOFF §11).
# Those recreate the dir more softly, so they warn instead of hard-failing.
#
# CRITICAL ASYMMETRY: this guard fails CLOSED. A false *negative* (a real
# background worker read as interactive) only over-warns — harmless. A false
# *positive* (an interactive session read as background) downgrades the hard-fail
# to a warning, so rename/migrate/remove proceed and CORRUPT the live session.
# So the markers must be SPECIFIC to Claude's real background spawns, never broad
# substrings. WHY this matters on macOS: `ps eww` appends each process's whole
# ENVIRONMENT to the command column (see live_dir_users), so <cmdline> here carries
# every env var value too — a bare `*daemon*` / `*--bg-*` would match an innocent
# interactive session whose env happens to hold e.g. `XDG_DATA_HOME=…/daemon-cache`
# and silently green-light corrupting it (verified 2026-06-16). Match Claude's
# actual background argv markers only.
_proc_is_background() {
  case "$1" in
    *"daemon run"*|*"--bg-spare"*|*"--bg-pty-host"*) return 0 ;;
    *) return 1 ;;
  esac
}

# assert_dir_free <dir> <envvar> <binary> <action> — shared in-use guard for
# rename/migrate/remove, run AFTER the caller's own current-shell env check. Scans
# OTHER processes bound to <dir>:
#   any interactive session -> hard log_fail (data integrity; NOT --force-able)
#   only background workers  -> log_warn, return 0 (caller may proceed)
# Returns 0 when nobody (or only background workers) hold it.
assert_dir_free() {
  local dir="$1" envvar="$2" binary="$3" action="${4:-move}"
  [ -n "$envvar" ] || return 0
  local lines; lines="$(live_dir_users "$dir" "$envvar" || true)"   # never let a scan failure abort the caller
  [ -n "$lines" ] || return 0
  local had_tui=0 pid cmd
  while IFS="$(printf '\t')" read -r pid cmd; do
    [ -n "$pid" ] || continue
    if _proc_is_background "$cmd"; then
      log_warn "A background $binary worker (pid $pid) is still bound to this tank."
    else
      had_tui=1
      log_err "$binary is still running on this tank in another shell (pid $pid):"
      log_err "    $(printf '%s' "$cmd" | cut -c1-72)"
    fi
  done <<EOF
$lines
EOF
  if [ "$had_tui" -eq 1 ]; then
    log_fail "Quit that $binary session first, then retry the $action — it would corrupt the live session and can leave a phantom tank."
  fi
  log_warn "Quit $binary fully before relying on this $action — a background worker can recreate the old tank."
  return 0
}
