# shellcheck shell=bash
# tests/bats/helpers/agy_blob.bash — hand-built agy conversation metadata
# (#153). agy keeps a per-conversation sqlite db at
# <tank>/antigravity-cli/conversations/<id>.db whose trajectory_metadata_blob
# row 'main' is a protobuf. These helpers assemble that protobuf byte by byte,
# in the top-level shape measured on a real tank (see adapter_session_mode in
# lib/adapters/antigravity.sh): a human conversation has fields 1 2 3 6 7 15
# 18; a subagent (the `self` kind and the built-in `research` kind alike) also
# has 4 (AgentConfig: 4.1 name, 4.7 config, 4.8 description), 5 (parent id), 8
# (the call: 8.1 name, 8.2 task title, 8.3 brief), 10 and 17.
#
# Everything is upper-case hex, two chars per byte, until agy_blob_db writes it.

_pb_varint() {
  local v="$1" out="" b
  while :; do
    b=$(( v & 127 )); v=$(( v >> 7 ))
    if [ "$v" -gt 0 ]; then out="$out$(printf '%02X' $(( b | 128 )))"
    else out="$out$(printf '%02X' "$b")"; break; fi
  done
  printf '%s' "$out"
}
_pb_hexstr() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n' | tr 'a-f' 'A-F'; }
pb_len() { printf '%s%s%s' "$(_pb_varint $(( ($1 << 3) | 2 )))" "$(_pb_varint $(( ${#2} / 2 )))" "$2"; }
pb_str() { pb_len "$1" "$(_pb_hexstr "$2")"; }
pb_int() { printf '%s%s' "$(_pb_varint $(( $1 << 3 )))" "$(_pb_varint "$2")"; }

# agy_blob_human <own-id> -> the ~600-byte shape a human (or burn) conversation has.
agy_blob_human() {
  printf '%s' "$(pb_str 1 "file:///work")$(pb_len 2 "$(pb_int 1 1790000000)")$(pb_str 3 "aaaaaaaa-1111-4000-8000-000000000000")$(pb_str 6 "$1")$(pb_str 7 "file:///work")$(pb_int 15 1)$(pb_str 18 default-cli-project)"
}

# agy_blob_subagent <own-id> <parent-id> <agent-name> [config-bytes]
# -> the subagent shape. [config-bytes] pads 4.7 so the blob is realistically
# large (the measured ones are 22 KB and 43 KB).
agy_blob_subagent() {
  local parent="$2" agent="$3" pad="${4:-2000}" cfg   # $1 (own id) is not stored in a subagent blob
  cfg="$(pb_str 1 "/Users/x/.gemini/antigravity-cli/builtin/agents/$agent/agent.json")$(pb_str 2 "$(printf 'c%.0s' $(seq 1 "$pad"))")"
  printf '%s' "$(pb_str 1 "file:///work")$(pb_len 2 "$(pb_int 1 1790000000)")$(pb_str 3 "bbbbbbbb-2222-4000-8000-000000000000")$(pb_len 4 "$(pb_str 1 "$agent")$(pb_len 7 "$cfg")$(pb_str 8 "Subagent that inherits the parent agent's full configuration")")$(pb_str 5 "$parent")$(pb_str 6 "$parent")$(pb_str 7 "file:///work")$(pb_len 8 "$(pb_str 1 "$agent")$(pb_str 2 "Chunk 5 Patcher")$(pb_str 3 "brief")")$(pb_len 10 "$(pb_str 1 x)")$(pb_int 17 1)$(pb_str 18 default-cli-project)"
}

# agy_blob_orphan <own-id> <parent-id> -> field 5 only (a parent that no longer
# exists, no AgentConfig): signal 1 on its own.
agy_blob_orphan() {
  printf '%s' "$(pb_str 1 "file:///work")$(pb_str 5 "$2")$(pb_str 6 "$2")$(pb_str 7 "file:///work")$(pb_str 18 default-cli-project)"
}

# agy_blob_agentonly <own-id> <agent-name> -> field 4 only (no parent field): a
# built-in agent this repo has never heard of, caught by signal 2 on its own.
agy_blob_agentonly() {
  printf '%s' "$(pb_str 1 "file:///work")$(pb_len 4 "$(pb_str 1 "$2")$(pb_str 8 "some future built-in agent")")$(pb_str 6 "$1")$(pb_str 7 "file:///work")$(pb_str 18 default-cli-project)"
}

# agy_blob_db <db-path> <hex> [wal] -> writes a WAL-mode db holding <hex> as
# trajectory_metadata_blob 'main'. With `wal`, the row is left ONLY in the
# -wal file (the db is copied mid-transaction-log, the way a live agy leaves it).
agy_blob_db() {
  local db="$1" hex="$2" mode="${3:-}"
  mkdir -p "$(dirname "$db")"
  if [ "$mode" = wal ]; then
    local t; t="$(mktemp -d)"
    sqlite3 "$t/c.db" "PRAGMA journal_mode=WAL; CREATE TABLE trajectory_metadata_blob(id TEXT, data BLOB);" >/dev/null
    # Hold a reader open so the writer's close cannot checkpoint, then copy the
    # pair while the new row still lives only in the -wal.
    python3 - "$t/c.db" "$hex" "$db" <<'PY'
import sqlite3, sys, shutil
src, hx, dst = sys.argv[1], sys.argv[2], sys.argv[3]
w = sqlite3.connect(src)
w.execute("PRAGMA wal_autocheckpoint=0")
w.execute("INSERT INTO trajectory_metadata_blob VALUES('main', ?)", (bytes.fromhex(hx),))
w.commit()
shutil.copy(src, dst); shutil.copy(src + "-wal", dst + "-wal")
PY
    rm -rf "$t"
  else
    sqlite3 "$db" "PRAGMA journal_mode=WAL; CREATE TABLE trajectory_metadata_blob(id TEXT, data BLOB); INSERT INTO trajectory_metadata_blob VALUES('main', X'$hex');" >/dev/null
  fi
}
