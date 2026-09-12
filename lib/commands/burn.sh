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
# shellcheck source=../core/duration.sh
source "$CLIKAE_LIB/core/duration.sh"

_burn_help() {
  cat <<'EOF'
Usage: clikae burn <engine> <tank> --artifact <path>
                   ( --prompt-file <f> | --prompt <str> | -- <engine command...> )
                   [--add-dir <dir>]... [--to <target>] [--timeout <secs>]
                   [--no-reroute] [--allow-active] [--fresh] [--wait-for-reset <dur>]
                   [--permission <acceptEdits|auto>]

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
                      artifact's parent. Repeatable. (codex uses the first as its cwd;
                      it must be a git work tree, or use --codex-skip-git-check.)
  --codex-skip-git-check  opt in to codex --skip-git-repo-check for generated commands.
  --artifact <path>   checked at engine exit. Success = it appears, or (if
                      it already existed) its timestamp changes — a STALE file from
                      a previous run is NOT counted as success.
  --fresh             delete <artifact> before running, for a clean slate.
  --to <target>       explicit next hop on a dry tank (<engine>/<tank> or a bare
                      tank of this engine). Otherwise burn walks this engine's
                      other tanks. A cross-engine --to runs the SAME command under
                      that engine — only sensible if the command is engine-agnostic.
  --permission <mode> claude-only: acceptEdits (default) or auto. Other engines
                      have no mapping and print one degradation line, keeping
                      their existing fixed mode — see docs/orchestration.md.
                      Applies to composed prompt argv; raw commands after --
                      stay verbatim.
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
  --wait-for-reset <dur>   (#38) when a tank runs dry AND its vendor-reported
                      reset falls within <dur> (e.g. `30m`, `2h`, `90s`, or a
                      bare integer of seconds), sleep until the reset and re-fire
                      the SAME tank instead of rerouting or stopping. A reset
                      further out than <dur>, or one burn can't parse into an
                      instant (docs/orchestration.md's limit_reset_epoch — two
                      grammars, both English), falls through to the normal
                      reroute-or-stop behaviour unchanged.

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
      --prompt-file task.txt --add-dir "$PWD"      # put the git repository first
  clikae burn codex M --artifact /tmp/out.md -- exec -C /tmp --skip-git-repo-check -s workspace-write \
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
  # P2-1/P2-2 (2026-09-12 round-1 review): gate on whether an adapter DECLARES
  # a --permission mapping (adapter_meta_permission_modes, claude-only today),
  # not on its binary name — and gate on whether the caller ASKED for a mode
  # ($permission_set), not on which mode. An explicit acceptEdits on an unmapped
  # engine used to be silent, which read as "you got what you asked for" even
  # though the engine's own fixed mode may differ (grok always runs
  # --permission-mode bypassPermissions, never acceptEdits). cli/burn_permission/
  # permission_set are cmd_burn locals, inherited here via bash dynamic scoping,
  # same convention as adapter_burn_flags' own burn_permission read below.
  if [ "${permission_set:-0}" -eq 1 ] && ! declare -F adapter_meta_permission_modes >/dev/null; then
    if [ "$cli" = grok ]; then
      log_warn "clikae does not map --permission for grok; the grok burn runs with the adapter's fixed permission mode."
    else
      log_warn "$cli has no equivalent for --permission ${burn_permission:-acceptEdits}; keeping its existing burn flags."
    fi
  fi
  # NUL-delimited read so a multi-line prompt survives as a single argv item.
  while IFS= read -r -d '' line; do BURN_ARGV+=("$line"); done < <(adapter_burn_flags "$prompt" "$@")
  if [ "$cli" = codex ] && [ "${codex_skip_git_check:-0}" -eq 1 ]; then
    local has_skip=0
    for line in "${post[@]}"; do
      [ "$line" != --skip-git-repo-check ] || has_skip=1
    done
    [ "$has_skip" -eq 1 ] || BURN_ARGV=("${BURN_ARGV[0]}" --skip-git-repo-check "${BURN_ARGV[@]:1}")
  fi
  BURN_ARGV+=("${post[@]}")
}

# _agy_burn <starting-tank> <prompt> <artifact> <timeout_s> <fresh> <reroute>
#           <wait_for_reset_s> <allow_active> <n_extra> <extra-agy-flags...> <add_dirs...>
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
  local start_tank="$1" prompt="$2" artifact="$3" timeout_s="$4" fresh="$5" reroute="$6" wait_for_reset_s="$7" allow_active="$8" n_extra="$9"; shift 9
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
    local run_id="agy-${cur}-burn-$$"
    local attempt_epoch
    attempt_epoch="$(date +%s)"
    local evidence_file; evidence_file="$(mktemp "${TMPDIR:-/tmp}/clikae-agy-artifact.XXXXXX")"
    local artifact_fresh=0 artifact_bytes_snapshot=null
    art_pre="$(_clikae_mtime "$artifact")"
    local out; out="$(
      "${runner[@]}" agy "${gen[@]}" </dev/null 2>&1 || true
      _burn_snapshot "$artifact" "$art_pre" "$evidence_file"
    )" || true
    read -r artifact_fresh artifact_bytes_snapshot < "$evidence_file"
    rm -f "$evidence_file"

    local sid_to_record=""
    load_adapter "antigravity" 2>/dev/null || true
    if declare -F adapter_recent_sids >/dev/null 2>&1; then
      local recent
      recent="$(adapter_recent_sids "$(_agy_slots)/$cur" 1 disk 2>/dev/null || true)"
      if [ -n "$recent" ]; then
        local r_epoch="${recent%%$'\037'*}"
        local r_sid="${recent##*$'\037'}"
        if [ -n "$r_epoch" ] && [ "$r_epoch" != "?" ] && [ "$r_epoch" -ge "$attempt_epoch" ]; then
          sid_to_record="$r_sid"
        fi
      fi
    fi
    if [ -n "$sid_to_record" ]; then
      local sidecar_file="$CLIKAE_HOME/state/burn-sessions/agy/$cur"
      mkdir -p "$(dirname "$sidecar_file")" 2>/dev/null || true
      printf '%s\t%s\t%s\n' "$sid_to_record" "$run_id" "$(date +%s)" >> "$sidecar_file"
    fi

    # Consume the run log once, then drop it on every path below — not just the
    # dry one — so a long reroute loop doesn't litter $TMPDIR.
    local reset dry=1
    reset="$(limit_log_dry "$runlog")" && dry=0
    rm -f "$runlog"
    if [ "$dry" -eq 0 ]; then
      log_warn "agy/$cur ran dry${reset:+  — }${reset}"

      # P1-2 (2026-09-09 round-1 review): the terminal `dry` write used to
      # land HERE, before the --wait-for-reset check below — which means a
      # tank that is about to sleep 30 seconds and finish the SAME task
      # published "this run is OVER, and it went dry" to every reader
      # (`wait`, `burn_tank_busy`) for the entire sleep, up to `<dur>`. Decide
      # whether this tank is actually being abandoned FIRST; only write the
      # terminal `dry` on the branches that really do abandon it.
      if [ -n "$wait_for_reset_s" ] && [ -n "$reset" ] \
         && _burn_wait_for_reset "$status_engine" "$cur" "$artifact" "$reset" "$wait_for_reset_s"; then
        log_info "agy/$cur should be reset now — re-firing on the same tank."
        continue
      fi

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
    # P2-2 (2026-09-09 round-1 review): this picker never called
    # burn_tank_busy — the ONE engine where that matters most, since agy's
    # login is a single GLOBAL Keychain entry (§2 above) and the ~/.gemini
    # swap is machine-wide and exclusive: agy structurally CANNOT run two
    # tanks at once, unlike claude/codex where a busy tank is merely
    # inconvenient to collide with. The start-of-run refusal in cmd_burn
    # already guards the tank named on the command line; it never guarded a
    # REROUTE target, which is exactly what this walk picks next.
    local nxt=""
    local _agy_cand
    while IFS= read -r _agy_cand; do
      [ -n "$_agy_cand" ] || continue
      case " ${agy_tried[*]} " in *" $_agy_cand "*) continue ;; esac
      if [ "$allow_active" != "1" ] && burn_tank_busy "$status_engine" "$_agy_cand" "$$"; then
        log_warn "skipping agy/$_agy_cand — another burn is already running on it (#40; --allow-active to override)."
        continue
      fi
      nxt="$_agy_cand"
      break
    done < <(_agy_tank_names)
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
#                     <reason> [reset] [reset_at]
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
# `updated_at`, `pid`, `log`, `reset_at`. Written UNCONDITIONALLY (never gated
# on `--json`) — #41 is "every burn", not "every --json burn".
#
# `reset_at` (P1-2, 2026-09-09 round-1 review): the epoch second
# `--wait-for-reset` computed the vendor's reset to land on, populated only
# for the non-terminal `waiting-reset` state below — null everywhere else.
#
# `ok` is the terminal/non-terminal signal this file's OWN readers rely on:
# every call site in this codebase passes `null` for a state that is still IN
# PROGRESS (`running`, an `infra` retry-in-progress, `waiting-reset`) and an
# explicit `true`/`false` only once the outcome is actually known (`done`,
# a real `dry`, `fail`, or `infra` giving up) — see `_BURN_TERMINAL_WRITTEN`
# just below, which leans on exactly that invariant so the EXIT/INT/TERM/HUP
# traps (P1-1) know whether a terminal state was already published.
#
# Reads the caller's own locals for everything this signature doesn't carry —
# `run_dir`, `burn_id`, `started_at`, `t0`, `tried`, `log_file`,
# `artifact_bytes_snapshot` — exactly the convention `_burn_result` already
# uses one function up; both are only ever called from inside `cmd_burn` or
# `_agy_burn`, which is what makes bash's dynamic scoping the right tool here
# rather than a footgun.
_burn_status_write() {
  local state="$1" ok="$2" eng="$3" tk="$4" art="$5" reason="$6" reset="${7:-}" reset_at="${8:-}"
  [ -n "${run_dir:-}" ] || return 0   # called before setup (should not happen) — no-op, never fatal
  local bytes="${artifact_bytes_snapshot:-}"
  if [ -z "$bytes" ] && [ -n "$art" ] && [ -e "$art" ]; then bytes="$(_burn_size "$art")"; fi
  case "$bytes" in ''|*[!0-9]*) bytes=null ;; esac
  # reset_at is an epoch SECOND (a number, like started_at/updated_at/pid
  # below), never a JSON string — json_or_null would quote it.
  case "$reset_at" in ''|*[!0-9]*) reset_at=null ;; esac
  local now; now="$(date +%s 2>/dev/null || echo 0)"
  # R3-P3-2 (2026-09-09 round-3 review): `t0` (the reroute-loop clock) isn't
  # set yet for the two refusals cmd_burn can write BEFORE it ever reaches
  # that loop (the lock-timeout and busy refusals) — `${t0:-SECONDS}` made
  # elapsed_s read a flat 0 on those no matter how long the wait actually
  # was, silently contradicting the started_at/updated_at pair right next to
  # it in the same object. Fall back to wall-clock epoch (started_at is set
  # at function entry, well before either refusal) instead of `$SECONDS`
  # itself when there's no `t0` yet.
  local elapsed elapsed_base
  if [ -n "${t0:-}" ]; then
    elapsed=$(( SECONDS - t0 ))
  else
    elapsed_base="${started_at:-$now}"
    elapsed=$(( now - elapsed_base ))
  fi
  local f="$run_dir/status.json"
  mkdir -p "$run_dir" 2>/dev/null || true
  {
    printf '{"ok":%s,"engine":%s,"tank":%s,"artifact":%s,"artifact_bytes":%s,"reason":%s,"reset":%s,"rerouted_from":[%s],"elapsed_s":%s,"run_id":%s,"state":%s,"started_at":%s,"updated_at":%s,"pid":%s,"log":%s,"reset_at":%s}\n' \
      "${ok:-null}" "$(json_or_null "$eng")" "$(json_or_null "$tk")" "$(json_or_null "$art")" \
      "${bytes:-null}" "$(json_or_null "$reason")" "$(json_or_null "$reset")" \
      "$(_burn_tried_json "${tried:-}")" "$elapsed" "$(json_or_null "${burn_id:-}")" \
      "$(json_str "$state")" "${started_at:-null}" "$now" "$$" "$(json_or_null "${log_file:-}")" \
      "${reset_at}"
  } > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null || true
  # P1-1 (2026-09-09 round-1 review): `ok` is null for every state that is
  # still IN PROGRESS and true/false only once a real terminal outcome is
  # known (see the comment above) — so this is the one place that gets to
  # say "a terminal state now exists on disk", and every trap/poller below
  # trusts it instead of re-deriving it from `state` alone.
  [ "${ok:-null}" = "null" ] || _BURN_TERMINAL_WRITTEN=1
}

