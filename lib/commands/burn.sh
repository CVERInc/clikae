# shellcheck shell=bash
# lib/commands/burn.sh — `clikae burn <engine> <tank> --artifact <path> -- <cmd...>`
#
# Run a HEADLESS task on a tank, but actually KNOW whether it finished — and if the
# tank ran dry mid-task, keep burning the next tank in your reserve. This closes the
# 2026-06-03 burn-writeup gap: `codex exec` exits 0 even when it hit its usage limit
# and wrote nothing, so the exit code lies. burn judges by two honest signals: the
# limit string in the captured output (lib/core/limit.sh) AND the expected artifact.
#
# Scope on purpose: burn is the SINGLE-task unit an orchestrator fans out and
# re-fires — batch/parallelism stays the orchestrator's job (that's how the real
# burn ran: claude dispatched in parallel and reviewed). "Your tanks are the
# reserve" (docs/grammar.md — why `pool` was removed), so auto-reroute walks THIS
# engine's other tanks; --to forces an explicit next hop (may cross engines, warned).
#
# agy is adapter-less (global single-account, no per-shell env), so it can't go
# through the adapter-driven loop below — it gets its own loop, _agy_burn.
# shellcheck source=./antigravity.sh
source "$CLIKAE_LIB/commands/antigravity.sh"

