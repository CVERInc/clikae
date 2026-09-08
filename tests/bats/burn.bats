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
# clikae asks for a per-run log with --log-file so a concurrent interactive agy
# cannot have its quota event charged to this run; honour it, and fail loudly if
# the flag ever stops being passed (the shared symlink is the bug, not a default).
AGY_ARGV="$*"                             # keep the full argv; the loop below eats it
log=""
while [ $# -gt 0 ]; do
  [ "$1" = "--log-file" ] && { log="$2"; break; }
  shift
done
[ -n "$log" ] || { echo "stub: clikae did not pass --log-file" >&2; exit 64; }
[ -n "$STUB_ARGV_LOG" ] && printf '%s\n' "$AGY_ARGV" >> "$STUB_ARGV_LOG"
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
  CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"   # burn.sh sources antigravity.sh at load time
  . "$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\n' > "$BATS_TEST_TMPDIR/bin/timeout"; chmod +x "$BATS_TEST_TMPDIR/bin/timeout"
  local out; out="$(PATH="$BATS_TEST_TMPDIR/bin:$PATH" _burn_timeout_bin)"
  [ "$out" = "timeout" ]
}

@test "_burn_timeout_bin: no timeout tool → empty bin + a WARNING (runs unbounded, doesn't silently lie)" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"   # burn.sh sources antigravity.sh at load time
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
  CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"   # burn.sh sources antigravity.sh at load time
  . "$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
  mkdir -p "$BATS_TEST_TMPDIR/perlbin"
  printf '#!/usr/bin/env bash\n' > "$BATS_TEST_TMPDIR/perlbin/perl"; chmod +x "$BATS_TEST_TMPDIR/perlbin/perl"
  local out; out="$(PATH="$BATS_TEST_TMPDIR/perlbin" _burn_timeout_bin)"   # only perl, no (g)timeout
  [ "$out" = "perl" ]
}

# --- issue #24: the convenience surface (--prompt-file / --prompt / --add-dir) ---
# clikae fills each engine's headless-write flags from its adapter, so the caller
# never hand-assembles them (2026-06-06 tugtile burn-writeup friction #1).

@test "burn executes headless tasks inside tmux when available" {
  if ! command -v tmux >/dev/null 2>&1; then
    skip "tmux not installed"
  fi
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  export STUB_ARTIFACT="$A"
  
  # Inject a payload that dumps the actual tmux session name to the artifact
  # (Since $TMUX could be inherited from an outer shell, we ask tmux itself)
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat << 'STUB' > "$BATS_TEST_TMPDIR/bin/codex"
#!/usr/bin/env bash
if [ -n "$TMUX" ]; then
  tmux display-message -p '#S' > "$STUB_ARTIFACT" 2>/dev/null || echo "TMUX_ERR" > "$STUB_ARTIFACT"
else
  echo "NO_TMUX" > "$STUB_ARTIFACT"
fi
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/codex"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  run clikae burn codex T1 --artifact "$A" --prompt "dump tmux status"
  [ "$status" -eq 0 ]
  [ -f "$A" ]
  run cat "$A"
  [[ "$output" == clikae-*-burn-* ]]
}

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
  [ "${#got[@]}" -eq 6 ]
  [ "${got[0]}" = "-p" ]
  [ "${got[1]}" = "do a thing" ]
  # 🔴 A SCOPED grant, not a blanket one. burn's contract is "write to --add-dir",
  # and --dangerously-skip-permissions bypasses the permission system entirely:
  # measured 2026-08-16, it wrote OUTSIDE the roots it was given, while
  # acceptEdits wrote inside and was blocked outside. codex has always been
  # scoped (-s workspace-write); this was the engine where the same documented
  # promise had no boundary.
  [ "${got[2]}" = "--permission-mode" ]
  [ "${got[3]}" = "acceptEdits" ]
  [ "${got[4]}" = "--add-dir" ]
  [ "${got[5]}" = "/tmp/wd" ]
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
  [ "${#got[@]}" -eq 6 ]          # NOT 8 — the 3 prompt lines did not split
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

# --- agy: burn's artifact contract vs agy's headless permission model ---------
# Field report 2026-07-27: `burn agy --artifact` failed in 11s, every time.
# burn proves a run by the artifact FILE (exit codes lie); agy's headless mode
# auto-denies the file tools on your paths because it cannot prompt for
# permission with no terminal. Two contracts that cannot both be satisfied by
# agy — but only over who holds the pen. agy prints fine, and burn already had
# the output in hand, so clikae writes the artifact.
_stub_agy_prints() {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  cat > "$bin/agy" <<'STUB'
#!/usr/bin/env bash
log="$HOME/.gemini/antigravity-cli/cli.log"; mkdir -p "$(dirname "$log")"; : > "$log"
# Exactly the real shape: prints its answer, never touches the caller's paths.
printf 'REVIEW: looks good\n'
printf 'ARGV: %s\n' "$*"
exit 0
STUB
  chmod +x "$bin/agy"; PATH="$bin:$PATH"; export PATH
}

_stub_agy_silent() {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  cat > "$bin/agy" <<'STUB'
#!/usr/bin/env bash
log="$HOME/.gemini/antigravity-cli/cli.log"; mkdir -p "$(dirname "$log")"; : > "$log"
exit 0
STUB
  chmod +x "$bin/agy"; PATH="$bin:$PATH"; export PATH
}

@test "burn agy: clikae captures agy's stdout into the artifact it can't write itself" {
  _stub_agy_prints
  printf 'y\n' | "$CLIKAE_BIN" init agy default >/dev/null 2>&1
  local art="$BATS_TEST_TMPDIR/review.md"
  run clikae burn agy default --artifact "$art" --prompt "review this"
  [ "$status" -eq 0 ]
  [ -f "$art" ]
  [[ "$(cat "$art")" == *"REVIEW: looks good"* ]] || false
  # and it says WHO wrote it — the user must not think agy did
  [[ "$output" == *"clikae captured its output"* ]] || false
}

@test "burn agy: a REFUSAL is a failure, not an artifact full of the refusal" {
  # agy exits 0 whether it answered or declined, and the decline arrives on the
  # same stdout an answer would. Capturing stdout blindly turned "the tool said
  # no" into a DONE row with the refusal text sitting in the artifact — a false
  # success, worse than the honest failure it replaced. Caught by dogfooding.
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  cat > "$bin/agy" <<'STUB'
#!/usr/bin/env bash
log="$HOME/.gemini/antigravity-cli/cli.log"; mkdir -p "$(dirname "$log")"; : > "$log"
printf 'jetski: no output produced — a tool required the "read_file" permission that headless mode cannot prompt for, so it was auto-denied.\n'
exit 0
STUB
  chmod +x "$bin/agy"; PATH="$bin:$PATH"; export PATH
  printf 'y\n' | "$CLIKAE_BIN" init agy default >/dev/null 2>&1
  local art="$BATS_TEST_TMPDIR/refused.md"
  run clikae burn agy default --artifact "$art" --prompt "review this"
  [ "$status" -ne 0 ]
  [ ! -f "$art" ]                                  # no artifact full of "I declined"
  [[ "$output" == *"declined"* ]] || false
}

@test "burn agy: success says CAPTURED, not verified" {
  # burn's artifact means "the ENGINE did the work" for claude/codex. For agy
  # clikae only relocates stdout, which proves nothing — the wording must not
  # borrow the stronger claim.
  _stub_agy_prints
  printf 'y\n' | "$CLIKAE_BIN" init agy default >/dev/null 2>&1
  local art="$BATS_TEST_TMPDIR/cap.md"
  run clikae burn agy default --artifact "$art" --prompt "x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CAPTURED, NOT VERIFIED"* ]] || false
}

@test "burn agy: a silent run is still a failure, and says where to look" {
  _stub_agy_silent
  printf 'y\n' | "$CLIKAE_BIN" init agy default >/dev/null 2>&1
  local art="$BATS_TEST_TMPDIR/nothing.md"
  run clikae burn agy default --artifact "$art" --prompt "review this"
  [ "$status" -ne 0 ]
  [ ! -f "$art" ]
  [[ "$output" == *"brain"* ]] || false      # points at agy's own buffer dir
}

