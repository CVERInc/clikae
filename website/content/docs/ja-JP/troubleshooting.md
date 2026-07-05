---
title: トラブルシューティング
description: clikae でよくある問題への対処法。
section: Reference
order: 2
---

# トラブルシューティング

## `clikae: command not found`

ランチャーのシンボリックリンクが `PATH` 上にありません。`install.sh` はそれを
`$PREFIX/bin/clikae`（既定は `~/.local/bin/clikae`）に置きます。そのディレクトリを
シェルの rc ファイルで `PATH` に追加してください。

```bash
export PATH="$HOME/.local/bin:$PATH"
```

そのうえで新しいシェルを開くか、rc を `source` してください。`clikae info` で確認できます。
これは解決されたインストールパスを表示します。

## 新しいエイリアスが効かない

エイリアスはシェルの rc ファイルに書き込まれ、それはシェルの起動時にしか読まれません。
`clikae init … --alias`（または `clikae alias …`）のあとは、新しいターミナルを開くか、
rc ファイルを読み直してください。

```bash
source ~/.zshrc        # or whichever rc clikae reported writing to
```

clikae は `$SHELL` から rc ファイルを選びます。

| シェル | rc ファイル |
|---|---|
| zsh | `~/.zshrc` |
| bash（macOS、存在する場合） | `~/.bash_profile` |
| bash（それ以外） | `~/.bashrc` |
| その他 | `~/.profile` |

エイリアスが別のファイルにある場合（たとえば、すべてを `~/.zprofile` にまとめている等）は、
clikae が書き込んだファイルから clikae のブロックを source するか、センチネルで囲まれた
ブロックを手で移してください。

## 切り替えは効くのにエンジンが起動しない：「'claude' isn't installed」

clikae が切り替えるのは**アカウント／設定**であって、土台となる CLI を**インストール
しません**。エンジンのバイナリが `PATH` 上にないタンクに切り替えると、clikae はタンクを
設定したうえで、素の `exec: …: not found` ではなく、はっきりしたメッセージで止まります。

```
Switched to claude/work, but 'claude' isn't installed (not on your PATH).
Install it, then retry:  npm install -g @anthropic-ai/claude-code
```

エンジンをインストールし（例：`npm install -g @anthropic-ai/claude-code`、
`npm install -g @openai/codex`）、タンクを再度実行してください。インストール済みなのに
clikae が見つけられない場合、ランチャーがおそらく**非ログイン**シェルを使っています。
インストール先ディレクトリ（`~/.local/node/bin`、`/opt/homebrew/bin`、…）が、clikae を
実行するシェルの PATH 上にあることを確認してください。ログインシェル（`zsh -l`）は rc を
source するので、`.app`／Dock ランチャーは `zsh -lc` を実行すべきです — clikae 自身の
`.app` ランチャーはそうしています。

## `.app` が開かない：「cannot be opened because it is from an unidentified developer」

ランチャーはローカルで `osacompile` によりコンパイルされ、**コード署名も公証もされて
いません**ので、macOS の Gatekeeper が初回起動時にブロックします。自分のマシン上で
アプリをビルドするツールでは、これは想定どおりです。開くには：

- **`.app` を右クリック（または Control クリック）→ 開く → 開く。** これは各ランチャーに
  つき一度だけ行えばよく、以降はダブルクリックで動きます。
- または：システム設定 → プライバシーとセキュリティ → ブロックされたアプリの通知まで
  スクロール → **このまま開く**。

## `clikae app` が「osacompile not found」で失敗する

`osacompile` は macOS に付属しています。それが見つからないなら、ほぼ確実に macOS では
ありません — `app` コマンドは macOS 専用です。代わりに `clikae alias`（シェルエイリアス）
または `clikae run` を使ってください。

## `clikae app` が既存のランチャーの上書きを拒む

仕様どおりです — clikae はあなたのファイルを黙って上書きすることが決してありません。
置き換えるには `--force` を付けて再実行してください。

```bash
clikae app claude work --force
```

## `aws` プロファイルが切り替わらない

AWS アダプタは `AWS_PROFILE` を使います。これは既存の `~/.aws/config` から*名前付き
プロファイル*を選ぶもので、隔離された config ディレクトリを作る**わけではありません**。
`clikae init aws work` は、対応する `[profile work]` セクションが `~/.aws/config` に
すでに存在することを前提とします。なければ追加してください（あるいは `lib/adapters/aws.sh`
の冒頭に記載された `env-file` 方式を使ってください）。

## プロファイルを削除したのに残骸が残る

`clikae remove` は、プロファイルディレクトリ、エイリアスブロック、`.app` を削除します —
それぞれ存在する場合のみ、それぞれ独立に。何かが生き残った場合：

- **エイリアスが rc に残っている：** clikae が管理するのは、自身のセンチネル
  （`# >>> clikae:<cli>.<profile> >>>` … `# <<< … <<<`）で囲まれたブロックだけです。
  そのマーカーの外にある手編集・手書きのエイリアスは、あなたが削除するために残されます。
- **`.app` がカスタムの場所にある：** `--out <dir>` で作った場合は、そのディレクトリから
  手で削除してください。
