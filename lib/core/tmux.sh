# shellcheck shell=bash
# lib/core/tmux.sh — the ONE place a tmux session (and therefore a tmux SERVER)
# is created.
#
# WHY THIS FILE EXISTS. `docs/DESIGN-tmux.md` has been the SSOT for this layer
# since v0.4: six rules, each with receipts. Rule 2 says the exits must "全部收斂
# 到同一組函式，別各寫一份", and Rule 5 refers to `clikae_spawn_session` as the
# wrapper holding Rules 1 and 2. That function was never written. It appeared
# three times in the design doc and zero times in the source, so four call sites
# (switch.sh ×3, burn.sh ×1) each re-implemented the rules by hand — and drifted:
# three carried a 200-character copy-pasted option prefix and burn.sh carried
# none, so a server born by `clikae burn` got tmux's 2000-line default scrollback
# instead of clikae's 50000 (tests/bats/tmux-spawn.bats, red before this file).
#
# THE THING THE OLD SHAPE COULD NOT EXPRESS. `tmux new-session` reads like a
# command — "run this" — but its real contract is "talk to the server, and if
# there isn't one, CREATE one from my current context". That server then outlives
# every process here and permanently keeps what it was born with. tests/bats/
# roam.bats already found one half of this the hard way:
#
#   "tmux passes only its `update-environment` list into a session, and everything
#    else is inherited from the SERVER's process environment — which is whoever
#    started the server, not us."
#
# That was fixed for environment variables by passing them explicitly with `-e`.
# The other half cannot be fixed that way: on macOS the server also inherits its
# TCC identity — which folders it may read — and nothing can hand that over after
# birth. A server started where no app holds the grant makes every tank on it,
# forever, unable to read a Soul that lives under ~/Library/Mobile Documents or
# ~/Documents, with no prompt and no error beyond EPERM. Diagnosed 2026-08-15;
# see DESIGN-tmux.md Rule 7.
#
# So creation is not an implementation detail to be inlined. It is the moment the
# server's whole identity is decided, and it belongs to exactly one function.

# THE SESSION NAME PREFIX, and why there are two.
#
# Every session clikae starts is `<prefix><engine>-<tank>[-<argv digest>]`, and
# that prefix is how `live.sh` tells clikae's sessions apart from the ones the
# human made by hand. It was `ck-` from v0.4 to 0.28.2 — an abbreviation nobody
# chose, appearing in no README, no formula, no alias, and no doc: it existed
# only in the one place a user actually reads it, `tmux ls`.
#
# 🔴 IT LIVED AS A LITERAL IN 64 PLACES. This file's own header tells the story
# of a rule that said "converge on one set of functions", was never written, and
# let four call sites drift apart. A bare string repeated 64 times is that same
# shape waiting to happen, so the prefix now has exactly one definition and the
# rename below is a one-line change for whoever comes next.
CLIKAE_SESS_PREFIX="clikae-"

# 🔴 AND THE OLD ONE STAYS READABLE. A rename is a MIGRATION: sessions started
# before the upgrade are still running under `ck-`, and dropping the old prefix
# would make them vanish from the board, refuse to be attached, and be spawned
# over with a duplicate. Reading both is cheap; the day this is deleted is the
# day no `ck-` session or state file can still exist anywhere.
CLIKAE_SESS_PREFIX_LEGACY="ck-"

# tmux_sessv <id> — sets CLIKAE_TMUX_SESS and CLIKAE_TMUX_SESS_EXISTS for a session id.
#
#   CLIKAE_TMUX_SESS         the name to USE: an already-running session under
#                            either prefix, else the new-prefix name to create
#   CLIKAE_TMUX_SESS_EXISTS  1 when that session is already up, 0 when it is not
#
# Both answers come from one pass because the callers need both and asking tmux
# twice is two forks on the launch path. Sets variables rather than printing for
# the same reason — see profile_store.sh's `...v` helpers.
# tmux_sess_has_engine <session> -> 0 when it holds a window that is not the
# waiter, i.e. when it is a tank you can actually use.
#
# 🔴 `has-session` IS THE WRONG QUESTION and this is the failure it hides. The
# wake waiter lives in a window of the tank's own session, so when the engine
# exits — you quit it, or it crashed — the SESSION SURVIVES with only the waiter
# in it. wake_watch notices and leaves, but it polls on WAKE_WATCH_INTERVAL (60s),
# so for up to a minute the session is alive and empty of anything to talk to.
# `clikae <tank>` in that minute found has-session true, started no engine, and
# attached the human to a countdown with nothing to type into. Reported as
# "I had to press left-arrow to find you again".
#
# Prefix, not an exact name: the waiter renames its own window to carry the
# countdown (`wake 9m`), so matching `wake` exactly stops working seconds in.
tmux_sess_has_engine() {
  command -v tmux >/dev/null 2>&1 || return 1
  tmux list-windows -t "=$1:" -F '#{window_name}' 2>/dev/null \
    | grep -qvE '^wake( |$)'
}

# shellcheck disable=SC2034  # CLIKAE_TMUX_SESS_EXISTS is an output slot, read by
# the callers in switch.sh / antigravity.sh / burn.sh, which shellcheck analyses
# as separate files. Same shape as tui.sh's TUI_KEY.
tmux_sessv() {
  CLIKAE_TMUX_SESS="$CLIKAE_SESS_PREFIX$1"
  CLIKAE_TMUX_SESS_EXISTS=0
  command -v tmux >/dev/null 2>&1 || return 0
  if tmux has-session -t "=$CLIKAE_TMUX_SESS" 2>/dev/null; then
    CLIKAE_TMUX_SESS_EXISTS=1
    return 0
  fi
  # Nothing under the new name. An older session may still be up under the old
  # one — so RENAME it rather than learning to answer to two names forever.
  #
  # 🔴 Renaming on encounter, not in a one-shot migration, and the difference
  # matters here: this machine also has clikae 0.27.0 installed by brew, and an
  # older binary keeps creating `ck-` sessions after any migration has run. A
  # once-only sweep would leave those behind with nothing left to collect them.
  #
  # The wake waiter inside such a session has the OLD name baked into its
  # command (`clikae wake --watch … <session>`), and wake_watch exits cleanly the
  # moment `has-session` on that name fails — so the rename closes its window by
  # itself. switch.sh re-attaches one unconditionally, and wake_attach_watcher is
  # idempotent, so the waiter comes back on the very next launch rather than
  # being silently lost. It is the 3:50am nudge; it does not get to go missing.
  local _legacy="$CLIKAE_SESS_PREFIX_LEGACY$1"
  tmux has-session -t "=$_legacy" 2>/dev/null || return 0
  CLIKAE_TMUX_SESS_EXISTS=1
  if ! tmux rename-session -t "=$_legacy" "$CLIKAE_TMUX_SESS" 2>/dev/null; then
    # Something took the new name between the check above and here, or this tmux
    # refused. Answer to the old name rather than pretending the rename worked.
    CLIKAE_TMUX_SESS="$_legacy"
  fi
  return 0
}

# tmux_server_running -> 0 when a server is already up on the current socket.
# `list-sessions` rather than `has-session`: no target to guess, and tmux's
# exit-empty means a server with zero sessions does not linger.
tmux_server_running() {
  command -v tmux >/dev/null 2>&1 || return 1
  tmux list-sessions >/dev/null 2>&1
}

# _tmux_already_has <show-flags> <option> <needle> -> 0 when the option already
# contains the needle.
#
# WHY: `terminal-overrides` and `terminal-features` are APPENDED to, and the
# option block below runs on every session creation, not only when the server is
# born — so each spawn added another copy. Measured on a two-day-old server:
# four identical `*:smcup@:rmcup@` entries and four `xterm*:extkeys` ones.
#
# Harmless to tmux and invisible unless you go looking, but it is the same shape
# as the bug this whole layer exists to stop: an operation written as though it
# were idempotent when it is really cumulative.
_tmux_already_has() {
  tmux show-options "$1" "$2" 2>/dev/null | grep -qF -- "$3"
}

# tmux_usable -> 0 when an interactive tmux session is possible here.
# tmux is a convenience over `clikae run`, never a dependency (DESIGN-tmux Rule 2).
tmux_usable() {
  command -v tmux >/dev/null 2>&1 && [ -t 0 ] && [ -t 1 ]
}

# _tmux_ancestry -> a compact "who started us" chain, newest first, e.g.
#   bash<clikae<zsh<login<ghostty
# Best-effort and bounded. This is the breadcrumb that today's four-hour
# investigation did not have: PID 17229 could have been born by switch.sh's
# interactive path or by its unattended carry path, and the two leave byte-
# identical tmux command lines behind. By the time it matters the parent is
# always launchd, so the answer has to be written down at birth or not at all.
_tmux_ancestry() {
  local pid="$PPID" i=0 comm parent out=""
  while [ "$i" -lt 8 ]; do
    [ -n "$pid" ] || break
    case "$pid" in 0|1) break ;; esac
    comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    comm="${comm##*/}"
    [ -n "$comm" ] || break
    if [ -z "$out" ]; then out="$comm"; else out="$out<$comm"; fi
    parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    [ -n "$parent" ] || break
    pid="$parent"
    i=$((i + 1))
  done
  printf '%s' "${out:-unknown}"
}

# tmux_server_born_note — record what the server was created from, in the server
# itself. Read it back with `tmux show-environment -g CLIKAE_SERVER_BORN`.
#
# Cosmetic-grade failure handling on purpose: a tmux too old for set-environment,
# or a race with another client, must never fail a launch.
tmux_server_born_note() {
  local when tty_state
  when="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'unknown')"
  if [ -t 0 ] && [ -t 1 ]; then tty_state="tty"; else tty_state="no-tty"; fi
  tmux set-environment -g CLIKAE_SERVER_BORN \
    "$when $tty_state $(_tmux_ancestry)" 2>/dev/null || true
}

# tmux_server_born -> the recorded birth context, or nothing.
tmux_server_born() {
  command -v tmux >/dev/null 2>&1 || return 0
  tmux show-environment -g CLIKAE_SERVER_BORN 2>/dev/null \
    | sed -n 's/^CLIKAE_SERVER_BORN=//p'
}

# _tmux_ssh_agent_link -> print the stable socket path to forward, or nothing.
#
# Rule 4 keeps ONE symlink at a fixed path so a session's SSH_AUTH_SOCK stays
# valid across reconnects, and hands that path to the session instead of the
# agent's own. Which means that inside a clikae session, $SSH_AUTH_SOCK IS THE
# LINK — and spawning from in there ran
#
#     ln -sf <link> <link>
#
# which `-f` happily turns into a symlink pointing at itself. After that the
# guard's own `[ -S ]` fails, so the block was skipped, so it never repaired
# itself and stopped forwarding anything at all. Observed on the maintainer's
# machine 2026-08-23 as `ssh-add -l` answering "Error connecting to agent: Too
# many levels of symbolic links" — a sentence that names the mechanism perfectly
# and helps nobody who has not already guessed it.
#
# 🔴 THE POST-CONDITION IS THE GUARD, not the path comparison. Reasoning about
# which strings are equal covers the loop we know about; asking "is the thing I
# just made a socket" covers every way of arriving at one, including a caller
# whose SSH_AUTH_SOCK reaches the link by some other name.
_tmux_ssh_agent_link() {
  local link="$HOME/.clikae/state/clikae_ssh_auth.sock"
  local src="${SSH_AUTH_SOCK:-}"
  [ -n "$src" ] || return 1

  mkdir -p "$HOME/.clikae/state" 2>/dev/null || true
  chmod 0700 "$HOME/.clikae/state" 2>/dev/null || true

  # Already inside a clikae session: the variable names the link, and the link
  # is the only one who knows where the real agent is. Reuse it while it works;
  # when it does not, delete it rather than pass a broken path on — a spawn from
  # a terminal that still has a real agent will rebuild it.
  if [ "$src" = "$link" ]; then
    if [ -S "$link" ]; then printf '%s\n' "$link"; return 0; fi
    rm -f "$link" 2>/dev/null || true
    return 1
  fi

  [ -S "$src" ] || return 1
  ln -sf "$src" "$link" 2>/dev/null || return 1
  [ -S "$link" ] || { rm -f "$link" 2>/dev/null || true; return 1; }
  printf '%s\n' "$link"
}

