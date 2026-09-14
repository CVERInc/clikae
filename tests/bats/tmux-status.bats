#!/usr/bin/env bats
# tests/bats/tmux-status.bats — the tmux status row (#77).
#
# The row it replaced was never tested because nothing was setting most of it:
# tmux derived the window list, the title and the date, and clikae contributed
# eight characters of label. This file pins the parts that are now decisions.
#
# Almost everything here renders the row WITHOUT a tmux server, because
# tmux_status_render is a pure function of its arguments plus $HOME/$CLIKAE_HOME
# — that is the whole reason it is a separate function from tmux_status_line.
# The two tests that do need a real tmux use their own socket from `mktemp -d`
# and never `kill-server` on a shared one.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/dry_store.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/burn_status.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
}

# _usage_cache <engine> <tank> <window_pct> <weekly_pct> [age_seconds]
# #72's cache file, written by hand in the shape PR #89 writes it.
_usage_cache() {
  local engine="$1" tank="$2" w="$3" k="$4" age="${5:-0}" now
  now=$(( $(date +%s) - age ))
  mkdir -p "$CLIKAE_HOME/state/usage/$engine"
  printf '{"window_pct":%s,"weekly_pct":%s,"window_resets_at":null,"weekly_resets_at":null,"source":"vendor","cached_at":%s,"scanned_at":%s}\n' \
    "$w" "$k" "$now" "$now" > "$CLIKAE_HOME/state/usage/$engine/$tank.json"
}

# _dry_marker <engine> <tank> [age_seconds] — what the live catchers write.
_dry_marker() {
  local engine="$1" tank="$2" age="${3:-0}"
  mkdir -p "$CLIKAE_HOME/dry/$engine"
  printf '%s\tresets 3pm\n' "$(( $(date +%s) - age ))" > "$CLIKAE_HOME/dry/$engine/$tank"
}

# _burn_status <run> <state> <pid> — #41's status.json for one run directory.
_burn_status() {
  local run="$1" state="$2" pid="$3"
  mkdir -p "$HOME/.clikae/logs/$run"
  printf '{"ok":null,"engine":"claude","tank":"wrasse","artifact":"/x","artifact_bytes":null,"reason":"","reset":null,"rerouted_from":[],"elapsed_s":3,"run_id":"%s","state":"%s","started_at":1,"updated_at":2,"pid":%s,"log":"/x","reset_at":null}\n' \
    "$run" "$state" "$pid" > "$HOME/.clikae/logs/$run/status.json"
}

# _manifest — every path under clikae's own state, with size and mtime.
#
# 🔴 SCOPED TO CLIKAE'S STATE, and the scope was measured rather than chosen.
# The first version walked the whole throwaway $HOME and went red on a real
# side effect worth knowing about: asking tmux anything (live_session_id's
# `show-options`) makes tmux CREATE its own socket directory under
# $TMUX_TMPDIR. That is tmux's housekeeping, in a directory that already exists
# in the only place this helper ever really runs (as a child of a live tmux
# server), and it is not clikae state. The claim this test defends is the one
# that matters: the row never changes anything clikae wrote.
# GNU/BSD stat both, the same two-arm form the rest of this repo uses; no
# `find -printf`, which is GNU-only and would make this whole test a no-op on
# macOS while still printing green.
_manifest() {
  local f
  find "$CLIKAE_HOME" "$HOME/.clikae" -print 2>/dev/null | sort -u | while IFS= read -r f; do
    printf '%s %s\n' "$f" \
      "$(stat -c '%Y %s' "$f" 2>/dev/null || stat -f '%m %z' "$f" 2>/dev/null)"
  done
}

# A pid that is structurally incapable of existing: above every platform's
# pid_max. Reusing a real-but-exited pid would be a test that passes until the
# machine wraps its pid space onto it.
_dead_pid() { printf '2147483647'; }

# ── the fuel segment ────────────────────────────────────────────────────────

@test "fuel: the usage cache is what the row shows, as 5h/7d percentages" {
  _src
  _usage_cache claude wrasse 42.0 65.0
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"5h 42%"* ]] || { echo "$output"; false; }
  [[ "$output" == *"7d 65%"* ]] || { echo "$output"; false; }
  # `wk` was the first wording and chodaict corrected it: both windows are
  # written as time spans, so the weekly one is `7d`.
  [[ "$output" != *"wk "* ]] || { echo "$output"; false; }
}

