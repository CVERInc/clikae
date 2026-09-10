#!/usr/bin/env bats
# tests/bats/live.bats — the board's Live section: what is running right now.
#
# It exists because of a real report: ssh in, run `clikae`, and the session you
# left running was nowhere on the page. The board could say which accounts you
# had and what you did yesterday, but not what was alive — a category tmux
# created and the board never grew.
#
# These drive the STATIC render (no tty), which is what `clikae` prints when it
# is not drawing the interactive picker, so the rows can be read as text.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

# A tank name unique to this test, so real sessions on the developer's machine
# and parallel runs cannot be mistaken for the fixture.
_tank() { printf 'lv%s%s' "$$" "${BATS_TEST_NUMBER:-0}"; }
_sess() { printf 'clikae-codex-%s' "$(_tank)"; }
# claude fixtures (below) need a real transcript on disk, and claude's adapter
# scopes "this dir's sessions" by $PWD's slug — same transform as
# _claude_project_slug in lib/adapters/claude.sh, kept in sync by hand since
# this file does not load adapters.
_csess() { printf 'clikae-claude-%s' "$(_tank)"; }
_slug() { printf '%s' "$PWD" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

# Write a minimal claude transcript at <dir>/projects/<slug>/<sid>.jsonl whose
# title resolves to <title> (adapter_title_for_file matches a bare
# customTitle line — see lib/adapters/claude.sh), stamped at <mtime>
# ("[[CC]]YY]MMDDhhmm[.ss]", touch -t's format).
_claude_transcript() {
  local dir="$1" sid="$2" title="$3" mtime="$4" proj
  proj="$dir/projects/$(_slug)"
  mkdir -p "$proj"
  printf '{"type":"custom-title","customTitle":"%s"}\n' "$title" > "$proj/$sid.jsonl"
  touch -t "$mtime" "$proj/$sid.jsonl"
}

# Extract just the "▸ Live" section from a board render — the SAME title also
# appears in "▸ Resume" (this dir's recent transcripts, plural, independent of
# what is live), so an assertion against the whole $output can pass by reading
# the wrong section. Mirrors the extraction the pre-existing dup-rows test
# above already uses.
_live_block() { printf '%s\n' "$1" | awk '/▸ Live/{f=1; next} /▸ /{f=0} f && NF'; }

teardown() {
  tmux kill-session -t "$(_sess)" 2>/dev/null || true
  tmux kill-session -t "$(_sess)-4242" 2>/dev/null || true
  tmux kill-session -t "$(_csess)" 2>/dev/null || true
  tmux kill-session -t "$(_csess)-4242" 2>/dev/null || true
  [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
  return 0
}

@test "live: a running session appears, with its tank and engine" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init codex "$(_tank)"
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"Live"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$(_tank)"* ]] || { echo "$output"; false; }
}

@test "live: no running session means no section — not an empty one" {
  # clikae's habit everywhere else: when it cannot read something it says
  # nothing, rather than printing a heading with nothing under it.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init codex "$(_tank)"
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" != *"▸ Live"* ]] || { echo "$output"; false; }
}

@test "live: a session whose tank no longer exists is not drawn" {
  # A row you cannot open is worse than no row. The tank is resolved against the
  # disk, so a leftover session simply drops off.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  tmux new-session -d -s "$(_sess)" 'sleep 30'      # never init-ed: the session exists, the tank does not
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" != *"▸ Live"* ]] || { echo "$output"; false; }
}

@test "live: a resumed session (name carries an argv digest) is drawn too" {
  # Since a session is keyed on what was asked for, a resumed conversation is
  # `ck-<engine>-<tank>-<digits>`. It is just as alive as the bare one, and the
  # digest must not hide it.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init codex "$(_tank)"
  tmux new-session -d -s "$(_sess)-4242" 'sleep 30'
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"▸ Live"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$(_tank)"* ]] || { echo "$output"; false; }
}

@test "live: somebody else's tmux session is none of clikae's business" {
  # ADVERSARIAL ON PURPOSE. The obvious fixture — a session called `notclikae-1` —
  # is rejected by the tank-exists check whether or not the `ck-` gate is there,
  # so it proves nothing: both guards could be deleted and it stayed green.
  #
  # This name is one character away from being ours. Strip the `ck-` gate and
  # `codex-<tank>` parses straight into a tank that really exists, so the row
  # would be drawn — which is the failure this test is supposed to catch.
  #
  # There are TWO `ck-` gates (the grep in live_session_names and the case in
  # live_split) and they are redundant on purpose: widening either one alone
  # leaves this green, and widening both turns exactly this test red. Recorded
  # because "no test fails when I delete it" is the usual reason a redundant
  # guard gets deleted, and here it means the other one caught it.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init codex "$(_tank)"
  local theirs; theirs="codex-$(_tank)"
  tmux new-session -d -s "$theirs" 'sleep 30'
  run clikae
  tmux kill-session -t "$theirs" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" != *"▸ Live"* ]] || { echo "$output"; false; }
}

@test "live: with no tmux at all the section is absent and nothing errors" {
  # A PATH without tmux, not a stub that exits non-zero: `command -v` still FINDS
  # a stub, so a stub would test the wrong branch. (Learned the hard way when a
  # tmux stubbed as `exit 127` made a correct guard look broken.)
  clikae init codex "$(_tank)"
  # Link EVERYTHING on the current PATH except tmux, rather than listing the
  # binaries the board happens to need today. A hand-written list is a second
  # thing to keep in sync, and when it falls behind the test fails for the wrong
  # reason — which is exactly what it did on the first attempt.
  local farm="$BATS_TEST_TMPDIR/nopath" d f
  mkdir -p "$farm"
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -x "$f" ] || continue
      case "${f##*/}" in tmux) continue ;; esac
      [ -e "$farm/${f##*/}" ] || ln -s "$f" "$farm/${f##*/}" 2>/dev/null || true
    done
  done <<PATHDIRS
