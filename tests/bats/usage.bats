#!/usr/bin/env bats
load '../helpers'
bats_require_minimum_version 1.5.0   # for `run --separate-stderr`

usage_fixture() {
  clikae init claude work
  printf '%s\n' '{"claudeAiOauth":{"accessToken":"stub-secret-usage72"}}' > "$CLIKAE_HOME/profiles/claude/work/.credentials.json"
  export USAGE_CALLS="$TEST_HOME/calls" USAGE_LOG="$TEST_HOME/curl.log"
  cat > "$TEST_HOME/.testbin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'call\n' >> "$USAGE_CALLS"
printf '%s\n' "$@" >> "$USAGE_LOG"
env >> "$USAGE_LOG"
config="$(cat)"
[[ "$config" == *'Authorization: Bearer stub-secret-usage72'* ]] || exit 2
[[ "$config" == *'anthropic-beta: oauth-2025-04-20'* ]] || exit 2
[ "${USAGE_FAIL:-0}" = 0 ] || { echo '{"error":"unauthorized"}'; exit 22; }
# P2-3 (round-1 review): the vendor's real shape is microseconds + a numeric
# UTC offset, never a bare "…Z" — the old fixture used "2099-01-01T00:00:00Z"
# and so never exercised the format the vendor actually sends.
echo '{"five_hour":{"utilization":65,"resets_at":"2099-01-01T00:00:00.189940+00:00"},"seven_day":{"utilization":92,"resets_at":"2099-01-07T00:00:00.189960+00:00"}}'
STUB
  chmod +x "$TEST_HOME/.testbin/curl"
}

# P2-1(b) (round-2 review): _burn_next_same_engine now fetches each candidate
# LIVE (usage_read … 1) before ranking, so a fixture that only wrote the cache
# file directly would have its numbers overwritten by that fetch right before
# the assertion runs. multi_curl_stub + live_usage give each tank its own
# credentials/token and register that token's percentage with a single shared
# curl stub keyed by the request's Bearer token — the refresh then fetches
# exactly the number the test intended, the same way a real vendor would.
# Same value for window_pct/weekly_pct, matching every fixture in this file
# below (none of them ever needed the two to differ).
multi_curl_stub() {
  # $TEST_HOME itself is a plain (unexported) bats variable — invisible to an
  # EXEC'd external process like this stub script. Export the map path
  # explicitly (same pattern usage_fixture uses for $USAGE_CALLS/$USAGE_LOG
  # above) rather than relying on $TEST_HOME reaching the child.
  export CLIKAE_TEST_PCTMAP="$TEST_HOME/pctmap"
  cat > "$TEST_HOME/.testbin/curl" <<'STUB'
#!/usr/bin/env bash
config="$(cat)"
tok="$(printf '%s' "$config" | sed -n 's/.*Bearer \([^"]*\)".*/\1/p')"
line="$(awk -v t="$tok" '$1==t{print; exit}' "$CLIKAE_TEST_PCTMAP" 2>/dev/null)"
if [ -z "$line" ]; then echo '{"error":"unauthorized"}'; exit 22; fi
read -r _ window weekly <<< "$line"
printf '{"five_hour":{"utilization":%s,"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":%s,"resets_at":"2099-01-07T00:00:00.000000+00:00"}}\n' "$window" "$weekly"
STUB
  chmod +x "$TEST_HOME/.testbin/curl"
}
# live_usage <tank> <window_pct> [weekly_pct] — weekly defaults to window
# (every earlier fixture in this file only ever needed the two equal); pass
# both explicitly to test intra-tier ordering, where the two must differ.
live_usage() {
  local tank="$1" window="$2" weekly="${3:-$2}"
  clikae init claude "$tank" >/dev/null 2>&1 || true
  printf '{"claudeAiOauth":{"accessToken":"tok-%s"}}\n' "$tank" > "$CLIKAE_HOME/profiles/claude/$tank/.credentials.json"
  printf 'tok-%s %s %s\n' "$tank" "$window" "$weekly" >> "$CLIKAE_TEST_PCTMAP"
}

@test "usage JSON, board percentages, TTL and fresh; secret stays off output argv environment and logs" {
  usage_fixture
  run clikae usage claude work --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_HOME/output.log"
  echo "$output" | jq -e '.engine == "claude" and .tank == "work" and .window_pct == 65 and .weekly_pct == 92 and .source == "vendor"'
  run clikae usage claude work --json
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 1 ]
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *'window 65% · weekly 92%'* ]]
  printf '%s\n' "$output" >> "$TEST_HOME/output.log"
  run clikae usage --fresh --json
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 2 ]
  ! grep -R 'stub-secret-usage72' "$USAGE_LOG" "$TEST_HOME/output.log" "$CLIKAE_HOME/state"
}

@test "401 becomes cached unknown and board survives" {
  usage_fixture
  export USAGE_FAIL=1
  run clikae usage claude work --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "unknown" and .window_pct == null'
  [[ "$output" != *'stub-secret-usage72'* ]]
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" != *'stub-secret-usage72'* ]]
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 1 ]
}

@test "expired TTL refreshes and malformed TTL uses default" {
  usage_fixture
  clikae usage --json
  CLIKAE_USAGE_TTL=bad clikae usage --json
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 1 ]
  CLIKAE_USAGE_TTL=0 clikae usage --json
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 2 ]
}

@test "reserve ranks vendor headroom and skips solo tanks" {
  usage_fixture
  clikae init claude reserve
  clikae init claude private
  mkdir -p "$CLIKAE_HOME/profiles/claude/private/clikae-meta"
  touch "$CLIKAE_HOME/profiles/claude/private/clikae-meta/solo"
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/burn.sh"
  clikae init claude reserve2
  multi_curl_stub
  live_usage work 95
  # P3-8-shaped gap (round-2 review): the original fixture had exactly ONE
  # tier-0 candidate (reserve), so this test could not tell "picked the
  # right tank" from "picked the ONLY tank" — deleting the ranking pass
  # entirely would have stayed green. reserve and reserve2 are BOTH tier-0
  # (well under 90%) with opposite window/weekly shapes, so which one wins
  # only comes from the intra-tier sort actually running.
  live_usage reserve 15 80; live_usage reserve2 5 85
  # private is solo — tank_is_solo short-circuits it before P2-1(b)'s refresh
  # ever fetches it, so it needs no credentials/pctmap entry at all.
  run _burn_next_same_engine claude '' '' '' 1
  [ "$status" -eq 0 ]
  [ "$output" = reserve2 ]
}

