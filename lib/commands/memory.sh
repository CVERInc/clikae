# shellcheck shell=bash
# lib/commands/memory.sh — `clikae memory <share|isolate|status>`: the memory dial
# (docs/grammar.md §10, docs/memory.md). A tank holds more than fuel — it holds the
# engine's long-term memory. This points that memory at ONE shared markdown store so
# several of your own tanks — across ENGINES — read/write a single "Soul":
#
#   share   N tanks → 1 store   (aggregate your brain across YOUR accounts & engines)
#   isolate N → N               (today's default — restore the tank's own memory)
#   status                      (which tanks share which group)
#
# Two ways a tank points at the canonical Soul, by what the engine exposes:
#   · symlink strategy (claude) — the engine keeps memory in a markdown DIR
#     (adapter_memory_dir); we fan that dir into the store with a symlink. Per-$PWD,
#     mirroring claude's per-project memory. The persistent sibling of --ephemeral's
#     fan-OUT (switch.sh §10.4): same stash/restore, pointed at a kept store.
#   · pointer strategy (codex) — the engine keeps memory opaquely (sqlite) but reads
#     a markdown INSTRUCTIONS file (adapter_memory_pointer_path, e.g. $CODEX_HOME/
#     AGENTS.md). We drop a fenced "your long-term memory is <store>; read it, append
#     to it" note there. The engine reads+writes the SAME markdown via the memory
#     protocol — so cross-engine needs NO translator and never drifts (no LLM rewrite).
#
# The canonical Soul is ONE vendor-neutral markdown dir: $CLIKAE_HOME/souls/<group>/
# memory. claude symlinks into it; codex points at it; all read/write it directly.
#
# 🔴 Locked values (docs/memory.md §4): aggregate-never-mutate-the-source (seed by
# COPY; stash a joiner's own memory aside, reversible); account isolation is sacred
# (opt-in, per-tank, never auto-cross — crossing your own accounts is announced); no
# phantom continuity (Soul carries context, not the model's capability).

# Path helpers + tank-level membership live in lib/core/soul.sh (always sourced
# by bin/clikae): souls_root, soul_store_path, soul_members_file,
# soul_group_for_tank, soul_prelaunch. Membership is the tank-level SSOT;
# symlinks (claude, per-directory) and pointer notes (codex/agy) are projections
# of it — soul_prelaunch re-projects the current directory at every launch.
_memory_store_path() { soul_store_path "$1"; }

# Are <a> and <b> the SAME directory? Resolved with `pwd -P` (symlinks followed,
# trailing slashes and `..` collapsed) rather than compared as literal strings —
# a trailing slash (what shell tab-completion adds) or a `..` segment must not
# make two paths that name the same directory look like two different sources.
# Prints nothing; empty output on either side (path doesn't exist) means "no".
_memory_same_dir() {
  local a b
  a="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  b="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# Seed the Soul's operating manual into the store (write-back hygiene). claude
# learns the memory protocol from its system prompt, but codex/agy only get the
# pointer note's gist — so the full read+write rules live IN the store, where any
# engine reading the Soul (and any human browsing it) finds them. Idempotent: only
# written if absent, never clobbers a hand-edited one.
_memory_seed_protocol() {
  local store="$1" f="$1/PROTOCOL.md"
  [ -e "$f" ] && return 0
  mkdir -p "$store"
  cat > "$f" <<'PROTO'
# Soul — how to read & write this memory

> This file is managed by `clikae memory` (docs/memory.md). It is the operating
> manual for the shared markdown "Soul" in this directory. Several of one person's
> own AI tanks — possibly across engines (Claude / Codex / Antigravity) — read and
> write these same files. Follow these rules so the Soul stays coherent.

## Reading
- `MEMORY.md` is the index — one line per memory, grouped by area. Read it first,
  then open only the topic files relevant to the task. Don't load everything.
- Each topic file holds ONE fact, with YAML frontmatter (`name`, `description`,
  `metadata.type` = user | feedback | project | reference).
- Remember: a memory records what was TRUE WHEN WRITTEN, not necessarily now. If a file
  names a path/flag/version, verify against the real code before relying on it.
- Remember: some files record a past *incident* or a *correction* (e.g. a mis-attribution
  that was fixed). Read the file's own framing + its `description`; do not take an
  incident record as a current fact about the user.

## Writing back
- When you learn a durable fact about the user or the work, persist it: append or
  update ONE topic file (one fact per file), then add/update its one-line pointer
  in `MEMORY.md`. Keep index lines short (≤ ~200 chars).
- Prefer UPDATING an existing file over creating a near-duplicate. Delete a file
  that turns out to be wrong (and its index line).
- Concurrency: another tank may be writing too. Touch only the files you're
  changing; never rewrite the whole `MEMORY.md` — append/edit your own line. Keep
  one fact per file so two writers rarely collide on the same file.
- Don't record what the repo already captures (code structure, git history) or what
  only matters to one conversation.

## Optional Soul frontmatter (clikae)
- `metadata.scope` = share | isolate | evaporate — whether this fact may travel.
- `metadata.project` = an area slug — groups the entry in the index.
- `metadata.accounts` = a share-group allowlist. Never break this: account isolation is sacred:
  never copy a fact into a group it isn't allowed in.
PROTO
}

# Copy every file under <src> into <dst>, recursively, preserving mode (`cp
# -p`, the same private-file guarantee _memory_adopt gives topic files). A
# symlink is followed and its TARGET's content copied in (vendor-neutral: the
# Soul shouldn't hold a link pointing back out at a path that only exists on
# this machine) — except a dangling one, which is skipped and reported by
# name, the same as an unreadable file. One file that can't be read
# (permission denied) must not fail the whole seed — before this it did, via
# `cp -R … || log_fail`, which turned "join the fleet" from something that
# almost never failed into something that could, for a reason that had
# nothing to do with the join itself. The tank's own memory at <src> is
# unaffected either way — it is left in place here and only replaced by a
# symlink later in _memory_share, once seeding is done. Reports what it
# skipped; never fails.
_memory_seed_dir() {
  local src="$1" dst="$2" f rel skipped=0
  while IFS= read -r f; do
    rel="${f#"$src"/}"
    if [ -L "$f" ] && [ ! -f "$f" ]; then
      log_warn "Skipping dangling symlink $rel while seeding memory from $src."
      skipped=$((skipped+1))
      continue
    fi
    mkdir -p "$dst/$(dirname "$rel")" 2>/dev/null
    if ! cp -p "$f" "$dst/$rel" 2>/dev/null; then
      log_warn "Couldn't read $rel while seeding memory from $src — skipped."
      skipped=$((skipped+1))
    fi
  done < <(find "$src" \( -type f -o -type l \) 2>/dev/null)
  if [ "$skipped" -gt 0 ]; then
    log_warn "$skipped file(s) under $src were not copied into the Soul (unreadable); the rest were — $src itself is unchanged."
  fi
  return 0
}

_memory_members_file() { soul_members_file "$1"; }

# Drop a tank (field 1 == <engine>/<tank>) from a group's member file, in place.
_memory_drop_member() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -F'\t' -v k="$key" 'NF>=1 && $1!=k' "$file" > "$file.tmp" 2>/dev/null || true
  mv "$file.tmp" "$file" 2>/dev/null || true
}

