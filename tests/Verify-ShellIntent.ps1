[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$moduleManifest = Join-Path $repoRoot 'ShellIntent\ShellIntent.psd1'
$installerPath = Join-Path $repoRoot 'install.ps1'

Import-Module PSReadLine -ErrorAction Stop
Import-Module $moduleManifest -Force

function Assert-True {
    param(
        [bool] $Condition,
        [string] $Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string] $Message
    )

    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message`nExpected: $Expected`nActual: $Actual"
    }
}

function Assert-Match {
    param(
        [string] $Text,
        [string] $Pattern,
        [string] $Message
    )

    if ($Text -notmatch $Pattern) {
        throw "Assertion failed: $Message`nPattern: $Pattern"
    }
}

$tempRoot = Join-Path $env:TEMP "shell-intent-verify-$PID"
Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

$moduleInstallRoot = Join-Path $tempRoot 'Modules'
$profilePath = Join-Path $tempRoot 'profile.ps1'
$installedModuleManifest = Join-Path $moduleInstallRoot 'ShellIntent\ShellIntent.psd1'

& $installerPath `
    -ModuleInstallRoot $moduleInstallRoot `
    -ProfilePath $profilePath `
    -TerminalProcessNames @('warp.exe') `
    -ForcePrefix '?' `
    -Model 'gpt-5.3-codex-spark' `
    -ReasoningEffort 'medium' | Out-Null

$firstProfileContent = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8

Assert-Match -Text $firstProfileContent -Pattern '(?m)^# ShellIntent$' -Message 'Fresh install should write the managed block start marker.'
Assert-Match -Text $firstProfileContent -Pattern '(?m)^if \(Get-Module -Name ShellIntent\) {$' -Message 'Fresh install should disable any loaded ShellIntent module before re-import.'
Assert-Match -Text $firstProfileContent -Pattern '(?m)^\$null = Disable-ShellIntent$' -Message 'Fresh install should tear down the ShellIntent bridge before reload.'
Assert-Match -Text $firstProfileContent -Pattern '(?m)^Remove-Module ShellIntent -Force -ErrorAction SilentlyContinue$' -Message 'Fresh install should remove any preloaded ShellIntent module before import.'
Assert-Match -Text $firstProfileContent -Pattern ([regex]::Escape("Import-Module '$installedModuleManifest' -Force")) -Message 'Fresh install should import the installed module manifest path.'
Assert-Match -Text $firstProfileContent -Pattern "Enable-ShellIntent -TerminalProcessNames @\('warp\.exe'\) -ForcePrefix '\?' -Model 'gpt-5\.3-codex-spark' -ReasoningEffort 'medium'" -Message 'Fresh install should write the configured enable command.'

& $installerPath `
    -ModuleInstallRoot $moduleInstallRoot `
    -ProfilePath $profilePath `
    -TerminalProcessNames @('WindowsTerminal.exe') `
    -ForcePrefix '!' `
    -Model 'gpt-5.3-codex-spark' `
    -ReasoningEffort 'low' | Out-Null

$secondProfileContent = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8
$managedBlockCount = ([regex]::Matches($secondProfileContent, '(?m)^# ShellIntent$')).Count

Assert-Equal -Expected 1 -Actual $managedBlockCount -Message 'Reinstall should keep exactly one managed ShellIntent block.'
Assert-Match -Text $secondProfileContent -Pattern "Enable-ShellIntent -TerminalProcessNames @\('WindowsTerminal\.exe'\) -ForcePrefix '!' -Model 'gpt-5\.3-codex-spark' -ReasoningEffort 'low'" -Message 'Reinstall should replace the managed block with the new options.'
Assert-True -Condition ($secondProfileContent -notmatch "Enable-ShellIntent -TerminalProcessNames @\('warp\.exe'\) -ForcePrefix '\?'") -Message 'Reinstall should not leave the old options behind.'

Remove-Module ShellIntent -ErrorAction SilentlyContinue
Import-Module $moduleManifest -Force
$profileOutput = & { . $profilePath }
$loadedModules = @(Get-Module ShellIntent)
$commandModuleBase = (Get-Command Get-ShellIntentInputDisposition).Module.ModuleBase
$expectedModuleBase = Join-Path $moduleInstallRoot 'ShellIntent'

Assert-True -Condition ($null -eq $profileOutput) -Message 'Sourcing the generated profile should stay silent.'
Assert-Equal -Expected 1 -Actual $loadedModules.Count -Message 'Sourcing the generated profile should leave only the installed ShellIntent module loaded.'
Assert-Equal -Expected $expectedModuleBase -Actual $loadedModules[0].ModuleBase -Message 'Sourcing the generated profile should replace the repo module with the installed copy.'
Assert-Equal -Expected $expectedModuleBase -Actual $commandModuleBase -Message 'ShellIntent commands should come from the installed module after sourcing the generated profile.'

Set-PSReadLineKeyHandler -Chord Enter -Function HistorySearchBackward
$beforeProfileReload = Get-PSReadLineKeyHandler | Where-Object Key -eq 'Enter' | Select-Object -First 1

$null = & { . $profilePath }
$null = & { . $profilePath }
Disable-ShellIntent

$afterProfileReloadDisable = Get-PSReadLineKeyHandler | Where-Object Key -eq 'Enter' | Select-Object -First 1
$remainingPendingCommands = @(
    Get-ChildItem function:__shell_intent* -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
)

Assert-Equal -Expected $beforeProfileReload.Function -Actual $afterProfileReloadDisable.Function -Message 'Reloading the generated profile should preserve the original Enter handler.'
Assert-Equal -Expected 0 -Actual $remainingPendingCommands.Count -Message 'Reloading the generated profile should not leave stale pending helper commands behind.'

Set-PSReadLineKeyHandler -Chord Enter -BriefDescription 'VerifyCustomEnter' -ScriptBlock {
    param($key, $arg)
}

$beforeDisable = Get-PSReadLineKeyHandler | Where-Object Key -eq 'Enter' | Select-Object -First 1

$enabled = Enable-ShellIntent -AlwaysEnable
Assert-True -Condition $enabled -Message 'Enable-ShellIntent should succeed when forced on.'

$duringEnable = Get-PSReadLineKeyHandler | Where-Object Key -eq 'Enter' | Select-Object -First 1
Assert-Equal -Expected 'ShellIntent.Enter' -Actual $duringEnable.Function -Message 'Enable-ShellIntent should replace Enter with the ShellIntent handler.'

Disable-ShellIntent

$afterDisable = Get-PSReadLineKeyHandler | Where-Object Key -eq 'Enter' | Select-Object -First 1
Assert-Equal -Expected $beforeDisable.Function -Actual $afterDisable.Function -Message 'Disable-ShellIntent should restore the previous Enter handler function.'
Assert-Equal -Expected 'codex' -Actual (Get-ShellIntentInputDisposition '?winget grep notepad') -Message 'The force prefix should still route to Codex.'

Write-Host 'ShellIntent verification passed.'
