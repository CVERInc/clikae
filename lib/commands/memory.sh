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
#   • symlink strategy (claude) — the engine keeps memory in a markdown DIR
#     (adapter_memory_dir); we fan that dir into the store with a symlink. Per-$PWD,
#     mirroring claude's per-project memory. The persistent sibling of --ephemeral's
#     fan-OUT (switch.sh §10.4): same stash/restore, pointed at a kept store.
#   • pointer strategy (codex) — the engine keeps memory opaquely (sqlite) but reads
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

souls_root() { printf '%s/souls\n' "$CLIKAE_HOME"; }

# The ONE canonical Soul store for a group — flat & vendor-neutral, so claude,
# codex and agy all point at the same markdown brain (no per-engine, per-dir forks).
_memory_store_path() { printf '%s/%s/memory\n' "$(souls_root)" "$1"; }

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
- 🔴 A memory records what was TRUE WHEN WRITTEN, not necessarily now. If a file
  names a path/flag/version, verify against the real code before relying on it.
- 🔴 Some files record a past *incident* or a *correction* (e.g. a mis-attribution
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
- `metadata.accounts` = a share-group allowlist. 🔴 Account isolation is sacred:
  never copy a fact into a group it isn't allowed in.
PROTO
}

_memory_members_file() { printf '%s/%s/members\n' "$(souls_root)" "$1"; }

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

# Which group (if any) the resolved tank currently shares — by strategy.
_memory_current_group() {
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
  mv "$file.tmp" "$file" 2>/dev/null || true
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
  clikae memory isolate        [<engine> <tank>]   restore the tank's own memory (undo share)
  clikae memory status         [<engine> <tank>]   show share state

Defaults: engine = claude; tank = whichever this shell is switched to.
Engines: claude fans its memory DIR into the store (symlink, per-directory); codex
and agy read a pointer note in their AGENTS.md / GEMINI.md and read/write the same
markdown via the memory protocol.

Flags:
  -y, --yes    skip the cross-account confirmation (for scripts/automation)

🔴 Sharing is opt-in and per-tank; clikae never auto-crosses accounts. Crossing your
own accounts is announced. The store is seeded by COPY; a joiner's own memory is
stashed aside (reversible via `isolate`), never overwritten. To wall a tank off so it
can never be shared (a bot/persona tank on your own account), make it standalone with
`clikae solo` — `share` then refuses it.
EOF
      return 0 ;;
    share)   _memory_share "$@" ;;
    isolate) _memory_isolate "$@" ;;
    status)  _memory_status "$@" ;;
    *) log_fail "memory: unknown subcommand '$sub' (try: share | isolate | status)" ;;
  esac
}

