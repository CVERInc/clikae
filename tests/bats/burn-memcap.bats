#!/usr/bin/env bats
# tests/bats/burn-memcap.bats — #236: `clikae burn --memory-max` puts the
# ENGINE in its own memory-capped systemd user scope. A cap put around
# `clikae burn` caps nothing: tmux starts the engine, in the tmux server's cgroup.
#   1. with real systemd user scopes, the engine and its children run inside
#      a scope whose cgroup carries the requested memory.max / memory.high;
#   2. without the option nothing changes (the spawn command is pinned);
#   3. a cap that cannot apply is refused before anything starts;
#   4. every launch has its own unit, and no unit outlives the burn;
#   5. only a unit this launch started is ever stopped, and an engine the cap
#      killed is reported as such.
# Stub engines only. One real-systemd test allocates 128M under a 64M cap
# (no swap) to be OOM-killed; nothing else allocates memory or generates load.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'
bats_require_minimum_version 1.5.0   # for `run --separate-stderr`

# The host's own systemctl, before any test puts a double on PATH.
REAL_SYSTEMCTL="$(command -v systemctl || true)"

# A stand-in unit a test started on the real user manager is stopped even
# when the test fails.
teardown() {
  if [ -n "$REAL_SYSTEMCTL" ] && [ -s "${BATS_TEST_TMPDIR:-/nonexistent}/standin.unit" ]; then
    "$REAL_SYSTEMCTL" --user stop "$(cat "$BATS_TEST_TMPDIR/standin.unit")" >/dev/null 2>&1 || true
  fi
  [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
}

_memcap_init() {
  unset ANTHROPIC_MODEL CLAUDE_CODE_EFFORT_LEVEL CLIKAE_BURN_MEMORY_MAX CLIKAE_BURN_MEMORY_HIGH
  git init -q "$BATS_TEST_TMPDIR"     # a generated codex burn needs a git cwd
  A="$BATS_TEST_TMPDIR/out.md"; L="$TEST_HOME/argv.log"; S="$TEST_HOME/sdrun.log"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export STUB_ARTIFACT="$A" STUB_ARGV_LOG="$L"
  PATH="$BIN:$PATH"; export PATH
}

# A codex stub that logs its argv and writes the artifact; dry when its tank
# carries a .dry file (for the reroute test).
_stub_codex() {
  cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; printf -- '--END--\n'; } >> "$STUB_ARGV_LOG"
if [ -f "$CODEX_HOME/.dry" ]; then
  echo "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
  exit 0
fi
: > "$STUB_ARTIFACT"
exit 0
STUB
  chmod +x "$BIN/codex"
}

# A systemd-run double: answers the preflight probe from STUB_PROBE_* (or
# fails with STUB_SDRUN_FAIL), refuses a launch with STUB_SDRUN_LAUNCH_FAIL,
# and otherwise logs its argv and execs the command after `--` with
# INVOCATION_ID=$STUB_IID, as `systemd-run --scope` does. A systemctl double
# next to it logs every call to $TEST_HOME/systemctl.log, so nothing here
# reaches the host's real user manager; `show` reports the unit with
# InvocationID $STUB_SHOW_IID (default: $STUB_IID), ActiveState $STUB_STATE
# (default inactive) and Result $STUB_RESULT (default success).
_stub_sdrun() {
  : > "$S"
  export STUB_SDRUN_LOG="$S" STUB_SYSTEMCTL_LOG="$TEST_HOME/systemctl.log"
  cat > "$BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_SYSTEMCTL_LOG"
case " $* " in
  *" show "*)
    printf 'InvocationID=%s\nActiveState=%s\nResult=%s\nControlGroup=%s\n' \
      "${STUB_SHOW_IID-${STUB_IID:-stub-iid-1}}" "${STUB_STATE:-inactive}" \
      "${STUB_RESULT:-success}" "/user.slice/stub/${!#}" ;;
esac
exit 0
STUB
  chmod +x "$BIN/systemctl"
  cat > "$BIN/systemd-run" <<'STUB'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; printf -- '--END--\n'; } >> "$STUB_SDRUN_LOG"
if [ "${!#}" = clikae-memcap-probe ]; then
  [ -z "${STUB_SDRUN_FAIL:-}" ] || { printf '%s\n' "$STUB_SDRUN_FAIL" >&2; exit 1; }
  printf '%s\n%s\n%s\n' "${STUB_PROBE_MAX:-none}" "${STUB_PROBE_HIGH:-max}" "${STUB_PROBE_SWAP:-0}"
  exit 0
fi
[ -z "${STUB_SDRUN_LAUNCH_FAIL:-}" ] || { printf '%s\n' "$STUB_SDRUN_LAUNCH_FAIL" >&2; exit 1; }
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
INVOCATION_ID="${STUB_IID:-stub-iid-1}" exec "$@"
STUB
  chmod +x "$BIN/systemd-run"
}

# Synchronous tmux transport that also keeps what it was handed: its argv in
# $TEST_HOME/tmux.argv and a copy of the wrapper script in $TEST_HOME/wrapper.sh.
_stub_tmux() {
  cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in has-session) exit 1 ;; esac
for arg in "$@"; do
  case "$arg" in
    *'bash "'*)
      printf '%s\n' "$@" > "$HOME/tmux.argv"
      w="${arg#*bash \"}"; w="${w%\"*}"
      cp "$w" "$HOME/wrapper.sh"
      bash -c "$arg" >/dev/null 2>&1
      exit 0 ;;
  esac