# _BURN_TERMINAL_WRITTEN — 0 until this burn's status file has recorded a
# real terminal outcome (see `_burn_status_write` above), then 1 for the rest
# of the process's life. `clikae burn` is a fresh process per invocation (see
# bin/clikae's dispatch: it sources this file and calls `cmd_burn` once), so
# the file-load-time 0 below is the only initialization this ever needs.
_BURN_TERMINAL_WRITTEN=0

# _burn_exit_guard [exit-code] — the P1-1 (2026-09-09 round-1 review) safety
# net: a burn that dies WITHOUT ever writing a terminal state (a `log_fail`
# this file doesn't yet cover explicitly, a raw `exit` from a sourced helper,
# or SIGINT/TERM/HUP/an ordinary process exit) used to leave `status.json`
# saying `running` forever — `clikae wait` would then block on a dead burn
# until its own `--timeout` (if any) expired, since nothing ever told it the
# writer was gone. Installed as an EXIT/INT/TERM/HUP trap immediately after
# the FIRST `running` write in `cmd_burn` (before that point no status file
# exists yet, so there is nothing to rescue), and a no-op once
# `_BURN_TERMINAL_WRITTEN` is already 1 — the common, healthy case, where
# this fires anyway (every trap converges on this Bash process's one EXIT)
# but has nothing to do. Bash's dynamic scoping means `_burn_status_write`
# still resolves `run_dir`/`cur`/`status_engine`/etc. from whichever of
# `cmd_burn` / `_agy_burn` is on the call stack when the trap fires — the
# same convention `_burn_status_write` itself already documents.
_burn_exit_guard() {
  local ec="${1:-$?}"
  [ "${_BURN_TERMINAL_WRITTEN:-0}" -eq 1 ] && return 0
  _burn_status_write fail false "${status_engine:-${cli:-}}" "${cur:-${tank:-}}" "${artifact:-}" \
    "burn exited without reaching a terminal state (exit $ec)" ""
}

# Installed right after the first `running` write (see the comment above).
# Each SIGNAL trap writes the terminal state THEN exits with the signal's
# conventional code (128+n), so a killed burn's own exit code still reads as
# a kill, not a plain failure; the EXIT trap is the catch-all for every other
# path (a `log_fail` `exit 1`, a normal `return`, anything not already
# terminal) and is always the last one to run, no matter which of these
# fires first.
_burn_install_exit_trap() {
  trap '_burn_exit_guard 129; exit 129' HUP
  trap '_burn_exit_guard 130; exit 130' INT
  trap '_burn_exit_guard 143; exit 143' TERM
  trap '_burn_exit_guard "$?"' EXIT
}

# _burn_parse_duration now lives in lib/core/duration.sh (P1-4a, 2026-09-09
# round-1 review) — `clikae wait --timeout` needs the exact same grammar and
# has no other reason to source burn.sh's much larger dependency chain. See
# that file for the function itself; sourced at the top of this file.

# _burn_wait_for_reset <engine> <tank> <artifact> <reset-phrase> <window_s> ->
# 0 once the tank's reset should have landed (the caller should re-fire the
# SAME tank now); 1 if the reset was never within <window_s> to begin with,
# or moved out far enough on re-check that it no longer is.
#
# P1-2 (2026-09-09 round-1 review): before this, `--wait-for-reset` wrote a
# TERMINAL `dry` (ok:false) BEFORE deciding whether to wait — so a tank that
# was about to sleep a few minutes and finish the SAME task told every
# reader "this run is OVER, and it went dry" for the whole sleep, up to
# `<dur>`. `#41`'s own `wait` reads exactly that as a terminal outcome and
# returns instantly; `#40`'s `burn_tank_busy` reads `state != running` as
# "free" and lets a SECOND burn (or the reroute walk) land on the same tank
# mid-wait. Neither is what "waiting, not abandoning" is supposed to mean.
#
# The fix: while this function is waiting, the status file says the
# NON-terminal `waiting-reset` (ok:null, `reset_at` the epoch this is aiming
# for) — `burn_tank_busy` (lib/core/burn_status.sh) now holds a tank busy on
# that state exactly like `running`. Only the CALLER decides what terminal
# state to write once this returns: 0 → re-fire, whose real outcome (done or
# a fresh dry) is what finally gets published; 1 → the caller writes the
# terminal `dry` it always would have.
#
# On wake, the reset is RE-CHECKED rather than trusted blindly — an
# interrupted sleep, a suspended/resumed machine, or a vendor reset phrase
# that (being relative, "resets in 30m") resolves to something later when
# re-anchored from a fresh `now`, could all mean the target has not actually
# arrived yet. One bounded extra wait is given, capped at the ORIGINAL
# `<window_s>` from when this was first called (never re-extended) — not an
# unbounded retry loop: a reset that keeps moving past the window gives up
# and returns 1 rather than sleeping forever.
_burn_wait_for_reset() {
  local eng="$1" tk="$2" art="$3" reset="$4" window_s="$5"
  local now at remain deadline
  now="$(date +%s 2>/dev/null || echo 0)"
  at="$(limit_reset_epoch "$reset" "$now")" || return 1
  remain=$(( at - now ))
  [ "$remain" -le "$window_s" ] || return 1
  [ "$remain" -lt 0 ] && remain=0
  deadline=$(( now + window_s ))

  log_info "$eng/$tk resets in ${remain}s, within --wait-for-reset ${window_s}s — waiting instead of moving on."
  _burn_status_write waiting-reset null "$eng" "$tk" "$art" "waiting for reset at ${reset}" "$reset" "$at"
  sleep "$remain"

  now="$(date +%s 2>/dev/null || echo 0)"
  if [ "$now" -lt "$at" ] && [ "$now" -lt "$deadline" ]; then
    local at2 remain2
    if at2="$(limit_reset_epoch "$reset" "$now")" && [ "$at2" -le "$deadline" ]; then
      remain2=$(( at2 - now ))
      [ "$remain2" -lt 0 ] && remain2=0
      log_info "$eng/$tk hasn't reset yet — waiting the remaining ${remain2}s (still inside the original window)."
      _burn_status_write waiting-reset null "$eng" "$tk" "$art" "waiting for reset at ${reset}" "$reset" "$at2"
      sleep "$remain2"
    else
      return 1   # the reset no longer resolves inside the window — give up
    fi
  fi
  return 0
}

# _burn_tank_lock_path <engine> <tank> -> the rendezvous path for this exact
# engine/tank pair's lock — a SYMLINK, never a directory (R3-P1-1/R3-P1-2,
# 2026-09-09 round-3 review; see _burn_tank_lock_acquire below for why).
_burn_tank_lock_path() {
  local safe
  safe="$(printf '%s_%s' "$1" "$2" | tr -c 'A-Za-z0-9_' '_')"
  printf '%s/.clikae/state/tank-busy-%s.lock\n' "$HOME" "$safe"
}

# _burn_reclaim_mutex_try <reclaim_link> -> 0 once THIS process holds the
# mutex (its own `ln -s` succeeded); 1 otherwise.
#
# R3-P1-1/R3-P1-2 (2026-09-09 round-3 review): every REMOVAL of the tank
# lock symlink — a stale reclaim tearing down a dead holder's link, or an
# owner's own release — happens only while holding this SECOND, short-lived
# mutex (`_burn_tank_lock_acquire`/`_burn_tank_lock_release` below).
#
# R4-P1-1/R4-P1-2/R4-P1-3 (2026-09-10 round-4 review): round 3's mutex was a
# directory claimed by `mkdir`, with its own pid written in a SEPARATE
# statement right after — the exact two-statement claim-then-identify race
# the symlink lock above exists to abolish, ported one function up and left
# unguarded. A process killed between the `mkdir` and the pid write left a
# directory with no pid inside, which was then never reaped (a pid-less
# mutex read `''` and unconditionally `return 1`ed before ever reaching the
# stale rule) — permanently disabling the tank it guarded. And even a
# mutex WITH a pid was reaped by a check-then-act on a directory this
# process does not own: read the pid, decide it's dead, then unconditionally
# `rm`/`rmdir` — with nothing stopping a THIRD process from having
# `mkdir`'d it, live, in between.
#
# Both are fixed the same way the lock itself was: the mutex is now a
# SYMLINK, `ln -s "<pid>:<started_at>" "$reclaim_link"` — one atomic
# syscall, identity present from the instant the path exists, so there is
# no pid-less window at any level to leave permanently unclaimable. Its own
# `started_at` travels IN that payload, so the "≥30s" half of the stale
# rule is `now - started_at` read straight out of it — no `stat` call
# anywhere in this function any more (R4-P1-3: there is no `stat -f`/`stat
# -c` order left to get wrong, because there is no `stat` left).
#
# Reaping a mutex that looks abandoned never trusts its own read enough to
# act on it directly: it first `mv`s the symlink to a private, unique
# graveyard name (`mv` — i.e. `rename(2)` — of a symlink is atomic, and
# because that destination name has never existed before, it can never
# nest the way `ln -s`/`mv` onto an existing directory can). Only ONE
# racing reaper's `mv` can possibly win, because after the first `mv`
# there is nothing left at `$reclaim_link` for a second `mv` to move — the
# decision of WHO gets to act is made by the filesystem, not by comparing
# reads taken at different times. The winner then `readlink`s its OWN
# graveyard copy and checks what it actually caught: if it still names the
# pid judged dead, the eviction was correct — remove the graveyard entry
# and return (the caller's loop races `ln -s` fresh; reaping here never
# claims the mutex for the caller, same as before). If it names anyone
# else, this reaper's `mv` raced a live holder's fresh `ln -s` into the
# exact same window between the unsynchronized read and the `mv` — the
# eviction was WRONG, and the `mv` just vacated a path that live holder
# legitimately occupied (the same vacate hazard R3-P1-1 found in the main
# lock, one function up). Rather than leave that vacancy open for any
# length of time — even a bounded wait is a window a THIRD process's `ln
# -s` could land in, becoming a second live holder — it is put back
# immediately by RE-CREATING it with `ln -s` (not by trying to `mv` the
# graveyard copy back — measured: `mv -n` onto an existing SYMLINK
# destination silently CLOBBERS it on the system `/bin/mv`, `-n` only
# reliably no-clobbers a regular-file destination; `ln -s` is EEXIST-on-
# conflict by definition of the syscall, identical on every vendor): either
# an equivalent entry lands right back (the destination was still empty),
# or the attempt fails because something claimed it again in the handful
# of syscalls since, in which case nothing safe is left to do but log it.
# Either way, only the `mv` winner ever removes or restores anything, and
# only the one graveyard path it alone created.
# _BURN_RECLAIM_MUTEX_OWNED — empty when this process holds no reclaim
# mutex right now, set to the reclaim_link path for the exact window this
# process holds one. R5-P2-3 (2026-09-10 round-5 review): a signal landing
# inside that window and running _burn_tank_lock_release from a trap must
# not try to re-acquire a mutex this SAME process already holds — its own
# liveness check would see its own live pid and correctly refuse to evict
# it, deadlocking the release against itself for the full retry budget
# (and again for the EXIT trap the signal handler's own `exit` triggers).
# Every place that wins _burn_reclaim_mutex_try sets this before acting and
# clears it right after _burn_reclaim_mutex_release, so a trap firing
# anywhere in between can see it and skip straight to acting under the
# mutex already held instead of looping to acquire it a second time.
_BURN_RECLAIM_MUTEX_OWNED=""

