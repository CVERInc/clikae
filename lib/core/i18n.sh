# shellcheck shell=bash
# shellcheck disable=SC2034  # T_* are a string table consumed by the renderers in
#                              lib/commands/home.sh (and others), not within this file.
# lib/core/i18n.sh — clikae's tiny, bash-3.2-safe localisation layer.
#
# WHY no associative arrays: macOS ships bash 3.2, which has none. So instead of
# a `declare -A` table we load every UI string into plain `T_*` globals once per
# render (English first as the base, then the active language OVERRIDES the keys
# it translates). Two wins: (a) automatic fallback — any key a language hasn't
# translated keeps its English value; (b) zero subshells per redraw — the TUI
# reads `$T_CONTINUE`, not `$(t continue)`, so repainting on every keypress stays
# cheap.
#
# Languages: en-US (base), ja-JP (日本語), zh-TW (繁體中文 — Traditional only,
# never Simplified). Full locale codes, not the short forms. The katakana
# "ｷﾘｶｴ" rides along in the ja-JP wordmark (T_WORDMARK) as a bonus for Japanese
# users; en-US / zh-TW just show "clikae".
#
# Resolution order (first hit wins): $CLIKAE_LANG env > persisted $CLIKAE_HOME/lang
# > $LC_ALL / $LANG > en. The `h` key in the dashboard and `clikae lang <code>`
# both call i18n_set to persist + reload live.

# Map any locale-ish string to one of clikae's three full codes.
_i18n_normalize() {
  case "$1" in
    zh-TW|zh_TW*|zh-Hant*|zh*Hant*|*Hant*) echo "zh-TW" ;;
    zh*)                                    echo "zh-TW" ;;  # we only ship Traditional
    ja|ja_*|ja-*|*japanese*|*Japanese*)     echo "ja-JP" ;;
    *)                                      echo "en-US" ;;
  esac
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
  CLIKAE_LANG_RESOLVED="$(_i18n_normalize "${raw:-en-US}")"
  printf '%s' "$CLIKAE_LANG_RESOLVED"
}

