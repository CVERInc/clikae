#!/usr/bin/env bats
# tests/bats/burn.bats — `clikae burn`: run a headless task on a tank, verify by
# ARTIFACT (not exit code — codex exec exits 0 even when limited), and fall through
# to the next tank when one runs dry. Uses a stubbed `codex` binary; no real codex.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

# Stub `codex` on PATH. Per-tank behaviour keyed off $CODEX_HOME:
#   a ".dry" marker in the tank dir  -> emit the limit line, write nothing (exit 0)
#   `run <path>`                     -> create <path> (the legacy raw-argv form)
#   `exec …` (the generated form)    -> create $STUB_ARTIFACT, if set
#   otherwise                        -> do nothing (a task that fails to produce)
# If $STUB_ARGV_LOG is set, every invocation appends its full argv (one line) there
# so a test can assert the generated flag shape.
_stub_codex() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/codex" <<'STUB'
#!/usr/bin/env bash
[ -n "$STUB_ARGV_LOG" ] && printf '%s\n' "$*" >> "$STUB_ARGV_LOG"
[ -n "$STUB_ARGC_LOG" ] && printf '%s' "$#" > "$STUB_ARGC_LOG"
if [ -f "$CODEX_HOME/.dry" ]; then
  echo "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
  exit 0
fi
if [ "$1" = "run" ] && [ -n "$2" ]; then : > "$2"; fi
if [ "$1" = "exec" ] && [ -n "$STUB_ARTIFACT" ]; then : > "$STUB_ARTIFACT"; fi
exit 0
STUB
  chmod +x "$bin/codex"
  PATH="$bin:$PATH"; export PATH
}

# A stub `gh` (a real adapter that does NOT define adapter_burn_flags) for the
# "no headless-write recipe" error path.
_stub_gh() {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/gh"; chmod +x "$bin/gh"
  PATH="$bin:$PATH"; export PATH
}

@test "burn completes on a live tank and verifies by the artifact" {
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  [ "$status" -eq 0 ]
  [ -f "$A" ]
  [[ "$output" == *"Done on codex/T1"* ]] || false
}

@test "burn reroutes from a dry tank to the next same-engine tank" {
  _stub_codex
  clikae init codex T1
  clikae init codex T2
  : > "$CLIKAE_HOME/profiles/codex/T1/.dry"     # T1 is dry; T2 is live
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  [ "$status" -eq 0 ]
  [ -f "$A" ]
  [[ "$output" == *"ran dry"* ]] || false
  [[ "$output" == *"codex/T2"* ]] || false
}

@test "burn honours an explicit --to next hop on a dry tank" {
  _stub_codex
  clikae init codex T1
  clikae init codex H
  : > "$CLIKAE_HOME/profiles/codex/T1/.dry"
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" --to codex/H -- run "$A"
  [ "$status" -eq 0 ]
  [ -f "$A" ]
  [[ "$output" == *"codex/H"* ]] || false
}

@test "burn fails when every reachable tank is dry" {
  _stub_codex
  clikae init codex T1
  clikae init codex T2
  : > "$CLIKAE_HOME/profiles/codex/T1/.dry"
  : > "$CLIKAE_HOME/profiles/codex/T2/.dry"
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" -- run "$BATS_TEST_TMPDIR/out.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dry"* ]] || false
}

@test "burn does NOT reroute a real task failure (no artifact, no limit)" {
  _stub_codex
  clikae init codex T1
  clikae init codex T2
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" -- noop
  [ "$status" -ne 0 ]
  [[ "$output" == *"real task failure"* ]] || false
  [[ "$output" != *"codex/T2"* ]] || false      # did not fall through
}

@test "burn --no-reroute runs once and stops on a dry tank" {
  _stub_codex
  clikae init codex T1
  clikae init codex T2
  : > "$CLIKAE_HOME/profiles/codex/T1/.dry"
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" --no-reroute -- run "$BATS_TEST_TMPDIR/out.md"
  [ "$status" -ne 0 ]
  [[ "$output" != *"codex/T2"* ]] || false
}

