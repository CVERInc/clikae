# shellcheck shell=bash
# lib/core/soul.sh — the Soul's path helpers + tank-level membership, shared by
# `clikae memory` (lib/commands/memory.sh) and every engine-launch path.
#
# Why this lives in core: joining a Soul is consented PER TANK (the members file
# records <engine>/<tank>; the cross-account guard runs at share time). For the
# symlink strategy (claude) the engine keeps ONE memory dir per $PWD, so a single
# `share` can only link the directory it ran in — every other directory would
# silently fall back to its own isolated slot, fragmenting the brain the user
# explicitly aggregated. `soul_prelaunch` closes that gap: at every launch, if
# the tank is a member, the CURRENT directory's slot is fanned into the store
# first. Membership (consent) is only ever granted by `memory share` and revoked
# by `memory isolate`; prelaunch just keeps reality in line with it.

souls_root() { printf '%s/souls\n' "$CLIKAE_HOME"; }

# The ONE canonical Soul store for a group — flat & vendor-neutral, so claude,
# codex and agy all point at the same markdown brain (no per-engine forks).
soul_store_path()   { printf '%s/%s/memory\n'  "$(souls_root)" "$1"; }
soul_members_file() { printf '%s/%s/members\n' "$(souls_root)" "$1"; }

# The group <engine>/<tank> is a member of, from the members files (the tank-level
# SSOT — symlinks/pointer notes are per-directory/per-file projections of it).
# Prints nothing when the tank belongs to no group.
soul_group_for_tank() {
  local key="$1/$2" root f
  root="$(souls_root)"
  [ -d "$root" ] || return 0
  for f in "$root"/*/members; do
    [ -f "$f" ] || continue
    if awk -F'\t' -v k="$key" 'NF>=1 && $1==k {found=1} END {exit !found}' "$f" 2>/dev/null; then
      basename "$(dirname "$f")"
      return 0
    fi
  done
  return 0
}

# Rewrite a tank's membership key across every group (for `clikae rename` — the
# profile dir moves, but the members files still name the old tank).
soul_rename_member() {
  local engine="$1" old="$2" new="$3" root f
  root="$(souls_root)"
  [ -d "$root" ] || return 0
  for f in "$root"/*/members; do
    [ -f "$f" ] || continue
    awk -F'\t' -v OFS='\t' -v o="$engine/$old" -v n="$engine/$new" \
      '$1==o {$1=n} {print}' "$f" > "$f.tmp" 2>/dev/null || continue
    mv "$f.tmp" "$f" 2>/dev/null || true
  done
}

# Ensure the CURRENT directory's memory slot of a member tank points at its
# group's store. Called from every non-ephemeral engine-launch path, AFTER the
# adapter is loaded. No-op for: engines without a memory dir (pointer engines
# read the store via their instructions note — nothing per-directory to link),
# non-member tanks, solo tanks, and slots already linked.
soul_prelaunch() {
  local engine="$1" tank="$2" cfg="$3"
  declare -F adapter_memory_dir >/dev/null 2>&1 || return 0
  tank_is_solo "$engine" "$tank" && return 0
  local group store mem cur
  group="$(soul_group_for_tank "$engine" "$tank")"
  [ -n "$group" ] || return 0
  store="$(soul_store_path "$group")"
  [ -d "$store" ] || return 0
  mem="$(adapter_memory_dir "$cfg" 2>/dev/null || true)"
  [ -n "$mem" ] || return 0
  cur="$(readlink "$mem" 2>/dev/null || true)"
  [ "$cur" = "$store" ] && return 0
  if [ -L "$mem" ]; then
    rm -f "$mem"                       # stale link (old store layout / crash)
  elif [ -e "$mem" ]; then
    # This slot accumulated its own memory before the tank joined the Soul.
    # Same contract as `memory share`: stash it aside, reversible — never lost,
    # never silently merged. (A rare second stash gets a unique suffix.)
    local stash="$mem.clikae-soul-stash"
    [ -e "$stash" ] && stash="$stash.$$"
    mv "$mem" "$stash"
    log_dim "soul: this directory had its own memory — stashed at ${stash##*/} (see: clikae memory isolate)"
  fi
  mkdir -p "$(dirname "$mem")"
  ln -s "$store" "$mem"
  log_dim "soul: linked this directory into shared memory '$group'."
}
