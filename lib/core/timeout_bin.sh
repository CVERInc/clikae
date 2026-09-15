# shellcheck shell=bash
# lib/core/timeout_bin.sh — the one bounded-run helper every caller that needs
# to cap a subprocess shares.
#
# P2-2 (round-2 review): this used to live ONLY in lib/commands/burn.sh, and
# lib/adapters/claude.sh's Keychain read (a 5s bound on `security`) grew its
# OWN two-arm copy instead of calling it — `timeout` -> `gtimeout`, no third
# arm. That is exactly the one platform this code exists FOR: stock macOS
# ships neither `timeout` nor `gtimeout` (Homebrew coreutils only), so on the
# adapter's only real platform the 5s bound was silently empty — a `security`
# call that can block on a locked Keychain ran with no bound at all. Moved
# here — a plain core file, sourced once in bin/clikae like every other
# lib/core/*.sh, so BOTH burn (the launch/reroute timeout, --timeout) and any
# adapter (the Keychain read) can call the SAME three-arm resolver without
# one having to source the other's command file for it.
#
# _burn_timeout_bin -> echo `timeout` or `gtimeout` or `perl` if one is on
# PATH (in that preference order); otherwise echo NOTHING and warn that the
# run will be UNBOUNDED. Factored out (originally within burn.sh) so the
# "no tool → honest warning, still runs" contract is unit-testable.
_burn_timeout_bin() {
  if command -v timeout  >/dev/null 2>&1; then printf 'timeout';  return 0; fi
  if command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout'; return 0; fi
  if command -v perl     >/dev/null 2>&1; then printf 'perl';     return 0; fi
  log_warn "--timeout needs \`timeout\`/\`gtimeout\` (coreutils) or \`perl\` on PATH — running WITHOUT a time bound."
  return 0
}