$(printf '%s\n' "$PATH" | tr ':' '\n')
PATHDIRS
  [ ! -x "$farm/tmux" ]                      # the whole point of the farm
  run env PATH="$farm" "$CLIKAE_BIN"
  [ "$status" -eq 0 ]
  [[ "$output" != *"▸ Live"* ]] || { echo "$output"; false; }
}

@test "live: a waiter's countdown is readable from the session, not only inside it" {
  # The countdown rides in the waiter's window NAME, which is what lets the board
  # show "it will resume itself" without anyone switching windows.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/live.sh"
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  tmux new-window -d -t "$(_sess)" -n 'wake 13h38m' 'sleep 30'
  run live_wake_note "$(_sess)"
  [ "$output" = "13h38m" ]
}

@test "live: a waiter that has not started counting yet reports nothing" {
  # `wake` with no time is a window that exists but has not begun; reporting a
  # countdown for it would be inventing one.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/live.sh"
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  tmux new-window -d -t "$(_sess)" -n wake 'sleep 30'
  run live_wake_note "$(_sess)"
  [ -z "$output" ]
}

@test "live: a row's packed field survives an age that contains a space" {
  # The live row packs attached/age/wake into ONE \037 field. It used to join
  # them with a space — and `age` is a human string with a space in it ("2m
  # ago"), so the consumer's `read attached age wake` assigned wake="ago" on
  # every live row. wake non-empty means "a waiter is counting", so the board
  # announced "resuming in ago" for any selected live session: a countdown that
  # did not exist, which the render site's own comment forbids.
  #
  # live_wake_note was correct and covered by the test above. The wiring around
  # it was not, so a right answer arrived in the wrong variable.
  local row
  row="live"$'\037'"claude"$'\037'"t"$'\037'"title"$'\037'"recap"$'\037'"1"$'\036'"2m ago"$'\036'""$'\037'"clikae-claude-t"
  local kind cli profile label alias active note
  IFS=$'\037' read -r kind cli profile label alias active note <<<"$row"
  local at age wake
  IFS=$'\036' read -r at age wake <<<"$active"
  [ "$at" = "1" ]
  [ "$age" = "2m ago" ] || { echo "age was '$age'"; false; }
  # The one that broke: no waiter counting must read as empty, not as a leftover.
  [ -z "$wake" ] || { echo "wake leaked '$wake' out of the age"; false; }
}

