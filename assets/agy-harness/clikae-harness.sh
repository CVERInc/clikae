#!/usr/bin/env bash
# clikae-harness.sh — the restraint clikae installs into an agy tank.
#
# It does not change how the agent talks. It can stay as confident as it likes;
# it just cannot finish a turn in which it changed something and then measured
# nothing. It judges ACTIONS (the sequence of tool calls), not words — so it
# works in any language. The claim has to arrive with a receipt.
#
# THIS FILE IS YOURS. It was copied into your tank at `clikae init agy <tank>`,
# not linked, so editing it is the intended way to make it stricter — and
# deleting it (or config/hooks.json next to it) turns the whole thing off with no
# other consequence. agy works exactly as before without it.
#
# ── what it checks ─────────────────────────────────────────────────────────
# 1. CHANGED, NOT MEASURED (clikae's, works in any project and any language)
#    The rule reads the SEQUENCE of tool calls, never the reply's text. Every
#    tool call is classified once — see THE TABLE below — as MUTATING (file
#    edits, write-type shell commands, MCP writes such as save_page /
#    set_theme / patch_page / publish_site) or OBSERVING (file reads, test
#    runs, inspect_page / probe_render, screenshots). At Stop: if this turn
#    mutated something and no observing call happened AFTER the last mutation,
#    the stop is blocked with one fixed sentence:
#        "You changed something and have not measured it since. Measure it
#         and show what the measurement printed."
#    It targets the failure actually seen in the wild (edit → declare done),
#    and it fires in Chinese exactly as it fires in English, because there is
#    nothing in it that reads a word.
#
# 2. ZERO EVIDENCE (secondary, English only)
#    Did the reply claim work was verified, in a session with no commands run at
#    all? Kept because it catches a claim made without ANY tool call, which rule
#    1 cannot see (nothing mutated, nothing to measure). Its patterns are
#    English; a reply in another language simply skips this check — rule 1 is
#    the one that covers everyone.
#
# 3. THE PROJECT'S OWN GATE (yours, only if you wrote one)
#    An executable `.clikae-gate` at the workspace root, or $CK_HARNESS_GATE.
#    clikae cannot know what "done" means in your project — that is your file.
#    No gate, no check; it says so rather than implying coverage it doesn't have.
#
# ── what it does NOT cover — plainly ───────────────────────────────────────
# • Whether the measurement was the RIGHT one. `view_file` after an edit
#   satisfies rule 1; so does running the wrong test. The harness sees that a
#   measurement happened, not what it measured. The real fix for that lives in
#   the tools: a mutating tool should return its own verification (set_theme
#   handing back a before/after render diff), so measuring is part of changing.
# • The project gate needs a workspace. An MCP-only session (editing a hosted
#   site through an MCP server, no repo open) has no `.clikae-gate` to run.
#   Rule 1 still applies there — MCP writes are in the table.
# • Whether the agent complies once blocked. See "WHAT THIS CANNOT DO" below.
# • Anything the hooks do not see: work done outside a tool call, or a tool
#   whose name is not in the table (unknown names count as neither — the rule
#   fails towards silence, never towards nagging).
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

# ── THE TABLE: what counts as changing, what counts as measuring ───────────
# Edit these. Unknown names fall in neither bucket. Tool names are agy's own
# (`write_to_file`, `run_command`, …); MCP tools are matched on the ToolName
# inside `call_mcp_tool`, so `save_page` here means any server's save_page.
# Shell commands are matched on the FIRST WORD of each pipeline segment (`git`
# is refined by its subcommand: git commit/push/… mutate, git diff/log/… do
# not); a `>` / `>>` redirect to a file is also a mutation.
CK_MUTATING_TOOLS="${CK_MUTATING_TOOLS:-write_to_file replace_file_content multi_replace_file_content edit_file delete_file}"
CK_OBSERVING_TOOLS="${CK_OBSERVING_TOOLS:-view_file view_file_outline read_url_content browser_screenshot capture_screenshot}"
CK_MUTATING_MCP="${CK_MUTATING_MCP:-save_page set_theme patch_page publish_site create_page delete_page update_page write_file}"
CK_OBSERVING_MCP="${CK_OBSERVING_MCP:-inspect_page probe_render build_preview build_status diff_versions get_page screenshot take_screenshot read_file}"
CK_MUTATING_CMDS="${CK_MUTATING_CMDS:-rm mv cp mkdir rmdir touch chmod chown ln tee sed patch install dd truncate}"
CK_MUTATING_GIT="${CK_MUTATING_GIT:-commit push pull merge rebase reset checkout switch restore stash apply cherry-pick add rm mv tag}"
CK_OBSERVING_CMDS="${CK_OBSERVING_CMDS:-cat head tail less grep rg diff ls find stat wc test bats pytest jest make npm npx pnpm yarn cargo go bun bash sh python python3 node curl wget shellcheck jq git}"

# One ledger per conversation: PreToolUse appends a line per call, Stop reads it
# and clears it once the stop is allowed — so "this turn" means "since the last
# allowed stop". Lives next to the block counter, swept by the same rule.
_ledger_file() { printf '%s' "$STATE_DIR/${1:-unknown}.calls"; }