@test "burn agy passes extra flags after -- through to agy, not dropping them" {
  _stub_agy_burn
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy default >/dev/null 2>&1
  local A="$BATS_TEST_TMPDIR/out.md"
  local L="$BATS_TEST_TMPDIR/argv.log"
  # Headless dispatch needs --dangerously-skip-permissions (agy's print mode
  # auto-denies file tools) and -c to continue a run. agy has no adapter, so
  # clikae cannot compose these — it must at least not swallow them.
  STUB_ARTIFACT="$A" STUB_ARGV_LOG="$L" run clikae burn agy default \
    --artifact "$A" --prompt "do the thing" -- --dangerously-skip-permissions -c
  [ "$status" -eq 0 ]
  grep -q -- "--dangerously-skip-permissions" "$L" || { cat "$L"; false; }
  grep -q -- " -c" "$L" || { cat "$L"; false; }
}

@test "burn agy: --timeout is handed to agy as --print-timeout" {
  # Without this, agy enforced its OWN 5-minute default and clikae's --timeout
  # was a fiction for any longer task.
  _stub_agy_prints
  printf 'y\n' | "$CLIKAE_BIN" init agy default >/dev/null 2>&1
  local art="$BATS_TEST_TMPDIR/t.md"
  run clikae burn agy default --artifact "$art" --prompt "x" --timeout 900
  [ "$status" -eq 0 ]
  [[ "$(cat "$art")" == *"--print-timeout 900s"* ]] || false
}

# --json — the machine-readable result. AGENTS.md's rule 1 is "judge by the
# artifact/output, never the exit code", and until 2026-08-16 an agent had to
# read that judgement out of prose. With rerouting, the tank that actually did
# the work is often not the one you named, and nothing said which in a form a
# script could use.

@test "burn --json: success is one object on stdout, prose on stderr" {
  _stub_codex
  clikae init codex T1
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" --json -- run "$BATS_TEST_TMPDIR/out.md"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # stdout must be parseable on its own — the whole point.
  clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/o2.md" --json -- run "$BATS_TEST_TMPDIR/o2.md" \
    > "$BATS_TEST_TMPDIR/j.txt" 2> "$BATS_TEST_TMPDIR/e.txt"
  run python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['ok'], d['engine'], d['tank'], d['artifact_bytes'] is not None)" "$BATS_TEST_TMPDIR/j.txt"
  [ "$status" -eq 0 ] || { echo "stdout was not valid JSON:"; cat "$BATS_TEST_TMPDIR/j.txt"; false; }
  [ "$output" = "True codex T1 True" ] || { echo "got: $output"; false; }
  # and the prose still happened, just not on stdout
  grep -q 'Done on codex/T1' "$BATS_TEST_TMPDIR/e.txt" || { cat "$BATS_TEST_TMPDIR/e.txt"; false; }
}

@test "burn --json: a reroute names the tank that ACTUALLY ran it" {
  # The case prose is worst at: you asked for T1, T2 did the work.
  _stub_codex
  clikae init codex T1
  clikae init codex T2
  : > "$CLIKAE_HOME/profiles/codex/T1/.dry"
  clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" --json -- run "$BATS_TEST_TMPDIR/out.md" \
    > "$BATS_TEST_TMPDIR/j.txt" 2>/dev/null
  run python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['ok'], d['tank'], ','.join(d['rerouted_from']))" "$BATS_TEST_TMPDIR/j.txt"
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/j.txt"; false; }
  [ "$output" = "True T2 codex/T1" ] || { echo "got: $output"; false; }
}

@test "burn --json: every tank dry is a distinct, readable outcome" {
  _stub_codex
  clikae init codex T1
  : > "$CLIKAE_HOME/profiles/codex/T1/.dry"
  clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" --json -- run "$BATS_TEST_TMPDIR/out.md" \
    > "$BATS_TEST_TMPDIR/j.txt" 2>/dev/null || true
  run python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['ok'], d['reason'])" "$BATS_TEST_TMPDIR/j.txt"
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/j.txt"; false; }
  [[ "$output" == "False every reachable tank is dry" ]] || { echo "got: $output"; false; }
}

@test "burn without --json prints no JSON at all" {
  # The result object must not leak into the human surface.
  _stub_codex
  clikae init codex T1
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" -- run "$BATS_TEST_TMPDIR/out.md"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *'"artifact_bytes"'* ]] || { echo "$output"; false; }
}

# --- prelaunch lock (2026-09-06 report): soul_prelaunch/fleet_mcp_prelaunch race
# on (engine, tank, $PWD), unlocked, the same bug class switch.sh's --ephemeral
# path fixed for itself after the 2026-07-19 incident. burn.sh now serializes on
# a BLOCKING lock keyed the same way — held only across those two calls.
@test "burn's soul/MCP prelaunch waits out a held lock instead of racing it" {
  command -v lockf >/dev/null 2>&1 || skip "lockf needed to hold the lock"
  _stub_codex
  clikae init codex T1
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"    # for CLIKAE_SESS_PREFIX, same as burn.sh
  cd "$BATS_TEST_TMPDIR"                    # fix $PWD: the lock key includes it
  local lockfile
  lockfile="$HOME/.clikae/state/${CLIKAE_SESS_PREFIX}prelaunch-$(printf '%s' "codex/T1:$PWD" | cksum | cut -d' ' -f1).lock"
  mkdir -p "$(dirname "$lockfile")"

  # Hold the SAME lock burn.sh is about to want, the way suite-lock.bats holds
  # its own door: a real external holder, not a mock.
  lockf -k -t 5 "$lockfile" sleep 2 &
  local holder=$!
  local i=0
  while [ "$i" -lt 50 ]; do
    lockf -k -t 0 "$lockfile" true 2>/dev/null || break   # confirmed busy
    i=$((i + 1)); sleep 0.1
  done
  [ "$i" -lt 50 ] || { kill "$holder" 2>/dev/null; skip "could not get the lock held"; }

  local A="$BATS_TEST_TMPDIR/out.md"
  local t0; t0=$(date +%s)
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  local t1; t1=$(date +%s)
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  # It must still SUCCEED (a queued burn, not a refused one) …
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$A" ] || { echo "$output"; false; }
  # … and it must have actually WAITED for the holder rather than stepping past
  # it — the whole point of a blocking flock/lockf over a `-n` one.
  [ "$((t1 - t0))" -ge 1 ] || { echo "finished in $((t1 - t0))s — did it wait at all?"; false; }
}


# Synchronous tmux transport: execute the real generated wrapper, then let the
# cockpit consume DONE before burn's parent observes the exit marker. No timing
# lottery and no real server; engine/env/exit-trap code still runs unchanged.
_stub_burn_transport() {
  _stub_codex
  cat > "$BATS_TEST_TMPDIR/bin/tmux" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    'bash "'*)
      bash -c "$arg" >/dev/null 2>&1
      [ -z "${STUB_CONSUME_ARTIFACT:-}" ] || rm -f "$STUB_CONSUME_ARTIFACT"
      # Simulate a write landing AFTER the engine-exit snapshot (P2-1): the
      # engine's own process tree already exited empty-handed by the time
      # `bash -c "$arg"` above returns, so this write is chronologically
      # later than `_burn_snapshot` — but still before cmd_burn classifies.
      [ -z "${STUB_LATE_WRITE_ARTIFACT:-}" ] || printf 'late' > "$STUB_LATE_WRITE_ARTIFACT"
      exit 0 ;;
  esac
done
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
}


@test "burn #42: cockpit consumption after engine exit preserves success and bytes" {
  _stub_burn_transport
  clikae init codex T1
  export STUB_CONSUME_ARTIFACT="$BATS_TEST_TMPDIR/DONE"
  run clikae burn codex T1 --json --artifact "$STUB_CONSUME_ARTIFACT" -- run "$STUB_CONSUME_ARTIFACT"
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_CONSUME_ARTIFACT" ]
  [[ "$output" == *'"artifact_bytes":0'* ]] || false
  [[ "$output" == *'"ok":true'* ]] || false
}


@test "burn #42: snapshot preserves nonempty size after consumption" {
  _src_burn
  local artifact="$BATS_TEST_TMPDIR/DONE" evidence="$BATS_TEST_TMPDIR/evidence"
  printf 'success' > "$artifact"
  _burn_snapshot "$artifact" 0 "$evidence"
  rm "$artifact"
  [ "$(cat "$evidence")" = '1 7' ]
}

