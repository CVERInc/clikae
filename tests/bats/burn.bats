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
  # Generated Codex burns require a real git cwd (#66).
  git init -q "$BATS_TEST_TMPDIR"
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

# Stub `claude` and `grok` the same way _stub_codex stubs codex: log the full
# argv (one line per invocation) to $STUB_ARGV_LOG when set, and create
# $STUB_ARTIFACT so burn's own success check (the artifact, never the exit
# code) has something to find. Round-1 review (P2-1): these run the REAL
# `clikae burn <engine> …` entry point, not a stubbed validate_name — so a
# regression in the wiring between the parsed --permission and the composed
# engine argv (production call site, lib/commands/burn.sh's _burn_compose
# call) shows up here, not just in the lighter _permission_argv harness below.
_stub_claude() {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  cat > "$bin/claude" <<'STUB'
#!/usr/bin/env bash
[ -n "$STUB_ARGV_LOG" ] && printf '%s\n' "$*" >> "$STUB_ARGV_LOG"
[ -n "$STUB_ENV_LOG" ] && printf 'BG_WAIT=%s\n' "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS-unset}" >> "$STUB_ENV_LOG"
[ -n "$STUB_ARTIFACT" ] && : > "$STUB_ARTIFACT"
exit 0
STUB
  chmod +x "$bin/claude"
  PATH="$bin:$PATH"; export PATH
}

_stub_grok() {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  cat > "$bin/grok" <<'STUB'
#!/usr/bin/env bash
[ -n "$STUB_ARGV_LOG" ] && printf '%s\n' "$*" >> "$STUB_ARGV_LOG"
[ -n "$STUB_ARTIFACT" ] && : > "$STUB_ARTIFACT"
exit 0
STUB
  chmod +x "$bin/grok"
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

# --- #61 P2-5 (round-1 review): rc alone used to conflate "stopped on a dry
# tank because --no-reroute says so" with a REAL task failure — both were rc
# 1, exactly the ambiguity #61 opened against reroute exhaustion. The status
# file already wrote `state: dry` for --no-reroute's stop (unchanged by this
# PR), but the process's own rc disagreed with what it had just written to
# disk. Fixed: BOTH shapes a burn can stop dry without exhausting the whole
# reserve — --no-reroute here, and reroute exhaustion in the sibling test
# below — are $CLIKAE_BURN_RC_NO_TANK (2); only a genuine task failure stays
# 1. `reason` (not rc) is what still tells the two dry shapes apart — see
# docs/orchestration.md.
@test "burn #61 P2-5: --no-reroute's dry stop and a real task failure use DIFFERENT rc (2 vs 1)" {
  _stub_codex
  clikae init codex dry1
  clikae init codex fail1
  : > "$CLIKAE_HOME/profiles/codex/dry1/.dry"

  run clikae burn codex dry1 --artifact "$BATS_TEST_TMPDIR/d.md" --no-reroute -- run "$BATS_TEST_TMPDIR/d.md"
  [ "$status" -eq 2 ] || { echo "--no-reroute dry: got rc=$status, want 2"; echo "$output"; false; }

  run clikae burn codex fail1 --artifact "$BATS_TEST_TMPDIR/f.md" --no-reroute -- noop
  [ "$status" -eq 1 ] || { echo "real task failure: got rc=$status, want 1"; echo "$output"; false; }
}

@test "burn #61 P2-5: reroute exhaustion (no-tank-available) is the SAME rc as --no-reroute's dry stop" {
  _stub_codex
  clikae init codex T1
  clikae init codex T2
  : > "$CLIKAE_HOME/profiles/codex/T1/.dry"
  : > "$CLIKAE_HOME/profiles/codex/T2/.dry"
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" -- run "$BATS_TEST_TMPDIR/out.md"
  [ "$status" -eq 2 ] || { echo "got rc=$status, want 2 (CLIKAE_BURN_RC_NO_TANK)"; echo "$output"; false; }
}

# --- #61 round-3 P1-2 end-to-end: the one-time adoption sweep must close on
# the FIRST command run against the store, not just the first one that
# happens to walk it. Reproduces the review's own repro: an upgrade whose
# FIRST command is a successful burn (never walks the store — no reroute
# needed) must still close the window right there, so a directory dropped in
# afterward is never swept up and rerouted onto — issue #61's exact original
# symptom ("burned a few minutes failing to log in, reported as an
# indistinguishable generic task failure"), reproduced with a stub engine.
@test "burn #61 P1-2: a directory dropped in AFTER the first command is never rerouted onto" {
  _stub_codex
  # A pre-marker real tank — the shape an upgrade actually finds, not
  # `clikae init` (which stamps a marker immediately and would close the
  # window itself, hiding the bug this test exists to catch).
  mkdir -p "$CLIKAE_HOME/profiles/codex/A"
  printf 'x\n' > "$CLIKAE_HOME/profiles/codex/A/auth.json"
  rm -f "$CLIKAE_HOME/state/tanks-adopted-v1"
  [ ! -f "$CLIKAE_HOME/state/tanks-adopted-v1" ]

  # Step 1: the upgrade's first command — an ordinary successful burn. It
  # never walks the store (A is live, no reroute needed), but the hoist at
  # the top of bin/clikae still runs the sweep here, closing the window.
  run clikae burn codex A --artifact "$BATS_TEST_TMPDIR/out1.md" -- run "$BATS_TEST_TMPDIR/out1.md"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$BATS_TEST_TMPDIR/out1.md" ]
  [ -f "$CLIKAE_HOME/state/tanks-adopted-v1" ]
  [ -f "$CLIKAE_HOME/profiles/codex/A/.clikae-tank" ]

  # Step 2: something else drops a stray directory in — AFTER the window closed.
  mkdir -p "$CLIKAE_HOME/profiles/codex/hello"

  # Step 3: A runs dry; burn needs to reroute. `hello` is the only other
  # directory under codex/ but was never adopted — reroute must exhaust
  # (no-tank-available), never land on `hello`.
  : > "$CLIKAE_HOME/profiles/codex/A/.dry"
  run clikae burn codex A --json --artifact "$BATS_TEST_TMPDIR/out2.md" -- run "$BATS_TEST_TMPDIR/out2.md"
  [ "$status" -eq 2 ] || { echo "reroute landed somewhere instead of exhausting: $output"; false; }
  [[ "$output" == *'"reason":"no-tank-available"'* ]] || { echo "$output"; false; }
  [ ! -e "$CLIKAE_HOME/profiles/codex/hello/.clikae-tank" ]
  [ ! -f "$BATS_TEST_TMPDIR/out2.md" ]
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

@test "burn #61 P2-5: agy --no-reroute's dry stop is also rc 2, same as codex's" {
  _stub_agy_burn
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy default >/dev/null 2>&1
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli"
  : > "$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli/.dry"
  run clikae burn agy default --artifact "$BATS_TEST_TMPDIR/out.md" --no-reroute --prompt "do the thing"
  [ "$status" -eq 2 ] || { echo "got rc=$status, want 2 (CLIKAE_BURN_RC_NO_TANK)"; echo "$output"; false; }
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

# P2-2 (2026-09-09 round-1 review): the agy reroute walk never called
# burn_tank_busy — the ONE engine this matters most for, since agy's login
# is a single GLOBAL Keychain entry and the ~/.gemini swap is machine-wide
# and exclusive (agy structurally CANNOT run two tanks at once, unlike
# claude/codex where a busy tank is merely inconvenient to collide with).
@test "burn agy: the reroute walk SKIPS a busy tank instead of colliding with it" {
  _stub_agy_burn
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy third >/dev/null 2>&1   # "third" sorts before "work" (_agy_tank_names is glob order — alphabetical), so it's what the walk reaches FIRST
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli"
  : > "$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli/.dry"   # default is dry -> would normally reroute to third (alphabetically first)

  # "third" already has a burn running on it, per #41's own status files —
  # it must be SKIPPED, landing on "work" instead.
  local run_id="burn-agy-busy-$RANDOM"
  local d="$CLIKAE_HOME/logs/$run_id"
  mkdir -p "$d"
  local now; now="$(date +%s 2>/dev/null || echo 1)"
  printf '{"ok":null,"engine":"agy","tank":"third","artifact":null,"artifact_bytes":null,"reason":null,"reset":null,"rerouted_from":[],"elapsed_s":0,"run_id":"%s","state":"running","started_at":%s,"updated_at":%s,"pid":%s,"log":null,"reset_at":null}\n' \
    "$run_id" "$now" "$now" "$$" > "$d/status.json"

  local A="$BATS_TEST_TMPDIR/out.md"
  STUB_ARTIFACT="$A" run clikae burn agy default --artifact "$A" --prompt "do the thing"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$A" ] || false
  [[ "$output" == *"skipping agy/third"* ]] || false
  [[ "$output" == *"already running"* ]] || false
  [[ "$output" == *"Done on agy/work"* ]] || false
  [ "$(readlink "$HOME/.gemini")" = "$CLIKAE_HOME/profiles/antigravity/work" ]
}

@test "burn agy: --allow-active overrides the reroute-walk busy skip" {
  _stub_agy_burn
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli"
  : > "$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli/.dry"

  local run_id="burn-agy-busy2-$RANDOM"
  local d="$CLIKAE_HOME/logs/$run_id"
  mkdir -p "$d"
  local now; now="$(date +%s 2>/dev/null || echo 1)"
  printf '{"ok":null,"engine":"agy","tank":"work","artifact":null,"artifact_bytes":null,"reason":null,"reset":null,"rerouted_from":[],"elapsed_s":0,"run_id":"%s","state":"running","started_at":%s,"updated_at":%s,"pid":%s,"log":null,"reset_at":null}\n' \
    "$run_id" "$now" "$now" "$$" > "$d/status.json"

  local A="$BATS_TEST_TMPDIR/out.md"
  STUB_ARTIFACT="$A" run clikae burn agy default --artifact "$A" --prompt "do the thing" --allow-active
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$A" ] || false
  [[ "$output" != *"skipping agy/work"* ]] || false
  [[ "$output" == *"Done on agy/work"* ]] || false
}

# #63 round-6 P3-1 (G5b, r6 review): the automatic dry-walk hop used to pass
# --force-cockpit straight through to the gate it asks for the NEXT tank,
# even though the operator only named it for the STARTING target — so
# `burn agy default --force-cockpit`, with default dry and work the
# recorded cockpit, actually launched on agy/work. Help (burn.sh:101-102)
# and fix5's own report both promise auto-reroute never picks the cockpit,
# with or without this flag; this closes the one path where it did.
@test "burn agy: an automatic dry-walk hop still SKIPS the cockpit even with --force-cockpit (#63 r6 P3-1, G5b)" {
  _stub_agy_burn
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy work >/dev/null 2>&1   # default(active) + work
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli"
  : > "$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli/.dry"   # default is dry -> walk would hop to work
  mkdir -p "$CLIKAE_HOME/state"; printf 'antigravity/work\n' > "$CLIKAE_HOME/state/cockpit"   # work is the cockpit

  local A="$BATS_TEST_TMPDIR/out.md"
  STUB_ARTIFACT="$A" run clikae burn agy default --artifact "$A" --prompt "do the thing" --force-cockpit
  [ "$status" -ne 0 ]
  [[ "$output" == *"skipping agy/work"* ]] || false
  [[ "$output" == *"it is the cockpit"* ]] || false
  [[ "$output" != *"Done on agy/work"* ]] || false
  [ ! -f "$A" ]
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
  . "$CLIKAE_TEST_ROOT/lib/core/json.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/dry_store.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/burn_status.sh"   # #40: _burn_next_same_engine calls burn_tank_busy
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

# --- cockpit exclusion (#63 P3-5, round-4 review) ---
# The cockpit used to be protected only BY ACCIDENT, through P0: a cockpit
# tank normally has an interactive session sitting on it, so the live-
# session check happened to catch it. cockpit-guard.sh is a Claude Code
# PreToolUse hook — it never fires for a headless `clikae burn` run at all
# — so the moment that session isn't there, nothing stopped auto-reroute
# from dispatching straight onto the tank that's supposed to be doing the
# dispatching. These simulate NO live session anywhere (the accident-cover
# gone) to isolate the new, explicit rule from the old, accidental one.

@test "_burn_next_same_engine: refuses when the cockpit is the ONLY idle same-engine tank left (#63 r4 P3-5)" {
  _src_burn
  clikae init claude a; clikae init claude b
  mkdir -p "$CLIKAE_HOME/state"; printf 'claude/b\n' > "$CLIKAE_HOME/state/cockpit"
  live_dir_users() { :; }   # nobody interactive anywhere -- P0's accidental cover is gone
  local out; out="$(_burn_next_same_engine claude "claude/a" "" CLAUDE_CONFIG_DIR 0 2>/dev/null)"
  [ -z "$out" ]             # only 'b' remains in the reserve and it's the cockpit
}

@test "_burn_next_same_engine: --allow-active does NOT rescue the cockpit tank (#63 r4 P3-5)" {
  _src_burn
  clikae init claude a; clikae init claude b
  mkdir -p "$CLIKAE_HOME/state"; printf 'claude/b\n' > "$CLIKAE_HOME/state/cockpit"
  live_dir_users() { :; }
  local out; out="$(_burn_next_same_engine claude "claude/a" "" CLAUDE_CONFIG_DIR 1 2>/dev/null)"
  [ -z "$out" ]             # unlike P0, this exclusion is unconditional
}

@test "_burn_next_same_engine: a tank that is NOT the cockpit is still picked normally (#63 r4 P3-5)" {
  _src_burn
  clikae init claude a; clikae init claude b; clikae init claude c
  mkdir -p "$CLIKAE_HOME/state"; printf 'claude/b\n' > "$CLIKAE_HOME/state/cockpit"   # b is the cockpit; c is not
  live_dir_users() { :; }
  local out; out="$(_burn_next_same_engine claude "claude/a" "" CLAUDE_CONFIG_DIR 0 2>/dev/null)"
  [ "$out" = "c" ]
}

# --- launch gate (#63 round-5 P2-1) ---
# The exclusion above only ever covered AUTOMATIC reroute. The codex review
# reproduced `clikae burn claude <cockpit> --no-reroute …` entering the stub
# engine, writing the artifact, rc=0. Every launch now asks one gate.

@test "burn refuses an EXPLICIT target that is the recorded cockpit: rc≠0, engine never entered, no artifact (#63 r5 P2-1)" {
  _stub_claude
  clikae init claude A
  mkdir -p "$CLIKAE_HOME/state"; printf 'claude/A\n' > "$CLIKAE_HOME/state/cockpit"
  local art="$BATS_TEST_TMPDIR/artifact" L="$TEST_HOME/argv.log"
  STUB_ARTIFACT="$art" STUB_ARGV_LOG="$L" run clikae burn claude A --no-reroute --json --prompt 'review worktree' --artifact "$art"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cockpit-guard: refused — claude/A is the recorded cockpit"* ]] || false
  [[ "$output" == *"--force-cockpit"* ]] || false
  [ ! -e "$L" ]      # the stub engine was never started
  [ ! -e "$art" ]
}

@test "burn --force-cockpit runs on the cockpit and says so on stderr (#63 r5 P2-1)" {
  _stub_claude
  clikae init claude A
  mkdir -p "$CLIKAE_HOME/state"; printf 'claude/A\n' > "$CLIKAE_HOME/state/cockpit"
  local art="$BATS_TEST_TMPDIR/artifact" L="$TEST_HOME/argv.log"
  STUB_ARTIFACT="$art" STUB_ARGV_LOG="$L" run clikae burn claude A --no-reroute --force-cockpit --prompt 'review worktree' --artifact "$art"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--force-cockpit: burning claude/A even though it is the recorded cockpit"* ]] || false
  [ -s "$L" ]
  [ -e "$art" ]
}

@test "burn refuses a --to hop onto the cockpit after a dry tank, engine entered only for the first tank (#63 r5 P2-1)" {
  _stub_codex
  clikae init codex T1
  clikae init codex H
  : > "$CLIKAE_HOME/profiles/codex/T1/.dry"
  mkdir -p "$CLIKAE_HOME/state"; printf 'codex/H\n' > "$CLIKAE_HOME/state/cockpit"
  local A="$BATS_TEST_TMPDIR/out.md" L="$TEST_HOME/argv.log"
  STUB_ARGV_LOG="$L" run clikae burn codex T1 --artifact "$A" --to codex/H -- run "$A"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cockpit-guard: refused — codex/H is the recorded cockpit"* ]] || false
  [ "$(wc -l < "$L" | tr -d ' ')" = 1 ]   # T1 only
  [ ! -e "$A" ]
}

@test "burn refuses a tank that is a symlink alias of the cockpit (physical identity, #63 r5 P2-1)" {
  _stub_claude
  clikae init claude A
  ln -s "$CLIKAE_HOME/profiles/claude/A" "$CLIKAE_HOME/profiles/claude/alias"
  mkdir -p "$CLIKAE_HOME/state"; printf 'claude/A\n' > "$CLIKAE_HOME/state/cockpit"
  local art="$BATS_TEST_TMPDIR/artifact" L="$TEST_HOME/argv.log"
  STUB_ARTIFACT="$art" STUB_ARGV_LOG="$L" run clikae burn claude alias --no-reroute --prompt 'x' --artifact "$art"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cockpit-guard: refused"* ]] || false
  [ ! -e "$L" ]
  [ ! -e "$art" ]
}

# #63 round-6 P3-2 (G6, r6 review): a state file that EXISTS but does not
# read back cleanly used to make _cockpit_state_read return EMPTY —
# byte-for-byte identical to "no cockpit was ever recorded" — so the gate
# waved every burn through, including straight onto the tank the corrupt
# file was failing to protect. Three ways a state file stops parsing
# cleanly: unreadable (mode 000), an unsafe path (symlink), and malformed
# content (a stray CR). All three must now refuse EVERY burn, not just one
# naming the tank the file happened to (fail to) record.

@test "burn refuses ALL burns when the state file exists but is unreadable (mode 000, #63 r6 P3-2)" {
  _stub_claude
  clikae init claude A
  mkdir -p "$CLIKAE_HOME/state"; printf 'claude/A\n' > "$CLIKAE_HOME/state/cockpit"
  chmod 000 "$CLIKAE_HOME/state/cockpit"
  local art="$BATS_TEST_TMPDIR/artifact" L="$TEST_HOME/argv.log"
  STUB_ARTIFACT="$art" STUB_ARGV_LOG="$L" run clikae burn claude A --no-reroute --prompt 'x' --artifact "$art"
  chmod 600 "$CLIKAE_HOME/state/cockpit"   # so bats' own cleanup can remove it
  [ "$status" -ne 0 ]
  [[ "$output" == *"cockpit-guard: refused"* ]] || false
  [[ "$output" == *"state/cockpit"* ]] || false
  [[ "$output" == *"clikae doctor"* ]] || false
  [[ "$output" == *"cockpit --off"* ]] || false
  [ ! -e "$L" ]
  [ ! -e "$art" ]
}

@test "burn refuses ALL burns when the state file is a symlink (#63 r6 P3-2)" {
  _stub_claude
  clikae init claude A
  clikae init claude decoy
  mkdir -p "$CLIKAE_HOME/state"
  ln -s "$CLIKAE_HOME/profiles/claude/decoy/settings.json" "$CLIKAE_HOME/state/cockpit"
  local art="$BATS_TEST_TMPDIR/artifact" L="$TEST_HOME/argv.log"
  STUB_ARTIFACT="$art" STUB_ARGV_LOG="$L" run clikae burn claude A --no-reroute --prompt 'x' --artifact "$art"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cockpit-guard: refused"* ]] || false
  [ ! -e "$L" ]
  [ ! -e "$art" ]
}

@test "burn refuses ALL burns when the state file's content has a stray CR (#63 r6 P3-2)" {
  _stub_codex
  clikae init codex H
  mkdir -p "$CLIKAE_HOME/state"; printf 'codex/H\r\n' > "$CLIKAE_HOME/state/cockpit"
  local art="$BATS_TEST_TMPDIR/artifact" L="$TEST_HOME/argv.log"
  STUB_ARGV_LOG="$L" run clikae burn codex H --no-reroute --prompt 'x' --artifact "$art"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cockpit-guard: refused"* ]] || false
  [ ! -e "$L" ]
  [ ! -e "$art" ]
}

@test "burn is unaffected when the state file simply does not exist (#63 r6 P3-2, no regression)" {
  _stub_claude
  clikae init claude A
  # no $CLIKAE_HOME/state/cockpit at all
  local art="$BATS_TEST_TMPDIR/artifact" L="$TEST_HOME/argv.log"
  STUB_ARTIFACT="$art" STUB_ARGV_LOG="$L" run clikae burn claude A --no-reroute --prompt 'x' --artifact "$art"
  [ "$status" -eq 0 ]
  [ -e "$L" ]
  [ -e "$art" ]
}

@test "_burn_next_same_engine: with no cockpit recorded, nothing is excluded on that account (#63 r4 P3-5)" {
  _src_burn
  clikae init claude a; clikae init claude b
  live_dir_users() { :; }
  run _burn_next_same_engine claude "claude/a" "" CLAUDE_CONFIG_DIR 0
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

@test "burn's engine process gets the tmux guard first on PATH despite the compgen -e restore (P2-3)" {
  if ! command -v tmux >/dev/null 2>&1; then
    skip "tmux not installed"
  fi
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  export STUB_ARTIFACT="$A"

  # A stub codex that dumps its OWN process's PATH — the engine burn's
  # wrapper script actually execs, downstream of the `compgen -e` restore
  # that P2-3 (review round 1) found clobbers whatever tmux_spawn_session put
  # there. This test's own PATH (below) deliberately has NO shim on it — the
  # shape of an unattended `clikae burn` (cron, CI, a plain shell that never
  # ran through tmux_spawn_session), which is burn's actual home turf and
  # exactly what `compgen -e` captures and restores.
  #
  # 🔴 STRIP IT, DON'T SKIP ON IT (P3, clikae#97 review round 2). A `skip`
  # gated on "the caller's PATH happens not to have the shim" is a premise
  # that only holds by ACCIDENT of how this suite is invoked today (bats'
  # own helpers.bash and this file each prepend their own bin dir ahead of
  # it) — and the one direction this PR actually points, running the suite
  # from inside a clikae tank, is exactly the direction that accident stops
  # holding. A self-skipping premise check silently stops covering the
  # regression the moment it would start firing. Stripping the shim entry
  # instead of trusting it was never there keeps this test exercising the
  # `compgen -e` restore unconditionally, whichever PATH invoked bats.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat << 'STUB' > "$BATS_TEST_TMPDIR/bin/codex"
#!/usr/bin/env bash
printf '%s' "$PATH" > "$STUB_ARTIFACT"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/codex"
  local caller_path="$PATH"
  case "$caller_path" in
    "$CLIKAE_LIB/shims:"*) caller_path="${caller_path#"$CLIKAE_LIB/shims:"}" ;;
  esac
  export PATH="$BATS_TEST_TMPDIR/bin:$caller_path"

  run clikae burn codex T1 --artifact "$A" --prompt "dump my PATH"
  [ "$status" -eq 0 ]
  [ -f "$A" ]
  run cat "$A"
  case "$output" in
    "$CLIKAE_LIB/shims:"*) : ;;
    *) echo "engine process PATH: $output"; false ;;
  esac
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
  run declare -F adapter_burn_flags # gh must NOT have inherited it
  [ "$status" -ne 0 ]
  # P3-5 (#81 round-1 fix review): matches the line above — `! cmd` (like a
  # bare `[[ ]]`) is exempt from `set -e`, so a failing bare assertion here
  # would be silently ignored mid-body, not just stylistically inconsistent
  # with its neighbour.
  run declare -F adapter_audit_flags
  [ "$status" -ne 0 ]
}

# P1-1 (2026-09-12 round-2 review): adapter_meta_permission_modes (claude.sh,
# #60's --permission gate) was added to claude but never to adapter_loader's
# unset list — a codex/grok load right after claude's kept "seeing" claude's
# hook via declare -F, so burn.sh:508's capability gate (permission_set=1 AND
# no adapter_meta_permission_modes) silently believed the new engine mapped
# --permission when it never defined the hook at all. Same shape as the
# leak-guard above, scoped to the one hook this PR introduced.
@test "adapter_meta_permission_modes does NOT leak across adapters (leak-guard)" {
  _src_burn
  load_adapter claude
  declare -F adapter_meta_permission_modes >/dev/null   # claude HAS it
  load_adapter codex
  ! declare -F adapter_meta_permission_modes >/dev/null || false # codex must NOT have inherited it
  load_adapter claude
  load_adapter grok
  ! declare -F adapter_meta_permission_modes >/dev/null # grok must NOT have inherited it
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

@test "burn --json: a HEALTHY codex run carries its own proactive reset, not null" {
  # The literal bug report: `clikae burn codex … --json` printed "reset":null
  # on a run that never hit anything, even though codex's own rollout already
  # knew when its 5h/weekly windows reset (see limit_codex_status).
  _stub_codex
  clikae init codex T1
  local dir="$CLIKAE_HOME/profiles/codex/T1"
  mkdir -p "$dir/sessions/2026/09/10"
  printf '%s\n' \
    '{"timestamp": "2026-09-10T09:00:00.000Z", "type": "event_msg", "payload": {"type": "token_count", "info": {}, "rate_limits": {"limit_id": "codex", "limit_name": null, "primary": {"used_percent": 10.0, "window_minutes": 300, "resets_at": 4102444800}, "secondary": {"used_percent": 96.0, "window_minutes": 10080, "resets_at": 4103049600}, "credits": {"has_credits": false}}}}' \
    > "$dir/sessions/2026/09/10/rollout-a.jsonl"
  clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" --json -- run "$BATS_TEST_TMPDIR/out.md" \
    > "$BATS_TEST_TMPDIR/j.txt" 2>/dev/null
  run python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['ok'], d['reset'])" "$BATS_TEST_TMPDIR/j.txt"
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/j.txt"; false; }
  [[ "$output" == "True resets "* ]] || { echo "got: $output"; false; }
  [[ "$output" != "True None" ]] || { echo "reset was null: $output"; false; }
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
  [[ "$output" == "False no-tank-available" ]] || { echo "got: $output"; false; }
}

# --- #61: a stray lock file/sidecar/dotdir/dangling symlink in the profiles
# dir must never be mistaken for a reroute target, and exhausting the real
# reserve must say so distinctly (reason "no-tank-available", not a task
# failure) — both in prose and in --json, with a documented, distinguishable
# exit code. Fixture mirrors the issue exactly: x/ (dry), hello/ (skipped —
# another burn is already running on it, #40), hello.lock (a FILE), ghost (a
# dangling symlink), .cache (a dotdir), world.lock/ (a DIRECTORY-shaped
# sidecar), a dir under an unknown engine, and zzempty/ (an empty dir with no
# lock-ish name at all).
#
# round-1 review P1-2: the negative control in the PR body ("delete this
# PR's two new lines and both new tests go red") moved TWO variables at
# once — the guard AND main's own pre-existing `for … in "$cli_dir"*/` +
# `[ -d "$profile_path" ] || continue`. hello.lock (a plain FILE), ghost (a
# dangling symlink) and .cache (a dotdir, which that glob never even yields
# — bash doesn't match a leading dot without dotglob) were ALL already
# stopped by that pre-existing glob, with or without this PR's own guard —
# so the control's red proved main's glob works, not that this PR's code
# does anything. The one case that actually needs a directory-aware guard —
# a directory that PASSES the `[ -d ]` glob and has no marker/fingerprint —
# had no fixture at all. world.lock/ (a lock-SHAPED name, but a directory),
# an unknown-engine dir, and zzempty/ (no lock-ish name whatsoever — the
# reviewer's own R61-D reproduction, round-1 P1-3) are that case, three ways.
#
# round-1 review P1-1: hello's "skip" signal used to be a real background
# `env CODEX_HOME=… sleep 60 &`, relying on live_dir_users' env-of-process
# scan (lib/core/proc.sh) to see it. That scan is HONEST about not working
# for a no-tty process on macOS (proc.sh:12-21, "Verified 2026-06-04: … a
# no-tty `sleep` with the same env is listed but its env is not") — the exact
# shape this fixture used, so on macOS hello was never skipped, burn
# succeeded on it, and this test's rc=2 / no-tank-available / never-names-a-
# non-tank assertions never ran there at all (`bats (macos-latest)` fail,
# `not ok 309`). Fixed by using a DIFFERENT, OS-agnostic "skip" signal:
# #40's own burn_tank_busy (lib/core/burn_status.sh) reads a status.json, not
# a process environment — a fake OTHER burn's status file, `state: running`
# on codex/hello with this test's own (real, alive) pid, produces the same
# "another burn is already running on it" skip on every platform bats runs
# on, with no process to spawn or clean up.
@test "burn --json: reroute never names a lock file, dangling symlink, or dotdir; exhaustion is no-tank-available (#61)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _stub_codex
  clikae init codex x
  clikae init codex hello
  : > "$CLIKAE_HOME/profiles/codex/x/.dry"

  # hello: SKIPPED because burn_tank_busy sees another burn already running
  # on codex/hello — the pid is this test's own (kill -0 must see it alive
  # for the whole call), so nothing needs spawning or killing.
  local fake_run="$HOME/.clikae/logs/burn-faketest61"
  mkdir -p "$fake_run"
  printf '{"ok":null,"engine":"codex","tank":"hello","artifact":null,"artifact_bytes":null,"reason":null,"reset":null,"rerouted_from":[],"elapsed_s":0,"run_id":"burn-faketest61","state":"running","started_at":%s,"updated_at":%s,"pid":%s,"log":null,"reset_at":null}' \
    "$(date +%s)" "$(date +%s)" "$$" > "$fake_run/status.json"

  : > "$CLIKAE_HOME/profiles/codex/hello.lock"
  ln -s /nonexistent "$CLIKAE_HOME/profiles/codex/ghost"
  mkdir -p "$CLIKAE_HOME/profiles/codex/.cache"
  # round-1 P1-2: these three DO pass main's own `*/ ` + `[ -d ]` glob — only
  # this PR's marker/fingerprint guard (round-1 P1-3) keeps them out.
  mkdir -p "$CLIKAE_HOME/profiles/codex/world.lock"       # directory-shaped sidecar
  mkdir -p "$CLIKAE_HOME/profiles/nonsense-engine/ghostly" # unknown-engine dir
  mkdir -p "$CLIKAE_HOME/profiles/codex/zzempty"           # empty dir, no lock-ish name

  local A="$BATS_TEST_TMPDIR/out.md" rc=0
  clikae burn codex x --artifact "$A" --json -- run "$A" \
    > "$BATS_TEST_TMPDIR/j.txt" 2> "$BATS_TEST_TMPDIR/err.txt" || rc=$?

  [ "$rc" -eq 2 ] || { echo "rc=$rc"; cat "$BATS_TEST_TMPDIR/err.txt"; false; }
  [ ! -e "$A" ]

  run jq -e '.ok == false and .reason == "no-tank-available"' "$BATS_TEST_TMPDIR/j.txt"
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/j.txt"; false; }
  # reset is x's own — the only tank that actually went dry (hello was
  # skipped, never judged dry; the fixture's non-tanks were never candidates).
  run jq -e '.reset | test("Jul 7th, 2026")' "$BATS_TEST_TMPDIR/j.txt"
  [ "$status" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/j.txt"; false; }
  run jq -e '.tank == "hello.lock" or .tank == "ghost" or .tank == ".cache" or .tank == "world.lock" or .tank == "zzempty" or .engine == "nonsense-engine"' "$BATS_TEST_TMPDIR/j.txt"
  [ "$status" -eq 1 ] || { echo "reroute named a non-tank: $(cat "$BATS_TEST_TMPDIR/j.txt")"; false; }

  grep -qF "hello.lock" "$BATS_TEST_TMPDIR/err.txt" && { echo "prose mentioned hello.lock"; false; }
  grep -qF "codex/ghost" "$BATS_TEST_TMPDIR/err.txt" && { echo "prose mentioned ghost"; false; }
  grep -qF "codex/.cache" "$BATS_TEST_TMPDIR/err.txt" && { echo "prose mentioned .cache"; false; }
  grep -qF "codex/world.lock" "$BATS_TEST_TMPDIR/err.txt" && { echo "prose mentioned world.lock"; false; }
  grep -qF "codex/zzempty" "$BATS_TEST_TMPDIR/err.txt" && { echo "prose mentioned zzempty"; false; }
  grep -qF "nonsense-engine" "$BATS_TEST_TMPDIR/err.txt" && { echo "prose mentioned nonsense-engine"; false; }
  true
}

# --- #61 P2-7 (round-1 review): the earliest-reset tracking added alongside
# the reroute fix (_burn_dry_epoch + the earliest_epoch/earliest_reset pair,
# burn.sh:404-412/2709-2716) was correct but UNTESTED — the PR's own fixture
# only ever sent one dry tank through the walk, so "track the earliest
# across every hop" and the old "${reset:-}" (this hop's own) produce
# byte-identical output on one hop; nothing distinguished them. Three tanks,
# resets visited out of order, pin the actual logic instead of a case it
# happens to also satisfy.
_stub_codex_dry_resets() {
  # $1/$2/$3 = the reset clause (after "Try again at ") for T1/T2/T3 — each
  # always reports dry (unconditionally, no .dry marker needed: the fixture
  # IS three dry tanks, there is no live outcome to also stub).
  git init -q "$BATS_TEST_TMPDIR"
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/codex" <<STUB
#!/usr/bin/env bash
tank="\${CODEX_HOME##*/}"
case "\$tank" in
  T1) echo "You've hit your usage limit. Try again at $1." ;;
  T2) echo "You've hit your usage limit. Try again at $2." ;;
  T3) echo "You've hit your usage limit. Try again at $3." ;;