@test "live: two sessions on the SAME tank draw two DISTINGUISHABLE rows, not duplicates" {
  # 2026-09 report: a bare session + a resumed one on the same tank drew two
  # byte-identical "l" rows — same dot, same name, same engine, same title —
  # with nothing on screen to tell them apart or say which is which.
  #
  # Extracted by SECTION, not by grepping the tank name: _tank() bakes in $$ and
  # BATS_TEST_NUMBER for uniqueness, which can run past the board's 7-column
  # name budget and get ellipsis-truncated — a real row would then never
  # contain the untruncated fixture string at all, which is a fact about the
  # fixture, not the fix.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init codex "$(_tank)"
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  tmux new-session -d -s "$(_sess)-4242" 'sleep 30'
  run clikae
  [ "$status" -eq 0 ]
  local block n
  block="$(printf '%s\n' "$output" | awk '/▸ Live/{f=1; next} /▸ /{f=0} f && NF')"
  n="$(printf '%s\n' "$block" | grep -c .)"
  [ "$n" -ge 2 ] || { echo "$output"; false; }
  local first second
  first="$(printf '%s\n' "$block" | sed -n '1p')"
  second="$(printf '%s\n' "$block" | sed -n '2p')"
  [ "$first" != "$second" ] || { echo "duplicate rows, indistinguishable:"; echo "$output"; false; }
  # One of the two must carry a disambiguating badge.
  [[ "$block" == *"#2"* ]] || { echo "$output"; false; }
}

@test "live: two sessions on the SAME tank each show THEIR OWN title, not the tank's newest" {
  # This is the 2026-09-12 report: PineNote's session and KITT's main session,
  # both on tank l, showed the SAME name — whichever transcript had the most
  # recent activity, on BOTH rows. The resolver (_home_live_rows) was keyed by
  # TANK ("the tank's newest transcript"), never by which session a given row
  # actually is.
  #
  # Fixture: two live tmux sessions on one tank, each stamped (as
  # tmux_set_session_id does at launch — lib/core/tmux.sh) with the session id
  # it actually carries. The OLDER transcript belongs to the row that would
  # otherwise win a "who is newest" contest, and the fixture still expects the
  # OTHER row to show it — proving resolution goes by recorded identity, not
  # by mtime. RED on main: main has no @clikae_session_id / live_session_id at
  # all, so both rows fall back to "the tank's newest transcript" and "Alpha
  # work" never appears in the output.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init claude "$(_tank)"
  local dir="$CLIKAE_HOME/profiles/claude/$(_tank)"
  _claude_transcript "$dir" sidA "Alpha work" 202001010000   # older
  _claude_transcript "$dir" sidB "Beta work"  202601010000   # newer — the naive "guess"

  tmux new-session -d -s "$(_csess)" 'sleep 30'
  tmux new-session -d -s "$(_csess)-4242" 'sleep 30'
  tmux set-option -t "=$(_csess):" @clikae_session_id sidA
  tmux set-option -t "=$(_csess)-4242:" @clikae_session_id sidB

  run clikae
  [ "$status" -eq 0 ]
  local block; block="$(_live_block "$output")"
  [[ "$block" == *"Alpha work"* ]] || { echo "sidA's own title never appeared in Live:"; echo "$output"; false; }
  [[ "$block" == *"Beta work"*  ]] || { echo "sidB's own title never appeared in Live:"; echo "$output"; false; }
  # Neither is a guess (both rows carry recorded identity) — no "?" on either.
  [[ "$block" != *"Alpha work?"* ]] || { echo "$output"; false; }
  [[ "$block" != *"Beta work?"*  ]] || { echo "$output"; false; }
}

