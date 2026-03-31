# ShellIntent

`ShellIntent` is a PowerShell module that sends terminal input through Codex before execution.

It keeps normal PowerShell commands working as usual, but routes:

- natural-language input
- bash/zsh-style commands
- anything prefixed with `?`

to Codex for interpretation.

The response format is optimized for terminal use:

- brief explanation first
- the final line is always one raw recommended PowerShell command

## What It Solves

This gives you a "universal input" layer in PowerShell:

- `Get-ChildItem` runs normally
- `ls -la` gets translated by Codex
- `list files in this folder` gets interpreted by Codex
- `?winget grep notepad` forces Codex even if the input looks command-like

It works best in Warp, but it can be scoped to any terminal app by parent process name, or enabled for all PowerShell sessions.

## Files

- `ShellIntent/ShellIntent.psm1`
- `ShellIntent/ShellIntent.psd1`
- `install.ps1`

## Install

Run the installer from the PowerShell environment you want to target.

### Warp on Windows PowerShell 5.1

Run this from a Warp PowerShell tab:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
. .\install.ps1
```

By default this will:

- copy the module into your user module path
- update the current host profile
- scope activation to `warp.exe`
- use `?` as the force-to-Codex prefix
- use `gpt-5.3-codex-spark` with medium reasoning for the Codex bridge path

### PowerShell 7

Run the same installer from `pwsh`. It will target the PowerShell 7 user module path and PowerShell 7 current-host profile automatically.

### Any Terminal Host

Examples:

```powershell
. .\install.ps1 -TerminalProcessNames @('WindowsTerminal.exe')
```

```powershell
. .\install.ps1 -TerminalProcessNames @('warp.exe', 'WindowsTerminal.exe')
```

```powershell
. .\install.ps1 -AlwaysEnable
```

## Manual Profile Setup

If you do not want to use the installer, add this to your profile:

```powershell
Import-Module ShellIntent
Enable-ShellIntent -TerminalProcessNames @('warp.exe') -ForcePrefix '?' -Model 'gpt-5.3-codex-spark' -ReasoningEffort 'medium'
```

## Behavior

### Normal commands

These execute directly in PowerShell:

```powershell
Get-ChildItem
git status
mkdir demo
```

### Codex-translated commands

These go through Codex:

```text
ls -la
find . -name *.ts
list files in this folder
?winget grep notepad
```

### Forced Codex prefix

Any line starting with `?` bypasses the detector and goes straight to Codex.

Examples:

```text
?ip a
?why is git failing
?winget grep notepad
```

If the response contains alternatives, the last line is still the primary raw command, for example:

```text
Closest PowerShell equivalent for `ip a` is `Get-NetIPConfiguration`.

If you only want assigned IPs, use `Get-NetIPAddress`.

Get-NetIPConfiguration
```

## Exported Functions

- `Enable-ShellIntent`
- `Disable-ShellIntent`
- `Test-ShellIntentHost`
- `Get-ShellIntentInputDisposition`
- `Invoke-ShellIntentQuery`

Useful checks:

```powershell
Test-ShellIntentHost
Get-ShellIntentInputDisposition 'ls -la'
Invoke-ShellIntentQuery '?ip a'
```

## Warp Compatibility Note

Warp injects its own PowerShell helper script. On older PSReadLine builds, Warp can call unsupported `Set-PSReadLineOption` parameters during prompt redraw. The module includes a compatibility shim for Warp so the bridge can run without tripping that error path.

## Publishing

### GitHub

1. Put these files in a repository, for example `shell-intent`.
2. Tag releases.
3. Tell users to clone or download the repo and run `install.ps1`.

### PowerShell Gallery

1. Update the metadata in the module manifest.
2. Version the module properly.
3. Publish with:

```powershell
Publish-Module -Path .\ShellIntent -NuGetApiKey <your-key>
```

Then users can install with:

```powershell
Install-Module ShellIntent
```

and add the profile line manually.

## Suggested Packaging Strategy

If you want this to be broadly reusable, ship it in three layers:

1. PowerShell module: the real functionality
2. installer script: the easy path for end users
3. README + examples: host-specific setup for Warp, Windows Terminal, plain `powershell.exe`, and `pwsh`

That keeps the bridge logic testable and lets users adopt it without editing a long profile by hand.
