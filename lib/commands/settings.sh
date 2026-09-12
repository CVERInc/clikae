# shellcheck shell=bash
# Merge only missing template permissions; compliant files are never rewritten.
_settings_tank() (
  local engine="$1" tank="$2" mode="$3" template="$4"
  local file input result allow deny tmp=""
  command -v jq >/dev/null 2>&1 || {
    printf '%s/%s: skipped — settings inspection requires jq\n' "$engine" "$tank"
    return 1
  }
  file="$(profile_dir "$engine" "$tank")/settings.json"
  input="$file"
  if [ -L "$file" ] || { [ -e "$file" ] && [ ! -f "$file" ]; }; then
    printf '%s/%s: skipped — settings.json is not a regular, unlinked file\n' "$engine" "$tank"
    return 1
  fi
  [ -e "$file" ] || input=/dev/null
  # $HOME, not a hardcoded /home/<user>: this template also ships to macOS via
  # Homebrew, where $HOME is /Users/<user> and there is no /home at all.
  if ! result="$(jq -n --arg user_home "$HOME/*" --slurpfile template "$template" --slurpfile current "$input" '
    def rules: type == "array" and all(.[]; type == "string");
    def valid:
      type == "object" and
      ((has("permissions") | not) or
       (.permissions | type == "object" and
        ((has("allow") | not) or (.allow | rules)) and
        ((has("deny") | not) or (.deny | rules))));
    if ($template | length) != 1 or ($template[0] | valid | not)
      then error("invalid template") else . end |
    if ($current | length) > 1 or
       (($current | length) == 1 and ($current[0] | valid | not))
      then error("invalid settings") else . end |
    ($current[0] // {}) as $old |
    (($template[0].permissions.allow // [] | map(if . == "Bash(/home/<user>/*)" then "Bash(" + $user_home + ")" else . end)) - ($old.permissions.allow // []) | unique) as $a |
    (($template[0].permissions.deny // []) - ($old.permissions.deny // []) | unique) as $d |
    ($old | .permissions.allow = ((.permissions.allow // []) + $a) |
           .permissions.deny = ((.permissions.deny // []) + $d)) as $merged |
    (($merged.permissions.allow // []) as $A | ($merged.permissions.deny // []) as $D | $A - ($A - $D)) as $shadow |
    {allow: ($a | length), deny: ($d | length), shadow: $shadow, settings: $merged}
  ' 2>/dev/null)" || { [ "$input" != /dev/null ] && [ ! -s "$file" ]; }; then
    printf '%s/%s: skipped — invalid JSON or permissions shape in settings.json/template\n' "$engine" "$tank"
    return 1
  fi
  local shadow
  shadow="$(printf '%s' "$result" | jq -r '.shadow | join(", ")')"
  if [ -n "$shadow" ]; then
    printf '%s/%s: refused — allow rule(s) shadow a deny rule: %s\n' "$engine" "$tank" "$shadow"
    return 1
  fi
  allow="$(printf '%s' "$result" | jq -r .allow)"
  deny="$(printf '%s' "$result" | jq -r .deny)"
  if [ "$allow" -eq 0 ] && [ "$deny" -eq 0 ]; then
    [ "$mode" = doctor ] || printf '%s/%s: unchanged\n' "$engine" "$tank"
    return 0
  fi
  if [ "$mode" = doctor ] || [ "$mode" = check ]; then
    printf '%s/%s: permissions drift (+%s allow / +%s deny); run clikae settings apply %s %s\n' "$engine" "$tank" "$allow" "$deny" "$engine" "$tank"
    return 1
  fi
  if [ "$mode" = apply ]; then
    trap '[ -z "$tmp" ] || rm -f "$tmp"' EXIT
    trap 'exit 1' HUP INT TERM
    tmp="$(mktemp "${file}.tmp.XXXXXX")" || { printf '%s/%s: failed to create a temp file\n' "$engine" "$tank"; return 1; }
    if [ -f "$file" ]; then
      # Seed the temp file's owner/mode from the live file; the actual backup
      # is the separate copy made below, right before the live file is touched.
      cp -p "$file" "$tmp" || { printf '%s/%s: failed to prepare the temp file\n' "$engine" "$tank"; return 1; }
    fi
    printf '%s' "$result" | jq '.settings' > "$tmp" || { printf '%s/%s: failed to write the temp file\n' "$engine" "$tank"; return 1; }
    if [ -f "$file" ]; then
      local backup
      backup="$(mktemp "${file}.clikae.bak.XXXXXX")" || { printf '%s/%s: failed to create a backup file\n' "$engine" "$tank"; return 1; }
      cp -p "$file" "$backup" || { printf '%s/%s: failed to back up settings.json\n' "$engine" "$tank"; return 1; }
    fi
    mv -f "$tmp" "$file" || { printf '%s/%s: failed to replace settings.json\n' "$engine" "$tank"; return 1; }
    tmp=""
  fi
  printf '%s/%s: +%s allow / +%s deny%s\n' "$engine" "$tank" "$allow" "$deny" "$( [ "$mode" != dry-run ] || printf ' (dry-run)' )"
)

cmd_settings() {
  local engine="" tank="" mode=apply arg template d rc=0
  case "${1:-}" in
    -h|--help) ;;
    apply) shift ;;
    *) log_err 'Usage: clikae settings apply [engine] [tank] [--check|--dry-run]'; return 1 ;;
  esac
  for arg in "$@"; do
    case "$arg" in
      -h|--help)
        cat <<'HELP'
Usage: clikae settings apply [engine] [tank] [--check|--dry-run]

Engine defaults to claude; omit tank to apply to every tank of that engine.
Union template allow/deny rules, keeping all other settings and extra rules.
--check    List drift; exit 1 when rules are missing, without writing.
--dry-run  Preview per-tank additions without writing.
Existing changed files get a settings.json.clikae.bak.* backup.
HELP
        return 0 ;;
      --check|--dry-run)
        [ "$mode" = apply ] || { log_err 'Use only one of --check and --dry-run'; return 1; }
        mode="${arg#--}" ;;
      -*) log_err "Unknown flag: $arg"; return 1 ;;
      *)
        if [ -z "$engine" ]; then engine="$arg"
        elif [ -z "$tank" ]; then tank="$arg"
        else log_err "Unexpected argument: $arg"; return 1
        fi ;;
    esac
  done
  engine="${engine:-claude}"
  validate_name cli "$engine"
  [ -z "$tank" ] || validate_name profile "$tank"
  template="$CLIKAE_ROOT/templates/permissions/$engine.json"
  [ -f "$template" ] || { log_warn "No permissions template for engine: $engine; skipping"; return 2; }
  command -v jq >/dev/null 2>&1 || { log_err 'settings apply requires jq; permissions template not applied'; return 3; }
  if [ -n "$tank" ]; then
    profile_exists "$engine" "$tank" || { log_err "Tank does not exist: $engine/$tank"; return 1; }
    _settings_tank "$engine" "$tank" "$mode" "$template"
    return $?
  fi
  local found=0
  for d in "$(profiles_root)/$engine"/*; do
    [ -d "$d" ] || continue
    found=1
    _settings_tank "$engine" "${d##*/}" "$mode" "$template" || rc=1
  done
  [ "$found" -eq 1 ] || printf 'No %s tanks found.\n' "$engine"
  return "$rc"
}
