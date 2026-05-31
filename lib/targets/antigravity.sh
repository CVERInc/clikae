# shellcheck shell=bash
# lib/targets/antigravity.sh — a handoff TARGET for Google's Antigravity CLI (agy).
#
# Why a "target" and not an adapter: clikae adapters manage *switchable* profiles,
# which needs a config-dir env var (or a flag) to point a CLI at a per-profile
# directory. Antigravity's CLI (`agy`) hardcodes its state under ~/.gemini with no
# such override — investigated on a real install: neither $ANTIGRAVITY_EXECUTABLE_DATA_DIR
# nor $HOME relocates it, and there's no config-dir flag. So we can't give it
# multiple fuel tanks.
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
# A one-line note for the dashboard. agy hardcodes ~/.gemini and ignores env, so
# by default it's single-account (launch-only).
target_meta_note()   { echo "single-account · opens ~/.gemini directly"; }

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
