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
Running `. .\install.ps1` with no arguments targets Warp only.
The installer updates your PowerShell profile. To enable ShellIntent in the current session, either restart the terminal or run `. $PROFILE` after the install command.

### Warp On Windows PowerShell 5.1

Launch a Warp PowerShell tab and run:

```powershell
git clone git@github.com:andrewginns/shell-intent.git
cd shell-intent
Set-ExecutionPolicy -Scope Process Bypass
. .\install.ps1
. $PROFILE
```

### Windows Terminal On PowerShell 7 Or Windows PowerShell

Launch a Windows Terminal tab that uses either `pwsh` or Windows PowerShell and run:

```powershell
git clone git@github.com:andrewginns/shell-intent.git
cd shell-intent
Set-ExecutionPolicy -Scope Process Bypass
. .\install.ps1 -TerminalProcessNames @('WindowsTerminal.exe')
. $PROFILE
```

### VS Code Integrated Terminal

Launch the VS Code integrated terminal and run:

```powershell
git clone git@github.com:andrewginns/shell-intent.git
cd shell-intent
Set-ExecutionPolicy -Scope Process Bypass
. .\install.ps1 -TerminalProcessNames @('Code.exe')
. $PROFILE
```

### Plain powershell.exe Or pwsh

If you want ShellIntent in any PowerShell session, launch your preferred shell and run:

```powershell
git clone git@github.com:andrewginns/shell-intent.git
cd shell-intent
Set-ExecutionPolicy -Scope Process Bypass
. .\install.ps1 -AlwaysEnable
. $PROFILE
```

If you downloaded the repository as a ZIP instead of cloning it, open the extracted folder in the target terminal and run the same final two commands from there.

## Manual Profile Setup

If you do not want to use the installer, add this to your profile.
Replace `warp.exe` with the terminal host you actually use, such as `WindowsTerminal.exe` or `Code.exe`, or use `-AlwaysEnable` if you want ShellIntent in every PowerShell session.

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

## Troubleshooting

```powershell
Test-ShellIntentHost
Get-ShellIntentInputDisposition 'hey'
```

`Test-ShellIntentHost` should be `True` for the terminal you configured.
`Get-ShellIntentInputDisposition 'hey'` should return `codex`.

## Warp Note

Warp injects its own PowerShell helper script. On older PSReadLine builds, Warp can call unsupported `Set-PSReadLineOption` parameters during prompt redraw. The module includes a compatibility shim so the bridge can run without tripping that error path.
