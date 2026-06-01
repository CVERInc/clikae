# clikae grammar & lexicon — the single source of truth

This document defines clikae's command grammar and its vocabulary. It is the
SSOT: `bin/clikae` (dispatch), `lib/commands/help.sh`, every user-facing string,
the home dashboard, and the docs all conform to what is written here. When the
grammar and the code disagree, the grammar wins — fix the code.

> Read this end-to-end before touching the command surface or any user-facing
> wording.

---

## 0. The one idea

**`clikae` is a verb.** The name is `CLI` + `kae` (切り替え, *kirikae* — "to
switch"). The tool's whole job is *switching*, so the word `clikae` already
*means* "switch". The grammar is built on that:

- The headline action — point a CLI at a tank and start it — needs **no verb at
  all**, because the verb is the program name. `clikae claude work` reads
  "**switch** claude **to** work". Nothing to memorise: you already know what
  `clikae` means.
- Everything that *isn't* switching (create, delete, inspect, monitor) keeps an
  explicit, conventional verb.

This is the opposite of inventing cute verbs. We do not rename `run` to `burn`.
We **elide** the verb where the program name already carries it, and otherwise
use the plain verbs every power user already has in muscle memory.

---

## 1. Two layers, one rule

> **The interface follows convention. The metaphor lives in the model.**

| Layer | What goes here | Rule |
|---|---|---|
| **Verbs / operation** | what you type, tab-complete, script | Follow convention. `init` / `remove` / `list` / `status` are what git, docker, npm, kubectl, gh use. The *switch* action is elided (program name = verb). **Zero novel verbs to learn.** |
| **Nouns / model** | the concepts you read and remember | This is where the fuel metaphor earns its keep — it makes the model sticky at no keystroke cost. |
| **Prose / dashboard** | help intro, status lines, errors, README, the board | Tell the fuel story freely here. |

**The test a metaphor must pass:** it may help you *understand*; it must never
be required to *operate*. `clikae run claude work` needs no story. We never ship
a verb you must decode a metaphor to use.

---

## 2. The lexicon (nouns)

| Concept | Word | Notes |
|---|---|---|
| A CLI tool clikae manages (claude, codex, agy…) | **engine** *(a.k.a. CLI)* | The thing that burns fuel. The arg is `<engine>`. Internal code, adapters, and `lib/adapters/` keep the name `cli` — users see *engine*. |
| One account/config you can burn | **tank** *(a.k.a. profile)* | The core noun. **Replaces `profile` and `slot` on every user-facing surface.** Annotate "(a.k.a. profile)" the first time it appears in help and in `--help` for `init`/`list`, for people who know the old word. |
| The usage allowance in a tank | **fuel** / quota | — |
| A tank that's out of quota | **dry** tank | Badged `⚠` on the board. |
| Using a CLI (consuming fuel) | **burn** | Prose only ("swap the tank, keep burning"). **Not a command.** |
| The ordered reserve tanks `watch` falls through | **pool** | — |
| Carrying a live session to another tank | **relay** (same CLI) / **handoff** (cross-CLI) | Internal/legacy terms. The user-facing verb is `to` (§3). |

**`profile` and `slot` are retired from user-facing text.** They survive only as
internal identifiers and on disk (`~/.clikae/profiles/<engine>/<tank>/`,
`profile_dir`, `profiles_root`) — we do **not** churn the storage layout or the
core functions. Users see exactly one word: *tank*.

---

## 3. The grammar (verbs)

### 3.1 Switching — the elided verb

| You type | Means | Replaces |
|---|---|---|
| `clikae` | Open your tank board (home). | — |
| `clikae <engine> <tank>` | Switch `<engine>` to `<tank>` and **start fresh**. | `run` |
| `clikae <engine>` | One tank → switch to it. Many → list / pick. None → offer to create. | — |
| `clikae <engine> <tank> -- <args>` | …passing `<args>` straight to the CLI. | `run … -- …` |

### 3.2 Carrying a session — `to`

`to` is the **"bring my work with me"** marker. `clikae to codex` reads "switch
**to** codex", and *carries the current session* rather than starting fresh.

| You type | Means | Replaces |
|---|---|---|
| `clikae to <tank>` | Carry this shell's current session onto another **tank of the same CLI** → a real `--resume`. | `relay` |
| `clikae to <engine> [tank]` | Carry it to a **different CLI** → that engine can't resume a foreign session, so clikae hands it a written **brief** (cold start). | `handoff` |

The source is auto-detected: first the live env var, then — because the bare
switch / aliases / `.app` run the engine with a prefix assignment that never
reaches the parent shell — **the tank with this directory's most recent
transcript** (stateless; "the session I was just in here"). To pin a shell to a
tank explicitly, `eval "$(clikae env <engine> <tank>)"`. clikae always
**announces which mechanism it used**, so the resume-vs-brief difference is
surfaced at runtime, never memorised:

```
✓ carried your live session → claude/personal (thread resumed)
⚠ codex can't resume a claude session — handed it a written brief (cold start)
```

> **Precision (a tank holds more than fuel).** `to` carries the **session
> transcript** — the thread continues — but NOT the engine's *long-term memory*,
> which lives inside the tank dir (e.g. claude's file-memory under
> `CLAUDE_CONFIG_DIR`) and stays with the source tank. So "resume" means the
> conversation, not the brain. Carrying/sharing memory across tanks is a separate,
> future opt-in (see the link/overlay idea in §10). Don't claim "context intact".

`to`'s argument resolves **engine name first, then a tank of the current
engine** (stateless and predictable: a known engine name always crosses to it).
Disambiguate explicitly with `clikae to <engine> <tank>`. clikae always
announces what it resolved, so a wrong guess is visible and correctable.

### 3.3 Management — plain conventional verbs

These are **not** switching, so they keep an explicit, conventional verb. No
fuel words forced on them.

| Command | Purpose |
|---|---|
| `clikae init <engine> <tank>` | Create a tank. (`--alias` also writes a shell alias.) |
| `clikae remove <engine> <tank>` | Remove a tank (dir, alias, .app). |
| `clikae rename <engine> <old> <new>` | Rename a tank (dir, alias, login carried over). |
| `clikae tanks` (alias: `clikae list` / `ls`) | List every tank, with the logged-in account. `tanks` is canonical — a **noun query**, like the existing `adapters` command, not a coined verb. `list`/`ls` stay for convention and for the GUI's `list --json`. |
| `clikae status [cli]` | Which tank each CLI is on **in this shell**. |
| `clikae watch <engine> [tank]` | Notice a dry tank; offer/auto carry onward (drives `to` through the `pool`). |
| `clikae pool [add\|remove] [target]` | Manage the reserve order `watch` falls through. |
| `clikae migrate [cli]` | Adopt a hand-rolled config-dir + alias setup. |
| `clikae app` / `clikae alias` | Generate a macOS launcher / write a shell alias. |
| `clikae doctor` / `info` / `adapters` / `demo` / `help` / `version` | Inspect / meta. |

---

## 4. Parsing & precedence

`bin/clikae` resolves the first argument in this order:

1. **Reserved command?** (`init`, `remove`, `list`, `tanks`, `status`, `to`,
   `watch`, `pool`, `rename`, `migrate`, `app`, `alias`, `run`, `continue`,
   `relay`, `handoff`, `doctor`, `info`, `adapters`, `demo`, `home`, `help`,
   `version`, plus `-h/--help/-v/--version`) → run that command.
2. **Else, a known CLI?** (an adapter in `lib/adapters/` or a target in
   `lib/targets/`, e.g. `claude`, `codex`, `agy`) → the **bare switch** of §3.1.
3. **Else** → unknown; show an error + `help`.

Consequences, documented so they never surprise:

- Reserved commands win. If you ever have a CLI literally named like a reserved
  word, reach it via the explicit alias: `clikae run <engine> <tank>`.
- `clikae <engine> --help` is ambiguous, so we don't guess: clikae's own help is
  `clikae help <engine>`; flags meant for the CLI go after `--`
  (`clikae <engine> <tank> -- --help`).

---

## 5. The `to` footgun — and how we defuse it

`clikae claude work` (start fresh) and `clikae to claude work` (carry the
session) differ by one word. A bare switch does **not** destroy anything — your
old tank's transcript is still there to `to` back into later — so the cost of
forgetting `to` is usually just a wasted step, and it's recoverable.

The one moment it genuinely stings is when **the tank you're on just ran dry**:
you hit a limit, you want to continue, and a silent fresh start is the opposite
of your intent. So the mitigation is **narrow on purpose** — it fires only there:

**Mitigation (option B):** a bare switch is **dry-aware**, not session-aware in
general. When `clikae <engine> <tank>` is invoked and the tank you're currently
on for that engine **is over quota (dry)**, clikae does not silently start fresh.
On a TTY it asks:

```
claude/main is out of fuel right now.
  ❯ Carry this session over to work   (= clikae to)
    Start work fresh
```

Non-interactively (pipe/script) it defaults to **start fresh** but prints:
`hint: to continue this session, use  clikae to claude work`.

When the current tank is **not** dry, a bare switch is silent and instant — we
respect that switching to another tank is probably intentional. This puts the
one prompt exactly on the product's core moment (dry → swap tank), and nowhere
else.

---

## 6. Antigravity (agy) folds into the same grammar — no special verbs

The engine's canonical name is **`agy`** — that's what its own CLI calls itself,
and it matches the rule that the engine arg is always the binary name (`claude`,
`codex`, `gh`). `Antigravity` is the proper name we use in prose and UI titles
("Antigravity (agy)"); `antigravity` survives only as a hidden long-form alias of
the engine name. **You type `agy`.**

agy hardcodes `~/.gemini`, ignores every env var, and has no config-dir flag, so
it can't switch per-shell like other engines. clikae handles it by swapping
`~/.gemini` between tank dirs via a symlink — a global, one-tank-active-at-a-time
power mode. The user does **not** learn a separate command tree for this: agy
uses the *same verbs as everything else*, with **zero special subcommands**.

| You type | agy behaviour |
|---|---|
| `clikae init agy work` | **First time:** warn about the tradeoffs and ask one explicit `[y/N]` before clikae takes `~/.gemini` over, then back it up, migrate the current login into a `default` tank, and create `work`. **After:** just creates the tank (no ceremony — the dangerous one-time takeover already happened). |
| `clikae agy work` | Switch the active tank to `work` (refuses if agy is live), then start agy. Prints `agy is global — switched all terminals to work`, because the side-effect is machine-wide. |
| `clikae list` / `status` | agy tanks appear alongside the rest; `●` marks the one active tank; labelled `(global)`. |
| `clikae remove agy work` | Remove the tank. **Removing the last tank** offers to also restore a vanilla `~/.gemini` and release the takeover — that's the teardown, folded into `remove`. |
| `clikae agy --release` | The rare "keep my tanks but stop managing `~/.gemini`" case: restore a normal single-account `~/.gemini` and release the symlink takeover, leaving the tank dirs on disk for later. A flag (not a tank name → no bare-switch collision). |

There is **no** `clikae agy disable` / `antigravity disable` — it would collide
with the bare switch (`clikae agy <tank>` reads `disable`/anything as a tank
name). Teardown lives in `remove` (last tank) and the `--release` flag.

Key points:
- agy **can have many tanks** (store as many as you like). It can only have
  **one active at a time** across the whole machine — agy's engine has a single
  hardcoded fuel line (`~/.gemini`). The board's `●` makes that visible.
- The warn-and-confirm lives on the **first-ever takeover only** (turning your
  real `~/.gemini` into a managed symlink). Subsequent `init agy <tank>` is a
  plain `mkdir` — same friction as `init claude`.
- agy can be a relay/`to` **target** (`clikae to agy` → brief + launch) but not
  a **source** (its `.pb` transcript is opaque). `watch agy` is alert-only.

---

## 7. Back-compatibility (hidden aliases)

These keep working but are **not** advertised in `clikae help` (they may appear
in `clikae help <cmd>`):

| Hidden alias | Canonical |
|---|---|
| `run <engine> <tank>` | `clikae <engine> <tank>` |
| `continue` / `relay` / `handoff` | `clikae to …` |
| `antigravity add` / `use` / `enable` / `disable` | folded into `init` / bare-switch / first-`init` / `remove`-last-tank + `--release` |
| `antigravity` (as the engine name) | `agy` (canonical engine name; `antigravity` is a hidden long alias) |
| `list` / `ls` → `tanks`, `rm` → `remove`, `dashboard` → `home` | `tanks` is canonical; `list`/`ls` are aliases |

Scripts and CI should prefer the explicit aliases (`clikae run …`) where
clarity beats brevity — that's exactly what they're for.

---

## 8. Help must lead with the elided form

Because the bare switch has no verb, it is *invisible* unless taught. The home
screen (bare `clikae`) and `clikae help` MUST open with it:

```
clikae <engine> <tank>     switch <engine> to <tank> and run it      ← the main thing
clikae to <where>       carry your current session elsewhere
clikae                  your tank board
clikae init <engine> <tank>   create a new tank
clikae help                full command reference
```

---

## 9. Implementation checklist (conform the code to this doc)

- [ ] **Dispatch** (`bin/clikae`): the §4 first-arg resolver — reserved command
      → bare switch (known CLI) → error. Wire `to` and `tanks`; keep `run`,
      `continue`, `relay`, `handoff` as hidden aliases.
- [ ] **Bare switch**: route `<engine> <tank>` through the existing `cmd_run` path
      (env apply + exec). Add the §5 session-aware prompt.
- [ ] **`to`**: a single command that auto-detects source, picks resume
      (same CLI) vs brief (cross CLI), and announces which. Fold today's
      `relay` + `handoff` behind it.
- [ ] **agy**: intercept `cli ∈ {agy, antigravity}` in `init` / bare-switch /
      `remove` **before** `load_adapter` (agy has no adapter). First `init agy`
      runs the warn-and-confirm takeover; bare-switch does select-slot + launch +
      the global notice; **remove of the last tank offers teardown**, and
      `clikae agy --release` handles keep-tanks-but-release. **No `disable`
      subcommand** (collides with bare switch). Canonical engine name is `agy`;
      `antigravity` becomes a hidden long alias — drop the old
      `cmd_antigravity` subcommand tree.
- [ ] **Wording sweep**: `profile`/`slot` → `tank` (a.k.a. profile) across
      `help.sh`, `list` header (`PROFILE` → `TANK`), `init`/`run`/`remove`
      prompts, error strings, and the home dashboard. Disk layout and core
      function names stay `profile`.
- [ ] **Help**: rewrite `cmd_help` to §8 — lead with the elided form.
- [ ] **Docs**: update `usage.md` / `README.md` to this grammar; purge `run`
      and `relay/handoff` from the *recommended* surface (keep as aliases).
- [ ] **Tests**: bats for first-arg resolution, the `to` footgun prompt
      (TTY vs non-TTY), agy folding, and back-compat aliases.
- [ ] **PowerShell mirror**: reflect the same grammar in `Clikae.psm1` where it
      applies.

---

## 10. Open design frontier — a tank holds more than fuel

> Contributed by a concurrent session (the over-quota-detection work, profile b,
> 2026-06-01). Recorded here as an open frontier, **not yet a decision** — the
> maintainer's call whether to fold it into the model.

**The tension.** §2 says *fuel = quota* and *tank = one account/config*. True,
but the tank dir holds far more than fuel — it holds the engine's **long-term
memory and every transcript**. Fuel is fungible; memory is not. So "swap the
tank, keep burning" quietly swaps the engine's *brain* too. (Proof: claude's
file-memory lives inside `CLAUDE_CONFIG_DIR`, so `profiles/claude/a` and
`…/b` have entirely separate memory stores — they've even drifted to different
naming conventions. Cross-tank memory only travels by a hand-rolled bridge.)

