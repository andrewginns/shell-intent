Set-StrictMode -Version Latest

$script:ShellIntentConfig = @{
    TerminalProcessNames = @('warp.exe')
    ForcePrefix = '?'
    CodexExecutable = 'codex'
    Model = 'gpt-5.3-codex-spark'
    ReasoningEffort = 'medium'
    AlwaysEnable = $false
}

$script:ShellIntentEnterHandlerBriefDescription = 'ShellIntent.Enter'
$script:ShellIntentPendingCommandNamePrefix = '__shell_intent'
$script:ShellIntentPendingCommandName = '{0}_{1}' -f $script:ShellIntentPendingCommandNamePrefix, ([guid]::NewGuid().ToString('N'))
$script:ShellIntentSavedEnterHandler = $null

function Test-ShellIntentHost {
    [CmdletBinding()]
    param(
        [string[]] $TerminalProcessNames = $script:ShellIntentConfig.TerminalProcessNames
    )

    if (-not $TerminalProcessNames -or $TerminalProcessNames.Count -eq 0) {
        return $false
    }

    $expectedNames = @($TerminalProcessNames | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    if ($expectedNames.Count -eq 0) {
        return $false
    }

    try {
        $currentProcessId = [int] $PID

        for ($depth = 0; $depth -lt 8; $depth++) {
            $process = Get-CimInstance Win32_Process -Filter "ProcessId = $currentProcessId" -ErrorAction Stop

            if ($process.Name -and ($process.Name.ToLowerInvariant() -in $expectedNames)) {
                return $true
            }

            if (-not $process.ParentProcessId -or $process.ParentProcessId -eq $currentProcessId) {
                break
            }

            $currentProcessId = [int] $process.ParentProcessId
        }
    } catch {
        return $false
    }

    return $false
}

function Repair-ShellIntentHostCompatibility {
    [CmdletBinding()]
    param()

    if (-not (Test-ShellIntentHost -TerminalProcessNames @('warp.exe'))) {
        return
    }

    if (-not (Get-Command -Name Warp-Disable-PSPrediction -ErrorAction SilentlyContinue)) {
        return
    }

    function global:Warp-Disable-PSPrediction {
        [CmdletBinding()]
        param()

        try {
            $psReadLineOption = Get-Command -Name Set-PSReadLineOption -ErrorAction Stop

            if ($psReadLineOption.Parameters.ContainsKey('PredictionSource')) {
                Set-PSReadLineOption -PredictionSource None
            }

            if ($psReadLineOption.Parameters.ContainsKey('PredictionViewStyle')) {
                Set-PSReadLineOption -PredictionViewStyle InlineView
            }
        } catch {
        }
    }
}

function Get-ShellIntentPSReadLineEnterBinding {
    [CmdletBinding()]
    param()

    try {
        $bindingFlags = [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Static
        $psConsoleReadLineType = [Microsoft.PowerShell.PSConsoleReadLine]
        $singletonField = $psConsoleReadLineType.GetField('_singleton', $bindingFlags)
        $singleton = $singletonField.GetValue($null)

        if (-not $singleton) {
            return $null
        }

        $dispatchField = $psConsoleReadLineType.GetField('_dispatchTable', $bindingFlags)
        $dispatchTable = $dispatchField.GetValue($singleton)

        foreach ($entry in $dispatchTable.GetEnumerator()) {
            if ($entry.Key.ToString() -eq 'Enter') {
                return @{
                    DispatchTable = $dispatchTable
                    Key = $entry.Key
                    Handler = $entry.Value
                }
            }
        }
    } catch {
        return $null
    }

    return $null
}

function Test-ShellIntentBridgeEnterBinding {
    [CmdletBinding()]
    param(
        $Binding
    )

    if (-not $Binding -or -not $Binding.Handler) {
        return $false
    }

    return $Binding.Handler.BriefDescription -eq $script:ShellIntentEnterHandlerBriefDescription
}

function Get-ShellIntentPublicPSReadLineEnterBinding {
    [CmdletBinding()]
    param()

    try {
        return Get-PSReadLineKeyHandler -Bound | Where-Object { $_.Key -eq 'Enter' } | Select-Object -First 1
    } catch {
        return $null
    }
}

function Test-ShellIntentPublicBridgeEnterBinding {
    [CmdletBinding()]
    param(
        $Binding
    )

    if (-not $Binding) {
        return $false
    }

    return $Binding.Function -eq $script:ShellIntentEnterHandlerBriefDescription
}

function Save-ShellIntentPSReadLineEnterBinding {
    [CmdletBinding()]
    param()

    $currentBinding = Get-ShellIntentPSReadLineEnterBinding
    if (-not $currentBinding) {
        return
    }

    if (Test-ShellIntentBridgeEnterBinding -Binding $currentBinding) {
        return
    }

    $script:ShellIntentSavedEnterHandler = $currentBinding.Handler
}

function Restore-ShellIntentPSReadLineEnterBinding {
    [CmdletBinding()]
    param()

    try {
        $currentBinding = Get-ShellIntentPSReadLineEnterBinding

        if (
            $script:ShellIntentSavedEnterHandler -and
            $currentBinding -and
            (Test-ShellIntentBridgeEnterBinding -Binding $currentBinding)
        ) {
            $currentBinding.DispatchTable[$currentBinding.Key] = $script:ShellIntentSavedEnterHandler
        } elseif ($currentBinding -and (Test-ShellIntentBridgeEnterBinding -Binding $currentBinding)) {
            Set-PSReadLineKeyHandler -Chord Enter -Function AcceptLine
        } elseif (Test-ShellIntentPublicBridgeEnterBinding -Binding (Get-ShellIntentPublicPSReadLineEnterBinding)) {
            Set-PSReadLineKeyHandler -Chord Enter -Function AcceptLine
        }
    } finally {
        $script:ShellIntentSavedEnterHandler = $null
    }
}

function Remove-ShellIntentPendingCommands {
    [CmdletBinding()]
    param()

    Remove-Item "alias:$($script:ShellIntentPendingCommandNamePrefix)*" -ErrorAction SilentlyContinue
    Remove-Item "function:$($script:ShellIntentPendingCommandNamePrefix)*" -ErrorAction SilentlyContinue
}

function Resolve-ShellIntentCommandInfo {
    [CmdletBinding()]
    param(
        [string] $CommandName
    )

    if (-not $CommandName) {
        return $null
    }

    $commandInfo = Get-Command -Name $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $commandInfo) {
        return $null
    }

    if ($commandInfo.CommandType -eq [System.Management.Automation.CommandTypes]::Alias -and $commandInfo.Definition) {
        $resolvedCommand = Get-Command -Name $commandInfo.Definition -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($resolvedCommand) {
            return $resolvedCommand
        }
    }

    return $commandInfo
}

function Get-ShellIntentCommandArgumentList {
    [CmdletBinding()]
    param(
        [System.Management.Automation.Language.CommandAst] $CommandAst,

        [System.Management.Automation.CommandInfo] $CommandInfo
    )

    $argumentList = @()

    if ($CommandAst) {
        foreach ($element in ($CommandAst.CommandElements | Select-Object -Skip 1)) {
            $value = $null
            $isBareWordString = $false

            if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $value = $element.Value
                $isBareWordString = $element.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::BareWord
            } elseif ($element -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                $value = $element.Value
            }

            if (-not $value) {
                continue
            }

            if ($isBareWordString -and $value.StartsWith('-')) {
                continue
            }

            $argumentList += $value
        }
    }

    if ($argumentList.Count -eq 0 -and $CommandInfo -and $CommandInfo.Name -eq 'Get-ChildItem') {
        $argumentList = @((Get-Location).Path)
    }

    return $argumentList
}

