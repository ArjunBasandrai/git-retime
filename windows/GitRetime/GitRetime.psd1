@{
    RootModule = 'GitRetime.psm1'
    ModuleVersion = '0.1.0'
    GUID = '2f828bea-b865-4ec4-b526-cbe06e21563d'
    Author = 'git-retime contributors'
    Description = 'Rewrite Git commit timestamps with raw object operations.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @('Invoke-GitRetime')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            LicenseUri = 'https://www.apache.org/licenses/LICENSE-2.0'
            Tags = @('Git', 'Timestamp', 'History')
        }
    }
}
