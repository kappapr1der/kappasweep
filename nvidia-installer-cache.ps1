Set-StrictMode -Version Latest

function Get-NvidiaInstalledVersions {
    $versions = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -match 'NVIDIA' } | ForEach-Object {
        $parts = ([string]$_.DriverVersion).Split('.')
        if ($parts.Count -ne 4) { throw 'Unrecognized NVIDIA driver version.' }
        $number = ([int]$parts[2] % 10) * 10000 + [int]$parts[3]
        '{0}.{1:00}' -f [int][math]::Floor($number / 100), ($number % 100)
    })
    if (-not $versions.Count) { throw 'Installed NVIDIA driver could not be identified.' }
    return $versions
}

function Test-NvidiaUpdateBusy {
    # The display container/overlay are always-on services, not driver installers.
    $processes = @(Get-Process -ErrorAction Stop)
    return @($processes | Where-Object {
        $_.ProcessName -match '^(NVIDIA app|NVIDIA Installer|setup|setuphost|nvsetup|NVI2|NvidiaPackageLauncher)$' -or
        $_.ProcessName -match '^\d{3,4}\.\d{2}-desktop-win'
    }).Count -gt 0
}

function Test-NvidiaPlainPath {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        if ($item -is [IO.FileInfo]) { $item = $item.Directory } else { $item = $item.Parent }
    }
    return $true
}

function Read-NvidiaStatus {
    param([string]$Path)
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file.Length -gt 1MB -or -not (Test-NvidiaPlainPath $Path)) { throw 'Unsafe NVIDIA status file.' }
    $parsed = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $items = @($parsed)
    if ($items.Count -lt 1 -or $items.Count -gt 100) { throw 'Unexpected NVIDIA status record count.' }
    return $items
}

function Get-NvidiaInstallerPlan {
    param([string]$UpdateRoot = (Join-Path $env:ProgramData 'NVIDIA Corporation\NVIDIA App\UpdateFramework'))
    if (-not (Test-Path -LiteralPath $UpdateRoot -PathType Container)) { return }
    if (-not (Test-NvidiaPlainPath $UpdateRoot)) { throw 'NVIDIA update root uses a reparse point.' }
    if (Test-NvidiaUpdateBusy) { throw 'NVIDIA app or an installer is open; retry when it is closed.' }
    $installed = @(Get-NvidiaInstalledVersions)
    $downloadPath = Join-Path $UpdateRoot 'status\grd\download.json'
    $processingPath = Join-Path $UpdateRoot 'status\grd\postprocessing.json'
    $downloads = @(Read-NvidiaStatus $downloadPath)
    $processing = @(Read-NvidiaStatus $processingPath)
    $root = [IO.Path]::GetFullPath((Join-Path $UpdateRoot 'ota-artifacts\grd'))
    $records = @()
    $ids = @{}
    foreach ($download in $downloads) {
        $id = [string]$download.taskId
        $version = [string]$download.version
        if ($id -notmatch '^[a-f0-9]{32}$' -or $ids.ContainsKey($id) -or $version -notmatch '^\d{3,4}\.\d{2}$') {
            throw 'Unrecognized NVIDIA package metadata.'
        }
        $ids[$id] = $true
        $pp = @($processing | Where-Object { $_.taskId -eq $id })
        if ($download.state -ne 8 -or $download.percentComplete -ne 100 -or $download.errorCode -ne 0 -or
            $pp.Count -ne 1 -or $pp[0].status -ne 1 -or -not @($pp[0].actions).Count -or @($pp[0].actions | Where-Object status -ne 2).Count) {
            throw 'NVIDIA download/extraction is incomplete or has an unknown state.'
        }
        $package = Join-Path $root $id
        $extracted = Join-Path (Join-Path $root 'post-processing') $id
        $leaf = [IO.Path]::GetFileName([string]$download.fileLocation)
        if ($leaf -notmatch ('^' + [regex]::Escape($version) + '-desktop-win[\w.-]+\.exe$') -or
            [IO.Path]::GetFullPath([string]$download.fileLocation) -ine (Join-Path $package $leaf) -or
            [IO.Path]::GetFullPath([string]$pp[0].postProcessingInput) -ine (Join-Path $package $leaf) -or
            [IO.Path]::GetFullPath([string]$pp[0].taskOutput) -ine (Join-Path $extracted 'setup.exe')) {
            throw 'NVIDIA package paths do not match their expected cache locations.'
        }
        $records += [pscustomobject]@{Id=$id;Version=$version;Paths=@($package,$extracted);Reason='obsolete';Root=$root}
    }
    $latest = ($records | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1).Version
    foreach ($record in $records) {
        if ($installed -contains $record.Version) { $record.Reason = 'installed driver package' }
        elseif ($record.Version -eq $latest) { $record.Reason = 'newest downloaded driver package' }
        $record
    }
}

