#!/usr/bin/env bats
# tests/bats/burn-memcap.bats — #236: `clikae burn --memory-max` puts the
# ENGINE in its own memory-capped systemd user scope. A cap put around
# `clikae burn` caps nothing: tmux starts the engine, in the tmux server's cgroup.
#   1. with real systemd user scopes, the engine and its children run inside
#      a scope whose cgroup carries the requested memory.max / memory.high;
#   2. without the option nothing changes (the spawn command is pinned);
#   3. a cap that cannot apply is refused before anything starts;
#   4. every launch has its own unit, and no unit outlives the burn.
# Stub engines only. Nothing here allocates memory or generates load.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'
bats_require_minimum_version 1.5.0   # for `run --separate-stderr`

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
# fails with STUB_SDRUN_FAIL), and otherwise logs its argv and execs the
# command after `--`, as `systemd-run --scope` does. A systemctl double next
# to it logs every call to $TEST_HOME/systemctl.log, so nothing here reaches
# the host's real user manager; it reports a unit active when STUB_ACTIVE=1.
_stub_sdrun() {
  : > "$S"
  export STUB_SDRUN_LOG="$S" STUB_SYSTEMCTL_LOG="$TEST_HOME/systemctl.log"
  cat > "$BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_SYSTEMCTL_LOG"
case " $* " in
  *" is-active "*) [ "${STUB_ACTIVE:-0}" = 1 ] || exit 3 ;;
  *" show "*) echo "/user.slice/stub/${!#}" ;;
esac
exit 0
STUB
  chmod +x "$BIN/systemctl"
  cat > "$BIN/systemd-run" <<'STUB'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; printf -- '--END--\n'; } >> "$STUB_SDRUN_LOG"
if [ "${!#}" = clikae-memcap-probe ]; then
  [ -z "${STUB_SDRUN_FAIL:-}" ] || { printf '%s\n' "$STUB_SDRUN_FAIL" >&2; exit 1; }
  printf '%s\n%s\n' "${STUB_PROBE_MAX:-none}" "${STUB_PROBE_HIGH:-max}"
  exit 0
fi
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
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
  [[ "$stderr" == *"memory cap: codex/T1 runs in clikae-burn-codex-T1-burn-"*"-l1.scope (MemoryMax=256M, MemoryHigh=192M)"* ]] || false
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
  want_re='^_burn_capture_stderr systemd-run --user --scope --quiet --collect --unit=clikae-burn-codex-T1-burn-[0-9]+-l1 --description=clikae\\ burn\\ codex/T1 -p MemoryMax=10G -p MemoryHigh=8G -- codex run '
  [[ "$line" =~ $want_re ]] || { echo "$line"; false; }
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
  [[ "$(_engine_line)" == *" -p MemoryMax=2G -- codex run "* ]] || false
  export STUB_PROBE_MAX=1073741824
  CLIKAE_BURN_MEMORY_MAX=1G run clikae burn codex T1 --artifact "$A" --fresh -- run "$A"
  [ "$status" -eq 0 ]
  [[ "$(_engine_line)" == *" -p MemoryMax=1G -- codex run "* ]] || false
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
  grep -qE '^--unit=clikae-burn-codex-first-burn-[0-9]+-l1$' "$S"
  grep -qE '^--unit=clikae-burn-codex-second-burn-[0-9]+-l2$' "$S"
  # one probe + two launches, every one of them capped
  [ "$(grep -c '^--END--$' "$S")" -eq 3 ]
  [ "$(grep -c '^MemoryMax=1G$' "$S")" -eq 3 ]
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
  grep -qE '^--unit=clikae-burn-agy-default-burn-[0-9]+-l1$' "$S"
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
  [[ "$(_json_field memory_unit)" =~ ^clikae-burn-codex-T1-burn-[0-9]+-l1\.scope$ ]] || { echo "$output"; false; }
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
  grep -qE '^--user is-active --quiet clikae-burn-codex-T1-burn-[0-9]+-l1\.scope$' "$TEST_HOME/systemctl.log"
  run ! grep -q ' stop ' "$TEST_HOME/systemctl.log"
  # Still active after the engine returned: its own unit, and only it, is stopped.
  : > "$TEST_HOME/systemctl.log"
  STUB_ACTIVE=1 run clikae burn codex T1 --artifact "$A" --fresh --memory-max 1G -- run "$A"
  [ "$status" -eq 0 ]
  [ "$(grep -c ' stop ' "$TEST_HOME/systemctl.log")" -eq 1 ]
  grep -qE '^--user stop clikae-burn-codex-T1-burn-[0-9]+-l1\.scope$' "$TEST_HOME/systemctl.log"
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
  [[ "$unit" =~ ^clikae-burn-codex-T1-burn-[0-9]+-l2\.scope$ ]] || { echo "$output"; false; }
  prefix="${unit%-l2.scope}"
  [[ "$stderr" == *"memory cap: codex/T1 runs in $prefix-l1.scope"* ]] || false
  [[ "$stderr" == *"memory cap: codex/T1 runs in $prefix-l2.scope"* ]] || false
  # The first launch's leftover was ended with its scope.
  [[ "$stderr" == *"memory cap: codex/T1 exited and left 1 process(es) in $prefix-l1.scope; stopping the scope, which ends them."* ]] || { echo "$stderr"; false; }
  [ -z "$(systemctl --user list-units --all --no-legend "$prefix-*")" ] || { systemctl --user list-units --all "$prefix-*"; false; }
}