**The unifying pattern.** agy's `~/.gemini` symlink-swap (§6) isn't a one-off.
clikae keeps hitting engines that hardcode *where* their state lives in a way
that mismatches the cardinality we want — and the fix is always filesystem
indirection to reshape that mapping:

| Case | Engine assumes | clikae wants | Indirection |
|---|---|---|---|
| **agy** (§6) | one hardcoded `~/.gemini` | many tanks | symlink fans **out** (1 path → pick of N) |
| **shared memory** | memory bundled in the swapped dir | one shared store | symlink fans **in** (N paths → 1 store) |
| **`to`** (§3.2) | transcript siloed per tank | carry it across | copy bridges the boundary |

Same primitive, three directions. The cooperative engines (claude/codex/gh) are
the easy case — an env var, so `env-dir`/`env-file`/`flag` just point it. agy and
memory are the entangled cases that want the same tool.

**The idea to weigh:** a fourth strategy alongside `env-dir`/`env-file`/`flag` —
a **link / overlay** strategy. It would (a) make agy a principled strategy rather
than a "target, not adapter" snowflake, (b) give *cross-tank memory sharing* a
home (a warned, reversible opt-in symlinking one shared memory store into each
tank — informed-consent style, like §6), and (c) connect `to`'s transcript-carry
to the same family. i.e. "agy folds into the same grammar" extended one level
down to "agy folds into the same *state-control model*, no special mechanism."

