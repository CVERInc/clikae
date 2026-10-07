#!/usr/bin/env bats
# tests/bats/relay.bats — `clikae relay`
#
# relay exec's the target CLI, so we put a stub `claude` on PATH that records its
# argv + CLAUDE_CONFIG_DIR to a log file and exits, instead of the real binary.

load '../helpers'

# Install a fake `claude` on PATH. Writes argv/env to $CLAUDE_STUB_LOG.
_install_claude_stub() {
  mkdir -p "$TEST_HOME/bin"
  cat > "$TEST_HOME/bin/claude" <<'STUB'
#!/usr/bin/env bash
{
  echo "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"
  echo "ARGS=$*"
} > "$CLAUDE_STUB_LOG"
exit 0
STUB
  chmod +x "$TEST_HOME/bin/claude"
  export PATH="$TEST_HOME/bin:$PATH"
  export CLAUDE_STUB_LOG="$TEST_HOME/stub.log"
}

# Slug a path the way Claude Code does: [^A-Za-z0-9] -> '-'.
_slug() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

# Seed a transcript for <profile> covering directory <dir>.
_seed_transcript() {
  local profile="$1" dir="$2" sid="$3"
  local slug; slug="$(_slug "$dir")"
  mkdir -p "$CLIKAE_HOME/profiles/claude/$profile/projects/$slug"
  echo '{"type":"user","text":"hi"}' \
    > "$CLIKAE_HOME/profiles/claude/$profile/projects/$slug/$sid.jsonl"
}

@test "relay copies the current dir's transcript into the target and resumes it" {
  _install_claude_stub
  clikae init claude a
  clikae init claude b
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sid="11111111-2222-3333-4444-555555555555"
  _seed_transcript a "$work" "$sid"

  cd "$work"
  unset CLAUDE_CONFIG_DIR
  run clikae relay claude a b
  [ "$status" -eq 0 ]

  # Resumed the right session under profile b's config dir.
  grep -q "ARGS=--resume $sid" "$CLAUDE_STUB_LOG"
  grep -q "CLAUDE_CONFIG_DIR=$CLIKAE_HOME/profiles/claude/b" "$CLAUDE_STUB_LOG"

  # Transcript now present under b, and still present under a (non-destructive).
  local slug; slug="$(_slug "$work")"
  [ -f "$CLIKAE_HOME/profiles/claude/b/projects/$slug/$sid.jsonl" ]
  [ -f "$CLIKAE_HOME/profiles/claude/a/projects/$slug/$sid.jsonl" ]
}

@test "relay auto-detects the source profile from CLAUDE_CONFIG_DIR" {
  _install_claude_stub
  clikae init claude a
  clikae init claude b
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  _seed_transcript a "$work" "$sid"

  cd "$work"
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/a" run clikae relay claude b
  [ "$status" -eq 0 ]
  grep -q "ARGS=--resume $sid" "$CLAUDE_STUB_LOG"
}

@test "relay starts fresh when there is no transcript to carry" {
  _install_claude_stub
  clikae init claude a
  clikae init claude b
  local empty="$TEST_HOME/empty"; mkdir -p "$empty"

  cd "$empty"
  unset CLAUDE_CONFIG_DIR
  run clikae relay claude a b
  [ "$status" -eq 0 ]
  # No --resume: a plain run under b.
  grep -q "ARGS=$" "$CLAUDE_STUB_LOG"
  grep -q "CLAUDE_CONFIG_DIR=$CLIKAE_HOME/profiles/claude/b" "$CLAUDE_STUB_LOG"
}

@test "relay refuses when source and target are the same" {
  _install_claude_stub
  clikae init claude a
  run clikae relay claude a a
  [ "$status" -ne 0 ]
  [[ "$output" == *"same tank"* ]] || false
}

@test "relay refuses to carry onto a SOLO target (out of the fleet)" {
  _install_claude_stub
  clikae init claude a
  clikae init claude b
  clikae solo claude b
  run clikae relay claude a b
  [ "$status" -ne 0 ]
  [[ "$output" == *"SOLO"* ]] || false
  [[ "$output" == *"--off"* ]] || false
  [ ! -f "$CLAUDE_STUB_LOG" ]   # the engine was never launched on the solo tank
}

@test "relay errors when a named profile does not exist" {
  _install_claude_stub
  clikae init claude a
  run clikae relay claude a nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || false
}

@test "relay can't auto-detect source errors helpfully" {
  _install_claude_stub
  clikae init claude a
  clikae init claude b
  unset CLAUDE_CONFIG_DIR
  run clikae relay claude b
  [ "$status" -ne 0 ]
  [[ "$output" == *"explicitly"* ]] || false
}