@test "P2-3: intra-tier ordering is window_pct primary, weekly_pct only the tie-break (three-way discriminating fixture)" {
  # No usage_fixture here (unlike round-2's version of this test): it plants
  # an unrelated "work" tank whose name sorts between mmwinbest and
  # zzweekbest — round-3's P3-4 caps the LIVE refresh to the first 3
  # candidates by listing order, so "work" would steal zzweekbest's refresh
  # slot and leave it an unrefreshed "unknown" (tier 1), silently defeating
  # the three-way discrimination below. multi_curl_stub is all this test
  # needs; it does not depend on usage_fixture's own (overwritten) stub.
  clikae init claude aamiddle; clikae init claude mmwinbest; clikae init claude zzweekbest
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/burn.sh"
  multi_curl_stub
  # round-3 review, P3-1: the round-2 fixture (hiwin 85/5, hiweek 5/20) named
  # its tanks so the CORRECT answer (hiweek) was ALSO the alphabetical-listing
  # fallback (list_all_profiles pipes through `sort`) — deleting the intra-tier
  # comparison entirely (burn.sh's Pass-3 loop then just keeps the first
  # same-tier candidate it sees) stayed green, indistinguishable from the
  # ranking actually running. Three tanks, three DIFFERENT answers per
  # algorithm, so each wrong algorithm has its own distinct wrong tank:
  #   aamiddle    window=50 weekly=50  — alphabetically first; the answer a
  #                                       deleted-ranking fallback gives.
  #   mmwinbest   window=10 weekly=85  — lowest window_pct; the CORRECT
  #                                       answer (a burn starting now runs
  #                                       against the 5h window).
  #   zzweekbest  window=80 weekly=5   — lowest weekly_pct; the answer a
  #                                       weekly_pct-primary regression
  #                                       (round-1's shape) gives.
  # All three tier-0 (<90% peak). Negative controls run against a disposable
  # `cp -a` of this tree, never this worktree (paste in the fix commit body):
  #   - delete the Pass-3 up/uw comparison entirely -> aamiddle -> red.
  #   - swap the comparison back to weekly_pct-primary -> zzweekbest -> red.
  live_usage aamiddle 50 50
  live_usage mmwinbest 10 85
  live_usage zzweekbest 80 5
  run _burn_next_same_engine claude '' '' '' 1
  [ "$status" -eq 0 ]
  [ "$output" = mmwinbest ]
}

@test "P2-3: tier boundary — 89.9%peak beats unknown, 90.0%peak loses to unknown" {
  usage_fixture
  clikae init claude k899; clikae init claude unk
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/burn.sh"
  multi_curl_stub
  live_usage k899 89.9
  # unk: no credentials at all — P2-1(b)'s refresh fetch fails cleanly and
  # it stays unknown, same technique as the P2-9 test above.
  run _burn_next_same_engine claude '' '' '' 1
  [ "$status" -eq 0 ]
  [ "$output" = k899 ]   # <90 beats unknown

  clikae init claude k900
  live_usage k900 90.0
  # Exclude k899 via $tried (it's tier-0 and would win outright regardless
  # of how k900/unk compare) — this call isolates the tier-1-vs-tier-2
  # boundary the assertion is actually about.
  run _burn_next_same_engine claude ' claude/k899' '' '' 1
  [ "$status" -eq 0 ]
  [ "$output" = unk ]   # >=90 loses to unknown
}

@test "P2-9: a tank we have no reading for beats one known >=90% used" {
  usage_fixture
  clikae init claude aaa
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/burn.sh"
  multi_curl_stub
  # aaa: no credentials at all — P2-1(b)'s refresh fetch fails cleanly
  # (adapter_usage returns before ever calling curl) and it stays unknown.
  # bbb: known, 99% used on both windows, fetched fresh right before ranking.
  live_usage bbb 99
  # A tank known to be nearly exhausted must not outrank one we simply have
  # no data for — before this fix, unknown always lost to ANY reading.
  run _burn_next_same_engine claude '' '' '' 1
  [ "$status" -eq 0 ]
  [ "$output" = aaa ]
}

@test "P2-6a: same-account tanks rank as one, using the worst shared reading" {
  # No usage_fixture here (round-3 review, P3-4): it plants an unrelated
  # "work" tank that reaches the SAME refresh stage as xxx/yyy/zzz below —
  # with all four eligible, P3-4's cap-to-3-by-listing-order refresh would
  # give zzz's slot to "work" (alphabetically ahead of zzz), leaving zzz an
  # unrefreshed "unknown" and silently breaking this test's own premise.
  # multi_curl_stub is all this test needs.
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/burn.sh"
  multi_curl_stub

  # xxx and yyy share an account; xxx looks bad (95, >=90) and yyy looks
  # great (20) — but they are the SAME real quota. zzz is independent at 50.
  # Ranking must use the WORST shared reading (95, tier >=90), so the
  # genuinely independent 50% tank (zzz) wins, not yyy's falsely-good 20%.
  live_usage xxx 95; live_usage yyy 20; live_usage zzz 50
  printf '{"emailAddress":"shared@acct"}\n' > "$CLIKAE_HOME/profiles/claude/xxx/.claude.json"
  printf '{"emailAddress":"shared@acct"}\n' > "$CLIKAE_HOME/profiles/claude/yyy/.claude.json"
  run _burn_next_same_engine claude '' '' '' 1
  [ "$status" -eq 0 ]
  [ "$output" = zzz ]
}

@test "P2-6b: a same-account sibling is never chosen as the next (consecutive) hop" {
  usage_fixture
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/burn.sh"
  multi_curl_stub

  # ppp and qqq share an account; ppp is the tank the caller JUST tried
  # (passed in $tried). qqq looks great (5%) but sharing ppp's account means
  # hopping there gains nothing real — it must be skipped even though
  # dried_accts (confirmed-dry only) says nothing about it yet. rrr is the
  # only genuine option left.
  live_usage ppp 30; live_usage qqq 5; live_usage rrr 60
  printf '{"emailAddress":"hop@acct"}\n' > "$CLIKAE_HOME/profiles/claude/ppp/.claude.json"
  printf '{"emailAddress":"hop@acct"}\n' > "$CLIKAE_HOME/profiles/claude/qqq/.claude.json"
  # --separate-stderr: this scenario DOES skip a candidate (qqq), which
  # log_warn's advisory goes to stderr for — bats' `run` merges stdout+
  # stderr into $output by default, which would make an exact-match
  # assertion fail on a legitimate log line, not a real bug. Real callers
  # capture this function via `$(...)`, which only ever sees stdout (see
  # the function's own header comment); separate-stderr here matches that.
  run --separate-stderr _burn_next_same_engine claude ' claude/ppp' '' '' 1
  [ "$status" -eq 0 ]
  [ "$output" = rrr ]
}

