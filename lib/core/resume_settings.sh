# shellcheck shell=bash
# lib/core/resume_settings.sh — whether resuming a non-dry session asks which
# tank to land on, or only asks when the tank is actually dry.
#
#   always    (default) — the tank-choice comes up every time you resume a
#             session with more than one tank for that engine, same as
#             `clikae resume`'s standalone picker already does.
#   dry-only  — only ask when the tank you're resuming is dry (the older,
#               quieter behavior, for anyone who resumes on the same tank
#               often enough that being asked every time is just friction).
#
# Consumed by lib/commands/home.sh (`_home_resume_action`) and exposed via
# `clikae resume ask-tank [always|dry-only]` (lib/commands/resume.sh).

resume_ask_tank_file() { printf '%s\n' "$CLIKAE_HOME/resume-ask-tank"; }

# resume_ask_tank_get -> always | dry-only  (default always; unknown content normalises to always).
resume_ask_tank_get() {
  local v=""
  [ -f "$(resume_ask_tank_file)" ] && v="$(tr -d '[:space:]' < "$(resume_ask_tank_file)" 2>/dev/null)"
  case "$v" in dry-only) printf '%s' "$v" ;; *) printf 'always' ;; esac
}

# resume_ask_tank_set <always|dry-only> -> persist. Returns 1 on an unknown value.
resume_ask_tank_set() {
  case "$1" in
    always|dry-only) : ;;
    *) return 1 ;;
  esac
  mkdir -p "$CLIKAE_HOME" 2>/dev/null || true
  printf '%s\n' "$1" > "$(resume_ask_tank_file)" 2>/dev/null || true
}

# resume_ask_tank_label <value> -> a short human description for status/help.
resume_ask_tank_label() {
  case "$1" in
    always)   printf 'ask every time' ;;
    dry-only) printf 'ask only when the tank is dry' ;;
    *)        printf 'unknown' ;;
  esac
}
