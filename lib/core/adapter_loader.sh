# shellcheck shell=bash
# lib/core/adapter_loader.sh — load a CLI adapter and expose its hooks.
#
# An adapter is a bash script at lib/adapters/<cli>.sh that defines these functions:
#
#   adapter_meta_name           # human-readable name, echo-only
#   adapter_meta_cli_binary     # name of the binary to exec ("claude", "gh", ...)
#   adapter_meta_env_var        # primary env var (e.g. "CLAUDE_CONFIG_DIR")
#   adapter_meta_strategy       # one of: env-dir, env-file, env-var, flag, subcommand
#   adapter_meta_description    # one-line description
#
#   adapter_init <profile_dir>          # called once when a profile is created (optional, default no-op)
#   adapter_export_env <profile_dir>    # prints KEY=VALUE lines to be exported in shell/.app
#   adapter_run <profile_dir> [args...] # invoke the CLI with this profile

# Discover available adapter names by scanning lib/adapters/.
list_adapters() {
  local f name
  for f in "$CLIKAE_LIB"/adapters/*.sh; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .sh)"
    case "$name" in
      _*) continue ;;  # underscored files are templates/helpers
    esac
    printf '%s\n' "$name"
  done | sort
}

# Portable file mtime in epoch seconds. GNU stat FIRST: on Linux `stat -f` means
# --file-system (it silently prints garbage instead of failing), so the BSD form
# must never be tried first there. BSD/macoS stat rejects `-c`, failing cleanly to
# the fallback.
_clikae_mtime() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || echo 0; }

# newest_transcript_tank <engine>  ->  "<tank>\t<mtime-epoch>"  for the tank of
# <engine> whose transcript for $PWD is the newest, or nothing.
#
# Source-detection fallback for to/relay/handoff: the bare switch, the aliases,
# and the .app all run the engine with a PREFIX assignment (never exported), so
# `$CLAUDE_CONFIG_DIR` isn't in the parent shell after the engine exits — but the
# session we just had left a transcript in this directory. The tank with the
# newest transcript here is the one we were just working in. Runs in a subshell
# (loads the adapter) so it's safe to call across engines without leaking hooks.
newest_transcript_tank() {
  local engine="$1"
  [ -f "$CLIKAE_LIB/adapters/$engine.sh" ] || return 0
  local root; root="$(profiles_root)/$engine"
  [ -d "$root" ] || return 0
  (
    load_adapter "$engine" >/dev/null 2>&1 || exit 0
    declare -F adapter_transcript_path >/dev/null 2>&1 || exit 0
    local pdir tank tpath mt best="" best_mt=0
    for pdir in "$root"/*/; do
      [ -d "$pdir" ] || continue
      tank="$(basename "$pdir")"
      tpath="$(adapter_transcript_path "${pdir%/}" 2>/dev/null || true)"
      [ -n "$tpath" ] && [ -f "$tpath" ] || continue
      mt="$(_clikae_mtime "$tpath")"
      if [ "$mt" -gt "$best_mt" ]; then best_mt="$mt"; best="$tank"; fi
    done
    if [ -n "$best" ]; then printf '%s\t%s\n' "$best" "$best_mt"; fi
  )
}

# adapter_env_prefix <profile_dir>  -> one line: KEY="VAL" KEY2="VAL2" ...
# Renders the adapter's env vars as a shell-quoted prefix string, used to build
# both the alias body (`clikae alias`) and the .app command (`clikae app`).
# Requires the adapter to already be loaded (adapter_export_env in scope).
adapter_env_prefix() {
  local profile_dir="$1" prefix="" line key val
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    val="${line#*=}"
    prefix="$prefix $key=\"$val\""
  done < <(adapter_export_env "$profile_dir")
  printf '%s\n' "${prefix# }"
}

# adapter_cmd_suffix <profile_dir>  -> flag args to append AFTER the binary, or empty.
# For `flag`-strategy adapters (no config env var; the profile is selected by a
# CLI flag like vercel's `--global-config <dir>`). The adapter expresses this via
# an optional `adapter_flag_args <profile_dir>` hook that prints the (already
# shell-quoted) flag string. Env-strategy adapters don't define it -> empty.
# Used by the alias and .app generators alongside adapter_env_prefix.
adapter_cmd_suffix() {
  local profile_dir="$1"
  if declare -F adapter_flag_args >/dev/null; then
    adapter_flag_args "$profile_dir"
  fi
}