# --- P2 (2026-09-14 round-4 review): the reroute refresh cap took the first
# 3 candidates by LISTING (alphabetical) order, ran BEFORE ranking existed,
# so the vendor calls landed on tanks that could never win while the tank
# that DID win was the one candidate left unverified with a stale, flattering
# on-disk reading. Rank first (on whatever's known), spend the live budget
# only on candidates that ranking says could win, bounded by the same cap. ---

@test "P2 (round-4 review): the review's 6-candidate scenario — cap spent on a plausible winner, not the alphabet" {
  # Reproduces the review's exact fixture shape: 6 same-engine candidates,
  # cap=3. d4 has an on-disk reading from 5 minutes ago (inside the age
  # ceiling, so Pass 3's snapshot legitimately ranks it tier-0) claiming 5%
  # used — but its REAL vendor value is 99%. a1/b2/c3/e5/f6 have never been
  # fetched (unknown on disk). On 9da32cd: Pass 1 refreshes the first 3
  # candidates BY LISTING ORDER (a1, b2, c3) regardless of what's already on
  # disk, d4 is never touched this call, and its stale 5% — lower than
  # anything a1/b2/c3's REAL headroom turns out to be — wins outright.
  # After the fix: d4's on-disk tier-0 reading gets it verified FIRST (it's
  # the one candidate that looks like it could win), revealing the true 99%;
  # the remaining 2 slots (cap=3 total) go to a1 and b2 in listing order
  # (c3 is never reached — an accepted, disclosed cap-bound limit, same as
  # today's), and the best VERIFIED reading (b2, 40%) wins.
  clikae init claude a1; clikae init claude b2; clikae init claude c3
  clikae init claude d4; clikae init claude e5; clikae init claude f6
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/burn.sh"
  multi_curl_stub
  live_usage a1 70; live_usage b2 40; live_usage c3 10
  live_usage e5 99; live_usage f6 99
  live_usage d4 99   # d4's REAL vendor value — only reached if it's refreshed
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  local d4_at; d4_at=$(( $(date +%s) - 300 ))   # 5 minutes ago
  jq -cn --argjson at "$d4_at" \
    '{window_pct:5,weekly_pct:5,window_resets_at:"2099-01-01T00:00:00.000000+00:00",weekly_resets_at:"2099-01-01T00:00:00.000000+00:00",source:"vendor",cached_at:$at,scanned_at:$at}' \
    > "$CLIKAE_HOME/state/usage/claude/d4.json"
  run _burn_next_same_engine claude '' '' '' 1
  [ "$status" -eq 0 ]
  [ "$output" = b2 ]
}

@test "P2 (round-4 review): a stale-but-good-looking on-disk reading is verified before it can win" {
  # 4 candidates, cap=3. zstale's on-disk 5% (10 minutes old, inside the
  # ceiling) looks best of all four with nothing refreshed yet, so it is the
  # FIRST one the fix spends a vendor call on — revealing 99%. The remaining
  # 2 slots go to aaa and fresh50 (next in listing order); mmm is never
  # reached. The best VERIFIED reading (fresh50, 50%) wins — never zstale's
  # never-verified-on-9da32cd 5%.
  clikae init claude aaa; clikae init claude fresh50
  clikae init claude mmm; clikae init claude zstale
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/burn.sh"
  multi_curl_stub
  live_usage aaa 80; live_usage fresh50 50; live_usage mmm 70
  live_usage zstale 99   # zstale's REAL vendor value
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  local stale_at; stale_at=$(( $(date +%s) - 600 ))   # 10 minutes ago
  jq -cn --argjson at "$stale_at" \
    '{window_pct:5,weekly_pct:5,window_resets_at:"2099-01-01T00:00:00.000000+00:00",weekly_resets_at:"2099-01-01T00:00:00.000000+00:00",source:"vendor",cached_at:$at,scanned_at:$at}' \
    > "$CLIKAE_HOME/state/usage/claude/zstale.json"
  run _burn_next_same_engine claude '' '' '' 1
  [ "$status" -eq 0 ]
  [ "$output" = fresh50 ]
}

@test "P2 (round-4 review): a same-account sibling never spends a second refresh slot" {
  # sib1/sib2 share an account; lone is independent — 3 tanks total, same as
  # the cap. On 9da32cd, Pass 1 refreshes ALL THREE before Pass 2 ever
  # collapses the siblings (2 of the 3 calls land on the SAME account). After
  # the fix, Pass 2's collapse runs before any live call, so sib2 is never a
  # ranking candidate at all — only sib1 (the representative) and lone are
  # ever refreshed: 2 calls, not 3.
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/burn.sh"
  multi_curl_stub
  export USAGE_CALLS="$TEST_HOME/calls"
  # multi_curl_stub's own stub doesn't count calls; wrap it so this test can.
  cat > "$TEST_HOME/.testbin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'call\n' >> "$USAGE_CALLS"
config="$(cat)"
tok="$(printf '%s' "$config" | sed -n 's/.*Bearer \([^"]*\)".*/\1/p')"
line="$(awk -v t="$tok" '$1==t{print; exit}' "$CLIKAE_TEST_PCTMAP" 2>/dev/null)"
if [ -z "$line" ]; then echo '{"error":"unauthorized"}'; exit 22; fi
read -r _ window weekly <<< "$line"
printf '{"five_hour":{"utilization":%s,"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":%s,"resets_at":"2099-01-07T00:00:00.000000+00:00"}}\n' "$window" "$weekly"
STUB
  chmod +x "$TEST_HOME/.testbin/curl"
  live_usage sib1 20; live_usage sib2 25; live_usage lone 60
  printf '{"emailAddress":"shared@acct"}\n' > "$CLIKAE_HOME/profiles/claude/sib1/.claude.json"
  printf '{"emailAddress":"shared@acct"}\n' > "$CLIKAE_HOME/profiles/claude/sib2/.claude.json"
  run _burn_next_same_engine claude '' '' '' 1
  [ "$status" -eq 0 ]
  [ "$output" = sib1 ]
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" -eq 2 ]
}

