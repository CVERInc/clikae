# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **A pre-push guard refuses a push that changes `lib/` or `bin/` without
  touching `CHANGELOG.md`.** At 0.28.0, nineteen commits shipped and exactly one
  had updated the changelog; the release notes were reconstructed afterwards from
  commit messages, which worked only because someone sat down and did it. Narrow
  on purpose — `tests/`, `docs/`, `hooks/` and `scripts/` do not trip it, and the
  granularity is the push rather than the commit, so writing the notes just before
  pushing is fine. `CLIKAE_SKIP_CHANGELOG=1 git push` is the escape for a genuinely
  invisible change, and it says so out loud rather than passing silently.

## [0.28.0] — 2026-08-20

The board got roughly three times faster to open and five times faster to move
around in, and stopped telling four different lies while it did. Measured on the
maintainer's real store (9 tanks, 5.2 GB, 1,384 transcripts), 0.27.1 and this
release run back to back on the same machine, median of nine interleaved runs:

    board opens          1329 ms  ->  403 ms   (-70%)
    redraw per keypress   256 ms  ->   51 ms   (-80%)

Minor, not patch: the burn order changed meaning (solo tanks no longer hold a
position in it), the fuel dots changed shape, and an agy tank's ACCOUNT column
can now report a different — correct — account than it did before.

Every fix below ships with a regression test proven to go red on the pre-fix
code. The two rewrites with the widest blast radius were checked by differential
instead: the title extractor against all 1,384 transcripts in the store (titles
byte-identical), and the whole board against four terminal widths (output
byte-identical). The three background scans added here were checked for races by
rendering 60 times and requiring every run to be byte-identical.

### Fixed

- **A resumed session could open onto a dead tank: the countdown window with no
  engine to type into.** Reported as "`clikae resume` → pick a session → switch
  tank → sometimes it just hangs."

  The cause is a guard that has never once fired. `wake_watch` (and `wake_sit`)
  ask "am I the last window left — did the engine exit?", and both wrote the test
  with the inside-single-quotes escape idiom at the TOP level of the line:

  ```
  -F '"'"'#{window_name}'"'"'       →  tmux received   "'#{window_name}'"
  grep -qvE '"'"'^wake( |$)'"'"'    →  grep received   "'^wake( |$)'"
  ```

  So tmux emitted `'wake'` with the quotes included, and grep was handed a
  pattern whose `^` sits mid-string and therefore matches nothing — making
  `grep -qv` succeed on every input. The condition was constant-true, so the
  watcher kept looping after the engine window closed, **the tmux session it
  lives in never died**, and the next launch onto that same session name found
  `tmux has-session` true, started no engine, and dropped you into the `wake`
  window showing "watching for a limit" with nothing to type into.

  That is precisely the failure this guard was added for on 2026-08-15 ("the user
  was stranded on 'watching for a limit' with no way out but closing the
  terminal") — the fix shipped mis-quoted and was never exercised, because the
  only test covering the watcher's exit killed the whole *session*, which trips a
  different branch. Verified against real tmux; the new regression test is
  time-bounded on purpose (a naive one passes on the broken code too, since the
  session eventually dies on its own and the other exit covers for it).

- **The bare switch could start an engine and say nothing.** Inside tmux with no
  client on the current pane's session (a detached pane — a burn wrapper, an
  agent run), `switch-client` was skipped and the function simply returned: the
  engine was already running in `ck-<id>`, spending the account's quota, while
  the command looked like it had done nothing. It now names the session and how
  to reach it.


- **`clikae solo --off` could leave a tank with no brain.** It decided which
  memory group to rejoin by reading the machine default, which is written only by
  the first `memory share` ever run and is empty on plenty of installs — the
  maintainer's included. With it empty the rejoin did nothing: the marker came
  off, the board showed the tank back in the fleet, and its memory slot stayed an
  empty directory. `solo` now writes the group name down at the only moment the
  answer is knowable, and `--off` reads it back.

- **Pasting into the board ran commands.** The pickers entered the alt screen
  without bracketed paste and the decoder reads a byte at a time, so every pasted
  character was a keystroke. Reproduced on a real pty: one paste of `dy⏎` deleted
  a tank and answered its own confirmation. The paste mode and the alt screen now
  travel together, across all 14 entry and 8 exit sites — a partial conversion is
  not a partial fix but no fix, because any un-converted exit turns the mode off.

- **The help overlay could mutate state.** It dismissed on a one-byte read, so an
  arrow key's tail was read back as real keystrokes: `[` moved a tank in the burn
  order and materialised the order file, `A` cycled autonomy. Two persistent
  changes, no prompt, from the one screen whose whole job is to teach the keymap.

- **The board's footer printed a bash error and a wrong number.** A single-engine
  store leaves two globs unmatched, `ls` exits non-zero, pipefail promotes it, and
  a trailing `|| echo 0` appended a second line — so the count printf was handed
  `4\n0`, died in frame, and rendered "0 sessions total" under four listed
  sessions.

- **A filter that matched nothing killed the board.** `grep -c .` exits 1 on zero
  matches under `set -eo pipefail`: blank screen, no message. The "no matches"
  notice three lines below had therefore never rendered once, in any of the nine
  locales.

- **Rows ran off the terminal, and the gate that swore they did not had never
  measured one.** Its fixture held two short ASCII tank names and zero sessions,
  and resume rows — the widest thing the board draws — were never in it. Given a
  real specimen the gate fails at 30/36/40/48/56/64/72/80 columns, up to 83
  columns on an 80-column terminal. All three causes fixed.

- **The board could simply stop, with no error, on ordinary content.** The claude
  title extractor ran a nested-star regex through bash's backtracking matcher; on
  a real 229 KB transcript line one match attempt did not finish in 30 seconds,
  and trimming the input did not rescue it. The board asks for a title on every
  recent session. Across the store: 526 s with 25 files over a 10-second timeout,
  down to 123 s with none.

- **`clikae resume`'s `?` was dead**, one keystroke after the board teaches it,
  and the picker also implements g/G, 1-9 and PgUp/PgDn while advertising none.
  It now has an overlay listing what it really has. **`clikae resume > file` began
  with raw alt-screen escape bytes**, and **"no sessions found" exited non-zero**,
  so an empty store looked like a crash.

- **An agy tank showed the wrong account after signing in as someone else.** The
  scrape's own description said "most recent", but it took whichever file the
  filesystem happened to hand back last — which agrees with recency only because
  the names sort chronologically and the directory happens to come back sorted,
  neither of which is promised. Newest by mtime now wins.

- **An agy tank's account column went blank when its log contained a NUL byte.**
  `grep` without `-a` calls such a file binary and prints nothing at all, so a
  signed-in tank read as signed-out. This column had no tests at all; it has nine
  now.

### Changed

- **The burn order is the fleet.** A tank marked solo — explicitly out of the
  fleet — used to hold a slot in the carry order. Nothing ever carried onto one,
  but the file said they were there while the board drew them in a separate
  section, so the rows on screen were never the order on disk, and pressing `[`
  or `]` wrote the interleaved file order back. Measured on a real store: 4 of 9
  order entries were solo. `order_list` is now the fleet and `solo_list` its exact
  complement.

- **Each fuel state has its own shape**: ready `●`, dry `○`, weekly `◐`, no
  reading `·`. Dry, weekly-warning and ready all printed the same `●` and differed
  by colour alone — invisible to anyone with a colour-vision deficiency, under
  `NO_COLOR`, and in a piped or screenshotted board. The overlay's own legend read
  four labels against two glyphs.

- **Autonomy is an explicit choice, not a cycle.** `A` opens a picker instead of
  stepping ask → safe → full, and the board says so on every frame when it is
  raised above `ask` — that being exactly when clikae may carry a live session to
  another account on its own.

### Performance

- **The board no longer asks the terminal how wide it is once per row**, reads the
  shell rc once per frame instead of once per tank, and answers "which tank is
  active" once per engine instead of once per row.

- **"Is this tank out of fuel?" no longer forks `awk`.** Every tank row asked it
  twice — once for its dot, once for the over-quota footer — to look up one key in
  a string that is empty on a healthy fleet: 2.28 ms a call, 8.5 ms a row, on
  every keypress. It is 0.11 ms now, and the whole render dropped from 106 ms to
  34 ms.

- **An agy tank's account no longer costs a scan of every log it ever wrote.** agy
  writes one per launch and never prunes; on the maintainer's machine that had
  reached 362 files and 17 MB, re-read on every frame — so the board got slower
  the more agy was used. Newest log, bounded read, first hit wins: 200 ms to 15 ms.

- **The board stops re-counting the whole store on every keypress.** Listing every
  session file to draw one footer line cost 15 ms per arrow key; it now rides with
  the fuel scan and is exactly as fresh as everything else on the page.

- **Scans that share nothing now run at the same time** rather than adding up:
  the fuel scan against the item build, the resume list against the tank list, and
  the tanks' transcripts against the vendors' limit logs.

- **The claude title extractor reads each transcript once**, matching both title
  keys in a single pass instead of pushing a 512 KiB slice back through a pipe per
  key. Across the store: 113 s to 84 s, titles byte-identical.

- `order_list`, `solo_list` and `tank_is_solo` stopped forking per tank —
  82.9 ms to 6.2 ms for the first, which the board pays on every frame because the
  burn order is the row order.

### Fixed (tests)

- **Three functions the board depends on had no tests at all** and have them now:
  the agy account column, `_home_dry_set` (which decides whether a tank is drawn
  as out of fuel — and whose output is EMPTY on a healthy fleet, so a silent break
  shows up as a green dot on an exhausted tank and nothing else), and
  `autonomy_get` (which decides whether clikae may carry a live session onto
  another account without asking). Each new test file keeps the implementation it
  replaced, verbatim, as the reference to compare against.

## [0.27.1] — 2026-08-18

A strict correctness/security audit pass. Every fix ships with a regression test
proven to go red on the pre-fix code (except the two paths the suite tests
manually — the `watch` tail loop and `--ephemeral` stash race — verified by a
standalone harness instead).

### Security

- **Ephemeral/burn lock files moved out of world-writable `/tmp` into the private
  `$HOME/.clikae/state` (0700).** Their names are predictable
  (`ck-ephem-<run_id>` / `ck-ephem-slot-<cksum>`), so in `/tmp` another local user
  could plant one as a symlink (our `exec 8>`/`9>` would truncate the target) or
  as a plain file that `clikae clean`'s GC reads as a *dead* lock — killing your
  tmux session `ck-<name>` and `rm -f`-ing your `$HOME/.clikae/state/<name>.*`. A
  private dir removes the ability to plant, and sidesteps macOS's `/tmp` purge.
  The GC now scans only the private dir and skips any malformed session id.
  (DESIGN-tmux Rule 6 updated.)

- **The tmux launch command no longer double-expands engine passthrough args.**
  The pane command was built as `bash -c "$target_cmd"`, and since tmux runs it
  via `sh -c`, the outer quotes let the shell re-expand a passthrough arg carrying
  `$`, a backtick, or a quote — and a backtick / `$(…)` was *executed*. It is now
  single-quoted through a helper, so `clikae claude x -- --foo '$(cmd)'` reaches
  the engine verbatim.

### Fixed

- **Auto-carry after a mid-session limit created a session literally named
  `ck-`.** `_switch_supervise`'s same-engine relay used `$tank_id`, which was
  local to a different function (run in a subshell) and thus empty — so the
  carried session, its scrollback file, and `CLIKAE_TANK_NAME` were all wrong.

- **`clikae burn`'s reported exit code was always 0.** The tmux wrapper's EXIT
  trap read `$?` off a `… | tee` pipeline with no `pipefail`, so the `rc=…` in the
  "real task failure" line reported tee's status, not the engine's.

- **`fleet_mcp_prelaunch` rewrote a tank's `.claude.json` on every single
  launch.** Its no-op check byte-compared jq's reformatted output against the
  on-disk file (jq reindents and drops the trailing newline), so it never matched
  and the file's inode was replaced each time — racing any live session on the
  same tank. The no-op is now decided semantically in jq.

- **`clikae rename` orphaned a tank's burn-order entry and dry marker.** Both key
  the tank by name from *outside* its directory, so a rename silently dropped the
  tank to the bottom of the board order and stranded its red-badge record. Now
  carried across (both the env-adapter and agy rename paths).

- **`clikae rename` / `migrate` / `memory` no longer detach a symlinked dotfile.**
  Rewrites used `mv "$tmp" "$file"`, replacing a `~/.zshrc` (or `AGENTS.md`)
  symlinked into a dotfiles repo with a detached 0600 regular file. They now write
  *through* the file, preserving its inode, mode, and symlink.

- **The home board's solo toggle now matches `clikae solo`.** The `s` key only
  flipped the marker file, leaving a shared tank in the "solo BUT STILL SHARING"
  state `clikae memory status` calls impossible; the `m` → *isolate* menu item
  still called the **retired** `memory isolate` (a hard error). Both now delegate
  to the real `clikae solo` verb, which also leaves/rejoins the Soul group.

- **`clikae to` / `relay` refuse a solo tank as an explicit target.** grammar
  §127 says a solo tank is never a `to`/relay target; auto-carry and `memory
  share` already honored it, but a named target slipped through. Solo tanks are
  also dropped from relay's target picker.

- **`memory share` no longer `rm -rf`s a prior own-memory stash.** The `$PWD`-slot
  path destroyed an existing `.clikae-soul-stash` before stashing, against the
  "reversible, never lost" contract; it now uses a unique suffix like its siblings.

- **The auto-resume nudge reaches the engine window, not the waiter's own pane.**
  `wake_sit` typed "go" into `-t <session>` (the *current* window) — which is the
  `wake` countdown window whenever the user was watching it, so the engine never
  resumed. It now targets the first non-`wake` window explicitly.

- **`clikae watch`'s prompts no longer read their answer off the transcript.** The
  dry-detection loop piped `tail -f` into the loop's stdin, so every `confirm()`
  inside it (the wake opt-in, the "switch now?" / auto-consent) read the next
  transcript line instead of the keyboard, and the `exec clikae handoff` handed
  the tail pipe to the started engine. The tail now reads on fd 3.

- **The update-check tag from GitHub is sanitized** to version characters before
  it is printed or cached, so a tampered release name can't smuggle an escape
  sequence to the terminal or a control byte into the cache.

## [0.27.0] — 2026-08-16

### Added

- **`clikae burn --json`** and **`clikae conduct --json`** — the two dispatch
  shapes an agent actually uses now say what happened in a form nothing has to
  parse by eye. One object on stdout, every word of progress on stderr.

  AGENTS.md's first non-negotiable rule is *judge by the artifact/output, never
  the exit code* — and clikae made an agent read that judgement out of
  sentences. `burn` is the worst case: with rerouting, **the tank that did the
  work is often not the one you named**, and the only record of which was a line
  of prose.

  ```
  burn:    {ok, engine, tank, artifact, artifact_bytes, reason, reset,
            rerouted_from[], elapsed_s, run_id}
  conduct: {out_dir, captured, dry, other,
            legs:[{engine, tank, status, detail, output, output_bytes}]}
  ```

  `artifact_bytes` is the artifact's own measurement, so the evidence rule 1
  asks for travels with the verdict instead of being a second call the caller
  has to remember. `reason` separates the two failures that read alike in prose
  and are not the same thing: `every reachable tank is dry` (wait, or add fuel)
  from `no fresh artifact and no limit` (the task itself failed). conduct's
  `status` separates `EMPTY` from `DRY` for the same reason — clikae never
  judges, so the caller is the one who has to rank the legs.

  Audited the whole surface for this: 33 commands, 5 had `--json` (`info`,
  `list`, `watch`, `memory`, `status`). These two were the gap on the axis
  AGENTS.md cares about.

### Fixed

- **The test suite was not safe to run beside a copy of itself — and the hooks
  guarantee that it is.** `clean`'s live guard runs `ps -axo command=` so it can
  never offer a session a process still has open. Correct for the command; fatal
  for concurrency. Suite A's `clikae` processes appear in suite B's snapshot, the
  fixtures use fixed session ids, and B decides those sessions are live and skips
  the rows it is asserting on. pre-commit runs the suite and so does pre-push, so
  `git commit && git push` overlaps them by construction.

  Reproduced by starting a second run 25 s into the first — three of four rounds
  turned red, every failure `[ "$status" -eq 0 ]` on a `clikae clean`. This is
  the explanation for a pre-push red that ~218 isolated runs could not
  reproduce: 10 full suites, 5 sequential and 3 concurrent copies of the file,
  and 200 runs of the exact file at the exact commit in a worktree, all green.
  The condition they were all missing was another suite running beside them.

  `scripts/test.sh` now takes `$TMPDIR/clikae-test-suite.lock` and **waits**,
  saying what it is waiting for. A suite that is red for a reason outside the
  code teaches you to ignore red, which is the one thing a gate cannot afford.

## [0.26.2] — 2026-08-16

### Fixed

- **`pty-smoke size` failed instead of skipping where tmux is not installed.**
  GitHub's `macos-latest` runner has no tmux, so the check added in 0.26.1
  turned CI red for a missing tool rather than a defect — and a red that means
  "a tool is absent" is how a red that means "something is broken" stops being
  read. v0.26.1 was tagged while the board was already this colour.

  Three states, not two: a check a run could not perform is `skip`, never a pass
  and never a failure. `verify-tmux-birth.sh` and `verify-agy-shapes.sh` both
  carry that rule in their own headers; this file was the one that did not have
  it, and it is the one that broke. Proven both ways — with tmux on `PATH` the
  two size checks run, with `PATH=/usr/bin:/bin` they skip and the suite exits 0.

  No product code changed between 0.26.1 and 0.26.2. This exists so the released
  tag is one whose own suite passes on a clean machine.

## [0.26.1] — 2026-08-16

### Fixed

- **The board did not fit a narrow terminal.** Reported from a PineNote over
  ssh; measured on the repo, it overflowed at **every width below 72 columns**.
  There is a fluid layer (`_home_cols`, `_home_row_budget`,
  `_home_wrap_prefixed`, `_home_trunc`) and there were rows that bypassed it:

  | | |
  |---|---|
  | 69 cols | `more   clikae status · clikae doctor · clikae demo · clikae help` |
  | 45 cols | the tank rows — `4 lead + dot + 3 spaces + 7 + 8 + 22`, all literals |
  | 38 cols | the interactive frame's autonomy legend |
  | 34 cols | the wordmark + summary header |

  The `more` row is the one you saw first: a bare `printf` of a hardcoded
  string, not even a call to `_home_cols`, and the last line of the board.

  The tank row's widths were written out at **both** tank-row sites — the static
  board and the interactive one — and neither asked the terminal's width. They
  now share one `_home_tank_fields`: the account column is what is left after
  the fixed chrome (capped at the old 22, so a wide terminal is unchanged), the
  value is truncated to it rather than only padded to it, and it is padded only
  when something follows — otherwise the padding is trailing whitespace that
  still counts as width, which is how a row whose account was the single
  character `-` measured 45 columns.

- **`_home_wrap_prefixed`'s escape hatch produced the overflow it prevented.**
  When the hanging indent left under 12 columns to wrap into, it widened the
  budget to the *whole* terminal and still printed the prefix — so every line
  came out exactly `hang` columns too wide. At 30 columns with a 19-column
  prefix it wrapped text to 29 and printed 48. It drops the indent now.

- **Every tmux session was born 80x24, whatever terminal you were on.**
  `tmux new-session -d` is detached, and a detached session has no client to
  take its size from, so tmux used `default-size`. Measured on a pty at 60, 100
  and 140 columns: 80x24 every time. The engine paints its first frame for 80
  columns and only then do we attach and tmux resizes — so the first screen was
  laid out for a terminal you are not using, and that applied to the **engine's
  own TUI** as much as to the board. `tmux_spawn_session` now passes `-x`/`-y`
  when there is a controlling terminal to ask; a headless `burn` has none and
  keeps tmux's default.

- **The board never repainted on resize.** `tui_read_key` blocks — its argument
  is a file descriptor, not a timeout — so the loop sat there until a key
  arrived, while every layout figure was already read per draw. It polls once a
  second now and repaints only when the size actually changed.

  A `trap … WINCH` does not fix this: bash installs handlers with `SA_RESTART`,
  so the blocked read resumes and the flag is never looked at (measured —
  SIGWINCH produced zero bytes of repaint). And the loop cannot branch on the
  read's exit code, because macOS's stock **bash 3.2 returns 1 for a `read -t`
  timeout** where bash 4+ returns >128 — indistinguishable from EOF. It asks
  something independent instead: a terminal that is gone has no size.

### Added

