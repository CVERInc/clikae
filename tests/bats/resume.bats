#!/usr/bin/env bats
# tests/bats/resume.bats — `clikae resume [session-id]`
#
# resume exec's the engine to reopen a past session, so we stub `claude` to record
# its argv + CLAUDE_CONFIG_DIR + cwd, then assert clikae found the right tank,
# cd'd to the session's recorded directory, and resumed under that tank's config.

load '../helpers'

# A fake `claude` that records argv, CLAUDE_CONFIG_DIR and $PWD, then exits.
_install_claude_stub() {
  mkdir -p "$TEST_HOME/bin"
  cat > "$TEST_HOME/bin/claude" <<'STUB'
#!/usr/bin/env bash
{
  echo "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"
  echo "PWD=$PWD"
  echo "ARGS=$*"
} > "$CLAUDE_STUB_LOG"
exit 0
STUB
  chmod +x "$TEST_HOME/bin/claude"
  export PATH="$TEST_HOME/bin:$PATH"
  export CLAUDE_STUB_LOG="$TEST_HOME/stub.log"
}

# Slug a path the way Claude Code does: [^A-Za-z0-9] -> '-'.
_slug() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

# Bring _resume_carry_session (lib/core/session_carry.sh) and its dependencies
# into THIS bats process, in the same order bin/clikae sources them — needed only
# by tests that call it directly rather than through a `clikae` subprocess.
_source_session_carry() {
  CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  # shellcheck source=../../lib/core/log.sh
  source "$CLIKAE_LIB/core/log.sh"
  # shellcheck source=../../lib/core/profile_store.sh
  source "$CLIKAE_LIB/core/profile_store.sh"
  # shellcheck source=../../lib/core/adapter_loader.sh
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  # shellcheck source=../../lib/core/history.sh
  source "$CLIKAE_LIB/core/history.sh"
  # shellcheck source=../../lib/core/session_carry.sh
  source "$CLIKAE_LIB/core/session_carry.sh"
}

# Seed a transcript for <profile> covering directory <dir>, carrying a cwd field.
_seed_transcript() {
  local profile="$1" dir="$2" sid="$3"
  local slug; slug="$(_slug "$dir")"
  mkdir -p "$CLIKAE_HOME/profiles/claude/$profile/projects/$slug"
  printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"hi"}}\n' "$dir" \
    > "$CLIKAE_HOME/profiles/claude/$profile/projects/$slug/$sid.jsonl"
}

@test "resume finds the tank holding a session id and resumes it there" {
  _install_claude_stub
  clikae init claude a
  clikae init claude b
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sid="11111111-2222-3333-4444-555555555555"
  _seed_transcript b "$work" "$sid"   # session lives in tank b

  cd "$TEST_HOME"                       # NOT in the session's dir
  unset CLAUDE_CONFIG_DIR
  run clikae resume "$sid"
  [ "$status" -eq 0 ]

  grep -q "ARGS=--resume $sid" "$CLAUDE_STUB_LOG"
  grep -q "CLAUDE_CONFIG_DIR=$CLIKAE_HOME/profiles/claude/b" "$CLAUDE_STUB_LOG"
  # cd'd into the session's recorded directory.
  grep -q "PWD=$work" "$CLAUDE_STUB_LOG"
}

@test "resume writes no terminal escapes into a pipe" {
  # `clikae resume > file` began with the raw bytes ESC[?25h ESC[?1049l — the
  # alt-screen teardown, emitted unconditionally by _home_tty_leave, which the
  # non-interactive listing path also calls. Terminal control codes in a pipe are
  # noise at best and corrupt whatever parses the output at worst.
  clikae init claude work
  run clikae resume
  # The output must be plain text: no ESC anywhere in it.
  [[ "$output" != *$'\033'* ]] || false
}

