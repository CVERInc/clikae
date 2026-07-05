# shellcheck shell=bash
# lib/core/session_carry.sh — copy an arbitrary PAST session (by id) from one
# tank into another, per-engine. Lives in core (not resume.sh or home.sh)
# specifically to avoid a circular source: resume.sh already sources home.sh
# (for its interactive picker helpers), so home.sh sourcing resume.sh back for
# this one function would recurse infinitely.
#
# Shared by `clikae resume`'s own cross-tank picker (_resume_pick in
# lib/commands/resume.sh) and the home board's "Carry this session to another
# tank" action (_home_carry_action / _home_resume_action in
# lib/commands/home.sh) — one copy of the per-engine copy logic instead of two.
#
# Deliberately separate from `clikae relay`/`adapter_relay`: relay's contract is
# "carry the CURRENT live session" (claude-only hook, auto-detects the newest
# transcript); this is "copy a specific session someone already picked from the
# resume list, for any engine resume.sh knows how to resume" — antigravity and
# codex included, neither of which define adapter_relay.

# _resume_carry_session <engine> <from_tank> <to_tank> <sid> — never touches the
# source tank; a no-op (nothing found) is not an error — the caller's own
# resume/launch path will just find nothing under the new tank and handle it.
_resume_carry_session() {
  local engine="$1" from_tank="$2" to_tank="$3" sid="$4"
  local src_d d; src_d="$(profile_dir "$engine" "$from_tank")"; d="$(profile_dir "$engine" "$to_tank")"
  if [ "$engine" = "antigravity" ]; then
    local src_brain="$src_d/antigravity-cli/brain/$sid"
    local tgt_brain="$d/antigravity-cli/brain/$sid"
    if [ -d "$src_brain" ]; then
      mkdir -p "$(dirname "$tgt_brain")"
      cp -R "$src_brain" "$tgt_brain"
    fi
    local src_db="$src_d/antigravity-cli/conversations/$sid.db"
    local tgt_db="$d/antigravity-cli/conversations/$sid.db"
    if [ -f "$src_db" ]; then
      mkdir -p "$(dirname "$tgt_db")"
      cp "$src_db"* "$(dirname "$tgt_db")/" 2>/dev/null || true
    fi
    history_log "resume: copied antigravity session $sid from $from_tank to $to_tank"
  else
    # load_adapter is NOT guaranteed to already be loaded (for the right engine)
    # here — most callers only ever load_adapter inside a `$(...)` subshell for
    # their own board-rendering pass, which doesn't persist function definitions
    # back to this process. It clears + redefines the adapter_* hooks every call
    # (adapter_loader.sh's own contract), so calling it unconditionally is safe
    # even if a DIFFERENT engine's adapter happens to already be loaded.
    load_adapter "$engine"
    local found; found="$(adapter_find_session "$src_d" "$sid" 2>/dev/null || true)"
    if [ -n "$found" ]; then
      if [ "$engine" = "codex" ]; then
        local rel_path; rel_path="${found#*/sessions/}"
        local tgt_file="$d/sessions/$rel_path"
        mkdir -p "$(dirname "$tgt_file")"
        cp "$found" "$tgt_file"
      else
        local slug; slug="$(basename "$(dirname "$found")")"
        local tgt_proj="$d/projects/$slug"
        mkdir -p "$tgt_proj"
        cp "$found" "$tgt_proj/$sid.jsonl"
      fi
      history_log "resume: copied $engine session $sid from $from_tank to $to_tank"
    fi
  fi
}
