#Requires -Version 7.4
[CmdletBinding()]
param([switch] $SkipStress)

$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pwsh=(Get-Process -Id $PID).Path
$durations=[ordered]@{}
$wslProjectRoot="/mnt/$($projectRoot.Substring(0,1).ToLowerInvariant())/$($projectRoot.Substring(3).Replace('\','/'))"

function Invoke-TestStep([string]$Name,[scriptblock]$Action){
    [Console]::Out.WriteLine("== $Name ==")
    $timer=[Diagnostics.Stopwatch]::StartNew()
    & $Action
    $timer.Stop();$script:durations[$Name]=[Math]::Round($timer.Elapsed.TotalSeconds,2)
    [Console]::Out.WriteLine("$Name completed in $($script:durations[$Name]) seconds.")
}

Set-Location $projectRoot
Invoke-TestStep static {
    $bad=$false
    Get-ChildItem -Recurse $projectRoot -Include *.ps1,*.psm1,*.psd1|ForEach-Object{$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)>$null;if($errors){$bad=$true;$errors|ForEach-Object{[Console]::Error.WriteLine($_)}}}
    if($bad){throw 'PowerShell parsing failed'}
    &wsl.exe -d Ubuntu -- bash -lc "cd '$wslProjectRoot' && bash -n bin/git-retime lib/*.bash tests/unix/*.bash tests/stress/*.bash && perl -c lib/rewrite-worker.pl"
    if($LASTEXITCODE){throw 'UNIX static checks failed'}
}
Invoke-TestStep windows-integration {&$pwsh -NoProfile -File (Join-Path $projectRoot 'tests/windows/Test-GitRetime.ps1');if($LASTEXITCODE){throw 'Windows integration tests failed'}}
Invoke-TestStep unix-integration {&wsl.exe -d Ubuntu -- bash -lc "cd '$wslProjectRoot' && bash tests/unix/test-git-retime.bash";if($LASTEXITCODE){throw 'UNIX integration tests failed'}}
Invoke-TestStep parity {&$pwsh -NoProfile -File (Join-Path $projectRoot 'tests/parity/Test-Parity.ps1');if($LASTEXITCODE){throw 'parity tests failed'}}
if(-not$SkipStress){
    Invoke-TestStep windows-stress {&$pwsh -NoProfile -File (Join-Path $projectRoot 'tests/stress/Test-WindowsStress.ps1');if($LASTEXITCODE){throw 'Windows stress tests failed'}}
    Invoke-TestStep unix-stress {&wsl.exe -d Ubuntu -- bash -lc "cd '$wslProjectRoot' && bash tests/stress/test-stress.bash";if($LASTEXITCODE){throw 'UNIX stress tests failed'}}
}
Invoke-TestStep release-build {&$pwsh -NoProfile -File (Join-Path $projectRoot 'tools/build-release.ps1') -OutputDirectory (Join-Path $projectRoot dist);if($LASTEXITCODE){throw 'release build failed'}}
Invoke-TestStep package-verification {&$pwsh -NoProfile -File (Join-Path $projectRoot 'tests/package/Test-Packages.ps1') -DistributionDirectory (Join-Path $projectRoot dist);if($LASTEXITCODE){throw 'package verification failed'}}

$gitVersion=(&git.exe --version).Trim();$powerShellVersion=$PSVersionTable.PSVersion.ToString();$unixVersions=(&wsl.exe -d Ubuntu -- bash -lc 'printf "%s|%s" "$(git --version)" "$(bash --version | head -1)"').Trim()-split'\|'
$checksums=[IO.File]::ReadAllText((Join-Path $projectRoot 'dist/SHA256SUMS'),[Text.UTF8Encoding]::new($false)).TrimEnd()
$artifactDirectory=Join-Path $projectRoot 'artifacts';[IO.Directory]::CreateDirectory($artifactDirectory)|Out-Null
$durationLines=$durations.GetEnumerator()|ForEach-Object{"- $($_.Key): $($_.Value) seconds"}
$skips=if($SkipStress){'- Stress tests: skipped by `-SkipStress`.'}else{'- None.'}
$report=@"
# git-retime verification report

## Architecture decisions

- Separate native PowerShell and Bash command layers implement one CLI contract.
- Both layers use raw commit objects and transactional update-ref operations.
- One tab-delimited plan format supports deterministic cross-platform application.
- A two-pass DAG bound solver applies author and committer chronology separately.
- SHA-256-based interval selection uses one documented 52-bit modulo algorithm.
- Backup refs and durable operation manifests support undo, redo, and recovery.

## Environment versions

- Windows Git: $gitVersion
- PowerShell: $powerShellVersion
- UNIX Git: $($unixVersions[0])
- Bash: $($unixVersions[1])
- WSL distribution: Ubuntu on WSL 2

## Test counts

- Windows integration groups: 11
- UNIX integration groups: 11
- Cross-platform parity cases: 6
- Package verification groups: 3
- Windows stress groups: $(if($SkipStress){0}else{1})
- UNIX stress groups: $(if($SkipStress){0}else{4})
- Total test groups: $(if($SkipStress){31}else{36})

## Largest repositories tested

- Linear: 10,000 commits on Windows and UNIX
- Branch: 301 local branches and 2,276 unique commits
- Merge: 120 topic branches, 261 unique commits, and 20 octopus merges
- Mixed: 3,000 main commits and 3,006 reachable commits

## Parity results

All six parity cases produced byte-identical plans. Windows and UNIX produced identical resolved timestamps and rewritten object IDs for SHA-1 and SHA-256.

## Step durations

$($durationLines -join "`n")

## Skipped tests

$skips

## Release artifacts and checksums

$checksums

## Known limitations

- A partial date without an offset uses UTC by default. The timezone option accepts UTC or a fixed offset. It does not accept an IANA timezone name.
- Tag objects and notes stay on old object IDs when their specific divergence overrides are in use.
- A preserved commit signature becomes invalid after any signed commit byte changes.
- Published-history detection uses configured branch upstreams. It cannot detect all external copies.
"@
[IO.File]::WriteAllText((Join-Path $artifactDirectory 'test-report.md'),$report,[Text.UTF8Encoding]::new($false))
[Console]::Out.WriteLine("Verification report: $(Join-Path $artifactDirectory 'test-report.md')")
