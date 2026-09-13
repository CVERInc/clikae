#!/usr/bin/env bash
# Translate a click-pair swipe. Args: release row, pane id, pane_in_mode.
# Invoked by tmux run-shell; no clikae state or engine initialization needed.
y2=${1:-}; TS_PANE_ID=${2:-}; inmode=${3:-0}
case "$inmode" in ''|*[!0-9]*) inmode=0 ;; esac
# TS_PANE_ID is #{pane_id} from the binding (`%3`): an ID, already exact. tmux
# 3.4 rejects `=%3` (can't find pane), so the exact-target lint names this
# variable as an exception instead of the `=` prefix it wants for names.
[ -n "$TS_PANE_ID" ] || exit 0

# _touch_opt <option> -> the value tmux would actually apply to this pane,
# walking the scope chain by hand. tmux's own -A only chains WITHIN one
# namespace — pane -> window -> global-window (documented: "Pane options
# inherit from window options... global set of window options") — it does not
# also fall through into session scope, which is a SEPARATE namespace ("a
# separate set of global session options"). clikae only ever writes the
# session/global-session pair (`set-option -og`), but a human may reasonably
# reach for `set -p`/`set -w` too, and P3-2 (2026-09 R1 review) showed the
# session level itself was silently unreachable: `set @clikae_touch_scroll
# off` in one session (no -g) left `show-options -gqv` still reading the
# global "on", because that call never asked the session level at all.
_touch_opt() {
  local name="$1" v
  v=$(tmux show-options -qv -p -A -t "$TS_PANE_ID" "$name" 2>/dev/null)
  [ -n "$v" ] && { printf '%s' "$v"; return; }
  v=$(tmux show-options -qv -t "$TS_PANE_ID" "$name" 2>/dev/null)
  [ -n "$v" ] && { printf '%s' "$v"; return; }
  tmux show-options -gqv -t "$TS_PANE_ID" "$name" 2>/dev/null
}

enabled=$(_touch_opt @clikae_touch_scroll)
case "$enabled" in off|0|no|false) exit 0 ;; esac
y1=$(tmux show-options -pqv -t "$TS_PANE_ID" @clikae_touch_y 2>/dev/null)
# 🔴 Use it once. UNSET immediately after reading, before any validation or
# branch below, so a stale @clikae_touch_y is not a bug to avoid causing but a
# value that cannot exist: an Up with no matching Down on its OWN key table
# (P1-2, 2026-09 R1 review — `copy-mode-vi` under `mode-keys vi` fell back to
# root and reused whatever a previous, unrelated Down had written) now finds
# nothing here rather than something old. `-p` matches how Down wrote it
# (`set-option -p -t = ...`); unlike the read above, this is NOT chained
# through _touch_opt — the value must be cleared at the exact scope it was
# written at, not wherever a fallback happened to find a copy.
tmux set-option -pu -t "$TS_PANE_ID" @clikae_touch_y 2>/dev/null || true
# Validate before arithmetic: option values are user-editable.
case "$y1" in ''|*[!0-9]*) exit 0 ;; esac
case "$y2" in ''|*[!0-9]*) exit 0 ;; esac
dy=$((10#$y1 - 10#$y2)); distance=${dy#-}
if [ "$distance" -ge 2 ]; then
  multiplier=$(_touch_opt @clikae_touch_scroll_lines)
  case "$multiplier" in ''|*[!0-9]*) multiplier=2 ;; esac
  multiplier=$((10#$multiplier))
  [ "$multiplier" -gt 0 ] || multiplier=2
  lines=$((distance * multiplier))
  # #{pane_in_mode} is a COUNT of stacked mode layers, not a boolean: a
  # run-shell that produces output stacks its own view-mode over an existing
  # copy-mode, so a pane already in copy-mode can read inmode=2 (P2-2, 2026-09
  # R1 review). `= 1` was false for that count and re-entered copy-mode on top
  # of itself; `-gt 0` treats any nonzero depth as "already in a mode".
  [ "$inmode" -gt 0 ] || tmux copy-mode -t "$TS_PANE_ID" || exit 0
  direction=scroll-down
  [ "$dy" -le 0 ] || direction=scroll-up
  tmux send-keys -t "$TS_PANE_ID" -X -N "$lines" "$direction"
elif [ "$inmode" -gt 0 ]; then
  tmux send-keys -t "$TS_PANE_ID" -X cancel
fi