done
exit 0
STUB
  chmod +x "$BIN/tmux"
}

_engine_line() {   # the wrapper's one engine launch line
  grep -E '^ *_burn_capture_stderr .*</dev/null' "$TEST_HOME/wrapper.sh" | sed 's/^ *//'
}

_json_field() {
  printf '%s' "$output" | grep -oE "\"$1\":(\"[^\"]*\"|null)" | head -n 1 | sed -E 's/^"[^"]*"://; s/^"//; s/"$//'
}

# Can this host start a systemd user scope whose cgroup carries a memory cap?
_real_scopes_or_skip() {
  [ "$(uname -s)" = Linux ] || skip "systemd user scopes are Linux-only (this is $(uname -s))"
  command -v systemd-run >/dev/null 2>&1 || skip "no systemd-run on this host"
  local got
  # shellcheck disable=SC2016
  got="$(systemd-run --user --scope --quiet --collect -p MemoryMax=64M -- \
    sh -c 'p="$(sed -n "s/^0:://p" /proc/self/cgroup)"; cat "/sys/fs/cgroup$p/memory.max"' 2>/dev/null)" \
    || skip "no reachable systemd user manager (systemd-run --user --scope failed)"
  [ "$got" = 67108864 ] || skip "the user manager's scopes do not carry the memory controller (memory.max: ${got:-unreadable})"
}

# ── 1. the engine is inside the capped scope (real systemd) ─────────────────

@test "burn --memory-max: the engine and its child run in their own scope carrying the cap (#236)" {
  _real_scopes_or_skip
  _memcap_init
  # The engine reports from its own /proc/self/cgroup, and so does a child it
  # forks — the cap must hold both, not only the first process.
  # `codex app-server` is clikae's own usage read (not the task); it must not
  # overwrite the engine's report.
  cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = app-server ] && exit 1
p="$(sed -n 's/^0:://p' /proc/self/cgroup)"
child="$(sh -c "sed -n 's/^0:://p' /proc/self/cgroup")"
{
  printf 'cgroup=%s\n' "$p"
  printf 'child=%s\n' "$child"
  printf 'max=%s\n' "$(cat "/sys/fs/cgroup$p/memory.max")"
  printf 'high=%s\n' "$(cat "/sys/fs/cgroup$p/memory.high")"
} > "$STUB_ARTIFACT"
STUB
  chmod +x "$BIN/codex"
  clikae init codex T1
  run --separate-stderr clikae burn codex T1 --artifact "$A" --prompt 'do it' \
    --memory-max 256M --memory-high 192M --json
  [ "$status" -eq 0 ]
  local cg; cg="$(sed -n 's/^cgroup=//p' "$A")"
  [[ "$cg" == */clikae-burn-codex-T1-burn-*.scope ]] || { cat "$A"; false; }
  [ "$(sed -n 's/^child=//p' "$A")" = "$cg" ]
  [ "$(sed -n 's/^max=//p' "$A")" = 268435456 ]
  [ "$(sed -n 's/^high=//p' "$A")" = 201326592 ]
  # …and it is not the cgroup this test (the caller of `clikae burn`) is in.
  [ "$cg" != "$(sed -n 's/^0:://p' /proc/self/cgroup)" ]
  # shellcheck disable=SC2154
  [[ "$stderr" == *"memory cap: codex/T1 runs in clikae-burn-codex-T1-burn-"*"-l1-"*".scope (MemoryMax=256M, MemoryHigh=192M, no swap)"* ]] || false
  # --json names the unit and the cap; the unit is gone once the burn returned.
  local unit; unit="$(_json_field memory_unit)"
  [[ "$cg" == */"$unit" ]] || { echo "$unit vs $cg"; false; }
  [ "$(_json_field memory_max)" = 256M ]
  [ "$(_json_field memory_high)" = 192M ]
  [ -z "$(systemctl --user list-units --all --no-legend "$unit")" ] || { systemctl --user list-units --all "$unit"; false; }
}

# ── 2. without the option nothing changes ───────────────────────────────────

@test "burn without --memory-max: the spawn command and the engine line are unchanged (#236)" {
  _memcap_init; _stub_codex; _stub_tmux; _stub_sdrun
  clikae init codex T1
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  [ "$status" -eq 0 ]
  [[ "$output" != *"memory cap"* ]] || false
  [ "$(_engine_line)" = "_burn_capture_stderr codex run $A  </dev/null || engine_rc=\$?" ]
  # The pane's start command, pinned: the shim PATH, then bash on the wrapper.
  local spawn_re
  spawn_re="^env -u _CLIKAE_TMUX_SHIM_HOPS PATH=[^ ]+ bash \"$CLIKAE_HOME/state/codex-T1-burn-[0-9]+\\.sh\"\$"
  [[ "$(tail -n 1 "$TEST_HOME/tmux.argv")" =~ $spawn_re ]] || { tail -n 1 "$TEST_HOME/tmux.argv"; false; }
  run ! grep -q systemd-run "$TEST_HOME/tmux.argv" "$TEST_HOME/wrapper.sh"
  [ ! -s "$S" ]                                   # never probed, never wrapped
  [ ! -e "$TEST_HOME/systemctl.log" ]             # never reaped either
  # --json says so: no cap, no unit.
  run --separate-stderr clikae burn codex T1 --artifact "$A" --fresh --json -- run "$A"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"memory_max":null,"memory_high":null,"memory_unit":null'* ]] || { echo "$output"; false; }
  [ ! -s "$S" ]; [ ! -e "$TEST_HOME/systemctl.log" ]
}

