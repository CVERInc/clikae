# shellcheck shell=bash
# lib/core/log.sh — coloured logging primitives. Sourced by bin/clikae.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  __C_RESET='\033[0m'
  __C_GREEN='\033[0;32m'
  __C_YELLOW='\033[1;33m'
  __C_RED='\033[0;31m'
  __C_DIM='\033[2m'
  __C_BOLD='\033[1m'
  __C_CYAN='\033[36m'
  __C_BCYAN='\033[96m'
else
  __C_RESET='' __C_GREEN='' __C_YELLOW='' __C_RED='' __C_DIM='' __C_BOLD='' __C_CYAN='' __C_BCYAN=''
fi

# The narration prefixes ARE the family's badges (signet/packages/cli/SPEC.md).
# They were `[OK] [INFO] [WARN] [ERR]` — four columns wide, their own vocabulary
# — which meant a person met `[WARN]` here and `[ WARN ]` in a report in the
# same sitting, with no way to know why they differed.
#
# `[OK]` was carrying two meanings, the same overload the badge set exists to
# force apart: "I did something" (Created / Removed / Moved / Renamed, ~54 call
# sites) and "I checked, and there was nothing to do" (already shares…, wasn't
# solo, no limit marker, ~9). The question is the one sheersweep asks of its own
# report: did this line change the state? Changed → DONE, unchanged → PASS.
#
# `[INFO]` gets no badge at all. It isn't a state — it's guidance that follows
# something ("No alias added. Run `clikae alias …`"), so it indents under the
# badge column and says nothing where nothing happened.
log_done()  { printf '%b[ DONE ]%b %s\n'   "$__C_GREEN"  "$__C_RESET" "$*"; }
log_pass()  { printf '%b[ PASS ]%b %s\n'   "$__C_GREEN"  "$__C_RESET" "$*"; }
log_info()  { printf '         %s\n'                                  "$*"; }
log_warn()  { printf '%b[ WARN ]%b %s\n'   "$__C_YELLOW" "$__C_RESET" "$*" >&2; }
log_err()   { printf '%b[ FAIL ]%b %s\n'   "$__C_RED"    "$__C_RESET" "$*" >&2; }
log_dim()   { printf '%b%s%b\n'            "$__C_DIM"    "$*"          "$__C_RESET"; }
log_bold()  { printf '%b%s%b\n'            "$__C_BOLD"   "$*"          "$__C_RESET"; }
log_fail()  { log_err "$*"; exit 1; }

# Prompt for yes/no. Returns 0 for yes. Defaults to no.
confirm() {
  local prompt="${1:-Continue?} [y/N] "
  local reply
  printf '%s' "$prompt"
  read -r reply || return 1
  case "$reply" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}
