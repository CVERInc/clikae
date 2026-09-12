#!/usr/bin/env bats
# Burn provenance and resume filtering, using only temporary homes and stub engines.

load '../helpers'

_fixture() {
  # Exercise the documented override, not just its default $HOME/.clikae value.
  mv "$CLIKAE_HOME" "$TEST_HOME/store"
  export CLIKAE_HOME="$TEST_HOME/store"
  unset CLIKAE_RESUME_ALL
  export STUB_ARGV_LOG="$TEST_HOME/argv" STUB_ARTIFACT="$TEST_HOME/result"
  export STUB_SID="22222222-2222-4222-8222-222222222222"
  export HUMAN_SID="11111111-1111-4111-8111-111111111111"
  # Force direct, synchronous execution even on machines with tmux installed.
  export RESUME_TEST_PATH="$PATH"
  local direct_bin="$TEST_HOME/direct-bin"
  mkdir -p "$direct_bin"
  python3 - "$direct_bin" <<'PY'
import os, sys
for directory in os.environ['PATH'].split(os.pathsep):
    if not os.path.isdir(directory):
        continue
    for name in os.listdir(directory):
        src = os.path.join(directory, name)
        dst = os.path.join(sys.argv[1], name)
        if name != 'tmux' and os.path.isfile(src) and os.access(src, os.X_OK) and not os.path.lexists(dst):
            os.symlink(os.path.abspath(src), dst)
PY
  export PATH="$direct_bin"
  mkdir -p "$TEST_HOME/bin" "$TEST_HOME/work"
  export PATH="$TEST_HOME/bin:$PATH"
  cd "$TEST_HOME/work" || return
  git init -q .
  cat > "$TEST_HOME/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$STUB_ARGV_LOG"
sid=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session-id ]; then sid="$2"; break; fi
  shift
done
if [ -n "$sid" ]; then
  slug="$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/$slug"
  printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"Automated task"}}\n' "$PWD" > "$CLAUDE_CONFIG_DIR/projects/$slug/$sid.jsonl"
fi
printf 'done\n' > "$STUB_ARTIFACT"
STUB
  cat > "$TEST_HOME/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$STUB_ARGV_LOG"
mkdir -p "$CODEX_HOME/sessions/2026/09/13"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$STUB_SID" "$PWD" > "$CODEX_HOME/sessions/2026/09/13/rollout-2026-09-13T00-00-00-$STUB_SID.jsonl"
printf 'done\n' > "$STUB_ARTIFACT"
STUB
  cat > "$TEST_HOME/bin/agy" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$STUB_ARGV_LOG"
while [ "$#" -gt 0 ]; do
  if [ "$1" = --log-file ]; then : > "$2"; break; fi
  shift
done
base="$HOME/.gemini/antigravity-cli"
mkdir -p "$base/brain/$STUB_SID/.system_generated/logs"
printf '{"content":"Automated task"}\n' > "$base/brain/$STUB_SID/.system_generated/logs/transcript.jsonl"
printf '{"conversation_id":"%s","workspace":"%s"}\n' "$STUB_SID" "$PWD" >> "$base/brain/history.jsonl"
printf 'done\n' > "$STUB_ARTIFACT"
STUB
  chmod +x "$TEST_HOME/bin/claude" "$TEST_HOME/bin/codex" "$TEST_HOME/bin/agy"
}

teardown() {
  export PATH="${RESUME_TEST_PATH:-$PATH}"
  [ -z "${TEST_HOME:-}" ] || rm -rf "$TEST_HOME"
}

_human_claude() {
  local slug
  slug="$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$CLIKAE_HOME/profiles/claude/T1/projects/$slug"
  printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"Human conversation"}}\n' "$PWD" > "$CLIKAE_HOME/profiles/claude/T1/projects/$slug/$HUMAN_SID.jsonl"
}

_burn() {
  run clikae burn "$1" "$2" --prompt 'Write the artifact' --add-dir "$PWD" --artifact "$STUB_ARTIFACT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -s "$STUB_ARTIFACT" ]
  [ -s "$STUB_ARGV_LOG" ]
}

_assert_sidecar() {
  local file="$CLIKAE_HOME/state/burn-sessions/$1/$2"
  [ -f "$file" ]
  [ "$(wc -l < "$file" | tr -d ' ')" = 1 ]
  awk -F '\t' -v sid="$3" 'NF != 3 || $1 != sid || $2 == "" || $3 !~ /^[0-9]+$/ {exit 1}' "$file"
  [ ! -d "$HOME/.clikae/state/burn-sessions" ]
}

@test "burn records exactly the Claude session id passed to the engine" {
  _fixture
  clikae init claude T1
  _burn claude T1
  local sid
  sid="$(awk '$0 == "--session-id" {getline; print}' "$STUB_ARGV_LOG")"
  [ -n "$sid" ]
  _assert_sidecar claude T1 "$sid"
}