# _BURN_LOCK_ACQUIRE_FOREIGN_MUTEX — set by `_burn_tank_lock_acquire` to the
# reclaim-mutex path it refused on, immediately before it `return`s 2 (R9-
# P1-2/R9-P2-3, 2026-09-11 round-9 review): a foreign object never self-
# heals, so that refusal is terminal rather than an ordinary busy-mutex
# backoff, and the caller (`cmd_burn`) reads this to write the specific
# `foreign-mutex: <path>` reason into the status file and the terminal
# message, instead of the generic busy-timeout text. Empty whenever the
# most recent `_burn_tank_lock_acquire` call did not return 2 for this
# reason — callers must not read it after any OTHER return value.
_BURN_LOCK_ACQUIRE_FOREIGN_MUTEX=""

# _burn_reclaim_mutex_is_foreign <reclaim_link> -> 0 if the path is occupied
# by something this codebase never wrote and will never touch (a directory,
# a symlink resolving to one, a plain file, a fifo, a socket — anything
# `-e` sees through to), 1 for anything else (vacant, or a well-formed
# `<pid>:<started_at>` symlink of ours, live or dead). Shared by
# `_burn_reclaim_mutex_try`, `_burn_reclaim_mutex_available` and
# `clean.sh`'s GC, so all three report the exact same "foreign-mutex"
# verdict for the exact same path — see the KITT ruling above `try`'s own
# refusal for why this is a single rule rather than three cases.
#
# R9-P2-1 (2026-09-11 round-9 review): the shipped `[ -e "$1" ] && { [ ! -L
# "$1" ] || [ -d "$1" ]; }` was three conditions where one already does the
# whole job, and the extra two let one shape through: a symlink resolving
# to an EXISTING NON-DIRECTORY (a regular file, a symlink chain to one, or
# a device node) made `-e` true, `[ ! -L ]` false AND `[ -d ]` false, so
# `is_foreign` returned 1 (not foreign) and the malformed-payload branch
# below evicted it — measured, on a regular file, a chained symlink, and
# `/dev/null`: removed, not refused, exactly the object all three surfaces
# (this comment, `try`'s refusal message, and docs/orchestration.md) say is
# never touched. `-e` alone is sufficient because it DEREFERENCES: our own
# claim's target is always DATA (`<pid>:<started_at>`), never a real path,
# so `-e` on our own claim is always false regardless of liveness — that
# one property is the whole rule. *Anything* the path resolves to is
# foreign, because nothing this codebase ever writes resolves to anything.
# This also removes the ENOENT race the three-condition form had (R9-P3-1):
# if the object vanished between a first and a second `stat`, `[ -e ]` was
# true and `[ ! -L ]` was true (ENOENT), misclassifying a now-VACANT path as
# foreign — with a single `stat` there is no second call left to race.
_burn_reclaim_mutex_is_foreign() {
  [ -e "$1" ]
}

_burn_reclaim_mutex_try() {
  local reclaim_link="$1" now_epoch target mpid mstarted evict_now age
  local grave gtarget gpid

  # KITT (2026-09-11, extreme-subtraction ruling on R8-P1-1 / R8-P1-2): this
  # PR never shipped, so no released clikae ever created a directory-shaped
  # reclaim mutex -- the legacy-directory reclaim branch that used to sit
  # here (four straight rounds' worth of P1s against it: R8-P1-1's `ln -s`
  # trusted-exit-code restore that nested silently into a foreign directory
  # and destroyed the only copy of a live holder's claim, and R8-P1-2's bare
  # `rm -f` with no re-test and no mutex around it) is DELETED, not patched
  # a fifth time. What replaces it, and the sibling non-symlink branch, and
  # the foreign-symlink-to-directory guard that used to sit further down, is
  # ONE rule, applied before any removal is even considered: a mutex path
  # this function did not itself write -- a directory, a symlink resolving
  # to one, or a plain file -- is never touched. `-d` DEREFERENCES a symlink
  # (R7-P2-2's own finding), so `[ -d "$reclaim_link" ]` alone already
  # catches both a bare directory and a symlink-to-directory; `[ ! -L
  # "$reclaim_link" ]` catches a plain foreign file. Nothing this function
  # ever writes is anything but a symlink whose target is DATA
  # (`<pid>:<started_at>`, never a real path), so this condition can only be
  # foreign: refuse loudly and name the path. This function's own job stops
  # at refusing once -- it never retries a refusal itself. R9-P1-2 (2026-
  # 09-11 round-9 review): the OLD comment here said this "backs off exactly
  # like any other busy mutex, the caller's own retry/timeout policy is
  # unchanged" -- true of this function in isolation, false of what it
  # licensed callers to assume, because a foreign object never self-heals
  # the way an ordinary busy mutex does. `_burn_tank_lock_acquire` treats
  # THIS specific refusal as terminal (see its own R9-P1-2 comment) rather
  # than looping back with a backoff sleep; measured on the old
  # loop-forever-with-no-sleep shape: 9.79s of CPU and 49,151 duplicate
  # refusal lines in one 10s burn. `clikae clean`'s GC reports the same
  # refusal under the same reason and moves on to the next tank without
  # retrying this one either.
  if _burn_reclaim_mutex_is_foreign "$reclaim_link"; then
    printf 'clikae: reclaim mutex at %s is a foreign-mutex (a directory, a symlink to one, or a plain file) -- remove it by hand, then retry\n' "$reclaim_link" >&2
    return 1
  fi

  now_epoch="$(date +%s 2>/dev/null || echo 0)"
  if ln -s "$$:$now_epoch" "$reclaim_link" 2>/dev/null; then
    # R9-P2-2 (2026-09-11 round-9 review): `ln -s`'s own exit code is NOT
    # proof the claim landed AT $reclaim_link -- the same fact R8-P1-1 found
    # for the RESTORE twelve lines below applies just as much to this
    # CLAIM: if a foreign directory arrives in the window between the
    # is_foreign check above and this `ln -s` (this function does not hold
    # any mutex over ITSELF), `ln -s` follows the now-existing directory and
    # nests our claim INSIDE it, still returning rc=0 -- measured 5/5 with a
    # hook planted in that exact window. Verify by `readlink`, exactly like
    # the restore already does: on a match we genuinely hold the mutex; on
    # a mismatch we hold nothing at `$reclaim_link` at all, so the caller's
    # normal retry sees the object that arrived and the next `is_foreign`
    # call refuses it correctly instead of two processes believing they
    # both hold this mutex.
    if [ -L "$reclaim_link" ] && [ "$(readlink "$reclaim_link" 2>/dev/null)" = "$$:$now_epoch" ]; then
      return 0
    fi
    # R10-P3-2 (2026-09-12 round-10 review): the readlink verify above only
    # tells us the claim did NOT land at $reclaim_link -- it does not undo
    # what `ln -s` already did. When the destination that arrived in the
    # unguarded window between the `is_foreign` check above and this
    # `ln -s` resolves to a DIRECTORY, `ln -s` nests our claim INSIDE it
    # (named by our own payload -- it carries no slash) instead of failing,
    # still returning rc=0 -- measured 5/5 with a hook. Every surface (this
    # function's own header, its refusal message above, docs/
    # orchestration.md) promises a foreign object is "never touched"/
    # "never removed either"; leaving litter INSIDE one breaks that promise
    # as much as removing it would. Clean up only the exact entry we just
    # created (named by our own pid:epoch payload) -- never anything else
    # the foreign directory might already contain.
    if [ -d "$reclaim_link" ]; then
      rm -f "$reclaim_link/$$:$now_epoch" 2>/dev/null
    fi
    return 1
  fi

  [ -L "$reclaim_link" ] || return 1   # vanished between the checks above and here — caller retries
  target="$(readlink "$reclaim_link" 2>/dev/null || true)"
  mpid="${target%%:*}"
  mstarted="${target#*:}"
  case "$mstarted" in ''|*[!0-9]*) mstarted=0 ;; esac

  evict_now=0
  case "$mpid" in
    ''|*[!0-9]*)
      # Empty, dangling, or malformed payload: a well-formed mutex link
      # ALWAYS has a numeric pid from the instant it exists (it's written
      # atomically by the `ln -s` above), so this shape is foreign or
      # corrupt, never a young legitimate holder — evict regardless of age.
      evict_now=1
      ;;
    *)
      if kill -0 "$mpid" 2>/dev/null; then
        # R5-P2-1 (2026-09-10 round-5 review): a bare `kill -0` only proves
        # SOMETHING is alive at this pid, not that it's the SAME process
        # this marker's `started_at` was recorded for — a pid recycled
        # onto a dead holder's number would otherwise wedge this mutex,
        # and the tank it guards, for the recycler's ENTIRE lifetime (a
        # daemon or a long-lived tmux server: unbounded in practice). The
        # tank lock itself is already guarded against exactly this
        # (`_burn_pid_matches_marker`, further down); the mutex protecting
        # its removal needs the same check, not a weaker one.
        _burn_pid_matches_marker "$mpid" "$mstarted" && return 1   # alive AND matches -- do not evict
        evict_now=1   # alive pid, but not the process that wrote this marker -- stale regardless of age
      else
        # R5-P2-2: clamp instead of trusting the sign. A `started_at`
        # AHEAD of `now` (a backward clock step on the reader, or a
        # forward one on the writer at claim time) must not make a dead
        # holder's mutex permanently un-reapable until wall clock catches
        # up to it -- treat a negative age the same as "long past due",
        # not as "not due yet".
        age=$((now_epoch - mstarted))
        [ "$age" -lt 0 ] && age=30
        [ "$age" -ge 30 ] && evict_now=1
      fi
      ;;
  esac
  [ "$evict_now" -eq 1 ] || return 1

  # R10-P3-5 (2026-09-12 round-10 review): `$$.$RANDOM` alone is safe
  # against two REAPERS colliding right now (no two processes share a
  # pid), but not against a grave deliberately KEPT (the "could NOT
  # restore" branch below, R10-P2-1's fix makes these sweepable, not
  # instantly gone) colliding with a LATER process that recycles the same
  # pid and happens to draw the same $RANDOM -- a `mv` onto that path would
  # silently clobber the only surviving copy of a live claim. A wall-clock
  # timestamp added to the same name shrinks that already-small window
  # further without changing how any sweeper parses it (they all read only
  # the first `.`-delimited field after `.stale.` as the pid).
  grave="${reclaim_link}.stale.$$.$RANDOM.$(date +%s 2>/dev/null || echo 0)"
  mv "$reclaim_link" "$grave" 2>/dev/null || return 1   # someone else already reaped or released it
  gtarget="$(readlink "$grave" 2>/dev/null || true)"
  gpid="${gtarget%%:*}"
  if [ "$gpid" = "$mpid" ]; then
    rm -f "$grave" 2>/dev/null   # exactly the abandoned mutex we judged dead — never claims it for the caller
    return 1
  fi
  # We caught someone ELSE'S mutex: a live holder's fresh `ln -s` landed in
  # this EXACT path in the window between our unsynchronized read (above)
  # and our `mv` (just now) — our `mv` just vacated the path a live holder
  # was legitimately occupying. That vacancy is itself a hazard structurally
  # identical to R3-P1-1's original `mv`-vacate bug, just one function up:
  # if left open, a THIRD process's `ln -s` can land in it and become a
  # SECOND live holder of this mutex while the one we just evicted (still
  # alive, still inside whatever it was doing) has no idea it happened.
  #
  # So the fix does NOT wait-then-discard (which leaves that vacancy open
  # for as long as the wait, however short) — it puts an equivalent entry
  # BACK immediately, by re-creating it with `ln -s "$gtarget" ...` rather
  # than trying to `mv` the graveyard copy back. This is NOT the same
  # thing: measured on this machine, `mv -n SRC DST` when DST is an
  # EXISTING SYMLINK silently CLOBBERS it on the system `/bin/mv` (BSD) —
  # `-n` reliably no-clobbers a regular-file destination but not a
  # symlink-to-symlink `mv`, while GNU coreutils' `mv -n` gets this right;
  # a fix that only works with one vendor's coreutils on `$PATH` is exactly
  # the R4-P1-3 shape this same round already closed once. `ln -s`, by
  # contrast, is EEXIST-on-conflict by definition of the syscall itself —
  # confirmed identical on both `/bin/ln` and GNU coreutils' `ln`: it never
  # overwrites, ever, on either vendor, because there is no `-n`-style
  # switch to get inconsistently implemented in the first place. Re-
  # creating (rather than moving) also means our graveyard copy is always
  # `rm -f`-able afterward regardless of which branch we took — nothing
  # downstream ever depends on the SAME inode surviving, only on the same
  # payload existing at `$reclaim_link` again.
  # R8-P1-1 (2026-09-11 round-8 review): `ln -s`'s own exit code is NOT
  # proof the link landed -- EEXIST-atomic only against another SYMLINK, it
  # silently nests INSIDE anything the destination resolves to (a directory,
  # or a symlink to one) and still returns rc=0, measured identical on GNU
  # coreutils' `ln` and BSD `/bin/ln`. Verifying by `readlink` instead of by
  # exit code is what tells "restored" apart from "nested as junk inside
  # whatever is occupying the path now" -- and on a mismatch the graveyard
  # copy is KEPT, never `rm -f`'d, because it is the only surviving copy of
  # a live holder's claim and `clean`'s graveyard sweep is its recovery
  # path. `[ -L "$reclaim_link" ] &&` is load-bearing, not decoration:
  # without it an empty `$gtarget` (a caught empty-target link) compares
  # equal to `readlink`'s empty output on a path that does not exist at
  # all, and a false "restored" comes straight back.
  # R10-P3-4 (2026-09-12 round-10 review): the two messages below used to
  # say "raced a live holder (pid %s)" -- true in the common case, but
  # wrong in two real ones this function itself can catch: a caught
  # empty-target claim ($gpid empty, printing an empty "(pid )"), and a
  # pid that matches the age-evicted holder's own but with a different
  # `started_at` (a recycled marker) -- which is a DIFFERENT identity from
  # the one just evicted, not provably "live". Reporting the raw caught
  # identity (never empty in the printed string) instead of a liveness
  # claim this function did not itself re-verify is accurate in all three
  # cases. (Comment placed here, not between the verify and the message
  # below, so it stays out of the structural pin's fixed-offset window --
  # see the KITT/R8-P1-1 test right below this function's own test.)
  ln -s "$gtarget" "$reclaim_link" 2>/dev/null || true
  if [ -L "$reclaim_link" ] && [ "$(readlink "$reclaim_link" 2>/dev/null)" = "$gtarget" ]; then
    printf 'clikae: reclaim mutex reaper for %s raced a holder it did not judge stale (identity: %s) -- restored it\n' "$reclaim_link" "${gtarget:-<empty>}" >&2
    rm -f "$grave" 2>/dev/null
  else
    printf 'clikae: reclaim mutex reaper for %s raced a holder it did not judge stale (identity: %s) -- could NOT restore (the mutex path is occupied) -- the claim is kept at %s\n' "$reclaim_link" "${gtarget:-<empty>}" "$grave" >&2
  fi
  return 1
}

