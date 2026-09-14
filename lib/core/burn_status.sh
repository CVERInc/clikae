# shellcheck shell=bash
# lib/core/burn_status.sh — read side of #41's machine-readable burn status file.
#
# lib/commands/burn.sh writes `status.json` into its own run directory
# ($HOME/.clikae/logs/burn-<pid>/status.json) at every transition (see
# _burn_status_write there for the writer and the field contract, mirrored in
# docs/orchestration.md). This file is the READ side, used by `clikae wait`
# (#37), which polls one or more of these files for a terminal state instead
# of a hand-rolled `until [ -e DONE ]` loop.
#
# Purpose-built, not a general JSON parser: the only JSON these functions ever
# read is the flat, single-line object _burn_status_write itself produces (no
# nesting except the `rerouted_from` array, no field value ever contains a
# literal `"`), so a small grep/sed extractor is honest here where it would be
# a trap on arbitrary JSON.

# burn_status_field <json> <field> -> the RAW JSON-encoded value for <field>
# (a quoted string, `null`, `true`/`false`, a bare number, or a `[...]`
# array) — or nothing if the field is absent or the object doesn't match the
# one shape this reads.
burn_status_field() {
  burn_status_fieldv "$1" "$2"
  printf '%s' "$_BSF"
}

# burn_status_fieldv <json> <field> -> the same RAW value, into $_BSF, WITHOUT
# FORKING. Empty when the field is absent.
#
# 🔴 WHY THE FORK-FREE TWIN. The echoing form above costs a `grep`, a
# `head`, a `sed` and a command substitution — four processes — for one field,
# and both of its callers ask for several fields of several files in a loop:
# burn_tank_busy walks every run directory on the machine before a burn may
# start, and the tmux status line (lib/core/tmux.sh's tmux_status_render) does
# the same walk every 5 seconds inside tmux's own server, under a 30 ms budget
# that four processes per field cannot meet. The parse is pure bash 3.2
# parameter expansion, which is exactly as honest as the grep was: this reads
# the flat single-line object _burn_status_write itself produces and nothing
# else (see this file's header), so "the first `"<field>":` in the string" is
# the whole grammar either way.
#
# The `"` and `:` around the name are load-bearing and are why a prefix cannot
# be confused with a longer name: asking for `artifact` cannot match
# `"artifact_bytes":`.
# shellcheck disable=SC2034  # _BSF is an output slot, read by lib/core/tmux.sh.
burn_status_fieldv() {
  local json="$1" field="$2" rest
  _BSF=""
  rest="${json#*\"$field\":}"
  [ "$rest" = "$json" ] && return 0          # no such field
  case "$rest" in
    '"'*)  rest="${rest#\"}"; _BSF="\"${rest%%\"*}\"" ;;   # a quoted string, re-quoted
    '['*)  _BSF="${rest%%]*}]" ;;                           # the rerouted_from array
    *)     _BSF="${rest%%,*}"; _BSF="${_BSF%%\}*}" ;;       # null/true/false/number
  esac
  return 0
}

# burn_status_str <json> <field> -> <field>'s value with quotes stripped, or
# empty for `null`/absent. For string fields (engine, tank, state, run_id, …).
burn_status_str() {
  local v; v="$(burn_status_field "$1" "$2")"
  [ -n "$v" ] && [ "$v" != null ] || return 0
  v="${v#\"}"; v="${v%\"}"
  printf '%s' "$v"
}

# burn_status_state <json> -> the `state` field (running|done|dry|fail|infra),
# or empty if unreadable.
burn_status_state() { burn_status_str "$1" state; }

# burn_status_dir <run_id> -> the run directory burn wrote for <run_id>
# (matches lib/commands/burn.sh's own `run_dir="$HOME/.clikae/logs/burn-$$"`
# — hardcoded to $HOME, like the rest of burn's own log/state paths, not
# $CLIKAE_HOME: the two agree by default but a caller overriding $CLIKAE_HOME
# alone would otherwise read from a directory burn never wrote to).
burn_status_dir() { printf '%s/.clikae/logs/%s\n' "$HOME" "$1"; }

# burn_status_dirs -> every burn run directory that exists on this machine, one
# per line, newest LAST (glob order). Fork-free: a plain glob, no `find`, no
# command substitution — the tmux status line (lib/core/tmux.sh) walks this on
# a 5-second timer inside tmux's own server process.
#
# The literal below is the same layout burn_status_dir six lines up prints, and
# deliberately sits next to it rather than being derived from it: deriving it
# would mean an unquoted command substitution, which word-splits a $HOME
# containing a space. Two literals in the same paragraph drift far less easily
# than two in different files — and if this layout ever moves, both lines are
# on the same screen.
burn_status_dirs() {
  burn_status_dirsv
  [ "${#_BSDIRS[@]}" -gt 0 ] || return 0
  printf '%s\n' "${_BSDIRS[@]}"
}