_burn_help() {
  cat <<'EOF'
Usage: clikae burn <engine> <tank> --artifact <path>
                   ( --prompt-file <f> | --prompt <str> | -- <engine command...> )
                   [--add-dir <dir>]... [--to <target>] [--timeout <secs>]
                   [--no-reroute] [--allow-active] [--fresh]

Run a headless engine task on <tank>, verify it by the ARTIFACT it should
produce (never the exit code — codex exec exits 0 even when it hit its limit and
wrote nothing), and if the tank ran dry, re-fire the SAME task on the next tank
in your reserve.

Give the task in one of two ways:
  · the easy way — --prompt-file <f> / --prompt <str>: clikae fills in each
    engine's own headless-write flags (claude's -p / codex's exec …) from its
    adapter, so you never hand-assemble them and a cross-engine reroute stays
    sound (the flags are regenerated for the new engine).
  · the power-user way — -- <engine command...>: pass the raw engine argv yourself.
    For agy there is no adapter to compose, so `--` means EXTRA AGY FLAGS riding
    alongside --prompt, not a whole command. Headless dispatch usually wants:
      -- --dangerously-skip-permissions     let agy write (print mode auto-denies)
      -- -c                                 continue the previous conversation

  --prompt-file <f>   read the task prompt from a file (no quoting hell).
  --prompt <str>      inline prompt, for one-liners. (Mutually exclusive with the above.)
  --add-dir <dir>     a directory the engine may write in. Defaults to the
                      artifact's parent. Repeatable. (codex uses the first as its cwd.)
  --artifact <path>   checked at engine exit. Success = it appears, or (if
                      it already existed) its timestamp changes — a STALE file from
                      a previous run is NOT counted as success.
  --fresh             delete <artifact> before running, for a clean slate.
  --to <target>       explicit next hop on a dry tank (<engine>/<tank> or a bare
                      tank of this engine). Otherwise burn walks this engine's
                      other tanks. A cross-engine --to runs the SAME command under
                      that engine — only sensible if the command is engine-agnostic.
  --timeout <secs>    bound the run. Uses `timeout`/`gtimeout` (coreutils) if present,
                      else a `perl` alarm (SIGALRM, direct child only). With none of
                      the three on PATH the run is NOT bounded and a warning is printed.
  --json              print ONE result object on stdout and every word of
                      progress on stderr — so a script never parses prose to
                      learn what happened. Rule 1 is "judge by the artifact,
                      never the exit code", and with rerouting the tank that did
                      the work is often not the one you named:
                        {ok, engine, tank, artifact, artifact_bytes, reason,
                         reset, rerouted_from[], elapsed_s, run_id}
                      `artifact_bytes` is the artifact's own measurement, so the
                      evidence travels with the verdict.
  --infra-retries <n> retry tool-host infrastructure failures on the SAME tank
                      up to n times (default 2; 0 disables retries).
  --infra-delay <s>   initial retry delay in whole seconds (default 5), doubled
                      for each subsequent retry. --timeout bounds each attempt.
  --no-reroute        on a dry tank, stop instead of falling through.
  --allow-active      let auto-reroute use a tank an interactive session is on,
                      AND (#40) let a burn start on a tank that already has a
                      running burn on it — by default both are refused/skipped:
                      the reserve SKIPS such tanks (rerouting a headless job onto
                      the tank you're mid-conversation on would silently burn
                      that quota, and two burns on one tank collide on the tmux
                      session name) and tanks sharing an already-dry account.

Outcomes: artifact present -> done (exit 0); dry on every reachable tank -> fail;
tool-host failure -> retry the same tank, then reason: infra (exit 1);
no artifact, limit, or infrastructure signal -> a real task failure (NOT rerouted — it'd fail the same
on every tank).

Every burn writes ONE machine-readable status file, updated at every
transition, so a cockpit never has to grep a log for "ran dry" or "[ FAIL ]"
(#41 — those are just as likely to be words from the task's own PROMPT). See
"Status file" in docs/orchestration.md for the path and the field contract.

Examples:
  clikae burn claude L --artifact out/core.test.cjs \
      --prompt-file task.txt --add-dir "$PWD"      # the easy way
  clikae burn codex M --artifact /tmp/out.md \
      --prompt-file task.txt --add-dir /tmp        # same task, different engine, no flag changes
  clikae burn codex M --artifact /tmp/out.md -- exec -C /tmp -s workspace-write \
      "read /tmp/in.txt, write /tmp/out.md"        # the power-user way (raw argv)

burn is the headless sibling of the interactive switch: pre-stage inputs to /tmp
(never hand a tank slow iCloud-backed I/O), and make tasks idempotent + artifact-
checked so a dropped one just re-fires elsewhere.

Boundary: burn only fits tasks whose success is a FILE you can name — codegen,
analysis, transforms. It CANNOT judge work whose proof is runtime behaviour (a UI
renders, a server answers); that still needs a human to verify.

Dry-detection leans on each vendor's CURRENT limit wording. If a vendor rewords
it, a dry tank would be misread as a real task failure (no reroute). Set
$CLIKAE_LIMIT_PATTERN='<regex>' to teach burn a new phrase (same override clikae
watch honours).

Re-firing the same task on another account sits in the vendors' terms gray
zone — where the line is, with the actual policy language and dates:
docs/terms-and-your-accounts.md (shown once before your first carry).
EOF
}

# Infrastructure signatures must name the tool host: a generic timeout can be
# a task failure and must not spend another attempt automatically. This is a
# hand-written whitelist, not a real-corpus one like limit.sh's 175-line
# fixture (P2-5, 2026-09-08 review) — five plausible real tool-host failure
# sentences all NO-MATCHED, one by a single word ("waiting" vs "negotiating").
# Widened to cover more real phrasings of the same four shapes (a timeout/
# failure/closed-connection/disconnect NAMING the tool host) without
# loosening the "must name the host" discipline that keeps this from becoming
# a P1-2-style generic-timeout catcher.
#
# P1-2 (2026-09-08 round-2 review): the widening above turned the two
# "host <gap> verb" alternatives into a prose catcher — `[^."]*` has no upper
# bound, so ANY sentence that happens to mention "tool host" and, later in
# the same period-free run, one of the failure verbs fired (e.g. "the tool
# host section of the runbook explains why our Redis connection closed",
# PROBE C-live in the review). Every real shape in the corpus — this round's
# and the last — has the verb within a handful of characters of "host" (a
# single connecting word like "was"/"'s", never a clause); bounding the gap
# to 6 chars keeps every real corpus row matching while rejecting prose that
# merely mentions the host somewhere upstream of an unrelated failure.
_burn_output_infra() {
  # P2-1 (2026-09-08 round-4 review): a here-string, not a pipe from a
  # separate `printf` process — see limit_codex_reset's comment for why a
  # pipe risks hanging on a large, untruncated haystack. This one has no
  # early-exit flag (no `-q`/`-m1`) so it was never actually exposed to that
  # specific hang, but it reads the SAME out_for_class a large capture can
  # now carry, so it gets the same safer plumbing on general principle.
  grep -aiE 'timed out (negotiating with|waiting for|connecting to) (the )?(code[ -]mode|tool)[ -]host|(failed|unable) to (connect to|establish (a )?connection (with|to)|reach) (the )?(code[ -]mode|tool)[ -]host|error (connecting to|reaching) (the )?(code[ -]mode|tool)[ -]host|(code[ -]mode|tool)[ -]host[^."]{0,6}(connection (closed|refused|lost|timed out)|disconnected|handshake failed|exited unexpectedly|is (unreachable|unavailable))|connection to (the )?(code[ -]mode|tool)[ -]host[^."]{0,6}(closed|refused|timed out|lost)|mcp server "[^"]*(code[ -]mode|tool)[^"]*" connection (closed|refused|lost|reset)' <<< "$1" >/dev/null
}

# _burn_redact <text> [replacement] -> <text> with the task's own content
# taken out (or swapped for <replacement>, default empty) — whichever
# dispatch form supplied it. P1-1 (2026-09-08 round-2 review): the previous
# redaction only ever looked at $prompt, which is UNSET for the raw
# `-- <engine argv...>` form ("the power-user way" — AGENTS.md's front door
# and docs/orchestration.md both document it) — so an engine echoing its own
# argv back on stdout sailed through unredacted on that path (PROBE B: two
# extra full engine calls, a leaked task-text tail, and the wrong `reason`).
# $cmd holds the raw argv for that form and is never reassigned by a
# cross-engine reroute (unlike --prompt mode's regenerated flags), so
# looping over it stays correct across the whole retry loop. Whichever form
# supplied the task, exactly one of $prompt / $cmd is populated at any call
# site, so checking $prompt first is enough to pick the right one.
#
# P1-2 (2026-09-08 round-3 review): bash's ${text//needle/repl} is
# super-linear in the haystack's size, so redacting the WHOLE captured
# output cost tens of seconds to minutes of pure bash string time AFTER the
# engine had already exited — no progress output, outside --timeout's reach
# (it bounds the engine, not this). Measured on an 8 MB capture: 1MB/4MB/8MB
# single-pass costs of 382ms/5125ms/20209ms, and end-to-end ×23 (--prompt
# form) to ×129 (raw argv, four minutes) versus a main-branch clone on the
# same stub. burn's own purpose — long, unattended tasks — produces exactly
# the large captures this is slowest on. The classifiers only need the
# FINAL message anyway (limit.sh's own doc: "a genuine vendor sentence IS
# the line, or leads it"), so bound the haystack to its own tail before
# ever substituting into it — this is what P2-1's boundary/length fix below
# also relies on to stay fast.
_BURN_REDACT_TAIL_BYTES=${_BURN_REDACT_TAIL_BYTES:-65536}

# P2-1 (2026-09-08 round-3 review): the raw `-- <argv>` form redacted every
# item of $cmd with NO minimum length and no word boundary — argv is full of
# short tokens (`exec` `-C` `.` `-s` `workspace-write`), and each one got
# blindly stripped out of the engine's ENTIRE reply. A day-to-day `-C .`
# deleted every period in the reply, merging two sentences into one and
# flipping "a real task failure" into "infra" (the tool-host bounded-gap
# pattern only holds because a period normally separates unrelated
# sentences); a short task string like `"hit"` shredded a genuine
# "…hit your usage limit…" line into unrecognizable pieces. Short flags and
# path fragments are not "the task's own text echoed back" — redacting them
# buys no privacy and only corrupts unrelated prose. Below this length,
# skip the item entirely; at or above it, replace only BOUNDARY-safe
# occurrences (the byte immediately before/after the match, if any, is not
# itself a word character) — plain substring search, not regex, so a
# needle full of shell/path metacharacters is never mis-parsed.
_BURN_REDACT_MIN_LEN=${_BURN_REDACT_MIN_LEN:-20}

# P1-3 (2026-09-08 round-5 review): round-4's P2-1 fix (below this comment)
# made classification read the UNTRUNCATED capture, which put the awk loop's
# per-match `substr(t, i)` back on the hook for every byte of a multi-MB
# reply — and that copy is taken once PER MATCH, not once total, so a dense
# needle (burn's own PROMPT or a repeated argv path, exactly what long
# unattended tasks echo back a lot of) reopened round-3's P1-2 in a new
# shape: O(matches × remaining-length) instead of O(capture-size). Measured
# on this machine: a 4 MB capture with the needle on every line (53774
# hits) took 26.5s, quadratic in the hit count (doubling MB ~4x'd the time).
# Reworking the awk loop to avoid the copy (`split()`, `gsub()`) does not
# help THIS awk (macOS's BWK build, `awk version 20200816`): raw `split()`
# alone on 300000 matches took 55s CPU — the slowdown lives in its
# many-match path generally, not in this loop's shape specifically.
#
# A SEPARATE, bigger cost hid behind that one: whichever tool does the
# substitution, `_burn_redact_full` used to invoke it ONCE PER ARGV ITEM
# (below), reassigning `text` through a bash command substitution each
# time — even for items too short to redact. bash 3.2 (macOS's own
# `/bin/bash`) turns out to be the real bottleneck for a multi-MB haystack:
# measured, six bare pass-throughs of an 8 MB string via `local t="$1"` +
# `printf '%s' "$t"` inside `$( )` took 75s — no awk or perl involved at
# all. A raw `-- <argv>` task commonly has 2+ items at or above the minimum
# length (a long `-C <path>` plus the task string itself), so this fired on
# every dense-capture burn regardless of which substitution engine was
# fixed. The fix is to stop reassigning `text` per item: gather every
# qualifying needle first, then make exactly ONE pass over the haystack
# (`perl` builds one alternation of all of them; that regex engine is
# linear in matches — 0.11s CPU on a 300000-match input, 0.04s on the
# 53774-hit/7 MB case — and is already an accepted dependency here,
# `_burn_timeout_bin` falls back to it for `--timeout`). The no-perl
# fallback below still loops per item (rare path, correct but slower).
_BURN_REDACT_NEEDLE_SEP=$'\001'   # SOH — see the RS comment on the awk fallback for why not NUL

_burn_redact_one_awk() {
  local text="$1" needle="$2" repl="$3"
  # P2-1 (2026-09-08 round-4 review): the haystack used to travel through
  # ENVIRON (an exported env var), which is what forced the 64 KiB
  # truncation below in the first place — a multi-MB capture in an env var
  # risks E2BIG. Feed it over stdin instead, with RS set to a byte that
  # never splits it, so the whole capture arrives as ONE record; only the
  # small needle/repl still go through ENVIRON.
  #
  # P1-2 (2026-09-08 round-5 review): RS="\x00" was that byte, on the theory
  # that bash strings are NUL-free so it could never appear in $text. False
  # on macOS's own /usr/bin/awk (BWK awk, `awk version 20200816`): its RS
  # cannot HOLD a NUL byte at all, and a "\x00" value silently collapses to
  # RS="" — awk's PARAGRAPH-mode sentinel — not "no separator". A capture
  # with a blank line (routine engine output formatting) then arrived as
  # MULTIPLE records glued back together by `printf "%s"` below with no
  # separator at all: "Working on it.\n\nYou've hit your usage limit\n\nBye."
  # became "Working on it.You've hit your usage limitBye." — destroying the
  # `^` line anchors both classifiers rely on (a real limit line stopped
  # matching) and fabricating brand-new ones (two sentences fused at a blank
  # line could spell a false infra match). Verified on this machine: `awk
  # 'BEGIN{RS="\x00"}{print NR}' ` on a 3-blank-line-separated file reports
  # NR=3, not 1. "\001" (SOH) is an ordinary byte, not the string
  # terminator, so no awk implementation needs to special-case it — verified
  # NR=1 on the same input. It is not impossible for an engine to emit a raw
  # SOH byte, but it is not the C-string terminator every string primitive
  # already treats specially, which NUL is.
  printf '%s' "$text" | RNEEDLE="$needle" RREPL="$repl" awk '
    BEGIN {
      RS = "\001"
      n = ENVIRON["RNEEDLE"]; r = ENVIRON["RREPL"]
      nlen = length(n)
    }
    {
      t = $0; tlen = length(t)
      out = ""; i = 1
      while (i <= tlen) {
        p = index(substr(t, i), n)
        if (p == 0) { out = out substr(t, i); break }
        start = i + p - 1; endc = start + nlen - 1
        before = (start > 1)   ? substr(t, start - 1, 1) : ""
        after  = (endc < tlen) ? substr(t, endc + 1, 1)  : ""
        ok = 1
        if (before != "" && before ~ /[A-Za-z0-9_]/) ok = 0
        if (after  != "" && after  ~ /[A-Za-z0-9_]/) ok = 0
        out = out substr(t, i, start - i) (ok ? r : substr(t, start, nlen))
        i = endc + 1
      }
      printf "%s", out
    }'
}

# _burn_redact_full <text> [replacement] -> <text> with the task's own
# content taken out, over the WHOLE haystack, no truncation.
#
# P2-1 (2026-09-08 round-4 review): _burn_redact (below) truncated to the
# tail BEFORE substituting, which — since P1-2's fix made the substitution
# an O(n) awk pass instead of bash's super-linear ${text//…} — was no longer
# needed to keep substitution fast, but it was still unconditionally in the
# path CLASSIFICATION reads (`out_for_class` in cmd_burn), so any dry/infra
# signal past the last 64 KiB went blind: a task's own tool-host failure,
# typically mid-run since the engine keeps talking afterward, drifts exactly
# there on a long capture — burn's whole reason to exist. Substitution
# staying bounded is fine; classification silently narrowing its view is
# not. Split the two: this variant never truncates, and is what feeds the
# classifiers. _burn_redact still truncates, but only for the short
# human-facing diagnostic tail below, where a bound is genuinely harmless.
#
# P1-3 (2026-09-08 round-5 review): gather every needle at/above the
# minimum length FIRST, then substitute all of them in exactly ONE pass
# over `text` (one `perl`/`awk` invocation, one command substitution) —
# see the cost comment above `_burn_redact_one_awk` for why looping this
# per argv item was the actual bottleneck, independent of which tool did
# the matching. $prompt is always a single item (and may be genuinely
# multi-line, e.g. a `--prompt-file` task echoed back verbatim) so it skips
# the multi-needle join entirely — joining/splitting on SOH would still be
# safe (a raw SOH in a needle is exactly as unlikely, and exactly as
# tolerated, as the awk fallback's RS byte above), but there is no reason
# to pay for it when there is only one needle.
_burn_redact_full() {
  local text="$1" repl="${2:-}"
  local -a needles=()
  if [ -n "${prompt:-}" ]; then
    [ "${#prompt}" -ge "$_BURN_REDACT_MIN_LEN" ] && needles=("$prompt")
  else
    local c
    for c in "${cmd[@]}"; do
      [ "${#c}" -ge "$_BURN_REDACT_MIN_LEN" ] && needles+=("$c")
    done
  fi
  [ "${#needles[@]}" -gt 0 ] || { printf '%s' "$text"; return 0; }
  if command -v perl >/dev/null 2>&1; then
    local needle_list; needle_list="$(printf "%s${_BURN_REDACT_NEEDLE_SEP}" "${needles[@]}")"
    # -0777 slurps the whole input as one string (undef $/), so a needle
    # spanning multiple lines still matches as one unit. \Q..\E (via
    # quotemeta) makes every needle a literal, never a regex — a path full
    # of `.`/`/` must never be parsed as one. The lookaround pair is the
    # same boundary rule as the awk fallback's before/after byte check,
    # native instead of hand-rolled: a word character on either side means
    # "not a citation of the task's own text", so leave it alone. Perl's
    # backtracking tries each alternative in order and only commits once
    # the trailing lookahead also holds, so a needle that is a PREFIX of
    # another (rare, but possible across several argv items) still resolves
    # to the longest real match at that position rather than a truncated
    # one. $r is substituted as a whole Perl SCALAR, never re-parsed for
    # `$`/`@`/backslash escapes of its own content.
    printf '%s' "$text" | RNEEDLES="$needle_list" RREPL="$repl" RSEP="$_BURN_REDACT_NEEDLE_SEP" perl -0777 -pe '
      BEGIN {
        $r = $ENV{"RREPL"};
        my @ns = split /\Q$ENV{"RSEP"}\E/, $ENV{"RNEEDLES"};
        $pat = join("|", map { quotemeta($_) } @ns);
      }
      s/(?<![A-Za-z0-9_])(?:$pat)(?![A-Za-z0-9_])/$r/g if length($pat);
    '
    return 0
  fi
  local n
  for n in "${needles[@]}"; do
    text="$(_burn_redact_one_awk "$text" "$n" "$repl")"
  done
  printf '%s' "$text"
}

_burn_redact() {
  local text="$1" repl="${2:-}"
  if [ "${#text}" -gt "$_BURN_REDACT_TAIL_BYTES" ]; then
    text="$(printf '%s' "$text" | tail -c "$_BURN_REDACT_TAIL_BYTES")"
  fi
  _burn_redact_full "$text" "$repl"
}

# Redact an engine's exact echo of the task BEFORE taking a diagnostic tail.
# Raw engine output stays in its capture log; burn's progress never repeats
# the task, on either dispatch form (see _burn_redact).
_burn_output_tail() {
  local text="$1" lines="${2:-5}"
  [ -n "${saved_prompt:-}" ] && text="$(_burn_redact "$text" "[prompt: $saved_prompt]")"
  printf '%s\n' "$text" | tail -n "$lines" | sed 's/^/    /'
}

# _burn_next_same_engine <cli> <tried> <dried_accts> <envvar> <allow_active>
# The next same-engine tank to reroute a dry burn onto, in listing order — but the
# reserve is no longer naive (the 2026-06-04 "burn-out" dogfood):
#   · P0 — SKIP a tank an INTERACTIVE session is live on (live_dir_users finds a proc
#     holding <envvar>=<tank dir>). Rerouting a headless job onto the tank you're
#     using right now silently burns the quota you're mid-conversation on. Pass
#     allow_active=1 to override.
#   · P1 — SKIP a tank whose ACCOUNT is one we already dried (<dried_accts>, newline-
#     joined): same login = same quota = already dry, so hopping there is wasted.
# Echoes the tank name, or nothing when the reserve is exhausted. Note: log_warn
# writes to stderr, so a skip notice can't corrupt this function's captured stdout.
_burn_next_same_engine() {
  local cli="$1" tried="$2" dried_accts="$3" envvar="$4" allow_active="$5" t tdir tacct
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case " $tried " in *" $cli/$t "*) continue ;; esac
    tank_is_solo "$cli" "$t" && continue   # solo tanks are out of the fleet — never an auto-reroute target
    tdir="$(profile_dir "$cli" "$t")"
    if [ "$allow_active" != "1" ] && [ -n "$envvar" ] \
       && [ -n "$(live_dir_users "$tdir" "$envvar" 2>/dev/null)" ]; then
      log_warn "skipping $cli/$t — an interactive session is using it (burn would spend that quota; --allow-active to override)."
      continue
    fi
    if [ -n "$dried_accts" ]; then
      tacct="$(_limit_tank_account "$cli" "$t" 2>/dev/null || true)"
      if [ -n "$tacct" ] && printf '%s\n' "$dried_accts" | grep -qxF "$tacct"; then
        log_warn "skipping $cli/$t — same account as a tank already dry (shared quota)."
        continue
      fi
    fi
    # P2 (#40) — SKIP a tank that already has a RUNNING burn on it, per #41's
    # status files (never tmux session names: two burns on one tank collide
    # on the tmux session name before either gets far enough to prove
    # anything from tmux). $$ excludes the tank THIS burn is on right now,
    # which would otherwise appear busy on its own account.
    if [ "$allow_active" != "1" ] && burn_tank_busy "$cli" "$t" "$$"; then
      log_warn "skipping $cli/$t — another burn is already running on it (#40; --allow-active to override)."
      continue
    fi
    printf '%s\n' "$t"; return 0
  done <<EOF
$(list_all_profiles | awk -F'\t' -v c="$cli" '$1==c{print $2}')
EOF
}

# _burn_timeout_bin -> echo `timeout` or `gtimeout` if one is on PATH; otherwise echo
# NOTHING and warn that the run will be UNBOUNDED. Factored out so the "no tool →
# honest warning, still runs" contract is unit-testable (stock macOS ships neither).
_burn_timeout_bin() {
  if command -v timeout  >/dev/null 2>&1; then printf 'timeout';  return 0; fi
  if command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout'; return 0; fi
  if command -v perl     >/dev/null 2>&1; then printf 'perl';     return 0; fi
  log_warn "--timeout needs \`timeout\`/\`gtimeout\` (coreutils) or \`perl\` on PATH — running WITHOUT a time bound."
  return 0
}

# Artifact freshness uses _clikae_mtime (lib/core/adapter_loader.sh) — epoch mtime,
# 0 if absent, GNU-stat-first for Linux portability — so a STALE file from a prior
# run can't be mistaken for this run's success (2026-06-06 tugtile dogfood #2).
# Whole-second resolution; a same-second overwrite is invisible (--fresh sidesteps it).

# _burn_size <path> -> byte count, or "?" if absent (for the summary line).
_burn_size() {
  if [ -e "$1" ]; then wc -c < "$1" 2>/dev/null | tr -d ' '; else printf '?'; fi
}

# _burn_sweep_old_logs — best-effort retention for burn's own prompt-copy run
# dirs. #43 made every burn write the FULL task text to
# ~/.clikae/logs/burn-<pid>/prompt.txt (0600) so progress/diagnostic tails
# never repeat it — a real privacy win over "it's in a log line" — but the net
# effect was to trade a transient exposure for a PERMANENT one: nothing ever
# swept these directories (P2-4, 2026-09-08 review; `clikae clean` has no
# notion of ~/.clikae/logs at all). One sweep per burn invocation is enough —
# this isn't a daemon and doesn't need to be. $CLIKAE_BURN_LOG_RETENTION_DAYS
# overrides the default (7); 0 disables the sweep (kept forever, old
# behaviour). Best-effort: a `find`/`rm` failure never aborts the burn itself.
_burn_sweep_old_logs() {
  local base="$HOME/.clikae/logs" days="${CLIKAE_BURN_LOG_RETENTION_DAYS:-7}"
  case "$days" in ''|*[!0-9]*) return 0 ;; esac
  [ "$days" -gt 0 ] || return 0
  [ -d "$base" ] || return 0
  local d
  while IFS= read -r -d '' d; do
    rm -rf "$d" 2>/dev/null || true
  done < <(find "$base" -maxdepth 1 -type d -name 'burn-*' -mtime "+$days" -print0 2>/dev/null)
}