function Get-NvidiaPackageTree {
    param([string[]]$Paths, [string]$Root, [string[]]$ExcludedPaths = @())
    $files = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $directories = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
    $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $cutoff = (Get-Date).AddHours(-24)
    foreach ($path in $Paths) {
        $full = [IO.Path]::GetFullPath($path)
        $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
        if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe NVIDIA cleanup target.' }
        $relative = $full.Substring($prefix.Length)
        if ($relative -notmatch '^(post-processing\\)?[a-f0-9]{32}$') { throw 'Unsafe NVIDIA cleanup target.' }
        if (-not (Test-Path -LiteralPath $full)) { continue }
        if (-not (Test-NvidiaPlainPath $full)) { throw 'NVIDIA package contains a reparse point.' }
        foreach ($excluded in $ExcludedPaths) {
            if ([string]::IsNullOrWhiteSpace($excluded)) { continue }
            $excludedFull = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($excluded)).TrimEnd('\')
            if ($full -ieq $excludedFull -or $full.StartsWith($excludedFull+'\', [StringComparison]::OrdinalIgnoreCase) -or
                $excludedFull.StartsWith($full+'\', [StringComparison]::OrdinalIgnoreCase)) { throw 'NVIDIA package intersects an excluded path.' }
        }
        $pending.Push([IO.DirectoryInfo]::new($full))
    }
    while ($pending.Count) {
        if ($watch.Elapsed.TotalSeconds -gt 20 -or $files.Count -gt 20000 -or $directories.Count -gt 5000) {
            throw 'NVIDIA package scan limit reached; nothing was deleted.'
        }
        $directory = $pending.Pop()
        $directories.Add($directory)
        foreach ($entry in $directory.EnumerateFileSystemInfos()) {
            if ($watch.Elapsed.TotalSeconds -gt 20 -or $files.Count -gt 20000 -or $pending.Count -gt 5000) { throw 'NVIDIA package scan limit reached.' }
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'NVIDIA package contains a reparse point.' }
            if ($entry.CreationTime -gt $cutoff -or $entry.LastWriteTime -gt $cutoff) { throw 'NVIDIA package was modified within the last 24 hours.' }
            if ($entry -is [IO.DirectoryInfo]) { $pending.Push($entry) } else { $files.Add($entry) }
        }
    }
    [pscustomobject]@{Files=$files;Directories=$directories}
}

function Invoke-NvidiaInstallerCacheCore {
    param(
        [switch]$Apply,
        [string[]]$ExcludedPaths = @(),
        [string]$UpdateRoot = (Join-Path $env:ProgramData 'NVIDIA Corporation\NVIDIA App\UpdateFramework')
    )
    try { $plan = @(Get-NvidiaInstallerPlan $UpdateRoot) }
    catch {
        [pscustomobject]@{Version='';Status='skipped';Bytes=[int64]0;Items=0;Failures=0;Path=$UpdateRoot;Message=$_.Exception.Message}
        return
    }
    foreach ($record in $plan) {
        $result = [pscustomobject]@{Version=$record.Version;Status='kept';Bytes=[int64]0;Items=0;Failures=0;Path=$record.Paths[0];Message=$record.Reason}
        if ($record.Reason -ne 'obsolete') { $result; continue }
        try {
            $tree = Get-NvidiaPackageTree -Paths $record.Paths -Root $record.Root -ExcludedPaths $ExcludedPaths
            if ($tree.Files.Count -eq 0 -and $tree.Directories.Count -eq 0) {
                $result.Status = 'missing'
                $result.Message = 'Package was already removed.'
                $result
                continue
            }
            # Re-read metadata and process state immediately before touching each package.
            $fresh = @(Get-NvidiaInstallerPlan $UpdateRoot | Where-Object { $_.Id -eq $record.Id -and $_.Reason -eq 'obsolete' })
            if ($fresh.Count -ne 1) { throw 'NVIDIA package protection changed during scanning.' }
            $result.Status = if ($Apply) { 'cleaned' } else { 'would clean' }
            foreach ($file in $tree.Files) {
                if ($Apply) {
                    if ($result.Items % 32 -eq 0 -and (Test-NvidiaUpdateBusy)) { throw 'An installer opened during cleanup.' }
                    if (-not (Test-NvidiaPlainPath $file.FullName)) { throw 'NVIDIA package path changed.' }
                    $file.Refresh()
                    if ($file.LastWriteTime -gt (Get-Date).AddHours(-24) -or $file.CreationTime -gt (Get-Date).AddHours(-24)) { throw 'NVIDIA package changed during cleanup.' }
                    $length = $file.Length
                    $file.Delete()
                } else { $length = $file.Length }
                $result.Bytes += $length
                $result.Items++
            }
            if ($Apply) {
                foreach ($dir in ($tree.Directories | Sort-Object { $_.FullName.Length } -Descending)) {
                    if (-not (Test-NvidiaPlainPath $dir.FullName)) { throw 'NVIDIA package directory changed.' }
                    $dir.Delete($false)
                }
            }
        }
        catch {
            $result.Status = if ($result.Items) { 'partial' } else { 'skipped' }
            $result.Message = $_.Exception.Message
            $result.Failures = 1
        }
        $result
    }
}

function Invoke-NvidiaInstallerCache {
    param(
        [switch]$Apply,
        [string[]]$ExcludedPaths = @(),
        [string]$UpdateRoot = (Join-Path $env:ProgramData 'NVIDIA Corporation\NVIDIA App\UpdateFramework')
    )
    $mutex = [Threading.Mutex]::new($false, 'Local\KappaSweep.NvidiaInstallerCache')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            [pscustomobject]@{Version='';Status='skipped';Bytes=[int64]0;Items=0;Failures=0;Path=$UpdateRoot;Message='Another NVIDIA cache operation is running.'}
            return
        }
        Invoke-NvidiaInstallerCacheCore -Apply:$Apply -ExcludedPaths $ExcludedPaths -UpdateRoot $UpdateRoot
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