@test "burn --memory-max: the engine line is the scope prefix, then the same engine argv (#236)" {
  _memcap_init; _stub_codex; _stub_tmux; _stub_sdrun
  export STUB_PROBE_MAX=10737418240 STUB_PROBE_HIGH=8589934592
  clikae init codex T1
  run clikae burn codex T1 --artifact "$A" --memory-max 10G --memory-high 8G -- run "$A"
  [ "$status" -eq 0 ]
  local line want_re
  line="$(_engine_line)"
  want_re='^_burn_capture_stderr systemd-run --user --scope --quiet --unit=clikae-burn-codex-T1-burn-[0-9]+-l1-[0-9a-f]{8} --description=clikae\\ burn\\ codex/T1 -p MemoryMax=10G -p MemoryHigh=8G -p MemorySwapMax=0 -p TimeoutStopSec=10s -- sh -c .+ clikae-memcap-scope [^ ]+/clikae-burn-codex-T1-burn-[0-9]+-l1-[0-9a-f]{8}\.iid codex run '
  [[ "$line" =~ $want_re ]] || { echo "$line"; false; }
  # The marker the scope's own sh wrote is consumed by the reaper.
  run ! compgen -G "$TEST_HOME/.clikae/logs/burn-*/clikae-burn-*.iid"
  # The engine still ran, with the same argv it gets without a cap.
  grep -qx run "$L"
  [ -f "$A" ]
}

@test "CLIKAE_BURN_MEMORY_MAX opts in like --memory-max, and the flag wins (#236)" {
  _memcap_init; _stub_codex; _stub_tmux; _stub_sdrun
  export STUB_PROBE_MAX=2147483648
  clikae init codex T1
  CLIKAE_BURN_MEMORY_MAX=1G run clikae burn codex T1 --artifact "$A" --memory-max 2G -- run "$A"
  [ "$status" -eq 0 ]
  [[ "$(_engine_line)" == *" -p MemoryMax=2G -p MemorySwapMax=0 -p TimeoutStopSec=10s -- sh -c "*" codex run "* ]] || false
  export STUB_PROBE_MAX=1073741824
  CLIKAE_BURN_MEMORY_MAX=1G run clikae burn codex T1 --artifact "$A" --fresh -- run "$A"
  [ "$status" -eq 0 ]
  [[ "$(_engine_line)" == *" -p MemoryMax=1G -p MemorySwapMax=0 -p TimeoutStopSec=10s -- sh -c "*" codex run "* ]] || false
}

@test "burn --memory-max: every reroute hop runs in its own capped unit (#236)" {
  _memcap_init; _stub_codex; _stub_sdrun
  export STUB_PROBE_MAX=1073741824
  clikae init codex first
  clikae init codex second
  : > "$CLIKAE_HOME/profiles/codex/first/.dry"
  run clikae burn codex first --to second --artifact "$A" --prompt 'do it' --memory-max 1G
  [ "$status" -eq 0 ]
  [ -f "$A" ]
  grep -qE '^--unit=clikae-burn-codex-first-burn-[0-9]+-l1-[0-9a-f]{8}$' "$S"
  grep -qE '^--unit=clikae-burn-codex-second-burn-[0-9]+-l2-[0-9a-f]{8}$' "$S"
  # one probe + two launches, every one of them capped
  [ "$(grep -c '^--END--$' "$S")" -eq 3 ]
  [ "$(grep -c '^MemoryMax=1G$' "$S")" -eq 3 ]
  [ "$(grep -c '^MemorySwapMax=0$' "$S")" -eq 3 ]   # #236 r2 P2-B: no swap, anywhere
  [ "$(grep -c '^TimeoutStopSec=10s$' "$S")" -eq 2 ] # the two launches
}

