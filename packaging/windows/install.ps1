#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $Destination = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs/git-retime')
)

$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot
[IO.Directory]::CreateDirectory($Destination) | Out-Null
Copy-Item -LiteralPath (Join-Path $source 'git-retime.cmd') -Destination $Destination -Force
Copy-Item -LiteralPath (Join-Path $source 'git-retime.ps1') -Destination $Destination -Force
$moduleDestination = Join-Path $Destination 'GitRetime'
if (Test-Path -LiteralPath $moduleDestination) { Remove-Item -LiteralPath $moduleDestination -Recurse -Force }
Copy-Item -LiteralPath (Join-Path $source 'GitRetime') -Destination $Destination -Recurse
[Console]::Out.WriteLine("Installed git-retime in $Destination")
[Console]::Out.WriteLine('Add this directory to PATH to use "git retime" from all repositories.')
