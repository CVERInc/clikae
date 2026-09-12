# shellcheck shell=bash
# Tree discovery belongs to session boundaries. Renders consume immutable,
# per-tank generations through an atomically replaced pointer. A missing index
# is an unknown reading, never permission to scan a transcript tree on a frame.
board_key() { local k; k="$(printf '%s' "$1" | cksum)"; printf '%s' "${k%% *}"; }
board_root() { printf '%s/state/board/%s' "${CLIKAE_HOME:-$HOME/.clikae}" "$(board_key "$1")"; }
board_generation() {
  local root gen=""
  root="$(board_root "$1")"
  [ -f "$root/current" ] && IFS= read -r gen < "$root/current"
  case "$gen" in generation.*) printf '%s/%s' "$root" "$gen" ;; *) return 1 ;; esac
}
board_read() {
  local gen
  gen="$(board_generation "$1")" || return 0
  [ ! -f "$gen/$2" ] || cat "$gen/$2"
}
board_recent() {
  local engine="$1" dir="$2" n="${3:-10}" scope gen
  case "$n" in ''|*[!0-9]*) n=10 ;; esac
  gen="$(board_generation "$dir")" || return 0
  if [ "$engine" = claude ]; then scope="$(_claude_project_slug "$PWD")"; else scope="${PWD%/}"; fi
  scope="$(board_key "$scope")"
  [ ! -f "$gen/recent/$scope" ] || head -n "$n" "$gen/recent/$scope"
}
board_find() {
  local engine="$1" dir="$2" sid="$3" gen f=""
  # A newly launched Claude session has a known path even before its first
  # lifecycle snapshot. No wildcard lookup, even when the stamp is missing.
  if [ "$engine" = claude ]; then
    f="$dir/projects/$(_claude_project_slug "$PWD")/$sid.jsonl"
    [ ! -f "$f" ] || { printf '%s\n' "$f"; return 0; }
  fi
  gen="$(board_generation "$dir")" || return 1
  [ -f "$gen/sids/$(board_key "$sid")" ] || return 1
  IFS= read -r f < "$gen/sids/$(board_key "$sid")"
  [ -f "$f" ] || return 1
  printf '%s\n' "$f"
}

board_state_refresh() (
  # Subshell isolates adapter hooks, umask and board-mode overrides from caller.
  local engine="$1" dir="$2" root gen pointer files f mt sid scope key count=0
  local _CLIKAE_BOARD=0 n="${CLIKAE_HOME_RECENT_MAX:-10}"
  case "$engine" in claude|codex|antigravity|grok) ;; *) return 0 ;; esac
  case "$n" in ''|*[!0-9]*) n=10 ;; esac
  umask 077
  root="$(board_root "$dir")"
  mkdir -p "$root" || return 0
  gen="$(mktemp -d "$root/generation.XXXXXX")" || return 0
  mkdir -p "$gen/recent" "$gen/sids"
  load_adapter "$engine" >/dev/null 2>&1 || return 0
  case "$engine" in
    claude) files="$(find "$dir/projects" -type f -name '*.jsonl' 2>/dev/null || true)" ;;
    codex) files="$(find "$(_codex_sessions_dir "$dir")" -type f -name 'rollout-*.jsonl' 2>/dev/null || true)" ;;
    grok) files="$(find "$dir/sessions" -maxdepth 3 -type f -name summary.json 2>/dev/null || true)" ;;
    antigravity) files="$(find "$dir/antigravity-cli/brain" -type f -name transcript.jsonl 2>/dev/null || true)" ;;
  esac
  local -a paths=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    count=$((count + 1))
    case "${f##*/}" in agent-*) continue ;; esac
    paths+=("$f")
  done <<< "$files"
  printf '%s\n' "$count" > "$gen/count"
  date +%s > "$gen/updated"
  if [ "${#paths[@]}" -gt 0 ]; then
    while read -r mt f; do
      [ -f "$f" ] || continue
      case "$engine" in
        claude) sid="${f##*/}"; sid="${sid%.jsonl}"; scope="${f%/*}"; scope="${scope##*/}" ;;
        codex) sid="$(_codex_meta_field "$f" id)"; scope="$(_codex_meta_field "$f" cwd)" ;;
        grok) sid="$(_grok_json_str "$f" id)"; scope="$(_grok_json_str "$f" cwd)" ;;
        antigravity) sid="${f%/.system_generated/*}"; sid="${sid##*/}"; scope="$(adapter_session_cwd "$f")" ;;
      esac
      [ -n "$sid" ] || continue
      key="$(board_key "$sid")"
      printf '%s\n' "$f" > "$gen/sids/$key"
      key="$(board_key "${scope%/}")"
      printf '%s\037%s\n' "$mt" "$sid" >> "$gen/recent/$key.all"
    done < <(sessions_by_mtime "${paths[@]}")
  fi
  for f in "$gen"/recent/*.all; do
    [ -f "$f" ] || continue
    head -n "$n" "$f" > "${f%.all}"
    rm -f "$f"
  done
  case "$engine" in
    claude)
      files="$(find "$dir/projects" -name '*.jsonl' -mmin -300 2>/dev/null || true)"
      _limit_claude_readings "$files" > "$gen/claude-usage" ;;
    antigravity) agy_email "$dir" > "$gen/email" ;;
    codex)
      _limit_codex_rate_limits_cached "$dir" "$root/codex-cache" > "$gen/codex-usage" || true
      files="$(find "$dir/sessions" -name 'rollout-*.jsonl' -mmin -10080 2>/dev/null || true)"
      _limit_codex_readings "$files" > "$gen/codex-dry" ;;
  esac
  pointer="$(mktemp "$root/current.XXXXXX")" || return 0
  printf '%s\n' "${gen##*/}" > "$pointer"
  mv -f "$pointer" "$root/current"
  # Old generations remain available to concurrent readers. GC runs only here.
  find "$root" -type d -name 'generation.*' -mtime +1 -exec rm -rf {} + 2>/dev/null || true
)

board_total() {
  local engine tank dir n total=0
  while IFS=$'\t' read -r engine tank dir; do
    [ -n "$tank" ] || continue
    n="$(board_read "$dir" count)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    total=$((total + n))
  done <<EOF_PROFILES
$(list_all_profiles)
EOF_PROFILES
  printf '%s' "$total"
}
