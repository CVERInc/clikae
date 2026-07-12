# shellcheck shell=bash
# shellcheck disable=SC2034  # T_* are a string table consumed by the renderers.
# lib/i18n/zh-TW.sh — 繁體中文（Traditional Chinese）. Chinese is keyed by WRITING
# SYSTEM, not region: this file serves zh_TW / zh_HK / anything *Hant*; Simplified
# (zh-Hans — zh_CN / zh_SG) is a SEPARATE locale file, arriving later (until it
# ships, the resolver reads any other zh as zh-TW). Loaded OVER the en-US base by
# i18n_load and must define every key lib/i18n/en-US.sh defines
# (tests/bats/i18n.bats enforces it, including printf placeholder parity).
# Same file contract as en-US.sh: one `T_KEY="value"` per line at column 0,
# %s/%d kept in en-US's order, %% for a literal percent.

T_LANG_NAME="繁體中文"

# board
T_WORDMARK="clikae"                          # deliberately the plain wordmark (the katakana bonus is ja-JP-only)
T_TAGLINE1="在帳號之間切換任何 CLI"
T_TAGLINE2="— 換個油箱，繼續燃燒"
T_CONTINUE="接續 (Resume)"
T_RESUME_FOOTER="共 %d 個會話 · 按 [R] 搜尋或查看全部"
T_TANKS="油箱"
T_SOLO_SECTION="單飛 (Solo)"
T_LANG_PICK="選擇介面語言"
T_RESUME="接回"
T_ENTER_RESUME="Enter 接回"
T_ALSO_AVAILABLE="也可開啟"
T_NO_TANK_DEFAULT="尚無油箱 — 開預設"
T_AGY_NOTE="單帳號 · 全域登入（所有 shell 共用）"
T_AGY_BURN_NOTE="agy 登入是全域的（同時只一個帳號，無法並行）— 'clikae burn agy <tank>' 現在能在燒乾時自動接力到下一個油箱（Keychain 攜帶登入，不必 OAuth）；也能用 'agy -p' 在當前帳號跑 headless。"
T_LAUNCH="啟動"
T_MORE="更多"
T_OVER_QUOTA="已達上限"
T_OVER_QUOTA_HINT="把 session 接到下一顆油箱：clikae to"
# footer key hints
T_K_MOVE="移動"
T_K_OPEN="開啟"
T_K_RELAY="接力"
T_K_NEW="新增"
T_K_RENAME="改名"
T_K_DELETE="刪除"
T_K_SOLO="單飛／歸隊（移出車隊 — 不接力／burn／共享）"
T_K_MEMORY="記憶（Soul）— 共享／隔離這個油箱的腦"
T_MEM_TITLE="記憶（Soul）"
T_MEM_OPT_SHARE="共享進一個 group…"
T_MEM_OPT_ISOLATE="隔離（用自己的記憶）"
T_MEM_OPT_STATUS="狀態（顯示共享）"
T_MEM_SHARE_FOR="共享記憶"
T_MEM_GROUP_PROMPT="group 名稱："
T_MEM_NOGROUP="沒有輸入 group — 已取消。"
T_K_QUIT="離開"
T_K_FILTER="篩選"
T_K_CLEANUP="清除"
T_K_CLEAN="清理 session 資料 — 釋放磁碟空間"
T_CLEAN_SECT_REDUNDANT="重複資料（可安全刪除）"
T_CLEAN_SECT_OLD="超過 %s 天未使用"
T_CLEAN_SECT_MIN="%s MB 以上"
T_CLEAN_SECT_BIG="很大但最近用過 — 由你決定"
T_K_HELP="說明"
T_K_LANG="語言"
T_K_TOPBOTTOM="頂/底"
T_K_JUMP="跳到第 N 個"
T_K_REORDER="排序"
T_K_AUTO="自主度"
T_K_INCOGNITO="無痕"
# welcome
T_NO_TANKS_YET="尚無油箱"
T_ENGINES_HERE="個引擎，就在這："
T_ENGINES_SUPPORTED="個引擎支援"
T_NONE_DETECTED="(此處 PATH 上未偵測到)"
T_FILL_FIRST="裝滿你的第一個油箱："
T_CURIOUS_DEMO="好奇？  clikae demo"
# resume submenu
T_RESUME_TITLE="這個 session — 接下來？"
T_RESUME_OPT_RESUME="接回上次離開的進度"
T_RESUME_OPT_SWITCH="這顆油箱、開新局（不接舊進度）"
T_RESUME_DRY_TITLE="%s 已燒乾 — 接下來？"
T_RESUME_OPT_RELAY="接到 %s 繼續"
T_RESUME_OPT_FORCE="硬接回 %s（會立刻撞限額）"
T_RESUME_OPT_CARRY="接著這段、換到另一顆油箱"
T_RESUME_CARRY_PICK="帶著 %s 換油箱 —— 選一顆繼續"
T_RESUME_WHICH_TANK="要接回哪顆油箱？"
T_UPDATE_AVAIL="有新版！"
T_UPDATE_NOTES="更新說明："
T_UPDATE_NOW="立即更新（執行 \`%s\`）"
T_UPDATE_SHOW="顯示更新指令"
T_UPDATE_SKIP="略過"
T_UPDATE_SKIP_VER="略過此版，有更新版再提醒"
T_UPDATE_DONE="已更新 —— 重新執行 clikae 即可生效。"
T_UPDATE_FAILED="更新指令失敗 —— 請自行執行，或查看 release 頁面。"
T_UPDATE_MANUAL="用你的安裝方式更新 clikae，或從這裡取得："
T_DRY_SEEN="擷取於 %s"
# new-tank / rename prompts
T_NEWTANK_TITLE="新增油箱 — 選一個 CLI"
T_NEWTANK_PROFILE="%s 的油箱名稱（例：work、personal）："
T_NEWTANK_CANCEL="已取消 — 未建立油箱。"
T_NEWTANK_NONAME="已取消 — 未輸入名稱。"
T_RENAME_FOR="改名"
T_RENAME_NEW="新名稱："
T_RENAME_CANCEL="已取消 — 名稱未變更。"
# filter / help / misc
T_FILTER_PROMPT="篩選："
T_FILTER_NONE="無相符項目"
T_HELP_TITLE="clikae — 按鍵"
T_HELP_AGY="agy (Antigravity) 是 power 模式：'n' → agy 或 'clikae init agy <名稱>'，會接管 ~/.gemini（會先問你）。"
T_DOTS_TITLE="燈號 = 油況"
T_DOT_READY="可燒"
T_DOT_DRY="乾（超限）"
T_DOT_WEEK="本週用量（BETA）"
T_DOT_NONE="無讀數"
T_HELP_DISMISS="按任意鍵關閉"
T_PICKER_HINT="上下移動 · Enter 選擇 · q 取消"
T_LANG_SET="介面語言：%s"
T_LANG_UNKNOWN="未知語言：%s （可用：%s）"

# Chinese measures with 個, no plural forms — override the English summary.
i18n_summary() {
  printf '%s 個油箱、%s 個引擎' "$1" "$2"
}
