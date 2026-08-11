#!/usr/bin/env bash
# harness-pretool-hook.sh — Antigravity `PreToolUse` hook: refuse to let a
# dispatched agent edit the ruler (tests/, scripts/test.sh, .github/) as a side
# effect of a task that is not about tests. S9 in docs/gemini-harness.md.
#
# Contract (verified against
# ~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md:181-196):
#   stdin  : JSON with toolCall{name,args}, stepIdx, workspacePaths, …
#   stdout : {"decision":"allow"|"deny"|"ask"|"force_ask", "reason": "…"}
#   decision is REQUIRED. Emitting {} is not "no opinion" — the tool does not run.
#
# FAIL OPEN. Measured 2026-08-11: a PreToolUse hook that errors, or answers
# without a decision, blocks every tool call — the agent retried list_dir 13 times
# and gave up. A broken guard must not brick the agent, so every unexpected path
# below ends in "allow".
#
# Escape hatch: the ruler may legitimately need to change. Declare it first —
#   CK_ALLOW_RULER_EDIT=1 in the dispatching environment — and say so in the
#   report's 尺的變更 column, which harness-gate.sh then checks against git.
set -uo pipefail

allow() { printf '{"decision":"allow"}\n'; exit 0; }
trap allow ERR

[ -n "${CK_ALLOW_RULER_EDIT:-}" ] && allow

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || allow

verdict="$(printf '%s' "$payload" | python3 -c '
import json, re, sys

# A path can appear anywhere in a command line, so anchoring on ^ or / misses
# `sed -i … tests/x` entirely. Guard against word-chars instead, so "contests/"
# does not match while " tests/", "\"tests/", "./tests/" and "a/tests/" do.
RULER = re.compile(r"(?<![\w.-])(tests/|\.github/|scripts/test\.sh)")
# Tools that only look. Everything else is treated as capable of writing —
# run_command included, since `sed -i` and `>` live there.
READ_ONLY = {"list_dir", "view_file", "read_file", "grep_search", "codebase_search",
             "search_web", "ask_question", "view_code_item", "read_url_content"}

try:
    d = json.load(sys.stdin)
    tc = d.get("toolCall") or {}
    name = tc.get("name") or ""
    if name in READ_ONLY:
        print("allow"); raise SystemExit
    blob = json.dumps(tc.get("args") or {})
    if RULER.search(blob):
        print("deny\t%s" % name); raise SystemExit
    print("allow")
except SystemExit:
    raise
except Exception:
    print("allow")
' 2>/dev/null || printf 'allow')"

case "$verdict" in
	deny*)
		tool="${verdict#deny}"
		tool="${tool#	}"
		python3 -c '
import json, sys
print(json.dumps({
    "decision": "deny",
    "reason": ("harness: %s targets the ruler (tests/, scripts/test.sh, .github/) and this task "
               "did not declare a ruler change. If the ruler really is what is wrong, say so in "
               "the report under 尺的變更 and have the dispatcher set CK_ALLOW_RULER_EDIT=1."
               % (sys.argv[1] or "this tool")),
}, ensure_ascii=False))' "$tool" 2>/dev/null || allow
		;;
	*) allow ;;
esac