- `--keep-data` を使いましたか？ それは意図的に `~/.clikae/profiles/` 配下のプロファイル
  ディレクトリを残します。

## `clikae migrate` で実行中のセッションが壊れた／移したディレクトリが空で再出現した

`migrate` は config ディレクトリを `~/.clikae/profiles/` へ*移動*します。CLI がその時点で
そのディレクトリを実際に使っていた場合 — 典型例は、まさにその `CLAUDE_CONFIG_DIR` が
移動対象になっている `claude` セッションの中から `clikae migrate` を実行したケース — 稼働中
プロセスは自分のディレクトリを失い、元のパスに空のディレクトリを作り直すことがあります。
結果として、本物のデータが `~/.clikae/profiles/<cli>/<p>/` 配下に、はぐれた空ディレクトリが
元の場所に、という状態になります。

これを避けるには：**その CLI のインスタンスが一つも動いていない、まっさらなシェルから
`migrate` を実行してください。** `clikae migrate --dry-run` は何も移動しないので、自由に
プレビューできます。v0.4 以降、`migrate` は、稼働中の `$CLAUDE_CONFIG_DIR`（またはアダプタの
環境変数）がこれから移動するディレクトリを指している場合、はっきりと拒否もします — なので
最もよくある引き金は、状態を壊す代わりにはっきりしたメッセージで止まるようになりました。

すでに起きてしまった場合の回復法：影響を受けた CLI を終了し、はぐれた空の古いディレクトリを
（空であることを確認してから）削除し、シェルの rc を読み直してください — 書き換えられた
エイリアスは、すでに移行済みのプロファイルを指しています。

## `clikae migrate` のあと、claude がまたログインを求めてくる（macOS）

想定どおりです。macOS では、Claude Code はログイントークンを `CLAUDE_CONFIG_DIR` の中
ではなく**ログイン Keychain** に保管します — しかもキーチェーンのエントリは config
ディレクトリの*パス*をキーにしています（`Claude Code-credentials-<sha256(path)[:8]>`）。
`migrate` はディレクトリを新しいパスへ移すので、claude は新しいキーチェーンキーの下を探し、
何も見つからず、ログインを求めます。設定、履歴、プロジェクトはすべて問題なく移っています。
保存されたログインだけがついてこなかったのです。

対処は二通り：

- **最も簡単：** 移行した各プロファイルを一度開いて、ログインし直すだけ。移行前のパスに
  対応する古いキーチェーンエントリは、いまや孤立して無害です。残しても、Keychain
  Access で削除してもかまいません。
- **そもそも避ける：** `clikae migrate --keep-login` を実行すると、移動の一環として、古い
  パスのキーチェーンエントリから保存済みトークンを新しいほうへコピーします（macOS のみ）。
  トークンが Keychain から出ることはありません。macOS がキーチェーンアクセスの許可を
  求めるダイアログを出すことがあります — それは想定どおりです。

`--keep-login` なしですでに移行してしまった場合、それを付けて再実行しても効きません：
`migrate` はすでに移したプロファイルをスキップするので、引き継ぎの手順が走らないからです。
プロファイルごとに一度ログインし直すだけ — それが最も簡単な道です。

詳しい経緯（キーチェーンキーの形式、手動での回復）は
[Claude on macOS](claude-on-macos) にあります。

## 移行後、claude の起動画面の見た目が変わった（macOS）

移行したプロファイルが**コンパクト**なロゴで開く一方、別のプロファイルは**フルの
ウェルカムボックス**（`Welcome back …` ＋ Tips ＋ What's new）を表示することがあります。
これは clikae や移動が原因では**ありません**。Claude Code は、そのプロファイルの
`.claude.json` 内のカウンター（現在のリリースノートと Opus 4.8 のバナーをすでに見たか）と
`CLAUDE_CODE_FORCE_FULL_LOGO` 環境変数からヘッダーを選びます — config ディレクトリの
パスからではありません。よく使い込まれ、すでに告知を見たプロファイルはコンパクトな
ロゴを表示します。その状態はディレクトリとともにそのまま移っただけです。フルのボックスを
強制するには `CLAUDE_CODE_FORCE_FULL_LOGO=1` を設定してください。詳細と逆コンパイルした
ロジックは [Claude on macOS](claude-on-macos) に。

## シェルの rc への変更を取り消したい

rc への編集はすべて、rc ファイルの隣の `<rc>.clikae.bak.<timestamp>` にまずバックアップ
されます（例：`~/.zshrc.clikae.bak.20260605-143000`）。最新のバックアップを復元します。

```bash
cp ~/.zshrc.clikae.bak.<timestamp> ~/.zshrc
```

## 開発／テストの実行

clikae は Node 非依存を保ちます。ローカルでのチェックには `shellcheck` と `bats` を
使います。

```bash
brew install shellcheck bats-core
shellcheck bin/clikae lib/**/*.sh install.sh
bats tests/bats
```

完全な検証レシピ（あなたの本物の `$HOME` に触れない、隔離されたエンドツーエンドの実行を
含む）は [HANDOFF.md](../HANDOFF.md) §6 を参照してください。