@test "burn #42: stale and absent snapshots cannot claim success" {
  _src_burn
  local artifact="$BATS_TEST_TMPDIR/DONE" evidence="$BATS_TEST_TMPDIR/evidence"
  _burn_snapshot "$artifact" 0 "$evidence"
  [ "$(cat "$evidence")" = '0 null' ]
  printf old > "$artifact"
  _burn_snapshot "$artifact" "$(_clikae_mtime "$artifact")" "$evidence"
  [ "$(cat "$evidence")" = '0 3' ]
}

@test "burn #42: direct fallback keeps artifact evidence with a nonzero engine exit" {
  _stub_burn_transport
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/tmux"
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'done' > "$STUB_ARTIFACT"
exit 7
STUB
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  clikae init codex T1
  run clikae burn codex T1 --json --artifact "$STUB_ARTIFACT" --prompt x
  [ "$status" -eq 0 ]
  [[ "$output" == *'"artifact_bytes":4'* ]] || false
  [[ "$output" == *'"ok":true'* ]] || false
}

@test "burn #45: Claude weekly limit preserves dated reset in JSON" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf "You've hit your weekly limit · resets Jul 27 at 5am (Asia/Tokyo)\n"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  clikae init claude T1
  run clikae burn claude T1 --no-reroute --json --artifact "$BATS_TEST_TMPDIR/out" --prompt x
  [ "$status" -ne 0 ]
  [[ "$output" == *'"reason":"tank ran dry and --no-reroute is set"'* ]] || false
  [[ "$output" == *'"reset":"resets Jul 27 at 5am (Asia/Tokyo)"'* ]] || false
}


@test "burn #45: all Claude limit spellings relay reset text and ordinary prose stays clear" {
  _src_burn
  local phrase reset
  reset="$(awk -F '\t' '!/^#/ && $2 ~ /Jul 27 at 5am/ {print $2; exit}' "$CLIKAE_TEST_ROOT/tests/fixtures/limit-reset-phrases.tsv")"
  [ -n "$reset" ]
  for phrase in "You've hit your weekly limit" "You've hit your weekly-limit" 'Weekly limit reached' "You've hit your session limit" "You've hit your usage limit"; do
    run limit_output_dry claude "$phrase · $reset"
    [ "$status" -eq 0 ]
    [ "$output" = "$reset" ]
  done
  run limit_output_dry claude 'Please explain the weekly limit reset policy'
  [ "$status" -ne 0 ]
}

# --- P2-2 (2026-09-08 review): "weekly[ -]limit (reached|exceeded)" was the
# only bare alternative in the claude branch — every other one anchors on a
# verb naming the human ("hit your …"). Ordinary prose that merely discusses a
# weekly limit fired it (review's test K, all three FALSE-DRY with reset:[]).

@test "burn #45: prose merely discussing a weekly limit does not fire dry (P2-2)" {
  _src_burn
  local phrase
  for phrase in \
    "In the audit, the weekly limit reached its cap in July." \
    "Document the case where the weekly limit reached zero." \
    "the weekly limit exceeded expectations"
  do
    run limit_output_dry claude "$phrase"
    [ "$status" -ne 0 ]
  done
}

# --- P2-1 (2026-09-08 ROUND-2 review): the very fix above landed a bare
# "reached your … limit" alongside the anchored "weekly[ -]limit" one — same
# hole, reopened in the same commit sequence. Unlike "hit your …", "reached
# your …" reads naturally in third-person documentation prose that also
# addresses the reader as "you" (review's PROBE D, all three FALSE-DRY —
# including one where a plain word-wrap happens to land the phrase at the
# start of a line, showing a line anchor alone would not have been enough).

@test "burn #45: prose that reads 'reached your … limit' without a direct vendor report does not fire dry (P2-1 r2)" {
  _src_burn
  local phrase
  for phrase in \
    $'The runbook covers what happens when you have\nreached your weekly limit and how to wait it out.' \
    "Each seat has reached your weekly limit of five reviews." \
    "> Once a tank has reached your usage limit the board turns red."
  do
    run limit_output_dry claude "$phrase"
    [ "$status" -ne 0 ]
  done
}

@test "burn #45: a genuine 'reached your … limit' vendor report still fires dry (P2-1 r2)" {
  _src_burn
  run limit_output_dry claude "You've reached your session limit · resets 5am (Asia/Tokyo)"
  [ "$status" -eq 0 ]
  [ "$output" = "resets 5am (Asia/Tokyo)" ]
  run limit_output_dry claude "You have reached your usage limit. Try again Sep 14."
  [ "$status" -eq 0 ]
}

# --- P1-1 (2026-09-08 ROUND-3 review): the fix just above required "you've"/
# "you have" to sit IMMEDIATELY before the verb — narrower than main, which
# never required that prefix at all. A curly apostrophe or a one-word adverb
# are both things a real vendor sentence can carry, and both made the phrase
# invisible (review's PROBE A / A2): a genuinely dry tank was misread as a
# hard task failure — no reroute, no dry marker, no reset, the exact failure
# `burn --help` warns about.

@test "burn #45: a curly apostrophe before the verb still fires dry (P1-1 r3)" {
  _src_burn
  run limit_output_dry claude "You’ve hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
  [ "$status" -eq 0 ]
}

@test "burn #45: an adverb between the direct report and the verb still fires dry (P1-1 r3)" {
  _src_burn
  run limit_output_dry claude "You have already hit your usage limit."
  [ "$status" -eq 0 ]
  run limit_output_dry claude "You've just hit your session limit."
  [ "$status" -eq 0 ]
  run limit_output_dry claude "You have already hit your weekly limit. Your limit will reset at 5am (Asia/Tokyo)."
  [ "$status" -eq 0 ]
  [ "$output" = "reset at 5am (Asia/Tokyo)" ]
}

# --- P1-1 (2026-09-08 ROUND-3 review, closing item): the review's harder
# complaint wasn't just the two counterexamples above — it was that
# limit.sh's comment and CHANGELOG both claimed a "corpus" backed this
# regex ("every genuine phrase in the corpus has … and none of the false
# positives do") when `tests/fixtures/limit-reset-phrases.tsv` holds only
# reset phrases, not full vendor sentences (`grep -c 'hit your'` on it is
# 0 — CHANGELOG now carries a Correction note saying so). Nothing in this
# suite tied the fixture's REAL reset-phrase corpus to a real vendor
# sentence shape and proved the pair still classifies, and nothing proved
# main's own literal corpus sentence — never broken by any of these fixes,
# but never checked for claude specifically either — still fires dry.

@test "burn #45: main's own corpus sentence still fires dry for claude (P1-1 closing)" {
  _src_burn
  run limit_output_dry claude "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
  [ "$status" -eq 0 ]
  [ "$output" = "Try again at Jul 7th, 2026 2:17 PM" ]
}

@test "burn #45: a real sample of the fixture's reset-phrase corpus fires dry under every real vendor-sentence shape (P1-1 closing)" {
  _src_burn
  local fixture="$CLIKAE_TEST_ROOT/tests/fixtures/limit-reset-phrases.tsv"
  local -a resets=()
  local _e phrase _x
  while IFS=$'\t' read -r _e phrase _x; do
    [ -n "$phrase" ] || continue
    resets+=("$phrase")
  done < <(awk -F'\t' '!/^#/ && NF==3' "$fixture" | awk 'NR==1 || NR%37==0')
  [ "${#resets[@]}" -ge 4 ]
  local reset core
  for reset in "${resets[@]}"; do
    for core in "You've hit your usage limit." "You’ve hit your usage limit." "You have already hit your usage limit."; do
      run limit_output_dry claude "$core $reset"
      [ "$status" -eq 0 ]
      [ "$output" = "$reset" ]
    done
  done
}

@test "burn #45: a real dry reply with a curly apostrophe reroutes instead of a hard failure (P1-1 r3)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
case "$CLAUDE_CONFIG_DIR" in
  */T1) echo "You’ve hit your usage limit · resets 5am (Asia/Tokyo)" ;;
  *) printf 'done' > "$STUB_ARTIFACT" ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  clikae init claude T1
  clikae init claude T2
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  run clikae burn claude T1 --json --artifact "$STUB_ARTIFACT" --prompt x
  [ "$status" -eq 0 ]
  [[ "$output" == *'"tank":"T2"'* ]] || false
  [[ "$output" == *'"rerouted_from":["claude/T1"]'* ]] || false
}

