# shellcheck shell=bash
# lib/commands/init.sh — `clikae init <engine> <tank> [--alias]`

# _init_merge_template_settings <engine> <tank> <dir> <template settings.json>
# -> merge template-only TOP-LEVEL keys into the new tank's settings.json,
# print the count of keys added, or nothing on any failure (best-effort: a
# tank is already created by the time this runs). Never touches a key the
# tank already has — this seeds defaults, it does not enforce them — and
# goes through the one write path settings.sh owns (_settings_snapshot /
# _settings_write_file) so the backup/lock/atomic-rename discipline every
# other settings.json mutation gets is not hand-rolled a second time here.
# A subshell: _settings_snapshot installs THIS subshell's EXIT trap for the
# snapshot dir it creates (see its docstring in settings.sh).
_init_merge_template_settings() (
  local engine="$1" tank="$2" dir="$3" tmpl_file="$4" result added settings_out
  _settings_snapshot "$dir" "$engine/$tank" >/dev/null 2>&1 || return 0
  result="$(jq -n --slurpfile tmpl "$tmpl_file" --slurpfile cur "${_SETTINGS_SNAP:-/dev/null}" '
    ($tmpl[0] // {}) as $t | ($cur[0] // {}) as $c |
    if ($t | type) != "object" then error("invalid template settings.json")
    elif ($cur | length) > 0 and ($c | type) != "object" then error("invalid settings.json")
    else . end |
    ($t | keys_unsorted | map(select(. as $k | ($c | has($k)) | not))) as $new |
    {added: ($new | length),
     settings: ($c + ($t | with_entries(select(.key as $k | $new | index($k)))))}
  ' 2>/dev/null)" || return 0
  added="$(printf '%s' "$result" | jq -r '.added // 0' 2>/dev/null)"
  case "$added" in ''|0|*[!0-9]*) return 0 ;; esac
  settings_out="$(printf '%s' "$result" | jq '.settings' 2>/dev/null)" || return 0
  _settings_write_file "$_SETTINGS_FILE" "$settings_out" "$engine/$tank" "$_SETTINGS_SNAP" >/dev/null 2>&1 || return 0
  printf '%s' "$added"
)

# _init_apply_template <engine> <tank> <dir> -> seed a freshly-created tank
# from $CLIKAE_HOME/template/<engine>/ (#95), if the operator ever set one up
# there. This is the SMALL version of #95: hooks and MCP servers are already
# covered fleet-wide by `clikae hooks share` / `clikae mcp share` (#141) and
# must not be duplicated here — this only ever handles per-tank FILES a
# template directory holds (a theme, other config the engine reads straight
# off disk) plus settings.json KEYS, which get merged rather than copied
# because settings.json already exists by the time init gets here (the
# permissions template and fleet_hooks_prelaunch, both above, may have
# already written to it).
#
# Never overwrites anything init already wrote: every non-settings.json file
# is copied only when the tank does not already have it at that relative
# path; settings.json goes through _init_merge_template_settings, which only
# adds keys the tank's settings.json is missing. Silent when there is no
# template directory for this engine — the whole point is that a maintainer
# who never set one up sees no new output at all.
_init_apply_template() {
  local engine="$1" tank="$2" dir="$3" tmpl copied=0 merged=0 names="" f rel target
  tmpl="$CLIKAE_HOME/template/$engine"
  [ -d "$tmpl" ] || return 0

  if ! declare -F _settings_snapshot >/dev/null 2>&1; then
    # shellcheck source=./settings.sh
    source "$CLIKAE_LIB/commands/settings.sh"
  fi

  while IFS= read -r -d '' f; do
    rel="${f#"$tmpl"/}"
    if [ "$rel" = "settings.json" ]; then
      if command -v jq >/dev/null 2>&1; then
        local n; n="$(_init_merge_template_settings "$engine" "$tank" "$dir" "$f")"
        case "$n" in ''|*[!0-9]*) ;; *) merged=$((merged + n)) ;; esac
      fi
      continue
    fi
    target="$dir/$rel"
    if [ -e "$target" ] || [ -L "$target" ]; then continue; fi
    mkdir -p "$(dirname "$target")" 2>/dev/null || continue
    cp -p "$f" "$target" 2>/dev/null || continue
    copied=$((copied + 1))
    names="${names:+$names, }$rel"
  done < <(find "$tmpl" -type f -print0 2>/dev/null)

  [ "$copied" -gt 0 ] || [ "$merged" -gt 0 ] || return 0
  local msg="Seeded from template ($engine/$tank)"
  [ -z "$names" ] || msg="$msg: $names"
  if [ "$merged" -gt 0 ]; then
    msg="$msg${names:+; }settings.json +$merged key$( [ "$merged" -eq 1 ] || printf s )"
  fi
  log_info "$msg"
}