# Resolve the tank this command acts on, and HOW it points at a Soul. Sets:
#   MEM_CLI MEM_TANK MEM_CFG   — the tank
#   MEM_STRATEGY               — "symlink" (adapter_memory_dir) | "pointer" (adapter_memory_pointer_path)
#   MEM_DIR                    — (symlink) the tank's real memory dir for $PWD
#   MEM_PTR                    — (pointer) the instructions file we write the note into
# Default engine = claude; default tank = whichever this shell is switched to.
_memory_resolve_tank() {
  local engine="$1" tank="$2"
  [ -n "$engine" ] || engine="claude"
  # Launch-only targets (agy) keep memory opaquely but read a markdown rules file
  # (GEMINI.md). They don't load via load_adapter — source the target and use its
  # pointer hook. Single-account/global, so the "active tank" is the ~/.gemini link.
  if clikae_is_target "$engine"; then
    local canon="$engine"; [ "$canon" = "agy" ] && canon="antigravity"
    # shellcheck source=/dev/null
    source "$CLIKAE_LIB/targets/$canon.sh" 2>/dev/null || log_fail "memory: can't load target '$engine'."
    declare -F target_memory_pointer_path >/dev/null 2>&1 \
      || log_fail "memory: cross-engine Soul for '$engine' isn't supported yet."
    MEM_STRATEGY="pointer"
    if [ -z "$tank" ]; then
      tank="$(target_active_profile 2>/dev/null || true)"
      [ -n "$tank" ] || log_fail "memory: no active $engine tank — name one: clikae memory <sub> $engine <tank>"
    fi
    profile_exists "$canon" "$tank" || log_fail "memory: no such tank: $engine/$tank"
    MEM_CLI="$canon"; MEM_TANK="$tank"
    MEM_CFG="$(profile_dir "$canon" "$tank")"
    MEM_DIR=""; MEM_PTR="$(target_memory_pointer_path "$MEM_CFG")"
    [ -n "$MEM_PTR" ] || log_fail "memory: '$engine' reported no rules file to point."
    return 0
  fi
  load_adapter "$engine" >/dev/null 2>&1 || log_fail "memory: no adapter for '$engine'."
  if declare -F adapter_memory_dir >/dev/null 2>&1; then
    MEM_STRATEGY="symlink"
  elif declare -F adapter_memory_pointer_path >/dev/null 2>&1; then
    MEM_STRATEGY="pointer"
  else
    log_fail "memory: '$engine' has no known memory layout (supported: claude, codex)."
  fi
  if [ -z "$tank" ]; then
    local var value
    var="$(adapter_meta_env_var)"
    value="$(eval "printf '%s' \"\${$var:-}\"")"
    tank="$(resolve_active_profile "$engine" "$(adapter_meta_strategy)" "$value")"
    [ -n "$tank" ] || log_fail "memory: no $engine tank active in this shell — name one: clikae memory <sub> $engine <tank>"
  fi
  profile_exists "$engine" "$tank" || log_fail "memory: no such tank: $engine/$tank"
  MEM_CLI="$engine"; MEM_TANK="$tank"
  MEM_CFG="$(profile_dir "$engine" "$tank")"
  MEM_DIR=""; MEM_PTR=""
  if [ "$MEM_STRATEGY" = "symlink" ]; then
    MEM_DIR="$(adapter_memory_dir "$MEM_CFG")"
    [ -n "$MEM_DIR" ] || log_fail "memory: '$engine' reported no memory dir for this directory."
  else
    MEM_PTR="$(adapter_memory_pointer_path "$MEM_CFG")"
    [ -n "$MEM_PTR" ] || log_fail "memory: '$engine' reported no instructions file to point."
  fi
}

_memory_account() {                            # best-effort account label for MEM_CFG
  if declare -F adapter_account_label >/dev/null 2>&1; then
    adapter_account_label "$MEM_CFG" 2>/dev/null || true
    return 0
  fi
  # Targets have no adapter hook; agy keeps its login email only in its cli log.
  if [ "${MEM_CLI:-}" = "antigravity" ] && declare -F agy_email >/dev/null 2>&1; then
    agy_email "$MEM_CFG" 2>/dev/null || true
    return 0
  fi
  printf '\n'
}

# Which group (if any) the resolved tank currently shares. Membership (the
# members file) is authoritative — a per-directory symlink only tells you about
# $PWD's slot. The per-strategy inspection remains as a fallback so a tank
# linked by hand (or by a pre-membership clikae) still reads as shared.
_memory_current_group() {
  local g
  g="$(soul_group_for_tank "$MEM_CLI" "$MEM_TANK")"
  if [ -n "$g" ]; then printf '%s\n' "$g"; return 0; fi
  if [ "$MEM_STRATEGY" = "symlink" ]; then
    [ -L "$MEM_DIR" ] || return 0
    local tgt root; tgt="$(readlink "$MEM_DIR" 2>/dev/null || true)"
    root="$(souls_root)/"
    case "$tgt" in
      "$root"*) tgt="${tgt#"$root"}"; printf '%s\n' "${tgt%%/*}" ;;
    esac
  else
    [ -f "$MEM_PTR" ] || return 0
    # Read the group from our fenced sentinel: `>>> clikae soul:<group> >>>`.
    sed -n 's/.*>>> clikae soul:\([^ ]*\) >>>.*/\1/p' "$MEM_PTR" 2>/dev/null | head -n 1
  fi
}

# Every memory slot of MEM_CFG currently linked into <store> (claude keeps one
# memory dir per project directory — projects/<slug>/memory). Used by isolate
# (unlink them ALL) and share (link the already-existing ones eagerly; new
# directories are linked lazily by soul_prelaunch at launch).
_memory_all_linked_slots() {
  local store="$1" l
  find "$MEM_CFG" -maxdepth 3 -type l -name memory 2>/dev/null | while IFS= read -r l; do
    [ "$(readlink "$l" 2>/dev/null || true)" = "$store" ] && printf '%s\n' "$l"
  done
}

# ── pointer-strategy note (fenced, idempotent, removable) ───────────────────
_memory_ptr_open()  { printf '<!-- >>> clikae soul:%s >>> -->' "$1"; }
_memory_ptr_close() { printf '<!-- <<< clikae soul:%s <<< -->' "$1"; }

# Strip our fenced block for <group> out of <file>, in place (leaves the rest).
_memory_ptr_strip() {
  local file="$1" group="$2" o c
  [ -f "$file" ] || return 0
  o="$(_memory_ptr_open "$group")"; c="$(_memory_ptr_close "$group")"
  awk -v o="$o" -v c="$c" '
    index($0,o){skip=1}
    !skip{print}
    index($0,c){skip=0}
  ' "$file" > "$file.tmp" 2>/dev/null || true
  # Write THROUGH the instructions file (AGENTS.md / GEMINI.md), don't `mv` onto it:
  # a user may symlink it into a dotfiles repo, and `mv` would detach the link.
  [ -f "$file.tmp" ] && { cat "$file.tmp" > "$file" 2>/dev/null || true; rm -f "$file.tmp"; }
  # Always 0: this strip is best-effort (the old `mv … || true` never failed the
  # caller), and callers run under `set -eo pipefail` — a missing tmp on the `&&`
  # above must not abort a share/solo mid-flight.
  return 0
}

# Write/refresh the Soul pointer for <group> into <file>, pointing at <store>.
_memory_ptr_write() {
  local file="$1" group="$2" store="$3"
  mkdir -p "$(dirname "$file")"
  _memory_ptr_strip "$file" "$group"
  # Keep a trailing newline before our block if the file has prior content.
  [ -s "$file" ] && printf '\n' >> "$file"
  {
    _memory_ptr_open "$group"; printf '\n'
    printf '## Your long-term memory (Soul)\n\n'
    printf 'Your durable memory lives at:\n\n    %s\n\n' "$store"
    printf 'Read `%s/MEMORY.md` first — it indexes everything. It is plain markdown you\n' "$store"
    printf 'own and share with your other engines. The full read + write-back rules are in\n'
    printf '`%s/PROTOCOL.md` — read it before writing anything back. In short: pull in the\n' "$store"
    printf 'files relevant to the task, and when you learn a durable fact about the user or\n'
    printf 'project, append/update a file there (one fact per file) and add a one-line\n'
    printf 'pointer to MEMORY.md. This is shared continuity & context across engines — not a\n'
    printf 'different model'"'"'s capability.\n'
    _memory_ptr_close "$group"; printf '\n'
  } >> "$file"
}

cmd_memory() {
  local sub=""
  [ $# -gt 0 ] && { sub="$1"; shift; }
  case "$sub" in
    ""|-h|--help|help)
      cat <<'EOF'
Usage: clikae memory <share|isolate|status> [options]

A tank holds more than fuel — it holds the engine's long-term memory. This points
that memory at ONE shared markdown store, so several of YOUR OWN tanks — across
engines — read/write a single "Soul" (continuity & context). See docs/memory.md.

  clikae memory share <group> [<engine> <tank>]   point a tank at <group>'s Soul store
  clikae memory status         [<engine> <tank>]   show share state
  clikae memory status --json                      the same, machine-readable:
                               one object per tank {cli, tank, group, account,
                               solo, inconsistent, dispatchable}. `dispatchable`
                               is false for a solo tank AND for one in the
                               impossible solo-and-shared state — read it before
                               fanning work out.

To take a tank OUT of the shared brain, make it standalone: `clikae solo <engine>
<tank>` leaves the group and gives the tank its own memory back. There is no
separate `isolate` — in the fleet means sharing, solo means not, and the board
shows which is which.

Defaults: engine = claude; tank = whichever this shell is switched to.
Engines: claude fans its memory DIR into the store (symlink, per-directory); codex
and agy read a pointer note in their AGENTS.md / GEMINI.md and read/write the same
markdown via the memory protocol.

Flags:
  -y, --yes    skip the cross-account confirmation (for scripts/automation)

On a Claude tank's first share, existing ~/.claude and tank project memory is
listed and offered for adoption [y/N]. Non-interactive runs print an exact command:
  clikae memory share <group> claude <tank> --adopt <memory-dir>
--adopt also works after joining. It copies markdown topics without overwriting
names and appends MEMORY.md under a source heading; originals remain untouched.
--yes confirms account sharing only, never adoption of discovered sources.

Note: consent is given ONCE, not per tank. Nothing is shared until your first `share`;
that share also records the group as this machine's default, and from then on a NEW
tank joins it automatically at `clikae init`. A solo tank never joins. Crossing your
own accounts is still announced at that first share. The store is seeded by COPY; a
joiner's own memory is stashed aside (given back by `clikae solo`), never overwritten.

Why automatic: the board's only axis is fleet-vs-solo, so a tank sitting in the fleet
with no brain looks exactly like one that has it. Asking per tank produced that state
routinely, and nothing on screen could tell you.
EOF
      return 0 ;;
    share)   _memory_share "$@" ;;
    status)  _memory_status "$@" ;;
    isolate)
      # Retired 2026-07-27. It read like "incognito" and was reached for as such —
      # an agent ran it on a LIVE tank to spawn a cold reader and the maintainer's
      # running session went amnesiac mid-flight (v0.14.3). It also created a third,
      # invisible state: a tank inside the fleet with no brain, which the board has
      # no way to show. Leaving the fleet is now one visible idea.
      log_fail "memory isolate is gone. To take a tank out of the shared brain use \`clikae solo $*\` — it leaves the group AND gives the tank its own memory back, and the board shows it. For a memory-less SESSION you want \`--ephemeral\`, which changes this run only." ;;
    *) log_fail "memory: unknown subcommand '$sub' (try: share | status)" ;;
  esac
}

