#!/usr/bin/env bats
# tests/bats/ssh-agent-link.bats — DESIGN-tmux Rule 4's stable socket symlink.
#
# 🔴 THE DEFECT. Rule 4 hands a session a FIXED path instead of the agent's own,
# so the session survives a reconnect. Which means that inside a clikae session
# $SSH_AUTH_SOCK *is* that fixed path — and spawning from in there ran
#
#     ln -sf <link> <link>
#
# which `-f` turns into a symlink pointing at itself. From then on the guard's
# own `[ -S ]` test failed, so the whole block was skipped: it never repaired
# itself, and it stopped forwarding anything at all. Silent, permanent, and
# self-inflicted by the very feature that was supposed to make the path stable.
#
# Found on the maintainer's machine 2026-08-23, not by reading: `ssh-add -l`
# answering "Error connecting to agent: Too many levels of symbolic links".

load '../helpers'

_src_tmux() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
}

# A REAL unix socket. A regular file would pass `[ -e ]` and fail `[ -S ]`, so a
# stand-in would be testing a different question than the one that broke.
_mk_sock() {
  command -v python3 >/dev/null 2>&1 || skip "python3 needed to make a unix socket"
  python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$1"
}

LINK() { printf '%s/.clikae/state/clikae_ssh_auth.sock\n' "$HOME"; }

@test "ssh agent: a real socket gets the stable link pointed at it" {
  _src_tmux
  _mk_sock "$TEST_HOME/agent.sock"
  SSH_AUTH_SOCK="$TEST_HOME/agent.sock" run _tmux_ssh_agent_link
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$(LINK)" ] || { echo "got: $output"; false; }
  [ -S "$(LINK)" ] || { echo "the link is not a socket"; false; }
}

@test "ssh agent: spawning from INSIDE a session does not point the link at itself" {
  # 🔴 THE REGRESSION. $SSH_AUTH_SOCK is the link here, exactly as clikae set it
  # for the session — and the old code linked it to itself.
  _src_tmux
  _mk_sock "$TEST_HOME/agent.sock"
  SSH_AUTH_SOCK="$TEST_HOME/agent.sock" _tmux_ssh_agent_link >/dev/null

  SSH_AUTH_SOCK="$(LINK)" run _tmux_ssh_agent_link
  [ "$status" -eq 0 ] || { echo "a working link was thrown away: $output"; false; }
  [ "$output" = "$(LINK)" ]
  # Where it points is the whole question: still the agent, never itself.
  local target; target="$(readlink "$(LINK)")"
  [ "$target" = "$TEST_HOME/agent.sock" ] || { echo "now points at: $target"; false; }
  [ -S "$(LINK)" ] || { echo "the link stopped being a socket"; false; }
}

@test "ssh agent: a link that already points at itself is removed, not passed on" {
  # The state the maintainer's machine was actually in. Handing this path to a
  # session is worse than handing it nothing: everything that touches it gets
  # ELOOP, and the message names symbolic links rather than ssh.
  _src_tmux
  mkdir -p "$HOME/.clikae/state"
  ln -sf "$(LINK)" "$(LINK)"
  [ -S "$(LINK)" ] && { echo "premise broken: a self-link should not test as a socket"; false; }
  [ -L "$(LINK)" ] || { echo "premise broken: nothing was created"; false; }

  SSH_AUTH_SOCK="$(LINK)" run _tmux_ssh_agent_link
  [ "$status" -ne 0 ] || { echo "passed a looping path on: $output"; false; }
  [ -z "$output" ]
  # 🔴 `-L`, NOT `-e`. `-e` follows the link, a self-link cannot be followed, so
  # `[ ! -e ]` is TRUE for a file that is still sitting right there — this
  # assertion passed against the unfixed code until a mutation run exposed it.
  # The question is whether the entry exists, not whether it resolves.
  [ ! -L "$(LINK)" ] || { echo "the broken link survived: $(ls -l "$(LINK)")"; false; }
  [ ! -e "$(LINK)" ]
}

