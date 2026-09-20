#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$retime = Join-Path $projectRoot 'windows/git-retime.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("git-retime-windows-tests-{0}" -f [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$script:TestCount = 0

function Complete-Test([string] $Name) { $script:TestCount++; [Console]::Out.WriteLine("ok $script:TestCount - $Name") }
function Assert-Equal($Expected, $Actual, [string] $Name) { if ($Expected -ne $Actual) { throw "$Name`: expected [$Expected], got [$Actual]" } }
function Assert-NotEqual($Left, $Right, [string] $Name) { if ($Left -eq $Right) { throw "$Name`: values are equal" } }
function Invoke-Git([string] $Repository, [string[]] $Arguments) {
    $output = & git.exe -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $output" }
    ($output -join "`n").TrimEnd()
}
function New-TestRepository([string] $Name, [int] $Count = 0) {
    $repo = Join-Path $testRoot $Name
    & git.exe init -q -b main $repo
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
    Invoke-Git $repo @('config','user.name','Test') | Out-Null
    Invoke-Git $repo @('config','user.email','test@example.com') | Out-Null
    for ($index = 0; $index -lt $Count; $index++) {
        [IO.File]::AppendAllText((Join-Path $repo 'data.txt'), "$index`n", [Text.UTF8Encoding]::new($false))
        Invoke-Git $repo @('add','data.txt') | Out-Null
        $epoch = 1704067200 + $index * 100
        $env:GIT_AUTHOR_DATE = "@$epoch +0000"; $env:GIT_COMMITTER_DATE = $env:GIT_AUTHOR_DATE
        Invoke-Git $repo @('commit','-q','-m',"commit $index") | Out-Null
        Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE
    }
    $repo
}
function Invoke-Retime([string] $Repository, [string[]] $Arguments, [hashtable] $Environment = @{}) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Process -Id $PID).Path
    $info.WorkingDirectory = $Repository
    $info.UseShellExecute = $false; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo','-NoProfile','-File',$retime) + $Arguments) { [void]$info.ArgumentList.Add($argument) }
    foreach ($item in $Environment.GetEnumerator()) { $info.Environment[$item.Key] = [string]$item.Value }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info; [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync(); $process.WaitForExit()
    [pscustomobject]@{ ExitCode=$process.ExitCode; Output=$stdoutTask.GetAwaiter().GetResult(); Error=$stderrTask.GetAwaiter().GetResult() }
}
function Assert-RetimeSuccess([string] $Repository, [string[]] $Arguments) {
    $result = Invoke-Retime $Repository $Arguments
    if ($result.ExitCode -ne 0) { throw "git-retime failed with $($result.ExitCode): $($result.Error)" }
    $result
}
function Invoke-GitBinaryForTest {
    param([string]$Repository,[string[]]$Arguments)
    $info=[Diagnostics.ProcessStartInfo]::new('git.exe');$info.WorkingDirectory=$Repository;$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($argument in $Arguments){[void]$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($info);$memory=[IO.MemoryStream]::new();$task=$process.StandardOutput.BaseStream.CopyToAsync($memory);$errorTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit();[void]$task.GetAwaiter().GetResult();$errorText=$errorTask.GetAwaiter().GetResult();if($process.ExitCode-ne0){throw $errorText};return ,$memory.ToArray()
}

try {
    $version = Invoke-Retime $projectRoot @('--version')
    Assert-Equal 0 $version.ExitCode 'version exit'
    Assert-Equal 'git-retime 0.1.0' $version.Output.Trim() 'version text'
    Complete-Test 'version'

    $repo = New-TestRepository linear 4
    $old = Invoke-Git $repo @('rev-parse','HEAD')
    $plan = Join-Path $testRoot 'linear.plan'
    Assert-RetimeSuccess $repo @('set','--date','2025','--last','1','--seed','smoke','--dry-run','--save-plan',$plan) | Out-Null
    Assert-RetimeSuccess $repo @('apply-plan',$plan) | Out-Null
    $new = Invoke-Git $repo @('rev-parse','HEAD')
    Assert-NotEqual $old $new 'set rewrite'
    $author = [long](Invoke-Git $repo @('show','-s','--format=%at','HEAD'))
    $committer = [long](Invoke-Git $repo @('show','-s','--format=%ct','HEAD'))
    if ($author -lt 1735689600 -or $author -gt 1767225599 -or $committer -lt 1735689600 -or $committer -gt 1767225599) { throw 'partial year range' }
    $operations = (Assert-RetimeSuccess $repo @('operations')).Output.TrimEnd() -split "`r?`n"
    $operation = $operations[1].Split("`t")[0]
    Assert-RetimeSuccess $repo @('undo',$operation) | Out-Null; Assert-Equal $old (Invoke-Git $repo @('rev-parse','HEAD')) 'undo'
    Assert-RetimeSuccess $repo @('redo',$operation) | Out-Null; Assert-Equal $new (Invoke-Git $repo @('rev-parse','HEAD')) 'redo'
    Complete-Test 'set, partial date, plan, backup, undo, and redo'

    $repo = New-TestRepository fields 5
    $beforeAuthor = [long](Invoke-Git $repo @('show','-s','--format=%at','HEAD')); $beforeCommitter = [long](Invoke-Git $repo @('show','-s','--format=%ct','HEAD'))
    Assert-RetimeSuccess $repo @('shift','--by','2h','--author','--chronology','off') | Out-Null
    Assert-Equal ($beforeAuthor + 7200) ([long](Invoke-Git $repo @('show','-s','--format=%at','HEAD'))) 'author shift'
    Assert-Equal $beforeCommitter ([long](Invoke-Git $repo @('show','-s','--format=%ct','HEAD'))) 'committer preservation'
    Assert-RetimeSuccess $repo @('schedule','--start','2027-01-01','--end','2027-01-03','--last','3') | Out-Null
    Assert-RetimeSuccess $repo @('backdate','--before','2020','--root','--chronology','off') | Out-Null
    $batchOid = Invoke-Git $repo @('rev-parse','HEAD'); $batch = Join-Path $testRoot 'batch.tsv'
    [IO.File]::WriteAllText($batch, "$batchOid`t2028-03-04T05:06:07Z`t-`n", [Text.UTF8Encoding]::new($false))
    Assert-RetimeSuccess $repo @('batch','--file',$batch) | Out-Null
    Assert-Equal 1835759167 ([long](Invoke-Git $repo @('show','-s','--format=%at','HEAD'))) 'batch timestamp'
    Complete-Test 'field modes, shift, schedule, backdate, and batch'

    $repo = New-TestRepository normalize 3
    Assert-RetimeSuccess $repo @('set','--date','2010-01-01T00:00:00Z','--chronology','off') | Out-Null
    $audit = Assert-RetimeSuccess $repo @('audit','--repo')
    if ($audit.Output -notmatch 'chronology violations') { throw 'audit output' }
    Assert-RetimeSuccess $repo @('normalize','--repo') | Out-Null
    $audit = Assert-RetimeSuccess $repo @('audit','--repo')
    if ($audit.Output -notmatch 'Found 0 chronology violations') { throw 'normalize result' }
    Complete-Test 'audit and DAG normalization'

    $repo = New-TestRepository merge 2
    Invoke-Git $repo @('branch','topic','HEAD') | Out-Null
    [IO.File]::AppendAllText((Join-Path $repo 'data.txt'),"main`n"); Invoke-Git $repo @('add','data.txt')|Out-Null; Invoke-Git $repo @('commit','-q','-m','main')|Out-Null
    Invoke-Git $repo @('switch','-q','topic')|Out-Null; [IO.File]::WriteAllText((Join-Path $repo 'topic.txt'),"topic`n"); Invoke-Git $repo @('add','topic.txt')|Out-Null; Invoke-Git $repo @('commit','-q','-m','topic')|Out-Null
    Invoke-Git $repo @('switch','-q','main')|Out-Null; Invoke-Git $repo @('merge','-q','--no-ff','topic','-m','merge')|Out-Null
    $mainBefore=Invoke-Git $repo @('rev-parse','main');$topicBefore=Invoke-Git $repo @('rev-parse','topic');$headDates=Invoke-Git $repo @('show','-s','--format=%at %ct','main')
    Assert-RetimeSuccess $repo @('shift','--by','1d','--branch','main','--root','--chronology','off')|Out-Null
    Assert-NotEqual $mainBefore (Invoke-Git $repo @('rev-parse','main')) 'merge closure';Assert-Equal $topicBefore (Invoke-Git $repo @('rev-parse','topic')) 'branch isolation';Assert-Equal $headDates (Invoke-Git $repo @('show','-s','--format=%at %ct','main')) 'closure-only timestamp preservation'
    Complete-Test 'branch scope and merge closure'

    $repo = New-TestRepository bytes 1
    $tree=Invoke-Git $repo @('show','-s','--format=%T','HEAD');$parent=Invoke-Git $repo @('rev-parse','HEAD')
    $rawText="tree $tree`nparent $parent`nauthor Tést <test@example.com> 1704067300 +0530`ncommitter Test <test@example.com> 1704067301 -0400`nencoding UTF-8`nx-extra value`n continuation`n`nmessage with trailing spaces  `r`nsecond line`r`n"
    $rawPath=Join-Path $testRoot 'raw.commit';[IO.File]::WriteAllText($rawPath,$rawText,[Text.UTF8Encoding]::new($false))
    $custom=Invoke-Git $repo @('hash-object','-t','commit','-w',$rawPath);Invoke-Git $repo @('update-ref','refs/heads/main',$custom,$parent)|Out-Null
    Assert-RetimeSuccess $repo @('set','--date','2027-01-15T08:00:00Z','--chronology','off')|Out-Null
    $newRaw=[Text.UTF8Encoding]::new($false).GetString((Invoke-GitBinaryForTest $repo @('cat-file','commit','HEAD')))
    $epoch=[DateTimeOffset]::Parse('2027-01-15T08:00:00Z').ToUnixTimeSeconds()
    $expected=$rawText.Replace('1704067300 +0530',"$epoch +0000").Replace('1704067301 -0400',"$epoch +0000")
    Assert-Equal $expected $newRaw 'raw byte preservation'
    Complete-Test 'byte preservation for Unicode, CRLF message data, and unknown headers'

    $repo = New-TestRepository safety 2
    [IO.File]::AppendAllText((Join-Path $repo 'data.txt'),"dirty`n")
    Assert-Equal 3 (Invoke-Retime $repo @('shift','--by','1h')).ExitCode 'dirty safety';Invoke-Git $repo @('restore','data.txt')|Out-Null
    Invoke-Git $repo @('tag','-a','-m','keep','keep','HEAD')|Out-Null;Assert-Equal 3 (Invoke-Retime $repo @('shift','--by','1h')).ExitCode 'tag safety'
    Assert-RetimeSuccess $repo @('shift','--by','1h','--allow-tag-divergence')|Out-Null
    Invoke-Git $repo @('notes','add','-m','note','HEAD')|Out-Null;Assert-Equal 3 (Invoke-Retime $repo @('shift','--by','1h','--allow-tag-divergence')).ExitCode 'note safety'
    $stale=Join-Path $testRoot 'stale.plan';Assert-RetimeSuccess $repo @('set','--date','2030','--dry-run','--save-plan',$stale,'--allow-tag-divergence','--allow-note-divergence')|Out-Null
    [IO.File]::WriteAllText((Join-Path $repo 'next.txt'),"next`n");Invoke-Git $repo @('add','next.txt')|Out-Null;Invoke-Git $repo @('commit','-q','-m','next')|Out-Null
    Assert-Equal 6 (Invoke-Retime $repo @('apply-plan',$stale,'--allow-tag-divergence','--allow-note-divergence')).ExitCode 'concurrency safety'
    Complete-Test 'dirty, tag, note, and concurrent-ref safety'

    foreach($stage in @('after-manifest','after-backups','before-refs','after-refs')){
        $repo = New-TestRepository "recovery_$stage" 2;$old=Invoke-Git $repo @('rev-parse','HEAD')
        $failed=Invoke-Retime $repo @('shift','--by','1h') @{GIT_RETIME_FAIL_STAGE=$stage};Assert-Equal 6 $failed.ExitCode "injected failure $stage"
        $changed=Invoke-Git $repo @('rev-parse','HEAD');if($stage-eq'after-refs'){Assert-NotEqual $old $changed 'ref changed before recovery'}else{Assert-Equal $old $changed 'pre-transaction failure'}
        Assert-RetimeSuccess $repo @('recover')|Out-Null;Assert-Equal $old (Invoke-Git $repo @('rev-parse','HEAD')) 'recovery rollback'
    }
    Complete-Test 'four-stage failure injection and crash recovery'

    $repo=New-TestRepository safety_modes 3
    [IO.File]::WriteAllText((Join-Path $repo '.git/MERGE_HEAD'),'')
    Assert-Equal 3 (Invoke-Retime $repo @('shift','--by','1h')).ExitCode 'active operation safety';Remove-Item -LiteralPath (Join-Path $repo '.git/MERGE_HEAD')
    Invoke-Git $repo @('remote','add','origin','https://example.invalid/repository.git')|Out-Null;Invoke-Git $repo @('update-ref','refs/remotes/origin/main','HEAD')|Out-Null;Invoke-Git $repo @('config','branch.main.remote','origin')|Out-Null;Invoke-Git $repo @('config','branch.main.merge','refs/heads/main')|Out-Null
    Assert-Equal 3 (Invoke-Retime $repo @('shift','--by','1h')).ExitCode 'published safety';Assert-RetimeSuccess $repo @('shift','--by','1h','--allow-published')|Out-Null
    Invoke-Git $repo @('config','--unset','branch.main.remote')|Out-Null;Invoke-Git $repo @('config','--unset','branch.main.merge')|Out-Null
    $linked=Join-Path $testRoot linked;Invoke-Git $repo @('branch','linked','HEAD')|Out-Null;Invoke-Git $repo @('worktree','add','-q',$linked,'linked')|Out-Null
    Assert-Equal 3 (Invoke-Retime $repo @('shift','--by','1h','--all-local-branches')).ExitCode 'linked worktree safety';Invoke-Git $repo @('worktree','remove','-f',$linked)|Out-Null
    $rootOid=Invoke-Git $repo @('rev-list','--max-parents=0','HEAD');Invoke-Git $repo @('replace',$rootOid,'HEAD')|Out-Null
    Assert-Equal 3 (Invoke-Retime $repo @('shift','--by','1h')).ExitCode 'replace safety';Invoke-Git $repo @('replace','-d',$rootOid)|Out-Null
    Invoke-Git $repo @('switch','-q','--detach')|Out-Null;Assert-Equal 3 (Invoke-Retime $repo @('shift','--by','1h')).ExitCode 'detached safety';Assert-RetimeSuccess $repo @('shift','--by','1h','--allow-detached')|Out-Null;Invoke-Git $repo @('switch','-q','main')|Out-Null
    $tree=Invoke-Git $repo @('show','-s','--format=%T','HEAD');$parent=Invoke-Git $repo @('rev-parse','HEAD')
    $signedText="tree $tree`nparent $parent`nauthor Test <test@example.com> 1704067600 +0000`ncommitter Test <test@example.com> 1704067600 +0000`ngpgsig -----BEGIN PGP SIGNATURE-----`n fake`n -----END PGP SIGNATURE-----`n`nsigned`n"
    $signedPath=Join-Path $testRoot 'signed.commit';[IO.File]::WriteAllText($signedPath,$signedText,[Text.UTF8Encoding]::new($false));$signed=Invoke-Git $repo @('hash-object','-t','commit','-w',$signedPath);Invoke-Git $repo @('update-ref','refs/heads/main',$signed,$parent)|Out-Null
    Assert-Equal 3 (Invoke-Retime $repo @('shift','--by','1h','--chronology','off')).ExitCode 'signature safety';Assert-RetimeSuccess $repo @('shift','--by','1h','--chronology','off','--allow-invalid-signatures')|Out-Null
    $shallow=Join-Path $testRoot shallow;$sourceUri=([Uri]$repo).AbsoluteUri;&git.exe clone -q --depth=1 $sourceUri $shallow;if($LASTEXITCODE-ne0){throw 'shallow clone failed'}
    Assert-Equal 3 (Invoke-Retime $shallow @('shift','--by','1h')).ExitCode 'shallow safety';Assert-RetimeSuccess $shallow @('shift','--by','1h','--chronology','off','--allow-shallow','--allow-published','--allow-invalid-signatures')|Out-Null
    Complete-Test 'active operation, published, worktree, replace, detached, signature, and shallow safety'

    $repo=Join-Path $testRoot sha256;&git.exe init -q -b main --object-format=sha256 $repo
    if($LASTEXITCODE -eq 0){Invoke-Git $repo @('config','user.name','Test')|Out-Null;Invoke-Git $repo @('config','user.email','test@example.com')|Out-Null;[IO.File]::WriteAllText((Join-Path $repo 'data'),"sha256`n");Invoke-Git $repo @('add','data')|Out-Null;Invoke-Git $repo @('commit','-q','-m','sha256')|Out-Null;Assert-RetimeSuccess $repo @('shift','--by','1h','--chronology','off')|Out-Null;if((Invoke-Git $repo @('rev-parse','HEAD')).Length-ne64){throw 'SHA-256 OID length'};Complete-Test 'SHA-256 repository'}else{Complete-Test 'SHA-256 unavailable (skipped)'}

    $repo=New-TestRepository maintenance 2
    $editor=Join-Path $projectRoot 'tests/fixtures/edit-plan.cmd'
    $edit=Invoke-Retime $repo @('edit','--chronology','off') @{GIT_EDITOR=$editor};if($edit.ExitCode){throw $edit.Error}
    Assert-Equal 2059366028 ([long](Invoke-Git $repo @('show','-s','--format=%at','HEAD'))) 'edit timestamp'
    Assert-RetimeSuccess $repo @('prune-backups','--older-than','0')|Out-Null
    Assert-Equal '' (Invoke-Git $repo @('for-each-ref','--format=%(refname)','refs/git-retime/backups')) 'prune backups'
    if((Invoke-Retime $projectRoot @('completion','bash')).Output-notmatch'complete -F'){throw 'Bash completion'}
    if((Invoke-Retime $projectRoot @('completion','powershell')).Output-notmatch'Register-ArgumentCompleter'){throw 'PowerShell completion'}
    Complete-Test 'edit, backup pruning, and completion'

    [Console]::Out.WriteLine("1..$script:TestCount")
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