# adapter_command <profile_dir>  -> the full command string to run the CLI with
# this profile applied: "[ENV=VAL ...] <binary> [--flag <dir> ...]". Single line.
# This is what the alias body and the .app launcher both execute. Centralises the
# env-prefix + binary + flag-suffix assembly so the two generators stay in sync.
adapter_command() {
  local profile_dir="$1"
  local prefix suffix binary cmd
  prefix="$(adapter_env_prefix "$profile_dir")"
  suffix="$(adapter_cmd_suffix "$profile_dir")"
  binary="$(adapter_meta_cli_binary)"
  cmd="$binary"
  [ -n "$prefix" ] && cmd="$prefix $cmd"
  [ -n "$suffix" ] && cmd="$cmd $suffix"
  printf '%s\n' "$cmd"
}

# adapter_command_fish <profile_dir>  -> the run-command in FISH syntax.
# fish has no inline `VAR=val cmd` env-setting (it's a syntax error), so when
# the adapter contributes env vars we route through `env VAR=val … binary`,
# which fish executes fine. Flag-strategy adapters (no env prefix) are identical
# to the POSIX form. Used by `clikae alias` when the user's shell is fish.
adapter_command_fish() {
  local profile_dir="$1"
  local prefix suffix binary cmd
  prefix="$(adapter_env_prefix "$profile_dir")"
  suffix="$(adapter_cmd_suffix "$profile_dir")"
  binary="$(adapter_meta_cli_binary)"
  if [ -n "$prefix" ]; then
    cmd="env $prefix $binary"
  else
    cmd="$binary"
  fi
  [ -n "$suffix" ] && cmd="$cmd $suffix"
  printf '%s\n' "$cmd"
}

# adapter_label <profile_dir>  -> a human-readable account label for this
# profile (e.g. the logged-in email), or empty. Optional hook
# `adapter_account_label`; env adapters that can't tell simply don't define it.
# Requires the adapter to already be loaded.
adapter_label() {
  if declare -F adapter_account_label >/dev/null; then
    adapter_account_label "$1"
  fi
}

# Source the adapter file for <cli>. Fails if missing.
load_adapter() {
  local cli="$1"
  local f="$CLIKAE_LIB/adapters/$cli.sh"
  if [ ! -f "$f" ]; then
    # agy (Antigravity) is a known engine with no adapter on purpose: it ignores
    # env vars and hardcodes ~/.gemini, so it's switched globally, not per-shell
    # or per-config-dir. Give that guidance instead of the generic "no adapter"
    # whenever a generic path (env/app/alias/run/relay/migrate) is handed it.
    case "$cli" in
      agy|antigravity)
        log_err "agy (Antigravity) is global — clikae can't route it per-shell or per-config-dir."
        log_dim "Switch the machine-wide login with:  clikae agy <tank>   (see clikae agy --help)"
        exit 1 ;;
    esac
    log_err "No built-in adapter for '$cli'."
    log_dim "Available: $(list_adapters | paste -sd , - | sed 's/,/, /g')"
    log_dim "To add your own, see docs/adding-an-adapter.md"
    exit 1
  fi
  # Clear any adapter hooks left over from a previously loaded adapter before
  # sourcing this one. Required hooks get redefined by every adapter, but the
  # OPTIONAL ones (adapter_relay, adapter_start_with_prompt, …) would otherwise
  # leak across adapters — e.g. `clikae handoff <a> --to <b>` loads two adapters
  # in one process, and a hook b doesn't define must NOT be inherited from a.
  unset -f adapter_meta_name adapter_meta_cli_binary adapter_meta_env_var \
           adapter_meta_strategy adapter_meta_description \
           adapter_export_env adapter_run adapter_init \
           adapter_relay adapter_transcript_path adapter_start_with_prompt \
           adapter_account_label adapter_migrate_credentials adapter_flag_args \
           adapter_memory_dir \
           2>/dev/null || true

  # shellcheck source=/dev/null
  source "$f"
  # Verify required hooks exist.
  local fn
  for fn in adapter_meta_name adapter_meta_cli_binary adapter_meta_env_var \
            adapter_meta_strategy adapter_meta_description \
            adapter_export_env adapter_run; do
    if ! declare -F "$fn" >/dev/null; then
      log_fail "Adapter '$cli' is missing required function: $fn"
    fi
  done
}