esac
exit 0
STUB
  chmod +x "$bin/codex"
  PATH="$bin:$PATH"; export PATH
}

@test "burn #61 P2-7: earliest parseable reset wins across three dry tanks, visited out of order" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  # Visit order T1 -> T2 -> T3; resets Jul 9 / Jul 7 / Jul 8 — the EARLIEST
  # (Jul 7) is the SECOND hop, not the first or the last, so picking "this
  # hop's own" or "the last hop's" would both silently pass a naive fixture.
  _stub_codex_dry_resets "Jul 9th, 2026 2:17 PM" "Jul 7th, 2026 2:17 PM" "Jul 8th, 2026 2:17 PM"
  clikae init codex T1; clikae init codex T2; clikae init codex T3
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" --json -- run "$BATS_TEST_TMPDIR/out.md"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'"reason":"no-tank-available"'* ]] || { echo "$output"; false; }
  [[ "$output" == *'"reset":"Try again at Jul 7th, 2026 2:17 PM"'* ]] || { echo "$output"; false; }
}

@test "burn #61 P2-7: an unparseable reset mid-walk is skipped — earliest of the PARSEABLE ones wins" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  # T2 (the earliest-VISITED, were it parseable) reports dry with a reset
  # clause limit_codex_reset can still extract (non-empty, so the tank is
  # still correctly classified dry — round-4 review P2-2's contract) but
  # limit_reset_epoch cannot turn into an epoch. It must be skipped for
  # RANKING purposes without being misread as a task failure: T3 (Jul 8,
  # parseable) must win over both T1 (Jul 9) and T2 (unparseable).
  _stub_codex_dry_resets "Jul 9th, 2026 2:17 PM" "some undetermined future time" "Jul 8th, 2026 2:17 PM"
  clikae init codex T1; clikae init codex T2; clikae init codex T3
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" --json -- run "$BATS_TEST_TMPDIR/out.md"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'"reason":"no-tank-available"'* ]] || { echo "$output"; false; }
  [[ "$output" == *'"reset":"Try again at Jul 8th, 2026 2:17 PM"'* ]] || { echo "$output"; false; }
}

