@{
    RootModule = 'ShellIntent.psm1'
    ModuleVersion = '0.1.0'
    GUID = '4f2fcdca-9ac4-4f7a-a20d-d367f3a8245c'
    Author = 'Andrew Ginns'
    CompanyName = 'Open Source'
    Copyright = '(c) Andrew Ginns. All rights reserved.'
    Description = 'Routes natural-language and bash-style PowerShell input through Codex.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Disable-ShellIntent',
        'Enable-ShellIntent',
        'Get-ShellIntentInputDisposition',
        'Invoke-ShellIntentQuery',
        'Test-ShellIntentHost'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('codex', 'powershell', 'warp', 'terminal', 'psreadline')
            ProjectUri = 'https://github.com/andrewginns/shell-intent'
        }
    }
}

