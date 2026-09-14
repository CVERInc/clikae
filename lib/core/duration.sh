# shellcheck shell=bash
# lib/core/duration.sh — shared "Nu" duration parsing (u ∈ {s,m,h,d}, bare = seconds).
#
# Used by `clikae burn --wait-for-reset` (#38) and, since the 2026-09-09
# round-1 review of #41/#37/#40/#38 (P1-4a), `clikae wait --timeout` too: both
# need the SAME small grammar, and a caller must never have to guess whether
# `30m` is accepted here the way it already was for --wait-for-reset. Used to
# live only in lib/commands/burn.sh; moved here so a command file that has no
# other reason to source burn.sh's much larger dependency chain (wait.sh)
# still gets it — bin/clikae sources this globally, same as every other core
# lib, and burn.sh/wait.sh each source=/dev/null it explicitly too, for the
# same "state your own dependencies" reason burn.sh already sources
# burn_status.sh's sibling files that way.
#
# bash 3.2 safe: no `${var,,}`, no associative arrays, no `[[ =~ ]]`.

# _human_age <epoch-mtime> [now-epoch] -> "just now" / "5m ago" / "3h ago" /
# "2d ago". One formatter for the board's Continue list, the resume picker,
# and (P2-5, 2026-09-14 round-1 fix review) the tmux status row's stale-fuel
# suffix — each used to carry its own copy, or (the status row) would have
# needed one. Moved here from lib/commands/home.sh for the same reason
# _burn_parse_duration lives here rather than in lib/commands/burn.sh: a
# caller that has no other reason to source home.sh's much larger command
# machinery (lib/core/status_line.sh, sourced standalone as tmux's `#()`
# helper — see that file's own "leaf library, no top-level side effects"
# rule) still gets it. home.sh keeps calling this same function; it no
# longer defines its own.
_human_age() {
  local mt="$1" now="${2:-}" d
  [ -n "$now" ] || now="$(date +%s 2>/dev/null || echo "$mt")"
  d=$(( now - mt ))
  if   [ "$d" -lt 60 ];    then printf 'just now'
  elif [ "$d" -lt 3600 ];  then printf '%dm ago' "$(( d / 60 ))"
  elif [ "$d" -lt 86400 ]; then printf '%dh ago' "$(( d / 3600 ))"
  else                          printf '%dd ago' "$(( d / 86400 ))"
  fi
}

# _burn_parse_duration <dur> -> whole seconds, or return 1 (nothing echoed)
# for anything that doesn't parse. Accepts a bare integer (seconds) or an
# integer with one trailing unit s/m/h/d. The caller must refuse rather than
# guess on a parse failure — a silent wrong number here sleeps or times out
# for the wrong length with nothing to show for it until the effect runs
# long or short.
_burn_parse_duration() {
  local s="$1" n unit
  case "$s" in
    *[0-9])
      n="$s"; unit="" ;;
    ?*[a-zA-Z])
      n="${s%?}"; unit="${s: -1}" ;;
    *)
      return 1 ;;
  esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$unit" in
    '') printf '%s' "$n" ;;
    s)  printf '%s' "$n" ;;
    m)  printf '%s' "$((n * 60))" ;;
    h)  printf '%s' "$((n * 3600))" ;;
    d)  printf '%s' "$((n * 86400))" ;;
    *)  return 1 ;;
  esac
}