@test "burn #61 P2-7: every dry tank's reset is unparseable -> reset is null, not a stale/wrong phrase" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _stub_codex_dry_resets "some undetermined time" "whenever it feels like it" "not a real date at all"
  clikae init codex T1; clikae init codex T2; clikae init codex T3
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" --json -- run "$BATS_TEST_TMPDIR/out.md"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'"reason":"no-tank-available"'* ]] || { echo "$output"; false; }
  [[ "$output" == *'"reset":null'* ]] || { echo "$output"; false; }
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
    # P1-1 (clikae#97 review round 1): the pane's start command is now
    # `env PATH=<shim dir>:$PATH bash "<wrapper>"`, not bare `bash "<wrapper>"`
    # — match the substring wherever it lands, not just at the start of $arg.
    *'bash "'*)
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
  [[ "$output" != *'"reason":"no-tank-available"'* ]] || false   # #61 round-1 P2-4: this used to compare against a retired string (main renamed it to no-tank-available long before this PR) that could never appear, so the assertion was unconditionally true no matter what burn did
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
  [[ "$output" != *'"reason":"no-tank-available"'* ]] || false   # #61 round-1 P2-4: this used to compare against a retired string (main renamed it to no-tank-available long before this PR) that could never appear, so the assertion was unconditionally true no matter what burn did
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
  # A 120-char filler arg pushes the secret past the "preview:" line's own
  # 120-char cutoff (see burn #43's "only 120 characters previewed" test,
  # same technique) — without it, whether the secret survives inside that
  # window depends on $BATS_TEST_TMPDIR's own length, which varies enough by
  # platform (short on ubuntu-latest CI, long on macOS) to make this
  # assertion pass or fail on the SAME code. Confirmed by CI run 34276613681:
  # the diagnostic tail this test targets was already correctly redacted to
  # "[prompt: …/command.txt]"; only the unrelated, size-capped preview line
  # (#43's contract, not #47's) leaked, because this fixture never padded it.
  local filler; filler="$(printf '%0120d' 0)"
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out" \
    -- exec -C "$BATS_TEST_TMPDIR" -s workspace-write "$filler" "PRIVATE-ARGV-SECRET-XYZ"
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

# --- P3-1 (round-3 fix review, this PR): `_burn_redact_full` used to
# `return 0` regardless of whether its own `perl` invocation actually ran —
# a needle list too large for perl's exec to accept at all (E2BIG, the #99
# shape: a >128 KiB --prompt-file) prints NOTHING on stdout and now returns
# 1 instead, so a caller can tell "redacted to nothing" apart from "the
# redaction tool itself crashed". A real E2BIG needs an OS-specific argv
# ceiling to reproduce; a `perl` stub that fails to run proves the SAME
# code path (PIPESTATUS[1] != 0) without depending on that ceiling.

@test "_burn_redact_full: perl failing to run is reported via a non-zero return, not a silent empty success (P3-1 r3)" {
  _src_burn
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  cat > "$BATS_TEST_TMPDIR/fakebin/perl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$BATS_TEST_TMPDIR/fakebin/perl"
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH"
  prompt="this-is-the-secret-needle-value"
  cmd=()
  run _burn_redact_full "some text with this-is-the-secret-needle-value inside"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "burn #99 (P3-1 r3): when redaction itself fails, the fast-failure reason says so distinctly, not 'output redacted'" {
  _stub_burn_transport
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  cat > "$BATS_TEST_TMPDIR/fakebin/perl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$BATS_TEST_TMPDIR/fakebin/perl"
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
echo "some ordinary diagnostic line, unrelated to any prompt echo" >&2
exit 3
STUB
  clikae init codex T1
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" run clikae burn codex T1 --json --no-reroute \
    --artifact "$BATS_TEST_TMPDIR/out" --prompt "this-is-the-secret-needle-value-in-the-prompt" \
    -- exec -C "$BATS_TEST_TMPDIR" -s workspace-write "refactor the parser"
  [ "$status" -ne 0 ]
  [[ "$output" == *'"reason":"engine exited rc=3, output could not be redacted"'* ]] || false
  [[ "$output" != *'"reason":"engine exited rc=3, output redacted"'* ]] || false
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

# P1-1 (round-3 fix review, this PR): the guard above only exercises the
# HIT path (an anchor line found near the tail) — every healthy run with NO
# limit line anywhere pays the SAME cost on the way to deciding that (the
# fallback that tests every adjacent line pair for a split anchor phrase).
# Round-2's `${line%$'\r'}` per-line CR strip was O(n^2) on both paths;
# measured 727x slower at 2 MB even near-idle load (REVIEW-stderr81-r3.md
# P1-1). This is the everyday case — a task that just finishes — so it must
# stay fast even though nothing was ever going to match.
@test "burn #44: an 8MB HEALTHY capture (no limit line at all) still classifies fast (P1-1 r3 timing guard)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
head -c 8000000 /dev/zero | tr '\0' 'x'
printf '\ndone.\n'
STUB
  clikae init codex T1
  local t0 t1
  t0="$(date +%s)"
  run clikae burn codex T1 --json --no-reroute --artifact "$BATS_TEST_TMPDIR/out" \
    -- exec -C "$BATS_TEST_TMPDIR" -s workspace-write "refactor the parser"
  t1="$(date +%s)"
  # No artifact was written and no limit line is in the reply — a real task
  # failure, not dry. The behavioral shape isn't the point of this guard,
  # the WALL TIME is.
  [[ "$output" == *'"ok":false'* ]] || false
  local elapsed=$((t1 - t0))
  [ "$elapsed" -le 10 ] || { echo "classification took ${elapsed}s on a healthy 8MB capture — expected single-digit seconds"; false; }
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

# P3-3 (2026-09-13 fix-round-3 review): `watch-github-*` run dirs had ONLY
# a 200-directory count cap (_wg_runs_rotate), no day-based retention —
# this sweep now globs them too, same policy as burn's own.
@test "burn #43/P3-3: a stale watch-github-* run directory is ALSO swept (same sweep, same policy)" {
  _stub_burn_transport
  clikae init codex T1
  mkdir -p "$HOME/.clikae/logs/watch-github-CVERInc-99999"
  printf '{"ok":true}' > "$HOME/.clikae/logs/watch-github-CVERInc-99999/status.json"
  touch -t "$(date -v-8d '+%Y%m%d%H%M' 2>/dev/null || date -d '8 days ago' '+%Y%m%d%H%M')" \
    "$HOME/.clikae/logs/watch-github-CVERInc-99999"
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out" -- run "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.clikae/logs/watch-github-CVERInc-99999" ]
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

# Stop at validation, after real option parsing, and compose with the real
# adapter. This tests CLI-to-adapter wiring without starting a burn transport.
_permission_argv() (
  _src_burn
  # cmd_burn supplies these locals through Bash dynamic scope.
  # shellcheck disable=SC2154
  validate_name() {
    load_adapter "$cli"
    _burn_compose "$prompt" "${#cmd[@]}" "${cmd[@]}" -- "${add_dirs[@]}"
    printf '%s\0' "${BURN_ARGV[@]}" > "$permission_argv_file"
    exit 0
  }
  cmd_burn "$@"
)

@test "burn #60: default composed argv is byte-identical to explicit acceptEdits" {
  local prompt=$'build with spaces\nand a newline'
  local permission_argv_file="$TEST_HOME/default.argv"
  _permission_argv claude T1 --artifact out --prompt "$prompt" --add-dir '/workspace with spaces' -- --verbose
  permission_argv_file="$TEST_HOME/explicit.argv"
  _permission_argv claude T1 --artifact out --permission acceptEdits --prompt "$prompt" --add-dir '/workspace with spaces' -- --verbose
  printf '%s\0' -p "$prompt" --permission-mode acceptEdits --add-dir '/workspace with spaces' --verbose > "$TEST_HOME/expected.argv"
  cmp "$TEST_HOME/default.argv" "$TEST_HOME/explicit.argv"
  cmp "$TEST_HOME/default.argv" "$TEST_HOME/expected.argv"
}

@test "burn #60: claude auto composes the selected permission mode" {
  local permission_argv_file="$TEST_HOME/auto.argv"
  _permission_argv claude T1 --artifact out --permission auto --prompt 'build and review' --add-dir /workspace
  printf '%s\0' -p 'build and review' --permission-mode auto --add-dir /workspace > "$TEST_HOME/expected.argv"
  cmp "$TEST_HOME/auto.argv" "$TEST_HOME/expected.argv"
}

@test "burn #60: codex auto degrades once on stderr with unchanged argv" {
  # #66 round-1's codex git-cwd check now fires before validate_name (the
  # stub _permission_argv installs), so add_dirs[0] must be a real git work
  # tree here — a bare literal path like the claude test above uses would
  # fail that check before ever reaching the --permission composition logic.
  local ws="$BATS_TEST_TMPDIR/workspace"; mkdir -p "$ws"; git init -q "$ws"
  local permission_argv_file="$TEST_HOME/default.argv"
  _permission_argv codex T1 --artifact out --prompt 'build and review' --add-dir "$ws"
  permission_argv_file="$TEST_HOME/auto.argv"
  _permission_argv codex T1 --artifact out --permission auto --prompt 'build and review' --add-dir "$ws" 2> "$TEST_HOME/warning"
  cmp "$TEST_HOME/default.argv" "$TEST_HOME/auto.argv"
  [ "$(wc -l < "$TEST_HOME/warning" | tr -d ' ')" = 1 ]
  grep -F 'codex has no equivalent for --permission auto; keeping its existing burn flags.' "$TEST_HOME/warning"
}

@test "burn #60: invalid or missing permission is refused with one usage line" {
  local value
  for value in bypassPermissions AUTO ''; do
    run clikae burn claude T1 --permission "$value"
    [ "$status" -ne 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == *'--permission must be acceptEdits or auto'* ]] || false
  done
  run clikae burn claude T1 --permission
  [ "$status" -ne 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *'--permission must be acceptEdits or auto'* ]] || false
}

# --- P2-1 (round-1 review): the four tests above stop at a stubbed
# validate_name, which calls _burn_compose ITSELF — before cmd_burn's own real
# call site (lib/commands/burn.sh's _burn_compose call) ever runs. That proves
# the parse-layer local is right and adapter_burn_flags honours it, but not
# that cmd_burn's production wiring actually carries it through. These two run
# the real `clikae burn claude … --prompt` entry point end to end with a
# stubbed `claude` binary (mirroring codex's STUB_ARGV_LOG convention above).
@test "burn #60 (production path): default composes acceptEdits exactly once" {
  _stub_claude
  clikae init claude T1
  local A="$BATS_TEST_TMPDIR/out.md" L="$TEST_HOME/argv.log"
  STUB_ARTIFACT="$A" STUB_ARGV_LOG="$L" run clikae burn claude T1 --artifact "$A" --prompt 'build and review' --add-dir /workspace
  [ "$status" -eq 0 ]
  [ -f "$A" ]
  [ "$(grep -o -- '--permission-mode acceptEdits' "$L" | wc -l | tr -d ' ')" = 1 ]
  ! grep -q -- '--permission-mode auto' "$L"
}

@test "burn #60 (production path): --permission auto composes auto exactly once" {
  _stub_claude
  clikae init claude T1
  local A="$BATS_TEST_TMPDIR/out.md" L="$TEST_HOME/argv.log"
  STUB_ARTIFACT="$A" STUB_ARGV_LOG="$L" run clikae burn claude T1 --artifact "$A" --permission auto --prompt 'build and review' --add-dir /workspace
  [ "$status" -eq 0 ]
  [ -f "$A" ]
  [ "$(grep -o -- '--permission-mode auto' "$L" | wc -l | tr -d ' ')" = 1 ]
  ! grep -q -- '--permission-mode acceptEdits' "$L"
}

@test "burn #60: codex acceptEdits (explicit) also degrades once on stderr with unchanged argv" {
  # Same reason as the auto-degrade test above: add_dirs[0] must be a real
  # git work tree for the #66 round-1 codex git-cwd check to pass.
  local ws="$BATS_TEST_TMPDIR/workspace"; mkdir -p "$ws"; git init -q "$ws"
  local permission_argv_file="$TEST_HOME/default.argv"
  _permission_argv codex T1 --artifact out --prompt 'build and review' --add-dir "$ws"
  permission_argv_file="$TEST_HOME/accept.argv"
  _permission_argv codex T1 --artifact out --permission acceptEdits --prompt 'build and review' --add-dir "$ws" 2> "$TEST_HOME/warning"
  cmp "$TEST_HOME/default.argv" "$TEST_HOME/accept.argv"
  [ "$(wc -l < "$TEST_HOME/warning" | tr -d ' ')" = 1 ]
  grep -F 'codex has no equivalent for --permission acceptEdits; keeping its existing burn flags.' "$TEST_HOME/warning"
}

# --- P2-2 (round-1 review): grok ships its OWN --permission-mode (always
# bypassPermissions, lib/adapters/grok.sh), so it must not be lumped in with
# "no equivalent" engines like codex, and --permission acceptEdits must not be
# silent on it (silence used to read as "you got acceptEdits").
@test "burn #60: grok — both acceptEdits and auto degrade truthfully, argv unchanged" {
  _stub_grok
  clikae init grok T1
  local A="$BATS_TEST_TMPDIR/out.md"

  STUB_ARTIFACT="$A" STUB_ARGV_LOG="$TEST_HOME/default.log" \
    clikae burn grok T1 --artifact "$A" --prompt 'build and review' --add-dir /workspace >/dev/null 2>/dev/null
  [ -f "$A" ]; rm -f "$A"

  STUB_ARTIFACT="$A" STUB_ARGV_LOG="$TEST_HOME/accept.log" \
    clikae burn grok T1 --artifact "$A" --permission acceptEdits --prompt 'build and review' --add-dir /workspace \
    >/dev/null 2>"$TEST_HOME/accept.err"
  [ -f "$A" ]; rm -f "$A"

  STUB_ARTIFACT="$A" STUB_ARGV_LOG="$TEST_HOME/auto.log" \
    clikae burn grok T1 --artifact "$A" --permission auto --prompt 'build and review' --add-dir /workspace \
    >/dev/null 2>"$TEST_HOME/auto.err"
  [ -f "$A" ]

  cmp "$TEST_HOME/default.log" "$TEST_HOME/accept.log"
  cmp "$TEST_HOME/default.log" "$TEST_HOME/auto.log"
  [ "$(wc -l < "$TEST_HOME/accept.err" | tr -d ' ')" = 1 ]
  [ "$(wc -l < "$TEST_HOME/auto.err" | tr -d ' ')" = 1 ]
  grep -F 'clikae does not map --permission for grok' "$TEST_HOME/accept.err"
  grep -F 'clikae does not map --permission for grok' "$TEST_HOME/auto.err"
  # and it must NOT reuse codex's "has no equivalent" wording — that phrasing
  # reads as "grok has no permission modes at all", which is false: it has one,
  # clikae just doesn't map onto it.
  ! grep -F 'has no equivalent' "$TEST_HOME/accept.err"
}

# --- P3-1 (round-1 review): agy's degradation path had zero tests. The stub's
# --log-file value is a per-run random tmp path (_stub_agy_burn's own doc
# comment above), so argv comparison normalizes that one token out.
@test "burn #60: agy — both acceptEdits and auto degrade once, argv unchanged apart from --log-file" {
  _stub_agy_burn
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy default >/dev/null 2>&1
  local A="$BATS_TEST_TMPDIR/out.md"

  STUB_ARTIFACT="$A" STUB_ARGV_LOG="$TEST_HOME/default.log" \
    clikae burn agy default --artifact "$A" --prompt "do the thing" >/dev/null 2>/dev/null
  [ -f "$A" ]; rm -f "$A"

  STUB_ARTIFACT="$A" STUB_ARGV_LOG="$TEST_HOME/accept.log" \
    clikae burn agy default --artifact "$A" --permission acceptEdits --prompt "do the thing" \
    >/dev/null 2>"$TEST_HOME/accept.err"
  [ -f "$A" ]; rm -f "$A"

  STUB_ARTIFACT="$A" STUB_ARGV_LOG="$TEST_HOME/auto.log" \
    clikae burn agy default --artifact "$A" --permission auto --prompt "do the thing" \
    >/dev/null 2>"$TEST_HOME/auto.err"
  [ -f "$A" ]

  sed -E 's/--log-file [^ ]+/--log-file X/' "$TEST_HOME/default.log" > "$TEST_HOME/default.norm"
  sed -E 's/--log-file [^ ]+/--log-file X/' "$TEST_HOME/accept.log"  > "$TEST_HOME/accept.norm"
  sed -E 's/--log-file [^ ]+/--log-file X/' "$TEST_HOME/auto.log"    > "$TEST_HOME/auto.norm"
  cmp "$TEST_HOME/default.norm" "$TEST_HOME/accept.norm"
  cmp "$TEST_HOME/default.norm" "$TEST_HOME/auto.norm"

  [ "$(wc -l < "$TEST_HOME/accept.err" | tr -d ' ')" = 1 ]
  [ "$(wc -l < "$TEST_HOME/auto.err" | tr -d ' ')" = 1 ]
  grep -F 'agy has no equivalent for --permission acceptEdits; keeping its existing burn flags.' "$TEST_HOME/accept.err"
  grep -F 'agy has no equivalent for --permission auto; keeping its existing burn flags.' "$TEST_HOME/auto.err"
}

# --- P3-2 (round-1 review): the raw-argv advisory used to sit after the whole
# lock/status-file section; it only needs prompt_set, which is settled long
# before that. Proven by an invalid tank name: validate_name (right after the
# advisory now) fails before $HOME/.clikae/logs is ever created, so if the
# advisory still prints here, it printed before any state existed.
@test "burn #60: raw-argv --permission advisory fires before validate_name / any state work" {
  run clikae burn codex 'bad name' --artifact /tmp/x --permission auto -- run /tmp/x
  [ "$status" -ne 0 ]
  [[ "$output" == *'--permission does not modify raw engine argv; set the engine permission flag after --.'* ]] || false
  [ ! -d "$CLIKAE_HOME/logs" ]
}

# --- P3-6 (round-1 review): prompt mode composes --permission-mode itself; a
# raw --permission-mode / --dangerously-skip-permissions riding in after `--`
# (the documented #24 escape hatch) can now collide with or override it
# silently. clikae warns once and does NOT touch argv — both flags must still
# appear in what's actually sent to the engine.
@test "burn #60: a duplicate engine permission flag after -- warns once, argv untouched" {
  _stub_claude
  clikae init claude T1
  local A="$BATS_TEST_TMPDIR/out.md" L="$TEST_HOME/argv.log" E="$TEST_HOME/warn.err"
  # --no-reroute: skip the one-time "different accounts" carry notice (unrelated
  # to this test, and it would otherwise land in $E and break the line count).
  STUB_ARTIFACT="$A" STUB_ARGV_LOG="$L" \
    clikae burn claude T1 --artifact "$A" --no-reroute --prompt 'build and review' -- --permission-mode bypassPermissions \
    >/dev/null 2>"$E"
  [ -f "$A" ]
  [ "$(grep -o -- '--permission-mode' "$L" | wc -l | tr -d ' ')" = 2 ]
  [ "$(wc -l < "$E" | tr -d ' ')" = 1 ]
  grep -F 'raw argv after -- includes --permission-mode or --dangerously-skip-permissions' "$E"
}

# --- P1-1 (2026-09-12 round-2 review): the production reroute path itself —
# claude/T1 genuinely dry, --to codex/T2, --permission auto. This is the ONLY
# shape in this file that calls load_adapter twice (claude, then codex) inside
# ONE process via the real `clikae burn` reroute loop (burn.sh:2554-2564), so
# it is the only test that can catch adapter_meta_permission_modes leaking
# from claude onto codex and making burn.sh:508's `! declare -F
# adapter_meta_permission_modes` gate lie (codex looks like it maps
# --permission when it never defined the hook). Every OTHER --permission test
# above calls `clikae burn <one engine>` exactly once per process — a fresh
# `load_adapter` from a clean shell — so the leak can never surface there.
@test "burn #60 P1-1 (round-2 review): cross-engine --to reroute does not leak claude's permission-mode capability onto codex" {
  _stub_codex
  # A claude stub that always reports the vendor's hard usage-limit line (the
  # exact wording limit_output_dry's claude branch requires), so this burn is
  # forced down the dry -> reroute path every time, deterministically.
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  cat > "$bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
exit 0
STUB
  chmod +x "$bin/claude"
  PATH="$bin:$PATH"; export PATH

  clikae init claude T1
  clikae init codex T2
  : > "$CLIKAE_HOME/carry-notice-shown"   # one-time cross-account note is unrelated to this test

  local A="$BATS_TEST_TMPDIR/out.md" L="$TEST_HOME/codex.argv" E="$TEST_HOME/warn.err"
  STUB_ARTIFACT="$A" STUB_ARGV_LOG="$L" \
    clikae burn claude T1 --artifact "$A" --to codex/T2 --permission auto --prompt 'x' \
    >/dev/null 2>"$E"
  [ -f "$A" ]   # codex/T2 actually ran and produced the artifact

  # The capability gate must fire for codex: codex never defines
  # adapter_meta_permission_modes, so --permission auto must degrade truthfully
  # on it — exactly once, the SAME wording the single-engine codex test above
  # (burn #60: codex auto degrades once on stderr with unchanged argv) uses.
  [ "$(grep -Fc 'codex has no equivalent for --permission auto; keeping its existing burn flags.' "$E" | tr -d ' ')" = 1 ]

  # And codex's actual argv must never carry --permission-mode — proving the
  # gate's truthful warning is backed by truthful argv, not just backed by
  # inherited claude state that happens to also block it once.
  ! grep -q -- '--permission-mode' "$L"
}

@test "burn #66: non-git cwd refuses before creating any clikae state" {
  rm -rf "$HOME/.clikae"  # undo shared setup; this refusal must create nothing
  local plain="$HOME/plain directory"
  mkdir -p "$plain"
  run clikae burn codex T1 --json --artifact "$plain/out" --prompt x --add-dir "$plain"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$plain"* ]] || false
  [[ "$output" == *"put the repository first"* ]] || false
  [[ "$output" == *"--codex-skip-git-check"* ]] || false
  [ "${#lines[@]}" -eq 1 ]
  [ ! -e "$HOME/.clikae" ]
}

@test "burn #66: git cwd keeps generated argv byte-identical" {
  _stub_burn_transport
  clikae init codex T1
  export STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv"
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  run clikae burn codex T1 --artifact "$STUB_ARTIFACT" --prompt x --add-dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf 'exec -C %s -s workspace-write x\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/expected"
  cmp "$BATS_TEST_TMPDIR/expected" "$STUB_ARGV_LOG"
}

@test "burn #66: explicit opt-in adds skip-git-repo-check exactly once" {
  _stub_burn_transport
  clikae init codex T1
  local plain="$HOME/plain"
  mkdir -p "$plain"
  export STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv"
  export STUB_ARTIFACT="$plain/out"
  run clikae burn codex T1 --artifact "$STUB_ARTIFACT" --prompt x --add-dir "$plain" --codex-skip-git-check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf 'exec --skip-git-repo-check -C %s -s workspace-write x\n' "$plain" > "$BATS_TEST_TMPDIR/expected"
  cmp "$BATS_TEST_TMPDIR/expected" "$STUB_ARGV_LOG"
}

@test "burn #66: fast failure JSON reason uses trimmed stderr first line" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'ordinary stdout\n'
printf '  launch refused by engine  \nsecond stderr line\n' >&2
exit 7
STUB
  clikae init codex T1
  run clikae burn codex T1 --json --artifact "$BATS_TEST_TMPDIR/out" -- noop
  [ "$status" -eq 1 ]
  [[ "$output" == *'"reason":"launch refused by engine"'* ]] || { echo "$output"; false; }
  [[ "$output" == *'"ok":false'* ]] || false
  [[ "$output" == *'rc=7'* ]] || false
}

