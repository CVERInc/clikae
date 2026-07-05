---
title: 使い方
description: clikae という動詞、タンク、エンジン、そしてホームボード。
section: Getting started
order: 3
---

# clikae を使う

**clikae はそれ自体が動詞**です（切り替え、*switching*）。中心となる操作には専用の動詞がありません。プログラム名そのものが動詞です。

```bash
clikae <engine> <tank>      # switch <engine> to <tank> and run it
```

`<engine>` はアダプタを備えた CLI（`clikae adapters` で一覧）、`<tank>` は 1 つのアカウントや設定に付ける、あなたが決める名前です（使える文字は `A-Z a-z 0-9 . _ -`）。全体を通して燃料のたとえが流れています。タンクはエンジンのクォータ（その*燃料*）を蓄え、タンクが*空*になったら `clikae to` で作業を次へ運んでいきます。

コマンドごとの詳しいリファレンスは `clikae help <command>` で見られます。言語の設計全体は [grammar.md](grammar) にまとめてあります。

## クイックツアー

```bash
# Create a tank for Claude Code, and add the matching shell alias
clikae init claude work --alias

# Switch to it and run — the bare verb (no `run` needed)
clikae claude work
clikae claude work -- --help    # args after -- go straight to the engine

# Or pick up the alias and use that
source ~/.zshrc                 # or your rc file
claude-work

# Generate a macOS launcher you can double-click from ~/Applications
clikae app claude work

# See what you've got
clikae tanks                    # alias: clikae list
#   ENGINE       TANK
#   claude       work
clikae tanks -p                 # also print the tank directory paths

# Tear it all down (tank dir + alias + .app, asks to confirm)
clikae remove claude work
```

## コマンド

clikae 自体が動詞なので、**切り替えに動詞は要りません**。管理系のコマンドは、ふつうの素直な動詞をそのまま使います。

### 切り替え（いちばん大事なところ）

| コマンド | 役割 |
|---|---|
| `<engine> <tank> [-- args]` | `<engine>` を `<tank>` に切り替えて実行します。これがむき出しの動詞です。（`run` は隠しエイリアスです。） |
| `<engine> <tank> --ephemeral` | 切り替えて、**揮発する記憶（ephemeral memory）**で実行します。このセッションの長期記憶は使い捨てで、終了時に破棄されます。タンク本来の記憶には触れません。ログインとトランスクリプトは通常どおりです。claude のみ対応（clikae が記憶のレイアウトを把握している必要があります）。詳しくは後述します。 |
| `<engine>` | タンクが 1 つ → それを使います。複数 → 一覧表示します。なし → 作成を提案します。 |
| `to <target> [tank] [-- args]` | **このシェルの現在のセッション**を別のタンクへ運びます。同じエンジン → 本物のレジューム。別のエンジン → 書き起こしたブリーフ（コールドスタート）。clikae がどちらかを知らせます。ソースは自動検出します（環境変数、なければこのディレクトリで直近のセッション）。relay の `-y`/`--fresh`/`--session` をそのまま渡します。（`relay`/`handoff`/`continue` は隠しエイリアスです。） |
| `eval "$(clikae env <engine> <tank>)"` | **現在のシェル**をタンクに固定します（その設定の環境変数をエクスポートします）。これでエンジン自身のコマンドや `clikae status`/`to` がそれを認識します。一発のむき出し切り替えに対する、明示的な代替手段です。 |

### タンクを作る・管理する

