#!/usr/bin/env bats
load '../helpers'

@test "the claude permissions template is valid, shaped JSON with no exact-duplicate rules" {
  # `init` only tolerates rc 2 (no template) / rc 3 (no jq) from `settings
  # apply`; any other failure -- including a template that fails cmd_settings'
  # own shape check -- surfaces as a half-created tank (P76 R2 P3-B). This
  # guards the one trigger for that left standing once P2-1 was removed.
  local f="$CLIKAE_ROOT/templates/permissions/claude.json"
  jq -e 'type == "object" and (.permissions.allow | type == "array" and all(.[]; type == "string")) and (.permissions.deny | type == "array" and all(.[]; type == "string"))' "$f"
  jq -e '.permissions.allow | length == (unique | length)' "$f"
  jq -e '.permissions.deny | length == (unique | length)' "$f"
}

@test "settings unions both lists and preserves other keys and backup" {
  local d="$CLIKAE_HOME/profiles/claude/work"
  mkdir -p "$d"
  # #61 round-2 P2-3: naming a tank now requires the marker (no more seeding
  # a fingerprint by writing settings.json) — stamp it directly, same as a
  # real `clikae init` would have.
  printf 'claude\n' > "$d/.clikae-tank"
  printf '%s\n' '{"permissions":{"allow":["Bash(custom *)"],"deny":["Bash(secret *)"],"defaultMode":"acceptEdits"},"env":{"X":"keep"},"hooks":{}}' > "$d/settings.json"
  cp "$d/settings.json" "$TEST_HOME/before"
  run clikae settings apply claude work
  [ "$status" -eq 0 ]
  jq -e '.permissions.allow[0] == "Bash(custom *)" and .permissions.deny[0] == "Bash(secret *)" and .permissions.defaultMode == "acceptEdits" and .env.X == "keep" and .hooks == {} and (.permissions.deny | index("Bash(sudo *)") != null)' "$d/settings.json"
  cmp "$TEST_HOME/before" "$d"/settings.json.clikae.bak.*
}

@test "second apply is a byte-identical no-op" {
  clikae init claude work
  local f="$CLIKAE_HOME/profiles/claude/work/settings.json"
  cp "$f" "$TEST_HOME/before"
  run clikae settings apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude/work: unchanged"* ]] || false
  cmp "$f" "$TEST_HOME/before"
}

@test "check detects hand-edited drift and goes green after apply" {
  clikae init claude work
  local f="$CLIKAE_HOME/profiles/claude/work/settings.json"
  jq 'del(.permissions.deny[0])' "$f" > "$TEST_HOME/edited"
  cp "$TEST_HOME/edited" "$f"
  run clikae settings apply --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude/work: permissions drift"* ]] || false
  cmp "$f" "$TEST_HOME/edited"
  clikae settings apply
  run clikae settings apply --check
  [ "$status" -eq 0 ]
}

@test "init creates settings that pass check" {
  clikae init claude fresh
  run clikae settings apply claude fresh --check
  [ "$status" -eq 0 ]
}

@test "invalid JSON is skipped while other tanks are applied" {
  mkdir -p "$CLIKAE_HOME/profiles/claude/bad" "$CLIKAE_HOME/profiles/claude/good"
  # #61 round-1 P1-3: "good" has no settings.json/.claude.json of its own yet
  # (that's the whole point of this test — apply must CREATE one), so it has
  # no fingerprint to be adopted by; stamp it directly, same as a real
  # `clikae init` would have.
  printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/good/.clikae-tank"
  # #61 round-2 P2-3: "bad"'s only fingerprint used to be the very
  # settings.json this test writes below — that no longer seeds a tank, so
  # stamp its marker directly too (same as "good" above), or apply would
  # never enumerate "bad" at all and this test would stop touching it.
  printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/bad/.clikae-tank"
  local f="$CLIKAE_HOME/profiles/claude/bad/settings.json"
  printf '{broken' > "$f"
  cp "$f" "$TEST_HOME/before"
  run clikae settings apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude/bad: skipped"*"invalid JSON"* ]] || false
  cmp "$f" "$TEST_HOME/before"
  [ -f "$CLIKAE_HOME/profiles/claude/good/settings.json" ]
}