# _burn_reclaim_mutex_release <reclaim_link> — the counterpart to a
# successful _burn_reclaim_mutex_try. Always called by the same process
# that just claimed it (every call site is `if _burn_reclaim_mutex_try
# …; then … _burn_reclaim_mutex_release …; fi`), but re-verifies the link
# still names THIS pid before removing it anyway — the same defence in
# depth `_burn_tank_lock_release` applies to the lock itself: a reaper that
# mistakenly `mv`-ed away a live holder's link (R4-P1-2's residual window,
# between that reaper's `mv` and its own cleanup) could leave a THIRD
# process's fresh claim sitting at this exact path by the time some other
# code path calls release — trusting "I must be the one who's calling
# this" without checking is exactly the assumption that bit the lock
# itself before its own release was hardened this way.
#
# R5-P1-3 (2026-09-10 round-5 review): this mutex is NOT mathematically
# exclusive, and that is written down here rather than implied away. The
# window this comment names is real: a reaper that mistakenly evicted a
# live holder and then lost the restore race (a THIRD claim landing first)
# leaves that live holder still believing it holds the mutex while the
# third claim also holds it — two processes briefly inside the SAME
# removal critical section. Measured at 0 in 300 real `clikae burn` trials
# and 0/50 on this function's own calling path; a synthetic, zero-backoff
# hammer of the mutex in total isolation (a rhythm no real caller
# produces) found it at up to ~24%. The re-verify above is what bounds the
# cost when it happens: it never lets EITHER process delete a link that
# isn't its own, so the worst case is one extra live holder for the span
# of one critical section, caught downstream by the tank LOCK's own
# owner-only release — two burns briefly on one tank (#40), never a
# corrupted lock file and never data loss. See docs/orchestration.md's
# "Round 5" note for the full numbers.
_burn_reclaim_mutex_release() {
  local target; target="$(readlink "$1" 2>/dev/null || true)"
  [ "${target%%:*}" = "$$" ] && rm -f "$1" 2>/dev/null
  return 0
}

# _burn_reclaim_mutex_available <reclaim_link> -> 0 if _burn_reclaim_mutex_try
# would currently be ABLE to act on <reclaim_link> (it is vacant, or a dead
# or recycled holder it would reap), 1 if a genuinely live holder occupies
# it, OR it is a foreign object (a directory, a symlink to one, or a plain
# file) that a real `try` would refuse rather than touch (KITT, 2026-09-11).
#
# R6-P2-1 (2026-09-10 round-6 review): `clikae clean --dry-run` used to
# preview a tank lock's removal with NO knowledge of whether its reclaim
# mutex was even claimable (the `.lock` loop), and with a bare `kill -0` for
# the mutex's OWN liveness (the `.lock.reclaim` loop) — the exact "third,
# weaker liveness rule for the same object" `_burn_pid_matches_marker`
# replaced everywhere else. A dry run that over-promises a removal the real
# run would refuse (busy) or under-promises one it would make (already
# reaped) is worse than no preview.
#
# READ-ONLY BY DESIGN: makes the identical decision `_burn_reclaim_mutex_try`
# makes, without ever moving, creating, or removing anything — not even the
# transient claim-then-release a real `try`+`release` pair would leave no
# permanent trace from either, but WOULD destroy a pre-existing dead entry
# a dry run has no business touching. Mirrors `_burn_reclaim_mutex_try`'s
# symlink marker-match liveness rule, and its single foreign-mutex refusal
# rule, exactly; a change to either there must be mirrored here — see
# tests/bats/clean.bats's R6-P2-1 parity tests, which exercise both
# functions against the same fixtures and assert they agree.
_burn_reclaim_mutex_available() {
  local reclaim_link="$1" now_epoch target mpid mstarted age
  # 🔴 `-e` DEREFERENCES: a well-formed mutex symlink's target is data
  # (`<pid>:<started_at>`), never a real path, so `-e` on a live mutex link
  # is ALWAYS false -- checking existence with `-e` alone here would treat
  # every genuinely-held mutex as vacant. Same correction the review's own
  # leak detector needed ("a dangling symlink is invisible to `-e` alone").
  { [ -L "$reclaim_link" ] || [ -e "$reclaim_link" ]; } || return 0
  # KITT (2026-09-11): mirrors _burn_reclaim_mutex_try's single foreign-
  # mutex rule exactly -- a directory, a symlink resolving to one, or a
  # plain foreign file is never claimable by a real `try`, so it is never
  # "available" here either. `-d` DEREFERENCES a symlink (R7-P2-2), so this
  # one condition covers all three shapes.
  if _burn_reclaim_mutex_is_foreign "$reclaim_link"; then
    return 1
  fi
  target="$(readlink "$reclaim_link" 2>/dev/null || true)"
  mpid="${target%%:*}"
  mstarted="${target#*:}"
  case "$mstarted" in ''|*[!0-9]*) mstarted=0 ;; esac
  case "$mpid" in
    ''|*[!0-9]*) return 0 ;;
    *)
      if ! kill -0 "$mpid" 2>/dev/null; then
        now_epoch="$(date +%s 2>/dev/null || echo 0)"
        age=$((now_epoch - mstarted))
        [ "$age" -lt 0 ] && age=30
        [ "$age" -ge 30 ] && return 0
        return 1
      fi
      _burn_pid_matches_marker "$mpid" "$mstarted" && return 1
      return 0
      ;;
  esac
}

# _burn_tank_lock_reap_verified <lock> <judged_holder> <judged_hstarted> ->
# reap <lock> IF, AND ONLY IF, an atomic `mv` still catches the exact
# identity the caller already judged stale from an earlier unsynchronized
# read; if it catches anything else, put it back. 0 if the lock was
# genuinely reaped, 1 otherwise (nothing to reap, or a live claim was
# safely restored).
#
# R9-P1-1 (2026-09-11 round-9 review): every OTHER remover in this file
# already earns mutual exclusion by never trusting a decision made before
# the removal — `_burn_reclaim_mutex_try` itself is the model: `mv` first
# (atomic; catches whatever is THERE, not whatever was there when a
# fork-ago read happened), then classify what was actually caught. The two
# call sites of THIS helper (`_burn_tank_lock_acquire`'s re-verify-under-
# the-mutex block, and `_clean_tank_lock_gc`'s twin) had that discipline
# applied to the MUTEX that serialises their removals, never to the LOCK
# the mutex protects: both used to `readlink`-decide-then-`rm -f "$lock"`
# directly, and `_burn_pid_matches_marker` forks `ps` AND `date` in
# between decide and remove. The reclaim mutex serialises REMOVERS, never
# CLAIMANTS — a claim is a bare `ln -s` with no mutex around it at all
# (see the claim below) — so a live burn's fresh claim landing in that
# fork-sized window was deleted by a reaper that never re-read what it was
# about to `rm`. Measured through real `clikae burn`/`clikae clean`
# binaries: 6 genuine engine overlaps (two burns holding one tank lock at
# once, the #40 symptom this entire mechanism exists to prevent), and
# deterministically 5/5 at each site with a hook planted immediately
# before the old bare `rm -f "$lock"`.
#
# The fix is the same `mv`-then-classify shape, parameterised by the
# identity the caller already believes is stale (so this helper re-derives
# nothing about liveness itself — that stays the caller's job, exactly
# once, right before calling this): `mv` is atomic on one filesystem, so
# whatever is at `$lock` the instant this runs is what lands in the
# graveyard and nothing else can land there afterward. If the graveyard's
# own payload still names the judged-stale identity, the eviction was
# correct and the graveyard copy is discarded. If it names anyone else, a
# live holder's fresh claim landed in the window between the caller's read
# and this `mv` — put it back immediately (never leave the path vacant for
# a THIRD contender to land in, the same vacate hazard R3-P1-1 found in the
# main lock and R4-P1-2 found in the mutex), and verify the restore by
# `readlink`, not by `ln -s`'s own exit code (R8-P1-1's own rule, applied
# here to the lock rather than the mutex): on a mismatch the graveyard copy
# is KEPT, never discarded, because it is the only surviving copy of a live
# holder's claim.
_burn_tank_lock_reap_verified() {
  local lock="$1" judged_holder="$2" judged_hstarted="$3"
  local grave gtarget gholder ghstarted
  [ -L "$lock" ] || return 1
  # R10-P3-5 (2026-09-12 round-10 review): same fix as the reclaim mutex's
  # own grave naming above -- `$$.$RANDOM` alone only protects against two
  # REAPERS colliding right now, not against a deliberately-kept grave (the
  # "could NOT restore" branch below) colliding with a LATER pid-recycled
  # process drawing the same $RANDOM. The added timestamp costs no sweeper
  # anything: every sweeper reads only the first field after `.stale.`.
  grave="${lock}.stale.$$.$RANDOM.$(date +%s 2>/dev/null || echo 0)"
  mv "$lock" "$grave" 2>/dev/null || return 1   # someone else already reaped or released it
  gtarget="$(readlink "$grave" 2>/dev/null || true)"
  gholder="${gtarget%%:*}"
  ghstarted="${gtarget#*:}"
  if [ "$gholder" = "$judged_holder" ] && [ "$ghstarted" = "$judged_hstarted" ]; then
    rm -f "$grave" 2>/dev/null   # exactly the identity we judged stale -- discard it
    return 0
  fi
  # We caught someone ELSE'S claim: a live holder's fresh `ln -s` landed on
  # this EXACT path in the window between the caller's unsynchronized read
  # and this `mv`. Put an equivalent entry back immediately rather than
  # leaving the vacancy open for any length of time.
  ln -s "$gtarget" "$lock" 2>/dev/null || true
  if [ -L "$lock" ] && [ "$(readlink "$lock" 2>/dev/null)" = "$gtarget" ]; then
    # R10-P3-4 (2026-09-12 round-10 review): "raced a live claim (pid %s)"
    # is wrong in two real cases this function itself can catch: a caught
    # empty-target claim ($gholder empty, printing an empty "(pid )"), and
    # a pid that matches the judged-stale holder's own but with a
    # different `started_at` (a recycled marker) -- a DIFFERENT identity
    # from the one just judged stale, not provably "live". Reporting the
    # raw caught identity (never empty in the printed string) instead of a
    # liveness claim this function did not re-verify is accurate in all
    # three cases.
    printf 'clikae: tank lock reaper for %s raced a claim it did not judge stale (identity: %s) -- restored it\n' "$lock" "${gtarget:-<empty>}" >&2
    rm -f "$grave" 2>/dev/null
  else
    printf 'clikae: tank lock reaper for %s raced a claim it did not judge stale (identity: %s) -- could NOT restore (the lock path is occupied) -- the claim is kept at %s\n' "$lock" "${gtarget:-<empty>}" "$grave" >&2
  fi
  return 1
}