@test "ssh agent: a broken link is repaired by a spawn that has a real agent" {
  # The recovery path the removal above exists for.
  _src_tmux
  mkdir -p "$HOME/.clikae/state"
  ln -sf "$(LINK)" "$(LINK)"
  _mk_sock "$TEST_HOME/agent.sock"
  SSH_AUTH_SOCK="$TEST_HOME/agent.sock" run _tmux_ssh_agent_link
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$(LINK)")" = "$TEST_HOME/agent.sock" ]
  [ -S "$(LINK)" ]
}

@test "ssh agent: no agent means no link and no variable" {
  _src_tmux
  SSH_AUTH_SOCK="" run _tmux_ssh_agent_link
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$(LINK)" ] || { echo "made a link with nothing to point it at"; false; }
}

@test "ssh agent: a source that is not a socket is refused" {
  # `[ -e ]` would pass here. The question is whether it is an AGENT.
  _src_tmux
  : > "$TEST_HOME/not-a-sock"
  SSH_AUTH_SOCK="$TEST_HOME/not-a-sock" run _tmux_ssh_agent_link
  [ "$status" -ne 0 ]
  [ ! -e "$(LINK)" ]
}

@test "ssh agent: the spawned session is given the link, not the agent's own path" {
  # The point of Rule 4, executed rather than asserted about: what lands in the
  # session must be the stable path, or a reconnect breaks it.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_tmux
  _mk_sock "$TEST_HOME/agent.sock"
  SSH_AUTH_SOCK="$TEST_HOME/agent.sock" \
    tmux_spawn_session --session sshprobe -- 'sleep 30'
  run tmux show-environment -t '=sshprobe' SSH_AUTH_SOCK
  tmux kill-session -t '=sshprobe' 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "SSH_AUTH_SOCK=$(LINK)" ] || { echo "got: $output"; false; }
}

@test "ssh agent: a spawn with NO agent still starts a session" {
  # 🔴 THE REGRESSION THE UNIT TESTS COULD NOT SEE. Every check above calls
  # _tmux_ssh_agent_link directly, where returning 1 for "nothing to forward" is
  # correct and harmless. clikae runs under `set -eo pipefail`, where a bare
  # assignment takes the exit status of its command substitution — so that
  # correct 1 killed tmux_spawn_session outright, on exactly the machines with
  # no agent, which is most of them. Six green unit tests and a suite that went
  # red one function further out.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  run env -u SSH_AUTH_SOCK bash -c "
    set -eo pipefail
    . '$CLIKAE_TEST_ROOT/lib/core/log.sh'
    . '$CLIKAE_TEST_ROOT/lib/core/tmux.sh'
    tmux_spawn_session --session noagent -- 'sleep 30'
    echo SPAWNED
  "
  tmux kill-session -t '=noagent' 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "spawn died with no agent: $output"; false; }
  [[ "$output" == *"SPAWNED"* ]] || { echo "$output"; false; }
}

@test "ssh agent: a spawn whose link is ALREADY broken still starts a session" {
  # The other path through the same `return 1` — the state a machine is left in
  # after the old bug, reached from inside a session.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  mkdir -p "$HOME/.clikae/state"
  ln -sf "$(LINK)" "$(LINK)"
  run bash -c "
    set -eo pipefail
    export SSH_AUTH_SOCK='$(LINK)'
    . '$CLIKAE_TEST_ROOT/lib/core/log.sh'
    . '$CLIKAE_TEST_ROOT/lib/core/tmux.sh'
    tmux_spawn_session --session brokenlink -- 'sleep 30'
    echo SPAWNED
  "
  tmux kill-session -t '=brokenlink' 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "spawn died on a broken link: $output"; false; }
  [[ "$output" == *"SPAWNED"* ]] || { echo "$output"; false; }
}