# tmux_spawn_session --session <name> [--window <name>] [--env K=V]… -- <command>
#
# The only `tmux new-session` in the codebase. Holds, in one place:
#
#   Rule 1  Global options MUST be chained into the same invocation that creates
#           the session. Measured in 62b33a2: a standalone `tmux start-server \;
#           set-option -g history-limit 50000` returns 0 and the server then exits
#           immediately (exit-empty defaults on), so the setting evaporates and the
#           next session silently gets tmux's 2000-line default.
#   Rule 4  The SSH agent socket is injected as clikae's own stable symlink, never
#           the caller's raw $SSH_AUTH_SOCK, so a reconnect does not strand a
#           long-running session without git credentials.
#   Rule 5  Session names are whitelisted rather than quoted around.
#   Rule 7  What the server inherited at birth is written down (see above).
#   Rule 10 The tmux guard shim goes first on PATH before the session is
#           created, so the session — and everything it forks — inherits it.
#
# Returns 2 on a rejected name, 1 if tmux refused, 0 on success.
tmux_spawn_session() {
  local session="" window="" cmd=""
  local -a env_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) session="$2"; shift 2 ;;
      --window)  window="$2";  shift 2 ;;
      --env)     env_args+=("-e" "$2"); shift 2 ;;
      # Everything after `--` is the command, so stop rather than shift past the
      # end — a trailing `--` with nothing after it would fail the shift.
      --)        shift; cmd="${1:-}"; break ;;
      # Unknown flags are a caller bug, not something to skip quietly. This is the
      # one constructor; a typo'd option here would silently drop an option off a
      # server that then keeps the omission for life.
      *)         return 2 ;;
    esac
  done

  command -v tmux >/dev/null 2>&1 || return 1
  [ -n "$session" ] && [ -n "$cmd" ] || return 2
  # Rule 5 — do not rely on shell quoting to survive a hostile name.
  case "$session" in *[!a-zA-Z0-9_-]*) return 2 ;; esac

  # Rule 10 — the tmux guard shim (CVERInc/clikae#97, lib/shims/tmux) goes
  # first on PATH for the new session.
  #
  # 🔴 THE PANE'S OWN PROCESS, NOT `-e`, IS WHAT ACTUALLY CARRIES THIS (P1-1,
  # clikae#97 review round 1). `tmux(1)`'s own "GLOBAL AND SESSION
  # ENVIRONMENT" section says a new process's environment is the GLOBAL table
  # (frozen at server birth) merged with the SESSION table (only touched by
  # `-e`/`set-environment`) — PATH in neither by default — but measured
  # directly (throwaway -S server, no clikae involved) that is not what a
  # pane's REAL process gets: it inherits the SPAWNING CLIENT's live $PATH
  # instead, which `-e PATH=…` never touches and `tmux show-environment -t`
  # can never see either way (it only ever reports what `-e` wrote). An
  # earlier version of this function relied on `-e` alone for the whole
  # guarantee — every LAUNCH test read `show-environment` back and stayed
  # green — while the pane process itself, and everything it forked,
  # inherited whatever PATH the client happened to have. `doctor`'s
  # `_doctor_tmux_guard` had the identical blind spot for the identical
  # reason (P1-2, same review) and now reads the pane process directly.
  #
  # So: wrap the PANE'S OWN START COMMAND with `env PATH=…`, below, once
  # `$cmd` is otherwise finalised. That is the pane's own first exec — the
  # guard reaches it no matter what tmux does with its environment tables,
  # any client-PATH quirk included. `-e "PATH=…"` is kept alongside (next
  # line) as a harmless, documentary trace visible to `show-environment`;
  # nothing in clikae relies on it for the guarantee any more.
  #
  # Also mutate THIS process's own $PATH, idempotently: harmless, and it
  # means every tmux call this function goes on to make (including the
  # chain below) already resolves `tmux` through the guard too.
  local _shim_dir="$CLIKAE_LIB/shims"
  case "$PATH" in
    "$_shim_dir:"*) : ;;
    *) PATH="$_shim_dir:$PATH" ;;
  esac
  export PATH
  env_args+=("-e" "PATH=$PATH")
  # The real guarantee (see above): the pane's own process is `env`'s child,
  # so its PATH is exactly this, regardless of tmux. `printf %q` because $cmd
  # travels on to `new-session` as a single shell command STRING (tmux runs it
  # via the pane's default shell), and PATH is user- and machine-dependent
  # data, not something to splice in unquoted.
  #
  # 🔴 `-u _CLIKAE_TMUX_SHIM_HOPS` (clikae#97 review round 2, P2-1). The shim's
  # own cycle counter (lib/shims/tmux) has to survive an exec into a SCRIPT —
  # another guard, a version-manager shim — because that script may leapfrog
  # straight back into us (the whole reason the counter exists). But nothing
  # requires that script to be as careful: if it just execs onward to a real
  # binary without ever bouncing back (measured with `~/.local/bin/tmux`,
  # clikae#97 round 2), the counter rides along into THAT client's environment
  # — and if that client is the one that forks a new server (no socket existed
  # yet), the counter is now in the server's GLOBAL table forever, so every
  # future pane on it is born believing it is already mid-cycle. This is the
  # one place clikae controls unconditionally for every session it creates
  # (the same reasoning that put `PATH=` here for P1-1): strip the counter
  # from the PANE's own process the same way PATH is forced onto it.
  #
  # 🔴 THIS ONLY COVERS THE PANE THIS FUNCTION SPAWNS (review round 3,
  # P2-A). The earlier claim here, that a leaked counter "never reaches
  # anything clikae itself reads", was measured false: `new-window`, a split,
  # and clikae's own wake window (lib/core/wake.sh) inherit the server's
  # table, not this command line. What actually closes the leak is in the
  # shim: the counter is `<pid>:<n>` and only believed by that same pid or
  # its direct child, so a copy frozen into a server is ignored by every
  # pane. This `-u` stays because it costs nothing and keeps the pane's
  # environment clean.
  cmd="env -u _CLIKAE_TMUX_SHIM_HOPS PATH=$(printf '%q' "$PATH") $cmd"
  # 🔴 CONSTRAINS EVERY FUTURE CALLER: `$cmd` MUST BE A SIMPLE COMMAND (P3,
  # clikae#97 review round 2). `env … $cmd` only ever wraps the FIRST word —
  # `cd x && …`, `exec foo`, `A=1 foo`, or anything with `;`/`&&` in it would
  # change meaning (the guard would apply to `cd`, not to what runs after
  # it, or `env` would try to exec a shell builtin and fail). The four
  # current callers (switch.sh, burn.sh, antigravity.sh) all pass
  # `bash -c …`/`bash "<file>"`, which is simple by construction — not an
  # accident to rely on without saying so.

  # Rule 4 — a single global symlink, refreshed on every spawn.
  local _agent_sock=""
  # 🔴 `|| _agent_sock=""` is load-bearing, and its absence killed every spawn on
  # a machine with no agent. Two separate statements because `local x=$(...)`
  # reports local's status rather than the command's — but then, under `set -e`,
  # a bare assignment TAKES the exit status of its command substitution, and this
  # one returns 1 exactly when there is nothing to forward. Being part of a `||`
  # list is what exempts it. (`[ -n "$x" ] && …` on the next line is already
  # exempt: only the command after the final `&&` counts.)
  _agent_sock="$(_tmux_ssh_agent_link)" || _agent_sock=""
  if [ -n "$_agent_sock" ]; then
    env_args+=("-e" "SSH_AUTH_SOCK=$_agent_sock")
  fi

  # Ask BEFORE creating: after this call a server always exists, so "did I create
  # it" is unanswerable a line later.
  local births_server=0
  tmux_server_running || births_server=1

  local -a win_args=()
  if [ -n "$window" ]; then win_args=("-n" "$window"); fi

  # EXTENDED KEYS. tmux defaults to `extended-keys off`, which flattens a modifier
  # onto the key it modifies before the application ever sees it — so Shift+Enter
  # arrives as a plain Enter, and an engine that treats Enter as "send" submits the
  # message instead of inserting a newline. Reported 2026-08-13 as "shift+return
  # stopped inserting a line break", and it was: the tmux layer put a translator in
  # the middle of the keyboard.
  #
  # Two settings, because they answer different questions. `extended-keys on` is
  # whether tmux FORWARDS the extended encoding to the application — `on`, not
  # `always`, so it only does so for an application that asked, which is the
  # conservative half. `terminal-features …:extkeys` is whether tmux ASKS the outer
  # terminal for them at all; without it tmux never requests the sequences and
  # there is nothing to forward. Measured: with both set, a fresh client reports
  # `extkeys` among its features, and without them it does not.
  #
  # They are SERVER options, so this reaches the whole tmux server rather than one
  # session — the same scope history-limit and terminal-overrides already take.
  # Benign in the other direction: an application that never requests extended
  # keys is unaffected.
  #
  # 🔴 Only a NEW client picks the feature up. Terminal features are resolved when
  # a client attaches, so a session you are already inside keeps the old behaviour
  # until you detach and come back.
  #
  # SELECTING AND COPYING. Disabling the outer terminal's alternate screen (the
  # smcup@/rmcup@ override, needed so the scrollback capture has something to
  # capture) has a cost nobody costed: the terminal's own scrollback fills with
  # tmux's full-screen redraws, so scrolling the wheel shows redraw debris while
  # the clean 50000-line history sits in tmux where the wheel cannot reach it.
  # Reported 2026-08-15 as "since clikae started using tmux I cannot copy text",
  # and that is exactly right — the text was never selectable, it was unreachable.
  #
  #   mouse on          the wheel scrolls tmux's real history, and a drag selects
  #                     in it. Cost: a native terminal selection (to paste
  #                     somewhere tmux is not) now needs ⌥ held.
  #   set-clipboard on  a copy-mode yank reaches the SYSTEM clipboard over OSC 52.
  #                     tmux's default here is `external`, which passes an
  #                     application's own OSC 52 through but never emits one for
  #                     tmux's own selections — so before this, copying inside
  #                     copy-mode put the text in a buffer only tmux could paste.
  #
  # Rule 1 — ONE invocation. `tmux start-server \; set-option …` on its own
  # returns 0 and then the server exits (exit-empty), taking the settings with
  # it, so the options and the session that keeps them alive travel together.
  local -a chain=(start-server)
  chain+=(";" set-option -g history-limit 50000)
  # 🔴 SET window-size, do not inherit it. Rule 1 describes clikae's sizing
  # behaviour as "window-size latest 下最近使用的 client 決定尺寸" — and nothing
  # ever set it. tmux's own default has moved across releases, so the behaviour
  # the design doc promises held on 3.7b and not on 3.4: measured on ubuntu CI,
  # a 100-column client attached and the window stayed at default-size 80
  # (tests/bats/roam.bats "a second client attaches…", red there since this
  # layer landed while macOS passed every time).
  #
  # Roaming is the reason this layer exists — walk away from one device, pick the
  # session up on another — and it was resting on a default nobody chose.
  chain+=(";" set-option -g window-size latest)
  chain+=(";" set-option -s extended-keys on)
  # The two append-only options, added only when they are not already in place.
  #
  # 🔴 Only ASK when a server exists to ask. With no server there is nothing to
  # duplicate, so the answer is known without a query — and querying anyway means
  # running a tmux command against a socket that is not there, moments before
  # creating it. Some tmux builds start a server to answer such a query; ours
  # does not, which is exactly why this cost a green CI run to find. Whatever the
  # local build does, not asking is correct and cannot race with the create.
  if [ "$births_server" -eq 1 ]; then
    chain+=(";" set-option -ag terminal-overrides ",*:smcup@:rmcup@")
    chain+=(";" set-option -as terminal-features ",xterm*:extkeys")
  else
    if ! _tmux_already_has -g terminal-overrides '*:smcup@:rmcup@'; then
      chain+=(";" set-option -ag terminal-overrides ",*:smcup@:rmcup@")
    fi
    if ! _tmux_already_has -s terminal-features 'xterm*:extkeys'; then
      chain+=(";" set-option -as terminal-features ",xterm*:extkeys")
    fi
  fi
  # 🔴 BORN AT THE TERMINAL'S SIZE, NOT tmux's DEFAULT.
  # `new-session -d` is detached, and a detached session has no client to take
  # its size from — so tmux uses `default-size`, which is 80x24. The engine then
  # paints its first frame for 80 columns, and only afterwards do we attach and
  # tmux resize the window to the real terminal. Nothing repaints: there is no
  # SIGWINCH handling anywhere in clikae, and the board reads the width per
  # render, not per resize. So the first screen you see was laid out for a
  # terminal you are not using.
  #
  # Reported 2026-08-16 from a PineNote over ssh — a terminal narrower than 80 —
  # where the board "does not fit". Passing -x/-y makes the session born the
  # right size, so the first paint is already correct.
  #
  # Only when we have a controlling terminal to ask. A headless `burn` has none,
  # and inventing a size for it would be worse than tmux's default.
  local _sz _sw _sh
  _sz="$( { stty size </dev/tty; } 2>/dev/null || true )"
  _sh="${_sz%% *}"; _sw="${_sz##* }"
  # Each field checked on its own. A combined `case "$w:$h"` cannot express
  # "empty", because the string always contains the colon — shellcheck SC2195
  # caught exactly that in the first draft.
  case "$_sw" in ''|*[!0-9]*) _sw="" ;; esac
  case "$_sh" in ''|*[!0-9]*) _sh="" ;; esac
  if [ -n "$_sw" ] && [ -n "$_sh" ] && [ "$_sw" -ge 20 ] && [ "$_sh" -ge 5 ]; then
    win_args+=(-x "$_sw" -y "$_sh")
  fi
  chain+=(";" new-session -d "${env_args[@]}" -s "$session" "${win_args[@]}" "$cmd")

  # Say why, when it fails. A constructor that returns 1 in silence sends the
  # caller off to guess: on 2026-08-15 the same ubuntu-only failure was reasoned
  # about three times from a marker count, on a machine that could not reproduce
  # it, before anything printed the invocation that actually failed.
  local _rc=0
  tmux "${chain[@]}" || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    printf 'clikae: tmux refused to create the session (rc=%s)\n  tmux %s\n' \
      "$_rc" "${chain[*]}" >&2
    return 1
  fi

  # 🔴 mouse / set-clipboard go AFTER the session exists, not into the chain.
  #
  # A tmux command list aborts at the first failure — including the new-session
  # at the end of it. So any option in that chain that a given tmux build does
  # not accept does not merely fail to apply: it prevents the session from being
  # created at all, and the caller then finds nothing to attach to. That is what
  # red CI looked like from 2026-08-15: on ubuntu the attach printed "no
  # sessions", switch fell back to a direct run, and the scrollback capture the
  # test asserts on never happened. macOS was green throughout.
  #
  # Rule 1 requires the chain only because a server with no session evaporates
  # (exit-empty). Once new-session has run, that danger is over and later
  # set-options are safe as separate calls. So the options Rule 1 is actually
  # about stay in the chain; these two — which change how selection and copying
  # behave, not whether the session exists — cannot take a session down with
  # them.
  # The area of a client's terminal that the window does not cover is filled with
  # dots by default. With window-size `latest` (DESIGN-tmux Rule 1) a second,
  # smaller client — the PineNote arriving — shrinks the window, and the larger
  # screen fills with a field of them. A blank is the same information without
  # the texture. Cosmetic only, and it changes nothing about either client's size.
  tmux set-option -g fill-character " " 2>/dev/null || true
  # mouse on is unconditional and stays OUTSIDE the touch-scroll floor check
  # below: it needs none of the newer flags the touch bindings do, and it
  # predates this feature (was its own line before 2026-09-13). Gating it on
  # the same floor would regress mouse support itself on an old tmux for a
  # convenience feature that tmux does not even reach on that build.
  tmux set-option -g mouse on 2>/dev/null || true
  # TOUCH SCROLLING. Measured 2026-09-13: a-Shell on iPhone over ssh sends
  # a swipe as SGR button-1 press/release at different rows, never a wheel.
  # Claude Code asks for mouse tracking, so the default forwards that click and
  # history never moves. Translate a two-row displacement into copy-mode scroll;
  # a tap in copy-mode returns to the live view. Keep the normal press behaviour.
  #
  # Desktop wheels and drag selection use WheelUp/DownPane and
  # MouseDrag1Pane/MouseDragEnd1Pane; none of those bindings are replaced here.
  # Defaults use -o so a later launch preserves the human's off/speed settings.
  # Like mouse on, this chain runs AFTER creation: mouse support cannot prevent
  # a session from being born. The helper is a standalone script, avoiding the
  # CLI's state migration and profile setup on every release.
  #
  # 🔴 root's MouseUp1Pane binds run-shell ONLY, so it CONSUMES the release
  # instead of forwarding it. Stock tmux's root table has no MouseUp1Pane at
  # all — the release falls through to the pane's program by default — so any
  # app that tracks mouse state (Claude Code included) got the press and never
  # the release. Measured (tmux 3.4, throwaway socket, `mouse on`, pane running
  # `printf '\e[?1006h\e[?1000h'; cat -v`): stock tmux delivers both `M` and
  # `m`; the un-fixed binding delivered only `M` (2026-09 R1 review, P1-1).
  # Fixed by forwarding FIRST, translating second — `send-keys -M` before
  # `run-shell` — the same order stock tmux already uses for MouseDown1Pane's
  # own select-pane-then-forward. A swipe therefore also reaches the app as a
  # click at the release row (the app already got the press on the way down;
  # docs/usage.md says so).
  #
  # 🔴 copy-mode ALONE is not the copy key table on this machine, or on any
  # machine whose ~/.tmux.conf sets `mode-keys vi` (very common — vim users do
  # it by habit). tmux picks copy-mode OR copy-mode-vi at copy-mode-entry time
  # depending on the `mode-keys` option, and clikae has never set that option
  # — same lesson docs/DESIGN-tmux.md:74 already draws about `base-index`: not
  # setting an option does not mean the default applies, it means whatever the
  # human's rc file says applies. Binding only `copy-mode` left `copy-mode-vi`
  # falling back to root: Down never fires there (root's Down still runs, but
  # writes @clikae_touch_y on every press — including one made a moment before
  # entering copy-mode), and Up runs the helper against whatever @clikae_touch_y
  # was last written, not the value for this copy-mode session. Measured (tmux
  # 3.4, `set -g mode-keys vi`): a same-row tap AFTER a swipe that had already
  # entered copy-mode scrolled 36 -> 52 instead of cancelling — the only escape
  # a phone (no scroll wheel) has, going backwards (2026-09 R1 review, P1-2).
  # Fixed two ways, together: (a) mirror the copy-mode Down/Up pair onto
  # copy-mode-vi, so it gets its own fresh @clikae_touch_y instead of root's
  # leftovers; (b) touch_scroll.sh now UNSETS @clikae_touch_y the moment it
  # reads it (`set-option -pu`), so an Up with no Down on ITS OWN table is
  # structurally incapable of reusing a value some earlier Down left behind —
  # not "we remembered to clear it", but "there is nothing left to reuse".
  #
  # choose-mode / choose-mode-vi (`choose-tree`, the pane/window/session
  # picker) are deliberately LEFT UNBOUND here, not mirrored a third time. A
  # tap there is a SELECTION, not a swipe-cancel — that is a different design
  # than "leave copy-mode", and inventing one is out of scope for this fix.
  # A tap there — and in clock-mode (`Ctrl-b t`) — used to still reach this
  # helper via root's fallback (no choose-mode/clock-mode override exists to
  # catch it first) and appear to stack a view-mode layer over the picker
  # (`#{pane_in_mode}` 1 -> 2). Measured (2026-09 R2 review, P2-1): that
  # "layer" was never a real mode transition — tree-mode and clock-mode have
  # no `send-keys -X` command table, so the helper's `send-keys -X` call
  # failed with tmux's own `not in a mode`, and because touch_scroll.sh's two
  # send-keys calls were the only ones in the file not silenced, run-shell
  # rendered that stderr text as a view-mode box on top of the picker/clock —
  # a stacked error message, not a stacked mode. touch_scroll.sh now reads
  # #{pane_mode} (the mode NAME tmux is actually in, not the stack depth) and
  # only acts on '' (no mode), copy-mode, and view-mode; tree-mode, clock-mode,
  # choose-mode/choose-mode-vi, and any other mode name all exit before making
  # a tmux call, so the picker and the clock are left exactly as tmux's own
  # default leaves them. Selecting a tree-mode row on tap is still out of
  # scope for this fix — the gap is now a silent no-op, not an error overlay.
  # TAP ZONES (#108). The same touch that #88 reads for DISPLACEMENT carries a
  # second, unused signal: where on the pane it happened. A tap in the top
  # band pages the history back one screen, a tap in the bottom band pages
  # forward and then returns to the live view — a page per tap is the gesture
  # a phone can actually aim, where a swipe's two-row threshold on a 40-row
  # pane is a lot of thumb for a little history.
  #
  # 🔴 IT IS THE SAME BINDING, ON PURPOSE. Both features are decided inside
  # ONE MouseUp1Pane handler (touch_scroll.sh's decision tree: displacement
  # first, then zone, then leave it alone), because two bindings on one key
  # is not a design — tmux keeps the last one bound, and the feature that
  # lost would fail silently and only on a device nobody here owns.
  #
  # OFF BY DEFAULT (`@clikae_touch_pages off`), unlike #88's options, which
  # default on: this one takes a click that currently reaches the program and
  # gives it to tmux, so it has to be asked for. `@clikae_touch_pages_rows`
  # (default 3) is the band height. The press handlers also record
  # `@clikae_touch_h` (`#{pane_height}` at press time) next to
  # `@clikae_touch_y` — the band has to be measured against the geometry the
  # finger actually landed on, not whatever the pane has resized to by the
  # time the release is translated.
  # DRAG MOTION (#108, second half). Measured on a real iPhone 2026-09-16
  # (a-Shell -> ssh -> tmux 3.4, passive event log on the server): a TAP is
  # MouseDown1Pane + MouseUp1Pane on the same row, but a FLICK or a
  # press-and-drag is MouseDown1Pane + one MouseDrag1Pane per row crossed +
  # MouseDragEnd1Pane — and NO MouseUp1Pane at all. Everything above this
  # paragraph translates the click pair, so on the device it was written for it
  # never fired: tmux's own root `MouseDrag1Pane -> copy-mode -M` and
  # `MouseDragEnd1Pane -> copy-pipe-and-cancel` won every time, and the gesture
  # ended in "copied N chars to tmux buffer" instead of scrolling. The
  # MouseDown/MouseUp pair above is NOT replaced — a terminal that sends no
  # motion still needs it, and a tap still has no motion to send.
  #
  # 🔴 THESE SIX USE if-shell, NOT run-shell, AND THAT IS THE DESIGN. run-shell
  # throws the helper's exit status away, so a binding built on it can only
  # ever CONSUME the key. MouseDrag1Pane's stock meaning on a pane with no
  # mouse-tracking program is mouse drag-SELECTION — the way every desktop user
  # of this tool selects text — and there is no runtime signal that separates a
  # finger from a trackpad, because a-Shell's drag and a trackpad's drag are
  # the same tmux events. So the helper's status chooses: 0 means clikae
  # translated the gesture, non-zero means run tmux's OWN command for this key,
  # written out below verbatim from `list-keys` on a stock server
  # (`tmux -f /dev/null`). `@clikae_touch_drag off` is therefore not an
  # approximation of the default — it IS the default, drag-selection included.
  # Verified that a mouse event survives into an if-shell branch: a binding
  # whose shell command exited 1 ran `copy-mode -M` against the real press
  # (tmux 3.4, a client driven with raw SGR bytes).
  #
  # OFF BY DEFAULT for the same reason, on #108's tap-zone precedent: a gesture
  # that today reaches the program or the selection has to be asked for
  # (`set -g @clikae_touch_drag on`). @clikae_touch_scroll remains the master
  # switch over both halves.
  #
  # 🔴 EVERY FORMAT ARGUMENT IS QUOTED HERE AND NOT ABOVE. `#{pane_mode}`
  # expands to the EMPTY STRING outside a mode — not to a placeholder, to
  # nothing — so unquoted it produces NO argument and everything after it
  # shifts left one place. The MouseUp line above survives unquoted only
  # because #{pane_mode} is its LAST argument; the drag lines put two more
  # after it, so all five are quoted. The quotes are single quotes inside a
  # tmux double-quoted string: tmux expands the format first and `sh -c` then
  # sees a genuine empty argument.
  #
  # root MouseDragEnd1Pane is bound even though stock tmux leaves it UNBOUND:
  # declining there runs no else-command, which is exactly what an unbound key
  # does, so the two agree.
  local touch_helper touch_base touch_drag touch_end
  local bind_drag_root bind_drag_copy bind_end_copy
  touch_base="bash $(_switch_shquote "${CLIKAE_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/core/touch_scroll.sh")"
  touch_helper="$touch_base #{mouse_y} #{pane_id} #{pane_mode}"
  touch_drag="$touch_base '#{mouse_y}' '#{pane_id}' '#{pane_mode}' drag '#{mouse_x}'"
  touch_end="$touch_base '#{mouse_y}' '#{pane_id}' '#{pane_mode}' end '#{mouse_x}'"
  bind_drag_root="if-shell \"$touch_drag\" '' 'if -F \"#{||:#{pane_in_mode},#{mouse_any_flag}}\" \"send-keys -M\" \"copy-mode -M\"'"
  bind_drag_copy="if-shell \"$touch_drag\" '' 'select-pane ; send-keys -X begin-selection'"
  bind_end_copy="if-shell \"$touch_end\" '' 'send-keys -X copy-pipe-and-cancel'"
  # 🔴 THE FLOOR. `set-option -p` / `-pu` (pane-scoped options, used by every
  # binding below) needs tmux >= 3.1 (added CHANGES-3.0-to-3.1); the
  # copy-mode-vi key table needs only >= 2.4 (CHANGES-2.3-to-2.4) — 3.1 is the
  # binding floor. The repo declared no tmux floor anywhere before this
  # (2026-09 R1 review, P3-1): `bind-key` validates its own command AT BIND
  # TIME and a tmux command list aborts at the first failure, so on a tmux
  # below this floor the chain used to stop at the first line an old binary
  # rejected and install whatever came before it — a half-install that
  # happened to be all-or-nothing only by the accident of which command was
  # written first, silenced by `2>/dev/null || true`. Skip the whole chain
  # below the floor instead of gambling on write order.
  if _tmux_touch_scroll_floor_met; then
    tmux set-option -og @clikae_touch_scroll on \
      \; set-option -og @clikae_touch_scroll_lines 2 \
      \; set-option -og @clikae_touch_pages off \
      \; set-option -og @clikae_touch_pages_rows 3 \
      \; set-option -og @clikae_touch_drag off \
      \; bind-key -T root MouseDown1Pane 'set-option -p -t = -F @clikae_touch_y "#{mouse_y}"; set-option -p -t = -F @clikae_touch_h "#{pane_height}"; select-pane -t =; send-keys -M' \
      \; bind-key -T root MouseUp1Pane "send-keys -M; run-shell \"$touch_helper\"" \
      \; bind-key -T copy-mode MouseDown1Pane 'set-option -p -t = -F @clikae_touch_y "#{mouse_y}"; set-option -p -t = -F @clikae_touch_h "#{pane_height}"; select-pane -t =' \
      \; bind-key -T copy-mode MouseUp1Pane run-shell "$touch_helper" \
      \; bind-key -T copy-mode-vi MouseDown1Pane 'set-option -p -t = -F @clikae_touch_y "#{mouse_y}"; set-option -p -t = -F @clikae_touch_h "#{pane_height}"; select-pane -t =' \
      \; bind-key -T copy-mode-vi MouseUp1Pane run-shell "$touch_helper" \
      \; bind-key -T root MouseDrag1Pane "$bind_drag_root" \
      \; bind-key -T root MouseDragEnd1Pane "if-shell \"$touch_end\" ''" \
      \; bind-key -T copy-mode MouseDrag1Pane "$bind_drag_copy" \
      \; bind-key -T copy-mode MouseDragEnd1Pane "$bind_end_copy" \
      \; bind-key -T copy-mode-vi MouseDrag1Pane "$bind_drag_copy" \
      \; bind-key -T copy-mode-vi MouseDragEnd1Pane "$bind_end_copy" \
      2>/dev/null || true
  fi
  tmux set-option -s set-clipboard on 2>/dev/null || true

  if [ "$births_server" -eq 1 ]; then tmux_server_born_note; fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# THE STATUS LINE (#77). Composed HERE, in one function, and nowhere else.
#
# WHAT IT REPLACED, and why none of it was load-bearing. Until this, the bottom
# row of every session read:
#
#   [claude/hello] 0:claude* 1:wake …  "✳ [ KITT ] tending th"  20:06 12-Sep-26
#
# — a label clikae set (`tmux_label`), tmux's own window list, tmux's truncated
# pane title, and a clock with a date. It is the single most persistently
# visible string in the product, on screen for the whole session, and it
# answered none of the three questions the operator actually has every thirty
# seconds: how do I get back here, how much fuel is left, is anything red.
#
#   the window list   surfaced clikae's OWN `wake` watcher as a window the human
#                     never opened. What the watcher has to say ("this tank went
#                     dry") now arrives as the alert count instead.
#   the pane title    was truncated to 20 columns by tmux, and Claude Code
#                     already draws the session's name in its own top border.
#   the date          does not change while you are looking at it.
#
# THE LINE, left → right (issue #77, as corrected three times in its own thread
# by chodaict on 2026-09-12 — the corrections are the spec, not the opening
# proposal):
#
#   clikae resume a52bdc12 │ 5h 42% · 7d 65% │                          20:19
#   clikae resume a52bdc12 │ 5h 42% · 7d 65% │ !2 │                     20:19
#
# 🔴 NO EMOJI, AND THE ALERT SEGMENT IS ABSENT AT ZERO. The proposal's `🔴N`
# cannot be built: `scripts/signet-lint.sh` fails any printed emoji outside the
# ❯ cursor, and this string is printed. It is `!N`, coloured red by tmux, and
# it is not drawn at all when N is 0 — "a human does not need to see silence
# spelled out; the line is for what needs attention".
#
# 🔴 NO FLEET SEGMENT. The proposal's `reefbox x● hi● l○` was withdrawn in the
# same thread: per-tank fuel for the whole fleet belongs on the board
# (`clikae home`), which #72 turns into real numbers, and the status line is
# about THIS tank and THIS session. Nothing here enumerates tanks — the alert
# count is the one host-wide thing that survived, because "is anything red" is
# the question the row exists to answer.
#
# WHAT IT COSTS. tmux re-runs the `#()` helper every `status-interval` (5s) per
# attached client, inside tmux's own server process. So this whole path is
# FORK-FREE except where a fork is unavoidable (`date`, and the one command
# substitution that enumerates burn run directories): the JSON is read with
# burn_status_fieldv, the dry markers with dry_store_peekv, and nothing here
# calls a vendor, `curl`, `jq`, or `clikae` itself. Measured cost is in
# docs/DESIGN-tmux.md Rule 11.
#
# 🔴 AND IT NEVER WRITES. A status line that collected stale state would make
# "when did this marker disappear" depend on whether anyone was looking at a
# status bar — see dry_store_peekv's header for the read-only twin this needs.

# tmux_status_fuelv <engine> <tank> [now] -> $_TSTAT_FUEL, this tank's fuel,
# plus $_TSTAT_FUEL_AGE, the age of that reading as a bare phrase ("23h ago")
# or empty.
#
#   "5h 42% · 7d 65%"   from #72's usage CACHE, when it holds a reading
#   "⏳"                 the cache says the token expired (#107) — a state with a
#                       remedy, so it is not collapsed into "no reading"
#   "○" / "·"           the board's own dry / no-reading glyphs, when it does not
#
# 🔴 THE AGE IS A SEPARATE SLOT, not glued onto $_TSTAT_FUEL (P2-1, 2026-09-14
# round-3 review). It is rung 2 of the width ladder in tmux_status_rowv: the
# composer has to be able to DROP it, which it cannot do to a string it can
# only measure. Everything about when the suffix exists is still decided here.
#
# 🔴 THE CACHE FILE, NEVER THE VENDOR. `state/usage/<engine>/<tank>.json` (#72,
# PR #89) is written by `clikae usage`, by `burn` at run end, and — since the
# refresh had no owner on a machine that never burns — by this session's own
# `wake` window every WAKE_USAGE_INTERVAL (lib/core/wake.sh; the full list of
# writers is in lib/core/usage.sh). This reads
# whatever is on disk and is structurally incapable of fetching: a status line
# that could make a network call would make one every five seconds, per client,
# forever — and it runs in tmux's server, where nobody would ever see it fail.
# tests/bats/tmux-status.bats puts a loudly-failing `curl` on PATH to keep that
# true.
#
# A reading older than 24h is treated as unread rather than shown as current —
# the same ceiling docs/DESIGN-board-fuel-dots.md gives the board, and for the
# same reason: a week-old percentage presented as now is worse than no number.
# `cached_at` TRULY ABSENT (an older cache shape) is not aged out; we cannot
# judge what we cannot read — that decision stays. `cached_at` PRESENT but
# unparseable (P2-5/P3-2, 2026-09-14 round-1 fix review: pretty-printed JSON,
# an ISO string, any future writer shape this reader doesn't understand) is
# the opposite case and is now treated as UNTRUSTED, not as "must be current":
# collapsing "absent" and "present-but-garbled" into the same empty string (as
# this used to) meant a writer that changed `cached_at`'s shape would silently
# defeat the ceiling forever, on the reasoning "we cannot judge what we cannot
# read" — which is backwards for a field that IS there and IS unreadable.
#
# 🔴 P2-5 (same review): a reading between 1h and 24h old rendered pixel-for-
# pixel identical to one read a second ago — measured: `cached_at` "just now",
# 1h old and 23h old all painted `5h 42% · 7d 65%`, only the 24h ceiling itself
# (25h) visibly differed. Past 1h this now appends the board's own age
# formatter (`_human_age`, moved to lib/core/duration.sh in this same commit
# so a leaf-sourcing caller like this one doesn't have to pull in all of
# lib/commands/home.sh to get it — see that file's header for the same move
# already made for _burn_parse_duration) — "· 23h ago" — one shared
# implementation of "how stale is old enough to say so" instead of a second
# one invented here. Under 1h stays bare: that is recent enough that
# annotating it would be noise on a row with no room to spare (Rule 11 §7).
#
# The fallback is the DRY MARKER, not the board's full transcript scan. The
# board's dot costs ~4 ms of forks per call and is re-derived per redraw; this
# row redraws on a timer whether or not anyone is asking. The marker is what
# the live catchers (burn's stdout classifier, `_switch_supervise`) already
# wrote the moment they saw a limit, so it is the same fact, read the cheap way
# — and `·` honestly says "no reading" rather than inventing a green dot.
tmux_status_fuelv() {
  local engine="$1" tank="$2" now="${3:-}" f json w k ca ca_raw age fresh suffix src
  _TSTAT_FUEL=""; _TSTAT_FUEL_AGE=""
  case "$now" in ''|*[!0-9]*) now="$(date +%s 2>/dev/null || echo 0)" ;; esac

  f="${CLIKAE_HOME:-$HOME/.clikae}/state/usage/$engine/$tank.json"
  if [ -f "$f" ] && declare -F burn_status_fieldv >/dev/null 2>&1; then
    # P3-1 (2026-09-14 round-1 fix review): `read` without `-d ''` returns
    # non-zero (and skips the loop body) on a final line with NO trailing
    # newline, silently dropping it — a cache written without a trailing `\n`
    # read as completely empty. `read -r -d ''` reads to EOF regardless,
    # still no fork, and the `|| true` is for its own non-zero "no NUL found"
    # return, not an error.
    IFS= read -r -d '' json < "$f" || true
    burn_status_fieldv "$json" window_pct; w="$_BSF"
    burn_status_fieldv "$json" weekly_pct; k="$_BSF"
    burn_status_fieldv "$json" cached_at;  ca_raw="$_BSF"
    # A vendor percentage arrives as 42 or 42.0; the board owns precision, this
    # row owns width. Anything that is not a number at all (null, absent) fails
    # this and falls through to the glyph.
    w="${w%%.*}"; k="${k%%.*}"
    case "$w" in ''|*[!0-9]*) w="" ;; *) [ "$w" -gt 100 ] && w=100 ;; esac
    case "$k" in ''|*[!0-9]*) k="" ;; *) [ "$k" -gt 100 ] && k=100 ;; esac
    # P3-3: a corrupt cache ({"window_pct":999999}) must not blow the row's
    # width budget — clamp AFTER the numeric check above so a non-number stays
    # "" (falls through to the glyph) rather than being clamped into a fake 100.
    ca="$ca_raw"
    case "$ca" in ''|*[!0-9]*) ca="" ;; esac
    fresh=1; suffix=""
    if [ -n "$ca" ]; then
      age=$(( now - ca ))
      # P3-4 (2026-09-14 round-2 review): a future cached_at renders as a
      # reading taken now — bare percentages, no suffix, never a negative or
      # huge age. Decided, not defaulted: #89's writer and this reader share
      # one host clock, so a future stamp is skew on the order of seconds, and
      # the percentages it carries are still the vendor's; the review's other
      # option (untrusted, like an unparseable stamp) would blank a good
      # reading for a clock step. tests/bats/tmux-status.bats pins it.
      [ "$age" -lt 0 ] && age=0
      if [ "$age" -ge 86400 ]; then
        fresh=0
      elif [ "$age" -ge 3600 ] && declare -F _human_agev >/dev/null 2>&1; then
        # P2-2 (round-2 review): the `…v` form, not `$(_human_age …)` — that
        # was one subshell fork per render on this 5-second path.
        _human_agev suffix "$ca" "$now"
      fi
    elif [ -n "$ca_raw" ]; then
      fresh=0   # cached_at IS present, just not in a shape this reader understands — untrusted, not "current"
    fi
    if [ -n "$w" ] && [ -n "$k" ] && [ "$fresh" = 1 ]; then
      _TSTAT_FUEL="5h ${w}% · 7d ${k}%"
      _TSTAT_FUEL_AGE="$suffix"
      return 0
    fi
    # AN EXPIRED TOKEN IS NOT "NO READING". #107's whole point: an idle tank at
    # 99% weekly used to read exactly like a tank with no login at all. The
    # cache says which of the two this is (`source:"expired"`, written only with
    # `reason:"expired-token"` — see usage_unknown, lib/core/usage.sh), and the
    # remedy is one a person can act on: run a session, or `clikae usage --wake
    # <tank>`. So the row says so with the board's own mark for this state
    # (usage_expired_board_notev's `⏳`) rather than the glyph that means
    # "nobody has read this tank yet".
    #
    # 🔴 THE SAME FRESHNESS CEILING AS A READING, on purpose: `fresh` is already
    # decided above, and a nine-day-old "expired" is no more current than a
    # nine-day-old percentage. Past 24h this falls through to `·` — the honest
    # answer is then "no reading", not a remedy for a fact nobody rechecked.
    # (usage_read re-reads an expired entry after _USAGE_AUTH_FAIL_TTL_SEC
    # rather than the full TTL, so a refreshed token clears this in a minute.)
    #
    # NO AGE SUFFIX. The suffix qualifies a NUMBER ("42% · 3h ago"); this slot
    # carries no number, and rung 2 of the ladder exists to drop the qualifier
    # first, not to explain a glyph.
    if [ "$fresh" = 1 ]; then
      burn_status_fieldv "$json" source; src="$_BSF"
      if [ "$src" = '"expired"' ]; then
        _TSTAT_FUEL="⏳"
        return 0
      fi
    fi
  fi

  _TSTAT_FUEL="·"
  declare -F dry_store_peekv >/dev/null 2>&1 || return 0
  # `unknown` counts as a dry reading: the marker parsed, only the clock is
  # missing (P2-1, 2026-09-14 round-4 review — dry_store_peekv's verdicts).
  if dry_store_peekv "$engine" "$tank" "$now"; then
    case "$_DRY_PEEK" in fresh|unknown) _TSTAT_FUEL="○" ;; esac
  fi
  return 0
}

