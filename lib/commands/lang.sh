# shellcheck shell=bash
# lib/commands/lang.sh — `clikae lang [code]` — show or set the interface language.
#
#   clikae lang            print the active language + the choices
#   clikae lang ja         set Japanese (persists to $CLIKAE_HOME/lang)
#   clikae lang zh-TW      set Traditional Chinese
#   clikae lang en         set English
#
# The dashboard's `h` key flips the same persisted preference live; this command
# is the scriptable / non-interactive way to set it. i18n_set + clikae_lang live
# in lib/core/i18n.sh.

_lang_display() {
  case "$1" in
    en-US) echo "English (en-US)" ;;
    ja-JP) echo "日本語 (ja-JP)" ;;
    zh-TW) echo "繁體中文 (zh-TW)" ;;
    *)     echo "$1" ;;
  esac
}

cmd_lang() {
  i18n_load "$(clikae_lang)"   # T_* aren't loaded at source time; this command prints them
  case "${1:-}" in
    -h|--help)
      cat <<'EOF'
Usage: clikae lang [en-US | ja-JP | zh-TW]

Show or set clikae's interface language for the dashboard and prompts.
With no argument it prints the active language and the available choices.

  clikae lang            show the current language
  clikae lang ja-JP      switch to 日本語
  clikae lang zh-TW      switch to 繁體中文
  clikae lang en-US      switch to English

Short forms (en, ja, zh) and locale strings (ja_JP.UTF-8) are accepted too.
Resolution when unset: $CLIKAE_LANG env > this saved choice > $LANG/$LC_ALL >
en-US. The dashboard's `h` key flips the same preference live (no restart).
EOF
      return 0 ;;
  esac

  if [ -z "${1:-}" ]; then
    local cur; cur="$(clikae_lang)"
    log_info "$(printf "$T_LANG_SET" "$(_lang_display "$cur")")"
    log_dim  "Choices:  en-US · ja-JP · zh-TW    (set with: clikae lang <code>)"
    return 0
  fi

  # Call DIRECTLY (not in $()): i18n_set reloads the T_* globals in this shell, so
  # the confirmation below is already in the new language. A subshell would lose
  # that reload and the cache reset.
  if i18n_set "$1"; then
    log_ok "$(printf "$T_LANG_SET" "$(_lang_display "$CLIKAE_LANG_RESOLVED")")"
  else
    log_fail "$(printf "$T_LANG_UNKNOWN" "$1")"
  fi
}
