# shellcheck shell=bash
# tests/bats/helpers/bounded.bash — a wall-clock bound for a test's own safety
# net, on every platform the suite runs on, including the one that matters most.
#
# 🔴 Why this exists (#112 item 10). Six tests in burn.bats need a hard ceiling
# around the real `clikae` binary: they deliberately wedge a `find`, a `stat` or
# `.git/HEAD`, and a regression that hangs `burn` hangs the test with it — a bats
# test that never returns does not fail, it wedges the whole suite (reproduced:
# 10+ minutes on real bash 3.2, inside a pre-push hook, looking exactly like a
# stuck terminal). They got that ceiling from `timeout`/`gtimeout` and skipped
# when neither was on `$PATH` — which is stock macOS. So the tests written to
# prove a macOS-shaped bug was fixed had never run on macOS: every bash 3.2
# receipt in those rounds came from a `bash:3.2.57` container (Alpine/musl),
# which shares the bash version and nothing else — including the `set -m`
# process-group behaviour the fix under test depends on.
#
# `bounded_run <secs> <cmd> [args…]` keeps `timeout`/`gtimeout` as the preferred
# path when one is present (same binary, same semantics as before) and otherwise
# enforces the bound in bash itself, with no external binary at all:
#
#   * `{ set -m; } 2>/dev/null` for exactly the length of the fork, so the child
#     gets a process group of its own (pgid == its pid) and the deadline can kill
#     the GROUP — a `clikae burn` under test forks `find`/`git`/`stat`, and a
#     kill aimed at one pid leaves those running, still holding the capture pipe
#     that `run` is waiting on for EOF. fd 2 is redirected for the `set` builtin
#     itself so bash cannot take the controlling terminal's foreground group
#     while initialising job control.
#   * a blocking `wait`, not a `kill -0` poll loop: no polling latency is added
#     to a command that finishes instantly.
#   * the watchdog closes fd 3. bats uses fd 3 for its own output, and a
#     background process that keeps it open wedges the run — the same fd-lifetime
#     trap `_burn_lb_bounded`'s own watchdog redirects itself away from.
#
# bash 3.2 safe: no arrays, no `${var,,}`, no `mapfile`, no `$'…'`. Receipt for
# that claim, from the repo root:
#
#   docker run --rm -v "$PWD":/w bash:3.2 bash -n /w/tests/bats/helpers/bounded.bash
#
# and the behaviour itself is asserted by burn.bats ("#112 item 10"), which runs
# on both CI runners — so the bash-native path is exercised on real macOS, not
# only in a container that happens to ship the same bash.

# bounded_run <secs> <cmd> [args…]
# Runs <cmd> with a wall-clock ceiling of <secs>. Returns the command's own exit
# status, or 137 (128+SIGKILL) when the ceiling killed it — the same status
# `timeout -s KILL` reports, so a caller cannot tell the two paths apart.
bounded_run() {
  local secs="$1"; shift
  # The receipt seam. A runner that HAS `timeout` never takes the in-bash path,
  # so on Linux CI the six tests that depend on it would go on proving nothing
  # about the runner this exists for. Set CLIKAE_TEST_FORCE_BASH_BOUND=1 to run
  # them the way stock macOS will:
  #   CLIKAE_TEST_FORCE_BASH_BOUND=1 bats tests/bats/burn.bats
  if [ "${CLIKAE_TEST_FORCE_BASH_BOUND:-0}" = 1 ]; then
    _bounded_in_bash "$secs" "$@"
    return $?
  fi
  local bin
  bin="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  if [ -n "$bin" ]; then
    "$bin" -s KILL "$secs" "$@"
    return $?
  fi
  _bounded_in_bash "$secs" "$@"
}

# The no-external-binary path. Called directly by the test that proves it works
# on the runner it is standing in, whether or not that runner has `timeout`.
_bounded_in_bash() {
  local secs="$1"; shift
  local mflag pid watcher rc=0
  case "$-" in *m*) mflag=1 ;; *) mflag=0 ;; esac
  { set -m; } 2>/dev/null
  "$@" &
  pid=$!
  # The group kill is the whole point; the single-pid kill after it is for a
  # platform that would not give the child a group, where this is still no worse
  # than a bare `kill`. `kill -0` first so a command that finished on its own at
  # the very same instant is not reported as killed.
  ( sleep "$secs"
    kill -0 "$pid" 2>/dev/null || exit 0
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  ) >/dev/null 2>&1 3>&- &
  watcher=$!
  [ "$mflag" -eq 1 ] || { set +m; } 2>/dev/null
  wait "$pid" 2>/dev/null || rc=$?
  # Take the watchdog's own group with it: its `sleep` is a grandchild, and a
  # grandchild left running holds whatever it inherited for the rest of <secs>.
  kill -KILL -- "-$watcher" 2>/dev/null || kill -KILL "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$rc"
}
