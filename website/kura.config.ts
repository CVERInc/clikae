import { defineKura } from "@kurajs/docs";

export default defineKura({
  site: { name: "clikae", brand: "clikae" },
  // Sidebar groups (frontmatter `section` model). The values here are stable KEYS —
  // keep them identical across locales; localized headings live in `sectionLabels`.
  sections: ["Getting started", "Guides", "Reference"],

  // i18n — English (en-US) is the default at "/", Japanese (ja-JP) lives under "/ja-JP".
  // Default-locale content stays flat in content/docs/*.md; ja-JP mirrors it in
  // content/docs/ja-JP/<same-slug>.md. Missing translations fall back to English.
  i18n: {
    defaultLocale: "en-US",
    locales: {
      "en-US": {},
      "ja-JP": { path: "/ja-JP" },
    },
  },
  // Language-switcher display names.
  localeNames: {
    "en-US": "English",
    "ja-JP": "日本語",
  },
  // Localized sidebar section headings (key → display), keyed by locale.
  sectionLabels: {
    "ja-JP": {
      "Getting started": "はじめに",
      Guides: "ガイド",
      Reference: "リファレンス",
    },
  },
  // Localized UI strings. en-US is the built-in default; ja-JP overrides only what it changes.
  labels: {
    "ja-JP": {
      onThisPage: "このページの内容",
      navigation: "ナビゲーション",
      searchPlaceholder: "検索…",
      copyMarkdown: "Markdown をコピー",
      viewMarkdown: "Markdown を表示",
      openInChatGPT: "ChatGPT で開く",
      openInClaude: "Claude で開く",
      previous: "前へ",
      next: "次へ",
      search: "検索",
      noResults: "該当する結果がありません",
      notTranslated: "このページはまだ翻訳されていません。英語版を表示しています。",
    },
  },

  // No embedder → zero-dependency lexical search (CJK locales use Intl.Segmenter for
  // word splitting automatically). Deploys to Cloudflare Workers out of the box.
});
