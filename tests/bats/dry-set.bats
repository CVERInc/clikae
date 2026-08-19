#!/usr/bin/env bats
# tests/bats/dry-set.bats — _home_dry_set is what turns a tank's dot red. It reads
# two entirely different sources (the tanks' transcripts, and a vendor's own limit
# log) and they now run concurrently, so the ORDER it emits them in is structural
# rather than sequential. It had no test of its own: every existing one stubbed it
# out. On a healthy machine its output is EMPTY, which is exactly why a silent
# break here would show up as a green dot on an exhausted tank and nothing else.

load '../helpers'

_boot() {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/i18n.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/dry_store.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
}

# A claude tank whose newest transcript carries a GENUINE limit marker (synthetic
# model + the api-error flag — text alone is a quote, not an event).
_dry_claude_tank() {
  local tank="$1" phrase="$2"
  clikae init claude "$tank" >/dev/null 2>&1
  local d="$CLIKAE_HOME/profiles/claude/$tank/projects/proj"
  mkdir -p "$d"
  printf '%s\n' \
    "{\"type\":\"assistant\",\"isApiErrorMessage\":true,\"timestamp\":\"2099-01-01T00:00:00Z\",\"message\":{\"model\":\"<synthetic>\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"$phrase\"}]}}" \
    > "$d/s.jsonl"
  touch "$d/s.jsonl"          # inside the -mmin 300 window the scan uses
}

@test "dry set: a genuinely limited claude tank is emitted with its phrase" {
  _boot
  _dry_claude_tank limited "You've hit your session limit · resets 2:10am (Asia/Tokyo)"
  clikae init claude fine >/dev/null 2>&1
  run _home_dry_set
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"$'\037'"limited"$'\037'* ]] || false
  [[ "$output" != *"claude"$'\037'"fine"$'\037'* ]] || false
}

@test "dry set: a healthy fleet emits nothing at all, and succeeds" {
  _boot
  clikae init claude a >/dev/null 2>&1
  clikae init claude b >/dev/null 2>&1
  run _home_dry_set
  [ "$status" -eq 0 ]        # must not abort the board under set -eo pipefail
  [ -z "$output" ] || false
}

@test "dry set: tanks come before targets" {
  _boot
  # The two halves read different things and now run at the same time. The board
  # renders rows in the order this emits them, so the order has to be pinned
  # independently of which half happens to finish first.
  _dry_claude_tank limited "You've hit your session limit · resets 2:10am (Asia/Tokyo)"
  # A dry log-only target: a fake `agy` on PATH plus a limit log it points at.
  mkdir -p "$TEST_HOME/.testbin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_HOME/.testbin/agy"
  chmod +x "$TEST_HOME/.testbin/agy"
  export PATH="$TEST_HOME/.testbin:$PATH"
  mkdir -p "$TEST_HOME/.gemini/antigravity-cli"
  printf '%s\n' 'RESOURCE_EXHAUSTED (code 429): Individual quota reached. Resets in 47h47m20s.' \
    > "$TEST_HOME/.gemini/antigravity-cli/cli.log"
  run _home_dry_set
  [ "$status" -eq 0 ]
  local tank_at target_at i=0
  while IFS= read -r line; do
    case "$line" in
      claude*)      [ -n "${tank_at:-}" ]   || tank_at=$i ;;
      *antigravity*) [ -n "${target_at:-}" ] || target_at=$i ;;
    esac
    i=$(( i + 1 ))
  done <<EOF
$output
EOF
  [ -n "${tank_at:-}" ]   || { echo "no tank row in: $output"; false; }
  [ -n "${target_at:-}" ] || { echo "no target row in: $output"; false; }
  [ "$tank_at" -lt "$target_at" ] || { echo "target came first: $output"; false; }
}

@test "dry set: a target whose binary is NOT installed is never emitted" {
  _boot
  # The gate exists so an uninstalled vendor's stale log cannot badge a row the
  # board does not even draw. The maintainer's machine HAS agy installed, so the
  # PATH is narrowed and the precondition is asserted — without that this test
  # passes by testing nothing wherever the vendor happens to be absent.
  export PATH="$TEST_HOME/.testbin:/usr/bin:/bin:/usr/sbin:/sbin"
  command -v agy >/dev/null 2>&1 && skip "agy resolves even on the narrowed PATH"
  mkdir -p "$TEST_HOME/.gemini/antigravity-cli"
  printf '%s\n' 'RESOURCE_EXHAUSTED (code 429): Individual quota reached. Resets in 47h47m20s.' \
    > "$TEST_HOME/.gemini/antigravity-cli/cli.log"
  run _home_dry_set
  [ "$status" -eq 0 ]
  [[ "$output" != *"antigravity"* ]] || false
}
