[CmdletBinding()]
param(
    [string]$GuardStart = "00:15",
    [int]$GuardEveryHours = 3,
    [int]$LowFreeGB = 35,
    [int]$LowFreePercent = 18,
    [string]$DeepWeekly = "03:20",
    [ValidateSet("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")]
    [string]$DeepDay = "Sunday",
    [switch]$BrowserCaches,
    [switch]$AppCaches,
    [switch]$SpotifyCache,
    [switch]$DiscordCache,
    [switch]$TelegramCache,
    [switch]$SlackCache,
    [switch]$TeamsCache,
    [switch]$ZoomCache,
    [switch]$Registry,
    [switch]$ExtraPaths,
    [switch]$DeveloperCaches,
    [switch]$GameCaches,
    [switch]$RecycleBin,
    [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$encodingHelper = Join-Path $PSScriptRoot "kappasweep-encoding.ps1"
if (Test-Path -LiteralPath $encodingHelper -PathType Leaf) {
    . $encodingHelper
}

$script:CliParameters = @{}
foreach ($key in $PSBoundParameters.Keys) {
    $script:CliParameters[$key] = $true
}

function Get-ConfigProperty {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Resolve-KappaSweepPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([IO.Path]::IsPathRooted($expanded)) {
        return $expanded
    }

    return (Join-Path $PSScriptRoot $expanded)
}

function Set-StringFromConfig {
    param(
        [string]$Name,
        $Value
    )

    if ($null -eq $Value -or $script:CliParameters.ContainsKey($Name)) {
        return
    }

    Set-Variable -Name $Name -Value ([string]$Value) -Scope Script
}

function Set-IntFromConfig {
    param(
        [string]$Name,
        $Value
    )

    if ($null -eq $Value -or $script:CliParameters.ContainsKey($Name)) {
        return
    }

    Set-Variable -Name $Name -Value ([int]$Value) -Scope Script
}

function Set-SwitchFromConfig {
    param(
        [string]$Name,
        $Value
    )

    if ($null -eq $Value -or $script:CliParameters.ContainsKey($Name)) {
        return
    }

    Set-Variable -Name $Name -Value ([bool]$Value) -Scope Script
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $defaultConfigPath = Join-Path $PSScriptRoot "kappasweep-config.json"
    if (Test-Path -LiteralPath $defaultConfigPath -PathType Leaf -ErrorAction SilentlyContinue) {
        $ConfigPath = $defaultConfigPath
    }
}
else {
    $ConfigPath = Resolve-KappaSweepPath -Path $ConfigPath
}

if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf -ErrorAction SilentlyContinue)) {
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

    $schedule = Get-ConfigProperty -Object $config -Name "schedule"
    Set-StringFromConfig -Name "GuardStart" -Value (Get-ConfigProperty -Object $schedule -Name "guardStart")
    Set-IntFromConfig -Name "GuardEveryHours" -Value (Get-ConfigProperty -Object $schedule -Name "guardEveryHours")
    Set-StringFromConfig -Name "DeepWeekly" -Value (Get-ConfigProperty -Object $schedule -Name "deepWeekly")
    Set-StringFromConfig -Name "DeepDay" -Value (Get-ConfigProperty -Object $schedule -Name "deepDay")

    $thresholds = Get-ConfigProperty -Object $config -Name "thresholds"
    Set-IntFromConfig -Name "LowFreeGB" -Value (Get-ConfigProperty -Object $thresholds -Name "minFreeGB")
    Set-IntFromConfig -Name "LowFreePercent" -Value (Get-ConfigProperty -Object $thresholds -Name "minFreePercent")

    $features = Get-ConfigProperty -Object $config -Name "features"
    Set-SwitchFromConfig -Name "BrowserCaches" -Value (Get-ConfigProperty -Object $features -Name "browserCaches")
    Set-SwitchFromConfig -Name "AppCaches" -Value (Get-ConfigProperty -Object $features -Name "appCaches")
    Set-SwitchFromConfig -Name "SpotifyCache" -Value (Get-ConfigProperty -Object $features -Name "spotifyCache")
    Set-SwitchFromConfig -Name "DiscordCache" -Value (Get-ConfigProperty -Object $features -Name "discordCache")
    Set-SwitchFromConfig -Name "TelegramCache" -Value (Get-ConfigProperty -Object $features -Name "telegramCache")
    Set-SwitchFromConfig -Name "SlackCache" -Value (Get-ConfigProperty -Object $features -Name "slackCache")
    Set-SwitchFromConfig -Name "TeamsCache" -Value (Get-ConfigProperty -Object $features -Name "teamsCache")
    Set-SwitchFromConfig -Name "ZoomCache" -Value (Get-ConfigProperty -Object $features -Name "zoomCache")
    Set-SwitchFromConfig -Name "Registry" -Value (Get-ConfigProperty -Object $features -Name "registry")
    Set-SwitchFromConfig -Name "ExtraPaths" -Value (Get-ConfigProperty -Object $features -Name "extraPaths")
    Set-SwitchFromConfig -Name "DeveloperCaches" -Value (Get-ConfigProperty -Object $features -Name "developerCaches")
    Set-SwitchFromConfig -Name "GameCaches" -Value (Get-ConfigProperty -Object $features -Name "gameCaches")
    Set-SwitchFromConfig -Name "RecycleBin" -Value (Get-ConfigProperty -Object $features -Name "clearRecycleBin")

    $paths = Get-ConfigProperty -Object $config -Name "paths"
    $guardDrive = [string](Get-ConfigProperty -Object $paths -Name "guardDrive")
    $perDrive = Get-ConfigProperty -Object $thresholds -Name "perDrive"
    if ($null -ne $perDrive -and -not [string]::IsNullOrWhiteSpace($guardDrive)) {
        $driveThreshold = Get-ConfigProperty -Object $perDrive -Name $guardDrive.TrimEnd("\\").ToUpperInvariant()
        if ($null -ne $driveThreshold) {
            Set-IntFromConfig -Name "LowFreeGB" -Value (Get-ConfigProperty -Object $driveThreshold -Name "minFreeGB")
            Set-IntFromConfig -Name "LowFreePercent" -Value (Get-ConfigProperty -Object $driveThreshold -Name "minFreePercent")
        }
    }

    Write-Host "Using config: $ConfigPath"
}

