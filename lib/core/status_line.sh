#!/usr/bin/env bash
# lib/core/status_line.sh — the `#()` end of the tmux status row (#77).
#
# tmux cannot recompute a shell value on its own, so a row whose content changes
# (fuel, alerts, the client's width) has to be a `#(shell-command)` that tmux
# re-runs every `status-interval`. This file is that command, and it is
# DELIBERATELY EMPTY OF JUDGEMENT: every decision about what the row says lives
# in `tmux_status_render` (lib/core/tmux.sh), which is the one place the line is
# composed. This end does three things a pure function cannot do for itself —
# put $HOME/$CLIKAE_HOME where the library expects them, ask tmux which
# transcript this session is driving, and never let a failure reach the screen.
#
# Args, all from tmux_status_line and all single-quoted there:
#   $1 HOME   $2 CLIKAE_HOME   $3 engine   $4 tank   $5 tmux session   $6 host
#   $7 the client's width (`#{client_width}`, expanded by tmux before this runs)
#
# 🔴 $HOME AND $CLIKAE_HOME ARRIVE AS ARGUMENTS rather than being inherited.
# tmux runs this as a child of the SERVER, whose environment is whoever started
# it — possibly a different shell, on a different day, before `clikae init` ever
# chose a state directory. Passing them means the row reads the same state the
# clikae that launched this session reads (roam.bats documents the same trap for
# every other variable: tmux hands a session only its `update-environment` list
# and the rest comes from the server's process, not from us).
#
# 🔴 NO clikae, NO curl, NO jq, NO network, and no `set -e`. This runs every
# five seconds, per attached client, inside tmux's server, where an error goes
# to a log nobody reads or paints itself over the row. Everything it sources is
# a leaf library with no top-level side effects.
HOME="${1:-$HOME}"; export HOME
CLIKAE_HOME="${2:-$HOME/.clikae}"; export CLIKAE_HOME
CK_ENGINE="${3:-}"; CK_TANK="${4:-}"; CK_SESSION="${5:-}"; CK_HOST="${6:-}"
CK_WIDTH="${7:-}"

CK_CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dry_store.sh
. "$CK_CORE/dry_store.sh"    2>/dev/null || exit 0
# shellcheck source=burn_status.sh
. "$CK_CORE/burn_status.sh"  2>/dev/null || exit 0
# shellcheck source=live.sh
. "$CK_CORE/live.sh"         2>/dev/null || exit 0
# shellcheck source=tmux.sh
. "$CK_CORE/tmux.sh"         2>/dev/null || exit 0

# WHICH TRANSCRIPT — asked, not guessed. live_session_id reads the per-session
# tmux option first and the `state/<session>.session_id` mirror second, in that
# order, and the order is the whole point: the option belongs to THIS session
# and goes away with it, while the mirror file merely has this session's NAME.
# A tank relaunched without a resumable id (codex, antigravity) would otherwise
# inherit the id of whatever claude session last used that name, and the row
# would offer a command that reopens the wrong conversation.
CK_SID="$(live_session_id "$CK_SESSION" 2>/dev/null || true)"

tmux_status_render "$CK_ENGINE" "$CK_TANK" "$CK_SID" "$CK_HOST" "$CK_WIDTH"
