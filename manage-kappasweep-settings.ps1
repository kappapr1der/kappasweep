[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [ValidateSet("Menu", "Caches", "Drives", "Exclusions", "Show")]
    [string]$Section = "Menu"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$encodingHelper = Join-Path $PSScriptRoot "kappasweep-encoding.ps1"
if (Test-Path -LiteralPath $encodingHelper -PathType Leaf) {
    . $encodingHelper
}

function Resolve-ConfigPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return (Join-Path $PSScriptRoot "kappasweep-config.json")
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([IO.Path]::IsPathRooted($expanded)) {
        return $expanded
    }

    return (Join-Path $PSScriptRoot $expanded)
}

function Get-ConfigProperty {
    param($Object, [string]$Name)

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-OrAddObjectProperty {
    param(
        $Object,
        [string]$Name,
        $DefaultValue
    )

    $existing = Get-ConfigProperty -Object $Object -Name $Name
    if ($null -ne $existing) {
        return $existing
    }

    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $DefaultValue -Force
    return $DefaultValue
}

function Save-Config {
    param($Config, [string]$Path)

    $json = $Config | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Format-ByteSize {
    param([int64]$Bytes)

    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-ExistingCachePaths {
    param([string[]]$Patterns)

    $paths = New-Object System.Collections.ArrayList
    foreach ($pattern in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) {
            continue
        }

        try {
            if ($pattern.IndexOfAny([char[]]"*?") -ge 0) {
                Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { [void]$paths.Add($_.FullName) }
            }
            elseif (Test-Path -LiteralPath $pattern -PathType Container -ErrorAction SilentlyContinue) {
                [void]$paths.Add($pattern)
            }
        }
        catch {
            continue
        }
    }

    return @($paths | Select-Object -Unique)
}

function Measure-CachePaths {
    param([string[]]$Paths)

    $total = [int64]0
    foreach ($path in @($Paths)) {
        try {
            Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue |
                ForEach-Object { $total += [int64]$_.Length }
        }
        catch {
            continue
        }
    }

    return $total
}

function Get-CacheSwitches {
    $appData = $env:APPDATA
    $localAppData = $env:LOCALAPPDATA
    $programFilesX86 = ${env:ProgramFiles(x86)}

    return @(
        [pscustomobject]@{
            Key = "discordCache"; Name = "Discord"; Description = "Cache, Code Cache и GPUCache";
            Patterns = @(
                (Join-Path $appData "discord\Cache"),
                (Join-Path $appData "discord\Code Cache"),
                (Join-Path $appData "discord\GPUCache"),
                (Join-Path $appData "discordptb\Cache"),
                (Join-Path $appData "discordcanary\Cache")
            )
        }
        [pscustomobject]@{
            Key = "telegramCache"; Name = "Telegram Desktop"; Description = "Кэш и медиа-кэш";
            Patterns = @(
                (Join-Path $appData "Telegram Desktop\tdata\user_data\cache"),
                (Join-Path $appData "Telegram Desktop\tdata\user_data\media_cache")
            )
        }
        [pscustomobject]@{
            Key = "spotifyCache"; Name = "Spotify"; Description = "Потоковый, browser и storage cache";
            Patterns = @(
                (Join-Path $localAppData "Spotify\Data"),
                (Join-Path $localAppData "Spotify\Storage"),
                (Join-Path $localAppData "Spotify\Browser\Cache"),
                (Join-Path $appData "Spotify\Browser\Cache")
            )
        }
        [pscustomobject]@{
            Key = "slackCache"; Name = "Slack"; Description = "Cache, Code Cache и GPUCache";
            Patterns = @(
                (Join-Path $appData "Slack\Cache"),
                (Join-Path $appData "Slack\Code Cache"),
                (Join-Path $appData "Slack\GPUCache")
            )
        }
        [pscustomobject]@{
            Key = "teamsCache"; Name = "Microsoft Teams"; Description = "Кэш старого и нового клиента";
            Patterns = @(
                (Join-Path $appData "Microsoft\Teams\Cache"),
                (Join-Path $appData "Microsoft\Teams\Code Cache"),
                (Join-Path $appData "Microsoft\Teams\GPUCache"),
                (Join-Path $localAppData "Packages\MSTeams_*\LocalCache\Microsoft\MSTeams\Cache")
            )
        }
        [pscustomobject]@{
            Key = "zoomCache"; Name = "Zoom"; Description = "Webview cache";
            Patterns = @((Join-Path $appData "Zoom\data\WebviewCache"))
        }
        [pscustomobject]@{
            Key = "browserCaches"; Name = "Браузеры"; Description = "Кэш Chrome, Edge, Brave и Firefox";
            Patterns = @(
                (Join-Path $localAppData "Google\Chrome\User Data\*\Cache\Cache_Data"),
                (Join-Path $localAppData "Microsoft\Edge\User Data\*\Cache\Cache_Data"),
                (Join-Path $localAppData "BraveSoftware\Brave-Browser\User Data\*\Cache\Cache_Data"),
                (Join-Path $localAppData "Mozilla\Firefox\Profiles\*\cache2\entries")
            )
        }
        [pscustomobject]@{
            Key = "developerCaches"; Name = "Кэши разработки"; Description = "npm, pnpm, pip, NuGet и Gradle";
            Patterns = @(
                (Join-Path $localAppData "npm-cache"),
                (Join-Path $localAppData "pnpm\store"),
                (Join-Path $localAppData "pip\Cache"),
                (Join-Path $localAppData "NuGet\v3-cache"),
                (Join-Path $env:USERPROFILE ".gradle\caches\build-cache-1")
            )
        }
        [pscustomobject]@{
            Key = "gameCaches"; Name = "Игровые кэши"; Description = "Steam, Epic, Battle.net, Riot и лаунчеры";
            Patterns = @(
                $(if ($programFilesX86) { Join-Path $programFilesX86 "Steam\appcache\httpcache" }),
                $(if ($programFilesX86) { Join-Path $programFilesX86 "Steam\steamapps\shadercache" }),
                (Join-Path $localAppData "EpicGamesLauncher\Saved\webcache*"),
                (Join-Path $localAppData "Battle.net\Cache"),
                (Join-Path $localAppData "Riot Games\Riot Client\Data\Cache")
            )
        }
    )
}

function Show-CacheSwitches {
    param($Features)

    $switches = @(Get-CacheSwitches)
    Write-Host ""
    Write-Host "== Кэши программ ==" -ForegroundColor Green
    for ($index = 0; $index -lt $switches.Count; $index++) {
        $item = $switches[$index]
        $enabled = [bool](Get-ConfigProperty -Object $Features -Name $item.Key)
        $paths = @(Get-ExistingCachePaths -Patterns $item.Patterns)
        $size = if ($paths.Count -gt 0) { Format-ByteSize (Measure-CachePaths -Paths $paths) } else { "не найден" }
        $mark = if ($enabled) { "x" } else { " " }
        Write-Host ("{0}. [{1}] {2} - {3}" -f ($index + 1), $mark, $item.Name, $size)
    }
    Write-Host ""
    Write-Host "N. Уведомления при нехватке места"
    Write-Host "D. Пороги свободного места по дискам"
    Write-Host "E. Исключения"
    Write-Host "Q. Назад"
    return $switches
}

function Invoke-CacheMenu {
    param($Config, [string]$Path)

    $features = Get-OrAddObjectProperty -Object $Config -Name "features" -DefaultValue ([pscustomobject]@{})
    while ($true) {
        Clear-Host
        $switches = @(Show-CacheSwitches -Features $features)
        $choice = (Read-Host "Выбери пункт").Trim()
        if ($choice -match '^[0-9]+$') {
            $index = [int]$choice - 1
            if ($index -ge 0 -and $index -lt $switches.Count) {
                $item = $switches[$index]
                $current = [bool](Get-ConfigProperty -Object $features -Name $item.Key)
                $features | Add-Member -NotePropertyName $item.Key -NotePropertyValue (-not $current) -Force
                Save-Config -Config $Config -Path $Path
            }
            continue
        }

        switch ($choice.ToUpperInvariant()) {
            "N" {
                $current = [bool](Get-ConfigProperty -Object $features -Name "notifyOnPressure")
                $features | Add-Member -NotePropertyName "notifyOnPressure" -NotePropertyValue (-not $current) -Force
                Save-Config -Config $Config -Path $Path
            }
            "D" { Invoke-DriveMenu -Config $Config -Path $Path }
            "E" { Invoke-ExclusionMenu -Config $Config -Path $Path }
            "Q" { return }
        }
    }
}

function Get-FixedDriveRows {
    return @([System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady } |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                Drive = $_.Name.TrimEnd("\\")
                Free = (Format-ByteSize -Bytes $_.AvailableFreeSpace)
                FreePercent = [Math]::Round(($_.AvailableFreeSpace / $_.TotalSize) * 100, 1)
            }
        })
}