@test "live: with no recorded identity, an ambiguous tank's guessed title is marked" {
  # Same shape as the report, but neither window was launched in a way that
  # could record its identity (a bare "start fresh" launch, same as most real
  # sessions) — there is genuinely nothing exact to key on. The fix's honesty
  # requirement: say so, with a trailing "?", rather than presenting a 50/50
  # guess as fact on both rows.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init claude "$(_tank)"
  local dir="$CLIKAE_HOME/profiles/claude/$(_tank)"
  _claude_transcript "$dir" sidA "Gamma work" 202001010000
  _claude_transcript "$dir" sidB "Delta work" 202601010000

  tmux new-session -d -s "$(_csess)" 'sleep 30'
  tmux new-session -d -s "$(_csess)-4242" 'sleep 30'
  # Deliberately no @clikae_session_id on either — both fall back to the guess.

  run clikae
  [ "$status" -eq 0 ]
  local block; block="$(_live_block "$output")"
  [[ "$block" == *'?"'* ]] || { echo "no guess marker in Live on an ambiguous tank:"; echo "$output"; false; }
}

@test "live: a single live session's title carries no guess marker" {
  # One-session-per-tank fixture: the fallback lookup is unambiguous here (there
  # is no OTHER live row on this tank it could be confused with), so this must
  # render byte-identical to before the fix — no "?", same title.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init claude "$(_tank)"
  local dir="$CLIKAE_HOME/profiles/claude/$(_tank)"
  _claude_transcript "$dir" solo "Solo work" 202601010000

  tmux new-session -d -s "$(_csess)" 'sleep 30'

  run clikae
  [ "$status" -eq 0 ]
  local block; block="$(_live_block "$output")"
  [[ "$block" == *'"Solo work"'* ]] || { echo "$output"; false; }
  [[ "$block" != *'"Solo work?"'* ]] || { echo "$output"; false; }
}

@test "live: two live sessions on DIFFERENT tanks are each exact, no guess marker" {
  # Different-tank behaviour must stay byte-identical: two live rows on the
  # board is not by itself ambiguous — only two on the SAME tank is.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local ta tb; ta="$(_tank)a"; tb="$(_tank)b"
  clikae init claude "$ta"
  clikae init claude "$tb"
  _claude_transcript "$CLIKAE_HOME/profiles/claude/$ta" sidA "Tank A work" 202601010000
  _claude_transcript "$CLIKAE_HOME/profiles/claude/$tb" sidB "Tank B work" 202601020000

  tmux new-session -d -s "clikae-claude-$ta" 'sleep 30'
  tmux new-session -d -s "clikae-claude-$tb" 'sleep 30'

  run clikae
  tmux kill-session -t "clikae-claude-$ta" 2>/dev/null || true
  tmux kill-session -t "clikae-claude-$tb" 2>/dev/null || true
  [ "$status" -eq 0 ]
  local block; block="$(_live_block "$output")"
  [[ "$block" == *'"Tank A work"'* ]] || { echo "$output"; false; }
  [[ "$block" == *'"Tank B work"'* ]] || { echo "$output"; false; }
  [[ "$block" != *"?"* ]] || { echo "unexpected guess marker across different tanks:"; echo "$output"; false; }
}

