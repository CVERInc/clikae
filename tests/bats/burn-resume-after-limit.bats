#!/usr/bin/env bats
# tests/bats/burn-resume-after-limit.bats — #36: `--resume-after-limit` — a dry
# tank with a parseable reset is waited out in-process, then the SAME task is
# relaunched on the SAME tank from the SAME cwd with a resume note prepended.
#
# `sleep` is stubbed to a no-op that logs its argument (and snapshots what a
# reader would see mid-wait), so no wall-clock time passes. The stub engine
# records its cwd and its prompt (the last argv item) per call.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'
bats_require_minimum_version 1.5.0

# _stub_codex <dry_calls> -> codex goes dry for the first <dry_calls> calls,
# then writes $ART. Every call appends "<n>\t<cwd>" to calls.tsv and its last
# argument (the prompt) to prompt.<n>.
_stub_codex() {
  local bin="$BATS_TEST_TMPDIR/bin" dry="$1"
  mkdir -p "$bin"
  ART="$BATS_TEST_TMPDIR/work/out.md"
  mkdir -p "$BATS_TEST_TMPDIR/work"
  cat > "$bin/codex" <<STUB
#!/usr/bin/env bash
c="$BATS_TEST_TMPDIR/calls.tsv"
n=\$(( \$( [ -f "\$c" ] && wc -l < "\$c" || echo 0) + 1 ))
printf '%s\t%s\n' "\$n" "\$PWD" >> "\$c"
printf '%s' "\${@: -1}" > "$BATS_TEST_TMPDIR/prompt.\$n"
if [ "\$n" -le $dry ]; then
  echo "You've hit your usage limit. resets 11:59pm (UTC)"
  exit 0
fi
echo done > "$ART"
exit 0
STUB
  chmod +x "$bin/codex"
  cat > "$bin/sleep" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/sleep.log"
for s in "\$HOME"/.clikae/logs/burn-*/status.json; do
  [ -f "\$s" ] && cat "\$s" >> "$BATS_TEST_TMPDIR/during.json"
done
bash -c '. "$CLIKAE_TEST_ROOT/lib/core/json.sh"; . "$CLIKAE_TEST_ROOT/lib/core/burn_status.sh"; burn_status_waiting_rows' \
  >> "$BATS_TEST_TMPDIR/waiting.tsv" 2>/dev/null || true
exit 0
STUB
  chmod +x "$bin/sleep"
  PATH="$bin:$PATH"; export PATH
}

_calls() { wc -l < "$BATS_TEST_TMPDIR/calls.tsv" | tr -d ' '; }

@test "resume: dry once -> waits, relaunches the same tank from the same cwd with a resume note" {
  _stub_codex 1
  clikae init codex T1
  clikae init codex T2   # reserve tank that must never be touched while waiting
  cd "$BATS_TEST_TMPDIR/work"
  run clikae burn codex T1 --artifact "$ART" --prompt "write the report" \
      --add-dir "$BATS_TEST_TMPDIR/work" --codex-skip-git-check --resume-after-limit
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$ART" ] || false
  [ "$(_calls)" -eq 2 ] || false
  # same cwd on both launches
  [ "$(cut -f2 "$BATS_TEST_TMPDIR/calls.tsv" | sort -u | wc -l | tr -d ' ')" -eq 1 ] || false
  # first prompt is the task verbatim; the relaunch carries the note, then the task once
  [ "$(cat "$BATS_TEST_TMPDIR/prompt.1")" = "write the report" ] || false
  [[ "$(cat "$BATS_TEST_TMPDIR/prompt.2")" == "RESUME NOTE: previous attempt killed by quota limit at "*"this is attempt 2;"*"write the report" ]] || false
  [ "$(grep -c 'write the report' "$BATS_TEST_TMPDIR/prompt.2")" -eq 1 ] || false
  # never rerouted while waiting
  [[ "$output" != *"Rerouting"* ]] || false
  [[ "$output" != *"codex/T2"* ]] || false
  [[ "$output" == *"[ RESUME ]"* ]] || false
  # it actually waited, and a reader mid-wait saw a NON-terminal state
  [ -s "$BATS_TEST_TMPDIR/sleep.log" ] || false
  grep -q '"state":"waiting-reset"' "$BATS_TEST_TMPDIR/during.json" || false
  ! grep -q '"state":"dry"' "$BATS_TEST_TMPDIR/during.json" || false
  # the [ RESUME ] lines are in the burn log too
  grep -q '\[ RESUME \]' "$HOME"/.clikae/logs/codex-T1-burn-*.log || false
}