| コマンド | 役割 |
|---|---|
| `init <engine> <tank> [--alias]` | タンクのディレクトリを作成します。`--alias` を付けるとシェルのエイリアスも書き込みます。 |
| `remove <engine> <tank> [--force] [--keep-data]` | ディレクトリ + エイリアス + `.app` を削除します。`--keep-data` はディレクトリを残します。 |
| `rename <engine> <old> <new> [--force]` | タンクの名前を変更します（ディレクトリを移動し、エイリアスを書き換え、ログインを引き継ぎます）。 |
| `migrate [<engine>] [--dry-run] [--force] [--keep-login]` | 手作業で組んだ設定ディレクトリ + エイリアスの構成を取り込みます。 |
| `alias <engine> <tank> [--name <n>]` | シェルのエイリアスを書き込みます（または置き換えます）。既定の名前は `<engine>-<tank>` です。 |
| `app <engine> <tank> [--terminal <app>] [--force] [--out <dir>]` | macOS の `.app` ランチャーを生成します（既定は `~/Applications`）。macOS のみ。`--terminal`：`terminal`（既定）、`iterm2`、`ghostty`。 |
| `app --board [--terminal <app>] [--force] [--out <dir>]` | 1 つのタンクではなく**ボード**（直近のセッション + タンクのメニュー）を開く `clikae.app` を生成します。入口の全体を、ダブルクリック 1 つのボタンにまとめます。 |

> **Ghostty のランチャー**は、コマンドを `-e` ではなく信頼された Ghostty の**設定ファイル**（`--config-file=`）経由で渡します。Ghostty は外部から注入された `-e` コマンドに対して「Ghostty にこの実行を許可しますか？」というダイアログを出すため、`-e` のランチャーは Allow を押すまで空のシェルのように見えます。設定ファイルは信頼されているので、ウィンドウはそのまま開きます。この設定は `.app` の中に置かれ、`path to me` 経由で見つかるので、ランチャーを移動しても動き続けます。

### タンクが空になっても燃やし続ける

| コマンド | 役割 |
|---|---|
| `to [target] [tank]` | タンクが空になったとき、このシェルのセッションを次へ運びます。**むき出しの `clikae to`** は、あなたの burn order（消費順）で次のタンクへ自動的に流れます（同じエンジン → 本物のレジューム、別のエンジン → コールドスタートのブリーフ）。あなたのタンク群がそのまま予備タンクです。設定するものは何もありません。 |
| `auto [ask\|safe\|full]` | **（BETA、claude 起動のセッションのみ）** **`clikae` 経由で起動した**セッションが上限に達したとき、clikae がどこまで自前で運ぶかを決めます。エイリアス/`.app`/他エンジンからの起動には効きません。`ask`（既定）は確認します。`safe` は同一エンジンを自動でレジュームし、エンジンをまたぐときは確認します。`full` はそのまま進めます（同一エンジン = レジューム、エンジンまたぎ = コールドのブリーフ）。ボードの `A` キーで切り替えられます。 |
| `watch <engine> [<tank>] [--auto] [--to <target>]` | セッションを見張り、空になったら burn order の次のタンクへ流れます（エンジンまたぎは `--to` で）。 |
| `burn <engine> <tank> --artifact <path> -- <cmd…>` | タンク上で**ヘッドレス**のタスクを実行し、終了コードではなく成果物（artifact）で完了を確認します。タンクが空なら、同じタスクを次の予備タンクで撃ち直します。`to`/`watch` のヘッドレス版にあたります。下の「ヘッドレスタスク」を参照してください。 |

> **監督付き起動（BETA・claude・フィードバック歓迎）。** claude を clikae *経由で*起動すると、clikae が親プロセスとして残り続けます。**そのセッションが上限に達して終了したとき** — 対話実行なら死んだセッションを終了させ、ヘッドレスの `claude -p` は自分で終了します — clikae が `clikae auto` の設定に従って、**同じターミナル**であなたを burn order の次のタンクへ運び（再描画 1 回）、会話はそこで続きます。正直に言うと、進むのは*終了時*であって、稼働中のセッションを途中で殺すわけではありません（それにはエンジン側の対応が必要です。issue anthropics/claude-code#35744 を参照）。1 回の実行につき 1 ホップ。対話モードの **codex** は（ファイルの手がかりがなく）自動検出できないため、今のところ claude 専用です。clikae 経由で起動したものでない限り、バックグラウンドでは何も動きません（デーモンなし）。これは意図的な設計です。何を運んだか（直近の引き継ぎ）は `clikae status` で確認できます。**使い心地をぜひ教えてください。**

### 状態を見る