@test "dry-run previews all tanks without creating settings" {
  mkdir -p "$CLIKAE_HOME/profiles/claude/a" "$CLIKAE_HOME/profiles/claude/b"
  # #61 round-1 P1-3: --dry-run creates no settings.json by design, so these
  # have no fingerprint of their own — stamp the marker directly, same as a
  # real `clikae init` would have.
  printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/a/.clikae-tank"
  printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/b/.clikae-tank"
  run clikae settings apply --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude/a: +"*"claude/b: +"* ]] || false
  # #61 round-2 P3: was narrowed to two `[ ! -e … /settings.json ]` checks —
  # equivalent for THESE two fixtures, but weaker in general: it would stay
  # green even if --dry-run started writing some OTHER file. Assert the full
  # claim ("dry-run creates no files at all") again, just excluding the
  # `.clikae-tank` markers this fixture itself stamped above.
  [ "$(find "$CLIKAE_HOME/profiles" -type f ! -name .clikae-tank | wc -l | tr -d ' ')" -eq 0 ]
}

@test "settings rejects malformed shapes and empty files unchanged" {
  local d="$CLIKAE_HOME/profiles/claude/work" value
  mkdir -p "$d"
  # #61 round-2 P2-3: without a marker, named apply would now refuse for a
  # DIFFERENT reason ("not a tank") before ever reaching the malformed-JSON
  # check this test exists to exercise — stamp it so the assertion stays
  # honest about what it is testing.
  printf 'claude\n' > "$d/.clikae-tank"
  for value in '' 'null' '[]' '{"permissions":{"allow":"oops"}}' '{} {}'; do
    printf '%s' "$value" > "$d/settings.json"
    cp "$d/settings.json" "$TEST_HOME/before"
    run clikae settings apply claude work
    [ "$status" -ne 0 ]
    cmp "$d/settings.json" "$TEST_HOME/before"
  done
}

@test "settings rejects unsupported engines missing tanks and conflicting flags" {
  run clikae settings apply codex
  [ "$status" -eq 2 ]
  [[ "$output" == *"No permissions template for engine: codex"* ]] || false
  run clikae settings apply claude absent
  [ "$status" -ne 0 ]
  [[ "$output" == *"Tank does not exist: claude/absent"* ]] || false
  run clikae settings apply --check --dry-run
  [ "$status" -ne 0 ]
}

@test "settings apply without jq fails clearly and does not write" {
  local nojq="$BATS_TEST_TMPDIR/nojq"
  path_without_jq "$nojq"
  PATH="$nojq" command -v jq >/dev/null 2>&1 && skip "jq is on PATH even without /usr/bin and /bin"
  clikae init claude work
  local f="$CLIKAE_HOME/profiles/claude/work/settings.json"
  cp "$f" "$TEST_HOME/before"
  run env PATH="$nojq" "$CLIKAE_BIN" settings apply claude work
  [ "$status" -eq 3 ]
  [[ "$output" == *"requires jq"* ]] || false
  cmp "$f" "$TEST_HOME/before"
}

@test "an allow rule that matches a deny rule by the same string is applied, not refused" {
  # Claude evaluates deny before allow, so an identical string in both lists
  # is not a bypass: deny still wins. Refusing to write it here bought
  # nothing and left the tank worse off in the one case it fired on for real
  # (a tank that had already allowed Bash(sudo *) kept sudo allowed and
  # unopposed, instead of picking up the template's matching deny rule).
  local d="$CLIKAE_HOME/profiles/claude/work"
  mkdir -p "$d"
  # #61 round-2 P2-3: naming a tank now requires the marker — stamp it
  # directly, same as a real `clikae init` would have.
  printf 'claude\n' > "$d/.clikae-tank"
  printf '%s\n' '{"permissions":{"allow":["Bash(sudo *)"]}}' > "$d/settings.json"
  run clikae settings apply claude work
  [ "$status" -eq 0 ]
  jq -e '.permissions.allow | index("Bash(sudo *)") != null' "$d/settings.json"
  jq -e '.permissions.deny | index("Bash(sudo *)") != null' "$d/settings.json"
}

@test "settings apply with no tanks of the engine says so and exits 0" {
  run clikae settings apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"No claude tanks found."* ]] || false
}

# --- #61 round-1 P2-6 ("ONE ENUMERATOR, REALLY"): settings.sh:131's own
# `for d in profiles_root/$engine/*` (no trailing slash on the glob, so it
# did not even need `[ -d ]` to fail) was the ONE walker in the whole audit
# that WRITES into whatever it finds — a directory-shaped `hello.lock/`
# sitting next to real tanks got settings.json written straight into it.
@test "settings apply with a hello.lock/ dir and a zzempty/ dir present writes nothing into them" {
  clikae init claude real
  mkdir -p "$CLIKAE_HOME/profiles/claude/hello.lock" "$CLIKAE_HOME/profiles/claude/zzempty"
  run clikae settings apply
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"claude/real:"* ]] || { echo "$output"; false; }
  [[ "$output" != *"hello.lock"* ]] || { echo "prose mentioned hello.lock: $output"; false; }
  [[ "$output" != *"zzempty"* ]] || { echo "prose mentioned zzempty: $output"; false; }
  [ ! -e "$CLIKAE_HOME/profiles/claude/hello.lock/settings.json" ]
  [ ! -e "$CLIKAE_HOME/profiles/claude/zzempty/settings.json" ]
}