# Count of files _memory_adopt would actually copy from <source> — every
# regular file under it, recursively (see _memory_adopt for why: adoption
# follows the whole index, not just top-level markdown), except the index
# itself. Used for the "Found memory: … (N files)" / "Adopt … (N files)?"
# prompts, which before this counted only top-level *.md — AND counted
# MEMORY.md itself as one of them, so a source with one real topic file
# reported "(2 files)".
_memory_adopt_count() {
  local source="$1"
  # `|| true` around the `find | grep` pair, not just at the end: callers run
  # under `set -eo pipefail`, and `grep -v` exits 1 when EVERY line matched
  # and got filtered out (source holds only MEMORY.md, so 0 lines remain) —
  # without this, that "correct answer of zero" aborted the whole command.
  { find "$source" -type f 2>/dev/null | grep -vFx "$source/MEMORY.md" || true; } | wc -l | tr -d ' '
}

# Adopt a source's memory by copy: every regular file under it, recursively —
# not just top-level markdown. A source's MEMORY.md commonly links into
# subdirectories (an archive/, per-topic notes/) and to non-markdown
# attachments (a diagram); copying only the top level left those links
# silently pointing at nothing once adopted, with no warning. A symlinked
# file is followed and its target's content copied in; a DANGLING symlink is
# skipped and reported by name, same as an unreadable file, rather than
# aborting the adopt. Collisions with an existing store file stay in the
# source and are announced, never silently overwritten.
#
# Everything is staged in a scratch directory NEXT TO the store (same
# filesystem as the store's parent, never inside the store itself) first, and
# moved into place only once the whole copy has succeeded. A copy that fails
# partway (one unreadable file among several) must leave nothing behind: the
# next share's seed gate used to be "store non-empty" (`[ -z "$(ls -A
# "$store")" ]`) — before staging existed, that could only be true after a
# real successful share; a half-copied adopt satisfied it too, so a retry
# never seeded the joiner's own (stashed, reversible) memory in at all.
#
# 🔴 Staging used to live INSIDE the store (`mktemp -d "$store/.adopt.XXXXXX"`)
# with no trap. An interrupted adopt (Ctrl-C, a closed terminal, a killed
# session — anything that kills this process before any of the three explicit
# `rm -rf "$staging"` returns below get to run) left that `.adopt.*` directory
# behind FOREVER, and `ls -A "$store"` sees a dotdir just fine: the very next
# `memory share` on this group read "store non-empty" and silently skipped
# seeding — green output, an empty Soul (R6-P2-1). Two independent fixes: this
# function no longer stages inside the store at all (so nothing it does can
# trip that gate), and a `trap` frees the staging dir on a signal too, not
# only on a `return`. Belt AND suspenders — `_memory_share`'s seed gate below
# also ignores dotfiles/dot-dirs on its own, so residue from an OLDER build of
# clikae (which did stage inside the store) can't fool it either.
#
# One helper for every private scratch file this function writes as a
# SIBLING of $staging (never inside it — see why above): 0600 explicitly,
# because under `umask 000` a bare `: > "$f"` would leave it at 0666,
# world-writable, inside `souls/<group>` (0777 — R4-P3-14, unrelated and
# unchanged here). $moved lists absolute store paths the rollback below
# unlinks/rmdirs by name, and $staging.lnerr captures `ln`'s stderr every
# time through the move loop — either one, a co-resident user on a shared
# machine could otherwise tamper with while an adopt is in flight (R9-P3-2,
# R10-P3-1). $staging itself already gets 0700 from `mktemp -d`'s own mode,
# independent of umask.
_memory_adopt_private_tempfile() {
  { : > "$1" && chmod 600 "$1"; } 2>/dev/null
}
# Undo exactly what THIS invocation's move-into-place loop (inside
# _memory_adopt, below) has linked into $store so far — read from $moved, a
# manifest of destination paths kept OUTSIDE $staging (see _memory_adopt's
# comment). Called from the signal traps AND from the move_failed path, so
# neither an interruption nor a hard failure mid-move can strand a `ln`'d
# file with no "## Adopted from" heading pointing at it (R8-P2-1). Never
# touches anything not listed in $moved — a pre-existing store file that a
# collision skipped ("Keeping existing …") was never appended to $moved and
# so is never a candidate here. Best-effort throughout: one `rm -f` failing
# must not stop the rest of the rollback (`$staging`, `$moved` themselves)
# from being cleaned up.
#
# $dirs (R10-P2-1) is the companion manifest of directories the move loop's
# own `mkdir -p` actually created (never ones that already existed — see the
# move loop's own guard). Removed with `rmdir`, NEVER `rm -rf` — a directory
# on a store path is never blown away wholesale here — and only AFTER every
# file above has already been unlinked, so an empty one goes quietly and one
# that (should never happen, but belt-and-suspenders) still holds something
# this rollback didn't unlink is simply left in place. `sort -ru` is
# deepest-first for free: a directory string is always a proper PREFIX of
# anything nested under it, so plain lexicographic order already puts a
# child after its own parent everywhere it matters, `-r` reverses that, and
# `-u` collapses a directory recorded once per file it ended up holding down
# to a single `rmdir` attempt.
_memory_adopt_rollback() {
  local moved="$1" staging="$2" dirs="$3" d
  if [ -f "$moved" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && rm -f "$d" 2>/dev/null
    done < "$moved"
  fi
  if [ -n "$dirs" ] && [ -f "$dirs" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && rmdir "$d" 2>/dev/null
    done < <(sort -ru "$dirs" 2>/dev/null)
  fi
  rm -rf "$staging"
  rm -f "$moved" "$dirs" 2>/dev/null
  # "$staging.lnerr" — `ln`'s captured stderr for whichever call was in
  # flight — is a SIBLING of $staging (see why above), so `rm -rf "$staging"`
  # above doesn't reach it; a signal landing mid-`ln` can leave it behind.
  rm -f "${staging}.lnerr" 2>/dev/null
  return 0
}

_memory_adopt() {
  local source="$1" store="$2" sdir f rel staging dest destdir newdir heading broken=0 target line found=0 copied=0 moved dirsfile linked=0
  ! _memory_same_dir "$source" "$store" || return 0
  # Never append through an index symlink into somebody else's memory — check
  # this FIRST, before touching anything, so a refusal here leaves the store
  # exactly as it was. (Moved up from after the copy loop: it used to run only
  # once topic files had already landed, so a symlinked MEMORY.md still left
  # files adopted with no index entry pointing at them.)
  [ ! -L "$store/MEMORY.md" ] || { log_err "Refusing to append to a symlinked MEMORY.md"; return 1; }

  # A trailing slash on $source (shell tab-completion) must not break the
  # "$sdir/" prefix strip below: with the slash left in, the prefix pattern
  # gains a SECOND slash ("…/legacy//") that never matches find's single-slash
  # output, so nothing strips and `rel` ends up as the full absolute path —
  # every file then lands nested under that whole path inside the store
  # instead of at its real name. $source itself (trailing slash and all) is
  # kept as-is everywhere else (the heading text, the dedup check) — only this
  # local copy is normalized, for path arithmetic.
  sdir="${source%/}"

  # Validate the source is actually usable BEFORE anything is created inside
  # the store: an unlistable directory or an unreadable index must fail here.
  # Without this, a failure reading $source/MEMORY.md while merging the index
  # (below, well after topic files are already moved into place) left an
  # orphan "## Adopted from" heading with nothing under it — and that heading
  # alone is enough for _memory_adopted_heading_exists to treat this source as
  # already merged, so no retry (even after fixing the permission) could ever
  # append its index again.
  [ -r "$sdir" ] && [ -x "$sdir" ] || { log_err "Can't list $source"; return 1; }
  [ -r "$sdir/MEMORY.md" ] || { log_err "Can't read $source/MEMORY.md"; return 1; }

  # Resolve the adopt directory itself, not just the files under it. `find`
  # never descends into an operand that is ITSELF a symlink — it only matches
  # the symlink as a single `-type l` entry and stops there. That is exactly
  # the maintainer's own layout (memory lives in iCloud; a bare symlink in
  # $HOME points at it): `find "$sdir" …` below saw only $sdir, matched it as
  # a dangling-looking symlink, and never listed a single file inside it,
  # while the index still merged and printed a clean DONE. Canonicalizing
  # first — the same `cd … && pwd -P` _memory_same_dir already uses — makes
  # the loop see the real directory, whichever path segment carried the link.
  sdir="$(cd "$sdir" && pwd -P)" || { log_err "Can't resolve $source"; return 1; }

  # Staged as a SIBLING of the store, not inside it — see the comment above —
  # but still on the store's own filesystem: the move below (`ln`, a hard
  # link) requires that, and `$store`'s parent already IS that filesystem
  # (`_memory_share` just `mkdir -p`'d $store under it).
  staging="$(mktemp -d "$(dirname "$store")/.adopt.XXXXXX" 2>/dev/null)" \
    || { log_err "Couldn't stage adoption of $source"; return 1; }
  # Manifest of destination paths THIS invocation's move-into-place loop
  # (below) actually `ln`s into $store — kept as a SIBLING file, OUTSIDE
  # $staging, specifically so the `rm -rf "$staging"` on every exit path below
  # can never take it down before a trap or move_failed gets to read it. This
  # is what makes the move loop's own rollback (R8-P2-1) exact: it can unlink
  # precisely what THIS run linked, and never anything that was already in
  # the store. 0600 via _memory_adopt_private_tempfile (R9-P3-2) — see that
  # helper's own comment.
  moved="$staging.moved"
  _memory_adopt_private_tempfile "$moved" \
    || { log_err "Couldn't stage adoption of $source"; rm -rf "$staging"; return 1; }
  # Companion manifest (R10-P2-1): every directory the move loop's own
  # `mkdir -p "$(dirname "$dest")"` actually creates — never one that already
  # existed — so the rollback can `rmdir` exactly those, the same way $moved
  # lets it `rm -f` exactly the files it linked. Before this, that mkdir -p
  # ran unconditionally at the top of every iteration and nothing recorded or
  # ever freed what it created: a source with even one subdirectory
  # (archive/, notes/, …) left an empty directory behind after a signal or a
  # move_failed, and _memory_store_has_content's glob below couldn't tell
  # that apart from real content either — R8-P2-1's exact symptom, wearing a
  # directory instead of a file.
  dirsfile="$staging.dirs"
  _memory_adopt_private_tempfile "$dirsfile" \
    || { log_err "Couldn't stage adoption of $source"; rm -f "$moved"; rm -rf "$staging"; return 1; }
  # $staging.lnerr (R10-P3-1): precreated here, ONCE, at 0600 — not left to
  # whatever the `2>"$staging.lnerr"` redirect inside the move loop below
  # would create it as on its first use. Under `umask 000` that redirect
  # would otherwise open the file itself (O_CREAT) at 0666, world-writable,
  # for exactly as long as it takes the loop to reach its first failing
  # `ln` — the same class of gap R9-P3-2 closed for $moved, just on a
  # different file. Precreating it here instead of inside the loop matters
  # because `>` onto a file that ALREADY EXISTS only truncates its contents,
  # never its mode or its inode, so one 0600 creation up front holds for
  # every iteration after it.
  _memory_adopt_private_tempfile "$staging.lnerr" \
    || { log_err "Couldn't stage adoption of $source"; rm -f "$moved" "$dirsfile"; rm -rf "$staging"; return 1; }
  # A signal (SIGINT/SIGTERM/SIGHUP — Ctrl-C, a killed session, a closed
  # terminal) must free $staging AND end the function with the conventional
  # 128+signal status, exactly like home.sh:2450, burn.sh:598-601 and
  # switch.sh:582-583 do. A bare `trap 'rm -rf "$staging"' … INT TERM HUP`
  # (R7-P2-1) only cleans up — bash resumes the interrupted loop right after
  # the handler returns, so the copy continues into a staging dir the trap
  # just deleted: files copied before the signal vanish silently while later
  # ones land, `ln` then fails against a half-populated (or missing) staging
  # dir and is misreported as a same-name collision, and the function still
  # reaches the DONE path with a Soul missing an unknown number of files.
  # 🔴 That fix only covered the COPY loop (into staging). The MOVE loop
  # further down (`ln` from staging into $store) had no rollback at all: a
  # signal landing there left every file this run had already `ln`'d into
  # $store permanently in place — real, readable markdown, not a dotfile, so
  # `_memory_store_has_content`'s dotfile-skipping glob (R6-P2-1) can't see
  # them either, and the NEXT ordinary `share` reads "store has content" and
  # silently skips seeding: green output, an unindexed, un-seeded Soul
  # (R8-P2-1). `_memory_adopt_rollback` (below) is what the trap calls now —
  # it undoes exactly the destinations recorded in $moved, never anything
  # pre-existing, then frees staging.
  # `_memory_adopt` runs in the caller's own shell (never a subshell), so
  # `exit` here ends that process, not just this function — the same process
  # a killed `clikae memory share … --adopt` invocation is. Cleared right
  # before each of the explicit cleanup calls below so a normal return never
  # double-runs it through both the trap AND the explicit call; the EXIT trap
  # firing again after `exit` is harmless (rolling back an already-empty
  # manifest, or `rm -rf`/`rm -f` on already-gone paths, are no-ops).
  trap '_memory_adopt_rollback "$moved" "$staging" "$dirsfile"' EXIT
  trap '_memory_adopt_rollback "$moved" "$staging" "$dirsfile"; exit 130' INT
  trap '_memory_adopt_rollback "$moved" "$staging" "$dirsfile"; exit 143' TERM
  trap '_memory_adopt_rollback "$moved" "$staging" "$dirsfile"; exit 129' HUP
  while IFS= read -r f; do
    rel="${f#"$sdir"/}"
    [ "$rel" = MEMORY.md ] && continue
    # A genuinely dangling symlink (target doesn't exist at all) is skipped,
    # named, and MUST NOT count toward $found below — it has nothing to
    # contribute either way, so a source that is otherwise just an inline
    # MEMORY.md plus one stale link must still end in DONE, not a refusal
    # (R3-P2-2, R5-P2-1). `-e` (not `-f`) is the right test here: it is false
    # only when the target is actually missing, unlike `-f`, which is also
    # false for a live symlink to a directory — that's a different case,
    # handled below.
    if [ -L "$f" ] && [ ! -e "$f" ]; then
      log_warn "Skipping dangling symlink $rel in $source."
      continue
    fi
    found=$((found+1))
    # A symlink to a directory IS live (its target exists) but `find` never
    # descends into an operand that is itself a symlink, so nothing under it
    # was ever visited or copied. Unlike a dangling link, this one WAS
    # supposed to contribute content the index likely references — count it
    # toward $found so the all-skipped refusal below can fire for it.
    if [ -L "$f" ] && [ -d "$f" ]; then
      log_warn "Skipping symlinked directory $rel in $source; its contents were not adopted."
      continue
    fi
    mkdir -p "$staging/$(dirname "$rel")" 2>/dev/null \
      || { trap - EXIT INT TERM HUP; rm -rf "$staging"; rm -f "$moved" "$dirsfile" "$staging.lnerr"; return 1; }
    # `-p` PRESERVES the source's permission bits (e.g. a private 0600 memory
    # file some other user on the machine can't read) instead of falling back
    # to umask, which is what a plain `cat "$f" > dest` would do.
    if ! cp -p "$f" "$staging/$rel" 2>/dev/null; then
      trap - EXIT INT TERM HUP
      rm -rf "$staging"
      rm -f "$moved" "$dirsfile" "$staging.lnerr"
      return 1
    fi
    copied=$((copied+1))
  done < <(find "$sdir" \( -type f -o -type l \) 2>/dev/null)

  # A source that genuinely holds nothing but its own MEMORY.md, or nothing
  # but dangling links ($found == 0), is a legitimate empty adopt and still
  # ends in DONE below. But $found > 0 with $copied == 0 means every entry
  # that WAS live got skipped (e.g. a symlinked subdirectory this loop
  # doesn't recurse into) — the index is about to merge pointing at files
  # that never landed. Refuse instead of printing a green DONE over an adopt
  # that copied nothing. Dangling links never reach $found (see above), so
  # one stale link alongside real content never trips this.
  if [ "$found" -gt 0 ] && [ "$copied" -eq 0 ]; then
    trap - EXIT INT TERM HUP
    rm -rf "$staging"
    rm -f "$moved" "$dirsfile" "$staging.lnerr"
    log_err "Adoption of $source copied 0 of $found file(s) found under it — nothing to merge."
    return 1
  fi

  # The whole copy succeeded — move each staged file into place.
  local move_failed=0 ln_err=""
  while IFS= read -r rel; do
    dest="$store/$rel"
    destdir="$(dirname "$dest")"
    # Record into $dirsfile, BEFORE `mkdir -p` runs, every ancestor of
    # $destdir that does not exist yet at all (R10-P2-1) — same discipline
    # as $moved below: walk upward from $destdir, and for each level nothing
    # sits at (no file, no directory, no symlink — `mkdir -p` only ever
    # CREATES a level where NOTHING is there), append it, then keep walking
    # up. The walk stops the moment it reaches a level that already exists
    # in any form: if that's a real directory, everything above it is
    # already there too (mkdir -p wouldn't touch it); if it's some OTHER
    # kind of entry blocking the way (R9-P3-3's ENOTDIR shape — a file
    # sitting where a directory needs to be), `mkdir -p` creates nothing at
    # all for this $rel, so nothing here should be recorded as created
    # either, and rollback's `rmdir` on a non-directory is a silent no-op
    # regardless. Recording BEFORE the mkdir -p (not after) means a signal
    # landing mid-syscall still leaves a record — over-recording a directory
    # `mkdir -p` never got to finish creating costs nothing: `rmdir` on
    # something that doesn't exist just fails quietly.
    newdir="$destdir"
    while [ ! -e "$newdir" ] && [ ! -L "$newdir" ]; do
      printf '%s\n' "$newdir" >> "$dirsfile"
      newdir="$(dirname "$newdir")"
    done
    mkdir -p "$destdir" 2>/dev/null
    # `-e` alone is false for a DANGLING symlink at $dest (its own target
    # missing) even though a real directory entry sits there — `-L` catches
    # that case the same way _memory_store_has_content above already does.
    #
    # Checked, and recorded into $moved, BEFORE `ln` runs (R9-P2-1). `ln` is
    # an external command, and bash defers a pending signal's trap until the
    # foreground command it's running actually exits — so a TERM/INT/HUP
    # landing WHILE `ln` itself is executing used to fall in the gap between
    # "file created on disk" and "line appended to $moved" (that `printf` used
    # to run only after `ln` succeeded), leaving a real, readable file behind
    # that the trap's rollback had no record of and so could never remove.
    # `_memory_store_has_content`'s dotfile-skipping glob can't see it either
    # (R6-P2-1) — the next ordinary `share` reads "store has content" and
    # silently skips seeding, exactly R8-P2-1's symptom, just for one file
    # instead of every remaining one.
    #
    # Recording the destination FIRST — but only once this guard has
    # confirmed nothing is there yet — closes that gap: the manifest can
    # never list a file that pre-existed (the guard already sent that case to
    # "Keeping existing" and skipped it), and a signal landing anywhere
    # around `ln` — before it runs, mid-syscall, or after — is always
    # covered. If `ln` never got as far as creating $dest, the rollback's
    # `rm -f` on that path is simply a no-op. (A TOCTOU where some OTHER
    # process creates $dest between this check and the `ln` below remains in
    # principle, but it's a far narrower window than the one this closes.)
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      log_warn "Keeping existing $rel; source copy remains in $source."
      continue
    fi
    printf '%s\n' "$dest" >> "$moved"
    # `ln` (not `mv`) so the no-overwrite contract stays atomic; the guard
    # above already handles the ordinary "$dest exists" case, so any failure
    # reaching here is something else entirely — most commonly EXDEV
    # ($staging and $store on different filesystems, e.g. $store is a
    # symlink to another volume), but not always (R9-P3-3: an ENOTDIR from a
    # store entry blocking a later path is a different failure that used to
    # be misreported with the same "different filesystems" wording). `ln`'s
    # stderr is captured to a plain FILE redirect, not `$(ln … 2>&1)` —
    # command substitution forks an extra subshell to run `ln` in, which
    # would sit BETWEEN this process and `ln` for as long as it's running,
    # and `pkill -P` (what a caller unblocking a stuck `wait` reaches for)
    # only walks one level of children, not grandchildren. Read back and
    # discarded immediately below, only once `ln` has already returned.
    if ln "$staging/$rel" "$dest" 2>"$staging.lnerr"; then
      linked=$((linked+1))
    else
      ln_err="$(cat "$staging.lnerr" 2>/dev/null)"
      rm -f "$staging.lnerr" 2>/dev/null
      move_failed=1
      break
    fi
  done < <(cd "$staging" && find . -type f 2>/dev/null | sed 's#^\./##')
  rm -f "$staging.lnerr" 2>/dev/null
  if [ "$move_failed" -eq 1 ]; then
    trap - EXIT INT TERM HUP
    # $linked is exactly how many destinations THIS run already `ln`'d before
    # the failing one — _memory_adopt_rollback undoes precisely those (never
    # anything pre-existing), so "Nothing was adopted" below is true again
    # instead of the false claim R8-P3-1 found (some files landed, uncounted,
    # unindexed, while the message said none did).
    local rolled_back=$linked reason
    _memory_adopt_rollback "$moved" "$staging" "$dirsfile"
    # Only actual EXDEV ("Cross-device link" — the wording both BSD and GNU
    # `ln` use for it) is reported as a filesystem mismatch; any other error
    # (ENOTDIR, EACCES, …) says only that the move failed, quoting `ln`'s own
    # message instead of asserting a cause that wasn't what happened.
    case "$ln_err" in
      *"Cross-device link"*)
        reason="are they on different filesystems (e.g. $store is a symlink to another volume)?"
        ;;
      *)
        reason="could not move them ($ln_err)."
        ;;
    esac
    if [ "$rolled_back" -gt 0 ]; then
      log_err "Couldn't move staged files from $staging into $store — $reason Rolled back $rolled_back already-moved file(s); nothing was adopted."
    else
      log_err "Couldn't move staged files from $staging into $store — $reason Nothing was adopted."
    fi
    return 1
  fi
  trap - EXIT INT TERM HUP
  rm -rf "$staging"
  # $dirsfile isn't rolled back here — every destination inside those
  # directories just landed for real, so they're non-empty and rmdir would
  # be a no-op anyway — but the manifest itself is bookkeeping, not content,
  # and must not survive as a stray dotfile next to a successful adopt.
  rm -f "$moved" "$dirsfile"

  heading="## Adopted from $source"
  if ! _memory_adopted_heading_exists "$store/MEMORY.md" "$source"; then
    { printf '\n%s\n\n' "$heading"; cat "$source/MEMORY.md" || return 1; printf '\n'; } >> "$store/MEMORY.md" || return 1
    # The index is the part of a memory best worth reading — force 0600 on
    # every merge, the same guarantee the topic files above get from `cp -p`.
    # Without this, a MEMORY.md written fresh by the `>>` above lands at
    # process umask instead of staying private.
    chmod 600 "$store/MEMORY.md" 2>/dev/null || true
  fi

  # Report any index entry that still doesn't resolve inside the store — a
  # relative link the copy above didn't reach (an absolute path, one escaping
  # $source, or one already dangling in the source itself). Adoption must
  # never say DONE while a link silently points at nothing.
  while IFS= read -r line; do
    case "$line" in
      \[*\]\(*\))
        target="${line##*\(}"; target="${target%\)}"
        case "$target" in http://*|https://*|mailto:*|/*) continue ;; esac
        [ -e "$store/$target" ] || broken=$((broken+1))
        ;;
    esac
  done < "$source/MEMORY.md"
  if [ "$broken" -gt 0 ]; then
    local noun=entries; [ "$broken" -eq 1 ] && noun=entry
    log_warn "$broken index $noun in $source didn't resolve after adopting — check $source/MEMORY.md."
  fi

  log_done "Adopted memory by COPY from $source (originals untouched)."
}

