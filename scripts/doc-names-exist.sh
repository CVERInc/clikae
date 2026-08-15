#!/usr/bin/env bash
# scripts/doc-names-exist.sh — the docs must not name things the code lacks.
#
# WHY THIS IS A GATE AND NOT A HABIT. Three defects in v0.24.0/v0.25.0 were one
# shape: a document naming something the source did not have.
#
#   1. clikae_spawn_session   3 mentions in DESIGN-tmux, 0 definitions, for two
#                             years, while four call sites hand-rolled the rules
#                             it was supposed to hold and drifted apart.
#   2. fleet_mcp_prelaunch    its docstring named switch.sh / run.sh as the
#                             callers; relay.sh had it too and burn.sh had none.
#   3. window-size latest     Rule 1 described the behaviour and nothing set the
#                             option, so it held on tmux 3.7b and not on 3.4.
#
# A doc that names a thing is what an auditor reads INSTEAD of the code. A stale
# one does not merely fail to help — it hides the gap it would otherwise expose,
# because the reader now believes the thing exists. That is how (1) survived an
# audit looking for exactly it.
#
# 🔴 The first version of this script checked shape 1 only, and passed both
# negative controls for 2 and 3 — a gate motivated by three defects that caught
# one of them. Each check below therefore has a probe in
# tests/bats/doc-contract.bats proving it fires.
#
# Prose drifts and cannot be checked. A name, a call site, and an option can.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# 🔴 Scan TRACKED source, not the working directory. Measured 2026-08-16: a
# `sed -i.bak` left lib/commands/*.sh.bak on disk and this gate read them as
# repo source — both directions at once. False negative: a function renamed in
# every real file still "existed", because its old definition survived in the
# backup, so the gate stayed green on exactly the drift it exists to catch.
# False positive: the backup counted as a caller, so check 2 demanded the
# docstring list `burn.sh.bak`. An editor swapfile, a merge .orig, or an
# untracked experiment does the same. What the code HAS is a statement about
# the tracked tree; anything else on disk is a copy, and a copy is not the SSOT.
# No mapfile/readarray here: clikae targets macOS's stock bash 3.2, and this
# gate runs from scripts/test.sh on that very shell.
SRC=(); DOCS=()
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  list_src() { git ls-files 'lib/*' 'bin/*' 2>/dev/null; }
  list_doc() { git ls-files 'docs/*.md' AGENTS.md README.md 2>/dev/null | grep -v '^docs/proposals/'; }
else
  # Tarball / brew install: no index to ask, so exclude the junk by name.
  list_src() { find lib bin -type f ! -name '*.bak' ! -name '*.orig' \
    ! -name '*.rej' ! -name '*~' 2>/dev/null | sort; }
  list_doc() { { find docs -name '*.md' ! -name '*.bak' ! -path 'docs/proposals/*' 2>/dev/null | sort
                 ls AGENTS.md README.md 2>/dev/null; }; }
fi
while IFS= read -r f; do [ -n "$f" ] && SRC+=("$f"); done <<SRCLIST
$(list_src)
SRCLIST
# A copy of the tree that happens to sit inside some OTHER repo answers
# `is-inside-work-tree` yes and `ls-files` nothing. Fall back rather than die.
if [ "${#SRC[@]:-0}" -eq 0 ]; then
  list_src() { find lib bin -type f ! -name '*.bak' ! -name '*.orig' \
    ! -name '*.rej' ! -name '*~' 2>/dev/null | sort; }
  list_doc() { { find docs -name '*.md' ! -name '*.bak' ! -path 'docs/proposals/*' 2>/dev/null | sort
                 ls AGENTS.md README.md 2>/dev/null; }; }
  while IFS= read -r f; do [ -n "$f" ] && SRC+=("$f"); done <<SRCFALLBACK
