# Adding a new CLI adapter

An **adapter** teaches `clikae` how to switch profiles for a particular CLI tool.

## TL;DR

1. Copy `lib/adapters/_template.sh` to `lib/adapters/<your-cli>.sh`.
2. Fill in the metadata and the two required hooks.
3. Submit a PR (or keep it local).

```bash
cp lib/adapters/_template.sh lib/adapters/gh.sh
# edit
clikae adapters         # your new adapter should appear
clikae init gh personal
```

## The adapter contract

Every adapter is a bash script that defines a set of functions. The dispatcher
loads it and calls these hooks. Required functions:

| Function | Purpose | Returns / prints |
| --- | --- | --- |
| `adapter_meta_name` | Human-readable name | string via `echo` |
| `adapter_meta_cli_binary` | The actual binary to invoke | string via `echo` |
| `adapter_meta_env_var` | Primary env var this adapter manipulates | string via `echo` |
| `adapter_meta_strategy` | One of: `env-dir`, `env-file`, `env-var`, `flag`, `subcommand` | string via `echo` |
| `adapter_meta_description` | One-line description | string via `echo` |
| `adapter_export_env <profile_dir>` | Lines of `KEY=VALUE` to export for this profile | newline-separated `K=V` lines |
| `adapter_run <profile_dir> [args...]` | Run the CLI with this profile active | execs the CLI |

Optional:

| Function | Purpose |
| --- | --- |
| `adapter_init <profile_dir>` | Called once at `clikae init`. Seed the profile dir with defaults, etc. |

## The five strategies

Most CLIs fit one of these. Pick the right one and the adapter is usually 10 lines.

### `env-dir` — env var points at a config DIRECTORY

Examples: Anthropic Claude (`CLAUDE_CONFIG_DIR`), GitHub CLI (`GH_CONFIG_DIR`),
Google Cloud (`CLOUDSDK_CONFIG`), Docker (`DOCKER_CONFIG`), Helm (`HELM_CONFIG_HOME`).

```bash
adapter_meta_strategy() { echo "env-dir"; }
adapter_export_env() { printf 'MY_CFG_DIR=%s\n' "$1"; }
adapter_run() { local d="$1"; shift; MY_CFG_DIR="$d" exec mycli "$@"; }
```

### `env-file` — env var points at a config FILE

Examples: `kubectl` (`KUBECONFIG`), AWS CLI (`AWS_CONFIG_FILE`,
`AWS_SHARED_CREDENTIALS_FILE`).

In `adapter_init`, you may want to `touch` the file or seed it.

```bash
adapter_init() { touch "$1/config"; }
adapter_export_env() { printf 'KUBECONFIG=%s/config\n' "$1"; }
adapter_run() { local d="$1"; shift; KUBECONFIG="$d/config" exec kubectl "$@"; }
```

### `env-var` — env var holds a profile NAME

Examples: AWS CLI (`AWS_PROFILE`, when used with the shared credentials file).

```bash
adapter_export_env() { printf 'AWS_PROFILE=%s\n' "$(basename "$1")"; }
adapter_run() { local d="$1"; shift; AWS_PROFILE="$(basename "$d")" exec aws "$@"; }
```

### `flag` — wrapper injects a `--profile`-style flag

Examples: `doctl` (`--context`), `aws --profile` (when not using env vars).

```bash
adapter_export_env() { :; }   # nothing for the alias path; the flag does the work
adapter_run() { local d="$1"; shift; exec doctl --context "$(basename "$d")" "$@"; }
```

(`clikae alias` doesn't make as much sense for `flag` strategies — it would generate
an alias that loses extra arg-passing. We're considering wrapping flag-strategy
adapters in a small shim script in v0.2.)

### `subcommand` — CLI has its own activate/use command

Examples: `gcloud config configurations activate`, `kubectl config use-context`.

```bash
adapter_run() {
  local d="$1"; shift
  gcloud config configurations activate "$(basename "$d")" >/dev/null
  exec gcloud "$@"
}
```

## Conventions

- Use `exec` in `adapter_run`. This lets signals (Ctrl-C) reach the child cleanly.
- The `<profile_dir>` you receive is `~/.clikae/profiles/<cli>/<name>/`.
  You're free to lay out anything inside it.
- Never write outside the profile dir without good reason.
- Keep the file dependency-free: pure POSIX-ish bash, no Python/Node.

## Testing your adapter

```bash
# From the repo root:
PATH="$PWD/bin:$PATH" clikae adapters     # your CLI shows up?
clikae init <cli> testprof
clikae run <cli> testprof
clikae remove <cli> testprof --force
```

Add a bats test under `tests/bats/adapters/<cli>.bats` (v0.2 onwards).
