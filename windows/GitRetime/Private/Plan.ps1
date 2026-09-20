function New-PlanHeaderLines {
    param([string] $Operation, [hashtable] $Options)
    @(
        "git-retime-plan`t1"
        "object-format`t$(Get-GitObjectFormat)"
        "operation`t$Operation"
        "seed`t$($Options.Seed)"
        "minimum-gap`t$($Options.MinimumGap)"
        "chronology`t$($Options.Chronology)"
        "field-mode`t$($Options.FieldMode)"
    )
}

function New-TargetLine {
    param(
        [string] $Oid, [object] $AuthorLow, [object] $AuthorHigh, [string] $AuthorOffset,
        [object] $CommitterLow, [object] $CommitterHigh, [string] $CommitterOffset,
        [string] $FieldMode
    )
    if ($FieldMode -eq 'author') { $CommitterLow = '-'; $CommitterHigh = '-'; $CommitterOffset = '-' }
    if ($FieldMode -eq 'committer') { $AuthorLow = '-'; $AuthorHigh = '-'; $AuthorOffset = '-' }
    "target`t$Oid`t$AuthorLow`t$AuthorHigh`t$AuthorOffset`t$CommitterLow`t$CommitterHigh`t$CommitterOffset"
}

function New-OperationPlan {
    param([string] $Operation, [hashtable] $Options, [object] $Scope, [object[]] $Metadata)
    $targetSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$Scope.Targets, [StringComparer]::Ordinal)
    $targetLines = [System.Collections.Generic.List[string]]::new()
    switch ($Operation) {
        set {
            if (-not $Options.Date) { Throw-GitRetimeError $script:ExitUsage 'set requires --date' }
            $interval = ConvertTo-DateInterval $Options.Date $Options.Timezone
            foreach ($oid in $Scope.Targets) { $targetLines.Add((New-TargetLine $oid $interval.Low $interval.High $interval.Offset $interval.Low $interval.High $interval.Offset $Options.FieldMode)) }
        }
        shift {
            if (-not $Options.By) { Throw-GitRetimeError $script:ExitUsage 'shift requires --by' }
            $duration = ConvertTo-DurationSeconds $Options.By
            foreach ($commit in $Metadata) {
                if (-not $targetSet.Contains($commit.Oid)) { continue }
                $targetLines.Add((New-TargetLine $commit.Oid ($commit.AuthorEpoch + $duration) ($commit.AuthorEpoch + $duration) $commit.AuthorOffset ($commit.CommitterEpoch + $duration) ($commit.CommitterEpoch + $duration) $commit.CommitterOffset $Options.FieldMode))
            }
        }
        backdate {
            if (-not $Options.Before) { Throw-GitRetimeError $script:ExitUsage 'backdate requires --before' }
            $interval = ConvertTo-DateInterval $Options.Before $Options.Timezone
            foreach ($commit in $Metadata) {
                if (-not $targetSet.Contains($commit.Oid)) { continue }
                $authorHigh = [Math]::Min($interval.High, $commit.AuthorEpoch - 1)
                $committerHigh = [Math]::Min($interval.High, $commit.CommitterEpoch - 1)
                if($Options.FieldMode-ne'committer' -and $interval.Low-gt$authorHigh){Throw-GitRetimeError $script:ExitChronology "backdate interval is not earlier than author timestamp of commit $($commit.Oid)"}
                if($Options.FieldMode-ne'author' -and $interval.Low-gt$committerHigh){Throw-GitRetimeError $script:ExitChronology "backdate interval is not earlier than committer timestamp of commit $($commit.Oid)"}
                $targetLines.Add((New-TargetLine $commit.Oid $interval.Low $authorHigh $interval.Offset $interval.Low $committerHigh $interval.Offset $Options.FieldMode))
            }
        }
        schedule {
            if (-not $Options.Start -or -not $Options.End) { Throw-GitRetimeError $script:ExitUsage 'schedule requires --start and --end' }
            $start = ConvertTo-DateInterval $Options.Start $Options.Timezone
            $end = ConvertTo-DateInterval $Options.End $Options.Timezone
            if ($start.Low -gt $end.High) { Throw-GitRetimeError $script:ExitUsage 'schedule start is after schedule end' }
            $count = $Scope.Targets.Count
            for ($index = 0; $index -lt $count; $index++) {
                $value = if ($count -eq 1) { $start.Low } else { $start.Low + [long][Math]::Floor($index * ($end.High - $start.Low) / ($count - 1)) }
                $targetLines.Add((New-TargetLine $Scope.Targets[$index] $value $value $start.Offset $value $value $start.Offset $Options.FieldMode))
            }
        }
        normalize {
            $authorValue = @{}
            $committerValue = @{}
            foreach ($commit in $Metadata) {
                $newAuthor = $commit.AuthorEpoch
                $newCommitter = $commit.CommitterEpoch
                foreach ($parent in $commit.Parents) {
                    $newAuthor = [Math]::Max($newAuthor, [long]$authorValue[$parent] + $Options.MinimumGap)
                    $newCommitter = [Math]::Max($newCommitter, [long]$committerValue[$parent] + $Options.MinimumGap)
                }
                $authorValue[$commit.Oid] = $newAuthor
                $committerValue[$commit.Oid] = $newCommitter
                $changed = (($Options.FieldMode -ne 'committer') -and ($newAuthor -ne $commit.AuthorEpoch)) -or (($Options.FieldMode -ne 'author') -and ($newCommitter -ne $commit.CommitterEpoch))
                if ($changed) { $targetLines.Add((New-TargetLine $commit.Oid $newAuthor $newAuthor $commit.AuthorOffset $newCommitter $newCommitter $commit.CommitterOffset $Options.FieldMode)) }
            }
        }
        default { Throw-GitRetimeError $script:ExitInternal "unsupported plan operation: $Operation" }
    }
    if (-not $targetLines.Count) { Throw-GitRetimeError $script:ExitUsage 'the operation does not select a timestamp change' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]](New-PlanHeaderLines $Operation $Options))
    $lines.AddRange([string[]]@($targetLines | Sort-Object { $_.Split("`t")[1] } -CaseSensitive))
    foreach ($ref in ($Scope.Refs | Sort-Object Name -CaseSensitive)) { $lines.Add("ref`t$($ref.Name)`t$($ref.Oid)") }
    @($lines)
}

