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

log_ok()    { printf '%b[OK]%b    %s\n'    "$__C_GREEN"  "$__C_RESET" "$*"; }
log_info()  { printf '%b[INFO]%b  %s\n'    "$__C_YELLOW" "$__C_RESET" "$*"; }
log_warn()  { printf '%b[WARN]%b  %s\n'    "$__C_YELLOW" "$__C_RESET" "$*" >&2; }
log_err()   { printf '%b[ERR]%b   %s\n'    "$__C_RED"    "$__C_RESET" "$*" >&2; }
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
