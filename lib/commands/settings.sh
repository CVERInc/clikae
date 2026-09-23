# shellcheck shell=bash

# _settings_lock_acquire [break_stale] -> take the ONE lock that serializes a
# cockpit role transition (lib/commands/cockpit.sh: move, repair, --off) and
# a `settings apply` write: a `mkdir` in $CLIKAE_HOME/state (atomic on every
# filesystem, bash 3.2, no flock on macOS). Waits up to
# CLIKAE_SETTINGS_LOCK_WAIT_S seconds (default 20), then refuses. By default
# never breaks a lock on its own: a holder whose pid is gone is named, with
# the exact removal command, because a crashed transition is also the moment
# to look at `clikae doctor` first.
#
# #63 round-5 P2-4: without it, two moves interleaved — A→B wrote state=B and
# paused; B→A installed A, wrote state=A, removed B; A→B resumed and removed
# A. Both returned 0 and neither tank was guarded. A `settings apply` holding
# a snapshot taken before an install could likewise write the guard away.
#
# #63 round-6 P3-3: `break_stale=1` (used ONLY by `clikae cockpit --off`) is
# the one exception to "never breaks a lock on its own" above. `--off` is
# defined (P1-3) as the operator's last-resort escape hatch that must never
# stay blocked — but a transition that crashed holding this lock did exactly
# that: doctor named the stale lock, yet the one command meant to recover
# from it refused with the same "in progress" message a LIVE holder gets.
# With break_stale=1, a lock whose pid is confirmably dead is removed and
# re-taken instead of refused; a lock still held by a LIVE pid still waits
# and still refuses (round-5's mutual exclusion is unchanged) — only the
# crash case, which is unambiguous (kill -0 says so), is auto-recovered.
_settings_lock_acquire() {
  local break_stale="${1:-0}"
  local d="$CLIKAE_HOME/state" lock pid tries=0 max="${CLIKAE_SETTINGS_LOCK_WAIT_S:-20}"
  case "$max" in ''|*[!0-9]*) max=20 ;; esac
  lock="$d/settings.lock"
  mkdir -p "$d" 2>/dev/null || { log_err "Could not create $d"; return 1; }
  [ ! -L "$d" ] || { log_err "Refusing to lock: $d is a symlink"; return 1; }
  while ! mkdir "$lock" 2>/dev/null; do
    pid="$(head -n 1 "$lock/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      if [ "$break_stale" = 1 ]; then
        log_warn "cockpit: breaking a stale settings lock $lock (pid $pid is not running) — --off is the last-resort escape hatch (#63 round-6 P3-3) and must not stay blocked by a transition that crashed holding it. Run \`clikae doctor\` afterward to see what it left guarded."
        rm -rf "$lock" 2>/dev/null
        pid=""
        continue
      fi
      log_err "A clikae cockpit/settings change died holding $lock (pid $pid is not running). Nothing was changed. Check clikae doctor, then remove the lock: rm -rf '$lock'"
      return 1
    fi
    if [ "$tries" -ge $((max * 10)) ]; then
      log_err "Another clikae cockpit/settings change is in progress (pid ${pid:-unknown}; lock $lock). Nothing was changed — try again when it finishes."
      return 1
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  printf '%s\n' "$$" > "$lock/pid" || { rmdir "$lock" 2>/dev/null; log_err "Could not write $lock/pid"; return 1; }
  _SETTINGS_LOCK_HELD="$lock"
}

# _settings_lock_release -> drop the lock, only if this process holds it.
_settings_lock_release() {
  local lock="${_SETTINGS_LOCK_HELD:-}"
  [ -n "$lock" ] || return 0
  _SETTINGS_LOCK_HELD=""
  [ "$(head -n 1 "$lock/pid" 2>/dev/null)" = "$$" ] || return 0
  rm -f "$lock/pid" 2>/dev/null
  rmdir "$lock" 2>/dev/null || true
}

