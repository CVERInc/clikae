#!/usr/bin/env bash
# make-launcher.sh: make a double-clickable macOS .app that opens clikae in a terminal.
# Not part of clikae itself. It needs only `clikae` on the PATH of a login shell.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: make-launcher.sh --board       [--terminal <app>] [--force] [--out <dir>]
       make-launcher.sh <engine> <tank> [--terminal <app>] [--force] [--out <dir>]

--board opens the clikae board. <engine> <tank> runs `clikae <engine> <tank>`.

  -t, --terminal <app>  terminal, iterm2, or ghostty. Defaults to the terminal
                        you are in when it is one of those, else Terminal.app.
  -f, --force           Replace an existing .app.
  -o, --out <dir>       Where to put the .app. Default: ~/Applications
EOF
}

die() { printf 'make-launcher: %s\n' "$1" >&2; exit 1; }

# AppleScript string body: backslash first, then double quote.
as_escape() {
  local s="${1//\\/\\\\}"
  printf '%s' "${s//\"/\\\"}"
}

bundle_path() { # <app name> <bundle id>
  local hit
  [ -d "/Applications/$1.app" ] && { printf '%s\n' "/Applications/$1.app"; return 0; }
  [ -d "$HOME/Applications/$1.app" ] && { printf '%s\n' "$HOME/Applications/$1.app"; return 0; }
  hit="$(mdfind "kMDItemCFBundleIdentifier == '$2'" 2>/dev/null | head -n 1 || true)"
  [ -n "$hit" ] && [ -d "$hit" ] && { printf '%s\n' "$hit"; return 0; }
  hit="$(osascript -e "POSIX path of (path to application id \"$2\")" 2>/dev/null || true)"
  hit="${hit%/}"
  [ -n "$hit" ] && [ -d "$hit" ] && { printf '%s\n' "$hit"; return 0; }
  return 1
}

default_terminal() {
  case "${TERM_PROGRAM:-}" in
    iTerm.app) bundle_path iTerm com.googlecode.iterm2 >/dev/null && { printf 'iterm2\n'; return 0; } ;;
    ghostty|Ghostty) bundle_path Ghostty com.mitchellh.ghostty >/dev/null && { printf 'ghostty\n'; return 0; } ;;
  esac
  printf 'terminal\n'
}

write_script() { # <file> <terminal> <command> <title>
  local cmd title
  cmd="$(as_escape "$3")"; title="$(as_escape "$4")"
  case "$2" in
    terminal)
      cat > "$1" <<EOF
on run
    tell application "Terminal"
        activate
        set newTab to do script "$cmd"
        set custom title of newTab to "$title"
    end tell
end run
EOF
      ;;
    iterm2)
      cat > "$1" <<EOF
on run
    tell application "iTerm"
        activate
        set newWindow to (create window with default profile command "$cmd")
        tell current session of newWindow
            set name to "$title"
        end tell
    end tell
end run
EOF
      ;;
    ghostty)
      # The command comes from a config file inside the bundle, which Ghostty trusts,
      # so it never shows its "Allow execute" dialog. That is also why the .app can move.
      cat > "$1" <<'EOF'
on run
    set confPath to (POSIX path of (path to me)) & "Contents/Resources/clikae-ghostty.conf"
    set theTitle to do shell script "sed -n 's/^title *= *//p' " & quoted form of confPath
    set theCmd to do shell script "sed -n 's/^command *= *//p' " & quoted form of confPath
    if application "Ghostty" is running then
        try
            tell application "Ghostty"
                set cfg to new surface configuration
                set command of cfg to theCmd
                set win to new window with configuration cfg
                delay 0.5
                perform action ("set_tab_title:" & theTitle) on (focused terminal of selected tab of win)
                activate window win
            end tell
            return
        on error
            do shell script "open -na Ghostty.app --args --config-file=" & quoted form of confPath
        end try
    else
        do shell script "open -a Ghostty.app --args --config-file=" & quoted form of confPath
    end if
