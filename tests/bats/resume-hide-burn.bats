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
# Real codex's -C changes ITS OWN cwd before it does anything else — a
# session's recorded "cwd" is wherever -C pointed, not the caller's $PWD.
while [ "$#" -gt 0 ]; do
  if [ "$1" = -C ]; then cd "$2" || exit 1; break; fi
  shift
done
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

# #74 round-1 P1-1: the sidecar holding the right sid is necessary but not
# sufficient — resume's picker must derive that SAME sid from the rollout
# path to actually hide it. codex's two derivations used to disagree (a
# hyphen-embedding uuid vs "everything after the last hyphen"), so this
# scenario's sidecar was byte-correct and the row stayed visible anyway.
@test "codex burn session actually hides in resume (not just recorded in the sidecar)" {
  _fixture
  clikae init codex T1
  _human_claude   # a human claude session too, in the same store, must stay visible
  _burn codex T1
  local sid
  sid="$(cut -f1 "$CLIKAE_HOME/state/burn-sessions/codex/T1")"
  [ -n "$sid" ]
  [ "${#sid}" -eq 36 ]
  run clikae resume
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HUMAN_SID"* ]] || false
  [[ "$output" != *"$sid"* ]] || false
  run clikae resume --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"$sid"* ]] || false
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

# --- #74 round-1 P1-2/P2-3: sidecar attribution must be PROVEN (a before/after
# transcript-set diff), not guessed (the old "newest mtime >= attempt start"
# heuristic, which happily attributed a human's own concurrent session to the
# lane that never touched it). Zero transcripts -> no ghost sid on a
# dry/failed run either. ------------------------------------------------------

@test "agy burn writes no sidecar line when the run produces zero transcripts" {
  _fixture
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy default >/dev/null 2>&1
  cat > "$TEST_HOME/bin/agy" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$STUB_ARGV_LOG"
while [ "$#" -gt 0 ]; do
  if [ "$1" = --log-file ]; then : > "$2"; break; fi
  shift
done
printf 'done\n' > "$STUB_ARTIFACT"   # artifact written, but NO transcript at all
STUB
  chmod +x "$TEST_HOME/bin/agy"
  _burn agy default
  [ ! -e "$CLIKAE_HOME/state/burn-sessions/agy/default" ]
}

@test "agy burn records nothing (not the wrong one) when it can't tell its own new session apart from a concurrent one" {
  _fixture
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | "$CLIKAE_BIN" init agy default >/dev/null 2>&1
  local other_sid="99999999-9999-4999-8999-999999999999"
  cat > "$TEST_HOME/bin/agy" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$STUB_ARGV_LOG"
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = --log-file ]; then : > "\$2"; break; fi
  shift
done
base="\$HOME/.gemini/antigravity-cli"
mkdir -p "\$base/brain/$STUB_SID/.system_generated/logs" "\$base/brain/$other_sid/.system_generated/logs"
printf '{"content":"lane task"}\n' > "\$base/brain/$STUB_SID/.system_generated/logs/transcript.jsonl"
printf '{"content":"a human, same cwd, same instant"}\n' > "\$base/brain/$other_sid/.system_generated/logs/transcript.jsonl"
printf '{"conversation_id":"%s","workspace":"%s"}\n' "$STUB_SID" "\$PWD" >> "\$base/brain/history.jsonl"
printf '{"conversation_id":"%s","workspace":"%s"}\n' "$other_sid" "\$PWD" >> "\$base/brain/history.jsonl"
printf 'done\n' > "$STUB_ARTIFACT"
STUB
  chmod +x "$TEST_HOME/bin/agy"
  run clikae burn agy default --prompt 'Write the artifact' --add-dir "$PWD" --artifact "$STUB_ARTIFACT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not attribute session"* ]] || false
  [ ! -e "$CLIKAE_HOME/state/burn-sessions/agy/default" ]
}

@test "codex burn writes no sidecar line when the run produces zero transcripts" {
  _fixture
  clikae init codex T1
  cat > "$TEST_HOME/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$STUB_ARGV_LOG"
printf 'done\n' > "$STUB_ARTIFACT"   # artifact written, but NO rollout at all
STUB
  chmod +x "$TEST_HOME/bin/codex"
  _burn codex T1
  [ ! -e "$CLIKAE_HOME/state/burn-sessions/codex/T1" ]
}