function Invoke-DriveMenu {
    param($Config, [string]$Path)

    $thresholds = Get-OrAddObjectProperty -Object $Config -Name "thresholds" -DefaultValue ([pscustomobject]@{})
    $perDrive = Get-OrAddObjectProperty -Object $thresholds -Name "perDrive" -DefaultValue ([pscustomobject]@{})
    $globalGB = [int](Get-ConfigProperty -Object $thresholds -Name "minFreeGB")
    $globalPercent = [int](Get-ConfigProperty -Object $thresholds -Name "minFreePercent")

    while ($true) {
        Clear-Host
        Write-Host "== Пороги по дискам ==" -ForegroundColor Green
        foreach ($drive in (Get-FixedDriveRows)) {
            $entry = Get-ConfigProperty -Object $perDrive -Name $drive.Drive
            $gb = if ($entry) { [int](Get-ConfigProperty -Object $entry -Name "minFreeGB") } else { $globalGB }
            $percent = if ($entry) { [int](Get-ConfigProperty -Object $entry -Name "minFreePercent") } else { $globalPercent }
            Write-Host ("{0}  свободно: {1} ({2}%). Порог: {3} GB или {4}%%" -f $drive.Drive, $drive.Free, $drive.FreePercent, $gb, $percent)
        }
        Write-Host ""
        $driveName = (Read-Host "Буква диска для изменения, Enter - назад").Trim().TrimEnd("\\")
        if ([string]::IsNullOrWhiteSpace($driveName)) { return }
        if ($driveName.Length -eq 1) { $driveName = "$driveName`:" }
        $driveName = $driveName.ToUpperInvariant()
        $gbInput = Read-Host "Минимум свободных GB"
        $percentInput = Read-Host "Минимум свободных процентов"
        [int]$gb = 0
        [int]$percent = 0
        if (-not [int]::TryParse($gbInput, [ref]$gb) -or $gb -lt 1 -or -not [int]::TryParse($percentInput, [ref]$percent) -or $percent -lt 1 -or $percent -gt 99) {
            Write-Host "Нужны числа: минимум 1 GB и от 1 до 99%." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
            continue
        }
        $perDrive | Add-Member -NotePropertyName $driveName -NotePropertyValue ([pscustomobject]@{ minFreeGB = $gb; minFreePercent = $percent }) -Force
        Save-Config -Config $Config -Path $Path
    }
}

