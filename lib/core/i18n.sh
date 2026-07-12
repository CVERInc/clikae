# shellcheck shell=bash
# lib/core/i18n.sh — clikae's tiny, bash-3.2-safe localisation layer: the locale
# resolver, the supported-locale list, and the loader. The STRINGS live in
# lib/i18n/<locale>.sh (one file per locale; en-US is the canonical key list) —
# they ship with the body and load via a plain `source`: fast, offline, and a
# language switch can never fail on a download.
#
# WHY no associative arrays: macOS ships bash 3.2, which has none. So instead of
# a `declare -A` table we load every UI string into plain `T_*` globals once per
# render (English first as the base, then the active locale's file OVERRIDES
# every key). Two wins: (a) automatic fallback — any key a locale file doesn't
# define keeps its English value (a safety net; shipped locales must be complete,
# tests/bats/i18n.bats enforces it); (b) zero subshells per redraw — the TUI
# reads `$T_CONTINUE`, not `$(t continue)`, so repainting on every keypress
# stays cheap.
#
# Chinese is keyed by WRITING SYSTEM, not region: Traditional (zh-TW — also
# serves zh_HK / *Hant*) and Simplified (zh-Hans — zh_CN / zh_SG / *Hans*) are
# SEPARATE locales, each with its own file. A bare `zh` (no script named) reads
# Traditional — the incumbent default.
#
# Resolution order (first hit wins): $CLIKAE_LANG env > persisted $CLIKAE_HOME/lang
# > $LC_ALL / $LANG > en-US. The `l` key in the dashboard and `clikae lang <code>`
# both call i18n_set to persist + reload live.
#
# ⚠ Strings containing %s / %d are used as printf FORMATS (the placeholder is
# where the tank name / count lands). A translation must keep exactly en-US's
# placeholders in en-US's order, and write %% for a literal percent sign — a
# stray % corrupts the printf at runtime. tests/bats/i18n.bats pins this
# contract mechanically for every locale.

# Where the locale files live — computed from THIS file's location (lib/core/ →
# lib/i18n/), never from the environment: a stale exported CLIKAE_LIB (another
# clikae install on the machine, a sourced `clikae env`) must not redirect the
# string tables. Also makes i18n.sh sourceable standalone (tests, tools).
_CLIKAE_I18N_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../i18n" && pwd)"

# _i18n_locales — the supported-locale list, one full code per line. ⚠ SSOT:
# `clikae lang`'s choices, the board's `l` picker, AND the completeness test in
# tests/bats/i18n.bats all call THIS function — adding a locale line here (plus
# its lib/i18n/<code>.sh file) is picked up by all three with zero further
# edits. Keep en-US first (it is the base/fallback and the canonical key list).
# Full instructions: docs/adding-a-locale.md.
_i18n_locales() {
  printf '%s\n' \
    en-US \
    ja-JP \
    zh-TW \
    zh-Hans \
    ko-KR \
    es-ES \
    de-DE \
    fr-FR \
    pt-BR
}

# _i18n_normalize <locale-ish> — map any locale-ish string (a full code, a short
# form, a $LANG value like ja_JP.UTF-8, a human spelling) to a supported full
# code. Prints NOTHING for an unrecognised input: clikae_lang falls back to
# en-US, i18n_set rejects (so a typo can't silently switch you to English).
#
# A new locale usually needs NO line here: its exact code passes through the
# membership check, and regional variants (ko_KR → ko-KR, fr_CA → fr-FR) match
# through the generic language-subtag rule below. Only a script-split language
# (Chinese) or an extra human alias needs its own case line.
_i18n_normalize() {
  local raw="$1" low sub l
  # 1. An exact supported code passes through untouched.
  for l in $(_i18n_locales); do
    if [ "$raw" = "$l" ]; then printf '%s' "$l"; return 0; fi
  done
  low="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$low" in
    # 2. Chinese: split by SCRIPT, not region — Traditional reads zh-TW…
    zh_tw*|zh-tw*|*hant*|zh_hk*|zh-hk*|繁體中文|台|台灣) printf 'zh-TW'; return 0 ;;
    # …Simplified reads zh-Hans (Mainland + Singapore).
    zh_cn*|zh-cn*|zh_sg*|zh-sg*|*hans*|简体中文) printf 'zh-Hans'; return 0 ;;
    # A bare `zh` names no script, so it needs a default: Traditional, the
    # incumbent (clikae shipped zh-TW alone for its first three releases).
    zh*) printf 'zh-TW'; return 0 ;;
    # Human spellings that don't start with the language subtag:
    english)         printf 'en-US'; return 0 ;;
    *japanese*|日本語) printf 'ja-JP'; return 0 ;;
  esac
  # 3. Generic: match the language subtag against the supported list
  #    (ja_JP.UTF-8 → ja → ja-JP; works for future locales with no case line).
  sub="${low%%[._-]*}"
  if [ -n "$sub" ]; then
    for l in $(_i18n_locales); do
      if [ "$sub" = "${l%%-*}" ]; then printf '%s' "$l"; return 0; fi
    done
  fi
  return 0   # unrecognised → empty output; the caller decides fallback/reject
}