# #74 round-2 P2-2: "proven" used to read adapter_find_session's EXIT CODE,
# but codex/grok both return 0 (success) on a miss — empty stdout, no
# matching rollout on disk. A caller-supplied `-- exec resume <sid>` (P2-3's
# minted-vs-caller-supplied path) recorded that sid as proven the moment
# codex accepted the flag, whether or not the sid corresponded to any real
# rollout on this profile.
@test "#74 round-2 P2-2: codex burn with a caller-supplied --resume sid that matches zero transcripts writes no ghost sidecar line" {
  _fixture
  clikae init codex T1
  local fake_sid="99999999-9999-4999-8999-999999999999"
  # Models codex accepting an unknown `resume <sid>` without erroring on it
  # and without ever writing a rollout for that sid.
  cat > "$TEST_HOME/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$STUB_ARGV_LOG"
printf 'done\n' > "$STUB_ARTIFACT"
STUB
  chmod +x "$TEST_HOME/bin/codex"
  run clikae burn codex T1 --artifact "$STUB_ARTIFACT" -- exec --skip-git-repo-check resume "$fake_sid" go
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$CLIKAE_HOME/state/burn-sessions/codex/T1" ]
}

@test "codex burn picks the ONE new rollout whose recorded cwd is this run's, among several" {
  _fixture
  clikae init codex T1
  local elsewhere_sid="88888888-8888-4888-8888-888888888888"
  cat > "$TEST_HOME/bin/codex" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$STUB_ARGV_LOG"
mkdir -p "\$CODEX_HOME/sessions/2026/09/13"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$STUB_SID" "\$PWD" > "\$CODEX_HOME/sessions/2026/09/13/rollout-2026-09-13T00-00-00-$STUB_SID.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"/somewhere/else"}}\n' "$elsewhere_sid" > "\$CODEX_HOME/sessions/2026/09/13/rollout-2026-09-13T00-00-01-$elsewhere_sid.jsonl"
printf 'done\n' > "$STUB_ARTIFACT"
STUB
  chmod +x "$TEST_HOME/bin/codex"
  _burn codex T1
  _assert_sidecar codex T1 "$STUB_SID"
}

# --- #74 round-2 P1-1: the tie-break used to compare each candidate's
# recorded cwd against $PWD — this SHELL's cwd, not the cwd codex actually
# ran in (-C, which defaults to dirname("$artifact")). Any --artifact outside
# $PWD (or an explicit --add-dir) made burn's OWN session stop matching here,
# leaving a concurrent human session in $PWD as the sole "match" — recorded
# and hidden. -------------------------------------------------------------

@test "#74 round-2 P1-1: codex burn attributes to its own -C launch dir, not the caller's \$PWD, and never hides a concurrent human session there" {
  _fixture
  clikae init codex T1
  mkdir -p "$TEST_HOME/repo"
  (cd "$TEST_HOME/repo" && git init -q .)
  local artifact="$TEST_HOME/repo/result"
  export STUB_ARTIFACT="$artifact"   # the stub writes wherever THIS points, not --artifact
  # Two transcripts appear DURING the run (both "new" against the before
  # snapshot): burn's own, whose recorded cwd is codex's -C launch dir
  # (dirname("$artifact") here, since no --add-dir was given); and a
  # concurrent human's, whose recorded cwd is the CALLER's $PWD ($TEST_HOME/work).
  # Old code compared each candidate's cwd against THIS SHELL's $PWD, so it
  # picked the human's and never burn's own.
  cat > "$TEST_HOME/bin/codex" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$STUB_ARGV_LOG"
orig_pwd="\$PWD"
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = -C ]; then cd "\$2" || exit 1; break; fi
  shift