# Does $store/MEMORY.md already carry an "## Adopted from <source>" heading for
# THIS source — comparing by canonical directory, not literal text? A literal
# `grep -Fqx` treated "…/memory" and "…/memory/" (what shell tab-completion
# appends) as two different sources, so re-running --adopt with a trailing
# slash re-merged the same source's index into a fresh duplicate section every
# time, even though the per-file no-overwrite check above already skipped every
# file in it as a collision.
_memory_adopted_heading_exists() {
  local file="$1" source="$2" line p
  [ -f "$file" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "## Adopted from "*)
        p="${line#"## Adopted from "}"
        { [ "$p" = "$source" ] || _memory_same_dir "$p" "$source"; } && return 0
        ;;
    esac
  done < "$file"
  return 1
}

_memory_offer_adoption() {
  local store="$1" group="$2" explicit="$3" seeded="$4" source count label command_line adopt_path
  for source in "$HOME"/.claude/projects/*/memory "$MEM_CFG"/projects/*/memory; do
    [ -d "$source" ] && [ ! -L "$source" ] && [ -f "$source/MEMORY.md" ] && [ ! -L "$source/MEMORY.md" ] || continue
    # Canonical, not literal: an explicit --adopt path with a trailing slash
    # (shell tab-completion) must still be recognised as this same source, or
    # this loop offers to adopt it AGAIN while _memory_adopt (called separately,
    # below, for the explicit path) already just adopted it — printing "was NOT
    # imported" and "Adopted … (originals untouched)" for the same directory in
    # the same run.
    { [ -z "$explicit" ] || ! _memory_same_dir "$source" "$explicit"; } || continue
    count="$(_memory_adopt_count "$source")"
    log_info "Found memory: $source ($count files)"
    # Preserve the existing automatic seed of this tank's current directory.
    if [ "$source" = "$MEM_DIR" ] && [ "$seeded" -eq 1 ]; then
      log_dim "This tank's current memory was seeded by COPY."
      continue
    fi
    # Both ends, not just stdin: init.sh and solo.sh self-invoke `memory share`
    # as `"$CLIKAE_BIN" memory share … >/dev/null 2>&1` — stdout+stderr go to
    # /dev/null but stdin is left alone, so on a real terminal `[ -t 0 ]` alone
    # was still true and `confirm` blocked on a `read` whose prompt had just
    # been discarded: a black screen, forever. `[ -t 1 ]` is false the instant
    # a caller redirects stdout, which is exactly the signal that this run
    # isn't a human sitting in front of it, whoever set that redirection.
    if [ -t 0 ] && [ -t 1 ] && confirm "Adopt $source ($count files)?"; then
      _memory_adopt "$source" "$store" || log_fail "Memory adoption failed: $source"
    else
      label="tank memory"
      case "$source" in "$HOME"/.claude/*) label='your ~/.claude memory' ;; esac
      adopt_path="$source"
      # share stashes this tank's own slots below. The recovery command must
      # name that preserved directory, not the soon-to-be shared symlink.
      case "$source" in "$MEM_CFG"/projects/*/memory)
        adopt_path="$source.clikae-soul-stash"
        [ ! -e "$adopt_path" ] || adopt_path="$adopt_path.$$" ;;
      esac
      printf -v command_line 'clikae memory share %q %q %q --adopt %q' "$group" "$MEM_CLI" "$MEM_TANK" "$adopt_path"
      log_warn "$label ($count files) was NOT imported; run $command_line to adopt"
    fi
  done
}