_memory_share() {
  local group="" engine="" tank="" yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
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

  local store account members existing_group
  store="$(_memory_store_path "$group")"
  account="$(_memory_account)"

  existing_group="$(_memory_current_group)"
  if [ "$existing_group" = "$group" ]; then
    log_ok "$MEM_CLI/$MEM_TANK already shares '$group'."
    return 0
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
        if [ -t 0 ]; then
          confirm "Share across these accounts?" || log_fail "Aborted — memory not shared."
        else
          log_fail "Refusing to cross accounts non-interactively. Re-run with --yes if intended."
        fi
      fi
    fi
  fi

  mkdir -p "$store"

  if [ "$MEM_STRATEGY" = "symlink" ]; then
    # Seed a NEW store by COPYING this tank's existing memory outward (never move the
    # source). If the store already has content, the joiner adopts the shared brain.
    if [ -d "$MEM_DIR" ] && [ ! -L "$MEM_DIR" ]; then
      if [ -z "$(ls -A "$store" 2>/dev/null || true)" ]; then
        cp -R "$MEM_DIR"/. "$store"/ 2>/dev/null || true
      fi
    fi
    # Self-heal a half-done prior run, then stash the tank's own memory (reversible)
    # and fan in to the shared store. Mirrors _switch_run_ephemeral's stash/restore.
    local stash="$MEM_DIR.clikae-soul-stash"
    [ -L "$MEM_DIR" ] && rm -f "$MEM_DIR"
    if [ -e "$MEM_DIR" ] && [ ! -L "$MEM_DIR" ]; then
      rm -rf "$stash"; mv "$MEM_DIR" "$stash"
    fi
    mkdir -p "$(dirname "$MEM_DIR")"
    ln -s "$store" "$MEM_DIR"
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

  log_ok "$MEM_CLI/$MEM_TANK now shares memory group '$group'."
  log_dim "store: $store"
  if [ "$MEM_STRATEGY" = "symlink" ]; then
    [ -d "$MEM_DIR.clikae-soul-stash" ] && log_dim "its previous own memory is stashed (reversible): clikae memory isolate $MEM_CLI $MEM_TANK"
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
    log_ok "$MEM_CLI/$MEM_TANK already has its own (isolated) memory."
    return 0
  fi

  if [ "$MEM_STRATEGY" = "symlink" ]; then
    # Drop only the symlink — the shared store is left untouched (aggregate, never
    # mutate). Restore the tank's stashed own memory if we have it.
    local stash="$MEM_DIR.clikae-soul-stash"
    rm -f "$MEM_DIR"
    [ -d "$stash" ] && mv "$stash" "$MEM_DIR"
    log_ok "$MEM_CLI/$MEM_TANK is back on its own memory (left group '$group')."
    [ -d "$MEM_DIR" ] || log_dim "(it had no stashed memory; the engine will create a fresh one.)"
  else
    # Pointer strategy: remove only our note (the store is untouched).
    _memory_ptr_strip "$MEM_PTR" "$group"
    log_ok "$MEM_CLI/$MEM_TANK no longer points at group '$group' (its own memory is unchanged)."
  fi

  members="$(_memory_members_file "$group")"
  _memory_drop_member "$members" "$MEM_CLI/$MEM_TANK"
  return 0
}

_memory_status() {
  local engine="" tank=""
  while [ $# -gt 0 ]; do
    case "$1" in
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
    local saw=0
    [ "$strat" = "symlink" ] && log_info "memory sharing for: $PWD" || log_info "memory sharing ($eng):"
    while IFS=$'\t' read -r cli tname _; do
      [ "$cli" = "$canon" ] || continue
      saw=1
      MEM_CLI="$cli"; MEM_TANK="$tname"; MEM_STRATEGY="$strat"
      MEM_CFG="$(profile_dir "$cli" "$tname")"
      MEM_DIR=""; MEM_PTR=""
      if [ "$strat" = "symlink" ]; then MEM_DIR="$(adapter_memory_dir "$MEM_CFG")"
      elif clikae_is_target "$eng"; then MEM_PTR="$(target_memory_pointer_path "$MEM_CFG")"
      else MEM_PTR="$(adapter_memory_pointer_path "$MEM_CFG")"; fi
      local g acct lk; g="$(_memory_current_group)"; acct="$(_memory_account)"
      lk=""; tank_is_solo "$cli" "$tname" && lk="  🔒 solo"
      if [ -n "$g" ]; then log_ok "  $cli/$tname  → shared '$g'${acct:+  ($acct)}$lk"
      else log_dim "  $cli/$tname  → isolated${acct:+  ($acct)}$lk"; fi
    done < <(list_all_profiles)
    [ "$saw" -eq 1 ] || log_dim "  (no $eng tanks)"
    return 0
  fi
  # One named tank.
  _memory_resolve_tank "$engine" "$tank"
  local g acct lk; g="$(_memory_current_group)"; acct="$(_memory_account)"
  lk=""; tank_is_solo "$MEM_CLI" "$MEM_TANK" && lk="  🔒 solo"
  if [ -n "$g" ]; then
    log_ok "$MEM_CLI/$MEM_TANK → shared '$g'${acct:+  ($acct)}$lk"
    log_dim "store: $(_memory_store_path "$g")"
  else
    log_dim "$MEM_CLI/$MEM_TANK → isolated${acct:+  ($acct)}$lk"
  fi
  return 0
}