done
mkdir -p "\$CODEX_HOME/sessions/2026/09/13"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$STUB_SID" "\$PWD" > "\$CODEX_HOME/sessions/2026/09/13/rollout-2026-09-13T00-00-00-$STUB_SID.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$HUMAN_SID" "\$orig_pwd" > "\$CODEX_HOME/sessions/2026/09/13/rollout-2026-09-13T00-00-01-$HUMAN_SID.jsonl"
printf 'done\n' > "$STUB_ARTIFACT"
STUB
  chmod +x "$TEST_HOME/bin/codex"
  run clikae burn codex T1 --prompt 'Write the artifact' --artifact "$artifact"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -s "$artifact" ]
  _assert_sidecar codex T1 "$STUB_SID"
  run clikae resume --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"$STUB_SID"* ]] || false
  [[ "$output" == *"$HUMAN_SID"* ]] || false
  run clikae resume
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HUMAN_SID"* ]] || false
  [[ "$output" != *"$STUB_SID"* ]] || false
}

@test "#74 round-2 P1-1: with an explicit --add-dir \"\$PWD\" the two-candidate tie still records nothing" {
  _fixture
  clikae init codex T1
  local other_sid="77777777-7777-4777-8777-777777777777"
  cat > "$TEST_HOME/bin/codex" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$STUB_ARGV_LOG"
mkdir -p "\$CODEX_HOME/sessions/2026/09/13"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$STUB_SID" "\$PWD" > "\$CODEX_HOME/sessions/2026/09/13/rollout-2026-09-13T00-00-00-$STUB_SID.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$other_sid" "\$PWD" > "\$CODEX_HOME/sessions/2026/09/13/rollout-2026-09-13T00-00-01-$other_sid.jsonl"
printf 'done\n' > "$STUB_ARTIFACT"
STUB
  chmod +x "$TEST_HOME/bin/codex"
  run clikae burn codex T1 --prompt 'Write the artifact' --add-dir "$PWD" --artifact "$STUB_ARTIFACT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"could not attribute session"* ]] || false
  [ ! -e "$CLIKAE_HOME/state/burn-sessions/codex/T1" ]
}

# --- #74 round-3 P1-1: raw '-- <cmd...>' mode reruns round-2's P1-1 exactly —
# _burn_launch_cwd used to stay at its "$PWD" default for this path no matter
# what the user's own argv said, because both places that ever reset it
# (_burn_compose's two call sites) are gated on prompt_set==1. codex's OWN -C
# can be given directly after `--` (this is literally burn --help's own raw
# example, burn.sh:118), so a caller-supplied `-C` outside $PWD reproduced
# round-2's exact bug on this path: burn's own session stopped matching and a
# concurrent human session in $PWD got recorded and hidden instead. ---------

@test "#74 round-3 P1-1: raw '-- <cmd...>' codex burn with -C attributes to it, not the caller's \$PWD, and never hides a concurrent human session there" {
  _fixture
  clikae init codex T1
  mkdir -p "$TEST_HOME/repo"
  (cd "$TEST_HOME/repo" && git init -q .)
  local artifact="$TEST_HOME/repo/result"
  # Two transcripts appear DURING the run: burn's own, whose recorded cwd is
  # codex's -C launch dir ($TEST_HOME/repo); and a concurrent human's, whose
  # recorded cwd is the CALLER's $PWD ($TEST_HOME/work, unchanged). Before
  # this fix, _burn_launch_cwd never left its "$PWD" default in raw mode, so
  # the human's transcript was the one that matched.
  cat > "$TEST_HOME/bin/codex" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$STUB_ARGV_LOG"
orig_pwd="\$PWD"
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = -C ]; then cd "\$2" || exit 1; break; fi
  shift
done
mkdir -p "\$CODEX_HOME/sessions/2026/09/13"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$STUB_SID" "\$PWD" > "\$CODEX_HOME/sessions/2026/09/13/rollout-2026-09-13T00-00-00-$STUB_SID.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$HUMAN_SID" "\$orig_pwd" > "\$CODEX_HOME/sessions/2026/09/13/rollout-2026-09-13T00-00-01-$HUMAN_SID.jsonl"
printf 'done\n' > "$artifact"
STUB
  chmod +x "$TEST_HOME/bin/codex"
  run clikae burn codex T1 --artifact "$artifact" -- exec -C "$TEST_HOME/repo" --skip-git-repo-check -s workspace-write 'go'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -s "$artifact" ]
  _assert_sidecar codex T1 "$STUB_SID"
  run clikae resume --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"$STUB_SID"* ]] || false
  [[ "$output" == *"$HUMAN_SID"* ]] || false
  run clikae resume
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HUMAN_SID"* ]] || false
  [[ "$output" != *"$STUB_SID"* ]] || false
}

