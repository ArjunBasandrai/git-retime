#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [int] $Count = 10000,
    [int] $Seed = 104729
)

$ErrorActionPreference='Stop'
$Path=[IO.Path]::GetFullPath($Path)
&git.exe init -q -b main $Path
if($LASTEXITCODE){throw 'git init failed'}
&git.exe -C $Path config user.name 'Stress Fixture'
&git.exe -C $Path config user.email 'stress@example.com'
&git.exe -C $Path config git-retime.fixtureKind linear
&git.exe -C $Path config git-retime.fixtureSeed $Seed
$builder=[Text.StringBuilder]::new()
for($index=1;$index-le$Count;$index++){
    $epoch=1500000000+$index*2;$message="linear $index seed $Seed"
    [void]$builder.Append("commit refs/heads/main`nmark :$index`nauthor Stress Fixture <stress@example.com> $epoch +0000`ncommitter Stress Fixture <stress@example.com> $epoch +0000`ndata $($message.Length)`n$message`n")
    if($index-gt1){[void]$builder.Append("from :$($index-1)`n")}
    [void]$builder.Append("`n")
}
$info=[Diagnostics.ProcessStartInfo]::new('git.exe');$info.WorkingDirectory=$Path;$info.UseShellExecute=$false;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
foreach($argument in @('fast-import','--quiet')){[void]$info.ArgumentList.Add($argument)}
$process=[Diagnostics.Process]::Start($info);$outputTask=$process.StandardOutput.ReadToEndAsync();$errorTask=$process.StandardError.ReadToEndAsync();$inputTask=$process.StandardInput.WriteAsync($builder.ToString());[void]$inputTask.GetAwaiter().GetResult();$process.StandardInput.Close();$process.WaitForExit();$errorText=$errorTask.GetAwaiter().GetResult();[void]$outputTask.GetAwaiter().GetResult()
if($process.ExitCode){throw $errorText}
&git.exe -C $Path checkout -q main
if($LASTEXITCODE){throw 'git checkout failed'}
[Console]::Out.WriteLine("linear`t$Seed`t$Count")
