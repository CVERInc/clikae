# shellcheck shell=bash
# lib/commands/demo.sh — `clikae demo`
#
# A guided, non-interactive tour that runs entirely inside a throwaway sandbox
# (a temp CLIKAE_HOME) so it can show — not just tell — what clikae does without
# touching your real ~/.clikae, your logins, or your shell rc. The accounts are
# simulated (fake account labels), so it works with no real CLI installed and no
# second account. Every tank is one you'd OWN (named cver-A / cver-B): clikae
# switches between the multiple accounts ONE person legitimately holds — never a
# shared login. The sandbox is removed when the tour ends.

# Print a faux shell prompt + the command, then run it against the sandbox.
# Usage: _demo_cmd <sandbox> [ENV=VAL ...] -- <clikae args...>
_demo_cmd() {
  local sb="$1"; shift
  local env_pairs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do env_pairs+=("$1"); shift; done
  shift   # drop the --
  printf '  %b$ clikae %s%b\n' "$__C_DIM" "$*" "$__C_RESET"
  env CLIKAE_HOME="$sb" "${env_pairs[@]}" "$CLIKAE_BIN" "$@" || true
  echo ""
}

_demo_act() { printf '%b▸ %s%b\n\n' "$__C_BOLD" "$*" "$__C_RESET"; }

# _demo_claude_acct <sandbox> <tank> <email> — simulate a signed-in Claude account
# (clikae reads the email from .claude.json's oauthAccount).
_demo_claude_acct() {
  printf '{\n  "oauthAccount": { "emailAddress": "%s" }\n}\n' "$3" \
    > "$1/profiles/claude/$2/.claude.json"
}

# _demo_codex_acct <sandbox> <tank> <email> — simulate a signed-in Codex account.
# Codex stores identity in auth.json's id_token (a JWT); clikae decodes the
# base64url payload's "email" for the label. We forge a header.payload.sig where
# only the payload carries meaning (the signature is never verified — it's a
# display label, not an auth check).
_demo_codex_acct() {
  local dir="$1/profiles/codex/$2" pl
  mkdir -p "$dir"
  pl="$(printf '{"email":"%s"}' "$3" | base64 | tr '+/' '-_' | tr -d '=\n')"
  printf '{ "id_token": "e30.%s.demo" }\n' "$pl" > "$dir/auth.json"
}

# _demo_agy_acct <sandbox> <tank> <email> — simulate a signed-in agy (Antigravity)
# account. agy keeps no account file; clikae scrapes the signed-in Google address
# from "email=<x>" in its antigravity-cli/log, so we seed exactly that. (init agy
# would run the real ~/.gemini takeover, so the tour seeds the dir by hand.)
_demo_agy_acct() {
  local dir="$1/profiles/antigravity/$2/antigravity-cli"
  mkdir -p "$dir"
  printf 'email=%s\n' "$3" > "$dir/log"
}

# _demo_reset_phrase — codex's verbatim "out of quota" wording with a fresh
# near-future reset time (portable BSD/GNU date), so the demo's red dot never
# reads stale. clikae stores and shows this verbatim — it never computes a
# countdown of its own.
_demo_reset_phrase() {
  local when
  when="$(date -v+3H '+%b %e, %Y %l:%M %p' 2>/dev/null \
       || date -d '+3 hours' '+%b %-d, %Y %-I:%M %p' 2>/dev/null \
       || echo 'in about 3 hours')"
  when="$(printf '%s' "$when" | tr -s ' ')"
  printf "You've hit your usage limit. Try again at %s." "$when"
}

cmd_demo() {
  case "${1:-}" in
    -h|--help)
      cat <<'EOF'
Usage: clikae demo