function New-BatchPlan {
    param([hashtable] $Options, [object] $Scope)
    if (-not $Options.File -or -not (Test-Path -LiteralPath $Options.File -PathType Leaf)) { Throw-GitRetimeError $script:ExitUsage "batch file does not exist: $($Options.File)" }
    $universeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$Scope.Universe, [StringComparer]::Ordinal)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $targetLines = [System.Collections.Generic.List[string]]::new()
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Options.File))) {
        $lineNumber++
        if (-not $line -or $line.StartsWith('#')) { continue }
        $fields = $line.Split("`t")
        if ($fields.Count -ne 3) { Throw-GitRetimeError $script:ExitUsage "batch line $lineNumber must have three fields" }
        $revision = Invoke-GitText -ArgumentList @('rev-parse', '--verify', "$($fields[0])^{commit}") -AllowFailure
        if ($revision.ExitCode -ne 0) { Throw-GitRetimeError $script:ExitUsage "invalid batch revision at line $lineNumber`: $($fields[0])" }
        $oid = $revision.Output.Trim()
        if (-not $universeSet.Contains($oid)) { Throw-GitRetimeError $script:ExitUsage "batch revision is outside the selected scope at line $lineNumber" }
        if (-not $seen.Add($oid)) { Throw-GitRetimeError $script:ExitUsage 'batch file selects a commit more than once' }
        if ($fields[1] -and $fields[1] -ne '-') { $author = ConvertTo-DateInterval $fields[1] $Options.Timezone } else { $author = [pscustomobject]@{ Low = '-'; High = '-'; Offset = '-' } }
        if ($fields[2] -and $fields[2] -ne '-') { $committer = ConvertTo-DateInterval $fields[2] $Options.Timezone } else { $committer = [pscustomobject]@{ Low = '-'; High = '-'; Offset = '-' } }
        if ($author.Low -eq '-' -and $committer.Low -eq '-') { Throw-GitRetimeError $script:ExitUsage "batch line $lineNumber changes no field" }
        $targetLines.Add((New-TargetLine $oid $author.Low $author.High $author.Offset $committer.Low $committer.High $committer.Offset both))
    }
    if (-not $targetLines.Count) { Throw-GitRetimeError $script:ExitUsage 'batch file has no operations' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]](New-PlanHeaderLines batch $Options))
    $lines.AddRange([string[]]@($targetLines | Sort-Object { $_.Split("`t")[1] } -CaseSensitive))
    foreach ($ref in ($Scope.Refs | Sort-Object Name -CaseSensitive)) { $lines.Add("ref`t$($ref.Name)`t$($ref.Oid)") }
    @($lines)
}