# _classify <tool> <mcp_tool> <command_line> -> mutating | observing | neither
_classify() {
  CK_MUTATING_TOOLS="$CK_MUTATING_TOOLS" CK_OBSERVING_TOOLS="$CK_OBSERVING_TOOLS" \
  CK_MUTATING_MCP="$CK_MUTATING_MCP" CK_OBSERVING_MCP="$CK_OBSERVING_MCP" \
  CK_MUTATING_CMDS="$CK_MUTATING_CMDS" CK_MUTATING_GIT="$CK_MUTATING_GIT" \
  CK_OBSERVING_CMDS="$CK_OBSERVING_CMDS" \
  python3 - "$1" "$2" "$3" <<'PY' 2>/dev/null || printf neither
import os, re, shlex, sys
tool, mcp, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
E = lambda k: set(os.environ.get(k, "").split())
if tool in E("CK_MUTATING_TOOLS"):  print("mutating");  sys.exit()
if tool in E("CK_OBSERVING_TOOLS"): print("observing"); sys.exit()
if tool == "call_mcp_tool":
    if mcp in E("CK_MUTATING_MCP"):  print("mutating");  sys.exit()
    if mcp in E("CK_OBSERVING_MCP"): print("observing"); sys.exit()
    print("neither"); sys.exit()
if tool == "run_command" and cmd.strip():
    # A redirect INTO a file is a write, whichever command fed it. `2>&1` and
    # `>/dev/null` are not (they change where output goes, not the tree).
    if re.search(r'(?<![0-9&<])>>?\s*(?!&|/dev/null)\S', cmd): print("mutating"); sys.exit()
    verdict = "neither"
    for seg in re.split(r'\|\|?|&&|;|\n', cmd):
        try: words = shlex.split(seg)
        except ValueError: words = seg.split()
        words = [w for w in words if not re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', w)]  # drop VAR=x prefixes
        if words and words[0] in ("sudo", "env", "command", "time"): words = words[1:]
        if not words: continue
        head = os.path.basename(words[0])
        if head == "git" and len(words) > 1 and words[1] in E("CK_MUTATING_GIT"): print("mutating"); sys.exit()
        if head == "sed" and not any(w == "-i" or w.startswith("-i") for w in words[1:]):
            verdict = "observing"; continue                # sed without -i only prints
        if head in E("CK_MUTATING_CMDS"): print("mutating"); sys.exit()
        if head in E("CK_OBSERVING_CMDS"): verdict = "observing"
    print(verdict); sys.exit()
print("neither")
PY
}

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

# ── PreToolUse: record the call; dispatched, also guard the ruler ───────────
# The LEDGER is written in every mode — interactive too — because rule 1 needs
# the sequence of calls and the transcript is not guaranteed to exist for an
# MCP-only session. Recording is not blocking; it is allow, always, with a
# side effect.
#
# The ruler guard stays dispatch-only. Interactively the tests are YOURS — a
# tool that stops the owner from editing their own test file has confused "how
# dangerous is this action" with "who is doing it". A subordinate is different:
# it can make the gate pass by changing the gate.
if [ "$MODE_HOOK" = "PreToolUse" ]; then
  parsed="$(printf '%s' "$payload" | python3 -c '
import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
tc = d.get("toolCall") or {}
a = tc.get("args") or {}
cmd = a.get("CommandLine") or ""
if not isinstance(cmd, str): cmd = ""
for f in (d.get("conversationId") or "unknown", tc.get("name") or "", a.get("ToolName") or "", cmd[:400].replace("\n"," ").replace("\t"," ")):
    print(f)
print(json.dumps(a))
' 2>/dev/null)"
  args=""
  if [ -n "$parsed" ]; then
    convo="$(printf '%s\n' "$parsed" | sed -n 1p)"
    tool="$(printf '%s\n' "$parsed" | sed -n 2p)"
    mcp="$(printf '%s\n' "$parsed" | sed -n 3p)"
    cmd="$(printf '%s\n' "$parsed" | sed -n 4p)"
    args="$(printf '%s\n' "$parsed" | sed -n '5,$p')"
    if [ -n "$tool" ]; then
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      printf '%s\t%s\t%s\n' "$(_classify "$tool" "$mcp" "$cmd")" "$tool" "${mcp:-$cmd}" >> "$(_ledger_file "$convo")" 2>/dev/null || true
    fi
  fi
  [ "${CLIKAE_DISPATCH:-0}" = "1" ] || { printf '%s' '{"decision":"allow"}'; exit 0; }
  [ "${CK_ALLOW_RULER_EDIT:-0}" = "1" ] && { printf '%s' '{"decision":"allow"}'; exit 0; }
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
ledger="$(_ledger_file "$convo")"

# --- 1. changed, not measured ------------------------------------------------
# The ledger is a list of `class<TAB>tool<TAB>detail` lines in call order. The
# question is one line long: is the LAST non-neutral entry a mutation?
if [ -s "$ledger" ]; then
  last_class="$(awk -F'\t' '$1=="mutating"||$1=="observing"{c=$1} END{print c}' "$ledger" 2>/dev/null)"
  if [ "$last_class" = "mutating" ]; then
    findings="${findings}- You changed something and have not measured it since. Measure it and show what the measurement printed.
"
  fi
fi

# --- 2. zero evidence (secondary, English only) --------------------------------------------------------
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

# --- 3. the project's own gate ----------------------------------------------
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

[ -n "$findings" ] || { rm -f "$count_file" "$ledger" 2>/dev/null; allow_stop; }

n=$((n + 1))
printf '%s' "$n" > "$count_file" 2>/dev/null || true

if [ "$n" -gt "$max" ]; then
  # Out of interruptions. Stop blocking, but do not pretend it passed: the last
  # word the human reads should be the unmet finding, not a clean finish.
  printf '%s\n' "⚠️  clikae harness: still unmet after $max attempt(s) — letting the session end." >&2
  printf '%s\n' "$findings" >&2
  rm -f "$count_file" "$ledger" 2>/dev/null
  allow_stop
fi

block_with "CLIKAE HARNESS — this claim is not accepted yet ($n/$max).

$findings
Fix it or say plainly what you did not do. Do not restate the claim."