@test "resume: an empty store is a state, not a failure (human 0, script 1)" {
  # Having no sessions yet is where every new user starts; it was reported with
  # [ FAIL ] and exit 1, which reads as "clikae is broken" and offers no next
  # step. The exit code now splits by audience — and under bats there is no tty,
  # so this asserts the SCRIPT side: still non-zero, so `clikae resume ||
  # fallback` keeps working.
  clikae init claude work
  run clikae resume
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"No sessions to resume yet"* ]] || false
  [[ "$output" == *"clikae <engine> <tank>"* ]] || false
  [[ "$output" != *"FAIL"* ]] || false
}

@test "resume errors when the session is in no tank" {
  _install_claude_stub
  clikae init claude a
  run clikae resume "deadbeef-0000-0000-0000-000000000000"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No session"* ]] || false
  [ ! -f "$CLAUDE_STUB_LOG" ]
}

@test "resume forwards passthrough args after --" {
  _install_claude_stub
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  _seed_transcript a "$work" "$sid"

  cd "$TEST_HOME"
  unset CLAUDE_CONFIG_DIR
  run clikae resume "$sid" -- --model opus
  [ "$status" -eq 0 ]
  grep -q "ARGS=--resume $sid --model opus" "$CLAUDE_STUB_LOG"
}

@test "resume picks the most recent when a session id is in two tanks" {
  _install_claude_stub
  clikae init claude a
  clikae init claude b
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sid="cccccccc-dddd-eeee-ffff-000000000000"
  _seed_transcript a "$work" "$sid"
  _seed_transcript b "$work" "$sid"
  # Make tank b's copy strictly newer than a's (distinct mtimes, not sub-second ties).
  local slug; slug="$(_slug "$work")"
  touch -t 202601010000 "$CLIKAE_HOME/profiles/claude/a/projects/$slug/$sid.jsonl"
  touch -t 202606250000 "$CLIKAE_HOME/profiles/claude/b/projects/$slug/$sid.jsonl"

  cd "$TEST_HOME"
  unset CLAUDE_CONFIG_DIR
  run clikae resume "$sid"
  [ "$status" -eq 0 ]
  grep -q "CLAUDE_CONFIG_DIR=$CLIKAE_HOME/profiles/claude/b" "$CLAUDE_STUB_LOG"
}

@test "resume --help shows usage" {
  run clikae resume --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: clikae resume"* ]]
}

@test "resume is a reserved command (not mistaken for a tank)" {
  run clikae resume "no-such-session-id-xyz"
  [ "$status" -ne 0 ]
  # The error is resume's "No session", not the dispatcher's "Unknown command".
  [[ "$output" == *"No session"* ]]
}

# --- resume ask-tank (lib/core/resume_settings.sh) -----------------------------

@test "resume ask-tank defaults to always, with no setting file" {
  run clikae resume ask-tank
  [ "$status" -eq 0 ]
  [[ "$output" == *"always"* ]] || false
  [ ! -f "$CLIKAE_HOME/resume-ask-tank" ]
}

@test "resume ask-tank <value> persists and reports back" {
  run clikae resume ask-tank dry-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-only"* ]] || false
  [ "$(cat "$CLIKAE_HOME/resume-ask-tank")" = "dry-only" ]
  run clikae resume ask-tank
  [[ "$output" == *"dry-only"* ]]
}

@test "resume ask-tank rejects an unknown value" {
  run clikae resume ask-tank sometimes
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown choice"* ]]
}

# --- _resume_carry_session (lib/core/session_carry.sh) -------------------------
# Unit-level: the shared cross-tank session copy, exercised directly (no TTY
# needed) so both `clikae resume`'s picker and the home board's carry action are
# covered by testing the one function they both call.

@test "_resume_carry_session copies a claude transcript into the target tank, source untouched" {
  _source_session_carry
  clikae init claude a >/dev/null
  clikae init claude b >/dev/null
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sid="cccccccc-1111-2222-3333-444444444444"
  _seed_transcript a "$work" "$sid"
  cd "$TEST_HOME"; load_adapter claude
  _resume_carry_session claude a b "$sid"
  [ -f "$CLIKAE_HOME/profiles/claude/b/projects/$(_slug "$work")/$sid.jsonl" ]
  [ -f "$CLIKAE_HOME/profiles/claude/a/projects/$(_slug "$work")/$sid.jsonl" ]   # source untouched
}

