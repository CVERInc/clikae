---
title: macOS での Claude Code
description: clikae に影響する（あるいは影響しているように*見える*だけの）macOS 固有の Claude Code の挙動と、その対処方法。
section: Guides
order: 3
---

# メモ：macOS での Claude Code

clikae に影響する（あるいは影響しているように*見える*だけの）、macOS 固有の
Claude Code の挙動を 2 つ記録しておきます。どちらも、2026-05-29 に実機のデュアル
アカウント Mac で `clikae migrate` をドッグフーディングしている最中に見つかり、
その後 Claude Code 2.1.156 のバイナリから裏付けを取ったものです。次に同じ現象に
出くわした人が原因を一から追わなくて済むよう、ここに残しておきます。

ひとことで言うと、こうです。**macOS では、Claude のプロファイルは
`CLAUDE_CONFIG_DIR` だけで完全に表現されるわけではありません。ログイントークンは
Keychain にあり、起動画面は `.claude.json` 内のカウンターによって決まります。
clikae が設定するのは `CLAUDE_CONFIG_DIR` だけで、そのどちらにも一切手を触れません。**

---

## 1. ログイントークンは、config-dir の*パス*をキーにして Keychain に保存される

### 起こること

手作りの `~/.claude-acct-*` 構成を `clikae migrate` で取り込んだあと、移行した各
プロファイルを開くと、設定・履歴・プロジェクトがすべてきれいに移っているのは
見て取れるのに、**もう一度ログイン**を求められます。

### 根本原因

macOS では、Claude Code は OAuth トークンを `CLAUDE_CONFIG_DIR` の**中には**
保存しません。**ログイン用 Keychain** に保存し、そのサービス名は config-dir の
パスをキーにして付けられます。

```
Claude Code-credentials-<suffix>
```

ここで `<suffix>` は `sha256(<末尾スラッシュなしの絶対 CLAUDE_CONFIG_DIR>)` の
先頭 8 桁の 16 進文字です。（サフィックスなしの `Claude Code-credentials` は、
デフォルトの `~/.claude` を指します。）

`migrate` は config dir を新しいパスへ*移動*します。するとハッシュが変わるため、
Claude は新しい keychain キーを探しに行き、そこには何もないので、ログインを
求めてきます。トークンは移動したディレクトリと一緒には**移動しません**。古い
keychain エントリは取り残されます（無害です）。

メンテナの Mac で確認した結果は次のとおりです。

| Config dir | Keychain サフィックス |
|---|---|
| `~/.claude-acct-a` | `739359e9` |
| `~/.claude-acct-b` | `a646a362` |
| `~/.clikae/profiles/claude/a` | `bb827224` |
| `~/.clikae/profiles/claude/b` | `30621b40` |

自分でも確かめられます。

```bash
# 任意の config dir に対するサフィックス:
printf '%s' "$HOME/.clikae/profiles/claude/b" | shasum -a 256 | cut -c1-8
# いま keychain にあるエントリ:
security dump-keychain 2>/dev/null | grep -o '"Claude Code-credentials[^"]*"' | sort -u
```

### clikae の対応

- **デフォルト:** 何もしません。移行したプロファイルごとに一度ログインするだけです。
  これは一度きりのコストで、新規の `clikae init` ＋ログインには影響しません
  （プロファイルのパスごとに専用の keychain スロットが割り当てられます。これこそが、
  アカウント同士が衝突しない理由です）。
- **オプトイン:** `clikae migrate --keep-login` は、移動の一環として、古いパスの
  keychain エントリに保存されたトークンを新しいエントリへコピーするので、セッションが
  維持されます。これは `lib/adapters/claude.sh` 内のオプションのアダプタフック
  （`adapter_migrate_credentials`）として実装されており、デフォルトでは無効です。
  トークンが Keychain の外に出ることはありません。macOS からアクセス許可を求められる
  ことがあります。

