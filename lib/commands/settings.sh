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
  # ${HOME%/} strips a trailing slash so a caller with HOME=/x/ vs HOME=/x
  # expands to the same rule string instead of drifting forever (P76 R2 P3-C).
  if ! result="$(jq -n --arg user_home "${HOME%/}/*" --slurpfile template "$template" --slurpfile current "$input" '
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
    # Claude treats "Bash(cmd:*)" and "Bash(cmd *)" as the same rule; normalize
    # to the space spelling before diffing so an existing colon-spelled rule
    # does not get duplicated by the template space-spelled rule (P76 R2 P3-6).
    def norm_bash:
      if type == "string" and test("^Bash\\(.+:\\*\\)$")
      then sub("^Bash\\((?<c>.+):\\*\\)$"; "Bash(\(.c) *)")
      else . end;
    ($current[0] // {}) as $old |
    ($old.permissions.allow // [] | map(norm_bash)) as $old_a_norm |
    ($old.permissions.deny // [] | map(norm_bash)) as $old_d_norm |
    (($template[0].permissions.allow // [] | map(if . == "Bash(/home/<user>/*)" then "Bash(" + $user_home + ")" else . end)) as $tmpl_a |
      $tmpl_a | unique_by(norm_bash) |
      map(select((norm_bash) as $n | ($old_a_norm | index($n)) == null))) as $a |
    (($template[0].permissions.deny // []) as $tmpl_d |
      $tmpl_d | unique_by(norm_bash) |
      map(select((norm_bash) as $n | ($old_d_norm | index($n)) == null))) as $d |
    ($old | .permissions.allow = ((.permissions.allow // []) + $a) |
           .permissions.deny = ((.permissions.deny // []) + $d)) as $merged |
    {allow: ($a | length), deny: ($d | length), settings: $merged}
  ' 2>/dev/null)" || { [ "$input" != /dev/null ] && [ ! -s "$file" ]; }; then
    printf '%s/%s: skipped — invalid JSON or permissions shape in settings.json/template\n' "$engine" "$tank"
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
  local engine="" tank="" mode=apply arg template rc=0
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
    # #61 round-2 P2-3: profile_exists is a bare `[ -d ]` — naming an
    # existing but not-yet-a-tank directory used to write settings.json
    # straight into it, and since claude's OLD fingerprint list included
    # settings.json (a file CLIKAE ITSELF writes, never the engine), the next
    # walk silently adopted it as a permanent tank — #61's exact symptom,
    # this time with the enumerator's own blessing. A named target must be a
    # tank already; there is no more "seed it into existence" side door.
    tank_dir_is_tank "$engine" "$(profile_dir "$engine" "$tank")" \
      || { log_err "Not a tank: $engine/$tank (no .clikae-tank marker — see clikae doctor)"; return 1; }
    _settings_tank "$engine" "$tank" "$mode" "$template"
    return $?
  fi
  # #61 round-1 P2-6: used to be its own `for … in profiles_root/$engine/*`
  # (no trailing slash — so it did not even need `[ -d ]` to fail: it
  # happily WROTE settings.json into a directory-shaped `hello.lock/`, the
  # ONE walker in this whole audit that mutates what it finds). Routed
  # through tanks_for_engine (lib/core/profile_store.sh) so `settings apply`
  # only ever touches a real tank.
  local found=0 d_tank
  while IFS= read -r d_tank; do
    [ -n "$d_tank" ] || continue
    found=1
    _settings_tank "$engine" "$d_tank" "$mode" "$template" || rc=1
  done <<EOF
$(tanks_for_engine "$engine")
EOF
  [ "$found" -eq 1 ] || printf 'No %s tanks found.\n' "$engine"
  return "$rc"
}