@test "resume hides burn sessions by default and --all labels their row" {
  _fixture
  clikae init claude T1
  _human_claude
  _burn claude T1
  local sid
  sid="$(cut -f1 "$CLIKAE_HOME/state/burn-sessions/claude/T1")"
  [ -n "$sid" ]
  run clikae resume
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HUMAN_SID"* ]] || false
  [[ "$output" != *"$sid"* ]] || false
  run clikae resume --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HUMAN_SID"* ]] || false
  [[ "$output" == *"$sid"* ]] || false
  [[ "$output" == *'"[burn] Automated task"'* ]] || false
  [[ "$output" != *'[burn] Human conversation'* ]] || false
}

@test "codex burn records the newest transcript written during the run" {
  _fixture
  clikae init codex T1
  local old="$CLIKAE_HOME/profiles/codex/T1/sessions/2026/09/13"
  mkdir -p "$old"
  printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$HUMAN_SID" "$PWD" > "$old/rollout-2026-09-13T23-59-59-$HUMAN_SID.jsonl"
  touch -t 202001010000 "$old/rollout-2026-09-13T23-59-59-$HUMAN_SID.jsonl"
  _burn codex T1
  _assert_sidecar codex T1 "$STUB_SID"
}

_agy_fixture() {
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy default >/dev/null 2>&1
  local base="$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli"
  mkdir -p "$base/brain/$HUMAN_SID/.system_generated/logs" "$base/cache"
  printf '{"content":"Human conversation"}\n' > "$base/brain/$HUMAN_SID/.system_generated/logs/transcript.jsonl"
  touch -t 202001010000 "$base/brain/$HUMAN_SID/.system_generated/logs/transcript.jsonl"
  printf '{"conversation_id":"%s","workspace":"%s"}\n' "$HUMAN_SID" "$PWD" > "$base/brain/history.jsonl"
  # Deliberately stale: the latest engine transcript must beat this cached id.
  printf '{"%s":"%s"}\n' "$PWD" "$HUMAN_SID" > "$base/cache/last_conversations.json"
}

@test "agy burn records the newest on-disk transcript even with a stale cache" {
  _fixture
  _agy_fixture
  _burn agy default
  _assert_sidecar agy default "$STUB_SID"
}

@test "agy session absent from the cache still resolves from its transcript" {
  _fixture
  _agy_fixture
  local base="$CLIKAE_HOME/profiles/antigravity/default"
  mkdir -p "$base/antigravity-cli/brain/$STUB_SID/.system_generated/logs"
  printf '{"content":"Uncached conversation"}\n' > "$base/antigravity-cli/brain/$STUB_SID/.system_generated/logs/transcript.jsonl"
  # Direct adapter lookup is also how resume locates a supplied sid.
  # shellcheck source=../../lib/adapters/antigravity.sh
  source "$CLIKAE_LIB/adapters/antigravity.sh"
  run adapter_find_session "$base" "$STUB_SID"
  [ "$status" -eq 0 ]
  [ "$output" = "$base/antigravity-cli/brain/$STUB_SID/.system_generated/logs/transcript.jsonl" ]
  run clikae resume
  [ "$status" -eq 0 ]
  [[ "$output" == *"$STUB_SID"* ]] || false
}

@test "clean removes a stale state candidate but preserves burn sidecars byte for byte" {
  _fixture
  mv "$CLIKAE_HOME" "$HOME/.clikae"
  export CLIKAE_HOME="$HOME/.clikae"
  clikae init claude T1
  _burn claude T1
  local sidecars="$CLIKAE_HOME/state/burn-sessions"
  cp -R "$sidecars" "$TEST_HOME/sidecar-before"
  # State GC runs even for non-TTY clean; transcript deletion requires the picker.
  mkdir -p "$HOME/.clikae/state"
  local dead=999999
  if kill -0 "$dead" 2>/dev/null; then skip "fixture pid is alive"; fi
  local candidate="$HOME/.clikae/state/tank-busy-claude_T2.lock"
  ln -s "$dead:1700000000" "$candidate"
  run clikae clean
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -L "$candidate" ]
  [ -d "$sidecars" ]
  diff -r "$TEST_HOME/sidecar-before" "$sidecars"
}

@test "resume ignores malformed sidecar records without hiding a human session" {
  _fixture
  clikae init claude T1
  _human_claude
  mkdir -p "$CLIKAE_HOME/state/burn-sessions/claude"
  printf '\n%s\n%s\trun\tnot-an-epoch\n%s\trun\t123\textra\n' "$HUMAN_SID" "$HUMAN_SID" "$HUMAN_SID" > "$CLIKAE_HOME/state/burn-sessions/claude/T1"
  run clikae resume
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"$HUMAN_SID"* ]] || false
  run clikae resume --all
  [ "$status" -eq 0 ]
  [[ "$output" != *'[burn]'* ]] || false
}