@test "burn --memory-max: agy's own launcher gets the scope too (#236)" {
  _memcap_init; _stub_sdrun
  export STUB_PROBE_MAX=1073741824
  cat > "$BIN/agy" <<'STUB'
#!/usr/bin/env bash
log=""
while [ $# -gt 0 ]; do [ "$1" = "--log-file" ] && { log="$2"; break; }; shift; done
[ -n "$log" ] && { mkdir -p "$(dirname "$log")"; : > "$log"; }
: > "$STUB_ARTIFACT"
STUB
  chmod +x "$BIN/agy"
  printf 'y\n' | "$CLIKAE_BIN" init agy default >/dev/null 2>&1
  run clikae burn agy default --artifact "$A" --prompt 'do it' --memory-max 1G
  [ "$status" -eq 0 ]
  grep -qE '^--unit=clikae-burn-agy-default-burn-[0-9]+-l1-[0-9a-f]{8}$' "$S"
  [ -f "$A" ]
}

# ── 3. refused before anything starts ───────────────────────────────────────

@test "burn --memory-max refuses an invalid size before anything starts (#236)" {
  _memcap_init; _stub_codex; _stub_sdrun
  clikae init codex T1
  local bad
  for bad in 10GB 0 0G -5 abc 1.5G 10g infinity 50% 9999999999999G; do
    run clikae burn codex T1 --artifact "$A" --prompt x --memory-max "$bad"
    [ "$status" -ne 0 ] || { echo "accepted: $bad"; false; }
    [[ "$output" == *"--memory-max: not a size: '$bad'"* ]] || { echo "$output"; false; }
  done
  run clikae burn codex T1 --artifact "$A" --prompt x --memory-max 1G --memory-high 2G
  [ "$status" -ne 0 ]
  [[ "$output" == *"--memory-high 2G is above --memory-max 1G"* ]] || false
  run clikae burn codex T1 --artifact "$A" --prompt x --memory-high 1G
  [ "$status" -ne 0 ]
  [[ "$output" == *"--memory-high 1G needs --memory-max (or CLIKAE_BURN_MEMORY_MAX)"* ]] || false
  CLIKAE_BURN_MEMORY_MAX=lots run clikae burn codex T1 --artifact "$A" --prompt x
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLIKAE_BURN_MEMORY_MAX: not a size: 'lots'"* ]] || false
  [ ! -e "$L" ]; [ ! -s "$S" ]; [ ! -e "$A" ]
}

@test "burn --memory-max refuses when systemd-run is missing, before anything starts (#236)" {
  _memcap_init; _stub_codex
  clikae init codex T1
  # A PATH that has everything this host has EXCEPT systemd-run.
  local nosd="$BATS_TEST_TMPDIR/nosd" d f
  mkdir -p "$nosd"
  local IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -x "$f" ] && [ ! -d "$f" ] || continue
      [ "${f##*/}" != systemd-run ] || continue
      [ -e "$nosd/${f##*/}" ] || ln -s "$f" "$nosd/${f##*/}"
    done
  done
  unset IFS
  PATH="$nosd" run --separate-stderr "$nosd/bash" "$CLIKAE_BIN" burn codex T1 --artifact "$A" --prompt x --memory-max 1G --json
  [ "$status" -eq 1 ]
  # shellcheck disable=SC2154
  [[ "$stderr" == *"--memory-max needs systemd-run (Linux with a systemd user manager); there is none on this $(uname -s) system. Nothing was started; drop --memory-max to run uncapped."* ]] || { echo "$stderr"; false; }
  [ "$(_json_field reason)" = "refused: --memory-max needs systemd-run" ]
  [ ! -e "$L" ]; [ ! -e "$A" ]
}

@test "burn --memory-max refuses when the user manager cannot be reached, before anything starts (#236)" {
  _memcap_init; _stub_codex; _stub_sdrun
  export STUB_SDRUN_FAIL="Failed to connect to bus: No medium found"
  clikae init codex T1
  run --separate-stderr clikae burn codex T1 --artifact "$A" --prompt x --memory-max 1G --json
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--memory-max could not start a systemd user scope (rc 1: Failed to connect to bus: No medium found). Is the user manager running and reachable (systemctl --user status)? Nothing was started; drop --memory-max to run uncapped."* ]] || { echo "$stderr"; false; }
  [ "$(_json_field reason)" = "refused: --memory-max could not start a systemd user scope" ]
  [ "$(grep -c '^--END--$' "$S")" -eq 1 ]        # the probe, and nothing after it
  [ ! -e "$L" ]; [ ! -e "$A" ]
  # The refusal is a terminal status row, so `clikae wait` does not stall on it.
  grep -q '"state":"fail"' "$TEST_HOME"/.clikae/logs/burn-*/status.json
}

@test "burn --memory-max refuses when the scope's cgroup does not carry the cap (#236)" {
  _memcap_init; _stub_codex; _stub_sdrun
  clikae init codex T1
  export STUB_PROBE_MAX=none           # no memory controller in the user manager
  run --separate-stderr clikae burn codex T1 --artifact "$A" --prompt x --memory-max 1G
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--memory-max: a systemd user scope started, but its cgroup does not carry the cap (memory.max: none, wanted 1073741824 bytes)."* ]] || { echo "$stderr"; false; }
  [ ! -e "$L" ]
  export STUB_PROBE_MAX=1073741824 STUB_PROBE_HIGH=max   # high asked for, not applied
  run --separate-stderr clikae burn codex T1 --artifact "$A" --prompt x --memory-max 1G --memory-high 512M
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"(memory.max: 1073741824, wanted 1073741824 bytes; memory.high: max, wanted 536870912 bytes)"* ]] || { echo "$stderr"; false; }
  [ ! -e "$L" ]
  # Page rounding is not a mismatch.
  export STUB_PROBE_MAX=99999744 STUB_PROBE_HIGH=max
  run clikae burn codex T1 --artifact "$A" --prompt x --memory-max 100000000
  [ "$status" -eq 0 ]
  [ -f "$A" ]
}

@test "burn --memory-max refuses a cap below 64M, naming the knob, before anything starts (#236)" {
  _memcap_init; _stub_codex; _stub_sdrun
  clikae init codex T1
  local small
  for small in 1 4095 1M 63M 67108863; do
    run clikae burn codex T1 --artifact "$A" --prompt x --memory-max "$small"
    [ "$status" -ne 0 ] || { echo "accepted: $small"; false; }
    [[ "$output" == *"--memory-max $small is below the smallest cap burn accepts, 64M (67108864 bytes): no engine starts under less. Nothing was started."* ]] || { echo "$output"; false; }
  done
  run clikae burn codex T1 --artifact "$A" --prompt x --memory-max 1G --memory-high 1M
  [ "$status" -ne 0 ]
  [[ "$output" == *"--memory-high 1M is below the smallest cap burn accepts, 64M"* ]] || { echo "$output"; false; }
  CLIKAE_BURN_MEMORY_MAX=2M run clikae burn codex T1 --artifact "$A" --prompt x
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLIKAE_BURN_MEMORY_MAX=2M is below the smallest cap burn accepts, 64M"* ]] || { echo "$output"; false; }
  [ ! -e "$L" ]; [ ! -s "$S" ]; [ ! -e "$A" ]
  # 64M itself is accepted.
  export STUB_PROBE_MAX=67108864
  run clikae burn codex T1 --artifact "$A" --prompt x --memory-max 64M
  [ "$status" -eq 0 ]
  [ -f "$A" ]
}

