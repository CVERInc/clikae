# shellcheck shell=bash
# lib/commands/app.sh — `clikae app <cli> <profile>` (macOS only)
#
# Generates a double-clickable .app that opens a new Terminal window and runs
# the CLI with the given profile's env vars applied.

cmd_app() {
  local cli="" profile="" force=0 out_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force) force=1; shift ;;
      -o|--out)   out_dir="$2"; shift 2 ;;
      -h|--help)
        cat <<'EOF'
Usage: clikae app <cli> <profile> [--force] [--out <dir>]

Generate a macOS .app launcher for a profile. Double-clicking the .app opens a
new Terminal window with the given profile active.

Options:
  -f, --force     Overwrite an existing .app at the destination.
  -o, --out <dir> Where to put the .app. Default: ~/Applications

The window's title is set to "<CLI> (<profile>)" so you can tell windows apart.

macOS only.
EOF
        return 0
        ;;
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

  [ "$(uname -s)" = "Darwin" ] || log_fail "clikae app is macOS-only. Use \`clikae alias\` on Linux/Windows."
  command -v osacompile >/dev/null 2>&1 || log_fail "osacompile not found (it's a macOS built-in — this is unexpected)."

  [ -n "$cli" ]     || log_fail "Missing <cli>. See: clikae app --help"
  [ -n "$profile" ] || log_fail "Missing <profile>. See: clikae app --help"
  validate_name cli "$cli"
  validate_name profile "$profile"

  load_adapter "$cli"
  local d
  d="$(ensure_profile --require "$cli" "$profile")"
  local binary title
  binary="$(adapter_meta_cli_binary)"
  title="${cli} (${profile})"

  [ -n "$out_dir" ] || out_dir="$HOME/Applications"
  mkdir -p "$out_dir"
  local app_name="${cli} (${profile}).app"
  local app_path="$out_dir/$app_name"

  if [ -e "$app_path" ]; then
    if [ "$force" -eq 1 ]; then
      rm -rf "$app_path"
      log_info "Removed existing $app_path (--force)"
    else
      log_fail "$app_path already exists. Pass --force to overwrite."
    fi
  fi

  # Build the shell command the .app will run in Terminal.
  # It's: KEY1="V1" KEY2="V2" ... <binary>
  local shell_cmd=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local key="${line%%=*}" val="${line#*=}"
    shell_cmd="$shell_cmd $key=\"$val\""
  done < <(adapter_export_env "$d")
  shell_cmd="${shell_cmd# } $binary"

  # AppleScript: open Terminal, run cmd, set custom title.
  local tmpl tmp_scpt
  tmpl="$CLIKAE_LIB/templates/launcher.applescript.tmpl"
  [ -f "$tmpl" ] || log_fail "Missing template: $tmpl"
  tmp_scpt="$(mktemp -t clikae-launcher.XXXXXX).applescript"

  # Substitute. The shell_cmd needs its " escaped to \" for AppleScript.
  local shell_cmd_escaped
  shell_cmd_escaped="${shell_cmd//\"/\\\"}"
  sed \
    -e "s|@SHELL_CMD@|${shell_cmd_escaped}|g" \
    -e "s|@TITLE@|${title}|g" \
    "$tmpl" > "$tmp_scpt"

  osacompile -o "$app_path" "$tmp_scpt"
  rm -f "$tmp_scpt"
  log_ok "Created $app_path"
  log_dim "  title: $title"
  log_dim "  runs : $shell_cmd"
}
