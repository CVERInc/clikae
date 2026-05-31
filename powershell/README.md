# clikae for Windows (PowerShell)

`Clikae.psm1` is the Windows-native port of the bash `clikae` CLI. There's no
bash on a stock Windows box and no `.app` launcher, so this module keeps the
same model with PowerShell mechanics:

- isolated profile dirs at `%USERPROFILE%\.clikae\profiles\<cli>\<profile>\`
  (override the root with `$env:CLIKAE_HOME`),
- the same 13 built-in adapters (claude, codex, gh, gcloud, docker, helm,
  kubectl, aws, az, npm, terraform, pulumi, vercel), kept in sync with
  `lib/adapters/*.sh`,
- instead of a shell alias (PowerShell aliases can't carry env vars) it writes a
  **sentinel-wrapped function** into your `$PROFILE`, e.g. `claude-work`,
- optional `.lnk` shortcuts you can pin to the Start menu / Taskbar.

It follows the same working principles as the bash tool: it backs up `$PROFILE`
before editing, sentinel-wraps everything it writes (`# >>> clikae:<cli>.<p> >>>`
… `# <<< clikae:<cli>.<p> <<<`), never logs in for you, and only ever touches
`$env:CLIKAE_HOME`, your `$PROFILE`, and the shortcut output dir.

## Use it

```powershell
Import-Module .\powershell\Clikae.psm1

# create a profile dir AND add a `claude-work` function to your $PROFILE
New-ClikaeProfile -Cli claude -Profile work -Alias
. $PROFILE        # reload the profile
claude-work       # runs claude with CLAUDE_CONFIG_DIR set to that profile

Get-ClikaeProfile                       # list profiles
Get-ClikaeProfile -Json                 # … as a JSON array (for the GUI / scripts)
Get-ClikaeStatus                         # which profile each CLI is on in THIS session
Get-ClikaeStatus -Cli claude -Json       # … as a JSON array with a `state` field
Get-ClikaeAdapter                       # list built-in adapters
Invoke-ClikaeProfile -Cli gh -Profile personal status   # one-off run, no alias
New-ClikaeShortcut -Cli claude -Profile work             # a pinnable .lnk
Remove-ClikaeProfile -Cli claude -Profile work -Force    # clean up dir + function
```

### Functions

| Function | Purpose |
|---|---|
| `New-ClikaeProfile -Cli -Profile [-Alias]` | Create a profile dir; `-Alias` also adds the `$PROFILE` function. |
| `Add-ClikaeFunction -Cli -Profile` | Write/replace just the `$PROFILE` function (idempotent). |
| `Get-ClikaeProfile [-Cli] [-Json]` | List profiles. `-Json` emits a JSON array of `{Cli, Profile, Path}`. |
| `Get-ClikaeStatus [-Cli] [-Json]` | Show which profile each CLI is on **in this session** (`active`/`external`/`default`/`flag`). `-Json` emits a JSON array. The `clikae status` equivalent. |
| `Remove-ClikaeProfile -Cli -Profile [-Force] [-KeepData]` | Remove the dir + function (`-KeepData` keeps the dir). |
| `Invoke-ClikaeProfile -Cli -Profile [args…]` | Run the CLI once with the profile env applied. |
| `Get-ClikaeAdapter [-Cli]` | List/inspect built-in adapters. |
| `New-ClikaeShortcut -Cli -Profile [-OutDir]` | Generate a `.lnk` launcher (Windows only). |

All mutating functions support `-WhatIf` / `-Confirm`. Pass `-ProfilePath` to
target a profile script other than `$PROFILE` (used by the test suite).

## Tests

`Clikae.Tests.ps1` is a [Pester](https://pester.dev) v5 suite. CI runs it on
`windows-latest` under both PowerShell 7 (`pwsh`) and Windows PowerShell 5.1
(`powershell`).

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester -Path .\powershell\Clikae.Tests.ps1
```

> Status: the module and its tests ship in the repo and are exercised in CI. The
> module is not yet published to the PowerShell Gallery — import it from the repo
> for now. PRs from Windows PowerShell folks very welcome, especially around the
> `.lnk` UX and a `migrate` equivalent.
