#Requires -Version 7.4
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Arguments
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GitRetime/GitRetime.psd1') -Force

try {
    Invoke-GitRetime -Arguments $Arguments
} catch {
    $code = if ($_.Exception.Data.Contains('GitRetimeExitCode')) { [int]$_.Exception.Data['GitRetimeExitCode'] } else { 8 }
    [Console]::Error.WriteLine("git-retime: {0}" -f $_.Exception.Message)
    exit $code
}