function Get-ShellIntentNamedPathArgument {
    [CmdletBinding()]
    param(
        [System.Management.Automation.Language.CommandAst] $CommandAst,

        [string[]] $ParameterNames = @('Path', 'LiteralPath')
    )

    if (-not $CommandAst -or -not $ParameterNames -or $ParameterNames.Count -eq 0) {
        return $null
    }

    $commandElements = @($CommandAst.CommandElements | Select-Object -Skip 1)

    for ($index = 0; $index -lt $commandElements.Count; $index++) {
        $element = $commandElements[$index]
        if (-not ($element -is [System.Management.Automation.Language.CommandParameterAst])) {
            continue
        }

        if ($element.ParameterName -notin $ParameterNames) {
            continue
        }

        if ($element.Argument) {
            if ($element.Argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                return $element.Argument.Value
            }

            if ($element.Argument -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                return $element.Argument.Value
            }

            continue
        }

        if ($index + 1 -ge $commandElements.Count) {
            continue
        }

        $valueElement = $commandElements[$index + 1]
        if ($valueElement -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            return $valueElement.Value
        }

        if ($valueElement -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
            return $valueElement.Value
        }
    }

    return $null
}

function Get-ShellIntentProviderNameForPath {
    [CmdletBinding()]
    param(
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return (Get-Location).Provider.Name
    }

    if ($Path -match '^(?<provider>[^:]+)::') {
        $provider = Get-PSProvider -PSProvider $matches.provider -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($provider) {
            return $provider.Name
        }
    }

    if ($Path -match '^(?<drive>[^\\/:]+):(?:(\\|/)|$)') {
        $drive = Get-PSDrive -Name $matches.drive -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($drive) {
            return $drive.Provider.Name
        }
    }

    return (Get-Location).Provider.Name
}