cmd_init() {
  local with_alias=0 cli="" profile="" no_template=0 adopt=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --alias) with_alias=1; shift ;;
      --no-template) no_template=1; shift ;;
      --adopt) adopt=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: clikae init <engine> <tank> [--alias] [--no-template]
       clikae init <engine> <tank> --adopt

Create a new tank (account/config) for an engine.

Arguments:
  <engine>   Engine name (a CLI with an adapter). Run `clikae adapters` to list.
  <tank>     Tank name. A-Z a-z 0-9 . _ - allowed.

Options:
  --alias        Also add a shell alias to your shell rc:
                   <engine>-<tank>   (e.g. claude-work)
  --no-template  Skip applying the permissions template to a new claude tank
                 (same effect as CLIKAE_NO_PERMISSIONS_TEMPLATE=1), AND skip
                 seeding the tank from $CLIKAE_HOME/template/<engine>/, if
                 one exists (#95) — one flag, both template steps.
  --adopt        Mark an EXISTING directory a tank instead of creating one.
                 Refuses unless the directory already looks like a <engine>
                 tank (has that engine's own config file) — the one-time
                 adoption sweep (#61) only ever runs once per store; this is
                 the way back for a directory that landed there afterward (a
                 restored backup, a stray you've since confirmed is real).
                 Does not touch the directory's content, and is a harmless
                 no-op if it's already a tank. Incompatible with --alias and
                 --no-template (run `clikae alias` separately if you want one).

Example:
  clikae init claude work --alias       # then:  clikae claude work
  clikae init claude restored --adopt   # mark an existing dir a tank
EOF
        return 0
        ;;
      --) shift; break ;;
      -*) log_fail "Unknown flag: $1" ;;
      *)
        if [ -z "$cli" ]; then cli="$1"
        elif [ -z "$profile" ]; then profile="$1"
        else log_fail "Unexpected argument: $1"
        fi
        shift
        ;;
    esac
  done

  [ -n "$cli" ]     || log_fail "Missing <engine>. See: clikae init --help"
  [ -n "$profile" ] || log_fail "Missing <tank>. See: clikae init --help"
  validate_name cli "$cli"
  validate_name profile "$profile"

  # #61 round-3 P2-1: --adopt marks an EXISTING directory a tank instead of
  # creating a new one. Refuses unless the directory already looks like the
  # named engine's own content (the same read-only fingerprint signal
  # `doctor` already uses to explain a stray directory) — least-new-surface:
  # no new flag shape, reuses profile_dir/tank_dir_is_tank/
  # _tank_fingerprint_match exactly as adoption and doctor already do.
  if [ "$adopt" -eq 1 ]; then
    # #61 round-4 P3-1: --adopt only ever writes the marker file (see its
    # --help text: "Does not touch the directory's content") — --alias and
    # --no-template belong to the CREATE path below and silently doing
    # nothing with them here used to look like success while writing no
    # alias and applying no skip. Refuse the combination instead of
    # guessing; both have their own one-line follow-up command.
    if [ "$with_alias" -eq 1 ]; then
      log_fail "clikae init --adopt does not write shell aliases. Run \`clikae alias $cli $profile\` after adopting."
    fi
    if [ "$no_template" -eq 1 ]; then
      log_fail "clikae init --adopt never applies a permissions template — --no-template has nothing to skip here."
    fi
    if [ "$cli" = "agy" ] || [ "$cli" = "antigravity" ]; then
      log_fail "clikae init --adopt does not apply to agy — it has no marker-based tanks (see: clikae agy --help)."
    fi
    load_adapter "$cli"
    # #61 round-4 P3-2: the same shapes the one-time sweep refuses BY NAME,
    # regardless of content (_tank_shape_excluded — dotdirs, lock/sidecar
    # suffixes) — a directory `--adopt` should never be able to hand a
    # marker to something the sweep itself would have skipped past on sight.
    if _tank_shape_excluded "$profile"; then
      log_fail "Refusing to adopt $cli/$profile — that name shape (dotdir, or a lock/sidecar suffix like .lock/.tmp/.bak) can never be a tank."
    fi
    local d
    d="$(profile_dir "$cli" "$profile")"
    # #61 round-4 P3-6: a FILE at $d is a different problem than nothing
    # there at all, and the old single message called it "No such
    # directory" (wrong — it exists) while suggesting `clikae init $cli
    # $profile` (which would also fail: ensure_profile --create collides
    # with the same file). Name what's actually there, suggest something
    # that works.
    if [ -e "$d" ] && [ ! -d "$d" ]; then
      log_fail "$cli/$profile  ($d) is a file, not a directory — nothing to adopt. Move or remove it, then \`clikae init $cli $profile\` to create a tank there."
    fi
    # #61 round-5 P3-7: `[ -e ]` FOLLOWS symlinks, so a dangling one answers
    # no to both tests above and fell into "No such directory … use `clikae
    # init $cli $profile` instead" — a suggestion that cannot work, because
    # the name is taken by the broken link (and, before the same round's fix
    # to the create path, one that printed "Created tank" before failing).
    if [ -L "$d" ] && [ ! -d "$d" ]; then
      log_fail "$cli/$profile  ($d) is a broken symlink (it points at $(readlink "$d" 2>/dev/null), which doesn't exist) — nothing to adopt. Remove it (\`rm \"$d\"\`), then \`clikae init $cli $profile\` to create a tank there."
    fi
    if [ ! -d "$d" ]; then
      log_fail "No such directory: $cli/$profile  ($d) — nothing to adopt. Use \`clikae init $cli $profile\` to create a new tank instead."
    fi
    if tank_dir_is_tank "$cli" "$d"; then
      log_pass "Already a tank: $cli/$profile  ($d) — nothing to do."
      return 0
    fi
    if ! _tank_fingerprint_match "$cli" "$d" 2>/dev/null; then
      log_fail "Refusing to adopt $cli/$profile  ($d) — it doesn't look like a $cli tank (no $cli-shaped content found). If you're certain, add the marker yourself: printf '%s\n' $cli > \"$d/.clikae-tank\""
    fi
    tank_marker_write "$cli" "$d"
    profiles_cache_reset 2>/dev/null || true
    log_done "Adopted existing directory as tank: $cli/$profile  ($d)"
    return 0
  fi

  # agy is opt-in symlink-swap, not an env adapter — it has no lib/adapters file,
  # so handle it before load_adapter (which would fail). See docs/grammar.md §6.
  if [ "$cli" = "agy" ] || [ "$cli" = "antigravity" ]; then
    # shellcheck source=./antigravity.sh
    source "$CLIKAE_LIB/commands/antigravity.sh"
    _agy_init "$profile"
    return $?
  fi

  load_adapter "$cli"

  if profile_exists "$cli" "$profile"; then
    log_fail "Tank already exists: $cli/$profile  ($(profile_dir "$cli" "$profile"))"
  fi
  # #61 round-5 P3-7: profile_exists is `[ -d ]`, so a name already taken by
  # something that is NOT a directory — a broken symlink, a file, a fifo —
  # sailed past it into ensure_profile, whose `mkdir -p` then failed with its
  # own error. That failure did not abort: `local d; d="$(…)"` reports the
  # exit status of `local`, never of the substitution, so `set -e` saw
  # success and init printed "[ DONE ] Created tank" before the next command
  # failed for real. One outcome, one line: name what is in the way here.
  local d; d="$(profile_dir "$cli" "$profile")"
  if [ -L "$d" ]; then
    log_fail "Cannot create $cli/$profile: $d is a broken symlink (it points at $(readlink "$d" 2>/dev/null), which doesn't exist). Remove it (\`rm \"$d\"\`), then run this again."
  fi
  if [ -e "$d" ]; then
    log_fail "Cannot create $cli/$profile: $d already exists and is not a directory. Move or remove it, then run this again."
  fi
  # `|| return 1`, not a bare assignment: see the note above — an assignment
  # to a `local` swallows the substitution's exit status entirely.
  d="$(ensure_profile --create "$cli" "$profile")" || return 1
  log_done "Created tank: $cli/$profile  ($d)"

  if declare -F adapter_init >/dev/null; then
    adapter_init "$d"
  fi

  if [ "$cli" = claude ]; then
    if [ "$no_template" -eq 1 ] || [ "${CLIKAE_NO_PERMISSIONS_TEMPLATE:-0}" = 1 ]; then
      log_info "Skipping permissions template (--no-template / CLIKAE_NO_PERMISSIONS_TEMPLATE=1)"
    else
      # shellcheck source=./settings.sh
      source "$CLIKAE_LIB/commands/settings.sh"
      # rc 2 (no template for this engine) and rc 3 (jq missing) are
      # already reported by cmd_settings itself; a template is a value-add,
      # not a precondition for a tank to exist, so init keeps going either
      # way. Any other failure is a real bug and should still surface.
      # `|| _settings_rc=$?`, not a bare call: bin/clikae runs under `set -e`,
      # so an unguarded nonzero return here would abort the whole process
      # before this case statement ever got to see it.
      local _settings_rc=0
      cmd_settings apply claude "$profile" || _settings_rc=$?
      case "$_settings_rc" in
        0|2|3) ;;
        # #63 round-6 P3-3: rc 4 means the settings lock itself was
        # unavailable (held, or stale from a crashed cockpit/settings
        # transition) — the tank above is already created either way, so
        # this is the same "value-add, not a precondition" case as 2/3,
        # just WARNed instead of silently swallowed, since the operator
        # needs to know the template never got a chance to apply and why.
        4) log_warn "Tank created, but the permissions template could not be applied: the settings lock ($CLIKAE_HOME/state/settings.lock) is held by another change or was left behind by one that crashed. Run \`clikae doctor\`, then \`clikae settings apply claude $profile\` once it clears." ;;
        *) return 1 ;;
      esac
      [ "$_settings_rc" -ne 0 ] || log_info "Broad shell/file permissions applied for headless use; deny rules are advisory, not a sandbox. Use --no-template to skip."
    fi
  fi

  # #141: a new tank gets the fleet's shared hooks NOW, not at its first
  # launch. This is the whole point of the feature — the reported incident is
  # tanks recreated under new names that silently had no Stop hook, and a tank
  # you created five minutes ago is exactly the one you will not think to
  # check. Unlike the MCP list (which has to wait for the engine to write
  # .claude.json), settings.json is clikae's own file and already exists here.
  # No-op for an engine with no hooks layout, a solo tank, an empty store, or
  # a machine without jq (lib/core/fleet_hooks.sh).
  fleet_hooks_prelaunch "$cli" "$profile" "$d"

  # #95: seed a new tank from $CLIKAE_HOME/template/<engine>/, if the operator
  # ever set one up (theme/config files it copies, settings.json keys it
  # merges — see _init_apply_template above). Hooks and MCP servers are NOT
  # part of this: those are already fleet-wide via `hooks share` / `mcp
  # share` and fleet_hooks_prelaunch just above, so duplicating them here
  # would be a second, competing writer. Same --no-template escape hatch as
  # the permissions template; CLIKAE_NO_PERMISSIONS_TEMPLATE does not gate
  # this (its name says permissions, on purpose).
  [ "$no_template" -eq 1 ] || _init_apply_template "$cli" "$profile" "$d"

  # A new tank joins the machine's default Soul group, if one was ever set.
  # The board shows FLEET vs SOLO and nothing else, so a tank that quietly has no
  # brain is indistinguishable from one that does — which is how a person ends up
  # believing every tank shares, because that is exactly what the board told them.
  # Consent still exists: it was given once, at the first `memory share`. With no
  # default set (a fresh install, or someone who never opted in) nothing happens.
  local _soul_default
  _soul_default="$(soul_default_group 2>/dev/null || true)"
  if [ -n "$_soul_default" ]; then
    # Self-invoke rather than source memory.sh: it is a 500-line command that
    # brings its own resolution/guard machinery, and `init` only needs the verb.
    #
    # Deliberately NOT --yes. The cross-account guard only fires once a tank has a
    # known account label, and a tank created seconds ago has not logged in yet —
    # so there is nothing to cross and the join is clean. If the label IS already
    # known and differs, the guard refuses non-interactively and this falls to the
    # warning below: the tank keeps its own memory and you decide. That keeps
    # "crossing your own accounts is announced" true, which --yes would have
    # quietly broken.
    "$CLIKAE_BIN" memory share "$_soul_default" "$cli" "$profile" >/dev/null 2>&1 \
      && log_pass "joined the shared memory group '$_soul_default' (clikae solo $cli $profile to keep it separate)" \
      || log_warn "could not join the memory group '$_soul_default' — this tank starts with its own memory."
  fi

  if [ "$with_alias" -eq 1 ]; then
    # alias.sh isn't auto-sourced by the dispatcher; load it on demand.
    # shellcheck source=./alias.sh
    source "$CLIKAE_LIB/commands/alias.sh"
    cmd_alias "$cli" "$profile"
  else
    log_info "No alias added. Run \`clikae alias $cli $profile\` to add one."
  fi

  echo ""
  log_bold "Next steps:"
  echo "  clikae $cli $profile           # switch to it and run"
  echo "  clikae app $cli $profile       # generate a macOS .app launcher"
  echo "  clikae alias $cli $profile     # add a shell alias"
}
