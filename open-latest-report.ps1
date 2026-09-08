[CmdletBinding()]
param(
    [string]$LogDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$candidates = New-Object System.Collections.ArrayList
if (-not [string]::IsNullOrWhiteSpace($LogDir)) {
    [void]$candidates.Add($LogDir)
}
if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
    [void]$candidates.Add((Join-Path $env:ProgramData "CodexWindowsCleanup\Logs"))
}
if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
    [void]$candidates.Add((Join-Path $env:TEMP "CodexWindowsCleanup\Logs"))
}

$reports = New-Object System.Collections.ArrayList
foreach ($dir in ($candidates | Select-Object -Unique)) {
    $reportDir = Join-Path $dir "Reports"
    if (-not (Test-Path -LiteralPath $reportDir -PathType Container -ErrorAction SilentlyContinue)) {
        continue
    }

    Get-ChildItem -LiteralPath $reportDir -Filter "*.html" -File -ErrorAction SilentlyContinue |
        ForEach-Object { [void]$reports.Add($_) }
}

$latest = @($reports | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
if ($latest.Count -eq 0) {
    Write-Host "No KappaSweep HTML reports found." -ForegroundColor Yellow
    return
}

Write-Host "Opening report: $($latest[0].FullName)"
$chromeOpener = Join-Path $PSScriptRoot "open-report-in-chrome.ps1"
if (Test-Path -LiteralPath $chromeOpener -PathType Leaf) {
    & $chromeOpener -Path $latest[0].FullName
}
else {
    Start-Process -FilePath $latest[0].FullName
}