# Capture evidence beside the engine, before publishing completion. Consumers
# may move/delete the artifact as soon as they see DONE; the parent must never
# re-stat it to reconstruct an earlier outcome. Publish the pair atomically.
_burn_snapshot() {
  local artifact="$1" before="$2" evidence="$3" fresh=0 bytes=null
  if [ -e "$artifact" ]; then
    bytes="$(_burn_size "$artifact")"
    [ "$(_clikae_mtime "$artifact")" = "$before" ] || fresh=1
  fi
  case "$bytes" in ''|*[!0-9]*) bytes=null ;; esac
  printf '%s %s\n' "$fresh" "$bytes" > "$evidence.tmp"
  mv -f "$evidence.tmp" "$evidence"
}

# _burn_compose <prompt> <post_cmd_count> <post_cmd...> -- <add_dir...>
# Build the full engine argv into the global array BURN_ARGV: the per-engine
# headless-write flags from adapter_burn_flags (which must be defined for the
# CURRENTLY-loaded adapter), followed by any verbatim post-`--` argv. Called once
# per engine so a cross-engine reroute regenerates the flags for the NEW engine
# (fixing the old "ship claude's -p flags to codex" unsoundness). Newline-per-item
# read keeps a multi-line prompt with spaces intact.
_burn_compose() {
  local prompt="$1"; shift
  local n="$1"; shift
  local -a post=(); local i
  for ((i=0; i<n; i++)); do post+=("$1"); shift; done
  shift   # drop the literal "--" separator
  BURN_ARGV=()
  local line
  # NUL-delimited read so a multi-line prompt survives as a single argv item.
  while IFS= read -r -d '' line; do BURN_ARGV+=("$line"); done < <(adapter_burn_flags "$prompt" "$@")
  BURN_ARGV+=("${post[@]}")
}