@test "live: a stamped row's sid is excluded from an unstamped row's guess on the same tank" {
  # 2026-09-12 round-1 review, R1-P1-1: this is issue #55's ACTUAL headline
  # shape — one resumed (stamped) session and one bare (unstamped) session on
  # the same tank — and it was NOT covered by the two tests above, which both
  # stamp (or both leave bare) BOTH rows. The naive fallback ("just take the
  # tank's newest transcript") does not look at what a neighbouring row has
  # already claimed, so before this fix the unstamped row picked the SAME
  # transcript the stamped row already owns, and the two rows differed only by
  # a trailing "?" — not by which conversation they actually named.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init claude "$(_tank)"
  local dir="$CLIKAE_HOME/profiles/claude/$(_tank)"
  _claude_transcript "$dir" sidB "Bare work"    202001010000   # older — the UNSTAMPED row's real transcript
  _claude_transcript "$dir" sidA "Resumed work" 202601010000   # newer — stamped, and what a naive mtime guess would pick for BOTH rows

  tmux new-session -d -s "$(_csess)" 'sleep 30'
  tmux new-session -d -s "$(_csess)-4242" 'sleep 30'
  tmux set-option -t "=$(_csess):" @clikae_session_id sidA
  # $(_csess)-4242 is deliberately left unstamped — a bare launch.

  run clikae
  [ "$status" -eq 0 ]
  local block; block="$(_live_block "$output")"
  [[ "$block" == *'"Resumed work"'* ]] || { echo "stamped row lost its exact title:"; echo "$output"; false; }
  [[ "$block" == *'"Bare work'*     ]] || { echo "unstamped row's guess did not skip the claimed sid:"; echo "$output"; false; }
  local first second
  first="$(printf '%s\n' "$block" | sed -n '1p')"
  second="$(printf '%s\n' "$block" | sed -n '2p')"
  [ "$first" != "$second" ] || { echo "rows are identical:"; echo "$output"; false; }
}

@test "live: a stale stamp (post-/clear) downgrades to a marked guess instead of a confident wrong answer" {
  # 2026-09-12 round-1 review, R1-P2-1: a stamp is written once, at spawn, and
  # never revisited. `/clear` (or a fork) makes the engine start writing a NEW
  # transcript under a NEW id — the tmux option and state file still point at
  # the old one. main happened to get this right (it always guessed the
  # newest transcript); the PR under review made it WORSE by presenting the
  # now-stale stamp as an unmarked fact. The fix must be at least as correct
  # as main: prefer the newer transcript, but — unlike main's accidental
  # correctness — say so with "?", because it is a guess now, not the
  # recorded fact it was at spawn.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init claude "$(_tank)"
  local dir="$CLIKAE_HOME/profiles/claude/$(_tank)"
  _claude_transcript "$dir" sidOld "Old before clear" 202001010000
  tmux new-session -d -s "$(_csess)" 'sleep 30'
  tmux set-option -t "=$(_csess):" @clikae_session_id sidOld
  # Stamped on a transcript that is about to stop being the newest one — dated
  # WELL after this test runs, so it reads as "written after the session
  # started" regardless of the machine's real clock.
  _claude_transcript "$dir" sidNew "What I am doing now" 203001010000

  run clikae
  [ "$status" -eq 0 ]
  local block; block="$(_live_block "$output")"
  [[ "$block" == *'"What I am doing now'* ]] || { echo "stale stamp was not detected — still showing the old title:"; echo "$output"; false; }
  [[ "$block" != *'"Old before clear"'*   ]] || { echo "$output"; false; }
}

@test "live: a stamped sid outside this board's PWD project slug still renders a title, not a blank one" {
  # 2026-09-12 round-1 review, R1-P2-2: `clikae resume <sid>` cd's to the
  # session's OWN recorded directory before exec'ing (lib/commands/resume.sh),
  # which is routinely a different directory than wherever the board itself is
  # later run from. The stamped path must search across ALL projects the same
  # way the resume picker does (adapter_find_session + adapter_title_for_file),
  # not derive its path from $PWD — or an out-of-$PWD stamp renders the title
  # column as a literal empty string, the one row on the board with no
  # fallback text at all.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init claude "$(_tank)"
  local dir="$CLIKAE_HOME/profiles/claude/$(_tank)"
  local otherslug="-some-other-project-dir"
  mkdir -p "$dir/projects/$otherslug"
  printf '{"type":"custom-title","customTitle":"%s"}\n' "Work done elsewhere" \
    > "$dir/projects/$otherslug/sidFar.jsonl"
  touch -t 202601010000 "$dir/projects/$otherslug/sidFar.jsonl"

  tmux new-session -d -s "$(_csess)" 'sleep 30'
  tmux set-option -t "=$(_csess):" @clikae_session_id sidFar

  run clikae
  [ "$status" -eq 0 ]
  local block; block="$(_live_block "$output")"
  [[ "$block" == *'"Work done elsewhere"'* ]] || { echo "cross-project stamp rendered blank:"; echo "$output"; false; }
  [[ "$block" != *'""'* ]] || { echo "title rendered as a literal empty string:"; echo "$output"; false; }
}

