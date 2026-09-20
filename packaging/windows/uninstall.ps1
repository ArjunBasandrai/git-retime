#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Destination = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs/git-retime')
)

$ErrorActionPreference = 'Stop'
$resolved = [IO.Path]::GetFullPath($Destination)
if ($PSCmdlet.ShouldProcess($resolved, 'Remove the git-retime installation')) {
    foreach ($name in @('git-retime.cmd', 'git-retime.ps1', 'GitRetime')) {
        $target = Join-Path $resolved $name
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    }
    if ((Test-Path -LiteralPath $resolved) -and -not (Get-ChildItem -LiteralPath $resolved -Force)) { Remove-Item -LiteralPath $resolved }
    [Console]::Out.WriteLine("Removed git-retime from $resolved")
}