@test "_resume_carry_session copies a codex rollout into the target tank" {
  _source_session_carry
  clikae init codex a >/dev/null
  clikae init codex b >/dev/null
  local sid="dddddddd-1111-2222-3333-444444444444"
  local rdir="$CLIKAE_HOME/profiles/codex/a/sessions/2026/07/05"
  mkdir -p "$rdir"
  printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$sid" "$TEST_HOME" \
    > "$rdir/rollout-2026-07-05T00-00-00-$sid.jsonl"
  load_adapter codex
  _resume_carry_session codex a b "$sid"
  find "$CLIKAE_HOME/profiles/codex/b/sessions" -name "*$sid.jsonl" | grep -q .
  find "$CLIKAE_HOME/profiles/codex/a/sessions" -name "*$sid.jsonl" | grep -q .   # source untouched
}

@test "_resume_carry_session copies antigravity brain + conversation db into the target tank" {
  _source_session_carry
  local sid="eeeeeeee-1111-2222-3333-444444444444"
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/a/antigravity-cli/brain/$sid"
  echo "note" > "$CLIKAE_HOME/profiles/antigravity/a/antigravity-cli/brain/$sid/note.txt"
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/a/antigravity-cli/conversations"
  echo "db" > "$CLIKAE_HOME/profiles/antigravity/a/antigravity-cli/conversations/$sid.db"
  _resume_carry_session antigravity a b "$sid"
  [ -f "$CLIKAE_HOME/profiles/antigravity/b/antigravity-cli/brain/$sid/note.txt" ]
  [ -f "$CLIKAE_HOME/profiles/antigravity/b/antigravity-cli/conversations/$sid.db" ]
  [ -f "$CLIKAE_HOME/profiles/antigravity/a/antigravity-cli/brain/$sid/note.txt" ]   # source untouched
}

@test "_resume_carry_session is a safe no-op when there's nothing to find" {
  _source_session_carry
  clikae init claude a >/dev/null
  clikae init claude b >/dev/null
  load_adapter claude
  run _resume_carry_session claude a b "no-such-session"
  [ "$status" -eq 0 ]
}

@test "resume works on a SINGLE-engine store (unmatched globs for other engines must not kill it)" {
  # Regression: with only claude tanks, the codex/antigravity globs reach stat
  # as literal paths; stat's non-zero + pipefail + set -e killed resume/cleanup
  # dead silent for every single-engine user. Caught by the 2026-07-11
  # ephemeral red-team review.
  #
  # The store is a REAL tank now (`clikae init`), not a bare directory that
  # merely looks like one: the enumerator behind this list walks
  # tanks_for_engine, the same "what is a tank" answer the board has used since
  # #61, instead of globbing profiles/<engine>/*/. What this test is about —
  # a store with one engine in it must not die on the engines it has nothing
  # for — is unchanged, and it now exercises the shape a user actually has.
  clikae init claude only >/dev/null
  mkdir -p "$CLIKAE_HOME/profiles/claude/only/projects/-x"
  printf '{"type":"summary","aiTitle":"solo"}\n' > "$CLIKAE_HOME/profiles/claude/only/projects/-x/eeee-ffff.jsonl"
  CLIKAE_NO_INTERACTIVE=1 run clikae resume
  [ "$status" -eq 0 ]
  [[ "$output" == *"solo"* ]] || false
  run clikae resume cleanup --dry-run --older-than 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude/only"* ]] || false
}