@test "doctor permissions helper reports each drifted tank and stays read-only" {
  local d="$CLIKAE_HOME/profiles/claude/work"
  mkdir -p "$d"
  run bash -c 'source "$CLIKAE_LIB/core/profile_store.sh"; source "$CLIKAE_LIB/commands/settings.sh"; _settings_tank claude work doctor "$CLIKAE_ROOT/templates/permissions/claude.json"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude/work: permissions drift"* ]] || false
  [ ! -e "$d/settings.json" ]
}

@test "targeted apply leaves other tanks alone and expands \$HOME" {
  mkdir -p "$CLIKAE_HOME/profiles/claude/a" "$CLIKAE_HOME/profiles/claude/b"
  # #61 round-2 P2-3: naming "a" now requires the marker — stamp it directly,
  # same as a real `clikae init` would have. "b" is never named, so it needs
  # none (the assertion below is that apply never touches it).
  printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/a/.clikae-tank"
  clikae settings apply claude a
  [ ! -e "$CLIKAE_HOME/profiles/claude/b/settings.json" ]
  jq -e --arg rule "Bash($HOME/*)" '.permissions.allow | index($rule) != null' "$CLIKAE_HOME/profiles/claude/a/settings.json"
}

@test "\$HOME/* expands the same whether or not the caller's HOME has a trailing slash" {
  mkdir -p "$CLIKAE_HOME/profiles/claude/a"
  # #61 round-2 P2-3: naming "a" now requires the marker — stamp it directly,
  # same as a real `clikae init` would have.
  printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/a/.clikae-tank"
  clikae settings apply claude a
  run env HOME="$HOME/" "$CLIKAE_BIN" settings apply claude a --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude/a: unchanged"* ]] || false
}

@test "a colon-spelled allow rule is recognized as equivalent to the template's space-spelled rule" {
  local d="$CLIKAE_HOME/profiles/claude/work"
  mkdir -p "$d"
  # #61 round-2 P2-3: naming a tank now requires the marker — stamp it
  # directly, same as a real `clikae init` would have.
  printf 'claude\n' > "$d/.clikae-tank"
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' > "$d/settings.json"
  run clikae settings apply claude work
  [ "$status" -eq 0 ]
  jq -e '[.permissions.allow[] | select(. == "Bash(ls *)" or . == "Bash(ls:*)")] | length == 1' "$d/settings.json"
}

@test "symlinked settings are skipped without changing the target" {
  mkdir -p "$CLIKAE_HOME/profiles/claude/work"
  # #61 round-2 P2-3: this tank's only "fingerprint" is the deliberately
  # SYMLINKED settings.json below, which no longer counts — without a real
  # marker, unnamed `settings apply` would enumerate zero claude tanks and
  # never even reach the symlink this test exists to exercise.
  printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/work/.clikae-tank"
  printf '{}\n' > "$TEST_HOME/target"
  cp "$TEST_HOME/target" "$TEST_HOME/before"
  ln -s "$TEST_HOME/target" "$CLIKAE_HOME/profiles/claude/work/settings.json"
  run clikae settings apply
  [ "$status" -ne 0 ]
  cmp "$TEST_HOME/target" "$TEST_HOME/before"
  [ -L "$CLIKAE_HOME/profiles/claude/work/settings.json" ]
}

@test "failed rename preserves the live file and cleans the temporary file" {
  local d="$CLIKAE_HOME/profiles/claude/work"
  mkdir -p "$d"
  # #61 round-2 P2-3: without a marker, unnamed `settings apply` would
  # enumerate zero claude tanks and never reach this fixture's settings.json.
  printf 'claude\n' > "$d/.clikae-tank"
  printf '{}\n' > "$d/settings.json"
  cp "$d/settings.json" "$TEST_HOME/before"
  printf '#!/bin/sh\nexit 1\n' > "$TEST_HOME/.testbin/mv"
  chmod +x "$TEST_HOME/.testbin/mv"
  run clikae settings apply
  [ "$status" -ne 0 ]
  cmp "$d/settings.json" "$TEST_HOME/before"
  [ "$(find "$d" -name '*.tmp.*' | wc -l | tr -d ' ')" -eq 0 ]
}
