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
# A target file defines just two things: a name and how to start it with a prompt.

target_meta_name()   { echo "Antigravity (agy)"; }
target_meta_binary() { echo "agy"; }

# target_start_with_prompt <prompt> [args...]
# Start agy seeded with the brief. No per-profile dir (single-account).
target_start_with_prompt() {
  local prompt="$1"; shift
  exec agy -i "$prompt" "$@"
}
