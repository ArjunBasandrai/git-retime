#Requires -Version 7.4
[CmdletBinding()]
param([string] $DistributionDirectory)

$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ("git-retime-package-tests-{0}" -f [Guid]::NewGuid().ToString('N'))
$dist=if($DistributionDirectory){[IO.Path]::GetFullPath($DistributionDirectory)}else{Join-Path $testRoot dist}
[IO.Directory]::CreateDirectory($dist)|Out-Null

function Run([string]$File,[string[]]$Arguments,[string]$WorkingDirectory=''){
    $info=[Diagnostics.ProcessStartInfo]::new($File);$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;if($WorkingDirectory){$info.WorkingDirectory=$WorkingDirectory};foreach($argument in $Arguments){[void]$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($info);$outputTask=$process.StandardOutput.ReadToEndAsync();$errorTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit();[pscustomobject]@{ExitCode=$process.ExitCode;Output=$outputTask.GetAwaiter().GetResult();Error=$errorTask.GetAwaiter().GetResult()}
}

try{
    if(-not $DistributionDirectory){
        & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $projectRoot 'tools/build-release.ps1') -OutputDirectory $dist
        if($LASTEXITCODE){throw 'release build failed'}
    }
    $windowsArchive=Join-Path $dist 'git-retime-windows-0.1.0.zip';$unixArchive=Join-Path $dist 'git-retime-unix-0.1.0.tar.gz'
    foreach($path in @($windowsArchive,$unixArchive,(Join-Path $dist 'SHA256SUMS'))){if(-not(Test-Path -LiteralPath $path)){throw "missing release file: $path"}}
    $checksums=[IO.File]::ReadAllLines((Join-Path $dist 'SHA256SUMS'))
    foreach($archive in @($windowsArchive,$unixArchive)){$expected=($checksums|Where-Object{$_ -like "*  $([IO.Path]::GetFileName($archive))"}).Split(' ')[0];$actual=(Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant();if($expected-ne$actual){throw "checksum mismatch: $archive"}}
    [Console]::Out.WriteLine('ok 1 - release files and SHA-256 checksums')

    $windowsExtract=Join-Path $testRoot windows;Expand-Archive -LiteralPath $windowsArchive -DestinationPath $windowsExtract
    $windowsSource=Join-Path $windowsExtract 'git-retime-windows-0.1.0';$windowsInstall=Join-Path $testRoot windows-install
    $result=Run (Get-Process -Id $PID).Path @('-NoProfile','-File',(Join-Path $windowsSource 'install.ps1'),'-Destination',$windowsInstall)
    if($result.ExitCode){throw $result.Error}
    $version=Run (Get-Process -Id $PID).Path @('-NoProfile','-File',(Join-Path $windowsInstall 'git-retime.ps1'),'--version')
    if($version.ExitCode -or $version.Output.Trim()-ne'git-retime 0.1.0'){throw 'installed Windows command failed'}
    $repo=Join-Path $testRoot windows-repo;&git.exe init -q -b main $repo;&git.exe -C $repo config user.name Test;&git.exe -C $repo config user.email test@example.com;[IO.File]::WriteAllText((Join-Path $repo 'data'),"data`n");&git.exe -C $repo add data;&git.exe -C $repo commit -q -m data
    $result=Run (Get-Process -Id $PID).Path @('-NoProfile','-File',(Join-Path $windowsInstall 'git-retime.ps1'),'shift','--by','1h','--chronology','off') $repo;if($result.ExitCode){throw $result.Error}
    $result=Run (Get-Process -Id $PID).Path @('-NoProfile','-File',(Join-Path $windowsSource 'uninstall.ps1'),'-Destination',$windowsInstall,'-Confirm:$false');if($result.ExitCode){throw $result.Error};if(Test-Path -LiteralPath (Join-Path $windowsInstall 'git-retime.ps1')){throw 'Windows uninstall failed'}
    [Console]::Out.WriteLine('ok 2 - Windows archive clean install, operation, and uninstall')

    $linuxArchive="/mnt/$($unixArchive.Substring(0,1).ToLowerInvariant())/$($unixArchive.Substring(3).Replace('\','/'))";$token=[Guid]::NewGuid().ToString('N');$linuxRoot="/tmp/git-retime-package-$token";$linuxPrefix="$linuxRoot/prefix"
    $script=@'
set -e
mkdir -p '{0}'
tar -xzf '{1}' -C '{0}'
'{0}/git-retime-unix-0.1.0/install.sh' --prefix '{2}'
'{2}/bin/git-retime' --version | grep -Fx 'git-retime 0.1.0'
git init -q -b main '{0}/repo'
git -C '{0}/repo' config user.name Test
git -C '{0}/repo' config user.email test@example.com
echo data >'{0}/repo/data'
git -C '{0}/repo' add data
git -C '{0}/repo' commit -q -m data
cd '{0}/repo'
'{2}/bin/git-retime' shift --by 1h --chronology off >/dev/null
'{0}/git-retime-unix-0.1.0/uninstall.sh' --prefix '{2}'
test ! -e '{2}/bin/git-retime'
rm -rf -- '{0}'
'@ -f $linuxRoot,$linuxArchive,$linuxPrefix
    $result=Run wsl.exe @('-d','Ubuntu','--','bash','-lc',$script);if($result.ExitCode){throw $result.Error}
    [Console]::Out.WriteLine('ok 3 - UNIX archive clean install, operation, and uninstall')
    [Console]::Out.WriteLine('1..3')
}finally{
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