# clikae_lang -> the resolved code, cached in CLIKAE_LANG_RESOLVED for the process.
clikae_lang() {
  if [ -n "${CLIKAE_LANG_RESOLVED:-}" ]; then printf '%s' "$CLIKAE_LANG_RESOLVED"; return 0; fi
  local raw=""
  if   [ -n "${CLIKAE_LANG:-}" ];                 then raw="$CLIKAE_LANG"
  elif [ -f "$CLIKAE_HOME/lang" ];                then raw="$(cat "$CLIKAE_HOME/lang" 2>/dev/null)"
  elif [ -n "${LC_ALL:-}" ];                      then raw="$LC_ALL"
  elif [ -n "${LANG:-}" ];                        then raw="$LANG"
  fi
  CLIKAE_LANG_RESOLVED="$(_i18n_normalize "${raw:-}")"
  [ -n "$CLIKAE_LANG_RESOLVED" ] || CLIKAE_LANG_RESOLVED="en-US"
  printf '%s' "$CLIKAE_LANG_RESOLVED"
}

# i18n_load <code> — populate every T_* global: the en-US base first (also the
# fallback for any undefined key), then the active locale's file overrides.
# Both are plain `source`s of files shipped in lib/i18n/. Call again to switch
# languages live.
i18n_load() {
  local lang="$1"
  # shellcheck source=/dev/null
  . "$_CLIKAE_I18N_DIR/en-US.sh"
  if [ "$lang" != "en-US" ] && [ -f "$_CLIKAE_I18N_DIR/$lang.sh" ]; then
    # shellcheck source=/dev/null
    . "$_CLIKAE_I18N_DIR/$lang.sh"
  fi
}

# i18n_set <code> — validate, persist to $CLIKAE_HOME/lang, and reload live.
# Returns 1 on an unknown code (caller decides how to message). Accepts every
# supported code plus the spellings _i18n_normalize understands; anything else
# is rejected so a typo can't silently fall through to English. Side-effect only
# (no echo) so it MUST be called directly, not in $(...): a subshell would lose
# the reloaded T_* globals and the reset cache. The canonical code lands in
# CLIKAE_LANG_RESOLVED.
i18n_set() {
  local want="$1" norm=""
  norm="$(_i18n_normalize "$want")"
  [ -n "$norm" ] || return 1
  mkdir -p "$CLIKAE_HOME" 2>/dev/null || true
  printf '%s\n' "$norm" > "$CLIKAE_HOME/lang" 2>/dev/null || true
  CLIKAE_LANG_RESOLVED="$norm"
  i18n_load "$norm"
}

# NOT initialised at source time: loading ~120 keys ×(base+override) plus the
# clikae_lang subshell costs ~2ms on EVERY invocation, and only the TUI-ish
# commands read T_* at all (home.sh — which resume.sh sources — plus lang and
# list; dry_store's and targets/' T_* uses are reached only via home). Those
# entry points call i18n_load "$(clikae_lang)" themselves; the ~30 other
# commands (env, switch, to, status, burn, …) skip the cost entirely.
# (i18n_summary — the board's "N tanks across M engines" line — is a FUNCTION
# defined by the locale files themselves: en-US.sh ships the pluralising
# English fallback, a locale may override it. It rides along with i18n_load.)
