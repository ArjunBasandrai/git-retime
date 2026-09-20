function Resolve-LocalBranchRef {
    param([string] $Name)
    $ref = if ($Name.StartsWith('refs/heads/')) { $Name } else { "refs/heads/$Name" }
    $result = Invoke-GitText -ArgumentList @('show-ref', '--verify', '--quiet', $ref) -AllowFailure
    if ($result.ExitCode -ne 0) { Throw-GitRetimeError $script:ExitUsage "local branch does not exist: $Name" }
    $ref
}

function Get-GitScopeData {
    param([hashtable] $Options)
    $refs = [System.Collections.Generic.List[object]]::new()
    $refNames = @()
    if ($Options.AllLocalBranches -or $Options.RepoScope) {
        $refNames = @(Get-GitLines @('for-each-ref', '--format=%(refname)', 'refs/heads') | Sort-Object -CaseSensitive)
    } elseif ($Options.Branches.Count) {
        $refNames = @($Options.Branches | ForEach-Object { Resolve-LocalBranchRef $_ })
    } else {
        $symbolic = Invoke-GitText -ArgumentList @('symbolic-ref', '-q', 'HEAD') -AllowFailure
        if ($symbolic.ExitCode -eq 0) {
            $refNames = @($symbolic.Output.Trim())
        } else {
            if (-not $Options.AllowDetached) { Throw-GitRetimeError $script:ExitSafety 'HEAD is detached; use --allow-detached to rewrite it' }
            $refNames = @('HEAD')
        }
    }
    if (-not $refNames.Count) { Throw-GitRetimeError $script:ExitSafety 'the selected scope has no refs' }
    foreach ($ref in ($refNames | Sort-Object -Unique -CaseSensitive)) {
        $result = Invoke-GitText -ArgumentList @('rev-parse', '--verify', "$ref^{commit}") -AllowFailure
        if ($result.ExitCode -ne 0) { Throw-GitRetimeError $script:ExitUsage "ref does not point to a commit: $ref" }
        $refs.Add([pscustomobject]@{ Name = $ref; Oid = $result.Output.Trim() })
    }
    $tips = @($refs | ForEach-Object Oid)
    $universe = @(Get-GitLines (@('rev-list', '--topo-order', '--reverse') + $tips))
    $universeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$universe, [StringComparer]::Ordinal)
    if ($Options.Commits.Count) {
        $selected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($revision in $Options.Commits) {
            $result = Invoke-GitText -ArgumentList @('rev-parse', '--verify', '--end-of-options', "$revision^{commit}") -AllowFailure
            if ($result.ExitCode -ne 0) { Throw-GitRetimeError $script:ExitUsage "invalid commit revision: $revision" }
            $oid = $result.Output.Trim()
            if (-not $universeSet.Contains($oid)) { Throw-GitRetimeError $script:ExitUsage "target commit is outside the selected ref scope: $oid" }
            if (-not $selected.Add($oid)) { Throw-GitRetimeError $script:ExitUsage "--commit resolves to the same commit more than once: $oid" }
        }
        $targets = @($universe | Where-Object { $selected.Contains($_) })
    } elseif ($Options.Range) {
        $arguments = @('rev-list', '--topo-order', '--reverse')
        if ($Options.FirstParent) { $arguments += '--first-parent' }
        $arguments += $Options.Range
        $targets = @(Get-GitLines $arguments)
    } elseif ($Options.RootScope) {
        $arguments = @('rev-list', '--max-parents=0', '--topo-order', '--reverse')
        if ($Options.FirstParent) { $arguments += '--first-parent' }
        $targets = @(Get-GitLines ($arguments + $tips))
    } elseif ($Options.Last -gt 0) {
        $arguments = @('rev-list', "--max-count=$($Options.Last)", '--topo-order', '--reverse')
        if ($Options.FirstParent) { $arguments += '--first-parent' }
        $targets = @(Get-GitLines ($arguments + $tips))
    } else {
        $targets = @($tips | Sort-Object -Unique -CaseSensitive)
    }
    if (-not $targets.Count) { Throw-GitRetimeError $script:ExitUsage 'the target selection is empty' }
    foreach ($target in $targets) {
        if (-not $universeSet.Contains($target)) { Throw-GitRetimeError $script:ExitUsage "target commit is outside the selected ref scope: $target" }
    }
    [pscustomobject]@{ Refs = @($refs); Universe = $universe; Targets = $targets }
}

function Get-GitMetadata {
    param([string[]] $Oids)
    $inputText = ($Oids -join "`n") + "`n"
    $lines = Get-GitLines -ArgumentList @('log', '--no-walk=unsorted', '--stdin', '--format=%H%x09-%P%x09%at%x09%ai%x09%ct%x09%ci') -InputText $inputText
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $lines) {
        $fields = $line.Split("`t")
        if ($fields.Count -ne 6) { Throw-GitRetimeError $script:ExitObject 'Git returned invalid commit metadata' }
        $parentsText = $fields[1].Substring(1)
        $result.Add([pscustomobject]@{
            Oid = $fields[0]
            Parents = if ($parentsText) { [string[]]($parentsText -split ' ') } else { [string[]]@() }
            AuthorEpoch = [long]$fields[2]
            AuthorOffset = $fields[3].Substring($fields[3].Length - 5)
            CommitterEpoch = [long]$fields[4]
            CommitterOffset = $fields[5].Substring($fields[5].Length - 5)
        })
    }
    @($result)
}

