# shellcheck shell=bash
# lib/commands/handoff.sh — `clikae handoff <cli> [<profile>] [--out <file>]`
#
# Produce a portable handoff brief from the *current directory's* most recent
# session under a profile — so when a tank runs dry, the next tank (any profile,
# model, or vendor) can pick up instead of starting blind. See lib/core/handoff.sh.
#
# Read-only: it never touches the source session or any profile.

cmd_handoff() {
  local cli="" profile="" got_profile=0 out="" summarizer="" to=""
  local -a positionals=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage: clikae handoff <cli> [<profile>] [--to <cli>[/<profile>]]
                       [--out <file>] [--summarizer <cmd>]

Write a portable handoff brief from the current directory's most recent session
under <profile> — what's being worked on, what's done, what's next — so another
profile / model / vendor can continue instead of starting blind when a tank runs
dry. Read-only: the session is never modified.

With no <profile>, it uses whichever profile this shell is on (resolved from the
CLI's live env var, e.g. $CLAUDE_CONFIG_DIR).

How the brief is written:
  • If a summarizer is set, the session tail is piped to it and its output is the
    brief. Point it at a LOCAL or cheap model so it costs nothing on the dry tank:
        export CLIKAE_HANDOFF_SUMMARIZER='llm -m my-local-model'
        clikae handoff claude --summarizer 'llm -m my-local-model'
    The command reads the prompt+transcript on stdin and writes the brief to stdout.
  • With no summarizer, you get a dependency-free RAW extract (metadata + recent
    prompts), clearly labelled as raw.

Options:
  --to <target>           After writing the brief, hand it to another tank: start
                          the target seeded with the brief as its opening prompt.
                          This is how you switch model or vendor — e.g. a dry
                          Claude → Codex. Replaces this process (exec). <target> is:
                            <cli>/<profile>  another account of a switchable CLI
                                             (claude, codex)
                            antigravity      Google's agy — a single-account vendor
                                             you can hand off to but can't profile-switch
  --out <file>            Write the brief to <file> (also works with --to).
  --summarizer <cmd>      Summarizer command (overrides $CLIKAE_HANDOFF_SUMMARIZER).

Examples:
  clikae handoff claude                      # brief for this shell's claude profile
  clikae handoff claude work --out HANDOFF.md
  clikae handoff claude --to codex/work      # dry Claude → continue on Codex
  clikae handoff claude a --to claude/b      # hand off to another Claude account
  clikae handoff claude --to antigravity     # hand off to Antigravity (agy)
EOF
        return 0
        ;;
      --to)
        shift; [ $# -gt 0 ] || log_fail "--to needs a target (<cli>[/<profile>])"
        to="$1"; shift ;;
      --out)
        shift; [ $# -gt 0 ] || log_fail "--out needs a file path"
        out="$1"; shift ;;
      --summarizer)
        shift; [ $# -gt 0 ] || log_fail "--summarizer needs a command"
        summarizer="$1"; shift ;;
      --) shift; break ;;
      -*) log_fail "Unknown flag: $1" ;;
      *) positionals+=("$1"); shift ;;
    esac
  done

  [ "${#positionals[@]}" -ge 1 ] || log_fail "Missing <cli>. See: clikae handoff --help"
  cli="${positionals[0]}"
  validate_name cli "$cli"

  case "${#positionals[@]}" in
    1) ;;
    2) profile="${positionals[1]}"; got_profile=1 ;;
    *) log_fail "Too many arguments. Usage: clikae handoff $cli [<profile>]" ;;
  esac

  load_adapter "$cli"

  if ! declare -F adapter_transcript_path >/dev/null; then
    log_err "'$cli' has no session transcripts clikae knows how to read."
    log_dim "(handoff needs an adapter that defines adapter_transcript_path)"
    exit 1
  fi

  # Auto-detect <profile> from this shell's live env var when not given.
  if [ "$got_profile" -eq 0 ]; then
    local var strategy value
    var="$(adapter_meta_env_var)"
    strategy="$(adapter_meta_strategy)"
    value="${!var}"
    profile="$(resolve_active_profile "$cli" "$strategy" "$value")"
    if [ -z "$profile" ]; then
      log_err "Couldn't tell which profile '$cli' is on (\$$var is unset or not a clikae profile)."
      log_dim "Name it explicitly:  clikae handoff $cli <profile>"
      exit 1
    fi
    log_dim "Using current profile: $profile  (\$$var)" >&2
  fi

  validate_name profile "$profile"

  local dir transcript
  dir="$(ensure_profile --require "$cli" "$profile")"
  transcript="$(adapter_transcript_path "$dir" || true)"
  if [ -z "$transcript" ]; then
    log_err "No session for this directory under '$cli/$profile'."
    log_dim "(handoff summarises the conversation tied to \$PWD: $PWD)"
    exit 1
  fi

  # Plain mode: print or save the brief and we're done.
  if [ -z "$to" ]; then
    if [ -n "$out" ]; then
      handoff_render "$transcript" "$summarizer" > "$out" || log_fail "Failed to write $out"
      log_ok "Handoff written to $out"
    else
      handoff_render "$transcript" "$summarizer"
    fi
    return 0
  fi

  # --- --to: render the brief, then hand it to another tank ------------------
  # Render to a variable now, while the SOURCE adapter is loaded (we need its
  # transcript). Loading the target adapter below redefines the adapter_* funcs.
  local brief
  brief="$(handoff_render "$transcript" "$summarizer")" || log_fail "Failed to build the handoff brief."
  [ -n "$brief" ] || log_fail "The handoff brief came out empty; not handing off."

  if [ -n "$out" ]; then
    printf '%s\n' "$brief" > "$out" || log_fail "Failed to write $out"
    log_ok "Handoff also written to $out"
  fi

  # Parse <cli>[/<profile>].
  local to_cli="${to%%/*}" to_profile=""
  case "$to" in */*) to_profile="${to#*/}" ;; esac
  validate_name cli "$to_cli"

  local adapter_file="$CLIKAE_LIB/adapters/$to_cli.sh"
  local target_file="$CLIKAE_LIB/targets/$to_cli.sh"

  if [ -f "$adapter_file" ]; then
    # A switchable CLI: hand off to one of its profiles.
    load_adapter "$to_cli"
    if ! declare -F adapter_start_with_prompt >/dev/null; then
      log_err "'$to_cli' can't be started from a handoff brief."
      log_dim "(its adapter defines no adapter_start_with_prompt hook)"
      exit 1
    fi
    local to_dir=""
    if [ -n "$to_profile" ]; then
      validate_name profile "$to_profile"
      to_dir="$(ensure_profile --require "$to_cli" "$to_profile")"
    fi
    log_ok "Handing off: $cli/$profile → $to${to_dir:+ ($to_dir)}"
    log_dim "Starting $to_cli seeded with the brief; the source session is untouched."
    adapter_start_with_prompt "$to_dir" "$brief" "$@"

  elif [ -f "$target_file" ]; then
    # A launch-only target (single-account vendor, e.g. antigravity): no profiles.
    [ -z "$to_profile" ] || log_fail "'$to_cli' is a single-account handoff target — drop the /$to_profile."
    # shellcheck source=/dev/null
    source "$target_file"
    log_ok "Handing off: $cli/$profile → $(target_meta_name)"
    log_dim "Starting $(target_meta_binary) seeded with the brief; the source session is untouched."
    target_start_with_prompt "$brief" "$@"

  else
    log_err "Unknown handoff target: '$to_cli'."
    log_dim "Use an adapter (e.g. codex, optionally codex/<profile>) or a target (antigravity)."
    exit 1
  fi
}