| コマンド | 役割 |
|---|---|
| *(引数なし)* | **ホームダッシュボード**、いわば「タンクボード」を開きます。エンジンごとにまとめたすべてのタンク、このシェルでアクティブなもの、アカウント + エイリアス名、そしてタンクなしで開けるエンジン/ターゲットの「Also available」一覧（例：`codex`、`agy`）が並びます。ターミナル上では**対話式のランチャー**になります。`?` で全キーの凡例が出ます。キー操作：↑/↓・`j`/`k`・Tab/Shift-Tab で移動、`g`/`G` で先頭/末尾、`1`〜`9` でジャンプ、⏎ で開く（Continue 行では _resume_ か _switch fresh_ を選べます）、`r` でセッションを運ぶ、`x` でシークレット、`n` で新規、`a` でタンク名を変更、`d` で削除、`/` で絞り込み、`l` で言語選択、`q`/Esc で終了。パイプ/スクリプト経由では同じボードをプレーンテキストで出力します（`CLIKAE_NO_INTERACTIVE` で強制できます）。 |
| `lang [en-US\|ja-JP\|zh-TW]` | インターフェースの言語（ダッシュボード + プロンプト）を表示・設定します。`$CLIKAE_HOME/lang` に保存され、ボードの `l` キーで言語ピッカーが開きます。未設定時の解決順は `$CLIKAE_LANG` > 保存された選択 > `$LC_ALL` > `$LANG` > en-US です。 |
| `tanks [-p\|--paths] [--json]` | すべてのタンクを一覧表示します。アダプタが判別できる場合はログイン中のアカウントも示します。（エイリアス：`list`、`ls`。）`--json` は機械可読な出力（`{cli, profile, account, path}`）を出し、スクリプトや GUI 向けです。 |
| `status [<engine>] [--json]` | **このシェルで**各エンジンがどのタンクにいるかを表示します。`--json` は `state` enum を持つオブジェクトをエンジンごとに 1 つ出します。 |
| `doctor` | 読み取り専用のヘルスチェック。対応エンジンのどれがインストール・ログイン済みか、それぞれのタンク数、環境、次に何をすべきかを表示します。 |
| `info [--json]` | インストールパス、プラットフォーム、アダプタ、タンク数を表示します。 |
| `adapters` | 対応エンジンを説明付きで一覧表示します。 |
| `demo` | 使い捨てのサンドボックスでの 30 秒ガイドツアー。隔離されたタンク、タンクボード、`to` の考え方（あなたのタンク群が予備）を見せたあと、後片付けします。本物には一切触れず、アカウントもシミュレーションなので、エンジンのインストールは不要です。 |

### Antigravity（agy）— 同じ動詞、1 つのパワーモード

agy は `~/.gemini` をハードコードしていて環境変数を無視するため、clikae は他のエンジンのようにシェルごとに切り替えることができません。それでも、オプトインのシンボリックリンク入れ替え（パワーモード）によって、**同じ動詞**の中に収まります（グローバル：すべてのターミナルを通じて一度に 1 つのタンクのみアクティブ。元に戻せます）。

| コマンド | 役割 |
|---|---|
| `init agy <tank>` | 初回：警告し、`~/.gemini` を引き継いでよいか確認してから（バックアップを取り、現在のログインを `default` タンクへ移行）、`<tank>` を作成します。2 回目以降：単にタンクを作成します。 |
| `agy <tank>` | アクティブなタンクを切り替え（agy が動作中なら拒否します）、agy を起動します。グローバル切り替えの通知を表示します。 |
| `remove agy <tank>` | タンクを削除します。**最後の**タンクを削除するときは、通常の `~/.gemini` への復元とパワーモードの解除を提案します。 |
| `agy --release` | アクティブなタンクから通常のシングルアカウント `~/.gemini` を復元し、タンクのディレクトリは残します。 |

## シェル

`clikae` は `$SHELL` からあなたのシェルを自動検出し、正しい rc ファイルにエイリアスを書き込みます。**zsh**（`~/.zshrc`）、**bash**（macOS では `~/.bash_profile`、それ以外は `~/.bashrc`）、**fish**（`~/.config/fish/config.fish`）に対応します。fish に対しては fish の構文 — `alias <name> 'env VAR=val <binary>'` — を出力します。fish にはインラインの `VAR=val cmd` がないためですが、結果としての挙動は同じです。`clikae remove` はいずれのシェルでもそのブロックを片付けます。

