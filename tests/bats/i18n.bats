#!/usr/bin/env bats
# tests/bats/i18n.bats — the localisation layer (lib/core/i18n.sh) + `clikae lang`.
# Covers: resolution order, set/persist, normalisation of short forms & locale
# strings, rejection of garbage, and that the dashboard renders per-locale.

load '../helpers'

@test "clikae lang with no arg shows the active language (en-US default)" {
  # helpers pins CLIKAE_LANG=en-US; unset it here to test the file/LANG fallback.
  unset CLIKAE_LANG
  run clikae lang
  [ "$status" -eq 0 ]
  [[ "$output" == *"en-US"* ]] || false
}

@test "clikae lang sets and persists the choice" {
  unset CLIKAE_LANG
  run clikae lang zh-TW
  [ "$status" -eq 0 ]
  [ "$(cat "$CLIKAE_HOME/lang")" = "zh-TW" ]
  # A fresh invocation honours the persisted choice.
  run clikae lang
  [[ "$output" == *"zh-TW"* ]] || false
}

@test "the set confirmation is shown IN the new language (no subshell stale T_*)" {
  unset CLIKAE_LANG
  run clikae lang zh-TW
  [[ "$output" == *"介面語言"* ]] || false   # zh-TW string, not the en/ja one
  run clikae lang ja
  [[ "$output" == *"表示言語"* ]] || false   # ja string
}

@test "short forms and locale strings normalise to full codes" {
  unset CLIKAE_LANG
  clikae lang ja
  [ "$(cat "$CLIKAE_HOME/lang")" = "ja-JP" ]
  clikae lang en
  [ "$(cat "$CLIKAE_HOME/lang")" = "en-US" ]
  CLIKAE_LANG=ja_JP.UTF-8 run clikae lang
  [[ "$output" == *"ja-JP"* ]] || false
}

@test "an unknown language is rejected (non-zero, no persist change)" {
  unset CLIKAE_LANG
  clikae lang en
  run clikae lang klingon
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown language"* ]] || false
  [ "$(cat "$CLIKAE_HOME/lang")" = "en-US" ]   # unchanged
}

@test "CLIKAE_LANG env overrides the persisted file" {
  unset CLIKAE_LANG
  clikae lang en
  CLIKAE_LANG=zh-TW run clikae lang
  [[ "$output" == *"zh-TW"* ]] || false
}

@test "the dashboard renders the continue headline per-locale" {
  clikae init claude a
  local work="$TEST_HOME/w"; mkdir -p "$work"
  local slug; slug="$(printf '%s' "$work" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  local d="$CLIKAE_HOME/profiles/claude/a/projects/$slug"; mkdir -p "$d"
  printf '{"type":"ai-title","aiTitle":"Hi","sessionId":"a"}\n' > "$d/aaa00000-0000-0000-0000-000000000000.jsonl"
  cd "$work"
  CLIKAE_LANG=zh-TW run clikae
  [[ "$output" == *"接續"* ]] || false
  CLIKAE_LANG=ja-JP run clikae
  [[ "$output" == *"再開"* ]] || false
  CLIKAE_LANG=en-US run clikae
  [[ "$output" == *"Resume"* ]] || false
}

@test "the katakana wordmark shows ONLY in ja-JP" {
  clikae init claude work
  CLIKAE_LANG=ja-JP run clikae
  [[ "$output" == *"ｷﾘｶｴ"* ]] || false
  CLIKAE_LANG=en-US run clikae
  [[ "$output" != *"ｷﾘｶｴ"* ]] || false
  [[ "$output" == *"clikae"* ]] || false
  CLIKAE_LANG=zh-TW run clikae
  [[ "$output" != *"ｷﾘｶｴ"* ]] || false
}

@test "the summary line is localised (engines/tanks wording)" {
  clikae init claude work
  clikae init codex cheap
  CLIKAE_LANG=zh-TW run clikae
  [[ "$output" == *"個油箱"* ]] || false
  [[ "$output" == *"個引擎"* ]] || false
  CLIKAE_LANG=en-US run clikae
  [[ "$output" == *"tanks across"* ]] || false
}

# --- mechanical completeness (the nine-locale standard's CI clause) -----------
# The KEY list is extracted from lib/i18n/en-US.sh (the canonical table: one
# `T_KEY="…"` per line at column 0) and the LOCALE list from the resolver's
# _i18n_locales — both mechanically, so adding a locale line to the resolver
# (plus its lib/i18n/<code>.sh) pulls it into enforcement with ZERO test edits,
# and a partial translation can never merge silently.

# _i18n_sig <string> — the printf-placeholder signature: literal %% stripped,
# then every %<letter> in order (e.g. "%s%d"). Empty for display-only strings.
_i18n_sig() {
  printf '%s' "$1" | sed 's/%%//g' | grep -oE '%[a-zA-Z]' | tr -d '\n' || true
}

# _i18n_has_stray_pct <string> — 0 if a % remains after removing %% and %<letter>.
_i18n_has_stray_pct() {
  case "$(printf '%s' "$1" | sed 's/%%//g; s/%[a-zA-Z]//g')" in
    *%*) return 0 ;; *) return 1 ;;
  esac
}

