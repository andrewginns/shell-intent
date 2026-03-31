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

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $providerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    return [System.IO.Path]::GetFullPath($providerPath)
}

function Resolve-ReparsePointTargetPath {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo] $Item
    )

    $targetValues = @()

    foreach ($propertyName in @('Target', 'LinkTarget')) {
        $property = $Item.PSObject.Properties[$propertyName]
        if (-not $property) {
            continue
        }

        $targetValues = @(
            @($property.Value) | Where-Object {
                $_ -and -not [string]::IsNullOrWhiteSpace([string] $_)
            }
        )

        if ($targetValues.Count -gt 0) {
            break
        }
    }

    if ($targetValues.Count -ne 1) {
        throw "Cannot resolve the reparse point target for '$($Item.FullName)'."
    }

    $targetPath = [string] $targetValues[0]
    if (-not [System.IO.Path]::IsPathRooted($targetPath)) {
        $targetPath = Join-Path (Split-Path -Path $Item.FullName -Parent) $targetPath
    }

    return Resolve-AbsolutePath -Path $targetPath
}

function Resolve-CanonicalPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $fullPath = Resolve-AbsolutePath -Path $Path
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)

    if (-not $pathRoot) {
        return $fullPath
    }

    $currentPath = [System.IO.Path]::GetFullPath($pathRoot)
    $relativePath = $fullPath.Substring($pathRoot.Length)
    $segments = @(
        $relativePath -split '[\\/]+' | Where-Object { $_ }
    )

    if ($segments.Count -eq 0) {
        return $currentPath
    }

    foreach ($segment in $segments) {
        $candidatePath = Join-Path $currentPath $segment
        $item = $null

        try {
            $item = Get-Item -LiteralPath $candidatePath -Force -ErrorAction Stop
        } catch {
        }

        if (-not $item) {
            $currentPath = [System.IO.Path]::GetFullPath($candidatePath)
            continue
        }

        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) {
            $currentPath = Resolve-ReparsePointTargetPath -Item $item
            continue
        }

        $currentPath = Resolve-AbsolutePath -Path $candidatePath
    }

    return [System.IO.Path]::GetFullPath($currentPath)
}

