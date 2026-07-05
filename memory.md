# clikae memory — the Soul layer (convention)

> **Status: cross-engine shipped (claude + codex).** This file defines the *schema
> and conventions* for clikae's memory layer; `clikae memory share|isolate|status`
> is live. The canonical Soul is ONE vendor-neutral markdown dir
> (`$CLIKAE_HOME/souls/<group>/memory`); **claude** symlinks its memory dir into it,
> **codex** gets a pointer note in `AGENTS.md` and reads/writes the same markdown via
> the memory protocol — so cross-engine continuity needs **no translator and never
> drifts** (it's literally the same file). Design rationale: [`grammar.md` §10](/grammar.md).
> Coming: cross-engine **agy** (same pointer hook); an **optional** apfel translator
> (`CLIKAE_MEMORY_TRANSLATOR`) only for slicing/compressing a Soul (never required for
> the basic experience); per-entry `scope:` dial.

## 0. The one idea

A tank holds more than fuel — it holds the engine's **long-term memory**. clikae
already controls *where the engine's state lives* (config-dir indirection); the
same lever controls *the engine's brain*. So memory is a **dial**, not a fixed
behaviour:

| Mode | Mapping | Primitive | For whom |
|---|---|---|---|
| **share** | N tanks → **1** store (fan-in) | symlink fans in | aggregate your own brain across your own accounts |
| **isolate** | N → **N** (today's default) | none (separate dirs) | blast-radius containment |
| **evaporate** | N → **0** (throwaway) | symlink to `mktemp -d` | the ephemeral power user (`--ephemeral`, ✅ shipped) |

Sharing is **per-tank, whole-brain**: the consent unit is the tank (the members
file under `souls/<group>/`), never a single directory. claude keeps one memory
dir *per project directory*, so those symlinks are just per-directory
**projections** of the membership — `share` fans in every existing directory's
slot at once, and every clikae launch re-projects the current directory first
(`soul_prelaunch`, lib/core/soul.sh). A member tank therefore never quietly
accumulates isolated side-memory in a new directory; the only way a tank keeps
its own memory is `isolate` (or `solo`, which refuses sharing outright).

The framing, stated once: **clikae controls where state lives, how long, and how
widely shared** — for auth (today), for fuel (the reframe), and now for memory.

## 1. The Soul / Brain split

- **Soul** = the memory you *own*: plain markdown, portable, vendor-neutral —
  the relationship history, the protocols, the cross-project context. It is
  yours; you can read it, edit it, `git` it, take it to another machine.
- **Brain** = the vendor's model (Claude / Codex / Antigravity). Swappable.

`share` aggregates one Soul across many Brains. **It carries continuity and
context, NOT the model's thinking** — swapping the Brain does not make a cheaper
model think like a more expensive one. Never claim "same AI, painless engine
swap." (See [[no-phantom-features]].)

## 2. SSOT = markdown + frontmatter

The single source of truth is **plain markdown with YAML frontmatter** — the
existing memory protocol (a `MEMORY.md` index + one fact per topic file). There
is **no dependency on Obsidian or any viewer**; Obsidian is one optional reader
of the same files.

The store also carries a `PROTOCOL.md` — the Soul's operating manual (how to read
and, crucially, how to *write back* without drift: one fact per file, append don't
rewrite, mark incident/correction records, respect account isolation). claude knows
this from its system prompt; codex/agy learn it by reading `PROTOCOL.md` (the pointer
note sends them there). It's seeded on first `share` and never clobbered.

claude's file-memory is already near-neutral markdown, so claude is the **anchor
format**: claude reads its own memory dir natively (zero translation). codex keeps
its *own* memory opaquely (sqlite) but reads markdown **instructions** (`AGENTS.md`),
so it reads/writes the shared Soul directly via a pointer note — also zero
translation. A translator is only ever needed to *slice/compress* a Soul for an
engine (optional, later), never to make it readable; markdown is universal to these
coding agents. No engine forces a schema change on the anchor.

### 2.1 Frontmatter schema

Every topic file carries frontmatter. Phase 0 adds three Soul fields on top of
the existing `name` / `description` / `metadata.type`:

```yaml
---
name: <short-kebab-case-slug>
description: <one-line summary — used for recall relevance>
metadata:
  type: user | feedback | project | reference
  scope: share | isolate | evaporate   # default: isolate
  project: <area-slug>                  # which area this fact belongs to (for grouping)
  accounts: [<group-name>]              # which share-group may see it (account allowlist)
---
```

- **`scope`** — the per-entry dial. `isolate` (default) keeps the fact in the
  current tank only. `share` lets it travel into the share-group's common store.
  `evaporate` marks a fact as ephemeral (never persisted to a shared store).
- **`project`** — the area/cluster the fact belongs to (e.g. `clikae`,
  `feelreef`, `tile`, `cver-infra`). Drives the **grouped index** (§3). This is
  organisational only; it does not gate visibility.
**Walling a tank off (`clikae solo <engine> <tank> [reason]`).** The cross-account
guard only fires across *different* accounts — so two tanks on the SAME account but
with different purposes (e.g. your main tank and a bot/persona tank) would slip past
it: an accidental `share` could commingle them silently. Making a tank **solo**
(standalone — see grammar §3.3) takes it out of the fleet entirely: no relay/`to`,
no burn rotation, and `memory share` refuses it (with the reason) until `clikae solo
… --off`. `memory status` shows 🔒 solo. This is tank-level, distinct from per-entry
`scope` below.

- **`accounts`** — the share-group allowlist. 🔴 **Account isolation is
  sacred:** a fact is only ever visible to tanks the maintainer has explicitly
  grouped as "the same you." `share` is always **opt-in and group-scoped** —
  clikae **never** auto-crosses accounts (a `cver` fact never leaks into a
  different account's brain). Absent / empty `accounts` ⇒ the fact stays where
  it is.

All three fields are **optional and additive** — existing files without them
behave exactly as today (`isolate`, ungrouped). Phase 0 does not require
back-filling every file; fields are added as facts are touched.

## 3. The grouped index

`MEMORY.md` is the index loaded into context each session. It groups entries by
**area** (the `project` field) under `type` headings, so a 200-line flat list
becomes a navigable map. One line per memory; never put memory content in the
index. The grouping is the cheap, no-code, immediately-felt win of Phase 0 — the
content was already well-separated; only the index was a flat wall.

## 4. The locked values (carry into every later phase)

- 🔴 **Aggregate, never mutate the source.** Any share/translate operates on a
  view/copy going *outward*; the source tank's memory is never rewritten in
  place. Same DNA as relay's "copy, never move; source untouched."
- 🔴 **Account isolation is sacred.** opt-in, group-scoped, never automatic.
- 🔴 **No phantom continuity.** Soul carries context, not capability.
- **Reviewable + reversible.** Memory is authoritative and accumulative; unlike
  a disposable handoff brief, it must never be silently rewritten by a model. A
  translator (Phase 3) renders *disposable slices*, not in-place edits.

## 5. Roadmap pointer

Phase 0 (this doc + grouped index) → Phase 1 (`clikae memory share|isolate|status`,
symlink fan-in for claude) → Phase 2 (bootstrap pointer + write-back hygiene) →
Phase 3 (cross-engine translator bridge) → Phase 4 (scope dial + orchestration).
Full roadmap: the maintainer's plan + [`grammar.md` §10](/grammar.md).
