#!/usr/bin/env bats
# tests/bats/agy-email.bats — the agy ACCOUNT column, shown by both `clikae list`
# and the home board. agy keeps no account on disk outside its per-launch log, so
# this scrape is the only thing standing between the board and a wrong account
# name next to a tank. It had no tests at all.

load '../helpers'

_boot() {
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/scan.sh"
  TANK="$TEST_HOME/agytank"
  LOGD="$TANK/antigravity-cli/log"
  mkdir -p "$LOGD"
}

# _log <name> <touch-stamp> <body...>  — a log file with a controlled mtime.
_log() {
  local name="$1" stamp="$2"; shift 2
  printf '%s\n' "$@" > "$LOGD/$name"
  touch -t "$stamp" "$LOGD/$name"
}

@test "agy_email: the account from the NEWEST log wins" {
  _boot
  # The re-login case, and the reason this is worth a test: the tank was signed
  # into one Google account and is now signed into another. Reading whichever
  # file the filesystem happened to hand back last could show either.
  _log old.log 202601010900 'boot' 'email=old@example.com' 'bye'
  _log new.log 202606151200 'boot' 'email=new@example.com' 'bye'
  run agy_email "$TANK"
  [ "$status" -eq 0 ]
  [ "$output" = "new@example.com" ] || false
}

@test "agy_email: newest-first holds when the names sort the other way" {
  _boot
  # Filenames that sort OPPOSITE to their mtimes, so a scan that leans on name
  # order (or on readdir handing names back sorted) picks the stale account.
  _log zzz-oldest.log 202601010900 'email=old@example.com'
  _log aaa-newest.log 202606151200 'email=new@example.com'
  run agy_email "$TANK"
  [ "$status" -eq 0 ]
  [ "$output" = "new@example.com" ] || false
}

@test "agy_email: a newer log with no account falls through to an older one" {
  _boot
  # A launch that crashed before logging in leaves a log with no email= at all.
  # That is not "no account" — it is "no news"; the last known login still holds.
  _log signed-in.log 202601010900 'boot' 'email=real@example.com'
  _log crashed.log   202606151200 'boot' 'panic: no session'
  run agy_email "$TANK"
  [ "$status" -eq 0 ]
  [ "$output" = "real@example.com" ] || false
}

@test "agy_email: a NUL byte in the log does not hide the account" {
  _boot
  # agy writes binary into these logs sometimes. `grep` without -a calls the whole
  # file binary and prints NOTHING for it, so the tank showed a BLANK account
  # column — a falsehood, not a gap: the tank is signed in.
  printf 'boot\nemail=nul@example.com\n' > "$LOGD/bin.log"
  printf 'x' | tr 'x' '\000' >> "$LOGD/bin.log"
  printf '\ntrailing\n' >> "$LOGD/bin.log"
  touch -t 202606151200 "$LOGD/bin.log"
  run agy_email "$TANK"
  [ "$status" -eq 0 ]
  [ "$output" = "nul@example.com" ] || false
}

@test "agy_email: the last account in a single log wins (re-auth mid-session)" {
  _boot
  _log one.log 202606151200 'email=first@example.com' 'work' 'email=second@example.com'
  run agy_email "$TANK"
  [ "$status" -eq 0 ]
  [ "$output" = "second@example.com" ] || false
}

@test "agy_email: a login well past the head bound is still found" {
  _boot
  # The read is bounded so a 17 MB log directory cannot stall the board. Pin the
  # bound against a login that sits deep in a big file — the dogfood machine's
  # furthest was byte 23,200, and a bound that cannot reach that is useless.
  { head -c 200000 /dev/zero | tr '\000' 'p'; printf '\nemail=deep@example.com\n'; } \
    > "$LOGD/big.log"
  touch -t 202606151200 "$LOGD/big.log"
  run agy_email "$TANK"
  [ "$status" -eq 0 ]
  [ "$output" = "deep@example.com" ] || false
}

@test "agy_email: no log directory at all is silent and empty" {
  _boot
  rm -rf "$TANK/antigravity-cli"
  run agy_email "$TANK"
  [ "$status" -eq 0 ]          # never aborts a caller under set -eo pipefail
  [ -z "$output" ] || false
}

@test "agy_email: an empty log directory is silent and empty" {
  _boot
  run agy_email "$TANK"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || false
}

@test "agy_email: a plain FILE named log works, not just a directory" {
  _boot
  # On a real install `log` is a directory of per-launch files, which is what the
  # rest of this file exercises. The old `grep -r` accepted a plain file without
  # noticing, and something out there relies on it — the shape is pinned here so
  # the newest-first scan cannot quietly drop it.
  rm -rf "$LOGD"
  mkdir -p "$TANK/antigravity-cli"
  printf 'boot\nemail=flatfile@example.com\n' > "$TANK/antigravity-cli/log"
  run agy_email "$TANK"
  [ "$status" -eq 0 ]
  [ "$output" = "flatfile@example.com" ] || false
}
