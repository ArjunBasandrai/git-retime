#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$retime=Join-Path $projectRoot 'windows/git-retime.ps1'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ("git-retime-parity-tests-{0}" -f [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot)|Out-Null
$count=0

function ConvertTo-WslPath([string]$Path){$full=[IO.Path]::GetFullPath($Path);"/mnt/$($full.Substring(0,1).ToLowerInvariant())/$($full.Substring(3).Replace('\','/'))"}
function Run-Process([string]$File,[string[]]$Arguments,[string]$WorkingDirectory=''){
    $info=[Diagnostics.ProcessStartInfo]::new($File);$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.CreateNoWindow=$true
    if($WorkingDirectory){$info.WorkingDirectory=$WorkingDirectory}
    foreach($argument in $Arguments){[void]$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($info);$outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
    [pscustomobject]@{ExitCode=$process.ExitCode;Output=$outTask.GetAwaiter().GetResult();Error=$errTask.GetAwaiter().GetResult()}
}
function Run-Git([string]$Repo,[string[]]$Arguments){$result=Run-Process git.exe (@('-C',$Repo)+$Arguments);if($result.ExitCode){throw $result.Error};$result.Output.TrimEnd()}
function Run-Retime([string]$Repo,[string[]]$Arguments){$result=Run-Process (Get-Process -Id $PID).Path (@('-NoLogo','-NoProfile','-File',$retime)+$Arguments) $Repo;if($result.ExitCode){throw "Windows git-retime failed: $($result.Error)"};$result}
function Run-Wsl([string]$Script){$result=Run-Process wsl.exe @('-d','Ubuntu','--','bash','-lc',$Script);if($result.ExitCode){throw "WSL command failed: $($result.Error)"};$result.Output.TrimEnd()}
function Pass([string]$Name){$script:count++;[Console]::Out.WriteLine("ok $script:count - $Name")}

try{
    $source=Join-Path $testRoot source
    &git.exe init -q -b main $source;if($LASTEXITCODE){throw 'git init failed'}
    Run-Git $source @('config','user.name','Parity Test')|Out-Null;Run-Git $source @('config','user.email','parity@example.com')|Out-Null
    for($index=0;$index-lt12;$index++){
        [IO.File]::AppendAllText((Join-Path $source 'data.txt'),"$index — café`n",[Text.UTF8Encoding]::new($false));Run-Git $source @('add','data.txt')|Out-Null
        $epoch=1704067200+$index*300;$offset=@('+0000','-0400','+0530')[$index%3];$env:GIT_AUTHOR_DATE="@$epoch $offset";$env:GIT_COMMITTER_DATE="@$($epoch+1) $offset"
        Run-Git $source @('commit','-q','-m',"parity $index — café")|Out-Null;Remove-Item Env:GIT_AUTHOR_DATE,Env:GIT_COMMITTER_DATE
    }
    $linuxSource=ConvertTo-WslPath $source
    $linuxProjectRoot=ConvertTo-WslPath $projectRoot
    $cases=@(
        [pscustomobject]@{Name='partial-set';Args=@('set','--date','2026-09','--last','5','--seed','parity-a')},
        [pscustomobject]@{Name='root-closure';Args=@('shift','--by','2h30m','--root','--chronology','off','--seed','parity-b')},
        [pscustomobject]@{Name='schedule';Args=@('schedule','--start','2027-01-01','--end','2027-02-01','--last','6','--seed','parity-c')},
        [pscustomobject]@{Name='author-only';Args=@('set','--date','2028-03-04T05:06','--timezone','+05:30','--author','--chronology','off','--seed','parity-d')},
        [pscustomobject]@{Name='committer-backdate';Args=@('backdate','--before','2020','--root','--committer','--chronology','off','--seed','parity-e')}
    )
    foreach($case in $cases){
        $winPlan=Join-Path $testRoot "$($case.Name).windows.plan";$unixPlan=Join-Path $testRoot "$($case.Name).unix.plan";$linuxUnixPlan=ConvertTo-WslPath $unixPlan
        Run-Retime $source (@($case.Args)+@('--dry-run','--save-plan',$winPlan))|Out-Null
        $quotedArgs=($case.Args|ForEach-Object{"'"+$_+"'"})-join' '
        Run-Wsl "cd '$linuxSource' && '$linuxProjectRoot/bin/git-retime' $quotedArgs --dry-run --save-plan '$linuxUnixPlan' >/dev/null"|Out-Null
        $winBytes=[IO.File]::ReadAllBytes($winPlan);$unixBytes=[IO.File]::ReadAllBytes($unixPlan)
        if([Convert]::ToBase64String($winBytes)-ne[Convert]::ToBase64String($unixBytes)){throw "plan mismatch: $($case.Name)"}

        $winRepo=Join-Path $testRoot "$($case.Name)-windows";$linuxRepo="/tmp/git-retime-parity-$($case.Name)-$([Guid]::NewGuid().ToString('N'))"
        &git.exe clone -q --no-local $source $winRepo;if($LASTEXITCODE){throw 'Windows clone failed'}
        Run-Git $winRepo @('config','--unset','branch.main.remote')|Out-Null;Run-Git $winRepo @('config','--unset','branch.main.merge')|Out-Null
        Run-Wsl "git clone -q --no-local '$linuxSource' '$linuxRepo' && git -C '$linuxRepo' config --unset branch.main.remote && git -C '$linuxRepo' config --unset branch.main.merge"|Out-Null
        Run-Retime $winRepo @('apply-plan',$winPlan)|Out-Null
        Run-Wsl "cd '$linuxRepo' && '$linuxProjectRoot/bin/git-retime' apply-plan '$(ConvertTo-WslPath $winPlan)' >/dev/null"|Out-Null
        $winState=Run-Git $winRepo @('log','--format=%H%x09%at%x09%ai%x09%ct%x09%ci','--topo-order','--exclude=refs/git-retime/*','--all')
        $unixState=Run-Wsl "git -C '$linuxRepo' log --format='%H%x09%at%x09%ai%x09%ct%x09%ci' --topo-order --exclude='refs/git-retime/*' --all"
        if($winState-ne$unixState){throw "rewritten state mismatch: $($case.Name)"}
        Run-Wsl "rm -rf -- '$linuxRepo'"|Out-Null
        Pass "$($case.Name) plan and object parity"
    }
    $shaSource=Join-Path $testRoot sha256-source
    &git.exe init -q -b main --object-format=sha256 $shaSource
    if($LASTEXITCODE-eq0){
        Run-Git $shaSource @('config','user.name','Parity Test')|Out-Null;Run-Git $shaSource @('config','user.email','parity@example.com')|Out-Null
        for($index=0;$index-lt3;$index++){[IO.File]::AppendAllText((Join-Path $shaSource 'data'),"$index`n");Run-Git $shaSource @('add','data')|Out-Null;$env:GIT_AUTHOR_DATE="@$((1705000000+$index*100)) +0000";$env:GIT_COMMITTER_DATE=$env:GIT_AUTHOR_DATE;Run-Git $shaSource @('commit','-q','-m',"sha256 $index")|Out-Null;Remove-Item Env:GIT_AUTHOR_DATE,Env:GIT_COMMITTER_DATE}
        $shaPlan=Join-Path $testRoot 'sha256.plan';$shaUnixPlan=Join-Path $testRoot 'sha256.unix.plan';Run-Retime $shaSource @('set','--date','2029-07','--last','2','--seed','sha256-parity','--dry-run','--save-plan',$shaPlan)|Out-Null
        $linuxShaSource=ConvertTo-WslPath $shaSource
        Run-Wsl "cd '$linuxShaSource' && '$linuxProjectRoot/bin/git-retime' set --date 2029-07 --last 2 --seed sha256-parity --dry-run --save-plan '$(ConvertTo-WslPath $shaUnixPlan)' >/dev/null"|Out-Null
        if([Convert]::ToBase64String([IO.File]::ReadAllBytes($shaPlan))-ne[Convert]::ToBase64String([IO.File]::ReadAllBytes($shaUnixPlan))){throw 'SHA-256 plan mismatch'}
        $shaWindows=Join-Path $testRoot sha256-windows;Copy-Item -LiteralPath $shaSource -Destination $shaWindows -Recurse
        $shaLinux="/tmp/git-retime-parity-sha256-$([Guid]::NewGuid().ToString('N'))"
        Run-Wsl "cp -a '$linuxShaSource' '$shaLinux'"|Out-Null
        Run-Retime $shaWindows @('apply-plan',$shaPlan)|Out-Null
        Run-Wsl "cd '$shaLinux' && '$linuxProjectRoot/bin/git-retime' apply-plan '$(ConvertTo-WslPath $shaPlan)' >/dev/null"|Out-Null
        $windowsOid=Run-Git $shaWindows @('rev-parse','HEAD');$linuxOid=Run-Wsl "git -C '$shaLinux' rev-parse HEAD"
        if($windowsOid-ne$linuxOid){throw 'SHA-256 rewritten object mismatch'}
        Run-Wsl "rm -rf -- '$shaLinux'"|Out-Null
        Pass 'SHA-256 plan and object parity'
    }else{Pass 'SHA-256 parity unavailable (skipped)'}
    [Console]::Out.WriteLine("1..$count")
}finally{
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
