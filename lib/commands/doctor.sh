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
  printf '%b%-12s %-11s %-9s %s%b\n' "$__C_BOLD" "ENGINE" "INSTALLED" "TANKS" "LOGGED IN" "$__C_RESET"
  local cli installed binary strategy count label inst
  while IFS=$'\037' read -r cli installed binary strategy count label; do
    [ -n "$cli" ] || continue
    if [ "$installed" -eq 1 ]; then inst="yes"; else inst="no"; fi
    printf '%-12s %-11s %-9s %s\n' "$(engine_label "$cli")" "$inst" "$count" "${label:--}"
  done
}

# --- Keychain coordinates -----------------------------------------------------
# macOS keeps the LOGIN for both claude and agy in the login Keychain, not in the
# config dir clikae swaps — so clikae's whole account-isolation story rests on two
# hard-coded coordinates. Neither is verifiable by the test suite:
# `antigravity.bats` stubs `security`, so a rename on the vendor's side (a new
# service name, a different account) would pass CI and only surface to a user as
# "why am I suddenly on the wrong account".
#
# This is that check, on the real machine, read-only: it asks whether the item
# EXISTS. It deliberately never passes `-w`, because reading the secret is what
# makes the Keychain prompt for access — `doctor` must never pop a dialog — and
# because a token value has no business anywhere near a terminal. Presence only.
_doctor_keychain() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  command -v security >/dev/null 2>&1 || return 0

  # Both helpers live outside doctor's usual reach; pull them in only if needed.
  if ! declare -F _agy_kc_canon_service >/dev/null 2>&1; then
    # shellcheck source=./antigravity.sh
    source "$CLIKAE_LIB/commands/antigravity.sh"
  fi
  declare -F _claude_keychain_service >/dev/null 2>&1 || load_adapter claude 2>/dev/null || true

  log_bold "Login Keychain (read-only — presence only, never the secret)"

  # agy: ONE machine-wide slot. This is the reason agy is global/single-account,
  # so if these coordinates ever stop matching, every agy tank silently shares
  # whichever account is live.
  local svc acct
  svc="$(_agy_kc_canon_service)"; acct="$(_agy_kc_account)"
  if security find-generic-password -s "$svc" -a "$acct" >/dev/null 2>&1; then
    printf '  %-16s %s\n' "agy" "found  ($svc / $acct)"
  else
    printf '  %-16s %s\n' "agy" "absent ($svc / $acct) — not signed in, or the coordinates moved"
  fi

  # claude: one slot PER TANK, keyed by a hash of that tank's config dir. A tank
  # with no slot is simply logged out — `clikae migrate` without --keep-login is
  # the usual way to orphan one.
  if declare -F _claude_keychain_service >/dev/null 2>&1; then
    local cli name path found=0 missing=""
    while IFS=$'\t' read -r cli name path; do
      [ "$cli" = "claude" ] || continue
      svc="$(_claude_keychain_service "$path" 2>/dev/null || true)"
      [ -n "$svc" ] || continue
      if security find-generic-password -s "$svc" >/dev/null 2>&1; then
        found=$((found + 1))
      else
        missing="$missing $name"
      fi
    done <<EOF
$(list_all_profiles 2>/dev/null || true)
EOF
    if [ "$found" -gt 0 ] || [ -n "$missing" ]; then
      printf '  %-16s %s\n' "claude" "$found tank(s) with a saved login${missing:+; no slot for:$missing}"
    fi
  fi
  echo ""
}

cmd_doctor() {
  case "${1:-}" in
    -h|--help)
      cat <<'EOF'
Usage: clikae doctor

A read-only health check: which supported engines are installed and logged in,
how many tanks each has, and what to do next. It changes nothing on disk.
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

  _doctor_keychain

  # Targeted next steps, derived from the scan. We only need cli/installed/count;
  # binary/strategy/label are read to reach the right columns.
  local installed_no_profile="" any_profiles=0 total_profiles=0
  local cli installed binary strategy count label
  while IFS=$'\037' read -r cli installed binary strategy count label; do
    [ -n "$cli" ] || continue
    : "$binary" "$strategy" "$label"   # consumed only to position $count
    [ "$count" -gt 0 ] && any_profiles=1
    total_profiles=$((total_profiles + count))
    if [ "$installed" -eq 1 ] && [ "$count" -eq 0 ] && [ -z "$installed_no_profile" ]; then
      installed_no_profile="$cli"
    fi
  done <<EOF
$rows
EOF

  log_bold "Next:"
  if [ -n "$installed_no_profile" ]; then
    log_dim "  · $installed_no_profile is installed with no tank yet:  clikae init $installed_no_profile work --alias"
  fi
  if [ "$rc_loaded" = "no" ] && [ "$any_profiles" -eq 1 ]; then
    log_dim "  · aliases aren't loaded in this shell yet:  source $rc"
  fi
  if [ "$total_profiles" -ge 2 ]; then
    log_dim "  · when a tank runs dry, carry on to the next one:  clikae to"
  fi
  log_dim "  · See your tanks at a glance:  clikae"
  log_dim "  · Take a risk-free tour:       clikae demo"
}
