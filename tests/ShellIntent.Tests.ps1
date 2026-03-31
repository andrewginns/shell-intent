$repoRoot = Split-Path -Parent $PSScriptRoot
$moduleManifestPath = Join-Path $repoRoot 'ShellIntent\ShellIntent.psd1'
$installScriptPath = Join-Path $repoRoot 'install.ps1'

function New-ShellIntentTestRoot {
    $testRoot = Join-Path $env:TEMP ("shell-intent-tests-{0}" -f [guid]::NewGuid())
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    return $testRoot
}

function New-ShellIntentInstallFixture {
    $testRoot = New-ShellIntentTestRoot
    $repoCopy = Join-Path $testRoot 'repo'
    $copiedInstallScriptPath = Join-Path $repoCopy 'install.ps1'
    $copiedModulePath = Join-Path $repoCopy 'ShellIntent'

    New-Item -ItemType Directory -Path $repoCopy | Out-Null
    Copy-Item -LiteralPath $installScriptPath -Destination $copiedInstallScriptPath -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'ShellIntent') -Destination $copiedModulePath -Recurse -Force

    return @{
        TestRoot = $testRoot
        RepoRoot = $repoCopy
        InstallScriptPath = $copiedInstallScriptPath
        ModulePath = $copiedModulePath
    }
}

function Get-ShellIntentEnterKeyHandler {
    return Get-PSReadLineKeyHandler -Bound | Where-Object { $_.Key -eq 'Enter' } | Select-Object -First 1
}

function Get-ShellIntentPendingCommandName {
    $module = Get-Module ShellIntent
    return & $module { $script:ShellIntentPendingCommandName }
}

function Get-ShellIntentCafeString {
    return "caf$([char] 0x00E9)"
}

function Import-ShellIntentInstallFunctions {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScriptPath, [ref] $tokens, [ref] $parseErrors)

    if ($parseErrors) {
        throw "Failed to parse install.ps1 for helper import."
    }

    $functionDefinitions = @(
        $ast.FindAll(
            {
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            },
            $false
        ) | ForEach-Object { $_.Extent.Text }
    )

    Invoke-Expression ($functionDefinitions -join "`r`n`r`n")
}

