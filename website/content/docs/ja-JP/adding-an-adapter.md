---
title: アダプタを追加する
description: 新しい CLI の切り替え方を、約 10 行の bash で clikae に教えます。
section: Guides
order: 4
---

# 新しい CLI アダプタを追加する

**アダプタ**は、特定の CLI ツールでプロファイルを切り替える方法を `clikae` に教えます。

## TL;DR

1. `lib/adapters/_template.sh` を `lib/adapters/<your-cli>.sh` にコピーします。
2. メタデータと、2 つの必須フックを埋めます。
3. PR を出します（あるいはローカルに留めておいても構いません）。

```bash
cp lib/adapters/_template.sh lib/adapters/gh.sh
# edit
clikae adapters         # your new adapter should appear
clikae init gh personal
```

## アダプタの契約

どのアダプタも、一連の関数を定義する bash スクリプトです。ディスパッチャがそれを
読み込み、これらのフックを呼び出します。必須の関数は次のとおりです。

| 関数 | 役割 | 戻り値／出力 |
| --- | --- | --- |
| `adapter_meta_name` | 人間が読める名前 | `echo` で文字列を出力 |
| `adapter_meta_cli_binary` | 実際に呼び出すバイナリ | `echo` で文字列を出力 |
| `adapter_meta_env_var` | このアダプタが操作する主要な環境変数 | `echo` で文字列を出力 |
| `adapter_meta_strategy` | `env-dir`、`env-file`、`env-var`、`flag`、`subcommand` のいずれか | `echo` で文字列を出力 |
| `adapter_meta_description` | 1 行の説明 | `echo` で文字列を出力 |
| `adapter_export_env <profile_dir>` | このプロファイルでエクスポートする `KEY=VALUE` の行 | 改行区切りの `K=V` の行 |
| `adapter_run <profile_dir> [args...]` | このプロファイルを有効にして CLI を実行する | CLI を exec する |

任意:

| 関数 | 役割 |
| --- | --- |
| `adapter_init <profile_dir>` | `clikae init` のときに一度だけ呼ばれます。プロファイルディレクトリにデフォルト値を入れる、などの初期化に使います。 |

## 5 つのストラテジー

たいていの CLI は、このうちのどれかに当てはまります。正しいものを選べば、アダプタは
だいたい 10 行で済みます。

### `env-dir` — 環境変数が設定ディレクトリ（DIRECTORY）を指す

例: Anthropic Claude（`CLAUDE_CONFIG_DIR`）、GitHub CLI（`GH_CONFIG_DIR`）、
Google Cloud（`CLOUDSDK_CONFIG`）、Docker（`DOCKER_CONFIG`）、Helm（`HELM_CONFIG_HOME`）。

```bash
adapter_meta_strategy() { echo "env-dir"; }
adapter_export_env() { printf 'MY_CFG_DIR=%s\n' "$1"; }
adapter_run() { local d="$1"; shift; MY_CFG_DIR="$d" exec mycli "$@"; }
```

### `env-file` — 環境変数が設定ファイル（FILE）を指す

例: `kubectl`（`KUBECONFIG`）、AWS CLI（`AWS_CONFIG_FILE`、
`AWS_SHARED_CREDENTIALS_FILE`）。

`adapter_init` の中で、ファイルを `touch` したり、初期値を入れたりするとよいでしょう。

```bash
adapter_init() { touch "$1/config"; }
adapter_export_env() { printf 'KUBECONFIG=%s/config\n' "$1"; }
adapter_run() { local d="$1"; shift; KUBECONFIG="$d/config" exec kubectl "$@"; }
```

### `env-var` — 環境変数がプロファイル名（NAME）を保持する

例: AWS CLI（共有クレデンシャルファイルと併用する場合の `AWS_PROFILE`）。

```bash
adapter_export_env() { printf 'AWS_PROFILE=%s\n' "$(basename "$1")"; }
adapter_run() { local d="$1"; shift; AWS_PROFILE="$(basename "$d")" exec aws "$@"; }
```

### `flag` — ラッパーが `--profile` 形式のフラグを差し込む

例: `doctl`（`--context`）、`aws --profile`（環境変数を使わない場合）。

```bash
adapter_export_env() { :; }   # nothing for the alias path; the flag does the work
adapter_run() { local d="$1"; shift; exec doctl --context "$(basename "$d")" "$@"; }
```

（`flag` ストラテジーでは `clikae alias` はあまり意味をなしません。生成される
エイリアスでは、追加の引数渡しが失われてしまうためです。v0.2 では、フラグ
ストラテジーのアダプタを小さな shim スクリプトで包むことを検討しています。）

### `subcommand` — CLI に独自の activate／use コマンドがある

例: `gcloud config configurations activate`、`kubectl config use-context`。

```bash
adapter_run() {
  local d="$1"; shift
  gcloud config configurations activate "$(basename "$d")" >/dev/null
  exec gcloud "$@"
}
```

## 慣例

- `adapter_run` では `exec` を使ってください。これにより、シグナル（Ctrl-C）が
  子プロセスにきれいに届きます。
- 受け取る `<profile_dir>` は `~/.clikae/profiles/<cli>/<name>/` です。その中の
  レイアウトは自由に決めて構いません。
- 正当な理由がない限り、プロファイルディレクトリの外には書き込まないでください。
- ファイルは依存ゼロに保ってください。Python や Node を使わず、純粋に POSIX 寄りの
  bash でまとめます。

## アダプタをテストする

```bash
# From the repo root:
PATH="$PWD/bin:$PATH" clikae adapters     # your CLI shows up?
clikae init <cli> testprof
clikae run <cli> testprof
clikae remove <cli> testprof --force
```

`tests/bats/adapters/<cli>.bats` に bats テストを追加してください（v0.2 以降）。
