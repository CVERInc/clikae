#!/usr/bin/env bats
# tests/bats/home-narrow.bats — #155: below 60 columns the bare `clikae` board
# is the SAME board, laid out by subtraction and alignment; at 60 and up it is
# byte-for-byte what it was.
#
# Measured at 46 columns (a-Shell on an upright iPhone) before this: every tank
# row printed the full account email and wrapped; a dry tank's status repeated
# its timezone and landed at column 0 with an orphaned "…"; the footer cut its
# own key hint ("Press [R] to see all…"); the keybar split "[ ]" from
# "reorder". None of that is visible to board-width.bats, whose specimen has no
# email, no dry tank and no usage reading — so this file's fixture has all three.
#
# 🔴 The board is rendered for REAL: `clikae` on a tmux pane of the width under
# test, on its own throwaway server (`tmux -S <path>`, never the default socket
# and never an inherited $TMUX — see tmux-shim.bats for why that is not
# optional). `capture-pane -J` joins what the terminal wrapped, so a line that
# overflowed comes back as ONE line wider than the pane instead of hiding as two
# that each fit.
#
# PATH inside the pane is /usr/bin:/bin plus this suite's own bash and jq, so no
# engine installed on the host (codex, agy, grok…) can add an "Also available"
# row — the 100-column golden has to be the same on every machine.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_visible() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g'; }

_n155_source() {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/reading_cache.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/board_state.sh"
  source "$CLIKAE_LIB/commands/home.sh"
}

# The vendor's dated reset phrase ("Sep 28 at 1:46am"), 6h20m ahead of the real
# clock in Asia/Tokyo — anchored to the clock for the reason home.bats'
# _phrase_ahead gives: a hardcoded hour goes stale once a day.
_n155_phrase() {
  local ep h m mon d suf h12
  ep=$(( $(date -u +%s) + 6 * 3600 + 1200 ))
  _d() { TZ=Asia/Tokyo date -d "@$ep" "$1" 2>/dev/null || TZ=Asia/Tokyo date -r "$ep" "$1"; }
  h=$((10#$(_d +%H))); m="$(_d +%M)"; mon="$(_d +%b)"; d=$((10#$(_d +%d)))
  suf=am; [ "$h" -ge 12 ] && suf=pm
  h12=$(( h % 12 )); [ "$h12" -eq 0 ] && h12=12
  printf '%s %d at %d:%s%s' "$mon" "$d" "$h12" "$m" "$suf"
}

# Four tanks with every field the narrow board has to give up or reflow: an
# email on each claude tank, one dry tank (dated reset + zone), one with a
# vendor reading that binds on a named model, and two sessions in the cwd, one
# titled in CJK.
_n155_seed() {
  clikae init claude work  >/dev/null
  clikae init claude dry   >/dev/null
  clikae init claude busy  >/dev/null
  clikae init codex  cheap >/dev/null
  local t now ago p slug d5
  for t in work dry busy; do
    printf '{\n  "oauthAccount": {\n    "emailAddress": "%s.person@example-company.com"\n  }\n}\n' "$t" \
      > "$CLIKAE_HOME/profiles/claude/$t/.claude.json"
  done
  now="$(date -u +%s)"
  ago="$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
  N155_PHRASE="$(_n155_phrase)"
  p="$CLIKAE_HOME/profiles/claude/dry/projects/-Users-x"; mkdir -p "$p"
  printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit · resets '"$N155_PHRASE"' (Asia/Tokyo)"}]},"timestamp":"'"$ago"'"}' > "$p/s.jsonl"
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  printf '{"window_pct":44,"weekly_pct":20,"window_resets_at":"2099-01-01T00:00:00+00:00","weekly_resets_at":"2099-01-07T00:00:00+00:00","models":[{"name":"Fable","pct":100,"resets_at":"2099-01-07T00:00:00+00:00"}],"source":"vendor","cached_at":%d,"scanned_at":%d}\n' \
    "$now" "$now" > "$CLIKAE_HOME/state/usage/claude/busy.json"
  mkdir -p "$TEST_HOME/w"
  slug="$(printf '%s' "$TEST_HOME/w" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  p="$CLIKAE_HOME/profiles/claude/work/projects/$slug"; mkdir -p "$p"
  { printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"first"}]}}\n'
    printf '{"type":"ai-title","aiTitle":"Refactor the payment reconciliation pipeline","sessionId":"dead0000-0000-0000-0000-000000000000"}\n'
  } > "$p/dead0000-0000-0000-0000-000000000000.jsonl"
  { printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"second"}]}}\n'
    printf '{"type":"ai-title","aiTitle":"支払い照合パイプラインを段階的に書き直す計画","sessionId":"beef0000-0000-0000-0000-000000000000"}\n'
  } > "$p/beef0000-0000-0000-0000-000000000000.jsonl"
  d5="$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '5 minutes ago' +%Y%m%d%H%M.%S)"
  touch -t "$d5" "$p/dead0000-0000-0000-0000-000000000000.jsonl"
  # The board consumes the session-boundary snapshot; publish it (home.bats'
  # _home_publish_fixture does the same, one tank at a time).
  ( cd "$TEST_HOME/w" && _n155_source && for t in work dry busy; do
      board_state_refresh claude "$CLIKAE_HOME/profiles/claude/$t"; done )
  mkdir -p "$TEST_HOME/pbin"
  ln -sf "$(command -v bash)" "$TEST_HOME/pbin/bash"
  command -v jq >/dev/null 2>&1 && ln -sf "$(command -v jq)" "$TEST_HOME/pbin/jq"
  return 0
}