# --- agy burn: since the 2026-07-05 Keychain-carry restore, a tank switch is
# non-interactive, so burn can auto-hop agy tanks on dry (sequential — agy still
# can't run two tanks in parallel, unlike other engines that's fine for burn's
# single-task-at-a-time contract anyway). Per-tank dry state is a `.dry` marker
# INSIDE that tank's own slot dir (mirroring conduct.bats's _stub_agy_conduct) —
# since $HOME/.gemini symlinks to whichever tank is active, the stub sees it
# only when that tank is the one currently switched in.
_stub_agy_burn() {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  cat > "$bin/agy" <<'STUB'
#!/usr/bin/env bash
log="$HOME/.gemini/antigravity-cli/cli.log"
mkdir -p "$(dirname "$log")"
if [ -f "$HOME/.gemini/antigravity-cli/.dry" ]; then
  echo "RESOURCE_EXHAUSTED (code 429): Individual quota reached. Resets in 3h32m48s." > "$log"
  exit 0
fi
: > "$log"
[ -n "$STUB_ARTIFACT" ] && : > "$STUB_ARTIFACT"
exit 0
STUB
  chmod +x "$bin/agy"; PATH="$bin:$PATH"; export PATH
}

@test "burn rejects agy with no raw '-- <cmd...>' form (no adapter to fill flags)" {
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1
  run clikae burn agy work --artifact /tmp/x -- run /tmp/x
  [ "$status" -ne 0 ]
  [[ "$output" == *"no adapter"* ]] || false
}

@test "burn agy completes on the active tank and verifies by the artifact" {
  _stub_agy_burn
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy default >/dev/null 2>&1
  local A="$BATS_TEST_TMPDIR/out.md"
  STUB_ARTIFACT="$A" run clikae burn agy default --artifact "$A" --prompt "do the thing"
  [ "$status" -eq 0 ]
  [ -f "$A" ]
  [[ "$output" == *"Done on agy/default"* ]] || false
}

@test "burn agy hops to the next tank (Keychain carry) when the first runs dry" {
  _stub_agy_burn
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1       # default(active) + work
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli"
  : > "$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli/.dry"   # default is dry
  local A="$BATS_TEST_TMPDIR/out.md"
  STUB_ARTIFACT="$A" run clikae burn agy default --artifact "$A" --prompt "do the thing"
  [ "$status" -eq 0 ]
  [ -f "$A" ]
  [[ "$output" == *"ran dry"* ]] || false
  [[ "$output" == *"Done on agy/work"* ]] || false
  [ "$(readlink "$HOME/.gemini")" = "$CLIKAE_HOME/profiles/antigravity/work" ]   # actually switched, not just retried
}

@test "burn agy fails when every tank is dry" {
  _stub_agy_burn
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli" \
           "$CLIKAE_HOME/profiles/antigravity/work/antigravity-cli"
  : > "$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli/.dry"
  : > "$CLIKAE_HOME/profiles/antigravity/work/antigravity-cli/.dry"
  run clikae burn agy default --artifact "$BATS_TEST_TMPDIR/out.md" --prompt "do the thing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"All 2 agy tank(s) are dry"* ]] || false
}

@test "burn requires --artifact" {
  run clikae burn codex T1 -- run x
  [ "$status" -ne 0 ]
  [[ "$output" == *"artifact"* ]] || false
}

# --- _burn_timeout_bin: the honest-when-no-coreutils contract (world-class P1) ---

@test "_burn_timeout_bin: picks \`timeout\` when it's on PATH" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  . "$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\n' > "$BATS_TEST_TMPDIR/bin/timeout"; chmod +x "$BATS_TEST_TMPDIR/bin/timeout"
  local out; out="$(PATH="$BATS_TEST_TMPDIR/bin:$PATH" _burn_timeout_bin)"
  [ "$out" = "timeout" ]
}

