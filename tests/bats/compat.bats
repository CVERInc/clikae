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

# P1-1 (round-2 review): `tests/bats/burn.bats` shipped `touch -d "@epoch"` —
# GNU coreutils only, BSD `touch -d` doesn't take `@epoch` at all — and every
# macOS CI run since has been silently testing nothing (see burn.bats' own
# P1-1 comment: with every `touch` failing, 30 fixture files collapsed to one
# identical mtime, and a broken string-sort fallback happened to produce the
# "right" answer by coincidence). This GNU-ism slipped past every scan above
# because it lived in `tests/`, which `scan()` never covered — so this one
# does, alongside bin/clikae and lib. `touch -t YYYYMMDDhhmm.SS` (POSIX,
# already this repo's own convention — grep `date -v.*touch -t` in
# live.bats/memory.bats/agy-harness.bats) is the portable replacement; there
# is no legitimate use of `touch -d` anywhere in this repo.
# Same three directories as `scan()`, plus `tests/` — that's where the P1-1
# GNU-ism actually lived, and `scan()` alone would never have caught it.
scan_incl_tests() {
  grep -rnE "$1" "$CLIKAE_TEST_ROOT/bin/clikae" "$CLIKAE_TEST_ROOT/lib" "$CLIKAE_TEST_ROOT/tests" \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
}

@test "no touch(1) -d (BSD form takes ISO-8601, not a GNU @epoch — use touch -t)" {
  run scan_incl_tests 'touch[[:space:]]+-d\b'
  [ -z "$output" ]
}

# P1-1 (round-2 review), same finding, the other two GNU date/stat calls the
# review named: `date -d`/`stat -c` are NOT a blanket ban like `touch -d`
# above — this codebase's own established idiom (grep `_limit_date_kind` in
# lib/core/limit.sh, or `_clikae_statv`/`_CLIKAE_STAT_FMT` in
# lib/core/profile_store.sh — "the platform probe") is GNU-first with a BSD
# fallback a few lines away, dozens of times over, and banning the GNU half
# outright would just break that idiom. What's actually unsafe is a `date
# -d`/`stat -c` call with NO BSD counterpart anywhere nearby — so this scans
# a small window around every hit for the fallback shapes this repo already
# uses (`date -j`/`date -r`/`date -v`, `_limit_date_kind`; `stat -f`,
# `_clikae_statv`/`_CLIKAE_STAT_FMT`) and only flags a hit that has none.
_scan_gnu_date_or_stat() {
  local pattern="$1" markers="$2" f ln rest window hits=""
  while IFS=: read -r f ln rest; do
    [[ "$rest" =~ ^[[:space:]]*# ]] && continue
    window="$(sed -n "$((ln > 3 ? ln - 3 : 1)),$((ln + 3))p" "$f" 2>/dev/null)"
    printf '%s' "$window" | grep -qE "$markers" && continue
    hits="$hits
$f:$ln:$rest"
  done < <(grep -rnE "$pattern" "$CLIKAE_TEST_ROOT/bin/clikae" "$CLIKAE_TEST_ROOT/lib" "$CLIKAE_TEST_ROOT/tests" 2>/dev/null)
  printf '%s' "$hits"
}

@test "date -d (GNU-only) never appears without a BSD fallback nearby" {
  run _scan_gnu_date_or_stat 'date[[:space:]]+-d\b' 'date[[:space:]]+-[jrv]|_limit_date_kind'
  [ -z "$output" ] || { echo "date -d with no BSD fallback nearby:$output"; false; }
}

@test "stat -c (GNU-only) never appears without a BSD fallback or the platform probe nearby" {
  run _scan_gnu_date_or_stat 'stat[[:space:]]+-c\b' 'stat[[:space:]]+-f|_clikae_statv|_CLIKAE_STAT_FMT'
  [ -z "$output" ] || { echo "stat -c with no BSD fallback/platform probe nearby:$output"; false; }
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
