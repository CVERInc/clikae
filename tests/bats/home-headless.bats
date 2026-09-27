#!/usr/bin/env bats
# tests/bats/home-headless.bats — the board lists only sessions a human opened
# (#153). agy subagent conversations, `claude -p` and `codex exec` runs are
# recognised by STRUCTURE (agy's conversation metadata, claude's "entrypoint",
# codex's "originator"), never by what their first message says; a session
# whose kind cannot be read stays on the board with a shorter title; and every
# title is one line of bounded width before it reaches the renderer.

load '../helpers'
load 'helpers/agy_blob'

PARENT="11111111-0000-4000-8000-000000000001"

# A brief the size of a real injected one: several KB, multi-line, CJK, quotes,
# tabs and the <SYSTEM_MESSAGE> wrapper — the shape that flooded the board.
_brief() {
  python3 -c 'import sys; sys.stdout.write("The following is a <SYSTEM_MESSAGE> not actually sent by the user.\n\n" + "## Brief 任務說明\n- step \"quoted\" \t tab 🙂\n" * int(sys.argv[1]))' "${1:-300}"
}

# _agy_conv <base> <sid> <touch-stamp> <content> <blob-hex|-> [wal]
# A conversation: its transcript (first message = <content>) and, unless <blob>
# is "-", its conversations/<sid>.db holding <blob> as the 'main' metadata.
_agy_conv() {
  local base="$1" sid="$2" stamp="$3" content="$4" blob="$5" d
  d="$base/brain/$sid/.system_generated/logs"
  mkdir -p "$d"
  python3 -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps({"content":sys.argv[2]},ensure_ascii=False)+"\n")' \
    "$d/transcript.jsonl" "$content"
  touch -t "$stamp" "$d/transcript.jsonl"
  [ "$blob" = - ] || agy_blob_db "$base/conversations/$sid.db" "$blob" "${6:-}"
}

# One human parent, older than everything else, then twelve subagents it
# spawned (self and research kinds), an orphan whose parent no longer exists,
# and an agent this repo has never heard of — every one of them carrying a
# multi-KB brief as its first message.
_agy_flood() {
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | clikae init agy default >/dev/null 2>&1
  AGY_BASE="$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli"
  mkdir -p "$AGY_BASE/brain" "$AGY_BASE/conversations"
  local brief i sid kind
  brief="$(_brief 300)"
  _agy_conv "$AGY_BASE" "$PARENT" 202601010000 "PARENT human conversation" "$(agy_blob_human "$PARENT")"
  for i in $(seq 1 12); do
    printf -v sid 'eeeeeeee-0000-4000-8000-%012d' "$i"
    kind=self; [ $((i % 3)) -eq 0 ] && kind=research
    _agy_conv "$AGY_BASE" "$sid" "2026020100$(printf %02d "$i")" "$brief" "$(agy_blob_subagent "$sid" "$PARENT" "$kind" 3000)"
  done
  sid="ffffffff-0000-4000-8000-000000000001"
  _agy_conv "$AGY_BASE" "$sid" 202603010000 "ORPHAN $brief" "$(agy_blob_orphan "$sid" "99999999-dead-4000-8000-000000000000")"
  sid="ffffffff-0000-4000-8000-000000000002"
  _agy_conv "$AGY_BASE" "$sid" 202603010100 "FUTURE-AGENT $brief" "$(agy_blob_agentonly "$sid" critic)"
  mkdir -p "$TEST_HOME/work"; cd "$TEST_HOME/work" || return
}

# The Continue list's rows as the renderer receives them: `_home_items`, in
# the same process shape home.bats' own sourcing tests use.
_items() {
  (
    source "$CLIKAE_LIB/core/log.sh"
    source "$CLIKAE_LIB/core/profile_store.sh"
    source "$CLIKAE_LIB/core/adapter_loader.sh"
    source "$CLIKAE_LIB/core/reading_cache.sh"
    source "$CLIKAE_LIB/core/limit.sh"
    source "$CLIKAE_LIB/core/board_state.sh"
    source "$CLIKAE_LIB/core/duration.sh"
    source "$CLIKAE_LIB/commands/home.sh"
    _home_recent_rows
  )
}