# _burn_tank_lock_acquire <engine> <tank> [timeout_s=10] -> 0 once THIS
# process holds the per-tank lock, 1 on an ordinary timeout (ONLY: the
# reclaim mutex stayed busy, or a live holder never released), 2 if the
# reclaim mutex is a foreign object -- a TERMINAL refusal, never retried,
# never counted against the timeout (R9-P1-2/R9-P2-3, see
# `_BURN_LOCK_ACQUIRE_FOREIGN_MUTEX` above for the path).
#
# P2-4 (2026-09-09 round-1 review): the busy check (`burn_tank_busy`) and the
# `running` write that makes a tank busy for anyone ELSE'S check are two
# separate statements — between them sit nothing at all, but two `clikae
# burn` processes started together both reach the check before either has
# written `running`, and both pass. `ln -s` is atomic even without
# flock/lockf (works on bash 3.2, NFS, anywhere symlink(2) works), so it
# closes the SAME window `--ephemeral`'s slot_lock already closes for a
# different resource (see cmd_burn's own soul/MCP prelaunch lock further
# down) — held only across the check-and-write, never across the engine run
# itself.
#
# R3-P1-1/R3-P1-2/R3-P2-1 (2026-09-09 round-3 review): round 2's `mv`-aside
# reclaim broke mutual exclusion rather than fixing it — `mv` IS atomic, but
# the thing it made atomic was the wrong thing. `mv "$lock" "$graveyard"`
# VACATES the rendezvous path, and a vacated path is exactly what every
# OTHER contender's plain `mkdir` is waiting for; measured, the `mv` winner
# and the next `mkdir` winner were two different processes in 48% of trials
# — worse than the naive two-statement reclaim it replaced. Restoring a
# capture (`mv "$graveyard" "$lock"`) also silently NESTED instead of
# failing whenever `$lock` had been recreated in the meantime, leaking a
# directory a later reclaim couldn't see through. And the pid-less grace it
# also carried was reachable from ordinary fork/subshell lag on a loaded
# machine, not only a kill mid-`mkdir` — it could steal a perfectly live
# holder's lock if that holder merely stalled between claiming the path and
# writing its identity into it.
#
# The fix removes all three defects by construction:
#
#   1. The lock is a SYMLINK, never a directory. `ln -s "<pid>:<started_at>"
#      "$lock"` is one atomic syscall (`symlink(2)`, EEXIST for the loser)
#      that carries the holder's identity from the instant the path exists
#      — there is no window where the path is claimed but pid-less, so the
#      grace branch is gone entirely, not merely tightened.
#   2. Nothing that REMOVES the link — a stale reclaim, or an owner's own
#      release (see _burn_tank_lock_release below) — ever runs outside
#      _burn_reclaim_mutex_try's mutex above. Because the link can only
#      disappear while that mutex is held, and can only newly appear via
#      some contender's own unsynchronized `ln -s`, a reclaimer's
#      readlink→verify-dead→`rm`, done AFTER it holds the mutex, cannot
#      delete a link a fresh holder claimed after the reclaimer's first,
#      unsynchronized read — the re-read under the mutex is what's actually
#      acted on.
#   3. Acquisition itself (`ln -s`) never touches the mutex — only removal
#      does — so the common, uncontended case costs exactly one syscall,
#      same as the `mkdir` it replaces.
#
# R4-P2-1/R4-P2-2 (2026-09-10 round-4 review): two corners of the symlink
# design itself still weren't guarded. `[ -e "$lock" ] && [ ! -L "$lock" ]`
# (point 1's own leftover-directory guard, and the round-2 non-symlink
# check it descends from) DEREFERENCES via `-e`, so a symlink whose target
# resolves to an EXISTING DIRECTORY slips past it and reaches `ln -s`
# below, which then nests INTO that directory instead of failing (see the
# `-L "$lock" && -d "$lock"` branch further down) — the same
# destination-is-a-directory hazard as before, just indirected through a
# foreign symlink. And a durably empty-target link (`ln -s "" "$lock"`)
# was read as "vanished, retry immediately", forever, at full CPU, because
# nothing ever makes a genuinely empty target become non-empty — fixed by
# falling through to the ordinary stale-holder path instead of `continue`ing
# past it (an empty/malformed holder is already `stale=1` there).
_burn_tank_lock_acquire() {
  local eng="$1" tk="$2" timeout_s="${3:-10}" lock reclaim_dir start_s now_s
  local target holder hstarted stale now_epoch
  lock="$(_burn_tank_lock_path "$eng" "$tk")"
  reclaim_dir="${lock}.reclaim"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  chmod 0700 "$(dirname "$lock")" 2>/dev/null || true
  start_s=$SECONDS
  while :; do
    # Wall-clock ($SECONDS), checked at the TOP of every iteration —
    # including the reclaim path below — so the timeout bounds the WHOLE
    # loop, not just a "not stale, about to sleep" tail. A stuck reclaim
    # mutex (see _burn_reclaim_mutex_try) still can't spin this forever: its
    # own 30s stale rule reaps it long before most callers' timeouts.
    now_s=$SECONDS
    [ "$((now_s - start_s))" -lt "$timeout_s" ] || return 1
    if [ -e "$lock" ] && [ ! -L "$lock" ]; then
      # Some non-symlink entry occupies the path (e.g. a pre-round-3,
      # directory-style lock left by an older clikae) — checked and cleared
      # BEFORE ever attempting `ln -s` below, never after: `ln -s TARGET
      # LINKNAME` where LINKNAME is an existing DIRECTORY does not fail,
      # it creates the link INSIDE that directory (the same
      # destination-is-a-directory nesting hazard R3-P1-2 found in `mv`) —
      # so this path can never be allowed to reach the `ln -s` below while
      # it might still be a directory. It can't carry an identity either
      # way, so it is unconditionally reclaimable, under the same removal
      # mutex as everything else.
      if _burn_reclaim_mutex_try "$reclaim_dir"; then
        _BURN_RECLAIM_MUTEX_OWNED="$reclaim_dir"
        [ -e "$lock" ] && [ ! -L "$lock" ] && rm -rf "$lock" 2>/dev/null
        _burn_reclaim_mutex_release "$reclaim_dir"
        _BURN_RECLAIM_MUTEX_OWNED=""
      elif _burn_reclaim_mutex_is_foreign "$reclaim_dir"; then
        # R9-P1-2 (2026-09-11 round-9 review): a foreign object at the
        # RECLAIM MUTEX path (as opposed to at the lock itself, the case
        # this branch exists for) never self-heals -- `_burn_reclaim_mutex_
        # try` refuses it on EVERY call, forever, so looping back to
        # `continue` with no backoff spun this whole branch at up to ~89%
        # of a core, printing the refusal `try` already logged once, until
        # the caller's outer timeout -- measured 49,151 duplicate lines in
        # one 10s burn. Refuse ONCE more, terminally: exit the acquisition
        # loop immediately rather than retrying a condition that cannot
        # change without a human removing the object by hand.
        _BURN_LOCK_ACQUIRE_FOREIGN_MUTEX="$reclaim_dir"
        return 2
      else
        sleep 1   # an ordinary busy mutex -- back off like every other branch does
      fi
      continue
    fi
    if [ -L "$lock" ] && [ -d "$lock" ]; then
      # R4-P2-1 (2026-09-10 round-4 review): the check above uses `-e`,
      # which DEREFERENCES — a symlink whose target resolves to an
      # EXISTING DIRECTORY makes `-e` true and `-L` true at once, so the
      # branch above (which requires `! -L`) never fires for it, and `ln -s
      # TARGET "$lock"` below does not fail on such a path: it follows
      # `$lock` to that directory and creates the link INSIDE it, same
      # nesting hazard as the non-symlink case, just one level indirected
      # through a foreign symlink. Nothing this function ever writes
      # resolves to a real directory (`<pid>:<epoch>` never names a real
      # path), so `-L "$lock" && -d "$lock"` can only be a foreign or
      # corrupt link — unconditionally reclaimable, `rm -f` (not `-rf`:
      # this removes the SYMLINK itself, never the directory it points at).
      if _burn_reclaim_mutex_try "$reclaim_dir"; then
        _BURN_RECLAIM_MUTEX_OWNED="$reclaim_dir"
        [ -L "$lock" ] && [ -d "$lock" ] && rm -f "$lock" 2>/dev/null
        _burn_reclaim_mutex_release "$reclaim_dir"
        _BURN_RECLAIM_MUTEX_OWNED=""
      elif _burn_reclaim_mutex_is_foreign "$reclaim_dir"; then
        # R9-P1-2, the sibling site: same terminal refusal as the
        # non-symlink branch above, same reason.
        _BURN_LOCK_ACQUIRE_FOREIGN_MUTEX="$reclaim_dir"
        return 2
      else
        sleep 1   # an ordinary busy mutex -- back off like every other branch does
      fi
      continue
    fi
    now_epoch="$(date +%s 2>/dev/null || echo 0)"
    if ln -s "$$:$now_epoch" "$lock" 2>/dev/null; then
      # R9-P2-2 sibling site (2026-09-11 round-9 review): the same
      # check-then-act hazard the reclaim mutex's own claim has -- `ln -s`
      # returns rc=0 without landing at `$lock` when `$lock` resolves to a
      # directory that arrived in the window since the `-L "$lock" && -d
      # "$lock"` check above. Verify by `readlink` before believing we hold
      # the tank lock; on a mismatch, fall through to the same handling as
      # an outright `ln -s` failure below (this loop's normal retry path).
      if [ -L "$lock" ] && [ "$(readlink "$lock" 2>/dev/null)" = "$$:$now_epoch" ]; then
        return 0
      fi
    fi
    target="$(readlink "$lock" 2>/dev/null || true)"
    if [ -z "$target" ] && [ ! -L "$lock" ]; then
      # Genuinely vanished between our failed `ln -s` above and this
      # `readlink` (someone else's release or reclaim finishing) — it may
      # now be free; retry `ln -s` at the top immediately, no sleep.
      continue
    fi
    # R4-P2-2 (2026-09-10 round-4 review): note this does NOT re-test
    # `[ -z "$target" ]` alone — a link that is STILL THERE (`-L "$lock"`
    # true above) but whose target reads empty, e.g. a durable `ln -s ""
    # "$lock"`, occupies the path forever on its own: no future event ever
    # makes `readlink` return non-empty, so the old code's blanket "empty
    # means vanished, retry immediately" was an infinite hot spin — `ln -s`
    # keeps failing EEXIST against the same dead weight, `continue` keeps
    # firing with no sleep and no path to the reclaim logic below. Falling
    # through here instead of `continue`ing routes it into the exact same
    # stale-holder handling as any other unparseable payload (`holder=""`
    # matches the `''|*[!0-9]*` case just below), which needs no separate
    # sleep of its own: the reclaim mutex below already resolves this in
    # one pass.
    holder="${target%%:*}"
    hstarted="${target#*:}"
    stale=0
    case "$holder" in
      ''|*[!0-9]*) stale=1 ;;
      *)
        # Reuse the same liveness+identity test `burn_tank_busy` uses (P2-1,
        # round-1): a bare `kill -0` only proves SOMETHING is alive at that
        # pid, not that it's the SAME process the lock's own recorded
        # started_at names — this lock has exactly that recycled-pid
        # weakness too.
        if kill -0 "$holder" 2>/dev/null; then
          _burn_pid_matches_marker "$holder" "$hstarted" || stale=1
        else
          stale=1
        fi
        ;;
    esac
    if [ "$stale" -ne 1 ]; then
      sleep 1
      continue
    fi
    if _burn_reclaim_mutex_try "$reclaim_dir"; then
      _BURN_RECLAIM_MUTEX_OWNED="$reclaim_dir"
      # Re-verify under the mutex — required, not paranoia: the target may
      # have changed since the unsynchronized read above (a live holder
      # released, or the earlier reclaim finished, and a fresh contender's
      # `ln -s` landed on this exact path in the meantime). Only remove
      # what THIS read — taken while holding the one thing that can remove
      # it — still judges stale.
      #
      # R4-P2-2: test `-L` here, not `-n "$target"` — an empty-target
      # symlink (`-L` true, `readlink` empty) is still an OCCUPYING entry
      # that must be removed if stale; `-n "$target"` would treat it the
      # same as "already gone" and never remove it, permanently skipping
      # the one removal that could ever clear it.
      if [ -L "$lock" ]; then
        target="$(readlink "$lock" 2>/dev/null || true)"
        holder="${target%%:*}"
        hstarted="${target#*:}"
        stale=0
        case "$holder" in
          ''|*[!0-9]*) stale=1 ;;
          *)
            if kill -0 "$holder" 2>/dev/null; then
              _burn_pid_matches_marker "$holder" "$hstarted" || stale=1
            else
              stale=1
            fi
            ;;
        esac
        # R9-P1-1 (2026-09-11 round-9 review): this used to `rm -f "$lock"`
        # directly on `$stale -eq 1` -- a bare readlink-decide-then-rm on
        # the path, not on the entry actually caught. The reclaim mutex
        # held across this whole block serialises REMOVERS (only one
        # process ever reaches this `rm`), but it does not and cannot
        # serialise CLAIMANTS: a claim is the bare `ln -s` above, which
        # takes no mutex at all. Between the `readlink` a few lines up and
        # the `rm -f` this replaces, `_burn_pid_matches_marker` forks `ps`
        # AND `date` -- milliseconds under load -- and a live burn's fresh
        # claim landing in that fork-sized window was deleted while it was
        # inside its own check-and-write, producing two engines on one
        # tank. Measured through real binaries: 6 overlaps in 130 trials
        # with `clikae clean` racing `clikae burn`; deterministically 5/5
        # with a hook. `_burn_tank_lock_reap_verified` closes it with the
        # same `mv`-then-classify discipline `_burn_reclaim_mutex_try`
        # already uses on itself, applied here to the LOCK: it re-catches
        # whatever is actually at `$lock` atomically and only discards it
        # if it still names the exact identity judged stale right above.
        #
        # R10-P3-1 (2026-09-12 round-10 review): `_burn_tank_lock_reap_
        # verified` returns 1 in three ordinary, non-error cases (someone
        # else already removed/released it; it caught and restored a live
        # claim -- this whole helper's reason for existing; a restore that
        # itself failed and kept the grave), and as the LAST command of an
        # `&&` list under this file's `set -eo pipefail`, a `1` here used
        # to terminate this function immediately via errexit -- it only
        # didn't, in practice, because `cmd_burn`'s own call site happens
        # to wrap this whole function in `|| _lock_acquire_rc=$?`, and
        # errexit's suppression propagates into the callee. That is a
        # correctness argument, not a guard against a caller who calls
        # this function bare: it made itself safe rather than depending on
        # its one caller shielding it forever.
        if [ "$stale" -eq 1 ]; then
          _burn_tank_lock_reap_verified "$lock" "$holder" "$hstarted" || true
        fi
      fi
      _burn_reclaim_mutex_release "$reclaim_dir"
      _BURN_RECLAIM_MUTEX_OWNED=""
    elif _burn_reclaim_mutex_is_foreign "$reclaim_dir"; then
      # R9-P1-2/R9-P2-3: the third call site with the same permanent
      # refusal -- terminal, not a busy-mutex backoff. Measured on this
      # exact fixture (a dead-holder lock, foreign reclaim mutex): the old
      # shape spun the sibling `sleep 1` branch below for the WHOLE
      # timeout, ending in the generic "try again shortly" busy-timeout
      # message for a condition that never times out on its own.
      _BURN_LOCK_ACQUIRE_FOREIGN_MUTEX="$reclaim_dir"
      return 2
    else
      # R5-P2-4 (2026-09-10 round-5 review; the other half of R4-P2-2): the
      # mutex being unclaimable right now (someone else holds it, or it's
      # not yet 30s stale) fell straight through to the `continue` below
      # with no sleep at all, spinning at full CPU for the rest of the
      # timeout — measured ~79% of a core per blocked burn, on every tank
      # merely recovering from a signal. The "holder is live" branch four
      # lines up already sleeps 1s between retries; this path costs
      # nothing extra to match it.
      sleep 1
    fi
    continue   # whether we reclaimed it, someone else already did, or a
               # fresher check now says it's live — retry `ln -s` at the top
  done
}