# shellcheck disable=SC2034  # _BSDIRS is an output slot, read by lib/core/tmux.sh.
# burn_status_dirsv -> the same list into the $_BSDIRS ARRAY, with NO fork at
# all — not even the command substitution that reading the printing form costs.
#
# The …v suffix is this repo's existing name for "sets a variable instead of
# printing, because the caller is on a hot path": tmux_sessv, _home_fuel_dotv,
# dry_store_peekv. Here the hot path is #77's status row, which walks this list
# every five seconds per attached client, and a `$( )` around it was measurably
# a third of the remaining budget on a loaded host.
#
# Indexed array assignment by length, not `+=`: bash 3.2.
burn_status_dirsv() {
  local d
  _BSDIRS=()
  for d in "$HOME"/.clikae/logs/burn-*; do
    [ -d "$d" ] || continue
    _BSDIRS[${#_BSDIRS[@]}]="$d"
  done
}

# burn_status_resolve <run_id|status-file> -> echo the status.json PATH to
# read, or return 1 if none can be found. Accepts, in order:
#   - an existing file path, used verbatim (the "…|status-file" half of
#     `clikae wait`'s contract);
#   - a run id as burn itself prints it, e.g. `burn-28186` (the top-level
#     invocation's id — stable across a whole burn's reroutes/retries, unlike
#     the per-attempt `run_id` in `--json`'s own output);
#   - `--json`'s own per-attempt `run_id`, e.g. `codex-T1-burn-28186` or
#     `codex-T1-burn-28186-retry2` (P2-5, 2026-09-09 round-1 review) —
#     collapsed to the top-level `burn-28186` it was derived from, since that
#     is the file that actually exists;
#   - a bare pid, e.g. `28186` (shorthand for `burn-28186`);
#   - anything else is tried as a literal run-directory name, so a caller who
#     already knows burn's layout is never second-guessed.
#
# P1-4b (2026-09-09 round-1 review): "the status file doesn't exist YET" is a
# NORMAL state, not an error — `clikae burn … --json & clikae wait "burn-$!"`
# (both published examples use exactly this shape) loses the startup race
# every time otherwise, since `wait` sources fewer libs than `burn` and gets
# to its first read before `burn` has even reached its first status write.
# So a computed (non-literal-file) path gets a short bounded wait for the
# file to appear before giving up — overridable via
# $CLIKAE_WAIT_RESOLVE_TIMEOUT_S (tests default it to 0: see tests/helpers.bash)
# so "an unknown target refuses rather than hanging" stays instant.
burn_status_resolve() {
  local arg="$1" p wait_s="${CLIKAE_WAIT_RESOLVE_TIMEOUT_S:-10}" waited=0
  [ -n "$arg" ] || return 1
  if [ -f "$arg" ]; then printf '%s' "$arg"; return 0; fi
  case "$arg" in
    burn-*)
      p="$(burn_status_dir "$arg")/status.json" ;;
    *-burn-[0-9]*)
      # --json's per-attempt run_id: "<engine>-<tank>-burn-<pid>[-retryN]".
      # Strip everything up to and including the LAST "-burn-", then drop an
      # optional trailing "-retryN" — what's left is the pid the top-level
      # burn_id ("burn-<pid>") was keyed on.
      local _tail; _tail="${arg##*-burn-}"
      local _pid; _pid="${_tail%%-retry*}"
      case "$_pid" in
        ''|*[!0-9]*) p="$(burn_status_dir "$arg")/status.json" ;;   # not actually a pid — fall back to literal
        *)           p="$(burn_status_dir "burn-$_pid")/status.json" ;;
      esac
      ;;
    ''|*[!0-9]*)
      p="$(burn_status_dir "$arg")/status.json" ;;
    *)
      p="$(burn_status_dir "burn-$arg")/status.json" ;;
  esac
  case "$wait_s" in ''|*[!0-9]*) wait_s=0 ;; esac
  while [ ! -f "$p" ] && [ "$waited" -lt "$wait_s" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  [ -f "$p" ] || return 1
  printf '%s' "$p"
}