@test "resume goes through the tmux path, the way the board's resume always has" {
  # `clikae resume` used to call adapter_run directly, so it was the one
  # user-facing entry point that started an engine with no tmux — no wake
  # watcher, no scrollback capture, no roaming — while the board's own resume
  # (home.sh: exec clikae <engine> <tank> -- <resume-args>) always had them.
  # Same intention, two different sessions, depending only on how you typed it.
  # Needs a real pty: without one, switch is entitled to run the engine directly.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init claude R
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sid="99999999-8888-7777-6666-555555555555"
  _seed_transcript R "$work" "$sid"

  # Stays alive, so the session is still there when we look.
  mkdir -p "$TEST_HOME/bin"
  printf '#!/usr/bin/env bash\nsleep 20\n' > "$TEST_HOME/bin/claude"
  chmod +x "$TEST_HOME/bin/claude"
  export PATH="$TEST_HOME/bin:$PATH"

  # Our own socket (helpers.bash), so this can never reach a real tank.
  tmux kill-server 2>/dev/null || true

  run python3 - "$CLIKAE_BIN" "$sid" <<'PYEOF'
import os, fcntl, termios, struct, sys, time
clikae, sid = sys.argv[1], sys.argv[2]
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
if os.fork() == 0:
    os.setsid(); fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    for fd in (0, 1, 2): os.dup2(slave, fd)
    os.close(master); os.close(slave)
    os.environ["TERM"] = "xterm-256color"
    os.execv(clikae, [clikae, "resume", sid])
os.close(slave); time.sleep(6)
PYEOF
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run tmux list-sessions -F '#{session_name}'
  local sessions="$output"
  tmux kill-server 2>/dev/null || true
  [[ "$sessions" == *"clikae-claude-R"* ]] || { echo "resume started no tmux session: '$sessions'"; false; }
}

# #74 round-1 P3-2: CLIKAE_RESUME_ALL used to be `export`ed — it is only ever
# read inside this same clikae process (the picker's filter, the non-
# interactive list), never needed by the resumed engine, and `export` let it
# leak into the engine's environment (the same class of incident claude.sh's
# CLIKAE_LAUNCH_SID comment records: an exported clikae-internal variable
# reaching a process it was never meant for).
@test "resume --all does not leak CLIKAE_RESUME_ALL into the resumed engine's environment" {
  mkdir -p "$TEST_HOME/bin"
  cat > "$TEST_HOME/bin/claude" <<'STUB'
#!/usr/bin/env bash
env > "$CLAUDE_STUB_LOG"
exit 0
STUB
  chmod +x "$TEST_HOME/bin/claude"
  export PATH="$TEST_HOME/bin:$PATH"
  export CLAUDE_STUB_LOG="$TEST_HOME/stub.log"
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sid="66666666-7777-4888-9999-000000000000"
  _seed_transcript a "$work" "$sid"
  cd "$TEST_HOME"
  unset CLAUDE_CONFIG_DIR
  run clikae resume --all "$sid"
  [ "$status" -eq 0 ]
  [ -s "$CLAUDE_STUB_LOG" ]
  ! grep -q '^CLIKAE_RESUME_ALL=' "$CLAUDE_STUB_LOG"
}

# --- #34 GAP 2: `clikae resume <agy-sid>` must actually hand agy
# `--conversation <sid>`, not silently launch a bare/new session. -------------
# adapter_resume_args used `printf '--conversation\n%s\n' "$sid"` — bash's
# printf builtin parses a leading `--conversation` as an unknown OPTION
# (rc=2, no stdout), so rargs ended up EMPTY and resume exec'd agy with no
# --conversation at all. No bats anywhere covered this path (only
# grok.bats/codex.bats checked their own adapter_resume_args). A fake `agy` on
# PATH records its real argv so this is a genuine end-to-end check, not just a
# direct call to the adapter function.
@test "resume hands agy '--conversation <sid>' end to end, not a bare relaunch (#34)" {
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | clikae init agy default >/dev/null 2>&1

  local sid="aaaaaaaa-0000-4000-8000-000000000001"
  local base="$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli"
  mkdir -p "$base/brain/$sid/.system_generated/logs"
  printf '{"content":"CWD-MATCH session content"}\n' \
    > "$base/brain/$sid/.system_generated/logs/transcript.jsonl"

  local work="$TEST_HOME/work-project"; mkdir -p "$work"
  printf '{"conversation_id":"%s","workspace":"%s"}\n' "$sid" "$work" \
    > "$base/brain/history.jsonl"
  cd "$work" || return 1

  # A fake `agy` that records its real argv — $TEST_HOME/.testbin is already
  # first on PATH (helpers.bash), same place pgrep/security are stubbed.
  local argv_log="$TEST_HOME/agy_argv.log"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf '"'"'%%s\\n'"'"' "$@" > %s\n' "$(printf '%q' "$argv_log")"
    printf 'exit 0\n'
  } > "$TEST_HOME/.testbin/agy"
  chmod +x "$TEST_HOME/.testbin/agy"

  run clikae resume "$sid"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$argv_log" ] || { echo "agy stub was never invoked — resume: $output"; false; }
  grep -qF -- "--conversation" "$argv_log" || { echo "argv: $(cat "$argv_log")"; false; }
  grep -qF "$sid" "$argv_log" || { echo "argv: $(cat "$argv_log")"; false; }
}

