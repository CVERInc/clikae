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

The source is auto-detected from the active session in this shell. clikae always
**announces which mechanism it used**, so the resume-vs-brief difference is
surfaced at runtime, never memorised:

```
✓ carried your live session → claude/personal (resumed, context intact)
⚠ codex can't resume a claude session — handed it a written brief (cold start)
```

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
| `clikae init agy work` | **First time:** multi-confirm that clikae may take over `~/.gemini`, back it up, migrate the current login into a `default` tank, then create `work`. **After:** just creates the tank (no ceremony — the dangerous one-time takeover already happened). |
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
- The "multi-confirm" lives on the **first-ever takeover only** (turning your
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
      runs the multi-confirm takeover; bare-switch does select-slot + launch +
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

*This grammar is a decision, not a sketch. Change it here first, with the
maintainer, before changing the code.*