@test "fuel: no usage cache falls back to the dot, and never invents a number" {
  # #72 has not landed yet for most tanks, and a row that made up a percentage
  # would be worse than one that admits it has no reading.
  _src
  run tmux_status_render codex goby '' '' 120
  [[ "$output" == *"·"* ]] || { echo "$output"; false; }
  [[ "$output" != *"5h "* ]] || { echo "$output"; false; }
  [[ "$output" != *"%"* ]] || { echo "$output"; false; }
}

@test "fuel: a fresh dry marker shows the board's dry glyph, not the no-reading one" {
  _src
  _dry_marker codex goby
  run tmux_status_render codex goby '' '' 120
  [[ "$output" == *"○"* ]] || { echo "$output"; false; }
}

@test "fuel: a dry marker older than its own TTL is not shown as dry" {
  # dry_store's TTL is the one place this rule lives; the row must not carry a
  # second copy of it. 7h against a 6h TTL.
  _src
  _dry_marker codex goby 25200
  run tmux_status_render codex goby '' '' 120
  [[ "$output" != *"○"* ]] || { echo "$output"; false; }
  [[ "$output" == *"·"* ]] || { echo "$output"; false; }
}

@test "fuel: a reading older than 24h is treated as unread, not shown as current" {
  # The failure this prevents: a percentage from last Tuesday, drawn every five
  # seconds as if it were now.
  _src
  _usage_cache claude wrasse 42.0 65.0 90000
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"42%"* ]] || { echo "$output"; false; }
  [[ "$output" == *"·"* ]] || { echo "$output"; false; }
}

@test "fuel: a cache with null percentages is no reading, not 0%" {
  _src
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  printf '{"window_pct":null,"weekly_pct":null,"source":"unknown"}\n' \
    > "$CLIKAE_HOME/state/usage/claude/wrasse.json"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"0%"* ]] || { echo "$output"; false; }
  [[ "$output" == *"·"* ]] || { echo "$output"; false; }
}

# ── the alert segment ───────────────────────────────────────────────────────

@test "alerts: zero reds means the segment is not drawn at all" {
  # The opposite of the opening proposal's `🔴0`: chodaict's correction is that
  # silence does not need spelling out, and the emoji fails signet-lint anyway.
  _src
  run tmux_status_render claude wrasse '' '' 120
  [ "$status" -eq 0 ]
  [[ "$output" != *"!"* ]] || { echo "$output"; false; }
  [[ "$output" != *"!0"* ]] || { echo "$output"; false; }
}

@test "alerts: a tank the catchers marked dry counts as one" {
  _src
  _dry_marker codex goby
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "$output"; false; }
}

@test "alerts: a burn lane whose writer is gone counts; one still running does not" {
  _src
  _burn_status burn-1 running "$(_dead_pid)"
  _burn_status burn-2 running "$$"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "$output"; false; }
}

@test "alerts: a lane that reached a terminal state is not red" {
  # `fail` printed its reason to whoever ran it. The row is for what nobody has
  # been told — a lane that died mid-flight, not one that reported.
  _src
  _burn_status burn-1 fail "$(_dead_pid)"
  _burn_status burn-2 done "$(_dead_pid)"
  _burn_status burn-3 dry  "$(_dead_pid)"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"!"* ]] || { echo "$output"; false; }
}

@test "alerts: a waiting-reset lane whose writer is gone counts too" {
  _src
  _burn_status burn-1 waiting-reset "$(_dead_pid)"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!1"* ]] || { echo "$output"; false; }
}

@test "alerts: they add up across both sources" {
  _src
  _dry_marker codex goby
  _dry_marker claude hi
  _burn_status burn-1 running "$(_dead_pid)"
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" == *"!3"* ]] || { echo "$output"; false; }
}

# ── the reconnect command ───────────────────────────────────────────────────

@test "reconnect: a known session id becomes an 8-character resume command" {
  _src
  run tmux_status_render claude wrasse 'a52bdc12-1111-2222-3333-444455556666' '' 120
  [[ "$output" == *"clikae resume a52bdc12"* ]] || { echo "$output"; false; }
  # …and the other 28 characters do not get to own the row.
  [[ "$output" != *"a52bdc12-1111"* ]] || { echo "$output"; false; }
}