@test "#74 round-3 P1-1: raw '-- <cmd...>' codex burn WITHOUT -C and two candidates records nothing" {
  _fixture
  clikae init codex T1
  local other_sid="88888888-8888-4888-8888-888888888888"
  cat > "$TEST_HOME/bin/codex" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$STUB_ARGV_LOG"
mkdir -p "\$CODEX_HOME/sessions/2026/09/13"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$STUB_SID" "\$PWD" > "\$CODEX_HOME/sessions/2026/09/13/rollout-2026-09-13T00-00-00-$STUB_SID.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$other_sid" "\$PWD" > "\$CODEX_HOME/sessions/2026/09/13/rollout-2026-09-13T00-00-01-$other_sid.jsonl"
printf 'done\n' > "$STUB_ARTIFACT"
STUB
  chmod +x "$TEST_HOME/bin/codex"
  # No -C at all: adapter_cwd_from_args finds nothing, _burn_launch_cwd is
  # EMPTY, so the tie-break's cwd compare 0-hits both candidates — never
  # falls back to $PWD and picks one by accident.
  run clikae burn codex T1 --artifact "$STUB_ARTIFACT" -- exec -s workspace-write 'go'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"could not attribute session"* ]] || false
  [ ! -e "$CLIKAE_HOME/state/burn-sessions/codex/T1" ]
}

@test "#74 round-4 P2-1: raw '-- <cmd...>' codex burn WITHOUT -C, one candidate's cwd unreadable, records nothing and the human stays visible" {
  _fixture
  clikae init codex T1
  cat > "$TEST_HOME/bin/codex" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$STUB_ARGV_LOG"
mkdir -p "\$CODEX_HOME/sessions/2026/09/13"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$STUB_SID" "\$PWD" > "\$CODEX_HOME/sessions/2026/09/13/rollout-2026-09-13T00-00-00-$STUB_SID.jsonl"
# A concurrent human's rollout whose header line has an id but no cwd field
# yet (the real race: codex creates the file before it flushes cwd into the
# first line) — adapter_session_cwd returns EMPTY for this one, same as
# _burn_launch_cwd in this raw/no-C run. Before this fix, empty == empty
# made it the sole "match".
printf '{"type":"session_meta","payload":{"id":"%s"}}\n' "$HUMAN_SID" > "\$CODEX_HOME/sessions/2026/09/13/rollout-2026-09-13T00-00-01-$HUMAN_SID.jsonl"
printf 'done\n' > "$STUB_ARTIFACT"
STUB
  chmod +x "$TEST_HOME/bin/codex"
  run clikae burn codex T1 --artifact "$STUB_ARTIFACT" -- exec -s workspace-write 'go'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"could not attribute session"* ]] || false
  [ ! -e "$CLIKAE_HOME/state/burn-sessions/codex/T1" ]
  run clikae resume --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HUMAN_SID"* ]] || false
}

@test "#74 round-3 P1-1: burn --help's own raw -C example shape still records the single new session" {
  _fixture
  clikae init codex T1
  # The literal shape documented at burn --help (burn.sh:118) and
  # docs/proposals/issue-24-burn-simplify.md:44 — a single new transcript, so
  # this never even reaches the cwd tie-break, but it must still run clean.
  run clikae burn codex T1 --artifact "$STUB_ARTIFACT" -- exec -C "$TEST_HOME/work" --skip-git-repo-check -s workspace-write 'read in.txt, write out.md'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -s "$STUB_ARTIFACT" ]
  _assert_sidecar codex T1 "$STUB_SID"
}

# --- #74 round-1 P1-3: burn used to append --session-id unconditionally, even
# when the caller's own extra args already carried resume/session identity —
# fighting claude's own rule ("--session-id can only be used with --continue
# or --resume if --fork-session is also specified", verified live 2.1.267)
# and turning a previously-working launch shape into rc=1 with no artifact. --

@test "burn claude does not clash --session-id onto a caller-supplied --resume (was rc=1)" {
  _fixture
  clikae init claude T1
  local existing_sid="33333333-3333-4333-8333-333333333333"
  cat > "$TEST_HOME/bin/claude" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$STUB_ARGV_LOG"
case " \$* " in
  *' --resume '*' --session-id '*|*' --session-id '*' --resume '*)
    echo "error: --session-id can only be used with --continue or --resume if --fork-session is also specified" >&2
    exit 1
    ;;
