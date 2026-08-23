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

# --- Who macOS thinks is asking -----------------------------------------------
# TCC does not grant access to "Claude Code"; it grants access to an IDENTITY.
# For a bundled .app that identity is the bundle id and survives updates. For a
# bare command-line executable it is the PATH — and Claude Code installs each
# release at its own path:
#
#   ~/.local/share/claude/versions/2.1.241     <- 2.1.240 was a different "app"
#
# Measured 2026-08-23: the two versions' code signatures are IDENTICAL, down to
# the designated requirement (`identifier "com.anthropic.claude-code" … OU =
# Q6L2SF6YDW`). Nothing about the binary changed. The path did, and that alone
# was enough for macOS to treat it as software it had never seen, revoking the
# grant with no error, no prompt in a background session, and no trace anywhere
# except EPERM. Four releases landed in 47 hours.
#
# So the fix is per-version and recurring, and the thing the human needs from us
# is the NAME to look for in System Settings — which is the executable's own
# basename, the meaningless-looking "2.1.241" in that list.

# _path_follow <path> -> the file a path finally names. Not `readlink -f`: that
# flag reached BSD readlink late, and this must not become the reason a warning
# about permissions fails on an older machine.
_path_follow() {
  local p="$1" hops=0 t
  while [ -L "$p" ] && [ "$hops" -lt 16 ]; do
    t="$(readlink "$p" 2>/dev/null)" || break
    [ -n "$t" ] || break
    case "$t" in
      /*) p="$t" ;;
      *)  p="$(dirname "$p")/$t" ;;
    esac
    hops=$((hops + 1))
  done
  printf '%s\n' "$p"
}

# _bin_identity_churns <resolved-path> -> true when the executable's own path
# carries a version, i.e. every auto-update hands macOS a stranger.
_bin_identity_churns() {
  case "$1" in
    */versions/*) return 0 ;;
  esac
  case "${1##*/}" in
    [0-9]*.[0-9]*[0-9]) return 0 ;;
  esac
  return 1
}