function Get-ShellIntentCommandProviderName {
    [CmdletBinding()]
    param(
        [System.Management.Automation.Language.CommandAst] $CommandAst,

        [System.Management.Automation.CommandInfo] $CommandInfo,

        [object[]] $ArgumentList = @()
    )

    if (
        -not $CommandInfo -or
        $CommandInfo.CommandType -ne [System.Management.Automation.CommandTypes]::Cmdlet -or
        $CommandInfo.Name -ne 'Get-ChildItem'
    ) {
        return $null
    }

    $pathArgument = Get-ShellIntentNamedPathArgument -CommandAst $CommandAst
    if (-not $pathArgument) {
        $pathArgument = if ($ArgumentList -and $ArgumentList.Count -gt 0) {
        [string] $ArgumentList[0]
    } else {
        (Get-Location).Path
    }
    }

    return Get-ShellIntentProviderNameForPath -Path $pathArgument
}

function Test-ShellIntentHasParameter {
    [CmdletBinding()]
    param(
        [System.Management.Automation.CommandInfo] $CommandInfo,

        [string] $ParameterName,

        [string] $ProviderName
    )

    if (-not $CommandInfo -or -not $ParameterName) {
        return $false
    }

    $parameterMetadata = @{}

    $commonParameterNames = @(
        'Debug',
        'ErrorAction',
        'ErrorVariable',
        'InformationAction',
        'InformationVariable',
        'OutBuffer',
        'OutVariable',
        'PipelineVariable',
        'Verbose',
        'WarningAction',
        'WarningVariable'
    )

    if ($PSVersionTable.PSVersion -ge [version] '7.4') {
        $commonParameterNames += 'ProgressAction'
    }

    if ($commonParameterNames -contains $ParameterName) {
        return $true
    }

    $matchingCommonParameters = @(
        $commonParameterNames | Where-Object {
            $_.StartsWith($ParameterName, [System.StringComparison]::OrdinalIgnoreCase)
        }
    )

    if ($matchingCommonParameters.Count -eq 1) {
        return $true
    }

    try {
        $commandMetadata = [System.Management.Automation.CommandMetaData]::new($CommandInfo)

        foreach ($entry in $commandMetadata.Parameters.GetEnumerator()) {
            $parameterMetadata[$entry.Key] = $entry.Value
        }
    } catch {
    }

    if ($parameterMetadata.ContainsKey($ParameterName)) {
        return $true
    }

    $aliasMatches = @(
        $parameterMetadata.GetEnumerator() | Where-Object {
            $_.Value.Aliases -contains $ParameterName
        }
    )

    if ($aliasMatches.Count -eq 1) {
        return $true
    }

    if (
        $ProviderName -eq 'FileSystem' -and
        $CommandInfo.CommandType -eq [System.Management.Automation.CommandTypes]::Cmdlet -and
        $CommandInfo.Name -eq 'Get-ChildItem'
    ) {
        $fileSystemParameterNames = @('Directory', 'File', 'Hidden', 'ReadOnly')
        if ($fileSystemParameterNames -contains $ParameterName) {
            return $true
        }

        $matchingFileSystemParameters = @(
            ($parameterMetadata.Keys + $fileSystemParameterNames | Select-Object -Unique) | Where-Object {
                $_.StartsWith($ParameterName, [System.StringComparison]::OrdinalIgnoreCase)
            }
        )

        if ($matchingFileSystemParameters.Count -eq 1 -and $fileSystemParameterNames -contains $matchingFileSystemParameters[0]) {
            return $true
        }
    }

    $matchingParameters = @(
        $parameterMetadata.Keys | Where-Object {
            $_.StartsWith($ParameterName, [System.StringComparison]::OrdinalIgnoreCase)
        }
    )

    return $matchingParameters.Count -eq 1
}