# --- P1-1 (2026-09-08 ROUND-4 review): the fix above anchored the direct
# report to `^`, the very start of a line — narrower than main yet again,
# for the third round running, this time on ordinary TRANSPORT noise no
# caller ever chose to write (indentation, a tab, a leading "⚠ "). Tolerate
# up to 12 bytes of LEADING NON-ALPHABETIC noise before "you've"/"you have"
# instead of requiring the direct report to be the very first byte.
# Corpus-as-contract: every row below MUST still fire dry, and every row in
# the r2/r3 false-positive corpus MUST still NOT fire — the widened anchor
# must not reopen either P2-2(r2)/P1-1(r3)'s closed prose cases. "Error: "/
# "codex: "/timestamp prefixes are a KNOWN, documented gap (review's P3-4):
# they carry their own letters, so a non-alphabetic-noise anchor cannot
# recover them without a real vendor-output corpus — not asserted here as a
# promise this round doesn't keep.

@test "burn #45: leading transport noise (indent/tab/warning glyph) does not hide a real vendor sentence (P1-1 r4 must-match)" {
  _src_burn
  local -a must_match=(
    "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
    "  You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
    $'\tYou\'ve hit your usage limit. Try again at Jul 7th, 2026 2:17 PM.'
    "⚠ You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
  )
  local line
  for line in "${must_match[@]}"; do
    run limit_output_dry claude "$line"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Jul 7th"* ]] || false
  done
}

@test "burn #45: the r2/r3 prose false-positive corpus still does not fire dry under the widened anchor (P1-1 r4 must-not-match)" {
  _src_burn
  local -a must_not_match=(
    "the weekly limit reached its cap in July"
    "Each seat has reached your weekly limit of five reviews."
    "I could not write the file. The runbook covers what happens when you have reached your weekly limit."
  )
  local line
  for line in "${must_not_match[@]}"; do
    run limit_output_dry claude "$line"
    [ "$status" -ne 0 ]
  done
}

# --- P2-1 (2026-09-08 round-5 review): the "up to 12 bytes of leading
# NON-ALPHABETIC noise" allowance (round-4's fix, just above) was wide
# enough to admit markdown syntax a model's own prose legitimately
# produces — a blockquote marker (`>`) or a numbered-list digit + `.` —
# neither of which are letters either. A real task failure whose reply was
# drafting a runbook ("The runbook I was drafting says: > You have reached
# your weekly limit.") let the blockquote marker stand in for transport
# noise and walked the whole reserve. `main` never matched "reached your
# weekly limit" at all, so this was a regression this PR introduced.

@test "burn #45: a markdown blockquote/list marker in front of quoted prose does not fire dry (P2-1 r5 must-not-match)" {
  _src_burn
  local -a must_not_match=(
    "> You have reached your weekly limit."
    "1. You have reached your weekly limit — explain this to the user."
  )
  local line
  for line in "${must_not_match[@]}"; do
    run limit_output_dry claude "$line"
    [ "$status" -ne 0 ]
  done
}

@test "burn #45: a real task failure whose reply quotes a runbook blockquote does not burn the whole reserve (P2-1 r5, PROBE B)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'I could not finish: the parser test still fails.\n'
printf 'The runbook I was drafting says:\n'
printf '> You have reached your weekly limit.\n'
printf '...and that is all I got done.\n'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  clikae init claude C1
  clikae init claude C2
  clikae init claude C3
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  run clikae burn claude C1 --json --artifact "$STUB_ARTIFACT" --prompt x
  [ "$status" -ne 0 ]
  [[ "$output" == *'"reason":"no fresh artifact and no limit"'* ]] || false
  [[ "$output" != *'"reason":"every reachable tank is dry"'* ]] || false
  [[ "$output" == *'"rerouted_from":[]'* ]] || false
}

# --- the leading transport noise the round-4 fix DID close must stay closed.

@test "burn #45: leading transport noise still fires dry under the narrowed noise class (P2-1 r5 must-match, no regression)" {
  _src_burn
  local -a must_match=(
    "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
    "  You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
    $'\tYou\'ve hit your usage limit. Try again at Jul 7th, 2026 2:17 PM.'
    "⚠ You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
  )
  local line
  for line in "${must_match[@]}"; do
    run limit_output_dry claude "$line"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Jul 7th"* ]] || false
  done
}

# --- P2-1 (2026-09-08 ROUND-4 review): _burn_redact truncated to the last
# 64 KiB BEFORE classification — bounding not just the (now O(n)) redaction
# but the classifiers' ENTIRE view of the reply. burn's own purpose is long,
# unattended tasks whose captures are large, and a vendor's own limit line
# or a tool-host outage commonly sits well before the tail once the model
# keeps talking afterward — exactly the captures burn exists for went blind.
# Classification must see the full capture; only the short diagnostic tail
# may still bound itself (see _burn_redact_full / _burn_redact in burn.sh).

@test "burn #45: a dry signal more than 64KiB from the end of the capture still reroutes (P2-1 r4 must-match)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
case "$CLAUDE_CONFIG_DIR" in
  */T1)
    printf "You've hit your usage limit · resets 5am (Asia/Tokyo)\n"
    yes "trailing noise after the limit line, same reply" | head -c 100000
    ;;
  *) printf 'done' > "$STUB_ARTIFACT" ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  clikae init claude T1
  clikae init claude T2
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  run clikae burn claude T1 --json --artifact "$STUB_ARTIFACT" --prompt x
  [ "$status" -eq 0 ]
  [[ "$output" == *'"tank":"T2"'* ]] || false
  [[ "$output" == *'"rerouted_from":["claude/T1"]'* ]] || false
}

@test "burn #45: a large CLEAN capture with no limit signal does not falsely reroute (P2-1 r4 must-not-match)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
yes "ordinary progress output, nothing to do with any limit" | head -c 100000
printf 'done' > "$STUB_ARTIFACT"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  clikae init claude T1
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  run clikae burn claude T1 --json --artifact "$STUB_ARTIFACT" --prompt x
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reason":"artifact produced"'* ]] || false
}

# --- P2-2 (2026-09-08 ROUND-4 review): limit_codex_output_dry matched a bare
# "hit your (usage|session) limit" ANYWHERE in the reply — unlike claude's
# branch, never anchored to a direct vendor report — so a task that merely
# TALKS ABOUT the limit while genuinely FAILING for an unrelated reason was
# misread as a real codex limit event: three tanks burned rerouting a task
# that was never dry (review PROBE B / B3). Anchor codex the same way as
# claude (line-start-tolerant direct report), AND require the reply to
# actually yield a reset phrase — a genuine codex event always carries
# "try again at …", prose about the limit almost never does.

@test "burn #45: codex prose that merely talks about the limit during a real task failure does not reroute (P2-2 r4 must-not-match, PROBE B3)" {
  _stub_burn_transport
  _src_burn
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'I could not finish: the parser test still fails.\n'
printf 'See docs/runbook.md for what to do once you hit your usage limit.\n'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/codex"
  clikae init codex T1
  clikae init codex T2
  clikae init codex T3
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  run clikae burn codex T1 --json --artifact "$STUB_ARTIFACT" --prompt x
  [ "$status" -ne 0 ]
  [[ "$output" == *'"reason":"no fresh artifact and no limit"'* ]] || false
  [[ "$output" != *'"reason":"every reachable tank is dry"'* ]] || false
  run dry_store_read codex T1
  [ "$status" -ne 0 ]                         # no false marker written
}

@test "burn #45: a genuine anchored codex limit sentence still fires dry and yields a reset (P2-2 r4 must-match)" {
  _src_burn
  run limit_codex_output_dry "You've hit your usage limit. try again at Jul 7th, 2026 2:17 PM."
  [ "$status" -eq 0 ]
  [[ "$output" == *"Jul 7th"* ]] || false
}

@test "burn #45: codex bare mention with no direct report and no reset phrase does not fire dry (P2-2 r4 must-not-match)" {
  _src_burn
  run limit_codex_output_dry "once you hit your usage limit, wait for the reset."
  [ "$status" -ne 0 ]
}