## 既存の構成を移行する

すでにアカウントを手作業でやりくりしている — たとえば `~/.claude-acct-a` / `~/.claude-acct-b` のペアを `~/.zshrc` のエイリアスで使い分けている — としましょう。`clikae migrate` はそれを clikae に取り込みます。

```bash
clikae migrate --dry-run   # preview: which dirs move where, which aliases change
clikae migrate             # do it (asks to confirm first)
```

シェルの rc を走査して、エンジンの設定環境変数を立ててエンジンを呼び出しているエイリアスを探します。見つけたものごとに、次を行います。

1. 参照している設定ディレクトリを `~/.clikae/profiles/<engine>/<p>/` の下へ移動し、
2. エイリアスを clikae 管理のセンチネルブロックに書き換えます。

rc ファイルはまず `<rc>.clikae.bak.<timestamp>` にバックアップされ、既存の clikae タンクが上書きされることは決してありません。別のツールのエイリアスを移行するにはエンジン名を渡します（`clikae migrate gh`）。既定は `claude` です。

> ⚠️ **使用中の設定ディレクトリは移行しないでください。** `migrate` はディレクトリを*移動*します。そのため、いままさにそれに対してプロセスが動いている場合（たとえば `CLAUDE_CONFIG_DIR` が移動対象を指している、まさにその `claude` セッションの中から `clikae migrate` を実行した場合）、稼働中のプロセスの足元からディレクトリを抜き取ってしまいます。書き込みに失敗したり、元のパスに空のディレクトリを作り直したりして、中途半端な状態が 2 つ残ることがあります。`migrate` は、そのエンジンのインスタンスが動いていない、まっさらなシェルから実行してください。`--dry-run` は常に安全です。
>
> v0.4 以降、`migrate` はこの最もよくある形を防ぎます。`$CLAUDE_CONFIG_DIR`（またはアダプタが使ういずれかの環境変数）が移動予定のディレクトリを現在指している場合、実行を拒否し、まっさらなシェルからやり直すよう伝えます。このガードは `--force` でも回避できません。これはあなたのデータを守るためのもので、確認のためのプロンプトではありません。

> 🔑 **macOS + claude：移行したタンクごとに一度の再ログインを見込んでください。** macOS では、Claude Code はログイントークンを `CLAUDE_CONFIG_DIR` の中ではなく**ログインキーチェーン**に保存します。そしてそのキーチェーンの項目は設定ディレクトリのパスをキーにしています。`migrate` がディレクトリを新しいパスへ移動するため、claude はトークンを見つけられなくなり、移行したタンクごとに一度ログインを求めます。データは無傷で、移動についていかないのは保存済みのログインだけです。再ログインを避けたい場合は `--keep-login` を渡してください。これは旧パスのキーチェーン項目から保存済みトークンを新しい項目へコピーします（macOS のみ。トークンをどこかへ読み出したり送信したりすることは決してなく、キーチェーンの中に留まります）。macOS がキーチェーンへのアクセス許可を求めることがあります。

## 使用上限に達したらセッションを運ぶ — `clikae to`

これこそが clikae の生い立ちです。1 つのアカウントのクォータが作業の途中で尽きるからこそ、2 つ目のアカウントを持っておく。`clikae to` は、まさに燃料タンクを差し替えるように作業を次へ運び、新しいクォータの上で**同じ会話を続けさせます**。

```bash
# You're working on claude tank `a` and just hit its limit. From the same project
# directory, carry the conversation onto another tank and keep going:
clikae to b                     # same engine → a real resume, on b's quota
clikae to codex                 # a different engine → a written brief (cold start)
clikae to codex work            # cross to a specific tank of another engine
```

