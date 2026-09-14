# shellcheck shell=bash
# lib/commands/init.sh — `clikae init <engine> <tank> [--alias]`

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
  --no-template  Skip applying the permissions template to a new claude tank.
                 Same effect as CLIKAE_NO_PERMISSIONS_TEMPLATE=1.
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
    local d
    d="$(profile_dir "$cli" "$profile")"
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

  local d
  d="$(ensure_profile --create "$cli" "$profile")"
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
        *) return 1 ;;
      esac
      [ "$_settings_rc" -ne 0 ] || log_info "Broad shell/file permissions applied for headless use; deny rules are advisory, not a sandbox. Use --no-template to skip."
    fi
  fi

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
