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

@test "the in-use scan is best-effort: a FAILING ps must not abort rename/remove" {
  # Regression: live_dir_users leaked the ps pipeline's exit code, so under
  # `set -eo pipefail` a non-zero `ps` (locked-down hosts, CI runners) aborted
  # rename/migrate/remove entirely. HANDOFF §11: the scan is best-effort.
  clikae init claude work
  local bin="$BATS_TEST_TMPDIR/failps"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/ps"; chmod +x "$bin/ps"
  PATH="$bin:$PATH" run clikae rename claude work personal --force
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/personal" ]
  [ ! -d "$CLIKAE_HOME/profiles/claude/work" ]
}

# --- 2026-06-16 adversarial: the interactive-vs-background classifier must not be
# fooled by the ENVIRONMENT block. On macOS `ps eww` appends each process's whole
# environment to the command column, so the cmdline _proc_is_background sees carries
# every env var VALUE too. A bare `*daemon*` / `*--bg-*` substring would then read an
# innocent interactive session (whose env merely contains "daemon" / "--bg-" in a
# path) as a background worker — downgrading the data-integrity hard-fail to a warn
# and letting rename/migrate/remove CORRUPT the live session. ---

@test "_proc_is_background: an interactive session with 'daemon' in an env var is NOT background" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/proc.sh"
  # `ps eww` appended this session's env; XDG_DATA_HOME points at a 'daemon-cache'
  # dir. This is an interactive claude — it must classify as foreground (return 1).
  run _proc_is_background "claude CLAUDE_CONFIG_DIR=/x/work XDG_DATA_HOME=/Users/me/.local/daemon-cache"
  [ "$status" -ne 0 ] || false
}

@test "_proc_is_background: an interactive session with '--bg-' in an arg is NOT background" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/proc.sh"
  # A user prompt / arg legitimately mentioning a '--bg-color' style token must not
  # be mistaken for Claude's real `--bg-spare` / `--bg-pty-host` daemon flags.
  run _proc_is_background "claude -p set the --bg-color CLAUDE_CONFIG_DIR=/x/work"
  [ "$status" -ne 0 ] || false
}

@test "_proc_is_background: Claude's real background markers still classify as background" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/proc.sh"
  run _proc_is_background "claude daemon run CLAUDE_CONFIG_DIR=/x/work"
  [ "$status" -eq 0 ] || false
  run _proc_is_background "claude --bg-spare CLAUDE_CONFIG_DIR=/x/work"
  [ "$status" -eq 0 ] || false
  run _proc_is_background "claude --bg-pty-host CLAUDE_CONFIG_DIR=/x/work"
  [ "$status" -eq 0 ] || false
}

@test "rename HARD-FAILS for an interactive session even when its env contains 'daemon'" {
  [[ "$OSTYPE" == darwin* ]] || skip "process-env scan uses ps on macOS, /proc on Linux"
  clikae init claude work
  local d="$CLIKAE_HOME/profiles/claude/work"
  # An interactive claude in another shell, but its appended env carries a
  # 'daemon-cache' path. Pre-fix this matched `*daemon*` → warn-and-proceed → the
  # live tank got renamed out from under it. It must HARD-FAIL.
  local stub; stub="$(_stub_ps "12321 claude CLAUDE_CONFIG_DIR=$d XDG_DATA_HOME=/Users/me/.local/daemon-cache")"
  PATH="$stub:$PATH" run clikae rename claude work personal --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"another shell"* ]] || false
  [ -d "$d" ]                                              # NOT moved
  [ ! -d "$CLIKAE_HOME/profiles/claude/personal" ]
}
