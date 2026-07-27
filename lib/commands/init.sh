# shellcheck shell=bash
# lib/commands/init.sh — `clikae init <engine> <tank> [--alias]`

cmd_init() {
  local with_alias=0 cli="" profile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --alias) with_alias=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: clikae init <engine> <tank> [--alias]

Create a new tank (account/config) for an engine.

Arguments:
  <engine>   Engine name (a CLI with an adapter). Run `clikae adapters` to list.
  <tank>     Tank name. A-Z a-z 0-9 . _ - allowed.

Options:
  --alias    Also add a shell alias to your shell rc:
               <engine>-<tank>   (e.g. claude-work)

Example:
  clikae init claude work --alias       # then:  clikae claude work
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