@test "burn #66: default artifact parent is checked before --fresh can delete it" {
  rm -rf "$HOME/.clikae"
  local plain="$HOME/plain"
  mkdir -p "$plain"
  printf 'keep me' > "$plain/out"
  run clikae burn codex T1 --artifact "$plain/out" --prompt x --fresh
  [ "$status" -eq 1 ]
  [[ "$output" == *"$plain"* ]] || false
  [ "$(cat "$plain/out")" = 'keep me' ]
  [ ! -e "$HOME/.clikae" ]
}

@test "burn #66: stderr reason is capped at 200 bytes even with engine rc zero" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '  %0250d  \nsecond line\n' 0 >&2
exit 0
STUB
  clikae init codex T1
  run clikae burn codex T1 --json --artifact "$BATS_TEST_TMPDIR/out" -- noop
  [ "$status" -eq 1 ]
  local expected; expected="$(printf '%0200d' 0)"
  [[ "$output" == *"\"reason\":\"$expected\""* ]] || { echo "$output"; false; }
  [[ "$output" == *'rc=0'* ]] || false
}

# --- P3-3 (round-2 review): _burn_sanitize_reason used to `tr -s ' '` the
# WHOLE result, squeezing any run of 2+ spaces down to one — including runs
# an engine legitimately printed on purpose (aligning a diagnostic), with no
# control byte or ANSI sequence involved at all. Only the substitution that
# turns a raw control byte into a space needs to stay JSON-safe; a genuine
# double space in an otherwise-clean stderr line is not this function's to
# collapse.
@test "burn #66: stderr reason keeps legitimate consecutive spaces (P3-3)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'error:  file    not found  (rc=3)\n' >&2
exit 7
STUB
  clikae init codex T1
  run clikae burn codex T1 --json --artifact "$BATS_TEST_TMPDIR/out" -- noop
  [ "$status" -eq 1 ]
  [[ "$output" == *'"reason":"error:  file    not found  (rc=3)"'* ]] || { echo "$output"; false; }
}

# --- P3-2 (#81 round-1 fix review): the fast-failure `reason` above went
# straight from raw stderr to _burn_sanitize_reason (JSON-escaping only,
# never redaction) — an engine that echoes the operator's own prompt back
# on stderr put it verbatim into --json/status.json's `reason`, the same
# class of leak #43 already closed for the diagnostic tail.

@test "burn #81: a prompt fragment echoed to stderr never reaches --json's reason (P3-2)" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'fatal: %s\n' "${@: -1}" >&2
exit 7
STUB
  clikae init codex T1
  local prompt="please write about PRIVATE-PROMPT-FRAGMENT-XYZ today"
  run clikae burn codex T1 --json --artifact "$BATS_TEST_TMPDIR/out" --prompt "$prompt"
  [ "$status" -eq 1 ]
  # The human-readable "preview:" line legitimately echoes the operator's own
  # prompt — only the JSON `reason` field is the thing #66 promises never
  # carries raw, unredacted engine stderr.
  local reason_field
  reason_field="$(printf '%s' "$output" | grep -o '"reason":"[^"]*"')"
  [[ "$reason_field" != *PRIVATE-PROMPT-FRAGMENT-XYZ* ]] || { echo "$reason_field"; false; }
  [[ "$reason_field" == *'fatal:'* ]] || { echo "$reason_field"; false; }
}

# --- #66 round-1 review fixes ---

@test "burn #66 round-1 P1-1: a cross-engine reroute INTO codex re-checks the git cwd" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf "You've hit your usage limit · resets in 1h\n"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  clikae init claude L1
  clikae init codex L2
  local plain="$HOME/plain_nongit"
  mkdir -p "$plain"
  export STUB_ARGV_LOG="$BATS_TEST_TMPDIR/codex-argv.log"
  run clikae burn claude L1 --json --artifact "$plain/out" --prompt x --add-dir "$plain" --to codex/L2
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not inside a git work tree"* ]] || { echo "$output"; false; }
  [ ! -e "$STUB_ARGV_LOG" ]   # codex itself must never have run
}

@test "burn #66 round-1 P1-1 control: reroute into codex still proceeds when the cwd IS a git work tree" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf "You've hit your usage limit · resets in 1h\n"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  clikae init claude L1
  clikae init codex L2
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"   # _stub_codex already git-init'd this dir
  run clikae burn claude L1 --json --artifact "$STUB_ARTIFACT" --prompt x --add-dir "$BATS_TEST_TMPDIR" --to codex/L2
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'"ok":true'* ]] || false
  [ -f "$STUB_ARTIFACT" ]
}

@test "burn #66 round-1 P2-1: ANSI/control chars in stderr sanitize into valid JSON" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'ordinary stdout\n'
printf '\033[31mbad\tthing "quoted" \\ end\033[0m\n' >&2
exit 7
STUB
  clikae init codex T1
  run clikae burn codex T1 --json --artifact "$BATS_TEST_TMPDIR/out" -- noop
  [ "$status" -eq 1 ]
  local json_line; json_line="$(printf '%s\n' "$output" | grep '^{')"
  [ -n "$json_line" ] || { echo "$output"; false; }
  printf '%s' "$json_line" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["reason"] == "bad thing \"quoted\" \\ end", d["reason"]
'
}

@test "burn #66 round-1 P2-2: 200-byte cap does not split a multibyte char under C locale" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 300 ]; do printf '\xe9\xbe\x8d' >&2; i=$((i + 1)); done
printf '\n' >&2
exit 7
STUB
  clikae init codex T1
  LC_ALL=C LANG=C LC_CTYPE=C run clikae burn codex T1 --json --artifact "$BATS_TEST_TMPDIR/out" -- noop
  [ "$status" -eq 1 ]
  local json_line; json_line="$(printf '%s\n' "$output" | grep '^{')"
  [ -n "$json_line" ] || { echo "$output"; false; }
  printf '%s' "$json_line" | python3 -c 'import json,sys; json.load(sys.stdin)'
  printf '%s' "$json_line" \
    | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["reason"])' \
    | iconv -f UTF-8 -t UTF-8 >/dev/null
}

@test "burn #66 round-1 P3-1: --codex-skip-git-check on a non-codex engine warns, does not fail" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'done' > "$STUB_ARTIFACT"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  clikae init claude L1
  export STUB_ARTIFACT="$BATS_TEST_TMPDIR/out"
  run clikae burn claude L1 --artifact "$STUB_ARTIFACT" --prompt x --codex-skip-git-check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"--codex-skip-git-check has no effect"* ]] || false
  [ -f "$STUB_ARTIFACT" ]
}

@test "burn #66 round-1 P3-1 control: raw argv form also warns the flag has no effect" {
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" --codex-skip-git-check -- run "$A"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"--codex-skip-git-check has no effect"* ]] || false
  [ -f "$A" ]
}

@test "burn #66 round-1 P3-2: a nonexistent --add-dir says so, not 'not a git work tree'" {
  rm -rf "$HOME/.clikae"
  local missing="$HOME/does/not/exist_at_all"
  run clikae burn codex T1 --json --artifact "$missing/out" --prompt x --add-dir "$missing"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]] || { echo "$output"; false; }
  [[ "$output" != *"is not inside a git work tree"* ]] || { echo "$output"; false; }
  [ ! -e "$HOME/.clikae" ]
}

# ── headless guards: no sub-agents, no background-wait kill (2026-09-13) ─────
# A claude lane that reaches for the Agent tool hands the task to a background
# sub-agent and ends its turn; `claude -p` then terminates the whole run after
# its background wait ceiling with nothing on disk (reefbox, #78 fix lane, 651 s).
# burn now appends `--disallowedTools Agent,Task` to every print-mode claude argv
# that carries no tools flag of its own, and exports
# CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 unless the operator set it.

@test "burn (claude, --prompt): appends --disallowedTools Agent,Task and exports the bg-wait ceiling" {
  _stub_claude
  clikae init claude t1
  local A="$BATS_TEST_TMPDIR/out.md"
  export STUB_ARTIFACT="$A" STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv.log" STUB_ENV_LOG="$BATS_TEST_TMPDIR/env.log"
  unset CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
  run clikae burn claude t1 --artifact "$A" --prompt "do it"
  [ "$status" -eq 0 ]
  grep -q -- "--permission-mode acceptEdits .*--disallowedTools Agent,Task" "$BATS_TEST_TMPDIR/argv.log"
  grep -q "^BG_WAIT=0$" "$BATS_TEST_TMPDIR/env.log"
}

@test "burn (claude, raw -- -p): the guards apply to the power-user form too" {
  _stub_claude
  clikae init claude t1
  local A="$BATS_TEST_TMPDIR/out.md"
  export STUB_ARTIFACT="$A" STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv.log" STUB_ENV_LOG="$BATS_TEST_TMPDIR/env.log"
  unset CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
  run clikae burn claude t1 --artifact "$A" -- -p "raw prompt" --permission-mode acceptEdits
  [ "$status" -eq 0 ]
  grep -q -- "-p raw prompt --permission-mode acceptEdits --disallowedTools Agent,Task" "$BATS_TEST_TMPDIR/argv.log"
  grep -q "^BG_WAIT=0$" "$BATS_TEST_TMPDIR/env.log"
}

@test "burn (claude): an operator-supplied tools flag switches the argv guard off; a set ceiling is kept" {
  _stub_claude
  clikae init claude t1
  local A="$BATS_TEST_TMPDIR/out.md"
  export STUB_ARTIFACT="$A" STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv.log" STUB_ENV_LOG="$BATS_TEST_TMPDIR/env.log"
  export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=1234
  run clikae burn claude t1 --artifact "$A" -- -p "raw prompt" --allowedTools "Bash,Agent"
  [ "$status" -eq 0 ]
  run grep -q -- "--disallowedTools" "$BATS_TEST_TMPDIR/argv.log"
  [ "$status" -ne 0 ]
  grep -q -- "--allowedTools Bash,Agent" "$BATS_TEST_TMPDIR/argv.log"
  grep -q "^BG_WAIT=1234$" "$BATS_TEST_TMPDIR/env.log"
}

@test "burn (codex): the claude guards do not leak into another engine's argv" {
  _stub_codex
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  export STUB_ARTIFACT="$A" STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
  run clikae burn codex T1 --artifact "$A" --prompt "do it"
  [ "$status" -eq 0 ]
  # P3-5 (#81 round-1 fix review): same `! cmd` set -e exemption as above —
  # bring this in line with the equivalent assertion earlier in this file.
  run grep -q -- "disallowedTools" "$BATS_TEST_TMPDIR/argv.log"
  [ "$status" -ne 0 ]
}

_stub_codex_stderr81() {
  _stub_codex
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$STUB_STDERR81" >&2
exit 0
STUB
}

@test "burn #81: stderr-only codex limit exits zero but reports dry and stores reset" {
  _stub_codex_stderr81
  export STUB_STDERR81
  STUB_STDERR81="$(awk -F '\t' '/^1789200000\tERROR:/ {print $2}' "$CLIKAE_TEST_ROOT/tests/fixtures/limit-reset-phrases.tsv")"
  clikae init codex T1
  run clikae burn codex T1 --json --no-reroute --artifact "$BATS_TEST_TMPDIR/out" --prompt x
  [ "$status" -ne 0 ]
  [[ "$output" == *'"reason":"tank ran dry and --no-reroute is set"'* ]] || false
  [[ "$output" == *'"reset":"try again at Sep 13th, 2026 2:13 AM"'* ]] || false
  [[ "$output" != *'no fresh artifact and no limit'* ]] || false
  [[ "$output" == *'Dry, and --no-reroute is set. Stopping.'* ]] || false
  [ ! -e "$BATS_TEST_TMPDIR/out" ]
  local reset
  reset="$(cut -f2 "$CLIKAE_HOME/dry/codex/T1")"
  [ "$reset" = "try again at Sep 13th, 2026 2:13 AM" ]
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  TZ=UTC run limit_reset_epoch "$reset" 1789200000
  [ "$status" -eq 0 ]
  [ "$output" = "1789265580" ]
}

@test "burn #81: ordinary codex stderr preserves the no-artifact failure" {
  _stub_codex_stderr81
  export STUB_STDERR81="ERROR: could not open input file"
  clikae init codex T1
  run clikae burn codex T1 --json --no-reroute --artifact "$BATS_TEST_TMPDIR/out" --prompt x
  [ "$status" -ne 0 ]
  [[ "$output" == *'produced no fresh artifact and shows no limit'* ]] || false
  # P3-6 (#81 round-1 fix review): this used to accept EITHER reason string,
  # so a real regression in #66's stderr-reason plumbing (the actual thing
  # this test's own title promises to guard) could never turn it red. Only
  # the shape this stub actually produces.
  [[ "$output" == *'"reason":"ERROR: could not open input file"'* ]] || false
  [[ "$output" == *'"reset":null'* ]] || false
  [ ! -e "$CLIKAE_HOME/dry/codex/T1" ]
}

