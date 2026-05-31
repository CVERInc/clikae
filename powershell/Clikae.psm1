<#
.SYNOPSIS
  clikae — CLI profile switcher, Windows / PowerShell edition.

.DESCRIPTION
  A faithful port of the bash `clikae` CLI for native Windows PowerShell, where
  there is no bash and no `.app` launcher. It keeps the same model:

    * isolated profile directories at  <CLIKAE_HOME>\profiles\<cli>\<profile>\
    * per-CLI adapters that map a profile dir to the env var the CLI reads
    * instead of a shell alias (PowerShell aliases can't carry env vars) it
      writes a sentinel-wrapped *function* into your $PROFILE, e.g. `claude-work`
    * optional .lnk shortcuts you can pin to the Start menu / Taskbar

  Working principles match the bash tool: check then act, back up $PROFILE
  before editing it, sentinel-wrap anything written into user-owned files,
  never log in for the user, never touch anything outside CLIKAE_HOME / $PROFILE
  / the shortcut output dir, no telemetry.

  The adapter table below mirrors lib/adapters/*.sh one-for-one. Keep them in
  sync: a new bash adapter should get a matching entry here.
#>

Set-StrictMode -Version Latest

# --- adapter registry (mirrors lib/adapters/*.sh) ---------------------------
# Strategy semantics (same as the bash adapter_export_env):
#   env-dir   the env var is the profile directory itself
#   env-file  the env var is a file *inside* the profile directory (\config)
#   env-var   the env var is the profile *name* (a selector, not a path)
#   flag      no env var; the profile dir is passed via a CLI flag (Flag key)
$script:ClikaeAdapters = [ordered]@{
    claude    = @{ Name = 'Claude Code';      Binary = 'claude';    EnvVar = 'CLAUDE_CONFIG_DIR';     Strategy = 'env-dir';  Description = 'Anthropic Claude Code CLI (credentials + settings in CLAUDE_CONFIG_DIR)' }
    codex     = @{ Name = 'OpenAI Codex CLI';  Binary = 'codex';     EnvVar = 'CODEX_HOME';            Strategy = 'env-dir';  Description = 'OpenAI Codex CLI (auth + config + history in CODEX_HOME)' }
    gh        = @{ Name = 'GitHub CLI';       Binary = 'gh';        EnvVar = 'GH_CONFIG_DIR';         Strategy = 'env-dir';  Description = 'GitHub CLI (auth + config in GH_CONFIG_DIR)' }
    gcloud    = @{ Name = 'Google Cloud CLI'; Binary = 'gcloud';    EnvVar = 'CLOUDSDK_CONFIG';       Strategy = 'env-dir';  Description = 'Google Cloud CLI (auth + active config in CLOUDSDK_CONFIG)' }
    docker    = @{ Name = 'Docker CLI';       Binary = 'docker';    EnvVar = 'DOCKER_CONFIG';         Strategy = 'env-dir';  Description = 'Docker CLI (registry auth + contexts in DOCKER_CONFIG)' }
    helm      = @{ Name = 'Helm';             Binary = 'helm';      EnvVar = 'HELM_CONFIG_HOME';      Strategy = 'env-dir';  Description = 'Helm (repo list + registry auth in HELM_CONFIG_HOME)' }
    kubectl   = @{ Name = 'kubectl';          Binary = 'kubectl';   EnvVar = 'KUBECONFIG';            Strategy = 'env-file'; File = 'config';      Description = 'Kubernetes CLI (cluster/context/creds in a KUBECONFIG file)' }
    aws       = @{ Name = 'AWS CLI';          Binary = 'aws';       EnvVar = 'AWS_PROFILE';           Strategy = 'env-var';  Description = 'AWS CLI (selects a named profile from your shared AWS config via AWS_PROFILE)' }
    az        = @{ Name = 'Azure CLI';        Binary = 'az';        EnvVar = 'AZURE_CONFIG_DIR';      Strategy = 'env-dir';  Description = 'Azure CLI (subscriptions + token cache in AZURE_CONFIG_DIR)' }
    npm       = @{ Name = 'npm';              Binary = 'npm';       EnvVar = 'NPM_CONFIG_USERCONFIG'; Strategy = 'env-file'; File = 'npmrc';       Description = 'npm (registry auth tokens in a per-profile .npmrc file)' }
    terraform = @{ Name = 'Terraform';        Binary = 'terraform'; EnvVar = 'TF_CLI_CONFIG_FILE';    Strategy = 'env-file'; File = 'terraformrc'; Description = 'Terraform (Terraform Cloud / registry credentials in a CLI config file)' }
    pulumi    = @{ Name = 'Pulumi';           Binary = 'pulumi';    EnvVar = 'PULUMI_HOME';           Strategy = 'env-dir';  Description = 'Pulumi (backend login + credentials in PULUMI_HOME)' }
    vercel    = @{ Name = 'Vercel CLI';       Binary = 'vercel';    EnvVar = '';                      Strategy = 'flag';     Flag = '--global-config'; Description = 'Vercel CLI (per-profile dir via --global-config)' }
}

# Sentinel markers — identical in spirit to the bash tool so a block written by
# either side is recognisable. The id is "<cli>.<profile>".
function Get-ClikaeSentinelOpen  { param([string]$Id) "# >>> clikae:$Id >>>" }
function Get-ClikaeSentinelClose { param([string]$Id) "# <<< clikae:$Id <<<" }

# --- paths ------------------------------------------------------------------

function Get-ClikaeHome {
    <#.SYNOPSIS Root of the clikae store ($env:CLIKAE_HOME, else ~\.clikae).#>
    [CmdletBinding()]
    param()
    if ($env:CLIKAE_HOME) { return $env:CLIKAE_HOME }
    return (Join-Path $HOME '.clikae')
}

function Get-ClikaeProfileDir {
    <#.SYNOPSIS Absolute path of a profile's config directory.#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Profile
    )
    Join-Path (Join-Path (Join-Path (Get-ClikaeHome) 'profiles') $Cli) $Profile
}

# --- validation -------------------------------------------------------------

function Test-ClikaeName {
    <#.SYNOPSIS Validate a cli/profile name (A-Z a-z 0-9 . _ - ; no leading dot).#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($Name.StartsWith('.'))          { return $false }
    return ($Name -match '^[A-Za-z0-9._-]+$')
}

function Assert-ClikaeName {
    param([string]$Kind, [string]$Name)
    if (-not (Test-ClikaeName -Name $Name)) {
        throw "Invalid $Kind name: '$Name'. Allowed: A-Z a-z 0-9 . _ - (no leading dot, no slashes/whitespace)."
    }
}

function Test-ClikaeWindows {
    <#.SYNOPSIS True on Windows (PS 5.1 Desktop, or PS Core on Windows).#>
    # Check PSEdition first so $IsWindows (absent on 5.1) is never read under StrictMode.
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    return ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows))
}

# --- adapters ---------------------------------------------------------------

function Get-ClikaeAdapter {
    <#.SYNOPSIS List built-in adapters, or get one by -Cli.#>
    [CmdletBinding()]
    param([string]$Cli)
    if ($PSBoundParameters.ContainsKey('Cli')) {
        if (-not $script:ClikaeAdapters.Contains($Cli)) {
            throw "No adapter for '$Cli'. Known: $($script:ClikaeAdapters.Keys -join ', ')."
        }
        $a = $script:ClikaeAdapters[$Cli]
        return [pscustomobject]@{ Cli = $Cli; Name = $a.Name; Binary = $a.Binary; EnvVar = $a.EnvVar; Strategy = $a.Strategy; Description = $a.Description }
    }
    foreach ($k in $script:ClikaeAdapters.Keys) {
        $a = $script:ClikaeAdapters[$k]
        [pscustomobject]@{ Cli = $k; Name = $a.Name; Binary = $a.Binary; EnvVar = $a.EnvVar; Strategy = $a.Strategy; Description = $a.Description }
    }
}

function Get-ClikaeProfileEnv {
    <#
    .SYNOPSIS  Compute the { EnvVar = Value } map for a profile (the export_env equiv).
    .DESCRIPTION
      Mirrors adapter_export_env: env-dir -> the dir; env-file -> <dir>\config;
      env-var -> the profile name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Profile
    )
    Assert-ClikaeName -Kind 'cli' -Name $Cli
    Assert-ClikaeName -Kind 'profile' -Name $Profile
    if (-not $script:ClikaeAdapters.Contains($Cli)) {
        throw "No adapter for '$Cli'. Known: $($script:ClikaeAdapters.Keys -join ', ')."
    }
    $a   = $script:ClikaeAdapters[$Cli]
    $dir = Get-ClikaeProfileDir -Cli $Cli -Profile $Profile
    # flag-strategy adapters select the profile via a CLI flag, not an env var,
    # so there is nothing to export.
    if ($a.Strategy -eq 'flag') { return [ordered]@{} }
    $value = switch ($a.Strategy) {
        'env-dir'  { $dir }
        'env-file' { (Join-Path $dir ($(if ($a.File) { $a.File } else { 'config' }))) }
        'env-var'  { $Profile }
        default    { throw "Unsupported strategy '$($a.Strategy)' for '$Cli'." }
    }
    return [ordered]@{ $a.EnvVar = $value }
}

function Get-ClikaeFlagArgs {
    <#
    .SYNOPSIS  The flag args to append after the binary for a `flag`-strategy
               profile (e.g. @('--global-config', '<dir>')). Empty for others.
               Mirrors the bash adapter_flag_args hook.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Profile
    )
    Assert-ClikaeName -Kind 'cli' -Name $Cli
    Assert-ClikaeName -Kind 'profile' -Name $Profile
    if (-not $script:ClikaeAdapters.Contains($Cli)) {
        throw "No adapter for '$Cli'. Known: $($script:ClikaeAdapters.Keys -join ', ')."
    }
    $a = $script:ClikaeAdapters[$Cli]
    if ($a.Strategy -ne 'flag') { return @() }
    $dir = Get-ClikaeProfileDir -Cli $Cli -Profile $Profile
    return @($a.Flag, $dir)
}

# --- machine-readable JSON (mirrors lib/core/json.sh + the --json modes) ----

function ConvertTo-ClikaeJsonArray {
    <#
    .SYNOPSIS  Render objects as a JSON ARRAY, always.
    .DESCRIPTION
      Windows PowerShell 5.1's ConvertTo-Json drops the [] wrapper for a single
      object (and -AsArray doesn't exist before PS 7), so we convert each element
      and join. This keeps `-Json` output a real array on every edition, matching
      the bash `--json` contract (empty -> [], one row -> [ {…} ]).
    #>
    [CmdletBinding()]
    param([object[]]$Items)
    $arr = @($Items | Where-Object { $null -ne $_ })
    if ($arr.Count -eq 0) { return '[]' }
    $parts = foreach ($it in $arr) { $it | ConvertTo-Json -Depth 6 -Compress }
    return '[' + ($parts -join ',') + ']'
}

# --- status (mirrors `clikae status`) --------------------------------------

function Resolve-ClikaeActiveProfile {
    <#
    .SYNOPSIS  Resolve a live env-var value back to a clikae profile name, or $null.
    .DESCRIPTION
      Mirrors bash resolve_active_profile: for env-var strategy the value IS the
      profile name (active when that profile dir exists); for path strategies
      (env-dir / env-file) the value is matched against each profiles\<cli>\<p>
      dir — an exact match, or a path *inside* it (e.g. env-file's <dir>\config).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Strategy,
        [AllowEmptyString()][string]$Value
    )
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    if ($Strategy -eq 'env-var') {
        if (Test-Path -LiteralPath (Get-ClikaeProfileDir -Cli $Cli -Profile $Value)) { return $Value }
        return $null
    }
    $norm = $Value.TrimEnd('\', '/')
    $root = Join-Path (Join-Path (Get-ClikaeHome) 'profiles') $Cli
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    foreach ($pd in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $pdir = $pd.FullName.TrimEnd('\', '/')
        if ($norm -eq $pdir -or
            $norm.StartsWith($pdir + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
            $norm.StartsWith($pdir + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $pd.Name
        }
    }
    return $null
}

function Get-ClikaeStatus {
    <#
    .SYNOPSIS  Show which profile each CLI is currently on *in this session*.
    .DESCRIPTION
      The `clikae status` equivalent. Reads each adapter's live env var (e.g.
      $env:CLAUDE_CONFIG_DIR) and resolves it back to a clikae profile. Emits one
      object per CLI with a State of:
        active   — the env var points at a clikae profile (Profile is set)
        external — the env var is set but not to a clikae profile
        default  — the env var is unset (the CLI's own system default)
        flag     — flag-strategy adapter; not detectable from the environment
      With no -Cli, reports every CLI that has at least one profile (matching bash).
    .PARAMETER Json
      Emit a JSON array (one object per CLI) instead of objects. Otherwise returns
      rich objects — pipe to ConvertTo-Json yourself if you prefer.
    #>
    [CmdletBinding()]
    param(
        [string]$Cli,
        [switch]$Json
    )
    $clis = @()
    if ($PSBoundParameters.ContainsKey('Cli')) {
        Assert-ClikaeName -Kind 'cli' -Name $Cli
        if (-not $script:ClikaeAdapters.Contains($Cli)) {
            throw "No adapter for '$Cli'. Known: $($script:ClikaeAdapters.Keys -join ', ')."
        }
        $clis = @($Cli)
    } else {
        $clis = @(Get-ClikaeProfile | Select-Object -ExpandProperty Cli -Unique)
    }

    $rows = foreach ($c in $clis) {
        if (-not $script:ClikaeAdapters.Contains($c)) { continue }
        $a = $script:ClikaeAdapters[$c]
        if ($a.Strategy -eq 'flag') {
            [pscustomobject]([ordered]@{ Cli = $c; State = 'flag'; Profile = $null; Account = $null; EnvVar = $null; EnvValue = $null })
            continue
        }
        $var   = $a.EnvVar
        $value = [Environment]::GetEnvironmentVariable($var)
        if ([string]::IsNullOrEmpty($value)) {
            [pscustomobject]([ordered]@{ Cli = $c; State = 'default'; Profile = $null; Account = $null; EnvVar = $var; EnvValue = $null })
            continue
        }
        $active = Resolve-ClikaeActiveProfile -Cli $c -Strategy $a.Strategy -Value $value
        if ($active) {
            [pscustomobject]([ordered]@{ Cli = $c; State = 'active'; Profile = $active; Account = $null; EnvVar = $var; EnvValue = $value })
        } else {
            [pscustomobject]([ordered]@{ Cli = $c; State = 'external'; Profile = $null; Account = $null; EnvVar = $var; EnvValue = $value })
        }
    }

    if ($Json) { return (ConvertTo-ClikaeJsonArray -Items $rows) }
    return $rows
}

# --- $PROFILE function blocks ----------------------------------------------

function Get-ClikaeFunctionName {
    param([string]$Cli, [string]$Profile)
    "$Cli-$Profile"
}

# Build the PowerShell source for a profile's launcher function.
function Get-ClikaeFunctionBlock {
    param([Parameter(Mandatory)][string]$Cli, [Parameter(Mandatory)][string]$Profile)
    $a      = $script:ClikaeAdapters[$Cli]
    $fn     = Get-ClikaeFunctionName -Cli $Cli -Profile $Profile
    $id     = "$Cli.$Profile"
    if ($a.Strategy -eq 'flag') {
        # No env var; pass the profile dir via the CLI flag.
        $dir  = (Get-ClikaeProfileDir -Cli $Cli -Profile $Profile).Replace("'", "''")
        $flag = ([string]$a.Flag).Replace("'", "''")
        $body = "& '$($a.Binary)' '$flag' '$dir' @args"
    } else {
        $envMap = Get-ClikaeProfileEnv -Cli $Cli -Profile $Profile
        # Single-quote the value and escape embedded single quotes for safe literals.
        $val  = ([string]$envMap[$a.EnvVar]).Replace("'", "''")
        $body = "`$env:$($a.EnvVar) = '$val'; & '$($a.Binary)' @args"
    }
    @(
        (Get-ClikaeSentinelOpen -Id $id)
        "function $fn { $body }"
        (Get-ClikaeSentinelClose -Id $id)
    ) -join [Environment]::NewLine
}

# Remove an existing clikae block for <id> from an array of profile-script lines.
function Remove-ClikaeBlockFromLines {
    param([string[]]$Lines, [string]$Id)
    $open  = Get-ClikaeSentinelOpen  -Id $Id
    $close = Get-ClikaeSentinelClose -Id $Id
    $out = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach ($line in $Lines) {
        if ($line -eq $open)  { $inBlock = $true;  continue }
        if ($line -eq $close) { $inBlock = $false; continue }
        if (-not $inBlock)    { $out.Add($line) }
    }
    return ,$out.ToArray()
}

function Backup-ClikaeProfileScript {
    param([string]$ProfilePath)
    if (Test-Path -LiteralPath $ProfilePath) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $ProfilePath -Destination "$ProfilePath.clikae.bak.$stamp" -Force
    }
}

# --- public verbs -----------------------------------------------------------

function New-ClikaeProfile {
    <#
    .SYNOPSIS  Create a profile directory; optionally add a $PROFILE function.
    .PARAMETER Alias  Also write a `<cli>-<profile>` function into the profile script.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Profile,
        [switch]$Alias,
        [string]$ProfilePath = $PROFILE
    )
    Assert-ClikaeName -Kind 'cli' -Name $Cli
    Assert-ClikaeName -Kind 'profile' -Name $Profile
    if (-not $script:ClikaeAdapters.Contains($Cli)) {
        throw "No adapter for '$Cli'. Known: $($script:ClikaeAdapters.Keys -join ', ')."
    }

    $dir = Get-ClikaeProfileDir -Cli $Cli -Profile $Profile
    if ($PSCmdlet.ShouldProcess($dir, 'Create profile directory')) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Write-Verbose "Profile dir: $dir"
    }

    if ($Alias) {
        Add-ClikaeFunction -Cli $Cli -Profile $Profile -ProfilePath $ProfilePath
    }
    Get-ClikaeProfile -Cli $Cli | Where-Object { $_.Profile -eq $Profile }
}

function Add-ClikaeFunction {
    <#.SYNOPSIS Write (or replace) a profile's launcher function in the profile script.#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Profile,
        [string]$ProfilePath = $PROFILE
    )
    Assert-ClikaeName -Kind 'cli' -Name $Cli
    Assert-ClikaeName -Kind 'profile' -Name $Profile
    $id    = "$Cli.$Profile"
    $block = Get-ClikaeFunctionBlock -Cli $Cli -Profile $Profile

    if (-not $PSCmdlet.ShouldProcess($ProfilePath, "Add clikae function $id")) { return }

    $parent = Split-Path -Parent $ProfilePath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $existing = @()
    if (Test-Path -LiteralPath $ProfilePath) {
        Backup-ClikaeProfileScript -ProfilePath $ProfilePath
        $existing = @(Get-Content -LiteralPath $ProfilePath)
    }
    # Idempotent: drop any prior block for this id, then append the fresh one.
    $kept = Remove-ClikaeBlockFromLines -Lines $existing -Id $id
    # Trim a trailing run of blank lines so we don't accumulate gaps on re-run.
    $kept = [System.Collections.Generic.List[string]]@($kept)
    while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) {
        $kept.RemoveAt($kept.Count - 1)
    }
    $final = New-Object System.Collections.Generic.List[string]
    $final.AddRange($kept)
    if ($final.Count -gt 0) { $final.Add('') }
    foreach ($l in ($block -split "`r?`n")) { $final.Add($l) }

    Set-Content -LiteralPath $ProfilePath -Value $final.ToArray() -Encoding UTF8
    Write-Verbose "Wrote clikae function '$(Get-ClikaeFunctionName -Cli $Cli -Profile $Profile)' to $ProfilePath"
}

function Get-ClikaeProfile {
    <#
    .SYNOPSIS List profiles (optionally for one -Cli).
    .PARAMETER Json
      Emit a JSON array (one object per profile) instead of objects — the bash
      `clikae list --json` equivalent. Otherwise returns rich objects you can pipe
      to ConvertTo-Json yourself.
    #>
    [CmdletBinding()]
    param([string]$Cli, [switch]$Json)
    $filterCli = $PSBoundParameters.ContainsKey('Cli')
    $rows = New-Object System.Collections.Generic.List[object]
    $root = Join-Path (Get-ClikaeHome) 'profiles'
    if (Test-Path -LiteralPath $root) {
        $cliDirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue
        foreach ($cd in $cliDirs | Sort-Object Name) {
            if ($filterCli -and $cd.Name -ne $Cli) { continue }
            foreach ($pd in (Get-ChildItem -LiteralPath $cd.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
                $rows.Add([pscustomobject]([ordered]@{ Cli = $cd.Name; Profile = $pd.Name; Path = $pd.FullName }))
            }
        }
    }
    if ($Json) { return (ConvertTo-ClikaeJsonArray -Items $rows.ToArray()) }
    return $rows.ToArray()
}

function Remove-ClikaeProfile {
    <#
    .SYNOPSIS  Remove a profile: its directory, its $PROFILE function, and any .lnk.
    .PARAMETER KeepData  Keep the profile directory; only remove the function block.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Profile,
        [switch]$KeepData,
        [switch]$Force,
        [string]$ProfilePath = $PROFILE
    )
    Assert-ClikaeName -Kind 'cli' -Name $Cli
    Assert-ClikaeName -Kind 'profile' -Name $Profile
    $id  = "$Cli.$Profile"
    $dir = Get-ClikaeProfileDir -Cli $Cli -Profile $Profile

    if (-not ($Force -or $PSCmdlet.ShouldProcess("$Cli/$Profile", 'Remove clikae profile'))) { return }

    # 1) function block out of the profile script (independent of the dir)
    if (Test-Path -LiteralPath $ProfilePath) {
        $lines = @(Get-Content -LiteralPath $ProfilePath)
        $kept  = Remove-ClikaeBlockFromLines -Lines $lines -Id $id
        if ($kept.Count -ne $lines.Count) {
            Backup-ClikaeProfileScript -ProfilePath $ProfilePath
            Set-Content -LiteralPath $ProfilePath -Value $kept -Encoding UTF8
            Write-Verbose "Removed clikae function block '$id' from $ProfilePath"
        }
    }

    # 2) the profile directory (unless -KeepData)
    if (-not $KeepData -and (Test-Path -LiteralPath $dir)) {
        Remove-Item -LiteralPath $dir -Recurse -Force
        Write-Verbose "Removed $dir"
        # tidy up an empty <cli> parent
        $cliDir = Split-Path -Parent $dir
        if ((Test-Path -LiteralPath $cliDir) -and -not (Get-ChildItem -LiteralPath $cliDir -Force)) {
            Remove-Item -LiteralPath $cliDir -Force
        }
    }
}

function Invoke-ClikaeProfile {
    <#.SYNOPSIS Run the CLI for a profile with its env applied (the `run` equivalent).#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(ValueFromRemainingArguments)][string[]]$Arguments
    )
    $envMap = Get-ClikaeProfileEnv -Cli $Cli -Profile $Profile
    $bin = $script:ClikaeAdapters[$Cli].Binary
    if (-not (Get-Command $bin -ErrorAction SilentlyContinue)) {
        throw "'$bin' is not on PATH. Install it (or check your PATH) before running this profile."
    }
    foreach ($k in $envMap.Keys) { Set-Item -Path "Env:$k" -Value $envMap[$k] }
    $flagArgs = Get-ClikaeFlagArgs -Cli $Cli -Profile $Profile
    & $bin @flagArgs @Arguments
}

function New-ClikaeShortcut {
    <#
    .SYNOPSIS  Create a .lnk that launches a profile (pin it to Start/Taskbar).
    .DESCRIPTION
      Windows-only. Generates a shortcut that opens PowerShell, applies the
      profile's env var, and runs the CLI. No .app equivalent exists on Windows;
      this is the closest thing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Profile,
        [string]$OutDir = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'clikae')
    )
    if (-not (Test-ClikaeWindows)) {
        throw 'New-ClikaeShortcut is Windows-only (.lnk needs the WScript.Shell COM object).'
    }
    $a       = $script:ClikaeAdapters[$Cli]
    $envMap  = Get-ClikaeProfileEnv -Cli $Cli -Profile $Profile
    $bin     = $a.Binary
    $lnkPath = Join-Path $OutDir ("$Cli-$Profile.lnk")

    if (-not $PSCmdlet.ShouldProcess($lnkPath, 'Create shortcut')) { return }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

    if ($a.Strategy -eq 'flag') {
        $dir    = Get-ClikaeProfileDir -Cli $Cli -Profile $Profile
        $psArgs = "-NoExit -Command `"& '$bin' '$($a.Flag)' '$dir'`""
    } else {
        $envVar = @($envMap.Keys)[0]
        $val    = $envMap[$envVar]
        $psArgs = "-NoExit -Command `"`$env:$envVar='$val'; & '$bin'`""
    }
    $wsh    = New-Object -ComObject WScript.Shell
    $sc     = $wsh.CreateShortcut($lnkPath)
    $target = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    if (-not $target) { $target = 'powershell.exe' }
    $sc.TargetPath  = $target
    $sc.Arguments   = $psArgs
    $sc.Description  = "clikae: $Cli ($Profile)"
    $sc.Save()
    Get-Item -LiteralPath $lnkPath
}

Export-ModuleMember -Function `
    Get-ClikaeHome, Get-ClikaeProfileDir, Test-ClikaeName, Test-ClikaeWindows, Get-ClikaeAdapter, `
    Get-ClikaeProfileEnv, Get-ClikaeFlagArgs, Get-ClikaeFunctionName, Get-ClikaeFunctionBlock, `
    ConvertTo-ClikaeJsonArray, Resolve-ClikaeActiveProfile, Get-ClikaeStatus, `
    New-ClikaeProfile, Add-ClikaeFunction, Get-ClikaeProfile, Remove-ClikaeProfile, `
    Invoke-ClikaeProfile, New-ClikaeShortcut
