[CmdletBinding()]
param(
    [int]$Top = 10,
    [string]$LogDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$encodingHelper = Join-Path $PSScriptRoot "kappasweep-encoding.ps1"
if (Test-Path -LiteralPath $encodingHelper -PathType Leaf) {
    . $encodingHelper
}

function Resolve-LogDirs {
    param([string]$Preferred)

    $dirs = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($Preferred)) {
        [void]$dirs.Add($Preferred)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        [void]$dirs.Add((Join-Path $env:ProgramData "CodexWindowsCleanup\Logs"))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        [void]$dirs.Add((Join-Path $env:TEMP "CodexWindowsCleanup\Logs"))
    }
    return @($dirs | Select-Object -Unique)
}

function Get-FirstMatch {
    param(
        [string[]]$Lines,
        [string]$Pattern
    )

    foreach ($line in $Lines) {
        if ($line -match $Pattern) {
            return $Matches[1]
        }
    }
    return ""
}

function Get-AmountFromLines {
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        if ($line -match "about (.*?), (?:blocked|failures|errors)") {
            return $Matches[1]
        }
    }
    return ""
}

$logs = New-Object System.Collections.ArrayList
foreach ($dir in (Resolve-LogDirs -Preferred $LogDir)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container -ErrorAction SilentlyContinue)) {
        continue
    }

    Get-ChildItem -LiteralPath $dir -Filter "cleanup-*.log" -File -ErrorAction SilentlyContinue |
        ForEach-Object { [void]$logs.Add($_) }
}

$logs = @($logs | Sort-Object LastWriteTime -Descending | Select-Object -First $Top)

Write-Host ""
Write-Host "== KappaSweep history ==" -ForegroundColor Green
if ($logs.Count -eq 0) {
    Write-Host "No cleanup logs found." -ForegroundColor Yellow
    return
}

$rows = foreach ($log in $logs) {
    $lines = @([IO.File]::ReadAllLines($log.FullName, [Text.UTF8Encoding]::new($false)))
    $start = @($lines | Where-Object { $_ -match "Windows cleanup started" } | Select-Object -First 1)
    $finish = @($lines | Where-Object { $_ -match "Windows cleanup finished|Analyze finished|Preview finished" } | Select-Object -Last 1)

    $profile = Get-FirstMatch -Lines $start -Pattern "Profile=([^ ]+)"
    $version = Get-FirstMatch -Lines $start -Pattern "Version=([^ ]+)"
    $mode = if ($start -match "Analyze=True") {
        "Analyze"
    }
    elseif ($start -match "DryRun=True") {
        "Preview"
    }
    else {
        "Clean"
    }
    $amount = Get-AmountFromLines -Lines $finish
    $locked = Get-FirstMatch -Lines $finish -Pattern "blocked: ([0-9]+)"
    if ([string]::IsNullOrWhiteSpace($locked)) {
        $locked = Get-FirstMatch -Lines $finish -Pattern "failures: ([0-9]+)"
    }
    $errors = Get-FirstMatch -Lines $finish -Pattern "errors: ([0-9]+)"

    [pscustomobject]@{
        Time = $log.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
        Mode = $mode
        Profile = $profile
        Amount = $amount
        Locked = $locked
        Errors = $errors
        Version = $version
        Log = $log.FullName
    }
}

$rows | Format-Table -AutoSize