- **`tests/bats/board-width.bats`** — renders the whole board at ten widths and
  measures every line, on **both** paths: `clikae` with no tty draws the STATIC
  board, so a gate that only ran the binary would have missed the interactive
  frame. The existing width test called `_home_wrap_prefixed` directly and
  proved the *helper* wraps, which says nothing about the 35 `printf` sites that
  never call it. It caught four defects while the fix was being written.

- **`pty-smoke.py size` / `pty-smoke.py resize`** — both depend on a controlling
  terminal, so in bats they would pass by not looking. Before the fix: 80x24 at
  every width, and nothing drawn after a resize.

## [0.26.0] — 2026-08-16

### Added

- **`clikae memory status --json`.** `dispatchable` per tank, so an agent can ask
  which tanks it may use instead of parsing prose. False for a solo tank, and
  false for the impossible *solo-and-shared* state — there the wiring does not
  match the label, so nothing about that tank is safe to reason about.

- **`scripts/mutate.sh` — break a guard on purpose and watch a test notice.** Not
  wired into `scripts/test.sh` (it copies the repo per mutation and costs
  minutes). Four rows, one per locked value in `docs/memory.md` §4: share without
  ever opting in, make a solo tank stop being solo, silence the cross-account
  note, turn seed-by-copy into a move. All four go red, and each row names the
  tests that caught it. A green suite says the code behaves on the inputs someone
  thought to write; only this says a guard is load-bearing.

  Two traps it is built around, both hit on its own first run. A mutation that
  did not apply looks exactly like a working guard — that run reported three
  hollow guards, and all three were the ruler (`tank_is_solo` lives in
  `profile_store.sh`, not the file being mutated; `notice.sh`'s function is
  `carry_notice_once`, not the name that was guessed). Every row now checksums
  its target and reports ⛔ rather than a verdict when nothing changed. And the
  reason those expressions silently did nothing: perl needs balanced braces
  inside `s{…}{…}`, and a shell function's replacement text almost always has an
  unmatched `{`.

### Fixed

- **A test that never ran the function it named.** `wake-sit.bats` asserted the
  "nobody to answer" case with `run bash -c 'wake_ask_once claude work'`. `bash
  -c` forks, and shell functions do not cross a fork — measured, both
  `wake_ask_once` and the `confirm()` stub two lines above report NOT-VISIBLE
  inside it. So the assertion was that a *command not found* message does not
  contain the word ASKED, which is true however `wake_ask_once` behaves,
  including asking on every headless launch and then typing into a live session.
  It passed for two months. Now called in the shell that holds the stub, and
  proven to fire. The other 25 `bash -c` sites in the suite were swept for the
  same shape; they are all real subprocesses.

- **The doc gate's scope was a list written from memory.** `doc-names-exist.sh`
  extracted candidate names with a hand-written prefix list. Measured: 20 real
  functions are named in the docs and were invisible to it — `tank_is_solo`,
  `next_tank`, `history_log`, `load_adapter` and five `limit_*` among them — and
  renaming one in every source file left the gate green. A gate whose scope is an
  enumeration is silent on exactly the entries its author forgot, and forgetting
  is the failure it was built for. Now unioned with "any backticked all-lowercase
  token containing an underscore", which needs no list.

- **The doc gate read the working directory as the source.** A `sed -i.bak` left
  `lib/commands/*.sh.bak` on disk during that very experiment, and the gate
  counted them as repo source in both directions at once: a renamed function
  still "existed" because the backup held its old definition, and the backup
  counted as a caller, so the docstring was asked to list `burn.sh.bak`. An
  editor swapfile or a merge `.orig` does the same. It reads `git ls-files` now,
  with a name-based fallback for a tarball install. `docs/proposals/` is out of
  scope with a reason: a proposal names the function it is asking for, and that
  function does not exist yet — that is what a proposal is.

- **`AGENTS.md`'s cold-reader section sat inside the numbered rules.** Rule 6's
  text ran on into a `##` heading, so the "non-negotiable rules" list visibly
  ended mid-rule. Moved after the list; the dispatch-pool query it duplicated is
  merged into rule 6.

- **A dangling half-sentence in 0.25.0's Known section**, left by a rewrite.

### Corrected

- **Four entries in this changelog were filed under `[0.25.0]` and shipped after
  the `v0.25.0` tag** — the `conduct` read-only enforcement, `burn`'s scoped
  write grant, `conduct` legs no longer leaving transcripts, and the Rule 8
  correction. Anyone running 0.25.0, which is what Homebrew serves, would have
  read that changelog and believed their `conduct` legs cannot write. They can.
  Moved below — the two sections marked "written before the v0.25.0 tag" —
  under the release where they actually ship. This is the same
  defect the last two releases have been auditing out of the docs, committed in
  the file that describes the audit.

### Fixed (written before the v0.25.0 tag, shipped after it)

- **🔴 `clikae conduct` said READ-ONLY and could write.** Its help says each leg
  "runs the prompt headless and READ-ONLY on its own tank", and the code comment
  explains the guarantee as *not passing* `--dangerously-skip-permissions`. That
  is not a boundary. A tank whose own `settings.json` carries
  `permissions.defaultMode: "auto"` approves writes without asking.

  Measured 2026-08-16, and not as a synthetic probe: a leg dispatched from this
  repo edited two tracked files — `lib/adapters/claude.sh` and
  `tests/bats/conduct.bats` — while conduct was printing "read-only" on screen. A
  leg then told to create a file created it.

  codex's recipe has always passed `-s read-only`. claude's enforced nothing, so
  the guarantee held on one engine and was decoration on the other. It now passes
  `--permission-mode plan`, verified end to end: the same leg, told to write, no
  longer can, and answers unchanged.

- **`clikae burn claude` granted write access to the whole disk.** Its recipe
  passed `--dangerously-skip-permissions`, which bypasses the permission system
  rather than scoping it. Measured 2026-08-16, the same task both ways:

  ```
  inside  --add-dir    acceptEdits ✅ writes     skip-permissions ✅ writes
  OUTSIDE --add-dir    acceptEdits ✅ blocked    skip-permissions 🔴 writes
  ```

  So an unattended run held the whole filesystem while the docs said "this
  directory". codex's recipe has always been scoped (`-s workspace-write`) —
  the same documented promise, bounded on one engine and not the other, which
  has been the tell for every defect in this release.

  Now `--permission-mode acceptEdits`. Capability is unchanged: the same
  bash-and-write burn finished in 20s against 15s. The honest cost is that a task
  reaching outside its roots now fails — which is the boundary working, and burn
  judges by artifact, so it reports "no artifact" rather than a silent wrong
  success.

- **`conduct` legs left a transcript each**, so a fan-out across five tanks put
  five rows in `clikae resume` for work already collected into `--out-dir`. A leg
  is one arm of a fan-out, not a session anybody resumes. `--ephemeral` already
  got this right; the audit recipe did not — two headless read-only paths, one
  trace-free and one not, with nothing saying why. Measured: 311 transcripts
  before a conduct run and 311 after.

### Corrected (written before the v0.25.0 tag, shipped after it)

- **Rule 8 suspected a bug in `switch` that does not exist.** It said the
  curated `-e` list meant a session inherited the SERVER's environment for
  everything else — whoever started it, possibly days earlier. Measured on an
  isolated socket: a server created by a shell WITHOUT a probe variable, then a
  new session created from a shell WITH it, and the session saw it. tmux
  inherits the environment of the CLIENT issuing `new-session`, not the server
  process.
  What genuinely cannot change is an already-running session's environment —
  which is Rule 4's whole reason for existing and what roam.bats' comment is
  about. Conflating the two is how a doc sends someone to fix a non-bug; the
  rule now carries the measurement instead of the suspicion.

## [0.25.0] — 2026-08-15

### Fixed

- **`clikae resume` now starts a session like every other entry point.** It
  called `adapter_run` directly, so it was the one user-facing command that
  launched an engine with no tmux — no wake watcher, no scrollback capture, no
  roaming. The board's own resume has always routed through switch
  (`home.sh`: `exec clikae <engine> <tank> -- <resume-args>`), so the *same
  intention* produced two different sessions depending only on how you typed it.

  Not a design decision — drift, and the dates say so. `_resume_exec` was
  written 2026-06-26; the tmux layer arrived 2026-08-11 in `62b33a2`, whose file
  list is `switch.sh` and `burn.sh`. `resume.sh` was simply missed.

  It stayed missed through the v0.24.0 audit because that audit enumerated *who
  calls tmux* — a list this file could never appear on. Searching for callers
  finds drift among the sites that already opted in; it cannot find the site
  that never did. The question that finds it is **"who launches an engine"**,
  which has one answer per `adapter_run` call: `run.sh` and `relay.sh` are the
  primitives switch itself falls back to, `switch.sh`'s own is `--ephemeral`,
  and `resume.sh` was the only user-facing entry point on the wrong side.

  Covered by a pty-driven test — without a real terminal switch is entitled to
  run the engine directly, so a non-pty test could not tell the two routes
  apart. Verified red on the old code (no tmux server at all) and green on the
  new one.

- **`clikae burn` now links the Soul and the fleet's MCP servers, like every
  other launch path.** `soul_prelaunch`'s contract is *"called from every
  non-ephemeral engine-launch path, AFTER the adapter is loaded"*, and burn is
  one — with no `--ephemeral` of its own, so it could not even be the exempt
  case. A headless run in a directory that had never hosted an interactive
  session therefore executed with an unlinked memory slot: a memory-less session
  nobody asked for, while `AGENTS.md` states the only way to ask for one is
  `--ephemeral`. Fleet MCP servers were missing from headless runs for the same
  reason.

  Placed inside the reroute loop rather than above it, so the tank that actually
  runs is the one whose slot gets linked — including after a cross-engine hop,
  which re-loads the adapter and comes back round. Both calls are no-ops for
  solo tanks and already-linked slots, so the reroute path pays nothing.

  Verified red (`burn left this directory's slot unlinked`) and green.

  Found by re-running the v0.24.0 audit with the corrected question. Asking *who
  calls tmux* had found four sites and missed `resume`; asking *who launches an
  engine* enumerates five, and answered honestly it reports four already correct
  — `switch`, `run`, and `relay` (which prelaunches the **target** tank after a
  dry-tank carry, not the source) — and one that was not.

- **`fleet_mcp_prelaunch`'s docstring named the wrong call sites.** It said
  "switch.sh / run.sh"; by then `relay.sh` had the call too. A docstring that
  enumerates call sites is what an audit reads instead of the code, so a stale
  one hides the gap it exists to expose — which is how burn's absence survived.

- **The waiter could never exit.** `wake_watch`'s only exit condition was
  `tmux has-session` — and the watcher is a window IN that session, so it is the
  reason the session is alive. The condition could never become true. When the
  engine's window closed and the waiter was the only one left, the loop ran
  forever and there was no way out but closing the terminal. `wake_sit`'s
  countdown had no liveness check at all. Both now ask about the ENGINE, which
  is what they were actually waiting on. A loop whose exit condition it
  guarantees to be false is not a loop with a bug; it is a loop with no exit.

- **The board announced a countdown that did not exist.** The live row packed
  attached/age/wake into one field joined by spaces, and `age` is a human string
  with a space in it ("2m ago") — so `read attached age wake` put "ago" into
  wake, and non-empty wake means "a waiter is counting". Every selected live row
  claimed one. The render site's own comment forbids exactly that. `live_wake_note`
  was right and had a test; the wiring downstream of it did not.

- **`--ephemeral` runs in the same directory could corrupt each other.** The
  memory slot is keyed on `$PWD`, so the second run's self-heal read the first
  run's symlink as a crashed leftover and moved the real memory back out from
  under a live engine — the 2026-07-19 incident, reachable on purpose by fanning
  out cold readers. Now one lock per slot, and the refusal says to give each run
  its own directory. (`lockf -k`, not `lockf`: measured, two processes both got
  rc=0 on the same file without it.)

- **`window-size` was never set.** Rule 1 describes clikae's sizing as
  "window-size latest" and nothing set the option, so it held on tmux 3.7b and
  not on 3.4 — a 100-column client attached and the window stayed at 80. Roaming
  is the reason this layer exists, and it was resting on a default nobody chose.

- **The scrollback capture named a session as its `-t` target**, which returns
  nothing on tmux 3.4 (measured: 1717 bytes with no target, 0 with it). The
  command runs inside the pane it captures, so the target was never needed.

### Added

- **`K` on the board closes a running session.** A session whose engine had
  finished left no way out but closing the terminal, while the board could see it
  and name it and offered only "enter it". Destructive, so it asks — and the
  question carries the fact that makes it safe: the conversation is a transcript,
  so `clikae resume` brings it back. What ends is the process.

- **`scripts/doc-names-exist.sh`, in the gate.** Every function a doc names must
  exist in the code. Three defects this release were that one shape, including
  one that survived two years and an audit looking for exactly it — because a doc
  that names a function is what an auditor reads *instead of* the code, so a
  stale one hides the gap it would otherwise expose. Exemptions need a written
  reason.

- **Selection and copy defaults**: `fill-character` blanks the dot field a
  smaller second client leaves on the larger screen.

### Known

