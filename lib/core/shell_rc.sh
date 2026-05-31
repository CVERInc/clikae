# shellcheck shell=bash
# lib/core/shell_rc.sh — detect the user's shell rc file and manage clikae-owned blocks.
#
# Managed blocks are wrapped with sentinels so we can find / remove them later:
#   # >>> clikae:<id> >>>
#   ... content ...
#   # <<< clikae:<id> <<<
#
# Where <id> is a stable identifier (e.g. "claude.work" for cli=claude profile=work).

# Print the detected rc file path.
detect_shell_rc() {
  local shell_name
  shell_name="$(basename "${SHELL:-/bin/bash}")"
  case "$shell_name" in
    zsh)
      printf '%s\n' "$HOME/.zshrc"
      ;;
    bash)
      # macOS: prefer .bash_profile if it exists; Linux: .bashrc
      if [ "$(uname -s)" = "Darwin" ] && [ -f "$HOME/.bash_profile" ]; then
        printf '%s\n' "$HOME/.bash_profile"
      else
        printf '%s\n' "$HOME/.bashrc"
      fi
      ;;
    fish)
      printf '%s\n' "$HOME/.config/fish/config.fish"
      ;;
    *)
      printf '%s\n' "$HOME/.profile"
      ;;
  esac
}

# detect_shell_kind -> the user's shell family: zsh | bash | fish | sh.
# Used where the SYNTAX (not just the rc path) differs — notably fish, which
# has no inline `VAR=val cmd` and a different alias form.
detect_shell_kind() {
  case "$(basename "${SHELL:-/bin/bash}")" in
    zsh)  printf 'zsh\n'  ;;
    bash) printf 'bash\n' ;;
    fish) printf 'fish\n' ;;
    *)    printf 'sh\n'   ;;
  esac
}

# Returns 0 if a block with the given id is present in the rc file.
rc_has_block() {
  local rc_file="$1" id="$2"
  [ -f "$rc_file" ] && grep -qF "# >>> clikae:$id >>>" "$rc_file"
}

# rc_wrap_block <id>  < content_on_stdin   -> sentinel-wrapped block on stdout.
# Single source of truth for the on-disk block format (used by rc_add_block and
# `clikae migrate`). Changing this format is a breaking change — see HANDOFF §7.
rc_wrap_block() {
  local id="$1"
  printf '\n# >>> clikae:%s >>>\n' "$id"
  cat
  printf '# <<< clikae:%s <<<\n' "$id"
}

# rc_add_block <rc_file> <id> < content_on_stdin
# Refuses to add if the block already exists; caller can rc_remove_block first.
rc_add_block() {
  local rc_file="$1" id="$2"
  if rc_has_block "$rc_file" "$id"; then
    log_fail "Block '$id' already exists in $rc_file. Remove it first."
  fi
  # Back up if file exists; otherwise create it (and any missing parent dir —
  # fish's ~/.config/fish/ may not exist yet).
  if [ -f "$rc_file" ]; then
    cp "$rc_file" "$rc_file.clikae.bak.$(date +%Y%m%d-%H%M%S)"
  else
    mkdir -p "$(dirname "$rc_file")"
    touch "$rc_file"
  fi
  rc_wrap_block "$id" >> "$rc_file"
}

# rc_remove_block <rc_file> <id>
rc_remove_block() {
  local rc_file="$1" id="$2"
  [ -f "$rc_file" ] || return 0
  rc_has_block "$rc_file" "$id" || return 0
  # Back up.
  cp "$rc_file" "$rc_file.clikae.bak.$(date +%Y%m%d-%H%M%S)"
  # Remove the block, including the sentinel lines.
  # Use awk since macOS sed is BSD-flavoured and harder to portable-script.
  local tmp
  tmp="$(mktemp)"
  awk -v id="$id" '
    BEGIN { skip=0 }
    $0 == "# >>> clikae:" id " >>>" { skip=1; next }
    $0 == "# <<< clikae:" id " <<<" { skip=0; next }
    skip == 0 { print }
  ' "$rc_file" > "$tmp"
  mv "$tmp" "$rc_file"
}
