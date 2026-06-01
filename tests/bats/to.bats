#!/usr/bin/env bats
# tests/bats/to.bats — `clikae to`: source auto-detection, especially the
# transcript-recency fallback that makes the bare-switch→to flow work from one
# shell (the switch/alias/.app never export the env var). See grammar §3.2 / §10.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_stub_claude() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\ntrue\n' > "$BATS_TEST_TMPDIR/bin/claude"
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
}

# Seed a transcript for $PWD under claude/<tank>.
_seed_tx() {
  local slug; slug="$(printf '%s' "$PWD" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  local p="$CLIKAE_HOME/profiles/claude/$1/projects/$slug"; mkdir -p "$p"
  printf '{"type":"user","message":{"role":"user","content":"hi from %s"}}\n' "$1" > "$p/s.jsonl"
}

@test "to: with no env var, detects the source from this dir's most recent transcript" {
  _stub_claude
  clikae init claude a
  clikae init claude b
  _seed_tx a                                   # a has this dir's only session
  unset CLAUDE_CONFIG_DIR
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae to b -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"most recent session"* ]] || false
  [[ "$output" == *"claude/a"* ]] || false     # detected source, then relays a→b
}

@test "to: picks the NEWEST tank's session when several exist here" {
  _stub_claude
  clikae init claude a
  clikae init claude b
  clikae init claude c
  _seed_tx a
  sleep 1
  _seed_tx c                                   # c is newer than a
  unset CLAUDE_CONFIG_DIR
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae to b -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude/c"* ]] || false     # newest wins
}

@test "to: errors clearly when there's no session in this directory to carry" {
  clikae init claude a
  clikae init claude b
  unset CLAUDE_CONFIG_DIR
  run clikae to b
  [ "$status" -ne 0 ]
  [[ "$output" == *"no recent session"* ]] || false
}