# --- P2-2 (#81 round-1 fix review): limit_codex_output_dry matched the exact
# vendor sentence ANYWHERE in the reply, not just when it terminates the run —
# so a HEALTHY codex asked to write about this very issue, that happens to
# quote the real sentence verbatim mid-transcript and then keeps working, was
# misread as dry. A genuine vendor limit line is never followed by pages of
# ordinary output (it IS the end of the run), so the anchor now only counts
# inside the last 20 lines.

@test "burn #81: the vendor sentence QUOTED mid-transcript, run finishes with an artifact, is not dry (P2-2)" {
  _stub_codex
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
for i in $(seq 1 99); do printf 'line %s of the runbook I am writing.\n' "$i"; done
printf "ERROR: You've hit your usage limit. try again at Sep 13th, 2026 2:13 AM.\n"
for i in $(seq 101 200); do printf 'line %s of the runbook I am writing.\n' "$i"; done
[ -n "$STUB_ARTIFACT" ] && : > "$STUB_ARTIFACT"
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/codex"
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  export STUB_ARTIFACT="$A"
  run clikae burn codex T1 --json --artifact "$A" --prompt x
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || false
  [[ "$output" == *'"reason":"artifact produced"'* ]] || false
  [ ! -e "$CLIKAE_HOME/dry/codex/T1" ]
}

@test "burn #81: the vendor sentence as the LAST line, no artifact, is still dry (P2-2 control)" {
  _stub_codex
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
for i in $(seq 1 199); do printf 'line %s of the runbook I am writing.\n' "$i"; done
printf "ERROR: You've hit your usage limit. try again at Sep 13th, 2026 2:13 AM.\n"
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/codex"
  clikae init codex T1
  run clikae burn codex T1 --json --no-reroute --artifact "$BATS_TEST_TMPDIR/out" --prompt x
  [ "$status" -ne 0 ]
  [[ "$output" == *'"reason":"tank ran dry and --no-reroute is set"'* ]] || false
  [[ "$output" == *'"reset":"try again at Sep 13th, 2026 2:13 AM"'* ]] || false
  local reset
  reset="$(cut -f2 "$CLIKAE_HOME/dry/codex/T1")"
  [ "$reset" = "try again at Sep 13th, 2026 2:13 AM" ]
}

# --- P1-1 (round-2 fix review, this PR): the `tail -n 20` window this
# function's P2-2 fix (above) was tested against hid the anchor from the
# other two real callers — burn.sh's NO-ARTIFACT branch (a real limit line
# followed by a stack trace longer than 20 lines read as "no limit here", an
# exact #81 recurrence) and burn.sh's ARTIFACT-PRODUCED branch (below). The
# window is gone: the classifier now scans the whole captured reply.

@test "burn #81 fix2: a limit line followed by a >20-line stack trace, no artifact, is dry — not a task failure (P1-1)" {
  _stub_codex
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf "ERROR: You've hit your usage limit. try again at Sep 13th, 2026 2:13 AM.\n"
for i in $(seq 1 25); do printf '    at codex::exec::run (src/exec.rs:%s)\n' "$i"; done
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/codex"
  clikae init codex T1
  run clikae burn codex T1 --json --no-reroute --artifact "$BATS_TEST_TMPDIR/out" --prompt x
  [ "$status" -ne 0 ]
  [[ "$output" == *'"reason":"tank ran dry and --no-reroute is set"'* ]] || false
  [[ "$output" == *'"reset":"try again at Sep 13th, 2026 2:13 AM"'* ]] || false
  [[ "$output" != *'no fresh artifact and no limit'* ]] || false
  [ ! -e "$BATS_TEST_TMPDIR/out" ]
  local reset
  reset="$(cut -f2 "$CLIKAE_HOME/dry/codex/T1")"
  [ "$reset" = "try again at Sep 13th, 2026 2:13 AM" ]
}

# --- P1-1(b) (round-2 fix review, this PR): burn.sh's artifact-wins branch
# already refused to clear a marker when limit_output_dry fired on the SAME
# reply — but limit_output_dry was fed the windowed tail, so on the path
# most likely to have the vendor's limit line far from the end (the run kept
# GOING and finished the artifact afterward), the window hid it and a real,
# pre-existing dry marker was silently cleared. The 2026-09-08 round-2 P2-2
# receipt, restored: a marker that predates this run must survive it.

@test "burn #81 fix2: a pre-existing dry marker survives an artifact-producing run whose SAME reply still shows a limit far from the tail (P1-1b)" {
  _stub_codex
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf "ERROR: You've hit your usage limit. try again at Sep 13th, 2026 2:13 AM.\n"
for i in $(seq 1 25); do printf 'line %s of the runbook I am writing.\n' "$i"; done
[ -n "$STUB_ARTIFACT" ] && : > "$STUB_ARTIFACT"
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/codex"
  clikae init codex T1
  mkdir -p "$CLIKAE_HOME/dry/codex"
  printf '1700000000\ttry again earlier today\n' > "$CLIKAE_HOME/dry/codex/T1"
  local A="$BATS_TEST_TMPDIR/out.md"
  export STUB_ARTIFACT="$A"
  run clikae burn codex T1 --json --artifact "$A" --prompt x
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || false
  [[ "$output" == *'not marking it dry'* ]] || false
  [ -f "$CLIKAE_HOME/dry/codex/T1" ]
  [ "$(cat "$CLIKAE_HOME/dry/codex/T1")" = "$(printf '1700000000\ttry again earlier today')" ]
}

# --- P1-1 rc-gate (round-2 fix review, this PR): the artifact-wins branch's
# clear was gated only on "no limit line in this reply" — add the belt this
# review's own design decision calls for: a fresh artifact with a NON-ZERO
# engine exit is not the "real success" dry_store_clear exists for either,
# even with no limit line in the reply.

@test "burn #81 fix2: a fresh artifact with a non-zero engine exit does not clear a pre-existing marker (P1-1 rc-gate)" {
  _stub_codex
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'partial output, then a crash\n'
[ -n "$STUB_ARTIFACT" ] && : > "$STUB_ARTIFACT"
exit 9
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/codex"
  clikae init codex T1
  mkdir -p "$CLIKAE_HOME/dry/codex"
  printf '1700000000\ttry again earlier today\n' > "$CLIKAE_HOME/dry/codex/T1"
  local A="$BATS_TEST_TMPDIR/out.md"
  export STUB_ARTIFACT="$A"
  run clikae burn codex T1 --json --artifact "$A" --prompt x
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || false
  [ -f "$CLIKAE_HOME/dry/codex/T1" ]
  [ "$(cat "$CLIKAE_HOME/dry/codex/T1")" = "$(printf '1700000000\ttry again earlier today')" ]
}

@test "burn #81 fix2: a fresh artifact with rc==0 and no limit line still clears a pre-existing marker (P1-1 rc-gate control)" {
  _stub_codex
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'all clear, task complete\n'
[ -n "$STUB_ARTIFACT" ] && : > "$STUB_ARTIFACT"
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/codex"
  clikae init codex T1
  mkdir -p "$CLIKAE_HOME/dry/codex"
  printf '1700000000\ttry again earlier today\n' > "$CLIKAE_HOME/dry/codex/T1"
  local A="$BATS_TEST_TMPDIR/out.md"
  export STUB_ARTIFACT="$A"
  run clikae burn codex T1 --json --artifact "$A" --prompt x
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || false
  [ ! -e "$CLIKAE_HOME/dry/codex/T1" ]
}
# --- P2-2 (round-2 fix review, this PR): the fast-failure `reason` field's
# redaction used _burn_redact_full's DEFAULT replacement — an empty string —
# and only ever looked at stderr's first line. When that first line IS, in
# its entirety, the thing being redacted (codex echoing the whole prompt
# back as its own first stderr line), redacting it to "" and stopping left
# `reason` empty, even though a real diagnostic sat right there on the next
# line.

@test "burn #99/P2-2 fix2: a stderr first line that IS the prompt does not empty reason — the real diagnostic on the next line survives" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}" >&2
printf 'error: real diagnostic follows\n' >&2
exit 7
STUB
  clikae init codex T1
  local prompt="please write about PRIVATE-PROMPT-FRAGMENT-XYZ today"
  run clikae burn codex T1 --json --artifact "$BATS_TEST_TMPDIR/out" --prompt "$prompt"
  [ "$status" -eq 1 ]
  local reason_field
  reason_field="$(printf '%s' "$output" | grep -o '"reason":"[^"]*"')"
  [ -n "$reason_field" ]
  [ "$reason_field" != '"reason":""' ]
  [[ "$reason_field" != *PRIVATE-PROMPT-FRAGMENT-XYZ* ]] || { echo "$reason_field"; false; }
  [[ "$reason_field" == *'real diagnostic follows'* ]] || { echo "$reason_field"; false; }
}

@test "burn #99/P2-2 fix2: when every stderr line is placeholder or blank, reason falls back to a plain message — never empty or null" {
  _stub_burn_transport
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}" >&2
printf '\n' >&2
printf '%s\n' "${@: -1}" >&2
exit 9
STUB
  clikae init codex T1
  local prompt="please write about PRIVATE-PROMPT-FRAGMENT-XYZ today"
  run clikae burn codex T1 --json --artifact "$BATS_TEST_TMPDIR/out" --prompt "$prompt"
  [ "$status" -eq 1 ]
  local reason_field
  reason_field="$(printf '%s' "$output" | grep -o '"reason":"[^"]*"')"
  [ -n "$reason_field" ]
  [ "$reason_field" != '"reason":""' ]
  [[ "$reason_field" == *'engine exited rc=9, output redacted'* ]] || { echo "$reason_field"; false; }
  [[ "$reason_field" != *PRIVATE-PROMPT-FRAGMENT-XYZ* ]] || { echo "$reason_field"; false; }
}

# Keep the scan away from the source checkout and the stub/config directories.
_left84_setup() {
  _stub_burn_transport
  clikae init codex T1
  mkdir -p "$TEST_HOME/scan" "$TEST_HOME/repos"
  cd "$TEST_HOME/scan" || return
}

_left84_repo() {
  export STUB_LEFT_REPO="$TEST_HOME/repos/work space"
  git init -q "$STUB_LEFT_REPO"
  git -C "$STUB_LEFT_REPO" config user.name 'Burn test'
  git -C "$STUB_LEFT_REPO" config user.email 'burn@example.invalid'
  git -C "$STUB_LEFT_REPO" commit -qm initial --allow-empty
  git -C "$STUB_LEFT_REPO" branch baseline
  git -C "$STUB_LEFT_REPO" branch --set-upstream-to=baseline >/dev/null
}

@test "burn #84: committed work without artifact is reported and deduplicated in JSON" {
  _left84_setup
  _left84_repo
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'saved work\n' > "$STUB_LEFT_REPO/saved.txt"
git -C "$STUB_LEFT_REPO" add saved.txt
git -C "$STUB_LEFT_REPO" commit -qm saved
STUB
  run clikae burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$TEST_HOME/repos" --add-dir "$STUB_LEFT_REPO" -- noop
  [ "$status" -eq 1 ]
  [[ "$output" == *"left behind:"*"ahead 1 dirty 0"* ]] || false
  [[ "$output" == *"hint: git -C "*" push"* ]] || false
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c '
import json, os, sys
rows = json.load(sys.stdin)["left_behind"]
assert len(rows) == 1, rows
r = rows[0]
assert r["repo"] == os.path.realpath(os.environ["STUB_LEFT_REPO"])
assert r["branch"] and r["ahead"] == 1 and r["dirty"] == 0
assert r["files"] == [r["repo"] + "/saved.txt"], r
'
}

@test "burn #84: clean unchanged repository leaves no block and an empty array" {
  _left84_setup
  _left84_repo
  run clikae burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$STUB_LEFT_REPO" -- noop
  [ "$status" -eq 1 ]
  [[ "$output" != *"left behind:"* ]] || false
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c 'import json,sys; assert json.load(sys.stdin)["left_behind"] == []'
}

@test "burn #84: non-git add-dir is skipped silently" {
  _left84_setup
  printf 'plain\n' > "$TEST_HOME/scan/plain"
  run clikae burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$TEST_HOME/scan" -- noop
  [ "$status" -eq 1 ]
  [[ "$output" != *"left behind:"* ]] || false
  [[ "$output" != *"fatal:"* ]] || false
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c 'import json,sys; assert json.load(sys.stdin)["left_behind"] == []'
}

@test "burn #84: dry failure reports dirty work with no upstream and caps recent files" {
  _left84_setup
  _left84_repo
  git -C "$STUB_LEFT_REPO" branch --unset-upstream
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
mkdir -p "$STUB_LEFT_REPO/node_modules"
printf ignored > "$STUB_LEFT_REPO/node_modules/ignored"
for i in {1..12}; do printf work > "$STUB_LEFT_REPO/file$i"; done
echo "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
STUB
  run clikae burn codex T1 --json --no-reroute --artifact "$TEST_HOME/missing" --add-dir "$STUB_LEFT_REPO" -- noop
  # #61 round-6 merge with #87: a DRY tank stopped by --no-reroute is rc 2
  # (CLIKAE_BURN_RC_NO_TANK), not a task failure's 1 — #61's whole point is
  # that "no tank was available" and "the task is broken" are different exits.
  # #87 wrote this test on main, where both were still 1. The left-behind
  # report itself is unaffected: it is produced on every artifact-less end.
  [ "$status" -eq 2 ]
  [[ "$output" == *"left behind:"*"ahead - dirty 13"* ]] || false
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c '
import json,sys
r = json.load(sys.stdin)["left_behind"][0]
assert r["ahead"] is None and r["dirty"] == 13
assert len(r["files"]) == 10
assert all("/.git/" not in f and "/node_modules/" not in f for f in r["files"])
'
}

@test "burn #84: timeout without artifact reports cwd work" {
  _left84_setup
  _left84_repo
  cd "$STUB_LEFT_REPO"
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf work > "$STUB_LEFT_REPO/partial"
sleep 3
STUB
  run clikae burn codex T1 --json --timeout 1 --artifact "$TEST_HOME/missing" -- noop
  [ "$status" -eq 1 ]
  [[ "$output" == *"left behind:"*"ahead 0 dirty 1"* ]] || false
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c 'import json,sys; assert len(json.load(sys.stdin)["left_behind"]) == 1'
}

@test "burn #84: successful artifact leaves JSON array empty despite existing work" {
  _left84_setup
  _left84_repo
  printf work > "$STUB_LEFT_REPO/partial"
  local artifact="$TEST_HOME/result"
  run clikae burn codex T1 --json --artifact "$artifact" --add-dir "$STUB_LEFT_REPO" -- run "$artifact"
  [ "$status" -eq 0 ]
  [[ "$output" != *"left behind:"* ]] || false
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c 'import json,sys; assert json.load(sys.stdin)["left_behind"] == []'
}

# P1 (round-1 review): a `.git/index` truncated to 0 bytes is exactly the
# shape a run killed mid-write leaves behind — `git rev-parse
# --show-toplevel` still succeeds (rc=0, so the repo enters the scan) but
# `git status --porcelain` fails (rc=128, "index file smaller than
# expected"). Under bin/clikae's `set -eo pipefail`, the ONE bare, unguarded
# assignment the review found (`burn.sh:808`) used to kill the whole burn
# process right there — exit code 1 became 128 and the `--json` object never
# printed at all. This asserts the block can NEVER do that: the JSON still
# parses, `reason` is unchanged, and the corrupted repo either shows
# `dirty:0` (the guard's fallback — not "null", since round-1's own
# suggested fix was literally `|| dirty=0`) or is absent from the array
# entirely (this fixture has no upstream-ahead commits and no post-start
# files, so with dirty treated as 0 it doesn't qualify and IS omitted).
@test "burn #84 P1: a corrupted .git/index never changes burn's exit code or --json shape" {
  _left84_setup
  _left84_repo
  : > "$STUB_LEFT_REPO/.git/index"
  run clikae burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$STUB_LEFT_REPO" -- noop
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c '
import json, sys
obj = json.load(sys.stdin)
assert obj["reason"] == "no fresh artifact and no limit", obj["reason"]
assert isinstance(obj["left_behind"], list)
rows = [r for r in obj["left_behind"] if r["repo"].endswith("/repos/work space")]
assert rows == [] or rows[0]["dirty"] in (0, None), rows
'
}

