# Adding a language

clikae's board and prompts speak `en-US`, `ja-JP` and `zh-TW` today (bare
`clikae lang` always prints the live list). Every locale ships **inside** clikae
itself — a language switch is instant, offline, and can never fail on a
download. Adding one is a self-contained PR touching **two files**.

## TL;DR — the touch points

1. **`lib/i18n/<code>.sh`** — copy `lib/i18n/en-US.sh` and translate. Use the
   full code (`ko-KR`, `fr-FR`, …). `en-US.sh` is the canonical key list; your
   file must define every key it defines (the test below will list what's
   missing).
2. **One line in `_i18n_locales`** in `lib/core/i18n.sh` — the supported-locale
   list. This function is the single source of truth: `clikae lang`'s choices,
   the board's `l` picker, and the CI completeness test all read it, so your
   locale appears everywhere (and is enforced) with no further edits.
3. Run `bash scripts/test.sh` — `tests/bats/i18n.bats` extracts the key list
   from `en-US.sh` and the locale list from `_i18n_locales` mechanically, and
   fails on any missing/empty key or placeholder mismatch. A partial
   translation cannot merge silently. No test edits needed.

That's it for almost every language: regional variants resolve through the
generic language-subtag rule in `_i18n_normalize` (`ko_KR.UTF-8` → `ko` →
`ko-KR`, `fr_CA` → `fr-FR`) with no extra line. **Two honest exceptions:**

- A **script-split language** needs its own resolver case: Chinese is keyed by
  writing system, not region — `zh_TW`/`zh_HK`/`*Hant*` → `zh-TW`, and
  Simplified (`zh_CN`/`zh_SG`/`*Hans*`) → `zh-Hans` once it ships. The exact
  slot is marked in `_i18n_normalize` (until then, all other `zh` reads
  `zh-TW`).
- Extra human spellings (`日本語`, `english`) are optional case lines in the
  same function.

## The file contract

`lib/i18n/<code>.sh` is plain bash, loaded with `source` over the `en-US` base
(so it must be dependency-free and bash-3.2-safe — no associative arrays):

- one `T_KEY="value"` per line, at **column 0**, double quotes — the test and
  `clikae lang` extract by this pattern;
- `T_LANG_NAME` is your language's own name for itself (the endonym) — it
  labels the language in `clikae lang`'s output;
- `%s` / `%d` are printf placeholders: keep exactly `en-US`'s placeholders in
  `en-US`'s order, and write `%%` for a literal percent sign — a stray `%`
  corrupts the printf at runtime (CI catches this too);
- `i18n_summary` — the board's "N tanks across M engines" line — is a
  *function*, because grammars count differently. Override it if English
  pluralisation reads wrong in your language; if you don't, the English
  fallback is used.

## What to translate (and what not to)

Translation is **graded**, not wall-to-wall:

- **Localize** the sentences a human reads to decide or understand: prompts,
  confirmations, menu items, status lines, warnings. These are the point —
  a consent question you can only read in English isn't informed consent.
- **Keep technical** the tokens that ARE the interface: command lines
  (`clikae to`, `clikae demo`), flags, paths (`~/.gemini`), engine/tank names,
  sizes and unit suffixes (`MB`). Users copy-paste, run, and search for these
  verbatim — translating them breaks that.

`en-US.sh` shows the split in practice; when unsure, match what `ja-JP.sh` and
`zh-TW.sh` did for the same key.

Quality bar: an **LLM-grade baseline translation is acceptable** to land a
language (that's how ja-JP started) — completeness is enforced by machines,
tone is improved by people. Native-speaker polish PRs are very welcome and can
be tiny (even one string).

## Checking your work

```bash
bash scripts/test.sh                     # completeness + the whole suite
CLIKAE_LANG=<code> clikae               # eyeball the board in your language
clikae lang <code>                       # the switcher already knows it
```