esac
sid=""
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = --resume ]; then sid="\$2"; break; fi
  shift
done
if [ -n "\$sid" ]; then
  slug="\$(printf '%s' "\$PWD" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "\$CLAUDE_CONFIG_DIR/projects/\$slug"
  printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"resumed"}}\n' "\$PWD" > "\$CLAUDE_CONFIG_DIR/projects/\$slug/\$sid.jsonl"
fi
printf 'done\n' > "$STUB_ARTIFACT"
STUB
  chmod +x "$TEST_HOME/bin/claude"
  run clikae burn claude T1 --artifact "$STUB_ARTIFACT" --add-dir "$PWD" -- -p 'go' --resume "$existing_sid"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -s "$STUB_ARTIFACT" ]
  [[ "$output" != *"--session-id"* ]] || false
  _assert_sidecar claude T1 "$existing_sid"
}

# #74 round-2 P2-3: a caller-supplied `--resume <sid>` names a transcript that
# ALREADY EXISTS before the engine ever runs — "the transcript exists" is a
# tautology for it, true whether or not this run touched anything. The old
# code recorded (and hid) a human's own conversation the moment the engine
# was TOLD to resume it, even when the engine refused to start and never
# read or wrote a single byte of it.
@test "#74 round-2 P2-3: burn claude --resume <existing sid> writes no sidecar line when the engine refuses to start" {
  _fixture
  clikae init claude T1
  _human_claude   # the transcript pre-exists, untouched by this run
  cat > "$TEST_HOME/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$STUB_ARGV_LOG"
echo "error: engine refused to start" >&2
exit 1
STUB
  chmod +x "$TEST_HOME/bin/claude"
  run clikae burn claude T1 --artifact "$STUB_ARTIFACT" --add-dir "$PWD" -- -p 'go' --resume "$HUMAN_SID"
  [ "$status" -ne 0 ]
  [ ! -e "$CLIKAE_HOME/state/burn-sessions/claude/T1" ]
  run clikae resume --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HUMAN_SID"* ]] || false
}

# #74 round-3 P3-2: round-2's own judgment was "rc == 0 OR (mtime,size)
# changed" — an OR, so a FAILED engine whose (mtime,size) changed anyway (a
# concurrent human still typing into the SAME transcript while burn's own
# attempt failed and never touched it) still got recorded and hidden. A
# (mtime,size)-changed check is a "someone wrote it" detector, not an "the
# engine ran" detector. rc == 0 is now required outright, not an alternative.
@test "#74 round-3 P3-2: burn claude --resume <existing sid> that fails while a concurrent human keeps typing into it writes no sidecar line" {
  _fixture
  clikae init claude T1
  _human_claude   # the transcript pre-exists
  cat > "$TEST_HOME/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$STUB_ARGV_LOG"
slug="$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')"
f="$CLAUDE_CONFIG_DIR/projects/$slug/$HUMAN_SID.jsonl"
# Simulate a concurrent human still typing into the SAME transcript — the
# file grows — while THIS engine invocation itself refuses to start and
# never reads or writes a single byte of it.
printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"more human typing"}}\n' "$PWD" >> "$f"
echo "error: engine refused to start" >&2
exit 1
STUB
  chmod +x "$TEST_HOME/bin/claude"
  run clikae burn claude T1 --artifact "$STUB_ARTIFACT" --add-dir "$PWD" -- -p 'go' --resume "$HUMAN_SID"
  [ "$status" -ne 0 ]
  [ ! -e "$CLIKAE_HOME/state/burn-sessions/claude/T1" ]
  run clikae resume --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HUMAN_SID"* ]] || false
}

