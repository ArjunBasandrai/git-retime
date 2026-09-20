function ConvertTo-FixedOffset {
    param([string] $Value)
    if (-not $Value) { $Value = 'Z' }
    if ($Value -in @('Z', 'z', 'UTC', 'utc', '+00:00', '-00:00', '+0000', '-0000')) {
        return [pscustomobject]@{ Git = '+0000'; TimeSpan = [TimeSpan]::Zero }
    }
    if ($Value -cmatch '^([+-])(\d{2}):?(\d{2})$') {
        $hours = [int]$Matches[2]
        $minutes = [int]$Matches[3]
        if ($hours -gt 23 -or $minutes -gt 59) { Throw-GitRetimeError $script:ExitUsage "invalid timezone offset: $Value" }
        $offset = [TimeSpan]::FromMinutes($hours * 60 + $minutes)
        if ($Matches[1] -eq '-') { $offset = -$offset }
        return [pscustomobject]@{ Git = "$($Matches[1])$($Matches[2])$($Matches[3])"; TimeSpan = $offset }
    }
    Throw-GitRetimeError $script:ExitUsage "timezone must be Z or a fixed offset: $Value"
}

function ConvertTo-DateInterval {
    param([string] $InputValue, [string] $DefaultZone = 'Z')
    $datePart = $InputValue
    $explicitZone = $null
    if ($InputValue -cmatch '^(.*)(Z|z)$') {
        $datePart = $Matches[1]; $explicitZone = 'Z'
    } elseif ($InputValue -cmatch '^(.*)([+-]\d{2}:\d{2})$') {
        $datePart = $Matches[1]; $explicitZone = $Matches[2]
    }
    $zone = ConvertTo-FixedOffset $(if ($explicitZone) { $explicitZone } else { $DefaultZone })
    $culture = [Globalization.CultureInfo]::InvariantCulture
    try {
        if ($datePart -cmatch '^(\d{4})$') {
            $start = [DateTimeOffset]::new([int]$Matches[1], 1, 1, 0, 0, 0, $zone.TimeSpan)
            $next = $start.AddYears(1)
        } elseif ($datePart -cmatch '^(\d{4})-(\d{2})$') {
            $start = [DateTimeOffset]::new([int]$Matches[1], [int]$Matches[2], 1, 0, 0, 0, $zone.TimeSpan)
            $next = $start.AddMonths(1)
        } elseif ($datePart -cmatch '^(\d{4})-(\d{2})-(\d{2})$') {
            $start = [DateTimeOffset]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], 0, 0, 0, $zone.TimeSpan)
            $next = $start.AddDays(1)
        } elseif ($datePart -cmatch '^(\d{4})-(\d{2})-(\d{2})T(\d{2})$') {
            $start = [DateTimeOffset]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4], 0, 0, $zone.TimeSpan)
            $next = $start.AddHours(1)
        } elseif ($datePart -cmatch '^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$') {
            $start = [DateTimeOffset]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4], [int]$Matches[5], 0, $zone.TimeSpan)
            $next = $start.AddMinutes(1)
        } elseif ($datePart -cmatch '^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})$') {
            $start = [DateTimeOffset]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4], [int]$Matches[5], [int]$Matches[6], $zone.TimeSpan)
            $next = $start
        } else {
            Throw-GitRetimeError $script:ExitUsage "date is not a supported ISO value: $InputValue"
        }
    } catch {
        if ($_.Exception.Data.Contains('GitRetimeExitCode')) { throw }
        Throw-GitRetimeError $script:ExitUsage "invalid date: $InputValue"
    }
    $low = $start.ToUnixTimeSeconds()
    $high = if ($next -eq $start) { $low } else { $next.ToUnixTimeSeconds() - 1 }
    [pscustomobject]@{ Low = $low; High = $high; Offset = $zone.Git }
}

function ConvertTo-DurationSeconds {
    param([string] $InputValue)
    if (-not $InputValue) { Throw-GitRetimeError $script:ExitUsage 'duration cannot be empty' }
    $sign = 1L
    $rest = $InputValue
    if ($rest.StartsWith('-')) { $sign = -1L; $rest = $rest.Substring(1) }
    elseif ($rest.StartsWith('+')) { $rest = $rest.Substring(1) }
    if (-not $rest) { Throw-GitRetimeError $script:ExitUsage "invalid duration: $InputValue" }
    $total = 0L
    while ($rest) {
        if ($rest -notmatch '^(\d+)([wdhms])(.*)$') { Throw-GitRetimeError $script:ExitUsage "invalid duration: $InputValue" }
        $number = [long]$Matches[1]
        $factor = switch ($Matches[2]) { w { 604800 } d { 86400 } h { 3600 } m { 60 } s { 1 } }
        $total += $number * $factor
        $rest = $Matches[3]
    }
    $sign * $total
}

function Format-GitTimestampIso {
    param([long] $Epoch, [string] $Offset)
    $zone = ConvertTo-FixedOffset $Offset
    [DateTimeOffset]::FromUnixTimeSeconds($Epoch).ToOffset($zone.TimeSpan).ToString('yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture) -replace '\+00:00$', 'Z'
}