end run
EOF
      ;;
  esac
}

install_icon() { # <app> <terminal>
  local name bundle icns src
  case "$2" in
    ghostty) name=Ghostty bundle=com.mitchellh.ghostty icns=Ghostty.icns ;;
    iterm2) name=iTerm bundle=com.googlecode.iterm2 icns=AppIcon.icns ;;
    *) name=Terminal bundle=com.apple.Terminal icns=Terminal.icns ;;
  esac
  src="$(bundle_path "$name" "$bundle" || true)/Contents/Resources/$icns"
  [ -f "$src" ] || return 0
  cp "$src" "$1/Contents/Resources/$icns" 2>/dev/null || return 0
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $icns" "$1/Contents/Info.plist" 2>/dev/null || true
  # The applet's asset-catalog icon outranks CFBundleIconFile unless it is removed.
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$1/Contents/Info.plist" 2>/dev/null || true
}

engine="" tank="" force=0 board=0 out="$HOME/Applications" terminal=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --board) board=1; shift ;;
    -f|--force) force=1; shift ;;
    -o|--out) [ $# -ge 2 ] || die "--out needs a directory"; out="$2"; shift 2 ;;
    -t|--terminal) [ $# -ge 2 ] || die "--terminal needs a name"; terminal="$2"; shift 2 ;;
    -*) die "unknown flag: $1" ;;
    *)
      if [ -z "$engine" ]; then engine="$1"
      elif [ -z "$tank" ]; then tank="$1"
      else die "unexpected argument: $1"; fi
      shift ;;
  esac
done

[ "$(uname -s)" = Darwin ] || die "macOS only. On Linux use: clikae alias <engine> <tank>"
[ -n "$terminal" ] || terminal="$(default_terminal)"
case "$terminal" in
  terminal) ;;
  iterm2) bundle_path iTerm com.googlecode.iterm2 >/dev/null || die "iTerm2 not found" ;;
  ghostty) bundle_path Ghostty com.mitchellh.ghostty >/dev/null || die "Ghostty not found" ;;
  *) die "unknown terminal '$terminal': choose terminal, iterm2, or ghostty" ;;
esac

if [ "$board" -eq 1 ]; then
  [ -z "$engine$tank" ] || die "--board takes no engine or tank"
  title=clikae cmd="clikae; exec zsh -i" name=clikae.app
else
  [ -n "$engine" ] && [ -n "$tank" ] || { usage >&2; exit 1; }
  for word in "$engine" "$tank"; do
    case "$word" in *[!A-Za-z0-9._-]*) die "not a tank name: $word" ;; esac
  done
  title="$engine ($tank)" cmd="clikae $engine $tank" name="$engine ($tank).app"
fi

mkdir -p "$out"
app="$out/$name"
if [ -e "$app" ]; then
  [ "$force" -eq 1 ] || die "$app already exists. Pass --force to replace it."
  rm -rf "$app"
fi

tmp="$(mktemp -d -t clikae-launcher.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
write_script "$tmp/launcher.applescript" "$terminal" "$cmd" "$title"
osacompile -o "$app" "$tmp/launcher.applescript"
install_icon "$app" "$terminal"
if [ "$terminal" = ghostty ]; then
  q=\'\\\'\'
  {
    printf 'title = %s\n' "$title"
    printf "command = /bin/zsh -lc '%s'\n" "${cmd//\'/$q}"
  } > "$app/Contents/Resources/clikae-ghostty.conf"
fi
# Resources changed after osacompile signed the bundle, so seal it again.
xattr -cr "$app" 2>/dev/null || true
codesign --force --sign - "$app" >/dev/null 2>&1 \
  || printf 'make-launcher: could not re-sign. Allow it once in System Settings > Privacy & Security.\n' >&2
printf 'Created %s\n  terminal: %s\n  runs: %s\n' "$app" "$terminal" "$cmd"