Describe 'ShellIntent input routing' {
    BeforeEach {
        Remove-Module ShellIntent -ErrorAction SilentlyContinue
        Import-Module $moduleManifestPath -Force
    }

    It 'accepts PowerShell parameters on alias commands' {
        foreach ($line in @('ls -Force', 'dir -Path .', 'mkdir -Name demo')) {
            (Get-ShellIntentInputDisposition $line) | Should Be 'accept'
        }
    }

    It 'accepts PowerShell parameter abbreviations on alias commands' {
        foreach ($line in @('ls -for .', 'dir -pa .', 'mkdir -n demo')) {
            (Get-ShellIntentInputDisposition $line) | Should Be 'accept'
        }
    }

    It 'accepts provider-specific filesystem parameters on alias commands' {
        foreach ($line in @('ls -File', 'ls -Directory', 'dir -Hidden', 'dir -ReadOnly')) {
            (Get-ShellIntentInputDisposition $line) | Should Be 'accept'
        }
    }

    It 'treats ProgressAction according to the current PowerShell version' {
        $expectedDisposition = if ($PSVersionTable.PSVersion -ge [version] '7.4') { 'accept' } else { 'codex' }

        foreach ($line in @('ls -ProgressAction SilentlyContinue', 'dir -ProgressAction SilentlyContinue')) {
            (Get-ShellIntentInputDisposition $line) | Should Be $expectedDisposition
        }
    }

    It 'still routes provider-specific parameters through Codex for unsupported providers' {
        if (Test-Path HKLM:\) {
            foreach ($line in @(
                'dir HKLM:\ -File',
                'dir HKLM:\ -Directory',
                'dir -Filter foo -Path HKLM:\ -File',
                'dir -Include *.txt -Path HKLM:\ -Directory',
                'dir -LiteralPath HKLM:\ -File'
            )) {
                (Get-ShellIntentInputDisposition $line) | Should Be 'codex'
            }
        }
    }

    It 'still routes bash-style alias flags through Codex' {
        foreach ($line in @('ls -a', 'ls -la', 'mkdir -p demo')) {
            (Get-ShellIntentInputDisposition $line) | Should Be 'codex'
        }
    }

    It 'still routes invalid alias flags through Codex' {
        foreach ($line in @('ls -zz .', 'dir -zz .', 'mkdir -zz demo')) {
            (Get-ShellIntentInputDisposition $line) | Should Be 'codex'
        }
    }

    It 'still routes ambiguous alias flags through Codex' {
        foreach ($line in @('ls -f .', 'dir -f .', 'mkdir -i Directory demo -WhatIf')) {
            (Get-ShellIntentInputDisposition $line) | Should Be 'codex'
        }
    }

    It 'accepts resolved PowerShell commands that start with keyword-like verbs' {
        foreach ($line in @('Write-Output $env:OPENAI_API_KEY', 'Write-Host test', 'where.exe git')) {
            (Get-ShellIntentInputDisposition $line) | Should Be 'accept'
        }
    }

    It 'accepts PowerShell commands with trailing question-mark wildcards' {
        foreach ($line in @('Get-ChildItem foo?', 'Test-Path .\file?')) {
            (Get-ShellIntentInputDisposition $line) | Should Be 'accept'
        }
    }

    It 'routes explicitly prefixed commands through Codex' {
        foreach ($line in @('?git status', '?Get-ChildItem foo?')) {
            (Get-ShellIntentInputDisposition $line) | Should Be 'codex'
        }
    }

    It 'does not treat trailing question marks on valid commands as Codex requests' {
        foreach ($line in @('git status?', 'Get-ChildItem foo?')) {
            (Get-ShellIntentInputDisposition $line) | Should Be 'accept'
        }
    }

    It 'accepts quoted leading-dash literals on alias commands' {
        foreach ($line in @("ls '-foo'", 'dir "-bar"')) {
            (Get-ShellIntentInputDisposition $line) | Should Be 'accept'
        }
    }

    It 'does not execute dynamicparam blocks while classifying alias input' {
        $global:ShellIntentDynamicParameterProbeCount = 0

        function global:Get-ChildItem {
            [CmdletBinding()]
            param(
                [string] $Path
            )

            dynamicparam {
                $global:ShellIntentDynamicParameterProbeCount++

                $attributes = [System.Collections.ObjectModel.Collection[System.Attribute]]::new()
                $attributes.Add([System.Management.Automation.ParameterAttribute]::new())

                $parameter = [System.Management.Automation.RuntimeDefinedParameter]::new('Danger', [string], $attributes)
                $parameters = [System.Management.Automation.RuntimeDefinedParameterDictionary]::new()
                $parameters.Add('Danger', $parameter)

                return $parameters
            }

            process {
            }
        }

        try {
            (Get-ShellIntentInputDisposition 'ls -Danger value') | Should Be 'codex'
            $global:ShellIntentDynamicParameterProbeCount | Should Be 0
        } finally {
            Remove-Item function:Get-ChildItem -ErrorAction SilentlyContinue
            Remove-Variable -Scope Global -Name ShellIntentDynamicParameterProbeCount -ErrorAction SilentlyContinue
        }
    }

    It 'still routes natural-language questions through Codex' {
        (Get-ShellIntentInputDisposition 'why is git failing?') | Should Be 'codex'
    }

    It 'treats && and || according to the current PowerShell version' {
        $expectedDisposition = if ($PSVersionTable.PSVersion.Major -ge 7) { 'accept' } else { 'codex' }
        (Get-ShellIntentInputDisposition 'git diff && git status') | Should Be $expectedDisposition
        (Get-ShellIntentInputDisposition 'git diff || git status') | Should Be $expectedDisposition
    }
}

