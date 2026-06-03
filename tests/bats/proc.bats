#!/usr/bin/env bats
# tests/bats/proc.bats — the cross-shell in-use guard (lib/core/proc.sh) that
# stops rename/migrate/remove from moving a tank out from under an engine running
# in ANOTHER terminal or a background worker (the phantom-tank bug, HANDOFF §11).
#
# macOS-gated: live_dir_users reads process environments via `ps eww` on darwin
# (stubbable here) and via /proc on Linux (not stubbable in a test). CI runs these
# on macos-latest. (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

# Put a `ps` on PATH that reports one process bound to <dir> with <cmd...>.
_stub_ps() {
  local line="$1"
  local stub="$BATS_TEST_TMPDIR/psbin"
  mkdir -p "$stub"
  cat > "$stub/ps" <<STUB
#!/usr/bin/env bash
printf '%s\n' " $line"
STUB
  chmod +x "$stub/ps"
  printf '%s' "$stub"
}

@test "rename hard-fails when an interactive session in another shell holds the tank" {
  [[ "$OSTYPE" == darwin* ]] || skip "process-env scan uses ps on macOS, /proc on Linux"
  clikae init claude work
  local d="$CLIKAE_HOME/profiles/claude/work"
  local stub; stub="$(_stub_ps "99999 claude CLAUDE_CONFIG_DIR=$d")"
  PATH="$stub:$PATH" run clikae rename claude work personal --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"another shell"* ]] || false
  [ -d "$d" ]                                              # not moved
  [ ! -d "$CLIKAE_HOME/profiles/claude/personal" ]
}

@test "rename warns but proceeds when only a background worker holds the tank" {
  [[ "$OSTYPE" == darwin* ]] || skip "process-env scan uses ps on macOS, /proc on Linux"
  clikae init claude work
  local d="$CLIKAE_HOME/profiles/claude/work"
  local stub; stub="$(_stub_ps "88888 claude daemon run --bg-spare CLAUDE_CONFIG_DIR=$d")"
  PATH="$stub:$PATH" run clikae rename claude work personal --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"background"* ]] || false
  [ -d "$CLIKAE_HOME/profiles/claude/personal" ]          # moved
}

@test "rename proceeds when the bound dir is a DIFFERENT tank (exact match only)" {
  [[ "$OSTYPE" == darwin* ]] || skip "process-env scan uses ps on macOS, /proc on Linux"
  clikae init claude work
  clikae init claude other
  local other="$CLIKAE_HOME/profiles/claude/other"
  local stub; stub="$(_stub_ps "77777 claude CLAUDE_CONFIG_DIR=$other")"
  PATH="$stub:$PATH" run clikae rename claude work personal --force
  [ "$status" -eq 0 ]                                      # 'work' isn't the held dir
  [ -d "$CLIKAE_HOME/profiles/claude/personal" ]
}

@test "remove hard-fails when an interactive session holds the tank" {
  [[ "$OSTYPE" == darwin* ]] || skip "process-env scan uses ps on macOS, /proc on Linux"
  clikae init claude work
  local d="$CLIKAE_HOME/profiles/claude/work"
  local stub; stub="$(_stub_ps "99998 claude CLAUDE_CONFIG_DIR=$d")"
  PATH="$stub:$PATH" run clikae remove claude work --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"another shell"* ]] || false
  [ -d "$d" ]                                              # not deleted
}
