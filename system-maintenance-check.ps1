[CmdletBinding()]
param(
    [switch]$AnalyzeComponentStore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$encodingHelper = Join-Path $PSScriptRoot "kappasweep-encoding.ps1"
if (Test-Path -LiteralPath $encodingHelper -PathType Leaf) {
    . $encodingHelper
}

function Format-ByteSize {
    param([int64]$Bytes)

    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-FileSizeOrZero {
    param([string]$Path)

    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop) {
            return [int64](Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        }
    }
    catch {
        return [int64]0
    }

    return [int64]0
}

function Get-ShadowStorageInfo {
    $vssadmin = Join-Path $env:SystemRoot "System32\vssadmin.exe"
    if (-not (Test-Path -LiteralPath $vssadmin -PathType Leaf -ErrorAction SilentlyContinue)) {
        return @("Shadow storage tool was not found.")
    }

    try {
        $lines = @(& $vssadmin "List" "ShadowStorage" 2>&1)
        if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) {
            return @("Shadow storage data is unavailable. Run as administrator for more detail.")
        }
        return @($lines | Where-Object { $_ -match "Used Shadow Copy Storage|Allocated Shadow Copy Storage|Maximum Shadow Copy Storage|For volume" })
    }
    catch {
        return @("Shadow storage data is unavailable: $($_.Exception.Message)")
    }
}

Write-Host ""
Write-Host "== KappaSweep system maintenance check ==" -ForegroundColor Green
Write-Host "This screen only inspects storage. It does not disable hibernation, remove restore points, or clean Windows components." -ForegroundColor DarkGray

$systemDrive = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) { "C:" } else { $env:SystemDrive }
$hiberFile = Join-Path "$systemDrive\" "hiberfil.sys"
$hiberBytes = Get-FileSizeOrZero -Path $hiberFile
if ($hiberBytes -gt 0) {
    Write-Host ("Hibernation file: {0}" -f (Format-ByteSize -Bytes $hiberBytes))
    Write-Host "  This enables hibernation and Fast Startup. Change it only if you understand the trade-off." -ForegroundColor DarkGray
}
else {
    Write-Host "Hibernation file: not present"
}

Write-Host ""
Write-Host "System Restore / shadow storage:" -ForegroundColor Green
foreach ($line in (Get-ShadowStorageInfo)) {
    Write-Host "  $line"
}

try {
    $restorePoints = @(Get-ComputerRestorePoint -ErrorAction Stop)
    Write-Host ("Restore points visible to this session: {0}" -f $restorePoints.Count)
}
catch {
    Write-Host "Restore point count: unavailable in this session." -ForegroundColor DarkGray
}

if ($AnalyzeComponentStore) {
    $dism = Join-Path $env:SystemRoot "System32\Dism.exe"
    Write-Host ""
    Write-Host "Analyzing Windows component store. This can take a few minutes..." -ForegroundColor Green
    if (Test-Path -LiteralPath $dism -PathType Leaf -ErrorAction SilentlyContinue) {
        & $dism /Online /Cleanup-Image /AnalyzeComponentStore
    }
    else {
        Write-Warning "DISM was not found."
    }
}
else {
    Write-Host ""
    Write-Host "For a read-only component-store analysis, run:" -ForegroundColor DarkGray
    Write-Host ".\system-maintenance-check.ps1 -AnalyzeComponentStore" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "No maintenance action was applied." -ForegroundColor Green