function Read-GitRetimePlan {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Throw-GitRetimeError $script:ExitUsage "plan file does not exist: $Path" }
    $header = @{}
    $targets = [System.Collections.Generic.List[object]]::new()
    $refs = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 0
    $format = ''
    foreach ($line in [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Path), $script:Utf8NoBom)) {
        $lineNumber++
        if (-not $line) { continue }
        $fields = $line.Split("`t")
        switch -CaseSensitive ($fields[0]) {
            'git-retime-plan' { if ($fields.Count -ne 2 -or $fields[1] -ne '1') { Throw-GitRetimeError $script:ExitUsage "invalid plan version at line $lineNumber" }; $header.Version = 1 }
            'object-format' { if ($fields.Count -ne 2 -or $fields[1] -notin @('sha1', 'sha256')) { Throw-GitRetimeError $script:ExitUsage "invalid object format at line $lineNumber" }; $format = $fields[1]; $header.ObjectFormat = $format }
            'operation' { if ($fields.Count -ne 2 -or -not $fields[1]) { Throw-GitRetimeError $script:ExitUsage "invalid operation record at line $lineNumber" }; $header.Operation = $fields[1] }
            'seed' { if ($fields.Count -ne 2) { Throw-GitRetimeError $script:ExitUsage "invalid seed record at line $lineNumber" }; $header.Seed = $fields[1] }
            'minimum-gap' { if ($fields.Count -ne 2 -or $fields[1] -notmatch '^\d+$') { Throw-GitRetimeError $script:ExitUsage "invalid minimum gap at line $lineNumber" }; $header.MinimumGap = [long]$fields[1] }
            'chronology' { if ($fields.Count -ne 2 -or $fields[1] -notin @('strict', 'off')) { Throw-GitRetimeError $script:ExitUsage "invalid chronology mode at line $lineNumber" }; $header.Chronology = $fields[1] }
            'field-mode' { if ($fields.Count -ne 2 -or $fields[1] -notin @('author', 'committer', 'both')) { Throw-GitRetimeError $script:ExitUsage "invalid field mode at line $lineNumber" }; $header.FieldMode = $fields[1] }
            'target' {
                if ($fields.Count -ne 8 -or -not (Test-GitOid $format $fields[1])) { Throw-GitRetimeError $script:ExitUsage "invalid target record at line $lineNumber" }
                foreach ($offset in @($fields[4], $fields[7])) { if ($offset -ne '-' -and $offset -notmatch '^[+-]\d{4}$') { Throw-GitRetimeError $script:ExitUsage "invalid target offset at line $lineNumber" } }
                foreach ($index in @(2, 3, 5, 6)) { if ($fields[$index] -ne '-' -and $fields[$index] -notmatch '^-?\d+$') { Throw-GitRetimeError $script:ExitUsage "invalid target interval at line $lineNumber" } }
                if($fields[2]-ne'-' -and [long]$fields[2]-gt[long]$fields[3]){Throw-GitRetimeError $script:ExitUsage "reversed author interval at line $lineNumber"}
                if($fields[5]-ne'-' -and [long]$fields[5]-gt[long]$fields[6]){Throw-GitRetimeError $script:ExitUsage "reversed committer interval at line $lineNumber"}
                $targets.Add([pscustomobject]@{ Oid=$fields[1]; AuthorLow=$fields[2]; AuthorHigh=$fields[3]; AuthorOffset=$fields[4]; CommitterLow=$fields[5]; CommitterHigh=$fields[6]; CommitterOffset=$fields[7] })
            }
            'ref' {
                if ($fields.Count -ne 3 -or -not (Test-GitOid $format $fields[2])) { Throw-GitRetimeError $script:ExitUsage "invalid ref record at line $lineNumber" }
                if($fields[1]-ne'HEAD'){$check=Invoke-GitText -ArgumentList @('check-ref-format',$fields[1]) -AllowFailure;if($check.ExitCode-ne0){Throw-GitRetimeError $script:ExitUsage "invalid ref at line $lineNumber"}}
                $refs.Add([pscustomobject]@{ Name=$fields[1]; Oid=$fields[2] })
            }
            default { Throw-GitRetimeError $script:ExitUsage "unknown plan record at line $lineNumber`: $($fields[0])" }
        }
    }
    foreach ($key in @('Version','ObjectFormat','Operation','Seed','MinimumGap','Chronology','FieldMode')) { if (-not $header.ContainsKey($key)) { Throw-GitRetimeError $script:ExitUsage 'plan header is incomplete' } }
    if ($header.ObjectFormat -ne (Get-GitObjectFormat)) { Throw-GitRetimeError $script:ExitUsage 'plan object format does not match the repository' }
    if (-not $targets.Count) { Throw-GitRetimeError $script:ExitUsage 'plan has no targets' }
    if (-not $refs.Count) { Throw-GitRetimeError $script:ExitUsage 'plan has no refs' }
    [pscustomobject]@{ Header=$header; Targets=@($targets); Refs=@($refs); Path=$Path }
}