# _n155_render <cols> [keys…] -> N155_OUT: the interactive board as the screen
# shows it, wrapped lines joined back into the lines the board printed.
_n155_render() {
  local cols="$1"; shift
  local sock="$TEST_HOME/n155-$cols.sock" k
  tmux -S "$sock" -f /dev/null new-session -d -s b -x "$cols" -y 60 \
    "cd '$TEST_HOME/w' && env -i HOME='$TEST_HOME' CLIKAE_HOME='$CLIKAE_HOME' PATH='$TEST_HOME/pbin:/usr/bin:/bin' TERM=xterm-256color LANG=C.UTF-8 LC_ALL=C.UTF-8 CLIKAE_LANG=en-US NO_COLOR=1 CLIKAE_NO_UPDATE_CHECK=1 CLIKAE_CODEX_USAGE_PROBE=0 '$CLIKAE_BIN'; sleep 60"
  for _ in $(seq 1 150); do
    tmux -S "$sock" capture-pane -p -t b 2>/dev/null | grep -q 'sessions total' && break
    sleep 0.1
  done
  for k in "$@"; do tmux -S "$sock" send-keys -t b "$k"; sleep 0.2; done
  sleep 0.8
  N155_OUT="$(tmux -S "$sock" capture-pane -p -J -t b | sed 's/[[:space:]]*$//')"
  tmux -S "$sock" kill-server 2>/dev/null || true
}

# The first column (0-based) at which <needle> occurs in <line>, by DISPLAY width.
_n155_col() {
  local pre="${1%%"$2"*}"
  _dwidth "$pre"
}

# Per test, not a setup(): a file-level setup() would replace helpers.bash's,
# which is what builds the throwaway $HOME in the first place.
_n155_setup() {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # macOS: $TMPDIR is /var/... but the shell in the pane resolves /private/var/...;
  # use the physical path so the cwd slug and the "~/" shortening both match.
  TEST_HOME="$(cd "$TEST_HOME" && pwd -P)"
  _n155_source
  _n155_seed
}

@test "narrow board (#155): at 46 columns no line is wider than 46 display columns" {
  _n155_setup
  _n155_render 46
  [[ "$N155_OUT" == *"Tanks"* ]] || { echo "board never drew: $N155_OUT"; false; }
  local line bad=""
  while IFS= read -r line; do
    [ "$(_dwidth "$line")" -le 46 ] || bad="$bad"$'\n'"  $(_dwidth "$line"): $line"
  done <<< "$N155_OUT"
  [ -z "$bad" ] || { echo "wider than 46:$bad"; echo "--- board ---"; echo "$N155_OUT"; false; }
}

@test "narrow board (#155): at 46 columns no email appears, and the status is one relative line" {
  _n155_setup
  _n155_render 46
  [[ "$N155_OUT" == *"Tanks"* ]] || { echo "board never drew: $N155_OUT"; false; }
  [[ "$N155_OUT" != *"@"* ]] || { echo "an email is on the board:"; echo "$N155_OUT"; false; }
  # Rule 2: the reset is relative, and the zone it carried is gone with it.
  [[ "$N155_OUT" == *"⟳"[0-9]*[mhd]* ]] || { echo "no relative reset:"; echo "$N155_OUT"; false; }
  [[ "$N155_OUT" != *"Asia/Tokyo"* ]] || { echo "the timezone is still printed:"; echo "$N155_OUT"; false; }
  # …and a status is never split mid-token: the whole reading is on one line.
  grep -qF 'window 44% · weekly 20% · Fable 100%' <<< "$N155_OUT" || {
    echo "the usage status was split:"; echo "$N155_OUT"; false; }
}