# _settings_snapshot <tank dir> <label> -> the ONE place a settings.json is
# located and read (#63 round-5 P3-3). Sets:
#   _SETTINGS_FILE  settings.json under the tank directory's PHYSICAL path
#                   (resolved once, `cd -P`), used for every later step;
#   _SETTINGS_SNAP  a private copy of it taken with a no-follow copy, or ""
#                   when there is no settings.json yet.
# Callers parse _SETTINGS_SNAP, and _settings_write_file backs up from it —
# the live path is never read a second time. The codex review swapped
# settings.json for a symlink between the JSON read and the backup `cp`,
# and the backup copied the symlink's target (a stand-in for a credential
# file). A link or non-file found at the path, or produced by a swap during
# the copy itself, is refused.
#
# Call it from a subshell: it installs that subshell's EXIT trap to remove
# the snapshot directory. `--no-copy` (a caller that will not write: doctor,
# --check, --dry-run) resolves and checks the same way but reads the live
# file in place, so a read-only command creates nothing in the tank.
_settings_snapshot() {
  local dir="$1" label="$2" no_copy="${3-}" phys
  _SETTINGS_FILE=""; _SETTINGS_SNAP=""; _SETTINGS_SNAP_DIR=""
  phys="$(cd -P "$dir" 2>/dev/null && pwd -P)" || { printf '%s: skipped — cannot resolve the tank directory\n' "$label"; return 1; }
  _SETTINGS_FILE="$phys/settings.json"
  if [ -L "$_SETTINGS_FILE" ] || { [ -e "$_SETTINGS_FILE" ] && [ ! -f "$_SETTINGS_FILE" ]; }; then
    printf '%s: skipped — settings.json is not a regular, unlinked file\n' "$label"
    return 1
  fi
  [ -e "$_SETTINGS_FILE" ] || return 0
  if [ "$no_copy" = --no-copy ]; then _SETTINGS_SNAP="$_SETTINGS_FILE"; return 0; fi
  _SETTINGS_SNAP_DIR="$(mktemp -d "$phys/.clikae-snap.XXXXXX" 2>/dev/null)" || { printf '%s: failed to create a snapshot directory\n' "$label"; return 1; }
  trap '[ -z "$_SETTINGS_SNAP_DIR" ] || rm -rf "$_SETTINGS_SNAP_DIR"' EXIT
  # -R -P: copy a symlink AS a symlink (never its target), on GNU and BSD cp.
  cp -RPp "$_SETTINGS_FILE" "$_SETTINGS_SNAP_DIR/settings.json" 2>/dev/null \
    || { printf '%s: failed to read settings.json\n' "$label"; return 1; }
  if [ -L "$_SETTINGS_SNAP_DIR/settings.json" ] || [ ! -f "$_SETTINGS_SNAP_DIR/settings.json" ]; then
    printf '%s: skipped — settings.json turned into a link or non-file while it was being read\n' "$label"
    return 1
  fi
  _SETTINGS_SNAP="$_SETTINGS_SNAP_DIR/settings.json"
}

