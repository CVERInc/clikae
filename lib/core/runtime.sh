#!/usr/bin/env bash
# lib/core/runtime.sh — a stable, version-independent copy of lib/ for
# anything clikae tells tmux or an engine to run LATER (clikae#146).
#
# WHY. $CLIKAE_LIB on a Homebrew install is
# /opt/homebrew/Cellar/clikae/<version>/libexec/lib, and `brew upgrade`
# deletes the old Cellar. Every path clikae spelled out into a live session —
# the tmux guard's shim dir on the pane PATH, the server-global touch-scroll
# bindings, the status row's `#()` command, a cockpit tank's PreToolUse hook —
# then points at a directory that no longer exists, and each later invocation
# exits 127. Measured 2026-09-24: nine touch_scroll bindings on a live server
# all naming Cellar/clikae/0.31.0 after an upgrade to 0.32.0. Reattaching does
# not repair any of it: those references are written only at creation.
#
# THE FIX, modelled on #59 ($CLIKAE_HOME/bin/claude): copy the installed lib/
# tree to $CLIKAE_HOME/runtime/lib at every launch that writes such a
# reference, and write THAT path instead. The path never changes across
# upgrades; its contents follow the installed version.
#
# LAYOUT. runtime/lib is a SYMLINK to runtime/trees/<stamp>. A sync copies into
# a fresh trees/ entry and swaps the symlink with a rename(2) (`mv -T` on GNU,
# `mv -h` on BSD), so a reader sees either the whole old tree or the whole new
# one, never a half-copied one or a missing path. The previous tree is KEPT
# (only older ones are pruned): cockpit-guard.sh resolves its own directory
# with `cd -P`, so a hook that started a moment before the swap is running from
# the physical old tree and must still find its siblings there.
#
# Opt out with CLIKAE_RUNTIME_STABLE=0 (parity with CLIKAE_CLAUDE_STABLE_PATH=0):
# runtime_lib then prints $CLIKAE_LIB and runtime_sync does nothing.

_runtime_enabled() {
  case "${CLIKAE_RUNTIME_STABLE:-1}" in
    0|off|no|false) return 1 ;;
  esac
  return 0
}

_runtime_dir() { printf '%s/runtime\n' "${CLIKAE_HOME:-$HOME/.clikae}"; }

_runtime_src_lib() {
  printf '%s\n' "${CLIKAE_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
}

# The stamp: installed version on line 1, the source lib/ it was copied from
# on line 2. The second line makes a second install at the SAME version (a
# checkout next to a release) re-sync instead of silently serving the other's
# files.
_runtime_stamp() {
  printf '%s\n%s\n' "${CLIKAE_VERSION:-unknown}" "$(_runtime_src_lib)"
}

# runtime_lib -> the lib/ path to spell into anything run later.
runtime_lib() {
  if _runtime_enabled; then
    printf '%s/lib\n' "$(_runtime_dir)"
  else
    _runtime_src_lib
  fi
}

# runtime_sync -> make $CLIKAE_HOME/runtime/lib a complete copy of the
# installed lib/. Idempotent: a matching VERSION and a present tree is a no-op.
# Never fatal to the caller: on any failure it returns 1 and leaves whatever
# was there in place.
runtime_sync() {
  _runtime_enabled || return 0
  local dir src stamp tree tmp link new old
  dir="$(_runtime_dir)"
  src="$(_runtime_src_lib)"
  stamp="$(_runtime_stamp)"
  [ -d "$src" ] || return 1
  if [ -f "$dir/VERSION" ] && [ -d "$dir/lib/core" ] && [ -d "$dir/lib/shims" ] &&
     [ "$(cat "$dir/VERSION" 2>/dev/null)" = "$stamp" ]; then
    return 0
  fi
  mkdir -p "$dir/trees" 2>/dev/null || return 1
  tmp="$(mktemp -d "$dir/trees/.sync.XXXXXX" 2>/dev/null)" || return 1
  # cp -pR keeps the executable bits (the shim and the hook are exec'd directly).
  if ! cp -pR "$src/." "$tmp/" 2>/dev/null; then
    rm -rf "$tmp"; return 1
  fi
  tree="${CLIKAE_VERSION:-unknown}.${tmp##*.sync.}"
  new="$dir/trees/$tree"
  mv "$tmp" "$new" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  old=""
  [ -L "$dir/lib" ] && old="$(readlink "$dir/lib" 2>/dev/null || true)"
  link="$dir/.lib.$$"
  rm -f "$link"
  ln -s "trees/$tree" "$link" 2>/dev/null || { rm -rf "$new"; return 1; }
  # A plain directory (never written by this code, but possible by hand)
  # cannot be replaced by a rename of a symlink; move it aside first.
  if [ -d "$dir/lib" ] && [ ! -L "$dir/lib" ]; then
    mv "$dir/lib" "$dir/trees/.legacy.$$" 2>/dev/null || true
  fi
  if ! { mv -Tf "$link" "$dir/lib" 2>/dev/null || mv -hf "$link" "$dir/lib" 2>/dev/null; }; then
    rm -f "$link"; rm -rf "$new"; return 1
  fi
  # VERSION last: a crash before this line leaves a stale stamp, which only
  # means the next launch copies again.
  printf '%s' "$stamp" > "$dir/VERSION.$$" && mv -f "$dir/VERSION.$$" "$dir/VERSION"
  # Keep the tree just swapped in and the one it replaced; prune the rest.
  local t base
  for t in "$dir"/trees/* "$dir"/trees/.legacy.*; do
    [ -e "$t" ] || continue
    base="trees/${t##*/}"
    [ "$base" = "trees/$tree" ] && continue
    [ -n "$old" ] && [ "$base" = "$old" ] && continue
    case "${t##*/}" in .sync.*) continue ;; esac   # another launch mid-copy
    rm -rf "$t"
  done
  return 0
}

# runtime_doctor -> one row: where the runtime copy is and whether it matches.
runtime_doctor() {
  local dir have want
  if ! _runtime_enabled; then
    printf '  %-16s %s\n' "runtime" "off (CLIKAE_RUNTIME_STABLE=0): live sessions point at $(_runtime_src_lib)"
    return 0
  fi
  dir="$(_runtime_dir)"
  want="${CLIKAE_VERSION:-unknown}"
  if [ ! -d "$dir/lib/core" ] || [ ! -f "$dir/VERSION" ]; then
    printf '  %-16s %s\n' "runtime" "missing: $dir/lib (the next clikae session creates it)"
    return 0
  fi
  have="$(head -n1 "$dir/VERSION" 2>/dev/null)"
  if [ "$(cat "$dir/VERSION" 2>/dev/null)" = "$(_runtime_stamp)" ]; then
    printf '  %-16s %s\n' "runtime" "$dir/lib ($have)"
  else
    printf '  %-16s %s\n' "runtime" "stale: $dir/lib is $have, installed is $want (the next clikae session refreshes it)"
  fi
  return 0
}