# P2-1 (round-1 review): the old code capped "recent files" at readdir
# order, not mtime — reproduced with f01..f30 (20ms apart) it reported 9 of
# the 10 newest wrong and dropped the actual newest file entirely.
#
# P1-1 (round-2 review): this fixture used `touch -d "@$((now+N))"` — GNU
# coreutils only, BSD `touch -d` rejects `@epoch`. On macOS CI all 30
# `touch`es failed, every mtime collapsed to "just created", and `sort -s`
# fell through to plain string order on the full path — which happened to
# equal f30..f21 by COINCIDENCE (filenames were assigned in that same
# order), so this test read green while testing nothing. Two independent
# fixes, neither optional: (1) `touch -t YYYYMMDDhhmm.SS` — POSIX, works on
# both — built the same way `tests/bats/live.bats`/`memory.bats` already do
# (`date -v+NS … 2>/dev/null || date -d "+N seconds" …`), not a new idiom;
# (2) the offset-to-filename mapping below is a deliberate shuffle (i -> ((i-1)*13
# mod 30)+1, coprime with 30 so it's a full permutation), asserted NOT to
# collapse to filename order — a regression back to "all mtimes equal, fall
# through to string-sort" now fails LOUDLY instead of passing by accident.
@test "burn #84 P2-1: recent files are the newest ten by mtime, not directory order" {
  _left84_setup
  _left84_repo
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
# One shared epoch base, computed ONCE — not resampled per file. A fresh
# `date -v+NS`/`date -d "+N seconds"` call PER ITERATION (round-2's first
# cut here) measures "N seconds from whenever this particular iteration
# happens to run", and 30 iterations of real subprocess work (date, touch)
# drift by more than 1 second under any real load — which corrupted the
# two CLOSEST offsets (26 vs 27) often enough to be a real flake, not a
# hypothetical one (measured on this box). Adding a fixed epoch instead
# means every file's timestamp is relative to the SAME instant.
now="$(date +%s)"
for i in $(seq -w 1 30); do
  f="$STUB_LEFT_REPO/f$i"
  printf '%s' "$i" > "$f"
  off=$(( ((10#$i - 1) * 13 % 30) + 1 ))
  target=$((now + off))
  ts="$(date -d "@$target" '+%Y%m%d%H%M.%S' 2>/dev/null || date -r "$target" '+%Y%m%d%H%M.%S')"
  touch -t "$ts" "$f"
done
STUB
  run clikae burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$STUB_LEFT_REPO" -- noop
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c '
import json, sys
rows = json.load(sys.stdin)["left_behind"]
row = next(r for r in rows if r["repo"].endswith("/repos/work space"))
files = [f.rsplit("/", 1)[1] for f in row["files"]]
offs = {f"f{i:02d}": ((i - 1) * 13 % 30) + 1 for i in range(1, 31)}
expect = sorted(offs, key=lambda f: -offs[f])[:10]
# The negative control itself: if this shuffle ever degenerated back into
# filename order, a broken (all-mtimes-equal) sort could pass by accident,
# same as the macOS bug this test exists to catch.
assert expect != sorted(offs, reverse=True)[:10], "offsets collapsed to filename order — negative control is dead"
assert files == expect, files
'
}

# P2-2/P2-5 (round-1 review): no cap meant one line per repo under a big
# --add-dir root, every time — 200 repos, 200 lines, for a run that failed
# for an unrelated reason. 30 repos, each with one post-start file at a
# distinct future-offset mtime (same determinism trick as P2-1), so the
# 25-cap and "newest activity first" ordering are both exactly assertable:
# repos r30..r06 (25 of them) are kept, r05..r01 are the "5 more".
# P1-1 (round-2 review): `touch -d "@epoch"` here is the same GNU-only call
# P2-1's fixture had — `touch -t` (built the live.bats/memory.bats way,
# `date -v+NS … || date -d "+N seconds" …`) instead.
# P2-2 (round-2 review): also asserts the new `left_behind_truncated` field
# — this cap is a pure display/JSON-size bound, so "25 shown, 5 more" must
# be a machine-readable fact, not only the human "and N more" line.
@test "burn #84 P2-2/P2-5: repos are capped at 25, newest-activity first, with a remainder line" {
  _stub_burn_transport
  clikae init codex T1
  mkdir -p "$TEST_HOME/scan" "$TEST_HOME/repos"
  cd "$TEST_HOME/scan" || return 1
  local i
  for i in $(seq -w 1 30); do
    git init -q "$TEST_HOME/repos/r$i"
    git -C "$TEST_HOME/repos/r$i" config user.name 'Burn test'
    git -C "$TEST_HOME/repos/r$i" config user.email 'burn@example.invalid'
    git -C "$TEST_HOME/repos/r$i" commit -q --allow-empty -m init
  done
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<STUB
#!/usr/bin/env bash
now="\$(date +%s)"
for i in \$(seq -w 1 30); do
  f="$TEST_HOME/repos/r\$i/touched"
  printf work > "\$f"
  off=\$(( 10#\$i ))
  target=\$((now + off))
  ts="\$(date -d "@\$target" '+%Y%m%d%H%M.%S' 2>/dev/null || date -r "\$target" '+%Y%m%d%H%M.%S')"
  touch -t "\$ts" "\$f"
done
STUB
  run clikae burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$TEST_HOME/repos" -- noop
  [ "$status" -eq 1 ]
  [[ "$output" == *"and 5 more repositories under"* ]] || false
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c '
import json, sys
obj = json.load(sys.stdin)
rows = obj["left_behind"]
assert len(rows) == 25, len(rows)
names = [r["repo"].rsplit("/", 1)[1] for r in rows]
expect = [f"r{n:02d}" for n in range(30, 5, -1)]
assert names == expect, names
assert obj["left_behind_truncated"] == 5, obj["left_behind_truncated"]
'
}

# P2-2 (round-2 review): `activity_ts` alone gave `ahead>0` (unpushed
# commits — the actual thing #84's title is about) zero ranking weight, so
# 29 noise repos (a stray post-start file each, ahead=0/dirty=1) could bury
# a real "payload" repo (a committed-but-unpushed commit, no post-start
# file at all) off the 25-cap entirely — measured on c42007a: not in the
# JSON, not in the human list, not even named in "and N more". The fix's
# whole point is the SAME repo shape here: with the three-level key
# (ahead>0, dirty>0, ts), payload is row 1 regardless of the 29 noise
# repos' file-mtime freshness, and its push hint prints even though this
# fixture keeps `n29` fresh enough that payload would rank last under the
# old key.
@test "burn #84 P2-2 (round-2 review): ahead>0 outranks file mtime in the 25-repo cap, and its push hint survives it" {
  _stub_burn_transport
  clikae init codex T1
  mkdir -p "$TEST_HOME/scan" "$TEST_HOME/repos"
  cd "$TEST_HOME/scan" || return 1
  local i
  for i in $(seq -w 1 29); do
    git init -q "$TEST_HOME/repos/n$i"
    git -C "$TEST_HOME/repos/n$i" config user.name t
    git -C "$TEST_HOME/repos/n$i" config user.email t@example.invalid
    git -C "$TEST_HOME/repos/n$i" commit -q --allow-empty -m init
  done
  git init -q "$TEST_HOME/repos/payload"
  git -C "$TEST_HOME/repos/payload" config user.name t
  git -C "$TEST_HOME/repos/payload" config user.email t@example.invalid
  git -C "$TEST_HOME/repos/payload" commit -q --allow-empty -m init
  git -C "$TEST_HOME/repos/payload" branch base
  git -C "$TEST_HOME/repos/payload" branch --set-upstream-to=base >/dev/null
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<STUB
#!/usr/bin/env bash
for i in \$(seq -w 1 29); do
  printf noise > "$TEST_HOME/repos/n\$i/stray"
done
git -C "$TEST_HOME/repos/payload" commit -q --allow-empty -m "left behind"
STUB
  run clikae burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$TEST_HOME/repos" -- noop
  [ "$status" -eq 1 ]
  [[ "$output" == *"hint: git -C "*"/repos/payload push"* ]] || false
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c '
import json, sys
rows = json.load(sys.stdin)["left_behind"]
assert rows, "empty left_behind"
assert rows[0]["repo"].endswith("/repos/payload"), rows[0]["repo"]
assert rows[0]["ahead"] == 1, rows[0]
'
}

# P2-3 (round-1 review): the old code read `elapsed_s` fresh (SECONDS - t0)
# AFTER _burn_left_behind ran, so a slow scan silently inflated it —
# measured 97s vs status.json's (unaffected: written a statement earlier,
# before any scan) 0s for the SAME run. A `find` shim that sleeps 1s makes
# the scan slow enough here to be measurable at 1-second $SECONDS
# granularity — a fast scan can't distinguish fixed from broken.
# P2-2 (round-4 review): a blanket "every `find` call sleeps 1s" shim was
# fine until #83 (`resume: hide sessions that burn started`, merged to main
# after this test was written) gave `cmd_burn` its own pre/post
# `adapter_all_transcripts` snapshot calls (codex.sh's own `find
# "$1/sessions" …`) — TWO more `find` invocations that run *inside* the
# timed window `elapsed_s` is pinned against (before `_burn_result`, same as
# the engine attempt itself), not inside `_burn_left_behind`'s scan. Once
# main is merged in, a shim that sleeps on every `find` legitimately makes
# `elapsed_s` read 2-3s — that IS the correct value now, the assertion below
# was just written against a world where those two calls didn't exist yet.
# Narrowing the sleep to the scan's own `find` shapes (discovery's
# `-print0`, the file-list find's `-newer` sentinel) keeps testing the same
# invariant — scan time must not leak into `elapsed_s` — without the
# session-attribution snapshot's unrelated `find` calls polluting it.
# P3-2 (round-5 review): narrowing that shim to the scan's own flags bound it
# to the implementation, and nothing asserted it still matched. The day
# discovery stops passing `-print0` (or the file-list find stops passing
# `-newer`) the shim fires zero times, the scan costs ~0s, and
# `[ "$json_elapsed" -lt 2 ]` passes unconditionally — the test goes quietly
# empty instead of going red, which is the failure mode this whole round of
# review keeps finding. The shim now records every time it fires and the test
# demands both shapes, so a flag change breaks the test loudly and in the
# right place.
@test "burn #84 P2-3: elapsed_s agrees across --json, the summary line, and status.json" {
  _left84_setup
  _left84_repo
  local fired="$BATS_TEST_TMPDIR/scan-find-fired"
  cat > "$BATS_TEST_TMPDIR/bin/find" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" -print0 "*) printf 'discovery\n' >> "$fired"; sleep 1 ;;
  *" -newer "*) printf 'filelist\n' >> "$fired"; sleep 1 ;;
esac
exec /usr/bin/find "\$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/find"
  run clikae burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$STUB_LEFT_REPO" -- noop
  [ "$status" -eq 1 ]
  local json_elapsed status_elapsed status_file
  json_elapsed="$(printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c 'import json,sys; print(json.load(sys.stdin)["elapsed_s"])')"
  status_file="$(find "$TEST_HOME/.clikae/logs" -name status.json | head -1)"
  [ -n "$status_file" ]
  status_elapsed="$(python3 -c "import json; print(json.load(open('$status_file'))['elapsed_s'])")"
  # The scan alone (repo discovery + the file-list find, each shimmed to
  # sleep 1s) costs >=2s; a pre-fix elapsed_s would show that. Both numbers
  # here should still read close to 0 (whatever cmd_burn did before the
  # scan even started) and agree with each other and with the summary line.
  [ "$json_elapsed" -lt 2 ]
  [ "$status_elapsed" -lt 2 ]
  local diff=$((json_elapsed - status_elapsed)); [ "${diff#-}" -le 1 ]
  [[ "$output" == *"elapsed=${json_elapsed}s"* ]] || false
  # …and the 2s the assertions above are measured against actually happened:
  # both scan `find` shapes must have gone through the shim.
  [ -s "$fired" ] || { echo "the scan find shim never fired — elapsed_s < 2 proved nothing"; false; }
  grep -q '^discovery$' "$fired" || { echo "discovery find never matched the shim:"; cat "$fired"; false; }
  grep -q '^filelist$' "$fired" || { echo "file-list find never matched the shim:"; cat "$fired"; false; }
}

# P2-4 (round-1 review): `find` never follows a symlink given as its own
# start point without -H/-L. `--add-dir` pointed at a symlink to a directory
# FULL of repos (this machine has ~/tools -> ~/Developer/cver-tools; macOS's
# $TMPDIR itself is a symlink, so any --add-dir "$TMPDIR/…" hit this)
# silently found nothing — the review's own repro. Resolving each root with
# `cd "$root" && pwd -P` before repo discovery (mirroring what the file
# scan already did) fixes it.
@test "burn #84 P2-4: an --add-dir that is a symlink to a directory of repos is still scanned" {
  _left84_setup
  _left84_repo
  ln -s "$TEST_HOME/repos" "$TEST_HOME/repos-link"
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'saved work\n' > "$STUB_LEFT_REPO/saved.txt"
git -C "$STUB_LEFT_REPO" add saved.txt
git -C "$STUB_LEFT_REPO" commit -qm saved
STUB
  run clikae burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$TEST_HOME/repos-link" -- noop
  [ "$status" -eq 1 ]
  [[ "$output" == *"left behind:"*"ahead 1 dirty 0"* ]] || false
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c '
import json, sys
rows = json.load(sys.stdin)["left_behind"]
assert len(rows) == 1, rows
assert rows[0]["ahead"] == 1, rows
'
}

# P2-1 (round-2 review): round-1's wall budget wrapped the file-list `find`
# only — every `_burn_lb_git` call ran bare, so a hung git call could block
# `_burn_left_behind` (and therefore all of `burn`) forever. `.git/HEAD`
# replaced by a FIFO reproduces the real trigger (a dead NFS/SMB mount, a
# wedged git process) without one: `git rev-parse`/`symbolic-ref`/`status`
# all block in open(2) waiting for a writer that never comes (verified: all
# three hang past a 3s external `timeout` on plain git, no clikae involved).
# `_burn_lb_bounded`'s 5s per-call bound must catch this and let the whole
# `clikae burn` process finish — this test's real assertion IS that `run`
# below returns at all; the wall-clock check just makes "how bounded" concrete.
# P3-3 (round-3 review): the assertion above was never backed by anything —
# a regression that hangs `burn` itself hangs `run` right along with it, and
# a bats test that never returns doesn't fail, it wedges the whole suite
# (reproduced: 10+ minutes on real bash 3.2 before P2-1's own fix, in a
# pre-push hook that would have looked exactly like a stuck terminal). An
# external `timeout -s KILL` around the real binary — NOT around the
# `clikae` bats helper function above, which `timeout` cannot see or signal
# — gives this test its own hard ceiling independent of whatever the bound
# under test does.
@test "burn #84 P2-1 (round-2 review): a .git/HEAD FIFO cannot hang burn past its budget" {
  # Stock macOS ships neither `timeout` nor `gtimeout` (`_burn_timeout_bin`'s
  # own comment) — this test's own safety net needs one regardless of what
  # burn.sh falls back to, so skip rather than wedge the runner without it.
  # `gtimeout` (coreutils via Homebrew) covers a macOS box that installed it.
  local timeout_bin
  timeout_bin="$(command -v timeout || command -v gtimeout || true)"
  [ -n "$timeout_bin" ] || skip "no \`timeout\`/\`gtimeout\` on PATH to bound this test itself"
  _left84_setup
  _left84_repo
  rm -f "$STUB_LEFT_REPO/.git/HEAD"
  mkfifo "$STUB_LEFT_REPO/.git/HEAD"
  local t0 t1
  t0="$(date +%s)"
  run "$timeout_bin" -s KILL 60 "$CLIKAE_BIN" burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$STUB_LEFT_REPO" -- noop
  t1="$(date +%s)"
  # Generous ceiling (5s bound + a few other fast calls + engine overhead) —
  # the point is "finishes", not "finishes in exactly N seconds".
  [ "$((t1 - t0))" -lt 30 ] || { echo "took $((t1 - t0))s"; false; }
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c 'import json, sys; json.load(sys.stdin)'
}

# P2-3 (round-1 review, unresolved until round-2): `-maxdepth 3` capped repo
# discovery 2 levels below the scanned root. `--add-dir <root>` with repos at
# increasing depth (L1/a/L2/a/b/L3/a/b/c/L4 — a/b/c/L4's `.git` is 5 levels
# below root, well past the old cap) reproduces "a lane's commits in a
# nested repo" (#84's own title) going completely silent: no row, no hint.
# `inner` is ACTUALLY nested inside L1's own working tree (not just deep
# under the same --add-dir root) — the fixture that exercises innermost
# attribution for real: pre-fix, L1's file scan walked straight through
# inner's `.git` boundary and inner/WORK.md came back in L1's `files`.
@test "burn #84 P2-3 (round-2 review): nested repos at any depth get their own row and hint; files attribute to the innermost repo" {
  _stub_burn_transport
  clikae init codex T1
  mkdir -p "$TEST_HOME/scan"
  cd "$TEST_HOME/scan" || return 1
  local d
  for d in L1 a/L2 a/b/L3 a/b/c/L4 L1/vendor/inner; do
    git init -q "$TEST_HOME/repos/$d"
    git -C "$TEST_HOME/repos/$d" config user.name t
    git -C "$TEST_HOME/repos/$d" config user.email t@example.invalid
    git -C "$TEST_HOME/repos/$d" commit -q --allow-empty -m init
    git -C "$TEST_HOME/repos/$d" branch base
    git -C "$TEST_HOME/repos/$d" branch --set-upstream-to=base >/dev/null
  done
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<STUB
#!/usr/bin/env bash
for d in L1 a/L2 a/b/L3 a/b/c/L4 L1/vendor/inner; do
  printf work > "$TEST_HOME/repos/\$d/WORK.md"
  git -C "$TEST_HOME/repos/\$d" add WORK.md
  git -C "$TEST_HOME/repos/\$d" commit -q -m work
done
STUB
  run clikae burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$TEST_HOME/repos" -- noop
  [ "$status" -eq 1 ]
  for d in L1 a/L2 a/b/L3 a/b/c/L4 L1/vendor/inner; do
    [[ "$output" == *"hint: git -C "*"/repos/$d push"* ]] || { echo "missing hint for $d"; false; }
  done
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c '
import json, sys
rows = json.load(sys.stdin)["left_behind"]
byname = {r["repo"].rsplit("/repos/", 1)[1]: r for r in rows}
for d in ["L1", "a/L2", "a/b/L3", "a/b/c/L4", "L1/vendor/inner"]:
    assert d in byname, (d, sorted(byname))
    assert byname[d]["ahead"] == 1, byname[d]
# innermost attribution: inner is INSIDE L1s own working tree — its
# WORK.md must show up only under inner, never re-listed under L1.
l1_files = byname["L1"]["files"]
assert not any("vendor/inner" in f for f in l1_files), l1_files
assert any("WORK.md" in f for f in byname["L1/vendor/inner"]["files"]), byname["L1/vendor/inner"]
'
}

# P3-3/criteria (round-1 review): "ahead" used to be a multityped JSON field
# (string "-" or a bare integer) — this asserts the fix (an int or JSON
# null, never a sentinel string) on the qualifying side: ahead>0 alone, with
# a KNOWN upstream and nothing else touched, still gets reported.
@test "burn #84 P3-3: ahead>0 alone (known upstream, nothing else changed) qualifies" {
  _left84_setup
  _left84_repo
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
git -C "$STUB_LEFT_REPO" commit -q --allow-empty -m "ahead only"
STUB
  run clikae burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$STUB_LEFT_REPO" -- noop
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c '
import json, sys
rows = json.load(sys.stdin)["left_behind"]
assert len(rows) == 1, rows
assert rows[0]["ahead"] == 1 and rows[0]["dirty"] == 0, rows
'
}

# Same criterion, the non-qualifying side: "ahead" with NO known upstream is
# "-" (JSON null), and that alone — no dirty state, no post-start files —
# must not be enough to report the repo.
@test "burn #84 P3-3: ahead with no known upstream, clean, no new files does not qualify" {
  _left84_setup
  _left84_repo
  git -C "$STUB_LEFT_REPO" branch --unset-upstream
  run clikae burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$STUB_LEFT_REPO" -- noop
  [ "$status" -eq 1 ]
  [[ "$output" != *"left behind:"* ]] || false
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c 'import json,sys; assert json.load(sys.stdin)["left_behind"] == []'
}

# P2-6 (round-1 review): the PR's own headline claim ("Read-only: nothing is
# pushed or modified") had zero bats coverage — the six existing #84 tests
# cover shapes, not the read-only guarantee itself. This is the reviewer's
# own ruler, as a test: a `.git`-wide `find -newer` sentinel (touched, then
# a 1s sleep so the sentinel sorts strictly before anything the scan might
# write, regardless of this filesystem's own mtime resolution) proves
# nothing under `.git` changed, and a sentinel-writing hook installed under
# every hook name from the review (including the ones `core.fsmonitor`/
# `core.hooksPath` on the command line — P3-4/decision 1 — are specifically
# there to defeat) proves none of them fired.
@test "burn #84 P2-6: the left-behind scan is provably read-only — .git untouched, no hook fires" {
  _left84_setup
  _left84_repo
  local hooks_dir="$STUB_LEFT_REPO/.git/hooks" sentinel_dir="$BATS_TEST_TMPDIR/hook-sentinels"
  mkdir -p "$hooks_dir" "$sentinel_dir"
  local h
  for h in pre-commit post-commit post-index-change pre-auto-gc reference-transaction post-checkout fsmonitor-watchman; do
    cat > "$hooks_dir/$h" <<HOOK
#!/usr/bin/env bash
: > "$sentinel_dir/$h.fired"
exit 0
HOOK
    chmod +x "$hooks_dir/$h"
  done
  git -C "$STUB_LEFT_REPO" config core.hooksPath .git/hooks
  # P3-1 (round-2 review): a mutation test (drop `-c core.hooksPath=/dev/null`
  # and rerun) found only `core.fsmonitor` below actually fires under
  # mutation — none of the seven named hooks in this loop do, because the
  # four read-only git subcommands `_burn_lb_git` ever calls
  # (rev-parse/symbolic-ref/rev-list/status) don't invoke a NAMED hook to
  # begin with. Left in as defense-in-depth (a future call site here that
  # DOES trigger one is still covered), but its seven `not fired` assertions
  # are honestly air, not evidence — the fire test below the fsmonitor block
  # is the only one of the eight with independently confirmed teeth.
  #
  # P3-4's actual repro: `core.fsmonitor` set to an arbitrary executable
  # PATH (not the named `fsmonitor-watchman` hook above — git treats these
  # as two different mechanisms; only `core.fsmonitor=true` invokes the
  # named hook, so it needed its own sentinel).
  local fsmon="$BATS_TEST_TMPDIR/fsmonitor-hook"
  cat > "$fsmon" <<HOOK
#!/usr/bin/env bash
: > "$sentinel_dir/core.fsmonitor.fired"
printf '1\n'
HOOK
  chmod +x "$fsmon"
  git -C "$STUB_LEFT_REPO" config core.fsmonitor "$fsmon"
  local snap="$BATS_TEST_TMPDIR/git-snapshot-sentinel"
  : > "$snap"
  sleep 1
  run clikae burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$STUB_LEFT_REPO" -- noop
  [ "$status" -eq 1 ]
  local newer; newer="$(find "$STUB_LEFT_REPO/.git" -newer "$snap" 2>/dev/null)"
  [ -z "$newer" ] || { echo "changed under .git: $newer"; return 1; }
  [ ! -e "$sentinel_dir/core.fsmonitor.fired" ] || { echo "core.fsmonitor hook fired"; return 1; }
  for h in pre-commit post-commit post-index-change pre-auto-gc reference-transaction post-checkout fsmonitor-watchman; do
    [ ! -e "$sentinel_dir/$h.fired" ] || { echo "hook fired: $h"; return 1; }
  done
}

# P3-2 (round-2 review): this proves the MEASURING METHOD works (git really
# does rewrite .git/index on this machine when nothing stops it) — it does
# NOT exercise `_burn_left_behind`, `clikae burn`, or any production call
# site (it's a hand-written `git -C … status --porcelain` in the test body).
# "negative control" implied it was testing the production read-only guard
# under mutation; renamed to say what it actually is. The read-only claim's
# real mutation coverage is `:2844`'s "GIT_OPTIONAL_LOCKS"/"core.fsmonitor"
# drops (see the round-2 review's own mutation table) — this test is
# evidence that those mutations mean something, not the guard itself.
@test "burn #84 P2-6 ruler sanity: without GIT_OPTIONAL_LOCKS, git status DOES touch .git/index" {
  _left84_setup
  _left84_repo
  # _left84_repo's own commit is --allow-empty (no tracked files), so
  # there's nothing for git's lazy stat-cache refresh to find stale — a
  # tracked file, re-touched (same content, new mtime) after its commit, is
  # what actually makes `git status` want to rewrite the index.
  printf tracked > "$STUB_LEFT_REPO/tracked.txt"
  git -C "$STUB_LEFT_REPO" add tracked.txt
  git -C "$STUB_LEFT_REPO" commit -qm tracked
  sleep 1
  touch "$STUB_LEFT_REPO/tracked.txt"
  local before after
  before="$(stat -c '%i' "$STUB_LEFT_REPO/.git/index" 2>/dev/null || stat -f '%i' "$STUB_LEFT_REPO/.git/index")"
  ( unset GIT_OPTIONAL_LOCKS; git -C "$STUB_LEFT_REPO" status --porcelain >/dev/null )
  after="$(stat -c '%i' "$STUB_LEFT_REPO/.git/index" 2>/dev/null || stat -f '%i' "$STUB_LEFT_REPO/.git/index")"
  [ "$before" != "$after" ]
}

# P3-2 (round-1 review): the push hint used to print for only the FIRST
# ahead repo — three ahead repos, one copy-pasteable command. One hint per
# ahead repo now.
@test "burn #84 P3-2: every ahead repo gets its own push hint, not just the first" {
  _stub_burn_transport
  clikae init codex T1
  mkdir -p "$TEST_HOME/scan" "$TEST_HOME/repos"
  cd "$TEST_HOME/scan" || return 1
  local i
  for i in a b c; do
    git init -q "$TEST_HOME/repos/r$i"
    git -C "$TEST_HOME/repos/r$i" config user.name t
    git -C "$TEST_HOME/repos/r$i" config user.email t@example.invalid
    git -C "$TEST_HOME/repos/r$i" commit -q --allow-empty -m init
    git -C "$TEST_HOME/repos/r$i" branch base
    git -C "$TEST_HOME/repos/r$i" branch --set-upstream-to=base >/dev/null
  done
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<STUB
#!/usr/bin/env bash
for i in a b c; do
  git -C "$TEST_HOME/repos/r\$i" commit -q --allow-empty -m "ahead \$i"
done
STUB
  run clikae burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$TEST_HOME/repos" -- noop
  [ "$status" -eq 1 ]
  for i in a b c; do
    [[ "$output" == *"hint: git -C "*"/repos/r$i push"* ]] || { echo "missing hint for r$i"; false; }
  done
}

# P3-5 (round-1 review): a submodule with its own uncommitted change used to
# count as "dirty" in BOTH its own row and the superproject's — but the
# superproject's push never carries the submodule's changes, so attributing
# them to it overstates what pushing the superproject would salvage.
# P3-5 (round-2 review, unresolved until now): the SAME contradiction was
# still open one level down — `--ignore-submodules=all` made `dirty` honest
# but the superproject's `files` list still walked straight into the
# submodule and listed its files anyway (self-contradicting: "dirty:0,
# files:[…/sub/…]" in the same row). A file written into the submodule
# DURING the run must show up under the submodule's OWN row, never
# re-listed under the superproject's — the same innermost-repo file pruning
# P2-3 added for nested repos (they're the same mechanism: a `.git`
# boundary inside the tree being scanned).
@test "burn #84 P3-5: a submodule's own dirty state and files are not double-counted into the superproject's" {
  _left84_setup
  _left84_repo
  local sub="$TEST_HOME/repos/subrepo"
  git init -q "$sub"
  git -C "$sub" config user.name t; git -C "$sub" config user.email t@example.invalid
  printf sub > "$sub/s.txt"; git -C "$sub" add s.txt; git -C "$sub" commit -qm sub-init
  git -c protocol.file.allow=always -C "$STUB_LEFT_REPO" submodule add -q "$sub" sub
  git -C "$STUB_LEFT_REPO" commit -qm "add submodule"
  printf changed > "$STUB_LEFT_REPO/sub/s.txt"
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf newsub > "$STUB_LEFT_REPO/sub/new-in-sub.txt"
STUB
  run clikae burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$STUB_LEFT_REPO" -- noop
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c '
import json, sys
rows = json.load(sys.stdin)["left_behind"]
super_row = next(r for r in rows if r["repo"].rstrip("/").endswith("work space"))
assert super_row["dirty"] == 0, super_row
assert super_row["ahead"] == 1, super_row
assert not any("new-in-sub.txt" in f for f in super_row["files"]), super_row
sub_row = next((r for r in rows if r["repo"].rstrip("/").endswith("/sub")), None)
assert sub_row is not None, [r["repo"] for r in rows]
assert any("new-in-sub.txt" in f for f in sub_row["files"]), sub_row
'
}

# --- round-5 review -----------------------------------------------------------

# `_burn_lb_bounded` on its own, with no burn around it: these three assert the
# bound's own contract (kill the whole process group; report 124 only when the
# watchdog actually fired) at a granularity a full `clikae burn` cannot reach.
# Sourcing `lib/commands/burn.sh` directly is this suite's own established
# pattern for a helper with no command-line surface (see limit.bats,
# agy-email.bats, antigravity_keychain_real.bats).
_burn_lb_boot() {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  # shellcheck source=../../lib/core/log.sh
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=../../lib/commands/burn.sh
  source "$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
}

# P2-1 (round-5 review): TERM+KILL aimed at the single pid `$!` names leaves
# every child that pid forked running past the deadline. `find`'s own `-exec`
# IS that shape — `-exec test -e {}/.git \;` forks once per directory and
# `-exec stat … {} +` once per batch — so the bound was never bounding the
# scan's most expensive call. A process group makes "the child" mean "the
# child and everything it forked".
@test "burn #84 P2-1 (round-5 review): the bound kills a forking child's whole process group" {
  _burn_lb_boot
  local forker="$BATS_TEST_TMPDIR/forker" pidfile="$BATS_TEST_TMPDIR/grandchild.pid"
  cat > "$forker" <<STUB
#!/usr/bin/env bash
# Forks a child and does NOT exec it — exactly \`find -exec\`'s own shape,
# and the shape TERM+KILL aimed at \`\$!\` alone cannot reach.
sleep 120 &
echo \$! > "$pidfile"
wait
STUB
  chmod +x "$forker"
  local t0 t1 rc=0 gpid=""
  t0="$(date +%s)"
  _burn_lb_bounded 3 "$forker" || rc=$?
  t1="$(date +%s)"
  [ -s "$pidfile" ] || { echo "forker never recorded its child"; false; }
  gpid="$(cat "$pidfile")"
  # Whatever this assertion does, never leave the grandchild behind.
  sleep 1
  local alive=0
  kill -0 "$gpid" 2>/dev/null && alive=1
  kill -KILL "$gpid" 2>/dev/null || true
  [ "$((t1 - t0))" -lt 10 ] || { echo "bounded call took $((t1 - t0))s"; false; }
  [ "$rc" -eq 124 ] || { echo "rc=$rc, expected 124"; false; }
  [ "$alive" -eq 0 ] || { echo "grandchild $gpid outlived the bound"; false; }
}

# P3-3 (round-5 review, same root as r3 P3-1): `[ $((SECONDS - start)) -lt
# "$secs" ]` is an INTEGER comparison of a clock that ticks on absolute
# second boundaries — a call that starts 0.01s before a tick and runs 4.1s
# under a 5s bound measures as 5 and gets reported as a timeout it never hit.
# Aligning to the boundary on purpose makes that deterministic instead of a
# coin flip (measured 4/8 on the real thing).
@test "burn #84 P3-3 (round-5 review): a bounded call that finished in time never reports 124" {
  _burn_lb_boot
  local rc=0 s0
  # $SECONDS ticks on ABSOLUTE second boundaries (bash reads time(2), whole
  # seconds), so the offset that matters is measured from the boundary, not
  # from the assignment. Wait for a tick, re-zero on it, then spend 0.9s of
  # that second before the bounded call starts: the call begins at ~.9 and
  # ends at ~5.05 — 4.15s of real time under a 5s bound, but two integer
  # ticks apart.
  SECONDS=0; s0=$SECONDS
  while [ "$SECONDS" -eq "$s0" ]; do sleep 0.02; done
  SECONDS=0
  sleep 0.9
  _burn_lb_bounded 5 sleep 4.15 || rc=$?
  [ "$rc" -ne 124 ] || { echo "phantom timeout: a 4.1s command under a 5s bound reported 124"; false; }
  [ "$rc" -eq 0 ] || { echo "rc=$rc, expected 0"; false; }
}

# The other direction of the same assertion: a real timeout must still be 124.
@test "burn #84 P3-3 (round-5 review): a bounded call that really overran still reports 124" {
  _burn_lb_boot
  local rc=0
  _burn_lb_bounded 2 sleep 30 || rc=$?
  [ "$rc" -eq 124 ] || { echo "rc=$rc, expected 124"; false; }
}

# P2-1 (round-5 review), end to end: the file-list `find`'s batched `stat` is
# the one call in this scan that can be wedged by a dead mount. With the bound
# reaching only `find` itself, `clikae burn` produced NOTHING — no "left
# behind:" block, no JSON, no exit — because the orphaned `stat` still held
# the scan's own command substitution open.
@test "burn #84 P2-1 (round-5 review): a never-returning file-list stat cannot hang burn" {
  local timeout_bin
  timeout_bin="$(command -v timeout || command -v gtimeout || true)"
  [ -n "$timeout_bin" ] || skip "no \`timeout\`/\`gtimeout\` on PATH to bound this test itself"
  _left84_setup
  _left84_repo
  # Only the batched mtime read the file-list scan makes hangs; `stat
  # --version` (the platform probe, _clikae_statv) and every other caller
  # must pass straight through or the scan never even gets that far.
  cat > "$BATS_TEST_TMPDIR/bin/stat" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" %Y %n "*|*" %m %N "*) exec sleep 100000 ;;
esac
exec /usr/bin/stat "$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/stat"
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'saved work\n' > "$STUB_LEFT_REPO/saved.txt"
git -C "$STUB_LEFT_REPO" add saved.txt
git -C "$STUB_LEFT_REPO" commit -qm saved
STUB
  local t0 t1
  t0="$(date +%s)"
  run "$timeout_bin" -s KILL 60 "$CLIKAE_BIN" burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$STUB_LEFT_REPO" -- noop
  t1="$(date +%s)"
  [ "$((t1 - t0))" -lt 40 ] || { echo "took $((t1 - t0))s"; false; }
  [ "$status" -eq 1 ] || { echo "status=$status"; printf '%s\n' "$output"; false; }
  [[ "$output" == *"left behind:"*"ahead 1"* ]] || { printf '%s\n' "$output"; false; }
  [[ "$output" == *"(scan timed out)"* ]] || { printf '%s\n' "$output"; false; }
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c 'import json, sys; json.load(sys.stdin)'
}

# P3-1 (round-5 review): round-4 stopped a merely-slow discovery `find` from
# declaring the whole budget spent, but kept round-2's one sentence for both
# outcomes. A `find` that hit its own 5s ceiling with 4s of the 10s budget
# still unspent printed "and 1 more (scan budget exhausted)" — which points a
# reader at a budget knob when what actually needs attention is the root that
# hung. The two facts now say which one they are.
@test "burn #84 P3-1 (round-5 review): a discovery find that hangs says discovery timed out, not budget exhausted" {
  local timeout_bin
  timeout_bin="$(command -v timeout || command -v gtimeout || true)"
  [ -n "$timeout_bin" ] || skip "no \`timeout\`/\`gtimeout\` on PATH to bound this test itself"
  _left84_setup
  _left84_repo
  # ONE root (the cwd, which is the payload repo itself) so the 5s discovery
  # ceiling cannot also exhaust the 10s global budget — this test is about
  # which sentence gets printed, and both sentences firing would prove
  # nothing about either.
  cd "$STUB_LEFT_REPO" || return 1
  # P3-2 (round-5 review): a shim keyed on the implementation's own flags
  # goes silently inert the day those flags change, and a test whose shim
  # never fires passes for the wrong reason. This one records that it fired
  # and the assertions below demand it.
  local fired="$BATS_TEST_TMPDIR/discovery-find-fired"
  cat > "$BATS_TEST_TMPDIR/bin/find" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" -name .git -print0 "*) printf 'x' >> "$fired"; exec sleep 100000 ;;
esac
exec /usr/bin/find "\$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/find"
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'saved work\n' > "$STUB_LEFT_REPO/saved.txt"
git -C "$STUB_LEFT_REPO" add saved.txt
git -C "$STUB_LEFT_REPO" commit -qm saved
STUB
  run "$timeout_bin" -s KILL 60 "$CLIKAE_BIN" burn codex T1 --json --artifact "$TEST_HOME/missing" -- noop
  [ -s "$fired" ] || { echo "the discovery find shim never fired — this test asserted nothing"; false; }
  [ "$status" -eq 1 ] || { echo "status=$status"; printf '%s\n' "$output"; false; }
  [[ "$output" == *"discovery timed out after 5s"* ]] || { printf '%s\n' "$output"; false; }
  [[ "$output" != *"scan budget exhausted"* ]] || { echo "still blaming the budget"; printf '%s\n' "$output"; false; }
  # round-4's own property, still standing: a bounded discovery call that
  # times out costs that root's unlisted repos, not the one already in hand.
  [[ "$output" == *"left behind:"*"ahead 1"* ]] || { printf '%s\n' "$output"; false; }
}

# P3-4 (round-5 review): with two roots whose discovery `find` each burns the
# full 5s ceiling, the 10s budget is gone by the time the per-repo loop
# starts — and the loop's own budget check then threw away the payload repo
# that discovery had ALREADY found and put in `repos[]`. Measured pre-fix:
# zero rows, `left_behind_truncated: 4`. Honest and bounded, and still the
# one row #84 exists to print.
@test "burn #84 P3-4 (round-5 review): a root repo already discovered survives the budget boundary" {
  local timeout_bin
  timeout_bin="$(command -v timeout || command -v gtimeout || true)"
  [ -n "$timeout_bin" ] || skip "no \`timeout\`/\`gtimeout\` on PATH to bound this test itself"
  _left84_setup
  _left84_repo
  local fired="$BATS_TEST_TMPDIR/discovery-find-fired"
  cat > "$BATS_TEST_TMPDIR/bin/find" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" -name .git -print0 "*) printf 'x' >> "$fired"; exec sleep 100000 ;;
esac
exec /usr/bin/find "\$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/find"
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'saved work\n' > "$STUB_LEFT_REPO/saved.txt"
git -C "$STUB_LEFT_REPO" add saved.txt
git -C "$STUB_LEFT_REPO" commit -qm saved
STUB
  local t0 t1
  t0="$(date +%s)"
  run "$timeout_bin" -s KILL 90 "$CLIKAE_BIN" burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$STUB_LEFT_REPO" -- noop
  t1="$(date +%s)"
  # Both roots' discovery must really have hung, or this asserts nothing.
  [ "$(wc -c < "$fired" | tr -d ' ')" -ge 2 ] || { echo "discovery shim fired $(wc -c < "$fired") time(s), expected 2"; false; }
  [ "$((t1 - t0))" -lt 45 ] || { echo "took $((t1 - t0))s"; false; }
  [ "$status" -eq 1 ] || { echo "status=$status"; printf '%s\n' "$output"; false; }
  [[ "$output" == *"left behind:"*"ahead 1"* ]] || { echo "the already-discovered root repo vanished"; printf '%s\n' "$output"; false; }
  [[ "$output" == *"hint: git -C "*" push"* ]] || { printf '%s\n' "$output"; false; }
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c '
import json, os, sys
d = json.load(sys.stdin)
rows = d["left_behind"]
assert len(rows) == 1, rows
assert rows[0]["repo"] == os.path.realpath(os.environ["STUB_LEFT_REPO"]), rows
assert rows[0]["ahead"] == 1, rows
# the roots whose discovery hung are still counted, just not INSTEAD of this row
assert d["left_behind_truncated"] >= 1, d
'
}
# --- round-6 review -----------------------------------------------------------

# P3-1 (round-6 review): `_burn_lb_pgroup_probe` proves the platform can be
# aimed at a process group; nothing proved the VALUE handed to `_burn_lb_kill`
# was a pid at all. `kill -- -0` is POSIX for "the caller's own process group",
# so one bad argument takes burn AND the operator's shell with it. Asserted
# against a shell FUNCTION named `kill` (a function wins over the builtin) so
# a regression cannot signal this test runner's own group: the assertion is
# that the guard returns before `kill` is reached at all.
@test "burn #84 P3-1 (round-6 review): _burn_lb_kill refuses every value that is not a signalable pid" {
  _burn_lb_boot
  local log="$BATS_TEST_TMPDIR/kill-args"
  : > "$log"
  kill() { printf '%s\n' "$*" >> "$log"; return 0; }
  _BURN_LB_PGROUP=1
  local bad rc
  for bad in 0 -1 '' abc 1 '2x' '-' ; do
    rc=0
    _burn_lb_kill TERM "$bad" || rc=$?
    [ "$rc" -eq 1 ] || { echo "_burn_lb_kill TERM '$bad' returned $rc, expected 1 (refused)"; false; }
  done
  [ ! -s "$log" ] || { echo "the guard let a refused value through to kill:"; cat "$log"; false; }
  # The one refusal that looks like an ordinary pid: our own process group.
  local mypgid
  mypgid="$(ps -o pgid= -p $$ 2>/dev/null || true)"
  mypgid="${mypgid// /}"
  case "$mypgid" in ''|*[!0-9]*) mypgid='' ;; esac
  if [ -n "$mypgid" ]; then
    rc=0
    _burn_lb_kill TERM "$mypgid" || rc=$?
    [ "$rc" -eq 1 ] || { echo "_burn_lb_kill did NOT refuse our own pgid $mypgid (rc=$rc)"; false; }
    [ ! -s "$log" ] || { echo "our own process group was signalled:"; cat "$log"; false; }
  fi
  # …and a real child pid still gets the group signal the fix exists to send.
  sleep 30 &
  local child=$!
  [ "$child" -gt 1 ] || { echo "no child pid to test with"; false; }
  rc=0
  _burn_lb_kill TERM "$child" || rc=$?
  [ "$rc" -eq 0 ] || { echo "a legitimate pid was refused (rc=$rc)"; false; }
  grep -q -- "-TERM -- -$child" "$log" || { echo "expected a group TERM for $child, got:"; cat "$log"; false; }
  unset -f kill
  builtin kill -KILL "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
}

