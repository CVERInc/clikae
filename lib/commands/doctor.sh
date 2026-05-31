# shellcheck shell=bash
# lib/commands/doctor.sh — `clikae doctor`
#
# A read-only health check answering "what can clikae do on THIS machine right
# now?": which supported CLIs are installed, how many profiles each has and the
# logged-in account, plus the environment (CLIKAE_HOME, shell rc + whether a
# clikae block is loaded, clikae on PATH) and a few targeted next steps derived
# from the scan. Changes nothing — pure inspection.

# Render the scan rows (on stdin) as an aligned table. Plain cells (no colour):
# escape codes count toward printf's field width and break alignment.
_doctor_render_table() {
  printf '%b%-12s %-11s %-9s %s%b\n' "$__C_BOLD" "CLI" "INSTALLED" "PROFILES" "LOGGED IN" "$__C_RESET"
  local cli installed binary strategy count label inst
  while IFS=$'\037' read -r cli installed binary strategy count label; do
    [ -n "$cli" ] || continue
    if [ "$installed" -eq 1 ]; then inst="yes"; else inst="no"; fi
    printf '%-12s %-11s %-9s %s\n' "$cli" "$inst" "$count" "${label:--}"
  done
}

cmd_doctor() {
  case "${1:-}" in
    -h|--help)
      cat <<'EOF'
Usage: clikae doctor

A read-only health check: which supported CLIs are installed and logged in, how
many profiles each has, and what to do next. It changes nothing on disk.
EOF
      return 0 ;;
    "") : ;;
    *) log_fail "Unexpected argument: $1" ;;
  esac

  local rc rc_loaded="no" on_path="no"
  rc="$(detect_shell_rc)"
  [ -f "$rc" ] && grep -qF "# >>> clikae:" "$rc" 2>/dev/null && rc_loaded="yes"
  command -v clikae >/dev/null 2>&1 && on_path="yes"

  log_bold "clikae doctor — what clikae can do on this machine"
  echo ""
  printf '  %-16s %s\n' "clikae"       "$CLIKAE_VERSION  ($CLIKAE_ROOT)"
  printf '  %-16s %s\n' "CLIKAE_HOME"  "$CLIKAE_HOME"
  if [ "$on_path" = "yes" ]; then
    printf '  %-16s %s\n' "on PATH"    "yes"
  else
    printf '  %-16s %s\n' "on PATH"    "no — add the install bin dir to your PATH (see docs/installation.md)"
  fi
  if [ "$rc_loaded" = "yes" ]; then
    printf '  %-16s %s\n' "shell rc"   "$rc  (clikae aliases present)"
  else
    printf '  %-16s %s\n' "shell rc"   "$rc  (no clikae aliases yet)"
  fi
  echo ""

  # Trailing newline matters: $(...) strips it, and a final line with no newline
  # is read into the loop vars but its body never runs — dropping the last CLI.
  local rows; rows="$(scan_clis)"
  printf '%s\n' "$rows" | _doctor_render_table
  echo ""

  # Targeted next steps, derived from the scan. We only need cli/installed/count;
  # binary/strategy/label are read to reach the right columns.
  local installed_no_profile="" any_profiles=0
  local cli installed binary strategy count label
  while IFS=$'\037' read -r cli installed binary strategy count label; do
    [ -n "$cli" ] || continue
    : "$binary" "$strategy" "$label"   # consumed only to position $count
    [ "$count" -gt 0 ] && any_profiles=1
    if [ "$installed" -eq 1 ] && [ "$count" -eq 0 ] && [ -z "$installed_no_profile" ]; then
      installed_no_profile="$cli"
    fi
  done <<EOF
$rows
EOF

  log_bold "Next:"
  if [ -n "$installed_no_profile" ]; then
    log_dim "  • $installed_no_profile is installed with no profile yet:  clikae init $installed_no_profile work --alias"
  fi
  if [ "$rc_loaded" = "no" ] && [ "$any_profiles" -eq 1 ]; then
    log_dim "  • aliases aren't loaded in this shell yet:  source $rc"
  fi
  log_dim "  • See your tanks at a glance:  clikae"
  log_dim "  • Take a risk-free tour:       clikae demo"
}