Full write-up: `~/clikae-handoff-state-mapping.md`.

> The rest of §10 is a maintainer design session (2026-06-01) building on that
> gift. Still a frontier, not a shipped decision — but the shape is agreed.

### 10.1 The synthesis: clikae is the control plane for the engine's *brain*

The tension above resolves into a single idea. clikae already controls **where
the engine's fuel comes from** (which account/quota). The same lever — filesystem
indirection on the config dir — also controls **the engine's memory**. So memory
is just another dial, with a spectrum:

| Mode | Memory mapping | For whom |
|---|---|---|
| **share** | N tanks → **1** store (fan-in) | aggregate your own brain across accounts |
| **isolate** | N → **N** (today's default) | the current behaviour; blast-radius containment |
| **evaporate** | N → **0** (redirect to throwaway) | the surgical/ephemeral power user |

Same primitive as agy's symlink, pointed at three purposes. **clikae's essence,
stated once: control where state lives, how long, and how widely shared** — for
auth/config (today), for fuel (the reframe), and now for memory.

**Guiding value (maintainer, locked):** *aggregate, never mutate the source.* Any
memory move/share/translate operates on a COPY going outward; the source tank's
memory is never rewritten in place. Same DNA as relay's "copy, never move; source
untouched."

### 10.2 The bridge — a pluggable, local-first translator

Cross-**engine** memory is NOT a symlink: claude / codex / agy store memory in
incompatible formats. The fix mirrors `handoff`'s existing
`CLIKAE_HANDOFF_SUMMARIZER` — a pluggable, local/cheap model does the semantic
work, clikae just runs plumbing. Propose **`CLIKAE_MEMORY_TRANSLATOR='<cmd>'`**:
model-agnostic, **local-first** (no quota burned, nothing leaves the machine —
memory is sensitive). Apple Intelligence is one backend (its on-device model is
reachable only via Swift `FoundationModels`, so a small `clikae-translate` shim —
the GUI is already Swift); `llm`/`ollama` another.

**The objection MOVES from format to *loss*.** A summarizer for a one-shot
handoff brief is safe because the brief is **disposable**. Memory is the opposite
— authoritative, accumulative, trusted across sessions. An LLM rewriting memory
on every sync drifts (a telephone game). So memory translation must be treated as
reviewable + reversible, never a silent background rewrite.

### 10.3 Light vs heavy — and idea B

- **Light — per-`to` memory injection (disposable).** On `clikae to codex`, the
  translator renders the *relevant slice* of the source tank's memory into a form
  codex can use, injected **once** alongside the handoff brief. codex doesn't
  permanently grow a claude-brain; it just knows enough for *this* continuation.
  No canonical store, no telephone game, no concurrency. It is literally
  `handoff` ++ : the brief carries the thread, this carries a brain-slice. **Do
  this first.**
- **Heavy — a persistent canonical store.** clikae keeps ONE canonical memory
  store; the translator does canonical↔each-engine; all tools share long-term.
  The endgame, but it needs a canonical schema, **reviewable sync (show the diff,
  approve)**, drift control, and concurrency handling.
- **Idea B (engines read/write clikae natively) — half true, half walled.**
  *Already true:* clikae's config-dir indirection ALREADY puts the memory
  physically in its own tree — this very file's `MEMORY.md` lives under
  `…/profiles/claude/b/…/memory/`. *Walled:* engines expose a memory *location*
  hook (the env var) but **not a memory *format* hook** — you can relocate
  claude's memory, you can't make it write clikae's schema or make codex read
  claude's files. So the clean form of B = **adopt claude's near-neutral markdown
  AS the canonical**, claude is ~native, others bridged by the translator. B
  doesn't escape translation; it minimises it by picking the most-neutral format
  as the anchor. (B is the heavy version reached from another door.)

### 10.4 Ephemeral memory (the "evaporate" mode) — ✅ SHIPPED

The surgical power user wants a model that **remembers nothing**. clikae already
owns the config-dir indirection, so pointing the `memory` subdir at a throwaway
is trivial — same primitive, third direction. **Shipped as
`clikae <engine> <tank> --ephemeral`** (`lib/commands/switch.sh`): it stashes the
tank's real `projects/<slug>/memory` aside, symlinks a `mktemp -d` throwaway in
its place, runs the engine **as a child** (not `exec`, so cleanup runs), and on
exit restores the real memory + wipes the throwaway. A crashed run self-heals on
the next `--ephemeral`. Login + transcripts are normal — **only memory is
throwaway**. Engine-gated by a new optional hook `adapter_memory_dir <dir>`
(claude defines it; others reject `--ephemeral` cleanly). bats in
`tests/bats/ephemeral.bats`.

**Honest framing (shipped as written):** clikae guarantees *the memory dir is
throwaway* — it's **ephemeral memory**, NOT "remembers nothing anywhere" (caches,
shell history, telemetry, Keychain are outside reach). The `--help`/docs promise
only what's kept.

### 10.5 Shipping order

1. ✅ **Ephemeral memory** — SHIPPED (`--ephemeral`; smallest, zero
   model/translation, immediate value for the surgical user).
2. **Light per-`to` memory injection** — the local-translator proving ground
   (`handoff`++). NEXT.
3. **Heavy canonical store** (= idea B) — only once the local bridge is proven
   reliable and the disposable slice turns out not to be enough.

All three are one `link/overlay` strategy (§10 intro) — clikae as the dial on the
engine's brain.

---

*This grammar is a decision, not a sketch. Change it here first, with the
maintainer, before changing the code.*