# --- P2-3 (2026-09-08 ROUND-3 review): the "you've "/"you have " prefix check
# above was never anchored to the start of a line, so it still matched its OWN
# documented counterexample — CHANGELOG's "the runbook covers what happens
# when you have reached your weekly limit…" — the instant it appears mid-
# sentence in a real reply, walking the entire reserve on a genuine task
# failure (round-3 PROBE O). Also: CHANGELOG and this file's own comments
# claimed "every genuine phrase in the corpus has it and none of the false
# positives do" — a claim this exact input disproves and the fixture never
# supported in the first place (it holds reset phrases, not full sentences).

@test "burn #45: a third-person sentence that merely QUOTES 'you have reached … limit' mid-line does not fire dry (P2-3 r3)" {
  _src_burn
  run limit_output_dry claude "I could not write the file. The runbook covers what happens when you have reached your weekly limit and how to wait it out."
  [ "$status" -ne 0 ]
}

@test "burn #45: that same sentence does not burn through the whole reserve (P2-3 r3)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "I could not write the file. The runbook covers what happens when you have reached your weekly limit and how to wait it out."
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  clikae init claude C1
  clikae init claude C2
  clikae init claude C3
  run clikae burn claude C1 --json --artifact "$BATS_TEST_TMPDIR/out" --prompt x
  [ "$status" -ne 0 ]
  [[ "$output" == *'"reason":"no fresh artifact and no limit"'* ]] || false
  [[ "$output" == *'"rerouted_from":[]'* ]] || false
}

# --- P2-3 (2026-09-08 review): #45's reset-extraction claim ("preserving the
# vendor's reset phrase") only held for two of five real-shaped declaration
# sentences from the review's corpus (PROBE G) — a singular "reset at" phrasing
# extracted nothing (reset:null), and a "reached your … limit" ordering wasn't
# even detected as dry at all (a real limit misread as a hard task failure,
# which is worse than a missing reset string). The review could not confirm
# which sentence a real vendor prints, so the honest fix widens coverage of
# both known real shapes rather than inventing an unconfirmed corpus row.

@test "burn #45: 'reset at' phrasing is extracted, not dropped to null (P2-3)" {
  _src_burn
  run limit_output_dry claude "You've hit your weekly limit. Your limit will reset at 5am (Asia/Tokyo)."
  [ "$status" -eq 0 ]
  [ "$output" = "reset at 5am (Asia/Tokyo)" ]
}

@test "burn #45: 'reached your weekly limit' ordering is detected as dry, not a hard task failure (P2-3)" {
  _src_burn
  run limit_output_dry claude "You've reached your weekly limit. Try again Sep 14."
  [ "$status" -eq 0 ]
}

@test "burn #45: all five review PROBE-G declaration shapes are honoured" {
  _src_burn
  run limit_output_dry claude "You've hit your weekly limit · resets 5am (Asia/Tokyo)"
  [ "$status" -eq 0 ]; [ "$output" = "resets 5am (Asia/Tokyo)" ]
  run limit_output_dry claude "You've hit your weekly limit — resets Sep 14 at 5am (Asia/Tokyo)"
  [ "$status" -eq 0 ]; [ "$output" = "resets Sep 14 at 5am (Asia/Tokyo)" ]
  run limit_output_dry claude "Weekly limit reached. Resets Sunday at 12:00 AM."
  [ "$status" -eq 0 ]; [ "$output" = "Resets Sunday at 12:00 AM." ]
}

@test "burn #45: a weekly dry tank reroutes to a reserve" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
case "$CLAUDE_CONFIG_DIR" in
  */T1) echo "You've hit your weekly limit · resets Jul 27 at 5am (Asia/Tokyo)" ;;
  *) printf 'done' > "$STUB_ARTIFACT" ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  clikae init claude T1
  clikae init claude T2
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  run clikae burn claude T1 --json --artifact "$STUB_ARTIFACT" --prompt x
  [ "$status" -eq 0 ]
  [[ "$output" == *'"tank":"T2"'* ]] || false
  [[ "$output" == *'"rerouted_from":["claude/T1"]'* ]] || false
}

@test "burn #44: tool-host outage retries same tank then reports infra" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$CODEX_HOME" >> "$STUB_ARGV_LOG"
echo 'timed out negotiating with the code-mode host'
exit 0
STUB
  export STUB_ARGV_LOG="$BATS_TEST_TMPDIR/attempts"
  clikae init codex T1
  clikae init codex T2
  run clikae burn codex T1 --json --infra-retries 2 --infra-delay 0 --artifact "$BATS_TEST_TMPDIR/out" --prompt x
  [ "$status" -ne 0 ]
  [[ "$output" == *'"reason":"infra"'* ]] || false
  [ "$(wc -l < "$STUB_ARGV_LOG" | tr -d ' ')" = 3 ]
  [ "$(sort -u "$STUB_ARGV_LOG")" = "$CLIKAE_HOME/profiles/codex/T1" ]
  [[ "$output" == *'"rerouted_from":[]'* ]] || false
  [[ "$output" != *'real task failure'* ]] || false
}


@test "burn #44: default backoff is 5 then 10 seconds and recovery stays on the same tank" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$CODEX_HOME" >> "$STUB_ARGV_LOG"
if [ "$(wc -l < "$STUB_ARGV_LOG")" -lt 3 ]; then
  echo 'failed to connect to the code-mode host'
else
  printf 'done' > "$STUB_ARTIFACT"
fi
STUB
  cat > "$BATS_TEST_TMPDIR/bin/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$STUB_DELAYS"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/sleep"
  export STUB_ARGV_LOG="$BATS_TEST_TMPDIR/attempts" STUB_DELAYS="$BATS_TEST_TMPDIR/delays"
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  clikae init codex T1
  clikae init codex T2
  run clikae burn codex T1 --json --no-reroute --artifact "$STUB_ARTIFACT" --prompt x
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DELAYS")" = $'5\n10' ]
  [ "$(wc -l < "$STUB_ARGV_LOG" | tr -d ' ')" = 3 ]
  [ "$(sort -u "$STUB_ARGV_LOG")" = "$CLIKAE_HOME/profiles/codex/T1" ]
  [[ "$output" == *'"artifact_bytes":4'* ]] || false
  [[ "$output" == *'"rerouted_from":[]'* ]] || false
}

@test "burn #44: zero retries reports infra without sleeping or marking dry" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$CODEX_HOME" >> "$STUB_ARGV_LOG"
echo 'connection to the tool host was closed'
exit 1
STUB
  export STUB_ARGV_LOG="$BATS_TEST_TMPDIR/attempts"
  clikae init codex T1
  run clikae burn codex T1 --json --infra-retries 0 --artifact "$BATS_TEST_TMPDIR/out" --prompt x
  [ "$status" -ne 0 ]
  [[ "$output" == *'"reason":"infra"'* ]] || false
  [ "$(wc -l < "$STUB_ARGV_LOG" | tr -d ' ')" = 1 ]
  _src_burn
  run dry_store_read codex T1
  [ "$status" -ne 0 ]
}

@test "burn #44: ordinary task errors are not infrastructure failures" {
  _src_burn
  local phrase
  for phrase in 'task timed out' 'failed to connect to database' 'weekly limit' 'connection refused'; do
    run _burn_output_infra "$phrase"
    [ "$status" -ne 0 ]
  done
}

# --- P2-5 (2026-09-08 review): the whitelist was hand-written, not drawn from
# a real corpus like limit.sh's — five plausible real tool-host failure
# sentences all NO-MATCHED (PROBE F), one of them by a single word
# ("waiting" vs "negotiating"). This feature could ship and never once fire on
# a real failure, silently falling back to the old behaviour, and nobody
# would notice.

@test "burn #44: real-shaped tool-host failure phrasings from the review corpus are recognized (P2-5)" {
  _src_burn
  local phrase
  for phrase in \
    'Error: MCP server "code-mode" connection closed' \
    'code-mode host exited unexpectedly' \
    'tool host handshake failed' \
    'timed out waiting for the code-mode host' \
    'Error connecting to tool host'
  do
    run _burn_output_infra "$phrase"
    [ "$status" -eq 0 ]
  done
}