@test "narrow board (#155): at 46 columns every key hint is complete" {
  _n155_setup
  _n155_render 46
  [[ "$N155_OUT" == *"Tanks"* ]] || { echo "board never drew: $N155_OUT"; false; }
  local h
  # The keybar with the cursor on a tank: every item on ONE line, whole.
  for h in "↑↓/Tab move" "⏎ open" "[ ] reorder" "/ filter" "? help" "q quit"; do
    grep -qF -- "$h" <<< "$N155_OUT" || { echo "hint not whole on one line: '$h'"; echo "$N155_OUT"; false; }
  done
  # The footer is a hint too: wrapped, never cut. Join it back and read it.
  local foot
  foot="$(sed -n '/sessions total/,$p' <<< "$N155_OUT" | sed 's/^ *//' | tr '\n' ' ' | sed 's/ *$//')"
  [[ "$foot" == *"3 sessions total · Press [R] to see all / search"* ]] || {
    echo "footer hint incomplete: '$foot'"; echo "$N155_OUT"; false; }
}

@test "narrow board (#155): at 46 columns continuation lines sit under the name column" {
  _n155_setup
  _n155_render 46
  [[ "$N155_OUT" == *"Tanks"* ]] || { echo "board never drew: $N155_OUT"; false; }
  local row next ncol lead
  # The busy tank's status does not fit beside it, so it continues below.
  row="$(grep -m1 ' busy ' <<< "$N155_OUT")"
  next="$(grep -A1 -m1 ' busy ' <<< "$N155_OUT" | sed -n 2p)"
  ncol="$(_n155_col "$row" busy)"
  lead="${next%%[! ]*}"
  [ "${#lead}" -eq "$ncol" ] && [[ "$next" == *"window 44%"* ]] || {
    echo "status continuation at col ${#lead}, name at col $ncol:"; echo "$row"; echo "$next"; false; }
  # The selected resume row's hover line (5 × Down: 4 tanks, then the 2nd session).
  _n155_render 46 Down Down Down Down Down
  row="$(grep -m1 '❯' <<< "$N155_OUT")"
  next="$(grep -A1 -m1 '❯' <<< "$N155_OUT" | sed -n 2p)"
  [[ "$row" == *Refactor* ]] || { echo "cursor is not on the session: $row"; echo "$N155_OUT"; false; }
  ncol="$(_n155_col "$row" work)"
  lead="${next%%[! ]*}"
  [ "${#lead}" -eq "$ncol" ] && [[ "$next" == *"Enter to resume"* ]] || {
    echo "hover line at col ${#lead}, name at col $ncol:"; echo "$row"; echo "$next"; false; }
}

@test "narrow board (#155): same sections, same order, same cursor as the wide board" {
  _n155_setup
  local wide narrow
  _n155_render 100; wide="$N155_OUT"
  _n155_render 46;  narrow="$N155_OUT"
  _skel() { grep -oE '▸ (Tanks|Resume)|❯|(busy|dry|work|cheap) |"(Refactor|支払い)' <<< "$1" | tr '\n' '|'; }
  [ "$(_skel "$wide")" = "$(_skel "$narrow")" ] || {
    echo "wide:   $(_skel "$wide")"; echo "narrow: $(_skel "$narrow")"; false; }
}

@test "wide board (#155): at 100 columns the board is unchanged from before the narrow layout" {
  _n155_setup
  command -v jq >/dev/null 2>&1 || skip "jq not installed (the golden carries a usage reading)"
  _n155_render 100
  local got want
  got="$(printf '%s\n' "$N155_OUT" | sed "s|$N155_PHRASE|@PHRASE@|g")"
  want="$(cat "$CLIKAE_TEST_ROOT/tests/fixtures/home-narrow-100.txt")"
  [ "$got" = "$want" ] || { diff <(printf '%s\n' "$want") <(printf '%s\n' "$got"); false; }
}