A 30-second guided tour in a throwaway sandbox — several of YOUR OWN accounts
across claude, codex and agy, the tank board with its fuel gauge (green ready /
yellow weekly / red over-quota with the vendor's own reset time / ○ no reading),
and the `to` idea (your tanks are the reserve). Then it cleans up. Touches
nothing real: not your ~/.clikae, not your logins, not your shell rc.
EOF
      return 0 ;;
    "") : ;;
    *) log_fail "Unexpected argument: $1" ;;
  esac

  local sb
  sb="$(mktemp -d "${TMPDIR:-/tmp}/clikae-demo.XXXXXX")"
  # Always clean up the sandbox, even on an early exit.
  # shellcheck disable=SC2064
  trap "rm -rf '$sb'" EXIT

  log_bold "clikae demo — a guided tour in a throwaway sandbox"
  log_dim  "Everything below runs in a temporary sandbox, gone when the tour ends."
  log_dim  "Your real ~/.clikae, logins, and shell rc are NOT touched."
  echo ""

  # --- Act 1: several accounts that are all YOURS, across engines, isolated --
  _demo_act "Several accounts that are all yours — across claude, codex and agy"
  local t
  for t in cver-A cver-B; do
    env CLIKAE_HOME="$sb" "$CLIKAE_BIN" init claude "$t" >/dev/null 2>&1 || true
  done
  for t in cver-A cver-B; do
    env CLIKAE_HOME="$sb" "$CLIKAE_BIN" init codex  "$t" >/dev/null 2>&1 || true
  done
  # Simulate a signed-in account in each tank — one person, several OWN logins.
  _demo_claude_acct "$sb" cver-A "cver@gmail.com"
  _demo_claude_acct "$sb" cver-B "cver.dev@gmail.com"
  _demo_codex_acct  "$sb" cver-A "cver@gmail.com"
  _demo_codex_acct  "$sb" cver-B "cver.dev@gmail.com"
  _demo_agy_acct    "$sb" cver-A "cver@gmail.com"   # agy is global; one tank shows the engine

  # A fuel reading per tank so the board's traffic light has something to show:
  #   • yellow — a weekly-usage notice clikae caught and cached (claude/cver-B)
  #   • red    — codex/cver-A is out of quota; clikae kept codex's verbatim reset time
  #   claude/agy stay green (detectable + ready); codex/cver-B has no detector → ○,
  #   which is the honest "no reading" rather than a guessed green.
  mkdir -p "$sb/cache/weekly"
  printf '82%% of your weekly limit\n' > "$sb/cache/weekly/claude-cver-B"
  mkdir -p "$sb/dry/codex"
  printf '%s\t%s\n' "$(date +%s 2>/dev/null || echo 0)" "$(_demo_reset_phrase)" \
    > "$sb/dry/codex/cver-A"
  # A deliberate burn order so the tour's board reads top-to-bottom.
  cat > "$sb/order" <<'ORD'
claude/cver-A
claude/cver-B
codex/cver-A
codex/cver-B
antigravity/cver-A
ORD

  log_dim "  Five isolated config dirs — no shared state, each its own login:"
  printf '    %s\n' "claude/cver-A · cver-B     codex/cver-A · cver-B     agy/cver-A"
  log_dim "  Each tank is an account YOU own — clikae never shares one login."
  echo ""

  # --- Act 2: the tank board (what `clikae` shows you) ---------------------
  _demo_act "Type \`clikae\` for your board — one fuel gauge per tank  (press q to go on)"
  _demo_cmd "$sb" "CLAUDE_CONFIG_DIR=$sb/profiles/claude/cver-A" --

  # --- Act 3: the magic (narrated — `to` carries a live session) -----------
  _demo_act "The payoff: codex/cver-A just hit its limit (red above) — keep burning"
  log_dim "  Mid-task, one tank runs dry. Your other tanks ARE the reserve —"
  log_dim "  nothing to set up — so instead of re-logging into another account and"
  log_dim "  re-explaining everything:"
  echo ""
  printf '    %b$ clikae to%b                  %b# carry the LIVE session to the next tank, resume there%b\n' \
    "$__C_DIM" "$__C_RESET" "$__C_DIM" "$__C_RESET"
  printf '    %b$ clikae to cver-B%b           %b# or name it; cross engines explicitly: clikae to codex%b\n' \
    "$__C_DIM" "$__C_RESET" "$__C_DIM" "$__C_RESET"
  printf '    %b$ clikae watch claude --auto%b %b# or let clikae notice and switch for you%b\n' \
    "$__C_DIM" "$__C_RESET" "$__C_DIM" "$__C_RESET"
  echo ""

  # --- Outro ---------------------------------------------------------------
  log_bold "That's clikae. The sandbox is now gone — your machine is untouched."
  log_dim  "Start for real:   clikae init <engine> <tank> --alias"
  log_dim  "See your setup:   clikae        ·   health check:   clikae doctor"
  # trap removes $sb on exit.
}
