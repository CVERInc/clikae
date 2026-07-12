# shellcheck shell=bash
# lib/commands/lang.sh — `clikae lang [code]` — show or set the interface language.
#
#   clikae lang            print the active language + the choices
#   clikae lang ja         set Japanese (persists to $CLIKAE_HOME/lang)
#   clikae lang zh-TW      set Traditional Chinese
#   clikae lang en         set English
#
# The dashboard's `l` key flips the same persisted preference live; this command
# is the scriptable / non-interactive way to set it. i18n_set + clikae_lang live
# in lib/core/i18n.sh — and so does _i18n_locales, the ONE list every choice
# below derives from (no second hardcoded locale list anywhere).

# _lang_display <code> — "English (en-US)"-style label. The endonym is the
# locale file's own T_LANG_NAME (a required key), extracted by pattern so we
# can label ANY locale without switching the live language.
_lang_display() {
  local name
  name="$(sed -n 's/^T_LANG_NAME="\([^"]*\)".*/\1/p' "$_CLIKAE_I18N_DIR/$1.sh" 2>/dev/null)"
  if [ -n "$name" ]; then echo "$name ($1)"; else echo "$1"; fi
}

# _lang_choices — "en-US · ja-JP · zh-TW", generated from the resolver's list.
_lang_choices() {
  local out="" l
  for l in $(_i18n_locales); do out="${out:+$out · }$l"; done
  printf '%s' "$out"
}

cmd_lang() {
  i18n_load "$(clikae_lang)"   # T_* aren't loaded at source time; this command prints them
  case "${1:-}" in
    -h|--help)
      cat <<'EOF'
Usage: clikae lang [<locale>]

Show or set clikae's interface language for the dashboard and prompts.
With no argument it prints the active language and every available choice
(the list comes from the locale files shipped in lib/i18n/).

  clikae lang            show the current language + the choices
  clikae lang ja-JP      switch to 日本語
  clikae lang zh-TW      switch to 繁體中文
  clikae lang en-US      switch to English

Short forms (en, ja, zh) and locale strings (ja_JP.UTF-8) are accepted too.
Resolution when unset: $CLIKAE_LANG env > this saved choice > $LANG/$LC_ALL >
en-US. The dashboard's `l` key flips the same preference live (no restart).
EOF
      return 0 ;;
  esac

  if [ -z "${1:-}" ]; then
    local cur; cur="$(clikae_lang)"
    log_info "$(printf "$T_LANG_SET" "$(_lang_display "$cur")")"
    log_dim  "Choices:  $(_lang_choices)    (set with: clikae lang <code>)"
    return 0
  fi

  # Call DIRECTLY (not in $()): i18n_set reloads the T_* globals in this shell, so
  # the confirmation below is already in the new language. A subshell would lose
  # that reload and the cache reset.
  if i18n_set "$1"; then
    log_ok "$(printf "$T_LANG_SET" "$(_lang_display "$CLIKAE_LANG_RESOLVED")")"
  else
    log_fail "$(printf "$T_LANG_UNKNOWN" "$1" "$(_lang_choices)")"
  fi
}