# --- P2-1 (2026-09-14 round-5 review): a candidate whose Pass-4 refresh call
# FAILS (401/expired token/network error) writes source:"unknown" to its own
# disk cache (usage_read's actual contract), but burn.sh:582-586 only updated
# c_up/c_uw/c_peak on a SUCCESSFUL post-refresh peek — a failed peek left
# Pass 1's stale in-memory tier-0 number alive, so the candidate that just
# proved itself unreadable still won the ranking over a sibling that verified
# clean this same call. Same failure shape as the round-4 P2, one call later:
# the vendor call that was supposed to make the winner verified instead made
# it silently unverifiable, and nothing downgraded it in memory. ---

@test "P2-1 (round-5 review): a candidate whose live refresh call fails loses to one that verified" {
  # zstale looks best of all three with nothing refreshed yet (5% on disk, 5
  # minutes old — inside the age ceiling, tier-0 in Pass 3's snapshot), so
  # it's the FIRST candidate the cap spends a call on. Its token is never
  # registered in the pctmap, so the stub 401s — usage_read caches that as
  # source:"unknown" and the post-refresh peek fails. Before this fix, the
  # failed peek left zstale's stale 5% untouched in memory and it won
  # outright, never having been read at all this call. After the fix, a
  # failed peek demotes it to unknown, and the best VERIFIED reading (good,
  # 40%) wins instead.
  clikae init claude zstale
  printf '{"claudeAiOauth":{"accessToken":"tok-zstale-invalid"}}\n' \
    > "$CLIKAE_HOME/profiles/claude/zstale/.credentials.json"
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/burn.sh"
  multi_curl_stub
  live_usage good 40; live_usage other 70
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  local stale_at; stale_at=$(( $(date +%s) - 300 ))   # 5 minutes ago
  jq -cn --argjson at "$stale_at" \
    '{window_pct:5,weekly_pct:5,window_resets_at:"2099-01-01T00:00:00.000000+00:00",weekly_resets_at:"2099-01-01T00:00:00.000000+00:00",source:"vendor",cached_at:$at,scanned_at:$at}' \
    > "$CLIKAE_HOME/state/usage/claude/zstale.json"
  # 3 runs stable (round-5 review: "連跑 3 次結果相同") — no ordering flake.
  local i
  for i in 1 2 3; do
    run _burn_next_same_engine claude '' '' '' 1
    [ "$status" -eq 0 ]
    [ "$output" = good ] || { echo "run $i got: $output"; false; }
    run usage_cache_peek claude zstale
    [ "$status" -ne 0 ] || { echo "run $i: zstale's failed refresh should read back as unknown, got: $output"; false; }
  done
}

@test "cached vendor thresholds pick the right glyph" {
  usage_fixture
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/home.sh"
  __C_RED=R __C_YELLOW=Y __C_GREEN=G __C_RESET=''
  # round-3 review, P2-1: dry/expired-limit are now checked BEFORE the usage
  # cache (home.sh's _home_fuel_dotv_compute) and WIN outright, so a stub
  # that reports an unverified caution here would mask every glyph below
  # regardless of percentage — report nothing dry/expired so the usage
  # block this test actually means to exercise is reachable at all.
  _home_is_dryv() { _DRY_RESET=''; return 1; }
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  local pct expected
  for pct in 59 60 90; do
    case "$pct" in 59) expected=G● ;; 60) expected=Y◐ ;; 90) expected=R○ ;; esac
    jq -cn --argjson pct "$pct" --argjson now "$(date +%s)" '{window_pct:$pct,weekly_pct:0,source:"vendor",cached_at:$now}' > "$CLIKAE_HOME/state/usage/claude/work.json"
    # P2-1 (round-1 review): _home_fuel_dotv now memoizes per (dry,cli,tank)
    # WITHIN one redraw (reset only by _home_fuel_memo_reset, called once at
    # the top of each real redraw) — correct in production, where nothing
    # rewrites a usage cache file mid-redraw, but this loop rewrites the
    # SAME tank's cache file between calls to simulate the cache changing
    # over time. Reset the memo each iteration so it reads the fresh file,
    # exactly as a real caller would after a new redraw begins.
    _home_fuel_memo_reset
    _home_fuel_dotv '' claude work
    [ "$_FDOT" = "$expected" ]
  done
}

@test "P2-1(c): a stale-but-recent vendor reading is shown WITH its age; 24h+ falls back to unverified" {
  usage_fixture
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/home.sh"
  __C_RED=R __C_YELLOW=Y __C_GREEN=G __C_RESET=''
  # round-3 review, P2-1: dry/expired-limit are now checked BEFORE the usage
  # cache and WIN outright — a stub that unconditionally reports the
  # unverified caution would mask the FIRST (fresh, <24h) case below, which
  # this test means to prove shows the READING instead. Report nothing
  # dry/expired until the second (25h-old, meant-to-fall-through) case flips
  # the flag below.
  local _sim_unverified=0
  _home_is_dryv() {
    if [ "$_sim_unverified" = 1 ]; then _DRY_RESET='reset passed · unverified'; else _DRY_RESET=''; fi
    return 1
  }
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  local now=1789400000

  # 3h old — long past the 120s TTL, nowhere near the 24h cutoff. This used to
  # show NOTHING (usage_cached_fields' TTL made it invisible) and fall all the
  # way through to the unverified-reset mock below; this is the exact gap the
  # round-2 review's own receipt measured (3 of 4 real tanks, hours stale,
  # showed nothing on the board). Now: still shown, WITH its age alongside it.
  jq -cn --argjson pct 65 --argjson now "$now" --argjson cached_at "$((now - 10800))" \
    '{window_pct:$pct,weekly_pct:20,source:"vendor",cached_at:$cached_at}' \
    > "$CLIKAE_HOME/state/usage/claude/work.json"
  _home_fuel_dotv_compute '' claude work "$now"
  [ "$_FDOT" = Y◐ ]
  [ "$_FNOTE" = 'window 65% · weekly 20% · 3h ago' ]

  # 25h old — past the 24h line: too stale to show as a number at all, falls
  # through to whatever the rest of the chain says below (weekly/codex/
  # ready). P3-1 (round-4 review): the round-3 version of this case flipped
  # _sim_unverified=1 here — but home.sh:1025 checks the SAME $_DRY_RESET
  # _home_is_dryv sets and returns BEFORE the usage block at :1028 (where
  # the 24h line at :1032 lives) is ever reached, so that assertion was
  # satisfied by the stub, not by the 24h line: deleting :1032 left this
  # test 82/82 green (see this test's own header — the receipt is now
  # recorded there in the commit body, not re-derived here). Testing
  # unverified PRIORITY is home.bats:646-701's job already; this scenario's
  # only job is the 24h cutoff, so it must not simulate unverified — keep
  # _DRY_RESET empty (never flip _sim_unverified) so control actually
  # reaches :1028. Assert no percentage sign: the SIGN the stale reading
  # was not used, without hard-coding which of weekly/codex/ready this bare
  # fixture (none of those wired up) happens to fall into.
  jq -cn --argjson pct 44 --argjson now "$now" --argjson cached_at "$((now - 90000))" \
    '{window_pct:$pct,weekly_pct:20,source:"vendor",cached_at:$cached_at}' \
    > "$CLIKAE_HOME/state/usage/claude/work.json"
  _home_fuel_dotv_compute '' claude work "$now"
  [[ "$_FNOTE" != *%* ]]
}

