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

@test "T_* strings used as printf FORMATS carry exactly their expected placeholder, every language" {
  # ~10 call sites do `printf "$T_X" arg` — the string IS the format, so a
  # translation that adds a stray % (e.g. "50% done") corrupts output at
  # runtime. This pins the contract per language: exactly one placeholder of
  # the right kind, and no other % (write %% for a literal percent).
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/i18n.sh"
  local lang key fmt want stripped
  for lang in en-US ja-JP zh-TW; do
    i18n_load "$lang"
    for key in T_DRY_SEEN:%s T_LANG_SET:%s T_LANG_UNKNOWN:%s \
               T_RESUME_CARRY_PICK:%s T_RESUME_OPT_RELAY:%s T_RESUME_OPT_FORCE:%s \
               T_RESUME_DRY_TITLE:%s T_NEWTANK_PROFILE:%s T_RESUME_FOOTER:%d \
               T_UPDATE_NOW:%s; do
      want="${key#*:}"; key="${key%%:*}"
      eval "fmt=\"\$$key\""
      [[ "$fmt" == *"$want"* ]] || { echo "$lang $key: missing $want in: $fmt"; false; }
      # After removing literal %% and the one placeholder, no % may remain.
      stripped="${fmt//%%/}"
      stripped="${stripped/"$want"/}"
      [[ "$stripped" != *%* ]] || { echo "$lang $key: stray %% in: $fmt"; false; }
    done
  done
}
