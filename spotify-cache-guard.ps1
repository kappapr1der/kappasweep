[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExpectedCachePath,
    [ValidateRange(0.01, 1000)]
    [double]$MaxGB = 8,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-SafeSpotifyPath {
    param([string]$Path)

    if ($Path -notmatch '^[A-Za-z]:\\' -or [IO.Path]::GetFileName($Path.TrimEnd('\')) -ine 'Data') {
        throw "ExpectedCachePath must be an absolute local Data directory."
    }

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $systemDrive = [IO.Path]::GetPathRoot($env:SystemRoot).TrimEnd('\')
    if ([IO.Path]::GetPathRoot($full).TrimEnd('\') -ieq $systemDrive) {
        throw 'The Spotify cache target must be on a non-system drive.'
    }

    $linkPath = Join-Path $env:LOCALAPPDATA 'Packages\SpotifyAB.SpotifyMusic_zpdnekdrzrea0\LocalCache\Spotify\Data'
    $link = Get-Item -LiteralPath $linkPath -Force -ErrorAction Stop
    if ($link.LinkType -ne 'Junction' -or @($link.Target).Count -ne 1) {
        throw 'The expected Spotify Store cache junction was not found.'
    }
    $linkTarget = [IO.Path]::GetFullPath([string]@($link.Target)[0]).TrimEnd('\')
    if ($linkTarget -ine $full) {
        throw "Spotify junction points to '$linkTarget', not '$full'."
    }

    $current = $full
    while ($current -and $current -ne [IO.Path]::GetPathRoot($current)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Unsafe cache path component: $current"
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    return $full
}

function Test-SpotifyRunning {
    return ($null -ne (Get-Process -Name Spotify,SpotifyWebHelper -ErrorAction SilentlyContinue | Select-Object -First 1))
}

function Write-GuardResult {
    param([string]$Message)

    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    if (-not $DryRun) {
        $logDir = Join-Path $env:ProgramData 'CodexWindowsCleanup\Logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        Add-Content -LiteralPath (Join-Path $logDir 'spotify-cache-guard.log') -Value $line -Encoding UTF8
    }
}

trap {
    $message = $_.Exception.Message
    try { Write-GuardResult "Error: $message" } catch { Write-Output "Error: $message" }
    exit 1
}

$cachePath = Assert-SafeSpotifyPath -Path $ExpectedCachePath
if (Test-SpotifyRunning) {
    Write-GuardResult 'Skipped: Spotify is running.'
    return
}

$files = New-Object 'System.Collections.Generic.List[string]'
$dirs = New-Object 'System.Collections.Generic.List[string]'
$pending = New-Object 'System.Collections.Generic.Stack[string]'
$pending.Push($cachePath)
$bytes = [long]0
$entries = 0
$deadline = (Get-Date).AddMinutes(2)
$prefix = $cachePath + [IO.Path]::DirectorySeparatorChar

while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    if ([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to scan a reparse point: $directory"
    }
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
        $entries++
        if ($entries -gt 100000 -or (Get-Date) -gt $deadline) {
            throw 'Spotify cache scan exceeded the bounded entry/time limit.'
        }
        if (-not [IO.Path]::GetFullPath($entry).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Entry escaped the expected Spotify cache: $entry"
        }
        $attributes = [IO.File]::GetAttributes($entry)
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to follow a reparse point inside Spotify cache: $entry"
        }
        if ($attributes -band [IO.FileAttributes]::Directory) {
            $dirs.Add($entry)
            $pending.Push($entry)
        }
        else {
            $files.Add($entry)
            $bytes += ([IO.FileInfo]::new($entry)).Length
        }
    }
}

$sizeGB = [math]::Round($bytes / 1GB, 2)
if ($bytes -lt ($MaxGB * 1GB)) {
    Write-GuardResult "Skipped: streaming cache is $sizeGB GB, below $MaxGB GB."
    return
}
if ($DryRun) {
    Write-GuardResult "Dry run: would clear $sizeGB GB in $($files.Count) files, leaving the Data directory and junction intact."
    return
}
if (Test-SpotifyRunning) {
    Write-GuardResult 'Skipped: Spotify started during the cache scan.'
    return
}

$removedBytes = [long]0
$removedFiles = 0
foreach ($file in $files) {
    if (Test-SpotifyRunning) {
        Write-GuardResult "Stopped: Spotify started during cleanup. Removed $removedFiles files ($([math]::Round($removedBytes / 1GB, 2)) GB)."
        return
    }
    if (-not [IO.Path]::GetFullPath($file).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "File escaped the expected Spotify cache: $file"
    }
    $attributes = [IO.File]::GetAttributes($file)
    if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to delete a reparse point: $file"
    }
    $length = ([IO.FileInfo]::new($file)).Length
    [IO.File]::Delete($file)
    $removedBytes += $length
    $removedFiles++
}

$dirs.Sort([StringComparer]::OrdinalIgnoreCase)
for ($i = $dirs.Count - 1; $i -ge 0; $i--) {
    if (Test-SpotifyRunning) { break }
    $dir = $dirs[$i]
    if ([IO.Directory]::Exists($dir) -and -not ([IO.File]::GetAttributes($dir) -band [IO.FileAttributes]::ReparsePoint)) {
        try { [IO.Directory]::Delete($dir, $false) }
        catch [IO.IOException] { } # Spotify may have created new cache files after starting.
    }
}

Write-GuardResult "Cleaned Spotify streaming cache: $removedFiles files, $([math]::Round($removedBytes / 1GB, 2)) GB."