@test "burn --memory-max: a refusal names the environment variable when that is what set the value (#236)" {
  _memcap_init; _stub_codex; _stub_sdrun
  clikae init codex T1
  CLIKAE_BURN_MEMORY_HIGH=8G run clikae burn codex T1 --artifact "$A" --prompt x --memory-max 4G
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLIKAE_BURN_MEMORY_HIGH=8G is above --memory-max 4G: it would never throttle before the hard cap."* ]] || { echo "$output"; false; }
  [[ "$output" != *"--memory-high 8G"* ]] || false
  CLIKAE_BURN_MEMORY_MAX=4G run clikae burn codex T1 --artifact "$A" --prompt x --memory-high 8G
  [ "$status" -ne 0 ]
  [[ "$output" == *"--memory-high 8G is above CLIKAE_BURN_MEMORY_MAX=4G"* ]] || { echo "$output"; false; }
  CLIKAE_BURN_MEMORY_HIGH=1G run clikae burn codex T1 --artifact "$A" --prompt x
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLIKAE_BURN_MEMORY_HIGH=1G needs --memory-max (or CLIKAE_BURN_MEMORY_MAX)"* ]] || { echo "$output"; false; }
  # The scope refusal's way out names the variable too.
  export STUB_SDRUN_FAIL="Failed to connect to bus: No medium found"
  CLIKAE_BURN_MEMORY_MAX=1G run --separate-stderr clikae burn codex T1 --artifact "$A" --prompt x
  [ "$status" -eq 1 ]
  # shellcheck disable=SC2154
  [[ "$stderr" == *"Nothing was started; unset CLIKAE_BURN_MEMORY_MAX to run uncapped."* ]] || { echo "$stderr"; false; }
  [ ! -e "$L" ]; [ ! -e "$A" ]
}

# ── 4. one unit per launch, none outlives the burn ──────────────────────────

@test "burn --memory-max: --json and the status file carry the cap and the launch's unit (#236)" {
  _memcap_init; _stub_codex; _stub_sdrun
  export STUB_PROBE_MAX=1073741824 STUB_PROBE_HIGH=805306368
  clikae init codex T1
  run --separate-stderr clikae burn codex T1 --artifact "$A" --prompt x --memory-max 1G --memory-high 768M --json
  [ "$status" -eq 0 ]
  [ "$(_json_field memory_max)" = 1G ]
  [ "$(_json_field memory_high)" = 768M ]
  [[ "$(_json_field memory_unit)" =~ ^clikae-burn-codex-T1-burn-[0-9]+-l1-[0-9a-f]{8}\.scope$ ]] || { echo "$output"; false; }
  local st; st="$(cat "$TEST_HOME"/.clikae/logs/burn-*/status.json)"
  [[ "$st" == *'"memory_max":"1G","memory_high":"768M","memory_unit":"'"$(_json_field memory_unit)"'"'* ]] || { echo "$st"; false; }
}

@test "burn --memory-max: once the engine exits, a scope still holding its leftovers is stopped (#236)" {
  _memcap_init; _stub_codex; _stub_tmux; _stub_sdrun
  export STUB_PROBE_MAX=1073741824
  clikae init codex T1
  # Not active: nothing is stopped.
  run clikae burn codex T1 --artifact "$A" --memory-max 1G -- run "$A"
  [ "$status" -eq 0 ]
  grep -qE '^--user show -p InvocationID -p ActiveState -p Result -p ControlGroup clikae-burn-codex-T1-burn-[0-9]+-l1-[0-9a-f]{8}\.scope$' "$TEST_HOME/systemctl.log"
  run ! grep -q ' stop ' "$TEST_HOME/systemctl.log"
  # Still active after the engine returned: its own unit, and only it, is stopped.
  : > "$TEST_HOME/systemctl.log"
  STUB_STATE=active run clikae burn codex T1 --artifact "$A" --fresh --memory-max 1G -- run "$A"
  [ "$status" -eq 0 ]
  [ "$(grep -c ' stop ' "$TEST_HOME/systemctl.log")" -eq 1 ]
  grep -qE '^--user stop clikae-burn-codex-T1-burn-[0-9]+-l1-[0-9a-f]{8}\.scope$' "$TEST_HOME/systemctl.log"
}

@test "burn --memory-max: a same-tank re-fire gets a new unit while the last one is still loaded, and none remains (#236)" {
  _real_scopes_or_skip
  _memcap_init
  # The first launch leaves a detached child behind (still in its scope) and
  # reports a limit whose reset is already past, so --wait-for-reset re-fires
  # the same tank at once, under the same run id. The second launch writes
  # the artifact. Before the launch counter, systemd-run refused the re-fire:
  # "Unit clikae-burn-...scope was already loaded or has a fragment file."
  export MARK="$BATS_TEST_TMPDIR/first"
  cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = app-server ] && exit 1
if [ ! -f "$MARK" ]; then
  : > "$MARK"
  for fd in /proc/$$/fd/*; do n=${fd##*/}; [ "$n" -gt 2 ] && eval "exec $n>&-"; done 2>/dev/null
  setsid sleep 12 >/dev/null 2>&1 </dev/null &
  echo "You've hit your usage limit. Try again at Jul 7th, 2026 2:17 PM."
  exit 0
