#!/usr/bin/env bash
# clikae-harness.sh — the restraint clikae installs into an agy tank.
#
# It does not change how the agent talks. It can stay as confident as it likes;
# it just cannot finish by saying it verified something in a session where it
# never ran anything. The claim has to arrive with a receipt.
#
# THIS FILE IS YOURS. It was copied into your tank at `clikae init agy <tank>`,
# not linked, so editing it is the intended way to make it stricter — and
# deleting it (or config/hooks.json next to it) turns the whole thing off with no
# other consequence. agy works exactly as before without it.
#
# ── what it checks ─────────────────────────────────────────────────────────
# 1. ZERO EVIDENCE (clikae's, works in any project)
#    Did the reply claim work was verified, in a session with no commands run at
#    all? The threshold is deliberately ZERO, not "enough": "you didn't test
#    enough" is an argument about taste that nobody can settle, while "you said
#    you verified it and this session never ran a single command" is not an
#    argument. Zero is also the only threshold that can never punish real work.
#
# 2. THE PROJECT'S OWN GATE (yours, only if you wrote one)
#    An executable `.clikae-gate` at the workspace root, or $CK_HARNESS_GATE.
#    clikae cannot know what "done" means in your project — that is your file.
#    No gate, no check; it says so rather than implying coverage it doesn't have.
#
# ── how it answers ─────────────────────────────────────────────────────────
# agy's Stop contract has exactly two outcomes (verified against its own docs and
# by experiment on 2026-08-12): `{"decision":"continue","reason":…}` blocks the
# stop, re-enters the loop, and injects `reason` as a system message; anything
# else lets it stop. There is no "let it stop but attach a note" — so a finding
# is delivered by blocking once, which the agent then has to answer.
#
# `reason` really does reach the model: a probe injected a random token and asked
# for it back, and the next reply contained it.
#
# Dispatched (nobody is reading) → block until it passes, up to CK_HARNESS_MAX.
# Interactive (you are reading)  → block ONCE, so the claim never reaches you
#                                  unaccompanied, then get out of your way.
# Either way there is a cap. A gate that can never pass must not be able to hold
# a session forever.
#
# WHAT THIS CANNOT DO, measured rather than assumed. Blocking is not compliance.
# The same prompt on two real tanks: one came back and said plainly "I did not
# actually run any commands"; the other was blocked just the same, went off and
# did something else, and the text printed at the end was still the original
# claim. The harness guarantees the claim is CHALLENGED, not that the agent
# answers well — and after the cap the last thing on screen can still be the
# unsupported sentence. Read the reply, not the fact that a harness exists.
set -uo pipefail

MODE_HOOK="${1:-Stop}"

STATE_DIR="${CK_HARNESS_STATE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.harness-state}"
GATE_NAME="${CK_HARNESS_GATE_NAME:-.clikae-gate}"

payload="$(cat)"

_json_get() {
  printf '%s' "$payload" | python3 -c '
import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
cur = d
for k in sys.argv[1].split("."):
    if isinstance(cur, list): cur = cur[0] if cur else None
    if not isinstance(cur, dict): cur = None; break
    cur = cur.get(k)
if isinstance(cur, list): cur = cur[0] if cur else None
print(cur if cur is not None else "")
' "$1" 2>/dev/null
}

allow_stop() { exit 0; }

block_with() {
  # One line out; agy injects `reason` verbatim.
  python3 -c 'import json,sys; print(json.dumps({"decision":"continue","reason":sys.argv[1]}, ensure_ascii=False))' "$1"
  exit 0
}

# ── PreToolUse: the agent may not edit the ruler ────────────────────────────
# Only when dispatched. Interactively the tests are YOURS — a tool that stops the
# owner from editing their own test file has confused "how dangerous is this
# action" with "who is doing it". A subordinate is different: it can make the
# gate pass by changing the gate.
if [ "$MODE_HOOK" = "PreToolUse" ]; then
  [ "${CLIKAE_DISPATCH:-0}" = "1" ] || { printf '%s' '{"decision":"allow"}'; exit 0; }
  [ "${CK_ALLOW_RULER_EDIT:-0}" = "1" ] && { printf '%s' '{"decision":"allow"}'; exit 0; }
  args="$(printf '%s' "$payload" | python3 -c '
import json,sys
try: d = json.load(sys.stdin)
except Exception: print(""); sys.exit(0)
print(json.dumps(d.get("toolCall", {}).get("args", {})))
' 2>/dev/null)"
  # Fail OPEN on anything unexpected: a harness that blocks work it cannot parse
  # is worse than one that misses an edit.
  case "$args" in
    *".clikae-gate"*|*"/tests/"*|*"/test/"*|*".github/workflows"*)
      printf '%s' '{"decision":"deny","reason":"The harness blocks edits to the checks themselves. Make the work pass the gate rather than changing it. If the gate is genuinely wrong, say so and stop — a human decides that."}'
      exit 0 ;;
  esac
  printf '%s' '{"decision":"allow"}'
  exit 0
