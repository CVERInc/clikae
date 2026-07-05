# clikae docs site

The public documentation site for [clikae](https://github.com/CVERInc/clikae),
built with [Kura](https://kura.build) (agent-native docs on
[June](https://june.build), deployed to Cloudflare Workers).

Humans get a docs site with sidebar, TOC, and search; agents get every page as
Markdown (`.md`), JSON (`.json`), and callable MCP tools at `/mcp`.

## Content is a projection of `../docs/`

The repo's `docs/*.md` stay the single source of truth. The curated public pages
under `content/docs/` are **generated** from them by `sync-docs.sh`, which copies
the public subset and prepends Kura frontmatter (`title`, `section`, `order`).
`introduction.md` is the one hand-authored page (the landing).

```bash
npm run sync     # regenerate content/docs/ from ../docs/ after editing a source doc
```

Edit a source doc in `../docs/`, run `npm run sync`, rebuild. To add a page to the
site, add a line to the `emit` list in `sync-docs.sh`.

## i18n (English + 日本語)

English (`en-US`) is the default locale at `/`; Japanese (`ja-JP`) lives under
`/ja-JP`, configured in `kura.config.ts` (`i18n`, `localeNames`, `sectionLabels`,
`labels`). Default-locale pages stay flat in `content/docs/*.md`; each Japanese
page mirrors its slug in `content/docs/ja-JP/<slug>.md`. A missing translation
falls back to English (with a "not translated" notice).

The `section`/`order` frontmatter values are **stable keys** — keep them identical
across locales; only `title`, `description`, and the body get translated. The
`ja-JP/` files are hand/translation-authored (there's no Japanese source in
`../docs/`), so `npm run sync` deliberately never touches them.

## Local preview

```bash
npm run dev       # Kura dev server with hot reload at http://localhost:3000
npm run preview   # alt: build + serve the real Worker at http://localhost:8788
```

`npm run dev` is the normal loop. `npm run preview` builds the production Worker
and serves it under Wrangler (exactly what `npm run deploy` ships) — useful for a
final check against the real runtime.

> Dependencies resolve cleanly now (`@junejs/server 0.0.46`, single `@junejs/core
> 0.0.46`). We previously needed a `package.json` `overrides` block to force the
> dev-server fix past a `0.0.x` caret-pin; the upstream `@junejs/cli 0.0.49`
> release fixed that at the source, so the override was removed.

## Deploy

```bash
npm run deploy    # build + deploy to Cloudflare Workers (needs `wrangler login`)
```

Requires the `workers-og` dependency (in `package.json`) for the OG-image route.
