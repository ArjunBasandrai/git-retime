#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$root=Join-Path ([IO.Path]::GetTempPath()) ("git-retime-windows-stress-{0}" -f [Guid]::NewGuid().ToString('N'))
$repo=Join-Path $root repo
[IO.Directory]::CreateDirectory($root)|Out-Null
try{
    $generation=Measure-Command{& (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $projectRoot 'tests/stress/New-LinearRepository.ps1') -Path $repo -Count 10000 -Seed 104729|Out-Null;if($LASTEXITCODE){throw 'stress generation failed'}}
    $old=&git.exe -C $repo rev-parse HEAD
    $rewrite=Measure-Command{
        $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$info.WorkingDirectory=$repo;$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        foreach($argument in @('-NoProfile','-File',(Join-Path $projectRoot 'windows/git-retime.ps1'),'shift','--by','1s','--root','--chronology','off')){[void]$info.ArgumentList.Add($argument)}
        $process=[Diagnostics.Process]::Start($info);$outputTask=$process.StandardOutput.ReadToEndAsync();$errorTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit();[void]$outputTask.GetAwaiter().GetResult();$errorText=$errorTask.GetAwaiter().GetResult();if($process.ExitCode){throw $errorText}
    }
    $new=&git.exe -C $repo rev-parse HEAD;$count=&git.exe -C $repo rev-list --count main
    if($old-eq$new-or$count-ne10000){throw 'Windows stress rewrite validation failed'}
    [Console]::Out.WriteLine('ok 1 - native Windows 10,000-commit full closure rewrite')
    [Console]::Out.WriteLine('1..1')
    [Console]::Out.WriteLine("windows_generate_seconds=$([Math]::Round($generation.TotalSeconds,2))")
    [Console]::Out.WriteLine("windows_rewrite_seconds=$([Math]::Round($rewrite.TotalSeconds,2))")
}finally{
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