function Resolve-PlanScope {
    param([object] $Plan)
    foreach ($ref in $Plan.Refs) {
        $current = Invoke-GitText -ArgumentList @('rev-parse', '--verify', "$($ref.Name)^{commit}") -AllowFailure
        if ($current.ExitCode -ne 0 -or $current.Output.Trim() -ne $ref.Oid) { Throw-GitRetimeError $script:ExitTransaction "ref changed after plan creation: $($ref.Name)" }
    }
    $tips = @($Plan.Refs | ForEach-Object Oid)
    $universe = @(Get-GitLines (@('rev-list', '--topo-order', '--reverse') + $tips))
    $universeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$universe, [StringComparer]::Ordinal)
    foreach ($target in $Plan.Targets) { if (-not $universeSet.Contains($target.Oid)) { Throw-GitRetimeError $script:ExitUsage "plan target is outside plan refs: $($target.Oid)" } }
    [pscustomobject]@{ Refs=$Plan.Refs; Universe=$universe; Targets=@($Plan.Targets | ForEach-Object Oid) }
}

function Resolve-PlanTimestamps {
    param([object] $Plan, [object[]] $Metadata)
    $byOid = @{}; $authorLow=@{}; $authorHigh=@{}; $authorSelected=@{}; $committerLow=@{}; $committerHigh=@{}; $committerSelected=@{}
    foreach ($commit in $Metadata) { $byOid[$commit.Oid]=$commit; $authorLow[$commit.Oid]=$commit.AuthorEpoch; $authorHigh[$commit.Oid]=$commit.AuthorEpoch; $committerLow[$commit.Oid]=$commit.CommitterEpoch; $committerHigh[$commit.Oid]=$commit.CommitterEpoch }
    $targetByOid=@{}
    foreach ($target in $Plan.Targets) {
        $targetByOid[$target.Oid]=$target
        if ($target.AuthorLow -ne '-') { $authorSelected[$target.Oid]=$true; $authorLow[$target.Oid]=[long]$target.AuthorLow; $authorHigh[$target.Oid]=[long]$target.AuthorHigh }
        if ($target.CommitterLow -ne '-') { $committerSelected[$target.Oid]=$true; $committerLow[$target.Oid]=[long]$target.CommitterLow; $committerHigh[$target.Oid]=[long]$target.CommitterHigh }
    }
    if ($Plan.Header.Chronology -eq 'strict') {
        Update-PlanBounds $Metadata $authorLow $authorHigh $authorSelected $Plan.Header.MinimumGap author
        Update-PlanBounds $Metadata $committerLow $committerHigh $committerSelected $Plan.Header.MinimumGap committer
    }
    $authorNew=@{}; $committerNew=@{}; $solved=[System.Collections.Generic.List[object]]::new()
    foreach ($commit in $Metadata) {
        if ($authorSelected.ContainsKey($commit.Oid)) {
            $low=[long]$authorLow[$commit.Oid]
            if ($Plan.Header.Chronology -eq 'strict') { foreach($parent in $commit.Parents) { $low=[Math]::Max($low,[long]$authorNew[$parent]+$Plan.Header.MinimumGap) } }
            $authorNew[$commit.Oid]=Get-DeterministicSecond $Plan.Header.Seed $Plan.Header.Operation $commit.Oid author $low ([long]$authorHigh[$commit.Oid])
        } else { $authorNew[$commit.Oid]=$commit.AuthorEpoch }
        if ($committerSelected.ContainsKey($commit.Oid)) {
            $low=[long]$committerLow[$commit.Oid]
            if ($Plan.Header.Chronology -eq 'strict') { foreach($parent in $commit.Parents) { $low=[Math]::Max($low,[long]$committerNew[$parent]+$Plan.Header.MinimumGap) } }
            $committerNew[$commit.Oid]=Get-DeterministicSecond $Plan.Header.Seed $Plan.Header.Operation $commit.Oid committer $low ([long]$committerHigh[$commit.Oid])
        } else { $committerNew[$commit.Oid]=$commit.CommitterEpoch }
        if ($authorSelected.ContainsKey($commit.Oid) -or $committerSelected.ContainsKey($commit.Oid)) {
            $target=$targetByOid[$commit.Oid]
            $solved.Add([pscustomobject]@{ Oid=$commit.Oid; AuthorEpoch=[long]$authorNew[$commit.Oid]; AuthorOffset=if($target.AuthorOffset -eq '-'){$commit.AuthorOffset}else{$target.AuthorOffset}; CommitterEpoch=[long]$committerNew[$commit.Oid]; CommitterOffset=if($target.CommitterOffset -eq '-'){$commit.CommitterOffset}else{$target.CommitterOffset}; ChangeAuthor=$authorSelected.ContainsKey($commit.Oid); ChangeCommitter=$committerSelected.ContainsKey($commit.Oid) })
        }
    }
    @($solved)
}