# --- the engine list `clikae resume` scans with ------------------------------
# `_resume_all_sessions` used to be three hand-typed globs, and its own comment
# said a new resumable engine's glob "goes here only". grok landed on
# 2026-07-31 with adapter_resume_args, adapter_recent_sids, adapter_find_session
# and adapter_session_cwd — it reached the home board, and every store-wide
# surface (the picker, prefix resolution, `clikae clean`'s scan) stayed blind to
# it, because nobody extended a list that had no way to say it was incomplete.
# The enumeration goes through the adapters now, so this test is about a
# mechanism, not about grok: an engine that CAN be resumed is enumerated.
@test "a grok session is reachable by prefix — resume enumerates through the adapters, not a glob list" {
  clikae init grok g

  local sid="019fb7b0-9b86-7f82-98a4-0000000000aa"
  local work="$TEST_HOME/grok-work"; mkdir -p "$work"
  local d="$CLIKAE_HOME/profiles/grok/g/sessions/%2Fgrok-work/$sid"
  mkdir -p "$d"
  cat > "$d/summary.json" <<JSON
{
  "info": {
    "id": "$sid",
    "cwd": "$work"
  },
  "session_summary": "GROK-PREFIX-FIXTURE",
  "generated_title": "GROK-PREFIX-FIXTURE"
}
JSON

  local argv_log="$TEST_HOME/grok_argv.log"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf '"'"'%%s\\n'"'"' "$@" > %s\n' "$(printf '%q' "$argv_log")"
    printf 'exit 0\n'
  } > "$TEST_HOME/.testbin/grok"
  chmod +x "$TEST_HOME/.testbin/grok"

  cd "$TEST_HOME" || return 1      # NOT the session's own directory
  # Eight characters is what the tmux status line shows, and prefix resolution
  # is the surface that reads the store-wide scan (_resume_prefix_candidates).
  run clikae resume "${sid:0:8}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$argv_log" ] || { echo "grok stub was never invoked — resume said: $output"; false; }
  grep -qF -- "--resume" "$argv_log" || { echo "argv: $(cat "$argv_log")"; false; }
  grep -qF "$sid" "$argv_log" || { echo "argv: $(cat "$argv_log")"; false; }
}

# The same enumeration, from the other end: a MISS has to be reportable. The
# store-wide locate used to inherit its exit status from the last tank it
# looked in, so with a tank for the last resume-capable engine (alphabetically
# grok) a miss killed the command under `set -e` — no "No session" line, and no
# prefix retry either, since the retry is downstream of that return.
@test "a miss is reported, not a silent death, when the last resume-capable engine has a tank" {
  clikae init grok g
  run clikae resume deadbeef
  [ "$status" -ne 0 ]
  [[ "$output" == *"No session"* ]] || { echo "output was: $output"; false; }
}