# tmux_status_alertsv [now] -> $_TSTAT_ALERTS, how many things on this host are
# red right now. Zero is normal and means the segment is not drawn at all.
#
# 🔴 COUNTED FROM STATE THAT ALREADY EXISTS. Nothing here writes a new kind of
# record, and nothing here is a judgement call this function invented:
#
#   a tank the live catchers marked dry   $CLIKAE_HOME/dry/<engine>/<tank>,
#                                         freshness by dry_store's own TTL. This
#                                         is the wake watcher's trigger — the
#                                         watcher fires BECAUSE this file
#                                         appeared — so it is issue #77's "wake
#                                         watchers that fired", read from the
#                                         durable half of that event rather than
#                                         from a window name that vanishes with
#                                         the session.
#   a burn lane whose writer is gone      $HOME/.clikae/logs/burn-*/status.json
#                                         still saying `running`/`waiting-reset`
#                                         with a pid that no longer exists —
#                                         #41's own definition of a lane that
#                                         died without reaching a terminal state,
#                                         i.e. without an artifact. A lane that
#                                         reached `fail` is NOT counted: it
#                                         printed its reason to whoever ran it.
#                                         That is the difference between "died"
#                                         and "failed", and only the first is
#                                         news nobody has been told.
#
# 🔴 SKIPPED-BY-STATE LANES PAY NOTHING BEYOND READING THE FILE (P1-1,
# 2026-09-14 round-1 fix review). `state` is parsed and switched on BEFORE
# `pid` is ever touched — a `fail`/`dry`/`done`/`infra` lane's other fields
# are never read at all. (Round 1 also claimed a failed lane's `reason` made
# this the expensive case; P2-6 of the round-2 review measured that false —
# `reason` is capped at 200 bytes and a real status.json is ~366 bytes, see
# burn_status.sh. What actually grows this loop's cost is the NUMBER of run
# directories — 97 on the development host, 7-day retention — not their size.)
#
# 🔴 A DEAD PID IS RED, HOWEVER LONG THE LANE RAN (P2-3, 2026-09-14 round-2
# review). Round 1 (P2-1) made a dead pid self-clear once `updated_at` was
# CLIKAE_DRY_TTL (6h) old, calling it "the same clock" as a stale dry marker.
# It is not the same clock: dry's stamp is the moment a limit was OBSERVED,
# but burn writes `running`/`waiting-reset` once at the START of an attempt
# (lib/commands/burn.sh has no periodic write while the engine runs), so
# `updated_at` is when the attempt began, not a heartbeat. Measured: a lane
# that ran 7h and died a second ago counted `!0`; a `waiting-reset` lane
# SIGKILLed after sleeping a day toward a weekly reset counted `!0` — the lanes
# most likely to die unattended were exactly the ones this could never report.
#
# So liveness decides: a live pid is never red, a dead one is. `updated_at`
# only bounds HOW LONG a dead lane stays red, and the bound is the retention
# the file itself lives under — `CLIKAE_BURN_LOG_RETENTION_DAYS` (7d), the
# same number `_burn_sweep_old_logs` removes the run directory at. The count
# can therefore never outlive the evidence, and a host that never runs
# `clikae burn` again still goes quiet after a week instead of never (round
# 1's P2-1, still closed). The price, stated rather than hidden: a lane whose
# single attempt started more than 7 days before it died is not reported.
# Nothing here deletes anything; the sweep is still the only remover.
#
# 🔴 CI RED IS NOT COUNTED, and that is a gap, not a decision to leave
# undocumented. Issue #77 lists "CI red seen by the Stop hook" as a third
# source; this repo's only Stop hook (`scripts/harness-stop-hook.sh`) records
# BLOCKED/ALLOWED report-gate verdicts to `state/harness-hook.log` and has never
# recorded a CI verdict. Counting it would mean inventing the state first, which
# is a different change; see docs/DESIGN-tmux.md Rule 11.
#
# 🔴 A `running` LANE WITH NO READABLE PID IS RED (P3-2, 2026-09-14 round-3
# review). This used to `continue` on it — measured: `{"state":"running",
# "pid":"x"}` counted `!0` — which made this the THIRD reader of the same
# "present but unreadable" situation in one render, and the only one going the
# other way (tmux_status_fuelv distrusts an unreadable `cached_at`,
# dry_store_peekv expires an undateable stamp, and this one shrugged).
#
# The reason it is red, and not merely consistency: `_burn_status_write`
# (lib/commands/burn.sh) writes `"pid":$$` unconditionally, so there is no
# legitimate `running` object without a numeric pid. An unreadable one is a
# truncated write, a half-finished `mv`, or a writer this reader does not
# understand — and in ALL THREE the thing the row is trying to report, a lane
# that stopped without reaching a terminal state, is exactly what a torn status
# file is evidence OF. "I cannot prove this writer is alive" is news on a row
# whose job is "what is unattended".
#
# It is bounded like every other red here: the same `updated_at` retention
# window applies below, so a torn file stops counting once its own run
# directory is old enough to be swept, and an unreadable `updated_at` is simply
# no bound (it stays until the sweep removes the directory) rather than a
# different clock.
#
# 🔴 LIVENESS IS `kill -0` PLUS ONE `ps`, AND ONLY FOR A PID THAT ALREADY
# FAILED (P3-1, 2026-09-14 round-3 review). This deliberately is NOT
# burn_status.sh's _burn_pid_matches_marker: that guard costs a `ps` per
# candidate and exists to stop a RECYCLED pid from refusing a real burn
# forever. But `kill -0` alone cannot tell ESRCH from EPERM — measured on this
# machine as an ordinary user, `kill -0 1` (init, root's) returns 1, exactly
# like a pid that does not exist, so a `running` lane whose pid had been
# recycled onto ANOTHER USER'S process counted as dead. The header used to say
# the errors were asymmetric in the safe direction ("a recycled pid makes this
# UNDERCOUNT"); that was true for a pid recycled onto one of OUR processes and
# false for every other user's, and this row's whole claim is that it never
# cries wolf. So a pid that fails `kill -0` is checked once with `ps -p`: still
# on the process table means alive-and-foreign, which is never red. The cost is
# paid only by a candidate that is already in a `running`/`waiting-reset` state
# AND already failed `kill -0` — normally none per render, and never one per
# marker.
#
# What is left, stated rather than hidden, in BOTH directions — because "the
# ONLY direction it misses in is undercount" is what this header said after the
# round-3 fix, and it is not true when `ps` cannot answer (P3-3, 2026-09-14
# round-4 review):
#
#   AS LONG AS `ps` CAN ANSWER, the only miss is an UNDERCOUNT: a pid recycled
#   onto any live process (ours or a stranger's) reads as "the lane is still
#   running" and we stay quiet. That is the direction a row that must never cry
#   wolf should miss in.
#
#   WHEN `ps` CANNOT ANSWER, the same recycled pid becomes an OVERCOUNT. Two
#   ways that happens: `ps` is not installed (there is no `command -v ps` guard
#   here — a missing `ps` simply returns non-zero), and `/proc` mounted
#   `hidepid=2`, the default on Proxmox and on plenty of hardened multi-user
#   hosts, where an ordinary user's `ps -p <another user's pid>` exits 1 exactly
#   like a pid that does not exist. Measured with a `ps` that always fails, over
#   nine synthetic run directories: `!5` where a working `ps` gives `!4` — the
#   extra one being a live process belonging to someone else. So on such a host
#   this row can report one lane as unattended that is in fact somebody else's
#   running process; it cannot LOSE a real alert that way.
#
# It is left as a statement rather than a guard on purpose: `command -v ps`
# would only catch the first of the two, and under `hidepid=2` there is no
# answer to distinguish "gone" from "not yours" — the row would have to invent a
# third verdict for a case where it has no evidence either way. Naming the
# environment is what a reader of this function actually needs.
tmux_status_alertsv() {
  local now="${1:-}" n=0 f e t d s json st pid upd dead_age keep_s
  _TSTAT_ALERTS=0
  case "$now" in ''|*[!0-9]*) now="$(date +%s 2>/dev/null || echo 0)" ;; esac
  keep_s="${CLIKAE_BURN_LOG_RETENTION_DAYS:-7}"
  case "$keep_s" in ''|*[!0-9]*|0) keep_s=7 ;; esac
  keep_s=$(( keep_s * 86400 ))

  if declare -F dry_store_peekv >/dev/null 2>&1; then
    for f in "${CLIKAE_HOME:-$HOME/.clikae}"/dry/*/*; do
      [ -f "$f" ] || continue
      t="${f##*/}"
      e="${f%/*}"; e="${e##*/}"
      dry_store_peekv "$e" "$t" "$now" || continue
      # fresh, or `unknown` — a marker whose stamp parsed but which no clock
      # could be aged against (P2-1, round-4). Under-counting there is the
      # exact harm that finding names: three fresh markers vanishing from `!4`
      # the moment `date` fails.
      case "$_DRY_PEEK" in fresh|unknown) n=$((n + 1)) ;; esac
    done
  fi

  if declare -F burn_status_dirsv >/dev/null 2>&1 \
     && declare -F burn_status_fieldv >/dev/null 2>&1; then
    burn_status_dirsv
    for d in "${_BSDIRS[@]:-}"; do
      [ -n "$d" ] || continue
      s="$d/status.json"
      [ -f "$s" ] || continue
      json=""
      IFS= read -r -d '' json < "$s" || true   # P3-1: see tmux_status_fuelv's twin fix
      burn_status_fieldv "$json" state; st="$_BSF"
      st="${st#\"}"; st="${st%\"}"
      case "$st" in running|waiting-reset) ;; *) continue ;; esac
      burn_status_fieldv "$json" pid; pid="$_BSF"
      case "$pid" in
        ''|*[!0-9]*)
          # P3-2 (round-3 review): a `running` lane whose pid is ABSENT or
          # unreadable. Counted, not skipped — see the header block above.
          ;;
        *)
          kill -0 "$pid" 2>/dev/null && continue   # still alive — not news, however old
          # P3-1 (round-3 review): `kill -0` says 1 for BOTH "no such process"
          # and "not yours". Only the first is dead. See the header block above.
          ps -p "$pid" >/dev/null 2>&1 && continue # alive, just someone else's
          ;;
      esac
      # P2-3 (round-2 review): pid liveness decides, not age. A dead writer is
      # red; `updated_at` only bounds how long, and the bound is the log
      # retention the file itself lives under — see the header block above
      # for why it is not CLIKAE_DRY_TTL any more.
      burn_status_fieldv "$json" updated_at; upd="$_BSF"
      case "$upd" in ''|*[!0-9]*) upd="" ;; esac
      if [ -n "$upd" ]; then
        dead_age=$(( now - upd ))
        [ "$dead_age" -ge "$keep_s" ] && continue
      fi
      n=$((n + 1))
    done
  fi

  _TSTAT_ALERTS="$n"
  return 0
}