# The same finding with a REAL `kill`, contained: `setsid` gives the probe a
# session of its own, so a regression kills only that session. Measured on the
# pre-fix helper exactly this way — the probe never printed its next line, it
# exited with rc=15, and its own sentinel child died with it.
@test "burn #84 P3-1 (round-6 review): a real \`_burn_lb_kill TERM 0\` leaves its caller and its children alive" {
  command -v setsid >/dev/null 2>&1 || skip "setsid needed to contain the group kill this asserts against"
  local probe="$BATS_TEST_TMPDIR/probe-p31"
  cat > "$probe" <<STUB
#!/usr/bin/env bash
export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
source "$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
_BURN_LB_PGROUP=1
sleep 30 &
sentinel=\$!
rc=0
_burn_lb_kill TERM 0 || rc=\$?
printf 'returned %s\n' "\$rc"
if kill -0 "\$sentinel" 2>/dev/null; then printf 'sentinel alive\n'; else printf 'sentinel dead\n'; fi
[ "\$sentinel" -gt 1 ] && kill -KILL "\$sentinel" 2>/dev/null
printf 'caller survived\n'
STUB
  chmod +x "$probe"
  run setsid -w bash "$probe"
  [[ "$output" == *"returned 1"* ]] || { echo "no refusal; probe said: $output"; false; }
  [[ "$output" == *"sentinel alive"* ]] || { echo "the caller's own child was killed: $output"; false; }
  [[ "$output" == *"caller survived"* ]] || { echo "the caller never came back: $output"; false; }
}

