$privateFiles = @(
    'Private/Common.ps1'
    'Private/Dates.ps1'
    'Private/Repository.ps1'
    'Private/Plan.ps1'
    'Private/Rewrite.ps1'
    'Private/Commands.ps1'
)

foreach ($file in $privateFiles) {
    . (Join-Path $PSScriptRoot $file)
}

Export-ModuleMember -Function Invoke-GitRetime
