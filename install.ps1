[CmdletBinding()]
param(
    [string] $ModuleInstallRoot,

    [string] $ProfilePath,

    [string[]] $TerminalProcessNames = @('warp.exe'),

    [string] $ForcePrefix = '?',

    [string] $Model = 'gpt-5.3-codex-spark',

    [ValidateSet('none', 'low', 'medium', 'high', 'xhigh')]
    [string] $ReasoningEffort = 'medium',

    [switch] $AlwaysEnable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CurrentUserCurrentHostProfilePath {
    if ($PROFILE -is [string]) {
        return $PROFILE
    }

    return $PROFILE.CurrentUserCurrentHost
}

function Convert-ToPowerShellArrayLiteral {
    param(
        [string[]] $Values
    )

    $escaped = foreach ($value in $Values) {
        "'$($value.Replace("'", "''"))'"
    }

    return "@($($escaped -join ', '))"
}

$moduleName = 'ShellIntent'
$sourceModulePath = Join-Path $PSScriptRoot $moduleName

if (-not (Test-Path -LiteralPath $sourceModulePath)) {
    throw "Module source path '$sourceModulePath' was not found."
}

if (-not $ModuleInstallRoot) {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $ModuleInstallRoot = Join-Path $HOME 'Documents\PowerShell\Modules'
    } else {
        $ModuleInstallRoot = Join-Path $HOME 'Documents\WindowsPowerShell\Modules'
    }
}

if (-not $ProfilePath) {
    $ProfilePath = Get-CurrentUserCurrentHostProfilePath
}

$destinationModulePath = Join-Path $ModuleInstallRoot $moduleName
New-Item -ItemType Directory -Force -Path $ModuleInstallRoot | Out-Null

if (Test-Path -LiteralPath $destinationModulePath) {
    Remove-Item -LiteralPath $destinationModulePath -Recurse -Force
}

Copy-Item -LiteralPath $sourceModulePath -Destination $destinationModulePath -Recurse -Force

$profileDirectory = Split-Path -Path $ProfilePath -Parent
if ($profileDirectory) {
    New-Item -ItemType Directory -Force -Path $profileDirectory | Out-Null
}

if (-not (Test-Path -LiteralPath $ProfilePath)) {
    New-Item -ItemType File -Path $ProfilePath -Force | Out-Null
}

$profileContent = Get-Content -LiteralPath $ProfilePath -Raw -ErrorAction SilentlyContinue
$terminalProcessLiteral = Convert-ToPowerShellArrayLiteral -Values $TerminalProcessNames

$enableArguments = @(
    "-TerminalProcessNames $terminalProcessLiteral",
    "-ForcePrefix '$($ForcePrefix.Replace("'", "''"))'",
    "-Model '$($Model.Replace("'", "''"))'",
    "-ReasoningEffort '$ReasoningEffort'"
)

if ($AlwaysEnable) {
    $enableArguments += '-AlwaysEnable'
}

$snippet = @"
# ShellIntent
Import-Module ShellIntent
Enable-ShellIntent $($enableArguments -join ' ')
# End ShellIntent
"@

if ($profileContent -notmatch '(?m)^# ShellIntent$') {
    Add-Content -LiteralPath $ProfilePath -Value "`r`n$snippet"
}

Write-Host "Installed module to: $destinationModulePath"
Write-Host "Updated profile: $ProfilePath"
Write-Host "Restart the target terminal or run: . `"$ProfilePath`""

