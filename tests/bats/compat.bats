#!/usr/bin/env bats
# tests/bats/compat.bats — guard against constructs that break macOS bash 3.2.
#
# macOS ships bash 3.2, so the source must avoid bash 4+ idioms and GNU-isms.
# These are source-scanning meta-tests, not behavioural ones.

load '../helpers'

scan() { grep -rnE "$1" "$CLIKAE_TEST_ROOT/bin/clikae" "$CLIKAE_TEST_ROOT/lib"; }

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