clikae は、このシェルがどのエンジン + タンクにいるかを自動検出します。まず生きている環境変数を見て、次に — むき出しの切り替え/エイリアス/`.app` はエンジンを、親シェルに届かない前置代入付きで実行するため — **このディレクトリで直近のセッションを持つタンク**（ついさっきまでここにいたもの）を見ます。だから `switch → work → to` が 1 つのシェルで成り立ちます。代わりにシェルをタンクへ明示的に固定したい場合は `eval "$(clikae env <engine> <tank>)"` を使ってください。ターゲットは**エンジン名を優先して**解決されます。既知のエンジン名ならそこへ渡り、それ以外なら現在のエンジンのタンク扱いです。clikae は**どの仕組みを使ったかを必ず知らせる**ので、レジュームかブリーフかを推測する必要はありません。

**同じエンジン（レジューム）。** Claude Code の場合、clikae はソースタンクの下から**現在のディレクトリの**直近のトランスクリプトを見つけてターゲットタンクへコピーし、そこで `claude --resume <id>` を実行します。会話は続きますが、新しいやり取りはすべてターゲットタンクのクォータを消費します。ソースタンクには一切触れません（コピーするだけで、移動はしません）ので、いつでも戻れます。何かが動く前にプレビュー + 確認が表示されます。`-y` はそれを省き、`--fresh` は何も運ばずにタンクだけ切り替え、`--session <id>` は特定のセッションを運びます。

> 引き継ぎは Claude Code のディスク上のトランスクリプト構造（`<config-dir>/projects/<slug>/<id>.jsonl`）と `--resume` に依存しています。現行の Claude Code に対して検証済みです。将来のバージョンでこの構造が変わった場合は、破壊的なことをするのではなく、まっさらな状態からの開始にフォールバックします。

**別のエンジン（ブリーフ）。** 別の*モデル*やベンダーは、よそのセッションをレジュームできません。共通のトランスクリプト形式がないからです。そこで clikae は**引き継ぎブリーフ**（何をしているか、何が済んだか、次は何か）を書き起こし、それを冒頭のプロンプトとして種にしてターゲットエンジンを起動します。clikae は**要約**を自動で書こうとします。ローカルモデルの CLI が `PATH` にあれば（`apfel`、`ollama`、`llm`）、それを使ってブリーフを無料で要約します。`CLIKAE_HANDOFF_AUTOLOCAL=0` でこの自動検出を無効にできます。それ以外の場合、ブリーフは**生の抜粋**（セッションのメタデータ + あなたの最近のプロンプト）になり、生であることが明示されます。特定の要約器を使わせるには、clikae に任意のモデルを指定してください。そうすれば、ちょうど空になったタンク上でブリーフを書くコストがゼロになります。

```bash
export CLIKAE_HANDOFF_SUMMARIZER='llm -m my-local-model'   # any stdin→stdout command
clikae to codex                                            # the model writes the brief
```

要約器（自動検出されたものか `CLIKAE_HANDOFF_SUMMARIZER`）は、標準入力で指示行とそれに続くセッショントランスクリプトの末尾を受け取り、ブリーフを標準出力に書き出します。何も出力しなければ、clikae は生の抜粋にフォールバックするので、引き継ぎが失われることはありません。どれだけのトランスクリプトを渡すかは `$CLIKAE_HANDOFF_LINES`（既定 `60`）で調整します。次へ運ぶ動作はソースに対して**読み取り専用**で、ソースのセッションやどのタンクにも触れません。

> 内部では、`clikae to` は `relay`（同じエンジン）または `handoff`（別のエンジン）に委譲します。どちらも隠しエイリアスとして使えます。たとえば `clikae handoff claude --out HANDOFF.md` は、何も起動せずにブリーフをファイルに書き出すだけです。詳しくは `clikae help to` / `help relay` / `help handoff` を実行してください。

## アンビエント：空のタンクを察知して切り替える（`watch`）

手作業で切り替える代わりに、タンクが空になる瞬間を clikae に見張らせ、次のタンクへ流れさせましょう。**あなたのタンク群がそのまま予備で、用意するものは何もありません。** 今のセッションを見張るだけです。

