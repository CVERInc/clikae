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
