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

  # Rule 4 — a single global symlink, refreshed on every spawn.
  if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "${SSH_AUTH_SOCK:-}" ]; then
    mkdir -p "$HOME/.clikae/state" 2>/dev/null || true
    chmod 0700 "$HOME/.clikae/state" 2>/dev/null || true
    ln -sf "$SSH_AUTH_SOCK" "$HOME/.clikae/state/clikae_ssh_auth.sock" 2>/dev/null || true
    env_args+=("-e" "SSH_AUTH_SOCK=$HOME/.clikae/state/clikae_ssh_auth.sock")
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
  chain+=(";" set-option -s extended-keys on)
  chain+=(";" set-option -g mouse on)
  chain+=(";" set-option -s set-clipboard on)
  # The two append-only options, added only when they are not already in place.
  if ! _tmux_already_has -g terminal-overrides '*:smcup@:rmcup@'; then
    chain+=(";" set-option -ag terminal-overrides ",*:smcup@:rmcup@")
  fi
  if ! _tmux_already_has -s terminal-features 'xterm*:extkeys'; then
    chain+=(";" set-option -as terminal-features ",xterm*:extkeys")
  fi
  chain+=(";" new-session -d "${env_args[@]}" -s "$session" "${win_args[@]}" "$cmd")

  tmux "${chain[@]}" || return 1

  if [ "$births_server" -eq 1 ]; then tmux_server_born_note; fi
  return 0
}

# tmux_label <session> <engine> <tank> — make the status bar say where you are, in
# clikae's own words.
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
  tmux set-option -t "$session" status-left-length 40 2>/dev/null || true
  tmux set-option -t "$session" status-left "[$engine/$tank] " 2>/dev/null || true
  # Without this tmux renames the window after whatever is running in it, and
  # `-n` is undone the moment the engine spawns a child.
  tmux set-window-option -t "$session" automatic-rename off 2>/dev/null || true
  # …and `-n` cannot be trusted to have survived to here either: on a machine
  # whose tmux has automatic-rename ON (which is tmux's own default), the window
  # is renamed in the gap between `new-session -n` and the line above. A test
  # found this by setting the option the way a user's config would; with the
  # maintainer's own config it never reproduced. So state the name again, now
  # that it will stick.
  local current
  current="$(tmux display-message -p -t "$session" '#{window_name}' 2>/dev/null || true)"
  # Never touch the waiter's window — it carries the countdown in its name.
  case "$current" in wake*) return 0 ;; esac
  tmux rename-window -t "$session" "$engine" 2>/dev/null || true
}

# tmux_attach <session> <started_here> <scrollback_file>
# Attach, replay what scrolled past, and say whether tmux would host us at all.
# Returns 1 when tmux refuses (TERM it cannot draw on, for one) — and then puts
# back what we started, because `new-session -d` has already launched the engine
# and a session nobody can see still spends the account's quota.
tmux_attach() {
  local session="$1" started_here="$2" scrollback_file="$3"
  if tmux attach -t "$session"; then
    if [ -s "$scrollback_file" ]; then
      awk '/^$/{b=b "\n"; next} {printf "%s%s\n", b, $0; b=""}' "$scrollback_file"
      rm -f "$scrollback_file"
    fi
    return 0
  fi
  [ "$started_here" -eq 1 ] && tmux kill-session -t "$session" 2>/dev/null
  rm -f "$scrollback_file"
  return 1
}