# _agy_burn <starting-tank> <prompt> <artifact> <timeout_s> <fresh> <reroute>
#           <n_extra> <extra-agy-flags...> <add_dirs...>
# The extras are whatever followed `--` on the command line. agy has no adapter,
# so clikae cannot compose its flags for you; what it CAN do is stop dropping the
# ones you asked for. Two that headless dispatch actually needs:
#   --dangerously-skip-permissions   agy's print mode auto-denies file tools, so
#                                    without this a burn can read but never write
#   -c / --conversation <id>         continue a previous run instead of starting cold
# Counted rather than sentinel-delimited because add_dirs is already a variadic
# tail and a second `--` inside argv is exactly the ambiguity this is fixing.
# agy's own burn loop. agy has no adapter (no per-shell env; one global
# ~/.gemini symlink), so it can't go through cmd_burn's adapter-driven engine
# loop below — this is a dedicated SEQUENTIAL dry→next-tank loop, reusing the
# read-only headless recipe + cli.log dry-detection from
# lib/commands/conduct.sh's _conduct_one_agy, and the Keychain carry from
# lib/commands/antigravity.sh (now that a tank switch is non-interactive, this
# can drive it programmatically instead of refusing outright — see 32507a8's
# revert). Only sequential: agy can't run two tanks in parallel (one global
# active tank), so unlike other engines' burn there's no cross-terminal safety
# concern from an interactive session being mid-use on a DIFFERENT tank — this
# still moves the ONE global active tank, same as `clikae agy <tank>` always has.
_agy_burn() {
  local start_tank="$1" prompt="$2" artifact="$3" timeout_s="$4" fresh="$5" reroute="$6" n_extra="$7"; shift 7
  local -a extra=()
  while [ "$n_extra" -gt 0 ]; do extra+=("$1"); shift; n_extra=$((n_extra - 1)); done
  local -a add_dirs=("$@")

  if [ "$fresh" -eq 1 ] && [ -e "$artifact" ]; then
    rm -f "$artifact" 2>/dev/null
    if [ -e "$artifact" ]; then log_warn "--fresh could not remove $artifact (judging by timestamp instead)."
    else log_info "--fresh: cleared $artifact"; fi
  elif [ -e "$artifact" ]; then
    log_warn "artifact already exists: $artifact — judging success by a timestamp change (use --fresh for a clean slate)."
  fi
  local art_pre; art_pre="$(_clikae_mtime "$artifact")"
  local t0=$SECONDS

  local cur="$start_tank" tank_count; tank_count="$(_agy_tank_names | grep -c . || true)"
  local -a agy_tried=("$start_tank")
  local tried=""   # "agy/<tank>"-per-hop, mirrors cmd_burn's own $tried — feeds #41's rerouted_from
  while :; do
    [ -d "$(_agy_slots)/$cur" ] || log_fail "No such agy tank: $cur  (create it:  clikae init agy $cur)"
    if [ "$cur" != "$(_agy_active)" ]; then
      log_info "burn agy/$cur → switching (Keychain carry, no OAuth needed since 2026-07-05)"
      _agy_assert_not_running
      local active; active="$(_agy_active)"
      [ -n "$active" ] && _agy_kc_stash "$active"
      _agy_kc_restore "$cur"
      _agy_kc_verify_restore "$cur"
      rm -f "$(_agy_link)"; ln -s "$(_agy_slots)/$cur" "$(_agy_link)"
    fi
    log_info "burn agy/$cur → agy (task: $saved_prompt)"
    _burn_status_write running null "$status_engine" "$cur" "$artifact" "" ""

    # Give THIS run its own log. agy's ~/.gemini/antigravity-cli/cli.log is a
    # symlink shared by every agy process on the tank, repointed by whichever
    # one started last — so reading it after our run can pick up an INTERACTIVE
    # session's quota event and blame it on us. Measured 2026-08-11: the same
    # request came back "ran dry" once and fine twice, while our own log carried
    # zero markers and two long-lived session logs carried 15 and 2.
    # --log-file leaves the shared symlink untouched (verified: readlink before
    # == after), so this neither reads nor disturbs anyone else's run.
    local runlog; runlog="$(mktemp "${TMPDIR:-/tmp}/clikae-agy-log.XXXXXX")"
    local -a gen=(-p "$prompt" --log-file "$runlog") d
    for d in "${add_dirs[@]}"; do gen+=(--add-dir "$d"); done
    # agy enforces its OWN print budget, default 5 minutes, and it does not know
    # about clikae's --timeout. Without this, `burn agy --timeout 1200` was a
    # fiction: agy self-terminated at 5m and clikae's outer bound never applied.
    # Only passed when the user actually asked for a budget — clikae has no
    # business inventing one.
    [ -n "$timeout_s" ] && gen+=(--print-timeout "${timeout_s}s")
    # Yours last, so an explicit flag beats clikae's default for the same option.
    [ "${#extra[@]}" -gt 0 ] && gen+=("${extra[@]}")
    local -a runner=()
    if [ -n "$timeout_s" ]; then
      local tb; tb="$(_burn_timeout_bin)"
      case "$tb" in
        timeout|gtimeout) runner=("$tb" "$timeout_s") ;;
        perl)             runner=(perl -e 'alarm shift; exec @ARGV or exit 127' "$timeout_s") ;;
      esac
    fi
    local evidence_file; evidence_file="$(mktemp "${TMPDIR:-/tmp}/clikae-agy-artifact.XXXXXX")"
    local artifact_fresh=0 artifact_bytes_snapshot=null
    art_pre="$(_clikae_mtime "$artifact")"
    local out; out="$(
      "${runner[@]}" agy "${gen[@]}" </dev/null 2>&1 || true
      _burn_snapshot "$artifact" "$art_pre" "$evidence_file"
    )" || true
    read -r artifact_fresh artifact_bytes_snapshot < "$evidence_file"
    rm -f "$evidence_file"

    # Consume the run log once, then drop it on every path below — not just the
    # dry one — so a long reroute loop doesn't litter $TMPDIR.
    local reset dry=1
    reset="$(limit_log_dry "$runlog")" && dry=0
    rm -f "$runlog"
    if [ "$dry" -eq 0 ]; then
      log_warn "agy/$cur ran dry${reset:+  — }${reset}"
      _burn_status_write dry false "$status_engine" "$cur" "$artifact" "tank ran dry" "$reset"
    elif [ "$artifact_fresh" -eq 1 ]; then
      log_done "Done on agy/$cur — artifact present at engine exit: $artifact"
      _burn_status_write "done" true "$status_engine" "$cur" "$artifact" "artifact produced" ""
      _burn_result true agy "$cur" "$artifact" "artifact produced"
      log_info "summary: tank=agy/$cur  reroutes=$((${#agy_tried[@]} - 1))  elapsed=$((SECONDS - t0))s  artifact=${artifact_bytes_snapshot}B"
      return 0
    elif printf '%s' "$out" | grep -qi "no output produced"; then
      # agy REFUSED and said so. It exits 0 either way (verified 2026-07-27), and
      # its refusal arrives on the same stdout an answer would — so capturing
      # stdout blindly turned "the tool declined" into a DONE row with the
      # decline text sitting in the artifact. That is a false success, which is
      # worse than the honest failure it replaced; caught within the hour by
      # dogfooding this very path. `no output produced` is agy telling us it
      # yielded nothing — a status claim, not prose about an answer, and the
      # closest thing to a structured marker it offers.
      log_err "agy/$cur declined the task — nothing was produced."
      _burn_status_write fail false "$status_engine" "$cur" "$artifact" "agy declined the task" ""
      _burn_output_tail "$out" 3
      log_dim  "agy's headless mode auto-denies file tools on your paths. Fence the task so it needs none (answer from the prompt text, print the answer), or run it yourself with the permission you're willing to grant."
      log_info "summary: tank=agy/$cur  reroutes=$((${#agy_tried[@]} - 1))  elapsed=$((SECONDS - t0))s  artifact=none"
      return 1
    elif [ -n "$out" ]; then
      # burn's contract is "the artifact proves it happened". agy's headless mode
      # AUTO-DENIES the file tools on your paths — it cannot prompt for
      # permission with no terminal — so asking agy to write the artifact itself
      # fails 100% of the time, and did (field report 2026-07-27). The two
      # contracts are incompatible, but only in who holds the pen: agy prints
      # perfectly well, and clikae already had the output in hand for its error
      # tail. So clikae writes it.
      #
      # Deliberately NOT the alternatives: adding an allow-rule to the user's agy
      # settings would have clikae widen an engine's permissions on their behalf
      # (the same line `--dangerously-skip-permissions` sits on), and refusing
      # --artifact outright would remove the only verification burn has.
      if printf '%s\n' "$out" > "$artifact" 2>/dev/null; then
        artifact_bytes_snapshot="$(_burn_size "$artifact")"
        log_done "agy/$cur finished — clikae captured its output into: $artifact"
        _burn_status_write "done" true "$status_engine" "$cur" "$artifact" "clikae captured stdout into the artifact" ""
        _burn_result true agy "$cur" "$artifact" "clikae captured stdout into the artifact"
        log_dim  "CAPTURED, NOT VERIFIED. For claude/codex the artifact is proof the ENGINE did the work; here clikae only relocated whatever agy printed. Read the file before you trust it — a large answer may be the pointer agy printed rather than the content it buffered into its own brain dir."
        log_info "summary: tank=agy/$cur  reroutes=$((${#agy_tried[@]} - 1))  elapsed=$((SECONDS - t0))s  artifact=${artifact_bytes_snapshot}B"
        return 0
      fi
      log_err "agy/$cur produced output but clikae could not write $artifact"
      _burn_status_write fail false "$status_engine" "$cur" "$artifact" "clikae could not write the artifact" ""
      log_info "summary: tank=agy/$cur  reroutes=$((${#agy_tried[@]} - 1))  elapsed=$((SECONDS - t0))s  artifact=none"
      return 1
    else
      log_err "agy/$cur produced NOTHING and shows no limit — a real task failure, not a dry tank."
      _burn_status_write fail false "$status_engine" "$cur" "$artifact" "engine produced nothing and showed no limit" ""
      _burn_result false agy "$cur" "$artifact" "engine produced nothing and showed no limit"
      log_dim  "agy buffers a large answer into its own brain dir and can print nothing at all; a silent run is not proof it did no work — check ~/.gemini/antigravity-cli/brain/ before re-firing."
      _burn_output_tail "$out"
      log_info "summary: tank=agy/$cur  reroutes=$((${#agy_tried[@]} - 1))  elapsed=$((SECONDS - t0))s  artifact=none"
      return 1
    fi

    [ "$reroute" -eq 1 ] || {
      log_info "Dry, and --no-reroute is set. Stopping."
      _burn_status_write dry false "$status_engine" "$cur" "$artifact" "tank ran dry and --no-reroute is set" "${reset:-}"
      _burn_result false "$cli" "$cur" "$artifact" "tank ran dry and --no-reroute is set" "${reset:-}"
      return 1
    }
    # `|| true`: under `set -e -o pipefail`, grep exiting 1 (every tank already
    # tried — nothing left to select) would otherwise abort the script here
    # instead of falling through to the "all dry" log_fail below.
    local nxt; nxt="$(_agy_tank_names | grep -vxF -f <(printf '%s\n' "${agy_tried[@]}") | head -1)" || true
    if [ -z "$nxt" ]; then
      _burn_status_write dry false "$status_engine" "$cur" "$artifact" "every reachable tank is dry" "${reset:-}"
      log_fail "All $tank_count agy tank(s) are dry — nothing left after: ${agy_tried[*]}. Add a tank (clikae init agy <name>) or wait for a reset."
    fi
    agy_tried+=("$nxt")
    tried="${tried:+$tried }agy/$cur"
    cur="$nxt"
    log_info "Rerouting (dry) → agy/$cur"
  done
}

