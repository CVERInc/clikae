---
title: Introduction
description: clikae is your starting point for working with AI CLIs — one board across every account and engine.
section: Getting started
order: 1
---

# clikae

> Type `clikae` and land back on your recent sessions — across every account and
> engine (Claude Code, Codex, Antigravity), each with a one-line recap of where
> you left off. Pick one and keep going.
>
> *"Kirikae" (切り替え, ki-ri-ka-e) is Japanese for "switching".*

You're juggling AI coding sessions across more than one account — two Claude
subscriptions because one Max plan ran dry, a Codex login, maybe Antigravity too
— in different terminals, on different projects, half of them unfinished. *Which
one was that in? Which account? What was I even doing?*

`clikae` is the on-ramp that fixes it. The home board lists those sessions newest
first, each with its one-line **recap** read free from Claude's own session
summary; pick one, hit Enter, and you're back — right account, right session.

## clikae is the verb

The name is 切り替え — *switching* — so **clikae is the verb**. There's no second
verb to memorise; the program name *is* the verb:

```bash
clikae <engine> <tank>   # point an engine (a CLI) at one of your tanks and run it
```

A **tank** is one account/config for an engine. clikae creates an isolated tank
directory per engine + tank, so logins, memory, and MCP connectors never bleed
across accounts.

## What it does

1. **Isolated tanks** — one folder per engine + tank, fully sandboxed.
2. **Shell aliases & macOS `.app` launchers** — double-clickable, titled windows so you can tell them apart.
3. **`clikae to`** — carry a live session to another tank when one runs dry (a real `--resume`), or hand it across vendors as a brief summarized **on-device** by a local model.
4. **`clikae burn`** — run headless tasks across tanks, verified by the **artifact** they produce (never the exit code), re-firing on the next reserve tank when one dries up.
5. **Your connectors ride along** — a tank isolates the claude.ai login, so its MCP connectors switch with it.
6. **`clikae memory`** — point several of your own tanks at one shared markdown **Soul** so they read and write a single brain **across engines**. `clikae solo` walls a tank off from the fleet.

Built-in adapters cover Claude Code, OpenAI Codex, GitHub CLI, gcloud, Docker,
Helm, kubectl, AWS, Azure CLI, npm, Terraform, Pulumi, Vercel, and per-account
Antigravity (`agy`). Adding a new one is ~10 lines of bash.

It's pure bash — no daemons, no global state, exactly one opt-out network call.
Every line is auditable.

## Swap the engine, keep the soul

A tank holds more than fuel — it holds the engine's long-term **memory**.
`clikae memory share <group>` points several of your own tanks at ONE vendor-neutral
markdown store — a **Soul** you own — so they read and write a single brain **across
engines**. Hit a Claude limit, carry on in Codex, and it already knows who you are and
where the work stands.

- **claude** fans its memory dir into the store with a symlink; **codex** and **agy**
  read a pointer note to the same markdown files — no translator, no drift.
- Sharing is **opt-in and per-tank**; clikae never auto-crosses accounts. The store is
  seeded by copy, and `clikae memory isolate` reverses it.
- `clikae solo` keeps a bot or persona tank — on your own account — out of the fleet:
  never relayed, burned, or shared.

It carries continuity and context, not the model's capability. See **[Memory](memory)**.

The home board reflects this: tanks lay out as **Tanks / Solo / Resume**, and on any
tank you can press `m` for the memory dial or `s` to toggle solo, right from the board.

## For humans and agents

This site serves the same content two ways: a fast docs site for you, and the
same pages as Markdown (`.md`) plus a callable `/mcp` endpoint for the agents
that drive clikae. One source, zero drift.

## Next

- **[Installation](installation)** — get clikae on your machine.
- **[Usage](usage)** — the verb, tanks, and the home board.
- **[Memory](memory)** — share one markdown Soul across your tanks and engines.
- **[Orchestration](orchestration)** — fan headless work across accounts.

> ⚠️ **Unofficial.** `clikae` is a community tool, not affiliated with or endorsed
> by any CLI vendor it integrates with. "Claude" is a trademark of Anthropic, PBC;
> other CLI names are trademarks of their respective owners.
