#!/usr/bin/env bats
# tests/bats/ephemeral.bats — `clikae <engine> <tank> --ephemeral`: this session's
# memory is a throwaway, the tank's real memory is left untouched.
# See docs/grammar.md §10.4. (NB: `[[ … ]]` assertions carry `|| false` — see
# tests/README.md.)

load '../helpers'

# A stub `claude` that writes a fact into whatever memory dir it's pointed at.
_stub_claude_writes_memory() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
slug="$(printf '%s' "$PWD" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
echo "EPHEMERAL-FACT" > "$CLAUDE_CONFIG_DIR/projects/$slug/memory/leaked.txt" 2>/dev/null || true
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
}

# The memory dir clikae would use for claude/<tank> at $PWD.
_memdir() {
  local slug; slug="$(printf '%s' "$PWD" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  printf '%s\n' "$CLIKAE_HOME/profiles/claude/$1/projects/$slug/memory"
}

@test "--ephemeral: the engine's memory writes do NOT persist to the tank" {
  _stub_claude_writes_memory
  clikae init claude work
  local mem; mem="$(_memdir work)"
  mkdir -p "$mem"; echo "REAL" > "$mem/real.txt"          # a real, persistent fact
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae claude work --ephemeral
  [ "$status" -eq 0 ]
  [ -d "$mem" ]                                            # real memory restored
  [ ! -L "$mem" ]                                          # as a real dir, not the link
  [ -f "$mem/real.txt" ]                                   # the real fact survived
  [ ! -f "$mem/leaked.txt" ]                               # the session's write did NOT leak in
}

@test "--ephemeral: works when the tank has no prior memory (nothing to stash)" {
  _stub_claude_writes_memory
  clikae init claude work
  local mem; mem="$(_memdir work)"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae claude work --ephemeral
  [ "$status" -eq 0 ]
  [ ! -f "$mem/leaked.txt" ]                               # nothing persisted
  [ ! -L "$mem" ]                                          # no stray symlink left behind
}

@test "--ephemeral: rejected for an engine clikae doesn't know the memory layout of" {
  clikae init codex work
  run clikae codex work --ephemeral
  [ "$status" -ne 0 ]
  [[ "$output" == *"isn't supported for 'codex'"* ]] || false
}

@test "--ephemeral: self-heals a crashed prior run (dangling link + stash)" {
  _stub_claude_writes_memory
  clikae init claude work
  local mem; mem="$(_memdir work)"
  mkdir -p "$(dirname "$mem")"
  mkdir -p "$mem.clikae-ephemeral-stash"
  echo "SURVIVED" > "$mem.clikae-ephemeral-stash/real.txt" # real memory left in the stash
  ln -s /tmp/gone-throwaway "$mem"                         # dangling link from the 'crash'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae claude work --ephemeral
  [ "$status" -eq 0 ]
  [ -d "$mem" ]
  [ ! -L "$mem" ]
  [ -f "$mem/real.txt" ]
  [ "$(cat "$mem/real.txt")" = "SURVIVED" ]                # recovered, not lost
}

# --- recovery on a NORMAL (non-ephemeral) launch. The 2026-07-19 incident: a
# hard terminal close (SIGHUP) skipped the EXIT-trap restore, so an own-memory
# tank was left dangling; the ephemeral path only self-heals on the NEXT
# ephemeral launch, so a plain `clikae claude <tank>` session never recovered it.
# soul_prelaunch's memory_heal_ephemeral now repairs it on ANY launch. ----------

@test "recovery: a plain launch restores an interrupted --ephemeral run's memory" {
  _stub_claude_writes_memory
  clikae init claude work
  local mem; mem="$(_memdir work)"
  mkdir -p "$(dirname "$mem")"
  mkdir -p "$mem.clikae-ephemeral-stash"
  echo "SURVIVED" > "$mem.clikae-ephemeral-stash/real.txt"
  ln -s "${TMPDIR:-/tmp}/clikae-ephemeral.GONE12" "$mem"   # dangling throwaway from the SIGHUP
  # NOTE: plain launch, NOT --ephemeral.
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae claude work
  [ "$status" -eq 0 ]
  [ -d "$mem" ]
  [ ! -L "$mem" ]
  [ -f "$mem/real.txt" ]
  [ "$(cat "$mem/real.txt")" = "SURVIVED" ]                # recovered on a normal session
  [ ! -d "$mem.clikae-ephemeral-stash" ]                   # stash consumed
}

@test "recovery: memory_heal_ephemeral drops a dangling throwaway link, keeps foreign links" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/soul.sh"
  local d="$BATS_TEST_TMPDIR/m"

  # (a) dangling throwaway link, no stash (a Soul-shared slot's crash): dropped,
  #     leaving the slot free for the soul re-link that follows.
  ln -s "${TMPDIR:-/tmp}/clikae-ephemeral.GONE34" "$d"
  memory_heal_ephemeral "$d"
  [ ! -e "$d" ] && [ ! -L "$d" ]

  # (b) a FOREIGN dangling link is NOT ours to delete — left untouched.
  ln -s "/tmp/some-user-symlink-that-is-broken" "$d"
  memory_heal_ephemeral "$d"
  [ -L "$d" ]
  rm -f "$d"

  # (c) a live memory dir is never clobbered, even with a stale stash beside it.
  mkdir -p "$d"; echo LIVE > "$d/x"
  mkdir -p "$d.clikae-ephemeral-stash"; echo STALE > "$d.clikae-ephemeral-stash/x"
  memory_heal_ephemeral "$d"
  [ -d "$d" ] && [ ! -L "$d" ]
  [ "$(cat "$d/x")" = "LIVE" ]                             # untouched
  [ -d "$d.clikae-ephemeral-stash" ]                      # stash left for the human
}

@test "--ephemeral: a hard SIGHUP still restores the real memory (EXIT trap via HUP)" {
  # Closing the terminal sends SIGHUP to the whole foreground group — the clikae
  # parent AND the engine child. The stub blocks until signalled so we can
  # reproduce that mid-session. Without the HUP trap the parent dies by default,
  # skipping the EXIT-trap restore and stranding memory on the throwaway link.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<STUB
#!/usr/bin/env bash
touch "$BATS_TEST_TMPDIR/ready"
exec sleep 30
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  clikae init claude work
  local mem; mem="$(_memdir work)"
  mkdir -p "$mem"; echo "REAL" > "$mem/real.txt"

  # Call the binary directly (not the helpers `clikae` function wrapper) so $pid
  # is the real clikae parent and its direct child is the engine — the shape the
  # HUP trap fires in. Through the wrapper, $pid would be an extra shell and the
  # signals would land a level off.
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" "$CLIKAE_BIN" claude work --ephemeral &
  local pid=$!
  local i=0; while [ ! -f "$BATS_TEST_TMPDIR/ready" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
  [ -f "$BATS_TEST_TMPDIR/ready" ]                         # engine actually started
  [ -L "$mem" ]                                            # mid-run: memory IS the throwaway link
  kill -HUP "$pid" 2>/dev/null || true                    # the parent (HUP trap defers to child exit)
  pkill -HUP -P "$pid" 2>/dev/null || true                # the engine child — as a terminal close does
  wait "$pid" 2>/dev/null || true                         # HUP → exit 129 → EXIT trap restores
  [ -d "$mem" ]                                            # real memory restored
  [ ! -L "$mem" ]
  [ "$(cat "$mem/real.txt")" = "REAL" ]                   # survived the hard close
}
