# clikae Playtest Guide — 10-Minute Get Started (v0.5.4)

> Hi 👋 Thank you for helping playtest **clikae**. This guide will take you from scratch to "Aha, I get it" in about 10 minutes.
> Even if you've **never used clikae before** or even heard of it, that's fine—just follow along.
>
> Note: clikae defaults to an **English interface**. This guide highlights English UI labels with their explanations.

---

## What is clikae? (Read this first)

If you use AI tools running in the terminal like **Claude Code** or **Codex**, and you have more than one account (e.g., because one ran dry, so you signed up for a second) or you are juggling multiple half-finished tasks at once, you've probably felt this pain:

- *Which terminal window has that conversation? Which account was I using?*
- *Where did I leave off?*
- *Never mind, let me just start a new one and tell the AI about the project all over again...*

**clikae is here to fix this mess.** Just type a single command, `clikae`, and you'll see a dashboard showing **everything you've been working on recently**—cross-account, cross-tool, newest first, with a one-line recap of "where you left off + next step." Pick one, press Enter, and you are right back where you stopped.

It's tiny, written in pure bash (every line is auditable), MIT open-source, **does not connect to the internet (zero-telemetry), has no background daemons, and stores no global state**. We call an AI account/config a **tank**—you can have many of them, and clikae helps you switch and resume between them cleanly.

---

## Prerequisites

- A **macOS or Linux** machine with [Homebrew](https://brew.sh) installed.
- **At least one AI CLI tool** you already use, most likely **Claude Code** (the `claude` command). clikae won't install the AI CLI or log in for you—it organizes what you already have.
- A Claude account you can sign in to (Pro or Max).
- About 10 minutes.

*Already a clikae user? Run `brew upgrade clikae` and skip to Step 3.*

---

## Step 0: Installation (1 min)

Open your terminal and paste:

```bash
brew install CVERInc/clikae/clikae
clikae version
```

The second command should print `clikae 0.5.4` (or newer). This means it's successfully installed.

---

## Step 1: Initialize your first tank (2 mins)

A **tank** is one account/config, isolated in its own directory so configurations never collide. The name can be anything you like—I'll use `myname` as an example. Let's create one for Claude Code, then open it to log in:

```bash
clikae init claude myname
clikae claude myname
```

The first command initializes the tank; the second opens Claude Code pointing to it. The first launch will guide you through Claude's normal browser login flow. Once logged in, **exit Claude** (type `/exit` or press Ctrl-C).
You now have a logged-in tank! 🎉

To see the "cross-account" effect, initialize a second tank with a different account (use any name you like):

```bash
clikae init claude anothername
clikae claude anothername
```

---

## Step 2: Leave some threads to resume (2 mins)

The board needs some activity to look interesting. Go to any project folder, converse with Claude, ask it to do something, and then exit:

```bash
cd ~/some-project-folder
clikae claude myname
# Do a bit of work with Claude, ask a couple of questions, then /exit to leave
```

Do this once or twice (even in the same folder). The more realistic your conversation, the better the recaps will be.

---

## Step 3: Open the Board (The main event 🌟)

In a folder where you recently ran Claude, type:

```bash
clikae
```

This is the "board". It has two sections:

**Top: Continue** — Recent conversations in this folder, newest first. Hovering over a row expands its one-line recap ("where you left off + next step").

**Bottom: Tanks** — All your accounts, listed in a single burn order (the priority queue clikae uses to automatically route headless jobs when one runs dry).

Each tank features a **status dot** indicating its quota status:

- 🟢 **Ready** — Has quota, ready to burn.
- 🔴 **Dry / Over limit** — Quota exhausted; shows estimated reset time.
- 🟡 **Weekly warning** — Reminds you of high weekly usage (BETA experimental feature).
- ○ **No reading** — Indeterminate status (e.g. Codex, where local status checking isn't supported, so it stays blank rather than guessing).

The tank **active in your current window** is marked as `active here`.

**How to control the board (controls are shown at the top of the screen):**

- `↑` `↓` (or `j` `k`) = move cursor
- `Enter` = open / resume the selected thread or tank
- `[` `]` = reorder the tanks up or down
- `/` = filter, `?` = help, `q` = quit
- `l` = switch language (English / Japanese / Traditional Chinese)

Press `?` to view the full hotkey map and legend. Press any key to return.

**Things to notice during this step:**

1. Is the board **fast**? Does it render in under a second?
2. Is navigation **flicker-free** and clean?
3. Do the status dots and recaps help you **grasp the situation at a glance**?

---

## Step 4: Resume & Incognito (2 mins)

Try these three actions on the board:

- Select a thread in the **Continue** section and press `Enter` → you will **resume that exact conversation**, carrying over the context right from where you left off.
- Go back to the board, select a tank in the **Tanks** section, and press `x` → starts an **incognito** session: clean, remembers nothing, leaves no trace on exit. Perfect for quick, throwaway tasks.
- Select a tank and press `Enter` → switches to that tank and starts a **fresh** Claude session.

Exit any session using `/exit` or Ctrl-C. clikae doesn't consume extra quota beyond the CLI session itself.

---

## Step 5 (Optional): Language & Handoff Briefs

**Language**: Press `l` on the board or run `clikae lang` to switch UI language between English, Japanese, and Traditional Chinese.

**Handoff Briefs**: When a session is close to its limit, `clikae to <another-tank-or-engine>` (relay) writes a handoff brief summarizing "what was done + next steps" and hands it to the target tank. These briefs are generated **on-device** using your local models—private, free, and offline. clikae auto-detects what is available in the order of: **Apple Intelligence** (via `apfel` on Apple Silicon Macs running macOS 26) → **Ollama** → **llm** command. If none are installed, it falls back to a clean raw extract of the transcript. It's a handy feature to know about even if you don't test it now.

---

## Let us know what you think! 🙏

All feedback is welcome! We'd love to know:

1. Did you **get it in 10 minutes**? Where did you get stuck or confused?
2. **The board**—fast enough? Clean? Did the dots and recaps make sense instantly?
3. **One thing** you wish it did, or found odd.

Send a message (or a screenshot of your board) to the team. **The more honest, the better!** 🍻

---

*clikae is open-source under the MIT license: <https://github.com/CVERInc/clikae> · The full vision is at [`docs/VISION.md`](./VISION.md).*