# tmux_status_render <engine> <tank> <sid> <host> <width> -> the whole left side
# of the row on stdout. Pure: every input is an argument or $CLIKAE_HOME/$HOME,
# so tests/bats/tmux-status.bats renders it without a tmux server anywhere.
#
# THE RECONNECT COMMAND is the left segment because it is literally the string
# you would type to get back here, and it is copy-pasteable:
#
#   a session with a known transcript id   `clikae resume <8 chars>` — the
#                                          prefix, not the UUID, because
#                                          `clikae resume` resolves a unique
#                                          prefix (lib/commands/resume.sh) and
#                                          36 characters would own the row.
#   a session without one                  `clikae <engine> <tank>` — codex and
#                                          antigravity bare launches record no
#                                          sid (see tmux_set_session_id), and
#                                          this is the exact command that
#                                          reattaches that tank. Never a bare
#                                          `clikae resume`, which would open a
#                                          picker rather than come back HERE.
#
# 🔴 THE WIDTH RULE: a yield ladder with a fixed priority, and the alert count
# and the clock are never on it. Issue #77 asks that the row fit 120 columns and
# that exactly one segment truncate below 100. The segment the proposal named for
# that job — the session title — was removed by the same thread's third
# correction, and round 1 and round 2 each shipped a rule that named ONE
# variable-width thing and was wrong about it:
#
#   round 1  "the only variable-width thing is somebody's hostname"  — the fuel
#            age suffix (`· 23h ago`, 0 or 9-10 columns) was the second one, and
#            at 100 columns with a 30-character host tmux cut the CLOCK.
#   round 2  the prefix now yields to the measured width — but `clikae <engine>
#            <tank>` is the THIRD one. `validate_name` (lib/core/profile_store.sh)
#            caps a tank name's CHARACTER SET, not its length. Measured on real
#            tmux 3.4 at 80 columns with a 23h-old cache: a 24-character claude
#            tank cut the clock (`!10 0:25`), and a 27-character antigravity tank
#            cut the ALERT COUNT itself (`!10` → `!`) — the one thing on this row
#            that is ever news, shortened without a mark.
#
# So the rule is no longer "which segment is variable-width" (three of them are)
# but "in what order do they give". tmux_status_rowv is that order, and it is
# fixed:
#
#   1. the `ssh <host> -t ` prefix   dropped whole, never cut — half a hostname
#                                    is not a command anyone can run, and
#                                    `clikae resume a52bdc12` alone is already
#                                    exactly right on the host reading the row.
#                                    (Below 100 columns it is never added.)
#   2. the fuel AGE suffix           `· 23h ago` goes; the percentages stay. The
#                                    reading is still the reading; losing its age
#                                    costs a qualifier, not a number.
#   3. the TANK NAME, elided in the  `averyverylongtankname` → `aver…name`, floor
#      middle to a floor of 8        8 columns. Elided, not truncated, and with
#                                    `…` in it, because a name cut at the end
#                                    reads as a DIFFERENT tank that exists —
#                                    silently wrong is worse than visibly short.
#   4. the ENGINE word               `clikae claude x` → `clikae x`. This is the
#                                    rung that stops being a paste-able command,
#                                    which is why it is last of the four.
#   5. the fuel segment, whole       the floor guard: only what rungs 1-4 cannot
#                                    reach, and it exists so that rule below is
#                                    an invariant and not a hope.
#
# 🔴 THE ALERT COUNT AND THE CLOCK ARE NEVER CUT. `!N` is why this row exists
# ("what is red"), and a clock with its hour missing is not a clock. Everything
# above yields first, all the way down to a row that is `clikae <8 columns of
# tank> │ !N `. What is GUARANTEED at 80 columns is therefore: the whole alert
# count, the whole clock, and at least 8 columns of the tank name. The rest is
# best-effort in the order above. (The arithmetic floor is `26 + the alert
# count's digits` — 27 at `!7`, 28 at `!10`, 29 at `!100`: 7 for `clikae `, the
# tank's 8, 4 for ` │ !`, the digits, the clock's 6 and this row's own trailing
# space. P3-2, round-4 review: it was written here as the flat constant 28,
# which is the two-digit case mistaken for all of them. The spec still promises
# only 80.)
#
# Cells, not bytes: the row can carry `·`, `○`, `│` and `…`, each multi-byte in
# UTF-8, and each is replaced by one ASCII byte before anything is counted — so
# `${#s}` is a count of CELLS AS TMUX COUNTS THEM, under a UTF-8 locale and
# under C alike, with no fork. What that is NOT is a promise about the screen;
# see the function below.