@test "completeness: every en-US key exists non-empty in every locale, printf placeholders matching (mechanical extraction)" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/i18n.sh"

  # (a) the canonical key list, from en-US's file
  local keys n_keys
  keys="$(grep -E '^T_[A-Z0-9_]+=' "$_CLIKAE_I18N_DIR/en-US.sh" | cut -d= -f1 | sort)"
  n_keys="$(printf '%s\n' "$keys" | grep -c .)"
  [ "$n_keys" -ge 80 ] || { echo "key extraction broke: only $n_keys keys"; false; }

  # (b) the locale list, from the resolver (the SSOT)
  local locales n_locs
  locales="$(_i18n_locales)"
  n_locs="$(printf '%s\n' "$locales" | grep -c .)"
  [ "$n_locs" -ge 3 ] || { echo "locale extraction broke: only $n_locs locales"; false; }
  printf '%s\n' "$locales" > "$TEST_HOME/locales"
  printf '%s\n' "$keys"    > "$TEST_HOME/en.keys"

  # en-US placeholder signature per key (KEY<TAB>SIG), from the file alone
  local key v
  ( # shellcheck source=/dev/null
    . "$_CLIKAE_I18N_DIR/en-US.sh"
    while IFS= read -r key; do
      eval "v=\${$key-}"
      printf '%s\t%s\n' "$key" "$(_i18n_sig "$v")"
    done < "$TEST_HOME/en.keys"
  ) > "$TEST_HOME/en.sig"

  # (c)+(d) per locale: every key defined IN ITS OWN FILE (the en-US fallback
  # must not mask a hole), non-empty, placeholder-parity with en-US, no stray %
  # on format keys — and no orphan key en-US doesn't know.
  local loc
  : > "$TEST_HOME/fails"
  while IFS= read -r loc; do
    ( set +e
      f="$_CLIKAE_I18N_DIR/$loc.sh"
      [ -f "$f" ] || { echo "$loc: MISSING file lib/i18n/$loc.sh"; exit 0; }
      # shellcheck source=/dev/null
      . "$f" || { echo "$loc: lib/i18n/$loc.sh failed to source"; exit 0; }
      grep -E '^T_[A-Z0-9_]+=' "$f" | cut -d= -f1 | sort > "$TEST_HOME/loc.keys"
      comm -23 "$TEST_HOME/en.keys" "$TEST_HOME/loc.keys" | sed "s/^/$loc: MISSING key /"
      comm -13 "$TEST_HOME/en.keys" "$TEST_HOME/loc.keys" | sed "s/^/$loc: ORPHAN key (not in en-US) /"
      while IFS= read -r key; do
        eval "v=\${$key-}"
        [ -n "$v" ] || { echo "$loc: EMPTY $key"; continue; }
        want="$(grep "^$key$(printf '\t')" "$TEST_HOME/en.sig" | cut -f2)"
        got="$(_i18n_sig "$v")"
        [ "$got" = "$want" ] || echo "$loc: $key placeholders [$got] != en-US [$want]"
        if [ -n "$want" ] && _i18n_has_stray_pct "$v"; then
          echo "$loc: $key has a stray % (printf format — write %% for a literal percent): $v"
        fi
      done < <(comm -12 "$TEST_HOME/en.keys" "$TEST_HOME/loc.keys")
    ) >> "$TEST_HOME/fails"
  done < "$TEST_HOME/locales"
  if [ -s "$TEST_HOME/fails" ]; then cat "$TEST_HOME/fails"; false; fi
}

@test "the resolver maps regions/scripts correctly (zh by SCRIPT; unknown → empty, not en)" {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/i18n.sh"
  # Traditional Chinese, wherever it's read:
  [ "$(_i18n_normalize zh_TW.UTF-8)" = "zh-TW" ]
  [ "$(_i18n_normalize zh_HK)" = "zh-TW" ]
  [ "$(_i18n_normalize zh-Hant-TW)" = "zh-TW" ]
  # Simplified inputs read zh-Hans (shipped); a bare `zh` names no script, so it
  # keeps the incumbent default, Traditional.
  [ "$(_i18n_normalize zh_CN)" = "zh-Hans" ]
  [ "$(_i18n_normalize zh_SG.UTF-8)" = "zh-Hans" ]
  [ "$(_i18n_normalize zh-Hans-CN)" = "zh-Hans" ]
  [ "$(_i18n_normalize zh)" = "zh-TW" ]
  # A regional variant of a shipped locale needs no case line — the generic
  # language-subtag rule catches it.
  [ "$(_i18n_normalize pt_PT.UTF-8)" = "pt-BR" ]
  [ "$(_i18n_normalize fr_CA)" = "fr-FR" ]
  [ "$(_i18n_normalize ko_KR.UTF-8)" = "ko-KR" ]
  # The generic language-subtag rule (no per-locale case line needed):
  [ "$(_i18n_normalize ja_JP.UTF-8)" = "ja-JP" ]
  [ "$(_i18n_normalize EN_us)" = "en-US" ]
  # Unknown stays EMPTY — clikae_lang falls back to en-US, i18n_set rejects.
  [ -z "$(_i18n_normalize it_IT)" ]
  [ -z "$(_i18n_normalize klingon)" ]
  [ -z "$(_i18n_normalize '')" ]
}

@test "clikae lang lists every supported locale (menu derives from _i18n_locales, no second list)" {
  unset CLIKAE_LANG
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/i18n.sh"
  run clikae lang
  [ "$status" -eq 0 ]
  local loc
  for loc in $(_i18n_locales); do
    [[ "$output" == *"$loc"* ]] || { echo "missing $loc in: $output"; false; }
  done
}