function Test-DirectoryPathOverlap {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FirstPath,

        [Parameter(Mandatory = $true)]
        [string] $SecondPath
    )

    # Compare physical filesystem targets so junctions and symlinks cannot bypass overlap checks.
    $firstFullPath = (Resolve-CanonicalPath -Path $FirstPath).TrimEnd('\', '/')
    $secondFullPath = (Resolve-CanonicalPath -Path $SecondPath).TrimEnd('\', '/')

    if ($firstFullPath.Equals($secondFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $firstDirectoryPath = $firstFullPath + [System.IO.Path]::DirectorySeparatorChar
    $secondDirectoryPath = $secondFullPath + [System.IO.Path]::DirectorySeparatorChar

    return (
        $firstDirectoryPath.StartsWith($secondDirectoryPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $secondDirectoryPath.StartsWith($firstDirectoryPath, [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Test-ByteOrderMark {
    param(
        [byte[]] $Bytes,
        [byte[]] $Preamble
    )

    if (-not $Bytes -or -not $Preamble -or $Preamble.Length -eq 0 -or $Bytes.Length -lt $Preamble.Length) {
        return $false
    }

    for ($index = 0; $index -lt $Preamble.Length; $index++) {
        if ($Bytes[$index] -ne $Preamble[$index]) {
            return $false
        }
    }

    return $true
}

function Get-TextEncodingFromByteOrderMark {
    param(
        [byte[]] $Bytes
    )

    $encodings = @(
        (New-Object System.Text.UTF8Encoding($true)),
        (New-Object System.Text.UnicodeEncoding($false, $true)),
        (New-Object System.Text.UnicodeEncoding($true, $true)),
        (New-Object System.Text.UTF32Encoding($false, $true)),
        (New-Object System.Text.UTF32Encoding($true, $true))
    )

    foreach ($encoding in $encodings) {
        if (Test-ByteOrderMark -Bytes $Bytes -Preamble $encoding.GetPreamble()) {
            return $encoding
        }
    }

    return $null
}

function Get-StrictUtf8DecodedContent {
    param(
        [byte[]] $Bytes
    )

    $utf8Encoding = New-Object System.Text.UTF8Encoding($false, $true)

    try {
        return @{
            Success = $true
            Content = $utf8Encoding.GetString($Bytes)
        }
    } catch {
        return @{
            Success = $false
            Content = $null
        }
    }
}

function Get-LegacyTextEncoding {
    return [System.Text.Encoding]::Default
}

function Get-FileTextState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $defaultEncoding = New-Object System.Text.UTF8Encoding($true)
    $resolvedPath = Resolve-AbsolutePath -Path $Path

    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        return @{
            Content = ''
            Encoding = $defaultEncoding
        }
    }

    $bytes = [System.IO.File]::ReadAllBytes($resolvedPath)
    $encoding = Get-TextEncodingFromByteOrderMark -Bytes $bytes

    if ($encoding) {
        $preambleLength = $encoding.GetPreamble().Length
        $contentLength = $bytes.Length - $preambleLength
        $content = if ($contentLength -gt 0) {
            $encoding.GetString($bytes, $preambleLength, $contentLength)
        } else {
            ''
        }

        return @{
            Content = $content
            Encoding = $encoding
        }
    }

    $utf8DecodedContent = Get-StrictUtf8DecodedContent -Bytes $bytes
    if ($utf8DecodedContent.Success) {
        return @{
            Content = $utf8DecodedContent.Content
            Encoding = $defaultEncoding
        }
    }

    return @{
        Content = (Get-LegacyTextEncoding).GetString($bytes)
        Encoding = Get-LegacyTextEncoding
    }
}

function Set-ProfileSnippet {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Snippet,

        [string] $StartMarker = '# ShellIntent',

        [string] $EndMarker = '# End ShellIntent'
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    $profileState = Get-FileTextState -Path $resolvedPath
    $profileContent = $profileState.Content

    $lineEnding = if ($profileContent -match "`r`n") {
        "`r`n"
    } elseif ($profileContent -match "`n") {
        "`n"
    } else {
        "`r`n"
    }
    $snippetWithLineEnding = $Snippet + $lineEnding
    $pattern = "(?ms)^$([regex]::Escape($StartMarker))\r?\n.*?^$([regex]::Escape($EndMarker))(?:\r?\n)?"

    if ($profileContent -match $pattern) {
        $updatedProfileContent = [regex]::Replace($profileContent, $pattern, $snippetWithLineEnding)
    } else {
        $updatedProfileContent = $profileContent

        if ($updatedProfileContent -and $updatedProfileContent -notmatch '(?:\r?\n)\z') {
            $updatedProfileContent += $lineEnding
        }

        if ($updatedProfileContent) {
            $updatedProfileContent += $lineEnding
        }

        $updatedProfileContent += $snippetWithLineEnding
    }

    [System.IO.File]::WriteAllText($resolvedPath, $updatedProfileContent, $profileState.Encoding)
}

function Install-ModuleDirectoryAtomically {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourcePath,

        [Parameter(Mandatory = $true)]
        [string] $DestinationPath,

        [scriptblock] $BeforePromoteAction
    )

    $resolvedSourcePath = Resolve-AbsolutePath -Path $SourcePath
    $resolvedDestinationPath = Resolve-AbsolutePath -Path $DestinationPath
    $destinationParentPath = Split-Path -Path $resolvedDestinationPath -Parent
    $destinationLeafName = Split-Path -Path $resolvedDestinationPath -Leaf
    $stagedDestinationPath = Join-Path $destinationParentPath ("{0}.staged.{1}" -f $destinationLeafName, [guid]::NewGuid().ToString('N'))
    $backupDestinationPath = Join-Path $destinationParentPath ("{0}.backup.{1}" -f $destinationLeafName, [guid]::NewGuid().ToString('N'))
    $backupCreated = $false

    try {
        Copy-Item -LiteralPath $resolvedSourcePath -Destination $stagedDestinationPath -Recurse -Force

        if (-not (Test-Path -LiteralPath $stagedDestinationPath)) {
            throw "Failed to stage module copy at '$stagedDestinationPath'."
        }

        if (Test-Path -LiteralPath $resolvedDestinationPath) {
            Move-Item -LiteralPath $resolvedDestinationPath -Destination $backupDestinationPath -Force
            $backupCreated = $true
        }

        if ($BeforePromoteAction) {
            & $BeforePromoteAction $stagedDestinationPath $resolvedDestinationPath $backupDestinationPath
        }

        Move-Item -LiteralPath $stagedDestinationPath -Destination $resolvedDestinationPath -Force
    } catch {
        if (Test-Path -LiteralPath $stagedDestinationPath) {
            Remove-Item -LiteralPath $stagedDestinationPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        if (
            $backupCreated -and
            (Test-Path -LiteralPath $backupDestinationPath) -and
            -not (Test-Path -LiteralPath $resolvedDestinationPath)
        ) {
            Move-Item -LiteralPath $backupDestinationPath -Destination $resolvedDestinationPath -Force
        }

        throw
    }

    if (Test-Path -LiteralPath $backupDestinationPath) {
        Remove-Item -LiteralPath $backupDestinationPath -Recurse -Force -ErrorAction SilentlyContinue
    }
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

$resolvedProfilePath = Resolve-AbsolutePath -Path $ProfilePath
$destinationModulePath = Join-Path $ModuleInstallRoot $moduleName
$destinationModuleManifestPath = Join-Path $destinationModulePath "$moduleName.psd1"

if (Test-DirectoryPathOverlap -FirstPath $sourceModulePath -SecondPath $destinationModulePath) {
    $resolvedSourceModulePath = Resolve-AbsolutePath -Path $sourceModulePath
    $resolvedDestinationModulePath = Resolve-AbsolutePath -Path $destinationModulePath
    throw "Module install root resolves to '$resolvedDestinationModulePath', which overlaps the source module path '$resolvedSourceModulePath'. Choose a different install root."
}

New-Item -ItemType Directory -Force -Path $ModuleInstallRoot | Out-Null

Install-ModuleDirectoryAtomically -SourcePath $sourceModulePath -DestinationPath $destinationModulePath

$profileDirectory = Split-Path -Path $resolvedProfilePath -Parent
if ($profileDirectory) {
    New-Item -ItemType Directory -Force -Path $profileDirectory | Out-Null
}

if (-not (Test-Path -LiteralPath $resolvedProfilePath)) {
    New-Item -ItemType File -Path $resolvedProfilePath -Force | Out-Null
}

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

$escapedModuleManifestPath = $destinationModuleManifestPath.Replace("'", "''")

$snippet = @"
# ShellIntent
if (Get-Module -Name ShellIntent) {
`$null = Disable-ShellIntent
}
Remove-Module ShellIntent -Force -ErrorAction SilentlyContinue
Import-Module '$escapedModuleManifestPath' -Force
`$null = Enable-ShellIntent $($enableArguments -join ' ')
# End ShellIntent
"@

Set-ProfileSnippet -Path $resolvedProfilePath -Snippet $snippet

Write-Host "Installed module to: $destinationModulePath"
Write-Host "Updated profile: $resolvedProfilePath"
Write-Host "Restart the target terminal or run: . `"$resolvedProfilePath`""
