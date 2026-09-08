[CmdletBinding()]
param(
    [switch]$AllFixedDrives,
    [string[]]$Drives = @(),
    [int]$Top = 12,
    [switch]$SkipFolderScan,
    [string]$LogDir = "",
    [switch]$SkipHistory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$encodingHelper = Join-Path $PSScriptRoot "kappasweep-encoding.ps1"
if (Test-Path -LiteralPath $encodingHelper -PathType Leaf) {
    . $encodingHelper
}

function Format-ByteSize {
    param([int64]$Bytes)

    if ($Bytes -ge 1TB) {
        return "{0:N2} TB" -f ($Bytes / 1TB)
    }
    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }
    if ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    }
    if ($Bytes -ge 1KB) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    }
    return "$Bytes bytes"
}

function Get-FixedDrives {
    $cimDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue |
        Where-Object { $_.Size -gt 0 } |
        Sort-Object DeviceID)

    if ($cimDisks.Count -gt 0) {
        return $cimDisks
    }

    $psDriveDisks = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Root -match '^[A-Za-z]:\\$' -and (($_.Free + $_.Used) -gt 0) } |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                DeviceID = "$($_.Name):"
                FreeSpace = [int64]$_.Free
                Size = [int64]($_.Free + $_.Used)
            }
        })

    if ($psDriveDisks.Count -gt 0) {
        return $psDriveDisks
    }

    $driveInfoDisks = @([System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady -and $_.TotalSize -gt 0 } |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                DeviceID = $_.Name.TrimEnd("\")
                FreeSpace = [int64]$_.AvailableFreeSpace
                Size = [int64]$_.TotalSize
            }
        })

    return $driveInfoDisks
}

function Resolve-HistoryFile {
    param([string]$PreferredLogDir)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($PreferredLogDir)) {
        $candidates += $PreferredLogDir
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $candidates += (Join-Path $env:ProgramData "CodexWindowsCleanup\Logs")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        $candidates += (Join-Path $env:TEMP "CodexWindowsCleanup\Logs")
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        try {
            New-Item -ItemType Directory -Path $candidate -Force -ErrorAction Stop | Out-Null
            return (Join-Path $candidate "space-history.jsonl")
        }
        catch {
            continue
        }
    }

    return ""
}