@test "live: a stamped row keeps its own title when a bare neighbour's transcript is written AFTER both sessions exist" {
  # 2026-09-12 round-2 review, R2-P1-1: the "stamped row's sid is excluded"
  # test above used transcript mtimes dated years before the tmux sessions
  # were created, so the stale-stamp check's "is there a newer transcript in
  # this tank" branch never actually got exercised there — every REAL
  # session's transcript is, by construction, newer than that session's own
  # creation time (it is written after the window exists). On real timing,
  # the naive mtime-vs-creation test flagged the STAMPED row as stale the
  # moment its bare neighbour wrote ANYTHING, because the neighbour's own
  # transcript is necessarily newer than both windows' creation. Timestamps
  # here are relative to NOW (both after this tmux session's real creation,
  # whatever the machine's clock says), reproducing that instead of dodging
  # it — the exact shape issue #55 itself used as its example.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init claude "$(_tank)"
  local dir="$CLIKAE_HOME/profiles/claude/$(_tank)"

  tmux new-session -d -s "$(_csess)" 'sleep 30'
  tmux new-session -d -s "$(_csess)-4242" 'sleep 30'
  tmux set-option -t "=$(_csess):" @clikae_session_id sidA
  # $(_csess)-4242 is deliberately left unstamped — a bare launch.

  local after1 after2
  after1="$(date -v+60S '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '+60 seconds' '+%Y%m%d%H%M.%S')"
  after2="$(date -v+120S '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '+120 seconds' '+%Y%m%d%H%M.%S')"
  _claude_transcript "$dir" sidA "Resumed work" "$after1"
  # sidB is written AFTER sidA and belongs to the BARE window, not to sidA —
  # exactly the neighbour that used to masquerade as "sidA's stamp went stale".
  _claude_transcript "$dir" sidB "Bare work"    "$after2"

  run clikae
  [ "$status" -eq 0 ]
  local block; block="$(_live_block "$output")"
  [[ "$block" == *'"Resumed work"'*  ]] || { echo "stamped row's title was overwritten by a busier neighbour:"; echo "$output"; false; }
  [[ "$block" != *'"Resumed work?"'* ]] || { echo "stamped row was wrongly downgraded to a guess:"; echo "$output"; false; }
  [[ "$block" == *'"Bare work'*      ]] || { echo "unstamped row's own guess did not appear:"; echo "$output"; false; }
  local first second
  first="$(printf '%s\n' "$block" | sed -n '1p')"
  second="$(printf '%s\n' "$block" | sed -n '2p')"
  [ "$first" != "$second" ] || { echo "rows are identical:"; echo "$output"; false; }
}

