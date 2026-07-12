# shellcheck shell=bash
# shellcheck disable=SC2034  # T_* are a string table consumed by the renderers in
#                              lib/commands/home.sh (and others), not within this file.
# lib/i18n/en-US.sh — English (US). THE CANONICAL KEY LIST: every T_* key clikae
# knows is defined here, and every other lib/i18n/<locale>.sh must define all of
# them (tests/bats/i18n.bats enforces key × locale completeness mechanically).
#
# FILE CONTRACT (the test and `clikae lang` extract from this file by pattern):
#   - one `T_KEY="value"` per line, at column 0, double quotes;
#   - %s / %d are printf placeholders — a translation must keep exactly the same
#     placeholders in the same order, and write %% for a literal percent sign
#     (a stray % corrupts the printf at runtime);
#   - command lines, paths, sizes and other copy-paste tokens stay technical —
#     see docs/adding-a-locale.md for the graded-translation doctrine.

T_LANG_NAME="English"                        # this locale's endonym, shown in `clikae lang`

# board
T_WORDMARK="clikae"                          # ja-JP adds the ｷﾘｶｴ katakana bonus
T_TAGLINE1="switch any CLI between accounts"
T_TAGLINE2="— swap the tank, keep burning"
T_CONTINUE="Resume"
T_RESUME_FOOTER="%d sessions total · Press [R] to see all / search"
T_TANKS="Tanks"
T_SOLO_SECTION="Solo"
T_LANG_PICK="Interface language"
T_RESUME="resume"
T_ENTER_RESUME="Enter to resume"
T_ALSO_AVAILABLE="Also available"
T_NO_TANK_DEFAULT="no tank yet — opens default"
T_AGY_NOTE="single-account · global login (one account, all shells)"
T_AGY_BURN_NOTE="agy login is global (one account at a time, never two in parallel) — 'clikae burn agy <tank>' can reroute it sequentially on dry (Keychain carry, no OAuth needed), or run it headless on the active account via 'agy -p'."
T_LAUNCH="launch"
T_MORE="more"
T_OVER_QUOTA="over quota"
T_OVER_QUOTA_HINT="carry your session on to the next tank:  clikae to"
# footer key hints
T_K_MOVE="move"
T_K_OPEN="open"
T_K_RELAY="relay"
T_K_NEW="new"
T_K_RENAME="rename"
T_K_DELETE="delete"
T_K_SOLO="solo / un-solo (out of the fleet — no relay/burn/share)"
T_K_MEMORY="memory (Soul) — share / isolate this tank's brain"
T_MEM_TITLE="Memory (Soul)"
T_MEM_OPT_SHARE="share into a group…"
T_MEM_OPT_ISOLATE="isolate (its own memory)"
T_MEM_OPT_STATUS="status (show sharing)"
T_MEM_SHARE_FOR="Share memory for"
T_MEM_GROUP_PROMPT="Group name: "
T_MEM_NOGROUP="No group named — cancelled."
T_K_QUIT="quit"
T_K_FILTER="filter"
T_K_CLEANUP="cleanup"
T_K_CLEAN="clean up session data — free disk space"
# `clikae clean` section headings (T_CLEAN_SECT_OLD/_MIN are printf formats)
T_CLEAN_SECT_REDUNDANT="Redundant (safe)"
T_CLEAN_SECT_OLD="Untouched for %s+ days"
T_CLEAN_SECT_MIN="%s MB or larger"
T_CLEAN_SECT_BIG="Big but recent — your call"
# `clikae clean` runtime strings: candidate row labels, the dry-run/no-tty
# preview summary, the interactive picker's chrome, and its own arg-validation
# errors. (The `-h`/`--help` usage block stays English, like every sibling
# command's --help — see docs/adding-a-locale.md's graded-translation split.)
T_CLEAN_LBL_STALE="stale copy (kept: %s)"
T_CLEAN_LBL_ORPHAN="orphaned subagent data"
T_CLEAN_LBL_DIVERGED="diverged — has unique content"
T_CLEAN_NO_TRANSCRIPT="(no transcript)"
T_CLEAN_NO_PREVIEW="(no preview)"
T_CLEAN_AGE_AGO="%sd ago"
T_CLEAN_LIST_HEADING="Session data that can be cleaned up (biggest first in each section):"
T_CLEAN_TOTAL="Total sessions to clean: %s"
T_CLEAN_SELECTED="Selected sessions to clean: %s"
T_CLEAN_SPACE_TO_FREE="Estimated space to free: %s"
T_CLEAN_UNCHECKED_HINT="%s row(s) start unchecked — big-but-recent sessions and diverged copies are your call."
T_CLEAN_DRYRUN_NOTE="Dry-run mode: no files were deleted."
T_CLEAN_REFUSE_NONINTERACTIVE="Refusing to delete without an interactive confirmation — re-run in a terminal (or use --dry-run to preview)."
T_CLEAN_CANCELLED="Cancelled — nothing deleted."
T_CLEAN_NOTHING_SELECTED="Nothing selected — nothing deleted."
T_CLEAN_CONFIRM_Q="Are you sure you want to permanently delete these sessions?"
T_CLEAN_CONFIRM_PROMPT="Press Enter to proceed, or Ctrl-C to cancel: "
T_CLEAN_NO_CONFIRM="No confirmation received — nothing deleted."
T_CLEAN_DELETING="Deleting session files..."
T_CLEAN_DONE="Cleanup complete. Freed approximately %s."
T_CLEAN_NONE_MINSIZE="No sessions of at least %s MB found (0 files to clean)."
T_CLEAN_NONE_AGE_MINSIZE="No sessions older than %s days and at least %s MB found (0 files to clean)."
T_CLEAN_NONE_ALL="Nothing to clean — no redundant copies, no sessions older than %s days, none over %s MB."
T_CLEAN_PICKER_HINT="· ↑↓ move · space toggle · a all · ⏎ delete selected · q cancel"
T_CLEAN_TALLY="selected: %s of %s · %s to free"
T_CLEAN_MORE_ABOVE="▲ ... %s more above ..."
T_CLEAN_MORE_BELOW="▼ ... %s more below ..."
T_CLEAN_ERR_OLDER_THAN="Error: --older-than requires a numeric number of days."
T_CLEAN_ERR_MIN_SIZE="Error: --min-size requires a numeric number of megabytes."
T_CLEAN_ERR_UNKNOWN_ARG="Unknown argument: %s  (see: clikae clean --help)"
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
T_RESUME_OPT_SWITCH="Open this tank fresh (don't resume)"
T_RESUME_DRY_TITLE="%s is out of fuel — carry on?"
T_RESUME_OPT_RELAY="Carry this session to %s"
T_RESUME_OPT_FORCE="Resume %s anyway (will hit the limit)"
T_RESUME_OPT_CARRY="Carry this session to another tank"
T_RESUME_CARRY_PICK="Carry %s — pick a tank to continue on"
T_RESUME_WHICH_TANK="Resume on which tank?"
T_UPDATE_AVAIL="Update available!"
T_UPDATE_NOTES="Release notes:"
T_UPDATE_NOW="Update now (runs \`%s\`)"
T_UPDATE_SHOW="Show me the upgrade command"
T_UPDATE_SKIP="Skip"
T_UPDATE_SKIP_VER="Skip until next version"
T_UPDATE_DONE="Updated — relaunch clikae to use the new version."
T_UPDATE_FAILED="Upgrade command failed — run it yourself, or see the release page."
T_UPDATE_MANUAL="Upgrade clikae with your installer, or grab it from:"
T_DRY_SEEN="seen %s"
# new-tank / rename prompts
T_NEWTANK_TITLE="New tank — pick a CLI"
T_NEWTANK_PROFILE="Tank name for %s (e.g. work, personal): "
T_NEWTANK_CANCEL="Cancelled — no tank created."
T_NEWTANK_NONAME="Cancelled — no name given."
T_RENAME_FOR="Rename"
T_RENAME_NEW="New name: "
T_RENAME_CANCEL="Cancelled — name unchanged."
# filter / help / misc
T_FILTER_PROMPT="filter: "
T_FILTER_NONE="no matches"
T_HELP_TITLE="clikae — keys"
T_HELP_AGY="agy (Antigravity) is power mode: 'n' → agy, or 'clikae init agy <name>', takes over ~/.gemini (asks first)."
T_DOTS_TITLE="Dots = fuel"
T_DOT_READY="ready"
T_DOT_DRY="dry (over limit)"
T_DOT_WEEK="weekly % (BETA)"
T_DOT_NONE="no reading"
T_HELP_DISMISS="any key to close"
T_PICKER_HINT="up/down move · Enter select · q cancel"
T_LANG_SET="Interface language: %s"
T_LANG_UNKNOWN="Unknown language: %s  (use: %s)"

# i18n_summary <ntanks> <nclis> — the board's "N tanks across M engines" line.
# A FUNCTION, not a string: English pluralises, other grammars count differently.
# A locale file MAY redefine it (ja-JP/zh-TW do); if it doesn't, this English
# version is the fallback. Echoes the phrase, no trailing newline.
i18n_summary() {
  local n="$1" m="$2"
  printf '%s tank%s across %s engine%s' \
    "$n" "$([ "$n" = 1 ] || echo s)" "$m" "$([ "$m" = 1 ] || echo s)"
}
