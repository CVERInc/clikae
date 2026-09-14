#!/usr/bin/env bats
# tests/bats/compat.bats — guard against constructs that break macOS bash 3.2.
#
# macOS ships bash 3.2, so the source must avoid bash 4+ idioms and GNU-isms.
# These are source-scanning meta-tests, not behavioural ones.

load '../helpers'

# 🔴 SKIPS WHOLE-LINE COMMENTS. These guards scan source TEXT, and a comment is
# text — so the paragraph written to explain "we deliberately do not use
# readlink -f here" satisfied the assertion that no such call exists, and the
# guard went red at the one place that was obeying it. A check that fires on its
# own documentation teaches people to stop documenting.
#
# Whole-line only, on purpose: a trailing comment still trips it. Erring toward
# a false alarm is right for a guard whose job is to be conservative, and
# stripping `#` correctly out of live shell code is not a job for a grep.
scan() {
  grep -rnE "$1" "$CLIKAE_TEST_ROOT/bin/clikae" "$CLIKAE_TEST_ROOT/lib" \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
}

@test "no mapfile / readarray (bash 4+)" {
  run scan '\b(mapfile|readarray)\b'
  [ -z "$output" ]
}

@test "no \${var,,} / \${var^^} case modification (bash 4+)" {
  run scan '\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)'
  [ -z "$output" ]
}

@test "no readlink -f (not on macOS/BSD)" {
  run scan 'readlink[[:space:]]+-f'
  [ -z "$output" ]
}

@test "the compat scans do not fire on their own documentation" {
  # 🔴 A CONTROL FOR THE RULER, not for the code. `scan` was a plain grep over
  # source text until a comment saying "not readlink -f" turned it red. Both
  # halves are pinned: a commented mention is ignored, a real call is not — the
  # second is what stops this exemption from quietly disabling every guard above.
  local probe="$TEST_HOME/probe"; mkdir -p "$probe/lib" "$probe/bin"
  : > "$probe/bin/clikae"
  printf '# we deliberately avoid readlink -f here\n' > "$probe/lib/note.sh"
  run env CLIKAE_TEST_ROOT="$probe" bash -c \
    'grep -rnE "readlink[[:space:]]+-f" "$CLIKAE_TEST_ROOT/bin/clikae" "$CLIKAE_TEST_ROOT/lib" | grep -vE "^[^:]+:[0-9]+:[[:space:]]*#"'
  [ -z "$output" ] || { echo "still fires on a comment: $output"; false; }

  printf 'target="$(readlink -f "$1")"\n' > "$probe/lib/real.sh"
  run env CLIKAE_TEST_ROOT="$probe" bash -c \
    'grep -rnE "readlink[[:space:]]+-f" "$CLIKAE_TEST_ROOT/bin/clikae" "$CLIKAE_TEST_ROOT/lib" | grep -vE "^[^:]+:[0-9]+:[[:space:]]*#"'
  [ -n "$output" ] || { echo "the exemption swallowed a REAL call"; false; }
}

@test "no &> redirection (use >file 2>&1)" {
  run grep -rn -- '&>' "$CLIKAE_TEST_ROOT/bin/clikae" "$CLIKAE_TEST_ROOT/lib"
  [ -z "$output" ]
}

# P3-6 (round-3 review): the guards above scan for known bash-4+ CONSTRUCTS
# via grep — they can't see a bash 3.2 PARSE error, which is exactly what
# broke CI on macOS (the interpreter itself, not a construct grep knows to
# name). A real bash:3.2 running `bash -n` on every shipped file is the
# direct gate; skip with a reason where docker isn't available rather than
# silently passing.
#
# P3-2 (round-4 review): this gate had no sample-count assertion — point it
# at an empty tree and it happily reports `checked=0`, rc=0: "passed" by
# checking nothing. `checked=$n` is now printed unconditionally (pass or
# fail) and asserted against a lower bound derived from the real tree
# (`lib/**/*.sh` alone, ignoring bin/ and non-.sh — a true floor, never a
# number that needs bumping by hand as files are added).
@test "bash 3.2 can parse every shipped lib/ + bin/ file (docker bash -n)" {
  command -v docker >/dev/null 2>&1 ||
    skip "docker not on PATH — cannot run a real bash 3.2 to parse-check lib/ + bin/"
  run docker run --rm -v "$CLIKAE_TEST_ROOT:/src:ro" bash:3.2 bash -c \
    'rc=0; n=0
     while IFS= read -r -d "" f; do
       n=$((n+1))
       bash -n "$f" || rc=1
     done < <(find /src/bin /src/lib -type f -not -path "/src/lib/templates/*" -print0)
     echo "checked=$n"
     exit $rc'
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  local checked floor
  checked="$(printf '%s\n' "$output" | sed -n 's/^checked=//p')"
  floor="$(find "$CLIKAE_TEST_ROOT/lib" -name '*.sh' -type f | wc -l | tr -d ' ')"
  [ -n "$checked" ] || { echo "gate printed no checked= count: $output" >&2; false; }
  [ "$checked" -ge "$floor" ] || { echo "checked=$checked < $floor lib/**/*.sh files — the gate scanned less than the real tree"; false; }
}