# _burn_result <ok> <engine> <tank> <artifact> <reason> [reset-phrase]
#
# 🔴 AGENTS.md's first non-negotiable rule is "judge by the artifact/output,
# never the exit code" — and until 2026-08-16 clikae made an agent read that
# judgement out of PROSE. `burn` is the dispatch shape an agent uses most, and
# the one whose outcome is least guessable: with rerouting, the tank that
# actually did the work is often not the one you named, and the only record of
# which was a sentence on stdout.
#
# The data was already there (the `summary:` line has tank, reroutes, elapsed
# and artifact size). This just says it in a form nothing has to parse by eye.
#
# `artifact_bytes` is the point: rule 1 says judge by the artifact, so the
# artifact's own measurement travels with the verdict rather than being a second
# call the caller has to remember to make.
_burn_result() {
  [ "${as_json:-0}" -eq 1 ] || return 0
  local ok="$1" eng="$2" tk="$3" art="$4" reason="$5" reset="${6:-}"
  local bytes=null
  if [ -n "${artifact_bytes_snapshot:-}" ]; then
    bytes="$artifact_bytes_snapshot"
  elif [ -n "$art" ] && [ -e "$art" ]; then
    bytes="$(_burn_size "$art")"
  fi
  printf '{"ok":%s,"engine":%s,"tank":%s,"artifact":%s,"artifact_bytes":%s,"reason":%s,"reset":%s,"rerouted_from":[%s],"elapsed_s":%s,"run_id":%s}\n' \
    "$ok" "$(json_or_null "$eng")" "$(json_or_null "$tk")" "$(json_or_null "$art")" \
    "${bytes:-null}" "$(json_str "$reason")" "$(json_or_null "$reset")" \
    "$(_burn_tried_json "${tried:-}")" "$((SECONDS - ${t0:-SECONDS}))" \
    "$(json_or_null "${run_id:-}")" >&4
}

# `tried` accumulates "engine/tank" words as the reroute walks the reserve.
_burn_tried_json() {
  local w first=1 out=""
  for w in $1; do
    [ "$first" -eq 1 ] || out="$out,"
    out="$out$(json_str "$w")"; first=0
  done
  printf '%s' "$out"
}

# _burn_status_write <state> <ok:true|false|null> <engine> <tank> <artifact>
#                     <reason> [reset]
#
# #41: every burn writes ONE machine-readable status file, updated at every
# transition — run start, each reroute hop, going dry, an infra retry, and the
# terminal outcome — so a cockpit reading it from OUTSIDE this process never
# has to grep a log for "ran dry" or "[ FAIL ]" (both false-positived on a
# task PROMPT that merely contained those words — the incident that opened
# this issue). It lives in the same private, swept run directory burn already
# makes for the task-text copy (`$run_dir`, 0700, `_burn_sweep_old_logs`'s
# retention), as `status.json` — one file per top-level `clikae burn`
# invocation (keyed on `$burn_id`/`$$`), not one per reroute attempt, so a
# caller can watch ONE path across a burn's whole reroute walk.
#
# Same field set as `--json`'s single result object (`{ok, engine, tank,
# artifact, artifact_bytes, reason, reset, rerouted_from[], elapsed_s,
# run_id}`), plus the fields only an outside-the-process reader needs and a
# once-at-exit `--json` object cannot give it: `state`, `started_at`,
# `updated_at`, `pid`, `log`. Written UNCONDITIONALLY (never gated on
# `--json`) — #41 is "every burn", not "every --json burn".
#
# Reads the caller's own locals for everything this signature doesn't carry —
# `run_dir`, `burn_id`, `started_at`, `t0`, `tried`, `log_file`,
# `artifact_bytes_snapshot` — exactly the convention `_burn_result` already
# uses one function up; both are only ever called from inside `cmd_burn` or
# `_agy_burn`, which is what makes bash's dynamic scoping the right tool here
# rather than a footgun.
_burn_status_write() {
  local state="$1" ok="$2" eng="$3" tk="$4" art="$5" reason="$6" reset="${7:-}"
  [ -n "${run_dir:-}" ] || return 0   # called before setup (should not happen) — no-op, never fatal
  local bytes="${artifact_bytes_snapshot:-}"
  if [ -z "$bytes" ] && [ -n "$art" ] && [ -e "$art" ]; then bytes="$(_burn_size "$art")"; fi
  case "$bytes" in ''|*[!0-9]*) bytes=null ;; esac
  local elapsed=$(( SECONDS - ${t0:-SECONDS} ))
  local now; now="$(date +%s 2>/dev/null || echo 0)"
  local f="$run_dir/status.json"
  mkdir -p "$run_dir" 2>/dev/null || true
  {
    printf '{"ok":%s,"engine":%s,"tank":%s,"artifact":%s,"artifact_bytes":%s,"reason":%s,"reset":%s,"rerouted_from":[%s],"elapsed_s":%s,"run_id":%s,"state":%s,"started_at":%s,"updated_at":%s,"pid":%s,"log":%s}\n' \
      "${ok:-null}" "$(json_or_null "$eng")" "$(json_or_null "$tk")" "$(json_or_null "$art")" \
      "${bytes:-null}" "$(json_or_null "$reason")" "$(json_or_null "$reset")" \
      "$(_burn_tried_json "${tried:-}")" "$elapsed" "$(json_or_null "${burn_id:-}")" \
      "$(json_str "$state")" "${started_at:-null}" "$now" "$$" "$(json_or_null "${log_file:-}")"
  } > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null || true
}