# _tmux_status_colsv <string> -> $_TSTAT_COLS, its width in the cells tmux lays
# the row out in. Styles (`#[...]`) are never passed here — the composer counts
# the parts before it adds them.
#
# 🔴 THE UNIT IS TMUX'S `wcwidth`, WHICH IS NOT ALWAYS THE TERMINAL'S (P3-4,
# 2026-09-14 round-4 review). This function substitutes one ASCII byte for each
# of the four glyphs, so its answer equals the column count only while each of
# them is one column wide. Measured, and the news is good at this layer: on
# glibc, `wcwidth` returns 1 for `…` U+2026, `·` U+00B7, `│` U+2502 and `○`
# U+25CB in C.UTF-8, zh_TW.UTF-8 and ja_JP.UTF-8 alike (glibc keeps one width
# table for every locale), and a real tmux 3.4 laid out the same 90-cell ladder
# matrix identically in all three — not one cell off by one.
#
# What is outside this function's reach is the EMULATOR. All four glyphs are
# East Asian AMBIGUOUS width, and iTerm2, Terminal.app and Windows Terminal all
# offer "treat ambiguous-width as two columns". With that on, tmux still lays
# the row out at 1 and the screen draws 2 — up to 4-5 cells of drift on a full
# row, which misaligns the whole status bar rather than just this segment. That
# is not new here (`·` and `│` are the board's existing vocabulary, and the
# emulator setting breaks tmux's own layout the same way), but `…` gives it one
# more place to appear, and this comment used to read as though the substitution
# had settled the question. It has not: an ambiguous=2 terminal can overflow the
# row by one cell per `…` drawn, and nothing this helper can measure would see
# it. The ASCII alternative (`...`) would cost two more columns on the rung that
# is already the tightest, so the glyph stays and the limit is written down.
#
# (Names cannot reach into this: `validate_name` — lib/core/profile_store.sh —
# caps a tank name to `^[A-Za-z0-9._-]+$`, and tmux_status_render filters the
# host to `[a-zA-Z0-9._-]`, so `${#s}` is exactly their column count.)
_tmux_status_colsv() {
  local s="$1"
  # 🔴 never `~` as a replacement: bash 5.2 TILDE-EXPANDS the replacement
  # string, so `${s//…/~}` silently substitutes $HOME and inflates the count.
  s="${s//·/.}"; s="${s//○/o}"; s="${s//│/|}"; s="${s//…/.}"
  # 🔴 `⏳` IS TWO CELLS, AND THAT IS WHY IT GETS TWO BYTES. The four glyphs
  # above are East Asian AMBIGUOUS (tmux lays them out at 1); U+23F3 is WIDE,
  # so tmux lays it out at 2 whatever the locale says. Measured rather than
  # looked up — tmux 3.7b, throwaway socket, the glyph typed into a pane and
  # `#{cursor_x}` read back: `·` 1, `○` 1, `⏳` 2, `AB` 2. Counting it as one
  # cell would make the ladder hand out a column the row does not have, on the
  # rung where the alert count and the clock are supposed to be untouchable.
  s="${s//⏳/xx}"
  _TSTAT_COLS="${#s}"
}