@test "resume: the state file carries tank, engine, cwd, argv, artifact, prompt file, reset, attempt" {
  _stub_codex 1
  clikae init codex T1
  printf 'task from file' > "$BATS_TEST_TMPDIR/task.txt"
  cd "$BATS_TEST_TMPDIR/work"
  run clikae burn codex T1 --artifact "$ART" --prompt-file "$BATS_TEST_TMPDIR/task.txt" \
      --add-dir "$BATS_TEST_TMPDIR/work" --codex-skip-git-check --resume-after-limit
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local f; f="$(ls "$HOME"/.clikae/state/burn-*.resume)"
  [ -f "$f" ] || false
  local j; j="$(cat "$f")"
  [[ "$j" == *'"engine":"codex"'* ]] || false
  [[ "$j" == *'"tank":"T1"'* ]] || false
  [[ "$j" == *"\"cwd\":\"$BATS_TEST_TMPDIR/work\""* ]] || false
  [[ "$j" == *'"argv":["codex","T1","--artifact",'*'"--resume-after-limit"]'* ]] || false
  [[ "$j" == *"\"artifact\":\"$ART\""* ]] || false
  [[ "$j" == *"\"prompt_file\":\"$BATS_TEST_TMPDIR/task.txt\""* ]] || false
  [[ "$j" == *'"reset":"'*'11:59pm'* ]] || false
  [[ "$j" =~ \"reset_at\":[0-9]+ ]] || false
  [[ "$j" == *'"attempt":1,"max_attempts":3'* ]] || false
}

@test "resume: attempts are capped at 3, then today's dry path; --json carries resumed" {
  _stub_codex 99
  clikae init codex T1
  cd "$BATS_TEST_TMPDIR/work"
  run --separate-stderr clikae burn codex T1 --artifact "$ART" --prompt "t" \
      --add-dir "$BATS_TEST_TMPDIR/work" --codex-skip-git-check --resume-after-limit --json
  # shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`
  [ "$status" -eq 2 ] || { echo "$output $stderr"; false; }
  [ "$(_calls)" -eq 4 ] || false          # first launch + 3 resumes
  [[ "$output" == *'"resumed":3'* ]] || false
  [[ "$output" == *'"ok":false'* ]] || false
  [[ "$stderr" == *"resume cap reached (3)"* ]] || false
  [[ "$(cat "$BATS_TEST_TMPDIR/prompt.4")" == *"this is attempt 4;"* ]] || false
}

@test "resume: --json reports resumed:1 on a dry-once success" {
  _stub_codex 1
  clikae init codex T1
  cd "$BATS_TEST_TMPDIR/work"
  run --separate-stderr clikae burn codex T1 --artifact "$ART" --prompt "t" \
      --add-dir "$BATS_TEST_TMPDIR/work" --codex-skip-git-check --resume-after-limit --json
  # shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  [[ "$output" == *'"ok":true'* ]] || false
  [[ "$output" == *'"resumed":1'* ]] || false
}

@test "resume: a waiting burn is listed with its reset instant for the board" {
  _stub_codex 1
  clikae init codex T1
  cd "$BATS_TEST_TMPDIR/work"
  run clikae burn codex T1 --artifact "$ART" --prompt "t" \
      --add-dir "$BATS_TEST_TMPDIR/work" --codex-skip-git-check --resume-after-limit
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Eq '^codex/T1	[0-9]+$' "$BATS_TEST_TMPDIR/waiting.tsv" || { cat "$BATS_TEST_TMPDIR/waiting.tsv"; false; }
}

@test "home: _home_burn_waiting_notes renders 'resumes at HH:MM'" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/i18n/en-US.sh"
  . "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  burn_status_waiting_rows() { printf 'codex/T1\t%s\n' "$(date -j -f '%Y-%m-%d %H:%M' '2026-01-02 19:32' +%s 2>/dev/null || date -d '2026-01-02 19:32' +%s)"; }
  __C_DIM="" __C_RESET=""
  run _home_burn_waiting_notes
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting: codex/T1 burn resumes at 19:32"* ]] || { echo "$output"; false; }
}

@test "resume: an explicit --to still wins over waiting" {
  _stub_codex 1
  clikae init codex T1
  clikae init codex T2
  cd "$BATS_TEST_TMPDIR/work"
  run clikae burn codex T1 --artifact "$ART" --prompt "t" --to T2 \
      --add-dir "$BATS_TEST_TMPDIR/work" --codex-skip-git-check --resume-after-limit
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"codex/T2"* ]] || false
  ! grep -q '"state":"waiting-reset"' "$BATS_TEST_TMPDIR/during.json" 2>/dev/null || false
  [[ "$output" != *"[ RESUME ]"* ]] || false
}

@test "control: without --resume-after-limit, a dry tank reroutes exactly as before" {
  _stub_codex 1
  clikae init codex T1
  clikae init codex T2
  cd "$BATS_TEST_TMPDIR/work"
  run --separate-stderr clikae burn codex T1 --artifact "$ART" --prompt "t" \
      --add-dir "$BATS_TEST_TMPDIR/work" --codex-skip-git-check --json
  # shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  [[ "$stderr" == *"codex/T2"* ]] || false
  [[ "$stderr" != *"[ RESUME ]"* ]] || false
  ! grep -q '"state":"waiting-reset"' "$BATS_TEST_TMPDIR/during.json" 2>/dev/null || false
  [ "$(cat "$BATS_TEST_TMPDIR/prompt.2")" = "t" ] || false   # no note on the reroute
  [[ "$output" == *'"resumed":0'* ]] || false
  ! ls "$HOME"/.clikae/state/burn-*.resume >/dev/null 2>&1 || false
}