# Does $store hold any REAL content — as opposed to merely being non-empty?
# `ls -A` (what the seed gate below used to test directly) counts dotfiles,
# and a leftover `.adopt.*` staging directory from an interrupted --adopt is
# exactly that: a dotdir with no memory in it (R6-P2-1). A bare glob (`*`)
# already skips every dotfile/dot-directory by shell convention — the fix here
# IS the difference between `ls -A` and this loop, not extra filtering logic.
#
# A plain (non-symlink) directory is a SECOND way to satisfy `[ -e "$f" ]`
# without holding any memory (R10-P2-1): the move loop's own `mkdir -p`
# creates the destination directory before it creates any file inside it,
# and before this fix nothing recorded or ever freed what it created — a
# source with even one subdirectory left an empty directory behind after a
# signal or a move_failed, and it satisfied `[ -e "$f" ]` exactly like a
# real file would. The move loop's own manifest-and-`rmdir` rollback (added
# alongside this) now closes that for a CURRENT build, but this gate is
# hardened independently too — belt AND suspenders, the same shape as
# R6-P2-1 above: residue from an OLDER build that never recorded directories
# at all can't fool it either. A directory only counts here if `find` turns
# up an actual regular file or symlink somewhere underneath it; a symlink AT
# THIS LEVEL is never recursed into (dangling or not, it already counts on
# its own, same as before) — only a real, non-symlink directory gets the
# recursive check.
_memory_store_has_content() {
  local store="$1" f
  for f in "$store"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if [ -d "$f" ] && [ ! -L "$f" ]; then
      find "$f" \( -type f -o -type l \) -print -quit 2>/dev/null | grep -q . || continue
    fi
    return 0
  done
  return 1
}