@test "Claude Keychain service uses the tank path; malformed credentials never invoke curl" {
  usage_fixture
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/adapters/claude.sh"
  local service
  service="$(_claude_keychain_service "$CLIKAE_HOME/profiles/claude/work")"
  cp "$CLIKAE_HOME/profiles/claude/work/.credentials.json" "$CLIKAE_TEST_KEYCHAIN/$service"
  rm "$CLIKAE_HOME/profiles/claude/work/.credentials.json"
  # Use a read-only stub with the same service assertion on every platform.
  cat > "$TEST_HOME/.testbin/security" <<STUB
#!/usr/bin/env bash
[ "\$1" = find-generic-password ] || exit 1
[ "\$3" = '$service' ] || exit 1
cat '$CLIKAE_TEST_KEYCHAIN/$service'
STUB
  chmod +x "$TEST_HOME/.testbin/security"
  OSTYPE=darwin run clikae usage claude work --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "vendor"'
  printf '%s\n' '{"claudeAiOauth":{"accessToken":"bad\nheader"}}' > "$CLIKAE_HOME/profiles/claude/work/.credentials.json"
  run clikae usage claude work --fresh --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "unknown"'
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 1 ]
}

@test "P2-2: the Keychain read is bounded by the PERL arm when neither timeout nor gtimeout exist" {
  usage_fixture
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/adapters/claude.sh"
  local service
  service="$(_claude_keychain_service "$CLIKAE_HOME/profiles/claude/work")"
  rm "$CLIKAE_HOME/profiles/claude/work/.credentials.json"

  # A `security` that blocks 30s before ever answering — the shape of a
  # locked Keychain or an ACL prompt with no one there to answer it. `exec
  # sleep 30` (replacing THIS process, not spawning sleep as a child) on
  # purpose: the perl arm's technique is `alarm N; exec real-cmd` — SIGALRM
  # lands on whatever process the alarm's PID has become, so it only bounds
  # a single process wearing that PID. A plain `sleep 30` launched as a
  # CHILD would still be holding the pipe's write end open, undetected,
  # after the alarm kills its parent — a fixture artifact that would fail
  # this test even though the real `security` binary (a single process,
  # same as the exec'd `sleep` here) is genuinely bounded.
  cat > "$TEST_HOME/.testbin/security" <<STUB
#!/usr/bin/env bash
[ "\$1" = find-generic-password ] || exit 1
[ "\$3" = '$service' ] || exit 1
exec sleep 30
STUB
  chmod +x "$TEST_HOME/.testbin/security"

  # Shadow PATH: every real tool already on PATH EXCEPT timeout/gtimeout —
  # this host has real coreutils `timeout` (most dev/CI machines do), so
  # simply not stubbing it is not enough; it has to be actively hidden for
  # this test to exercise the same fallback stock macOS hits for free. The
  # stubbed `security` above (this test's own .testbin, ahead of the shadow
  # copy) still wins over anything the shadow loop would have symlinked.
  local shadow="$BATS_TEST_TMPDIR/shadow" d f b
  mkdir -p "$shadow"
  ln -s "$TEST_HOME/.testbin/security" "$shadow/security"
  local IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -f "$f" ] && [ -x "$f" ] || continue
      b="$(basename "$f")"
      case "$b" in timeout|gtimeout) continue ;; esac
      [ -e "$shadow/$b" ] || ln -s "$f" "$shadow/$b" 2>/dev/null
    done
  done
  unset IFS
  [ -z "$(PATH="$shadow" command -v timeout 2>/dev/null)" ]
  [ -z "$(PATH="$shadow" command -v gtimeout 2>/dev/null)" ]
  [ -n "$(PATH="$shadow" command -v perl 2>/dev/null)" ]

  local t0 t1 wall
  t0=$(date +%s)
  PATH="$shadow" OSTYPE=darwin run clikae usage claude work --json
  t1=$(date +%s)
  wall=$(( t1 - t0 ))
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "unknown"'   # security never actually answered
  # Bounded near the 5s the Keychain read asks for, nowhere near the 30s the
  # stub actually sleeps — this is exactly the gap the round-2 review found:
  # the pre-fix two-arm resolver had NO third arm, so on a shadow PATH shaped
  # like stock macOS (no timeout/gtimeout) this call ran fully unbounded.
  [ "$wall" -ge 4 ]
  [ "$wall" -le 20 ]
}

@test "P3-2 (codex security review, round-5): an oversized response body is rejected, not fully parsed" {
  # Neither curl's --max-time (transfer TIME, not bytes) nor the small final
  # cache shape bounded how much a faulty/hostile upstream could make this
  # adapter buffer and hand to jq. A response padded well past the new byte
  # cap must come back unknown, not get silently truncated into a "valid"
  # partial JSON parse or fully accepted.
  usage_fixture
  cat > "$TEST_HOME/.testbin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'call\n' >> "$USAGE_CALLS"
config="$(cat)"
[[ "$config" == *'Authorization: Bearer stub-secret-usage72'* ]] || exit 2
pad="$(printf 'x%.0s' $(seq 1 200000))"
printf '{"five_hour":{"utilization":1,"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":2,"resets_at":"2099-01-07T00:00:00.000000+00:00"},"pad":"%s"}' "$pad"
STUB
  chmod +x "$TEST_HOME/.testbin/curl"
  run clikae usage claude work --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "unknown" and .window_pct == null'
}