# --- claude's subagent transcripts are not conversations ---------------------
# claude writes a subagent's transcript beside its parent's as
# `agent-<id>.jsonl` (every line `"isSidechain":true`). They cannot be reopened
# — `claude --resume agent-<id>` answers "not a UUID and does not match any
# session title" — and on a working store they outnumber real sessions, titled
# with whatever brief the parent dispatched ("Effort: high. Expected ~60 tool
# steps…"). So they are out of every LIST and COUNT, and out of nothing else.
_seed_agent_transcript() {   # <tank> <dir> <sid> ; echoes the path
  local tank="$1" dir="$2" sid="$3" slug
  slug="$(_slug "$dir")"
  mkdir -p "$CLIKAE_HOME/profiles/claude/$tank/projects/$slug"
  printf '{"type":"user","isSidechain":true,"cwd":"%s","message":{"role":"user","content":"Effort: high. Expected ~60 tool steps."}}\n' "$dir" \
    > "$CLIKAE_HOME/profiles/claude/$tank/projects/$slug/agent-$sid.jsonl"
  printf '%s\n' "$CLIKAE_HOME/profiles/claude/$tank/projects/$slug/agent-$sid.jsonl"
}

@test "the resume list leaves out claude's subagent transcripts" {
  clikae init claude a
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed_transcript a "$work" "11111111-2222-3333-4444-555555555555"
  _seed_agent_transcript a "$work" "99999999-2222-3333-4444-555555555555" >/dev/null

  cd "$work" || return 1
  CLIKAE_NO_INTERACTIVE=1 run clikae resume
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"11111111-2222-3333-4444-555555555555"* ]] || { echo "$output"; false; }
  [[ "$output" != *"agent-99999999"* ]] || { echo "subagent listed: $output"; false; }
  [[ "$output" != *"Expected ~60 tool steps"* ]] || { echo "subagent listed: $output"; false; }
}

@test "a full subagent id still LOCATES its tank — only the lists are narrowed" {
  _install_claude_stub
  clikae init claude a
  clikae init claude b
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed_agent_transcript b "$work" "99999999-2222-3333-4444-555555555555" >/dev/null

  cd "$TEST_HOME" || return 1          # NOT the session's dir
  unset CLAUDE_CONFIG_DIR
  run clikae resume "agent-99999999-2222-3333-4444-555555555555"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # The tank was found and clikae cd'd into the recorded directory before
  # handing over — what clikae owns. (The engine's own refusal to resume a
  # sidechain id is the engine's answer, and the reason these are not listed.)
  grep -q "CLAUDE_CONFIG_DIR=$CLIKAE_HOME/profiles/claude/b" "$CLAUDE_STUB_LOG"
  grep -q "PWD=$work" "$CLAUDE_STUB_LOG"
  grep -q "ARGS=--resume agent-99999999-2222-3333-4444-555555555555" "$CLAUDE_STUB_LOG"
}

# _resume_enumerate [--resumable] -> the store scan's own output, sourced the
# way bin/clikae sources it. Asserting the ENUMERATOR rather than `clean`'s
# screen keeps this test about the contract that changed; what clean then does
# with a candidate (age, size, live-session guards) is clean's own business and
# has its own suite.
_resume_enumerate() {
  bash -c '
    set -eo pipefail
    export CLIKAE_LIB="$1" CLIKAE_HOME="$2"
    for m in log i18n json profile_store adapter_loader; do . "$CLIKAE_LIB/core/$m.sh"; done
    . "$CLIKAE_LIB/commands/resume.sh"
    _resume_all_sessions ${3:+"$3"}
  ' _ "$CLIKAE_TEST_ROOT/lib" "$CLIKAE_HOME" "${1:-}"
}

@test "the store scan still hands clean a subagent transcript — it is disk, and that is clean's job" {
  clikae init claude only
  local work="$TEST_HOME/work"; mkdir -p "$work"
  _seed_transcript only "$work" "11111111-2222-3333-4444-555555555555"
  _seed_agent_transcript only "$work" "99999999-2222-3333-4444-555555555555" >/dev/null

  # What `clikae clean` asks for: everything on disk.
  run _resume_enumerate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"agent-99999999"* ]] || { echo "clean would never see it: $output"; false; }
  [[ "$output" == *"11111111-2222"* ]] || { echo "$output"; false; }

  # What every LIST asks for: conversations only.
  run _resume_enumerate --resumable
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"agent-99999999"* ]] || { echo "subagent in the list scan: $output"; false; }
  [[ "$output" == *"11111111-2222"* ]] || { echo "$output"; false; }
}
