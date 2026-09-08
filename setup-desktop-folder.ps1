[CmdletBinding()]
param(
    [string]$FolderName = "KappaSweep",
    [string]$DestinationRoot = "",
    [switch]$InstallSchedule,
    [switch]$BrowserCaches,
    [switch]$AppCaches,
    [switch]$SpotifyCache,
    [switch]$Registry,
    [switch]$ExtraPaths,
    [switch]$DeveloperCaches,
    [switch]$GameCaches,
    [switch]$RecycleBin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Merge-ConfigDefaults {
    param(
        $Existing,
        $Defaults
    )

    foreach ($defaultProperty in $Defaults.PSObject.Properties) {
        $existingProperty = $Existing.PSObject.Properties[$defaultProperty.Name]
        if ($null -eq $existingProperty) {
            $Existing | Add-Member -NotePropertyName $defaultProperty.Name -NotePropertyValue $defaultProperty.Value -Force
            continue
        }

        if ($existingProperty.Value -is [pscustomobject] -and $defaultProperty.Value -is [pscustomobject]) {
            Merge-ConfigDefaults -Existing $existingProperty.Value -Defaults $defaultProperty.Value
        }
    }
}

function Update-ConfigWithoutReset {
    param(
        [string]$DefaultConfigPath,
        [string]$ExistingConfigPath
    )

    $defaults = Get-Content -LiteralPath $DefaultConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $existing = Get-Content -LiteralPath $ExistingConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    Merge-ConfigDefaults -Existing $existing -Defaults $defaults
    [IO.File]::WriteAllText($ExistingConfigPath, ($existing | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

$sourceRoot = Split-Path -Parent $PSCommandPath
$desktop = $DestinationRoot
if ([string]::IsNullOrWhiteSpace($desktop)) {
    $desktop = [Environment]::GetFolderPath("DesktopDirectory")
    if ([string]::IsNullOrWhiteSpace($desktop)) {
        $desktop = Join-Path $env:USERPROFILE "Desktop"
    }
}

$targetRoot = Join-Path $desktop $FolderName
New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null

$exeCandidates = @(
    (Join-Path $sourceRoot "KappaSweep.exe"),
    (Join-Path $sourceRoot "dist\KappaSweep.exe")
)
$exeSource = $exeCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ($exeSource) {
    Copy-Item -LiteralPath $exeSource -Destination (Join-Path $targetRoot "KappaSweep.exe") -Force
}

$files = @(
    "cleanup-windows.ps1",
    "install-scheduled-cleanup.ps1",
    "kappasweep-menu.bat",
    "kappasweep-ui.ps1",
    "kappasweep-ui.bat",
    "kappasweep-encoding.ps1",
    "system-tweaks.ps1",
    "check-log-encoding.ps1",
    "check-log-encoding.bat",
    "kappasweep-config.json",
    "scan-results.bat",
    "cleanup-now.bat",
    "cleanup-safe-now.bat",
    "cleanup-smart-now.bat",
    "cleanup-gaming-now.bat",
    "cleanup-emergency-now.bat",
    "guard-check-now.bat",
    "cleanup-deep-now.bat",
    "cleanup-preview.bat",
    "disk-space-report.ps1",
    "disk-space-report.bat",
    "disk-analyzer-lite.bat",
    "space-hog-report.ps1",
    "space-hog-report.bat",
    "open-report-in-chrome.ps1",
    "repair-powershell-shortcut.ps1",
    "repair-powershell-shortcut.bat",
    "manage-kappasweep-settings.ps1",
    "manage-kappasweep-settings.bat",
    "system-maintenance-check.ps1",
    "system-maintenance-check.bat",
    "show-cleanup-history.ps1",
    "show-cleanup-history.bat",
    "open-latest-report.ps1",
    "open-latest-report.bat",
    "open-cleanup-logs.bat",
    "build-release.ps1",
    "build-release.bat",
    "install-scheduled-cleanup.bat",
    "uninstall-scheduled-cleanup.bat",
    "setup-desktop-folder.ps1",
    "setup-desktop-folder.bat",
    "extra-cache-paths.txt",
    "README.md",
    "CONFIG.md"
)

foreach ($file in $files) {
    $source = Join-Path $sourceRoot $file
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        continue
    }

    $destination = Join-Path $targetRoot $file
    $sourceFull = (Resolve-Path -LiteralPath $source).ProviderPath
    $destinationFull = [IO.Path]::GetFullPath($destination)

    if ($sourceFull -ieq $destinationFull) {
        continue
    }

    if ($file -eq "kappasweep-config.json" -and (Test-Path -LiteralPath $destination -PathType Leaf)) {
        try {
            Update-ConfigWithoutReset -DefaultConfigPath $source -ExistingConfigPath $destination
            Write-Host "Updated config without resetting personal settings:"
            Write-Host $destination
            continue
        }
        catch {
            Write-Warning "Could not merge existing config. Keeping it unchanged: $destination. $($_.Exception.Message)"
            continue
        }
    }

    Copy-Item -LiteralPath $source -Destination $destination -Force
}

Write-Host "Desktop folder is ready:"
Write-Host $targetRoot

if (-not $InstallSchedule) {
    Write-Host ""
    Write-Host "Schedule was not installed. Run install-scheduled-cleanup.bat from that folder when ready."
    return
}

$installer = Join-Path $targetRoot "install-scheduled-cleanup.ps1"
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "Installer was not copied to the desktop folder."
}

$scheduleArgs = @{}
if ($BrowserCaches) {
    $scheduleArgs.BrowserCaches = $true
}
if ($AppCaches) {
    $scheduleArgs.AppCaches = $true
}
elseif ($SpotifyCache) {
    $scheduleArgs.SpotifyCache = $true
}
if ($Registry) {
    $scheduleArgs.Registry = $true
}
if ($ExtraPaths) {
    $scheduleArgs.ExtraPaths = $true
}
if ($DeveloperCaches) {
    $scheduleArgs.DeveloperCaches = $true
}
if ($GameCaches) {
    $scheduleArgs.GameCaches = $true
}
if ($RecycleBin) {
    $scheduleArgs.RecycleBin = $true
}

Write-Host ""
Write-Host "Installing scheduled tasks from the desktop folder..."
& $installer @scheduleArgs