@test "reconnect: no session id gives the command that reattaches the tank" {
  # codex and antigravity bare launches record no sid (tmux_set_session_id).
  # A bare `clikae resume` would open a picker rather than come back HERE.
  _src
  run tmux_status_render codex goby '' '' 120
  [[ "$output" == *"clikae codex goby"* ]] || { echo "$output"; false; }
  [[ "$output" != *"clikae resume "* ]] || { echo "$output"; false; }
}

@test "reconnect: a session id that is not one is ignored rather than printed" {
  # It arrives from a tmux user option, which a human can set by hand.
  _src
  run tmux_status_render codex goby 'not a; session id' '' 120
  [[ "$output" == *"clikae codex goby"* ]] || { echo "$output"; false; }
  [[ "$output" != *"not a"* ]] || { echo "$output"; false; }
}

# ── the width rule ──────────────────────────────────────────────────────────

@test "width: at 120 columns the whole row is there, ssh prefix included" {
  _src
  _usage_cache claude wrasse 42.0 65.0
  run tmux_status_render claude wrasse 'a52bdc12-1111-2222-3333-444455556666' reefbox 120
  [[ "$output" == *"ssh reefbox -t clikae resume a52bdc12"* ]] || { echo "$output"; false; }
  [[ "$output" == *"5h 42%"* ]] || { echo "$output"; false; }
}

@test "width: 100 columns is the floor, not the first casualty" {
  _src
  run tmux_status_render claude wrasse 'a52bdc12-1111-2222-3333-444455556666' reefbox 100
  [[ "$output" == *"ssh reefbox -t clikae resume a52bdc12"* ]] || { echo "$output"; false; }
}

@test "width: below 100 the ssh prefix is dropped, and nothing else is" {
  # It is dropped rather than cut: half a hostname is not a command. What is
  # left is exactly right on the host where the row is being read.
  _src
  _usage_cache claude wrasse 42.0 65.0
  _dry_marker codex goby
  run tmux_status_render claude wrasse 'a52bdc12-1111-2222-3333-444455556666' reefbox 80
  [[ "$output" != *"ssh "* ]] || { echo "$output"; false; }
  [[ "$output" == *"clikae resume a52bdc12"* ]] || { echo "$output"; false; }
  [[ "$output" == *"5h 42%"* ]] || { echo "$output"; false; }
  [[ "$output" == *"!1"* ]] || { echo "$output"; false; }
}

@test "width: the whole row fits 120 columns, and still fits 80" {
  # The acceptance criterion, measured on the row rather than argued about:
  # tmux styles are not columns, so they come out before counting.
  _src
  _usage_cache claude wrasse 100.0 100.0
  _dry_marker codex goby
  _burn_status burn-1 running "$(_dead_pid)"
  local plain w
  for w in 120 100 80; do
    run tmux_status_render claude wrasse 'a52bdc12-1111-2222-3333-444455556666' \
      a-rather-long-hostname "$w"
    plain="$(printf '%s' "$output" | sed 's/#\[[^]]*\]//g')"
    # 6 columns reserved for the clock at the right edge.
    [ "${#plain}" -le "$(( w - 6 ))" ] || {
      echo "at $w columns the row is ${#plain} wide: $plain"; false; }
  done
}

@test "width: a width tmux could not tell us is not a crash" {
  _src
  run tmux_status_render claude wrasse '' reefbox ''
  [ "$status" -eq 0 ]
  [[ "$output" == *"clikae claude wrasse"* ]] || { echo "$output"; false; }
}

# ── what the row deliberately does NOT say ──────────────────────────────────

@test "row: there is no fleet segment" {
  # The proposal's `reefbox x● hi● l○` was withdrawn in the issue's own thread:
  # per-tank fleet fuel lives on the board, which is where it can be read.
  # This test exists so re-adding it is a decision somebody makes on purpose.
  _src
  clikae init claude other >/dev/null 2>&1 || true
  _usage_cache claude wrasse 42.0 65.0
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"/3"* ]] || { echo "$output"; false; }
  [[ "$output" != *"●"* ]] || { echo "$output"; false; }
  [[ "$output" != *"other"* ]] || { echo "$output"; false; }
}