function Get-RewriteClosure {
    param([object[]] $Metadata, [string[]] $Targets)
    $selected = [System.Collections.Generic.HashSet[string]]::new([string[]]$Targets, [StringComparer]::Ordinal)
    $closure = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($commit in $Metadata) {
        $include = $selected.Contains($commit.Oid)
        if (-not $include) {
            foreach ($parent in $commit.Parents) { if ($closure.Contains($parent)) { $include = $true; break } }
        }
        if ($include) { [void]$closure.Add($commit.Oid); $ordered.Add($commit.Oid) }
    }
    @($ordered)
}

function Get-ActiveGitOperation {
    $gitDirectory = Get-GitDirectory
    foreach ($name in @('rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_LOG', 'sequencer')) {
        if (Test-Path -LiteralPath (Join-Path $gitDirectory $name)) { return $name }
    }
    $null
}

function Assert-RepositorySafety {
    param([hashtable] $Options, [object[]] $Refs, [string[]] $Closure)
    if (-not $Options.AllowDirty) {
        $unstaged = Invoke-GitText -ArgumentList @('diff', '--quiet', '--ignore-submodules', '--') -AllowFailure
        if ($unstaged.ExitCode -ne 0) { Throw-GitRetimeError $script:ExitSafety 'the worktree has unstaged changes; use --allow-dirty' }
        $staged = Invoke-GitText -ArgumentList @('diff', '--cached', '--quiet', '--ignore-submodules', '--') -AllowFailure
        if ($staged.ExitCode -ne 0) { Throw-GitRetimeError $script:ExitSafety 'the index has staged changes; use --allow-dirty' }
        if (@(Get-GitLines @('ls-files', '--others', '--exclude-standard')).Count) { Throw-GitRetimeError $script:ExitSafety 'the worktree has untracked files; use --allow-dirty' }
    }
    $active = Get-ActiveGitOperation
    if ($active -and -not $Options.AllowActiveOperation) { Throw-GitRetimeError $script:ExitSafety "an active Git operation was detected ($active); use --allow-active-operation" }
    if (((Invoke-GitText -ArgumentList @('rev-parse', '--is-shallow-repository')).Output.Trim() -eq 'true') -and -not $Options.AllowShallow) {
        Throw-GitRetimeError $script:ExitSafety 'the repository is shallow; use --allow-shallow'
    }
    if (@(Get-GitLines @('for-each-ref', '--format=%(refname)', 'refs/replace')).Count -and -not $Options.AllowReplaceRefs) {
        Throw-GitRetimeError $script:ExitSafety 'replace refs exist; use --allow-replace-refs'
    }
    if (-not $Options.AllowPublished) {
        foreach ($ref in $Refs) {
            if (-not $ref.Name.StartsWith('refs/heads/')) { continue }
            $upstream = (Invoke-GitText -ArgumentList @('for-each-ref', '--format=%(upstream)', $ref.Name)).Output.Trim()
            if ($upstream) { Throw-GitRetimeError $script:ExitSafety "branch $($ref.Name.Substring(11)) has an upstream; use --allow-published" }
        }
    }
    if (-not $Options.AllowLinkedWorktrees) {
        $selectedRefs = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Refs | ForEach-Object Name), [StringComparer]::Ordinal)
        $currentPath = ''
        foreach ($line in (Get-GitLines @('worktree', 'list', '--porcelain'))) {
            if ($line.StartsWith('worktree ')) { $currentPath = $line.Substring(9) }
            elseif ($line.StartsWith('branch ')) {
                $branch = $line.Substring(7)
                if ($selectedRefs.Contains($branch) -and ([IO.Path]::GetFullPath($currentPath) -ne [IO.Path]::GetFullPath((Get-Location).Path))) {
                    Throw-GitRetimeError $script:ExitSafety "an affected branch is checked out in another worktree: $currentPath; use --allow-linked-worktrees"
                }
            }
        }
    }
    if ($Closure.Count) { Assert-RewriteMetadataSafety $Options $Closure }
}

function Assert-RewriteMetadataSafety {
    param([hashtable] $Options, [string[]] $Closure)
    $closureSet = [System.Collections.Generic.HashSet[string]]::new($Closure, [StringComparer]::Ordinal)
    if (-not $Options.AllowInvalidSignatures) {
        $objects=Get-GitCommitObjectMap $Closure
        foreach ($oid in $Closure) {
            $raw = $objects[$oid]
            $header = [Text.Encoding]::ASCII.GetString($raw)
            $separator = $header.IndexOf("`n`n")
            if ($separator -ge 0) { $header = $header.Substring(0, $separator) }
            if ($header -cmatch '(?m)^gpgsig ') { Throw-GitRetimeError $script:ExitSafety "rewriting signed commit $oid invalidates its signature; use --allow-invalid-signatures" }
        }
    }
    if (-not $Options.AllowTagDivergence) {
        foreach ($line in (Get-GitLines @('for-each-ref', '--format=%(objectname)%09%(objecttype)%09%(*objectname)', 'refs/tags'))) {
            $fields = $line.Split("`t")
            $target = if ($fields.Count -ge 3 -and $fields[2]) { $fields[2] } elseif ($fields[1] -eq 'commit') { $fields[0] } else { '' }
            if ($target -and $closureSet.Contains($target)) { Throw-GitRetimeError $script:ExitSafety "a tag points to rewritten commit $target; use --allow-tag-divergence" }
        }
    }
    if (@(Get-GitLines @('for-each-ref', '--format=%(refname)', 'refs/notes')).Count -and -not $Options.AllowNoteDivergence) {
        Throw-GitRetimeError $script:ExitSafety 'notes refs exist; use --allow-note-divergence'
    }
}
