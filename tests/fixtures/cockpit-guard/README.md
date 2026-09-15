# cockpit-guard fixtures

`real-pretooluse-payload.json` — a genuine Claude Code `PreToolUse` hook
payload for an `Agent` tool call, captured 2026-09-13 by running a throwaway
`claude -p` session under a `mktemp -d` `$HOME` with a one-off
`--settings` hooks block that `cat`s stdin to a file (see
`REPORT-cockpit63-fix1.md` for the exact command). `session_id`,
`transcript_path`, `cwd`, `prompt_id` and `tool_use_id` are replaced with
placeholders; every other byte — key order, formatting, escaping — is
exactly what Claude Code sent.

Contrary to the round-1 review's assumption ("Claude Code's real hook
payload is pretty-printed JSON"), the real payload is **compact, single-line
JSON with no whitespace around `:`** — and `tool_input`'s keys are
`description`, `prompt`, `model` **in that order** (`model` after `prompt`,
not before). `tests/bats/cockpit-guard.bats` uses this file as the primary
fixture for the guard's happy path; a hand-written pretty-printed / spaced
variant is exercised separately as a defensive case (JSON allows the
whitespace even though this capture shows real traffic doesn't use it).