@test "live: a stamped sid from another project still shows its own title after new transcripts appear under THIS project" {
  # 2026-09-12 round-2 review, R2-P2-1: the "stamped sid outside this board's
  # PWD project slug" test above had no OTHER transcript under $PWD to
  # compete with — so it never actually exercised the failure the naive
  # stale check introduced: the candidate pool for "is this stamp stale" was
  # $PWD-scoped (adapter_recent_sids), not scoped to the stamped session's
  # OWN directory, so a transcript that merely happens to be newer AND
  # merely happens to sit under the board's own $PWD — with nothing to do
  # with the resumed session running elsewhere — used to look exactly like
  # proof that stamp had gone stale.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init claude "$(_tank)"
  local dir="$CLIKAE_HOME/profiles/claude/$(_tank)"
  local otherslug="-some-other-project-dir"
  mkdir -p "$dir/projects/$otherslug"
  printf '{"type":"custom-title","customTitle":"%s"}\n' "Work done elsewhere" \
    > "$dir/projects/$otherslug/sidFar.jsonl"
  touch -t 202601010000 "$dir/projects/$otherslug/sidFar.jsonl"

  tmux new-session -d -s "$(_csess)" 'sleep 30'
  tmux set-option -t "=$(_csess):" @clikae_session_id sidFar

  # A transcript under THIS board's own $PWD project, written well after the
  # tmux session was created — unrelated to sidFar, which lives elsewhere.
  local after; after="$(date -v+60S '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '+60 seconds' '+%Y%m%d%H%M.%S')"
  _claude_transcript "$dir" sidHere "Work right here" "$after"

  run clikae
  [ "$status" -eq 0 ]
  local block; block="$(_live_block "$output")"
  [[ "$block" == *'"Work done elsewhere"'* ]] || { echo "cross-project stamp lost to an unrelated local transcript:"; echo "$output"; false; }
  [[ "$block" != *'"Work right here'*      ]] || { echo "cross-project stamp was overwritten by an unrelated \$PWD transcript:"; echo "$output"; false; }
}

@test "live: the guess marker survives 80-column truncation instead of being cut off" {
  # 2026-09-12 round-1 review, R1-P2-3: the marker used to be appended to the
  # title BEFORE truncation, so a title long enough to get truncated for
  # display (the same length class as docs/usage.md's own Live example, "…
  # retry the callback test?") lost the "?" along with whatever else got cut —
  # an ambiguous tank then looked exactly like an unambiguous one.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init claude "$(_tank)"
  local dir="$CLIKAE_HOME/profiles/claude/$(_tank)"
  local longtitle="auth redirect handling and the callback retry test we are still chasing down"
  _claude_transcript "$dir" sidA "$longtitle a" 202001010000
  _claude_transcript "$dir" sidB "$longtitle b" 202601010000
  tmux new-session -d -s "$(_csess)" 'sleep 30'
  tmux new-session -d -s "$(_csess)-4242" 'sleep 30'
  # Neither stamped — both guess, on an ambiguous tank, with a title long
  # enough to overflow the row's ~55-column title budget at the default
  # 80-column (no tty, no $COLUMNS) fallback.

  run clikae
  [ "$status" -eq 0 ]
  local block; block="$(_live_block "$output")"
  [[ "$block" == *'?"'* ]] || { echo "guess marker did not survive truncation:"; echo "$output"; false; }
}

@test "live: a guessed title that itself ends in \"?\" does not grow a second one" {
  # 2026-09-12 round-2 review, R2-P3-3 (R1-P3-1 unaddressed): the marker was
  # appended unconditionally after truncation, so a title that is itself a
  # literal question ("Why is it slow?") became "Why is it slow??" once
  # flagged as a guess — indistinguishable from a typo, and the two title
  # rows this test sets up (one ending "?", one not) would otherwise both
  # read as ending "??" / "?" with no way to tell which one had the real
  # question mark.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init claude "$(_tank)"
  local dir="$CLIKAE_HOME/profiles/claude/$(_tank)"
  _claude_transcript "$dir" sidA "Why is it slow?" 202001010000
  _claude_transcript "$dir" sidB "Fix the flake"    202601010000
  tmux new-session -d -s "$(_csess)" 'sleep 30'
  tmux new-session -d -s "$(_csess)-4242" 'sleep 30'
  # Neither stamped — both guess, on an ambiguous tank.

  run clikae
  [ "$status" -eq 0 ]
  local block; block="$(_live_block "$output")"
  [[ "$block" != *'slow??'* ]] || { echo "guess marker doubled up on a title that already ended in ?:"; echo "$output"; false; }
  [[ "$block" == *'"Why is it slow?"'* ]] || { echo "title with its own literal ? lost its marker distinction:"; echo "$output"; false; }
}