cmd_burn() {
  local cli="" tank="" artifact="" to="" timeout_s="" reroute=1 allow_active=0 fresh=0 as_json=0
  local prompt="" prompt_file="" prompt_set=0
  local infra_retries=2 infra_delay=5 infra_attempt=0 retry_delay=5
  local -a cmd=() add_dirs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)    _burn_help; return 0 ;;
      --artifact)   shift; [ $# -gt 0 ] || log_fail "--artifact needs a path"; artifact="$1"; shift ;;
      --to)         shift; [ $# -gt 0 ] || log_fail "--to needs a target"; to="$1"; shift ;;
      --timeout)    shift; [ $# -gt 0 ] || log_fail "--timeout needs seconds"; timeout_s="$1"; shift ;;
      --prompt)     shift; [ $# -gt 0 ] || log_fail "--prompt needs a string"; prompt="$1"; prompt_set=1; shift ;;
      --prompt-file) shift; [ $# -gt 0 ] || log_fail "--prompt-file needs a path"; prompt_file="$1"; shift ;;
      --add-dir)    shift; [ $# -gt 0 ] || log_fail "--add-dir needs a path"; add_dirs+=("$1"); shift ;;
      --infra-retries) shift; [ $# -gt 0 ] || log_fail "--infra-retries needs a count"; infra_retries="$1"; shift ;;
      --infra-delay) shift; [ $# -gt 0 ] || log_fail "--infra-delay needs seconds"; infra_delay="$1"; shift ;;
      --json)       as_json=1; shift ;;
      --no-reroute) reroute=0; shift ;;
      --allow-active) allow_active=1; shift ;;
      --fresh)      fresh=1; shift ;;
      --)           shift; cmd=("$@"); break ;;
      -*)           log_fail "Unknown flag: $1  (try: clikae burn --help)" ;;
      *)            if [ -z "$cli" ]; then cli="$1"
                    elif [ -z "$tank" ]; then tank="$1"
                    else log_fail "Unexpected argument: $1  (put the engine command after --)"; fi
                    shift ;;
    esac
  done

  case "$infra_retries" in ''|*[!0-9]*) log_fail "--infra-retries must be a nonnegative integer" ;; esac
  case "$infra_delay" in ''|*[!0-9]*) log_fail "--infra-delay must be a nonnegative integer" ;; esac
  # Bounds also keep the exponential delay within portable shell arithmetic.
  [ "${#infra_retries}" -le 2 ] && [ "$infra_retries" -le 10 ] || log_fail "--infra-retries must be between 0 and 10"
  [ "${#infra_delay}" -le 5 ] && [ "$infra_delay" -le 86400 ] || log_fail "--infra-delay must be between 0 and 86400"
  infra_retries=$((10#$infra_retries)); infra_delay=$((10#$infra_delay))
  retry_delay="$infra_delay"

  [ -n "$cli" ]      || log_fail "Missing <engine>. Usage: clikae burn <engine> <tank> --artifact <path> (--prompt-file <f> | -- <cmd...>)"
  [ -n "$tank" ]     || log_fail "Missing <tank>."
  [ -n "$artifact" ] || log_fail "Missing --artifact <path> — burn verifies completion by the artifact, never the exit code."

  # --json: ONE object on stdout, every word of progress on stderr. log_done and
  # log_info write to stdout, so without this the result would arrive mixed into
  # the prose it exists to replace. fd 4 is the real stdout, held for the result.
  if [ "$as_json" -eq 1 ]; then
    exec 4>&1
    exec 1>&2
  else
    exec 4>/dev/null
  fi

  # Convenience surface (--prompt / --prompt-file): clikae fills each engine's
  # headless-write flags from its adapter, so the task is just "a prompt + the
  # file it must produce" (2026-06-06 tugtile burn-writeup friction #1).
  [ "$prompt_set" -eq 1 ] && [ -n "$prompt_file" ] \
    && log_fail "Use either --prompt or --prompt-file, not both."
  if [ -n "$prompt_file" ]; then
    [ -r "$prompt_file" ] || log_fail "--prompt-file not readable: $prompt_file"
    prompt="$(cat "$prompt_file")"; prompt_set=1
  fi
  if [ "$prompt_set" -eq 1 ]; then
    # Default the writable dir to the artifact's parent, so the engine can always
    # at least write the file you asked for.
    [ "${#add_dirs[@]}" -ge 1 ] || add_dirs=("$(dirname "$artifact")")
  else
    [ "${#cmd[@]}" -ge 1 ] || log_fail "Give a task: --prompt-file <f> / --prompt <str>, or the explicit -- <cmd...> form."
  fi
  validate_name cli "$cli"
  validate_name profile "$tank"
  # Fall-through armed (the default) means a dry tank re-fires this task on the
  # next account — the cross-account carry case the one-time note is for.
  [ "$reroute" -eq 1 ] && carry_notice_once
  # P2-4: sweep prompt-copy dirs from past runs before adding this run's own.
  _burn_sweep_old_logs
  # Secure the parent before saving the task: validation below can exit before
  # the engine loop gets a chance to set log-directory permissions.
  mkdir -p "$HOME/.clikae/logs"
  chmod 0700 "$HOME/.clikae/logs"
  # Keep a private, stable copy even when the input file is later consumed.
  local run_dir="$HOME/.clikae/logs/burn-$$" saved_prompt task_preview
  mkdir -p "$run_dir"
  chmod 0700 "$run_dir"
  saved_prompt="$run_dir/prompt.txt"
  if [ "$prompt_set" -eq 1 ]; then
    (umask 077; printf '%s' "$prompt" > "$saved_prompt")
    task_preview="${prompt:0:120}"
  else
    # Raw argv has no portable prompt position; retain it as one argument per
    # line rather than guessing an engine-specific option grammar.
    saved_prompt="$run_dir/command.txt"
    (umask 077; printf '%s\n' "${cmd[@]}" > "$saved_prompt")
    task_preview="${cmd[*]}"; task_preview="${task_preview:0:120}"
  fi
  task_preview="${task_preview//$'\n'/ }"; task_preview="${task_preview//$'\r'/ }"
  log_info "task: $saved_prompt"
  log_info "preview: $task_preview"

  # #41: one status file per top-level `clikae burn` invocation, keyed on this
  # process's own pid — stable across the whole reroute walk below, unlike the
  # per-ATTEMPT `run_id` further down (which changes on every reroute/retry).
  # It lives in $run_dir, right beside the task-text copy: same private
  # directory (0700), same retention sweep (_burn_sweep_old_logs already ran
  # above), one thing to find.
  local burn_id="burn-$$" started_at
  started_at="$(date +%s 2>/dev/null || echo 0)"

  # #40: agy is always reported as "agy" (never its "antigravity" alias) in
  # both _burn_result and _agy_burn's own log lines — match that here so a
  # tank looks identical whichever path (busy-check, status file, --json)
  # names it, and a reroute picker on a different engine can never collide
  # with an agy row that used a different spelling of the same engine.
  local status_engine="$cli"
  [ "$status_engine" = antigravity ] && status_engine=agy

  # #40: refuse to START a burn on a tank that already has one running —
  # detected from #41's own status files (a `state: running` row whose pid is
  # still alive), never from tmux session names: two burns on one tank
  # collide on the tmux session name before either gets far enough to prove
  # anything FROM tmux, which is the bug report this closes. --allow-active
  # already means "let this burn use a tank that's otherwise in active use"
  # for the interactive-session guard elsewhere in this file; a running burn
  # is the headless shape of the same thing, so the same flag opts out of both
  # rather than adding a second flag for one more way to say "I know".
  if [ "$allow_active" != "1" ] && burn_tank_busy "$status_engine" "$tank" "$$"; then
    log_fail "$status_engine/$tank already has a running burn on it (#40) — clikae wait <its run id> to block on it, or --allow-active to run anyway (they will collide on the same tmux session)."
  fi

  _burn_status_write running null "$status_engine" "$tank" "$artifact" "" ""

  case "$cli" in
    agy|antigravity)
      _agy_enabled || log_fail "agy multi-account isn't set up yet. Create a tank first:  clikae init agy $tank"
      [ "$prompt_set" -eq 1 ] || log_fail "agy burn only supports the --prompt / --prompt-file form (agy has no adapter to fill in a raw '-- <cmd...>')."
      [ -z "$to" ] || log_fail "--to isn't supported for agy — it walks its own tanks (clikae init agy <name> to add more)."
      # For agy, whatever followed `--` is EXTRA AGY FLAGS, not a raw command:
      # there is no adapter to compose, so `--prompt` still carries the task and
      # these ride alongside it. They used to be parsed and then silently dropped.
      _agy_burn "$tank" "$prompt" "$artifact" "$timeout_s" "$fresh" "$reroute" \
                "${#cmd[@]}" ${cmd[@]+"${cmd[@]}"} ${add_dirs[@]+"${add_dirs[@]}"}
      return $?
      ;;
  esac
  # Keep the verbatim post-`--` argv aside; in --prompt mode it's appended after
  # the engine's generated flags (an escape hatch for extra per-engine args).
  local -a post_cmd=("${cmd[@]}")
  load_adapter "$cli"
  local binary; binary="$(adapter_meta_cli_binary)"
  command -v "$binary" >/dev/null 2>&1 || log_fail "'$binary' is not on PATH."
  local envvar; envvar="$(adapter_meta_env_var 2>/dev/null || true)"   # for the in-use guard
  if [ "$prompt_set" -eq 1 ]; then
    declare -F adapter_burn_flags >/dev/null \
      || log_fail "$cli has no headless-write recipe (adapter defines no adapter_burn_flags). Use the explicit '-- <cmd...>' form."
    _burn_compose "$prompt" "${#post_cmd[@]}" "${post_cmd[@]}" -- "${add_dirs[@]}"
    cmd=("${BURN_ARGV[@]}")
  fi

  # #2 (tugtile dogfood): snapshot the artifact so a STALE file from a prior run
  # isn't mistaken for success. --fresh clears it; otherwise warn + judge by mtime.
  if [ "$fresh" -eq 1 ] && [ -e "$artifact" ]; then
    rm -f "$artifact" 2>/dev/null
    if [ -e "$artifact" ]; then log_warn "--fresh could not remove $artifact (judging by timestamp instead)."
    else log_info "--fresh: cleared $artifact"; fi
  elif [ -e "$artifact" ]; then
    log_warn "artifact already exists: $artifact — judging success by a timestamp change (use --fresh for a clean slate)."
  fi
  local art_pre; art_pre="$(_clikae_mtime "$artifact")"   # 0 when absent
  local t0=$SECONDS

  local cur="$tank" tried="" dried_accts="" reset out rc
  while :; do
    validate_name profile "$cur"
    local dir; dir="$(ensure_profile --require "$cli" "$cur")"

    # soul_prelaunch's contract is "called from every non-ephemeral engine-launch
    # path, AFTER the adapter is loaded", and burn is one — it had no notion of
    # ephemeral at all, so it could not even be the exempt case. Without this, a
    # burn in a directory that has never hosted an interactive session ran with
    # an unlinked memory slot: a memory-less run nobody asked for, when AGENTS.md
    # says the only way to ask for one is --ephemeral. The fleet's MCP servers
    # were missing from headless runs for the same reason.
    #
    # Inside the loop, not above it: burn reroutes to the next tank when one runs
    # dry (and re-loads the adapter for a cross-engine hop at the bottom), so the
    # tank that actually runs is the one that needs its slot linked. Both are
    # no-ops for solo tanks and for slots already linked, so the reroute path
    # pays nothing to be correct.
    #
    # 🔴 2026-09-06: two burns on the SAME tank + SAME $PWD race this preflight
    # unlocked — soul_prelaunch's memory symlink and fleet_mcp_prelaunch's
    # .claude.json mv are both keyed on ($cli/$cur, $PWD), the exact bug class
    # switch.sh's --ephemeral path already fixed for itself (the 2026-07-19
    # incident, see _switch_run_ephemeral's slot_lock above). Serialize on the
    # same key here too — a BLOCKING lock, held only across these two calls,
    # never across the engine run itself: unlike --ephemeral's "one run per
    # slot" hard limit, a second burn here should queue behind the first's
    # symlink/.claude.json settling, not be refused outright.
    local _prelock_dir="$HOME/.clikae/state"
    mkdir -p "$_prelock_dir" 2>/dev/null || true
    chmod 0700 "$_prelock_dir" 2>/dev/null || true
    local _prelock
    _prelock="$_prelock_dir/${CLIKAE_SESS_PREFIX}prelaunch-$(printf '%s' "$cli/$cur:$PWD" | cksum | cut -d' ' -f1).lock"
    local _prelocked=0
    if command -v flock >/dev/null 2>&1; then
      exec 7>"$_prelock"
      flock 7
      _prelocked=1
    elif command -v lockf >/dev/null 2>&1; then
      # `lockf FD` (no command, no -n/-t) blocks indefinitely on the fd itself —
      # macOS has no `flock(1)`, only `lockf(1)`, and the fd form implies -k
      # (man lockf(1)), so this is the direct equivalent of `flock 7` above.
      exec 7>"$_prelock"
      lockf 7
      _prelocked=1
    else
      log_warn "no flock/lockf on this system — running soul/MCP prelaunch unlocked (safe unless another burn targets the same tank+dir right now)."
    fi
    soul_prelaunch "$cli" "$cur" "$dir"        # member tank → fan this dir into its Soul
    fleet_mcp_prelaunch "$cli" "$cur" "$dir"   # non-solo tank → fan in the shared MCP list
    # 🔴 `if`, not `[ … ] && exec …`: under bin/clikae's `set -eo pipefail`, a
    # `&&` whose LEFT side is false (the no-flock/no-lockf fallback, _prelocked=0)
    # makes the whole statement exit 1 — which set -e treats as this function
    # failing, aborting the burn on the very system the fallback exists for.
    if [ "$_prelocked" -eq 1 ]; then exec 7>&-; fi   # release before the (possibly long) engine run

    log_info "burn $cli/$cur → $binary (task: $saved_prompt)"

    # Run headless with the tank's env, stdin CLOSED (the burn-writeup hang lesson:
    # a headless codex can't interrupt its own child if stdin is open), capturing
    # combined output. Optional time bound if a timeout tool is available.
    local -a runner=()
    if [ -n "$timeout_s" ]; then
      local _tbin; _tbin="$(_burn_timeout_bin)"
      case "$_tbin" in
        timeout|gtimeout) runner=("$_tbin" "$timeout_s") ;;
        perl)             runner=(perl -e 'alarm shift; exec @ARGV or exit 127' "$timeout_s") ;;
      esac
    fi
    local run_id="${cli}-${cur}-burn-$$"
    [ "$infra_attempt" -eq 0 ] || run_id="${run_id}-retry${infra_attempt}"
    local log_file="$HOME/.clikae/logs/${run_id}.log"
    local state_file="$HOME/.clikae/state/${run_id}_exit"
    local evidence_file="$HOME/.clikae/state/${run_id}_artifact"
    local artifact_fresh=0 artifact_bytes_snapshot=null
    rm -f "$evidence_file"

    # #41 — this attempt is now the one actually running (first attempt, a
    # reroute hop, or an infra retry all land here); `log` now points at THIS
    # attempt's own capture log, and `rerouted_from` (via `$tried`) already
    # reflects every tank tried before this one.
    _burn_status_write running null "$cli" "$cur" "$artifact" "" ""
    # Lock under $HOME/.clikae/state (0700, created just below), NOT world-writable
    # /tmp: a predictable name there let another local user plant it — as a symlink
    # (truncation) or a plain file the clean GC reads as dead, killing your session
    # and deleting your state files. Private dir closes it (see clean.sh).
    local lock_file="$HOME/.clikae/state/${CLIKAE_SESS_PREFIX}ephem-$run_id.lock"
    
    mkdir -p "$HOME/.clikae/logs" "$HOME/.clikae/state"
    chmod 0700 "$HOME/.clikae/logs" "$HOME/.clikae/state"
    
    art_pre="$(_clikae_mtime "$artifact")"
    rc=0
    if command -v tmux >/dev/null 2>&1; then
      local wrapper_script="$HOME/.clikae/state/${run_id}.sh"

      # THE ENVIRONMENT TRAVELS IN THIS FILE, NOT ON THE COMMAND LINE.
      #
      # A burn inherits the caller's whole environment on purpose — an unattended
      # engine run needs the API keys, proxy settings and PATH the human had. The
      # old shape handed all of it to `tmux new-session` as `-e KEY=VAL` pairs, and
      # those pairs stay in the tmux process's argv. When the burn is what CREATES
      # the server (the common case for an unattended run on a fresh machine) that
      # argv becomes the SERVER's argv and lives as long as the server does —
      # readable by every process on the machine. Measured 2026-08-15: a server
      # born days earlier still listed each `-e` pair it was created with in `ps`.
      #
      # The wrapper is mode 0600 and already exists for the coroner trap, so the
      # environment goes there instead. Create it empty and lock it down BEFORE
      # writing, so there is no window where it is world-readable with secrets in.
      : > "$wrapper_script"
      chmod 0600 "$wrapper_script"
      {
        printf '{\n'
        local key
        for key in $(compgen -e); do
          case "$key" in
            TMUX*) continue ;;   # never inherit: it makes tmux refuse to nest
            # Only well-formed identifiers; anything else cannot be re-exported.
            [!A-Za-z_]*) continue ;;
            *[!A-Za-z0-9_]*) continue ;;
          esac
          printf 'export %s=%q\n' "$key" "${!key}"
        done
        # Readonly builtins in the child would fail loudly and dirty the pane;
        # restoring an environment is best-effort by nature.
        printf '} 2>/dev/null\n'
      } >> "$wrapper_script"

      {
        declare -f _clikae_mtime _burn_size _burn_snapshot
        printf 'artifact=%q\nart_pre=%q\nevidence_file=%q\n' "$artifact" "$art_pre" "$evidence_file"
      } >> "$wrapper_script"
      cat <<EOF >> "$wrapper_script"