```bash
clikae watch claude            # offer to switch to the next claude tank when dry
clikae watch claude --auto     # switch automatically (asks once for consent)
clikae watch claude --to codex/work   # cross to a specific tank/engine instead
```

空のタンクを検知すると、同じエンジンの次のタンクへ運びます（それ自体がクォータ切れのものは飛ばします）。エンジンまたぎには明示的な `--to` が必要です。既定では**まず確認します**。`--auto` は**一度きりの同意**のあと自動で切り替え（同意は `$CLIKAE_HOME/auto-relay-consent` に記憶されます。取り消すにはそのファイルを削除してください）、何をしたかは常に伝えます。

> **正直な注意点。** 対話式のエンジンは使用上限に達しても終了せず、コードも返さず、フックも発火しません。だから clikae が見張れるのは、上限がディスクに書き残すものだけです。claude ならセッショントランスクリプト、agy なら `~/.gemini/antigravity-cli/cli.log`（agy の `-p` 実行は空の出力で 0 終了するため、ログ行だけが手がかりです）。codex の上限はトランスクリプトに**永続化されないことが確認済み**なので、codex についてはディスクから空のタンクを検知できません。実際に初めて上限に当たったとき、マッチを確認・調整してください。
>
> ```bash
> clikae watch claude --check          # would the pattern fire on this session?
> CLIKAE_LIMIT_PATTERN='…' clikae watch claude   # override the match
> ```

## タンクをまたぐヘッドレスタスク — `clikae burn`

`watch`/`auto` は*対話式*のセッションを運びます。*ヘッドレス*な力仕事 — 「安いタンクに汚れ仕事をさせる」ケース — には `clikae burn` を使います。これは 1 つのタスクをタンク上で実行し、肝心なことに、本当に終わったかどうかを把握します。確認には、タスクが必ず生み出すべき**成果物（artifact）**を使い、終了コードは決して当てにしません（`codex exec` は使用上限に当たって何も書かなくても 0 で終了します）。タンクが空だったら、*同じ*タスクを予備の次のタンクで撃ち直します。

```bash
# Distil a file with codex on tank M; if M is dry, fall through to your next
# codex tank automatically. Success = /tmp/out.md exists.
clikae burn codex M --artifact /tmp/out.md -- \
    exec -C /tmp -s workspace-write "read /tmp/in.txt, write /tmp/out.md"

clikae burn codex M --artifact /tmp/out.md --to codex/H -- exec … "<task>"   # explicit next hop
clikae burn codex M --artifact /tmp/out.md --timeout 300 -- exec … "<task>"  # bound a long run
```

結果：成果物あり → 完了。届く範囲のすべてのタンクが空 → 失敗。実行したが成果物を生まず、上限も出していない → 本物の**タスク失敗**（どこでも同じように失敗するので、ルーティングし直しません）。`--no-reroute` は一度だけ実行し、空のタンクで止まります。

`burn` は単一タスクの単位です。**バッチ処理や並列はあくまであなたのオーケストレーターの仕事**です（複数の `burn` を扇形に展開し、成果物を確認してください）。タスクは冪等で成果物チェック付き（入出力パスを固定）にし、入力は遅い iCloud バックアップの I/O をタンクに渡すのではなく、あらかじめ `/tmp` に置いておきましょう。

> **`burn` は、あなたが使っているクォータは消費しません。** 自動ルーティングは、対話式セッションが生きているタンク（さもなければ進行中の会話を燃やしてしまいます）と、すでに空のアカウントを共有するタンクを*飛ばします*。使用中スキップを上書きするには `--allow-active`、ホップを明示するには `--to <tank>` を渡してください。

**タンクは*クォータ*の供給源であって、中身そのものではありません。** `burn <engine> <tank>` はコマンドを動かすために*そのタンクのクォータ*を使います。コマンドが読み書きするのは単なるファイルで、タンクとは無関係です。だから、安いタンクのクォータを使って*どんな*ファイルでも — 別のタンクのトランスクリプトさえ — 噛み砕けます。

