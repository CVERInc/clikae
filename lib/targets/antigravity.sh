# shellcheck shell=bash
# lib/targets/antigravity.sh — a handoff TARGET for Google's Antigravity CLI (agy).
#
# Why a "target" and not an adapter: clikae adapters manage *switchable* profiles,
# which needs a config-dir env var (or a flag) to point a CLI at a per-profile dir.
# agy's STATE dir does follow $HOME (os.UserHomeDir), but its LOGIN doesn't — the
# account is one global Keychain entry, and no env (ANTIGRAVITY_EXECUTABLE_DATA_DIR,
# GEMINI_HOME, …) or flag re-routes it. So accounts can't be switched per-shell;
# clikae's opt-in multi-account mode swaps them GLOBALLY (~/.gemini symlink + Keychain
# stash), one active at a time.
#
# What we CAN do is hand a session OFF to it: when a Claude/Codex tank runs dry,
# `clikae handoff <cli> --to antigravity` starts `agy` seeded with the handoff
# brief as its opening prompt. agy's `-i/--prompt-interactive` runs an initial
# prompt and continues the session — exactly what we need.
#
# A target file defines a name, how to start it with a prompt, and (optionally)
# where it logs a limit event so `clikae watch` can notice the tank ran dry.

target_meta_name()   { echo "Antigravity (agy)"; }
target_meta_binary() { echo "agy"; }
# A one-line note for the dashboard. agy's login is global (one account across all
# shells), so by default it's single-account (launch-only). Localised via T_AGY_NOTE
# (from lib/core/i18n.sh), with the English string as a fallback when i18n isn't loaded
# (e.g. a unit test that sources this target file in isolation).
target_meta_note()   { echo "${T_AGY_NOTE:-single-account · global login (one account, all shells)}"; }

# When the opt-in multi-account mode is enabled (see `clikae antigravity`), the
# active account is whichever slot the ~/.gemini symlink points at. The dashboard
# uses this to mark the active tank. Empty when not enabled / not a clikae slot.
target_active_profile() {
  local link="$HOME/.gemini" target slots="$CLIKAE_HOME/profiles/antigravity"
  [ -L "$link" ] || return 0
  target="$(readlink "$link")"
  case "$target" in "$slots"/*) basename "$target" ;; esac
}

# target_start_with_prompt <prompt> [args...]
# Start agy seeded with the brief. No per-profile dir (single-account).
target_start_with_prompt() {
  local prompt="$1"; shift
  exec agy -i "$prompt" "$@"
}

# target_limit_log_path
# Where agy records a quota/limit event so `clikae watch` can notice a dry tank.
# CONFIRMED (dogfooded 2026-05-31): `agy -p` hitting its Gemini quota exits 0 with
# EMPTY stdout/stderr — the ONLY signal is an E-level line in this log:
#   agent executor error: RESOURCE_EXHAUSTED (code 429): Individual quota reached.
#   … Resets in <Hh Mm>.
# This is a symlink that agy repoints to a fresh per-run file each invocation, so
# watchers must `tail -F` it (follow by name across rotation), not `tail -f` an
# inode. Single-account vendor → no profile dir, so this takes no argument.
target_limit_log_path() { echo "$HOME/.gemini/antigravity-cli/cli.log"; }

# target_memory_pointer_path <tank-dir>
# Where to drop a "your long-term memory (Soul) lives at <path>" pointer for
# `clikae memory share` (docs/memory.md). agy keeps its OWN memory opaquely
# (antigravity-cli/{knowledge,brain,implicit/*.pb}) — nothing markdown to symlink —
# but it reads `~/.gemini/GEMINI.md` as global rules (Antigravity v1.20.3+ native
# AGENTS.md/GEMINI.md support; GEMINI.md is the highest-priority global rules file).
# `~/.gemini` is clikae's per-tank symlink, so <tank-dir>/GEMINI.md IS that tank's
# global rules — the agy analogue of codex's $CODEX_HOME/AGENTS.md. Defining this
# marks the target as pointer-strategy for `clikae memory`.
target_memory_pointer_path() { printf '%s\n' "$1/GEMINI.md"; }