@test "#153: agy subagents (self, research, orphan, unknown agent) are not on the board; the human parent is" {
  _agy_flood
  run clikae
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"PARENT human conversation"* ]] || { echo "$output"; false; }
  [[ "$output" != *"SYSTEM_MESSAGE"* ]] || { echo "subagent listed: $output"; false; }
  [[ "$output" != *"ORPHAN"* ]] || { echo "orphan listed: $output"; false; }
  [[ "$output" != *"FUTURE-AGENT"* ]] || { echo "unknown agent listed: $output"; false; }
  # exactly one resume row: the parent
  [ "$(printf '%s\n' "$output" | grep -c '    · default agy      "')" -eq 1 ] || { echo "$output"; false; }
}

@test "#153: every Continue row is one line, and the items stream stays small" {
  _agy_flood
  local items bytes
  items="$(_items)"
  bytes="$(printf '%s' "$items" | wc -c | tr -d ' ')"
  echo "items bytes=$bytes" >&3
  # main carried every subagent's whole brief here (~10 × 25 KB for this
  # fixture, ~1 MB on the reported machine): the payload of every redraw.
  [ "$bytes" -le 4096 ] || { echo "items stream is $bytes bytes"; false; }
  # one resume row, one line: the record is exactly 7 fields on ONE line
  [ "$(printf '%s\n' "$items" | awk -F $'\037' '$1 == "resume"' | grep -c .)" -eq 1 ]
  printf '%s\n' "$items" | awk -F $'\037' '$1 == "resume" && NF != 7 { bad = 1 } END { exit bad }'
}

@test "#153: the board's first interactive frame has a byte ceiling" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  script --version >/dev/null 2>&1 || skip "needs util-linux script(1) to capture the pty"
  _agy_flood
  local sock="$TEST_HOME/tmux.sock" raw="$TEST_HOME/frame.raw" prev=-1 n=0 i
  # Own socket (-S), never the default server. `script` gives clikae a real pty
  # and records every byte it writes to it.
  tmux -S "$sock" -f /dev/null new-session -d -x 200 -y 50 \
    "cd '$TEST_HOME/work' && SHELL=/bin/bash script -qfc '$CLIKAE_BIN' '$raw'; sleep 30"
  for i in $(seq 1 60); do
    sleep 1
    n="$(wc -c < "$raw" 2>/dev/null | tr -d ' ')"; n="${n:-0}"
    [ "$n" -gt 0 ] && [ "$n" = "$prev" ] && break
    prev="$n"
  done
  tmux -S "$sock" send-keys q 2>/dev/null || true
  sleep 1
  tmux -S "$sock" kill-server 2>/dev/null || true
  echo "first frame bytes=$n" >&3
  grep -q 'PARENT human conversation' "$raw" || { cat -v "$raw"; false; }
  # main drew ten subagent rows here: 3219 bytes at 200 columns.
  [ "$n" -le 2048 ] || { echo "first frame is $n bytes"; false; }
}

@test "#153: a subagent whose metadata lives only in the -wal is still recognised, and agy's files are never written" {
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | clikae init agy default >/dev/null 2>&1
  local base="$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli"
  local sid="eeeeeeee-0000-4000-8000-00000000000a" db before after
  _agy_conv "$base" "$sid" 202602010000 "WAL-ONLY subagent" "$(agy_blob_subagent "$sid" "$PARENT" self)" wal
  db="$base/conversations/$sid.db"
  [ -s "$db-wal" ]
  # The row really is only in the -wal: the .db on its own has none.
  local t; t="$(mktemp -d)"; cp "$db" "$t/x.db"
  [ -z "$(sqlite3 "$t/x.db" "SELECT count(*) FROM trajectory_metadata_blob;" 2>/dev/null | grep -v '^0$')" ]
  rm -rf "$t"
  before="$(cksum "$db" "$db-wal")"
  run bash -c "source '$CLIKAE_LIB/adapters/antigravity.sh'; adapter_session_mode '${base%/antigravity-cli}' '$sid'"
  [ "$output" = headless ] || { echo "got: $output"; false; }
  after="$(cksum "$db" "$db-wal")"
  [ "$before" = "$after" ]
  [ ! -e "$db-shm" ]
}