# Self-heal residue from an OLDER clikae (before this fix, staging lived
# INSIDE the store) or from a signal this build's own trap somehow missed
# (e.g. a SIGKILL, which no trap can catch): any `.adopt.*` left for more
# than a day is dead — a real adopt stages and moves in well under a second
# even off a slow/iCloud source (the only way one survives this long is that
# whatever created it is gone). Named out loud rather than swept silently, so
# a maintainer who goes looking for "why did my adopt vanish" finds the
# answer in the log instead of nothing. The age floor also means a staging
# directory an adopt IN PROGRESS right now is never at risk of being pulled
# out from under it.
#
# Swept in TWO locations: `$store/.adopt.*` (where an older clikae build
# staged, before this fix moved staging out of the store) and
# `$(dirname "$store")/.adopt.*` — the CURRENT build's own location (see
# _memory_adopt). Sweeping only the old location would leave every fresh
# build's own signal-missed residue to accumulate in the new one forever,
# even though nothing else in `souls/<group>/` ever globs that directory
# (only `members` lives there beside `memory`), so it never fools the seed
# gate — just clutter the CHANGELOG already promises this sweeps away.
_memory_sweep_stale_adopt_staging() {
  local store="$1" d
  for d in "$store"/.adopt.* "$(dirname "$store")"/.adopt.*; do
    [ -d "$d" ] || continue
    [ -n "$(find "$d" -maxdepth 0 -mmin +1440 2>/dev/null)" ] || continue
    log_warn "Sweeping stale adopt staging left behind at $d."
    rm -rf "$d"
  done
}