function Update-PlanBounds {
    param([object[]]$Metadata,[hashtable]$Low,[hashtable]$High,[hashtable]$Selected,[long]$Gap,[string]$Field)
    foreach($commit in $Metadata){
        foreach($parent in $commit.Parents){ if($Selected.ContainsKey($commit.Oid)-or $Selected.ContainsKey($parent)){ $candidate=[long]$Low[$parent]+$Gap; if($candidate -gt [long]$Low[$commit.Oid]){$Low[$commit.Oid]=$candidate} } }
        if([long]$Low[$commit.Oid] -gt [long]$High[$commit.Oid]){Throw-GitRetimeError $script:ExitChronology "$Field chronology has no solution at commit $($commit.Oid)"}
    }
    for($index=$Metadata.Count-1;$index-ge 0;$index--){
        $commit=$Metadata[$index]
        foreach($parent in $commit.Parents){ if($Selected.ContainsKey($commit.Oid)-or $Selected.ContainsKey($parent)){ $candidate=[long]$High[$commit.Oid]-$Gap; if($candidate -lt [long]$High[$parent]){$High[$parent]=$candidate}; if([long]$Low[$parent] -gt [long]$High[$parent]){Throw-GitRetimeError $script:ExitChronology "$Field chronology has no solution at commit $parent"} } }
    }
}
