#!/usr/bin/env bats
# tests/bats/conduct.bats — `clikae conduct` (BETA): fan ONE prompt across N
# accounts in PARALLEL, collect each leg's full output, tabulate captured/dry.
# clikae never judges. Uses stubbed `codex`/`claude`/`gh` binaries; no real engine.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

# Stub `codex`: a ".dry" marker in $CODEX_HOME → emit the limit line (exit 0, the
# headless-exits-0-on-limit trap); otherwise echo a deterministic result so the
# parent can see "captured".
_stub_codex() {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  cat > "$bin/codex" <<'STUB'
#!/usr/bin/env bash
if [ -f "$CODEX_HOME/.dry" ]; then
  echo "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
  exit 0
fi
if [ -f "$CODEX_HOME/.fail" ]; then exit 3; fi    # a real failure: NON-ZERO, no output
echo "AUDIT from codex @ $CODEX_HOME"
exit 0
STUB
  chmod +x "$bin/codex"; PATH="$bin:$PATH"; export PATH
}

# Stub `claude`: echo a deterministic read-only result.
_stub_claude() {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  cat > "$bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "AUDIT from claude @ $CLAUDE_CONFIG_DIR"
exit 0
STUB
  chmod +x "$bin/claude"; PATH="$bin:$PATH"; export PATH
}

_stub_gh() {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/gh"; chmod +x "$bin/gh"
  PATH="$bin:$PATH"; export PATH
}

@test "conduct fans across two codex tanks; both captured; exit 0" {
  _stub_codex
  clikae init codex A
  clikae init codex B
  local D="$BATS_TEST_TMPDIR/out"
  run clikae conduct --prompt "audit this" --leg codex/A --leg codex/B --out-dir "$D"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 captured"* ]] || false
  [ -s "$D/codex-A.txt" ]
  [ -s "$D/codex-B.txt" ]
  grep -q "AUDIT from codex" "$D/codex-A.txt"
}

@test "conduct: a dry leg is shown as dry, a live leg still captures (exit 0)" {
  _stub_codex
  clikae init codex A
  clikae init codex B
  : > "$CLIKAE_HOME/profiles/codex/A/.dry"        # A is dry; B is live
  local D="$BATS_TEST_TMPDIR/out"
  run clikae conduct --prompt "x" --leg codex/A --leg codex/B --out-dir "$D"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex/A — ran dry"* ]] || false
  [[ "$output" == *"codex/B — captured"* ]] || false
  [[ "$output" == *"1 captured · 1 dry"* ]] || false
}

@test "conduct: every leg dry → non-zero (nothing captured)" {
  _stub_codex
  clikae init codex A
  clikae init codex B
  : > "$CLIKAE_HOME/profiles/codex/A/.dry"
  : > "$CLIKAE_HOME/profiles/codex/B/.dry"
  run clikae conduct --prompt "x" --leg codex/A --leg codex/B --out-dir "$BATS_TEST_TMPDIR/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"0 captured · 2 dry"* ]] || false
}

@test "conduct fans CROSS-ENGINE (codex + claude), both captured" {
  _stub_codex
  _stub_claude
  clikae init codex A
  clikae init claude C
  local D="$BATS_TEST_TMPDIR/out"
  run clikae conduct --prompt "x" --leg codex/A --leg claude/C --out-dir "$D"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 captured"* ]] || false
  grep -q "AUDIT from claude" "$D/claude-C.txt"
}

@test "conduct: a leg whose engine has no read-only recipe is flagged NORECIPE" {
  _stub_codex
  _stub_gh
  clikae init codex A
  clikae init gh G
  run clikae conduct --prompt "x" --leg codex/A --leg gh/G --out-dir "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]                                  # codex still captured
  [[ "$output" == *"no read-only recipe"* ]] || false
}

@test "conduct: a leg whose engine exits NON-ZERO with no output is EMPTY, not 'unknown'" {
  # Locks the #2 audit fix: under set -e (inherited by the background subshell) the
  # out="$(…)" assignment must not abort before the .status file is written.
  _stub_codex
  clikae init codex A
  clikae init codex B
  : > "$CLIKAE_HOME/profiles/codex/B/.fail"          # B fails hard (exit 3, no output)
  local D="$BATS_TEST_TMPDIR/out"
  run clikae conduct --prompt "x" --leg codex/A --leg codex/B --out-dir "$D"
  [ "$status" -eq 0 ]                                 # A still captured
  [[ "$output" == *"codex/B — no output"* ]] || false # classified EMPTY, not unknown
  [[ "$output" != *"unknown outcome"* ]] || false
  [ "$(head -1 "$D/codex-B.status")" = "EMPTY" ]      # the .status file WAS written
}

@test "conduct: an unknown tank is flagged, not crashed" {
  _stub_codex
  clikae init codex A
  run clikae conduct --prompt "x" --leg codex/A --leg codex/NOPE --out-dir "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex/NOPE — no such tank"* ]] || false
}

# --- 2026-06-16 adversarial: leg names were NEVER validated, so the per-leg slug
# (engine-tank) could carry `/` or `..` and make the result/status file escape the
# out-dir (and two legs could collide onto one slug, overwriting each other). ---