@test "P3-4 (round-5 review): a stale-but-evidenced candidate is verified before confident fresh ones, and P3-3 stops early on a verified 0%" {
  # Reproduces the review's exact board shape: alpha's on-disk 5% is 30
  # minutes old (past the 15-minute ceiling — usage_cache_peek reads it as
  # unknown), while bravo/charlie/delta all have confident FRESH readings
  # (60s old). Before this fix, confident tier 0 always outranked ANY tier 1
  # candidate for Pass 4's refresh budget, so alpha — despite the board
  # itself still showing its stale percentage — never got a single vendor
  # call, no matter how good its true headroom actually was (measured on
  # 9da32cd-shaped code: alpha's real value, 1%, the emptiest of all four,
  # went undiscovered). After the fix, alpha (stale-but-evidenced) is
  # refreshed FIRST, revealing its true 1% — and P3-3's early-stop then fires
  # the moment a later refresh confirms bravo can't beat it: the fixture
  # gives bravo/charlie/delta unchanged real values, so calls stop at 3, the
  # same total the review measured, but spent on the right three tanks.
  clikae init claude alpha; clikae init claude bravo
  clikae init claude charlie; clikae init claude delta
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/burn.sh"
  multi_curl_stub
  live_usage alpha 1; live_usage bravo 55; live_usage charlie 58; live_usage delta 59
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  local now; now="$(date +%s)"
  local alpha_at=$(( now - 1800 ))   # 30 minutes ago — past the ceiling
  local fresh_at=$(( now - 60 ))     # 60 seconds ago — well inside it
  jq -cn --argjson at "$alpha_at" \
    '{window_pct:5,weekly_pct:5,window_resets_at:"2099-01-01T00:00:00.000000+00:00",weekly_resets_at:"2099-01-01T00:00:00.000000+00:00",source:"vendor",cached_at:$at,scanned_at:$at}' \
    > "$CLIKAE_HOME/state/usage/claude/alpha.json"
  jq -cn --argjson at "$fresh_at" \
    '{window_pct:55,weekly_pct:55,window_resets_at:"2099-01-01T00:00:00.000000+00:00",weekly_resets_at:"2099-01-01T00:00:00.000000+00:00",source:"vendor",cached_at:$at,scanned_at:$at}' \
    > "$CLIKAE_HOME/state/usage/claude/bravo.json"
  jq -cn --argjson at "$fresh_at" \
    '{window_pct:58,weekly_pct:58,window_resets_at:"2099-01-01T00:00:00.000000+00:00",weekly_resets_at:"2099-01-01T00:00:00.000000+00:00",source:"vendor",cached_at:$at,scanned_at:$at}' \
    > "$CLIKAE_HOME/state/usage/claude/charlie.json"
  jq -cn --argjson at "$fresh_at" \
    '{window_pct:59,weekly_pct:59,window_resets_at:"2099-01-01T00:00:00.000000+00:00",weekly_resets_at:"2099-01-01T00:00:00.000000+00:00",source:"vendor",cached_at:$at,scanned_at:$at}' \
    > "$CLIKAE_HOME/state/usage/claude/delta.json"
  # Sanity: alpha really does read as unknown pre-refresh (past the ceiling).
  run usage_cache_peek claude alpha
  [ "$status" -ne 0 ]
  export USAGE_CALLS="$TEST_HOME/calls"
  cat > "$TEST_HOME/.testbin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'call\n' >> "$USAGE_CALLS"
config="$(cat)"
tok="$(printf '%s' "$config" | sed -n 's/.*Bearer \([^"]*\)".*/\1/p')"
line="$(awk -v t="$tok" '$1==t{print; exit}' "$CLIKAE_TEST_PCTMAP" 2>/dev/null)"
if [ -z "$line" ]; then echo '{"error":"unauthorized"}'; exit 22; fi
read -r _ window weekly <<< "$line"
printf '{"five_hour":{"utilization":%s,"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":%s,"resets_at":"2099-01-07T00:00:00.000000+00:00"}}\n' "$window" "$weekly"
STUB
  chmod +x "$TEST_HOME/.testbin/curl"
  run _burn_next_same_engine claude '' '' '' 1
  [ "$status" -eq 0 ]
  [ "$output" = alpha ]
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" -eq 3 ]
}

@test "P2-3: real vendor reset-instant shape expires correctly (negative control proves the old guard failed open)" {
  usage_fixture
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/usage.sh"
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  local now=1789300000 past future
  past="2020-01-01T00:00:00.189940+00:00"     # real shape, well before $now
  future="2099-01-01T00:00:00.189940+00:00"   # real shape, well after $now

  # Negative control: the PRE-FIX regex (sub("\.[0-9]+Z$";"Z")) is a no-op on
  # this shape (no bare "Z" to match — it's "…mmmmmm+00:00"), so
  # fromdateiso8601 throws and `catch` used to report "still valid" no
  # matter what the timestamp actually said. Prove it fails open on a
  # timestamp from 2020 — if THIS assertion ever fails, the negative
  # control itself is broken, not the fix below.
  run jq -cn --arg ts "$past" --argjson now "$now" \
    '($ts | (try (sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) catch ($now+1))) > $now'
  [ "$output" = true ]   # old regex: a 2020 timestamp reads as "not yet expired"

  # Fixed guard, same past timestamp, real shape, through usage_cached_fields:
  # an already-passed reset must NOT be trusted as a live reading. (jq 1.7's
  # `-e` reports a totally-empty stream as rc=4, not rc=1 — every caller in
  # this repo tests truthiness via `if usage_cached_fields ...; then`, which
  # treats any nonzero the same, so this asserts -ne 0 rather than a specific
  # code the jq version can change out from under.)
  jq -cn --arg ts "$past" --argjson now "$now" \
    '{window_pct:50,weekly_pct:50,window_resets_at:$ts,weekly_resets_at:null,source:"vendor",cached_at:$now}' \
    > "$CLIKAE_HOME/state/usage/claude/work.json"
  run usage_cached_fields claude work "$now"
  [ "$status" -ne 0 ]

  # Same fix, a real-shape FUTURE timestamp -> accepted.
  jq -cn --arg ts "$future" --argjson now "$now" \
    '{window_pct:50,weekly_pct:50,window_resets_at:$ts,weekly_resets_at:null,source:"vendor",cached_at:$now}' \
    > "$CLIKAE_HOME/state/usage/claude/work.json"
  run usage_cached_fields claude work "$now"
  [ "$status" -eq 0 ]
}