$(list_src)
SRCFALLBACK
fi
while IFS= read -r f; do [ -n "$f" ] && DOCS+=("$f"); done <<DOCLIST
$(list_doc)
DOCLIST
[ "${#SRC[@]:-0}" -gt 0 ] && [ "${#DOCS[@]:-0}" -gt 0 ] || { echo "no source/docs found" >&2; exit 1; }
# The subsets each check needs, filtered from the same tracked list.
CMDS=(); CORE=()
for f in "${SRC[@]}"; do
  case "$f" in lib/commands/*) CMDS+=("$f") ;; esac
  case "$f" in lib/core/*)     CORE+=("$f") ;; esac
done

# docs/proposals/ is out of scope on purpose: a proposal names the function it
# is asking for, and that function does not exist yet — that is what a proposal
# IS. Gating it would mean either no proposals or an allowlist entry per idea.
# (Found 2026-08-16 when switching to tracked files widened the doc set: three
# names from issue-22/24/25 fired, all of them correct as written.)
ALLOW_NAME="docs/.doc-names-allow"
ALLOW_OPT="docs/.doc-options-allow"
fail=0

say_fail() { printf '  ✖ %s\n' "$*"; fail=$((fail + 1)); }

# ── 1. Every function a doc NAMES must be defined ───────────────────────────
# Two extractions, unioned — because either one alone has a hole the other fills.
#
# (a) known prefixes, ANYWHERE in prose. Catches a name written mid-sentence or
#     inside a longer backticked phrase, which (b) cannot see.
# (b) any backticked all-lowercase token containing an underscore. Catches names
#     whose prefix I did not think to list.
#
# 🔴 (a) was the whole check until 2026-08-16, and its prefix list was a GUESS at
# what the docs name. Measured: 20 real functions were named in the docs and
# invisible to it — tank_is_solo, next_tank, history_log, load_adapter, five
# limit_*, and more. Negative control: renaming tank_is_solo in the docs left the
# gate green. A gate whose scope is an enumeration I wrote from memory is silent
# on precisely the names I forgot, and forgetting is the failure it exists to
# catch. (b) needs no such list: a lowercase identifier with an underscore, in
# backticks, is a function name or it is an exemption with a written reason.
names="$(
  {
    grep -ohE '\b(clikae_[a-z_]+|tmux_[a-z_]+|_switch_[a-z_]+|soul_[a-z_]+|wake_[a-z_]+|live_[a-z_]+|fleet_mcp_[a-z_]+|_home_[a-z_]+|memory_[a-z_]+|adapter_[a-z_]+)\b' \
      "${DOCS[@]}" 2>/dev/null || true
    grep -ohE '`[a-z_][a-z0-9_]*`' "${DOCS[@]}" 2>/dev/null | tr -d '`' | grep '_' || true
  } | sort -u || true)"
while IFS= read -r fn; do
  [ -n "$fn" ] || continue
  grep -qE "${fn}\.[a-z]" "${DOCS[@]}" 2>/dev/null && continue          # a filename
  [ -f "$ALLOW_NAME" ] && grep -qE "^${fn}[[:space:]]" "$ALLOW_NAME" && continue
  grep -qE "^[[:space:]]*${fn}\(\)" "${SRC[@]}" 2>/dev/null \
    || say_fail "$fn — named in a doc, defined nowhere"
done <<NAMES
$names
NAMES

# ── 2. Every "Called from a.sh / b.sh" list must be the REAL caller set ─────
# The shape that hid burn's missing prelaunch: the docstring named two files, a
# third had the call, and a fourth needed it. An enumeration is only useful if
# it is complete, so check it in both directions.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  src="${line%%:*}"; rest="${line#*:}"
  # The function is the nearest definition BELOW the comment in the same file.
  ln="$(cut -d: -f2 <<<"$line" 2>/dev/null || true)"
  fn="$(awk -v start="$ln" 'NR>start && /^[a-z_][a-zA-Z0-9_]*\(\)/ {sub(/\(\).*/,""); print; exit}' "$src")"
  [ -n "$fn" ] || continue
  claimed="$(grep -oE '[a-z_]+\.sh' <<<"$rest" | sort -u)"
  [ -n "$claimed" ] || continue
  actual="$(grep -lE "^[[:space:]]*${fn}[[:space:]\"]" "${CMDS[@]}" 2>/dev/null | xargs -n1 basename 2>/dev/null | sort -u)"
  for c in $claimed; do
    grep -qx "$c" <<<"$actual" || say_fail "$fn's docstring names $c as a caller, and $c does not call it"
  done
  for a in $actual; do
    grep -qx "$a" <<<"$claimed" || say_fail "$a calls $fn and the docstring does not list it"
  done
done <<CALLERS
$(grep -nE '^# .*[Cc]alled from .*\.sh' "${CORE[@]}" 2>/dev/null || true)
CALLERS

# ── 3. Every tmux option a design rule names must actually be set ───────────
# Rule 1 described `window-size latest` for a year and nothing set it, so the
# behaviour held on one tmux and not another. A rule that states a setting is a
# claim about the code.
# 🔴 Match a backtick followed by the NAME, not a fully-backticked name. The
# doc writes `window-size latest` — value inside the quotes — so a regex needing
# a closing backtick right after the name skipped exactly the option that
# motivated this check, while quietly matching four others and looking healthy.
opts="$(grep -ohE '`(window-size|history-limit|terminal-overrides|terminal-features|extended-keys|set-clipboard|mouse|fill-character|remain-on-exit|exit-empty|aggressive-resize|default-size)\b' \
  docs/DESIGN-tmux.md 2>/dev/null | tr -d '`' | sort -u || true)"
while IFS= read -r opt; do
  [ -n "$opt" ] || continue
  [ -f "$ALLOW_OPT" ] && grep -qE "^${opt}[[:space:]]" "$ALLOW_OPT" && continue
  grep -qE "set-option.*\b${opt}\b" lib/core/tmux.sh 2>/dev/null \
    || say_fail "$opt — named in DESIGN-tmux, never set in lib/core/tmux.sh"
done <<OPTS
$opts
OPTS

if [ "$fail" -gt 0 ]; then
  printf '\n%d doc claim(s) the code does not back.\n' "$fail" >&2
  printf 'Fix the code, fix the doc, or add a reason to %s / %s.\n' "$ALLOW_NAME" "$ALLOW_OPT" >&2
  exit 1
fi
printf '  docs name nothing the code lacks (functions, call sites, tmux options)\n'