# i18n_load <code> — populate every T_* global. English first (the base/fallback),
# then override per language. Call again to switch languages live.
i18n_load() {
  local lang="$1"

  # --- English (en-US) base (also the fallback for any untranslated key) -------
  # board
  T_WORDMARK="clikae"                          # ja-JP adds the ｷﾘｶｴ katakana bonus
  T_TAGLINE1="switch any CLI between accounts"
  T_TAGLINE2="— swap the tank, keep burning"
  T_CONTINUE="Continue"
  T_RESUME="resume"
  T_ENTER_RESUME="Enter to resume"
  T_ACTIVE_HERE="active here"
  T_ALSO_AVAILABLE="Also available"
  T_NO_TANK_DEFAULT="no tank yet — opens default"
  T_AGY_NOTE="single-account · opens ~/.gemini directly"
  T_LAUNCH="launch"
  T_MORE="more"
  T_INCOGNITO="Incognito"
  T_OVER_QUOTA="over quota"
  T_OR_ALIAS="or your alias"
  T_OVER_QUOTA_HINT="carry your session on to the next tank:  clikae to"
  # footer key hints
  T_K_MOVE="move"
  T_K_OPEN="open"
  T_K_RELAY="relay"
  T_K_NEW="new"
  T_K_RENAME="rename"
  T_K_DELETE="delete"
  T_K_QUIT="quit"
  T_K_FILTER="filter"
  T_K_HELP="help"
  T_K_LANG="language"
  T_K_TOPBOTTOM="top/bottom"
  T_K_JUMP="jump to Nth"
  T_K_REORDER="reorder"
  T_K_AUTO="autonomy"
  T_K_INCOGNITO="incognito"
  # welcome
  T_NO_TANKS_YET="No tanks yet"
  T_ENGINES_HERE="engines, here:"
  T_ENGINES_SUPPORTED="engines supported"
  T_NONE_DETECTED="(none detected on PATH here)"
  T_FILL_FIRST="Fill your first tank:"
  T_CURIOUS_DEMO="Curious?  clikae demo"
  # resume submenu (item 5)
  T_RESUME_TITLE="This session — what next?"
  T_RESUME_OPT_RESUME="Resume where you left off"
  T_RESUME_OPT_SWITCH="Switch to this tank (fresh session)"
  T_CANCEL="Cancelled."
  # new-tank / rename prompts
  T_NEWTANK_TITLE="New tank — pick a CLI"
  T_NEWTANK_PROFILE="Tank name for %s (e.g. work, personal): "
  T_NEWTANK_CANCEL="Cancelled — no tank created."
  T_NEWTANK_NONAME="Cancelled — no name given."
  T_RENAME_FOR="Rename"
  T_RENAME_CURRENTLY="currently"
  T_RENAME_NEW="New name: "
  T_RENAME_CANCEL="Cancelled — name unchanged."
  T_RENAME_NO_AGY="agy tanks can't be renamed (it's a global ~/.gemini target, not a per-shell engine)."
  # filter / help / misc
  T_FILTER_PROMPT="filter: "
  T_FILTER_NONE="no matches"
  T_HELP_TITLE="clikae — keys"
  T_HELP_DISMISS="any key to close"
  T_BACK="back to clikae"
  T_PICKER_HINT="up/down move · Enter select · q cancel"
  T_LANG_SET="Interface language: %s"
  T_LANG_UNKNOWN="Unknown language: %s  (use: en-US | ja-JP | zh-TW)"

  case "$lang" in
    ja-JP)
      T_WORDMARK="clikae  ｷﾘｶｴ"
      T_TAGLINE1="どの CLI でもアカウントを切り替え"
      T_TAGLINE2="— タンクを替えて、走り続ける"
      T_CONTINUE="続き"
      T_RESUME="再開"
      T_ENTER_RESUME="Enter で再開"
      T_ACTIVE_HERE="使用中"
      T_ALSO_AVAILABLE="その他"
      T_NO_TANK_DEFAULT="タンク未作成 — 既定で開く"
      T_AGY_NOTE="シングルアカウント · ~/.gemini を直接開く"
      T_LAUNCH="起動"
      T_MORE="その他"
      T_INCOGNITO="シークレット"
      T_OVER_QUOTA="上限到達"
      T_OR_ALIAS="エイリアス"
      T_OVER_QUOTA_HINT="次のタンクへセッションを引き継ぐ:  clikae to"
      T_K_MOVE="移動"
      T_K_OPEN="開く"
      T_K_RELAY="引継ぎ"
      T_K_NEW="新規"
      T_K_RENAME="名前変更"
      T_K_DELETE="削除"
      T_K_QUIT="終了"
      T_K_FILTER="絞込"
      T_K_HELP="ヘルプ"
      T_K_LANG="言語"
      T_K_TOPBOTTOM="先頭/末尾"
      T_K_JUMP="N番へ移動"
      T_K_REORDER="並べ替え"
      T_K_AUTO="自動度"
      T_K_INCOGNITO="シークレット"
      T_NO_TANKS_YET="タンクがまだありません"
      T_ENGINES_HERE="エンジンを検出:"
      T_ENGINES_SUPPORTED="エンジン対応"
      T_NONE_DETECTED="(PATH 上に見つかりません)"
      T_FILL_FIRST="最初のタンクを作成:"
      T_CURIOUS_DEMO="お試し:  clikae demo"
      T_RESUME_TITLE="このセッション — どうする?"
      T_RESUME_OPT_RESUME="続きから再開する"
      T_RESUME_OPT_SWITCH="このタンクに切り替え(新規セッション)"
      T_CANCEL="キャンセルしました。"
      T_NEWTANK_TITLE="新規タンク — CLI を選択"
      T_NEWTANK_PROFILE="%s のタンク名 (例: work, personal): "
      T_NEWTANK_CANCEL="キャンセル — タンク未作成。"
      T_NEWTANK_NONAME="キャンセル — 名前が未入力。"
      T_RENAME_FOR="名前変更"
      T_RENAME_CURRENTLY="現在"
      T_RENAME_NEW="新しい名前: "
      T_RENAME_CANCEL="キャンセル — 名前は変更されません。"
      T_RENAME_NO_AGY="agy タンクは名前変更できません(~/.gemini を使うグローバル対象のため)。"
      T_FILTER_PROMPT="絞込: "
      T_FILTER_NONE="一致なし"
      T_HELP_TITLE="clikae — キー操作"
      T_HELP_DISMISS="任意のキーで閉じる"
      T_BACK="clikae に戻る"
      T_PICKER_HINT="上下で移動 · Enter で選択 · q で中止"
      T_LANG_SET="表示言語: %s"
      T_LANG_UNKNOWN="不明な言語: %s  (en-US | ja-JP | zh-TW)"
      ;;
    zh-TW)
      T_TAGLINE1="在帳號之間切換任何 CLI"
      T_TAGLINE2="— 換個油箱，繼續燃燒"
      T_CONTINUE="續上次"
      T_RESUME="接回"
      T_ENTER_RESUME="Enter 接回"
      T_ACTIVE_HERE="使用中"
      T_ALSO_AVAILABLE="也可開啟"
      T_NO_TANK_DEFAULT="尚無油箱 — 開預設"
      T_AGY_NOTE="單帳號 · 直接開 ~/.gemini"
      T_LAUNCH="啟動"
      T_MORE="更多"
      T_INCOGNITO="無痕"
      T_OVER_QUOTA="已達上限"
      T_OR_ALIAS="或你的別名"
      T_OVER_QUOTA_HINT="把 session 接到下一顆油箱：clikae to"
      T_K_MOVE="移動"
      T_K_OPEN="開啟"
      T_K_RELAY="接力"
      T_K_NEW="新增"
      T_K_RENAME="改名"
      T_K_DELETE="刪除"
      T_K_QUIT="離開"
      T_K_FILTER="篩選"
      T_K_HELP="說明"
      T_K_LANG="語言"
      T_K_TOPBOTTOM="頂/底"
      T_K_JUMP="跳到第 N 個"
      T_K_REORDER="排序"
      T_K_AUTO="自主度"
      T_K_INCOGNITO="無痕"
      T_NO_TANKS_YET="尚無油箱"
      T_ENGINES_HERE="個引擎，就在這："
      T_ENGINES_SUPPORTED="個引擎支援"
      T_NONE_DETECTED="(此處 PATH 上未偵測到)"
      T_FILL_FIRST="裝滿你的第一個油箱："
      T_CURIOUS_DEMO="好奇？  clikae demo"
      T_RESUME_TITLE="這個 session — 接下來？"
      T_RESUME_OPT_RESUME="接回上次離開的進度"
      T_RESUME_OPT_SWITCH="換到這個油箱（開新局）"
      T_CANCEL="已取消。"
      T_NEWTANK_TITLE="新增油箱 — 選一個 CLI"
      T_NEWTANK_PROFILE="%s 的油箱名稱（例：work、personal）："
      T_NEWTANK_CANCEL="已取消 — 未建立油箱。"
      T_NEWTANK_NONAME="已取消 — 未輸入名稱。"
      T_RENAME_FOR="改名"
      T_RENAME_CURRENTLY="目前"
      T_RENAME_NEW="新名稱："
      T_RENAME_CANCEL="已取消 — 名稱未變更。"
      T_RENAME_NO_AGY="agy 油箱無法改名（它是吃 ~/.gemini 的全域對象，不是 per-shell 引擎）。"
      T_FILTER_PROMPT="篩選："
      T_FILTER_NONE="無相符項目"
      T_HELP_TITLE="clikae — 按鍵"
      T_HELP_DISMISS="按任意鍵關閉"
      T_BACK="回到 clikae"
      T_PICKER_HINT="上下移動 · Enter 選擇 · q 取消"
      T_LANG_SET="介面語言：%s"
      T_LANG_UNKNOWN="未知語言：%s （可用：en-US | ja-JP | zh-TW）"
      ;;
  esac
}