@test "network failure is unknown; Codex status windows are honestly source:transcript" {
  usage_fixture
  printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 7\n' > "$TEST_HOME/.testbin/curl"
  run clikae usage claude work --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "unknown"'
  clikae init codex work
  mkdir -p "$CLIKAE_HOME/profiles/codex/work/sessions/2026/09/10"
  printf '%s\n' '{"timestamp":"2026-09-10T09:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":10,"window_minutes":300,"resets_at":4102444800},"secondary":{"used_percent":96,"window_minutes":10080,"resets_at":4103049600}}}}' > "$CLIKAE_HOME/profiles/codex/work/sessions/2026/09/10/rollout-usage.jsonl"
  run clikae usage codex work --json
  [ "$status" -eq 0 ]
  # P2-4 (round-1 review): no `codex` process ever runs for this — it's read
  # straight from the rollout transcript above, so source is honestly
  # "transcript", never "vendor" (#72's own acceptance criteria named
  # "transcript" as a real value; nothing in the repo ever produced it
  # before this fix).
  echo "$output" | jq -e '.source == "transcript" and .window_pct == 10 and .weekly_pct == 96 and .window_resets_at == "2100-01-01T00:00:00Z"'
  # cached_at is the rollout event's OWN timestamp (2026-09-10T09:00:00Z),
  # not "now" — a week-old-in-test-time reading must not read as freshly
  # polled. epoch("2026-09-10T09:00:00Z") = 1789030800.
  jq -e '.cached_at == 1789030800' "$CLIKAE_HOME/state/usage/codex/work.json"
}

@test "usage.sh:29 (P3): a third positional argument is rejected with a clear error, not silent" {
  run clikae usage claude work extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"Too many arguments"* ]]
}

@test "P3: codex gets a real cache hit within TTL — scanned_at, not the event's own stale timestamp" {
  clikae init codex work
  mkdir -p "$CLIKAE_HOME/profiles/codex/work/sessions/2026/09/10"
  printf '%s\n' '{"timestamp":"2026-09-10T09:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":10,"window_minutes":300,"resets_at":4102444800},"secondary":{"used_percent":96,"window_minutes":10080,"resets_at":4103049600}}}}' > "$CLIKAE_HOME/profiles/codex/work/sessions/2026/09/10/rollout-usage.jsonl"
  run clikae usage codex work --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "transcript" and .window_pct == 10'
  # cached_at (the event's own time, 2026-09-10) is hours/days behind "now"
  # in test time — under the round-1 behaviour (TTL keyed on cached_at) that
  # made EVERY subsequent call a cache miss, a full rollout rescan each
  # time (round-2 review's own receipt: 85ms/82ms back-to-back, zero hits).
  # Prove this call was served from cache, not a rescan: delete the rollout
  # file, then read again within the TTL — a rescan would find NOTHING
  # (source:unknown); a real cache hit still returns the same reading.
  rm -f "$CLIKAE_HOME/profiles/codex/work/sessions/2026/09/10/rollout-usage.jsonl"
  run clikae usage codex work --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "transcript" and .window_pct == 10'
}

@test "P2-2 (codex security review, round-5): rescanning a 3-day-old rollout must not renew its ranking eligibility" {
  # _USAGE_CACHE_PEEK_MAX_AGE_SEC (900s) is meant to bound how OLD evidence
  # can be and still rank a tank. Before this fix, usage_cache_peek measured
  # that age off `scanned_at` — "when something last read this file" — which
  # for a codex transcript reading is unrelated to how old the underlying
  # quota EVENT actually is. A rollout can be rescanned (by `clikae usage`,
  # by burn's own refreshes) indefinitely without any new evidence ever
  # arriving from the vendor, and each rescan renewed the ceiling. Reproduces
  # the review's exact shape: an event 3 days old, both percentages at 100,
  # both resets already in the past.
  clikae init codex old
  mkdir -p "$CLIKAE_HOME/profiles/codex/old/sessions/2026/09/10"
  local three_days_ago
  three_days_ago="$(date -u -v-3d +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%S.000Z)"
  local reset_past=$(( $(date +%s) - 3600 ))   # 1 hour ago, well in the past
  printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":100,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":100,"window_minutes":10080,"resets_at":%s}}}}\n' \
    "$three_days_ago" "$reset_past" "$reset_past" \
    > "$CLIKAE_HOME/profiles/codex/old/sessions/2026/09/10/rollout-usage.jsonl"
  # A fresh scan honestly reports the old reading it found — this is `clikae
  # usage`'s job, not usage_cache_peek's; it must keep telling the truth
  # about what the transcript says, stale or not.
  run clikae usage codex old --fresh --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "transcript" and .window_pct == 100 and .weekly_pct == 100'
  # But burn's ranking must not trust it: cached_at (the EVENT's own 3-day-
  # old timestamp) is what the age ceiling measures now, not scanned_at (the
  # rescan that just happened). This candidate must read as unknown — never
  # as 0% (the old reset-passed branch's answer) and never as 100%.
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/usage.sh"
  run usage_cache_peek codex old
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "P3-12: norm_stamp handles a +09:00 offset, not only +00:00" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/usage.sh"
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  local now=1789300000
  # 23:50 JST (+09:00) on the day before $now's UTC date is 14:50 UTC the
  # same day as $now (16:40Z in the review's own worked example) — well
  # before $now either way. A guard that only strips "+00:00"/"-00:00"
  # fails to PARSE this at all and fails open (treated as not-yet-expired,
  # same bug shape as P2-3's round-1 fixture); the fixed norm_stamp does the
  # arithmetic and rejects it as expired.
  jq -cn --argjson now "$now" \
    '{window_pct:50,weekly_pct:50,window_resets_at:"2026-09-13T14:50:00.189940+09:00",weekly_resets_at:null,source:"vendor",cached_at:$now,scanned_at:$now}' \
    > "$CLIKAE_HOME/state/usage/claude/work.json"
  run usage_cached_fields claude work "$now"
  [ "$status" -ne 0 ]   # expired reset in +09:00 correctly rejected

  # Same offset, but shifted 20 hours later so the SAME wall-clock instant
  # reads as still in the future — proves this isn't accidentally rejecting
  # every +09:00 stamp outright.
  jq -cn --argjson now "$now" \
    '{window_pct:50,weekly_pct:50,window_resets_at:"2026-09-14T10:50:00.189940+09:00",weekly_resets_at:null,source:"vendor",cached_at:$now,scanned_at:$now}' \
    > "$CLIKAE_HOME/state/usage/claude/work.json"
  run usage_cached_fields claude work "$now"
  [ "$status" -eq 0 ]
}

