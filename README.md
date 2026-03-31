# ShellIntent

`ShellIntent` is a PowerShell module that sends terminal input through Codex before execution.

It keeps normal PowerShell commands working as usual, but routes:

- natural-language input
- bash/zsh-style commands
- anything prefixed with `?`

to Codex for interpretation.

By default it:

- scopes activation to `warp.exe`
- uses `?` as the force-to-Codex prefix
- uses `gpt-5.3-codex-spark`
- sets reasoning to `medium`

## Example

```text
PS> Get-ChildItem
# runs directly in PowerShell

PS> ls -la
# routed through Codex and translated into PowerShell

PS> list files in this folder
# routed through Codex as natural language

PS> ?winget grep notepad
# forced through Codex even though it looks command-like
```

## Install

Open the terminal you want to use with ShellIntent, then run the matching commands there.

### Warp On Windows PowerShell 5.1

Launch a Warp PowerShell tab and run:

```powershell
git clone git@github.com:andrewginns/shell-intent.git
cd shell-intent
Set-ExecutionPolicy -Scope Process Bypass
. .\install.ps1
```

### Windows Terminal On PowerShell 7

Launch a Windows Terminal tab that uses `pwsh` and run:

```powershell
git clone git@github.com:andrewginns/shell-intent.git
cd shell-intent
. .\install.ps1 -TerminalProcessNames @('WindowsTerminal.exe')
```

### Windows Terminal On Windows PowerShell

Launch a Windows Terminal tab that uses Windows PowerShell and run:

```powershell
git clone git@github.com:andrewginns/shell-intent.git
cd shell-intent
Set-ExecutionPolicy -Scope Process Bypass
. .\install.ps1 -TerminalProcessNames @('WindowsTerminal.exe')
```

### Plain powershell.exe Or pwsh

If you want ShellIntent in any PowerShell session, launch your preferred shell and run:

```powershell
git clone git@github.com:andrewginns/shell-intent.git
cd shell-intent
Set-ExecutionPolicy -Scope Process Bypass
. .\install.ps1 -AlwaysEnable
```

If you downloaded the repository as a ZIP instead of cloning it, open the extracted folder in the target terminal and run the same final two commands from there.

## Manual Profile Setup

If you do not want to use the installer, add this to your profile:

```powershell
Import-Module ShellIntent
Enable-ShellIntent -TerminalProcessNames @('warp.exe') -ForcePrefix '?' -Model 'gpt-5.3-codex-spark' -ReasoningEffort 'medium'
```

## Behavior

### Runs Directly In PowerShell

```powershell
Get-ChildItem
git status
mkdir demo
```

### Goes Through Codex

```text
ls -la
find . -name *.ts
list files in this folder
?winget grep notepad
```

If the response contains alternatives, the final line is still one raw recommended PowerShell command.

## Useful Checks

```powershell
Test-ShellIntentHost
Get-ShellIntentInputDisposition 'ls -la'
Invoke-ShellIntentQuery '?ip a'
```

## Warp Note

Warp injects its own PowerShell helper script. On older PSReadLine builds, Warp can call unsupported `Set-PSReadLineOption` parameters during prompt redraw. The module includes a compatibility shim so the bridge can run without tripping that error path.
