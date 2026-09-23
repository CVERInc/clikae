#!/usr/bin/env bash
# scripts/verify-tmux-birth.sh — the manual half of DESIGN-tmux Rule 7.
#
# WHY A SCRIPT AND NOT A TEST. What Rule 7 describes cannot be reached from bats:
# it is a property of the tmux SERVER that hosts the session, decided once at
# birth, on a real machine, against real macOS TCC. The suite covers the logic
# with an injected stub; this covers the thing itself. Run it from a terminal on
# the desktop — Ghostty, iTerm, Terminal — AFTER `clikae` has started a session.
#
# Read-only. It never creates or kills a server; running it twice is the same as
# running it once.
#
# 🔴 THREE STATES, NOT TWO — the same discipline the probe itself carries. A
# check this script cannot perform is reported as `skip`, never as a pass. The
# whole class of bug being guarded against here is a green light that means
# "I did not look".

set -uo pipefail

pass=0; fail=0; skip=0
ok()   { printf '  \033[32m✅ PASS\033[0m  %s\n' "$*"; pass=$((pass+1)); }
no()   { printf '  \033[31m🔴 FAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
sk()   { printf '  \033[33m—  skip\033[0m  %s\n' "$*"; skip=$((skip+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

printf '\n\033[1mverify-tmux-birth\033[0m — DESIGN-tmux Rule 7, on the real machine\n'

# ── 0. Is the code under test even the code that is installed? ───────────────
# Asked first because every later check would otherwise measure the OLD clikae
# and pass for the wrong reason. (2026-08-15: the fix lived in a working copy
# while `clikae` on PATH was the Homebrew build, which had none of it.)
head_ '0. is the installed clikae the one with the tmux layer?'
CK="$(command -v clikae 2>/dev/null || true)"
if [ -z "$CK" ]; then
  no "clikae is not on PATH"
else
  # Derive the install root from the binary that is ACTUALLY on PATH.
  #
  # 🔴 Do NOT read $CLIKAE_ROOT. It is set when a session starts and keeps
  # pointing at whatever was installed then — this check reported a correct
  # 0.24.0 install as broken because the inherited value still named the 0.23.0
  # Cellar that `brew cleanup` had just deleted. A stale pointer measured
  # instead of the disk is the same defect the rest of this file hunts.
  root=""
  # Homebrew installs a shim whose body execs the real path.
  shim_target="$(sed -n 's|.*exec "\(/.*\)/bin/clikae".*|\1|p' "$CK" 2>/dev/null | head -1)"
  if [ -n "$shim_target" ] && [ -d "$shim_target" ]; then
    root="$shim_target"
  else
    # install.sh puts bin/clikae one level under <prefix>/share/clikae.
    real="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$CK" 2>/dev/null || printf '%s' "$CK")"
    root="$(dirname "$(dirname "$real")")"
  fi
  if [ -n "$root" ] && [ -f "$root/lib/core/tmux.sh" ]; then
    ok "installed clikae has lib/core/tmux.sh  ($(clikae version 2>/dev/null | head -1))"
    printf '            root: %s\n' "$root"
  else
    no "installed clikae has NO lib/core/tmux.sh — it predates this work. Nothing below will mean what it says."
    printf '            looked in: %s\n' "${root:-<unresolved>}"
  fi
fi

# ── 1. Was this server born by the new constructor? ─────────────────────────
head_ '1. birth record (Rule 7.3)'
if ! command -v tmux >/dev/null 2>&1; then
  sk "tmux not installed"
elif ! tmux list-sessions >/dev/null 2>&1; then
  sk "no tmux server running — start a clikae session first"
else
  born="$(tmux show-environment -g CLIKAE_SERVER_BORN 2>/dev/null | sed -n 's/^CLIKAE_SERVER_BORN=//p')"
  if [ -n "$born" ]; then
    ok "CLIKAE_SERVER_BORN = $born"
    case "$born" in
      *tty*) ok "born from a tty — a human was present, so a grant could exist" ;;
      *)     no "born 'no-tty': this server came from an unattended context and may hold no file-access grant" ;;
    esac
  else
    no "no birth record — this server predates the change, or was created by something other than tmux_spawn_session"
  fi
fi

# ── 2. Selection and copy (Rule 9) ──────────────────────────────────────────
head_ '2. selection / copy (Rule 9)'
if tmux list-sessions >/dev/null 2>&1; then
  m="$(tmux show-options -gv mouse 2>/dev/null || echo '?')"
  c="$(tmux show-options -sv set-clipboard 2>/dev/null || echo '?')"
  [ "$m" = on ] && ok "mouse = on"          || no "mouse = $m (want on) — the wheel scrolls redraw debris, not tmux history"
  [ "$c" = on ] && ok "set-clipboard = on"  || no "set-clipboard = $c (want on) — a copy-mode yank never reaches the system clipboard"
else
  sk "no server to ask"
fi

# ── 3. The options are applied once, not once per session (Rule 9 note) ─────
head_ '3. global options are not accumulating'
if tmux list-sessions >/dev/null 2>&1; then
  o="$(tmux show-options -g terminal-overrides 2>/dev/null | grep -c 'smcup@' || true)"
  f="$(tmux show-options -s terminal-features 2>/dev/null | grep -c 'extkeys' || true)"
  [ "${o:-0}" -le 1 ] && ok "terminal-overrides carries $o copy of smcup@"   || no "terminal-overrides carries $o copies of smcup@ — appending on every spawn again"
  [ "${f:-0}" -le 1 ] && ok "terminal-features carries $f copy of extkeys"   || no "terminal-features carries $f copies of extkeys"
else
  sk "no server to ask"
fi

# ── 4. The thing this was all for ───────────────────────────────────────────
head_ '4. can a tank read its own memory?'
MEM="$HOME/.clikae/souls/me/memory"
if [ ! -e "$MEM" ]; then
  sk "no Soul store at $MEM"
elif ls "$MEM" >/dev/null 2>&1; then
  ok "memory is readable — the original 2026-08-15 failure is gone"
else
  if [ -r "$MEM" ]; then
    no "memory unreadable while the permission bits allow it — this server holds no file-access grant (Rule 7)"
  else
    no "memory unreadable and the bits deny it — an ordinary permissions problem, NOT the tmux one"
  fi
fi

# ── 5. The probe must be SILENT when everything is fine ─────────────────────
# A warning that also fires on healthy input trains you to ignore it.
head_ '5. positive control: the probe says nothing when it should not'
# Pick a lib dir that has the WHOLE set. Taking soul.sh alone found the old
# installed copy, whose directory has no tmux.sh — the source failed, and the
# check reported "the probe spoke" when what actually happened was that it never
# ran. A probe test that cannot tell "silent" from "never executed" is the exact
# defect this file exists to catch.
LIBD=""
for cand in "$(dirname "$0")/../lib/core" "${CLIKAE_LIB:-}/core"; do
  [ -f "$cand/soul.sh" ] && [ -f "$cand/tmux.sh" ] && [ -f "$cand/log.sh" ] || continue
  grep -q 'memory_access_warn()' "$cand/soul.sh" 2>/dev/null || continue
  LIBD="$cand"; break
done
if [ -z "$LIBD" ]; then
  sk "no lib/core with log+tmux+soul and a memory_access_warn to test"
else
  tmpd="$(mktemp -d)"; : > "$tmpd/MEMORY.md"
  out="$(bash -c "set -e
    source '$LIBD/log.sh'; source '$LIBD/tmux.sh'; source '$LIBD/soul.sh'
    declare -F memory_access_warn >/dev/null || { echo '__NOT_LOADED__'; exit 0; }
    memory_access_warn '$tmpd'" 2>&1)"
  rm -rf "$tmpd"
  case "$out" in
    "")              ok "silent on a healthy memory dir  (from $LIBD)" ;;
    *__NOT_LOADED__*) sk "memory_access_warn did not load — cannot tell silent from absent" ;;
    *)               no "spoke when it should not have:"; printf '%s\n' "$out" ;;
  esac
fi

# ── 6. The negative control cannot be recreated here ────────────────────────
head_ '6. negative control (real TCC)'
sk "cannot be synthesised on a healthy machine — a genuinely TCC-blind server is"
printf '          needed, and rebooting removes the one we had. The receipt taken on\n'
printf '          2026-08-15 from that server is recorded in docs/DESIGN-tmux.md Rule 7.\n'

printf '\n  \033[1m%d pass, %d fail, %d skip\033[0m\n' "$pass" "$fail" "$skip"
printf '  \033[2mskip is not a pass — it is a question this run could not ask.\033[0m\n\n'
[ "$fail" -eq 0 ]
