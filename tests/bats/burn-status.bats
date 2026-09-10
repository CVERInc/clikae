#!/usr/bin/env bats
# tests/bats/burn-status.bats — #41: every burn writes ONE machine-readable
# status file, updated at every transition, so a cockpit never has to grep a
# burn log for "ran dry" / "[ FAIL ]" — both of which a task's own PROMPT can
# contain (the false alarm that opened this issue). See docs/orchestration.md
# ("Status file — #41") for the contract this pins.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

# Same stub shape as burn.bats: a ".dry" marker in the tank dir makes codex
# emit the limit line and write nothing; `run <path>` (raw-argv form) writes
# the artifact.
_stub_codex() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/codex" <<'STUB'
#!/usr/bin/env bash
if [ -f "$CODEX_HOME/.dry" ]; then
  echo "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
  exit 0
fi
if [ "$1" = "run" ] && [ -n "$2" ]; then : > "$2"; fi
exit 0
STUB
  chmod +x "$bin/codex"
  PATH="$bin:$PATH"; export PATH
}

_stub_codex_never_succeeds() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/codex"
  chmod +x "$bin/codex"
  PATH="$bin:$PATH"; export PATH
}

# The one status.json this test's TEST_HOME should hold — each test gets a
# fresh $HOME, so there is exactly one burn-* run directory per test.
_the_status_file() {
  local f
  f="$(ls "$CLIKAE_HOME"/logs/burn-*/status.json 2>/dev/null | head -n 1)"
  [ -n "$f" ] || { echo "no status.json under \$CLIKAE_HOME/logs/burn-*/" >&2; return 1; }
  printf '%s' "$f"
}

_field() {
  # tiny helper: extract "field":value (quoted or bare) from a status.json
  grep -oE "\"$2\":(\"[^\"]*\"|null|true|false|-?[0-9]+|\[[^]]*\])" "$1" | head -n1 | sed -E "s/^\"$2\"://"
}

@test "burn-status: a completed burn's status file ends in state done with every contract field" {
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  [ "$status" -eq 0 ]

  local f; f="$(_the_status_file)"
  [ -f "$f" ] || false

  [ "$(_field "$f" state)" = '"done"' ] || false
  [ "$(_field "$f" ok)" = "true" ] || false
  [ "$(_field "$f" engine)" = '"codex"' ] || false
  [ "$(_field "$f" tank)" = '"T1"' ] || false
  [ "$(_field "$f" artifact)" = "\"$A\"" ] || false
  [ "$(_field "$f" pid)" != "" ] || false
  [ "$(_field "$f" run_id)" != "null" ] || false
  [ "$(_field "$f" started_at)" != "null" ] || false
  [ "$(_field "$f" updated_at)" != "null" ] || false
  [ "$(_field "$f" rerouted_from)" = "[]" ] || false
  # a completed run's own log file is a real, readable file
  local logp; logp="$(_field "$f" log)"
  logp="${logp#\"}"; logp="${logp%\"}"
  [ -f "$logp" ] || false
}

@test "burn-status: the run directory is private (0700) like the task-text copy it lives beside" {
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  [ "$status" -eq 0 ]
  local f; f="$(_the_status_file)"
  local d; d="$(dirname "$f")"
  # `stat`'s -f/-c flags mean DIFFERENT things on BSD vs GNU stat (and this
  # machine's PATH can put either first — see hub-env), so ask perl instead of
  # guessing which dialect answered.
  local perms; perms="$(perl -e 'printf "%o\n", (stat(shift))[2] & 07777' "$d")"
  [ "$perms" = "700" ] || false
}

@test "burn-status: a real task failure ends in state fail, not dry" {
  _stub_codex_never_succeeds
  clikae init codex T1
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" -- noop
  [ "$status" -ne 0 ]
  local f; f="$(_the_status_file)"
  [ "$(_field "$f" state)" = '"fail"' ] || false
  [ "$(_field "$f" ok)" = "false" ] || false
}

@test "burn-status: rerouting from a dry tank records rerouted_from and lands on state done" {
  _stub_codex
  clikae init codex T1
  clikae init codex T2
  : > "$CLIKAE_HOME/profiles/codex/T1/.dry"
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  [ "$status" -eq 0 ]

  local f; f="$(_the_status_file)"
  [ "$(_field "$f" state)" = '"done"' ] || false
  [ "$(_field "$f" tank)" = '"T2"' ] || false
  [[ "$(_field "$f" rerouted_from)" == *"codex/T1"* ]] || false
}

@test "burn-status: every burn writes a status file even without --json" {
  # #41 is "every burn", not "every --json burn" — the whole point is that a
  # cockpit reading a DIFFERENT process never needs the burn to have opted in.
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  [ "$status" -eq 0 ]
  [[ "$output" != *'"ok":'* ]] || false   # confirms --json's own stdout object was NOT requested
  local f; f="$(_the_status_file)"
  [ -f "$f" ] || false
}
