<#
  Pester tests for the Clikae PowerShell module. Runs on Windows PowerShell 5.1
  and PowerShell 7+. Each test uses an isolated $env:CLIKAE_HOME and a throwaway
  profile-script path, so nothing touches your real ~\.clikae or $PROFILE.

  Run:  Invoke-Pester -Path powershell/Clikae.Tests.ps1
#>

BeforeAll {
    Import-Module "$PSScriptRoot/Clikae.psm1" -Force

    $script:OrigClikaeHome = $env:CLIKAE_HOME
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("clikae-ps-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:TestRoot | Out-Null
    $env:CLIKAE_HOME = Join-Path $script:TestRoot '.clikae'

    # A throwaway profile-script path we pass explicitly everywhere.
    $script:ProfileScript = Join-Path $script:TestRoot 'profile.ps1'
}

AfterAll {
    $env:CLIKAE_HOME = $script:OrigClikaeHome
    if (Test-Path -LiteralPath $script:TestRoot) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'adapter registry' {
    It 'exposes the same 13 adapters as the bash tool' {
        $adapters = Get-ClikaeAdapter
        $adapters.Count | Should -Be 13
        ($adapters.Cli | Sort-Object) | Should -Be (@('aws','az','claude','codex','docker','gcloud','gh','helm','kubectl','npm','pulumi','terraform','vercel'))
    }

    It 'maps each CLI to the correct env var and strategy' {
        (Get-ClikaeAdapter -Cli claude).EnvVar  | Should -Be 'CLAUDE_CONFIG_DIR'
        (Get-ClikaeAdapter -Cli claude).Strategy | Should -Be 'env-dir'
        (Get-ClikaeAdapter -Cli codex).EnvVar     | Should -Be 'CODEX_HOME'
        (Get-ClikaeAdapter -Cli codex).Strategy   | Should -Be 'env-dir'
        (Get-ClikaeAdapter -Cli kubectl).Strategy | Should -Be 'env-file'
        (Get-ClikaeAdapter -Cli aws).Strategy     | Should -Be 'env-var'
        (Get-ClikaeAdapter -Cli aws).EnvVar       | Should -Be 'AWS_PROFILE'
        (Get-ClikaeAdapter -Cli az).EnvVar        | Should -Be 'AZURE_CONFIG_DIR'
        (Get-ClikaeAdapter -Cli npm).Strategy     | Should -Be 'env-file'
        (Get-ClikaeAdapter -Cli terraform).EnvVar | Should -Be 'TF_CLI_CONFIG_FILE'
        (Get-ClikaeAdapter -Cli pulumi).EnvVar    | Should -Be 'PULUMI_HOME'
        (Get-ClikaeAdapter -Cli vercel).Strategy  | Should -Be 'flag'
    }

    It 'throws on an unknown CLI' {
        { Get-ClikaeAdapter -Cli nope } | Should -Throw
    }
}

Describe 'Get-ClikaeProfileEnv (export_env equivalent)' {
    It 'env-dir: value is the profile directory' {
        $dir = Get-ClikaeProfileDir -Cli claude -Profile work
        (Get-ClikaeProfileEnv -Cli claude -Profile work)['CLAUDE_CONFIG_DIR'] | Should -Be $dir
    }
    It 'env-file: value is <dir>\config' {
        $dir = Get-ClikaeProfileDir -Cli kubectl -Profile prod
        (Get-ClikaeProfileEnv -Cli kubectl -Profile prod)['KUBECONFIG'] | Should -Be (Join-Path $dir 'config')
    }
    It 'env-file: per-adapter filename overrides the default (npm -> npmrc)' {
        $dir = Get-ClikaeProfileDir -Cli npm -Profile work
        (Get-ClikaeProfileEnv -Cli npm -Profile work)['NPM_CONFIG_USERCONFIG'] | Should -Be (Join-Path $dir 'npmrc')
    }
    It 'env-var: value is the profile name, not a path' {
        (Get-ClikaeProfileEnv -Cli aws -Profile staging)['AWS_PROFILE'] | Should -Be 'staging'
    }
    It 'flag: exports nothing (the dir goes via a flag)' {
        (Get-ClikaeProfileEnv -Cli vercel -Profile prod).Count | Should -Be 0
    }
}

Describe 'Get-ClikaeFlagArgs (flag strategy)' {
    It 'returns the flag and the profile dir for a flag adapter' {
        $dir  = Get-ClikaeProfileDir -Cli vercel -Profile prod
        $args = Get-ClikaeFlagArgs -Cli vercel -Profile prod
        $args[0] | Should -Be '--global-config'
        $args[1] | Should -Be $dir
    }
    It 'returns nothing for an env-strategy adapter' {
        (Get-ClikaeFlagArgs -Cli claude -Profile work).Count | Should -Be 0
    }
    It 'flag-strategy function block injects the flag, not an env assignment' {
        $block = Get-ClikaeFunctionBlock -Cli vercel -Profile prod
        $block | Should -Match 'function vercel-prod'
        $block | Should -Match "--global-config"
        $block | Should -Not -Match "env:"
        { [scriptblock]::Create($block) } | Should -Not -Throw
    }
}

Describe 'Test-ClikaeName' {
    It 'accepts valid names' {
        Test-ClikaeName -Name 'work'   | Should -BeTrue
        Test-ClikaeName -Name 'work.1' | Should -BeTrue
        Test-ClikaeName -Name 'a-b_c'  | Should -BeTrue
    }
    It 'rejects empty, leading-dot, slashes and whitespace' {
        Test-ClikaeName -Name ''        | Should -BeFalse
        Test-ClikaeName -Name '.hidden' | Should -BeFalse
        Test-ClikaeName -Name 'a/b'     | Should -BeFalse
        Test-ClikaeName -Name 'a b'     | Should -BeFalse
    }
}

Describe 'New-ClikaeProfile / Get-ClikaeProfile' {
    It 'creates the profile directory' {
        New-ClikaeProfile -Cli claude -Profile solo -ProfilePath $script:ProfileScript | Out-Null
        Get-ClikaeProfileDir -Cli claude -Profile solo | Should -Exist
    }
    It 'lists the created profile' {
        $p = Get-ClikaeProfile -Cli claude | Where-Object Profile -eq 'solo'
        $p | Should -Not -BeNullOrEmpty
        $p.Cli | Should -Be 'claude'
    }
    It 'rejects an invalid profile name' {
        { New-ClikaeProfile -Cli claude -Profile '.bad' -ProfilePath $script:ProfileScript } | Should -Throw
    }
}

Describe 'Add-ClikaeFunction ($PROFILE block)' {
    BeforeEach {
        $script:PS = Join-Path $script:TestRoot ("p-" + [Guid]::NewGuid().ToString('N') + '.ps1')
    }

    It 'writes a sentinel-wrapped function for the profile' {
        Add-ClikaeFunction -Cli claude -Profile work -ProfilePath $script:PS
        $content = Get-Content -LiteralPath $script:PS -Raw
        $content | Should -Match '# >>> clikae:claude\.work >>>'
        $content | Should -Match '# <<< clikae:claude\.work <<<'
        $content | Should -Match 'function claude-work'
        $content | Should -Match "env:CLAUDE_CONFIG_DIR"
    }

    It 'is idempotent — re-running replaces, never duplicates the block' {
        Add-ClikaeFunction -Cli claude -Profile work -ProfilePath $script:PS
        Add-ClikaeFunction -Cli claude -Profile work -ProfilePath $script:PS
        $opens = (Get-Content -LiteralPath $script:PS | Where-Object { $_ -eq '# >>> clikae:claude.work >>>' }).Count
        $opens | Should -Be 1
    }

    It 'preserves unrelated profile-script content' {
        Set-Content -LiteralPath $script:PS -Value @('# my profile', 'Set-Alias g git')
        Add-ClikaeFunction -Cli gh -Profile personal -ProfilePath $script:PS
        $content = Get-Content -LiteralPath $script:PS -Raw
        $content | Should -Match 'Set-Alias g git'
        $content | Should -Match 'function gh-personal'
    }

    It 'backs up an existing profile script before editing' {
        Set-Content -LiteralPath $script:PS -Value '# seed'
        Add-ClikaeFunction -Cli gh -Profile personal -ProfilePath $script:PS
        (Get-ChildItem -LiteralPath (Split-Path $script:PS) -Filter '*.clikae.bak.*').Count | Should -BeGreaterThan 0
    }

    It 'produces a syntactically valid, definable function' {
        $block = Get-ClikaeFunctionBlock -Cli claude -Profile work
        { [scriptblock]::Create($block) } | Should -Not -Throw
        . ([scriptblock]::Create($block))
        Get-Command claude-work -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Remove-ClikaeProfile' {
    BeforeEach {
        $script:PS = Join-Path $script:TestRoot ("r-" + [Guid]::NewGuid().ToString('N') + '.ps1')
        New-ClikaeProfile -Cli docker -Profile temp -Alias -ProfilePath $script:PS | Out-Null
    }

    It 'removes the directory and the function block' {
        Remove-ClikaeProfile -Cli docker -Profile temp -Force -ProfilePath $script:PS
        Get-ClikaeProfileDir -Cli docker -Profile temp | Should -Not -Exist
        (Get-Content -LiteralPath $script:PS -Raw) | Should -Not -Match 'clikae:docker\.temp'
    }

    It '-KeepData keeps the directory but removes the function block' {
        $dir = Get-ClikaeProfileDir -Cli docker -Profile temp
        Remove-ClikaeProfile -Cli docker -Profile temp -Force -KeepData -ProfilePath $script:PS
        $dir | Should -Exist
        (Get-Content -LiteralPath $script:PS -Raw) | Should -Not -Match 'clikae:docker\.temp'
    }

    It 'handles a missing directory without error (block-only removal)' {
        Remove-Item -LiteralPath (Get-ClikaeProfileDir -Cli docker -Profile temp) -Recurse -Force
        { Remove-ClikaeProfile -Cli docker -Profile temp -Force -ProfilePath $script:PS } | Should -Not -Throw
    }
}

Describe 'Invoke-ClikaeProfile' {
    It 'fails clearly when the CLI binary is not on PATH' {
        # 'claude' is not installed on the CI runner.
        { Invoke-ClikaeProfile -Cli claude -Profile work } | Should -Throw '*not on PATH*'
    }
}

Describe 'ConvertTo-ClikaeJsonArray' {
    It 'renders an empty input as []' {
        ConvertTo-ClikaeJsonArray -Items @()   | Should -Be '[]'
        ConvertTo-ClikaeJsonArray -Items $null | Should -Be '[]'
    }
    It 'wraps a SINGLE object in an array (the WinPS 5.1 trap)' {
        $json = ConvertTo-ClikaeJsonArray -Items @([pscustomobject]@{ a = 1 })
        $json | Should -Match '^\['
        $json | Should -Match '\]$'
        # WinPS 5.1 trap: ConvertFrom-Json emits an array as ONE non-enumerated
        # pipeline object, so @(... | ConvertFrom-Json) collects it as a single
        # element (Count 1). Assign first, THEN force-array — portable on 5.1 & 7+.
        $parsed = $json | ConvertFrom-Json
        $parsed = @($parsed)
        $parsed.Count | Should -Be 1
        $parsed[0].a  | Should -Be 1
    }
    It 'renders multiple objects as a 2-element array' {
        $json = ConvertTo-ClikaeJsonArray -Items @(
            [pscustomobject]@{ a = 1 }, [pscustomobject]@{ a = 2 })
        $parsed = $json | ConvertFrom-Json
        $parsed = @($parsed)
        $parsed.Count | Should -Be 2
    }
}

Describe 'Get-ClikaeProfile -Json' {
    It 'emits [] when no profiles match' {
        Get-ClikaeProfile -Cli no-such-cli -Json | Should -Be '[]'
    }
    It 'emits a JSON array of {Cli, Profile, Path}' {
        New-ClikaeProfile -Cli gh -Profile jsontest -ProfilePath $script:ProfileScript | Out-Null
        $json   = Get-ClikaeProfile -Cli gh -Json
        $json | Should -Match '^\['
        $parsed = $json | ConvertFrom-Json
        $parsed = @($parsed)
        ($parsed | Where-Object Profile -eq 'jsontest') | Should -Not -BeNullOrEmpty
        ($parsed | Where-Object Profile -eq 'jsontest').Cli | Should -Be 'gh'
    }
}

Describe 'Get-ClikaeStatus (status equivalent)' {
    BeforeAll {
        # Save any real values so we can restore them; these tests mutate env vars.
        $script:SavedClaude = $env:CLAUDE_CONFIG_DIR
        $script:SavedAws    = $env:AWS_PROFILE
        $script:SavedHelm   = $env:HELM_CONFIG_HOME
    }
    AfterAll {
        $env:CLAUDE_CONFIG_DIR = $script:SavedClaude
        $env:AWS_PROFILE       = $script:SavedAws
        $env:HELM_CONFIG_HOME  = $script:SavedHelm
    }
    BeforeEach {
        Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:AWS_PROFILE       -ErrorAction SilentlyContinue
        Remove-Item Env:HELM_CONFIG_HOME  -ErrorAction SilentlyContinue
    }

    It 'reports a flag-strategy adapter as state=flag with a null env var' {
        $s = Get-ClikaeStatus -Cli vercel
        $s.State  | Should -Be 'flag'
        $s.EnvVar | Should -BeNullOrEmpty
    }

    It 'reports an unset env var as state=default' {
        $s = Get-ClikaeStatus -Cli helm
        $s.State  | Should -Be 'default'
        $s.EnvVar | Should -Be 'HELM_CONFIG_HOME'
    }

    It 'resolves an env-dir value pointing at a clikae profile to state=active' {
        New-ClikaeProfile -Cli claude -Profile statusdir -ProfilePath $script:ProfileScript | Out-Null
        $env:CLAUDE_CONFIG_DIR = Get-ClikaeProfileDir -Cli claude -Profile statusdir
        $s = Get-ClikaeStatus -Cli claude
        $s.State   | Should -Be 'active'
        $s.Profile | Should -Be 'statusdir'
    }

    It 'reports an env var pointing somewhere unknown as state=external' {
        $env:CLAUDE_CONFIG_DIR = Join-Path ([System.IO.Path]::GetTempPath()) 'not-a-clikae-profile'
        $s = Get-ClikaeStatus -Cli claude
        $s.State   | Should -Be 'external'
        $s.Profile | Should -BeNullOrEmpty
    }

    It 'env-var strategy: an existing profile name resolves to active' {
        New-ClikaeProfile -Cli aws -Profile staging -ProfilePath $script:ProfileScript | Out-Null
        $env:AWS_PROFILE = 'staging'
        $s = Get-ClikaeStatus -Cli aws
        $s.State   | Should -Be 'active'
        $s.Profile | Should -Be 'staging'
    }

    It 'env-var strategy: an unknown profile name is external' {
        $env:AWS_PROFILE = 'ghost-profile'
        $s = Get-ClikaeStatus -Cli aws
        $s.State | Should -Be 'external'
    }

    It '-Json always emits a JSON array, even for a single CLI' {
        $json = Get-ClikaeStatus -Cli vercel -Json
        $json | Should -Match '^\['
        $json | Should -Match '\]$'
        $parsed = $json | ConvertFrom-Json
        $parsed = @($parsed)
        $parsed.Count    | Should -Be 1
        $parsed[0].State | Should -Be 'flag'
    }

    It 'rejects an unknown CLI' {
        { Get-ClikaeStatus -Cli nope } | Should -Throw
    }
}
