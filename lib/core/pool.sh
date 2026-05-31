# shellcheck shell=bash
# lib/core/pool.sh — the "fuel pool": an ordered list of tanks to fall through.
#
# When a tank runs dry, ambient relay (`clikae watch`) needs to know where to go
# next. The pool is a plain, user-owned text file at $CLIKAE_HOME/fuel-pool: one
# handoff target per line, in PRIORITY order (top = most preferred), e.g.
#
#     claude/a
#     claude/b
#     codex/work
#     antigravity
#
# Targets use the same grammar as `handoff --to`: <cli>/<profile> for a
# switchable CLI, or a bare target name (e.g. antigravity) for a launch-only one.
# Blank lines and `#` comments are ignored. We never verify a tank actually has
# quota left (that would mean burning it) — "next" simply means the next entry
# down the priority list, so order them the way you'd want to fall through.

pool_file() { printf '%s\n' "$CLIKAE_HOME/fuel-pool"; }

# Print the pool, one target per line (comments/blanks stripped).
pool_list() {
  local f; f="$(pool_file)"
  [ -f "$f" ] || return 0
  sed 's/#.*//' "$f" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//' | grep -v '^$' || true
}

# pool_next <current-target> — the entry AFTER <current> in priority order.
# If <current> isn't in the pool, returns the first entry. If <current> is the
# last entry, returns nothing (the pool is exhausted — nowhere left to fall).
pool_next() {
  local current="$1"
  local seen_current=0 first="" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ -n "$first" ] || first="$line"
    if [ "$seen_current" -eq 1 ]; then
      printf '%s\n' "$line"
      return 0
    fi
    [ "$line" = "$current" ] && seen_current=1
  done <<EOF
$(pool_list)
EOF
  # Current not found anywhere → start at the top of the pool.
  [ "$seen_current" -eq 0 ] && [ -n "$first" ] && printf '%s\n' "$first"
  return 0
}

# pool_add <target> — append a target if it's not already present.
pool_add() {
  local target="$1" f; f="$(pool_file)"
  validate_handoff_target "$target"
  if pool_list | grep -qxF "$target"; then
    log_info "Already in the pool: $target"
    return 0
  fi
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$target" >> "$f"
  log_ok "Added to the fuel pool: $target"
}

# pool_remove <target> — drop a target if present (rewrites the file).
pool_remove() {
  local target="$1" f; f="$(pool_file)"
  [ -f "$f" ] || { log_info "The fuel pool is empty."; return 0; }
  if ! pool_list | grep -qxF "$target"; then
    log_info "Not in the pool: $target"
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  # Preserve comments/blanks; only drop lines whose stripped value matches.
  local raw stripped
  while IFS= read -r raw || [ -n "$raw" ]; do
    stripped="$(printf '%s' "$raw" | sed 's/#.*//; s/[[:space:]]*$//; s/^[[:space:]]*//')"
    [ "$stripped" = "$target" ] && continue
    printf '%s\n' "$raw"
  done < "$f" > "$tmp"
  mv "$tmp" "$f"
  log_ok "Removed from the fuel pool: $target"
}

# Shared with `handoff --to`: a target is <cli>/<profile> or a bare name that
# resolves to an adapter or a lib/targets/ file. Just a shape/existence check.
validate_handoff_target() {
  local target="$1" cli="${1%%/*}"
  case "$cli" in
    ''|*[!a-zA-Z0-9._-]*) log_fail "Invalid target: '$target'" ;;
  esac
  [ -f "$CLIKAE_LIB/adapters/$cli.sh" ] || [ -f "$CLIKAE_LIB/targets/$cli.sh" ] \
    || log_fail "Unknown handoff target: '$cli' (no adapter or target by that name)"
}