fi
: > "$STUB_ARTIFACT"
STUB
  chmod +x "$BIN/codex"
  cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in has-session) exit 1 ;; esac
for arg in "$@"; do case "$arg" in *'bash "'*) bash -c "$arg" >/dev/null 2>&1; exit 0 ;; esac; done
exit 0
STUB
  chmod +x "$BIN/tmux"
  clikae init codex T1
  run --separate-stderr clikae burn codex T1 --no-reroute --wait-for-reset 1m --artifact "$A" \
    --memory-max 256M --json -- run "$A"
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr" | tail -20; false; }
  [ -f "$A" ]
  local unit prefix
  unit="$(_json_field memory_unit)"
  [[ "$unit" =~ ^clikae-burn-codex-T1-burn-[0-9]+-l2-[0-9a-f]{8}\.scope$ ]] || { echo "$output"; false; }
  prefix="${unit%-l2-*.scope}"
  [[ "$stderr" == *"memory cap: codex/T1 runs in $prefix-l1-"*".scope"* ]] || false
  [[ "$stderr" == *"memory cap: codex/T1 runs in $unit"* ]] || false
  # The first launch's leftover was ended with its scope, and named.
  local left_re="memory cap: codex/T1 exited and left 1 process\\(es\\) in $prefix-l1-[0-9a-f]{8}\\.scope \\([0-9]+ sleep\\); stopping the scope, which ends them\\."
  [[ "$stderr" =~ $left_re ]] || { echo "$stderr"; false; }
  [ -z "$(systemctl --user list-units --all --no-legend "$prefix-*")" ] || { systemctl --user list-units --all "$prefix-*"; false; }
}

# ── 5. only this launch's unit is touched; a cap that ended the engine says so

# A codex stub for the real-systemd tests below: skips clikae's own usage
# read, then runs $STUB_BODY (if any) and writes the artifact.
_stub_codex_real() {
  cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = app-server ] && exit 1
[ -z "${STUB_BODY:-}" ] || eval "$STUB_BODY"
: > "$STUB_ARTIFACT"
STUB
  chmod +x "$BIN/codex"
  cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in has-session) exit 1 ;; esac
for arg in "$@"; do case "$arg" in *'bash "'*) bash -c "$arg" >/dev/null 2>&1; exit 0 ;; esac; done
exit 0
STUB
  chmod +x "$BIN/tmux"
}

@test "burn --memory-max: a unit another process already holds under the same name is never stopped (#236 r2 P2-A)" {
  _real_scopes_or_skip
  _memcap_init; _stub_codex_real
  clikae init codex T1
  # The review's repro: a stand-in scope takes the name burn would have
  # derived from its own pid (clikae-burn-<engine>-<tank>-burn-$$-l1), then
  # the same pid execs the burn. Before the nonce, systemd-run refused the
  # launch and the reaper then stopped the stand-in, blaming codex.
  local mark="$BATS_TEST_TMPDIR/standin.unit"
  # shellcheck disable=SC2016  # $$ is the inner bash's pid, which the burn keeps
  run --separate-stderr bash -c '
    u="clikae-burn-codex-T1-burn-$$-l1"; printf "%s\n" "$u.scope" > "$1"
    systemd-run --user --scope --quiet --unit="$u" -- sleep 60 >/dev/null 2>&1 </dev/null &
    sleep 2; shift; exec "$@"' _ "$mark" \
    "$CLIKAE_BIN" burn codex T1 --artifact "$A" --no-reroute --memory-max 256M --json -- run "$A"
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr" | tail -20; false; }
  [ -f "$A" ]
  local standin; standin="$(cat "$mark")"
  # The stand-in is still running, nothing was blamed on codex, and the
  # burn's own unit is a different one.
  "$REAL_SYSTEMCTL" --user is-active --quiet "$standin" || { "$REAL_SYSTEMCTL" --user status "$standin"; false; }
  [[ "$stderr" != *"exited and left"* ]] || { echo "$stderr"; false; }
  [[ "$(_json_field memory_unit)" =~ ^${standin%.scope}-[0-9a-f]{8}\.scope$ ]] || { echo "$output"; false; }
  [[ "$(_json_field memory_unit)" != "$standin" ]] || false
  "$REAL_SYSTEMCTL" --user stop "$standin"
  [ -z "$("$REAL_SYSTEMCTL" --user list-units --all --no-legend "${standin%.scope}*")" ] \
    || { "$REAL_SYSTEMCTL" --user list-units --all "${standin%.scope}*"; false; }
}

@test "burn --memory-max: a launch systemd-run refused never stops the unit holding the name (#236 r2 P2-A)" {
  _memcap_init; _stub_codex; _stub_tmux; _stub_sdrun
  export STUB_PROBE_MAX=1073741824
  clikae init codex T1
  # The name is taken: systemd-run refuses, and that unit is someone else's
  # (active, another invocation id). The burn fails as it did; nothing is
  # stopped, nothing reset, nothing blamed on codex.
  STUB_SDRUN_LAUNCH_FAIL="Failed to start transient scope unit: Unit clikae-burn-x.scope was already loaded or has a fragment file." \
  STUB_STATE=active STUB_SHOW_IID=someone-elses-invocation \
    run --separate-stderr clikae burn codex T1 --artifact "$A" --memory-max 1G -- run "$A"
  [ "$status" -eq 1 ]
  [ ! -e "$L" ]                                   # the engine never ran
  run ! grep -qE ' (stop|reset-failed|kill) ' "$TEST_HOME/systemctl.log"
  [[ "$stderr" != *"exited and left"* ]] || { echo "$stderr"; false; }
  # Started, but by the time the engine exited the name belongs to another
  # invocation: left alone too.
  : > "$TEST_HOME/systemctl.log"
  STUB_STATE=active STUB_SHOW_IID=a-later-invocation \
    run --separate-stderr clikae burn codex T1 --artifact "$A" --fresh --memory-max 1G -- run "$A"
  [ "$status" -eq 0 ]
  grep -q ' show ' "$TEST_HOME/systemctl.log"
  run ! grep -qE ' (stop|reset-failed|kill) ' "$TEST_HOME/systemctl.log"
}

