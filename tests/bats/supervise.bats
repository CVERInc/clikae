#!/usr/bin/env bats
# tests/bats/supervise.bats — the BETA supervised launch (lib/commands/switch.sh):
# the autonomy decision gate, a normal (non-dry) launch still works, and the
# dry-advance carries onward + logs it. The real interactive kill+resume can only
# be confirmed by dogfooding real claude — these cover the loop machinery.

load '../helpers'

# A stub `claude` that ALWAYS writes a genuine session-limit line to its tank's
# transcript, then exits — so the supervisor sees the tank as dry.
_stub_claude_limit() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
p="$CLAUDE_CONFIG_DIR/projects/x"; mkdir -p "$p"
printf '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit, resets 11pm"}]},"isApiErrorMessage":true,"timestamp":"%s"}\n' "$(date +%Y-%m-%dT%H:%M:%S)" >> "$p/s.jsonl"
echo "RAN claude $CLAUDE_CONFIG_DIR"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# A plain stub that just runs and exits cleanly (no limit).
_stub_claude_ok() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\necho "RAN claude $CLAUDE_CONFIG_DIR"\n' > "$BATS_TEST_TMPDIR/bin/claude"
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "_supervise_decision: full always auto" {
  source "$CLIKAE_TEST_ROOT/lib/commands/switch.sh"
  [ "$(_supervise_decision full 1)" = "auto" ]
  [ "$(_supervise_decision full 0)" = "auto" ]
}

@test "_supervise_decision: safe auto same-engine, pause to cross" {
  source "$CLIKAE_TEST_ROOT/lib/commands/switch.sh"
  [ "$(_supervise_decision safe 1)" = "auto" ]
  [ "$(_supervise_decision safe 0)" = "pause" ]
}

@test "_supervise_decision: ask always asks" {
  source "$CLIKAE_TEST_ROOT/lib/commands/switch.sh"
  [ "$(_supervise_decision ask 1)" = "ask" ]
  [ "$(_supervise_decision ask 0)" = "ask" ]
}

@test "a normal (non-dry) claude launch still runs and exits cleanly" {
  _stub_claude_ok
  clikae init claude work
  run clikae claude work
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN claude"* ]] || false
  # No carry happened, so no auto entry in history.
  [ ! -f "$CLIKAE_HOME/history" ] || ! grep -q "auto:" "$CLIKAE_HOME/history"
}

@test "full auto: a dry claude tank carries onward to the next tank + logs it" {
  _stub_claude_limit
  clikae init claude a
  clikae init claude b
  clikae auto full
  run clikae claude a
  # The supervisor detected the dry limit and carried onward to claude/b.
  grep -q "auto: claude/a dry → claude/b" "$CLIKAE_HOME/history"
}

@test "ask (default): a dry tank does NOT silently carry (no auto log) without a TTY" {
  _stub_claude_limit
  clikae init claude a
  clikae init claude b
  # autonomy defaults to ask; no TTY in `run`, so it must NOT auto-carry.
  run clikae claude a
  [ ! -f "$CLIKAE_HOME/history" ] || ! grep -q "auto:" "$CLIKAE_HOME/history"
}