# --- P1-2 (2026-09-08 ROUND-2 review): the widening above turned the two
# "host <gap> failure verb" alternatives into an unbounded prose catcher —
# `[^."]*` has no upper bound, so any sentence that mentions "tool host"
# somewhere and, later in the same period-free run, one of the failure verbs
# fired even when the two had nothing to do with each other (PROBE C-live in
# the review: an engine's genuine task-failure reply that merely explains a
# runbook section named after the tool host burned two extra full engine
# calls and mislabelled a real failure as infra). Every real corpus row —
# this round's and the last — has the verb within a handful of characters of
# "host"; bounding the gap keeps them matching while rejecting prose whose
# mention of the host and its failure verb are unrelated.

@test "burn #44: prose that merely mentions the tool host near an unrelated failure verb is not infra (P1-2 r2)" {
  _src_burn
  local phrase
  for phrase in \
    'The tool host section of the runbook explains why our Redis connection closed.' \
    'I checked the tool host docs; the websocket to the build server disconnected.' \
    'Note: the code-mode host chapter is fine, but the SSH handshake failed twice.' \
    'While the tool host was idle the database connection timed out.' \
    'Tests for the tool host retry path assert that the connection timed out branch fires.' \
    'I could not finish. The tool host section of the runbook explains why our Redis connection closed.'
  do
    run _burn_output_infra "$phrase"
    [ "$status" -ne 0 ]
  done
}

@test "burn #44: a genuine task failure whose reply names the tool host in passing is not rerouted as infra (P1-2 r2)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf "I could not finish. The tool host section of the runbook explains why our Redis connection closed.\n"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  clikae init claude T1
  run clikae burn claude T1 --json --infra-retries 2 --infra-delay 0 --artifact "$BATS_TEST_TMPDIR/out" --prompt "summarise the incident"
  [ "$status" -ne 0 ]
  [[ "$output" == *'"reason":"no fresh artifact and no limit"'* ]] || false
  [[ "$output" != *'"reason":"infra"'* ]] || false
}

@test "burn #44: invalid retry policy fails before launching" {
  _stub_burn_transport
  clikae init codex T1
  export STUB_ARGV_LOG="$BATS_TEST_TMPDIR/attempts"
  local value
  for value in -1 nope 11 999999999999999999999; do
    run clikae burn codex T1 --infra-retries "$value" --artifact "$BATS_TEST_TMPDIR/out" --prompt x
    [ "$status" -ne 0 ]
    [[ "$output" == *'--infra-retries must be'* ]] || false
  done
  [ ! -e "$STUB_ARGV_LOG" ]
}

@test "burn #43: long multiline prompt is stored with only 120 characters previewed" {
  _stub_burn_transport
  clikae init codex T1
  local prompt; prompt="$(printf '%0120d' 0)"$'\nPRIVATE-PROMPT-TAIL'
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out" --prompt "$prompt"
  [ "$status" -ne 0 ]
  [[ "$output" != *PRIVATE-PROMPT-TAIL* ]] || false
  [[ "$output" == *prompt.txt* ]] || false
  local saved; saved="$(find "$HOME/.clikae/logs" -name prompt.txt -print)"
  [ -f "$saved" ]
  [ "$(cat "$saved")" = "$prompt" ]
}

@test "burn #43: diagnostic tail does not repeat the engine's multiline prompt echo" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}"
echo 'task failed'
STUB
  clikae init codex T1
  local prompt; prompt="$(printf '%0120d' 0)"$'\nPRIVATE-PROMPT-TAIL'
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out" --prompt "$prompt"
  [ "$status" -ne 0 ]
  [[ "$output" != *PRIVATE-PROMPT-TAIL* ]] || false
  [[ "$output" == *'task failed'* ]] || false
  local saved; saved="$(find "$HOME/.clikae/logs" -name prompt.txt -print)"
  [ "$(stat -c '%a' "$saved" 2>/dev/null || stat -f '%Lp' "$saved")" = 600 ]
}

# --- P1-1 (2026-09-08 review): a FINISHED burn must not be discarded because
# the engine's own reply happens to contain a limit phrase. The task below is
# what a real runbook-about-quotas prompt provokes: the engine writes the
# artifact AND signs off with a sentence containing "weekly limit" — before the
# fix, the dry-string check ran BEFORE the artifact-freshness check and threw
# the finished work away, rerouting the same task onto a second account.

@test "burn #42: a finished task is not discarded because its OWN reply mentions a limit phrase" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%072d' 0 > "$STUB_ARTIFACT"
printf "I wrote the runbook. It explains what to do once you've hit your weekly limit.\n"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  clikae init claude C1
  clikae init claude C2
  run clikae burn claude C1 --json --artifact "$STUB_ARTIFACT" --prompt "write a runbook about usage limits"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || false
  [[ "$output" == *'"tank":"C1"'* ]] || false
  [[ "$output" == *'"rerouted_from":[]'* ]] || false
  [[ "$output" == *'"artifact_bytes":72'* ]] || false
}

@test "burn #42: --no-reroute also honours a fresh artifact over a limit phrase in the reply" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%072d' 0 > "$STUB_ARTIFACT"
printf "I wrote the runbook. It explains what to do once you've hit your weekly limit.\n"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  clikae init claude C1
  run clikae burn claude C1 --json --no-reroute --artifact "$STUB_ARTIFACT" --prompt "write a runbook about usage limits"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || false
  [[ "$output" == *'"reason":"artifact produced"'* ]] || false
}

# --- P2-2 (2026-09-08 ROUND-2 review): the artifact-wins-outcome fix just
# above unconditionally cleared the dry marker in its success branch — so a
# run that finishes with a partial artifact WHILE its own reply also shows a
# limit event happening right now turned the board's red dot green and
# dropped the vendor's reset phrase from JSON, even though the account is
# still genuinely out of fuel (review PROBE R: the same stub, only variance
# is whether it also wrote a few bytes before the limit line). The artifact
# must still win the OUTCOME (ok:true / reason: "artifact produced" —
# unchanged), but the limit/reset is real account state and must still be
# recorded and shown, not silently overwritten.

@test "burn #42/#45: a fresh artifact does not drop the reset phrase when the SAME reply also shows a limit (P2-2 r2)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
echo "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
printf 'ab' > "$STUB_ARTIFACT"
STUB
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  clikae init codex T1
  run clikae burn codex T1 --json --artifact "$STUB_ARTIFACT" --prompt x
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || false
  [[ "$output" == *'"reason":"artifact produced"'* ]] || false
  [[ "$output" == *'"reset":"Try again at Jul 7th, 2026 2:17 PM"'* ]] || false
}

@test "burn #42/#45: a fresh artifact with a concurrent limit event leaves the tank marked dry, not cleared (P2-2 r2)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
echo "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
printf 'ab' > "$STUB_ARTIFACT"
STUB
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  clikae init codex T1
  _src_burn
  dry_store_mark codex T1 "Try again at Jul 6th, 2026 2:17 PM"
  run clikae burn codex T1 --json --artifact "$STUB_ARTIFACT" --prompt x
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || false
  run dry_store_read codex T1
  [ "$status" -eq 0 ]
}

# --- P1-1 (2026-09-08 round-5 review): the r2/r3 tests above only ever used
# codex's "try again at …" grammar. limit_codex_reset (before this fix) only
# recognized that ONE grammar, so a genuine concurrent limit phrased with
# "resets …" (the repo's own 175-row real corpus is entirely this grammar)
# yielded an empty reset, limit_codex_output_dry's second gate then treated
# the whole event as not-dry, and the fresh-artifact branch — reading "not
# dry" as "safe to recover" — CLEARED a real, pre-existing marker instead of
# leaving it untouched (review PROBE H).

@test "burn #45: a fresh artifact with a concurrent GENUINE limit phrased as \"resets …\" leaves an EXISTING marker untouched (P1-1 r5)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
echo "You've hit your usage limit · resets 5am (Asia/Tokyo)"
printf 'ab' > "$STUB_ARTIFACT"
STUB
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  clikae init codex T1
  _src_burn
  dry_store_mark codex T1 "resets 5am (Asia/Tokyo)"
  run clikae burn codex T1 --json --artifact "$STUB_ARTIFACT" --prompt x
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || false
  [[ "$output" == *'"reset":"resets 5am (Asia/Tokyo)"'* ]] || false
  run dry_store_read codex T1
  [ "$status" -eq 0 ]                          # marker left in place, not cleared
}