function Get-LatestSpaceSnapshot {
    param([string]$HistoryFile)

    if ([string]::IsNullOrWhiteSpace($HistoryFile) -or -not (Test-Path -LiteralPath $HistoryFile -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $lastLine = Get-Content -LiteralPath $HistoryFile -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Last 1
        if (-not [string]::IsNullOrWhiteSpace($lastLine)) {
            return ($lastLine | ConvertFrom-Json -ErrorAction Stop)
        }
    }
    catch {
        Write-Warning "Could not read previous disk snapshot. $($_.Exception.Message)"
    }

    return $null
}

function New-SpaceSnapshot {
    param($Disks)

    return [pscustomobject]@{
        TimeUtc = (Get-Date).ToUniversalTime().ToString("o")
        Drives  = @($Disks | ForEach-Object {
            [pscustomobject]@{
                Drive = $_.DeviceID
                FreeBytes = [int64]$_.FreeSpace
                TotalBytes = [int64]$_.Size
            }
        })
    }
}

function Save-SpaceSnapshot {
    param(
        [string]$HistoryFile,
        $Snapshot
    )

    if ([string]::IsNullOrWhiteSpace($HistoryFile)) {
        return
    }

    try {
        $json = $Snapshot | ConvertTo-Json -Depth 5 -Compress
        [IO.File]::AppendAllText($HistoryFile, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

        $lines = @(Get-Content -LiteralPath $HistoryFile -ErrorAction Stop)
        if ($lines.Count -gt 180) {
            [IO.File]::WriteAllLines($HistoryFile, @($lines | Select-Object -Last 180), [Text.UTF8Encoding]::new($false))
        }
    }
    catch {
        Write-Warning "Could not save disk snapshot. $($_.Exception.Message)"
    }
}

function Get-PreviousDriveSnapshot {
    param(
        $Snapshot,
        [string]$Drive
    )

    if ($null -eq $Snapshot) {
        return $null
    }

    foreach ($item in @($Snapshot.Drives)) {
        if ($item.Drive -eq $Drive) {
            return $item
        }
    }

    return $null
}

function Format-UsedSpaceChange {
    param(
        $Disk,
        $PreviousSnapshot
    )

    $previous = Get-PreviousDriveSnapshot -Snapshot $PreviousSnapshot -Drive $Disk.DeviceID
    if ($null -eq $previous) {
        return "first snapshot"
    }

    $freeChange = [int64]$Disk.FreeSpace - [int64]$previous.FreeBytes
    if ($freeChange -eq 0) {
        return "no change"
    }

    if ($freeChange -lt 0) {
        return ("used +{0}" -f (Format-ByteSize -Bytes ([Math]::Abs($freeChange))))
    }

    return ("freed {0}" -f (Format-ByteSize -Bytes $freeChange))
}

function Measure-DirectoryBytes {
    param([string]$Path)

    $total = [int64]0
    try {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
            ForEach-Object { $total += [int64]$_.Length }
    }
    catch {
        return $total
    }

    return $total
}

function Show-DriveOverview {
    param($Disk, $PreviousSnapshot)

    $free = [int64]$Disk.FreeSpace
    $size = [int64]$Disk.Size
    $used = $size - $free
    $freePercent = [Math]::Round(($free / $size) * 100, 1)

    [pscustomobject]@{
        Drive = $Disk.DeviceID
        Used = (Format-ByteSize -Bytes $used)
        Free = (Format-ByteSize -Bytes $free)
        Total = (Format-ByteSize -Bytes $size)
        FreePercent = "$freePercent%"
        ChangeSinceLast = (Format-UsedSpaceChange -Disk $Disk -PreviousSnapshot $PreviousSnapshot)
    }
}

function Show-TopFolders {
    param(
        [string]$Root,
        [int]$Count
    )

    Write-Host ""
    Write-Host ("== Biggest folders on {0} ==" -f $Root) -ForegroundColor Green
    Write-Host "Scanning can take a while. Access-denied folders are skipped." -ForegroundColor DarkGray

    $rows = New-Object System.Collections.ArrayList
    try {
        $children = Get-ChildItem -LiteralPath $Root -Force -Directory -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Could not list $Root. $($_.Exception.Message)"
        return
    }

    foreach ($child in $children) {
        Write-Host ("Scanning {0}" -f $child.FullName) -ForegroundColor DarkGray
        $bytes = Measure-DirectoryBytes -Path $child.FullName
        [void]$rows.Add([pscustomobject]@{
            SizeBytes = $bytes
            Size = (Format-ByteSize -Bytes $bytes)
            Path = $child.FullName
        })
    }

    $rows |
        Sort-Object SizeBytes -Descending |
        Select-Object -First $Count Size, Path |
        Format-Table -AutoSize
}

function Show-UserHotspots {
    param([int]$Count)

    $paths = @(
        (Join-Path $env:USERPROFILE "Downloads"),
        (Join-Path $env:USERPROFILE "Desktop"),
        (Join-Path $env:USERPROFILE "Documents"),
        (Join-Path $env:LOCALAPPDATA "Temp"),
        (Join-Path $env:LOCALAPPDATA "Packages"),
        (Join-Path $env:LOCALAPPDATA "Microsoft"),
        (Join-Path $env:APPDATA "Microsoft"),
        (Join-Path $env:APPDATA "Telegram Desktop"),
        (Join-Path $env:LOCALAPPDATA "Spotify"),
        (Join-Path $env:APPDATA "Spotify")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    Write-Host ""
    Write-Host "== User hotspots ==" -ForegroundColor Green
    $rows = New-Object System.Collections.ArrayList
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Container -ErrorAction SilentlyContinue)) {
            continue
        }

        Write-Host ("Scanning {0}" -f $path) -ForegroundColor DarkGray
        $bytes = Measure-DirectoryBytes -Path $path
        [void]$rows.Add([pscustomobject]@{
            SizeBytes = $bytes
            Size = (Format-ByteSize -Bytes $bytes)
            Path = $path
        })
    }

    $rows |
        Sort-Object SizeBytes -Descending |
        Select-Object -First $Count Size, Path |
        Format-Table -AutoSize
}

if ($AllFixedDrives -or $Drives.Count -eq 0) {
    $disks = @(Get-FixedDrives)
}
else {
    $wanted = $Drives | ForEach-Object {
        $drive = $_.TrimEnd("\")
        if ($drive.Length -eq 1) { "$drive`:" } else { $drive }
    }
    $disks = @(Get-FixedDrives | Where-Object { $wanted -contains $_.DeviceID })
}

Write-Host ""
Write-Host "== Drive overview ==" -ForegroundColor Green
$historyFile = if ($SkipHistory) { "" } else { Resolve-HistoryFile -PreferredLogDir $LogDir }
$previousSnapshot = if ([string]::IsNullOrWhiteSpace($historyFile)) { $null } else { Get-LatestSpaceSnapshot -HistoryFile $historyFile }
$currentSnapshot = New-SpaceSnapshot -Disks $disks
if (-not $SkipHistory) {
    Save-SpaceSnapshot -HistoryFile $historyFile -Snapshot $currentSnapshot
}
$disks | ForEach-Object { Show-DriveOverview -Disk $_ -PreviousSnapshot $previousSnapshot } | Format-Table -AutoSize

if ($SkipHistory) {
    Write-Host "Disk history recording is disabled for this run." -ForegroundColor DarkGray
}
elseif ($previousSnapshot) {
    Write-Host "Comparison uses the previous KappaSweep disk report." -ForegroundColor DarkGray
}
else {
    Write-Host "First disk snapshot saved. Run this report again later to see changes." -ForegroundColor DarkGray
}

if ($SkipFolderScan) {
    return
}

foreach ($disk in $disks) {
    Show-TopFolders -Root ("{0}\" -f $disk.DeviceID) -Count $Top
}

Show-UserHotspots -Count $Top
