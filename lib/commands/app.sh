# shellcheck shell=bash
# lib/commands/app.sh — `clikae app <engine> <tank>` (macOS only)
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
      # No token substitution: the script reads its command from a TRUSTED config
      # file (written into the bundle by cmd_app after osacompile) via `path to me`,
      # so Ghostty never shows the "-e" "Allow execute" dialog. The shell_cmd/title
      # flow into that conf, not this script.
      tmpl_content="$(cat "$tmpl")"
      ;;
    *)
      log_fail "Unknown --terminal '$target'. Choose: terminal, iterm2, ghostty."
      ;;
  esac

  printf '%s\n' "$tmpl_content" > "$out"
}

# Write the trusted Ghostty config into a freshly-compiled .app bundle. The
# launcher's AppleScript points `--config-file` here (via `path to me`), so Ghostty
# runs `command` WITHOUT the -e "Allow execute" dialog. The command carries no
# bundle-relative path, so the .app stays valid if moved. Args:
#   <app_path> <title> <shell_cmd>
_app_write_ghostty_conf() {
  local app_path="$1" title="$2" shell_cmd="$3"
  local resdir="$app_path/Contents/Resources"
  mkdir -p "$resdir"
  {
    printf 'title = %s\n' "$title"
    # Login shell so PATH has Homebrew + node bins; single-quote shell_cmd (it can
    # contain  KEY="dir"  pairs) so Ghostty's command parser keeps it as one arg.
    printf 'command = /bin/zsh -lc %s\n' "$(_app_shell_squote "$shell_cmd")"
  } > "$resdir/clikae-ghostty.conf"
}

cmd_app() {
  local cli="" profile="" force=0 out_dir="" board=0 target="${CLIKAE_TERMINAL:-terminal}"
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force) force=1; shift ;;
      -o|--out)   out_dir="$2"; shift 2 ;;
      -t|--terminal) target="$2"; shift 2 ;;
      --board)    board=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: clikae app <engine> <tank> [--terminal <app>] [--force] [--out <dir>]
       clikae app --board        [--terminal <app>] [--force] [--out <dir>]

Generate a macOS .app launcher. Double-clicking it opens a new terminal window.
With <engine> <tank> it opens that tank directly; with --board it opens the
clikae board (your menu of recent sessions + tanks) so you can pick from there.

Options:
  --board               Make a launcher for the clikae BOARD (no engine/tank) —
                        a single button that opens the menu.
  -t, --terminal <app>  Which terminal to open: terminal (default), iterm2,
                        ghostty. Default can also be set via $CLIKAE_TERMINAL.
  -f, --force           Overwrite an existing .app at the destination.
  -o, --out <dir>       Where to put the .app. Default: ~/Applications

The window's title is "<CLI> (<tank>)" (or "clikae" for --board) so you can tell
windows apart. The Ghostty launcher passes its command through a trusted config
file, so Ghostty never shows the "Allow Ghostty to execute…" dialog.

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

  local title shell_cmd app_name
  if [ "$board" -eq 1 ]; then
    [ -z "$cli$profile" ] || log_fail "--board opens the whole board — don't also pass an engine/tank."
    title="clikae"
    # Open the board; if you quit it (q), keep an interactive login shell rather
    # than closing the window. A login shell so PATH finds clikae + the engines.
    shell_cmd="clikae; exec zsh -i"
    app_name="clikae.app"
  else
    [ -n "$cli" ]     || log_fail "Missing <engine>. See: clikae app --help  (or --board for a menu launcher)"
    [ -n "$profile" ] || log_fail "Missing <tank>. See: clikae app --help"
    validate_name cli "$cli"
    validate_name profile "$profile"
    load_adapter "$cli"
    local d
    d="$(ensure_profile --require "$cli" "$profile")"
    title="${cli} (${profile})"
    # The shell command the launcher runs: [KEY="V" ...] <binary> [--flag <dir>].
    shell_cmd="$(adapter_command "$d")"
    app_name="${cli} (${profile}).app"
  fi

  [ -n "$out_dir" ] || out_dir="$HOME/Applications"
  mkdir -p "$out_dir"
  local app_path="$out_dir/$app_name"

  if [ -e "$app_path" ]; then
    if [ "$force" -eq 1 ]; then
      rm -rf "$app_path"
      log_info "Removed existing $app_path (--force)"
    else
      log_fail "$app_path already exists. Pass --force to overwrite."
    fi
  fi

  local tmp_dir tmp_scpt
  tmp_dir="$(mktemp -d -t clikae-launcher.XXXXXX)"
  tmp_scpt="$tmp_dir/launcher.applescript"
  _app_render_script "$tmp_scpt" "$target" "$shell_cmd" "$title"

  osacompile -o "$app_path" "$tmp_scpt"
  rm -rf "$tmp_dir"
  # Ghostty: drop the trusted config into the bundle the script reads via path-to-me,
  # then RE-SEAL. osacompile ad-hoc-signs the bundle; adding a Resource afterwards
  # breaks that seal ("a sealed resource is missing or invalid"), and on Apple
  # Silicon a broken signature makes macOS block the .app. Clear stray xattrs, then
  # re-sign ad-hoc so the conf is sealed in and the launcher opens cleanly.
  if [ "$target" = "ghostty" ]; then
    _app_write_ghostty_conf "$app_path" "$title" "$shell_cmd"
    xattr -cr "$app_path" 2>/dev/null || true
    if command -v codesign >/dev/null 2>&1; then
      codesign --force --sign - "$app_path" >/dev/null 2>&1 \
        || log_warn "Couldn't re-sign the .app — on Apple Silicon, allow it once in System Settings ▸ Privacy & Security."
    fi
  fi
  log_ok "Created $app_path"
  log_dim "  terminal: $target"
  log_dim "  title   : $title"
  log_dim "  runs    : $shell_cmd"
}