**agy を安い読み取り専用ワーカーとして使う。** agy は `burn` の*タンク*にはなれません（1 つのグローバルアカウントなので、ルーティングし合う予備がありません）が、ヘッドレスワーカーとしては優秀です。`burn` の予備ラッパーの外で、直接呼び出すだけです。

```bash
# agy as a summariser — content in via stdin, agy's own quota spent. Read-only.
cat /tmp/in.md | agy --sandbox -p "summarise this"  > /tmp/out.md

# …or through clikae, on a specific agy account (switches the global ~/.gemini
# symlink to tank R, then runs agy headless on R's quota):
clikae agy R -- -p "summarise this" --sandbox  < /tmp/in.md  > /tmp/out.md
```

ここでは `burn` の 2 つの保証を手放すことになります（空 → ルーティングなし。agy はアカウントが 1 つなので、空のままだと単に失敗します。成果物の検証もなし）。それから、`clikae agy` が切り替えるのはシェルごとの環境ではなく**マシン全体**のシンボリックリンクであること（そして agy には `--model` フラグがなく、モデルはアプリの設定であること）を覚えておいてください。

## どのタンクにいるかを確認する

```bash
clikae status            # every engine that has a tank
clikae status claude     # just one

#   ENGINE       TANK         ACCOUNT          SOURCE
#   claude       cver         hi@cver.net      CLAUDE_CONFIG_DIR=…/profiles/claude/cver
#   aws          (default)    -                AWS_PROFILE unset — system default
```

`status` は現在のシェルにおける各アダプタの環境変数の**生きた**値を読み、それを clikae のタンクへ逆引きします。これはシェルごとの見え方です。別のターミナル（あるいは別の `clikae app` から起動したもの）は、別のタンクにいることがあります。`(default)` は環境変数が未設定（エンジン自身の既定）を意味し、`(external)` は clikae のタンクではないどこかを指していることを意味します。ACCOUNT 列は、アダプタが判別できる場合にログイン中のアカウントを表示します。

## タンクの名前を付ける

タンクには、あなたにとって意味の通る名前を付けてください — `work`、`personal`、顧客名、あるいはアカウントのメールアドレスでも。素の `a`/`b` が何を指していたかを覚えておく必要はありません。`tanks` も `status` も、アダプタが読み取れる場合はログイン中の**アカウント**を表示します。

名前を考え直しましたか？ `clikae rename` はディレクトリを移動し、管理下のエイリアスを書き換え、そして — macOS の claude については — 保存済みのキーチェーンのログインを引き継ぐので、ログインし直す必要はありません。

```bash
clikae rename claude a cver        # a → cver; login + alias follow
```

新しい名前がすでに使われているか、そのエンジンがこのシェルでそのタンクを現在使っている場合は拒否します（まっさらなシェルから実行してください）。既存の `.app` ランチャーはそのまま残りますが、フラグが立ちます。`clikae app claude cver` で作り直してください。

## 揮発する記憶（`--ephemeral`）

外科的に、痕跡を残さない実行のために：`clikae claude work --ephemeral` はタンクに切り替えて実行しますが、エンジンの**長期記憶**を、エンジン終了時に破棄される使い捨てのディレクトリへ向けます。タンク本来の記憶は脇へ退避され、そのまま元へ戻されます。

```bash
clikae claude work --ephemeral     # incognito: nothing learned this session is kept
```

- **ログインとトランスクリプトは通常どおり**で、使い捨てなのは*記憶ストア*だけです（あなたはあなたのままで、会話も記録され、レジューム可能です）。
- **正直な範囲：** clikae が保証するのは*記憶ディレクトリ*が使い捨てであることだけです。エンジンが「どこにも何も覚えていない」とは約束できません。キャッシュ、シェルの履歴、テレメトリ、macOS のキーチェーンは clikae の手の届かないところにあります。だからこれは*揮発する記憶*であって、完全な記憶喪失を保証するものではありません。
- 記憶のレイアウトを clikae が把握しているエンジン（現在は **claude**）でのみ対応します。それ以外はその旨を伝えて終了します。
- 通常の切り替え（エンジンを `exec` します）と違い、`--ephemeral` は終了時に後片付けを走らせられるよう、エンジンを子プロセスとして実行します。クラッシュした実行は、次の `--ephemeral` で自己修復します（本来の記憶が退避先から復元されます）。