@test "row: no emoji reaches the screen" {
  # scripts/signet-lint.sh fails any printed emoji (the ❯ cursor excepted), and
  # this string is printed. Asserted on the RENDERED row, not on the source, so
  # a glyph that arrives from state rather than from a literal is caught too.
  command -v perl >/dev/null 2>&1 || skip "perl not installed"
  _src
  _dry_marker codex goby
  _burn_status burn-1 running "$(_dead_pid)"
  _usage_cache claude wrasse 42.0 65.0
  run tmux_status_render claude wrasse 'a52bdc12-1111-2222-3333-444455556666' reefbox 120
  run bash -c "printf '%s' \"\$1\" | perl -CSD -ne 'exit(/[\x{2600}-\x{27BF}\x{1F300}-\x{1FAFF}\x{2B00}-\x{2BFF}\x{FE0F}]/ ? 1 : 0)'" _ "$output"
  [ "$status" -eq 0 ] || { echo "an emoji reached the row: $output"; false; }
}

@test "row: no date, and the clock is not in the left segment" {
  _src
  run tmux_status_render claude wrasse '' '' 120
  [[ "$output" != *"%H"* ]] || { echo "$output"; false; }
  [[ "$output" != *"-26"* ]] || { echo "$output"; false; }
}

# ── the helper, as tmux actually runs it ────────────────────────────────────

@test "helper: it never calls the network, and never calls clikae" {
  # A status line that could make a network call would make one every five
  # seconds, per client, forever — from inside tmux's server, where nobody
  # would see it fail. Loud stubs, and a tripwire file that must not appear.
  local bin="$TEST_HOME/.testbin"
  local trip="$TEST_HOME/tripwire"
  local t
  for t in curl wget jq clikae ssh nc; do
    cat > "$bin/$t" <<INNER
#!/usr/bin/env bash
printf '%s\n' "$t" >> "$trip"
echo "$t must never be called from the status line" >&2
exit 99
INNER
    chmod +x "$bin/$t"
  done
  _usage_cache claude wrasse 42.0 65.0
  run bash "$CLIKAE_TEST_ROOT/lib/core/status_line.sh" \
    "$HOME" "$CLIKAE_HOME" claude wrasse clikae-claude-wrasse '' 120
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"5h 42%"* ]] || { echo "$output"; false; }
  [ ! -f "$trip" ] || { echo "the helper called: $(cat "$trip")"; false; }
}

@test "helper: it reads the session id from the mirror when tmux cannot answer" {
  mkdir -p "$HOME/.clikae/state"
  printf 'a52bdc12-1111-2222-3333-444455556666\n' \
    > "$HOME/.clikae/state/clikae-claude-wrasse.session_id"
  run bash "$CLIKAE_TEST_ROOT/lib/core/status_line.sh" \
    "$HOME" "$CLIKAE_HOME" claude wrasse clikae-claude-wrasse '' 120
  [[ "$output" == *"clikae resume a52bdc12"* ]] || { echo "$output"; false; }
}

@test "helper: it writes nothing, anywhere" {
  # 🔴 A measurement that deletes state is not a measurement. dry_store_read's
  # lazy collection of a stale marker is correct for a caller asking once, and
  # would make "when did this marker disappear" a function of whether anyone
  # was looking at a status bar. Every state shape the row reads is here,
  # including the stale ones it is entitled to be tempted by.
  _usage_cache claude wrasse 42.0 65.0 90000
  _dry_marker codex goby 25200
  _dry_marker claude hi
  _burn_status burn-1 running "$(_dead_pid)"
  mkdir -p "$HOME/.clikae/state"
  printf 'a52bdc12-1111-2222-3333-444455556666\n' \
    > "$HOME/.clikae/state/clikae-claude-wrasse.session_id"

  local before after
  before="$(_manifest)"
  run bash "$CLIKAE_TEST_ROOT/lib/core/status_line.sh" \
    "$HOME" "$CLIKAE_HOME" claude wrasse clikae-claude-wrasse '' 120
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  after="$(_manifest)"
  [ -n "$before" ] || { echo "the manifest itself is empty — this test proves nothing"; false; }
  [ "$before" = "$after" ] || {
    echo "the status line changed state:"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true
    false; }
}

@test "helper: it costs far less than a redraw budget" {
  # Not a benchmark — a tripwire. The real measured cost is ~14 ms per call on
  # the development host (docs/DESIGN-tmux.md Rule 10); the threshold here is
  # an order of magnitude above that, so it catches "somebody added a call that
  # blocks" and never catches "CI was busy".
  _usage_cache claude wrasse 42.0 65.0
  local t0 t1 i
  t0="$(date +%s)"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    bash "$CLIKAE_TEST_ROOT/lib/core/status_line.sh" \
      "$HOME" "$CLIKAE_HOME" claude wrasse clikae-claude-wrasse '' 120 >/dev/null
  done
  t1="$(date +%s)"
  [ "$(( t1 - t0 ))" -le 3 ] || {
    echo "10 renders took $(( t1 - t0 ))s — something in the row is blocking"; false; }
}

