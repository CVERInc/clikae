#!/usr/bin/env bats
# tests/bats/memory-access.bats — WHY a memory store cannot be read.
#
# 🔴 THE DEFECT THIS EXISTS FOR. The first version of this warning named ONE
# cause — "the tmux server was born without file access" — and told you to run
# tmux kill-server. That was true of the 2026-08-15 incident. On 2026-08-23 the
# same symptom came from somewhere else entirely: Claude Code had auto-updated,
# and macOS identifies a bare command-line executable BY ITS PATH:
#
#     ~/.local/share/claude/versions/2.1.241     <- 2.1.240 was a different "app"
#
# Measured that day: the two versions' code signatures are byte-identical down to
# the designated requirement. Nothing about the program changed; only where it
# sat. Against that cause, killing the tmux server fixes nothing and costs every
# session on it — a confident wrong move, handed over by a guard that sounded
# certain.
#
# So the contract these pin is: list the causes whose PRECONDITION HOLDS, and
# never one whose precondition does not.

load '../helpers'

_src_soul() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/soul.sh"
}

# TCC cannot be synthesised, so inject the SHAPE it produces: the permission bits
# say yes and the read still says no.
_deny_read() {
  cat > "$TEST_HOME/.testbin/ls" <<STUB
#!/usr/bin/env bash
case "\$*" in *"$1"*) exit 1 ;; esac
exec /bin/ls "\$@"
STUB
  chmod +x "$TEST_HOME/.testbin/ls"
}

# A fake engine whose executable sits at a version-numbered path, like the real
# one. The stub is REACHED THROUGH A SYMLINK on PATH, because that is the shape
# on a real machine (~/.local/bin/claude -> …/versions/2.1.241) and a probe that
# skips the symlink would not be testing the resolution at all.
_engine_at() {
  # Two statements, not `local ver=$1 d=…$ver`: a `local` builtin expands ALL of
  # its arguments before performing any of the assignments, so $ver would still
  # be empty inside $d. It fails loudly here; it would fail silently in library
  # code.
  local ver="$1"
  local d="$TEST_HOME/eng/versions/$ver"
  mkdir -p "$TEST_HOME/eng/versions"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d"; chmod +x "$d"
  ln -sf "$d" "$TEST_HOME/.testbin/faketool"
}

@test "memory: a readable store produces silence" {
  _src_soul
  local m="$TEST_HOME/mem"; mkdir -p "$m"; : > "$m/MEMORY.md"
  run memory_access_warn "$m" faketool
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "expected silence, got: $output"; false; }
}

@test "memory: a version-pinned engine is named, with the entry to switch on" {
  _src_soul
  local m="$TEST_HOME/mem"; mkdir -p "$m"; : > "$m/MEMORY.md"
  _engine_at 2.1.241
  _deny_read "/mem"
  run memory_access_warn "$m" faketool
  rm -f "$TEST_HOME/.testbin/ls"
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-updated"* ]] || { echo "$output"; false; }
  # 🔴 The actionable half. A warning that says "permissions" and stops leaves you
  # hunting a list of identical-looking rows; the name is the whole point.
  [[ "$output" == *"2.1.241"* ]] || { echo "did not name the entry: $output"; false; }
  [[ "$output" == *"versions/2.1.241"* ]] || { echo "did not show the path: $output"; false; }
}

@test "memory: an engine at a STABLE path is not accused of updating" {
  # The negative control for the check above. Without it, a hint that always
  # printed would pass every assertion in this file while meaning nothing.
  _src_soul
  local m="$TEST_HOME/mem"; mkdir -p "$m"; : > "$m/MEMORY.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_HOME/.testbin/faketool"
  chmod +x "$TEST_HOME/.testbin/faketool"
  _deny_read "/mem"
  run memory_access_warn "$m" faketool
  rm -f "$TEST_HOME/.testbin/ls"
  [ "$status" -eq 0 ]
  [[ "$output" != *"auto-updated"* ]] || { echo "blamed an update that cannot happen: $output"; false; }
}

@test "memory: outside tmux, the tmux server is not blamed" {
  # 🔴 THE REGRESSION THIS FILE IS FOR. The old text always said kill-server.
  # The probe reads the memory in clikae's own process, so a denial seen outside
  # any server is about clikae's identity — killing a server would destroy work
  # and change nothing.
  _src_soul
  [ -z "${TMUX:-}" ] || { echo "premise broken: TMUX leaked into the suite"; false; }
  local m="$TEST_HOME/mem"; mkdir -p "$m"; : > "$m/MEMORY.md"
  _engine_at 2.1.241
  _deny_read "/mem"
  run memory_access_warn "$m" faketool
  rm -f "$TEST_HOME/.testbin/ls"
  [[ "$output" != *"kill-server"* ]] || { echo "$output"; false; }
}

@test "memory: several engines share one brain, only the churning ones are named" {
  # A Soul is deliberately vendor-neutral, so "which identity is refused" can
  # have more than one answer — and must not have a wrong one.
  _src_soul
  local m="$TEST_HOME/mem"; mkdir -p "$m"; : > "$m/MEMORY.md"
  _engine_at 2.1.241
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_HOME/.testbin/steadytool"
  chmod +x "$TEST_HOME/.testbin/steadytool"
  _deny_read "/mem"
  run memory_access_warn "$m" faketool steadytool
  rm -f "$TEST_HOME/.testbin/ls"
  [[ "$output" == *"faketool auto-updated"* ]] || { echo "$output"; false; }
  [[ "$output" != *"steadytool auto-updated"* ]] || { echo "$output"; false; }
}

@test "memory: the gated area is named, and the symlink is followed to it" {
  # The store is reached through a symlink, and the thing macOS is gating is
  # where it LANDS. Printing only the link would send you to look at a path that
  # is not the one being refused.
  _src_soul
  local real="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault/Soul/t"
  mkdir -p "$real"; : > "$real/MEMORY.md"
  local m="$TEST_HOME/mem"; ln -sfn "$real" "$m"
  _deny_read "/mem"
  run memory_access_warn "$m"
  rm -f "$TEST_HOME/.testbin/ls"
  [[ "$output" == *"iCloud Drive"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Mobile Documents"* ]] || { echo "$output"; false; }
  [[ "$output" == *"it really lives at"* ]] || { echo "did not follow the link: $output"; false; }
}

@test "memory: an ordinary chmod is reported as itself" {
  _src_soul
  local m="$TEST_HOME/mem"; mkdir -p "$m"; : > "$m/MEMORY.md"
  chmod 000 "$m"
  run memory_access_warn "$m" faketool
  chmod 755 "$m"
  [[ "$output" == *"permission bits deny"* ]] || { echo "$output"; false; }
  [[ "$output" != *"auto-updated"* ]] || { echo "blamed TCC for a chmod: $output"; false; }
}

@test "memory: when nothing known fits, it says so instead of guessing" {
  _src_soul
  local m="$TEST_HOME/mem"; mkdir -p "$m"; : > "$m/MEMORY.md"
  _deny_read "/mem"
  run memory_access_warn "$m"
  rm -f "$TEST_HOME/.testbin/ls"
  [[ "$output" == *"none of the"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Continuing anyway"* ]] || { echo "stopped saying it keeps going: $output"; false; }
}