# _tcc_protected_root <resolved-path> -> the gated area it lives in, named the
# way the human sees it. NOT a guess at which Settings pane grants it: the same
# binary appears under several, and sending someone to the wrong switch is worse
# than sending them to the right list. (2026-08-22 that was exactly the mistake
# — "add it to Full Disk Access", when the dialog had said Documents.)
# shellcheck disable=SC2088  # `~/Documents` here is DISPLAY text, not a path to
# open: it is how the folder is named in the dialog the human just dismissed and
# in System Settings, and expanding it to /Users/<name>/Documents would make the
# message harder to match against the screen it is about.
_tcc_protected_root() {
  case "$1" in
    "$HOME/Library/Mobile Documents"/*) printf 'iCloud Drive (~/Library/Mobile Documents)\n' ;;
    "$HOME/Documents"/*)                printf '~/Documents\n' ;;
    "$HOME/Desktop"/*)                  printf '~/Desktop\n' ;;
    "$HOME/Downloads"/*)                printf '~/Downloads\n' ;;
  esac
}

# _memory_denied_hints <mem> [binary] — the candidate causes whose PRECONDITION
# actually holds, each with the fix that matches it.
#
# 🔴 CANDIDATES, NOT A VERDICT. The first version of this warning named one cause
# ("the tmux server was born without access") and told you to kill the server.
# That was true in 2026-08-15's incident and it is still true sometimes — but on
# 2026-08-23 the same symptom came from an auto-update instead, where killing the
# server fixes nothing and costs you every session on it. A guard that asserts
# one cause hands you a confident wrong move; one that lists what fits leaves the
# choosing to the person who can see the screen.
_memory_denied_hints() {
  local g="$1" mem="$2" real root bin n=0 c
  shift 2
  c="$g        "                              # continuation: past the label column
  real="$(_path_follow "$mem")"
  root="$(_tcc_protected_root "$real")"

  [ "$real" = "$mem" ] || printf '%sit really lives at: %s\n' "$c" "$real" >&2
  [ -n "$root" ] && printf '%sthat is inside %s, which macOS gates.\n' "$c" "$root" >&2
  printf '\n' >&2

  # Every engine that shares this store, not just the one launching: a Soul is
  # deliberately vendor-neutral (claude, codex and agy point at one brain), so
  # "which identity is being refused" can have more than one answer.
  local binary
  for binary in "$@"; do
    [ -n "$binary" ] || continue
    command -v "$binary" >/dev/null 2>&1 || continue
    bin="$(_path_follow "$(command -v "$binary")")"
    _bin_identity_churns "$bin" || continue
    n=$((n + 1))
    printf '%smaybe:  %s auto-updated. macOS identifies a bare executable\n' "$g" "$binary" >&2
    printf '%sby its PATH, and this one carries a version number:\n' "$c" >&2
    printf '%s    %s\n' "$c" "$bin" >&2
    printf '%sso every update is a stranger and the grant is gone.\n' "$c" >&2
    printf '%sfix:    System Settings > Privacy & Security. In the list that\n' "$g" >&2
    printf '%sgates the folder above, switch on the entry named\n' "$c" >&2
    printf '%s    %s\n' "$c" "${bin##*/}" >&2
    printf '%s(it looks like a version because that IS its name).\n' "$c" >&2
    printf '\n' >&2
  done

  if [ -n "${TMUX:-}" ]; then
    n=$((n + 1))
    printf '%smaybe:  the tmux server this session runs in was created by a\n' "$g" >&2
    printf '%sprocess holding no file access, which it can never gain\n' "$c" >&2
    printf '%safterwards.\n' "$c" >&2
    local born; born="$(tmux_server_born 2>/dev/null || true)"
    [ -n "$born" ] && printf '%sserver born: %s\n' "$c" "$born" >&2
    printf '%sfix:    from a terminal that HAS the access: tmux kill-server,\n' "$g" >&2
    printf '%sthen start clikae again. (Costs every session on it.)\n' "$c" >&2
    printf '\n' >&2
  fi

  if [ "$n" -eq 0 ]; then
    printf '%scause:  something above the filesystem refused, and none of the\n' "$g" >&2
    printf '%spatterns clikae knows about fits. On macOS, look for\n' "$c" >&2
    printf '%sthis program in System Settings > Privacy & Security.\n' "$c" >&2
    printf '\n' >&2
  fi
}

# _memory_denied_why <gutter> <mem> [binary...] — the whole answer to "why can
# this not be read", at whatever indent the caller writes in.
#
# 🔴 ONE COPY. The launch warning and `clikae doctor` ask the identical question
# and must not answer it in two voices — the first cut of the doctor check had
# its own `[ -r ]` branch and its own wording, which is how a sentence ends up
# fixed in one place and stale in the other.
#
# The gutter is a parameter rather than a constant because the two callers write
# in different columns: the launch warning sits under `[ WARN ] `, doctor under
# its own 16-wide label field. Hard-coding it left doctor's lines two spaces out
# of true — visible only once it was run on a real machine, never in a test that
# matched substrings.
_memory_denied_why() {
  local g="$1" mem="$2"
  shift 2
  if [ -r "$mem" ]; then
    printf '%sbits:   allow it, and the read still failed.\n' "$g" >&2
    _memory_denied_hints "$g" "$mem" "$@"
  else
    printf '%scause:  the permission bits deny it (%s).\n' \
      "$g" "$(ls -ld "$mem" 2>/dev/null | awk '{print $1}')" >&2
    printf '%sfix:    restore read access to that directory.\n' "$g" >&2
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
  local mem="$1" binary="${2:-}"
  [ -n "$mem" ] || return 0
  [ -e "$mem" ] || return 0                  # nothing there yet — a different story
  ls "$mem" >/dev/null 2>&1 && return 0      # readable — nothing to say

  log_warn "this tank cannot read its own memory."
  printf '         memory: %s\n' "$mem" >&2
  # shellcheck disable=SC2086  # a space-separated engine list, deliberately split
  _memory_denied_why '         ' "$mem" $binary
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
  # The binary too: which identity macOS is refusing is half the diagnosis, and
  # only the adapter knows what this engine actually execs.
  local ebin; ebin="$(adapter_meta_cli_binary 2>/dev/null || true)"
  memory_access_warn "$mem" "$ebin"
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
