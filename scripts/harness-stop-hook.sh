#!/usr/bin/env bash
# harness-stop-hook.sh — Antigravity `Stop` hook: the agent may not finish until
# its report passes scripts/harness-gate.sh.
#
# Contract (verified against
# ~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md):
#   stdin  : JSON with workspacePaths, terminationReason, fullyIdle, … (line 296-303)
#   stdout : {"decision":"continue","reason":"…"} blocks the stop and injects
#            `reason` as a system message; any other value lets it stop (line 308-316)
#
# This is the piece the harness was missing. Rules and skills still rely on the
# agent choosing to comply; this one runs whether or not it wants to.
#
# It does NOT make faking impossible (the gate cannot tell a real transcript from
# a pasted one) — it makes finishing without a report impossible.
set -uo pipefail

REPORT_NAME="${CK_HARNESS_REPORT:-report.md}"

LOG="$HOME/.clikae/state/harness-hook.log"
note() { mkdir -p "$(dirname "$LOG")"; printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "${2:-}" >>"$LOG"; }

emit_continue() {
	note BLOCKED "$report"
	# Keep it on one line; the reason is injected verbatim as a system message.
	python3 -c 'import json,sys; print(json.dumps({"decision":"continue","reason":sys.argv[1]}, ensure_ascii=False))' "$1"
	exit 0
}

payload="$(cat)"

ws="$(printf '%s' "$payload" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
p = d.get("workspacePaths") or []
print(p[0] if p else "")
' 2>/dev/null || true)"

[ -n "$ws" ] || ws="$PWD"
gate="$ws/scripts/harness-gate.sh"
report="$ws/$REPORT_NAME"

# No gate in this workspace → this hook has no opinion here.
[ -x "$gate" ] || { echo '{"decision":"stop"}'; exit 0; }

if [ ! -f "$report" ]; then
	emit_continue "沒有 ${REPORT_NAME}。交付前必須寫一份三欄報告（觀察／推論／還沒驗），收據欄只收 \$ 指令＋輸出＋rc。寫好後再結束。"
fi

out="$("$gate" "$report" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
	emit_continue "${REPORT_NAME} 沒有通過 harness-gate，先修好再結束：
$out"
fi

note ALLOWED "$report"
echo '{"decision":"stop"}'
