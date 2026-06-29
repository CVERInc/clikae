# shellcheck shell=bash
# lib/adapters/antigravity.sh — Antigravity (agy) RESUME-ONLY adapter shim.
#
# ⚠️ antigravity is a launch-only TARGET (lib/targets/antigravity.sh), NOT an
# env-switchable engine: it's a global single-account vendor whose tank switching
# rides the ~/.gemini symlink + a macOS Keychain login carry (see
# lib/commands/antigravity.sh). This file exists ONLY to give `clikae resume` the
# per-engine hooks it needs (find/resume a session by id) — it deliberately has an
# EMPTY env var and `subcommand` strategy so the rest of clikae keeps treating
# antigravity as the target it is. Classification code must use clikae_is_target,
# which wins over this file's presence; never infer "env-switchable" from it.

adapter_meta_name()        { echo "Antigravity"; }
adapter_meta_cli_binary()  { echo "agy"; }
adapter_meta_env_var()     { echo ""; }
adapter_meta_strategy()    { echo "subcommand"; }
adapter_meta_description() { echo "Google DeepMind Antigravity CLI"; }

adapter_init() {
  :
}

adapter_export_env() {
  :
}

adapter_run() {
  local profile_dir="$1"; shift
  local name; name="$(basename "$profile_dir")"
  # Sourcing lib/commands/antigravity.sh so we can call _agy_switch
  # shellcheck source=../commands/antigravity.sh
  source "$CLIKAE_LIB/commands/antigravity.sh"
  _agy_switch "$name" "$@"
}

adapter_resume_args() {
  local sid="$1"
  [ -n "$sid" ] || return 1
  printf '--conversation\n%s\n' "$sid"
}

adapter_find_session() {
  local dir="$1" sid="$2" f
  [ -n "$sid" ] || return 1
  f="$dir/antigravity-cli/brain/$sid/.system_generated/logs/transcript.jsonl"
  [ -f "$f" ] && printf '%s\n' "$f"
}

adapter_session_cwd() {
  local f="$1"
  [ -f "$f" ] || return 0
  local bdir; bdir="$(dirname "$(dirname "$(dirname "$(dirname "$f")")")")"
  local sid; sid="$(basename "$(dirname "$(dirname "$(dirname "$f")")")")"
  local cwd
  cwd="$(grep -F "$sid" "$bdir/history.jsonl" 2>/dev/null \
    | grep -oE '"workspace"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 \
    | sed -E 's/^"workspace"[[:space:]]*:[[:space:]]*"//; s/"$//' || true)"
  [ -n "$cwd" ] || cwd="$HOME"
  printf '%s\n' "$cwd"
}

adapter_session_title() {
  local dir="$1" sid="$2" f t
  [ -n "$sid" ] || return 0
  f="$dir/antigravity-cli/brain/$sid/.system_generated/logs/transcript.jsonl"
  [ -f "$f" ] || return 0
  t="$(head -n 1 "$f" 2>/dev/null | grep -oE '"content"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -n 1 \
        | sed -E 's/^"content"[[:space:]]*:[[:space:]]*"//; s/"$//' || true)"
  if [[ "$t" == *"<USER_REQUEST>"* ]]; then
    t="${t#*<USER_REQUEST>}"
    t="${t%%</USER_REQUEST>*}"
  fi
  printf '%s' "$t" | sed -E 's/\\n/ /g; s/\\t/ /g; s/\\"/"/g' \
    | tr '\t\n' '  ' | sed -E 's/  +/ /g; s/^ //; s/ $//'
}

adapter_recent_sessions() {
  local dir="$1" limit="${2:-12}" bdir f sid mt cwd title
  bdir="$dir/antigravity-cli/brain"
  [ -d "$bdir" ] || return 0

  local list="" t mt
  for t in "$bdir"/*/.system_generated/logs/transcript.jsonl; do
    [ -f "$t" ] || continue
    mt="$(stat -c '%Y' "$t" 2>/dev/null || stat -f '%m' "$t" 2>/dev/null || echo 0)"
    list="$list$mt $t"$'\n'
  done

  local sorted_files
  sorted_files="$( (printf '%s\n' "$list" | sort -rn | head -n "$limit") 2>/dev/null || true)"
  sorted_files="$(printf '%s\n' "$sorted_files" | cut -d' ' -f2-)"

  while IFS= read -r f; do
    [ -f "$f" ] || continue
    sid="$(basename "$(dirname "$(dirname "$(dirname "$f")")")")"
    [ -n "$sid" ] || continue
    mt="$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null || echo 0)"
    cwd="$(adapter_session_cwd "$f")"
    title="$(adapter_session_title "$dir" "$sid")"
    [ -n "$title" ] || title="(no preview)"
    printf '%s\037%s\037%s\037%s\n' "$mt" "$sid" "$cwd" "$title"
  done <<EOF
$sorted_files
EOF
}