@test "burn #42: a fresh artifact with NO limit in the reply still clears the dry marker (P2-2 r2 control)" {
  _stub_burn_transport
  clikae init codex T1
  _src_burn
  dry_store_mark codex T1 "Try again at Jul 6th, 2026 2:17 PM"
  run clikae burn codex T1 --json --artifact "$BATS_TEST_TMPDIR/out" -- run "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || false
  run dry_store_read codex T1
  [ "$status" -ne 0 ]
}

# --- P2-2 (2026-09-08 ROUND-3 review): limit_codex_output_dry — unlike
# claude's branch — was never anchored on a direct vendor report; it matches
# "hit your (usage|session) limit" bare, ANYWHERE in the reply. A codex task
# that merely TALKS ABOUT the limit while it SUCCEEDS made the r2 fix above
# call dry_store_mark on a healthy tank (limit_engine_detectable is false for
# codex, the only engine dry_store is for), and --json said nothing about it
# (ok:true, reset:null). dry_store.sh's own header promises "a successful run
# clears it explicitly" — a fresh artifact must never WRITE a new marker.

@test "burn #45: a successful codex burn that merely TALKS ABOUT the limit does not mark the tank dry (P2-2 r3, PROBE B)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'x' > "$STUB_ARTIFACT"
printf 'Done. The runbook now explains what to do once you hit your usage limit.\n'
STUB
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  clikae init codex T1
  _src_burn
  run dry_store_read codex T1
  [ "$status" -ne 0 ]                          # MARKER BEFORE: none
  run clikae burn codex T1 --json --artifact "$STUB_ARTIFACT" --prompt x
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || false
  [[ "$output" == *'"reason":"artifact produced"'* ]] || false
  run dry_store_read codex T1
  [ "$status" -ne 0 ]                          # MARKER AFTER: still none
}

@test "burn #45: a fresh artifact with a concurrent GENUINE limit event leaves an EXISTING marker untouched, but writes none of its own (P2-2 r3)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
echo "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
printf 'ab' > "$STUB_ARTIFACT"
STUB
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  clikae init codex T1
  clikae init codex T2
  _src_burn
  run dry_store_read codex T1
  [ "$status" -ne 0 ]                          # no pre-existing marker
  run clikae burn codex T1 --json --artifact "$STUB_ARTIFACT" --prompt x
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || false
  [[ "$output" == *'"reset":"Try again at Jul 7th, 2026 2:17 PM"'* ]] || false
  run dry_store_read codex T1
  [ "$status" -ne 0 ]                          # still none written
}

# --- P1-2 (2026-09-08 review): a tool-host phrase INSIDE THE PROMPT ECHO must
# not fire the infra classifier. codex (and other engines) can echo the user's
# own instructions back on stdout — PROBE A in the review used exactly this
# task text, and the un-redacted classifier burned two extra full engine calls
# plus 15s of sleep before mislabelling a real task failure as "infra".

@test "burn #44: a tool-host phrase inside the engine's PROMPT ECHO does not trigger infra retries" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}"
STUB
  clikae init codex T1
  local prompt='Review PR #44: it must retry when the engine prints "timed out negotiating with the code-mode host".'
  run clikae burn codex T1 --json --infra-retries 2 --infra-delay 0 --artifact "$BATS_TEST_TMPDIR/out" --prompt "$prompt"
  [ "$status" -ne 0 ]
  [[ "$output" == *'"reason":"no fresh artifact and no limit"'* ]] || false
  [[ "$output" != *'"reason":"infra"'* ]] || false
}

# --- P1-1 (2026-09-08 ROUND-2 review): the fix above only protected the
# --prompt/--prompt-file form. The raw `-- <engine argv...>` form ("the
# power-user way" — AGENTS.md/docs/orchestration.md's front door) never sets
# $prompt, so the substitution was skipped entirely on that path and round
# 1's P1-2 reappeared there verbatim (PROBE B in the review corpus: two
# extra full engine calls, a leaked task-text tail, and the wrong `reason`).

@test "burn #44: a tool-host phrase inside the engine's argv echo (raw -- form) does not trigger infra retries (P1-1 r2)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}"
STUB
  clikae init codex T1
  local task='Review PR #44: it must retry when the engine prints "timed out negotiating with the code-mode host".'
  run clikae burn codex T1 --json --infra-retries 2 --infra-delay 0 --artifact "$BATS_TEST_TMPDIR/out" \
    -- exec -C "$BATS_TEST_TMPDIR" -s workspace-write "$task"
  [ "$status" -ne 0 ]
  [[ "$output" == *'"reason":"no fresh artifact and no limit"'* ]] || false
  [[ "$output" != *'"reason":"infra"'* ]] || false
}

@test "burn #44: raw -- form diagnostic tail does not repeat the engine's own argv echo (P1-1 r2)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}"
echo 'task failed'
STUB
  clikae init codex T1
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out" \
    -- exec -C "$BATS_TEST_TMPDIR" -s workspace-write "PRIVATE-ARGV-SECRET-XYZ"
  [ "$status" -ne 0 ]
  [[ "$output" != *PRIVATE-ARGV-SECRET-XYZ* ]] || false
  [[ "$output" == *'task failed'* ]] || false
  [[ "$output" == *command.txt* ]] || false
}

# --- P1-2 (2026-09-08 round-5 review): _burn_redact_one fed its haystack to
# awk with RS="\x00" on the theory that a NUL byte can never appear in a
# bash string, so it was safe as a "no separator, one record" marker. False
# on macOS's own awk: it cannot hold a NUL in RS at all and silently falls
# back to PARAGRAPH mode, splitting on blank lines — routine engine output
# formatting — and gluing the pieces back together with NO separator, which
# both hides a real limit line (the `^` anchor no longer leads it) and can
# fabricate a false infra match (two unrelated sentences fused at the blank
# line). These are function-level, not end-to-end, because the bug is
# specific to the SHAPE of the haystack (a blank line) rather than any
# particular classifier.

@test "_burn_redact_full: a needle at or above the minimum length redacts across a blank-line capture (P1-2 r5)" {
  _src_burn
  prompt="this-is-the-secret-needle-value"
  cmd=()
  local text=$'Working on it.\n\nthis-is-the-secret-needle-value appears here.\n\nBye.'
  run _burn_redact_full "$text"
  [ "$status" -eq 0 ]
  [[ "$output" != *"this-is-the-secret-needle-value"* ]] || false
  # The blank lines (and the line structure the classifiers' `^` anchors
  # depend on) must survive — not be fused into one line.
  [[ "$output" == *$'Working on it.\n\n'* ]] || false
  [[ "$output" == *$'appears here.\n\nBye.'* ]] || false
}

@test "_burn_redact_full: a blank-line capture no longer fabricates a false infra match by fusing sentences (P1-2 r5, PROBE G3)" {
  _src_burn
  prompt=""
  cmd=("this-is-an-irrelevant-task-string-well-past-the-minimum-length")
  local text=$'I read docs/tool-host\n\nconnection closed unexpectedly in the unrelated log.'
  run _burn_output_infra "$(_burn_redact_full "$text")"
  [ "$status" -ne 0 ]
}

# --- P1-2 (2026-09-08 ROUND-3 review): pre-classification redaction ran bash's
# super-linear ${text//needle/repl} over the WHOLE captured output — measured
# 129x main's time on an 8 MB raw-argv capture (240s vs 1.9s), entirely AFTER
# the engine exits, invisible to --timeout. This is a timing GUARD, not a
# stopwatch on a specific number: the threshold is generous (a fixed, main-
# comparable multiple of the un-redacted case would be more precise but this
# machine's own load is not controlled for) — it exists to go red if the
# per-character substitution over the full capture ever comes back, not to
# pin an exact millisecond figure.

@test "burn #44: an 8MB capture still classifies fast (P1-2 timing guard)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
head -c 8000000 /dev/zero | tr '\0' 'x'
printf "\nYou've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM.\n"
STUB
  clikae init codex T1
  local t0 t1
  t0="$(date +%s)"
  run clikae burn codex T1 --json --no-reroute --artifact "$BATS_TEST_TMPDIR/out" \
    -- exec -C "$BATS_TEST_TMPDIR" -s workspace-write "refactor the parser"
  t1="$(date +%s)"
  [ "$status" -ne 0 ]
  [[ "$output" == *'"reason":"tank ran dry and --no-reroute is set"'* ]] || false
  [[ "$output" == *'"reset":"Try again at Jul 7th, 2026 2:17 PM"'* ]] || false
  local elapsed=$((t1 - t0))
  [ "$elapsed" -le 10 ] || { echo "classification took ${elapsed}s on an 8MB capture — expected single-digit seconds"; false; }
}