while IFS= read -r kv; do [ -n "\$kv" ] && export "\${kv%%=*}"="\${kv#*=}"; done <<'KV'
$(adapter_export_env "$dir")
KV
exec 9> "$lock_file"
if command -v flock >/dev/null 2>&1; then flock -n 9; else lockf -t 0 9; fi
trap 'echo 129 > "$state_file"; exit 129' HUP
trap 'echo 130 > "$state_file"; exit 130' INT
trap 'echo 143 > "$state_file"; exit 143' TERM
trap 'echo \$? > "$state_file"; exit' EXIT
# pipefail so the EXIT trap's \$? is the ENGINE's exit, not tee's (which is always
# 0). Without it the "real task failure (rc=…)" line always printed rc=0 — the
# outcome was still judged by the artifact, but the diagnostic rc was a lie.
set -o pipefail
( engine_rc=0
  $(printf "%q " "${runner[@]}" "$binary" "${cmd[@]}") </dev/null || engine_rc=\$?
  _burn_snapshot "\$artifact" "\$art_pre" "\$evidence_file"
  exit "\$engine_rc"
) 2>&1 | tee "$log_file"
EOF
      chmod 0700 "$wrapper_script"

      # One constructor for every path (lib/core/tmux.sh). This site used a bare
      # `tmux new-session`, so a server it created carried none of clikae's global
      # options — a burn on a fresh machine got tmux's 2000-line default scrollback
      # instead of 50000, and the next `switch` silently repaired it, which is why
      # it went unnoticed. tests/bats/tmux-spawn.bats pins it.
      if tmux_spawn_session \
           --env "CLIKAE_RUN_ID=$run_id" --env "HOME=$HOME" \
           --env "CLIKAE_HOME=$CLIKAE_HOME" \
           --session "${CLIKAE_SESS_PREFIX}$run_id" -- "bash \"$wrapper_script\""; then
        # Wait for completion via state file polling (Coroner trap)
        local poll_int=1
        while [ ! -f "$state_file" ]; do
          sleep $poll_int
          [ "$poll_int" -lt 5 ] && poll_int=$((poll_int + 1))
          if ! tmux has-session -t "=${CLIKAE_SESS_PREFIX}$run_id" 2>/dev/null && [ ! -f "$state_file" ]; then
            # Session vanished without writing state
            echo 255 > "$state_file"
            break
          fi
        done
        rc=$(cat "$state_file" 2>/dev/null || echo 1)
        out="$(cat "$log_file" 2>/dev/null || true)"
        rm -f "$wrapper_script" "$state_file"
      else
        rm -f "$wrapper_script" "$state_file"
        log_warn "tmux failed to start; falling back to direct execution"
        out="$(
          while IFS= read -r kv; do [ -n "$kv" ] && export "${kv%%=*}"="${kv#*=}"; done <<KV
$(adapter_export_env "$dir")
KV
          engine_rc=0
          "${runner[@]}" "$binary" "${cmd[@]}" </dev/null 2>&1 || engine_rc=$?
          _burn_snapshot "$artifact" "$art_pre" "$evidence_file"
          exit "$engine_rc"
        )" || rc=$?
      fi
    else
      out="$(
        while IFS= read -r kv; do [ -n "$kv" ] && export "${kv%%=*}"="${kv#*=}"; done <<KV