Describe 'install.ps1 profile updates' {
    It 'writes the bridge snippet when the profile does not exist yet' {
        $testRoot = New-ShellIntentTestRoot

        try {
            $moduleInstallRoot = Join-Path $testRoot 'Modules'
            $profilePath = Join-Path $testRoot 'profile.ps1'

            & $installScriptPath -ModuleInstallRoot $moduleInstallRoot -ProfilePath $profilePath | Out-Null

            $profileContent = Get-Content -LiteralPath $profilePath -Raw
            $profileBytes = [System.IO.File]::ReadAllBytes($profilePath)
            $moduleManifestPath = Join-Path $moduleInstallRoot 'ShellIntent\ShellIntent.psd1'

            $profileContent | Should Match '(?m)^# ShellIntent$'
            $profileContent | Should Match '(?m)^if \(Get-Module -Name ShellIntent\) {$'
            $profileContent | Should Match '(?m)^\$null = Disable-ShellIntent$'
            $profileContent | Should Match '(?m)^Remove-Module ShellIntent -Force -ErrorAction SilentlyContinue$'
            $profileContent | Should Match ([regex]::Escape("Import-Module '$moduleManifestPath' -Force"))
            $profileContent | Should Match "\$null = Enable-ShellIntent -TerminalProcessNames @\('warp\.exe'\) -ForcePrefix '\?'"
            $profileBytes[0] | Should Be 239
            $profileBytes[1] | Should Be 187
            $profileBytes[2] | Should Be 191
        } finally {
            if (Test-Path -LiteralPath $testRoot) {
                Remove-Item -LiteralPath $testRoot -Recurse -Force
            }
        }
    }

    It 'replaces an existing bridge snippet when install arguments change' {
        $testRoot = New-ShellIntentTestRoot

        try {
            $moduleInstallRoot = Join-Path $testRoot 'Modules'
            $profilePath = Join-Path $testRoot 'profile.ps1'

            Set-Content -LiteralPath $profilePath -Value '# existing profile'

            & $installScriptPath -ModuleInstallRoot $moduleInstallRoot -ProfilePath $profilePath -ForcePrefix '?' | Out-Null
            & $installScriptPath -ModuleInstallRoot $moduleInstallRoot -ProfilePath $profilePath -ForcePrefix '!' -AlwaysEnable | Out-Null

            $profileContent = Get-Content -LiteralPath $profilePath -Raw

            $profileContent.StartsWith('# existing profile') | Should Be $true
            $profileContent | Should Match "\$null = Enable-ShellIntent -TerminalProcessNames @\('warp\.exe'\) -ForcePrefix '!'"
            $profileContent | Should Match '-AlwaysEnable'
            $profileContent | Should Not Match "\$null = Enable-ShellIntent -TerminalProcessNames @\('warp\.exe'\) -ForcePrefix '\?'"
            ([regex]::Matches($profileContent, '(?m)^# ShellIntent$').Count) | Should Be 1
        } finally {
            if (Test-Path -LiteralPath $testRoot) {
                Remove-Item -LiteralPath $testRoot -Recurse -Force
            }
        }
    }

    It 'writes a silent profile that can import from a custom module root' {
        $testRoot = New-ShellIntentTestRoot

        try {
            $moduleInstallRoot = Join-Path $testRoot 'Modules'
            $profilePath = Join-Path $testRoot 'profile.ps1'
            $expectedModuleBase = Join-Path $moduleInstallRoot 'ShellIntent'

            & $installScriptPath -ModuleInstallRoot $moduleInstallRoot -ProfilePath $profilePath | Out-Null

            Remove-Module ShellIntent -ErrorAction SilentlyContinue
            $profileOutput = & { . $profilePath }
            $importedModule = Get-Module ShellIntent

            $profileOutput | Should Be $null
            $importedModule | Should Not Be $null
            $importedModule.ModuleBase | Should Be $expectedModuleBase
        } finally {
            Disable-ShellIntent
            Remove-Module ShellIntent -ErrorAction SilentlyContinue

            if (Test-Path -LiteralPath $testRoot) {
                Remove-Item -LiteralPath $testRoot -Recurse -Force
            }
        }
    }

    It 'replaces an already-loaded ShellIntent module when sourcing the generated profile' {
        $testRoot = New-ShellIntentTestRoot

        try {
            $moduleInstallRoot = Join-Path $testRoot 'Modules'
            $profilePath = Join-Path $testRoot 'profile.ps1'
            $expectedModuleBase = Join-Path $moduleInstallRoot 'ShellIntent'

            & $installScriptPath -ModuleInstallRoot $moduleInstallRoot -ProfilePath $profilePath | Out-Null

            Remove-Module ShellIntent -ErrorAction SilentlyContinue
            Import-Module $moduleManifestPath -Force

            $profileOutput = & { . $profilePath }
            $loadedModules = @(Get-Module ShellIntent)
            $commandModuleBase = (Get-Command Get-ShellIntentInputDisposition).Module.ModuleBase

            $profileOutput | Should Be $null
            $loadedModules.Count | Should Be 1
            $loadedModules[0].ModuleBase | Should Be $expectedModuleBase
            $commandModuleBase | Should Be $expectedModuleBase
        } finally {
            Disable-ShellIntent
            Remove-Module ShellIntent -ErrorAction SilentlyContinue

            if (Test-Path -LiteralPath $testRoot) {
                Remove-Item -LiteralPath $testRoot -Recurse -Force
            }
        }
    }

    It 'preserves a Unicode profile encoding when updating the bridge snippet' {
        $testRoot = New-ShellIntentTestRoot

        try {
            $moduleInstallRoot = Join-Path $testRoot 'Modules'
            $profilePath = Join-Path $testRoot 'profile.ps1'
            $cafe = Get-ShellIntentCafeString

            Set-Content -LiteralPath $profilePath -Value "Write-Output '$cafe'" -Encoding Unicode

            & $installScriptPath -ModuleInstallRoot $moduleInstallRoot -ProfilePath $profilePath | Out-Null

            $profileBytes = [System.IO.File]::ReadAllBytes($profilePath)
            $profileOutput = & powershell -NoProfile -File $profilePath

            $profileBytes[0] | Should Be 255
            $profileBytes[1] | Should Be 254
            (($profileOutput -join "`n").Trim()) | Should Be $cafe
        } finally {
            Remove-Module ShellIntent -ErrorAction SilentlyContinue

            if (Test-Path -LiteralPath $testRoot) {
                Remove-Item -LiteralPath $testRoot -Recurse -Force
            }
        }
    }

    It 'preserves BOM-less UTF-8 profile content by rewriting with a readable BOM' {
        $testRoot = New-ShellIntentTestRoot

        try {
            $moduleInstallRoot = Join-Path $testRoot 'Modules'
            $profilePath = Join-Path $testRoot 'profile.ps1'
            $cafe = Get-ShellIntentCafeString
            $utf8EncodingWithoutBom = New-Object System.Text.UTF8Encoding($false)

            [System.IO.File]::WriteAllText($profilePath, "Write-Output '$cafe'`r`n", $utf8EncodingWithoutBom)

            & $installScriptPath -ModuleInstallRoot $moduleInstallRoot -ProfilePath $profilePath | Out-Null

            $profileBytes = [System.IO.File]::ReadAllBytes($profilePath)
            $profileOutput = & powershell -NoProfile -File $profilePath

            $profileBytes[0] | Should Be 239
            $profileBytes[1] | Should Be 187
            $profileBytes[2] | Should Be 191
            (($profileOutput -join "`n").Trim()) | Should Be $cafe
        } finally {
            Remove-Module ShellIntent -ErrorAction SilentlyContinue

            if (Test-Path -LiteralPath $testRoot) {
                Remove-Item -LiteralPath $testRoot -Recurse -Force
            }
        }
    }

    It 'preserves ANSI profile encoding when updating the bridge snippet' {
        $testRoot = New-ShellIntentTestRoot

        try {
            $moduleInstallRoot = Join-Path $testRoot 'Modules'
            $profilePath = Join-Path $testRoot 'profile.ps1'
            $cafe = Get-ShellIntentCafeString
            $ansiEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)

            [System.IO.File]::WriteAllText($profilePath, "Write-Output '$cafe'`r`n", $ansiEncoding)

            & $installScriptPath -ModuleInstallRoot $moduleInstallRoot -ProfilePath $profilePath | Out-Null

            $profileBytes = [System.IO.File]::ReadAllBytes($profilePath)
            $profileText = [System.IO.File]::ReadAllText($profilePath, $ansiEncoding)
            $profileOutput = & powershell -NoProfile -File $profilePath

            ($profileBytes[0] -eq 239 -and $profileBytes[1] -eq 187 -and $profileBytes[2] -eq 191) | Should Be $false
            $profileText | Should Match ([regex]::Escape("Write-Output '$cafe'"))
            (($profileOutput -join "`n").Trim()) | Should Be $cafe
        } finally {
            Remove-Module ShellIntent -ErrorAction SilentlyContinue

            if (Test-Path -LiteralPath $testRoot) {
                Remove-Item -LiteralPath $testRoot -Recurse -Force
            }
        }
    }

    It 'supports home-relative profile paths when updating the bridge snippet' {
        $testRoot = New-ShellIntentTestRoot

        try {
            $moduleInstallRoot = Join-Path $testRoot 'Modules'
            $profileLeafName = "shell-intent-profile-{0}.ps1" -f [guid]::NewGuid()
            $profilePath = Join-Path '~' $profileLeafName
            $resolvedProfilePath = Join-Path $HOME $profileLeafName

            if (Test-Path -LiteralPath $resolvedProfilePath) {
                Remove-Item -LiteralPath $resolvedProfilePath -Force
            }

            & $installScriptPath -ModuleInstallRoot $moduleInstallRoot -ProfilePath $profilePath | Out-Null

            (Test-Path -LiteralPath $resolvedProfilePath) | Should Be $true
            (Get-Content -LiteralPath $resolvedProfilePath -Raw) | Should Match '(?m)^# ShellIntent$'
        } finally {
            Remove-Module ShellIntent -ErrorAction SilentlyContinue

            if (Test-Path -LiteralPath $resolvedProfilePath) {
                Remove-Item -LiteralPath $resolvedProfilePath -Force
            }

            if (Test-Path -LiteralPath $testRoot) {
                Remove-Item -LiteralPath $testRoot -Recurse -Force
            }
        }
    }

    It 'rejects an install root that resolves to the source module path' {
        $fixture = New-ShellIntentInstallFixture

        try {
            $profilePath = Join-Path $fixture.TestRoot 'profile.ps1'
            $errorMessage = $null

            try {
                & $fixture.InstallScriptPath -ModuleInstallRoot $fixture.RepoRoot -ProfilePath $profilePath | Out-Null
            } catch {
                $errorMessage = $_.Exception.Message
            }

            $errorMessage | Should Match 'overlaps the source module path'
            (Test-Path -LiteralPath $fixture.ModulePath) | Should Be $true
        } finally {
            if (Test-Path -LiteralPath $fixture.TestRoot) {
                Remove-Item -LiteralPath $fixture.TestRoot -Recurse -Force
            }
        }
    }

    It 'rejects an install root nested under the source module path' {
        $fixture = New-ShellIntentInstallFixture

        try {
            $profilePath = Join-Path $fixture.TestRoot 'profile.ps1'
            $nestedInstallRoot = Join-Path $fixture.ModulePath 'NestedRoot'
            $errorMessage = $null

            try {
                & $fixture.InstallScriptPath -ModuleInstallRoot $nestedInstallRoot -ProfilePath $profilePath | Out-Null
            } catch {
                $errorMessage = $_.Exception.Message
            }

            $errorMessage | Should Match 'overlaps the source module path'
            (Test-Path -LiteralPath $fixture.ModulePath) | Should Be $true
        } finally {
            if (Test-Path -LiteralPath $fixture.TestRoot) {
                Remove-Item -LiteralPath $fixture.TestRoot -Recurse -Force
            }
        }
    }

    It 'rejects an install root that resolves into the source tree through a junction' {
        $fixture = New-ShellIntentInstallFixture
        $junctionRoot = Join-Path $fixture.TestRoot 'junction-root'

        try {
            $profilePath = Join-Path $fixture.TestRoot 'profile.ps1'
            $errorMessage = $null

            New-Item -ItemType Junction -Path $junctionRoot -Target $fixture.RepoRoot | Out-Null

            try {
                & $fixture.InstallScriptPath -ModuleInstallRoot $junctionRoot -ProfilePath $profilePath | Out-Null
            } catch {
                $errorMessage = $_.Exception.Message
            }

            $errorMessage | Should Match 'overlaps the source module path'
            (Test-Path -LiteralPath $fixture.ModulePath) | Should Be $true
        } finally {
            if (Test-Path -LiteralPath $junctionRoot) {
                try {
                    [System.IO.Directory]::Delete($junctionRoot)
                } catch {
                }
            }

            if (Test-Path -LiteralPath $fixture.TestRoot) {
                Remove-Item -LiteralPath $fixture.TestRoot -Recurse -Force
            }
        }
    }

    It 'restores the previous installed module if atomic promotion fails' {
        $fixture = New-ShellIntentInstallFixture

        try {
            Import-ShellIntentInstallFunctions

            $moduleInstallRoot = Join-Path $fixture.TestRoot 'Modules'
            $destinationModulePath = Join-Path $moduleInstallRoot 'ShellIntent'
            $sentinelPath = Join-Path $destinationModulePath 'sentinel.txt'

            New-Item -ItemType Directory -Force -Path $moduleInstallRoot | Out-Null
            Copy-Item -LiteralPath $fixture.ModulePath -Destination $destinationModulePath -Recurse -Force
            Set-Content -LiteralPath $sentinelPath -Value 'original'

            {
                Install-ModuleDirectoryAtomically `
                    -SourcePath $fixture.ModulePath `
                    -DestinationPath $destinationModulePath `
                    -BeforePromoteAction { throw 'simulated promote failure' }
            } | Should Throw

            (Test-Path -LiteralPath $sentinelPath) | Should Be $true
            ((Get-Content -LiteralPath $sentinelPath -Raw).Trim()) | Should Be 'original'
            @(
                Get-ChildItem -LiteralPath $moduleInstallRoot -Filter 'ShellIntent.backup.*' -ErrorAction SilentlyContinue
            ).Count | Should Be 0
            @(
                Get-ChildItem -LiteralPath $moduleInstallRoot -Filter 'ShellIntent.staged.*' -ErrorAction SilentlyContinue
            ).Count | Should Be 0
        } finally {
            if (Test-Path -LiteralPath $fixture.TestRoot) {
                Remove-Item -LiteralPath $fixture.TestRoot -Recurse -Force
            }
        }
    }
}

Describe 'ShellIntent PSReadLine lifecycle' {
    BeforeEach {
        Remove-Module ShellIntent -ErrorAction SilentlyContinue
        Import-Module $moduleManifestPath -Force
        Import-Module PSReadLine -ErrorAction Stop
        Set-PSReadLineKeyHandler -Chord Enter -Function AcceptLine
    }

    AfterEach {
        if (Get-Command -Name Disable-ShellIntent -ErrorAction SilentlyContinue) {
            Disable-ShellIntent
        }

        Set-PSReadLineKeyHandler -Chord Enter -Function AcceptLine
        Remove-Module ShellIntent -ErrorAction SilentlyContinue
    }

    It 'restores a previous custom Enter handler on disable' {
        Set-PSReadLineKeyHandler -Chord Enter -BriefDescription 'TestEnterHandler' -ScriptBlock {
            param($key, $arg)
            [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine($key, $arg)
        }

        $before = Get-ShellIntentEnterKeyHandler

        (Enable-ShellIntent -AlwaysEnable) | Should Be $true
        Disable-ShellIntent

        $after = Get-ShellIntentEnterKeyHandler

        $after.Function | Should Be $before.Function
        $after.Description | Should Be $before.Description
    }

    It 'registers a callable pending bridge command in global scope' {
        (Enable-ShellIntent -AlwaysEnable -CodexExecutable '__missing_codex__') | Should Be $true

        $pendingCommandName = Get-ShellIntentPendingCommandName

        (Get-Command $pendingCommandName).CommandType | Should Be 'Function'

        $global:ShellIntentPendingQuery = '?demo'
        (& $pendingCommandName) | Should Match "Codex executable '__missing_codex__' was not found."

        { Get-Variable -Scope Global -Name ShellIntentPendingQuery -ErrorAction Stop } | Should Throw
    }

    It 'falls back to AcceptLine when the saved Enter handler is unavailable' {
        Set-PSReadLineKeyHandler -Chord Enter -Function HistorySearchBackward

        (Enable-ShellIntent -AlwaysEnable) | Should Be $true
        & (Get-Module ShellIntent) {
            $script:ShellIntentSavedEnterHandler = $null
        }

        Disable-ShellIntent

        (Get-ShellIntentEnterKeyHandler).Function | Should Be 'AcceptLine'
    }

    It 'falls back to AcceptLine when Enter binding inspection is unavailable during disable' {
        Set-PSReadLineKeyHandler -Chord Enter -Function HistorySearchBackward

        (Enable-ShellIntent -AlwaysEnable) | Should Be $true
        $module = Get-Module ShellIntent
        & $module {
            Set-Item function:Get-ShellIntentPSReadLineEnterBinding -Value { return $null }
            Set-Item function:Get-ShellIntentPublicPSReadLineEnterBinding -Value {
                return [pscustomobject]@{
                    Function = $script:ShellIntentEnterHandlerBriefDescription
                }
            }
        }

        Disable-ShellIntent

        (Get-ShellIntentEnterKeyHandler).Function | Should Be 'AcceptLine'
    }

    It 'does not overwrite a newer Enter handler set after enable' {
        Set-PSReadLineKeyHandler -Chord Enter -Function HistorySearchBackward

        (Enable-ShellIntent -AlwaysEnable) | Should Be $true
        Set-PSReadLineKeyHandler -Chord Enter -Function AcceptLine
        Disable-ShellIntent

        (Get-ShellIntentEnterKeyHandler).Function | Should Be 'AcceptLine'
    }

    It 'cleans up pending helper commands when enable fails during setup' {
        $before = Get-ShellIntentEnterKeyHandler
        $module = Get-Module ShellIntent

        try {
            & $module {
                Set-Item function:Register-ShellIntentPendingCommand -Value { throw 'simulated pending command registration failure' }
            }

            { Enable-ShellIntent -AlwaysEnable } | Should Throw
        } finally {
            & $module {
                Remove-Item function:Register-ShellIntentPendingCommand -ErrorAction SilentlyContinue
            }
        }

        @(
            Get-ChildItem function:__shell_intent* -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        ).Count | Should Be 0
        { Get-Variable -Scope Global -Name ShellIntentPendingQuery -ErrorAction Stop } | Should Throw
        (Get-ShellIntentEnterKeyHandler).Function | Should Be $before.Function
        (Get-ShellIntentEnterKeyHandler).Description | Should Be $before.Description
    }

    It 'restores the original Enter handler after sourcing the generated profile twice' {
        $testRoot = New-ShellIntentTestRoot

        try {
            $moduleInstallRoot = Join-Path $testRoot 'Modules'
            $profilePath = Join-Path $testRoot 'profile.ps1'

            & $installScriptPath -ModuleInstallRoot $moduleInstallRoot -ProfilePath $profilePath -AlwaysEnable | Out-Null

            Set-PSReadLineKeyHandler -Chord Enter -Function HistorySearchBackward
            $before = Get-ShellIntentEnterKeyHandler

            & { . $profilePath } | Out-Null
            & { . $profilePath } | Out-Null
            Disable-ShellIntent

            $after = Get-ShellIntentEnterKeyHandler

            $after.Function | Should Be $before.Function
            $after.Description | Should Be $before.Description
        } finally {
            Disable-ShellIntent
            Remove-Module ShellIntent -ErrorAction SilentlyContinue

            if (Test-Path -LiteralPath $testRoot) {
                Remove-Item -LiteralPath $testRoot -Recurse -Force
            }
        }
    }

    It 'does not leak pending helper commands when the generated profile is sourced repeatedly' {
        $testRoot = New-ShellIntentTestRoot

        try {
            $moduleInstallRoot = Join-Path $testRoot 'Modules'
            $profilePath = Join-Path $testRoot 'profile.ps1'

            & $installScriptPath -ModuleInstallRoot $moduleInstallRoot -ProfilePath $profilePath -AlwaysEnable | Out-Null

            & { . $profilePath } | Out-Null
            & { . $profilePath } | Out-Null

            $pendingCommandsWhileEnabled = @(
                Get-ChildItem function:__shell_intent* -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
            )

            $pendingCommandsWhileEnabled.Count | Should Be 1

            Disable-ShellIntent

            @(
                Get-ChildItem function:__shell_intent* -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
            ).Count | Should Be 0
        } finally {
            Disable-ShellIntent
            Remove-Module ShellIntent -ErrorAction SilentlyContinue

            if (Test-Path -LiteralPath $testRoot) {
                Remove-Item -LiteralPath $testRoot -Recurse -Force
            }
        }
    }
}