# tmux_status_rowv <width> <host> <engine> <tank> <sid8> <fuel> <age> <alerts>
#   -> $_TSTAT_ROW, the whole left side of the row including its trailing space.
#
# PURE, in the strongest sense in this file: it reads no file, runs no command,
# and calls `date` never — every input is an argument. That is what makes the
# ladder above testable as a TABLE (tests/bats/tmux-status.bats) instead of as a
# story about tmux. tmux_status_render gathers the parts; this decides the shape.
#
# <sid8> non-empty means the command is `clikae resume <8 chars>`, which has no
# engine and no tank in it — rungs 3 and 4 simply do not apply, and the row that
# form produces is fixed-width.
tmux_status_rowv() {
  local width="$1" host="$2" engine="$3" tank="$4" sid="$5" fuel="$6" age="$7" alerts="$8"
  local sep=" #[fg=colour244]│#[default] "
  local avail cmd rest name ecols tcols fcols acols pcols base tshow need target h t
  local prefix=0 drop_age=0 drop_engine=0 drop_fuel=0 elide=0
  _TSTAT_ROW=""

  case "$width" in ''|*[!0-9]*) width=80 ;; esac
  # 6 columns for the clock at the right edge (`%H:%M `, status-right-length),
  # 1 for this row's own trailing space.
  avail=$(( width - 7 )); [ "$avail" -lt 1 ] && avail=1

  case "$alerts" in ''|*[!0-9]*) alerts=0 ;; esac
  acols=0; [ "$alerts" -gt 0 ] && acols=$(( 3 + 1 + ${#alerts} ))   # sep + `!` + digits
  _tmux_status_colsv "$fuel"; fcols="$_TSTAT_COLS"
  [ "$fcols" -gt 0 ] && fcols=$(( fcols + 3 ))                      # sep
  local agecols=0
  [ -n "$age" ] && [ "$fcols" -gt 0 ] && agecols=$(( 3 + ${#age} )) # ` · ` + phrase
  _tmux_status_colsv "$engine"; ecols="$_TSTAT_COLS"
  _tmux_status_colsv "$tank";   tcols="$_TSTAT_COLS"
  pcols=0; [ -n "$host" ] && pcols=$(( ${#host} + 8 ))              # `ssh ` + host + ` -t `

  tshow="$tcols"
  base=$(( 7 + ecols + 1 + tshow ))                                 # `clikae <engine> <tank>`
  [ -n "$sid" ] && base=$(( 14 + ${#sid} ))                         # `clikae resume <sid8>`

  # Rung 1. The prefix is added only when the WHOLE row still fits with it — it
  # is not a width threshold on the hostname, it is the measured row.
  if [ -n "$host" ] && [ "$width" -ge 100 ] \
     && [ $(( pcols + base + fcols + agecols + acols )) -le "$avail" ]; then
    prefix=1
  fi

  if [ "$prefix" = 0 ]; then
    # Rung 2. The age suffix.
    if [ $(( base + fcols + agecols + acols )) -gt "$avail" ]; then
      drop_age=1; agecols=0
    fi
    # Rung 3. The tank name, elided from the middle, never below 8 columns.
    if [ -z "$sid" ] && [ $(( base + fcols + acols )) -gt "$avail" ]; then
      need=$(( base + fcols + acols - avail ))
      target=$(( tcols - need )); [ "$target" -lt 8 ] && target=8
      if [ "$target" -lt "$tcols" ]; then
        elide="$target"; tshow="$target"; base=$(( 7 + ecols + 1 + tshow ))
      fi
    fi
    # Rung 4. The engine word.
    if [ -z "$sid" ] && [ $(( base + fcols + acols )) -gt "$avail" ]; then
      drop_engine=1; base=$(( 7 + tshow ))
    fi
    # Rung 5. The fuel segment, whole — the floor guard that makes "the alert
    # count is never cut" an invariant rather than an aspiration.
    if [ $(( base + fcols + acols )) -gt "$avail" ]; then
      drop_fuel=1; fcols=0
    fi
    # 🔴 GIVE BACK WHAT THE LATER RUNGS FREED (P3-1, 2026-09-14 round-4 review).
    # Rung 3 sizes the tank name against a row that still contains the engine
    # word and the fuel segment. When rung 4 or rung 5 then removes one of
    # those, the columns they freed were nobody's: `tshow` was already pinned,
    # so the name stayed elided harder than the finished row needs. Measured on
    # real tmux 3.4: claude + a 12-character tank at 40 columns drew
    # `clikae tttt…ttt │ !10` — 22 columns used of 33 available, with the WHOLE
    # name costing 4 more. A 24-character tank kept 8 columns where 20 fit.
    # A yield ladder yields as much as the next rung needs, not as much as the
    # rung it happened to be standing on when it did the arithmetic.
    #
    # This runs after rung 5 on purpose: the spare it hands back is what is left
    # once the fuel segment's own fate is settled, so widening the name can
    # never be the reason the fuel (or anything below it) is dropped. The order
    # of the ladder is unchanged; only the budget is re-read.
    if [ -z "$sid" ] && [ "$elide" -gt 0 ]; then
      local spare=$(( avail - base - fcols - acols ))
      if [ "$spare" -gt 0 ]; then
        target=$(( tshow + spare ))
        if [ "$target" -ge "$tcols" ]; then
          elide=0; tshow="$tcols"          # the whole name fits after all
        else
          elide="$target"; tshow="$target"
        fi
        base=$(( 7 + ecols + 1 + tshow ))
        [ "$drop_engine" = 1 ] && base=$(( 7 + tshow ))
      fi
    fi
  fi

  name="$tank"
  if [ "$elide" -gt 0 ]; then
    h=$(( elide / 2 )); t=$(( elide - 1 - h ))
    name="${tank:0:$h}…${tank:$(( tcols - t ))}"
  fi

  if [ -n "$sid" ]; then
    cmd="clikae resume $sid"
  elif [ "$drop_engine" = 1 ]; then
    cmd="clikae $name"
  else
    cmd="clikae $engine $name"
  fi
  [ "$prefix" = 1 ] && cmd="ssh $host -t $cmd"

  # The separator is dim so the segments read as segments and not as one
  # sentence; the alert count is the only thing that gets a colour, because it
  # is the only thing that is ever news.
  rest=""
  if [ -n "$fuel" ] && [ "$drop_fuel" = 0 ]; then
    rest="$rest$sep$fuel"
    [ -n "$age" ] && [ "$drop_age" = 0 ] && rest="$rest · $age"
  fi
  [ "$alerts" -gt 0 ] && rest="$rest$sep#[fg=red]!$alerts#[default]"

  _TSTAT_ROW="$cmd$rest "
  return 0
}

tmux_status_render() {
  local engine="$1" tank="$2" sid="$3" host="$4" width="$5"
  # P3-3 (2026-09-14 round-2 review): ONE state directory for the whole row,
  # resolved once, seen by every reader below through bash's dynamic scope —
  # not a default spelled separately in each of them.
  local CLIKAE_HOME="${CLIKAE_HOME:-$HOME/.clikae}"
  case "$width" in ''|*[!0-9]*) width=80 ;; esac
  # A session id reaches here from a tmux user option, which a human can set by
  # hand. Anything that is not a plain id is not one.
  case "$sid" in *[!a-zA-Z0-9-]*) sid="" ;; esac
  case "$host" in *[!a-zA-Z0-9._-]*) host="" ;; esac

  # ONE `date` for the whole row, handed to both readers. They each know how to
  # ask for their own if nobody tells them (a test calling one directly), but
  # the row asks once: two forks per redraw, per client, every five seconds, is
  # exactly the kind of cost that is invisible until it is not — and a row
  # whose two halves disagreed about what "now" is would age one marker out and
  # not the other.
  local now; now="$(date +%s 2>/dev/null || echo 0)"

  # Gather, then fit. The two are separate functions on purpose: everything
  # above this line touches the disk and the clock, everything below it is the
  # ladder, and only the ladder is a decision worth a table test.
  tmux_status_fuelv "$engine" "$tank" "$now"
  tmux_status_alertsv "$now"
  tmux_status_rowv "$width" "$host" "$engine" "$tank" "${sid:0:8}" \
    "$_TSTAT_FUEL" "$_TSTAT_FUEL_AGE" "$_TSTAT_ALERTS"

  printf '%s' "$_TSTAT_ROW"
}

# tmux_status_line <session> <engine> <tank> — the ONE place clikae writes a
# `status-*` option. Best-effort like everything else in this file: a tmux too
# old for one of these leaves that part of the default bar, and a launch never
# fails over cosmetics.
#
# 🔴 `status-format[0]`, not `window-status-format ''`, is how the window list
# goes away. `window-status-format` is a WINDOW option: setting it through
# `-t "=$session:"` reaches that session's CURRENT window only, so the `wake`
# watcher's window — opened later, by wake_attach_watcher — would come back
# carrying the default, and setting it `-g` instead would blank the window list
# in every session on the server, including ones the human opened themselves.
# `status-format[0]` is a SESSION option that replaces the entire row, window
# list included. Measured on tmux 3.4 in both directions: with it set the drawn
# row is `<left> … <clock>`, and with it unset the same session draws
# `<left> 0:sleep* 1:wake`.
#
# 🔴 `#{client_width}` IS EXPANDED INSIDE `#()`. tmux expands the command as a
# format before running it, so the helper is told the real width of the client
# that is about to draw the row — which is the only place that number exists
# (two clients of different sizes each get their own render). Every argument is
# single-quoted in the command string so an empty one (no known host) stays an
# empty ARGUMENT rather than disappearing. Measured on tmux 3.4: a four-argument
# invocation with an empty second argument arrives as `count=4`.
#
# HOST IS RESOLVED HERE, not in the helper. `#()` runs as a child of the tmux
# SERVER and inherits the server's environment — whoever started it, possibly
# days ago. This function runs in clikae's own process, i.e. in the shell the
# human is actually sitting in, so `$SSH_CONNECTION` here means "this launch
# arrived over ssh". It is evidence, not proof, and it is asymmetric in the safe
# direction: not knowing the host shows the plain command, which is correct
# where the row is being read. `$CLIKAE_HOST` wins outright, because the name a
# machine calls itself is often not the name that resolves from outside it.
tmux_status_line() {
  local session="$1" engine="$2" tank="$3" lib host cmd
  command -v tmux >/dev/null 2>&1 || return 0
  lib="${CLIKAE_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  host="${CLIKAE_HOST:-}"
  if [ -z "$host" ] && [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]; then
    host="$(uname -n 2>/dev/null || true)"
    host="${host%%.*}"
  fi
  case "$host" in *[!a-zA-Z0-9._-]*) host="" ;; esac

  cmd="bash $(_switch_shquote "$lib/core/status_line.sh")"
  cmd="$cmd $(_switch_shquote "$HOME")"
  cmd="$cmd $(_switch_shquote "${CLIKAE_HOME:-$HOME/.clikae}")"
  cmd="$cmd $(_switch_shquote "$engine") $(_switch_shquote "$tank")"
  cmd="$cmd $(_switch_shquote "$session") $(_switch_shquote "$host")"
  cmd="$cmd '#{client_width}'"

  tmux set-option -t "=$session:" status-interval 5 2>/dev/null || true
  tmux set-option -t "=$session:" status-left-length 200 2>/dev/null || true
  tmux set-option -t "=$session:" status-right-length 12 2>/dev/null || true
  tmux set-option -t "=$session:" status-justify left 2>/dev/null || true
  tmux set-option -t "=$session:" status-left "#($cmd)" 2>/dev/null || true
  # The clock, and no date: a date does not change while you are looking at it.
  tmux set-option -t "=$session:" status-right '%H:%M ' 2>/dev/null || true
  tmux set-option -t "=$session:" 'status-format[0]' \
    '#[align=left]#{T;=/#{status-left-length}:status-left}#[align=right]#{T;=/#{status-right-length}:status-right}' \
    2>/dev/null || true
  return 0
}

# tmux_label <session> <engine> <tank> — hand the row above to
# tmux_status_line, and name the WINDOW in clikae's own words.
#
# The history below is about the status bar, which this function owned until
# #77 moved it one function up. It is kept here because the window name it
# still sets was the other half of the same defect.
#
# That bar is the single most persistently visible string in the product: it sits
# in the corner for the whole session. Until v0.21 clikae never set it, so tmux
# derived it from an INTERNAL identifier and showed `[ck-claude-x:bash]`. Two
# different mistakes in eight characters:
#
#   `ck-`  — the session NAME has to be unique and must not collide with sessions
#            the user opened themselves, so the prefix earns its keep. But that
#            name was doing double duty as the human-facing label, and those are
#            not the same requirement. tmux lets them be separate, so they are:
#            the session stays `ck-<engine>-<tank>` for `tmux ls`, and the bar
#            shows `engine/tank` — the vocabulary the user already thinks in.
#   `bash` — a plain defect. The pane is running claude; the bar said bash,
#            because the launch command literally is `bash -c …`. Three tanks
#            open meant three windows called `bash`, which is precisely the one
#            job a status bar has.
#
# Best-effort throughout: a tmux too old for any of these options leaves the
# default bar, which is what we had yesterday. Cosmetics never fail a launch.
tmux_label() {
  local session="$1" engine="$2" tank="$3"
  # THE BAR ITSELF MOVED (#77). What `[engine/tank]` was telling you — which
  # tank this window is — the reconnect command now says more precisely, and as
  # something you can paste. This function keeps the other half of its job: the
  # WINDOW name, which is a different tmux object and still says `claude`
  # instead of `bash`. Both call sites want both, so the label stays the door.
  tmux_status_line "$session" "$engine" "$tank"
  # Without this tmux renames the window after whatever is running in it, and
  # `-n` is undone the moment the engine spawns a child.
  tmux set-window-option -t "=$session:" automatic-rename off 2>/dev/null || true
  # …and `-n` cannot be trusted to have survived to here either: on a machine
  # whose tmux has automatic-rename ON (which is tmux's own default), the window
  # is renamed in the gap between `new-session -n` and the line above. A test
  # found this by setting the option the way a user's config would; with the
  # maintainer's own config it never reproduced. So state the name again, now
  # that it will stick.
  local current
  current="$(tmux display-message -p -t "=$session:" '#{window_name}' 2>/dev/null || true)"
  # Never touch the waiter's window — it carries the countdown in its name.
  case "$current" in wake*) return 0 ;; esac
  tmux rename-window -t "=$session:" "$engine" 2>/dev/null || true
}

# tmux_set_session_id <session> <sid> — record WHICH transcript this tmux
# session is driving, at the one moment it is knowable: a spawn (never an
# attach/reuse — see the identity block in switch.sh's
# `_switch_run_tmux_wrapped`) that either resumed a SPECIFIC past session (its
# id read back out of the engine argv by adapter_sid_from_args — resume.sh's
# `_resume_exec`, home.sh's `_home_launch` "resume" case, and a hand-typed
# `clikae claude x -- --resume <sid>` all go through the same argv, so all
# three are covered the same way) or started a brand-new one whose adapter can
# be handed a caller-chosen id up front (adapter_new_session_args — claude:
# `--session-id <uuid>`). A launch with neither has nothing to pass here — an
# engine with no such hook still only picks its own session id once it is
# already running — and that is fine: the board's fallback
# (lib/commands/home.sh's _home_live_rows) marks a title it had to guess
# rather than pretending every row is this precise.
#
# Written in TWO places on purpose. The tmux option is what a live board reads
# (cheap, no extra file); the state file is what survives a query racing a
# session that is being torn down, and what lets anything outside tmux (a test,
# `clikae doctor`) read the same fact without asking the tmux server. Neither
# is load-bearing for launch itself — best-effort, like tmux_label above.
#
# 🔴 2026-09: the bug this exists to fix. Two live sessions on the SAME tank
# both fell back to "the tank's newest transcript" for their title (home.sh's
# _home_live_rows, `adapter_recent_sids "$dir" 1`), so a bare session and a
# resumed one showed IDENTICAL titles — whichever transcript had the most
# recent activity, on BOTH rows. The resolver was keyed by tank, never by which
# session a given row actually is. This is the other half of the fix: give a
# resumed (or freshly-minted) row something exact to key on instead of a
# guess. An earlier round threaded the resume id through an exported
# CLIKAE_LAUNCH_SID instead of reading it from argv — never unset, so a tmux
# SERVER born under it handed the variable to every later session on that
# server, stamping unrelated bare launches with a foreign sid (2026-09-12
# round-1 review, R1-P1-2). That variable no longer exists.
tmux_set_session_id() {
  local session="$1" sid="$2"
  [ -n "$session" ] && [ -n "$sid" ] || return 0
  tmux set-option -t "=$session:" @clikae_session_id "$sid" 2>/dev/null || true
  mkdir -p "$HOME/.clikae/state" 2>/dev/null || true
  printf '%s\n' "$sid" > "$HOME/.clikae/state/${session}.session_id" 2>/dev/null || true
}

# tmux_attach <session> <started_here> <scrollback_file>
# Attach, replay what scrolled past, and say whether tmux would host us at all.
# Returns 1 when tmux refuses (TERM it cannot draw on, for one) — and then puts
# back what we started, because `new-session -d` has already launched the engine
# and a session nobody can see still spends the account's quota.
tmux_attach() {
  local session="$1" started_here="$2" scrollback_file="$3"
  if tmux attach -t "=$session"; then
    if [ -s "$scrollback_file" ]; then
      awk '/^$/{b=b "\n"; next} {printf "%s%s\n", b, $0; b=""}' "$scrollback_file"
      rm -f "$scrollback_file"
    fi
    return 0
  fi
  # 🔴 TWO DIFFERENT FAILURES WEAR THE SAME EXIT CODE, and treating them alike
  # is how three of the maintainer's sessions left tmux for good on 2026-08-21:
  # the server died under them, all three attaches returned 1, and the caller
  # did what it does for a terminal tmux cannot draw on — relaunched the engine
  # OUTSIDE tmux. The conversations survived (`exec` keeps the pid) but they
  # were no longer in `tmux ls`, so they could not be reattached, listed by the
  # board, or reached from his phone.
  #
  # The two are told apart by asking whether tmux is still there afterwards —
  # not by how long the attach lasted, which is a clock, not a cause:
  #
  #   TERM tmux cannot draw on : rc=1 in 0.05s, server still up   -> 1
  #   the server went away     : rc=1 after 3.66s, nothing to ask -> 2
  #
  # A session that simply ENDED is not either of these: measured rc=0, with and
  # without other sessions on the server, so it never reaches this line. That
  # matters — a wrong 2 here would relaunch an engine the human just quit.
  if ! tmux has-session -t "=$session" 2>/dev/null && ! tmux list-sessions >/dev/null 2>&1; then
    rm -f "$scrollback_file"
    return 2
  fi
  [ "$started_here" -eq 1 ] && tmux kill-session -t "=$session" 2>/dev/null
  rm -f "$scrollback_file"
  return 1
}


# Kept under its original `_switch_` name on purpose: it has three call sites on
# the engine LAUNCH path, and a rename that misses one fails at runtime where
# neither `bash -n` nor shellcheck can see it. Core owns it now — that is the
# part that mattered (DESIGN-tmux Rule 2; burn.sh once wrote its own copy of
# this and got it wrong). A rename is a separate, isolated change.
# _tmux_touch_scroll_floor_met -> 0 if this tmux build is new enough for the
# touch-scroll bind-key chain (needs `set-option -p`/`-pu`, tmux >= 3.1), 1
# otherwise or if the version cannot be parsed (fail closed — this feature is
# a convenience, not a dependency, per DESIGN-tmux Rule 2; skipping it costs
# nothing a caller depends on). bash 3.2-safe, same per-segment numeric
# compare as update_version_gt (lib/core/update_check.sh) instead of a string
# compare, which would rank "3.10" below "3.9".
_tmux_touch_scroll_floor_met() {
  local v maj min
  v="$(tmux -V 2>/dev/null)"                 # "tmux 3.4", "tmux next-3.5", ...
  v="${v#tmux }"; v="${v#next-}"
  maj="${v%%.*}"
  min="${v#*.}"; min="${min%%[!0-9]*}"        # drop a trailing "a"/"b" suffix
  case "$maj" in ''|*[!0-9]*) return 1 ;; esac
  case "$min" in '') min=0 ;; *[!0-9]*) return 1 ;; esac
  [ "$maj" -gt 3 ] && return 0
  [ "$maj" -eq 3 ] && [ "$min" -ge 1 ] && return 0
  return 1
}

# _switch_shquote <string> -> the string as ONE POSIX-sh single-quoted word.
# The tmux session command is ultimately run by `sh -c`, and inside it we spawn
# `bash -c <target>`. Wrapping <target> in `"..."` (the old shape) let sh EXPAND
# it first: a passthrough arg carrying a double-quote, $, backslash, or backtick
# was mangled — and a backtick / $(...) was executed. Single-quoting with the
# canonical '\'' escape passes the built command through untouched.
_switch_shquote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