@test "#153: the agy rule reads structure — own id in field 5 is not a parent, garbage is unknown" {
  source "$CLIKAE_LIB/adapters/antigravity.sh"
  local own="$PARENT"
  run _agy_blob_mode "$(agy_blob_human "$own")" "$own";                 [ "$output" = interactive ]
  run _agy_blob_mode "$(agy_blob_subagent "$own" "$PARENT-x" self)" "$own";   [ "$output" = headless ]
  run _agy_blob_mode "$(agy_blob_subagent "$own" "$PARENT-x" research)" "$own"; [ "$output" = headless ]
  run _agy_blob_mode "$(agy_blob_orphan "$own" "gone-parent")" "$own";  [ "$output" = headless ]
  run _agy_blob_mode "$(agy_blob_agentonly "$own" critic)" "$own";      [ "$output" = headless ]
  # field 5 naming the conversation itself is not "a parent"
  run _agy_blob_mode "$(pb_str 5 "$own")$(agy_blob_human "$own")" "$own"; [ "$output" = interactive ]
  # the words a subagent's brief uses are not a signal: a human conversation
  # whose metadata merely CONTAINS them (in the workspace string) stays
  run _agy_blob_mode "$(pb_str 1 "file:///self/builtin/agents/research/agent.json SYSTEM_MESSAGE")$(pb_str 6 "$own")" "$own"
  [ "$output" = interactive ]
  run _agy_blob_mode "0AFF" "$own";  [ "$output" = unknown ]
  run _agy_blob_mode "" "$own";      [ "$output" = unknown ]
}

@test "#153: an agy conversation with no readable metadata stays on the board, one line, shorter title" {
  mkdir -p "$HOME/.gemini"
  printf 'y\n' | clikae init agy default >/dev/null 2>&1
  local base="$CLIKAE_HOME/profiles/antigravity/default/antigravity-cli"
  _agy_conv "$base" "$PARENT" 202601010000 "NO-DB $(_brief 200)" -
  mkdir -p "$TEST_HOME/work"; cd "$TEST_HOME/work"
  local items title
  items="$(_items)"
  title="$(printf '%s\n' "$items" | awk -F $'\037' '$1 == "resume" { print $4 }')"
  [[ "$title" == "NO-DB The following is a <SYSTEM_MESSAGE>"* ]] || { echo "title: $title"; false; }
  [[ "$title" == *"…" ]] || { echo "not truncated: $title"; false; }
  # CLIKAE_HOME_TITLE_UNKNOWN_MAX (60) columns, ASCII here: 59 chars + "…"
  [ "$(printf '%s' "$title" | LC_ALL=C.UTF-8 wc -m | tr -d ' ')" -le 60 ] || { echo "${#title}: $title"; false; }
}

_claude_tx() {   # <dir> <sid> <entrypoint|-> <title> <stamp>
  local f="$1/$2.jsonl"
  if [ "$3" = - ]; then
    printf '{"type":"user","message":{"role":"user","content":"x"},"sessionId":"%s"}\n' "$2" > "$f"
  else
    printf '{"type":"user","entrypoint":"%s","message":{"role":"user","content":"x"},"sessionId":"%s"}\n' "$3" "$2" > "$f"
  fi
  printf '{"type":"ai-title","aiTitle":"%s","sessionId":"%s"}\n' "$4" "$2" >> "$f"
  touch -t "$5" "$f"
}

@test "#153: claude — entrypoint sdk-cli is not on the board, cli is, no entrypoint is listed with a shorter title" {
  clikae init claude a >/dev/null
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local slug; slug="$(printf '%s' "$work" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  local d="$CLIKAE_HOME/profiles/claude/a/projects/$slug"; mkdir -p "$d"
  local long; long="OLD-BUILD $(printf 'word %.0s' $(seq 1 60))"
  _claude_tx "$d" 33333333-0000-4000-8000-000000000001 cli     "HUMAN-CLI session" 202601010000
  _claude_tx "$d" 33333333-0000-4000-8000-000000000002 -       "$long"             202601010100
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    _claude_tx "$d" "44444444-0000-4000-8000-0000000000$(printf %02d "$i")" sdk-cli "HEADLESS-$i run" "2026020100$(printf %02d "$i")"
  done
  cd "$work"
  run clikae
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"HUMAN-CLI session"* ]] || { echo "$output"; false; }
  [[ "$output" == *"OLD-BUILD word"* ]] || { echo "$output"; false; }
  [[ "$output" != *"HEADLESS-"* ]] || { echo "headless listed: $output"; false; }
  local title
  title="$(_items | awk -F $'\037' '$1 == "resume" && $4 ~ /^OLD-BUILD/ { print $4 }')"
  [[ "$title" == *"…" ]] && [ "${#title}" -le 62 ] || { echo "${#title}: $title"; false; }
}

