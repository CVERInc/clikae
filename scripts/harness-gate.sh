#!/usr/bin/env bash
# harness-gate.sh — mechanical gate for agent-authored reports and design specs.
#
# This gate does NOT check whether you are careful. It checks whether the
# artifact has the SHAPE that only a careful process produces. It is greppable
# on purpose: the goal is to make running the command cheaper than writing a
# convincing sentence, not to prove the sentence is true.
#
# What it CANNOT do (state this, do not pretend otherwise):
#   - It cannot tell a real transcript from a fabricated one. A pasted `$ cmd`
#     + `rc=` block that never ran will pass. The gate raises the cost of
#     faking above the cost of running; it does not make faking impossible.
#   - Its guard/FIRES pairing is a count heuristic, not a proof of coverage.
#   - It reads only the artifact. It has no idea what the code actually does.
#
# Usage:
#   scripts/harness-gate.sh <file> [<file>...]
#   scripts/harness-gate.sh --selftest      # every check must be shown firing
#
# Exit: 0 all clean, 1 violations found, 2 usage error.
set -euo pipefail

VIOLATIONS=0
TMP_FINDINGS=$(mktemp)
SELFTEST_DIR=""
cleanup() {
	rm -f "$TMP_FINDINGS"
	[ -n "$SELFTEST_DIR" ] && rm -rf "$SELFTEST_DIR"
	return 0
}
trap cleanup EXIT

# Triumph vocabulary. A completion claim occupies the slot where the unverified
# list belongs; banning the words is how the slot stays open.
BANNED='無懈可擊|徹底解決|再無幻覺|終極版|終極|完美|100%|絕對不會|永不出錯|全部解決|bulletproof|flawless|no more bugs'

violation() {
	printf '  ✗ %s\n' "$1" >&2
	VIOLATIONS=$((VIOLATIONS + 1))
}

# Print the body of the first section whose heading contains $key, stopping at
# the next heading of any level.
extract_section() {
	local file=$1 key=$2
	awk -v key="$key" '
		/^#+[[:space:]]/ { insec = (index($0, key) > 0); next }
		insec { print }
	' "$file"
}

has_receipt_shape() {
	# A receipt is a pasted command line plus either a return code or output.
	printf '%s' "$1" | grep -qE '(^|\n)[[:space:]]*\$ ' &&
		printf '%s' "$1" | grep -qE 'rc=|EXIT=|回傳|exit [0-9]|→'
}

declares_no_receipt() {
	printf '%s' "$1" | grep -qE '收據：?無|無新收據|no receipts|未驗證'
}

check_banned() {
	local file=$1 hit
	if hit=$(grep -nE "$BANNED" "$file" | head -3); then
		while IFS= read -r line; do
			[ -n "$line" ] && violation "完成宣告詞彙（該位置應該是未驗清單）: $file:$line"
		done <<<"$hit"
	fi
}

# Paths whose job is to MEASURE the code. Editing one of these is editing the
# ruler, and a ruler change has to be argued for out loud — it is the cheapest
# way in existence to turn a red suite green.
TEST_INFRA_RE='^(tests/|scripts/test\.sh|\.github/)'

changed_test_infra() {
	local -a dcmd
	# CK_GATE_DIFF_CMD is a seam so the selftest can feed this check a fixed list.
	read -r -a dcmd <<<"${CK_GATE_DIFF_CMD:-git diff --name-only HEAD}"
	"${dcmd[@]}" 2>/dev/null | grep -E "$TEST_INFRA_RE" || true
}

check_test_infra() {
	local file=$1 changed p
	changed=$(changed_test_infra)
	[ -n "$changed" ] || return 0
	if ! grep -qE '^#+.*(尺的變更|測試基礎設施|test-infra)' "$file"; then
		violation "動了測試基礎設施卻沒有「尺的變更」欄: $file （$(printf '%s' "$changed" | tr '\n' ' ')）"
		return 0
	fi
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		grep -qF "$p" "$file" ||
			violation "「尺的變更」欄沒有列出 $p: $file"
	done <<EOF
$changed
EOF
}

check_report() {
	local file=$1 obs inf unv
	obs=$(extract_section "$file" 觀察)
	inf=$(extract_section "$file" 推論)
	unv=$(extract_section "$file" 還沒驗)

	[ -n "$(printf '%s' "$obs" | tr -d '[:space:]')" ] || violation "缺「觀察」欄: $file"
	[ -n "$(printf '%s' "$inf" | tr -d '[:space:]')" ] || violation "缺「推論」欄: $file"
	[ -n "$(printf '%s' "$unv" | tr -d '[:space:]')" ] || violation "缺「還沒驗」欄: $file"

	# The observation slot takes transcripts or an explicit admission. Prose in
	# that slot is the failure this whole gate exists for.
	if [ -n "$(printf '%s' "$obs" | tr -d '[:space:]')" ]; then
		if ! has_receipt_shape "$obs" && ! declares_no_receipt "$obs"; then
			violation "「觀察」欄沒有 \$ 指令＋rc（散文冒充收據）: $file"
		fi
	fi

	# An empty unverified list is not a clean bill of health, it is a claim that
	# you stopped thinking. Every real artifact has open edges.
	if [ -n "$(printf '%s' "$unv" | tr -d '[:space:]')" ]; then
		printf '%s' "$unv" | grep -qE '^\s*[-*]?\s*\[ \]' ||
			violation "「還沒驗」欄沒有任何 [ ] 項目（空清單＝沒在想）: $file"
	fi

	check_test_infra "$file"
}

