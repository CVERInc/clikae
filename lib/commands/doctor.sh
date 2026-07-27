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

# Name the "why is this tank suddenly logged out?" case instead of leaving it a
# mystery. clikae does not own the OAuth refresh — Claude Code does, in its own
# daemon — but that daemon writes its log INSIDE the tank clikae manages, so the
# aftermath is readable even though the mechanism isn't ours to fix.
#
# The failure it names: Claude's OAuth uses ROTATING refresh tokens, so when
# several sessions on one tank refresh at once, the loser gets `invalid_grant`,
# treats it as "logged out", and clears the Keychain entry the winner just wrote.
# One race, escalated into a whole-tank logout with no silent recovery. A user
# sees only that a working account stopped working.
#
# Read-only, bounded to the log's tail. We report only when the newest auth event
# is a FAILURE — a later success means it recovered and there is nothing to say.
_doctor_auth_dropouts() {
  local cli name path out bad ok
  while IFS=$'\t' read -r cli name path; do
    [ "$cli" = "claude" ] || continue
    [ -f "$path/daemon.log" ] || continue
    out="$(tail -c 200000 "$path/daemon.log" 2>/dev/null | awk '
      function ts(s,   t) {
        if (match(s, /^\[[0-9TZ:.-]+\]/)) { t = substr(s, RSTART+1, RLENGTH-2); return t }
        return ""
      }
      /auth: (proactive refresh failed|no token found|headless daemon cannot complete)/ {
        t = ts($0); if (t != "" && (bad == "" || t > bad)) bad = t; next
      }
      # "scheduling" counts as HEALTHY on purpose: the daemon only schedules a
      # refresh when it has a token to refresh — a tank with none says so with
      # "no token found" instead. Leaving it out produced a false positive on a
      # tank that had failed once, been re-logged-in, and been quietly fine for
      # a week (caught by reading the log instead of trusting the first draft).
      /auth: (proactive refresh succeeded|token still valid|scheduling proactive refresh)/ {
        t = ts($0); if (t != "" && (ok == "" || t > ok)) ok = t
      }
      END { printf "%s\037%s\n", bad, ok }
    ')"
    IFS=$'\037' read -r bad ok <<EOF
$out
EOF
    [ -n "$bad" ] || continue
    if [ -n "$ok" ]; then
      local newer; newer="$(printf '%s\n%s\n' "$bad" "$ok" | sort | tail -n 1)"
      [ "$newer" = "$ok" ] && continue      # recovered since
    fi
    printf '  %-16s %s\n' "claude/$name" "signed out by a token-refresh failure at ${bad%%.*} — fix: clikae claude $name, then /login"
    log_dim  "                   (concurrent sessions on one tank can race Claude's rotating refresh token; not something clikae can prevent)"
  done <<EOF
$(list_all_profiles 2>/dev/null || true)
EOF
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
  # NOT inside _doctor_keychain: that one returns early off macOS, and reading a
  # log file has nothing to do with the Keychain.
  _doctor_auth_dropouts

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