すでに移行が完了した*あと*に復旧したい場合は（このフックは移動中にしか動きません）、
プロファイルごとに一度ログインするだけで済みます。あるいは、スロットを手動でコピー
することもできます。

```bash
old="Claude Code-credentials-$(printf '%s' "$HOME/.claude-acct-b" | shasum -a 256 | cut -c1-8)"
new="Claude Code-credentials-$(printf '%s' "$HOME/.clikae/profiles/claude/b" | shasum -a 256 | cut -c1-8)"
secret=$(security find-generic-password -s "$old" -w) \
  && security add-generic-password -a "$USER" -s "$new" -l "$new" -w "$secret" -U
secret=
```

---

## 2.「Welcome back」ボックスとコンパクトなロゴの違いは、clikae のせいでは**ない**

### 起こること

移行したプロファイル（あるいは「よく使い込まれた」プロファイル）は、**コンパクト**な
3 行ロゴ（ロボット・`Claude Code vX`・モデル・cwd）で開くのに、別のプロファイルは
**フルの welcome ボックス**（`Welcome back <name>!` ＋アカウント＋ *Tips for getting
started* ＋ *What's new*）で開きます。これを見ると、移行でプロファイルが「格下げ」
されたように見えてしまいます。

実際にはそうではありません。この 2 つは、Claude Code 自身の「お知らせ疲れ」ロジックの
うえで、ただ違う段階にいるだけです。

### 根本原因（2.1.156 のバイナリから確認）

起動ヘッダーは、コンパクトかフルかを、実質的に次のように選びます。

```js
if (!hasReleaseNotes && !O && !env.CLAUDE_CODE_FORCE_FULL_LOGO) return <compact logo>
else <full welcome box>
```

- `hasReleaseNotes` — `.claude.json` の `lastReleaseNotesSeen` が実行中のバージョンと
  異なる間だけ true になります。
- `O` — その他のお知らせ。とくに Opus 4.8 のローンチバナーで、
  `opus48LaunchSeenCount < 8`（バイナリの定数 `k9O = 8`）でゲートされ、描画のたびに
  カウンターが増えます。
- `CLAUDE_CODE_FORCE_FULL_LOGO` — フルボックスを強制する環境変数です。

`firstParty` 判定（`Zq()`）が読むのは環境変数（`CLAUDE_CODE_USE_BEDROCK` など）だけで、
パスは一切見ません。

**入力はどれも `.claude.json` 内のカウンターか環境変数であって、config-dir のパスは
一つもありません。** `migrate` は `.claude.json` をバイト単位でそのまま移すので、
同じファイルは古いパスでも新しいパスでも同じヘッダーを描画します。プロファイルが
コンパクトロゴになるのは、Opus 4.8 バナーを 8 回見て、*かつ*
`lastReleaseNotesSeen` が現在のバージョンと一致したとき、つまり新しく知らせるべき
ことがもう何も残っていないときです。その状態は実際の利用を通じて積み上がるもので、
移動がそれを作り出したり変えたりすることはありません。

### 調整方法

- プロファイルにフルボックスを強制する（きれいで公式な環境変数）:

  ```bash
  CLAUDE_CODE_FORCE_FULL_LOGO=1 CLAUDE_CONFIG_DIR="$HOME/.clikae/profiles/claude/b" claude
  ```

  これを実行してボックスが戻ってくること自体が、*パス*が原因ではなかった証拠です。
  同じディレクトリ、同じ `.claude.json`、違うのは環境変数だけです。

- そのプロファイルの `.claude.json` で `opus48LaunchSeenCount` を下げれば、
  Opus 4.8 バナーをもう一度出せます。

---

これらは意図的に*メモ*であって、ロードマップ項目ではありません。clikae の契約は
「CLI の設定用環境変数を設定する、それ以上はしない」であり、どちらの挙動も完全に
Claude Code の内側にあります。ここで clikae が手を加える唯一のものは、§1 のオプト
イン式の keychain 引き継ぎだけです。