# _burn_pid_matches_marker <pid> <recorded-started_at-epoch> -> 0 if <pid>
# looks like the SAME process the marker's `started_at` was recorded for
# (its own start time is at-or-before that moment, a few seconds' slack for
# measurement lag), 1 if it looks like a DIFFERENT process — one that has
# been recycled onto <pid> since the original writer died.
#
# P2-1 (2026-09-09 round-1 review): `kill -0` alone only proves SOMETHING is
# alive at that pid, not that it is the SAME thing the marker names. A burn
# that crashed or was SIGKILLed leaves its pid free for the OS to hand to an
# unrelated process within the 7-day status-file retention window — hours,
# not days, once a busy machine wraps macOS's ~100k pid space — and from
# then on `burn_tank_busy` refused every burn on that tank FOREVER for a
# reason nobody could see (a false positive: it blocks real work and looks
# identical to a real busy tank, unlike the false-negative window every
# other pid-liveness check here already accepts — see live.sh).
#
# Two independent checks, in order (either one settling it is enough — a
# platform where one is unavailable/unparseable still gets the other):
#   1. The pid's own process-start time (`ps -o lstart=`), parsed with BOTH
#      the BSD (`date -j -f`, macOS's own `/bin/date`) and GNU (`date -d`)
#      grammars — this machine's own dev shell can put either `date` first
#      on PATH, and the target platform is documented as macOS/bash 3.2, so
#      guessing one dialect is not safe (see hub-env's GNU/BSD note). A
#      RECYCLED pid always started LATER than the marker it inherited.
#   2. If lstart can't be read or parsed on this platform, fall back to the
#      pid's own command line (`ps -o command=`) actually being a `clikae`
#      invocation — a real burn's argv always is.
# Nothing usable from either check (`recorded` itself unparseable, or a `ps`
# that returns nothing) never REFUSES a live pid on that basis alone — the
# absence of evidence is not evidence of a recycled pid.
_burn_pid_matches_marker() {
  local pid="$1" recorded="$2" lstart epoch
  case "$recorded" in ''|*[!0-9]*) return 0 ;; esac
  lstart="$(ps -o lstart= -p "$pid" 2>/dev/null)"
  if [ -n "$lstart" ]; then
    epoch="$(date -j -f '%a %b %e %T %Y' "$lstart" +%s 2>/dev/null)"
    [ -n "$epoch" ] || epoch="$(date -d "$lstart" +%s 2>/dev/null)"
    case "$epoch" in
      ''|*[!0-9]*) ;;   # unparseable on this platform — fall through to the cmdline check
      *)
        [ "$epoch" -le "$((recorded + 5))" ] && return 0
        return 1
        ;;
    esac
  fi
  case "$(ps -o command= -p "$pid" 2>/dev/null)" in
    '')      return 0 ;;   # ps gave nothing usable — don't false-refuse a live pid
    *clikae*) return 0 ;;
    *)       return 1 ;;
  esac
}

# burn_tank_busy <engine> <tank> [self-pid] -> 0 if some OTHER live process
# currently has a burn in the `running` state on this exact <engine>/<tank>
# (#40); 1 otherwise. <self-pid>, when given, is excluded from the scan (a
# burn checking whether ITS OWN tank is busy must not see its own just-written
# status file and refuse itself).
#
# "Live" means the recorded pid still exists AND still looks like the same
# process the marker names (`_burn_pid_matches_marker`, P2-1 above) — a
# status file left behind by a burn that crashed or was killed says
# `running` forever otherwise, and a once-collided tank would stay refused
# permanently.
#
# `waiting-reset` (P1-2, 2026-09-09 round-1 review) counts as busy too: a
# burn sleeping to a near vendor reset (`--wait-for-reset`) has NOT abandoned
# its tank — a second burn (or the reroute walk) landing on it mid-sleep
# would collide with the re-fire this one is about to make, exactly like the
# `running` case #40 already guards.
burn_tank_busy() {
  local eng="$1" tk="$2" self_pid="${3:-}" base d f json st feng ftk fpid fstarted
  base="$HOME/.clikae/logs"
  [ -d "$base" ] || return 1
  for d in "$base"/burn-*; do
    [ -d "$d" ] || continue
    f="$d/status.json"
    [ -f "$f" ] || continue
    json="$(cat "$f" 2>/dev/null)" || continue
    st="$(burn_status_state "$json")"
    case "$st" in running|waiting-reset) ;; *) continue ;; esac
    feng="$(burn_status_str "$json" engine)"
    ftk="$(burn_status_str "$json" tank)"
    [ "$feng" = "$eng" ] && [ "$ftk" = "$tk" ] || continue
    fpid="$(burn_status_str "$json" pid)"
    case "$fpid" in ''|*[!0-9]*) continue ;; esac
    [ -n "$self_pid" ] && [ "$fpid" = "$self_pid" ] && continue
    kill -0 "$fpid" 2>/dev/null || continue   # stale — the writer is gone
    fstarted="$(burn_status_str "$json" started_at)"
    _burn_pid_matches_marker "$fpid" "$fstarted" || continue   # stale — a recycled pid, not the same writer
    return 0
  done
  return 1
}