$scriptPath = Join-Path $PSScriptRoot "cleanup-windows.ps1"
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "cleanup-windows.ps1 was not found next to this installer."
}

$taskPath = "\Codex Windows Cleanup\"
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$powershellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest

try {
    Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
}
catch {
    Write-Warning "Could not clear old tasks under $taskPath. $($_.Exception.Message)"
}

function Register-CleanupTask {
    param(
        [string]$Name,
        [Microsoft.Management.Infrastructure.CimInstance[]]$Trigger,
        [string]$CleanupArgs,
        [string]$Description,
        [TimeSpan]$ExecutionTimeLimit
    )

    $configArg = ""
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $configArg = " -ConfigPath `"$ConfigPath`""
    }
    $actionArgs = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" $CleanupArgs$configArg"
    $action = New-ScheduledTaskAction -Execute $powershellPath -Argument $actionArgs
    $settings = New-ScheduledTaskSettingsSet `
        -Compatibility Win8 `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew `
        -Hidden `
        -ExecutionTimeLimit $ExecutionTimeLimit
    $task = New-ScheduledTask -Action $action -Trigger $Trigger -Settings $settings -Principal $principal -Description $Description
    Register-ScheduledTask -TaskPath $taskPath -TaskName $Name -InputObject $task -Force | Out-Null
    Write-Host "Registered: $taskPath$Name"
}

function New-DailyGuardTriggers {
    param(
        [string]$StartAt,
        [int]$EveryHours
    )

    if ($EveryHours -lt 1) {
        $EveryHours = 1
    }
    if ($EveryHours -gt 24) {
        $EveryHours = 24
    }

    try {
        $startTime = ([datetime]::Parse($StartAt)).TimeOfDay
    }
    catch {
        throw "GuardStart must look like HH:mm, for example 00:15."
    }

    $triggers = @()
    for ($hourOffset = 0; $hourOffset -lt 24; $hourOffset += $EveryHours) {
        $minutes = [int](($startTime.TotalMinutes + ($hourOffset * 60)) % 1440)
        $at = ([datetime]::Today.AddMinutes($minutes)).ToString("HH:mm")
        $triggers += New-ScheduledTaskTrigger -Daily -At $at -RandomDelay (New-TimeSpan -Minutes 15)
    }

    return $triggers
}

$optionalArgs = ""
if ($BrowserCaches) {
    $optionalArgs += " -CleanBrowserCaches"
}
if ($AppCaches) {
    $optionalArgs += " -CleanAppCaches"
}
elseif ($SpotifyCache) {
    $optionalArgs += " -CleanSpotifyCache"
}
if ($DiscordCache) {
    $optionalArgs += " -CleanDiscordCache"
}
if ($TelegramCache) {
    $optionalArgs += " -CleanTelegramCache"
}
if ($SlackCache) {
    $optionalArgs += " -CleanSlackCache"
}
if ($TeamsCache) {
    $optionalArgs += " -CleanTeamsCache"
}
if ($ZoomCache) {
    $optionalArgs += " -CleanZoomCache"
}
if ($Registry) {
    $optionalArgs += " -CleanRegistry"
}
if ($ExtraPaths) {
    $optionalArgs += " -CleanExtraPaths"
}
if ($DeveloperCaches) {
    $optionalArgs += " -CleanDeveloperCaches"
}
if ($GameCaches) {
    $optionalArgs += " -CleanGameCaches"
}
if ($RecycleBin) {
    $optionalArgs += " -ClearRecycleBin"
}

$guardTriggers = New-DailyGuardTriggers -StartAt $GuardStart -EveryHours $GuardEveryHours
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -RandomDelay (New-TimeSpan -Minutes 5)
$deepTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DeepDay -At $DeepWeekly -RandomDelay (New-TimeSpan -Minutes 40)

Register-CleanupTask `
    -Name "Pressure Guard" `
    -Trigger $guardTriggers `
    -CleanupArgs "-SmartGuard -ScheduledGuard -AggressiveSafe -MinFreeGB $LowFreeGB -MinFreePercent $LowFreePercent -TempOlderThanDays 0 -CacheOlderThanDays 0$optionalArgs" `
    -Description "Checks disk pressure every few hours and cleans safe caches only when free space is low." `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

Register-CleanupTask `
    -Name "Startup Guard" `
    -Trigger $logonTrigger `
    -CleanupArgs "-SmartGuard -ScheduledGuard -AggressiveSafe -MinFreeGB $LowFreeGB -MinFreePercent $LowFreePercent -TempOlderThanDays 0 -CacheOlderThanDays 0$optionalArgs" `
    -Description "Checks disk pressure shortly after logon and cleans safe caches only when free space is low." `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

Register-CleanupTask `
    -Name "Deep Weekly" `
    -Trigger $deepTrigger `
    -CleanupArgs "-Deep -AggressiveSafe -TempOlderThanDays 1 -CacheOlderThanDays 0$optionalArgs" `
    -Description "Weekly deeper cleanup including Windows component cleanup." `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 45)

Write-Host ""
Write-Host "Done. Tasks run as: $currentUser"
Write-Host "Task Scheduler path: $taskPath"
Write-Host "Pressure guard: every $GuardEveryHours hour(s), starting around $GuardStart, only below $LowFreeGB GB or $LowFreePercent% free."
Write-Host "Deep cleanup: $DeepDay around $DeepWeekly."
Write-Host "Logs: $env:ProgramData\CodexWindowsCleanup\Logs"