fi

# ── Stop: did the claim arrive with a receipt? ──────────────────────────────
ws="$(_json_get workspacePaths)"
transcript="$(_json_get transcriptPath)"
convo="$(_json_get conversationId)"
[ -n "$convo" ] || convo="unknown"

# The cap. Interactive gets one interruption; a dispatched run gets a few, since
# nobody is there to notice it looping.
if [ "${CLIKAE_DISPATCH:-0}" = "1" ]; then
  max="${CK_HARNESS_MAX:-3}"
else
  max="${CK_HARNESS_MAX:-1}"
fi
mkdir -p "$STATE_DIR" 2>/dev/null || true
# One counter per conversation, and a conversation that ends while still blocked
# (a timeout, a kill, an agent that wandered off) leaves its counter behind. Found
# three of them in a real tank within an hour, which is a directory that grows
# forever in someone's config. Sweep anything older than a day: a limit that is
# still being argued about after that is not the same argument.
find "$STATE_DIR" -type f -mtime +1 -delete 2>/dev/null || true
count_file="$STATE_DIR/$convo"
n=0; [ -f "$count_file" ] && n="$(cat "$count_file" 2>/dev/null || printf 0)"

findings=""

# --- 1. zero evidence --------------------------------------------------------
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  verdict="$(python3 - "$transcript" <<'PY' 2>/dev/null
import json,re,sys
path = sys.argv[1]
ran = 0        # commands that actually executed
tools = 0      # any tool call at all
wrote_test = 0
last = ""
for line in open(path, errors="replace"):
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except Exception: continue
    if "exit_code" in d: ran += 1
    if d.get("tool_calls"): tools += 1
    blob = json.dumps(d.get("tool_calls") or "")
    if re.search(r'(^|[/_.-])(tests?|specs?)([/_.-]|\b)', blob, re.I): wrote_test = 1
    c = d.get("content")
    if isinstance(c, str) and d.get("source") == "MODEL" and c.strip():
        last = c
# Only the strongest claims — ones that assert something HAPPENED. Missing a
# hedged claim is the safe direction; a false positive would nag real work.
claim_verified = bool(re.search(
    r"\b(i (ran|tested|verified|executed|checked)\b"
    r"|all tests (pass|passed|are passing)"
    r"|tests? (pass|passed|are passing)"
    r"|verified (it|that|this|everything)"
    r"|everything works"
    r"|confirmed (it|that|this) works"
    r"|fully (tested|verified))", last, re.I))
claim_tests = bool(re.search(r"\b(added|wrote|created|implemented)\b[^.]{0,40}\btests?\b", last, re.I))
print(json.dumps({"ran": ran, "tools": tools, "wrote_test": wrote_test,
                  "claim_verified": claim_verified, "claim_tests": claim_tests}))
PY
)"
  if [ -n "$verdict" ]; then
    cv="$(printf '%s' "$verdict" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("1" if d["claim_verified"] and d["ran"]==0 else "0")' 2>/dev/null)"
    ct="$(printf '%s' "$verdict" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("1" if d["claim_tests"] and not d["wrote_test"] else "0")' 2>/dev/null)"
    [ "$cv" = "1" ] && findings="${findings}- You stated the work was run or verified, but this session executed ZERO commands. Run it, then say what the command was and what it printed.
"
    [ "$ct" = "1" ] && findings="${findings}- You stated tests were added, but no test file was touched in this session.
"
  fi
fi

# --- 2. the project's own gate ----------------------------------------------
gate="${CK_HARNESS_GATE:-}"
[ -n "$gate" ] || { [ -n "$ws" ] && gate="$ws/$GATE_NAME"; }
if [ -n "$gate" ] && [ -x "$gate" ]; then
  gate_out="$("$gate" 2>&1)"; gate_rc=$?
  if [ "$gate_rc" -ne 0 ]; then
    findings="${findings}- The project's own gate ($GATE_NAME) failed (exit $gate_rc):
$(printf '%s' "$gate_out" | head -c 2000)
"
  fi
fi

[ -n "$findings" ] || { rm -f "$count_file" 2>/dev/null; allow_stop; }

n=$((n + 1))
printf '%s' "$n" > "$count_file" 2>/dev/null || true

if [ "$n" -gt "$max" ]; then
  # Out of interruptions. Stop blocking, but do not pretend it passed: the last
  # word the human reads should be the unmet finding, not a clean finish.
  printf '%s\n' "⚠️  clikae harness: still unmet after $max attempt(s) — letting the session end." >&2
  printf '%s\n' "$findings" >&2
  rm -f "$count_file" 2>/dev/null
  allow_stop
fi

block_with "CLIKAE HARNESS — this claim is not accepted yet ($n/$max).

$findings
Fix it or say plainly what you did not do. Do not restate the claim."