# ── against a real tmux server (its own socket, never a shared one) ─────────

_sock() { printf '%s/s' "$CK_SOCKDIR"; }
_t() { env -u TMUX tmux -S "$(_sock)" "$@"; }

@test "tmux: the options land on this session, and the window list is gone" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  CK_SOCKDIR="$(mktemp -d)"
  local sess="ckst-$$-${BATS_TEST_NUMBER:-0}"
  _t new-session -d -s "$sess" 'sleep 30'
  _t new-window -d -t "=$sess:" -n wake 'sleep 30'

  # tmux_status_line talks to whatever `tmux` resolves to, so point the real
  # binary at this socket for the duration of the call.
  #
  # 🔴 `command` FIRST, not `env -u TMUX command tmux`: `command` is a shell
  # builtin and `env` cannot exec one ("env: 'command': No such file or
  # directory", rc=127). Written the other way round this override failed on
  # every call, tmux_status_line's own `|| true` swallowed all seven failures,
  # and the assertion below read as "the product does not set status-left".
  tmux() { command env -u TMUX tmux -S "$(_sock)" "$@"; }
  tmux_status_line "$sess" claude wrasse
  unset -f tmux

  run _t show-options -v -t "=$sess:" status-left
  [[ "$output" == *"status_line.sh"* ]] || { echo "$output"; false; }
  [[ "$output" == *"client_width"* ]] || { echo "$output"; false; }

  run _t show-options -v -t "=$sess:" status-right
  [ "$output" = '%H:%M ' ] || { echo "got '$output'"; false; }

  run _t show-options -v -t "=$sess:" status-interval
  [ "$output" = "5" ] || { echo "got '$output'"; false; }

  # The window list is gone because status-format[0] replaces the whole row —
  # not because window-status-format was blanked, which would have reached
  # every session on the server (or only this session's current window).
  run _t show-options -v -t "=$sess:" 'status-format[0]'
  [[ "$output" == *"status-left"* ]] || { echo "$output"; false; }
  [[ "$output" == *"status-right"* ]] || { echo "$output"; false; }
  [[ "$output" != *"window-status"* ]] || { echo "$output"; false; }
  [[ "$output" != *"window_flags"* ]] || { echo "$output"; false; }

  _t kill-session -t "=$sess" 2>/dev/null || true
  _t kill-server 2>/dev/null || true
  rm -rf "$CK_SOCKDIR"
}

@test "tmux: a neighbouring session keeps its own row" {
  # Same exact-target rule the rest of this layer lives under: `-t "=name:"`.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  CK_SOCKDIR="$(mktemp -d)"
  local sess="ckst-$$-${BATS_TEST_NUMBER:-0}"
  _t new-session -d -s "$sess" 'sleep 30'
  _t new-session -d -s "${sess}-neighbour" 'sleep 30'
  _t set-option -t "=${sess}-neighbour:" status-left '[UNTOUCHED] '

  tmux() { command env -u TMUX tmux -S "$(_sock)" "$@"; }
  tmux_status_line "$sess" claude wrasse
  unset -f tmux

  run _t show-options -v -t "=${sess}-neighbour:" status-left
  [ "$output" = '[UNTOUCHED] ' ] || { echo "got '$output'"; false; }

  _t kill-server 2>/dev/null || true
  rm -rf "$CK_SOCKDIR"
}

@test "tmux: a session that is gone does not fail the caller" {
  # Cosmetics never fail a launch — this runs right after the engine starts.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  CK_SOCKDIR="$(mktemp -d)"
  tmux() { command env -u TMUX tmux -S "$(_sock)" "$@"; }
  run tmux_status_line "ckst-nope-$$" claude wrasse
  unset -f tmux
  [ "$status" -eq 0 ]
  rm -rf "$CK_SOCKDIR"
}

# ── the other half: `clikae resume <prefix>` ────────────────────────────────