@test "_burn_timeout_bin: no timeout tool → empty bin + a WARNING (runs unbounded, doesn't silently lie)" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  . "$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
  local out
  out="$(PATH="$TEST_HOME/.testbin" _burn_timeout_bin 2>"$BATS_TEST_TMPDIR/err")"   # testbin has no timeout/gtimeout
  [ -z "$out" ]                                                   # no bin selected
  grep -q "without a time bound" "$BATS_TEST_TMPDIR/err" || grep -qi "WITHOUT a time bound" "$BATS_TEST_TMPDIR/err"
}

# --- _burn_next_same_engine: in-use + same-account guards (2026-06-04 燒爆 dogfood) ---

_src_burn() {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/dry_store.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/adapter_loader.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/proc.sh"
  . "$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
}
_seed_email() { printf '{"emailAddress": "%s"}\n' "$3" > "$CLIKAE_HOME/profiles/$1/$2/.claude.json"; }

@test "_burn_next_same_engine: P0 — skips a tank an interactive session is live on" {
  _src_burn
  clikae init claude a; clikae init claude b
  live_dir_users() { case "$1" in */claude/a) printf '999\tclaude\n' ;; esac; }   # 'a' is in use
  local out; out="$(_burn_next_same_engine claude "" "" CLAUDE_CONFIG_DIR 0 2>/dev/null)"  # skip-warn → stderr
  [ "$out" = "b" ]
}

@test "_burn_next_same_engine: P0 — --allow-active (=1) uses the in-use tank anyway" {
  _src_burn
  clikae init claude a; clikae init claude b
  live_dir_users() { case "$1" in */claude/a) printf '999\tclaude\n' ;; esac; }
  run _burn_next_same_engine claude "" "" CLAUDE_CONFIG_DIR 1
  [ "$output" = "a" ]
}

@test "_burn_next_same_engine: P1 — skips a tank sharing a dried account (same quota)" {
  _src_burn
  clikae init claude a; clikae init claude b
  _seed_email claude a same@example.com; _seed_email claude b same@example.com
  live_dir_users() { :; }
  local out; out="$(_burn_next_same_engine claude "claude/a" "same@example.com" CLAUDE_CONFIG_DIR 0 2>/dev/null)"
  [ -z "$out" ]                          # b shares a's dried account → nothing left
}

@test "_burn_next_same_engine: P1 — a DIFFERENT account is still eligible" {
  _src_burn
  clikae init claude a; clikae init claude b
  _seed_email claude a one@example.com; _seed_email claude b two@example.com
  live_dir_users() { :; }
  run _burn_next_same_engine claude "claude/a" "one@example.com" CLAUDE_CONFIG_DIR 0
  [ "$output" = "b" ]
}

# --- #2 (tugtile dogfood): a STALE artifact must not be mistaken for success ---

@test "burn does NOT count a STALE artifact as success (judges by mtime change)" {
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  echo "leftover from a previous run" > "$A"     # stale artifact already present
  run clikae burn codex T1 --artifact "$A" -- noop   # this task writes nothing
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]] || false       # warned about the stale file
  [[ "$output" == *"real task failure"* ]] || false    # not a false "Done"
}

@test "burn --fresh clears a stale artifact before running" {
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  echo "leftover" > "$A"
  run clikae burn codex T1 --artifact "$A" --fresh -- run "$A"   # run recreates it
  [ "$status" -eq 0 ]
  [[ "$output" == *"cleared"* ]] || false
  [ -f "$A" ]
}

@test "burn counts an OVERWRITTEN pre-existing artifact as success (mtime advanced)" {
  # The path the absent->present tests miss: artifact PRE-EXISTS with an old mtime and
  # the task rewrites it. Catches the GNU/BSD stat-order bug (broken on Linux/CI).
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  echo "old" > "$A"; touch -t 202001010000 "$A"   # force an OLD mtime
  run clikae burn codex T1 --artifact "$A" -- run "$A"   # stub rewrites $A (mtime -> now)
  [ "$status" -eq 0 ]
  [[ "$output" == *"Done on codex/T1"* ]] || false
}

