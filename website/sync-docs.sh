#!/usr/bin/env bash
# Projects the curated public docs from ../docs/ into content/docs/ with Kura
# frontmatter. The repo's docs/ stay the single source of truth; this site is a
# projection. Re-run after editing any source doc. introduction.md is authored
# here by hand (a curated landing page), so it is never overwritten.
set -euo pipefail

cd "$(dirname "$0")"
SRC="../docs"
OUT="content/docs"
mkdir -p "$OUT"

# Drop previously-generated default-locale pages (keep the hand-authored
# introduction.md). -maxdepth 1 so locale mirrors like ja-JP/ — which are
# hand/translation-authored, NOT projected from ../docs — are never touched.
find "$OUT" -maxdepth 1 -name '*.md' ! -name 'introduction.md' -delete

# src | slug | title | section | order | description
emit() {
  local src="$1" slug="$2" title="$3" section="$4" order="$5" desc="$6"
  {
    printf -- '---\n'
    printf -- 'title: %s\n' "$title"
    printf -- 'description: %s\n' "$desc"
    printf -- 'section: %s\n' "$section"
    printf -- 'order: %s\n' "$order"
    printf -- '---\n\n'
    # Rewrite intra-doc links like ](usage.md) -> ](usage) so human nav stays clean.
    sed -E 's/\]\(([a-zA-Z0-9_-]+)\.md\)/](\1)/g' "$SRC/$src"
  } > "$OUT/$slug.md"
  echo "  $section/$slug"
}

echo "Projecting docs -> $OUT"
emit installation.md     installation   "Installation"       "Getting started" 2 "Install clikae via Homebrew or the install script — pure bash, no runtime."
emit usage.md            usage          "Usage"              "Getting started" 3 "The clikae verb, tanks, engines, and the home board."
emit orchestration.md    orchestration  "Orchestration"      "Guides"          1 "Fan headless work across your accounts with clikae burn and conduct."
emit agy-dispatch.md     agy-dispatch   "Driving agy headless" "Guides"        2 "Route work to your Antigravity (agy) account instead of burning Claude quota."
emit claude-on-macos.md  claude-on-macos "Claude Code on macOS" "Guides"       3 "macOS-specific Claude Code behaviours that affect clikae, and how to handle them."
emit adding-an-adapter.md adding-an-adapter "Adding an adapter" "Guides"       4 "Teach clikae to switch a new CLI in ~10 lines of bash."
emit grammar.md          grammar        "Grammar & lexicon"  "Reference"       1 "The single source of truth for clikae's command grammar and vocabulary."
emit memory.md           memory         "Memory (Soul)"      "Reference"       2 "Share one vendor-neutral markdown brain across your tanks and engines; what stays isolated, and clikae solo."
emit troubleshooting.md  troubleshooting "Troubleshooting"   "Reference"       3 "Fixes for common clikae issues."

# MDX-hazard guard. Kura compiles each page with @mdx-js/mdx, so an UNFENCED
# `{…}` (read as a JS expression) or a stray `<tag>` outside inline code makes the
# whole page fail to compile and get DROPPED silently. Fail loudly here instead of
# shipping a site that's quietly missing a page. Covers the locale mirrors too.
echo "Checking for MDX hazards…"
if python3 - "$OUT" <<'PY'
import re, sys, glob, os
root = sys.argv[1]
bad = 0
for path in sorted(glob.glob(os.path.join(root, "**", "*.md"), recursive=True)):
    fence = False
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        if line.lstrip().startswith("```"):
            fence = not fence; continue
        if fence:
            continue
        s = re.sub(r"`[^`]*`", "", line)  # drop inline-code spans (safe)
        if "{" in s or re.search(r"<[A-Za-z][A-Za-z0-9]*(\s|>|/)", s):
            print(f"  HAZARD {path}:{n}: {line.strip()[:90]}")
            bad += 1
sys.exit(1 if bad else 0)
PY
then :; else
  echo "✗ MDX hazards found — wrap the {…}/<tag> in backticks or fence it, else the page is dropped." >&2
  exit 1
fi

echo "Done."