_memory_share() {
  local group="" engine="" tank="" yes=0 adopt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --adopt)
        [ $# -ge 2 ] && [ -n "$2" ] || log_fail "--adopt requires a memory directory"
        [ -z "$adopt" ] || log_fail "Use one --adopt source per invocation"
        adopt="$2"; shift 2 ;;
      -y|--yes) yes=1; shift ;;
      -*) log_fail "memory share: unknown flag: $1" ;;
      *) if [ -z "$group" ]; then group="$1"
         elif [ -z "$engine" ]; then engine="$1"
         elif [ -z "$tank" ]; then tank="$1"
         else log_fail "memory share: unexpected argument: $1"; fi
         shift ;;
    esac
  done
  [ -n "$group" ] || log_fail "memory share: name a group:  clikae memory share <group>"
  validate_name profile "$group"   # exits with a clear message on a bad name
  _memory_resolve_tank "$engine" "$tank"

  # 🔴 A SOLO tank is deliberately out of the fleet (e.g. a bot/persona tank on your
  # own account that the cross-account guard can't protect). Refuse, loudly.
  if tank_is_solo "$MEM_CLI" "$MEM_TANK"; then
    log_err "$MEM_CLI/$MEM_TANK is SOLO (standalone, out of the fleet) — refusing to share it."
    local _r; _r="$(head -n1 "$(solo_marker_file "$MEM_CLI" "$MEM_TANK")" 2>/dev/null || true)"
    [ -n "$_r" ] && log_dim "reason: $_r"
    log_fail "If you really mean it: clikae solo $MEM_CLI $MEM_TANK --off"
  fi

  if [ -n "$adopt" ]; then
    [ "$MEM_CLI" = claude ] || log_fail "--adopt is supported for claude tanks only"
    [ -d "$adopt" ] && [ -f "$adopt/MEMORY.md" ] && [ ! -L "$adopt/MEMORY.md" ] \
      || log_fail "--adopt requires a directory with a regular MEMORY.md"
    # Keep the path as the user typed it (an absolute, existing directory) — the heading in
    # MEMORY.md is "## Adopted from <path>", and a user who typed /var/... must find it
    # under that name, not under macOS's /private/var/... alias. Sameness against the store
    # is still checked with pwd -P below (memory_adopt), so an aliased self-adopt is refused.
    case "$adopt" in /*) ;; *) adopt="$PWD/$adopt" ;; esac
  fi

  local store account members existing_group
  store="$(_memory_store_path "$group")"
  account="$(_memory_account)"

  existing_group="$(_memory_current_group)"
  if [ "$existing_group" = "$group" ]; then
    # Membership already granted — just make sure THIS directory's slot is
    # projected too (the same lazy repair soul_prelaunch does at launch).
    # Re-sharing an already-shared tank is a normal path (not just the
    # first-share block further below) — sweep here too, or residue this
    # build's own signal handling somehow missed sits until a DIFFERENT tank
    # happens to take the first-share branch (R8-P3-2).
    _memory_sweep_stale_adopt_staging "$store"
    if [ "$MEM_STRATEGY" = "symlink" ] && [ "$(readlink "$MEM_DIR" 2>/dev/null || true)" != "$store" ]; then
      soul_prelaunch "$MEM_CLI" "$MEM_TANK" "$MEM_CFG"
    fi
    if [ -n "$adopt" ]; then
      _memory_adopt "$adopt" "$store" || log_fail "Memory adoption failed: $adopt"
    fi
    log_pass "$MEM_CLI/$MEM_TANK already shares '$group'."
    return 0
  fi
  # One brain per tank: moving to another group leaves the old one's roster.
  if [ -n "$existing_group" ]; then
    _memory_drop_member "$(_memory_members_file "$existing_group")" "$MEM_CLI/$MEM_TANK"
    log_dim "leaving group '$existing_group' (a tank shares at most one Soul)."
  fi

  # Informed consent: if the store already holds another of YOUR accounts, say so
  # before commingling them into one brain. opt-in, never silent.
  members="$(_memory_members_file "$group")"
  if [ -e "$store" ] && [ -n "$account" ] && [ -f "$members" ]; then
    local others
    others="$(awk -F'\t' -v a="$account" 'NF>=2 && $2!="" && $2!=a {print $2}' "$members" | sort -u || true)"
    if [ -n "$others" ]; then
      log_warn "Group '$group' already shares memory across these accounts:"
      printf '%s\n' "$others" | while IFS= read -r o; do [ -n "$o" ] && log_dim "    $o"; done
      log_warn "Joining $MEM_CLI/$MEM_TANK ($account) merges it into the SAME shared brain."
      if [ "$yes" -ne 1 ]; then
        # Same fix as the adoption prompt above, and the same reason: init.sh
        # and solo.sh self-invoke this command with stdout+stderr routed to
        # /dev/null, and a bare `[ -t 0 ]` can't tell that apart from a human
        # at a real prompt.
        if [ -t 0 ] && [ -t 1 ]; then
          confirm "Share across these accounts?" || log_fail "Aborted — memory not shared."
        else
          log_fail "Refusing to cross accounts non-interactively. Re-run with --yes if intended."
        fi
      fi
    fi
  fi

  mkdir -p "$store"
  # Preserve current-directory seeding before additional sources fill the store.
  local seeded=0
  if [ "$MEM_STRATEGY" = symlink ] && [ -d "$MEM_DIR" ] && [ ! -L "$MEM_DIR" ]; then
    # Self-heal BEFORE asking the gate — see _memory_sweep_stale_adopt_staging
    # — so pre-fix residue does not even need a second `share` to clear out.
    _memory_sweep_stale_adopt_staging "$store"
    if ! _memory_store_has_content "$store"; then
      _memory_seed_dir "$MEM_DIR" "$store"
      seeded=1
    fi
  fi
  if [ "$MEM_CLI" = claude ]; then
    if [ -z "$existing_group" ]; then
      _memory_offer_adoption "$store" "$group" "$adopt" "$seeded"
    fi
    if [ -n "$adopt" ]; then
      _memory_adopt "$adopt" "$store" || log_fail "Memory adoption failed: $adopt"
    fi
  fi

  if [ "$MEM_STRATEGY" = "symlink" ]; then
    # Self-heal a half-done prior run, then stash the tank's own memory (reversible)
    # and fan in to the shared store. Mirrors _switch_run_ephemeral's stash/restore.
    local stash="$MEM_DIR.clikae-soul-stash"
    [ -L "$MEM_DIR" ] && rm -f "$MEM_DIR"
    if [ -e "$MEM_DIR" ] && [ ! -L "$MEM_DIR" ]; then
      # A pre-existing stash is a prior share's own-memory — NEVER `rm -rf` it (the
      # "reversible, never lost" contract). Give the new one a unique suffix, the
      # same as the per-project loop below and soul_prelaunch's stash.
      [ -e "$stash" ] && stash="$stash.$$"
      mv "$MEM_DIR" "$stash"
    fi
    mkdir -p "$(dirname "$MEM_DIR")"
    ln -s "$store" "$MEM_DIR"
    # Project the WHOLE tank, not just $PWD: fan in EVERY project directory of
    # this tank, creating the slot when it isn't there (own memory stashed
    # alongside, reversible). Membership is per-tank, so one consented `share`
    # covers them all.
    #
    # 🔴 This used to iterate `projects/*/memory` and skip any slot that didn't
    # already exist, leaving those to soul_prelaunch's lazy link at the next
    # launch — which made `isolate` → `share` a MEMORY-LOSING round trip.
    # isolate rm's every slot; a directory whose memory was a pure symlink (no
    # own-memory stash to restore) came back as NOTHING, so the re-share found
    # no slot there and silently skipped it. `memory status` reads the
    # membership file, so it went on reporting "shared" while the tank's memory
    # was gone from disk — and a session ALREADY RUNNING in that directory never
    # gets a relaunch, so never gets the lazy link: it just goes amnesiac
    # mid-flight. That is what happened to tank `l` on 2026-07-12 — a session
    # isolated it to spawn a cold-read agent, re-shared it 20 minutes later, and
    # the Soul never came back. Linking every project dir eagerly reaches the
    # same end state soul_prelaunch would, with no window where the membership
    # file and the disk disagree.
    local pdir slot sstash fanned=0
    for pdir in "$MEM_CFG"/projects/*/; do
      [ -d "$pdir" ] || continue
      slot="${pdir}memory"
      [ "$slot" = "$MEM_DIR" ] && continue
      if [ -L "$slot" ]; then
        [ "$(readlink "$slot" 2>/dev/null || true)" = "$store" ] && continue
        rm -f "$slot"
      elif [ -e "$slot" ]; then
        # The directory keeps its OWN memory: stash it alongside, never destroy
        # it — `isolate` moves it back.
        sstash="$slot.clikae-soul-stash"
        [ -e "$sstash" ] && sstash="$sstash.$$"
        mv "$slot" "$sstash"
      fi
      # No slot at all (a fresh dir, or one isolate emptied): just link it.
      ln -s "$store" "$slot" && fanned=$((fanned+1))
    done
    [ "$fanned" -gt 0 ] && log_dim "also fanned in $fanned other project-directory slot(s) of this tank."
  else
    # Pointer strategy: drop a note in the engine's instructions file. We do NOT
    # seed from the engine's own (opaque) memory — it adopts the shared markdown,
    # ideally already seeded by a claude share. An empty store is fine (it grows).
    _memory_ptr_write "$MEM_PTR" "$group" "$store"
  fi

  # Seed the Soul's read/write-back manual (after any symlink seed, so the empty-
  # store check above still copies the tank's real memory). Idempotent.
  _memory_seed_protocol "$store"

  # Record membership (dedup by engine/tank).
  mkdir -p "$(dirname "$members")"
  local key="$MEM_CLI/$MEM_TANK"
  _memory_drop_member "$members" "$key"
  printf '%s\t%s\t%s\n' "$key" "$account" "$store" >> "$members"

  # The FIRST share on this machine is the consent moment for the whole fleet:
  # from here on a new tank joins this group at `clikae init` unless it is solo.
  # Saying yes once is consent; being asked for every tank you ever create is a
  # chore, and the board can't show the difference anyway.
  if [ -z "$(soul_default_group)" ]; then
    soul_default_set "$group"
    log_dim "'$group' is now this machine's default: new tanks join it automatically (a solo tank never does)."
  fi

  log_done "$MEM_CLI/$MEM_TANK now shares memory group '$group'."
  log_dim "store: $store"
  if [ "$MEM_STRATEGY" = "symlink" ]; then
    [ -d "$MEM_DIR.clikae-soul-stash" ] && log_dim "its previous own memory is stashed (reversible): clikae solo $MEM_CLI $MEM_TANK"
  else
    log_dim "pointer written to $MEM_PTR — $MEM_CLI reads the shared Soul from there."
  fi
  log_dim "Soul carries continuity & context across tanks/engines — not the model's capability."
  return 0
}

_memory_isolate() {
  local engine="" tank=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -*) log_fail "memory isolate: unknown flag: $1" ;;
      *) if [ -z "$engine" ]; then engine="$1"
         elif [ -z "$tank" ]; then tank="$1"
         else log_fail "memory isolate: unexpected argument: $1"; fi
         shift ;;
    esac
  done
  _memory_resolve_tank "$engine" "$tank"

  local group members
  group="$(_memory_current_group)"
  if [ -z "$group" ]; then
    log_pass "$MEM_CLI/$MEM_TANK already has its own (isolated) memory."
    return 0
  fi

  if [ "$MEM_STRATEGY" = "symlink" ]; then
    # Drop the symlinks — ALL of them: one share may have projected into many
    # project directories (share fans in eagerly, soul_prelaunch lazily). The
    # shared store is left untouched (aggregate, never mutate). Each slot's
    # stashed own memory is restored where one exists.
    local store slot stash unlinked=0
    store="$(_memory_store_path "$group")"
    while IFS= read -r slot; do
      [ -n "$slot" ] || continue
      rm -f "$slot"; unlinked=$((unlinked+1))
      stash="$slot.clikae-soul-stash"
      [ -d "$stash" ] && mv "$stash" "$slot"
    done < <(_memory_all_linked_slots "$store")
    # $PWD's slot may predate membership records or point at an odd path — make
    # sure the resolved dir is covered even if the walk missed it.
    if [ -L "$MEM_DIR" ]; then
      rm -f "$MEM_DIR"
      [ -d "$MEM_DIR.clikae-soul-stash" ] && mv "$MEM_DIR.clikae-soul-stash" "$MEM_DIR"
    fi
    log_done "$MEM_CLI/$MEM_TANK is back on its own memory (left group '$group', $unlinked slot(s) unlinked)."
    [ -d "$MEM_DIR" ] || log_dim "(this directory had no stashed memory; the engine will create a fresh one.)"
  else
    # Pointer strategy: remove only our note (the store is untouched).
    _memory_ptr_strip "$MEM_PTR" "$group"
    log_done "$MEM_CLI/$MEM_TANK no longer points at group '$group' (its own memory is unchanged)."
  fi

  members="$(_memory_members_file "$group")"
  _memory_drop_member "$members" "$MEM_CLI/$MEM_TANK"
  return 0
}

_memory_status() {
  local engine="" tank="" as_json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      # An agent must read this before dispatching — clikae's own doctrine is
      # "check `memory status` first; a solo tank is not in the pool". Making
      # that answer prose-only left the one query the rules mandate as the one a
      # script had to parse by eye. `list` and `info` already emit --json.
      --json) as_json=1; shift ;;
      -*) log_fail "memory status: unknown flag: $1" ;;
      *) if [ -z "$engine" ]; then engine="$1"
         elif [ -z "$tank" ]; then tank="$1"
         else log_fail "memory status: unexpected argument: $1"; fi
         shift ;;
    esac
  done
  # Survey with no tank: walk every tank of the engine (default claude).
  if [ -z "$tank" ]; then
    local eng="${engine:-claude}" canon strat="symlink"
    canon="$eng"; [ "$canon" = "agy" ] && canon="antigravity"
    if clikae_is_target "$eng"; then
      # shellcheck source=/dev/null
      source "$CLIKAE_LIB/targets/$canon.sh" 2>/dev/null || log_fail "memory: can't load target '$eng'."
      declare -F target_memory_pointer_path >/dev/null 2>&1 \
        || log_fail "memory: cross-engine Soul for '$eng' isn't supported yet."
      strat="pointer"
    else
      load_adapter "$eng" >/dev/null 2>&1 || log_fail "memory: no adapter for '$eng'."
      declare -F adapter_memory_dir >/dev/null 2>&1 || strat="pointer"
      declare -F adapter_memory_pointer_path >/dev/null 2>&1 || [ "$strat" = "symlink" ] || log_fail "memory: '$eng' unsupported."
    fi
    local saw=0 stale="" first=1
    [ "$as_json" -eq 1 ] && printf '[' || log_info "memory sharing ($eng):"
    while IFS=$'\t' read -r cli tname _; do
      [ "$cli" = "$canon" ] || continue
      saw=1
      MEM_CLI="$cli"; MEM_TANK="$tname"; MEM_STRATEGY="$strat"
      MEM_CFG="$(profile_dir "$cli" "$tname")"
      MEM_DIR=""; MEM_PTR=""
      if [ "$strat" = "symlink" ]; then MEM_DIR="$(adapter_memory_dir "$MEM_CFG")"
      elif clikae_is_target "$eng"; then MEM_PTR="$(target_memory_pointer_path "$MEM_CFG")"
      else MEM_PTR="$(adapter_memory_pointer_path "$MEM_CFG")"; fi
      local g acct lk here; g="$(_memory_current_group)"; acct="$(_memory_account)"
      # solo means out of the shared brain — the two are one statement. A tank
      # that is solo AND in a group is a state the model says can't exist: it
      # was made solo before the verbs were wired together, or its isolate
      # failed. Badge it as broken rather than printing both facts flatly and
      # letting the reader take the 🔒 for the answer.
      lk=""
      if tank_is_solo "$cli" "$tname"; then
        if [ -n "$g" ]; then lk="  solo BUT STILL SHARING"; stale="${stale:+$stale }$cli/$tname"
        else lk="  solo"; fi
      fi
      # Sharing is tank-level; note when THIS directory's slot isn't projected
      # yet (it links on the tank's next launch here — soul_prelaunch).
      here=""
      if [ -n "$g" ] && [ "$strat" = "symlink" ] \
         && [ "$(readlink "$MEM_DIR" 2>/dev/null || true)" != "$(_memory_store_path "$g")" ]; then
        here="  (this dir: links on next launch)"
      fi
        if [ "$as_json" -eq 1 ]; then
          # `dispatchable` is the question the doctrine actually asks, answered
          # once here rather than re-derived by every caller: a solo tank is out
          # of the pool, and so is one in the impossible solo-and-shared state —
          # its wiring does not match its label, so it is not safe to reason about.
          local _solo=false _incon=false _disp=true
          tank_is_solo "$cli" "$tname" && { _solo=true; _disp=false; }
          [ "$_solo" = true ] && [ -n "$g" ] && _incon=true
          [ "$first" -eq 1 ] || printf ','
          first=0
          printf '{"cli":%s,"tank":%s,"group":%s,"account":%s,"solo":%s,"inconsistent":%s,"dispatchable":%s}' \
            "$(json_str "$cli")" "$(json_str "$tname")" "$(json_or_null "$g")" \
            "$(json_or_null "$acct")" "$_solo" "$_incon" "$_disp"
        elif [ -n "$g" ]; then log_done "  $cli/$tname  → shared '$g'${acct:+  ($acct)}$lk$here"
      else log_dim "  $cli/$tname  → isolated${acct:+  ($acct)}$lk"; fi
    done < <(list_all_profiles)
    if [ "$as_json" -eq 1 ]; then printf ']\n'; return 0; fi
    [ "$saw" -eq 1 ] || log_dim "  (no $eng tanks)"
    if [ -n "$stale" ]; then
      log_warn "solo tanks still on the shared brain: $stale"
      log_dim "  re-run \`clikae solo <engine> <tank>\` on each — it leaves the group for real."
    fi
    return 0
  fi
  # One named tank.
  _memory_resolve_tank "$engine" "$tank"
  local g acct lk; g="$(_memory_current_group)"; acct="$(_memory_account)"
  lk=""
  if tank_is_solo "$MEM_CLI" "$MEM_TANK"; then
    if [ -n "$g" ]; then lk="  solo BUT STILL SHARING"; else lk="  solo"; fi
  fi
  if [ -n "$g" ]; then
    log_done "$MEM_CLI/$MEM_TANK → shared '$g'${acct:+  ($acct)}$lk"
    if tank_is_solo "$MEM_CLI" "$MEM_TANK"; then
      log_warn "solo, but still in group '$g' — solo is supposed to leave it."
      log_dim "  fix: clikae solo $MEM_CLI $MEM_TANK"
    fi
    log_dim "store: $(_memory_store_path "$g")"
    if [ "$MEM_STRATEGY" = "symlink" ] \
       && [ "$(readlink "$MEM_DIR" 2>/dev/null || true)" != "$(_memory_store_path "$g")" ]; then
      log_dim "(this directory's slot links on the tank's next launch here.)"
    fi
  else
    log_dim "$MEM_CLI/$MEM_TANK → isolated${acct:+  ($acct)}$lk"
  fi
  return 0
}