# --- #3 (tugtile dogfood): perl alarm fallback when no coreutils timeout ---

@test "_burn_timeout_bin: falls back to perl when no timeout/gtimeout" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  . "$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
  mkdir -p "$BATS_TEST_TMPDIR/perlbin"
  printf '#!/usr/bin/env bash\n' > "$BATS_TEST_TMPDIR/perlbin/perl"; chmod +x "$BATS_TEST_TMPDIR/perlbin/perl"
  local out; out="$(PATH="$BATS_TEST_TMPDIR/perlbin" _burn_timeout_bin)"   # only perl, no (g)timeout
  [ "$out" = "perl" ]
}

# --- issue #24: the convenience surface (--prompt-file / --prompt / --add-dir) ---
# clikae fills each engine's headless-write flags from its adapter, so the caller
# never hand-assembles them (2026-06-06 tugtile burn-writeup friction #1).

@test "burn --prompt-file builds the engine command via the hook and completes" {
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  export STUB_ARTIFACT="$A"
  printf 'write the file\n' > "$BATS_TEST_TMPDIR/task.txt"
  run clikae burn codex T1 --artifact "$A" --prompt-file "$BATS_TEST_TMPDIR/task.txt"
  [ "$status" -eq 0 ]
  [ -f "$A" ]
  [[ "$output" == *"Done on codex/T1"* ]] || false
}

@test "burn --prompt inline is equivalent to --prompt-file" {
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  export STUB_ARTIFACT="$A"
  run clikae burn codex T1 --artifact "$A" --prompt "write the file"
  [ "$status" -eq 0 ]
  [ -f "$A" ]
}

@test "burn --add-dir defaults to the artifact's parent (codex gets -C dirname)" {
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/sub/out.md"; mkdir -p "$BATS_TEST_TMPDIR/sub"
  export STUB_ARTIFACT="$A" STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
  run clikae burn codex T1 --artifact "$A" --prompt "x"
  [ "$status" -eq 0 ]
  grep -q -- "exec -C $BATS_TEST_TMPDIR/sub -s workspace-write" "$BATS_TEST_TMPDIR/argv.log"
}

@test "burn rejects --prompt and --prompt-file together" {
  _stub_codex
  clikae init codex T1
  printf 'x\n' > "$BATS_TEST_TMPDIR/task.txt"
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" --prompt x --prompt-file "$BATS_TEST_TMPDIR/task.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not both"* ]] || false
}

@test "burn with no prompt and no -- errors and mentions the prompt options" {
  _stub_codex
  clikae init codex T1
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--prompt-file"* ]] || false
}

@test "burn --prompt on an engine with no adapter_burn_flags errors clearly" {
  _stub_gh
  clikae init gh T1
  run clikae burn gh T1 --artifact "$BATS_TEST_TMPDIR/out.md" --prompt "x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"headless-write recipe"* ]] || false
  [[ "$output" == *"-- <cmd"* ]] || false
}

@test "burn --prompt cross-engine reroute regenerates flags for the new engine" {
  # T1 dry → reroute to T2; both codex here, but the recompose path runs and the
  # generated exec form must reach T2 (proves the prompt survives the hop).
  _stub_codex
  clikae init codex T1
  clikae init codex T2
  : > "$CLIKAE_HOME/profiles/codex/T1/.dry"
  local A="$BATS_TEST_TMPDIR/out.md"
  export STUB_ARTIFACT="$A" STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
  run clikae burn codex T1 --artifact "$A" --prompt "write it"
  [ "$status" -eq 0 ]
  [ -f "$A" ]
  [[ "$output" == *"codex/T2"* ]] || false
  grep -q -- "exec -C .* -s workspace-write" "$BATS_TEST_TMPDIR/argv.log"
}

# --- issue #24: direct unit tests pinning each engine's flag recipe ---
# A CLI flag rename is caught here, not in the field.