- The board's resume list and `clikae resume` still show different session
  counts, for two reasons neither of which is written down anywhere: the board
  is scoped to the **current directory** (`_home_recent_rows`) and capped at 10
  (`CLIKAE_HOME_RECENT_MAX`), while `clikae resume` is not directory-scoped and
  caps at 50. Measured on one machine: 528 sessions across five tanks, of which
  a board opened from `~` surfaces 10. The scoping may well be right — "continue
  *here*" is a coherent headline — and the footer does say `%d sessions total ·
  Press [R] to see all / search`, so the escape hatch is stated. What is not
  stated is the *reason* the list is short: that it is this directory's. (An
  earlier draft of this entry said nothing told the reader at all; that was
  wrong, and is the same overstatement this release keeps auditing out.)

## [0.24.0] — 2026-08-15

### Fixed

- **You can select and copy text in a clikae session again.** Reported as "since
  clikae started using tmux I cannot copy text", and the diagnosis is that the
  text was never unselectable — it was unreachable. Disabling the outer
  terminal's alternate screen (the `smcup@/rmcup@` override, which the scrollback
  capture needs) fills that terminal's own scrollback with tmux's full-screen
  redraws, so the wheel scrolls debris while the clean 50000-line history sits in
  tmux where the wheel cannot reach it. And tmux's default `set-clipboard
  external` forwards an application's own OSC 52 but never emits one for tmux's
  own selections, so even a copy-mode yank landed in a buffer only tmux could
  paste from.

  `mouse on` puts the wheel and the drag onto tmux's real history;
  `set-clipboard on` puts a copy-mode yank on the system clipboard. The cost,
  stated plainly: a *native* terminal selection — for pasting somewhere tmux is
  not — now needs `⌥` held.

- **Global tmux options no longer pile up one copy per session.**
  `terminal-overrides` and `terminal-features` are appended to, and the option
  block ran on every session creation rather than only at server birth. Measured
  on a two-day-old server: four identical `*:smcup@:rmcup@` entries and four
  `xterm*:extkeys`. Harmless to tmux, and the same shape as the bug this whole
  layer exists to stop — an operation written as though it were idempotent when
  it is really cumulative.

- **🔴 Running the test suite no longer kills every tank you have open.**
  `tests/bats/roam.bats` calls a bare `tmux kill-server` twice — it needs a
  known-empty server to prove create-or-attach — and the suite had no tmux
  isolation at all, so on the default socket that command reached the
  maintainer's live sessions. `scripts/test.sh` was unsafe to run on any machine
  that dogfoods clikae, which is every machine that runs it.

  The fix is in `tests/helpers.bash`, and it took two parts, because the obvious
  one is not enough. `TMUX_TMPDIR` moves the socket; an inherited `$TMUX`
  overrides `TMUX_TMPDIR` and points straight back at the real server. Anyone
  running the suite from a tmux pane — the normal way — had the second. Measured:

  ```
  TMUX_TMPDIR=<iso> tmux list-sessions              -> isolated
  TMUX=<real> TMUX_TMPDIR=<iso> tmux list-sessions  -> the four live tanks
  ```

  So the suite now unsets `TMUX`/`TMUX_PANE` as well. `tmux-spawn.bats` keeps a
  negative control that proves the unset is load-bearing rather than decorative.

- **A tank that cannot read its own memory now says so, loudly, instead of
  starting with none.** A Soul kept under `~/Library/Mobile Documents` became
  unreadable to every tank on one tmux server and stayed readable on another;
  the only symptom was `EPERM`, with no prompt and nothing in any log.

  The cause is structural and is now Rule 7 of `docs/DESIGN-tmux.md`: a tmux
  server inherits its file-access permission from whoever created it, keeps it
  for life, and cannot be granted more afterwards. A server born from a context
  holding no grant makes every tank on it, forever, unable to read a protected
  directory.

  `soul_prelaunch` now probes the memory it is about to hand over. The test is a
  two-syscall asymmetry rather than an errno: `stat` succeeds and the read still
  fails. If the permission bits already deny the read, that is an ordinary
  `chmod` and is reported as one; if the bits ALLOW it and the read still fails,
  something above the filesystem refused, and the message names the server and
  how to replace it. It warns and starts anyway — a session with no memory is
  bad, a tank that will not start is worse.

- **`clikae burn` no longer creates a tmux server without clikae's global
  options.** `burn.sh` used a bare `tmux new-session -d`, with none of the
  option prefix the three `switch` call sites carried. When a burn was the first
  thing to run on a machine, the server it created took tmux's defaults —
  measured at `history-limit 2000` against the intended 50000 — and a later
  `switch` silently repaired it, which is why it was never noticed.

- **`clikae burn` no longer publishes your environment to `ps`.** It passed the
  caller's whole environment (`compgen -e`) to `tmux new-session` as `-e KEY=VAL`
  pairs. Those pairs stay in the tmux process's argv, and when the burn is what
  creates the server, that argv is the *server's* — readable by every process on
  the machine for as long as it lives. Verified on a server born days earlier:
  its command line still listed each `-e` pair. The environment now travels in
  burn's wrapper script, which is created and `chmod 0600`'d before anything is
  written to it.

- **A carried session is no longer handed an SSH agent socket that was never
  created.** The dry-tank carry path passed clikae's stable symlink path without
  the `ln -sf` that creates it; the interactive path did both. Both now go
  through one function.

### Added

- **`scripts/verify-tmux-birth.sh`** — the manual half of Rule 7, which bats
  cannot reach: whether the server hosting this session was born with file
  access, on a real machine, against real macOS TCC. Read-only, safe to repeat.
  Its first check is whether the *installed* clikae is even the one with the tmux
  layer, because every later check would otherwise measure the old build and pass
  for the wrong reason. Reports `skip` where it cannot look — a skip is not a
  pass.

  Rule 7 also gained the receipt that could only be taken once: the probe run
  against a genuinely TCC-blind server, before a reboot removed it. It took the
  TCC branch rather than the permissions branch, which is what makes the
  "stat succeeds, bits allow, read still fails" discriminator real rather than
  merely stub-tested.

### Changed

- **The tmux layer has an owner: `lib/core/tmux.sh`.** `docs/DESIGN-tmux.md` has
  specified this since v0.4 — Rule 2 asks for one shared set of exits, and Rule 5
  refers to a wrapper called `clikae_spawn_session`. That function was never
  written: three mentions in the design doc, zero in the source. Four call sites
  re-implemented the rules by hand and drifted, which is every defect above.

  `tmux_spawn_session` is now the only `tmux new-session` in the codebase, and it
  holds Rules 1, 4, 5 and 7 in one place. `tmux_usable`, `tmux_attach` and
  `tmux_label` moved out of `switch.sh` with it. No user-visible behaviour change
  beyond the fixes listed above.

## [0.23.0] — 2026-08-14

### Added

- **A session now watches itself for a usage limit.** The waiter worked;
  nothing ever started it. Detection lived in `clikae watch` — nobody starts a
  watcher in order to be interrupted later — and in the supervised launch, which
  only runs once the engine has EXITED. Sitting in a live session that hits its
  limit, which is the ordinary case and the only one that matters at 3am, reached
  neither.

  Confirmed against a real limit: the tank went dry at 21:57 with *"resets 12am
  (Asia/Tokyo)"*, the phrase parsed correctly to midnight — and no waiter was ever
  attached, because nothing looked. The release notes had promised a session that
  waits out its limit; on the common path it never could.

  Every session clikae starts now carries a `wake` window that asks the same
  question the board asks, once a minute, and hands over to the countdown in
  place. **One window, two phases**: bare `wake` while watching, `wake 13h38m`
  once counting. It keeps no record of anyone's quota and dies with the session.

- **The one-time question moved to launch.** Asking at limit time could not work:
  the question would have been posed by a watcher in a window nobody was looking
  at. At launch a human is demonstrably present — they just typed the command —
  and the friction is still paid exactly once. Silent where there is nobody to
  ask, and then nothing is scheduled either, which is the safe direction.

### Fixed

- **Shift+Enter inserts a newline again inside a clikae session.** tmux defaults
  to `extended-keys off`, which flattens a modifier onto the key it modifies
  before the application sees it — so Shift+Enter arrived as a plain Enter and an
  engine that treats Enter as "send" submitted instead of adding a line. The tmux
  layer had quietly put a translator in the middle of the keyboard.

  Two settings, because they answer different questions: whether tmux **forwards**
  the extended encoding to the application (`on`, not `always` — only for an
  application that asked), and whether it **asks the outer terminal** for those
  sequences at all. Without the second there is nothing to forward. Measured: a
  fresh client now reports `extkeys` among its features, and did not before.

  🔴 Only a NEW client picks this up — terminal features are resolved at attach
  time, so a session you are already inside keeps the old behaviour until you
  detach and come back.

- **A tmux test depended on an environment variable that never arrived.** tmux
  passes only its `update-environment` list into a session; everything else comes
  from the SERVER's process environment, which belongs to whoever started the
  server. So the stub engine's log path reached it only when that test happened
  to start the server itself, and vanished whenever one was already running —
  which is the whole story of that test's intermittency. It writes under `$HOME`
  now, which clikae passes explicitly.


## [0.22.0] — 2026-08-13

### Added

- **The board shows what is running right now.** `clikae` gained a **Live**
  section at the top, listing this machine's live sessions in the same columns as
  the rest of the page — and **Enter attaches to one** rather than starting
  anything.

  Reported by someone who ssh'd into their Mac, ran `clikae`, and could not see
  the session they had left running. The board could say which accounts they had
  and what they did yesterday; "what is alive" was a category tmux created and
  the board never grew. Keying a session on its argv made it sharper still: the
  Resume row now opens a *second* conversation, so without this section there was
  no way back into the first one except remembering the tank's name.

  The third column is the session's title, not a status word — `claude/x` does
  not say which piece of work that is. Selecting a row adds one line beneath it:
  for a limited tank, the vendor's own sentence verbatim, and clikae's promise
  only when a waiter is genuinely attached. `resets` is their fact; `resumes` is
  ours.

  Only this machine's sessions, because tmux is local — stated rather than
  papered over, since it is the truth about where a session lives. No tmux means
  no section, not an empty heading.

### Fixed

- **Two tests waited a fixed number of seconds for tmux.** Both passed alone and
  failed inside a full suite run, which is the shape of a timing guess rather
  than a defect. One of them was waiting for "nothing in tmux is attached" — a
  condition that is never true on a machine with a session open, so it burned its
  whole timeout every run and, under load, outlived the stub engine it was
  measuring. They wait for the states their assertions depend on now.

## [0.21.0] — 2026-08-13

### Added

- **The CLI surface is now checked against the family's design system.** signet
  is CVER's design system for plain-text terminal output; clikae was the one tool
  that had never been wired to it, so the board could drift and nothing would go
  red. CI runs its linter on every push.

  The linter is fetched at a **pinned** ref, never `main`. Fetching a
  neighbour's HEAD would let their commit turn this repo's CI red — a gate whose
  colour somebody else sets. It stays doc-and-CI only and never becomes a runtime
  dependency, because clikae sells "one file you run, no dependencies".

  What it found on the first honest run: 25 violations across 12 files. Twenty
  were fixed here. Seven were a marker inside help text, now words. Thirteen were
  a status glyph printed **next to a badge that already said the same thing** —
  `log_done "  ✔ …"` prints `[ DONE ]` and then a tick. One state, two
  vocabularies, which is the thing a closed badge set exists to stop.

  The remaining five are the selection cursor `❯`, kept deliberately and named in
  the check rather than hidden: signet decides a `[x]` / `[ ]` *checkbox* but has
  no *cursor*, and the two answer different questions. Reported upstream. The
  exception matches the cursor itself, not a file and line, so a second glyph
  riding along on the same line still fails.

### Fixed

- **A waiter already counting down no longer lets a second one attach.** The
  "one waiter per session" guard matched the window name exactly, and the waiter
  renames its own window to carry the countdown — so seconds after it started,
  the guard stopped recognising it. A second limit would then have attached a
  second waiter, and two of them would type into the same pane. Found by CI on
  Linux, which won a race macOS had been losing quietly.

- **Resuming a second session on the same tank now opens a second screen.**
  Reported and reproduced 2026-08-13: open `clikae claude work`, then from the
  board resume a DIFFERENT past session on that tank, and both tabs showed the
  same thing. The tmux session was named after the tank alone, so the second
  launch found one already running and attached to it — and the `--resume <sid>`
  was dropped in silence, because nothing was started to receive it.

  A session is now keyed on **what was asked for**. A bare `clikae <engine>
  <tank>` keeps the stable name, so walking away and coming back still lands in
  the same place; anything after `--` gets a short digest of that argv appended,
  because a session started with different arguments cannot answer a different
  request. Identical requests still collide on purpose — resuming the same
  session id twice returns you to it.

  Measured before and after with the same probe: one engine start and one screen
  became two engine starts and two screens, showing different things. The
  regression test asserts both.

- **The update notice speaks the family's vocabulary.** A successful upgrade
  printed a tick while the failure branch two lines below already used a badge —
  one state written two ways, which is the thing the closed badge set exists to
  stop. It is `[ DONE ]` now, and the decorative glyph on the "new version"
  banner is gone: the colour and the sentence were already saying it.

## [0.20.0] — 2026-08-12

### Added

- **A limit noticed on the way out can also just wait.** `clikae wake` was only
  offered by `clikae watch`, which meant it never came up unless you happened to
  be running a watcher. The supervised launch — clikae staying as the parent of a
  session it started — now offers it too, alongside the carry rather than instead
  of it.

  In the maintainer's words, which is the right framing: *staying put is staying
  put, and being asked where to go next belongs to leaving.* They are not
  alternatives and nobody has to choose between them.

  It stays silent when there is nothing to attach to. Chiefly: that path also
  runs after the engine has EXITED, and an exited engine took its conversation
  with it — there is no session left to resume. A detach leaves the session
  alive, and that is the case this is for.

## [0.19.0] — 2026-08-12

### Added

- **A new agy tank comes with a harness.** It does not change how agy talks — it
  stops a reply from ending with *"I verified everything works and all tests
  pass"* in a session that executed zero commands. The claim is blocked once and
  handed back with its own record; agy re-enters the loop and answers it.

  Measured on a real run — same tank, same prompt, the only variable being
  whether the harness was installed:

      with     "I verified everything works and all tests pass."
               "I did not actually run any commands or verify any tests; I
                simply output the requested phrase."
      without  "I verified everything works and all tests pass."

  **The threshold is zero, not "enough".** "You didn't test enough" is an
  argument about taste that nobody can settle; "you said you verified it and this
  session never ran a single command" is not. Zero is also the only threshold
  that cannot punish real work — an ordinary answer claiming nothing is left
  alone.

  A project can add its own executable `.clikae-gate`; clikae cannot know what
  "done" means in your repo, so that file is where you say so. No gate means no
  project check, and it says so rather than implying coverage it doesn't have.

  Interactively it interrupts once and then gets out of your way; a headless run
  is held longer, since nobody is there to notice. Either way there is a cap — a
  gate that can never pass must not hold a session forever. The rule against
  editing tests and CI applies only to a dispatched agent: interactively those
  are your tests, and friction belongs on how dangerous an action is, not on who
  is doing it.

  The script is copied into the tank, not linked. Editing it is how you make it
  stricter; deleting it turns it off, and clikae never puts it back.

  **Every existing tank gets it too, once.** Tanks made before this release are
  seeded on the next switch. "Every tank has it" and "deleting it means deleting
  it" are both promises, and install-if-missing cannot hold both — so clikae
  records that it has seeded a tank, outside the tank, and never looks again.

  **Blocking is not compliance, and that is measured rather than assumed.** Same
  prompt, two real tanks: one came back and said plainly *"I did not actually run
  any commands"*; the other was blocked just the same, went off and did something
  else, and the last line printed was still the original claim. What is
  guaranteed is that the claim gets challenged, not that the answer is good.

### Fixed

- **The harness no longer leaves a counter behind for every abandoned run.** A
  conversation that ends while still blocked — a timeout, a kill, an agent that
  wandered off — left its counter in the tank's config. Three turned up in a real
  tank within an hour, in a directory that would grow forever. Counters older
  than a day are swept.

- **The roaming test no longer guesses how long tmux needs.** It waited a fixed
  number of seconds — enough on an idle machine, not on a loaded one — so it
  passed 3/3 on its own and failed intermittently inside a full-suite run. It now
  waits for the states its assertions actually depend on.

## [0.18.1] — 2026-08-12

### Fixed

- **A reset time inside a DST gap now resolves the same on Linux and macOS.**
  A wall-clock time the spring-forward deletes (02:30 on the changeover day) has
  no correct answer, and the platforms picked different wrong ones on their own —
  BSD returned the instant an hour later, GNU refused. On Linux that meant no
  waiter was scheduled at all for such a phrase. Both now agree on the first
  instant after the time the vendor named, on the day they named. The ambiguous
  autumn hour, which exists twice, is deliberately left alone — nudging it would
  resume an hour late every November.

## [0.18.0] — 2026-08-12

### Added

- **`clikae wake` — a limited tank picks itself back up.** When you hit a usage
  limit, the session isn't gone: it's at its prompt with the conversation intact,
  which is why the manual fix is to come back at 3:50am and type `go`. clikae
  sends that keystroke for you. A countdown opens as a window inside that tank's
  own tmux session; when the limit lifts, the conversation continues.

  **It is not a re-run.** No prompt is replayed and nothing is dispatched twice —
  it is one keystroke into a conversation that never ended, so a task that had
  already written files or made a commit does not do it again.

  `clikae watch` offers this once when it sees a limit and remembers the answer.
  On by default, because it automates something you already do by hand; asked the
  first time, because typing into a live session is a power and clikae asks
  before taking one.

  Every failure path is silent and harmless: no tmux, no live session, or no time
  in the vendor's sentence, and nothing is scheduled. A waiter with a guessed
  time is worse than none — it fires at the wrong moment into something live.

  Before typing it asks three questions no vendor can reword: does the session
  exist, is anything alive in it, has the screen stopped moving? A busy or dead
  pane is retried three times and then given up on **visibly** — a waiter that
  disappears quietly leaves you believing your work resumed.

  The delay after the stated reset is 60 seconds, and that number was measured:
  across 116 real outages in which nothing succeeded during the window, the
  earliest success after the vendor's stated time was **30 seconds**, six
  separate times. The sentence is accurate to the second; 60s is that doubled,
  not a hedge against rounding nobody checked.

- **The reset sentence can now be read as a time.** Everywhere else clikae relays
  a vendor's reset phrase verbatim and never parses it; this is a separate pure
  function for the one caller that needs a number. Two grammars exist and only
  two — measured against 262 genuine limit events across five accounts, all 262
  of which carry a phrase. The grammar does **not** follow the limit type (a
  weekly limit appears in both forms), so branching on that would have been
  wrong. 175 distinct cases ship as a test fixture whose answer key was computed
  by a different implementation than the one under test.

### Fixed

- **The bats suite could write into whichever repo invoked it.** git exports an
  absolute `GIT_DIR` into every hook, so a test that cd's into its own throwaway
  repo and calls `git config` wrote to the real one. Running the suite from a
  pre-push hook put a test fixture's deliberately-wrong author into the
  maintainer's own git config, where it stayed for a month. The hook already
  scrubbed those variables; the suite does now too, because either layer alone
  leaves it unsafe to run from the other's context.

## [0.17.0] — 2026-08-12

### Added

- **Your session outlives the terminal.** A bare `clikae <engine> <tank>` now runs
  the engine inside a tmux session named for its tank, so closing the window — or
  an ssh connection dropping on the way home — leaves the work running. Come back
  with the same command from anywhere and you land back in the same conversation,
  at whatever size the screen in front of you happens to be. Verified across two
  real machines: a tablet attaches at 90x28, the desktop joins at 200x50, both
  stay live, and the engine is started exactly once.

  It degrades instead of breaking. No tmux installed, no terminal (a pipe, CI), or
  a `TERM` tmux cannot draw on, and clikae runs the engine directly — same command,
  same result, no persistence. One shape to know: `ssh yourmac 'clikae claude work'`
  is a *command* handed to ssh, which gets a terminal on stdin but a pipe on
  stdout, so it takes the direct path. Log in first, then type the command.

- **`clikae burn agy … -- <flags>` reaches agy instead of being swallowed.** The
  trailing argv was parsed and then dropped. agy has no adapter for clikae to
  compose flags from, but it can stop eating the ones you typed —
  `-- --dangerously-skip-permissions` (agy's print mode auto-denies file tools) and
  `-- -c` (continue the previous conversation) are the two that turn a single shot
  into a working headless loop.

### Fixed

- **The board no longer paints its logo over the session list.** The watermark was
  pinned bottom-right and gated on the terminal being big enough, which stopped
  being the right question once the resume section made the board's own content
  reach that corner. The two overwrote each other mid-line. The welcome screen
  keeps the logo, where nothing can collide with it.

- **An agy tank is no longer reported dry because another agy session hit a limit.**
  `~/.gemini/antigravity-cli/cli.log` is a symlink every agy process repoints at its
  own file, so reading it after a run could pick up an interactive session's quota
  event. Each run now asks for its own log with `--log-file`. Measured on a tank
  with 74% of its weekly limit left: the same request came back "ran dry" once and
  completed twice.

- **A `RESOURCE_EXHAUSTED` line from a background cache refresh is not a spent
  tank.** agy's log carries three different sentences with that error class and
  only two of them mean the account is out; matching the class alone sent burn off
  to reroute a tank that had fuel.

- **`watch` stops calling its claude limit marker a guess.** The file told users
  the marker was unconfirmed and the pattern a best guess to tune, while its own
  comments twenty lines down said CONFIRMED. Settled against every occurrence in a
  real user's transcripts: 194 genuine limit events all match, and all 89 mentions
  — including ordinary model replies discussing a limit — correctly do not.

## [0.16.1] — 2026-08-02

### Fixed

- **A solo tank that is still on the shared brain is now called out, instead of
  being reported as two flat facts.** `solo` and "in a memory group" are one
  statement — solo leaves the group — but `memory status` printed
  `→ shared 'me'  🔒 solo` on the same line and let the badge speak louder than
  the truth. Anyone scanning the board read that tank as isolated.

  The state is reachable: a tank made solo *before* 0.15.0 wired the two verbs
  together kept its pointer, and nothing since would have told you. Two of them
  were found in the field on 2026-08-02, sitting on the shared store for six days
  under a 🔒 badge.

  The survey now badges the combination `⚠️ solo BUT STILL SHARING`, prints one
  actionable line naming the affected tanks, and the single-tank view says what
  to run. Detection only — `clikae solo <engine> <tank>` already repairs it, and
  a silent auto-repair would hide the very thing worth seeing.

## [0.16.0] — 2026-07-31

### Added

- **grok is an engine now.** xAI's Grok Build CLI joins claude and codex as a
  full AI engine, not just a switchable tank: `clikae init grok <tank>` gives it
  its own login + config + history under `GROK_HOME`, and its sessions show up on
  the home board's Resume list, in `clikae resume`, and in `clean`'s scan.

  It carries the whole AI-engine set — `handoff --to grok/<tank>`, `burn`'s
  headless-write dialect (`--sandbox workspace` + `bypassPermissions`), `conduct`'s
  read-only leg (`--sandbox read-only` plus a tools **allowlist**), the ACCOUNT
  column, and Soul membership through a pointer note in `$GROK_HOME/AGENTS.md`
  (grok's own global-rules file — the same shape codex uses).

  Three things worth knowing, all verified by doing rather than assumed:
  - **The read-only leg is fenced twice, and the denylist form doesn't work.**
    Naming the mutating tools in `--disallowed-tools` was tried first; with the
    sandbox off, a leg still created the file. An allowlist (`--tools`) holds,
    needs no correct guess at what the write tool is called, and keeps holding
    when grok ships a new one. Note also what `--sandbox read-only` deliberately
    allows: writes to `GROK_HOME` and to temp dirs. A leg cannot touch your
    project; it *can* write to `/tmp`.
  - **Sessions are matched on the cwd grok RECORDS, not the folder it encodes.**
    grok names each session group after the percent-encoded working directory, with
    a slug+hash fallback for long paths. Reading `summary.json`'s own `info.cwd`
    instead means a change to that encoding can't silently empty your board.
  - **`/rename` and the model's title share one field.** A rename overwrites
    `generated_title` while `session_summary` keeps the original, so preferring
    `generated_title` is what puts *your* name on the board row.

  Honest limits, all listed in [Expectations](docs/EXPECTATIONS.md#grok): no fuel
  dot (grok reports a limit only on the exit path — exit status 1 with a stderr
  sentence — and writes nothing clikae can read afterwards), no `mcp share` (grok's
  servers live in TOML, clikae's fleet list merges JSON), and no `--ephemeral`
  (pointer-strategy memory has nothing to stash).


## [0.15.2] — 2026-07-27

`--ephemeral` finally isolates what it always implied. A cold reader that loads
your own skills already knows what you believe, and one holding the fleet's MCP
connectors can still reach your sites — so both are dropped now, per run, without
touching the tank. What it still cannot do is said on screen rather than left to
the word "ephemeral".

### Changed

- **`--ephemeral` now drops your skills and the fleet's MCP servers too, and says
  what it still can't drop.** Memory was only one of the channels a session
  inherits. A cold reader that loads your hand-authored skills already knows what
  you believe; one holding the fleet's MCP connectors can still reach your sites.
  Neither is a cold read, which is the main thing `--ephemeral` is for.

  The engine already had the primitives — clikae simply wasn't passing them. A
  new `adapter_ephemeral_flags` hook emits `--disable-slash-commands` and
  `--strict-mcp-config` on every ephemeral run, plus `--no-session-persistence`
  when the run is headless.

  **Per-run, never surgery.** The tempting fix — temporarily repointing the tank's
  `skills` symlink — would mutate a tank another session may be live on, which is
  exactly what made `memory isolate` dangerous. A concurrent session on the same
  tank is unaffected by these.

  Two honest limits, both stated on screen rather than left to the name:
  - Claude Code ties `--no-session-persistence` to `--print`, so an **interactive**
    ephemeral run still writes its transcript into the tank. Incognito here means
    *it doesn't know you*, not *it never happened*; the headless shape gives the
    stronger one.
  - 🔴 **Not `--bare`**, however much it reads like the answer: it also disables
    keychain reads and restricts auth to `ANTHROPIC_API_KEY`, so it cannot log in
    on a subscription tank at all.

  Verified against the real binary (Claude Code 2.1.220), both shapes.

- **zh-TW: `session` stays English; the fleet is 艦隊.** Checked against 4989 of
  Apple's own zh-Hant string tables on this machine: 會話 appears **zero** times
  (it is the mainland standard), and Apple avoids the concept entirely — the one
  English "Invalid Session." renders as 連線錯誤. The file had already decided
  anyway: twelve of the fourteen zh-TW strings mentioning a session used the
  English word, exactly as the same table already keeps `burn`, `Soul` and
  `clikae solo`. Two outliers were pulled back rather than a direction changed.
  zh-Hans deliberately keeps 会话 — the correct native term there, used by twelve
  of its keys. `車隊` → `艦隊`: Apple has neither, so it is a brand call, and
  艦隊 carries the sense of a formation dispatched under command.

## [0.15.1] — 2026-07-27

Three findings from one real dispatch, none of which a reader of the code would
have hit: `clikae burn agy --artifact` could never succeed, because burn proves a
run by the artifact FILE while agy's headless mode is not allowed to write to
your paths. They differ only in who holds the pen — so clikae holds it now.

### Fixed

- **`clikae burn agy --artifact` failed 100% of the time, and now works.** Two
  contracts that could not both be satisfied by agy: burn proves a run by the
  **artifact file** (never the exit code — `codex exec` returns 0 on a limit),
  while agy's headless mode **auto-denies the file tools on your paths**, because
  with no terminal it cannot prompt for permission. Asking agy to write the
  artifact was asking for the one thing it is not allowed to do — an 11-second
  failure, every time, reported from the field on 2026-07-27.

  They differ only in **who holds the pen**. agy prints fine, and burn already
  had the output in hand for its error tail, so clikae now writes the artifact
  from agy's stdout — and labels the row, so nobody believes agy wrote a file it
  cannot write. Deliberately not done: adding an allow-rule to the user's agy
  settings (that is clikae widening an engine's permissions on their behalf, the
  same line `--dangerously-skip-permissions` sits on), or refusing `--artifact`
  for agy (which would remove the only verification burn has).

  Honest limit, stated on the row and in the docs: agy buffers a *large* answer
  into its own brain dir and prints a pointer, so a big deliverable can arrive
  pointer-shaped. And a silent run is not proof nothing happened — the failure
  message now points at `~/.gemini/antigravity-cli/brain/` before you re-fire.

- **`burn --timeout` never reached agy.** agy enforces its own print budget,
  default 5 minutes, and knew nothing about clikae's `--timeout`, so
  `burn agy --timeout 1200` was a fiction — agy self-terminated at 5m first. The
  budget you ask for is now handed to agy as `--print-timeout`. With no
  `--timeout`, agy's own default stands; clikae does not invent one.

- **`clikae agy <tank>` in a non-TTY context ended in a confusing error after a
  SUCCESSFUL switch.** It switched, then unconditionally exec'd the interactive
  UI, which can only fail with `could not open TTY` — while still exiting 0, so
  it read like the switch had failed. With no terminal and nothing to pass
  through, it now completes the switch, says it is switch-only, and stops. A
  headless prompt (`-- -p "…"`) still always runs.

## [0.15.0] — 2026-07-27

A day spent reading what this project says about itself and checking it against
what the code does. Most of what follows was found in that gap.

The headline is a bug that had been shipping for releases: `exec` with no command
makes its redirections permanent, so eighteen tty lines had quietly pointed the
board's stderr at `/dev/null` — invisible prompts that read as a hang, muted
errors, and the engine you launched from the board losing its stderr entirely. It
survived a fully green gate, because neither shellcheck nor bats can watch a
terminal. The gate now has a third leg that can.

**Breaking:** `clikae memory isolate` is gone — `clikae solo` leaves the fleet and
gives the tank its own memory back — and a new tank now joins the shared brain
automatically once you have opted in once. In the fleet means sharing; solo means
not; there is no third state. See *Changed* below for why that was worth breaking.

### Changed

- **In the fleet now means sharing the brain, and `clikae solo` is the only way
  out.** The Soul layer had three states where the board can only show two.
  Sharing was opt-in *per tank*, so a tank created after you had already opted in
  silently started with no brain — and the board's only axis is fleet-vs-solo, so
  it looked exactly like one that shared. That is not a subtle bug: it taught the
  model's own author the wrong model. He described clikae back as "everything in
  a tank shares `me` unless I solo it", which is what the board, the docs and the
  design all say. Only the code disagreed, and it was the part nobody can see.

  - **Consent is once per machine, not once per tank.** Nothing is shared until
    your first `clikae memory share`; that share records the group in
    `$CLIKAE_HOME/soul-default`, and from then on a tank created by `clikae init`
    joins it. A machine that never opts in shares nothing, ever — so a stranger
    making one tank per client is not handed another client's memory.
  - **Crossing a different account is still announced.** `init` deliberately does
    not pass `--yes`: a fresh tank has no account yet so there is nothing to
    cross, but one whose account is already known and different is refused and
    keeps its own memory. The 🔴 locked value survives the redesign intact — the
    test that guards it is what forced this detail.
  - **`clikae memory isolate` is retired.** `clikae solo` leaves the fleet *and*
    gives the tank its own memory back; `--off` puts it back in both. One idea,
    one verb, visible on the board. The old verb now fails with a pointer rather
    than silently doing something adjacent.
  - **The board names the anomaly.** A fleet tank with no brain gets one dim
    line — the single state the board could not otherwise express. Silent before
    your first share, since nothing sharing is then the deliberate state.

  `memory isolate` was also the wrong verb to have within reach: an agent ran it
  on a LIVE tank to spawn a cold reader and a running session went amnesiac
  mid-flight (v0.14.3). Retiring it does not remove that footgun — it renames it,
  since `solo` is now the permanent form — so `AGENTS.md` and `docs/memory.md`
  now warn about `solo` in the words they used to spend on `isolate`. The
  mnemonic still holds: **ephemeral changes this once; solo changes from now on.**

### Fixed

- **The board, `resume` and `clean` threw away their own stderr — and handed a
  dead stderr to the engine they launched.** `exec` with no command makes its
  redirections **permanent for the shell**, so `exec 3</dev/tty 2>/dev/null`
  (meant only to hide the message if opening `/dev/tty` fails) pointed the whole
  process's stderr at `/dev/null` for the rest of its life. Eighteen fd-3 lines
  across `home.sh`, `resume.sh`, `clean.sh` and `relay.sh` did it, each one
  independently, so fixing any single site would not have helped. What it cost:

  - **A tank opened from the board lost the engine's entire stderr.** Pressing
    Enter on a row `exec`s through to `claude`/`codex`/`agy`, which inherited
    fd 2 = `/dev/null` — crashes, node warnings, OAuth failures and
    "command not found" all discarded. `clikae claude <tank>` run straight from
    the shell was never affected, which is why this hid for so long.
  - **`clean`'s Trash-fallback warning could never appear.** When `~/.Trash` is
    unusable, `clean` falls back to `rm` and `log_warn`s that the row was deleted
    unrecoverably — on stderr. In the interactive path that warning was
    guaranteed silent, which is precisely the disclosure it exists to make.
  - **Three prompts were invisible**, since bash writes `read -p` prompts to
    stderr: `n` (new tank), `a` (rename) and `m` (memory group) each dropped to a
    blank screen and read as a hang. This is the symptom that surfaced the bug.
  - **Every `log_err`/`log_warn`/`log_fail` from a board-launched subcommand was
    muted** — a duplicate `clikae init` name failed with no output at all.

  Each redirection is now scoped to a brace group (`{ exec 3</dev/tty; }
  2>/dev/null || …`), which still hides an open failure but reverts when the
  group ends. Verified in a real pty, including forcing the Trash fallback with a
  read-only `~/.Trash` and watching the warning actually print.

### Fixed

- **`clikae <typo>` printed help and exited `0`.** An unrecognised first argument
  is neither a command, an engine, nor a tank — but the dispatcher fell through
  to `help` and returned success, so no script could tell a typo from a hit
  (while `clikae mcp status` correctly returned 1, contradicting it two verbs
  away). Help is still printed as a courtesy; the exit status is now 1.

- **The new-tank picker could never preselect the engine you were standing on.**
  `_home_choose` compared the caller's bare value (`codex`) against its own
  ANNOTATED options (`codex  (AI)`), so the match never landed and the cursor sat
  on row 0 no matter which tank you pressed `n` from. Preselect now also matches
  an option's first token; menus with unannotated options are unaffected.

- **The new-tank picker offered Antigravity twice** — once as `agy (AI · power)`
  and again as `antigravity (tool)`, though `cmd_init` routes both to the same
  `_agy_init`. The scan that built the list keyed on "an adapter file exists",
  which is exactly the proxy `clikae_is_target` exists to replace: antigravity
  has an adapter file that is a resume-only shim on a launch-only target. It now
  asks the predicate.

- **Settled: agy quota is per-account and stacks — unless the accounts share a
  Google family plan.** This sat unresolved for months behind one hard fact: agy's
  `/usage` showed *byte-identical* figures for two different accounts, and the
  recorded conclusion was that only an expensive burn-test could tell a shared
  pool from a display artifact. The missing variable was that those two accounts
  were in the same Google **family**, which pools usage — so the identical
  display had been correct all along, not a preview bug. With three non-family
  accounts signed in, a read-only comparison settled it in minutes and cost no
  quota at all: 34.14% / 100% / 100% weekly. A shared pool would have shown one
  number three times.

- **Launcher templates are now compile-tested, and the iTerm2 gap self-closes.**
  AppleScript resolves an app's terminology from that app's dictionary, so the
  iTerm2 template can only be compiled on a machine that has iTerm2 — which is
  why it sat "never machine-verified" for months. Each template now has a compile
  test; the iTerm2 one SKIPS when iTerm2 is absent, so the first person who has
  it installed verifies it for everyone. Keeping iTerm2 (rather than dropping it
  for being unverifiable) is deliberate: the code path is gated on the app being
  present, so the only machine that runs it is one where the dictionary resolves,
  and a bad template fails loudly at `osacompile` instead of producing a broken
  `.app`.

- **Field-verified on ARM64 Linux.** The full bats suite and all three pty-smoke
  modes were run on a PineNote (aarch64, bash 5.2) over SSH: no failures,
  including the interactive pty paths and the launched engine keeping its stderr.
  CI runs x86 ubuntu, so real non-x86 hardware is a signal it cannot provide.

- **`clikae doctor` reports which agy tanks carry a saved login.** agy has one
  live Keychain slot, so switching tanks stashes the current login under
  `clikae-agy-<tank>` and restores the target's. A tank with no stash can't be
  switched to without an interactive Google sign-in — which means `clikae burn
  agy` can't auto-hop onto it either: a headless run would sit at a login prompt
  until `--print-timeout`. Found the hard way here (two of three tanks had lost
  their stash), and it was invisible until you tried it. It is a line in doctor
  now.

- **`clikae clean` no longer deletes anything as a fallback, and no longer says
  it moved things it didn't.** When `~/.Trash` was unusable, `_clean_to_trash`
  fell back to `rm` — "rather than leaving the row stuck" — and the closing line
  went on claiming everything had been moved to the Trash. The per-row warning
  was honest; the summary, which is the line a person remembers and would act on
  when they went looking for the file, was not.

  The two outcomes were never symmetric: a stuck row costs one uncleaned file, a
  fallback `rm` costs the file forever, and clean's payload is session history
  that cannot be regenerated — the very thing `clikae resume` exists to keep.
  Someone who asked to *move* something to the Trash never asked for that.

  - The Trash is now checked **before the red confirm**, so the question you
    answer is the one that will happen. Unusable → clikae says so and touches
    nothing.
  - `_clean_to_trash` never destroys. If an item can't be moved it is left
    exactly where it is and named.
  - The summary banks only rows that actually moved, and reports how many were
    left behind.

  Verified end to end in a real pty against a read-only `~/.Trash`: the confirm
  never appears, and the session file is still there afterwards.

- **`clikae doctor` names a tank that was signed out by a token-refresh race.**
  Claude's OAuth uses rotating refresh tokens, so when several sessions on one
  tank refresh at once the loser gets `invalid_grant`, treats it as "logged out",
  and clears the Keychain entry the winner just wrote — a working account dies
  with no explanation. clikae cannot prevent that (the refresh belongs to Claude
  Code's own daemon), but that daemon writes its log inside the tank clikae
  manages, so the aftermath is readable: doctor now reports the tank, the
  timestamp, and the one-line fix, and stays quiet once it has been logged back
  in. Bounded, read-only tail scan.

  The first draft of this check produced a false positive on the maintainer's own
  machine — it counted only "refresh succeeded" as healthy, and missed that the
  daemon's "scheduling proactive refresh" line is itself proof a token exists (a
  tank with none says "no token found" instead). Caught by reading the log the
  check had just accused, before believing it.

- **`clikae app` now defaults to the terminal you're actually using.** The
  default was hardcoded to Terminal.app, so an iTerm2 or Ghostty user got an
  Apple-Terminal launcher unless they knew `--terminal` existed. It now reads
  `$TERM_PROGRAM` — and only uses that guess if the app is really installed, so a
  guess can never turn a default into a failure. `$CLIKAE_TERMINAL` overrides the
  guess, `--terminal` overrides both, and the choice is printed on the
  `terminal:` line so it is never silent.

- **`clikae app --terminal warp` now explains itself.** Warp has no supported way
  to open a window running a given command — its URL scheme opens a tab in a
  directory and stops, and the only command-running door is a Launch
  Configuration YAML, a different shape from every other target and unverifiable
  without Warp installed. It says that, rather than shipping a launcher nobody
  has watched work or hiding behind a generic "unknown --terminal". The target
  name is also validated before the tank lookup now, so a mistyped `--terminal`
  no longer reports "profile not found" first and sends you debugging the wrong
  half of the command.

- **codex's usage limit turned out to be readable from disk after all, so the
  fuel gauge and `clikae auto` now cover it.** This project recorded for months
  that codex's limit was "exec-stdout-only — never written to a file clikae can
  scan"; that belief was load-bearing (it is why a codex tank could only ever
  show `○`, and why auto-carry was claude-only), and it was wrong. An
  *interactive* codex TUI writes the limit into its own rollout transcript:

  ```json
  {"type":"event_msg","payload":{"type":"task_complete","error":{
     "message":"You've hit your usage limit. … try again at Aug 23rd, 2026 8:26 PM.",
     "codex_error_info":"usage_limit_exceeded"}}}
  ```

  clikae matches `codex_error_info`, the machine-readable marker — never the
  English sentence beside it, which is vendor copy and will drift (a test pins
  that: a user typing "why do I keep hitting my usage limit?" must not dry the
  tank). Detection self-clears like claude's: an `agent_message` newer than the
  limit means the account recovered. The scan window is far wider than claude's
  5h roll, because a codex limit can run for weeks — but still bounded, since a
  tank nobody has touched has nothing to read and `○` is the honest answer.

  Confirmed against a real rollout on the maintainer's machine whose
  `session_meta` says `originator: codex-tui` — i.e. not a headless run — and the
  reset phrase is surfaced verbatim, never parsed into a countdown.

- **The same engine had two names depending on which screen you were on.**
  `clikae list` and the board said `agy`; `clikae doctor` printed the on-disk
  directory name, `antigravity`. Three surfaces had each grown a private copy of
  the mapping and doctor had none. There is now one owner, `engine_label` in
  `lib/core/profile_store.sh`, next to the predicate that already knew the alias.
  The store path, the `targets/` filename and the JSON `path` field all stay
  `antigravity` on purpose — and `docs/usage.md` now warns, where the JSON
  contract is documented, never to build a path out of `cli` + `profile`.

- **The `?` help overlay never listed `R`** (open the cross-tank resume picker),
  on the one screen whose entire job is to list every key. Added, with its label
  in all nine languages — and a bats test now fails when a key is bound in the
  board's key loop but missing from the legend, so the two cannot drift again.

### Added

- **The gate grew a third leg: a real-pty smoke run, and it blocks.** shellcheck
  reads source and bats never presses a key, so both are structurally blind to
  the TUI — which is where this project's regressions keep landing, most
  expensively the stderr bug above, which shipped through a fully green gate.
  `tests/tools/pty-smoke.py` now runs from `scripts/test.sh` and from CI on both
  macOS and Ubuntu, driving the real binary on a real pty.

  It became hermetic to earn that: each mode builds its own throwaway `$HOME`
  and `$CLIKAE_HOME` with fixture tanks, pins `CLIKAE_LANG=en-US` so assertions
  don't depend on the runner's locale, and puts a stub engine on `PATH` — it
  never reads the developer's store and never launches a real engine. It also
  stops short of nothing: a new `prompts` mode presses `n`, `a` and `m` and
  asserts each prompt is **visible**, presses Enter on a row and asserts the
  launched engine's **stderr** reaches the terminal, and triggers a
  duplicate-name `init` to assert its error is readable. Pacing is idle-based
  rather than fixed sleeps (58s → 28s), because a slow gate is a skipped gate.

  Every assertion was validated against a pre-fix worktree first: five of the
  eight `prompts` checks go red there, and the three that pass on both are the
  controls that prove the harness isn't simply failing everything.

- **`clikae doctor` now verifies the login-Keychain coordinates, read-only.**
  macOS keeps the login for both claude and agy in the Keychain rather than in
  the config dir clikae swaps, so account isolation rests on two hard-coded
  coordinates that the suite cannot check — `antigravity.bats` stubs `security`,
  so a vendor-side rename would pass CI and surface to a user only as "why am I
  suddenly on the wrong account". doctor now reports whether agy's slot
  (`gemini` / `antigravity`) exists and how many claude tanks have a saved
  login. It never passes `-w`: reading the secret is what makes the Keychain
  prompt for access, and `doctor` must never pop a dialog — presence only, never
  the value.

### Documentation

- **A documentation audit: every doc reconciled against the code.** `HANDOFF.md`
  was rewritten from 1089 lines of dated status blocks — its own "READ THIS
  FIRST" header was five releases stale and two of its claims were false — into
  a file where every line is either a live rule or an open item, under a
  maintenance contract that says closing an item means deleting its entry.
  `PLAN.md` and `docs/HANDOFF-world-class-gaps.md` were removed: both declared
  themselves shipped/cleared in their own first lines. `AGENTS.md` and
  `docs/DEVLOG.md` were brought up to the v0.13 repositioning (the devlog had
  stopped at v0.6.0). Corrections across the rest: **`clikae burn agy <tank>`
  has worked since v0.10.0**, but four documents still said agy couldn't be
  burned; the board's `← here` row marker was documented years after it was
  removed; `clikae adapters` does list `antigravity`; `docs/adding-a-locale.md`
  still described three languages and an unshipped `zh-Hans`;
  `docs/troubleshooting.md` told contributors to run `bats tests/bats` without
  `-r`, which silently skips every adapter test; `docs/grammar.md` carried an
  unchecked implementation checklist for work that shipped in v0.5 and labelled
  the Soul design an undecided frontier. `docs/adding-an-adapter.md` gained the
  ~20 optional adapter hooks it never mentioned. No behaviour changed.

## [0.14.5] — 2026-07-21

### Fixed

- **A hard terminal close during `--ephemeral` stranded the tank's real
  memory.** An ephemeral run points the tank's memory dir at a throwaway and
  stashes the real memory aside, restoring it from a `trap … EXIT`. But the trap
  caught only `EXIT`/`INT` — **not `HUP`/`TERM`**. Close the terminal window and
  the process takes a `SIGHUP`, whose default action terminates it *without*
  running the EXIT trap: the memory dir is left a dangling symlink to a
  now-deleted `clikae-ephemeral.XXXXXX` temp, the real memory marooned in
  `<mem>.clikae-ephemeral-stash`, and the slot reads as **empty**. Worse, the
  ephemeral path self-healed only on the *next* ephemeral launch, so an ordinary
  `clikae claude <tank>` session never recovered it — the tank stayed broken
  until fixed by hand. (Incident 2026-07-19: a hard-closed ephemeral left a
  tank's memory dangling; the Soul store itself was untouched — only the
  pointer.) Two guards, both shipped:

  1. `_switch_run_ephemeral` now traps `HUP`/`TERM` too, re-raising each as a
     normal exit so the restore runs on a terminal close.
  2. `soul_prelaunch` — the universal memory-prelaunch hook every launch path
     goes through — now runs `memory_heal_ephemeral` first: a dangling
     `clikae-ephemeral.*` link is dropped and the stashed memory restored, on
     *any* launch (solo, member, own-memory tanks alike). This also recovers the
     cases no trap can catch (`SIGKILL`, power loss). It never clobbers a live
     memory, and leaves foreign symlinks alone.

## [0.14.4] — 2026-07-21

### Fixed

- **`clikae resume` and the home board showed a session's PRE-`/rename`
  name.** `adapter_title_for_file` — the extractor behind the resume picker,
  the home board's continue list, and `clikae clean`'s deletion list — scanned
  only the first 100 lines of a transcript. But a `/rename` can land anywhere:
  Claude writes `{"type":"custom-title","customTitle":"…"}` at the point of the
  rename, so a session renamed deep in a long conversation kept listing its old
  name, while the board's own `_claude_meta_for_file` (which reads the tail)
  showed the new one. The two title paths had silently drifted — exactly the
  failure the "one place owns this format" note warned against, and the same
  code path behind the 2026-07-11 near-miss where a renamed live session almost
  landed on the `clean` deletion list. Found on the maintainer's machine: a
  60 MB session renamed `voxel@cvertex` at transcript line 13845 still listed
  as `cvertex`.

  `adapter_title_for_file` now scans the bounded tail slice **first** for the
  newest `customTitle`/`aiTitle` (`tail -c` seeks from the end — cost is the
  slice, not the file; the same primitive `_claude_meta_for_file` uses), then
  falls back to the head window and opening prompt. Precedence now mirrors the
  board extractor — `customTitle`(tail→head) > `aiTitle`(tail→head) > opening
  message — so the resume/home/clean views can't drift from the board again.

## [0.14.3] — 2026-07-13

### Fixed

- **`memory isolate` → `memory share` was a memory-LOSING round trip, and
  `memory status` lied about it.** `share` fanned in only the project-directory
  slots that still existed, and `isolate` had just removed every one of them —
  so a directory whose memory was a pure symlink (nothing of its own to stash)
  came back as *nothing*, and the re-share silently skipped it. Membership lives
  in the group's members file, so `memory status` went on reporting `shared`
  while the tank's memory was gone from disk. The per-directory symlink is
  otherwise re-projected at launch, but a session **already running** in that
  directory never gets a relaunch: it just goes amnesiac mid-flight. Found the
  hard way — an agent ran `isolate` on a live tank to spawn a cold reader, and
  the maintainer's running session lost its long-term memory.

  `share` now fans into **every** project directory of the tank, creating the
  slot when it isn't there. A directory that keeps its own memory is still
  stashed alongside, never destroyed, and `isolate` still gives it back.

### Documentation

- `AGENTS.md` now states the rule where an agent will actually hit it: **a
  memory-less session is `--ephemeral`, never `memory isolate`.** `isolate` is
  not "incognito" — it rewires the live tank, including every other session
  already running in it. *Ephemeral changes this once; isolate changes from now
  on.*

## [0.14.2] — 2026-07-13

### Fixed

- **Rows and prose no longer disagree about how wide the terminal is.** The
  board, `resume` and `clean` measured and cut titles by *characters* while
  their budgets were expressed in *columns* — so a CJK title, whose glyphs are
  two columns wide, rendered at roughly twice its budget and hard-wrapped back
  to column 0. Latin-only test fixtures can't tell the two apart, which is why
  the suite stayed green while real rows ran off the edge. Width is now measured
  by display columns throughout (`_dwidth`, East Asian width), the fixtures
  carry CJK titles, and `clikae clean` sacrifices columns by importance — age
  first, then size, then the title (never below a readable floor), and the
  keybar wraps rather than overflowing. The safety label is never truncated.
- **`_home_wrap_prefixed` read the terminal behind `_home_cols`' back**, so
  prose fell back to 80 columns whenever output was piped — every heading
  between 61 and 79 columns overflowed a narrower window. There is now one
  width source, and it honours `$COLUMNS` when there is no tty to ask.

Audited across nine locales at 60, 80 and 100 columns against a real session
store: no rendered line exceeds the terminal width.

## [0.14.1] — 2026-07-12

### Fixed

- **`clikae clean` could offer a LIVE session for deletion, unchecked, and then
  `rm` it outright — a real data-loss incident, on the maintainer's own
  machine, the day v0.14.0 shipped.** `clean`'s live-process guard only ever
  covered the stale-copy dedupe path; the main scan loop that classifies
  sessions as "Untouched for 30+ days" or "Big but recent" never consulted it,
  so a session with a process still attached (`claude --resume <sid>` open in
  another terminal) could surface unchecked under "Big but recent" — one
  keypress from deletion. It was checked, and deleted. The transcript was 612
  MB and 6 days old; Claude Code appends per-event and holds no open handle on
  it, so there was no inode for `lsof` to rescue, and `clean` used `rm`, which
  never reaches the Trash in the first place. Unrecoverable. Two fixes ship
  together: (1) one shared guard (`_clean_session_is_live`), called from every
  candidate class, not just dedupe — a live session is never offered, in any
  section, full stop; (2) `clean` now moves candidates to `~/.Trash` instead
  of `rm`ing them (collision-safe — same-named copies from different tanks get
  a ` (1)`, ` (2)`… suffix, never clobbering an existing entry), matching the
  line sibling tool sheersweep already holds for macOS uninstalls. Every
  string that used to promise space was "freed" now says it moved to the
  Trash, across all nine locales; if the Trash itself is unusable, a row falls
  back to a direct delete and SAYS SO on that row, rather than silently lying
  about where the data went.
- **A session's own `/rename` was invisible everywhere, including `clean`'s
  deletion list — which is why the live session above wasn't recognized
  before it got checked.** The claude adapter derived every title from
  Claude's machine-generated `aiTitle` only; `/rename`'s
  `{"type":"custom-title","customTitle":"…"}` was never read, so a
  deliberately renamed session kept showing its stale machine title on the
  board, in the resume picker, and in `clean`'s own list — 11 renamed sessions
  on the maintainer's machine showed none of their real names. A user-set
  title now outranks the machine-generated one everywhere the adapter derives
  a title from a transcript (codex and antigravity have no equivalent rename
  event to prefer — checked, not invented).

## [0.14.0] — 2026-07-12

### Added

- **i18n is ready for more languages: per-locale string files + mechanical CI.**
  The three string tables moved out of `lib/core/i18n.sh` into
  `lib/i18n/<locale>.sh` (en-US is the canonical key list; still loaded with a
  plain `source` — instant, offline, ships with the body), and the resolver's
  `_i18n_locales` became the single source of truth for the supported-locale
  list: `clikae lang`'s choices, the board's `l` picker, and the tests all
  derive from it — no second hardcoded list anywhere. A new completeness test
  in `tests/bats/i18n.bats` extracts the key list and the locale list from the
  code itself and asserts every key × every locale is defined, non-empty, and
  placeholder-compatible with en-US, so adding a language is a self-contained
  PR (one string file + one resolver line — see the new
  [docs/adding-a-locale.md](docs/adding-a-locale.md)) and a partial
  translation can never merge silently.

- **clikae speaks nine languages.** Joining English, 日本語 and 繁體中文:
  简体中文, 한국어, Español, Deutsch, Français and Português (Brasil). Each was
  transcreated against that language's own Apple macOS system strings rather
  than machine-translated from English, and translated *by grade*: the
  sentences you must understand to consent — deleting sessions, spending a
  tank's last fuel — are fully localized, while the things you type or copy
  (commands, flags, paths, sizes, session ids) stay technical. Chinese is keyed
  by writing system, not region: `zh_CN`/`zh_SG`/`*Hans*` read `zh-Hans`,
  `zh_HK`/`*Hant*` read `zh-TW`, and a bare `zh` keeps Traditional, the
  incumbent default. Any other regional variant (`pt_PT`, `fr_CA`, `ko_KR`…)
  lands through the generic language-subtag rule — no resolver line needed.

  The six new tables were reviewed by a model from a different family, reading
  each one cold against the English — which caught real inversions (a German
  line that promised the disk space you *have* rather than the space you'd
  *reclaim*) and, just as usefully, produced a pile of confident nonsense that
  did not survive checking. They are an honest LLM-grade baseline, not a
  native-speaker's work: if a string reads wrong in your language, the file to
  fix is `lib/i18n/<locale>.sh` and the PR is welcome.

- **`clikae clean` — disk cleanup is a top-level command now.** The flow that
  shipped inside `resume cleanup` (v0.13.1) was a capability buried under
  another command's subtree — nearly undiscoverable, and disk hygiene was
  never a resume concern. It's extracted whole into `clikae clean` (grammar
  §3.3; `clikae resume cleanup` keeps working as a hidden §7 alias that
  forwards verbatim), and the zero-knowledge path is the point: type
  `clikae clean`, look at ONE list, Enter, red confirm — no flags needed.
- **The preview is sectioned, with smart defaults.** The flat biggest-first
  list becomes three labeled sections (still biggest first within each):
  *Redundant (safe)* — stale copies + orphaned subagent data, pre-checked;
  *Untouched for 30+ days* (or your `--older-than`), pre-checked; and *Big
  but recent — your call* — sessions of 20 MB or more that no filter selected,
  plus copies with unique content (`diverged — has unique content`), shown
  UNCHECKED so the space hogs are visible with zero flags but never deleted
  without an explicit opt-in. `--dry-run`, the non-TTY refusal, and the
  `--older-than`/`--min-size` semantics carry over unchanged.
- **The board is the hub (grammar §8.1).** `c` on the home board opens the
  clean screen and returns to the board when it exits — same first-class-key
  treatment `R` gives the resume picker — and it's in the `?` legend in all
  three languages. The resume picker's `c` key no longer embeds its own
  cleanup pass: it opens the same `clikae clean` screen and, when that exits,
  rescans the store and redraws the picker instead of dropping you to the
  shell over a stale list.

## [0.13.1] — 2026-07-11

### Added

- **`resume cleanup` reclaims stale session copies, on by default.** `clikae to`
  /relay and a cross-tank resume COPY the transcript into the target tank and
  never clean the source — on a real store that was 686 MB of redundant copies
  (26% of the session data). Cleanup now groups every session's copies across
  all tanks and project dirs, keeps the LARGEST copy (mtime lies: the newest
  copy is not always the byte-superset), and offers a copy for deletion only
  when a byte-level safety check proves it redundant — an exact prefix of the
  kept copy, or a tail of session-metadata lines only. A copy with unique
  conversation content is listed as "diverged — not auto-selected" and starts
  unchecked; a session with a live process is skipped entirely. The prefix test
  is `head -c | cmp`, never `cmp -n` (BSD cmp exits 1 on an exactly-n-byte
  file, which would misread every byte-identical copy as diverged).
- **`resume cleanup --min-size <MB>`** — a size axis for the age filter's blind
  spot: space usually lives in big *recent* sessions, not old ones. Given
  alone, size is the only filter (no age cutoff); combined with an explicit
  `--older-than`, a candidate must satisfy both.
- **A checkbox preview replaces cleanup's all-or-nothing confirm.** The
  candidate list (always sorted biggest first) is now an interactive picker:
  arrows move, space toggles a row, `a` toggles all, Enter proceeds to the
  final red confirmation, q/ESC cancels. `--dry-run` prints the same list
  non-interactively, and a non-TTY run still refuses to delete anything.

### Fixed

- **`resume cleanup` leaked claude's per-session `<sid>/` directories** (the
  subagent/workflow transcripts next to each transcript): deleting a session
  now removes — and the preview prices — the sibling directory too, and
  already-orphaned sid dirs (dir present, transcript gone) are swept as their
  own candidate class, labeled `orphaned subagent data`.

## [0.13.0] — 2026-07-11

The repositioning release: the front page now tells the story VISION.md
always pointed at — your AI work has two halves, and clikae keeps YOUR half
(identity, memory, sessions, incognito) portable across engines. Multi-account
quota rotation steps down to an advanced chapter with an honest, dated terms
page. Gated, like v0.12.0, by an incognito red-team pass over the final diff
(which caught and killed two claims that overshot shipped behavior).

### Added

- **docs/terms-and-your-accounts.md** — where the vendors' terms draw the
  line on multi-account use, with the actual policy language, dated research
  (2026-07-11), and an honest map of which clikae features sit on which side.
  Different accounts for different purposes is explicitly fine; carrying the
  same task past a usage limit is the gray zone — this page says so plainly
  instead of leaving users to find out from an enforcement email.
- **A one-time note before your first cross-account carry** (`clikae to`, or
  `clikae burn` with fall-through armed): a short version of that page, once,
  then never again. Headless runs print it and never block.

## [0.12.0] — 2026-07-11

A deep no-new-features audit pass: four independent review lenses (performance,
dead code, correctness/portability, structure) over the whole tree, then the
verified findings applied.

### Fixed

- **`clikae resume` / `resume cleanup` died silently on a single-engine
  store** — with even one engine's directory absent, the unmatched session
  glob made `stat` exit non-zero and `set -eo pipefail` killed the command
  with no output at all. Present since v0.7.1; caught by pointing an
  incognito (`--ephemeral`) reviewer at this release's own diff.
- **`clikae resume` picker had no way to reach `cleanup`** — it shipped as a
  separate subcommand (`clikae resume cleanup`) with no affordance from the
  interactive picker, so it was easy to not know it existed. Press `c` from
  the picker now to jump straight into the same interactive cleanup flow.
- **`resume cleanup` titled every out-of-directory claude session "(no
  preview)"** — titles were looked up via the board's $PWD-scoped hook. A new
  file-based hook (`adapter_title_for_file`) extracts the title straight from
  the transcript; the picker and cleanup both use it.
- **Session titles truncated at an escaped quote** — the string-surgery
  extraction cut `Fix the \"off-by-one\" bug` down to `Fix the `. Extraction
  is now escape-aware (bash-native `=~`) in claude, codex, and the picker,
  which had also drifted from antigravity's canonical whitespace handling.
