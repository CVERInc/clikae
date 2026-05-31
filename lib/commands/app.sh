# shellcheck shell=bash
# lib/commands/app.sh — `clikae app <cli> <profile>` (macOS only)
#
# Generates a double-clickable .app that opens a new terminal window and runs the
# CLI with the given profile's env vars applied. The terminal can be Terminal.app
# (default), iTerm2, or Ghostty — pick with --terminal.

# Escape a string for embedding in an AppleScript double-quoted literal:
# backslash FIRST, then double-quote (order matters). Echoes the result.
# We substitute with bash parameter expansion, NOT sed — BSD/macOS sed strips
# backslashes from the replacement string and silently corrupts the script
# (see HANDOFF §4).
_app_applescript_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# POSIX single-quote a string for safe use as one shell word.
_app_shell_squote() {
  local s="${1//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

# Is a terminal app installed? Args: <App display name> <bundle id>.
# Checks the usual /Applications and ~/Applications paths, then Spotlight.
_app_terminal_installed() {
  local name="$1" bundle="$2"
  [ -d "/Applications/$name.app" ] && return 0
  [ -d "$HOME/Applications/$name.app" ] && return 0
  if command -v mdfind >/dev/null 2>&1; then
    [ -n "$(mdfind "kMDItemCFBundleIdentifier == '$bundle'" 2>/dev/null | head -n 1)" ] && return 0
  fi
  return 1
}

# Render the AppleScript for a target into $1 (a file path).
# Args: <out_file> <target> <shell_cmd> <title>
_app_render_script() {
  local out="$1" target="$2" shell_cmd="$3" title="$4"
  local tmpl tmpl_content

  case "$target" in
    terminal)
      tmpl="$CLIKAE_LIB/templates/launcher.applescript.tmpl"
      [ -f "$tmpl" ] || log_fail "Missing template: $tmpl"
      tmpl_content="$(cat "$tmpl")"
      tmpl_content="${tmpl_content//@SHELL_CMD@/$(_app_applescript_escape "$shell_cmd")}"
      tmpl_content="${tmpl_content//@TITLE@/$(_app_applescript_escape "$title")}"
      ;;
    iterm2)
      _app_terminal_installed "iTerm" "com.googlecode.iterm2" \
        || log_fail "iTerm2 not found. Install it, or pick another --terminal (terminal, ghostty)."
      tmpl="$CLIKAE_LIB/templates/launcher.iterm2.applescript.tmpl"
      [ -f "$tmpl" ] || log_fail "Missing template: $tmpl"
      tmpl_content="$(cat "$tmpl")"
      tmpl_content="${tmpl_content//@SHELL_CMD@/$(_app_applescript_escape "$shell_cmd")}"
      tmpl_content="${tmpl_content//@TITLE@/$(_app_applescript_escape "$title")}"
      ;;
    ghostty)
      _app_terminal_installed "Ghostty" "com.mitchellh.ghostty" \
        || log_fail "Ghostty not found. Install it, or pick another --terminal (terminal, iterm2)."
      tmpl="$CLIKAE_LIB/templates/launcher.ghostty.applescript.tmpl"
      [ -f "$tmpl" ] || log_fail "Missing template: $tmpl"
      # Ghostty can't open a window from the CLI on macOS — go through `open`.
      # Title before -e (which consumes the rest as the command to run).
      local launch_cmd
      launch_cmd="open -na Ghostty.app --args --title=$(_app_shell_squote "$title") -e /bin/zsh -lc $(_app_shell_squote "$shell_cmd")"
      tmpl_content="$(cat "$tmpl")"
      tmpl_content="${tmpl_content//@LAUNCH_CMD@/$(_app_applescript_escape "$launch_cmd")}"
      ;;
    *)
      log_fail "Unknown --terminal '$target'. Choose: terminal, iterm2, ghostty."
      ;;
  esac

  printf '%s\n' "$tmpl_content" > "$out"
}

cmd_app() {
  local cli="" profile="" force=0 out_dir="" target="${CLIKAE_TERMINAL:-terminal}"
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force) force=1; shift ;;
      -o|--out)   out_dir="$2"; shift 2 ;;
      -t|--terminal) target="$2"; shift 2 ;;
      -h|--help)
        cat <<'EOF'
Usage: clikae app <cli> <profile> [--terminal <app>] [--force] [--out <dir>]

Generate a macOS .app launcher for a profile. Double-clicking the .app opens a
new terminal window with the given profile active.

Options:
  -t, --terminal <app>  Which terminal to open: terminal (default), iterm2,
                        ghostty. Default can also be set via $CLIKAE_TERMINAL.
  -f, --force           Overwrite an existing .app at the destination.
  -o, --out <dir>       Where to put the .app. Default: ~/Applications

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
  local title
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

  # The shell command the launcher runs: [KEY="V" ...] <binary> [--flag <dir>].
  local shell_cmd
  shell_cmd="$(adapter_command "$d")"

  local tmp_dir tmp_scpt
  tmp_dir="$(mktemp -d -t clikae-launcher.XXXXXX)"
  tmp_scpt="$tmp_dir/launcher.applescript"
  _app_render_script "$tmp_scpt" "$target" "$shell_cmd" "$title"

  osacompile -o "$app_path" "$tmp_scpt"
  rm -rf "$tmp_dir"
  log_ok "Created $app_path"
  log_dim "  terminal: $target"
  log_dim "  title   : $title"
  log_dim "  runs    : $shell_cmd"
}