# --- P1-3 (2026-09-08 round-5 review): round-4's P2-1 fix (classification
# reads the full, untruncated capture) put the redaction awk loop's
# per-match `substr(t, i)` copy back in the hot path — and unlike P1-2
# above, that cost is per MATCH, not per byte: a capture with the needle
# repeated many times (exactly what a long build-log-style task echoes)
# reopened the same "burn looks hung after the engine exits" symptom in a
# new shape. Measured: a 4 MB capture with the redacted needle on every
# line (53774 hits) took 26.5s. The 8MB/0-hit guard above would NOT have
# caught this — it exercises the "no match" path, not "many matches".

@test "burn #44: a capture with the redacted needle repeated thousands of times still classifies fast (P1-3 timing guard, round-5)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 20000 ]; do
  printf 'line %d mentions /home/build/workspace/project-checkout-dir again\n' "$i"
  i=$((i + 1))
done
printf "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM.\n"
STUB
  clikae init codex T1
  local t0 t1
  t0="$(date +%s)"
  run clikae burn codex T1 --json --no-reroute --artifact "$BATS_TEST_TMPDIR/out" \
    -- exec -C /home/build/workspace/project-checkout-dir -s workspace-write "refactor the parser"
  t1="$(date +%s)"
  [ "$status" -ne 0 ]
  [[ "$output" == *'"reason":"tank ran dry and --no-reroute is set"'* ]] || false
  [[ "$output" == *'"reset":"Try again at Jul 7th, 2026 2:17 PM"'* ]] || false
  local elapsed=$((t1 - t0))
  [ "$elapsed" -le 10 ] || { echo "classification took ${elapsed}s on a dense-needle capture — expected single-digit seconds"; false; }
}

# --- P2-1 (2026-09-08 ROUND-3 review): the raw `-- <argv>` redaction had no
# minimum length or word/line boundary, so an everyday `-C .` deleted every
# period in the engine's reply — merging two sentences into one and letting
# the tool-host bounded-gap pattern jump across what used to be a sentence
# break (review's PROBE G). The reverse also held: a short task string could
# shred a genuine "…hit your usage limit…" line into unrecognizable pieces
# (PROBE F).

@test "burn #44: a day-to-day '-C .' no longer merges sentences into a false infra match (P2-1 r3, PROBE G)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$CODEX_HOME" >> "$STUB_ARGV_LOG"
printf 'I stopped early: the build step needs the tool host. The connection closed before I could retry, so nothing was written.\n'
STUB
  export STUB_ARGV_LOG="$BATS_TEST_TMPDIR/attempts"
  clikae init codex T1
  run clikae burn codex T1 --json --infra-retries 2 --infra-delay 0 --artifact "$BATS_TEST_TMPDIR/out" \
    -- exec -C . -s workspace-write "refactor the parser"
  [ "$status" -ne 0 ]
  [[ "$output" == *'"reason":"no fresh artifact and no limit"'* ]] || false
  [[ "$output" != *'"reason":"infra"'* ]] || false
  [ "$(wc -l < "$STUB_ARGV_LOG" | tr -d ' ')" = 1 ]     # no infra retries spent
}

@test "burn #44: a short raw-argv task string cannot shred a genuine limit line (P2-1 r3, PROBE F)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
case "$CODEX_HOME" in
  */T1) echo "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM." ;;
  *) printf 'done' > "$STUB_ARTIFACT" ;;
esac
STUB
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  clikae init codex T1
  clikae init codex T2
  run clikae burn codex T1 --json --artifact "$STUB_ARTIFACT" -- exec -s workspace-write "hit"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"tank":"T2"'* ]] || false
  [[ "$output" == *'"rerouted_from":["codex/T1"]'* ]] || false
}

# --- P2-1 (2026-09-08 review): #42's at-exit snapshot is narrower than main's
# old behaviour, which re-stat'd the artifact after the parent finished
# polling for completion — a write landing shortly after the engine's own
# process tree exits used to count and, on this branch, silently stopped
# counting (measured A/B against a main-branch clone, same stub, same params).

@test "burn #42: a write landing just after engine exit still counts as success (P2-1 grace window)" {
  _stub_burn_transport
  clikae init codex T1
  export STUB_LATE_WRITE_ARTIFACT="$BATS_TEST_TMPDIR/out"
  run clikae burn codex T1 --json --artifact "$STUB_LATE_WRITE_ARTIFACT" -- noop
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || false
  [[ "$output" == *'"reason":"artifact produced"'* ]] || false
  [[ "$output" == *'"artifact_bytes":4'* ]] || false
}

# --- P2-4 (2026-09-08 review): #43 made every burn write the FULL task text
# to a private run dir under ~/.clikae/logs so progress/diagnostics never
# repeat it — a real win over "it's in a log line", but nothing ever swept
# those dirs, trading a transient exposure for a permanent one. `clikae clean`
# has no notion of ~/.clikae/logs at all (`grep -c 'clikae/logs' → 0`).

@test "burn #43: a stale prompt-log run directory is swept past the retention window (P2-4)" {
  _stub_burn_transport
  clikae init codex T1
  mkdir -p "$HOME/.clikae/logs/burn-99999"
  printf 'stale task text' > "$HOME/.clikae/logs/burn-99999/prompt.txt"
  touch -t "$(date -v-8d '+%Y%m%d%H%M' 2>/dev/null || date -d '8 days ago' '+%Y%m%d%H%M')" \
    "$HOME/.clikae/logs/burn-99999"
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out" -- run "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.clikae/logs/burn-99999" ]
}

@test "burn #43: a recent prompt-log run directory survives the sweep (P2-4)" {
  _stub_burn_transport
  clikae init codex T1
  mkdir -p "$HOME/.clikae/logs/burn-88888"
  printf 'recent task text' > "$HOME/.clikae/logs/burn-88888/prompt.txt"
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out" -- run "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ -d "$HOME/.clikae/logs/burn-88888" ]
}

@test "burn #43: CLIKAE_BURN_LOG_RETENTION_DAYS=0 disables the sweep" {
  _stub_burn_transport
  clikae init codex T1
  mkdir -p "$HOME/.clikae/logs/burn-99999"
  printf 'stale task text' > "$HOME/.clikae/logs/burn-99999/prompt.txt"
  touch -t "$(date -v-30d '+%Y%m%d%H%M' 2>/dev/null || date -d '30 days ago' '+%Y%m%d%H%M')" \
    "$HOME/.clikae/logs/burn-99999"
  export CLIKAE_BURN_LOG_RETENTION_DAYS=0
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out" -- run "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ -d "$HOME/.clikae/logs/burn-99999" ]
}

# Early validation failures must leave both log directories private, even with
# a permissive caller umask.
@test "burn #43: ~/.clikae/logs is created 0700 even when burn fails before the engine loop (P2-3 r2)" {
  _stub_burn_transport
  clikae init codex T1
  rm -rf "$HOME/.clikae/logs"
  run bash -c 'umask 000; exec "$1" burn codex NOPE --artifact "$2" --prompt "x"' \
    _ "$CLIKAE_BIN" "$BATS_TEST_TMPDIR/out"
  [ "$status" -ne 0 ]
  [ -d "$HOME/.clikae/logs" ]
  local mode; mode="$(stat -c '%a' "$HOME/.clikae/logs" 2>/dev/null || stat -f '%Lp' "$HOME/.clikae/logs")"
  [ "$mode" = 700 ]
  local run_dirs=("$HOME/.clikae/logs"/burn-*)
  [ "${#run_dirs[@]}" -eq 1 ]
  [ -d "${run_dirs[0]}" ]
  [ "$(stat -c '%a' "${run_dirs[0]}" 2>/dev/null || stat -f '%Lp' "${run_dirs[0]}")" = 700 ]
  [ "$(stat -c '%a' "${run_dirs[0]}/prompt.txt" 2>/dev/null || stat -f '%Lp' "${run_dirs[0]}/prompt.txt")" = 600 ]
}