- **A space in `$HOME` / `$CLIKAE_HOME` silently dropped every codex session**
  from the board's Continue list (unquoted word-splitting of the rollout list).
- **A translation gaining a stray `%` can no longer corrupt output silently**
  — the ~10 `T_*` strings used as printf formats now have their placeholder
  contract pinned by a per-language test; `json_str` escapes `\r`/`\b`/`\f`
  so a CRLF-tainted value can't emit invalid `--json`; `migrate`'s rc-file
  rewrite cleans up its temp file and aborts untouched on failure.
- **`dry_seen_suffix` could print a wrong time on Linux** — BSD-style
  `date -r <epoch>` means "<file>'s mtime" on GNU, so a numeric-named file in
  $PWD made it succeed with garbage; the GNU form now runs first (the same
  ordering rule the codebase already applies to `stat`).

### Changed

- **One keyboard decoder for every picker** (`lib/core/tui.sh`). The home
  board, its sub-menus, and the resume picker each carried their own inline
  ESC state machine — the layer that regressed in dogfood more than once —
  and they had drifted. Now: the board gains PgUp/PgDn/Home/End, reads a
  dedicated /dev/tty fd like the others (it was the last bare-stdin reader)
  and never leaks that fd into a launched engine, application-mode arrows
  (ESC O A…) decode instead of leaving stray letters, and the resume picker
  paints each frame as one atomic write (the board's anti-flicker fix).
  Covered by decoder unit tests (`tests/bats/tui.bats`) and a real-pty
  end-to-end driver (`tests/tools/pty-smoke.py`).
- **`next_tank` no longer does O(n²) work**: one `order_list` pass and one
  batched dry-set (the board's kernel) instead of a per-candidate account-
  contagion scan that re-walked every profile.
- **Faster everywhere, measured on a real 2300-session store:** `resume
  cleanup` prices candidates with ONE batched `du` instead of one per session
  (7.4s → 3.7s at `--older-than 0`); `load_adapter` is memoized (one board
  render re-sourced the same adapter up to 18×); hot loops use parameter
  expansion instead of `basename`/`awk` forks; the home board render dropped
  ~15%. Non-TUI commands no longer load the i18n string table at all.
- **Bounded reads for the two stragglers** that still scanned whole
  transcripts (the documented 100+ MB trap): `_claude_meta_for_file` (relay
  preview, `clikae list`) and `watch --check`, which now reads the tail slice
  and says so.
- **~220 lines of dead/duplicated code removed**: the never-called
  `adapter_recent_sessions` hook (×3 adapters), `store_root`, `i18n_cycle`,
  5 unused `T_*` keys (×3 languages), and one shared owner each for the
  picker's row decode, path→session-fields derivation, the three-engine glob
  list, and the human-age formatter.

## [0.11.1] — 2026-07-06

### Added

- **`clikae mcp <share|unshare|list>`** — fleet-wide MCP server sharing.
  `tank_is_solo` was always meant to run two logics — fleet tanks work
  seamlessly together, a solo tank stays deliberately out of that — but until
  now only Soul memory (opt-in, per-tank) and skills/commands (unconditional)
  read it; dev-environment config like MCP servers had no fleet story at all.
  `mcp share <name>` promotes an already-added server into ONE canonical
  per-engine store, and every tank that ISN'T solo gets it merged into its own
  config automatically — at share time for existing tanks, and at every
  launch from then on (`fleet_mcp_prelaunch`, wired into
  `switch`/`run`/`relay`/`resume` alongside `soul_prelaunch`). Merge is
  additive-only: a tank's own entry for the same name is never overwritten.
  Requires `jq` (claude.sh only, for now).

## [0.11.0] — 2026-07-05

### Changed

- **Soul sharing is per-tank, whole-brain — not per-directory.** The consent
  unit was always the tank (the members file, the cross-account guard), but
  claude's per-project memory layout meant one `memory share` only linked the
  directory it ran in; sessions started anywhere else silently accumulated
  isolated side-memory. Now membership is the single source of truth and the
  per-directory symlinks are just projections of it: `share` fans in every
  existing project directory at once, and every launch path (switch, run,
  relay, resume) links the current directory's slot first (`soul_prelaunch`).
  A member tank can no longer fragment its brain; the only ways to keep a
  tank's own memory are `memory isolate` and `solo`.
- `memory isolate` unlinks EVERY projected directory (restoring each slot's
  stashed own memory), not just the directory it runs in.
- `memory status` reports tank-level membership, with a per-directory
  "links on next launch" note — an unlinked directory no longer reads as
  "isolated" for a tank that shares its brain.

### Fixed

- `--ephemeral` on a Soul-shared tank no longer permanently un-shares the
  directory: the Soul link was treated as a crashed run's leftover and
  removed; the exit trap now re-links it.
- `clikae rename` (claude and agy) carries Soul membership instead of leaving
  a ghost member under the old name and a tank that reads as isolated while
  its slots still point at the store.

## [0.10.0] — 2026-07-05

### Added

- **agy tank switching carries the Google login again, verified this time.** The
  2026-06-30 logout+re-OAuth flow is replaced by a hardened Keychain carry: every
  restore is checked against the stash before agy launches, refusing to proceed
  silently if it doesn't match — the actual fix for the trust bug that got the old
  carry removed. New real-Keychain integration test exercises the actual `security`
  binary against a disposable scratch keychain, never the login item.
- **`clikae burn agy <tank>` works.** Since a tank switch no longer needs interactive
  OAuth, burn can auto-hop agy to the next tank on dry — sequential only, agy still
  can't run two tanks in parallel (unchanged, structural).
- **`clikae resume ask-tank [always|dry-only]`.** Resuming a session now asks which
  tank to land on every time by default (matching `clikae resume`'s standalone
  picker), not just when the tank is dry — `dry-only` restores the quieter old
  behavior. The cross-tank session carry (`_resume_carry_session`) is now shared
  code between the standalone picker and the home board, and covers codex/
  antigravity, not just claude.
- **Windows via WSL is now a documented, first-class path.** clikae is plain bash,
  so it already runs unmodified under WSL — the README now says so instead of
  leaving Windows users to guess. The community PowerShell port (native Windows,
  no WSL) is unchanged: unsupported, CI informational-only.

### Fixed

- The shared cross-tank session carry now explicitly loads the target engine's
  adapter before looking up a session — it previously relied on that happening as
  a side effect of an unrelated subshell elsewhere in the board, which didn't
  reliably hold, silently carrying nothing on some paths.
- `clikae demo`'s end-to-end test asserted for the on-row `← here` marker text that
  was intentionally removed on 2026-06-30 (commit `9d55047`) — missed in that
  refactor because the assertion was missing `|| false`, so it silently never
  failed locally; only a stricter CI `bats` caught it. Test updated, two stale
  comments and the design doc corrected to match current behavior.

## [0.9.2] — 2026-07-01

### Fixed

- **A claude tank no longer isolates away your personal skills/commands.** `CLAUDE_CONFIG_DIR`
  isolation was meant for identity state (auth token, transcript history, keychain slot), but
  Claude Code also reads personal skills and slash commands from
  `$CLAUDE_CONFIG_DIR/{skills,commands}` — so a freshly created tank silently couldn't see
  anything under `~/.claude/skills` or `~/.claude/commands`. `clikae init` and every `clikae
  claude <tank>` switch now symlink `skills/` and `commands/` from `~/.claude` into the tank,
  share-by-default, unless the tank already has its own real entry there (a deliberate
  per-tank override, never touched). Idempotent, so tanks created before this fix self-heal
  on next use.

## [0.9.1] — 2026-06-30

### Fixed

- **The `?` help overlay aligned its descriptions by byte count**, so rows whose keys
  hold multibyte glyphs (`↑ ↓  j k  Tab`, `⏎ Enter`) sat crooked. The description
  column is now placed at an absolute terminal column, so every row lines up.
- **The `clikae resume` picker now uses the same columns as the home board** — dot ·
  name · engine · "title" (age) — instead of `engine/tank · "title"`, so the two views
  read as one grid. The expanded row still shows `dir:` + the full session `id:`.

## [0.9.0] — 2026-06-30

### Changed — agy tank switch logs out instead of carrying tokens

`clikae agy <tank>` now **logs agy out** on switch (clears the one machine-wide
Keychain login) and lets agy prompt a fresh Google sign-in for the new tank's
account — your browser already holds your logins, so it's a click. This replaces the
old per-tank Keychain stash/restore dance. Why: agy reads its account purely from
that one Keychain slot, ignoring which tank dir is active (verified live), so the
stash/restore was both fragile (never tested against a real Keychain) and risked
landing you on the wrong account if a restore silently no-op'd — you could burn the
wrong account's quota without noticing. Now clikae never reads or writes a token (no
secret handling), keeps no per-tank Keychain slots, and the account you end up on is
the one you explicitly picked. Honest cost: a cross-account switch needs an
interactive sign-in, so headless `burn`/`conduct` can't change agy accounts.

### Added — `clikae memory` (the Soul layer)

A tank holds more than fuel — it holds the engine's long-term memory. `clikae memory
share|isolate|status` points that memory at ONE vendor-neutral markdown store (a
"Soul") so several of your own tanks — **across engines** — read and write a single
brain. Swap the engine, keep the soul.

- **One canonical Soul** per group: `$CLIKAE_HOME/souls/<group>/memory`, plain
  markdown you own.
- **claude** fans its memory dir into the store with a symlink (the persistent
  fan-in sibling of `--ephemeral`'s fan-out).
- **codex** and **agy** keep their own memory opaquely, so they get a fenced pointer
  note in the markdown rules file each reads on start (`AGENTS.md` for codex,
  `GEMINI.md` for agy) and read/write the same Soul via the memory protocol — no
  translator, no drift (it's literally the same file).
- 🔴 Sharing is opt-in and per-tank; clikae never auto-crosses accounts. Crossing
  your own accounts is announced (`--yes` skips the prompt). The store is seeded by
  COPY; a joiner's own memory is stashed aside (reversible via `isolate`).

Convention + schema in `docs/memory.md`; design rationale in `docs/grammar.md` §10.
The per-entry scope dial + conduct/burn integration are the dogfood-gated Phase 4 —
parked until the shared Soul has been lived in, not in this release.

### Added — `clikae solo` (a tank out of the fleet)

`clikae solo [<engine> <tank>] [reason | --off]` marks a tank **standalone**: it's
skipped by `burn`/`watch` rotation and `to`/relay, and `memory share` refuses it. This
walls off a bot/persona tank that lives on **your own account** (so the cross-account
guard can't see it) and must never be commingled — for the maintainer, the gaido bot
tank. Bare `clikae solo` lists the solo tanks. Marker: `<tank>/clikae-meta/solo`.

### Changed — the home board is an interactive cockpit

`clikae` with no args on a terminal is now a full launcher, not just a listing. New
verbs on the selected tank: **`s`** toggles solo, **`m`** opens the memory (Soul) dial
(share / isolate / status) — alongside the existing open / relay / resume / incognito /
new / rename / delete / reorder / filter. The board was also redesigned for clarity:
**three sections (Tanks / Solo / Resume)** where a section is the badge (solo tanks live
in their own block, no per-row icon), **aligned columns** (name · engine · account,
CJK-safe), Resume rows on the same grid, and **no emoji / no "current shell" marker** —
with many tanks open at once, the latter is noise.

## [0.8.1] — 2026-06-30

Fixes the update notice going silent. A transient failure when fetching the latest
release (a slow network, a blocked `api.github.com`, or the old too-tight 2s timeout)
used to stamp a full 24h throttle **and** write back the last-known version — so one
hiccup could pin a version older than the one you'd already installed and the home
board would say nothing about a real new release, sometimes indefinitely. Now a
successful check is trusted for the full day, but a failed/offline check keeps the
last-known version and retries within the hour (`CLIKAE_UPDATE_RETRY`, default 3600s),
so a blip self-heals instead of going quiet. The fetch timeout is also relaxed from 2s
to 5s for slower connections. No behaviour change when the network is healthy.

## [0.8.0] — 2026-06-30

`clikae resume` grows up into an interactive, cross-engine session picker, and the
home board gets dramatically faster. With no id, `clikae resume` now opens a TUI
that lists recent sessions across **every** tank — claude, codex, and antigravity —
newest first, with live filtering and paging, so you pick a session by title
instead of copy-pasting a UUID; press `[R]` from the home dashboard to open it. A
new `clikae resume cleanup` reclaims disk from old session data (interactive, asks
first, with `--dry-run`/`--older-than`). Under the hood the home board went from
several seconds to well under one on large tanks, by reading only the slices of
(sometimes 100+ MB) transcripts it actually needs and scanning each tank's fuel
state once instead of repeatedly.

### Added

- **Interactive `clikae resume` picker** — run with no id to browse recent sessions
  across all tanks (filter with `/`, move with arrows/`j`/`k`, page with PgUp/PgDn,
  `g`/`G` for top/bottom). Cross-engine: claude, codex, and antigravity sessions all
  appear. `[R]` from the home board opens the same picker.
- **codex + antigravity resume** — both can now be resumed by id and surfaced in the
  picker (antigravity copies its `brain/` + conversation db across tanks on resume).
- **`clikae resume cleanup`** — delete old session transcripts/databases to free disk
  space. Interactive and asks before deleting; never removes tank configs or memory.
  `--dry-run` previews; `--older-than <days>` scopes it.

### Changed

- **Home board is much faster** (~8s → well under 1s on a multi-GB tank). Transcript
  reads are bounded to the head/tail slice actually needed (a shared
  `transcript_head`/`transcript_tail`), fuel/over-quota detection folds its per-file
  pipeline into a single pass, and the board scans each tank's fuel state once rather
  than re-scanning same-account siblings.
- A shared `sessions_by_mtime` kernel now backs every "recent sessions" listing (the
  picker, `cleanup`, and each adapter), replacing copy-pasted stat/ls loops.

### Fixed

- The resume picker no longer crashes or mis-pages on the arrow / Page Up / Page Down
  keys, and `[R]` from the board no longer aborts with `cmd_resume: command not found`.

## [0.7.1] — 2026-06-26

Resume a past session by id, no matter which tank holds it. Because clikae gives
each tank its own config dir, a session transcript lives under that tank — not the
engine's default home — so a bare `claude --resume <id>` in a fresh shell fails
with "No conversation found": the engine looked in its default home and the session
is in a tank. Resuming a known session is therefore clikae's job, and until now it
had no verb for it (`to`/`relay`/`continue` only carry your *current* shell's live
session *forward*). This release adds `clikae resume`, which reaches *backward* to a
named session: it scans every tank, finds the owner, cd's to the directory the
session was recorded in, and resumes it under that tank's config — so you never need
to know which tank, and with no id it lists recent sessions across all tanks by
title so you pick one instead of copy-pasting a UUID.

### Added

- **`clikae resume [session-id]`** — reopen a specific past session by id in
  whichever tank owns it. `clikae resume <id>` locates the tank, cd's to the
  session's recorded working directory, and resumes it under that tank's config dir.
  Run with no id, it lists recent sessions across all tanks (newest first, by title)
  and resumes the one you pick — no UUID to copy. Extra engine args pass through
  after `--`. Only engines that can resume by id take part (claude today).
- **Adapter hooks** `adapter_find_session`, `adapter_session_cwd`, and
  `adapter_recent_sessions` (claude) — locate a session by id across all of a config
  dir's projects, recover the directory it ran in, and list recent sessions for the
  picker. Engines that don't define them simply aren't reachable by `resume`.

## [0.7.0] — 2026-06-24

agy (Antigravity) becomes a first-class breadth engine. Until now `conduct` could
only fan to claude and codex; this release lets it fan a read-only best-of-N leg to
Antigravity too, so cheap/fast breadth work rides your agy quota instead of your main
budget. Because agy is adapter-less (one global Keychain login that can't be switched
per-shell or run in parallel), the leg is special-cased to run on the currently active
agy tank, with an honest `NOTACTIVE` report rather than silently using the wrong
account. Alongside it, the hard-won knowledge of how to drive agy headless — which a
session previously re-learned (and re-burned) every time — is now baked into
`clikae agy --help`, a canonical `docs/agy-dispatch.md`, and the orchestration
playbook. The misleading bare `not burnable` footer is reworded too.

### Added

- **`conduct` accepts an agy leg** — `clikae conduct --leg agy/<tank>` now fans a
  read-only best-of-N prompt to Antigravity alongside claude/codex legs, so cheap
  breadth work can ride your agy quota instead of your main budget. agy is
  adapter-less (one global Keychain login), so the leg is special-cased: it runs on
  the **currently active** agy tank only — a leg naming another tank is reported
  `NOTACTIVE` (with the active tank's name), never silently run on the wrong account,
  because clikae can't switch agy per-shell or run two agy tanks in parallel. Its dry
  state is read from `cli.log` (`limit_log_dry`), since `agy -p` exits 0 with empty
  stdout when it hits its Gemini quota. Tests in `tests/bats/conduct.bats` (+5).
- **`docs/agy-dispatch.md`** — a canonical how-to for driving agy headless via clikae
  (the `-p`-not-`-i` rule, prompt-via-file, write-to-a-file-not-stdout, fenced task +
  long `--print-timeout`, `--add-dir`, `pkill` before switching, skip-permissions is
  for a human not an agent). `clikae agy --help` now carries the one-line recipe and
  points here; `docs/orchestration.md` gained an agy section.

### Changed

- **agy "not burnable" footer reworded** — `clikae tanks` no longer prints the
  misleading bare phrase `not burnable`. It now reads (localised via
  `T_AGY_BURN_NOTE`, en/ja/zh-TW) that agy's global login means `burn` can't
  auto-reroute it across tanks, but it runs fine headless on the active account via
  `agy -p` (or switch interactively with `clikae agy <tank>`).

## [0.6.2] — 2026-06-20

A small housekeeping patch with no behaviour changes. One Chinese string was
leaking into the English `relay` / `to` preview card regardless of the user's
locale setting; it now reads `swap the tank · keep burning` in line with the
command's own header metaphor. Separately, every remaining foreign-language
string in code comments has been translated to English — the project policy is
that comments are English-only and only the i18n dictionary (`lib/core/i18n.sh`)
carries other languages.

### Fixed

- **`relay` preview card locale leak** — the subtitle label on the relay preview
  card was hardcoded in Chinese (`換油箱・接力`) and appeared in that language
  regardless of locale. It now reads `swap the tank · keep burning`, consistent
  with the file's own `"Swap the fuel tank and keep burning."` header.

### Changed

- **Code comments translated to English** — thirteen comments across `bin/clikae`,
  `lib/commands/home.sh`, `lib/commands/switch.sh`, `lib/commands/burn.sh`,
  `lib/adapters/claude.sh`, `lib/adapters/codex.sh`, and `lib/core/update_check.sh`
  contained Chinese or Japanese phrases. All are now English. The i18n dictionary
  and the two intentional native-language strings in `lang.sh` / `help.sh` are
  untouched.

## [0.6.1] — 2026-06-20

Six weeks of vertical-orchestration dogfooding shook out a collection of quiet
correctness bugs — in `conduct`, `burn`, `proc`, `app`, `codex`, and `state-version`
— and added two new test layers (PowerShell adapter-drift guard and a `conduct
--help` honesty test). No new command surface, no breaking changes. If v0.6.0 grew
the muscle, v0.6.1 makes sure it doesn't misfire.

### Fixed

- **`conduct --leg` name validation** — a leg slug with path characters could escape
  its output directory. `--leg` names are now validated before dispatch so a
  crafted name can't write outside the designated out-dir.
- **`proc` interactive-vs-background guard** — the env block was confusing the
  detection heuristic that classifies a process as interactive or a background
  daemon, producing wrong soft-vs-hard warn decisions. The guard is now reliable.
- **`_app_shell_squote`** — the shell-quoting helper produced broken shell for any
  value containing a single quote, making `.app` launchers malfunction for paths or
  prompts with apostrophes. Fixed.
- **`codex` cwd trailing-slash matching** — a session's recorded `cwd` is now
  matched trailing-slash-insensitively, so sessions stored with and without a
  trailing slash both appear in the board's Continue list.
- **`state-version` migration-failure message** — the failure message was garbled
  (double-substitution artefact). The message is now readable, and a new bats test
  pins the v1→v2 migration path.
- **`$CLIKAE_LIMIT_PATTERN` in headless output-dry path** — the environment
  override for the limit-detection pattern was not honoured when scanning headless
  output; clikae now respects it in that path, consistent with the interactive
  transcript path.

### Added

- **PowerShell adapter-drift test** — a new compat bats test asserts that the
  PowerShell adapter table stays in sync with the bash adapter set, catching
  future bash-only additions before they silently regress the Windows community port.
- **`conduct --help` honesty test** — bats now asserts that `clikae conduct --help`
  discloses its read-only, non-judging limits, keeping the help text honest as the
  command evolves.

### Docs

- **Orchestration playbook** (`docs/orchestration.md`) — the field guide for
  driving clikae headless / as an agent fleet, including the three dispatch shapes
  (`burn` / `conduct` / conductor legs), hard-won anti-patterns, and a recipe section.
  Added in this cycle and expanded with cost-aware model-tiering guidance and
  independent-verification principles in v0.6.1.
- **Demo board** (`clikae demo`) — richer, ToS-safe multi-engine demo board with
  fuel gauge; sandbox path removed from the tour; `help` notes the agy one-shot
  dispatch pattern.
- **Proposals archived** — issues #22 and #24 marked SHIPPED in v0.6.0 in
  `docs/proposals/`.
- **`homebrew/RELEASING.md`** — exact publish commands for the next release so the
  step-by-step is in-repo rather than implicit.

## [0.6.0] — 2026-06-14

The vertical-orchestration step: clikae grows the muscle for directing a fleet of
AI CLIs that each burn their own subscription — and a sibling Claude Code skill
(`conductor`) stands on it. All additive; the existing command surface is unchanged.

### Added

- **`clikae conduct` (BETA)** — fan ONE prompt across N accounts **in parallel**,
  each running headless **read-only** on its own tank (its own quota), then collect
  every leg's full output and print a captured/dry table. clikae does **not** judge —
  it hands you N result files and an honest table; you (or a session model acting as
  conductor) pick the winner. Read-only by design so legs can't clobber a shared
  tree. New optional adapter hook `adapter_audit_flags` (claude, codex).
- **`clikae git-id <engine> <tank> --name … --email …`** (issue #22) — give a tank
  an optional git commit identity. When set, `clikae env` also exports
  `GIT_AUTHOR_*` / `GIT_COMMITTER_*`, so commits made in that shell are stamped with
  the identity you intended — not the engine's account email (the HANDOFF §13
  mis-attribution incident). git env vars beat `git config`; honest limits (loses to
  an explicit `git -c user.email=…`, per-shell only, future commits only) are
  documented in the command's help and `docs/grammar.md`.
- **`clikae burn --prompt-file <f>` / `--prompt <str>` / `--add-dir <dir>`** (issue
  #24) — the easy way to burn a write-task: clikae fills each engine's headless-write
  flags from a new optional adapter hook `adapter_burn_flags` (claude, codex), so you
  no longer hand-assemble `-p … --dangerously-skip-permissions` / `exec -s
  workspace-write …`. A cross-engine `--to` reroute now regenerates the flags for the
  new engine (previously it shipped the wrong engine's flags). The explicit `-- <cmd…>`
  form keeps working unchanged.

### Fixed

- The new `adapter_burn_flags` / `adapter_audit_flags` recipes are **NUL-separated**,
  not newline-separated, so a multi-line prompt survives as a single argv item (a
  newline framing shattered a prompt that itself contained newlines).
- `clikae conduct` classifies a leg by its captured output, not the result file's
  size, so an empty (failed) leg is reported as a real failure rather than a false
  "captured" (an empty `printf` still writes a trailing newline).

## [0.5.14] — 2026-06-07

### Changed

- Final polish so the released tarball matches `main` — no behaviour change. Dropped a
  phantom `$CLIKAE_HOME/adapters` TODO comment (never implemented; adapter overrides
  live in the repo's `lib/adapters/`), and marked `docs/HANDOFF-world-class-gaps.md`
  historical now that its punch-list is cleared.

## [0.5.13] — 2026-06-07

### Added

- **`burn --fresh`** — delete the artifact before running, for a clean slate.
- **`burn --timeout` perl fallback** — when neither `timeout` nor `gtimeout` (coreutils)
  is on PATH, the run is bounded with a `perl` alarm (stock macOS ships neither). Only
  when all three are missing does the run go unbounded (still warned).
- **`burn` summary line** — on finish, one line: tank used, reroute count, elapsed time,
  artifact size.

### Fixed

- **`burn` no longer counts a STALE artifact as success.** A leftover artifact from a
  previous run could make a failed task look like it succeeded. Success is now judged by
  the artifact appearing *or its timestamp changing*, via the existing GNU-stat-first
  `_clikae_mtime` helper (portable across macOS/Linux; whole-second resolution — `--fresh`
  sidesteps a same-second overwrite).
- **Accurate agy docs & strings.** Comments and i18n that said agy "hardcodes ~/.gemini
  and ignores env" were imprecise: agy's *state* follows `$HOME`, but its *login* is one
  global Keychain entry — so different accounts can't be routed per-shell, which is why
  switching is global. Also removed a dead, incorrect "agy can't be renamed" string (it
  can — rename carries the per-tank Keychain login).
- **`remove agy <active-tank>`** now names a concrete other tank to switch to.

## [0.5.12] — 2026-06-05

### Added

- **State schema versioning.** Everything under `$CLIKAE_HOME/` now carries a
  `version` marker, so a future change to an on-disk format is safe: clikae reads it
  on startup and runs a forward migration if an older clikae last wrote your state
  (and warns, rather than downgrading, if a *newer* one did). Deliberately minimal —
  one version file + one migration runner, no framework. It's stamped when state is
  created, so read commands stay read-only; a pre-existing install with no marker is
  treated as the original layout and migrates cleanly when needed. (Invisible in
  normal use — this is groundwork for safe format changes later.)

## [0.5.11] — 2026-06-05

### Fixed

- **`clikae watch` now starts reliably.** Its live-tail path validated the
  handoff target through a helper that wasn't defined; `clikae watch <engine>` on a
  real session could exit before tailing. The target is now validated up front
  (fast-fail on a bad `--to`), and the path is covered by tests.
- **`clikae to codex <tank>` describes what it actually does.** codex can't resume a
  carried session, so the carry starts fresh — the message now says "FRESH (not a
  resume)" instead of announcing a resume.
- **Auto-reroute won't dead-end on agy.** `next_tank` no longer offers an
  `antigravity/<tank>` entry as a carry target (agy is global / single-account, so it
  can't take a `/tank` handoff). Reach agy explicitly when you want it.
- **`clikae tanks` shows an agy tank's real account.** The ACCOUNT column now reads
  agy's signed-in email (the same source the board uses, so the two agree) instead of
  a `(active)` state marker.

### Changed / docs

- New **[docs/EXPECTATIONS.md](docs/EXPECTATIONS.md)** — an "is this a bug?" guide to
  deliberate-but-surprising behaviours (the fuel dot, codex's UTC reset time, agy's
  global switch, account-level limits, …).
- Doc corrections: the board's language key is **`l`** (not `h`); `lang` opens a
  picker (not a blind cycle); `handoff` auto-detects a local summariser
  (`CLIKAE_HANDOFF_AUTOLOCAL=0` to disable); `auto` is claude-launched-only; `watch`'s
  next-tank is the same-engine-first ring; rc-backup timestamp format; `$LC_ALL`/`$LANG`
  resolution order; `env` listed in the grammar.

## [0.5.10] — 2026-06-05

### Fixed

- **`burn` no longer reroutes a headless job onto the tank you're actively using.**
  The original "燒爆" footgun: `clikae burn claude <X>` where the reserve walks onto
  `claude/C` — the tank an interactive session is live on — silently spends *that*
  conversation's quota. (A 2026-06-05 log had declared this fixed after testing
  **codex only**; the claude path was never covered and was confirmed still-live.)
  Now `burn`'s auto-reroute **skips a tank an interactive session holds** (detected
  via `live_dir_users`); pass `--allow-active` to override.
- **`burn` reserve is account-aware.** It skips a candidate tank that shares an
  account with one it already dried — same login = same quota = already dry, so the
  hop was wasted (e.g. `L`→`MFC` on one login).

### Changed

- The `agy` burn-refusal message reads truer ("agy is *already* global/single-account
  — there's no per-tank headless burn to do; just use it directly"), and `clikae
  tanks` now footnotes that agy is interactive-switch-only / not burnable.

## [0.5.9] — 2026-06-05

### Added

- **"✨ Update available" notice on the board.** When a newer clikae is out,
  `clikae` shows a codex-style prompt before the tank board — a ✨ banner + a 3-way
  choice: **update now** (runs the right command for your install — `brew upgrade
  clikae` or the curl installer, auto-detected; just *shown* if it can't tell, never
  a guess-run), **skip**, or **skip until next version**. Quiet and opt-out: the
  check is throttled to once a day, cached, offline-safe, and fully disabled by
  `CLIKAE_NO_UPDATE_CHECK=1`. Localised (en-US / ja-JP / zh-TW).
- **Carry a session onto another tank even when it still has fuel.** The Continue
  submenu gains a third choice — *carry this session to another tank* — so you can
  deliberately move a live conversation to another account, not only when the tank
  runs dry. (Shown for engines that can resume a carried session, when there's
  another tank to carry to.)
- **A capture-time tag on snapshot reset times.** codex (and agy) report a reset
  time clikae can only catch headless — codex in **UTC**, for whichever limit window
  it hit; agy as a relative "Resets in 3h" frozen at its last run. The board now
  appends "· seen HH:MM" (the local time we observed it), so a stale or off-timezone
  reset reads honestly as a snapshot rather than a live countdown. claude is exempt
  — its dry is re-read live each render and is already absolute + timezoned.

### Changed

- **`clikae burn --timeout` discloses its dependency.** It needs `timeout` /
  `gtimeout` (GNU coreutils); stock macOS has neither, so without it the run is
  **not** bounded — the flag help now says exactly that, and the warning is clearer.
  No silent promise of a bound the platform can't keep.

### Fixed

- Pinned a regression test for `clikae to`'s refusal when a shell is attached to
  more than one engine (it must ask, never guess which session to carry).

## [0.5.8] — 2026-06-05

### Added

- **Carry on from a dry tank, right from the board.** Pressing Enter on a
  Continue row whose tank is out of fuel no longer dead-ends on "resume" / "open
  fresh" — both of which only put you back on the exhausted quota. When the tank
  is dry, the submenu now leads with **carry this session onto the next fuelled
  tank**: a real `relay` (same engine resumes the conversation) or a written
  brief (cross engine), with "resume anyway" kept as an escape hatch.
- **codex tanks can light a red dot now.** codex's usage limit is exec-stdout-
  only — it never lands in a transcript, so the passive board had nothing to
  read and codex always showed `○` (no reading). `clikae burn` already detected
  it (and the vendor's verbatim reset phrase); it now **persists** that to a
  small dry-until store, so a later `clikae` shows codex red with its reset time.
  Self-clearing: a successful run clears it, and a stale marker ages out (6h)
  rather than pinning a tank red forever.

### Changed

- **The carry-onward selector is now a ring — account- and fuel-aware.** When a
  tank runs dry, `clikae to`, the BETA supervised auto-carry, and the board all
  pick the next tank by: **circling** the whole burn order (wrapping past the end
  — a tank *earlier* in your order is still a reserve, where before the list fell
  down once and stranded everything above you); preferring a fuelled **same-engine**
  tank (a real resume) over a cross-engine cold brief; and skipping any tank whose
  **account** is already exhausted. A usage limit hits the whole account, so a
  sibling tank sharing a dry login (same email) now reads dry too — no more
  pointless hop onto the same empty quota. When the *whole* ring is dry it says
  so, instead of hopping onto a tank that has no fuel either.
- The dry-tank board submenu's "open fresh" wording is clearer: it opens the
  **same** tank fresh — it never switched tanks (the old "換到這個油箱" read like a
  tank-picker). New dry-tank carry strings localised (en-US / ja-JP / zh-TW).

## [0.5.7] — 2026-06-04

### Added

- **`clikae app --board`** — a `.app` launcher for the **board** (your menu of
  recent sessions + tanks), not a single tank: one double-click button for the
  whole on-ramp. Works for Terminal, iTerm2, and Ghostty.
- **A helpful "engine isn't installed" message.** Switching to a tank whose CLI
  binary isn't on your PATH now reports it clearly — with a per-engine install
  hint (e.g. `npm install -g @anthropic-ai/claude-code`) — instead of a bare
  `exec: …: not found`. clikae switches accounts; it doesn't install the CLI.
  (New optional adapter hook `adapter_install_hint`.)

### Changed

- **The board shows only burnable fuel tanks** (claude / codex / agy). Tool-CLI
  tanks (gh, npm, aws, …) aren't AI sessions — "launching" one only printed a
  usage screen — so they now live in `clikae tanks` (the full inventory), not on
  the board. The adapters are unchanged; only their presence on the board is.
- **Ghostty `.app` launchers pass their command through a trusted config file**
  (`--config-file=`) instead of `-e`. Ghostty pops an "Allow Ghostty to execute…?"
  dialog for an externally-injected `-e` command (so a `-e` launcher looked like an
  empty shell until you clicked Allow); a config file is trusted, so the window
  just opens. The config is located at runtime via `path to me` (so the .app keeps
  working if moved), and the bundle is re-signed after the config is written so
  Apple Silicon doesn't block it.

### Fixed

- **The board no longer renders blank when there are 0 fuel tanks** (e.g. only
  tool-CLI tanks): a `grep -c .` returning exit 1 on a zero count aborted the whole
  render under `set -eo pipefail`.

## [0.5.6] — 2026-06-04

### Fixed

- **`rename` / `migrate` / `remove` no longer abort when the in-use process scan
  can't run.** v0.5.5's new cross-shell guard (`lib/core/proc.sh`) leaked
  `ps eww`'s exit code, so under `set -eo pipefail` a non-zero `ps` — on a
  locked-down host, a CI runner, or a restricted sandbox — took the whole command
  down instead of degrading to "couldn't scan, proceed". The scan is now truly
  best-effort, as HANDOFF §11 intended (no reading ⇒ no users found, never a hard
  error). Regression test added (a deliberately failing `ps` must not abort rename).

## [0.5.5] — 2026-06-04

### Added

- **agy is now real multi-account.** agy keeps its Google login in ONE machine-wide
  macOS Keychain item, so swapping the `~/.gemini` symlink alone left every agy tank
  riding the SAME account. `clikae agy <tank>` now carries the login WITH the tank:
  it stashes the outgoing tank's login into a clikae-namespaced Keychain slot and
  restores the incoming tank's (Keychain↔Keychain — the token never lands on disk);
  a fresh tank logs in clean instead of inheriting the previous account. `rename`
  carries the slot, `remove` forgets it. macOS-only; gated behind the existing agy
  multi-account consent, whose warning now discloses the Keychain carry.
- **`clikae burn <engine> <tank> --artifact <path> -- <cmd…>`** — a headless guarded
  task runner. Runs a task on a tank, verifies it by the **artifact** it must produce
  (never the exit code — `codex exec` exits 0 even when it hit its limit and wrote
  nothing), and re-fires the same task on the next reserve tank if this one runs dry.
  The headless sibling of `to`/`watch`; batch/parallelism stays the orchestrator's job.
- **codex sessions now appear in the board's "Continue" list** (cross-engine
  continuity). The codex adapter gained `adapter_transcript_path` / `recent_sids` /
  `session_title` / `resume_args`, matching on the rollout's recorded `cwd` (codex
  doesn't slug `$PWD` like claude). Resume via `codex resume <uuid>`.
- **codex usage-limit detection from plain `exec` output** — `limit_line_is_real`
  now matches codex's plain-text limit line (not just `--json`), with reset-time
  parsing (`limit_codex_reset`) and a captured-output check (`limit_output_dry`) that
  `burn` uses to tell a dry tank from a task failure.
- **`clikae tanks` marks the active agy tank** with `(active)` — the one fact that's
  knowable for sure (agy doesn't persist its account email to disk, so we never fake one).

### Fixed

- **`clikae status` no longer crashes** when an adapter-less tank (agy) exists. The
  no-args view aborted silently (empty output, exit 1) because `load_adapter` `exit`s
  rather than returns on a missing adapter, and the `||` guard was dead code under
  `set -eo pipefail`. It now gates on the adapter file and renders agy as a new
  `global` state showing its machine-wide `~/.gemini` symlink target.
- **rename / migrate / remove now refuse to move a tank a live session in ANOTHER
  terminal is still using** (the phantom-tank bug): the old guard saw only the shell
  running clikae. New `lib/core/proc.sh` scans all same-uid processes — an interactive
  session hard-fails (not `--force`-able); only background daemon/spare workers warn.
- **`clikae env agy`** (and app/alias/run/relay/migrate when handed agy) now give a
  helpful "agy is global — use `clikae agy <tank>`" message instead of the misleading
  "No built-in adapter for 'agy'".

### Changed

- **`clikae watch codex` is now honest**: codex records its usage limit only in the
  exec output stream, never the rollout transcript, so a transcript tail can't catch
  it. `watch codex` says so and points at dispatch-time detection (`clikae burn`),
  rather than tailing a file that will never carry the marker.

## [0.5.4] — 2026-06-03

### Changed

- **The board's status dot is now a fuel gauge, not a "you are here".** One axis,
  one reading per tank, like a traffic light: 🔴 dry (over limit, verbatim reset
  phrase) · 🟢 ready · ○ no reading (engines clikae can't read from disk, e.g.
  codex — honestly blank, never a guessed green). The old green "active" dot was
  confusing — it meant a global symlink for agy but a per-shell env var for claude,
  and "current account per engine" is switcher-thinking clikae isn't. "Which tank
  am I on" now lives only with the cursor, the burn-order position, and the `← here`
  text label (the `active` flag still drives the launch target). See
  `docs/DESIGN-board-fuel-dots.md`. Dot legend added to the `?` overlay (i18n).

### Added

- **Weekly-usage caution dot — 🟡 (BETA).** When `clikae watch` sees Claude's own
  "used N% of your weekly limit" notice stream past, it captures the phrase
  **verbatim** (never computed — disk has no weekly denominator) and the board
  shows that tank a yellow ●. BETA because it's not yet confirmed the notice
  reaches a stream clikae can tail; until one is observed, yellow simply never
  lights (safe default). `limit_weekly_marker` / `limit_engine_detectable` added.

## [0.5.3] — 2026-06-03

### Added

- **Your tanks are a single burn order, and the board IS that order.** The home
  board is now one flat list (no engine grouping; engine shown as an inline tag),
  in the order clikae falls through when a tank runs dry. Arrange it in place with
  **`[` / `]`** (move up/down). `clikae <name>` switches to a tank by name alone
  (e.g. `clikae cver`) — a tank's name is its identity. Bare **`clikae to`** carries
  your session to the next tank in that order.
- **Supervised launch — auto-carry on a dry tank (BETA · claude · feedback welcome).**
  Start claude *through* clikae and, when the session hits its limit, clikae carries
  you onward to the next tank in your burn order — in the **same terminal** (one
  redraw), conversation continuing. How much it does on its own is yours to choose:
  **`clikae auto ask|safe|full`** (or the board's `A` key) — safe default asks first;
  `safe` auto-resumes same-engine and asks before crossing engines; `full` just keeps
  going. Nothing runs in the background unless you launched it through clikae (no
  daemon — deliberate). Honest limits: one hop per run; interactive **codex** isn't
  auto-detectable yet (claude-only); the truly seamless in-place feel depends on the
  engine — please report how it behaves. `clikae status` shows what it carried.
- **The "what clikae did" log.** Carries (`clikae to`, the board's `r`, and the
  supervised auto-switch) are recorded; `clikae status` shows a **recent carries**
  tail so you can see what moved where, even while away.

### Changed

- **Your tanks ARE the fuel reserve — the `pool` concept is gone.** The separate,
  CLI-only "fuel pool" was undiscoverable (you couldn't set it from the board) and
  redundant with the tanks clikae already knows. Removed entirely (`clikae pool`,
  `lib/core/pool.sh`, the board's fuel-pool line). Falling through to another tank
  now works with zero setup:
  - **`clikae to`** (no target) carries your session to the **next tank of the
    engine you're on** — a real resume, skipping any tank that's itself over quota.
    Name a tank to pick it; name an engine to cross (a cold-start brief).
  - **`clikae watch`** falls through to the same next-tank logic; cross-engine
    still takes an explicit `--to`.
  If you ever want a custom order, that belongs on the board (reorder the tanks) —
  not a hidden file. New core helper `next_tank`.

### Added

- **Interface localisation — en-US / ja-JP / zh-TW.** The dashboard, prompts, and
  key hints now speak your language. A bash-3.2-safe string table
  (`lib/core/i18n.sh`) loads one set of `T_*` globals per render — no per-keypress
  cost. Resolution: `$CLIKAE_LANG` env > saved choice (`clikae lang <code>`) >
  `$LANG`/`$LC_ALL` > en-US. Set it with **`clikae lang en-US|ja-JP|zh-TW`** or flip
  it **live with the `h` key** in the board. The katakana wordmark `ｷﾘｶｴ` stays as
  the brand mark in every language. This also _cleanly separates_ the previously
  mixed-in strings (續上次 / 無痕 / 接回) so each language renders consistently.
- **A more capable interactive board.** New keys: **Tab / Shift-Tab** to move,
  **`g` / `G`** to jump to top / bottom, **`1`-`9`** to jump to a row, **`/`** to
  live-filter tanks, and **`?`** for a full, localised key legend (so every action
  stays discoverable without crowding the footer).
- **`a` now renames the whole TANK**, not just its alias — it runs `clikae rename`,
  carrying the managed alias and saved login across. Alias-only edits stay at
  `clikae alias` on the CLI. (agy tanks are a global `~/.gemini` target and can't
  be renamed.)
- **Continue rows offer a choice.** Pressing Enter on a 續上次 / continue row now
  opens a tiny menu: **resume that exact session**, or **switch to its tank with a
  fresh session** (換油箱開新局).

### Fixed

- **Long recaps wrap with a hanging indent.** A continue row's recap no longer
  spills back to column 0 when it wraps — continuation lines align under the
  recap's first word.
- **CJK labels line up.** The board's left-hand labels (launch / fuel pool / more)
  now pad by display width, so Japanese / Chinese labels align like the English
  ones instead of drifting.
- **CJK recaps wrap correctly.** A Chinese/Japanese recap no longer overflows and
  hard-wraps to column 0 — the wrapper now budgets by DISPLAY width (full-width
  glyphs = 2 cols), not character count. Long/garbled titles are truncated.
- **Polished from dogfeeding:** language is the **`l`** key and opens a select menu
  (not a blind cycle); a **"Tanks"** header sits above the tank list; **agy** shows
  its short name `[agy]` and its signed-in Google account on hover (read from its
  own log), sits under "Also available" instead of floating, and its tanks rename
  too; the new-tank picker groups **AI engines vs tool CLIs**; the shell alias is
  retired from the board (the tank name is the identity); fresh logo.

### Hardened

- **Over-quota detection is future-proofed.** The structural transcript greps that
  spot a genuine Claude session/usage limit now tolerate optional whitespace after
  JSON colons, so a future Claude Code that pretty-prints its `.jsonl` can't
  silently break the `!` badge. Timestamps are compared by bare ISO value. Locked
  in with regression tests for the exact session-limit shape (middot reset phrase
  + `apiErrorStatus:429`) and a spaced-JSON variant. (Detection itself already
  handled the new "session limit" wording — confirmed against a real burn.)

## [0.5.2] — 2026-06-02

### Added

- **The interactive board leads with "continue".** When this directory has
  sessions you can resume, `clikae` now opens with a **續上次 / continue list** at
  the top — your most recent sessions across all tanks (newest first), each titled
  by Claude's own ai-title and marked with a status dot consistent with the tanks:
  ● if that session is on the account you're using right now, ○ if it's on
  another — so you can see at a glance which ones mean switching accounts. Press Enter to reopen the selected one
  (`clikae <engine> <tank> -- --resume <id>` under the hood); the selected row
  also expands to a one-line **recap** — _"where you left off + next step"_ — read
  free from Claude's own session summary (`away_summary`, the `※ recap:` it shows
  at the bottom of a session), so you know what a session was doing before you
  jump back in. Sessions without a recap fall back to showing their age + an
  Enter-to-resume hint, so the hover detail is always there. It only appears for engines that can resume by id (new
  `adapter_resume_args` hook), so the affordance never lies, and it's absent in a
  brand-new directory. Listing stays fast — sessions are ranked by mtime and only
  the few rows shown read their title/recap (`adapter_recent_sids` /
  `adapter_session_title` / `adapter_session_recap`). The board also
  pins the logo top-right on wide terminals, no longer flickers on each keypress
  (the whole frame is composed once and written in a single pass — no per-line
  repaint, no full-screen clear), and adds an `x` key to open the selected tank
  **無痕** — with throwaway memory (`--ephemeral`), a clean amnesiac session that
  leaves nothing behind. Tank rows now collapse to a status dot + name, expanding
  to the account, alias, and reset time only for the selected row (a hover
  detail), so a long list reads at a glance. Board glyphs are ASCII-safe (no
  emoji or rare codepoints a terminal font might drop).
- **On-device handoff briefs — local-first, private, free.** When you carry a
  session across engines (`clikae to <other-engine>`, `clikae handoff`), clikae
  now auto-detects a LOCAL model already on your machine — `apfel` (Apple's
  on-device Foundation model, macOS 26), `ollama`, or `llm` — and writes the
  brief **on-device**. Nothing is bundled or installed by clikae; your session
  content (which may include source or secrets) never leaves the machine to make
  the handoff, it costs nothing, and it works offline. The choice is announced
  and fully overridable (`$CLIKAE_HANDOFF_SUMMARIZER`), can be turned off with
  `CLIKAE_HANDOFF_AUTOLOCAL=0`, and always falls back to the dependency-free raw
  extract. The transcript is first cleaned into a compact digest (capped via
  `CLIKAE_HANDOFF_CONTEXT_CHARS`, default 8000 chars) so it fits a small
  on-device model's context — which also yields more accurate, less hallucinated
  briefs than feeding a raw JSONL tail.

### Changed

- **Session titles now use Claude's own AI-generated name.** Claude Code writes
  a human-readable title into each transcript (`{"type":"ai-title",…}`, e.g.
  _"Lucky number confirmation"_) — the same name it shows in its session list.
  `clikae relay`'s preview card and session picker now prefer that title over
  the raw opening prompt, for free (no local model). Sessions without one — and
  other engines — fall back to the opening user message as before.

## [0.5.1] — 2026-06-01

### Added

- **A responsive welcome screen with the clikae logo.** First-run `clikae` (no
  tanks yet) now shows the logo (`assets/logo.txt`, bright-cyan): on a wide
  terminal the copy sits **beside** it (logo left, text right, placed with
  cursor-column moves); on a narrow terminal or a pipe it **stacks** — reflowing
  to the terminal width like a responsive page. Width is read with `stty size`
  (not `tput cols`, which returns the terminfo default inside a command
  substitution, so it can't see a narrow window). The everyday tank board is
  unchanged (no logo — it would bury your tanks). `install.sh` and the Homebrew
  formula now ship the `assets/` directory.

## [0.5.0] — 2026-06-01

### Fixed

- **`clikae to` / `relay` / `handoff` now auto-detect the source after a bare
  switch.** The switch, the aliases, and the `.app` all run the engine with a
  prefix assignment that never reaches the parent shell, so after a session
  `$CLAUDE_CONFIG_DIR` was unset and `clikae to <other>` couldn't tell which tank
  you were on (surfaced by the real-claude dogfood). Source detection now falls
  back, when no env var is set, to **the tank with this directory's most recent
  transcript** — "the session I was just in here" — so the headline
  switch → work → `to` flow works from one shell. Stateless (no breadcrumb);
  works regardless of how the session was launched.
- **Dogfood cleanups (v0.5.0 real-claude pass):** the home board's launch hint
  teaches the bare switch instead of `run`; the relay preview shows a real title
  for sessions whose opening message is a plain `"content"` string (current
  Claude Code stored it as a string, not a `text` array, so it read
  "(no preview)"); and the agy takeover is described honestly as one `[y/N]`
  confirmation (not "multi-confirm").

### Changed

- **clikae is a macOS / Linux tool; Windows support is now community/unsupported.**
  It's bash, and that's the pitch ("every line is auditable"). The PowerShell
  module in `powershell/` is no longer part of the maintained grammar (it lacks
  the v0.5 fuel-tank grammar) — kept as a community-contributed port, with its
  Windows CI job made informational (`continue-on-error`, never gates a release).
  Windows contributors are welcome to carry it forward. README/`powershell/README`
  updated; the maintained suite is bats (now with every assertion enforced —
  `set -e` + `|| false` on `[[ … ]]`, see `tests/README.md`).

### Added

- **`clikae env <engine> <tank>`** — print `export VAR="value"` lines to `eval`,
  the explicit way to put the current shell *on* a tank so the engine's own
  command and `clikae status` / `to` see it: `eval "$(clikae env claude work)"`.
  Flag-strategy engines (no config env var) say there's nothing to export.

- **`clikae <engine> <tank> --ephemeral` — run with throwaway memory.** For the
  leave-no-trace run: the engine's long-term memory is pointed at a `mktemp -d`
  throwaway that's discarded on exit, while the tank's real memory is stashed
  aside and restored untouched. Login and transcripts are normal — only the
  memory store is throwaway. Runs the engine as a child (not `exec`) so cleanup
  fires; a crashed run self-heals on the next `--ephemeral`. Engine-gated by a new
  optional adapter hook `adapter_memory_dir` (claude defines it; others reject it
  cleanly). Honest scope: clikae guarantees the *memory dir* is throwaway, not
  that the engine "remembers nothing anywhere" (caches/history/Keychain are out of
  reach). First of the §10 "memory control plane" (docs/grammar.md §10.4); bats in
  `tests/bats/ephemeral.bats`.

- **The fuel-tank grammar — clikae is now the verb.** The name is 切り替え
  (*switching*), so the headline action carries no verb of its own: **`clikae
  <engine> <tank>`** switches an engine to one of your tanks and runs it (`run` is
  a hidden alias). One **`clikae to <target>`** carries your current session
  onward — same engine resumes the conversation, a different engine gets a written
  brief — replacing the separate `relay`/`handoff` verbs (kept as hidden aliases),
  with the mechanism announced at runtime. Listing is **`clikae tanks`** (`list`
  stays as an alias). The vocabulary is **engine** (a.k.a. CLI) + **tank** (a.k.a.
  profile) + **fuel/dry** throughout help, the dashboard, `status`/`doctor`/`info`
  headers, and all messages; the on-disk `profiles/` layout and core function
  names are unchanged. The full design lives in `docs/grammar.md` (the SSOT), with
  §10 recording the open "memory control plane" frontier. A session-aware guard
  only prompts carry-vs-fresh when the current tank is over quota. bats 200/200.

- **Antigravity (agy) folds into the same verbs — no special subcommand tree.**
  agy hardcodes `~/.gemini` and ignores env vars, so clikae can't switch it
  per-shell. It now uses the **same verbs as every engine**, via an opt-in,
  reversible symlink-swap power mode: `clikae init agy <tank>` (the first one
  warns and asks before taking `~/.gemini` over, backs it up, migrates your login
  into a `default` tank), `clikae agy <tank>` (repoint the symlink — refusing
  while `agy` is live — and run, with a global-switch notice), `clikae remove agy
  <tank>` (removing the last tank offers to restore a normal `~/.gemini`), and
  `clikae agy --release` (restore a single-account `~/.gemini`, keep the tanks).
  The canonical engine name is **`agy`** (`antigravity` is a hidden long alias).
  Replaces the earlier `antigravity enable/add/use/disable` subcommand tree
  (which would have collided with the bare switch). Also fixed a latent crash
  where `clikae list`/`tanks` died on agy tanks (a missing-adapter `exit 1`
  propagating through `set -e`). bats rewritten (10 tests) against an isolated
  sandbox so no real `~/.gemini` is touched.

- **`clikae demo` — a guided tour in a throwaway sandbox.** A non-interactive,
  ~30-second walkthrough that runs entirely under a temp `CLIKAE_HOME`: it shows
  two fully isolated accounts of one CLI, the live tank board (one marked active
  in the shell), a fuel pool, and the relay payoff — then deletes the sandbox.
  Touches nothing real (not your `~/.clikae`, logins, or shell rc); the accounts
  are simulated (fake `.claude.json` labels), so it needs no installed CLI and no
  second account. The first thing you can safely hand a newcomer. Covered by bats
  (the tour runs, the real home is untouched, the sandbox is cleaned up).
- **Bare `clikae` now opens a home dashboard — your "tank board".** Typing
  `clikae` with no arguments used to print the help wall; it now opens a
  glanceable dashboard, the screen clikae wants to be the first thing you type:
  every profile (tank) grouped by CLI, the one **active in this shell** marked,
  the logged-in account and the **real managed alias name** beside each, an
  **"Also available"** section of relay-capable CLIs/targets you can open without
  a tank yet (e.g. `codex`, `agy` — chosen by who can take a handoff, so tools
  like `gh`/`npm` aren't listed), and the fuel-pool fall-through order.
  - On a **real terminal it's an interactive launcher**: ↑/↓ (or j/k) to move,
    Enter to open the selected tank, `r` to relay this shell's live session into
    it (from whichever profile is active here), `n` to create a new tank
    (arrow-key CLI picker, then name it), `a` to rename a tank's shell alias,
    `d` to delete a tank (confirms first), `q`/Esc to quit (leaving the board on
    screen). The mutating keys (`n`/`a`/`d`) run their action and **return to the
    menu** rather than dropping you back to the shell, so you can do several in a
    row; only the launching keys (Enter / `r`) leave. It uses the alternate
    screen buffer so your
    scrollback is untouched, and falls back to the **plain-text board** whenever
    output isn't a TTY (a pipe, a script, the GUI) — set `CLIKAE_NO_INTERACTIVE`
    to force that.
  - With no profiles yet it shows a **welcome** that scans the machine and names
    the supported CLIs you actually have, plus the exact first command. The full
    command reference moved one keystroke away to `clikae help`.
  New **`clikae doctor`** is a read-only health check (which CLIs are installed
  and logged in, profile counts, `CLIKAE_HOME` / shell-rc / PATH, and targeted
  next steps); a shared read-only scanner (`lib/core/scan.sh`) backs both.
  Covered by bats (incl. guards that the last adapter row isn't dropped, the
  agent/target filter, and that colour escapes don't leak as literal text).
- **Machine-readable `--json` across the read commands (for the v1.0 GUI).**
  `clikae list --json`, `status --json`, `pool --json`, and `info --json` now
  emit structured output for the planned menu-bar app and for scripting. The
  three inventory/state views form a data trio: `list` (every profile across
  CLIs: `{cli, profile, account, path}`), `status` (active profile per CLI in
  this shell, with a `state` enum: active | default | external | flag |
  noadapter), and `pool` (the fall-through order: `{position, target, cli,
  profile}`). Each command builds **one canonical record** rendered by either
  the human table or the JSON array, so the two can't drift; JSON is escaped by a
  shared `lib/core/json.sh` (no jq). The PowerShell module gains the matching
  surface — a new **`Get-ClikaeStatus`** (the `clikae status` equivalent) plus a
  `-Json` switch on it and on `Get-ClikaeProfile`, with array output that holds
  up on Windows PowerShell 5.1. (`info`'s human view also stopped mangling the
  adapter list — `paste`'s alternating-delimiter quirk.)
- **`clikae handoff <cli> [<profile>]` — a portable session handoff brief.** The
  real pain when a tank runs dry mid-task isn't the lost conversation, it's that
  the *next* tank starts blind. `handoff` reads the current directory's most
  recent session (read-only) and writes a short, vendor-neutral brief — what's
  being worked on, what's done, what's next — that any other profile / model /
  vendor can pick up. With `$CLIKAE_HANDOFF_SUMMARIZER` (or `--summarizer <cmd>`)
  set to a **local or cheap model**, the session tail is piped to it and its
  output is the brief, so it costs nothing on the tank that just ran dry; with no
  summarizer you get a dependency-free raw extract (metadata + recent prompts),
  clearly labelled as raw. New optional adapter hook `adapter_transcript_path`
  (claude reads `<dir>/projects/<pwd-slug>/<id>.jsonl`; the slug rule now lives
  there and `adapter_relay` reuses it). Covered by bats. Pure bash/grep/sed — no
  jq, python, or network.
- **`clikae handoff … --to <target>` — switch model or vendor in one command.**
  After writing the brief, hand it straight to the next tank: it starts that
  target seeded with the brief as its opening prompt (exec, like `run`/`relay`).
  Targets are either another account of a *switchable* CLI — `--to codex/work`,
  `--to claude/b` — via a new optional adapter hook `adapter_start_with_prompt`
  (claude + codex), or a **handoff target**: a single-account vendor you can hand
  off to but can't profile-switch. First one: **`antigravity`** (`--to antigravity`
  starts Google's `agy -i` with the brief). Antigravity's CLI hardcodes `~/.gemini`
  with no config-dir override (verified on a real install), so it can't be a
  switchable adapter — handoff targets live in `lib/targets/` and stay out of the
  profile/adapter machinery (and the cross-language PS parity).
- **`clikae watch` + `clikae pool` — ambient relay (notice a dry tank, switch).**
  `watch <cli> [<profile>]` tails the current session's transcript and, when it
  looks like the tank ran dry, hands off to the next tank — **offering first** by
  default, or **automatically after a one-time consent** with `--auto` (it asks
  once, remembers in `$CLIKAE_HOME/auto-relay-consent`, then auto-switches and
  tells you). Where it goes next comes from the **fuel pool**: an ordered,
  user-owned list managed by `clikae pool add|remove|list` (or `--to <target>`
  to override). The handoff reuses `clikae handoff`, so a switchable target keeps
  going on its own quota. **Honesty caveat, also in the code and `--help`:** an
  interactive CLI hitting its limit gives no exit code and fires no hook, so the
  only signal is what the limit writes into the transcript — and the exact marker
  is *not yet confirmed against a real limit event*. The match pattern is a
  best guess, fully overridable (`--pattern` / `$CLIKAE_LIMIT_PATTERN`), and
  `clikae watch --check` reports whether it would fire on the current session so
  you can confirm/tune it the first time you actually get limited. The live tail
  loop is smoke-tested; detection, pool fall-through, and consent are bats-covered.
- **Fixed account-label extraction on real `.claude.json`.** The file is
  pretty-printed (`"emailAddress": "you@…"`, whitespace after the colon), which
  the extractor didn't match — and worse, the no-match `grep` propagated failure
  under `set -eo pipefail`, so `clikae list` / `status` aborted with exit 1 on any
  real, logged-in profile. Now tolerates the whitespace and never propagates a
  miss. (Both bugs were in the unreleased account-label work; caught dogfooding.)
- **Fixed an adapter-hook leak across adapters.** `load_adapter` now clears all
  adapter hooks before sourcing the next adapter, so an optional hook one adapter
  defines (e.g. `adapter_start_with_prompt`) is never inherited by another that
  doesn't — exposed by `handoff --to`, the first path to load two adapters in one
  process.
- **Account labels + `clikae rename` (stop squinting at `a`/`b`).** `clikae list`
  and `clikae status` now show an **ACCOUNT** column with the logged-in account
  where the adapter can read it — for claude, the email from `.claude.json` (via a
  new optional adapter hook `adapter_account_label`, pure grep/sed, no jq). New
  **`clikae rename <cli> <old> <new>`** renames a profile: moves the directory,
  rewrites the managed alias (keeping a custom alias name, else swapping the
  default `<cli>-<old>` → `<cli>-<new>`), and — for claude on macOS — carries the
  saved Keychain login across (reusing the `--keep-login` mechanism) so you don't
  re-login. It refuses if the target exists or the profile is in use in this shell
  (a data-integrity guard, like `migrate`). Covered by bats.
- **`flag` strategy + two new adapters (now 13).** Adds a `flag` adapter strategy
  for CLIs that have no config-directory env var and instead take a flag — via a
  new optional adapter hook `adapter_flag_args <dir>` that the alias / `.app` /
  `run` generators append after the binary. New adapters: **`codex`** (OpenAI
  Codex CLI, env-dir `CODEX_HOME` — a cheaper model/vendor to route work to) and
  **`vercel`** (flag strategy, `--global-config <dir>`). The alias/`.app` command
  assembly is centralised in `adapter_command`. `clikae status` reports `(n/a)`
  for flag-based CLIs (nothing to read from the environment). The PowerShell
  module mirrors all of this (codex + vercel in the adapter table, `flag`
  handling in the env/function/invoke/shortcut paths, new `Get-ClikaeFlagArgs`).
- **macOS menu bar app skeleton (`gui/ClikaeMenuBar`, v1.0 track).** A SwiftPM +
  AppKit `NSStatusItem` app that builds with the Command Line Tools (no Xcode):
  lists profiles grouped by CLI, check-marks the active one (`clikae status`),
  click-to-launch a profile (`clikae run`), a per-CLI **Relay → …** submenu
  (`clikae relay`), Refresh, and Quit. The CLI stays the source of truth — the
  app only shells out to it. Prefers Ghostty for the terminal it opens, falling
  back to Terminal.app. Build-verified; packaging as a signed `.app` is a future
  step.
- **`clikae app --terminal <app>` — choose the terminal the launcher opens.**
  In addition to Terminal.app (default), the generated `.app` can open **iTerm2**
  (`--terminal iterm2`) or **Ghostty** (`--terminal ghostty`). Terminal.app and
  iTerm2 are driven via their AppleScript scripting APIs; Ghostty has no
  window-opening CLI on macOS, so its launcher goes through
  `open -na Ghostty.app --args --title=… -e /bin/zsh -lc '…'` (env vars and
  spaces in paths preserved). The default target can be set with the
  `$CLIKAE_TERMINAL` environment variable. The chosen terminal must be installed;
  `app` fails with a clear message otherwise. Covered by bats (Ghostty path
  asserted when installed; the not-found path otherwise).
- **`clikae relay <cli> [<from>] <to>` — hand a live session to another profile.**
  clikae's origin story is keeping a second account because one account's quota
  runs out mid-task; `relay` makes that switch seamless. For Claude Code it copies
  the current directory's most recent transcript from the source profile into the
  target profile and resumes it (`claude --resume <id>`), so the conversation
  continues but new turns burn the target profile's quota. The source profile is
  never modified (relay copies, never moves), and with no transcript to carry it
  just starts a fresh session. The source profile is auto-detected from this
  shell's env var when only the target is given. Implemented via a new optional
  adapter hook `adapter_relay <from_dir> <to_dir>` (Claude-only; other adapters
  fall back to a plain start under the target). Covered by bats.
- **`clikae status [<cli>]` — show which profile each CLI is on in this shell.**
  Reads the live value of each adapter's env var and resolves it back to a clikae
  profile. Reports `(default)` when the var is unset and `(external)` when it
  points outside the clikae profile store. Foundational for the planned menu-bar
  GUI. Covered by bats.

## [0.4.0] — 2026-05-30

### Added

- **Four more built-in adapters (now 11 total).** `az` (Azure CLI, env-dir
  `AZURE_CONFIG_DIR`), `npm` (env-file `NPM_CONFIG_USERCONFIG` — a per-profile
  `.npmrc` holding registry auth tokens), `terraform` (env-file
  `TF_CLI_CONFIG_FILE` — Terraform Cloud / registry credentials) and `pulumi`
  (env-dir `PULUMI_HOME`). The two env-file adapters seed an empty config file
  on `init`. The Windows PowerShell adapter table is kept in sync.
- **Windows / PowerShell support (v0.4).** New `powershell/Clikae.psm1` module
  ports the tool to native Windows PowerShell — no bash required. It mirrors the
  built-in adapters and the profile-store layout, and since PowerShell aliases
  can't carry env vars it writes a sentinel-wrapped *function* (e.g.
  `claude-work`) into your `$PROFILE` instead of an alias. Verbs: `New-`/`Get-`/
  `Remove-`/`Invoke-ClikaeProfile`, `Add-ClikaeFunction`, `Get-ClikaeAdapter`,
  and a Windows-only `New-ClikaeShortcut` (`.lnk`). Backs up `$PROFILE` before
  editing and supports `-WhatIf`/`-Confirm`. Covered by a Pester suite
  (`powershell/Clikae.Tests.ps1`) run in CI on `windows-latest` under both
  PowerShell 7 and Windows PowerShell 5.1.
- **`clikae migrate` in-use guard.** `migrate` now refuses to move a config
  directory that the CLI is currently using in your shell — i.e. when the live
  `$CLAUDE_CONFIG_DIR` (or whichever env var the adapter uses) points at a dir
  slated to move. Previously this was only documented as a sharp edge; running
  `migrate` from inside the very session whose config dir was being moved could
  pull the directory out from under the live process and leave split state. The
  guard is not bypassed by `--force` (it protects data, it isn't a confirmation)
  and never blocks `--dry-run`.

### Changed

- CI: bumped `actions/checkout` to v5 (the v4 pin runs on the now-deprecated
  Node 20 runtime) and added a `windows-latest` Pester job.

### Fixed

- CI: the bats step now runs with `-r`, so the `tests/bats/adapters/`
  subdirectory is actually executed. It was previously skipped — `bats` does not
  recurse into subdirectories without the flag — meaning the adapter-listing
  tests never ran in CI.

## [0.3.0] — 2026-05-29

### Added

- **Homebrew tap.** `brew install CVERInc/clikae/clikae` now works, served from
  the [`CVERInc/homebrew-clikae`](https://github.com/CVERInc/homebrew-clikae)
  tap (formula tracks v0.3.0).
- **`clikae migrate --keep-login`.** On macOS, Claude Code stores its OAuth token
  in the login Keychain keyed by the `CLAUDE_CONFIG_DIR` path, so migrating
  (which moves the dir to a new path) otherwise forces a one-time re-login per
  profile. `--keep-login` carries the saved token from the old path's keychain
  entry to the new one as part of the move. Implemented as an optional adapter
  hook (`adapter_migrate_credentials`) so the keychain logic stays in
  `lib/adapters/claude.sh`; off by default, and the token never leaves the
  Keychain.

### Changed

- Documented that migrating a claude setup on macOS asks you to log in again
  unless you pass `--keep-login` — with the why (keychain token keyed by the
  config-dir path) and both recovery paths — in `docs/usage.md` and
  `docs/troubleshooting.md`.
- New `docs/claude-on-macos.md` recording two macOS-specific Claude Code
  behaviours found while dogfooding: the Keychain-stored login token (keyed by
  the config-dir path) and the "Welcome back" box vs compact logo (driven by
  `.claude.json` counters + `CLAUDE_CODE_FORCE_FULL_LOGO`, never the path).
  Confirmed against the Claude Code 2.1.156 binary. Linked from the README and
  troubleshooting.

- Docs split: README trimmed to "what + why" plus a 30-second demo and links;
  install, full usage/command reference, the `migrate` guide, and how-it-works
  moved into `docs/installation.md` and `docs/usage.md`; new
  `docs/troubleshooting.md`.

## [0.2.0] — 2026-05-28

### Added

- Built-in adapters for **GitHub CLI** (`gh`), **Google Cloud** (`gcloud`),
  **Docker** (`docker`), **Helm** (`helm`), **kubectl** (`kubectl`, the first
  `env-file` adapter), and **AWS** (`aws`, the first `env-var` adapter).
- `clikae migrate [<cli>]` — adopt a hand-rolled "config dir + shell alias"
  setup (e.g. the `~/.claude-acct-{a,b}` dual-account pattern) into clikae: it
  moves each referenced config directory under `~/.clikae/profiles/<cli>/<p>/`
  and rewrites the alias into clikae's managed sentinel block. Previews the plan
  and confirms first, backs up the rc once, and never overwrites an existing
  profile. Supports `--dry-run` and `--force`.
- `bats-core` test suite under `tests/bats/` (init, alias, list, remove, app,
  migrate, adapters, and bash-3.2 compatibility guards). Each test runs in an
  isolated throwaway `$HOME` + `$CLIKAE_HOME`.

### Fixed

- `clikae app` produced an uncompilable AppleScript on macOS: the command was
  substituted into the template with `sed`, but BSD/macOS `sed` strips
  backslashes from the replacement string, so the escaped `\"` collapsed to `"`
  and terminated the AppleScript string early. Substitution now uses bash
  parameter expansion (and escapes backslashes before quotes), so launchers
  compile and run correctly. This path was never exercised in v0.1.

## [0.1.0] — 2026-05-28

### Added

- Initial v0.1 scaffold: pure-bash CLI dispatcher (`bin/clikae`) with a small
  modular `lib/` (core, commands, adapters, templates).
- `clikae init <cli> <profile>` — create a profile under `~/.clikae/profiles/<cli>/<profile>`.
- `clikae alias <cli> <profile>` — write a managed alias block to the user's shell rc.
- `clikae app <cli> <profile>` — generate a macOS double-click launcher `.app`
  with a custom Terminal window title.
- `clikae run <cli> <profile> [-- args]` — run a CLI with a profile, no alias needed.
- `clikae list`, `clikae info`, `clikae adapters`, `clikae help`.
- `clikae remove <cli> <profile>` — atomically clean up the dir, alias block, and `.app`.
- Built-in adapter for **Anthropic Claude Code** (`CLAUDE_CONFIG_DIR`).
- Adapter template and developer guide for adding new CLIs.
- `install.sh` for `curl | bash` installs and a Homebrew formula template.
- MIT License.