@test "conduct: a path-traversal leg is SKIPPED — no file escapes the out-dir" {
  _stub_codex
  clikae init codex A
  local D="$BATS_TEST_TMPDIR/out"
  # Sentinel one level above the out-dir; the traversal leg's status file would
  # have resolved to here ($D/../codex-..-..-x.status style) before the guard.
  local up="$BATS_TEST_TMPDIR/UP_MUST_STAY_EMPTY"; mkdir -p "$up"
  run clikae conduct --prompt "x" --leg codex/A --leg "codex/../../UP_MUST_STAY_EMPTY/pwn" --out-dir "$D"
  [ "$status" -eq 0 ]                                   # the good leg still ran
  [[ "$output" == *"skipping --leg"* ]] || false        # the bad leg was rejected
  [[ "$output" == *"codex/A — captured"* ]] || false
  # Nothing was written outside the out-dir.
  [ -z "$(ls -A "$up")" ] || false
}

@test "conduct: a leg with a slash in the tank is skipped, not parsed as a subdir" {
  _stub_codex
  clikae init codex A
  local D="$BATS_TEST_TMPDIR/out"
  run clikae conduct --prompt "x" --leg codex/A --leg "codex/a/b" --out-dir "$D"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping --leg 'codex/a/b'"* ]] || false
  [ ! -e "$D/codex-a" ]                                 # no stray subdir created
}

# --- honest-limits disclosure in --help (philosophy → docs; no phantom promises) ---
@test "conduct --help discloses the read-only, no-judge, adapter-gated, dry limits" {
  run clikae conduct --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Read-only by design"* ]] || false        # legs can't clobber
  [[ "$output" == *"clikae never judges"* ]] || false        # you pick the winner
  [[ "$output" == *"adapter_audit_flags"* ]] || false        # adapter-hook gated
  [[ "$output" == *"CLIKAE_LIMIT_PATTERN"* ]] || false        # dry-wording override
  # captured vs failed must be visible (the table's vocabulary)
  [[ "$output" == *"captured"* ]] || false
  [[ "$output" == *"empty (a real failure"* ]] || false
}

@test "conduct requires a prompt" {
  run clikae conduct --leg codex/A
  [ "$status" -ne 0 ]
  [[ "$output" == *"prompt"* ]] || false
}

@test "conduct requires at least one leg" {
  run clikae conduct --prompt "x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--leg"* ]] || false
}

@test "conduct rejects --prompt and --prompt-file together" {
  printf 'x\n' > "$BATS_TEST_TMPDIR/p.txt"
  run clikae conduct --prompt x --prompt-file "$BATS_TEST_TMPDIR/p.txt" --leg codex/A
  [ "$status" -ne 0 ]
  [[ "$output" == *"not both"* ]] || false
}

@test "conduct --prompt-file reads the prompt from a file" {
  _stub_codex
  clikae init codex A
  printf 'audit from a file\n' > "$BATS_TEST_TMPDIR/p.txt"
  local D="$BATS_TEST_TMPDIR/out"
  run clikae conduct --prompt-file "$BATS_TEST_TMPDIR/p.txt" --leg codex/A --out-dir "$D"
  [ "$status" -eq 0 ]
  [ -s "$D/codex-A.txt" ]
}

# Direct unit tests pinning the read-only recipes (a flag rename is caught here).
@test "adapter_audit_flags (codex): NUL read-only recipe, first dir = cwd" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/codex.sh"
  local -a got=(); local x
  while IFS= read -r -d '' x; do got+=("$x"); done < <(adapter_audit_flags "do it" /tmp/wd)
  [ "${#got[@]}" -eq 7 ]
  [ "${got[0]}" = "exec" ]
  [ "${got[1]}" = "--skip-git-repo-check" ]
  [ "${got[2]}" = "-C" ]
  [ "${got[3]}" = "/tmp/wd" ]
  [ "${got[4]}" = "-s" ]
  [ "${got[5]}" = "read-only" ]
  [ "${got[6]}" = "do it" ]
}

@test "adapter_audit_flags (claude): headless -p with no write permission" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local -a got=(); local x
  while IFS= read -r -d '' x; do got+=("$x"); done < <(adapter_audit_flags "do it" /tmp/wd)
  [ "${got[0]}" = "-p" ]
  [ "${got[1]}" = "do it" ]
  printf '%s\n' "${got[@]}" | grep -q "dangerously-skip-permissions" && false   # read-only: NO write grant
  return 0
}

@test "adapter_audit_flags: a MULTI-LINE prompt stays ONE argv item (the audit blind spot)" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/codex.sh"
  local ml; ml=$'analyze this:\n- point a\n- point b'
  local -a got=(); local x
  while IFS= read -r -d '' x; do got+=("$x"); done < <(adapter_audit_flags "$ml" /tmp/wd)
  [ "${#got[@]}" -eq 7 ]       # NOT split by the prompt's newlines
  [ "${got[6]}" = "$ml" ]      # whole multi-line prompt intact as the last arg
}
