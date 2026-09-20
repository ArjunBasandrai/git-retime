function Invoke-GitBinaryRead {
    param([string[]] $ArgumentList)
    $info = [System.Diagnostics.ProcessStartInfo]::new('git.exe')
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = (Get-Location).ProviderPath
    $info.Environment['GIT_NO_REPLACE_OBJECTS'] = '1'
    foreach ($argument in $ArgumentList) { [void]$info.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    [void]$process.Start()
    $memory = [System.IO.MemoryStream]::new()
    $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
    $errorTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    [void]$copyTask.GetAwaiter().GetResult()
    $errorText = $errorTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { Throw-GitRetimeError $script:ExitObject $errorText.Trim() }
    return ,$memory.ToArray()
}

function Invoke-GitHashCommit {
    param([byte[]] $Bytes)
    $info = [System.Diagnostics.ProcessStartInfo]::new('git.exe')
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = (Get-Location).ProviderPath
    $info.Environment['GIT_NO_REPLACE_OBJECTS'] = '1'
    foreach ($argument in @('hash-object', '-t', 'commit', '-w', '--stdin')) { [void]$info.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    [void]$process.Start()
    $process.StandardInput.BaseStream.Write($Bytes, 0, $Bytes.Length)
    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
    $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
    if ($process.ExitCode -ne 0) { Throw-GitRetimeError $script:ExitObject $stderr }
    $stdout
}

function Read-AsciiStreamLine {
    param([System.IO.Stream] $Stream)
    $memory = [System.IO.MemoryStream]::new()
    while (($value = $Stream.ReadByte()) -ge 0) {
        if ($value -eq 10) { return [Text.Encoding]::ASCII.GetString($memory.ToArray()) }
        $memory.WriteByte([byte]$value)
    }
    if ($memory.Length) { return [Text.Encoding]::ASCII.GetString($memory.ToArray()) }
    $null
}

function Read-ExactStreamBytes {
    param([System.IO.Stream] $Stream, [int] $Size)
    $buffer = [byte[]]::new($Size)
    $offset = 0
    while ($offset -lt $Size) {
        $count = $Stream.Read($buffer, $offset, $Size - $offset)
        if ($count -le 0) { Throw-GitRetimeError $script:ExitObject 'Git returned a short batch object' }
        $offset += $count
    }
    return ,$buffer
}

function Get-GitCommitObjectMap {
    param([string[]] $Oids)
    $info = [Diagnostics.ProcessStartInfo]::new('git.exe')
    $info.UseShellExecute=$false; $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true; $info.CreateNoWindow=$true
    $info.WorkingDirectory=(Get-Location).ProviderPath; $info.Environment['GIT_NO_REPLACE_OBJECTS']='1'
    foreach($argument in @('cat-file','--batch')){[void]$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($info)
    $errorTask=$process.StandardError.ReadToEndAsync()
    $inputText=($Oids -join "`n")+"`n"
    $inputTask=$process.StandardInput.WriteAsync($inputText)
    $objects=@{}
    foreach($expectedOid in $Oids){
        $header=Read-AsciiStreamLine $process.StandardOutput.BaseStream
        if($header -notmatch '^([0-9a-f]+) commit (\d+)$'){Throw-GitRetimeError $script:ExitObject 'Git returned an invalid batch object header'}
        $oid=$Matches[1];$size=[int]$Matches[2]
        $objects[$oid]=Read-ExactStreamBytes $process.StandardOutput.BaseStream $size
        if($process.StandardOutput.BaseStream.ReadByte()-ne10){Throw-GitRetimeError $script:ExitObject 'Git returned an invalid batch object delimiter'}
    }
    [void]$inputTask.GetAwaiter().GetResult();$process.StandardInput.Close();$process.WaitForExit();$errorText=$errorTask.GetAwaiter().GetResult()
    if($process.ExitCode-ne0){Throw-GitRetimeError $script:ExitObject $errorText.Trim()}
    $objects
}

function Get-GitCommitOid {
    param([byte[]]$Bytes,[string]$Format)
    $header=[Text.Encoding]::ASCII.GetBytes("commit $($Bytes.Length)`0")
    $input=[byte[]]::new($header.Length+$Bytes.Length)
    [Array]::Copy($header,0,$input,0,$header.Length);[Array]::Copy($Bytes,0,$input,$header.Length,$Bytes.Length)
    $hash=if($Format-eq'sha1'){[Security.Cryptography.SHA1]::HashData($input)}else{[Security.Cryptography.SHA256]::HashData($input)}
    [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Test-BytePrefix {
    param([byte[]] $Bytes, [int] $Start, [byte[]] $Prefix)
    if ($Start + $Prefix.Length -gt $Bytes.Length) { return $false }
    for ($index = 0; $index -lt $Prefix.Length; $index++) {
        if ($Bytes[$Start + $index] -ne $Prefix[$index]) { return $false }
    }
    $true
}

function Write-Bytes {
    param([System.IO.MemoryStream] $Stream, [byte[]] $Bytes, [int] $Start = 0, [int] $Count = -1)
    if ($Count -lt 0) { $Count = $Bytes.Length - $Start }
    $Stream.Write($Bytes, $Start, $Count)
}

function Convert-GitCommitBytes {
    param(
        [byte[]] $Bytes,
        [hashtable] $ParentMap,
        [Nullable[long]] $AuthorEpoch,
        [string] $AuthorOffset,
        [Nullable[long]] $CommitterEpoch,
        [string] $CommitterOffset
    )
    $ascii = [System.Text.Encoding]::ASCII
    $parentPrefix = $ascii.GetBytes('parent ')
    $authorPrefix = $ascii.GetBytes('author ')
    $committerPrefix = $ascii.GetBytes('committer ')
    $output = [System.IO.MemoryStream]::new()
    $lineStart = 0
    $position = 0
    $headerEnd = -1
    while ($position -lt $Bytes.Length - 1) {
        if ($Bytes[$position] -eq 10 -and $Bytes[$position + 1] -eq 10) { $headerEnd = $position; break }
        if ($position -lt $Bytes.Length - 3 -and $Bytes[$position] -eq 13 -and $Bytes[$position + 1] -eq 10 -and $Bytes[$position + 2] -eq 13 -and $Bytes[$position + 3] -eq 10) { $headerEnd = $position; break }
        $position++
    }
    if ($headerEnd -lt 0) { Throw-GitRetimeError $script:ExitObject 'commit object has no header separator' }

    while ($lineStart -lt $headerEnd) {
        $lineLf = [Array]::IndexOf($Bytes, [byte]10, $lineStart, $headerEnd - $lineStart)
        $lineAfter = if ($lineLf -ge 0) { $lineLf + 1 } else { $headerEnd }
        $contentEnd = if ($lineLf -ge 0 -and $lineLf -gt $lineStart -and $Bytes[$lineLf - 1] -eq 13) { $lineLf - 1 } elseif ($lineLf -ge 0) { $lineLf } else { $headerEnd }
        if (Test-BytePrefix $Bytes $lineStart $parentPrefix) {
            $oldOid = $ascii.GetString($Bytes, $lineStart + $parentPrefix.Length, $contentEnd - $lineStart - $parentPrefix.Length)
            $newOid = if ($ParentMap.ContainsKey($oldOid)) { [string]$ParentMap[$oldOid] } else { $oldOid }
            Write-Bytes $output $parentPrefix
            Write-Bytes $output $ascii.GetBytes($newOid)
            if ($lineAfter -gt $contentEnd) { Write-Bytes $output $Bytes $contentEnd ($lineAfter - $contentEnd) }
        } elseif (($null -ne $AuthorEpoch) -and (Test-BytePrefix $Bytes $lineStart $authorPrefix)) {
            Write-ReplacedIdentityLine $output $Bytes $lineStart $contentEnd $lineAfter ([long]$AuthorEpoch) $AuthorOffset
        } elseif (($null -ne $CommitterEpoch) -and (Test-BytePrefix $Bytes $lineStart $committerPrefix)) {
            Write-ReplacedIdentityLine $output $Bytes $lineStart $contentEnd $lineAfter ([long]$CommitterEpoch) $CommitterOffset
        } else {
            Write-Bytes $output $Bytes $lineStart ($lineAfter - $lineStart)
        }
        $lineStart = $lineAfter
    }
    Write-Bytes $output $Bytes $headerEnd ($Bytes.Length - $headerEnd)
    return ,$output.ToArray()
}

function Write-ReplacedIdentityLine {
    param(
        [System.IO.MemoryStream] $Output, [byte[]] $Bytes,
        [int] $LineStart, [int] $ContentEnd, [int] $LineAfter,
        [long] $Epoch, [string] $Offset
    )
    $lastSpace = -1
    $secondSpace = -1
    for ($index = $ContentEnd - 1; $index -ge $LineStart; $index--) {
        if ($Bytes[$index] -eq 32) {
            if ($lastSpace -lt 0) { $lastSpace = $index } else { $secondSpace = $index; break }
        }
    }
    if ($secondSpace -lt 0 -or $lastSpace -lt 0) { Throw-GitRetimeError $script:ExitObject 'commit identity header has an invalid timestamp' }
    Write-Bytes $Output $Bytes $LineStart ($secondSpace - $LineStart + 1)
    $replacement = [System.Text.Encoding]::ASCII.GetBytes("$Epoch $Offset")
    Write-Bytes $Output $replacement
    if ($LineAfter -gt $ContentEnd) { Write-Bytes $Output $Bytes $ContentEnd ($LineAfter - $ContentEnd) }
}

function Rewrite-GitCommitObject {
    param(
        [string] $Oid, [hashtable] $ParentMap,
        [Nullable[long]] $AuthorEpoch, [string] $AuthorOffset,
        [Nullable[long]] $CommitterEpoch, [string] $CommitterOffset
    )
    $raw = Invoke-GitBinaryRead @('cat-file', 'commit', $Oid)
    $changed = Convert-GitCommitBytes $raw $ParentMap $AuthorEpoch $AuthorOffset $CommitterEpoch $CommitterOffset
    Invoke-GitHashCommit $changed
}

function Rewrite-GitGraph {
    param([object[]] $Metadata, [object[]] $Solved)
    $solvedByOid = @{}
    foreach ($item in $Solved) { $solvedByOid[$item.Oid] = $item }
    $map = @{}
    $closure = [System.Collections.Generic.List[string]]::new()
    $closureSet=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($commit in $Metadata){
        $include=$solvedByOid.ContainsKey($commit.Oid)
        if(-not $include){foreach($parent in $commit.Parents){if($closureSet.Contains($parent)){$include=$true;break}}}
        if($include){[void]$closureSet.Add($commit.Oid);$closure.Add($commit.Oid)}
    }
    $rawObjects=Get-GitCommitObjectMap @($closure)
    $format=Get-GitObjectFormat
    $writeDirectory=Join-Path (Get-GitCommonDirectory) ("git-retime/tmp/objects.{0}" -f [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($writeDirectory)|Out-Null
    $paths=[System.Collections.Generic.List[string]]::new();$expectedOids=[System.Collections.Generic.List[string]]::new()
    try{
    foreach ($commit in $Metadata) {
        $parentMap = @{}
        $changed = $solvedByOid.ContainsKey($commit.Oid)
        foreach ($parent in $commit.Parents) {
            $newParent = if ($map.ContainsKey($parent)) { $map[$parent] } else { $parent }
            $parentMap[$parent] = $newParent
            if ($newParent -ne $parent) { $changed = $true }
        }
        if ($changed) {
            if ($solvedByOid.ContainsKey($commit.Oid)) {
                $item = $solvedByOid[$commit.Oid]
                $authorEpoch = if ($item.ChangeAuthor) { [Nullable[long]]$item.AuthorEpoch } else { $null }
                $committerEpoch = if ($item.ChangeCommitter) { [Nullable[long]]$item.CommitterEpoch } else { $null }
                $changedBytes = Convert-GitCommitBytes $rawObjects[$commit.Oid] $parentMap $authorEpoch $item.AuthorOffset $committerEpoch $item.CommitterOffset
            } else {
                $changedBytes = Convert-GitCommitBytes $rawObjects[$commit.Oid] $parentMap $null '' $null ''
            }
            $newOid=Get-GitCommitOid $changedBytes $format
            $path=Join-Path $writeDirectory "$newOid.commit";[IO.File]::WriteAllBytes($path,$changedBytes);$paths.Add($path);$expectedOids.Add($newOid)
            $map[$commit.Oid] = $newOid
        } else {
            $map[$commit.Oid] = $commit.Oid
        }
    }
    $writeResult=Invoke-GitText -ArgumentList @('hash-object','-t','commit','-w','--stdin-paths') -InputText (($paths -join "`n")+"`n")
    $actualOids=@($writeResult.Output.TrimEnd("`r","`n")-split"`r?`n")
    if(($actualOids -join "`n")-cne($expectedOids -join "`n")){Throw-GitRetimeError $script:ExitObject 'Git object IDs do not match calculated object IDs'}
    }finally{if(Test-Path -LiteralPath $writeDirectory){Remove-Item -LiteralPath $writeDirectory -Recurse -Force}}
    [pscustomobject]@{ Map = $map; Closure = @($closure) }
}

function Get-BackupRefName {
    param([string] $OperationId, [string] $Ref)
    $suffix = if ($Ref -eq 'HEAD') { 'detached-head' } else { $Ref.Substring(5) }
    "refs/git-retime/backups/$OperationId/$suffix"
}

function Get-ManifestPath {
    param([string] $OperationId)
    Join-Path (Get-GitCommonDirectory) "git-retime/operations/$OperationId.manifest"
}

function Set-ManifestState {
    param([string] $Path, [string] $State)
    $lines = [IO.File]::ReadAllLines($Path, $script:Utf8NoBom)
    for ($index = 0; $index -lt $lines.Count; $index++) { if ($lines[$index].StartsWith("state`t")) { $lines[$index] = "state`t$State" } }
    Write-Utf8NoBomLines $Path $lines
}

function Invoke-RefTransaction {
    param([object[]] $Updates, [string] $OperationId, [string] $PlanPath)
    if (-not $OperationId) { $OperationId = Get-OperationId }
    $manifestPath = Get-ManifestPath $OperationId
    if (Test-Path -LiteralPath $manifestPath) { Throw-GitRetimeError $script:ExitTransaction "operation ID already exists: $OperationId" }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $manifestPath)) | Out-Null
    $zero = if ((Get-GitObjectFormat) -eq 'sha1') { '0' * 40 } else { '0' * 64 }
    $manifest = [System.Collections.Generic.List[string]]::new()
    $manifest.Add("git-retime-operation`t1")
    $manifest.Add("id`t$OperationId")
    $manifest.Add("state`tprepared")
    $manifest.Add("created`t$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())")
    $manifest.Add("object-format`t$(Get-GitObjectFormat)")
    $identityLines=@($Updates|Sort-Object Ref -CaseSensitive|ForEach-Object{"$($_.Ref)`t$($_.Old)"})
    $identityText="git-retime-repository-v1`n$(Get-GitObjectFormat)`n"+($identityLines-join"`n")+"`n"
    $manifest.Add("repository-id`t$(Get-Sha256Hex $script:Utf8NoBom.GetBytes($identityText))")
    if($PlanPath){$manifest.Add("plan-sha256`t$((Get-FileHash -Algorithm SHA256 -LiteralPath $PlanPath).Hash.ToLowerInvariant())")}
    foreach ($update in $Updates) {
        $backup = Get-BackupRefName $OperationId $update.Ref
        $manifest.Add("ref`t$($update.Ref)`t$($update.Old)`t$($update.New)`t$backup")
    }
    Write-Utf8NoBomLines $manifestPath @($manifest)
    if ($env:GIT_RETIME_FAIL_STAGE -eq 'after-manifest') { Throw-GitRetimeError $script:ExitTransaction 'injected failure after manifest creation' }
    foreach ($update in $Updates) {
        $backup = Get-BackupRefName $OperationId $update.Ref
        $backupResult = Invoke-GitText -ArgumentList @('update-ref', $backup, $update.Old, $zero) -AllowFailure
        if ($backupResult.ExitCode -ne 0) { Throw-GitRetimeError $script:ExitTransaction "cannot create backup ref: $backup" }
    }
    if ($env:GIT_RETIME_FAIL_STAGE -eq 'after-backups') { Throw-GitRetimeError $script:ExitTransaction 'injected failure after backup creation' }
    if ($env:GIT_RETIME_FAIL_STAGE -eq 'before-refs') { Throw-GitRetimeError $script:ExitTransaction 'injected failure before ref transaction' }
    $commands = [System.Collections.Generic.List[string]]::new()
    $commands.Add('start')
    if ($Updates.Ref -contains 'HEAD') { $commands.Add('option no-deref') }
    foreach ($update in $Updates) { $commands.Add("update $($update.Ref) $($update.New) $($update.Old)") }
    $commands.Add('prepare'); $commands.Add('commit')
    $transaction = Invoke-GitText -ArgumentList @('update-ref', '--stdin') -InputText (($commands -join "`n") + "`n") -AllowFailure
    if ($transaction.ExitCode -ne 0) { Throw-GitRetimeError $script:ExitTransaction 'the ref transaction failed; refs changed concurrently or Git rejected an update' }
    if ($env:GIT_RETIME_FAIL_STAGE -eq 'after-refs') { Throw-GitRetimeError $script:ExitTransaction 'injected failure after ref transaction' }
    Set-ManifestState $manifestPath committed
    $OperationId
}

function Apply-GitRewrite {
    param([object[]] $Refs, [hashtable] $Map, [string] $PlanPath)
    $updates = [System.Collections.Generic.List[object]]::new()
    foreach ($ref in $Refs) {
        $newOid = if ($Map.ContainsKey($ref.Oid)) { $Map[$ref.Oid] } else { $ref.Oid }
        if ($newOid -ne $ref.Oid) { $updates.Add([pscustomobject]@{ Ref=$ref.Name; Old=$ref.Oid; New=$newOid }) }
    }
    if (-not $updates.Count) { Throw-GitRetimeError $script:ExitUsage 'the operation does not change a selected ref' }
    $operationId = Invoke-RefTransaction @($updates) '' $PlanPath
    [Console]::Out.WriteLine("Applied operation $operationId")
}

function Get-ManifestValue {
    param([string] $Path, [string] $Key)
    foreach ($line in [IO.File]::ReadAllLines($Path, $script:Utf8NoBom)) {
        $fields = $line.Split("`t")
        if ($fields[0] -eq $Key -and $fields.Count -ge 2) { return $fields[1] }
    }
    ''
}

function Get-ManifestRefRecords {
    param([string] $Path)
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($line in [IO.File]::ReadAllLines($Path, $script:Utf8NoBom)) {
        $fields = $line.Split("`t")
        if ($fields[0] -eq 'ref' -and $fields.Count -eq 5) { $records.Add([pscustomobject]@{ Ref=$fields[1]; Old=$fields[2]; New=$fields[3]; Backup=$fields[4] }) }
    }
    @($records)
}

function Find-OperationManifest {
    param([string] $Requested, [string] $WantedState)
    $directory = Join-Path (Get-GitCommonDirectory) 'git-retime/operations'
    if ($Requested) {
        $path = Join-Path $directory "$Requested.manifest"
        if (-not (Test-Path -LiteralPath $path)) { Throw-GitRetimeError $script:ExitUsage "operation does not exist: $Requested" }
        if ($WantedState -and (Get-ManifestValue $path state) -ne $WantedState) { Throw-GitRetimeError $script:ExitUsage "operation is not in state $WantedState`: $Requested" }
        return $path
    }
    if (Test-Path -LiteralPath $directory) {
        foreach ($file in (Get-ChildItem -LiteralPath $directory -Filter '*.manifest' | Sort-Object Name -Descending)) {
            if (-not $WantedState -or (Get-ManifestValue $file.FullName state) -eq $WantedState) { return $file.FullName }
        }
    }
    Throw-GitRetimeError $script:ExitUsage "there is no operation in state $WantedState"
}

function Invoke-ManifestReplay {
    param([ValidateSet('undo','redo')] [string] $Action, [string] $Requested)
    $wanted = if ($Action -eq 'undo') { 'committed' } else { 'undone' }
    $newState = if ($Action -eq 'undo') { 'undone' } else { 'committed' }
    $manifest = Find-OperationManifest $Requested $wanted
    $records = Get-ManifestRefRecords $manifest
    $commands = [System.Collections.Generic.List[string]]::new(); $commands.Add('start')
    if ($records.Ref -contains 'HEAD') { $commands.Add('option no-deref') }
    foreach ($record in $records) {
        if ($Action -eq 'undo') { $commands.Add("update $($record.Ref) $($record.Old) $($record.New)") }
        else { $commands.Add("update $($record.Ref) $($record.New) $($record.Old)") }
    }
    $commands.Add('prepare'); $commands.Add('commit')
    $result = Invoke-GitText -ArgumentList @('update-ref','--stdin') -InputText (($commands -join "`n") + "`n") -AllowFailure
    if ($result.ExitCode -ne 0) { Throw-GitRetimeError $script:ExitTransaction "$Action failed because a ref does not have the expected value" }
    Set-ManifestState $manifest $newState
    [Console]::Out.WriteLine("$([char]::ToUpperInvariant($Action[0]))$($Action.Substring(1)) operation $(Get-ManifestValue $manifest id)")
}

function Invoke-OperationRecovery {
    $directory = Join-Path (Get-GitCommonDirectory) 'git-retime/operations'
    $found = $false
    if (Test-Path -LiteralPath $directory) {
        foreach ($file in Get-ChildItem -LiteralPath $directory -Filter '*.manifest') {
            if ((Get-ManifestValue $file.FullName state) -ne 'prepared') { continue }
            $found = $true
            $records = Get-ManifestRefRecords $file.FullName
            $commands = [System.Collections.Generic.List[string]]::new(); $commands.Add('start')
            if ($records.Ref -contains 'HEAD') { $commands.Add('option no-deref') }
            $changed = $false
            foreach ($record in $records) {
                $currentResult = Invoke-GitText -ArgumentList @('rev-parse','--verify',"$($record.Ref)^{commit}") -AllowFailure
                $current = if ($currentResult.ExitCode -eq 0) { $currentResult.Output.Trim() } else { '' }
                if ($current -eq $record.New) { $commands.Add("update $($record.Ref) $($record.Old) $($record.New)"); $changed=$true }
                elseif ($current -ne $record.Old) { Throw-GitRetimeError $script:ExitRecovery "cannot recover $($record.Ref) because it has an unrelated value" }
            }
            if ($changed) {
                $commands.Add('prepare'); $commands.Add('commit')
                $result = Invoke-GitText -ArgumentList @('update-ref','--stdin') -InputText (($commands -join "`n") + "`n") -AllowFailure
                if ($result.ExitCode -ne 0) { Throw-GitRetimeError $script:ExitRecovery "cannot roll back prepared operation $(Get-ManifestValue $file.FullName id)" }
            }
            Set-ManifestState $file.FullName rolled-back
            [Console]::Out.WriteLine("Recovered operation $(Get-ManifestValue $file.FullName id) by rollback.")
        }
    }
    if (-not $found) { [Console]::Out.WriteLine('No recovery work is required.') }
}
