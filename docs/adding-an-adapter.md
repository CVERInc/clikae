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

Optional. **These are what separate a tank you can switch to from a tank clikae can
actually work with** — define none and your CLI still switches accounts correctly;
define the session ones and it joins the board, the resume picker and `clean`. Each
is independently optional: a caller that doesn't find one degrades honestly rather
than pretending. Engines listed are the ones that define it today, as a reference
implementation to read.

| Function | Unlocks | See |
| --- | --- | --- |
| `adapter_init <dir>` | Seed the profile dir once, at `clikae init`. | kubectl, npm |
| `adapter_install_hint` | A useful "not installed" message instead of a bare failure. | claude, codex, grok |
| `adapter_account_label <dir>` | The ACCOUNT column in `clikae list` / `status` / the board. | claude, codex, grok |
| `adapter_flag_args <dir>` | The `flag` strategy — args appended instead of env exported. | vercel |
| `adapter_migrate_credentials <old> <new>` | `--keep-login` on `migrate`/`rename` (macOS Keychain re-key). | claude |
| **Sessions — the board, `resume`, `clean`** | | |
| `adapter_transcript_path <dir>` | Your sessions appear in the board's Resume list. | claude, codex, grok |
| `adapter_title_for_file <file>` | A session's title, derived from the transcript file alone. **Prefer a user-set rename over a machine-generated title**, and scan the tail — a rename lands wherever it was typed. | claude, codex, grok, antigravity |
| `adapter_session_title` / `adapter_session_recap` / `adapter_session_meta` | Richer board rows (title, one-line recap, age/size). | claude |
| `adapter_find_session <id>` / `adapter_session_cwd` / `adapter_resume_args` | `clikae resume <id>` can locate, `cd` to, and reopen a past session. | claude, codex, grok, antigravity |
| `adapter_list_sessions` / `adapter_recent_sids` | Feed the cross-tank picker and `clean`'s candidate scan. | claude, codex, grok |
| **Headless + fleet** | | |
| `adapter_start_with_prompt` | Marks the engine as an **AI engine** — it's what the new-tank picker classifies on, and what `burn` needs to start a task. | claude, codex, grok |
| `adapter_burn_flags` / `adapter_audit_flags` | `burn`'s write dialect and `conduct`'s read-only dialect, so a reroute regenerates the *right* flags for the target engine. | claude, codex, grok |
| `adapter_relay <from> <to>` | `clikae to` / `relay` can carry a **live** session across tanks. Without it, the carry starts a clean session and says so. | claude |
| `adapter_memory_dir` / `adapter_memory_pointer_path` | Soul membership. Defining `adapter_memory_dir` (a real memory directory) also enables `--ephemeral`; the pointer variant is for engines whose memory is opaque. | claude / codex, grok |
| `adapter_mcp_config_file` | `clikae mcp share` can fan a server into this engine's tanks. | claude |

> The classification rule that matters: **never key behaviour on "an adapter file
> exists."** `antigravity` has an adapter file that is a resume-only shim on a
> launch-only target. `clikae_is_target` (`lib/core/profile_store.sh`) is the
> canonical predicate, and it wins.

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

Add a bats test under `tests/bats/adapters/<cli>.bats`, then run the gate:

```bash
bash scripts/test.sh        # shellcheck -S warning + the whole bats suite
```

**One thing will surprise you.** If your adapter uses `env-dir` / `env-file` /
`env-var` / `flag`, you must also add its row to the `$script:ClikaeAdapters` table
in `powershell/Clikae.psm1` — `tests/bats/compat.bats` asserts the two stay in sync,
and it is a **blocking** gate even though Windows itself is an unsupported community
port whose own CI never blocks. Copy the shape of a neighbouring row; you don't need
PowerShell installed to satisfy it (the test greps source, it doesn't run pwsh).

A `subcommand`-strategy adapter is exempt: that strategy marks a capability shim on a
launch-only target rather than a switchable engine, and the test skips it.