@test "burn --memory-max: the scope gets MemorySwapMax=0, and a scope that can still swap is refused (#236 r2 P2-B)" {
  _memcap_init; _stub_codex; _stub_tmux; _stub_sdrun
  export STUB_PROBE_MAX=1073741824
  clikae init codex T1
  run clikae burn codex T1 --artifact "$A" --memory-max 1G -- run "$A"
  [ "$status" -eq 0 ]
  # the probe and the launch both ask for no swap
  [ "$(grep -c '^MemorySwapMax=0$' "$S")" -eq 2 ]
  [[ "$(_engine_line)" == *" -p MemorySwapMax=0 -p TimeoutStopSec=10s -- sh -c "* ]] || { _engine_line; false; }
  # a kernel without swap accounting has no memory.swap.max: accepted
  STUB_PROBE_SWAP=none run clikae burn codex T1 --artifact "$A" --fresh --memory-max 1G -- run "$A"
  [ "$status" -eq 0 ]
  # a scope that still may swap is not a cap
  rm -f "$L"
  STUB_PROBE_SWAP=max run --separate-stderr clikae burn codex T1 --artifact "$A" --fresh --memory-max 1G --json -- run "$A"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--memory-max: a systemd user scope started, but its cgroup lets the engine swap past the cap (memory.swap.max: max, wanted 0). Nothing was started; drop --memory-max to run uncapped."* ]] || { echo "$stderr"; false; }
  [ ! -e "$L" ]
}

@test "burn --memory-max: an engine the cap OOM-killed is reported as ended by the memory cap (real systemd, #236 r2 P2-B/P3-4)" {
  _real_scopes_or_skip
  command -v python3 >/dev/null 2>&1 || skip "no python3 to allocate with"
  _memcap_init; _stub_codex_real
  clikae init codex T1
  # 128M touched under a 64M cap. With swap allowed it lived on (72M in
  # swap); with MemorySwapMax=0 the kernel kills it at the cap.
  export STUB_BODY='python3 -c "b = b\"x\" * (128 << 20)" || exit $?'
  run --separate-stderr clikae burn codex T1 --artifact "$A" --no-reroute --memory-max 64M --json -- run "$A"
  [ "$status" -eq 1 ] || { echo "$output"; echo "$stderr" | tail; false; }
  [ ! -e "$A" ]
  [[ "$stderr" == *"memory cap: codex/T1 hit its memory cap (--memory-max 64M): the kernel killed a process in clikae-burn-codex-T1-burn-"*"(oom-kill)."* ]] || { echo "$stderr"; false; }
  [[ "$stderr" == *"codex/T1 produced no fresh artifact: it was ended by the memory cap (--memory-max 64M) (rc="* ]] || { echo "$stderr"; false; }
  [[ "$stderr" != *"a real task failure"* ]] || { echo "$stderr"; false; }
  [ "$(_json_field reason)" = "ended by the memory cap (--memory-max 64M)" ]
  # The failed unit was read, then reset: none remains.
  [ -z "$("$REAL_SYSTEMCTL" --user list-units --all --no-legend "$(_json_field memory_unit)")" ] \
    || { "$REAL_SYSTEMCTL" --user list-units --all "$(_json_field memory_unit)"; false; }
}

@test "burn --memory-max: a scope that recorded an OOM kill names the cap instead of a task failure (#236 r2 P3-4)" {
  _memcap_init; _stub_sdrun; _stub_tmux
  export STUB_PROBE_MAX=1073741824
  # The engine dies as an OOM kill leaves it (SIGKILL, no artifact); the
  # user manager reports the scope Result=oom-kill.
  cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; printf -- '--END--\n'; } >> "$STUB_ARGV_LOG"