function Test-ShellIntentNaturalLanguage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Line,

        [System.Management.Automation.Language.CommandAst] $CommandAst
    )

    $trimmedLine = $Line.Trim()

    if (-not $trimmedLine) {
        return $false
    }

    $commandName = $null
    if ($CommandAst) {
        $commandName = $CommandAst.GetCommandName()
    } elseif ($trimmedLine -match '^\s*(\S+)') {
        $commandName = $matches[1]
    }

    $resolvedCommand = $null
    if ($commandName) {
        $resolvedCommand = Get-Command -Name $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if (
        $resolvedCommand -and
        $resolvedCommand.CommandType -ne [System.Management.Automation.CommandTypes]::Alias
    ) {
        return $false
    }

    if ($trimmedLine -match '^(?:please|can|could|would|should|how|what|why|when|where|who|tell|show|explain|summarize|search|find|list|open|create|write|translate)\b' -and $trimmedLine -match '\s') {
        return $true
    }

    if ($trimmedLine -notmatch '\s') {
        return $false
    }

    if ($trimmedLine -match '[|;&><`$@(){}\[\]=]') {
        return $false
    }

    if (-not $resolvedCommand) {
        return $true
    }

    return $false
}

function Test-ShellIntentBashLikeInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Line,

        [System.Management.Automation.Language.CommandAst] $CommandAst
    )

    $trimmedLine = $Line.Trim()
    if (-not $trimmedLine) {
        return $false
    }

    if ($PSVersionTable.PSVersion.Major -lt 7 -and $trimmedLine -match '(^|\s)(?:&&|\|\|)(\s|$)') {
        return $true
    }

    if ($trimmedLine -match '^\s*(?:export|source|unset|alias|unalias|sudo)\b') {
        return $true
    }

    if ($trimmedLine -match '^\s*[A-Za-z_][A-Za-z0-9_]*=.+' -and $trimmedLine -notmatch '^\s*\$') {
        return $true
    }

    $commandName = $null
    if ($CommandAst) {
        $commandName = $CommandAst.GetCommandName()
    } elseif ($trimmedLine -match '^\s*(\S+)') {
        $commandName = $matches[1]
    }

    if (-not $commandName) {
        return $false
    }

    $normalizedCommand = $commandName.ToLowerInvariant()

    $alwaysBashCommands = @(
        'awk',
        'chmod',
        'chown',
        'export',
        'fgrep',
        'find',
        'grep',
        'less',
        'sed',
        'source',
        'sudo',
        'touch',
        'unalias',
        'unset',
        'which',
        'xargs'
    )

    if ($normalizedCommand -in $alwaysBashCommands) {
        return $true
    }

    $unixStyleAliases = @(
        'cat',
        'cp',
        'dir',
        'ls',
        'man',
        'mkdir',
        'mv',
        'ps',
        'pwd',
        'rm',
        'rmdir'
    )

    if ($normalizedCommand -notin $unixStyleAliases) {
        return $false
    }

    if (-not $CommandAst) {
        return $trimmedLine -match '(?:^|\s)--?[A-Za-z][A-Za-z-]+'
    }

    $resolvedCommandInfo = Resolve-ShellIntentCommandInfo -CommandName $commandName
    $commandArgumentList = Get-ShellIntentCommandArgumentList -CommandAst $CommandAst -CommandInfo $resolvedCommandInfo
    $commandProviderName = Get-ShellIntentCommandProviderName -CommandAst $CommandAst -CommandInfo $resolvedCommandInfo -ArgumentList $commandArgumentList

    foreach ($element in ($CommandAst.CommandElements | Select-Object -Skip 1)) {
        $value = $null
        $isBareWordString = $false

        if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $value = $element.Value
            $isBareWordString = $element.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::BareWord
        } elseif ($element -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
            $value = $element.Value
        } elseif ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
            if (($normalizedCommand -in @('dir', 'ls')) -and $element.ParameterName -eq 'a') {
                return $true
            }

            if ($normalizedCommand -eq 'mkdir' -and $element.ParameterName -eq 'p') {
                return $true
            }

            if (-not $resolvedCommandInfo) {
                if ($element.Extent.Text -match '^--[A-Za-z][A-Za-z-]*$' -or $element.Extent.Text -match '^-[A-Za-z]+$') {
                    return $true
                }

                continue
            }

            if (-not (Test-ShellIntentHasParameter -CommandInfo $resolvedCommandInfo -ParameterName $element.ParameterName -ProviderName $commandProviderName)) {
                return $true
            }

            continue
        }

        if (-not $value) {
            continue
        }

        if ($isBareWordString -and $value -match '^--[A-Za-z][A-Za-z-]*$') {
            return $true
        }

        if ($isBareWordString -and $value -match '^-[A-Za-z]+$') {
            return $true
        }

        if ($normalizedCommand -eq 'mkdir' -and $value -eq '-p') {
            return $true
        }
    }

    return $false
}

