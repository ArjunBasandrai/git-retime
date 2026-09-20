Set-StrictMode -Version 3.0

$script:ExitUsage = 2
$script:ExitSafety = 3
$script:ExitChronology = 4
$script:ExitObject = 5
$script:ExitTransaction = 6
$script:ExitRecovery = 7
$script:ExitInternal = 8
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Throw-GitRetimeError {
    param([int] $Code, [string] $Message)
    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data['GitRetimeExitCode'] = $Code
    throw $exception
}

function Invoke-GitText {
    param(
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [string] $InputText,
        [switch] $AllowFailure
    )
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = 'git.exe'
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = (Get-Location).ProviderPath
    $info.Environment['GIT_NO_REPLACE_OBJECTS'] = '1'
    foreach ($argument in $ArgumentList) { [void]$info.ArgumentList.Add($argument) }
    if ($PSBoundParameters.ContainsKey('InputText')) { $info.RedirectStandardInput = $true }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if ($PSBoundParameters.ContainsKey('InputText')) {
        $process.StandardInput.NewLine = "`n"
        $inputTask = $process.StandardInput.WriteAsync($InputText)
        [void]$inputTask.GetAwaiter().GetResult()
        $process.StandardInput.Close()
    }
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0 -and -not $AllowFailure) {
        $message = $stderr.Trim()
        if (-not $message) { $message = "Git command failed: git $($ArgumentList -join ' ')" }
        Throw-GitRetimeError $script:ExitObject $message
    }
    [pscustomobject]@{ Output = $stdout; Error = $stderr; ExitCode = $process.ExitCode }
}

function Get-GitLines {
    param([Parameter(Mandatory)] [string[]] $ArgumentList, [string] $InputText)
    $parameters = @{ ArgumentList = $ArgumentList }
    if ($PSBoundParameters.ContainsKey('InputText')) { $parameters.InputText = $InputText }
    $text = (Invoke-GitText @parameters).Output
    if (-not $text) { return @() }
    @($text.TrimEnd("`r", "`n") -split "`r?`n")
}

function Assert-GitRepository {
    $result = Invoke-GitText -ArgumentList @('rev-parse', '--git-dir') -AllowFailure
    if ($result.ExitCode -ne 0) { Throw-GitRetimeError $script:ExitSafety 'the current directory is not a Git repository' }
}

function Assert-GitVersion {
    $result=Invoke-GitText -ArgumentList @('--version')
    if($result.Output -notmatch 'git version (\d+)\.(\d+)'){Throw-GitRetimeError $script:ExitInternal "cannot parse Git version: $($result.Output.Trim())"}
    $major=[int]$Matches[1];$minor=[int]$Matches[2]
    if($major-lt2-or($major-eq2-and$minor-lt38)){Throw-GitRetimeError $script:ExitInternal "Git 2.38 or later is required: $($result.Output.Trim())"}
}

function Get-GitCommonDirectory {
    $path = (Invoke-GitText -ArgumentList @('rev-parse', '--git-common-dir')).Output.Trim()
    [System.IO.Path]::GetFullPath($path, (Get-Location).Path)
}

function Get-GitDirectory {
    $path = (Invoke-GitText -ArgumentList @('rev-parse', '--git-dir')).Output.Trim()
    [System.IO.Path]::GetFullPath($path, (Get-Location).Path)
}

function Get-GitObjectFormat {
    $format = (Invoke-GitText -ArgumentList @('rev-parse', '--show-object-format')).Output.Trim()
    if ($format -notin @('sha1', 'sha256')) { Throw-GitRetimeError $script:ExitObject "unsupported Git object format: $format" }
    $format
}

function Test-GitOid {
    param([string] $Format, [string] $Oid)
    $length = if ($Format -eq 'sha1') { 40 } else { 64 }
    $Oid -cmatch "^[0-9a-f]{$length}$"
}

function Get-Sha256Hex {
    param([byte[]] $Bytes)
    $hash = [System.Security.Cryptography.SHA256]::HashData($Bytes)
    [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-DeterministicSecond {
    param(
        [string] $Seed, [string] $Operation, [string] $Oid, [string] $Field,
        [long] $Low, [long] $High
    )
    if ($High -lt $Low) { Throw-GitRetimeError $script:ExitChronology "empty timestamp interval for $Oid $Field" }
    $record = "git-retime-random-v1`n$Seed`n$Operation`n$Oid`n$Field`n$Low`n$High"
    $digest = Get-Sha256Hex $script:Utf8NoBom.GetBytes($record)
    $value = [Convert]::ToInt64($digest.Substring(0, 13), 16)
    $size = $High - $Low + 1
    $Low + ($value % $size)
}

function New-GitRetimeTemporaryDirectory {
    $parent = Join-Path (Get-GitCommonDirectory) 'git-retime/tmp'
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $path = Join-Path $parent ("run.{0}" -f [Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($path) | Out-Null
    $path
}

function Write-Utf8NoBomFile {
    param([string] $Path, [string] $Text)
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Write-Utf8NoBomLines {
    param([string] $Path, [string[]] $Lines)
    $text = if ($Lines.Count) { ($Lines -join "`n") + "`n" } else { '' }
    Write-Utf8NoBomFile $Path $text
}

function Get-OperationId {
    $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $entropy = "$PID-$([Guid]::NewGuid().ToString('N'))"
    $digest = Get-Sha256Hex $script:Utf8NoBom.GetBytes($entropy)
    "$stamp-$($digest.Substring(0, 12))"
}
