function Show-GitRetimeUsage {
    [Console]::Out.WriteLine(@'
usage: git retime <command> [options]

Commands:
  show audit set shift backdate schedule normalize edit batch
  operations undo redo recover prune-backups apply-plan completion

Run "git retime <command> --help" or read docs/cli.md for the command contract.
'@)
}

function New-DefaultOptions {
    @{
        Branches = [System.Collections.Generic.List[string]]::new()
        AllLocalBranches=$false; RepoScope=$false; Last=0; Range=''; RootScope=$false; FirstParent=$false
        FieldMode='both'; Date=''; By=''; Before=''; Start=''; End=''; File=''; Timezone='Z'; Seed="auto-$([Guid]::NewGuid().ToString('N'))"
        MinimumGap=1L; Chronology='strict'; DryRun=$false; SavePlan=''; OlderThan=30; Positional=[System.Collections.Generic.List[string]]::new()
        AllowDirty=$false; AllowActiveOperation=$false; AllowShallow=$false; AllowReplaceRefs=$false
        AllowLinkedWorktrees=$false; AllowDetached=$false; AllowPublished=$false; AllowInvalidSignatures=$false
        AllowTagDivergence=$false; AllowNoteDivergence=$false
    }
}

function ConvertTo-GitRetimeOptions {
    param([string[]] $Arguments)
    $options = New-DefaultOptions
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = $Arguments[$index]
        if($argument -eq '--'){
            for($position=$index+1;$position-lt$Arguments.Count;$position++){$options.Positional.Add($Arguments[$position])}
            break
        }
        $needsValue = $argument -in @('--branch','--last','--range','--date','--by','--before','--start','--end','--file','--timezone','--seed','--minimum-gap','--chronology','--save-plan','--older-than')
        if ($needsValue) {
            $index++
            if ($index -ge $Arguments.Count) { Throw-GitRetimeError $script:ExitUsage "option requires a value: $argument" }
            $value = $Arguments[$index]
        }
        switch -CaseSensitive ($argument) {
            '--branch' { $options.Branches.Add($value) }
            '--all-local-branches' { $options.AllLocalBranches=$true }
            '--repo' { $options.RepoScope=$true }
            '--last' { if($value -notmatch '^\d+$'){Throw-GitRetimeError $script:ExitUsage "--last must be a nonnegative integer: $value"}; $options.Last=[int]$value }
            '--range' { $options.Range=$value }
            '--root' { $options.RootScope=$true }
            '--first-parent' { $options.FirstParent=$true }
            '--author' { $options.FieldMode='author' }
            '--committer' { $options.FieldMode='committer' }
            '--both' { $options.FieldMode='both' }
            '--date' { $options.Date=$value }
            '--by' { $options.By=$value }
            '--before' { $options.Before=$value }
            '--start' { $options.Start=$value }
            '--end' { $options.End=$value }
            '--file' { $options.File=$value }
            '--timezone' { $options.Timezone=$value }
            '--seed' { $options.Seed=$value }
            '--minimum-gap' { if($value -notmatch '^\d+$'){Throw-GitRetimeError $script:ExitUsage "--minimum-gap must be a nonnegative integer: $value"}; $options.MinimumGap=[long]$value }
            '--chronology' { if($value -notin @('strict','off')){Throw-GitRetimeError $script:ExitUsage '--chronology must be strict or off'}; $options.Chronology=$value }
            '--dry-run' { $options.DryRun=$true }
            '--save-plan' { $options.SavePlan=$value }
            '--older-than' { if($value -notmatch '^\d+$'){Throw-GitRetimeError $script:ExitUsage "--older-than must be a nonnegative integer: $value"}; $options.OlderThan=[int]$value }
            '--allow-dirty' { $options.AllowDirty=$true }
            '--allow-active-operation' { $options.AllowActiveOperation=$true }
            '--allow-shallow' { $options.AllowShallow=$true }
            '--allow-replace-refs' { $options.AllowReplaceRefs=$true }
            '--allow-linked-worktrees' { $options.AllowLinkedWorktrees=$true }
            '--allow-detached' { $options.AllowDetached=$true }
            '--allow-published' { $options.AllowPublished=$true }
            '--allow-invalid-signatures' { $options.AllowInvalidSignatures=$true }
            '--allow-tag-divergence' { $options.AllowTagDivergence=$true }
            '--allow-note-divergence' { $options.AllowNoteDivergence=$true }
            '--help' { Show-GitRetimeUsage; return $null }
            '-h' { Show-GitRetimeUsage; return $null }
            default {
                if ($argument.StartsWith('-')) { Throw-GitRetimeError $script:ExitUsage "unknown option: $argument" }
                $options.Positional.Add($argument)
            }
        }
    }
    if ($options.AllLocalBranches -and $options.Branches.Count) { Throw-GitRetimeError $script:ExitUsage '--all-local-branches and --branch cannot be used together' }
    if ($options.RepoScope -and $options.Branches.Count) { Throw-GitRetimeError $script:ExitUsage '--repo and --branch cannot be used together' }
    if($options.Seed.IndexOfAny([char[]]@("`t","`r","`n"))-ge0){Throw-GitRetimeError $script:ExitUsage '--seed cannot contain a tab or line break'}
    $options
}

