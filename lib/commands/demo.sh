# shellcheck shell=bash
# lib/commands/demo.sh — `clikae demo`
#
# A guided, non-interactive tour that runs entirely inside a throwaway sandbox
# (a temp CLIKAE_HOME) so it can show — not just tell — what clikae does without
# touching your real ~/.clikae, your logins, or your shell rc. The CLI accounts
# are simulated (fake .claude.json email labels), so it works with no real CLI
# installed and no second account. The sandbox is removed when the tour ends.

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

cmd_demo() {
  case "${1:-}" in
    -h|--help)
      cat <<'EOF'
Usage: clikae demo

A 30-second guided tour in a throwaway sandbox — it shows isolated profiles, the
tank board, the fuel pool, and the relay idea, then cleans up. Touches nothing
real: not your ~/.clikae, not your logins, not your shell rc.
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
  log_dim  "Everything below runs under $sb"
  log_dim  "Your real ~/.clikae, logins, and shell rc are NOT touched."
  echo ""

  # --- Act 1: two accounts of one CLI, fully isolated ----------------------
  _demo_act "One CLI, two accounts — each in its own directory"
  env CLIKAE_HOME="$sb" "$CLIKAE_BIN" init claude alice >/dev/null 2>&1 || true
  env CLIKAE_HOME="$sb" "$CLIKAE_BIN" init claude bob   >/dev/null 2>&1 || true
  # Simulate a logged-in account in each (clikae reads the email from .claude.json).
  printf '{\n  "oauthAccount": { "emailAddress": "alice@studio.dev" }\n}\n' \
    > "$sb/profiles/claude/alice/.claude.json"
  printf '{\n  "oauthAccount": { "emailAddress": "bob@studio.dev" }\n}\n' \
    > "$sb/profiles/claude/bob/.claude.json"
  log_dim "  Created two isolated config dirs (no shared state between them):"
  printf '    %s\n' "$sb/profiles/claude/alice   → alice@studio.dev"
  printf '    %s\n' "$sb/profiles/claude/bob     → bob@studio.dev"
  echo ""

  # --- Act 2: the tank board (what `clikae` shows you) ---------------------
  _demo_act "Type \`clikae\` to see your tanks (alice is the one this shell is on)"
  _demo_cmd "$sb" "CLAUDE_CONFIG_DIR=$sb/profiles/claude/alice" --

  # --- Act 3: a fuel pool (the relay fall-through order) -------------------
  _demo_act "Set a fuel pool — the order to fall through when a tank runs dry"
  env CLIKAE_HOME="$sb" "$CLIKAE_BIN" pool add claude/alice >/dev/null 2>&1 || true
  env CLIKAE_HOME="$sb" "$CLIKAE_BIN" pool add claude/bob   >/dev/null 2>&1 || true
  _demo_cmd "$sb" -- pool list

  # --- Act 4: the magic (narrated — relay carries a live session) ----------
  _demo_act "The payoff: hit a limit mid-task? Swap the tank, keep burning"
  log_dim "  alice runs out of quota in the middle of a task. Instead of"
  log_dim "  re-logging into bob and re-explaining everything:"
  echo ""
  printf '    %b$ clikae relay claude bob%b   %b# carry the LIVE session over, resume on bob quota%b\n' \
    "$__C_DIM" "$__C_RESET" "$__C_DIM" "$__C_RESET"
  printf '    %b$ clikae watch claude --auto%b %b# or let clikae notice and fall through the pool for you%b\n' \
    "$__C_DIM" "$__C_RESET" "$__C_DIM" "$__C_RESET"
  echo ""

  # --- Outro ---------------------------------------------------------------
  log_bold "That's clikae. The sandbox is now gone — your machine is untouched."
  log_dim  "Start for real:   clikae init <cli> <profile> --alias"
  log_dim  "See your setup:   clikae        ·   health check:   clikae doctor"
  # trap removes $sb on exit.
}