# i18n_summary <ntanks> <nclis> — the board's "N tanks across M engines" line,
# localised (and English-pluralised). Echoes the phrase, no trailing newline.
i18n_summary() {
  local n="$1" m="$2"
  case "$(clikae_lang)" in
    ja-JP) printf '%s タンク・%s エンジン' "$n" "$m" ;;
    zh-TW) printf '%s 個油箱、%s 個引擎' "$n" "$m" ;;
    *)     printf '%s tank%s across %s engine%s' \
             "$n" "$([ "$n" = 1 ] || echo s)" "$m" "$([ "$m" = 1 ] || echo s)" ;;
  esac
}

# i18n_set <code> — validate, persist to $CLIKAE_HOME/lang, and reload live.
# Returns 1 on an unknown code (caller decides how to message). Accepts the three
# canonical codes plus common locale spellings; anything else is rejected so a
# typo can't silently fall through to English. Side-effect only (no echo) so it
# MUST be called directly, not in $(...): a subshell would lose the reloaded T_*
# globals and the reset cache. The canonical code lands in CLIKAE_LANG_RESOLVED.
i18n_set() {
  local want="$1" norm=""
  case "$want" in
    en-US|en|en_*|en-*|EN*|english|English)               norm="en-US" ;;
    ja-JP|ja|ja_*|ja-*|japanese|Japanese|日本語)          norm="ja-JP" ;;
    zh-TW|zh_TW*|zh-Hant*|zh*Hant*|zh|zh_*|zh-*|繁體中文|台|台灣) norm="zh-TW" ;;
    *) return 1 ;;
  esac
  mkdir -p "$CLIKAE_HOME" 2>/dev/null || true
  printf '%s\n' "$norm" > "$CLIKAE_HOME/lang" 2>/dev/null || true
  CLIKAE_LANG_RESOLVED="$norm"
  i18n_load "$norm"
}

# i18n_cycle — en-US -> ja-JP -> zh-TW -> en-US. Persists + reloads. Echoes the
# new code. Used by the dashboard's `h` key for a live, no-restart language flip.
i18n_cycle() {
  local cur next
  cur="$(clikae_lang)"
  case "$cur" in
    en-US) next="ja-JP" ;;
    ja-JP) next="zh-TW" ;;
    zh-TW) next="en-US" ;;
    *)     next="en-US" ;;
  esac
  i18n_set "$next"
  printf '%s' "$next"
}

# Initialise at source time. CLIKAE_HOME is set by bin/clikae before this is
# sourced, so the persisted preference is honoured from the first string.
i18n_load "$(clikae_lang)"
