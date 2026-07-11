# shellcheck shell=bash
# lib/core/notice.sh — one-time informed-consent notes.
#
# clikae's carry features are powerful, and ONE way of using them — continuing
# the same task past a usage limit on another account — sits in vendor-terms
# gray zone. The docs cover it in full (docs/terms-and-your-accounts.md); this
# makes sure a user has seen the headline at least once before their first
# carry, instead of assuming they read the docs. Shown exactly once per store,
# then never again — informed consent, not a nag. Headless runs print it but
# never block on input.

# carry_notice_once — print the note (and, on a TTY, wait for Enter) the first
# time a cross-account carry is about to happen. Marker: $CLIKAE_HOME/carry-notice-shown.
carry_notice_once() {
  local marker="$CLIKAE_HOME/carry-notice-shown"
  [ -f "$marker" ] && return 0
  {
    printf '\n%b%s%b\n' "${__C_BOLD:-}" "A one-time note about your accounts" "${__C_RESET:-}"
    printf '%s\n' "Different accounts for different purposes (work / personal / per client) is"
    printf '%s\n' "explicitly fine under the vendors' terms. Using a second account to continue"
    printf '%s\n' "the SAME task past a usage limit is not: OpenAI's terms name it directly,"
    printf '%s\n' "and Anthropic's policy language is broad enough to cover it. Your accounts"
    printf '%s\n' "carry the risk, so it is your call — the full, dated picture is here:"
    printf '%s\n' "  https://github.com/CVERInc/clikae/blob/main/docs/terms-and-your-accounts.md"
  } >&2
  if [ -t 0 ] && [ -t 2 ]; then
    printf '%s' "Enter to continue (this note never repeats): " >&2
    IFS= read -r _ || true
  fi
  printf '\n' >&2
  mkdir -p "$CLIKAE_HOME" 2>/dev/null || true
  : > "$marker" 2>/dev/null || true
  return 0
}