# P3-6 (round-6 review): the watchdog's mark was the one path in this file
# assembled by hand (`$TMPDIR/clikae-lb-kill.$$.$pid`) while disc/scan/rank all
# used `mktemp`. Both ingredients are readable by any other user of a shared
# /tmp: pre-create that name and the call reports a timeout that never
# happened; make it a symlink and the watchdog's write truncates whatever it
# points at. The poller below watches $TMPDIR for the whole bounded call and
# the assertion is on the NAME, not just on the cleanup.
@test "burn #84 P3-6 (round-6 review): the watchdog's mark is an unguessable mktemp path, and nothing is left behind" {
  _burn_lb_boot
  local tmp="$BATS_TEST_TMPDIR/marktmp"; mkdir -p "$tmp"
  export TMPDIR="$tmp"
  local seen="$BATS_TEST_TMPDIR/seen-names"; : > "$seen"
  ( for _i in $(seq 1 160); do ls -A "$tmp" >> "$seen" 2>/dev/null; sleep 0.05; done ) &
  local poller=$!
  local rc=0
  _burn_lb_bounded 2 sleep 30 || rc=$?
  [ "$poller" -gt 1 ] 2>/dev/null || { echo "bad poller pid"; false; }
  kill -TERM "$poller" 2>/dev/null || true
  wait "$poller" 2>/dev/null || true
  [ "$rc" -eq 124 ] || { echo "rc=$rc, expected 124"; false; }
  grep -q '^clikae-lb-kill\.' "$seen" || { echo "never saw a kill mark at all — this test proved nothing:"; cat "$seen"; false; }
  ! grep -qE '^clikae-lb-kill\.[0-9]+\.[0-9]+$' "$seen" || { echo "the mark still uses the guessable pid-pair name:"; cat "$seen"; false; }
  [ -z "$(ls -A "$tmp")" ] || { echo "the mark outlived the call:"; ls -A "$tmp"; false; }
}

# P3-3 (round-6 review): the watchdog's KILL is a GROUP kill and it was
# unreachable — `wait "$pid"` returns the instant the DIRECT child dies of
# TERM, and the parent then killed the watchdog mid-grace. Measured pre-fix: a
# TERM-ignoring direct child => 0 survivors (the parent was still in `wait`),
# but a child that dies of TERM with a TERM-ignoring child of its own => 1
# survivor, still alive three seconds later.
@test "burn #84 P3-3 (round-6 review): the group KILL still fires when the direct child dies of TERM first" {
  _burn_lb_boot
  local forker="$BATS_TEST_TMPDIR/forker-term" pidfile="$BATS_TEST_TMPDIR/term.pid"
  cat > "$forker" <<STUB
#!/usr/bin/env bash
# This one dies on TERM. Its child does not — only the escalation reaches it.
bash -c 'trap "" TERM; while :; do sleep 0.5; done' &
echo \$! > "$pidfile"
wait
STUB
  chmod +x "$forker"
  local t0 t1 rc=0
  t0="$(date +%s)"
  _burn_lb_bounded 2 "$forker" || rc=$?
  t1="$(date +%s)"
  [ -s "$pidfile" ] || { echo "the forker never recorded its child"; false; }
  local gpid; gpid="$(cat "$pidfile")"
  sleep 1
  local alive=0
  [ "$gpid" -gt 1 ] 2>/dev/null || { echo "bad child pid '$gpid'"; false; }
  kill -0 "$gpid" 2>/dev/null && alive=1
  kill -KILL "$gpid" 2>/dev/null || true
  [ "$rc" -eq 124 ] || { echo "rc=$rc, expected 124"; false; }
  [ "$((t1 - t0))" -lt 10 ] || { echo "bounded call took $((t1 - t0))s"; false; }
  [ "$alive" -eq 0 ] || { echo "the TERM-ignoring grandchild $gpid outlived the escalation"; false; }
}

# P3-5 (round-6 review): the 137/143 fallback used to run whenever no mark
# existed — which, before the mark became an `mktemp` file created up front,
# was every ordinary run. So ANY child killed from outside (the OOM killer, a
# maintainer's `pkill`) at or past the deadline was reported as a timeout burn
# invented. The child below kills ITSELF with TERM 4.2s into a 5s bound, from a
# start deliberately aligned 0.9s into a `$SECONDS` tick: the old integer clock
# reads 5 and says 124; the real answer is 143.
@test "burn #84 P3-5 (round-6 review): a child killed from outside near the deadline reports its signal, not a timeout" {
  _burn_lb_boot
  local stub="$BATS_TEST_TMPDIR/selfkill"
  cat > "$stub" <<'STUB'
#!/usr/bin/env bash
sleep 4.2
self=$$
case "$self" in ''|*[!0-9]*) exit 9 ;; esac
[ "$self" -gt 1 ] || exit 9
kill -TERM "$self"
sleep 5
STUB
  chmod +x "$stub"
  local rc=0 s0
  SECONDS=0; s0=$SECONDS
  while [ "$SECONDS" -eq "$s0" ]; do sleep 0.02; done
  SECONDS=0
  sleep 0.9
  _burn_lb_bounded 5 "$stub" || rc=$?
  [ "$rc" -ne 124 ] || { echo "an externally killed child was reported as a timeout it never hit"; false; }
  [ "$rc" -eq 143 ] || { echo "rc=$rc, expected 143 (killed by SIGTERM from outside)"; false; }
}

# P3-2 (round-6 review): `set -m` is what gives the bounded child its own
# process group — and a terminal sends SIGINT only to its FOREGROUND group, so
# from that fix onwards Ctrl-C stopped reaching the scan. Measured pre-fix:
# burn died instantly and the child plus its own children kept running with
# ppid=1 for the rest of the bound. The bound here (20s) is far longer than
# this test's own patience on purpose: only the INT forward can end it in time.
@test "burn #84 P3-2 (round-6 review): an interrupt during a bounded call stops the scan's own process group" {
  local timeout_bin
  timeout_bin="$(command -v timeout || command -v gtimeout || true)"
  [ -n "$timeout_bin" ] || skip "no \`timeout\`/\`gtimeout\` on PATH to bound this test itself"
  local forker="$BATS_TEST_TMPDIR/forker-int" pidfile="$BATS_TEST_TMPDIR/int.pid" probe="$BATS_TEST_TMPDIR/probe-int"
  local probe_out="$BATS_TEST_TMPDIR/probe-int.out"
  cat > "$forker" <<STUB
#!/usr/bin/env bash
# A background job of a shell WITHOUT job control inherits SIGINT=SIG_IGN
# (POSIX), which \`find\`'s own \`-exec\` children never do — find is not a
# shell. python3 puts the disposition back to default before exec so this
# fixture has the shape the fix is actually about, not a shell artefact.
python3 -c 'import os, signal; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp("sleep", ["sleep", "120"])' &
echo \$! > "$pidfile"
wait
STUB
  chmod +x "$forker"
  cat > "$probe" <<STUB
#!/usr/bin/env bash
export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
source "$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
self=\$\$
( sleep 2; [ "\$self" -gt 1 ] && kill -INT "\$self" 2>/dev/null ) &
rc=0
_burn_lb_bounded 20 "$forker" || rc=\$?
printf 'bounded returned %s\n' "\$rc"
STUB
  chmod +x "$probe"
  local t0 t1
  t0="$(date +%s)"
  # The probe's own output goes to a FILE, never to `run`'s capture pipe: a
  # child that outlives this call would hold that pipe open and wedge the whole
  # suite (`run` waits for EOF, not for the process — the same fd-lifetime trap
  # `_burn_lb_bounded`'s watchdog redirects itself away from).
  run "$timeout_bin" -s KILL 15 bash -c '"$0" > "$1" 2>&1' "$probe" "$probe_out"
  t1="$(date +%s)"
  [ -s "$pidfile" ] || { echo "the forker never recorded its child"; false; }
  local gpid; gpid="$(cat "$pidfile")"
  sleep 1
  local alive=0
  [ "$gpid" -gt 1 ] 2>/dev/null || { echo "bad child pid '$gpid'"; false; }
  kill -0 "$gpid" 2>/dev/null && alive=1
  kill -KILL "$gpid" 2>/dev/null || true
  [ "$((t1 - t0))" -lt 12 ] || { echo "the interrupt took $((t1 - t0))s to come back"; false; }
  [ "$status" -eq 130 ] || { echo "probe exited $status, expected 130 (it re-raises the interrupt); it said: $(cat "$probe_out" 2>/dev/null)"; false; }
  [ "$alive" -eq 0 ] || { echo "the scan's child $gpid outlived the interrupt"; false; }
}

# P3-4 (round-6 review), end to end: one temp file shared by the whole scan
# meant a writer that outlived its bound kept an open fd on the file the NEXT
# repo reuses. `>` resets the file's LENGTH, never a survivor's OFFSET, so its
# next write lands past a sparse hole — inside the next repo's results.
# Measured pre-fix at function level: repo B's own parser accepted
# `9999999999 /REPO-A-LEAKED/…` rows, and that forged mtime then won repo B's
# activity ranking. The survivor here escapes with `setsid` (the one shape the
# group kill genuinely cannot reach) and the two scans hand off through marker
# files, so nothing in this test depends on a race being won.
@test "burn #84 P3-4 (round-6 review): a write that outlives one repo's scan cannot land in the next repo's file list" {
  local timeout_bin
  timeout_bin="$(command -v timeout || command -v gtimeout || true)"
  [ -n "$timeout_bin" ] || skip "no \`timeout\`/\`gtimeout\` on PATH to bound this test itself"
  command -v setsid >/dev/null 2>&1 || skip "setsid needed to build a writer the group kill cannot reach"
  _left84_setup
  local a="$TEST_HOME/repos/alpha" b="$TEST_HOME/repos/bravo" r
  for r in "$a" "$b"; do
    git init -q "$r"
    git -C "$r" config user.name 'Burn test'
    git -C "$r" config user.email 'burn@example.invalid'
    git -C "$r" commit -qm initial --allow-empty
    printf 'x\n' > "$r/dirty.txt"
  done
  local started="$BATS_TEST_TMPDIR/bravo-started" leaked="$BATS_TEST_TMPDIR/leak-written"
  cat > "$BATS_TEST_TMPDIR/bin/find" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" -newer "*)
    case "\$1" in
      */alpha)
        setsid bash -c 'printf "1111111111 /alpha/%0200d\n" 1; while [ ! -e "$started" ]; do sleep 0.05; done; printf "9999999999 /REPO-A-LEAKED/one\n9999999999 /REPO-A-LEAKED/two\n"; : > "$leaked"' &
        exec sleep 100 ;;
      */bravo)
        : > "$started"
        for _i in \$(seq 1 200); do [ -e "$leaked" ] && break; sleep 0.05; done ;;
    esac ;;
esac
exec /usr/bin/find "\$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/find"
  run "$timeout_bin" -s KILL 90 "$CLIKAE_BIN" burn codex T1 --json --artifact "$TEST_HOME/missing" --add-dir "$a" --add-dir "$b" -- noop
  [ "$status" -eq 1 ] || { echo "burn exited $status; output: $output"; false; }
  # Both halves of the fixture really happened, or the assertion below is empty.
  [ -e "$started" ] || { echo "bravo's scan never ran — nothing was being tested"; false; }
  [ -e "$leaked" ] || { echo "the survivor never wrote — nothing was being tested"; false; }
  [[ "$output" != *"REPO-A-LEAKED"* ]] || { echo "alpha's survivor leaked into the report: $output"; false; }
  printf '%s\n' "$output" | sed -n '/^{/p' | python3 -c '
import json, sys
rows = json.load(sys.stdin)["left_behind"]
bravo = [r for r in rows if r["repo"].endswith("/bravo")]
assert bravo, rows
for f in bravo[0]["files"]:
    assert "REPO-A-LEAKED" not in f, bravo[0]
'
}