# CVERInc/clikae-lab#1 (2026-10-07, reefbox over SSH from a phone): the board's
# dry-tank "carry onward" execs `clikae relay`, and relay's carry ended in the
# claude adapter's own `exec claude --resume` — the transcript landed on the new
# tank but the engine ran with no tmux session, no scrollback trap and no wake
# watcher, so it died with the SSH connection. `clikae claude <tank> -- --resume`
# had all three. These two pin both halves: with tmux, the carried session goes
# through switch's tmux launch; without tmux, relay still just runs the engine.

# A fake tmux: logs every argv (one record per call) and answers the few probes
# switch makes. has-session says "no such session", so switch creates one.
_install_tmux_stub() {
  mkdir -p "$TEST_HOME/bin"
  cat > "$TEST_HOME/bin/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HOME:?}/tmux-argv.log"
for a in "$@"; do
  case "$a" in
    -V) echo "tmux 3.4"; exit 0 ;;
    has-session) exit 1 ;;
    new-session|new|attach|attach-session|list-sessions|ls|display-message|show-options|set-option|set|set-environment|setenv|kill-server|switch-client) exit 0 ;;
  esac
done
exit 0
STUB
  chmod +x "$TEST_HOME/bin/tmux"
  # Settle the one-time asks so the pty run never waits on a prompt.
  echo off > "$CLIKAE_HOME/wake-on-reset"
  echo off > "$CLIKAE_HOME/warm-compact"
}

@test "relay (cross-tank carry) launches through switch's tmux path, like clikae <engine> <tank>" {
  command -v python3 >/dev/null 2>&1 || skip "python3 needed for the pty"
  _install_claude_stub
  clikae init claude wrasse
  clikae init claude goby
  _install_tmux_stub
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sid="8c66f1d2-a689-4d7a-aeac-f2420a13fdb7"
  _seed_transcript wrasse "$work" "$sid"

  cd "$work"
  unset CLAUDE_CONFIG_DIR
  # A real pty: without a terminal, switch is entitled to skip tmux.
  run _pty_run "$CLIKAE_BIN" relay claude wrasse goby --yes
  [ -f "$TEST_HOME/tmux-argv.log" ] || { echo "tmux never invoked: $output"; false; }

  local tlog; tlog="$(cat "$TEST_HOME/tmux-argv.log")"
  # The session is named like a normal launch, and its command carries the
  # scrollback trap and the resume of the carried sid.
  [[ "$tlog" == *"new-session"*"clikae-claude-goby-"* ]] || { echo "no clikae-claude-goby-* session: $tlog"; false; }
  [[ "$tlog" == *".clikae/state/clikae-claude-goby-"*".scrollback"* ]] || { echo "no scrollback trap: $tlog"; false; }
  [[ "$tlog" == *"--resume $sid"* ]] || { echo "carried sid not resumed: $tlog"; false; }
  # The transcript was carried.
  local slug; slug="$(_slug "$work")"
  [ -f "$CLIKAE_HOME/profiles/claude/goby/projects/$slug/$sid.jsonl" ]
}

@test "relay without tmux on PATH still execs the engine (tmux is never required)" {
  command -v python3 >/dev/null 2>&1 || skip "python3 needed for the pty"
  _install_claude_stub
  clikae init claude wrasse
  clikae init claude goby
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sid="8c66f1d2-a689-4d7a-aeac-f2420a13fdb7"
  _seed_transcript wrasse "$work" "$sid"

  # PATH with no tmux at all — shadow every directory that has one.
  local nodir="$TEST_HOME/notmux"; mkdir -p "$nodir"
  local d p=""
  IFS=: read -ra _dirs <<<"$PATH"
  for d in "${_dirs[@]}"; do
    [ -n "$d" ] || continue
    if [ -x "$d/tmux" ] && [ "$d" != "$TEST_HOME/bin" ]; then
      for f in "$d"/*; do
        [ "${f##*/}" = tmux ] && continue
        [ -e "$nodir/${f##*/}" ] || ln -s "$f" "$nodir/${f##*/}" 2>/dev/null || true
      done
      d="$nodir"
    fi
    p="${p:+$p:}$d"
  done

  cd "$work"
  unset CLAUDE_CONFIG_DIR
  # Even on a terminal (where switch WOULD use tmux), no tmux -> plain exec.
  PATH="$p" run _pty_run "$CLIKAE_BIN" relay claude wrasse goby --yes
  PATH="$p" command -v tmux && { echo "tmux still on PATH"; false; }
  grep -q "ARGS=--resume $sid" "$CLAUDE_STUB_LOG" || { echo "engine not run: $output"; false; }
  grep -q "CLAUDE_CONFIG_DIR=$CLIKAE_HOME/profiles/claude/goby" "$CLAUDE_STUB_LOG"
}
