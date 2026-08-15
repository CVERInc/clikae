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

# ── The machine's default group ─────────────────────────────────────────────
# Consent to share a brain is given ONCE, not per tank. The first `memory share`
# on this machine records the group here; from then on a NEW tank joins it
# automatically unless it is solo.
#
# Why the default is a FILE and not simply "always share": a fresh install must
# share nothing. Someone who never opts in never gets a shared brain, and a
# stranger who makes one tank per client is not silently handed another client's
# memory. But once you HAVE said yes, saying it again for every tank you create
# is not consent — it is a chore that makes the board lie, because the board
# shows fleet-vs-solo and nothing else, so a tank that quietly has no brain looks
# exactly like one that does.
soul_default_file()  { printf '%s/soul-default\n' "$CLIKAE_HOME"; }
soul_default_group() {
  local f; f="$(soul_default_file)"
  [ -f "$f" ] || return 0
  tr -d '[:space:]' < "$f" 2>/dev/null
}
soul_default_set() {
  [ -n "$1" ] || return 0
  mkdir -p "$CLIKAE_HOME"
  printf '%s\n' "$1" > "$(soul_default_file)"
}

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
# Repair an --ephemeral run that never restored. A hard terminal close (SIGHUP)
# or a SIGTERM kills the ephemeral parent before its EXIT trap runs (switch.sh
# now also traps HUP/TERM, but a SIGKILL or power loss still can't be caught), so
# <mem> is left a symlink to a now-deleted throwaway (dangling) and the tank's
# real memory sits in <mem>.clikae-ephemeral-stash — the slot reads as NOTHING
# until a human fixes it. The ephemeral path self-heals only on the NEXT
# ephemeral launch; this runs on EVERY launch (soul_prelaunch is the universal
# memory-prelaunch hook — solo, member, and own-memory tanks all pass through),
# so a plain session recovers too. Soul-shared slots carry no stash: dropping the
# dangling link lets soul_prelaunch re-link the store just below. Never clobbers a
# live memory — the stash is restored only when the slot is genuinely free.
# (Incident 2026-07-19: a hard-closed ejecta ephemeral left the `l` tank's memory
# dangling; the Soul store itself was never touched, only the pointer.)
memory_heal_ephemeral() {
  local mem="$1" stash="$1.clikae-ephemeral-stash" tgt
  [ -n "$mem" ] || return 0
  if [ -L "$mem" ] && [ ! -e "$mem" ]; then          # a dangling symlink
    tgt="$(readlink "$mem" 2>/dev/null || true)"
    case "$tgt" in
      */clikae-ephemeral.*) rm -f "$mem" ;;          # our throwaway — safe to drop
    esac
  fi
  if [ -d "$stash" ] && [ ! -e "$mem" ] && [ ! -L "$mem" ]; then
    mv "$stash" "$mem"
    log_dim "recovered this tank's memory from an interrupted --ephemeral run."
  fi
}

# memory_access_warn <mem> — say something when the tank cannot read its own
# memory, and say WHY.
#
# The signature is a two-syscall asymmetry, and nothing else produces it:
#
#   stat <mem>   succeeds     the path resolves — not a typo, not a dangling link
#   read <mem>   fails        …and still nothing can be read out of it
#
# Deliberately NOT keyed on errno. What separates the two causes is whether the
# filesystem's own permission bits already explain the failure:
#
#   bits say no    an ordinary permissions problem, and `ls -ld` shows it.
#   bits say yes   something ABOVE the filesystem refused. On macOS that is TCC,
#                  and the reason is structural: the tmux server this tank runs
#                  in was created by a process holding no file-access grant, and
#                  a server can never acquire one after birth (DESIGN-tmux Rule
#                  7). Note that `[ -r ]` calls access(2), which reads only the
#                  bits and so answers "yes" here — an actual read is the only
#                  thing that tells the truth.
#
# Diagnosed 2026-08-15, after a Soul living under ~/Library/Mobile Documents
# became unreadable to every tank on one server and readable to every tank on
# another, with no error anywhere but EPERM.
#
# Warn and continue. tmux is a convenience layer rather than a dependency, and
# the same goes for what it can reach: a tank with no memory is a bad session, a
# tank that refuses to start is a worse one. Say it loudly; the human decides.
memory_access_warn() {
  local mem="$1" born
  [ -n "$mem" ] || return 0
  [ -e "$mem" ] || return 0                  # nothing there yet — a different story
  ls "$mem" >/dev/null 2>&1 && return 0      # readable — nothing to say

  log_warn "this tank cannot read its own memory."
  printf '         memory: %s\n' "$mem" >&2
  if [ -r "$mem" ]; then
    printf '         cause:  the permission bits allow it and the read still failed.\n' >&2
    printf '                 On macOS that means the tmux server this session runs\n' >&2
    printf '                 in was created without file access, which it can never\n' >&2
    printf '                 gain afterwards.\n' >&2
    born="$(tmux_server_born 2>/dev/null || true)"
    if [ -n "$born" ]; then
      printf '                 server born: %s\n' "$born" >&2
    fi
    printf '         fix:    from a terminal that HAS the access, run tmux\n' >&2
    printf '                 kill-server, then start clikae again.\n' >&2
  else
    printf '         cause:  the permission bits deny it (%s).\n' \
      "$(ls -ld "$mem" 2>/dev/null | awk '{print $1}')" >&2
    printf '         fix:    restore read access to that directory.\n' >&2
  fi
  # Neutral wording on purpose: soul_prelaunch is the universal memory hook, so
  # this also fires from `clikae memory share`, where "starting anyway" would be
  # a lie about what is happening.
  printf '         Continuing anyway — anything reading this memory sees it empty.\n' >&2
  return 0
}

soul_prelaunch() {
  local engine="$1" tank="$2" cfg="$3"
  _soul_prelaunch_link "$engine" "$tank" "$cfg" || true
  # Asked AFTER the linking, and outside it, so it covers every tank rather than
  # only the Soul members: each early return below lands on a real directory that
  # could be unreachable, and a solo tank losing its memory is the same defect.
  declare -F adapter_memory_dir >/dev/null 2>&1 || return 0
  local mem; mem="$(adapter_memory_dir "$cfg" 2>/dev/null || true)"
  memory_access_warn "$mem"
  return 0
}

_soul_prelaunch_link() {
  local engine="$1" tank="$2" cfg="$3"
  declare -F adapter_memory_dir >/dev/null 2>&1 || return 0
  local group store mem cur
  mem="$(adapter_memory_dir "$cfg" 2>/dev/null || true)"
  # Heal a crashed --ephemeral run FIRST — before the solo/non-member early
  # returns, since those tanks can be run ephemeral too and would otherwise never
  # self-repair on a normal launch.
  [ -n "$mem" ] && memory_heal_ephemeral "$mem"
  tank_is_solo "$engine" "$tank" && return 0
  group="$(soul_group_for_tank "$engine" "$tank")"
  [ -n "$group" ] || return 0
  store="$(soul_store_path "$group")"
  [ -d "$store" ] || return 0
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