check_spec() {
	local file=$1
	# Every rule heading needs a receipt slot, and that slot needs a transcript
	# or an explicit "收據：無".
	awk -v f="$file" '
		/^###[[:space:]]/ {
			if (rule != "") emit()
			rule = $0; line = NR; body = ""; next
		}
		# A higher-level heading ENDS the current rule. Without this the last
		# rule swallowed the rest of the file and was never really checked —
		# it only started failing once a rule was added after it.
		/^#{1,2}[[:space:]]/ {
			if (rule != "") { emit(); rule = "" }
			next
		}
		rule != "" { body = body "\n" $0 }
		END { if (rule != "") emit() }
		function emit() {
			if (index(body, "收據") == 0) {
				printf "MISSING\t%s\t%d\t%s\n", f, line, rule
			} else if (body !~ /\$ / && body !~ /收據：?無/ && body !~ /rc=/) {
				printf "PROSE\t%s\t%d\t%s\n", f, line, rule
			}
		}
	' "$file" >"$TMP_FINDINGS"
	# NB: read the findings via redirect, NOT `awk | while`. A pipeline puts the
	# loop in a subshell, so violation() increments a counter that dies with it —
	# the check prints and never changes the exit code. This gate shipped with
	# exactly that bug; the selftest caught it.
	while IFS=$'\t' read -r kind fname lno rule; do
		case "$kind" in
		MISSING) violation "規則沒有收據欄: $fname:$lno $rule" ;;
		PROSE) violation "收據欄是散文，沒有 \$ 指令或 rc（或誠實寫「收據：無」）: $fname:$lno $rule" ;;
		esac
	done <"$TMP_FINDINGS"

	# Every guard shipped must ship with an input that makes it fire.
	local guards fires
	guards=$(awk '
		/^```/ { inblk = !inblk; if (inblk) hit = 0; else if (hit) n++; next }
		inblk && /(^|[[:space:]])(if|case|trap)[[:space:]]/ { hit = 1 }
		END { print n + 0 }
	' "$file")
	fires=$(grep -cE '^[[:space:]]*(FIRES:|\*\*開火輸入\*\*)' "$file" || true)
	if [ "$guards" -gt "$fires" ]; then
		violation "有 $guards 段守衛程式碼，只有 $fires 個 FIRES: 開火輸入: $file"
	fi
}

gate_file() {
	local file=$1
	[ -f "$file" ] || {
		violation "檔案不存在: $file"
		return
	}
	printf '→ %s\n' "$file"
	check_banned "$file"
	# Detect on HEADINGS, not on the string anywhere. A document that merely
	# discusses the report format (this harness does) is not itself a report.
	if grep -qE '^#+.*(還沒驗|Unverified)' "$file"; then
		check_report "$file"
	elif grep -q '收據' "$file"; then
		check_spec "$file"
	else
		violation "認不出格式（需要 報告三欄 或 規格的 收據 欄）: $file"
	fi
}

# --- selftest -----------------------------------------------------------
# Rule 3 of the harness applies to the harness: every check below ships with an
# input that makes it fire. A check never seen failing is not known to work.
selftest() {
	local dir rc fails=0 total=0
	SELFTEST_DIR=$(mktemp -d)
	dir=$SELFTEST_DIR

	# Neutralise the git-diff seam for every fixture except the two that test it.
	export CK_GATE_DIFF_CMD=true

	expect() { # expect <want_rc> <name> <file>
		local want=$1 name=$2 f=$3
		total=$((total + 1))
		set +e
		"$0" "$f" >/dev/null 2>&1
		rc=$?
		set -e
		if [ "$rc" -eq "$want" ]; then
			printf '  ✅ %s (rc=%d)\n' "$name" "$rc"
		else
			printf '  ❌ %s: 期望 rc=%d 得到 rc=%d\n' "$name" "$want" "$rc"
			fails=$((fails + 1))
		fi
	}

	cat >"$dir/good-report.md" <<'EOF'
## 觀察
```
$ tmux show-options -g window-size
window-size latest
rc=0
```
## 推論
預設不會塌到最小 client。
## 還沒驗
- [ ] PineNote 端的 RequestTTY 行為
EOF

	cat >"$dir/honest-empty.md" <<'EOF'
## 觀察
無新收據。這一輪沒有自行設計探針。
## 推論
墊片遞迴應該會耗盡 process 上限。
## 還沒驗
- [ ] 墊片自我遞迴尚未實測
EOF

	cat >"$dir/bad-prose-receipt.md" <<'EOF'
## 觀察
經過深入推演，確認 tmux 的 window-size 行為符合預期。
## 推論
不需要處理。
## 還沒驗
- [ ] 無
EOF

	cat >"$dir/bad-missing-section.md" <<'EOF'
## 觀察
```
$ echo hi
rc=0
```
## 還沒驗
- [ ] 某件事
EOF

	cat >"$dir/bad-empty-unverified.md" <<'EOF'
## 觀察
```
$ echo hi
rc=0
```
## 推論
沒事。
## 還沒驗
全部驗完了。
EOF

	cat >"$dir/bad-banned.md" <<'EOF'
## 觀察
```
$ echo hi
rc=0
```
## 推論
這一版已經徹底解決所有問題。
## 還沒驗
- [ ] 沒有了
EOF

	cat >"$dir/good-spec.md" <<'EOF'
### Rule 1: 守衛
- 收據：
```
$ echo "$TMUX"
/private/tmp/tmux-502/default,66896,0
rc=0
```
- 規範：
```bash
if [ -n "$TMUX" ]; then :; fi
```
FIRES: `TMUX= scripts/shim claude` → 期望 rc=1 並印出 FATAL
EOF

	cat >"$dir/bad-spec-no-fires.md" <<'EOF'
### Rule 1: 守衛
- 收據：
```
$ echo "$TMUX"
rc=0
```
- 規範：
```bash
if [ -n "$TMUX" ]; then :; fi
```
EOF

	cat >"$dir/bad-spec-prose-receipt.md" <<'EOF'
### Rule 1: 守衛
- 收據：UNIX 進程無法從外部更改環境變數，這是常識。
- 規範：照著做就對了。
EOF

	cat >"$dir/bad-silent-ruler-change.md" <<'EOF'
## 觀察
```
$ ./scripts/test.sh
EXIT=0
```
## 推論
全部通過了。
## 還沒驗
- [ ] 互動路徑
EOF

	cat >"$dir/good-declared-ruler-change.md" <<'EOF'
## 觀察
```
$ ./scripts/test.sh
EXIT=0
```
## 尺的變更
改了 `tests/tools/pty-smoke.py`：注入 CLIKAE_PTY_SMOKE=1。
為什麼錯的是尺不是碼：（此處必須有理由，否則就是把紅的調成綠的）
## 推論
無。
## 還沒驗
- [ ] 撤掉這個變數之後 smoke 會不會紅
EOF

	echo "selftest — 每個檢查都必須被看到開火："
	expect 0 "乾淨報告放行" "$dir/good-report.md"
	expect 0 "誠實的『無新收據』放行" "$dir/honest-empty.md"
	expect 0 "乾淨規格放行" "$dir/good-spec.md"
	expect 1 "散文冒充收據 → 紅" "$dir/bad-prose-receipt.md"
	expect 1 "缺推論欄 → 紅" "$dir/bad-missing-section.md"
	expect 1 "未驗清單是空的 → 紅" "$dir/bad-empty-unverified.md"
	expect 1 "完成宣告詞彙 → 紅" "$dir/bad-banned.md"
	expect 1 "守衛沒有 FIRES 開火輸入 → 紅" "$dir/bad-spec-no-fires.md"
	expect 1 "規格收據是散文 → 紅" "$dir/bad-spec-prose-receipt.md"

	# The two fixtures that DO exercise the ruler-change check.
	CK_GATE_DIFF_CMD="printf %s\n tests/tools/pty-smoke.py" \
		expect 1 "動了測試基礎設施卻沒宣告 → 紅" "$dir/bad-silent-ruler-change.md"
	CK_GATE_DIFF_CMD="printf %s\n tests/tools/pty-smoke.py" \
		expect 0 "動了測試基礎設施並逐條宣告 → 放行" "$dir/good-declared-ruler-change.md"

	if [ "$fails" -eq 0 ]; then
		echo "selftest 全過（${total}/${total}）"
		return 0
	fi
	echo "selftest 失敗 $fails 項"
	return 1
}

main() {
	[ $# -ge 1 ] || {
		echo "usage: $0 <file>... | --selftest" >&2
		exit 2
	}
	if [ "$1" = "--selftest" ]; then
		selftest
		exit $?
	fi
	for f in "$@"; do gate_file "$f"; done
	if [ "$VIOLATIONS" -gt 0 ]; then
		printf '\n%d 項違規。\n' "$VIOLATIONS" >&2
		exit 1
	fi
	echo "clean"
}

main "$@"
