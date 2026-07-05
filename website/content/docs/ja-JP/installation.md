---
title: インストール
description: Homebrew またはインストールスクリプトで clikae を導入。純粋な bash で、ランタイムは不要です。
section: Getting started
order: 2
---

# clikae をインストールする

`clikae` は純粋な bash（3.2 以降に対応）で書かれており、Python や Node のランタイムは要りません。お好みの方法を選んでください。

## Homebrew（おすすめ）

```bash
brew install CVERInc/clikae/clikae
```

これで [`CVERInc/homebrew-clikae`](https://github.com/CVERInc/homebrew-clikae) を tap し、formula をインストールします。タグ付きリリースではなく最新の `main` を追いかけたいときは `--HEAD` を付けてください。更新は `brew upgrade clikae` です。

## ソースから

```bash
git clone https://github.com/CVERInc/clikae.git
cd clikae
./install.sh                 # installs to ~/.local
```

システム全体にインストールする場合は次のようにします。

```bash
PREFIX=/usr/local sudo ./install.sh
```

`install.sh` はツリー一式を `$PREFIX/share/clikae` にコピーし、`$PREFIX/bin/clikae` へのシンボリックリンクを張ります。それ以外、システムには一切手を加えません。

## `curl | bash`

```bash
curl -fsSL https://raw.githubusercontent.com/CVERInc/clikae/main/install.sh | bash
```

これは同じ `install.sh` を `~/.local` に対して実行します。スクリプトをそのまま bash に流し込むのが気になるなら、先に中身を読んでみてください。すべての行を確認できます。

## clikae を PATH に通す

`install.sh` はランチャーを `$PREFIX/bin/clikae` に置きます。そのディレクトリが `PATH` に入っていることを確認してください。

```bash
# ~/.local install
export PATH="$HOME/.local/bin:$PATH"   # add to your shell rc if not already there

# verify
clikae version
clikae info        # shows resolved install paths + profile counts
```

## アンインストール

```bash
rm "$PREFIX/bin/clikae"            # the symlink (e.g. ~/.local/bin/clikae)
rm -rf "$PREFIX/share/clikae"      # the program tree
```

プロファイルは `~/.clikae/` の下に独立して保存されており、そのまま残ります。アンインストール前に `clikae remove <cli> <profile>`（エイリアスや `.app` ランチャーも併せて片付けます）で削除するか、シェルの rc からエイリアスを取り除いたあとに `~/.clikae/` を手作業で消してください。