# _burn_tank_lock_release <engine> <tank> — safe to call unconditionally on
# every exit path out of the locked section (a timed-out acquire that never
# held the lock, a signal mid-check, the normal release after the write —
# see the trap installed around the locked section in cmd_burn below).
#
# R3-P1-1 (2026-09-09 round-3 review): removal — like a stale reclaim — only
# ever happens while holding the reclaim mutex (see _burn_reclaim_mutex_try
# and _burn_tank_lock_acquire above), and only when the link, re-read AFTER
# the mutex is held, still names THIS process — never on trust that "I must
# be the one who called acquire". Without that second check, a caller that
# raced the lock away (timed out while someone else holds it, or is
# cleaning up after a signal whose acquire never actually succeeded) would
# delete a lock a DIFFERENT, live process is legitimately holding.
#
# The retry here is bounded, not a bare loop, because this runs from exit
# traps: real contention on the mutex is a momentary thing (its own hold
# time is a readlink and an rm/rmdir), so a handful of one-second retries
# covers it, and the mutex's own 30s stale-reap bounds how long a truly
# wedged mutex could ever block a FUTURE caller. Giving up here just means
# this particular release didn't run this time — it never means a lock this
# process doesn't own gets deleted.
#
# R5-P2-3 (2026-09-10 round-5 review): a signal can land while THIS
# process already holds the reclaim mutex from _burn_tank_lock_acquire's
# own reclaim path (see _BURN_RECLAIM_MUTEX_OWNED above). Looping on
# _burn_reclaim_mutex_try in that situation deadlocks against ourselves —
# the mutex's own liveness check sees our own live pid, correctly judges
# it not abandoned, and refuses to evict it, for the full retry budget —
# and the EXIT trap this function's caller's own `exit` then triggers runs
# this same function a second time and pays the same cost again (measured:
# 18-19s to exit, mutex leaked). Checking ownership first and acting
# directly under the mutex already held, instead of trying to reacquire
# it, closes both.
_burn_tank_lock_release() {
  local lock reclaim_dir target holder tries=0
  lock="$(_burn_tank_lock_path "$1" "$2")"
  reclaim_dir="${lock}.reclaim"
  if [ -n "$_BURN_RECLAIM_MUTEX_OWNED" ] && [ "$_BURN_RECLAIM_MUTEX_OWNED" = "$reclaim_dir" ]; then
    target="$(readlink "$lock" 2>/dev/null || true)"
    holder="${target%%:*}"
    [ "$holder" = "$$" ] && rm -f "$lock" 2>/dev/null
    _burn_reclaim_mutex_release "$reclaim_dir"
    _BURN_RECLAIM_MUTEX_OWNED=""
    return 0
  fi
  while ! _burn_reclaim_mutex_try "$reclaim_dir"; do
    tries=$((tries + 1))
    [ "$tries" -lt 10 ] || return 0
    sleep 1
  done
  _BURN_RECLAIM_MUTEX_OWNED="$reclaim_dir"
  target="$(readlink "$lock" 2>/dev/null || true)"
  holder="${target%%:*}"
  [ "$holder" = "$$" ] && rm -f "$lock" 2>/dev/null
  _burn_reclaim_mutex_release "$reclaim_dir"
  _BURN_RECLAIM_MUTEX_OWNED=""
  return 0
}

# Preserve combined output while retaining stderr alone for launch diagnostics.
_burn_capture_stderr() {
  local capture_rc=0
  # fd 3 saves stdout before the pipe connects only stderr to tee.
  { "$@" 2>&1 1>&3; } | tee "$stderr_file" >&2
  capture_rc=${PIPESTATUS[0]}
  return "$capture_rc"
} 3>&1