@test "P2 (round-4 review): usage_cache_peek trusts a reading up to its age ceiling, unknown past it" {
  # Round-3's version of this test was named "the 'stale allowed' design"
  # and asserted a 3-DAY-old reading still ranks — that was exactly the
  # design the round-4 review's P2 found costing burn a wrong hop (a stale
  # but flattering on-disk reading, never re-verified, wins a ranking a
  # freshly-verified worse-looking candidate should have won). The new
  # contract: a reading survives up to _USAGE_CACHE_PEEK_MAX_AGE_SEC old
  # (stale-but-recent still beats no reading — burn's ranking still needs
  # SOME signal when nothing has refreshed a tank yet this call), unknown
  # once it's older than that — never a 3-day-old number pretending to be
  # current. See this file's own 6-candidate P2 scenario (above,
  # "_burn_next_same_engine" tests) for this mattering end-to-end, not just
  # at this function's own boundary.
  usage_fixture
  clikae init claude old
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  local now recent_at stale_at
  now="$(date +%s)"
  recent_at=$((now - 600))    # 10 minutes ago — inside the 900s ceiling
  stale_at=$((now - 1200))    # 20 minutes ago — past it
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  # A reading whose window has NOT reset (resets_at still in the future) —
  # 10 minutes stale by the clock, still trusted.
  jq -cn --argjson pct 30 --argjson at "$recent_at" \
    '{window_pct:$pct,weekly_pct:$pct,window_resets_at:"2099-01-01T00:00:00.000000+00:00",weekly_resets_at:"2099-01-01T00:00:00.000000+00:00",source:"vendor",cached_at:$at,scanned_at:$at}' \
    > "$CLIKAE_HOME/state/usage/claude/old.json"
  run usage_cache_peek claude old "$now"
  [ "$status" -eq 0 ]
  [ "$output" = $'30\t30\t30' ]
  # Same shape, 20 minutes old this time — past the ceiling, "unknown".
  jq -cn --argjson pct 30 --argjson at "$stale_at" \
    '{window_pct:$pct,weekly_pct:$pct,window_resets_at:"2099-01-01T00:00:00.000000+00:00",weekly_resets_at:"2099-01-01T00:00:00.000000+00:00",source:"vendor",cached_at:$at,scanned_at:$at}' \
    > "$CLIKAE_HOME/state/usage/claude/old.json"
  run usage_cache_peek claude old "$now"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # The TTL-gated function, by contrast, refuses BOTH (120s default) — the
  # two functions' different contracts are the point, not a bug in either.
  run usage_cached_fields claude old "$now"
  [ "$status" -ne 0 ]
}

@test "P3-6 (round-5 review): a non-numeric _USAGE_CACHE_PEEK_MAX_AGE_SEC warns loudly and falls back, instead of every peek silently going unknown" {
  usage_fixture
  clikae init claude work2
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  jq -cn --argjson pct 30 --argjson now "$(date +%s)" \
    '{window_pct:$pct,weekly_pct:$pct,window_resets_at:"2099-01-01T00:00:00.000000+00:00",weekly_resets_at:"2099-01-01T00:00:00.000000+00:00",source:"vendor",cached_at:$now,scanned_at:$now}' \
    > "$CLIKAE_HOME/state/usage/claude/work2.json"
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  run --separate-stderr bash -c '
    export CLIKAE_LIB="'"$CLIKAE_LIB"'" CLIKAE_HOME="'"$CLIKAE_HOME"'"
    source "$CLIKAE_LIB/core/log.sh"
    export _USAGE_CACHE_PEEK_MAX_AGE_SEC=abc
    source "$CLIKAE_LIB/core/usage.sh"
    usage_cache_peek claude work2
  '
  [ "$status" -eq 0 ]
  [ "$output" = $'30\t30\t30' ]   # fell back to the default (900) instead of going blind
  [[ "$stderr" == *"_USAGE_CACHE_PEEK_MAX_AGE_SEC"*"not a non-negative integer"* ]] || { echo "stderr: $stderr"; false; }
}

@test "P3-6 (round-5 review): a non-numeric _BURN_REROUTE_REFRESH_CAP warns loudly and falls back, instead of silently spending zero reroute calls" {
  clikae init claude a1; clikae init claude b2
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  multi_curl_stub
  live_usage a1 70; live_usage b2 40
  export USAGE_CALLS="$TEST_HOME/calls"
  cat > "$TEST_HOME/.testbin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'call\n' >> "$USAGE_CALLS"
config="$(cat)"
tok="$(printf '%s' "$config" | sed -n 's/.*Bearer \([^"]*\)".*/\1/p')"
line="$(awk -v t="$tok" '$1==t{print; exit}' "$CLIKAE_TEST_PCTMAP" 2>/dev/null)"
if [ -z "$line" ]; then echo '{"error":"unauthorized"}'; exit 22; fi
read -r _ window weekly <<< "$line"
printf '{"five_hour":{"utilization":%s,"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":%s,"resets_at":"2099-01-07T00:00:00.000000+00:00"}}\n' "$window" "$weekly"
STUB
  chmod +x "$TEST_HOME/.testbin/curl"
  run --separate-stderr bash -c '
    export CLIKAE_LIB="'"$CLIKAE_LIB"'" CLIKAE_HOME="'"$CLIKAE_HOME"'" CLIKAE_TEST_PCTMAP="'"$CLIKAE_TEST_PCTMAP"'" USAGE_CALLS="'"$USAGE_CALLS"'" PATH="'"$PATH"'" _BURN_REROUTE_REFRESH_CAP=abc
    source "$CLIKAE_LIB/core/log.sh"
    source "$CLIKAE_LIB/core/profile_store.sh"
    source "$CLIKAE_LIB/core/adapter_loader.sh"
    source "$CLIKAE_LIB/core/limit.sh"
    source "$CLIKAE_LIB/core/usage.sh"
    source "$CLIKAE_LIB/commands/burn.sh"
    _burn_next_same_engine claude "" "" "" 1
  '
  [ "$status" -eq 0 ]
  [ "$output" = b2 ]   # a live call actually happened and picked the real winner
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" -ge 1 ]   # not zero — the old silent-off failure mode
  [[ "$stderr" == *"_BURN_REROUTE_REFRESH_CAP"*"not a non-negative integer"* ]] || { echo "stderr: $stderr"; false; }
}