# _settings_write_file <file> <content> <label> <snapshot>  ->  write <content>
# to <file> atomically: a temp file seeded with the snapshot's owner/mode, a
# backup made FROM THE SNAPSHOT (never by re-reading <file>), then a rename
# into place. <file> and <snapshot> come from _settings_snapshot; an empty
# <snapshot> means there was no settings.json when it was read. <label>
# (e.g. "claude/work") prefixes every failure message.
#
# The ONE write path every settings.json mutation in clikae goes through —
# #76/#85's permissions-template apply below, and the cockpit guard's hook
# install/remove (#63, lib/commands/cockpit.sh) — so a second writer never
# hand-rolls its own jq-and-redirect with none of this safety.
_settings_write_file() (
  local file="$1" content="$2" label="$3" snap="${4-}" tmp=""
  # #63 P2-4: refuse to write nothing. `$content` is always built by a caller
  # as `"$(… | jq …)"` — if that jq dies mid-pipeline (OOM, disk full, killed
  # mid-upgrade), command substitution swallows its exit code AND turns the
  # empty stdout into an empty string, and the old code below happily wrote
  # `printf '%s\n' ""` — one bare newline — over a live settings.json,
  # rc=0, no error, backup made but the operator told nothing broke. This is
  # the one place in the whole write path that can catch it: every caller
  # funnels through here.
  [ -n "$content" ] || { printf '%s: refusing to write empty content\n' "$label" >&2; return 1; }
  [ "$#" -ge 4 ] || { printf '%s: internal error — no settings snapshot\n' "$label" >&2; return 1; }
  if [ -z "$snap" ] && { [ -e "$file" ] || [ -L "$file" ]; }; then
    printf '%s: skipped — settings.json appeared while it was being edited\n' "$label"
    return 1
  fi
  trap '[ -z "$tmp" ] || rm -f "$tmp"' EXIT
  trap 'exit 1' HUP INT TERM
  tmp="$(mktemp "${file}.tmp.XXXXXX")" || { printf '%s: failed to create a temp file\n' "$label"; return 1; }
  if [ -n "$snap" ]; then
    # Seed the temp file's owner/mode from the snapshot; the backup is the
    # separate copy made below, right before the live file is replaced.
    cp -p "$snap" "$tmp" || { printf '%s: failed to prepare the temp file\n' "$label"; return 1; }
  fi
  # Trailing newline: command substitution (how every caller builds $content
  # from `jq`) strips it, so add exactly one back — jq's own CLI output
  # always ends in one, and a write that quietly drops it would leave a
  # settings.json byte-different from anything jq itself would ever produce.
  printf '%s\n' "$content" > "$tmp" || { printf '%s: failed to write the temp file\n' "$label"; return 1; }
  if [ -n "$snap" ]; then
    local backup
    backup="$(mktemp "${file}.clikae.bak.XXXXXX")" || { printf '%s: failed to create a backup file\n' "$label"; return 1; }
    cp -p "$snap" "$backup" || { printf '%s: failed to back up settings.json\n' "$label"; return 1; }
    _settings_prune_backups "$file"
  fi
  # `mv -f tmp dir` would put the file INSIDE a directory swapped in at the
  # destination instead of replacing it.
  if [ -d "$file" ] && [ ! -L "$file" ]; then
    printf '%s: skipped — settings.json is now a directory\n' "$label"
    return 1
  fi
  mv -f "$tmp" "$file" || { printf '%s: failed to replace settings.json\n' "$label"; return 1; }
  tmp=""
)

# _settings_prune_backups <file> -> #63 P3-11: keep only the newest 5
# `<file>.clikae.bak.*` backups for this settings.json. `clikae cockpit`
# moving the role is a routine, repeated action (unlike #85's apply, which
# runs rarely) — nothing else was ever capping this, so the backup count
# grows without bound in a profile that moves cockpit often.
_settings_prune_backups() {
  local file="$1" bak i=0
  # bash 3.2: no mapfile/readarray. `ls -t` is newest-first; a glob with no
  # matches expands to nothing under nullglob, or the literal pattern
  # otherwise — either way `ls -t` on a non-existent path just fails quietly
  # (stderr discarded) and the loop body never runs.
  while IFS= read -r bak; do
    i=$((i + 1))
    [ "$i" -gt 5 ] && rm -f "$bak" 2>/dev/null
  done < <(ls -t "${file}.clikae.bak."* 2>/dev/null)
}

