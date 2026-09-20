#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $Version = '0.1.0',
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'dist' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ("git-retime-release-{0}" -f [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($stagingRoot) | Out-Null

try {
    $windowsName = "git-retime-windows-$Version"
    $windowsStage = Join-Path $stagingRoot $windowsName
    [IO.Directory]::CreateDirectory($windowsStage) | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'windows/git-retime.cmd'),(Join-Path $projectRoot 'windows/git-retime.ps1'),(Join-Path $projectRoot 'README.md'),(Join-Path $projectRoot 'LICENSE') -Destination $windowsStage
    Copy-Item -LiteralPath (Join-Path $projectRoot 'windows/GitRetime') -Destination $windowsStage -Recurse
    Copy-Item -LiteralPath (Join-Path $projectRoot 'docs') -Destination $windowsStage -Recurse
    Copy-Item -LiteralPath (Join-Path $projectRoot 'packaging/windows/install.ps1'),(Join-Path $projectRoot 'packaging/windows/uninstall.ps1') -Destination $windowsStage
    $windowsArchive = Join-Path $OutputDirectory "$windowsName.zip"
    if (Test-Path -LiteralPath $windowsArchive) { Remove-Item -LiteralPath $windowsArchive -Force }
    Compress-Archive -LiteralPath $windowsStage -DestinationPath $windowsArchive -CompressionLevel Optimal

    $unixName = "git-retime-unix-$Version"
    $unixStage = Join-Path $stagingRoot $unixName
    [IO.Directory]::CreateDirectory($unixStage) | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'bin'),(Join-Path $projectRoot 'lib'),(Join-Path $projectRoot 'docs') -Destination $unixStage -Recurse
    Copy-Item -LiteralPath (Join-Path $projectRoot 'README.md'),(Join-Path $projectRoot 'LICENSE') -Destination $unixStage
    Copy-Item -LiteralPath (Join-Path $projectRoot 'packaging/unix/install.sh'),(Join-Path $projectRoot 'packaging/unix/uninstall.sh') -Destination $unixStage
    $unixArchive = Join-Path $OutputDirectory "$unixName.tar.gz"
    if (Test-Path -LiteralPath $unixArchive) { Remove-Item -LiteralPath $unixArchive -Force }
    $linuxStage = "/mnt/$($stagingRoot.Substring(0,1).ToLowerInvariant())/$($stagingRoot.Substring(3).Replace('\','/'))"
    $linuxOutput = "/mnt/$($OutputDirectory.Substring(0,1).ToLowerInvariant())/$($OutputDirectory.Substring(3).Replace('\','/'))"
    & wsl.exe -d Ubuntu -- bash -lc "cd '$linuxStage' && chmod +x '$unixName/bin/git-retime' '$unixName/install.sh' '$unixName/uninstall.sh' && tar -czf '$linuxOutput/$unixName.tar.gz' '$unixName'"
    if ($LASTEXITCODE -ne 0) { throw 'UNIX archive creation failed' }

    $checksumLines = foreach ($archive in @($windowsArchive,$unixArchive)) {
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($archive))"
    }
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'SHA256SUMS'),($checksumLines -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
    $checksumLines | ForEach-Object { [Console]::Out.WriteLine($_) }
} finally {
    if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
}
