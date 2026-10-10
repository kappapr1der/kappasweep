[CmdletBinding()]
param(
    [ValidateRange(1, 1000)]
    [int]$MaxGB = 8,
    [ValidateRange(1, 24)]
    [int]$EveryHours = 6,
    [string]$StartAt = '02:10'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$guard = Join-Path $PSScriptRoot 'spotify-cache-guard.ps1'
if (-not (Test-Path -LiteralPath $guard -PathType Leaf)) {
    throw 'spotify-cache-guard.ps1 was not found next to the installer.'
}

$linkPath = Join-Path $env:LOCALAPPDATA 'Packages\SpotifyAB.SpotifyMusic_zpdnekdrzrea0\LocalCache\Spotify\Data'
$link = Get-Item -LiteralPath $linkPath -Force -ErrorAction Stop
if ($link.LinkType -ne 'Junction' -or @($link.Target).Count -ne 1) {
    throw 'Spotify music cache must first be moved to a non-system drive via a junction.'
}
$cachePath = [string]@($link.Target)[0]
& $guard -ExpectedCachePath $cachePath -MaxGB $MaxGB -DryRun | Out-Null

try {
    $startTime = [datetime]::ParseExact($StartAt, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture).TimeOfDay
}
catch {
    throw 'StartAt must have the form HH:mm, for example 02:10.'
}

$triggers = @()
for ($offset = 0; $offset -lt 24; $offset += $EveryHours) {
    $minutes = [int](($startTime.TotalMinutes + $offset * 60) % 1440)
    $at = [datetime]::Today.AddMinutes($minutes)
    $triggers += New-ScheduledTaskTrigger -Daily -At $at -RandomDelay (New-TimeSpan -Minutes 10)
}

$taskPath = '\'
$taskName = 'KappaSweep Spotify Cache Guard'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$actionArgs = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ExpectedCachePath "{1}" -MaxGB {2}' -f $guard, $cachePath, $MaxGB
$action = New-ScheduledTaskAction -Execute $powershellPath -Argument $actionArgs
$settings = New-ScheduledTaskSettingsSet `
    -Compatibility Win8 `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -Hidden `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
$task = New-ScheduledTask -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Description 'Checks the D: Spotify streaming cache and clears it only above the configured size when Spotify is closed.'
Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -InputObject $task -Force -ErrorAction Stop | Out-Null
Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop | Out-Null

Write-Host "Registered: $taskPath$taskName"
Write-Host "Cache: $cachePath"
Write-Host "Policy: $MaxGB GB threshold; every $EveryHours hours from $StartAt; Spotify must be closed."