function Get-ShellIntentInputDisposition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Line
    )

    $trimmedLine = $Line.Trim()
    if (-not $trimmedLine) {
        return 'accept'
    }

    $forcePrefix = $script:ShellIntentConfig.ForcePrefix
    if ($forcePrefix -and $trimmedLine.StartsWith($forcePrefix)) {
        return 'codex'
    }

    if ($trimmedLine -match '^(?:codex|exit|logout)\b') {
        return 'accept'
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Line, [ref] $tokens, [ref] $parseErrors)

    if ($parseErrors -and ($parseErrors | Where-Object IncompleteInput)) {
        return 'accept'
    }

    $commandAst = $ast.Find(
        {
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        },
        $false
    ) | Select-Object -First 1

    if (Test-ShellIntentNaturalLanguage -Line $Line -CommandAst $commandAst) {
        return 'codex'
    }

    if (Test-ShellIntentBashLikeInput -Line $Line -CommandAst $commandAst) {
        return 'codex'
    }

    if (-not $commandAst) {
        if ($parseErrors) {
            return 'codex'
        }

        return 'accept'
    }

    $commandName = $commandAst.GetCommandName()
    if (-not $commandName) {
        return 'accept'
    }

    $commandInfo = Get-Command -Name $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $commandInfo) {
        return 'codex'
    }

    return 'accept'
}

function Invoke-ShellIntentQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Query
    )

    $trimmedQuery = $Query.Trim()
    $forcePrefix = $script:ShellIntentConfig.ForcePrefix
    if ($forcePrefix -and $trimmedQuery.StartsWith($forcePrefix)) {
        $trimmedQuery = $trimmedQuery.Substring($forcePrefix.Length).Trim()
    }

    if (-not $trimmedQuery) {
        if ($forcePrefix) {
            return "Type a query after '$forcePrefix', for example:`r`n${forcePrefix}winget grep notepad"
        }

        return "Type a Codex query."
    }

    $codexCommand = Get-Command -Name $script:ShellIntentConfig.CodexExecutable -ErrorAction SilentlyContinue
    if (-not $codexCommand) {
        return "Codex executable '$($script:ShellIntentConfig.CodexExecutable)' was not found."
    }

    $codexPrompt = @"
You are interpreting terminal input from a terminal running Windows PowerShell.

If the input is a bash/zsh command, translate it into the closest PowerShell command and explain briefly.
If the input is a natural-language request, answer it concisely and include commands when useful.
Do not execute commands. Respond as terminal guidance only.
Always recommend one primary PowerShell command.
The final line of your response must be exactly that primary recommended command, runnable as-is, with no backticks, code fences, bullets, labels, or commentary.
If you mention alternatives, mention them earlier in the response, but the last line must still be only the primary command.