function Invoke-ExclusionMenu {
    param($Config, [string]$Path)

    $paths = Get-OrAddObjectProperty -Object (Get-OrAddObjectProperty -Object $Config -Name "paths" -DefaultValue ([pscustomobject]@{})) -Name "excludedPaths" -DefaultValue @()
    while ($true) {
        Clear-Host
        Write-Host "== Исключения ==" -ForegroundColor Green
        if (@($paths).Count -eq 0) {
            Write-Host "Пока нет исключений."
        }
        else {
            for ($index = 0; $index -lt @($paths).Count; $index++) {
                Write-Host ("{0}. {1}" -f ($index + 1), $paths[$index])
            }
        }
        Write-Host ""
        Write-Host "A. Добавить папку"
        Write-Host "Номер. Удалить исключение"
        Write-Host "Q. Назад"
        $choice = (Read-Host "Выбери пункт").Trim()
        if ($choice.ToUpperInvariant() -eq "Q") { return }
        if ($choice.ToUpperInvariant() -eq "A") {
            $newPath = (Read-Host "Полный путь к папке, которую нельзя чистить").Trim()
            if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                $paths = @($paths) + $newPath
                $Config.paths | Add-Member -NotePropertyName "excludedPaths" -NotePropertyValue @($paths | Select-Object -Unique) -Force
                $paths = $Config.paths.excludedPaths
                Save-Config -Config $Config -Path $Path
            }
            continue
        }
        if ($choice -match '^[0-9]+$') {
            $index = [int]$choice - 1
            if ($index -ge 0 -and $index -lt @($paths).Count) {
                $paths = @($paths | Where-Object { $_ -ne $paths[$index] })
                $Config.paths | Add-Member -NotePropertyName "excludedPaths" -NotePropertyValue $paths -Force
                Save-Config -Config $Config -Path $Path
            }
        }
    }
}

$resolvedPath = Resolve-ConfigPath -Path $ConfigPath
if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
    throw "Не найден kappasweep-config.json: $resolvedPath"
}

$config = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Section -eq "Show") {
    $features = Get-OrAddObjectProperty -Object $config -Name "features" -DefaultValue ([pscustomobject]@{})
    $null = Show-CacheSwitches -Features $features
    exit 0
}

switch ($Section) {
    "Caches" { Invoke-CacheMenu -Config $config -Path $resolvedPath }
    "Drives" { Invoke-DriveMenu -Config $config -Path $resolvedPath }
    "Exclusions" { Invoke-ExclusionMenu -Config $config -Path $resolvedPath }
    default {
        while ($true) {
            Clear-Host
            Write-Host "== Настройки KappaSweep ==" -ForegroundColor Green
            Write-Host "1. Кэши программ"
            Write-Host "2. Пороги свободного места по дискам"
            Write-Host "3. Исключения"
            Write-Host "Q. Готово"
            switch ((Read-Host "Выбери пункт").Trim().ToUpperInvariant()) {
                "1" { Invoke-CacheMenu -Config $config -Path $resolvedPath }
                "2" { Invoke-DriveMenu -Config $config -Path $resolvedPath }
                "3" { Invoke-ExclusionMenu -Config $config -Path $resolvedPath }
                "Q" { break }
            }
            if ((Read-Host "Enter - продолжить, Q - выйти").Trim().ToUpperInvariant() -eq "Q") { break }
        }
    }
}
