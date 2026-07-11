# Your accounts and the vendors' terms

clikae moves work between accounts. Whether a particular move is fine or risky
depends on the vendors' terms — and those terms draw a real line. This page
shows you where that line is, with the actual policy language, so you can
decide for yourself without digging through legal pages.

**Research date: 2026-07-11.** Terms change; the links below always show the
current version. This page is our honest reading, not legal advice.

## What clikae does — and deliberately doesn't — do

Mechanically, clikae only ever:

- runs the vendors' **official CLI binaries**, with each account's **own
  official credentials**, using each CLI's **documented configuration
  mechanism** (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, …);
- copies **your files on your machine** (session transcripts, memory notes)
  between directories you own.

It never proxies or intercepts traffic, never extracts an OAuth token into a
different product, and never shares one account's credentials with another
account or person. Those are the things vendors' terms prohibit outright —
Anthropic's consumer terms, for instance, forbid making your account
available to anyone else and forbid using its OAuth tokens outside Claude
Code / claude.ai.

## Where the line is

The vendors are consistent on this, and it is worth reading slowly:

**Different accounts for different purposes is fine.** A work account and a
personal account, or one account per client — that's ordinary, expected use.
Nothing in Anthropic's, OpenAI's, or Google's consumer terms objects to a
person holding several accounts they each pay for and using them for
separate things.

**Using a second account to continue the same task past a usage limit is
not.** OpenAI's [Terms of Use](https://openai.com/policies/row-terms-of-use/)
name it directly — they prohibit "circumventing any rate limits or
restrictions" and "configuring the Services to avoid Usage Limits."
Anthropic's [Usage Policy](https://www.anthropic.com/legal/aup) is broader
but points the same way: it prohibits coordinating "across multiple accounts
to … circumvent product guardrails," and usage limits are a product
guardrail. (As of the research date, neither vendor spells out "multiple
paid accounts + limit rotation" as its own named violation — this is gray
zone, which means the vendor holds the interpretation, and enforcement
doesn't require a court.)

## What that means for clikae's features, concretely

- `clikae claude work` / `clikae claude personal` — separate accounts for
  separate purposes. The safe side of the line.
- Tank isolation, `git-id`, per-account MCP connectors, Soul memory groups,
  `--ephemeral` — all operate on your own files and identities. Safe side.
- `clikae to` after hitting a limit, and `clikae burn`'s automatic re-fire on
  the next account — **when used to push the same task past a limit, this is
  the gray zone**. We won't dress that up: it is the use these features were
  originally built for, and it is the use the terms language points at.

Two more things you should know before choosing:

- **The pattern is visible.** A carry looks like: same machine, same IP, one
  account hitting its limit, another account continuing the identical
  conversation moments later. Assume the vendor can see that; don't choose
  based on the hope that they can't.
- **You carry the risk, not clikae.** If a vendor enforces, it's your
  accounts and your in-flight work. clikae can't protect them, and an MIT
  license means nobody is coming to compensate you. Also worth knowing:
  Anthropic now offers extra-usage purchases on Max plans — an official way
  to continue past a limit exists; check your plan's current options.

## The one-time note

The first time a cross-account carry is about to happen (`clikae to`, or a
`clikae burn` with fall-through armed), clikae prints a short version of this
page and, in a terminal, waits for Enter — once, then never again. Not a
nag; we'd just rather you saw the line before crossing it than after.

## Sources (as of 2026-07-11)

- Anthropic: [Consumer Terms](https://www.anthropic.com/legal/consumer-terms) ·
  [Usage Policy](https://www.anthropic.com/legal/aup)
- OpenAI: [Terms of Use](https://openai.com/policies/row-terms-of-use/) ·
  [Usage Policies](https://openai.com/policies/usage-policies/)
- Google: [Google Terms of Service](https://policies.google.com/terms) ·
  [Generative AI Additional Terms](https://policies.google.com/terms/generative-ai)

If you spot terms language this page should reflect, or a change after the
research date, [an issue](https://github.com/CVERInc/clikae/issues) is very
welcome — keeping this page honest is part of the product.
