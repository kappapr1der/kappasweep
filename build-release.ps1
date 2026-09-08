[CmdletBinding()]
param(
    [string]$Version = "",
    [switch]$Portable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSCommandPath
$cleanupScript = Join-Path $root "cleanup-windows.ps1"
if ([string]::IsNullOrWhiteSpace($Version)) {
    $text = Get-Content -LiteralPath $cleanupScript -Raw -Encoding UTF8
    if ($text -match 'KappaSweepVersion\s*=\s*"([^"]+)"') {
        $Version = $Matches[1]
    }
    else {
        $Version = "dev"
    }
}

$dist = Join-Path $root "dist"
$stageRoot = Join-Path $root ".release-stage"
$stageName = if ($Portable) { "KappaSweep-Portable-v$Version" } else { "KappaSweep-v$Version" }
$stage = Join-Path $stageRoot $stageName

New-Item -ItemType Directory -Path $dist -Force | Out-Null
if (Test-Path -LiteralPath $stageRoot) {
    $stageRootFull = [IO.Path]::GetFullPath($stageRoot)
    $rootFull = [IO.Path]::GetFullPath($root)
    if (-not $stageRootFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clear stage outside KappaSweep root: $stageRootFull"
    }
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $stage -Force | Out-Null

$files = @(
    "cleanup-windows.ps1",
    "kappasweep-config.json",
    "kappasweep-menu.bat",
    "kappasweep-ui.ps1",
    "kappasweep-ui.bat",
    "kappasweep-encoding.ps1",
    "system-tweaks.ps1",
    "check-log-encoding.ps1",
    "check-log-encoding.bat",
    "scan-results.bat",
    "cleanup-safe-now.bat",
    "cleanup-gaming-now.bat",
    "cleanup-smart-now.bat",
    "cleanup-preview.bat",
    "cleanup-now.bat",
    "cleanup-deep-now.bat",
    "cleanup-emergency-now.bat",
    "guard-check-now.bat",
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
    "publish-release.ps1",
    "publish-release.bat",
    "save-github-token.ps1",
    "save-github-token.bat",
    "install-scheduled-cleanup.ps1",
    "install-scheduled-cleanup.bat",
    "uninstall-scheduled-cleanup.bat",
    "setup-desktop-folder.ps1",
    "setup-desktop-folder.bat",
    "extra-cache-paths.txt",
    "kappasweep-icon.png",
    "README.md",
    "CONFIG.md",
    "RELEASES.md",
    "release-highlights.md",
    "build-kappasweep-exe.ps1"
)

foreach ($file in $files) {
    $source = Join-Path $root $file
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $stage $file) -Force
    }
}

$exeBuilder = Join-Path $root "build-kappasweep-exe.ps1"
$exeName = if ($Portable) { "KappaSweep-Portable.exe" } else { "KappaSweep.exe" }
$exePath = Join-Path $stage $exeName
$distExePath = Join-Path $dist $exeName
& $exeBuilder -PayloadRoot $stage -OutputPath $exePath -Portable:$Portable
Copy-Item -LiteralPath $exePath -Destination $distExePath -Force

$zipName = if ($Portable) { "KappaSweep-Portable-v$Version.zip" } else { "KappaSweep-v$Version.zip" }
$zipPath = Join-Path $dist $zipName
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

$publicStage = Join-Path $stageRoot "public"
New-Item -ItemType Directory -Path $publicStage -Force | Out-Null
Copy-Item -LiteralPath $exePath -Destination (Join-Path $publicStage "KappaSweep.exe") -Force
foreach ($publicFile in @("README.md", "CONFIG.md")) {
    Copy-Item -LiteralPath (Join-Path $stage $publicFile) -Destination (Join-Path $publicStage $publicFile) -Force
}

Compress-Archive -Path (Join-Path $publicStage "*") -DestinationPath $zipPath -Force
Remove-Item -LiteralPath $stageRoot -Recurse -Force

Write-Host "Release zip created:"
Write-Host $zipPath