# #74 round-4 P3-3: once the triple gate above rejects a --resume of an
# EXISTING sid, control used to fall through to the before/after snapshot
# diff further down — and that diff's own "exactly one new candidate ->
# record it unconditionally" branch has no rc check of its own. A DIFFERENT
# concurrent session minted during the same failed attempt was the sole "new"
# transcript, so it got recorded (and hidden) despite the gate's own verdict
# having nothing to do with it. The gate's rejection must be final: it must
# not hand the decision to a heuristic that knows nothing about why it fired.
@test "#74 round-4 P3-3: codex burn --resume <existing sid> that the triple gate rejects does not fall through and record a DIFFERENT concurrent session" {
  _fixture
  clikae init codex T1
  local existing_sid="77777777-7777-4777-8777-777777777777"
  local human_new_sid="66666666-6666-4666-8666-666666666666"
  local sdir="$CLIKAE_HOME/profiles/codex/T1/sessions/2026/09/13"
  mkdir -p "$sdir"
  # The resumed sid's rollout already exists BEFORE launch (that's what makes
  # this a --resume of an EXISTING sid, arming the triple gate).
  printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$existing_sid" "$PWD" \
    > "$sdir/rollout-2026-09-13T00-00-00-$existing_sid.jsonl"
  cat > "$TEST_HOME/bin/codex" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$STUB_ARGV_LOG"
# The engine fails WITHOUT touching the resumed transcript (gate condition 1
# and 2 both fail: rc != 0, and it never grew) — but, independent of that
# failure, a concurrent human mints a brand-new session during the same
# window. That new session is the ONLY "new" transcript in the before/after
# diff; it must stay unrecorded, because the gate's rejection was about the
# --resume target, not a verdict this second session ever earned.
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$human_new_sid" "\$PWD" \
  > "$sdir/rollout-2026-09-13T00-00-01-$human_new_sid.jsonl"
exit 1
STUB
  chmod +x "$TEST_HOME/bin/codex"
  run clikae burn codex T1 --artifact "$STUB_ARTIFACT" -- exec --skip-git-repo-check resume "$existing_sid" go
  [ "$status" -ne 0 ]
  [ ! -e "$CLIKAE_HOME/state/burn-sessions/codex/T1" ]
  run clikae resume --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"$human_new_sid"* ]] || false
}

@test "burn claude does not clash --session-id onto a caller-supplied --session-id" {
  _fixture
  clikae init claude T1
  local existing_sid="44444444-4444-4444-8444-444444444444"
  cat > "$TEST_HOME/bin/claude" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$STUB_ARGV_LOG"
n=0
for a in "\$@"; do [ "\$a" = --session-id ] && n=\$((n + 1)); done
if [ "\$n" -gt 1 ]; then
  echo "error: --session-id specified more than once" >&2
  exit 1
fi
sid=""
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = --session-id ]; then sid="\$2"; break; fi
  shift
done
if [ -n "\$sid" ]; then
  slug="\$(printf '%s' "\$PWD" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "\$CLAUDE_CONFIG_DIR/projects/\$slug"
  printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"own id"}}\n' "\$PWD" > "\$CLAUDE_CONFIG_DIR/projects/\$slug/\$sid.jsonl"
fi
printf 'done\n' > "$STUB_ARTIFACT"
STUB
  chmod +x "$TEST_HOME/bin/claude"
  run clikae burn claude T1 --artifact "$STUB_ARTIFACT" --add-dir "$PWD" -- -p 'go' --session-id "$existing_sid"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -s "$STUB_ARTIFACT" ]
  _assert_sidecar claude T1 "$existing_sid"
}

# #74 round-2 P3-5 (structural): _burn_sids_file's temp file has its OWN
# lifetime (created once per picker pass) — it must be removed whether or
# not there turned out to be any candidates to match it against. The old
# shape nested the `rm -f` inside the SAME `if` that gated the match loop on
# ${#_rf_sid[@]} -gt 0, so a zero-candidate pass (unreachable today: `files`
# empty exits earlier) would never clean it up. Not exercisable end-to-end
# (the unreachable path is exactly the point), so this pins the CODE SHAPE
# instead — the same technique clean.bats' own structural mutation-check
# tests already use for a shape that can't be driven from the outside.
@test "#74 round-2 P3-5 (structural): the sidecar temp file is removed independent of the candidate count" {
  run grep -qE 'if \[ -n "\$burn_sids_file" \] && \[ "\$\{#_rf_sid\[@\]\}" -gt 0 \]' "$CLIKAE_LIB/commands/resume.sh"
  [ "$status" -ne 0 ]
  run grep -qF 'rm -f "$burn_sids_file"' "$CLIKAE_LIB/commands/resume.sh"
  [ "$status" -eq 0 ]
}