Input:
$trimmedQuery
"@

    $outputPath = Join-Path $env:TEMP "shell-intent-$PID.txt"
    Remove-Item -LiteralPath $outputPath -ErrorAction SilentlyContinue

    $reasoningConfig = "model_reasoning_effort=`"$($script:ShellIntentConfig.ReasoningEffort)`""
    $codexArgs = @(
        'exec',
        '--skip-git-repo-check',
        '--sandbox', 'read-only',
        '--color', 'never',
        '--model', $script:ShellIntentConfig.Model,
        '-c', $reasoningConfig,
        '--cd', (Get-Location).Path,
        '--output-last-message', $outputPath,
        '-'
    )

    $null = $codexPrompt | & $script:ShellIntentConfig.CodexExecutable @codexArgs *> $null
    $exitCode = $LASTEXITCODE

    if (Test-Path -LiteralPath $outputPath) {
        return Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8
    }

    if ($exitCode -ne 0) {
        return "Codex query failed with exit code $exitCode."
    }

    return "Codex returned no output."
}

function Invoke-ShellIntentPendingQuery {
    [CmdletBinding()]
    param()

    $query = $global:ShellIntentPendingQuery
    Remove-Variable -Scope Global -Name ShellIntentPendingQuery -ErrorAction SilentlyContinue

    if ([string]::IsNullOrWhiteSpace($query)) {
        return
    }

    Invoke-ShellIntentQuery -Query $query
}

function Register-ShellIntentPendingCommand {
    [CmdletBinding()]
    param()

    Remove-ShellIntentPendingCommands

    $pendingCommandName = $script:ShellIntentPendingCommandName

    $functionDefinition = {
        [CmdletBinding()]
        param()

        $query = $global:ShellIntentPendingQuery
        Remove-Variable -Scope Global -Name ShellIntentPendingQuery -ErrorAction SilentlyContinue

        if ([string]::IsNullOrWhiteSpace($query)) {
            return
        }

        ShellIntent\Invoke-ShellIntentQuery -Query $query
    }.GetNewClosure()

    Set-Item "function:global:$pendingCommandName" -Value $functionDefinition
}

function Enable-ShellIntent {
    [CmdletBinding()]
    param(
        [string[]] $TerminalProcessNames = @('warp.exe'),

        [string] $ForcePrefix = '?',

        [string] $CodexExecutable = 'codex',

        [string] $Model = 'gpt-5.3-codex-spark',

        [ValidateSet('none', 'low', 'medium', 'high', 'xhigh')]
        [string] $ReasoningEffort = 'medium',

        [switch] $AlwaysEnable
    )

    $script:ShellIntentConfig = @{
        TerminalProcessNames = @($TerminalProcessNames)
        ForcePrefix = $ForcePrefix
        CodexExecutable = $CodexExecutable
        Model = $Model
        ReasoningEffort = $ReasoningEffort
        AlwaysEnable = [bool] $AlwaysEnable
    }

    if (-not $AlwaysEnable -and -not (Test-ShellIntentHost -TerminalProcessNames $TerminalProcessNames)) {
        return $false
    }

    if (-not (Get-Module -Name PSReadLine -ListAvailable)) {
        return $false
    }

    Repair-ShellIntentHostCompatibility
    Import-Module PSReadLine -ErrorAction SilentlyContinue
    Save-ShellIntentPSReadLineEnterBinding

    try {
        Set-PSReadLineKeyHandler -Chord Enter -BriefDescription $script:ShellIntentEnterHandlerBriefDescription -ScriptBlock {
            param($key, $arg)

            $line = $null
            $cursor = $null
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref] $line, [ref] $cursor)

            if ([string]::IsNullOrWhiteSpace($line)) {
                [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine($key, $arg)
                return
            }

            switch (Get-ShellIntentInputDisposition -Line $line) {
                'codex' {
                    [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($line)
                    $global:ShellIntentPendingQuery = $line
                    [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
                    [Microsoft.PowerShell.PSConsoleReadLine]::Insert($script:ShellIntentPendingCommandName)
                    [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine($key, $arg)
                    break
                }

                default {
                    [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine($key, $arg)
                    break
                }
            }
        }

        Register-ShellIntentPendingCommand
    } catch {
        Restore-ShellIntentPSReadLineEnterBinding
        Remove-ShellIntentPendingCommands
        Remove-Variable -Scope Global -Name ShellIntentPendingQuery -ErrorAction SilentlyContinue
        throw
    }

    return $true
}

function Disable-ShellIntent {
    [CmdletBinding()]
    param()

    if (Get-Module -Name PSReadLine -ListAvailable) {
        Import-Module PSReadLine -ErrorAction SilentlyContinue
        Restore-ShellIntentPSReadLineEnterBinding
    }

    Remove-ShellIntentPendingCommands
    Remove-Variable -Scope Global -Name ShellIntentPendingQuery -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function `
    Disable-ShellIntent, `
    Enable-ShellIntent, `
    Get-ShellIntentInputDisposition, `
    Invoke-ShellIntentQuery, `
    Test-ShellIntentHost