_two_sessions_sharing_a_prefix() {
  # 🔴 A STUB, because the real `claude` is on the developer's PATH and this
  # test ends in an exec. Without it the assertions would be about whatever a
  # real engine did with a fabricated transcript, and the suite would launch a
  # vendor CLI on every run.
  cat > "$TEST_HOME/.testbin/claude" <<'INNER'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${HOME:?}/claude-argv.log"
INNER
  chmod +x "$TEST_HOME/.testbin/claude"
  clikae init claude alpha >/dev/null 2>&1
  clikae init claude beta  >/dev/null 2>&1
  mkdir -p "$CLIKAE_HOME/profiles/claude/alpha/projects/-tmp-p" \
           "$CLIKAE_HOME/profiles/claude/beta/projects/-tmp-p"
  printf '{"cwd":"/tmp"}\n' \
    > "$CLIKAE_HOME/profiles/claude/alpha/projects/-tmp-p/a52bdc12-1111-2222-3333-444455556666.jsonl"
  printf '{"cwd":"/tmp"}\n' \
    > "$CLIKAE_HOME/profiles/claude/alpha/projects/-tmp-p/a52bdc12-9999-8888-7777-666655554444.jsonl"
  printf '{"cwd":"/tmp"}\n' \
    > "$CLIKAE_HOME/profiles/claude/beta/projects/-tmp-p/b0000000-1111-2222-3333-444455556666.jsonl"
}

@test "resume: a unique 8-character prefix resolves to the whole id" {
  # This is what makes the status row's left segment honest: it shows eight
  # characters because those eight characters are a command that works.
  _two_sessions_sharing_a_prefix
  run env CLIKAE_NO_INTERACTIVE=1 "$CLIKAE_BIN" resume b0000000
  [[ "$output" == *"claude/beta"* ]] || { echo "$output"; false; }
  # 🔴 The claim is not "it said something about beta" — it is that the ENGINE
  # was handed the WHOLE id. A resolver that passed the prefix through would
  # print exactly the same line and then fail in the vendor.
  [ -f "$TEST_HOME/claude-argv.log" ] || { echo "the engine never ran: $output"; false; }
  grep -qx 'b0000000-1111-2222-3333-444455556666' "$TEST_HOME/claude-argv.log" || {
    echo "engine argv was:"; cat "$TEST_HOME/claude-argv.log"; false; }
}

@test "resume: an ambiguous prefix is refused, with the candidates" {
  # Picking the newest would be the same shape as resuming a conversation the
  # operator did not name.
  _two_sessions_sharing_a_prefix
  run "$CLIKAE_BIN" resume a52bdc12
  [ "$status" -ne 0 ] || { echo "an ambiguous prefix was accepted: $output"; false; }
  [[ "$output" == *"matches 2 sessions"* ]] || { echo "$output"; false; }
  [[ "$output" == *"a52bdc12-1111-2222-3333-444455556666"* ]] || { echo "$output"; false; }
  [[ "$output" == *"a52bdc12-9999-8888-7777-666655554444"* ]] || { echo "$output"; false; }
}

@test "resume: the same id in two tanks is ONE candidate, not an ambiguity" {
  # A relay copies a session into a second tank. That is one conversation, and
  # _resume_locate already knows how to choose between the copies.
  _two_sessions_sharing_a_prefix
  cp "$CLIKAE_HOME/profiles/claude/alpha/projects/-tmp-p/a52bdc12-1111-2222-3333-444455556666.jsonl" \
     "$CLIKAE_HOME/profiles/claude/beta/projects/-tmp-p/"
  rm "$CLIKAE_HOME/profiles/claude/alpha/projects/-tmp-p/a52bdc12-9999-8888-7777-666655554444.jsonl"
  run env CLIKAE_NO_INTERACTIVE=1 "$CLIKAE_BIN" resume a52bdc12
  [[ "$output" != *"matches"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Resuming"* ]] || { echo "$output"; false; }
}

@test "resume: a full id is never re-read as a prefix" {
  _two_sessions_sharing_a_prefix
  run env CLIKAE_NO_INTERACTIVE=1 "$CLIKAE_BIN" resume a52bdc12-1111-2222-3333-444455556666
  [[ "$output" != *"matches"* ]] || { echo "$output"; false; }
  [[ "$output" == *"claude/alpha"* ]] || { echo "$output"; false; }
}

@test "resume: a prefix that matches nothing still says so plainly" {
  _two_sessions_sharing_a_prefix
  run "$CLIKAE_BIN" resume zzzzzzzz
  [ "$status" -ne 0 ]
  [[ "$output" == *"No session 'zzzzzzzz'"* ]] || { echo "$output"; false; }
}