function Write-OrSavePlan {
    param([string[]] $Lines, [hashtable] $Options, [string] $TemporaryPath)
    Write-Utf8NoBomLines $TemporaryPath $Lines
    if ($Options.SavePlan) {
        [IO.File]::Copy($TemporaryPath, [IO.Path]::GetFullPath($Options.SavePlan), $true)
        [Console]::Out.WriteLine("Saved plan to $($Options.SavePlan)")
    }
    if ($Options.DryRun) { [Console]::Out.Write(($Lines -join "`n") + "`n") }
}

function Invoke-PlanExecution {
    param([string] $Path, [hashtable] $Options)
    $plan = Read-GitRetimePlan $Path
    $scope = Resolve-PlanScope $plan
    $metadata = Get-GitMetadata $scope.Universe
    $closure = Get-RewriteClosure $metadata $scope.Targets
    Assert-RepositorySafety $Options $scope.Refs $closure
    $solved = Resolve-PlanTimestamps $plan $metadata
    if ($Options.DryRun) {
        [Console]::Out.Write([IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path), $script:Utf8NoBom))
        return
    }
    $rewrite = Rewrite-GitGraph $metadata $solved
    Apply-GitRewrite $scope.Refs $rewrite.Map $Path
}

function Invoke-MutatingCommand {
    param([string] $Command, [hashtable] $Options, [string] $TemporaryDirectory)
    $scope = Get-GitScopeData $Options
    $metadata = Get-GitMetadata $scope.Universe
    $lines = if ($Command -eq 'batch') { New-BatchPlan $Options $scope } else { New-OperationPlan $Command $Options $scope $metadata }
    $planPath = Join-Path $TemporaryDirectory 'plan'
    Write-OrSavePlan $lines $Options $planPath
    if (-not $Options.DryRun) { Invoke-PlanExecution $planPath $Options }
}

function Invoke-ShowCommand {
    param([hashtable] $Options)
    $Options.AllowDetached=$true
    $scope=Get-GitScopeData $Options
    $selected=[System.Collections.Generic.HashSet[string]]::new([string[]]$scope.Targets,[StringComparer]::Ordinal)
    [Console]::Out.WriteLine("OID`tAUTHOR`tCOMMITTER`tSUBJECT")
    foreach($commit in Get-GitMetadata $scope.Universe){
        if(-not $selected.Contains($commit.Oid)){continue}
        $subject=(Invoke-GitText -ArgumentList @('show','-s','--format=%s',$commit.Oid)).Output.TrimEnd("`r","`n")
        [Console]::Out.WriteLine("$($commit.Oid)`t$(Format-GitTimestampIso $commit.AuthorEpoch $commit.AuthorOffset)`t$(Format-GitTimestampIso $commit.CommitterEpoch $commit.CommitterOffset)`t$subject")
    }
}

function Invoke-AuditCommand {
    param([hashtable] $Options)
    $Options.AllowDetached=$true
    $scope=Get-GitScopeData $Options
    $author=@{};$committer=@{};$violations=0
    $metadata=Get-GitMetadata $scope.Universe
    foreach($commit in $metadata){
        foreach($parent in $commit.Parents){
            if($commit.AuthorEpoch -lt [long]$author[$parent]+$Options.MinimumGap){[Console]::Out.WriteLine("author`t$parent`t$($commit.Oid)`t$($author[$parent])`t$($commit.AuthorEpoch)");$violations++}
            if($commit.CommitterEpoch -lt [long]$committer[$parent]+$Options.MinimumGap){[Console]::Out.WriteLine("committer`t$parent`t$($commit.Oid)`t$($committer[$parent])`t$($commit.CommitterEpoch)");$violations++}
        }
        $author[$commit.Oid]=$commit.AuthorEpoch;$committer[$commit.Oid]=$commit.CommitterEpoch
    }
    [Console]::Out.WriteLine("Audited $($metadata.Count) commits. Found $violations chronology violations.")
}

function Invoke-EditCommand {
    param([hashtable] $Options, [string] $TemporaryDirectory)
    $scope=Get-GitScopeData $Options
    $editPath=Join-Path $TemporaryDirectory 'edit.tsv'
    $lines=[System.Collections.Generic.List[string]]::new();$lines.Add("# revision`tauthor-date`tcommitter-date")
    foreach($oid in $scope.Targets){$lines.Add("$oid`t-`t-")}
    Write-Utf8NoBomLines $editPath @($lines)
    $editor=if($env:GIT_EDITOR){$env:GIT_EDITOR}elseif($env:VISUAL){$env:VISUAL}else{'notepad.exe'}
    $process=Start-Process -FilePath $editor -ArgumentList @($editPath) -Wait -PassThru
    if($process.ExitCode -ne 0){Throw-GitRetimeError $script:ExitUsage 'the editor returned an error'}
    $Options.File=$editPath
    Invoke-MutatingCommand batch $Options $TemporaryDirectory
}