@test "#153: codex — originator codex_exec is not on the board, codex-tui is" {
  clikae init codex a >/dev/null
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local sdir="$CLIKAE_HOME/profiles/codex/a/sessions/2026/06/03"; mkdir -p "$sdir"
  local i sid f
  sid="019e0000-0000-7000-8000-000000000001"
  f="$sdir/rollout-2026-06-03T09-00-00-$sid.jsonl"
  { printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","originator":"codex-tui"}}\n' "$sid" "$work"
    printf '{"type":"event_msg","payload":{"type":"user_message","message":"HUMAN-TUI session"}}\n'; } > "$f"
  touch -t 202001010000 "$f"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sid="019e9999-0000-7000-8000-0000000000$(printf %02d "$i")"
    f="$sdir/rollout-2026-06-03T10-00-$(printf %02d "$i")-$sid.jsonl"
    { printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","originator":"codex_exec"}}\n' "$sid" "$work"
      printf '{"type":"event_msg","payload":{"type":"user_message","message":"EXEC-%s run"}}\n' "$i"; } > "$f"
  done
  cd "$work"
  run clikae
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"HUMAN-TUI session"* ]] || { echo "$output"; false; }
  [[ "$output" != *"EXEC-"* ]] || { echo "headless listed: $output"; false; }
}

@test "#153: a title is one line — newlines, tabs, ESC and the field separator become spaces" {
  source "$CLIKAE_LIB/commands/home.sh"
  _home_title_linev $'first\nsecond\r\tthird \033[31mred\037field   end' 120
  [ "$_TRUNC" = 'first second third [31mred field end' ] || { printf '%q\n' "$_TRUNC"; false; }
  # A megabyte title costs a bounded amount and comes back bounded.
  local big; big="$(printf '%*s' 1000000 '' | tr ' ' x)"
  _home_title_linev "$big" 120
  [ "${#_TRUNC}" -le 122 ]
  # CJK is cut by display columns and never mid-character.
  _home_title_linev "$(printf '任務說明%.0s' $(seq 1 100))" 20
  [ "$_TRUNC" = '任務說明任務說明任…' ] || { echo "$_TRUNC"; false; }
}

# The #93 truncation note asks "did the adapter fill the ask to the brim?" —
# a question about what it RETURNED. Counted after the headless filter it
# could never be true once a headless row was dropped, and the note went
# silent exactly when the ceiling bit.
@test "#153: dropping headless rows does not silence the #93 'list truncated' note" {
  clikae init claude a >/dev/null
  local work="$TEST_HOME/work"; mkdir -p "$work"
  local slug; slug="$(printf '%s' "$work" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  local d="$CLIKAE_HOME/profiles/claude/a/projects/$slug"; mkdir -p "$d"
  mkdir -p "$CLIKAE_HOME/state/burn-sessions/claude"
  local i sid
  for i in 1 2 3; do
    _claude_tx "$d" "33333333-0000-4000-8000-00000000000$i" cli "HUMAN-$i session" "20200101000$i"
  done
  for i in $(seq 1 50); do
    printf -v sid '44444444-0000-4000-8000-%012d' "$i"
    _claude_tx "$d" "$sid" sdk-cli "BURN-$i run" "2025010100$(printf %02d $((i % 60)))"
    printf '%s\trun\t1700000000\n' "$sid" >> "$CLIKAE_HOME/state/burn-sessions/claude/a"
  done
  for i in 1 2 3 4 5; do
    _claude_tx "$d" "55555555-0000-4000-8000-00000000000$i" sdk-cli "HEADLESS-$i run" "20260101000$i"
  done
  cd "$work"
  CLIKAE_HOME_RECENT_SCAN_MAX=20 CLIKAE_HOME_RECENT_MAX=10 run clikae
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"list truncated"* ]] || { echo "$output"; false; }
  [[ "$output" != *"HEADLESS-"* ]] || { echo "$output"; false; }
}