@test "P3-2 (round-4 review): the docker gate goes red on an empty tree's worth of nothing checked" {
  command -v docker >/dev/null 2>&1 ||
    skip "docker not on PATH — cannot run a real bash 3.2 to parse-check lib/ + bin/"
  # The ruler for the sample-count assertion above: point the SAME gate at a
  # disposable tree with no shell files in bin/ or lib/ at all. Before the
  # floor assertion, this "passed" (checked=0, rc=0) — reporting nothing
  # checked as a clean bill of health, exactly the gap P3-2 found.
  local probe="$TEST_HOME/emptytree"; mkdir -p "$probe/lib" "$probe/bin"
  run docker run --rm -v "$probe:/src:ro" bash:3.2 bash -c \
    'rc=0; n=0
     while IFS= read -r -d "" f; do
       n=$((n+1))
       bash -n "$f" || rc=1
     done < <(find /src/bin /src/lib -type f -not -path "/src/lib/templates/*" -print0)
     echo "checked=$n"
     exit $rc'
  [ "$status" -eq 0 ]
  local checked; checked="$(printf '%s\n' "$output" | sed -n 's/^checked=//p')"
  [ "$checked" = 0 ]
  # An empty tree must fail THIS repo's own floor (>=1 real lib/**/*.sh file).
  local floor; floor="$(find "$CLIKAE_TEST_ROOT/lib" -name '*.sh' -type f | wc -l | tr -d ' ')"
  [ "$floor" -gt 0 ]
  [ "$checked" -lt "$floor" ]
}

@test "P3-2 (round-4 review): the docker gate's negative control — seed c673adb's claude.sh, it must go red" {
  # This is the review's own negative control for THIS gate specifically
  # (distinct from "the compat scans do not fire on their own documentation"
  # above, which guards the grep-based scans): the historical claude.sh at
  # c673adb is the file whose bash-4+ shape once broke CI's real macOS bash
  # 3.2 with a genuine PARSE error (not a construct grep can name) — a
  # disposable copy of it must make this gate fail, verbatim, with that
  # error, or the gate is not actually exercising anything.
  command -v docker >/dev/null 2>&1 ||
    skip "docker not on PATH — cannot run a real bash 3.2 to parse-check lib/ + bin/"
  command -v git >/dev/null 2>&1 || skip "git not on PATH — cannot fetch c673adb's claude.sh"
  local probe="$TEST_HOME/negcontrol"
  mkdir -p "$probe/lib/adapters" "$probe/bin"
  ( cd "$CLIKAE_TEST_ROOT" && git show c673adb:lib/adapters/claude.sh ) > "$probe/lib/adapters/claude.sh" \
    || skip "c673adb:lib/adapters/claude.sh not reachable from this checkout"
  run docker run --rm -v "$probe:/src:ro" bash:3.2 bash -c \
    'rc=0; n=0
     while IFS= read -r -d "" f; do
       n=$((n+1))
       bash -n "$f" || rc=1
     done < <(find /src/bin /src/lib -type f -not -path "/src/lib/templates/*" -print0)
     echo "checked=$n"
     exit $rc'
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected EOF while looking for matching"* ]] || { echo "expected the verbatim bash 3.2 parse error, got: $output" >&2; false; }
}

# --- PowerShell adapter table parity (informational; no Windows/pwsh needed) ----
# powershell/Clikae.psm1 carries a hand-maintained $script:ClikaeAdapters table that
# "mirrors lib/adapters/*.sh one-for-one" (its own comment). This is a SOURCE scan
# that fails if the two drift: every bash adapter (binary + env var + strategy) must
# appear in the psm1 table, and the table must not list an engine that no longer has
# a bash adapter. Runs on macOS/Linux — it greps text, it does not execute pwsh.
@test "powershell adapter table mirrors lib/adapters/*.sh (binary/env-var/strategy)" {
  local psm="$CLIKAE_TEST_ROOT/powershell/Clikae.psm1"
  [ -f "$psm" ]
  local f n bin ev st missing=""
  for f in "$CLIKAE_TEST_ROOT"/lib/adapters/*.sh; do
    n="$(basename "$f" .sh)"
    [ "$n" = "_template" ] && continue
    bin="$(grep -m1 'adapter_meta_cli_binary' "$f" | sed -E 's/.*echo "([^"]*)".*/\1/')"
    ev="$(grep -m1 'adapter_meta_env_var'    "$f" | sed -E 's/.*echo "([^"]*)".*/\1/')"
    st="$(grep -m1 'adapter_meta_strategy'   "$f" | sed -E 's/.*echo "([^"]*)".*/\1/')"
    # `subcommand`-strategy adapters are NOT env-switchable engines — they're a
    # capability shim on a launch-only target (e.g. antigravity's resume hook: no
    # env var, macOS Keychain/symlink shaped). The PS module mirrors only
    # switchable adapters, so such a shim must NOT require a PS table row.
    [ "$st" = "subcommand" ] && continue
    # The psm1 row keys by the engine name; assert that row carries the same binary,
    # env var (empty for flag-strategy engines), and strategy.
    local row
    row="$(grep -E "^[[:space:]]*$n[[:space:]]*=" "$psm" || true)"
    [ -n "$row" ] || { missing="$missing $n(no-row)"; continue; }
    printf '%s' "$row" | grep -q "Binary = '$bin'"     || missing="$missing $n(binary)"
    printf '%s' "$row" | grep -q "EnvVar = '$ev'"       || missing="$missing $n(envvar)"
    printf '%s' "$row" | grep -q "Strategy = '$st'"     || missing="$missing $n(strategy)"
  done
  [ -z "$missing" ] || { echo "psm1 table drift:$missing" >&2; false; }

  # And the reverse: every engine listed in the table still has a bash adapter.
  local key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    [ -f "$CLIKAE_TEST_ROOT/lib/adapters/$key.sh" ] || { echo "psm1 lists orphan engine: $key" >&2; false; }
  done < <(grep -oE "^[[:space:]]+[a-z]+[[:space:]]*= @\{ Name" "$psm" | sed -E 's/^[[:space:]]+//; s/[[:space:]]*=.*//')
}