# _burn_check_codex_git_cwd — refuse to compose a codex argv whose cwd isn't a
# git work tree. Reads $cli/$prompt_set/$codex_skip_git_check/$add_dirs from
# the caller (cmd_burn's locals — same pattern _burn_result etc. already use).
#
# #66 round-1 P1-1: this used to be inlined once, at cmd_burn's entry, and
# only ever ran against the engine NAMED ON THE COMMAND LINE. A dry tank's
# cross-engine reroute (~2525 below) overwrites that same $cli variable and
# recomposes the argv for the new engine — so a reroute INTO codex from
# another engine skipped this check entirely and let codex itself reject the
# non-git cwd a run and a tank later, after the earlier engine's state
# (log dir, status.json, lock) had already been created. Called again at the
# reroute site, right before the new engine's argv is composed, so landing on
# codex is checked exactly where landing on codex first was.
_burn_check_codex_git_cwd() {
  [ "$cli" = codex ] || return 0
  [ "$prompt_set" -eq 1 ] || return 0
  [ "$codex_skip_git_check" -eq 0 ] || return 0
  local dir="${add_dirs[0]}"
  # #66 round-1 P3-2: `git -C <missing dir> rev-parse` also prints "not
  # inside a git work tree" (its own stderr, discarded below) for a cwd that
  # doesn't exist at all — name the actual cause instead of the wrong one.
  [ -d "$dir" ] || log_fail "codex cwd '$dir' does not exist."
  if [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
    log_fail "codex cwd '$dir' is not inside a git work tree; put the repository first in --add-dir, or pass --codex-skip-git-check."
  fi
}

# _burn_sanitize_reason <raw-line> — make an engine's own stderr safe to carry
# as a JSON string value.
#
# #66 round-1 P2-1: json_str (lib/core/json.sh) only escapes the seven C
# control chars JSON gives dedicated shorthand for (\t \n \r \b \f " \) — any
# OTHER byte in U+0000-U+001F, most commonly a bare ESC (0x1B) from an ANSI
# color code, passed straight through into the `--json` output verbatim.
# RFC 8259 requires every one of those to be escaped; a raw one makes the
# whole object invalid JSON for a strict parser, which is worse than the
# prose burn --json exists to replace (a strict parser can't even start
# reading it). Strip ANSI CSI sequences outright (the common, recoverable
# case: color codes an engine prints whether or not stdout is a tty), then
# turn every remaining control byte into a space — trading "illegal JSON"
# for "ugly reason text", never the other way round.
#
# P3-3 (2026-09-12 round-2 review): this used to also `tr -s ' '` the
# result, squeezing every run of spaces down to one — including runs the
# engine's own message legitimately printed, which had nothing to do with
# a replaced control byte. Only the control-byte substitution needs to
# stay safe for JSON; a real "two spaces" in the stderr line is not this
# function's problem to fix.
_burn_sanitize_reason() {
  local s="$1"
  s="$(printf '%s' "$s" | sed -E $'s/\x1b\\[[0-9;]*[a-zA-Z]//g')"
  s="$(printf '%s' "$s" | LC_ALL=C tr '\000-\037' ' ')"
  printf '%s' "$s"
}

# _burn_truncate_utf8 <str> <max-bytes> — cut <str> to at most <max-bytes>
# bytes without splitting a multibyte UTF-8 character.
#
# #66 round-1 P2-2: the original `${stderr_first:0:200}` truncates by
# CHARACTER count only when the shell's own locale is UTF-8-aware. Under
# C/POSIX — bash 3.2's default when LANG/LC_ALL/LC_CTYPE are unset, a real
# state for an unattended/containerized caller, which is exactly who invokes
# `clikae burn --json` — it degrades to raw BYTES, so a multibyte character
# sitting across the 200-byte boundary gets sliced in half, writing invalid
# UTF-8 into the JSON output. `local LC_ALL=C` forces byte semantics
# EXPLICITLY, in THIS function only, regardless of the caller's environment,
# so the cut point is deterministic; then back off any lead byte at the tail
# whose continuation bytes didn't make it into the cut.
_burn_truncate_utf8() {
  local LC_ALL=C
  local s="$1" max="$2" len
  len=${#s}
  [ "$len" -le "$max" ] && { printf '%s' "$s"; return; }
  local cut="${s:0:max}"
  local clen=${#cut} k pos c ord cont_needed=-1
  local look=4; [ "$clen" -lt "$look" ] && look=$clen
  for ((k = 1; k <= look; k++)); do
    pos=$((clen - k))
    c="${cut:pos:1}"
    ord="$(printf '%d' "'$c")"
    [ "$ord" -lt 0 ] && ord=$((ord + 256))
    if [ "$ord" -ge 240 ]; then cont_needed=3; break
    elif [ "$ord" -ge 224 ]; then cont_needed=2; break
    elif [ "$ord" -ge 192 ]; then cont_needed=1; break
    elif [ "$ord" -ge 128 ]; then continue
    else cont_needed=-1; break
    fi
  done
  if [ "$cont_needed" -ge 0 ] && [ $((k - 1)) -lt "$cont_needed" ]; then
    cut="${cut:0:pos}"
  fi
  printf '%s' "$cut"
}

cmd_burn() {
  local cli="" tank="" artifact="" to="" timeout_s="" reroute=1 allow_active=0 fresh=0 as_json=0
  local prompt="" prompt_file="" prompt_set=0 codex_skip_git_check=0
  local burn_permission=acceptEdits permission_set=0
  local infra_retries=2 infra_delay=5 infra_attempt=0 retry_delay=5
  local wait_for_reset_raw="" wait_for_reset_s=""
  local -a cmd=() add_dirs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)    _burn_help; return 0 ;;
      --artifact)   shift; [ $# -gt 0 ] || log_fail "--artifact needs a path"; artifact="$1"; shift ;;
      --to)         shift; [ $# -gt 0 ] || log_fail "--to needs a target"; to="$1"; shift ;;
      --timeout)    shift; [ $# -gt 0 ] || log_fail "--timeout needs seconds"; timeout_s="$1"; shift ;;
      --permission)
        shift
        case "${1:-}" in
          acceptEdits|auto) burn_permission="$1"; permission_set=1; shift ;;
          *) log_fail "--permission must be acceptEdits or auto" ;;
        esac
        ;;
      --prompt)     shift; [ $# -gt 0 ] || log_fail "--prompt needs a string"; prompt="$1"; prompt_set=1; shift ;;
      --prompt-file) shift; [ $# -gt 0 ] || log_fail "--prompt-file needs a path"; prompt_file="$1"; shift ;;
      --add-dir)    shift; [ $# -gt 0 ] || log_fail "--add-dir needs a path"; add_dirs+=("$1"); shift ;;
      --infra-retries) shift; [ $# -gt 0 ] || log_fail "--infra-retries needs a count"; infra_retries="$1"; shift ;;
      --infra-delay) shift; [ $# -gt 0 ] || log_fail "--infra-delay needs seconds"; infra_delay="$1"; shift ;;
      --wait-for-reset) shift; [ $# -gt 0 ] || log_fail "--wait-for-reset needs a duration (e.g. 30m)"; wait_for_reset_raw="$1"; shift ;;
      --codex-skip-git-check) codex_skip_git_check=1; shift ;;
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

  if [ -n "$wait_for_reset_raw" ]; then
    wait_for_reset_s="$(_burn_parse_duration "$wait_for_reset_raw")" \
      || log_fail "--wait-for-reset: not a duration: $wait_for_reset_raw  (use e.g. 30m, 2h, 90s, or a bare integer of seconds)"
  fi

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
  # P3-2 (2026-09-12 round-1 review): this only needs prompt_set, which is
  # settled right above — no reason to wait for the lock/state-file section
  # further down. Same discipline as --permission's own value validation: a
  # warning that's already true doesn't need to wait for state to exist.
  if [ "$prompt_set" -eq 0 ] && [ "$permission_set" -eq 1 ]; then
    log_warn "--permission does not modify raw engine argv; set the engine permission flag after --."
  fi
  # P3-6 (2026-09-12 round-1 review): the opposite gap — prompt mode composes
  # --permission-mode itself, and #24's escape hatch (extra argv after --,
  # appended verbatim after the generated flags) can duplicate or override it
  # silently. Warn without touching argv: -- stays a power-user escape hatch,
  # unchanged (docs/orchestration.md already says extra args still follow the
  # generated flags).
  if [ "$prompt_set" -eq 1 ]; then
    local _burn_dupe_permission_flag=0 _burn_post_arg
    for _burn_post_arg in "${cmd[@]}"; do
      case "$_burn_post_arg" in
        --permission-mode|--dangerously-skip-permissions) _burn_dupe_permission_flag=1; break ;;
      esac
    done
    if [ "$_burn_dupe_permission_flag" -eq 1 ]; then
      log_warn "raw argv after -- includes --permission-mode or --dangerously-skip-permissions; clikae's own --permission-mode is composed first and the two may collide."
    fi
  fi
  # #66 round-1 P3-1: the flag is parsed unconditionally but only ever does
  # anything for a codex run composed from --prompt/--prompt-file (raw argv
  # owns its own cwd/git-check policy, documented in --help). Silently
  # swallowing it elsewhere reads as "I turned on a protection" when nothing
  # happened — say so instead of staying quiet.
  if [ "$codex_skip_git_check" -eq 1 ] && { [ "$cli" != codex ] || [ "$prompt_set" -ne 1 ]; }; then
    log_warn "--codex-skip-git-check has no effect here: it only applies to a codex run started with --prompt/--prompt-file."
  fi
  # Validate the cwd we compose, before carry notices, logs, status or locks.
  # Raw argv owns its own cwd and git-check policy.
  _burn_check_codex_git_cwd
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
  # P2-4 (2026-09-09 round-1 review): hold a per-tank lock across the
  # check-and-write below — without it, two `clikae burn` processes started
  # together both reach the check before either has written `running`, and
  # both pass (see _burn_tank_lock_acquire's comment). Never held past this
  # block: the engine run itself, and everything else in this function, is
  # outside the lock.
  #
  # P2-1 (2026-09-09 round-2 review): every exit out of this section — the
  # lock-timeout refusal, the busy refusal, a signal landing mid-check — has
  # to release the lock; explicit releases on each branch alone miss a
  # signal arriving BETWEEN them (there is no trap covering this window yet:
  # `_burn_install_exit_trap` below is only reached once the lock is already
  # gone). A trap scoped to exactly this section closes that gap; cleared
  # again once the section's own explicit release has run, so it never
  # outlives the few statements it exists for.
  #
  # R3-P3-1 (2026-09-09 round-3 review): a signal landing IN this window used
  # to release the lock and exit without ever writing a status file — the
  # very gap this same commit closes for its two sibling branches (the
  # lock-timeout and busy refusals just below). `_burn_exit_guard` is
  # already exactly that safety net (installed one section later, for the
  # locked-out-window-after-this-one) — it no-ops once a terminal state is
  # already on disk, so reusing it here rather than duplicating its "write a
  # generic fail" logic is free: `run_dir`/`burn_id`/`started_at` are all
  # already set by this point in cmd_burn, and status_engine/tank fall back
  # correctly via the same dynamic-scoping convention it already documents.
  if [ "$allow_active" != "1" ]; then
    trap '_burn_tank_lock_release "$status_engine" "$tank"; _burn_exit_guard 129; exit 129' HUP
    trap '_burn_tank_lock_release "$status_engine" "$tank"; _burn_exit_guard 130; exit 130' INT
    trap '_burn_tank_lock_release "$status_engine" "$tank"; _burn_exit_guard 143; exit 143' TERM
    trap '_burn_tank_lock_release "$status_engine" "$tank"; _burn_exit_guard "$?"' EXIT
    # 🔴 `cmd || rc=$?`, never a bare `cmd; rc=$?` — this whole file runs
    # under bin/clikae's `set -eo pipefail`. A bare failing statement here
    # is NOT the condition of any if/while/&&/||, so `set -e` aborts this
    # function's execution AT THAT STATEMENT, before `_lock_acquire_rc=$?`
    # or either `if` below ever runs — verified: it does not merely skip to
    # the wrong branch, it exits immediately into the EXIT trap, which
    # calls `_burn_tank_lock_release` (itself then retrying against the
    # same foreign mutex for its own ~10-try backoff) and then
    # `_burn_exit_guard`'s generic "burn exited without reaching a terminal
    # state" fallback — neither the `foreign-mutex:` nor the `busy:` reason
    # below is ever written. `cmd || rc=$?` keeps the whole statement's own
    # exit status at 0 (the assignment succeeds) so `set -e` never fires,
    # while still capturing the real code.
    local _lock_acquire_rc=0
    _burn_tank_lock_acquire "$status_engine" "$tank" || _lock_acquire_rc=$?
    if [ "$_lock_acquire_rc" -eq 2 ]; then
      # R9-P1-2/R9-P2-3 (2026-09-11 round-9 review): a foreign object at the
      # reclaim mutex never self-heals, so `_burn_tank_lock_acquire` returns
      # this terminally rather than after the ordinary timeout — and until
      # this round the status file and the terminal message both collapsed
      # it into the generic busy-timeout case below, which asserts a false
      # cause ("mid self-heal … try again shortly") for the one condition
      # of the three that never self-heals (the same false-assertion shape
      # R6-P2-4 rewrote this same message to remove, for the SIGKILL case).
      trap - HUP INT TERM EXIT
      _burn_status_write fail false "$status_engine" "$tank" "$artifact" \
        "foreign-mutex: $_BURN_LOCK_ACQUIRE_FOREIGN_MUTEX" ""
      log_fail "clikae: reclaim mutex at $_BURN_LOCK_ACQUIRE_FOREIGN_MUTEX is a foreign-mutex (a directory, a symlink to one, or a plain file) -- remove it by hand, then retry."
    fi
    if [ "$_lock_acquire_rc" -ne 0 ]; then
      trap - HUP INT TERM EXIT
      # P3-1 (2026-09-09 round-2 review): see the busy-refusal write below —
      # the same "documented composition sees a stall, not a fail" gap.
      _burn_status_write fail false "$status_engine" "$tank" "$artifact" \
        "busy: timed out waiting for the busy-tank lock on $status_engine/$tank" ""
      # R6-P2-4 (2026-09-10 round-6 review): this refusal ALSO fires for a
      # SIGKILLed burn's lock — mutual exclusion was never broken, but the
      # old, single-cause message ("another clikae burn is mid-check")
      # asserted something false: there is no other burn, it died, and the
      # tank self-heals once the mutex's own 30s stale rule reaches it (a
      # ~30s total denial, measured — see docs/orchestration.md). The
      # timeout gives no way to tell the two apart from here, so the
      # message now names both rather than asserting the wrong one.
      log_fail "Timed out waiting for the busy-tank lock on $status_engine/$tank — either another clikae burn is genuinely mid-check on it right now, or the previous holder died and the tank is mid self-heal (up to ~30s after a kill); try again shortly."
    fi
    if burn_tank_busy "$status_engine" "$tank" "$$"; then
      _burn_tank_lock_release "$status_engine" "$tank"
      trap - HUP INT TERM EXIT
      # P3-1 (2026-09-09 round-2 review): a refusal this early has never
      # reached the first `running` write, so the documented `clikae burn …
      # & clikae wait "burn-$!"` composition finds no status file at all and
      # reads a 9-second-old refusal as "hasn't started yet" — stalling for
      # the whole resolve window before giving up. `fail` is always
      # terminal (it can never make this tank look busy to anyone else), so
      # writing it before the refusal costs nothing.
      _burn_status_write fail false "$status_engine" "$tank" "$artifact" \
        "busy: $status_engine/$tank already has a running burn on it (#40)" ""
      log_fail "$status_engine/$tank already has a running burn on it (#40) — clikae wait <its run id> to block on it, or --allow-active to run anyway (they will collide on the same tmux session)."
    fi
    _burn_status_write running null "$status_engine" "$tank" "$artifact" "" ""
    _burn_tank_lock_release "$status_engine" "$tank"
    trap - HUP INT TERM EXIT
  else
    _burn_status_write running null "$status_engine" "$tank" "$artifact" "" ""
  fi
  # P1-1 (2026-09-09 round-1 review): from here on, a status file exists that
  # claims this burn is `running` — install the safety net that keeps that
  # promise honest no matter how this process ends (see `_burn_exit_guard`'s
  # own comment above `_burn_status_write`).
  _burn_install_exit_trap

  case "$cli" in
    agy|antigravity)
      if ! _agy_enabled; then
        _burn_status_write fail false "$status_engine" "$tank" "$artifact" "agy multi-account isn't set up yet" ""
        log_fail "agy multi-account isn't set up yet. Create a tank first:  clikae init agy $tank"
      fi
      [ "$prompt_set" -eq 1 ] || log_fail "agy burn only supports the --prompt / --prompt-file form (agy has no adapter to fill in a raw '-- <cmd...>')."
      [ -z "$to" ] || log_fail "--to isn't supported for agy — it walks its own tanks (clikae init agy <name> to add more)."
      # For agy, whatever followed `--` is EXTRA AGY FLAGS, not a raw command:
      # there is no adapter to compose, so `--prompt` still carries the task and
      # these ride alongside it. They used to be parsed and then silently dropped.
      # P3-1/P3-4 (2026-09-12 round-1 review): fire for an EXPLICIT acceptEdits
      # too, not just auto — agy has no permission mapping at all, so either
      # value is equally unmet; name it via $status_engine (already normalized
      # to "agy" above, #40) rather than a third hardcoded spelling of the same
      # engine.
      if [ "$permission_set" -eq 1 ]; then
        log_warn "$status_engine has no equivalent for --permission $burn_permission; keeping its existing burn flags."
      fi
      _agy_burn "$tank" "$prompt" "$artifact" "$timeout_s" "$fresh" "$reroute" "$wait_for_reset_s" "$allow_active" \
                "${#cmd[@]}" ${cmd[@]+"${cmd[@]}"} ${add_dirs[@]+"${add_dirs[@]}"}
      return $?
      ;;
  esac
  # Keep the verbatim post-`--` argv aside; in --prompt mode it's appended after
  # the engine's generated flags (an escape hatch for extra per-engine args).
  local -a post_cmd=("${cmd[@]}")
  load_adapter "$cli"
  local binary; binary="$(adapter_meta_cli_binary)"
  if ! command -v "$binary" >/dev/null 2>&1; then
    _burn_status_write fail false "$cli" "$tank" "$artifact" "'$binary' is not on PATH" ""
    log_fail "'$binary' is not on PATH."
  fi
  local envvar; envvar="$(adapter_meta_env_var 2>/dev/null || true)"   # for the in-use guard
  if [ "$prompt_set" -eq 1 ]; then
    if ! declare -F adapter_burn_flags >/dev/null; then
      _burn_status_write fail false "$cli" "$tank" "$artifact" "$cli has no headless-write recipe (no adapter_burn_flags)" ""
      log_fail "$cli has no headless-write recipe (adapter defines no adapter_burn_flags). Use the explicit '-- <cmd...>' form."
    fi
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
    local dir
    if ! dir="$(ensure_profile --require "$cli" "$cur")"; then
      # ensure_profile --require already printed its own error (log_err, from
      # inside the command-substitution subshell) — no need to repeat it here.
      # P1-1: this is one of the "four early log_fail paths" the round-1
      # review named; the generic EXIT trap installed above would also catch
      # it (ensure_profile's own `exit 1` only ends its subshell, but the
      # failed assignment then trips `set -e` in THIS shell), but writing
      # `fail` explicitly here gives a caller a reason worth reading instead
      # of the trap's generic "exited without a terminal state".
      _burn_status_write fail false "$cli" "$cur" "$artifact" "profile not found: $cli/$cur" ""
      return 1
    fi

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
    local stderr_file="$run_dir/${run_id}.stderr" attempt_started=$SECONDS
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
    
    local attempt_epoch
    attempt_epoch="$(date +%s)"
    local launch_sid=""
    local -a _attempt_cmd=("${cmd[@]}")
    if declare -F adapter_new_session_args >/dev/null 2>&1; then
      launch_sid="$(uuidgen 2>/dev/null || true)"
      if [ -z "$launch_sid" ] && command -v python3 >/dev/null 2>&1; then
        launch_sid="$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || true)"
      fi
      launch_sid="$(printf '%s' "$launch_sid" | LC_ALL=C tr 'A-Z' 'a-z')"
      if [ -n "$launch_sid" ]; then
        local _nsline
        while IFS= read -r _nsline; do
          [ -n "$_nsline" ] && _attempt_cmd+=("$_nsline")
        done <<_NS_EOF
