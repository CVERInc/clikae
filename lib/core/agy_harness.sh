# shellcheck shell=bash
# lib/core/agy_harness.sh — installing the restraint into an agy tank.
#
# agy discovers customizations from three places; the machine-local one is
# `~/.gemini/config/`, and since clikae points `~/.gemini` at the tank you are
# on, that resolves to `<tank>/config/`. So a hook installed there applies to
# every project you use that tank for, without touching a single one of your
# repos. Verified by experiment (2026-08-12): a hooks.json in the tank's config
# fired in a workspace that had no `.agents/` at all.
#
# This is also why the feature belongs in clikae rather than in a README: agy
# only loads customizations for paths it was given, and clikae is what launches
# it.
#
# COPIED, NOT LINKED. The tank gets its own copy of the script, so editing it is
# how you make it stricter and deleting it is how you turn it off. Pointing at
# clikae's own copy would mean a `brew upgrade` silently rewrote a file someone
# had tuned — and would make "delete it" impossible without removing clikae.

agy_harness_dir()    { printf '%s\n' "$1/config"; }
agy_harness_script() { printf '%s\n' "$1/config/clikae-harness.sh"; }
agy_harness_hooks()  { printf '%s\n' "$1/config/hooks.json"; }

# agy_harness_installed <tank_dir> -> 0 when this tank has the harness.
agy_harness_installed() {
  [ -x "$(agy_harness_script "$1")" ] && [ -f "$(agy_harness_hooks "$1")" ]
}

# agy_harness_install <tank_dir> [force] -> 0 installed, 1 skipped, 2 failed.
#
# NEVER overwrites without `force`. Two different people's edits are at stake:
# someone who tuned the script, and someone who deleted it on purpose. Silently
# restoring a deleted guard is the same bug as silently deleting a guard.
#
# It also refuses to clobber a hooks.json it did not write — a tank may already
# carry someone else's hooks, and merging JSON blindly is how you break both.
agy_harness_install() {
  local dir="$1" force="${2:-0}" src_sh src_json dst_sh dst_json
  [ -n "$dir" ] || return 2
  src_sh="$CLIKAE_ROOT/assets/agy-harness/clikae-harness.sh"
  src_json="$CLIKAE_ROOT/assets/agy-harness/hooks.json"
  [ -f "$src_sh" ] && [ -f "$src_json" ] || return 2

  dst_sh="$(agy_harness_script "$dir")"
  dst_json="$(agy_harness_hooks "$dir")"
  mkdir -p "$(agy_harness_dir "$dir")" 2>/dev/null || return 2

  if [ "$force" != "1" ] && { [ -e "$dst_sh" ] || [ -e "$dst_json" ]; }; then
    return 1
  fi
  if [ -e "$dst_json" ] && ! grep -q 'clikae-harness' "$dst_json" 2>/dev/null; then
    return 1   # someone else's hooks live here
  fi

  cp "$src_sh" "$dst_sh" 2>/dev/null || return 2
  chmod +x "$dst_sh" 2>/dev/null || true
  # The hook command is an absolute path to the tank's own copy, so it keeps
  # working whatever directory agy is launched from.
  sed "s|__CK_HARNESS_SH__|$dst_sh|g" "$src_json" > "$dst_json" 2>/dev/null || return 2
  return 0
}
