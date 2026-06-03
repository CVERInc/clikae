# shellcheck shell=bash
# lib/commands/env.sh — `clikae env <engine> <tank>`: print the export lines that
# put THIS shell on a tank, for `eval`. The explicit escape hatch (the bare
# switch / aliases / .app run the engine with a prefix assignment that never
# reaches the parent shell, so `to`/`status` can't see it afterwards).
#
#   eval "$(clikae env claude work)"   # now this shell IS on claude/work
#   claude                              # uses it; clikae to / status detect it

cmd_env() {
  local cli="" tank=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage: eval "$(clikae env <engine> <tank>)"

Print `export VAR="value"` lines that put the CURRENT shell on a tank, so the
engine's own command (and `clikae to` / `clikae status`) see it. Meant to be
eval'd — printing alone changes nothing.

  eval "$(clikae env claude work)"   # this shell is now on claude/work
  clikae status claude               # → work
  clikae to personal                 # carries this shell's session onward

A flag-strategy engine (no config env var, e.g. vercel) has nothing to export
and reports so. Plain `clikae <engine> <tank>` is still the one-shot way to just
run the engine; `env` is for staying on a tank across several commands.
EOF
        return 0 ;;
      --) shift; break ;;
      -*) log_fail "Unknown flag: $1" ;;
      *)  if [ -z "$cli" ]; then cli="$1"
          elif [ -z "$tank" ]; then tank="$1"
          else log_fail "Unexpected argument: $1"
          fi
          shift ;;
    esac
  done

  [ -n "$cli" ]  || log_fail "Missing <engine>. Usage: eval \"\$(clikae env <engine> <tank>)\""
  [ -n "$tank" ] || log_fail "Missing <tank>. Usage: eval \"\$(clikae env <engine> <tank>)\""
  validate_name cli "$cli"
  validate_name profile "$tank"
  load_adapter "$cli"   # agy/antigravity get a tailored "it's global" error here
  local d
  d="$(ensure_profile --require "$cli" "$tank")"

  # adapter_export_env prints KEY=VALUE lines; re-emit as quoted `export`s so a
  # value with spaces survives the eval.
  local kv key val printed=0
  while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    key="${kv%%=*}"; val="${kv#*=}"
    printf 'export %s=%s\n' "$key" "$(_env_shquote "$val")"
    printed=1
  done <<EOF
$(adapter_export_env "$d")
EOF

  if [ "$printed" -eq 0 ]; then
    log_err "'$cli' has no config env var to export (it's a flag-strategy engine)."
    log_dim "Just run it directly:  clikae $cli $tank"
    return 1
  fi

  # If stdout is a terminal the user almost certainly forgot the eval — nudge on
  # stderr so it never pollutes the eval'd output.
  if [ -t 1 ]; then
    log_dim "tip: this only takes effect when eval'd —  eval \"\$(clikae env $cli $tank)\"" >&2
  fi
}

# Single-quote a value for safe eval (wrap in '...', escaping embedded quotes).
_env_shquote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