# Merge only missing template permissions; compliant files are never rewritten.
_settings_tank() (
  local engine="$1" tank="$2" mode="$3" template="$4"
  local file input result allow deny
  command -v jq >/dev/null 2>&1 || {
    printf '%s/%s: skipped — settings inspection requires jq\n' "$engine" "$tank"
    return 1
  }
  local copy=--no-copy
  [ "$mode" = apply ] && copy=""
  _settings_snapshot "$(profile_dir "$engine" "$tank")" "$engine/$tank" $copy || return 1
  file="$_SETTINGS_FILE"
  input="${_SETTINGS_SNAP:-/dev/null}"
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
  ' 2>/dev/null)" || { [ "$input" != /dev/null ] && [ ! -s "$input" ]; }; then
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
    # #63 P2-4: check the jq substitution's own exit status before handing
    # its output to the writer (see _settings_write_file's matching guard).
    local settings_out
    settings_out="$(printf '%s' "$result" | jq '.settings')" || {
      printf '%s/%s: jq failed while preparing settings.json\n' "$engine" "$tank" >&2
      return 1
    }
    _settings_write_file "$file" "$settings_out" "$engine/$tank" "$_SETTINGS_SNAP" || return 1
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
  fi
  # #63 round-5 P2-4: a writing apply holds the cockpit's lock (see
  # _settings_lock_acquire), inside a subshell so its traps never replace a
  # caller's (clikae init runs this too). Read-only modes take no lock.
  #
  # #61 round-5 merge: this subshell and #61's two "only ever touch a real
  # tank" criteria are the SAME walk seen from two sides — the lock decides
  # WHEN it is safe to write, tank_dir_is_tank/tanks_for_engine decide WHAT
  # may be written to — so the criteria live INSIDE the lock (every failure
  # path in here `exit`s, it cannot `return`).
  (
    if [ "$mode" = apply ]; then
      # #63 round-6 P3-3: exit 4 (not 1) specifically when the LOCK itself
      # is unavailable — distinct from every other failure below, which
      # stays rc=1. `clikae init claude <tank>` (lib/commands/init.sh)
      # already treats rc 2/3 (no template for this engine / jq missing) as
      # a value-add it can live without; it now treats 4 the same way, with
      # a WARN naming the lock, instead of returning 1 AFTER the tank it
      # just created — one crashed transition's stale lock should not make
      # a brand-new tank look like it failed to be created.
      _settings_lock_acquire 0 || exit 4   # never break_stale here — see cockpit.sh's _cockpit_locked
      trap '_settings_lock_release' EXIT
      trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
    fi
    if [ -n "$tank" ]; then
      # #61 round-2 P2-3: profile_exists is a bare `[ -d ]` — naming an
      # existing but not-yet-a-tank directory used to write settings.json
      # straight into it, and since claude's OLD fingerprint list included
      # settings.json (a file CLIKAE ITSELF writes, never the engine), the
      # next walk silently adopted it as a permanent tank — #61's exact
      # symptom, this time with the enumerator's own blessing. A named
      # target must be a tank already; there is no more "seed it into
      # existence" side door.
      tank_dir_is_tank "$engine" "$(profile_dir "$engine" "$tank")" \
        || { log_err "Not a tank: $engine/$tank (no .clikae-tank marker — see clikae doctor)"; exit 1; }
      _settings_tank "$engine" "$tank" "$mode" "$template"
      exit $?
    fi
    # #61 round-1 P2-6: used to be its own `for d in profiles_root/$engine/*`
    # (no trailing slash — so it did not even need `[ -d ]` to fail: it
    # happily WROTE settings.json into a directory-shaped `hello.lock/`, the
    # ONE walker in this whole audit that mutates what it finds). Routed
    # through tanks_for_engine (lib/core/profile_store.sh) so `settings
    # apply` only ever touches a real tank.
    found=0
    while IFS= read -r d_tank; do
      [ -n "$d_tank" ] || continue
      found=1
      _settings_tank "$engine" "$d_tank" "$mode" "$template" || rc=1
    done <<EOF
$(tanks_for_engine "$engine")
EOF
    [ "$found" -eq 1 ] || printf 'No %s tanks found.\n' "$engine"
    exit "$rc"
  )
}
