# powershell

Reserved for v0.4 — Windows support via a PowerShell module.

The plan:

- `ClaudeProfiles.psm1` provides `New-ClikaeProfile`, `Get-ClikaeProfile`,
  `Remove-ClikaeProfile`, `Invoke-ClikaeProfile` functions.
- Alias generation writes a function into `$PROFILE` instead of an alias
  (PowerShell aliases can't carry env vars).
- The `.app` generator obviously has no equivalent on Windows; instead we'll
  generate a `.bat` / `.lnk` shortcut you can pin to the Start menu or Taskbar.

PRs from Windows PowerShell folks very welcome.