$(adapter_new_session_args "$launch_sid" 2>/dev/null || true)
_NS_EOF
      fi
    fi
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
        declare -f _clikae_mtime _burn_size _burn_snapshot _burn_capture_stderr
        printf 'stderr_file=%q\n' "$stderr_file"
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
  _burn_capture_stderr $(printf "%q " "${runner[@]}" "$binary" "${_attempt_cmd[@]}") </dev/null || engine_rc=\$?
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
          _burn_capture_stderr "${runner[@]}" "$binary" "${_attempt_cmd[@]}" </dev/null 2>&1 || engine_rc=$?
          _burn_snapshot "$artifact" "$art_pre" "$evidence_file"
          exit "$engine_rc"
        )" || rc=$?
        # Neither direct-execution fallback pipes through `tee "$log_file"`
        # the way the tmux wrapper script above does, so `$log_file` was
        # never actually created here even though `_burn_status_write`'s
        # "log" field always names it -- a status reader followed a path
        # that only existed when tmux happened to be on PATH. Write the
        # captured output there too, so the contract holds regardless of
        # which path ran.
        printf '%s\n' "$out" > "$log_file" 2>/dev/null || true
      fi
    else
      out="$(
        while IFS= read -r kv; do [ -n "$kv" ] && export "${kv%%=*}"="${kv#*=}"; done <<KV
$(adapter_export_env "$dir")
KV
        engine_rc=0
        _burn_capture_stderr "${runner[@]}" "$binary" "${_attempt_cmd[@]}" </dev/null 2>&1 || engine_rc=$?
        _burn_snapshot "$artifact" "$art_pre" "$evidence_file"
        exit "$engine_rc"
      )" || rc=$?
      # Same gap as the "tmux failed to start" fallback above: no tmux at
      # all means no `tee "$log_file"` ever ran.
      printf '%s\n' "$out" > "$log_file" 2>/dev/null || true
    fi
    
    if [ -f "$evidence_file" ]; then
      read -r artifact_fresh artifact_bytes_snapshot < "$evidence_file"
    fi
    rm -f "$state_file" "$evidence_file"

    local sid_to_record="$launch_sid"
    if [ -z "$sid_to_record" ] && declare -F adapter_recent_sids >/dev/null 2>&1; then
      local recent
      recent="$(adapter_recent_sids "$dir" 1 2>/dev/null || true)"
      if [ -n "$recent" ]; then
        local r_epoch="${recent%%$'\037'*}"
        local r_sid="${recent##*$'\037'}"
        if [ -n "$r_epoch" ] && [ "$r_epoch" != "?" ] && [ "$r_epoch" -ge "$attempt_epoch" ]; then
          sid_to_record="$r_sid"
        fi
      fi
    fi
    if [ -n "$sid_to_record" ]; then
      local sidecar_file="$CLIKAE_HOME/state/burn-sessions/$cli/$cur"
      mkdir -p "$(dirname "$sidecar_file")" 2>/dev/null || true
      printf '%s\t%s\t%s\n' "$sid_to_record" "$run_id" "$(date +%s)" >> "$sidecar_file"
    fi

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
        # codex's hard-limit text above is the only DRY signal; a HEALTHY
        # codex run still has something worth showing — its own 5h/weekly
        # usage, which codex persists (headless `codex exec` included,
        # confirmed on this machine's own rollouts) as a `rate_limits`
        # reading regardless of whether anything ran dry. Proactive, not a
        # limit event — this is why `burn --json` used to print
        # `"reset": null` on a run that never hit anything at all (see
        # docs/DESIGN-board-fuel-dots.md). claude/agy are untouched: they
        # have no such vendor-reported reading to relay.
        if [ "$cli" = codex ]; then
          local _cx_status
          if _cx_status="$(limit_codex_status "$(profile_dir codex "$cur")" \
                              "$(date +%s 2>/dev/null || echo 0)" 2>/dev/null)"; then
            IFS=$'\037' read -r _ _ live_reset <<< "$_cx_status"
          fi
        fi
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

      # P1-2 (2026-09-09 round-1 review): the terminal `dry` write used to
      # land HERE, unconditionally, before ever checking --wait-for-reset —
      # so a tank about to sleep a few minutes and finish the SAME task told
      # every #41/#40 reader (`wait`, `burn_tank_busy`) "this run is OVER,
      # and it went dry" for the entire sleep. Decide first; only the
      # branches that really abandon this tank write a terminal `dry`.
      # Deliberately BEFORE the dry_store_mark / dried_accts bookkeeping
      # below and the reroute decision further down: a tank that only WAITED
      # never gets counted as tried, marked dry on disk, or excluded as a
      # same-account sibling — from the rest of this loop's point of view,
      # nothing happened yet.
      if [ -n "$wait_for_reset_s" ] && [ -n "$reset" ] \
         && _burn_wait_for_reset "$cli" "$cur" "$artifact" "$reset" "$wait_for_reset_s"; then
        log_info "$cli/$cur should be reset now — re-firing on the same tank."
        infra_attempt=0; retry_delay="$infra_delay"
        continue
      fi

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
      local failure_reason="no fresh artifact and no limit" stderr_first=""
      if [ "$((SECONDS - attempt_started))" -le 5 ] && [ -s "$stderr_file" ]; then
        stderr_first="$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;q;}' "$stderr_file")"
        stderr_first="$(_burn_sanitize_reason "$stderr_first")"
        failure_reason="$(_burn_truncate_utf8 "$stderr_first" 200)"
      fi
      _burn_status_write fail false "$cli" "$cur" "$artifact" "$failure_reason" ""
      _burn_result false "$cli" "$cur" "$artifact" "$failure_reason"
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
        # #66 round-1 P1-1: re-check here, now that $cli IS $nx_cli — a
        # reroute landing on codex composes a fresh -C argv from $add_dirs[0]
        # exactly like the entry check did, so it needs the same refusal.
        _burn_check_codex_git_cwd
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