$(adapter_export_env "$dir")
KV
        engine_rc=0
        "${runner[@]}" "$binary" "${cmd[@]}" </dev/null 2>&1 || engine_rc=$?
        _burn_snapshot "$artifact" "$art_pre" "$evidence_file"
        exit "$engine_rc"
      )" || rc=$?
    fi
    
    if [ -f "$evidence_file" ]; then
      read -r artifact_fresh artifact_bytes_snapshot < "$evidence_file"
    fi
    rm -f "$state_file" "$evidence_file"

    # P2-1 (2026-09-08 review): the snapshot above is taken the instant the
    # engine's own process exits, inside the same subshell — precise, but
    # narrower than main's pre-#42 behaviour, which re-stat'd the artifact
    # AFTER the parent finished polling the state file for completion. A
    # background child that keeps writing a few hundred ms past the engine's
    # own exit (A/B-measured against a main-branch clone, same stub, same
    # params) landed inside that older window and no longer does — an
    # undocumented narrowing. Restore it as a SECOND look, taken here before
    # anything is classified: if the snapshot wasn't fresh, check the mtime
    # once more right now. This can only ADD a success, never revoke one — a
    # fresh=1 snapshot already means a consumer deleting the artifact right
    # after DONE can't undo it (#42's guarantee still speaks first).
    if [ "$artifact_fresh" -ne 1 ] && [ -e "$artifact" ] && [ "$(_clikae_mtime "$artifact")" != "$art_pre" ]; then
      artifact_fresh=1
      artifact_bytes_snapshot="$(_burn_size "$artifact")"
    fi

    # P1-2 (2026-09-08 review): de-identify the engine's OWN echo of the task
    # BEFORE classifying — not just at display time. _burn_output_tail already
    # redacted the prompt from the DIAGNOSTIC tail, but only after the verdict
    # was already decided; codex and other engines can echo the user's own
    # instructions back on stdout (#43's stub models this: `printf '%s\n'
    # "${@: -1}"`), so a task that merely TALKS ABOUT a limit or a tool-host
    # outage was misread as one. Same redaction _burn_output_tail uses (P1-1,
    # 2026-09-08 round-2 review: now covers the raw `-- <argv>` form too, not
    # only --prompt/--prompt-file — see _burn_redact), run earlier so it
    # protects the classifiers too, not only the display. Computed here,
    # before the artifact check below, so BOTH branches can classify the
    # SAME reply.
    #
    # P2-1 (2026-09-08 round-4 review): this used to call _burn_redact, which
    # truncates to the last 64 KiB before redacting — bounding not just the
    # substitution (fine) but the CLASSIFIERS' entire view of the reply (not
    # fine: a signal past that tail was invisible to both dry and infra
    # detection). Use the untruncated variant here; only the display tail
    # still bounds itself. See _burn_redact_full's comment.
    local out_for_class; out_for_class="$(_burn_redact_full "$out")"

    # P1-1 (2026-09-08 review): artifact evidence must OUTRANK phrase-matching.
    # A burn that FINISHED — the artifact is fresh — was being discarded as dry
    # whenever the engine's OWN reply happened to contain a limit phrase (e.g. a
    # task about writing a quota runbook), which then re-fired the SAME task on
    # a second account. Judge success before scanning any prose for a limit or
    # an infra signature, so a completed task can never be rerouted to redo
    # work that is already done.
    if [ "$artifact_fresh" -eq 1 ]; then
      # P2-2 (2026-09-08 round-2 review): the artifact wins the OUTCOME — that
      # guarantee above is unchanged — but a limit event that IS happening in
      # this SAME reply is real account state, not noise the artifact should
      # silently overwrite. Before this, the success branch unconditionally
      # cleared the dry marker, so a run that finished with a few partial
      # bytes on a tank the engine had JUST reported as out of fuel turned the
      # board's red dot green (and dropped the vendor's reset phrase from
      # JSON) while the account was still genuinely dry. Check the same
      # signal the dry branch below would, and if it fires, leave any
      # existing marker alone instead of clearing it, and surface the reset
      # phrase.
      #
      # P2-2 (2026-09-08 round-3 review): that round-2 fix called
      # dry_store_mark here — but limit_codex_output_dry (unlike claude's
      # branch, never anchored on a direct vendor report) matches "hit your
      # (usage|session) limit" bare, ANYWHERE in the reply. A codex task that
      # merely TALKS ABOUT the limit while it succeeds ("Done. The runbook
      # now explains what to do once you hit your usage limit.") matched it
      # too, and limit_engine_detectable is false for codex — the ONLY
      # engine that uses dry_store at all — so a SUCCESSFUL burn silently
      # wrote a dry marker on a healthy tank (round-3 PROBE B), with --json
      # showing ok:true and reset:null: nothing said it happened.
      # dry_store.sh's own header promises "a successful run clears it
      # explicitly" — writing one here breaks that promise on the one path
      # it matters most (the tank that just proved it has fuel by finishing
      # the task). A fresh artifact must never WRITE a new marker; if the
      # SAME reply also shows a live signal, at most leave an existing
      # marker as-is (never clear a tank that may still be genuinely dry).
      # The reset phrase, when there is one, already reaches the caller via
      # `_burn_result`'s "reset" field below — unchanged by this.
      local live_reset=""
      if live_reset="$(limit_output_dry "$cli" "$out_for_class")"; then
        log_warn "$cli/$cur produced a fresh artifact but its reply also shows a limit${live_reset:+  — }${live_reset} — not marking it dry (any existing marker is left as-is)."
      else
        dry_store_clear "$cli" "$cur"   # a real success recovered this tank
      fi
      log_done "Done on $cli/$cur — artifact present at engine exit: $artifact"
      _burn_status_write "done" true "$cli" "$cur" "$artifact" "artifact produced" "$live_reset"
      _burn_result true "$cli" "$cur" "$artifact" "artifact produced" "$live_reset"
      log_info "summary: tank=$cli/$cur  reroutes=$(printf '%s' "$tried" | wc -w | tr -d ' ')  elapsed=$((SECONDS - t0))s  artifact=${artifact_bytes_snapshot}B"
      return 0
    fi

    # Judge by limit-string + artifact, never the exit code.
    if reset="$(limit_output_dry "$cli" "$out_for_class")"; then
      log_warn "$cli/$cur ran dry${reset:+  — }${reset}"
      _burn_status_write dry false "$cli" "$cur" "$artifact" "tank ran dry" "$reset"
      # Persist what we just caught LIVE so the passive board (clikae home) can
      # light this tank red + show the reset phrase — codex's limit lives only in
      # this stdout and would otherwise vanish. Only for engines whose dry state is
      # NOT already scannable from disk (claude=transcript, agy=log self-clear);
      # writing a store marker for those would mask their real recovery.
      limit_engine_detectable "$cli" || dry_store_mark "$cli" "$cur" "$reset"
      # Remember this dried tank's account so the reserve skips its same-quota siblings (P1).
      local _acct; _acct="$(_limit_tank_account "$cli" "$cur" 2>/dev/null || true)"
      [ -n "$_acct" ] && dried_accts="${dried_accts}${_acct}"$'\n'
    elif _burn_output_infra "$out_for_class"; then
      if [ "$infra_attempt" -lt "$infra_retries" ]; then
        infra_attempt=$((infra_attempt + 1))
        log_warn "$cli/$cur infrastructure failure — retry $infra_attempt/$infra_retries on the same tank in ${retry_delay}s."
        _burn_status_write infra null "$cli" "$cur" "$artifact" "infra retry $infra_attempt/$infra_retries" ""
        sleep "$retry_delay"
        retry_delay=$((retry_delay * 2))
        continue
      fi
      log_err "$cli/$cur infrastructure failure after $infra_attempt retries."
      _burn_status_write infra false "$cli" "$cur" "$artifact" "infra" ""
      _burn_result false "$cli" "$cur" "$artifact" "infra"
      _burn_output_tail "$out"
      return 1
    else
      log_err "$cli/$cur produced no fresh artifact and shows no limit — a real task failure (rc=$rc), not a dry tank."
      _burn_status_write fail false "$cli" "$cur" "$artifact" "no fresh artifact and no limit" ""
      _burn_result false "$cli" "$cur" "$artifact" "no fresh artifact and no limit"
      _burn_output_tail "$out"
      log_info "summary: tank=$cli/$cur  reroutes=$(printf '%s' "$tried" | wc -w | tr -d ' ')  elapsed=$((SECONDS - t0))s  artifact=none"
      return 1
    fi

    # Dry → fall through to the next tank in the reserve.
    [ "$reroute" -eq 1 ] || {
      log_info "Dry, and --no-reroute is set. Stopping."
      _burn_status_write dry false "$cli" "$cur" "$artifact" "tank ran dry and --no-reroute is set" "${reset:-}"
      _burn_result false "$cli" "$cur" "$artifact" "tank ran dry and --no-reroute is set" "${reset:-}"
      return 1
    }
    tried="$tried $cli/$cur"
    local nxt=""
    if [ -n "$to" ]; then
      nxt="$to"; to=""                       # explicit hop, consumed once (user's call)
    else
      nxt="$(_burn_next_same_engine "$cli" "$tried" "$dried_accts" "$envvar" "$allow_active")"
    fi
    if [ -z "$nxt" ]; then
      # The reserve is exhausted. log_fail exits, so the machine-readable answer
      # has to be said first — this is the outcome an agent most needs to tell
      # apart from a task failure, and prose is the only place it lived.
      _burn_status_write dry false "$cli" "$cur" "$artifact" "every reachable tank is dry" "${reset:-}"
      _burn_result false "$cli" "$cur" "$artifact" "every reachable tank is dry" "${reset:-}"
      log_fail "All reachable tanks are dry (or in interactive use / share a dry account) — nothing left after$tried. Add a tank, wait for a reset, or --allow-active / --to <tank>."
    fi

    # Resolve the next hop. A bare name = a tank of the same engine; engine/tank =
    # possibly cross-engine (the same command then runs under that engine — warned).
    local nx_cli nx_tank
    case "$nxt" in
      */*) nx_cli="${nxt%%/*}"; nx_tank="${nxt#*/}" ;;
      *)   nx_cli="$cli";       nx_tank="$nxt" ;;
    esac
    if [ "$nx_cli" != "$cli" ]; then
      cli="$nx_cli"; load_adapter "$cli"; binary="$(adapter_meta_cli_binary)"
      envvar="$(adapter_meta_env_var 2>/dev/null || true)"   # in-use guard tracks the new engine's var
      command -v "$binary" >/dev/null 2>&1 || log_fail "Reroute engine '$binary' is not on PATH."
      if [ "$prompt_set" -eq 1 ]; then
        # Regenerate the headless flags for the NEW engine — a cross-engine reroute
        # of a --prompt task is sound (codex's flags differ from claude's, and the
        # prompt is engine-agnostic). Without a recipe for the new engine, stop.
        declare -F adapter_burn_flags >/dev/null \
          || log_fail "Cross-engine reroute → $nx_cli, which has no headless-write recipe (no adapter_burn_flags)."
        _burn_compose "$prompt" "${#post_cmd[@]}" "${post_cmd[@]}" -- "${add_dirs[@]}"
        cmd=("${BURN_ARGV[@]}")
        log_warn "Cross-engine reroute → $nx_cli: re-running the same prompt under $nx_cli's headless flags."
      else
        log_warn "Cross-engine reroute → $nx_cli: the SAME command runs under $nx_cli (only sound if it's engine-agnostic)."
      fi
    fi
    cur="$nx_tank"
    infra_attempt=0; retry_delay="$infra_delay"
    log_info "Rerouting (dry) → $cli/$cur"
  done
}