## 仕組み

各タンクについて、`clikae` は次を行います。

1. `~/.clikae/profiles/<engine>/<tank>/` を作成します。これがエンジンの環境変数（例：`CLAUDE_CONFIG_DIR`）の指すディレクトリです。（ディスク上のパスは安定性のために `profiles` という語を保ちますが、あなたが入力・目にするのは常に*タンク*です。）
2. （`alias`）シェルの rc にセンチネルで囲まれたブロックを追記します。
   ```
   # >>> clikae:claude.work >>>
   alias claude-work='CLAUDE_CONFIG_DIR="/Users/you/.clikae/profiles/claude/work" claude'
   # <<< clikae:claude.work <<<
   ```
   このセンチネルにより、安全で正確な削除が可能になります。
3. （`app`、macOS）AppleScript でコンパイルした `.app` を生成します。これはターミナルを開き、環境変数を前置したエンジンを実行し、ウィンドウのタイトルを `claude (work)` に設定して、ウィンドウを見分けられるようにします。ターミナルは既定で **Terminal.app** です。`--terminal iterm2` と `--terminal ghostty` はそれぞれを対象にします（既定を変えるには `$CLIKAE_TERMINAL` を設定してください）。Terminal.app と iTerm2 は AppleScript で駆動します。Ghostty には macOS でウィンドウを開く CLI がないため、そのランチャーは `open -na Ghostty.app --args … -e …` を経由します。

デーモンなし、グローバルな状態なし、ネットワーク呼び出しなし。すべての行を読めます。

## 対応エンジン

| エンジン | 戦略 | 環境変数 |
|---|---|---|
| `claude` (Anthropic Claude Code) | `env-dir` | `CLAUDE_CONFIG_DIR` |
| `codex` (OpenAI Codex CLI) | `env-dir` | `CODEX_HOME` |
| `gh` (GitHub CLI) | `env-dir` | `GH_CONFIG_DIR` |
| `gcloud` (Google Cloud CLI) | `env-dir` | `CLOUDSDK_CONFIG` |
| `docker` (Docker CLI) | `env-dir` | `DOCKER_CONFIG` |
| `helm` | `env-dir` | `HELM_CONFIG_HOME` |
| `kubectl` | `env-file` | `KUBECONFIG` |
| `aws` (AWS CLI) | `env-var` | `AWS_PROFILE` |
| `az` (Azure CLI) | `env-dir` | `AZURE_CONFIG_DIR` |
| `npm` | `env-file` | `NPM_CONFIG_USERCONFIG` |
| `terraform` | `env-file` | `TF_CLI_CONFIG_FILE` |
| `pulumi` | `env-dir` | `PULUMI_HOME` |
| `vercel` (Vercel CLI) | `flag` | — (`--global-config <dir>`) |
| `agy` (Google Antigravity) | opt-in symlink | — (hardcoded `~/.gemini`; see above) |

`flag` 戦略は、設定ディレクトリの環境変数を持たないエンジン向けです。エクスポートした変数の代わりに、生成されたエイリアス/`.app`/実行コマンドの中で、タンクのディレクトリをコマンドラインフラグ（例：vercel の `--global-config`）として注入します。そうしたエンジンは `clikae status` で `(n/a)` と表示されます（環境から読み戻せるものがないためです）。

`clikae adapters` を実行すると、説明付きで一覧を見られます。自前で追加するのは bash 約 10 行ほどです — [adding-an-adapter.md](adding-an-adapter) を参照してください。

> **`aws` についての注意：** 他と違い、AWS アダプタは設定を別のディレクトリに隔離しません。`AWS_PROFILE` は、既存の `~/.aws/config` から*名前付きプロファイル*を選びます。そのため `clikae init aws work` は、対応する `[profile work]` の項目が存在することを前提とします。代替となる `env-file` 方式については、`lib/adapters/aws.sh` の冒頭のコメントを参照してください。