function Show-Operations {
    $directory=Join-Path (Get-GitCommonDirectory) 'git-retime/operations'
    [Console]::Out.WriteLine("ID`tSTATE`tCREATED")
    if(Test-Path -LiteralPath $directory){foreach($file in Get-ChildItem -LiteralPath $directory -Filter '*.manifest' | Sort-Object Name){[Console]::Out.WriteLine("$(Get-ManifestValue $file.FullName id)`t$(Get-ManifestValue $file.FullName state)`t$(Get-ManifestValue $file.FullName created)")}}
}

function Remove-OldBackups {
    param([hashtable] $Options)
    $directory=Join-Path (Get-GitCommonDirectory) 'git-retime/operations';$cutoff=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-$Options.OlderThan*86400
    if(-not(Test-Path -LiteralPath $directory)){[Console]::Out.WriteLine('No backups were pruned.');return}
    foreach($file in Get-ChildItem -LiteralPath $directory -Filter '*.manifest'){
        $created=Get-ManifestValue $file.FullName created
        if($created -notmatch '^\d+$' -or [long]$created -gt $cutoff){continue}
        foreach($record in Get-ManifestRefRecords $file.FullName){
            $current=Invoke-GitText -ArgumentList @('rev-parse','--verify',$record.Backup) -AllowFailure
            if($current.ExitCode -eq 0){$delete=Invoke-GitText -ArgumentList @('update-ref','-d',$record.Backup,$current.Output.Trim()) -AllowFailure;if($delete.ExitCode-ne 0){Throw-GitRetimeError $script:ExitTransaction "cannot delete backup ref: $($record.Backup)"}}
        }
        Set-ManifestState $file.FullName pruned
        [Console]::Out.WriteLine("Pruned backups for $(Get-ManifestValue $file.FullName id)")
    }
}

function Show-Completion {
    param([hashtable] $Options)
    $shell=if($Options.Positional.Count){$Options.Positional[0]}else{''}
    if($shell -eq 'bash'){
        [Console]::Out.WriteLine('_git_retime_complete() { COMPREPLY=( $(compgen -W ''show audit set shift backdate schedule normalize edit batch operations undo redo recover prune-backups apply-plan completion'' -- "${COMP_WORDS[COMP_CWORD]}") ); }')
        [Console]::Out.WriteLine('complete -F _git_retime_complete git-retime')
    }elseif($shell -eq 'powershell'){
        [Console]::Out.WriteLine(@'
Register-ArgumentCompleter -Native -CommandName git-retime -ScriptBlock { param($wordToComplete) 'show','audit','set','shift','backdate','schedule','normalize','edit','batch','operations','undo','redo','recover','prune-backups','apply-plan','completion' | Where-Object { $_ -like "$wordToComplete*" } }
'@)
    }else{Throw-GitRetimeError $script:ExitUsage 'completion requires bash or powershell'}
}

function Invoke-GitRetime {
    [CmdletBinding()]
    param([string[]] $Arguments)
    Assert-GitVersion
    if(-not $Arguments -or $Arguments[0] -in @('--help','-h')){Show-GitRetimeUsage;return}
    if($Arguments[0] -eq '--version'){[Console]::Out.WriteLine('git-retime 0.1.0');return}
    $command=$Arguments[0]
    $options=ConvertTo-GitRetimeOptions @($Arguments | Select-Object -Skip 1)
    if($null -eq $options){return}
    if($command -eq 'completion'){Show-Completion $options;return}
    Assert-GitRepository
    $temporaryDirectory=New-GitRetimeTemporaryDirectory
    try{
        switch($command){
            show {Invoke-ShowCommand $options}
            audit {Invoke-AuditCommand $options}
            {$_ -in @('set','shift','backdate','schedule','normalize','batch')} {Invoke-MutatingCommand $command $options $temporaryDirectory}
            edit {Invoke-EditCommand $options $temporaryDirectory}
            operations {Show-Operations}
            undo {Invoke-ManifestReplay undo $(if($options.Positional.Count){$options.Positional[0]}else{''})}
            redo {Invoke-ManifestReplay redo $(if($options.Positional.Count){$options.Positional[0]}else{''})}
            recover {Invoke-OperationRecovery}
            'prune-backups' {Remove-OldBackups $options}
            'apply-plan' {if(-not $options.Positional.Count){Throw-GitRetimeError $script:ExitUsage 'apply-plan requires a plan path'};Invoke-PlanExecution $options.Positional[0] $options}
            default {Throw-GitRetimeError $script:ExitUsage "unknown command: $command"}
        }
    }finally{
        if(Test-Path -LiteralPath $temporaryDirectory){Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force}
    }
}