kill -KILL $$
STUB
  chmod +x "$BIN/codex"
  clikae init codex T1
  STUB_STATE=failed STUB_RESULT=oom-kill \
    run --separate-stderr clikae burn codex T1 --artifact "$A" --memory-max 1G --json -- run "$A"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"[ WARN ] memory cap: codex/T1 hit its memory cap (--memory-max 1G): the kernel killed a process in clikae-burn-codex-T1-burn-"*"(oom-kill)."* ]] || { echo "$stderr"; false; }
  [[ "$stderr" == *"[ FAIL ] codex/T1 produced no fresh artifact: it was ended by the memory cap (--memory-max 1G) (rc=137), not a dry tank. Raise the cap, or give the task less to hold at once."* ]] || { echo "$stderr"; false; }
  [[ "$stderr" != *"a real task failure"* ]] || { echo "$stderr"; false; }
  [ "$(_json_field reason)" = "ended by the memory cap (--memory-max 1G)" ]
  grep -q '"reason":"ended by the memory cap (--memory-max 1G)"' "$TEST_HOME"/.clikae/logs/burn-*/status.json
  # Read before it was reset; a failed unit is not stopped, only reset.
  run ! grep -q ' stop ' "$TEST_HOME/systemctl.log"
  grep -qE '^--user reset-failed clikae-burn-codex-T1-burn-[0-9]+-l1-[0-9a-f]{8}\.scope$' "$TEST_HOME/systemctl.log"
  # Set by the variable, the message says so.
  CLIKAE_BURN_MEMORY_MAX=1G STUB_STATE=failed STUB_RESULT=oom-kill \
    run --separate-stderr clikae burn codex T1 --artifact "$A" --fresh --json -- run "$A"
  [ "$status" -eq 1 ]
  [ "$(_json_field reason)" = "ended by the memory cap (CLIKAE_BURN_MEMORY_MAX=1G)" ]
  # Without an OOM record, the same death is still a real task failure.
  STUB_STATE=inactive STUB_RESULT=success \
    run --separate-stderr clikae burn codex T1 --artifact "$A" --fresh --memory-max 1G -- run "$A"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"a real task failure (rc=137)"* ]] || { echo "$stderr"; false; }
  [[ "$stderr" != *"memory cap: codex/T1 hit"* ]] || false
}

@test "burn --memory-max: leftovers are named (five, then 'and N more'), and one ignoring SIGTERM holds the reap ~10s, not 90s (#236 r2 P3-3/P3-5)" {
  _real_scopes_or_skip
  _memcap_init; _stub_codex_real
  clikae init codex T1
  # Seven detached sleeps stay behind in the scope; one ignores SIGTERM.
  # shellcheck disable=SC2016
  export STUB_BODY='
    for fd in /proc/$$/fd/*; do n=${fd##*/}; [ "$n" -gt 2 ] && eval "exec $n>&-"; done 2>/dev/null
    for i in 1 2 3 4 5 6; do setsid sleep 60 >/dev/null 2>&1 </dev/null & done
    setsid sh -c "trap \"\" TERM; exec sleep 60" >/dev/null 2>&1 </dev/null &
    sleep 0.5'
  local t0=$SECONDS
  run --separate-stderr clikae burn codex T1 --artifact "$A" --no-reroute --memory-max 256M --json -- run "$A"
  local took=$((SECONDS - t0))
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr" | tail; false; }
  local unit; unit="$(_json_field memory_unit)"
  local unit_re left_re
  unit_re="$(printf '%s' "$unit" | sed 's/\./\\./g')"
  left_re="memory cap: codex/T1 exited and left 7 process\\(es\\) in $unit_re \\(([0-9]+ sleep, ){5}and 2 more\\); stopping the scope, which ends them\\."
  [[ "$stderr" =~ $left_re ]] || { echo "$stderr"; false; }
  # TimeoutStopSec=10s: SIGKILL after 10s, not the user manager's 90s.
  [ "$took" -lt 45 ] || { echo "took ${took}s"; false; }
  [ -z "$("$REAL_SYSTEMCTL" --user list-units --all --no-legend "$unit")" ] \
    || { "$REAL_SYSTEMCTL" --user list-units --all "$unit"; false; }
}

@test "burn --memory-max: refusals name the variable that set the cap, and --json carries the cap (#236 r2 P3-1/P3-2)" {
  _memcap_init; _stub_codex; _stub_sdrun
  clikae init codex T1
  export STUB_SDRUN_FAIL="Failed to connect to bus: No medium found"
  CLIKAE_BURN_MEMORY_MAX=1G run --separate-stderr clikae burn codex T1 --artifact "$A" --prompt x --json
  [ "$status" -eq 1 ]
  # shellcheck disable=SC2154
  [[ "$stderr" == *"[ FAIL ] CLIKAE_BURN_MEMORY_MAX could not start a systemd user scope (rc 1: Failed to connect to bus: No medium found). Is the user manager running and reachable (systemctl --user status)? Nothing was started; unset CLIKAE_BURN_MEMORY_MAX to run uncapped."* ]] || { echo "$stderr"; false; }
  [[ "$stderr" != *"--memory-max"* ]] || { echo "$stderr"; false; }
  [ "$(_json_field reason)" = "refused: CLIKAE_BURN_MEMORY_MAX could not start a systemd user scope" ]
  [[ "$output" == *'"memory_max":"1G","memory_high":null,"memory_unit":null'* ]] || { echo "$output"; false; }
  unset STUB_SDRUN_FAIL
  STUB_PROBE_MAX=none CLIKAE_BURN_MEMORY_MAX=1G CLIKAE_BURN_MEMORY_HIGH=512M \
    run --separate-stderr clikae burn codex T1 --artifact "$A" --prompt x --json
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"[ FAIL ] CLIKAE_BURN_MEMORY_MAX: a systemd user scope started, but its cgroup does not carry the cap"* ]] || { echo "$stderr"; false; }
  [ "$(_json_field reason)" = "refused: CLIKAE_BURN_MEMORY_MAX does not apply in a systemd user scope here" ]
  [[ "$output" == *'"memory_max":"1G","memory_high":"512M","memory_unit":null'* ]] || { echo "$output"; false; }
  # The flag still names the flag.
  STUB_PROBE_MAX=none run --separate-stderr clikae burn codex T1 --artifact "$A" --prompt x --memory-max 1G --json
  [ "$status" -eq 1 ]
  [ "$(_json_field reason)" = "refused: --memory-max does not apply in a systemd user scope here" ]
  [ ! -e "$L" ]; [ ! -e "$A" ]
}