@test "adapter_burn_flags (claude): exact NUL-per-argv recipe" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local -a got=(); local x
  while IFS= read -r -d '' x; do got+=("$x"); done < <(adapter_burn_flags "do a thing" /tmp/wd)
  [ "${#got[@]}" -eq 5 ]
  [ "${got[0]}" = "-p" ]
  [ "${got[1]}" = "do a thing" ]
  [ "${got[2]}" = "--dangerously-skip-permissions" ]
  [ "${got[3]}" = "--add-dir" ]
  [ "${got[4]}" = "/tmp/wd" ]
}

@test "adapter_burn_flags (codex): exact NUL-per-argv recipe, first add-dir = cwd" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/codex.sh"
  # second add-dir /ignored is dropped — codex's writable root is its cwd (-C).
  local -a got=(); local x
  while IFS= read -r -d '' x; do got+=("$x"); done < <(adapter_burn_flags "do a thing" /tmp/wd /ignored)
  [ "${#got[@]}" -eq 6 ]
  [ "${got[0]}" = "exec" ]
  [ "${got[1]}" = "-C" ]
  [ "${got[2]}" = "/tmp/wd" ]
  [ "${got[3]}" = "-s" ]
  [ "${got[4]}" = "workspace-write" ]
  [ "${got[5]}" = "do a thing" ]
}

# THE BLIND SPOT (independent-audit catch 2026-06-13): a MULTI-LINE prompt must
# survive as ONE argv item, not be shattered into one item per line. Every other
# burn/conduct test uses a single-line prompt, which hid this.
@test "adapter_burn_flags / adapter_audit_flags do NOT leak across adapters (leak-guard)" {
  # The new optional hooks are in adapter_loader's unset list, so an adapter that
  # doesn't define them (gh) must not inherit claude's.
  _src_burn
  load_adapter claude
  declare -F adapter_burn_flags >/dev/null   # claude HAS it
  declare -F adapter_audit_flags >/dev/null
  load_adapter gh
  ! declare -F adapter_burn_flags >/dev/null # gh must NOT have inherited it
  ! declare -F adapter_audit_flags >/dev/null
}

@test "burn: --prompt with a trailing -- appends the extra argv after the generated flags" {
  # Documented escape-hatch combo. Pin the behaviour so it's not a silent surprise:
  # generated flags first, post-`--` argv appended verbatim.
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  export STUB_ARTIFACT="$A" STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
  run clikae burn codex T1 --artifact "$A" --prompt "do it" -- --color never
  [ "$status" -eq 0 ]
  # exec -C <dir> -s workspace-write "do it" --color never  (extra appended last)
  grep -q -- "workspace-write do it --color never" "$BATS_TEST_TMPDIR/argv.log"
}

@test "adapter_burn_flags (claude): a multi-line prompt stays ONE argv item" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/adapters/claude.sh"
  local ml; ml=$'line one\nline two\nline three'
  local -a got=(); local x
  while IFS= read -r -d '' x; do got+=("$x"); done < <(adapter_burn_flags "$ml" /tmp/wd)
  [ "${#got[@]}" -eq 5 ]          # NOT 7 — the 3 prompt lines did not split
  [ "${got[1]}" = "$ml" ]         # the whole multi-line prompt, intact
}

@test "burn --prompt-file delivers a MULTI-LINE prompt to codex as one arg" {
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  export STUB_ARTIFACT="$A" STUB_ARGC_LOG="$BATS_TEST_TMPDIR/argc.log"
  printf 'first line\nsecond line\nthird line\n' > "$BATS_TEST_TMPDIR/task.txt"
  run clikae burn codex T1 --artifact "$A" --prompt-file "$BATS_TEST_TMPDIR/task.txt"
  [ "$status" -eq 0 ]
  # codex argv must be exactly: exec -C <dir> -s workspace-write <prompt> = 6 args.
  # A shattered 3-line prompt would be 8. (The file's trailing newline is part of
  # the single prompt arg, not a separate arg.)
  [ "$(cat "$BATS_TEST_TMPDIR/argc.log")" = "6" ]
}
