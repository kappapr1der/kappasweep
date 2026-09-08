[CmdletBinding()]
param(
    [string[]]$Drives = @(),
    [ValidateRange(3, 50)]
    [int]$Top = 12,
    [switch]$Quick,
    [switch]$OpenReport,
    [switch]$AnalyzeComponentStore,
    [switch]$NotificationSummary,
    [string]$LogDir = "",
    [switch]$SkipHistory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$encodingHelper = Join-Path $PSScriptRoot "kappasweep-encoding.ps1"
if (Test-Path -LiteralPath $encodingHelper -PathType Leaf) {
    . $encodingHelper
}

$script:AddedItemKeys = @{}

function Format-ByteSize {
    param([int64]$Bytes)

    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-FixedDrives {
    return @([System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady -and $_.TotalSize -gt 0 } |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                Drive = $_.Name.TrimEnd("\\")
                FreeBytes = [int64]$_.AvailableFreeSpace
                TotalBytes = [int64]$_.TotalSize
            }
        })
}

function Resolve-LogFolder {
    param([string]$PreferredLogDir)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($PreferredLogDir)) { $candidates += $PreferredLogDir }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) { $candidates += (Join-Path $env:ProgramData "CodexWindowsCleanup\Logs") }
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { $candidates += (Join-Path $env:TEMP "CodexWindowsCleanup\Logs") }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        try {
            New-Item -ItemType Directory -Path $candidate -Force -ErrorAction Stop | Out-Null
            return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).ProviderPath
        }
        catch {
            continue
        }
    }

    return ""
}

function Measure-PathBytes {
    param([string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            return [int64]$item.Length
        }
    }
    catch {
        return [int64]0
    }

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

function Add-SpaceItem {
    param(
        [System.Collections.ArrayList]$Items,
        [string]$Scope,
        [string]$Name,
        [string]$Path,
        [string]$Action
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
    }
    catch {
        return
    }

    $key = ("{0}|{1}" -f $Scope, $fullPath).ToLowerInvariant()
    if ($script:AddedItemKeys.ContainsKey($key)) { return }
    $script:AddedItemKeys[$key] = $true

    try {
        if (-not (Test-Path -LiteralPath $fullPath -ErrorAction Stop)) { return }
    }
    catch {
        return
    }

    $bytes = Measure-PathBytes -Path $fullPath
    if ($bytes -le 0) { return }

    [void]$Items.Add([pscustomobject]@{
        Key = $key
        Scope = $Scope
        Name = $Name
        Path = $fullPath
        SizeBytes = [int64]$bytes
        Size = Format-ByteSize -Bytes $bytes
        Change = "первый снимок"
        Action = $Action
    })
}

function Add-WildcardSpaceItems {
    param(
        [System.Collections.ArrayList]$Items,
        [string]$Scope,
        [string]$Name,
        [string]$Pattern,
        [string]$Action
    )

    if ([string]::IsNullOrWhiteSpace($Pattern)) { return }

    try {
        Get-ChildItem -Path $Pattern -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Add-SpaceItem -Items $Items -Scope $Scope -Name $Name -Path $_.FullName -Action $Action
        }
    }
    catch {
        return
    }
}

function Add-SystemSpaceItems {
    param(
        [System.Collections.ArrayList]$Items,
        [string]$SystemDrive,
        [object[]]$SelectedDrives,
        [switch]$QuickMode
    )

    if ([string]::IsNullOrWhiteSpace($SystemDrive)) { return }
    $systemRoot = "$SystemDrive\\"

    Add-SpaceItem -Items $Items -Scope "Windows" -Name "Файл гибернации" -Path (Join-Path $systemRoot "hiberfil.sys") -Action "Не удаляется автоматически; меняет режим гибернации и Fast Startup"
    Add-SpaceItem -Items $Items -Scope "Windows" -Name "Файл подкачки" -Path (Join-Path $systemRoot "pagefile.sys") -Action "Не удаляется автоматически; нужен Windows"
    Add-SpaceItem -Items $Items -Scope "Windows" -Name "Файл гибридной подкачки" -Path (Join-Path $systemRoot "swapfile.sys") -Action "Не удаляется автоматически; нужен Windows"
    Add-SpaceItem -Items $Items -Scope "Windows" -Name "Windows Update downloads" -Path (Join-Path $env:SystemRoot "SoftwareDistribution\Download") -Action "Доступно в глубокой очистке"
    Add-SpaceItem -Items $Items -Scope "Windows" -Name "Delivery Optimization cache" -Path (Join-Path $env:ProgramData "Microsoft\Windows\DeliveryOptimization\Cache") -Action "Доступно в глубокой очистке"
    Add-SpaceItem -Items $Items -Scope "Windows" -Name "Windows temporary files" -Path (Join-Path $env:SystemRoot "Temp") -Action "Доступно в безопасной очистке"
    Add-SpaceItem -Items $Items -Scope "Windows" -Name "CBS logs" -Path (Join-Path $env:SystemRoot "Logs\CBS") -Action "Только диагностика"

    foreach ($drive in @($SelectedDrives)) {
        Add-SpaceItem -Items $Items -Scope "Windows" -Name ("Корзина {0}" -f $drive.Drive) -Path (Join-Path ($drive.Drive + "\\") '$Recycle.Bin') -Action "Очистка корзины включается отдельно"
    }

    if ($QuickMode) { return }

    Add-SpaceItem -Items $Items -Scope "Windows" -Name "Хранилище компонентов WinSxS" -Path (Join-Path $env:SystemRoot "WinSxS") -Action "Только DISM; не удалять вручную"
    Add-SpaceItem -Items $Items -Scope "Windows" -Name "DriverStore" -Path (Join-Path $env:SystemRoot "System32\DriverStore\FileRepository") -Action "Только диагностика; не удалять вручную"
}

function Add-ApplicationSpaceItems {
    param(
        [System.Collections.ArrayList]$Items,
        [switch]$QuickMode
    )

    $local = $env:LOCALAPPDATA
    $roaming = $env:APPDATA
    $profile = $env:USERPROFILE
    $programFilesX86 = ${env:ProgramFiles(x86)}

    Add-SpaceItem -Items $Items -Scope "Кэш приложений" -Name "Spotify" -Path (Join-Path $local "Spotify\Data") -Action "Переключатель Spotify"
    Add-SpaceItem -Items $Items -Scope "Кэш приложений" -Name "Discord" -Path (Join-Path $roaming "discord\Cache") -Action "Переключатель Discord"
    Add-SpaceItem -Items $Items -Scope "Кэш приложений" -Name "Telegram Desktop" -Path (Join-Path $roaming "Telegram Desktop\tdata\user_data\media_cache") -Action "Переключатель Telegram"
    Add-SpaceItem -Items $Items -Scope "Кэш приложений" -Name "Slack" -Path (Join-Path $roaming "Slack\Cache") -Action "Переключатель Slack"
    Add-SpaceItem -Items $Items -Scope "Кэш приложений" -Name "Microsoft Teams" -Path (Join-Path $roaming "Microsoft\Teams\Cache") -Action "Переключатель Teams"
    Add-SpaceItem -Items $Items -Scope "Кэш приложений" -Name "Zoom" -Path (Join-Path $roaming "Zoom\data\WebviewCache") -Action "Переключатель Zoom"
    Add-WildcardSpaceItems -Items $Items -Scope "Кэш приложений" -Name "Chrome" -Pattern (Join-Path $local "Google\Chrome\User Data\*\Cache") -Action "Переключатель браузеров"
    Add-WildcardSpaceItems -Items $Items -Scope "Кэш приложений" -Name "Edge" -Pattern (Join-Path $local "Microsoft\Edge\User Data\*\Cache") -Action "Переключатель браузеров"
    Add-WildcardSpaceItems -Items $Items -Scope "Кэш приложений" -Name "Brave" -Pattern (Join-Path $local "BraveSoftware\Brave-Browser\User Data\*\Cache") -Action "Переключатель браузеров"
    Add-WildcardSpaceItems -Items $Items -Scope "Кэш приложений" -Name "Firefox" -Pattern (Join-Path $local "Mozilla\Firefox\Profiles\*\cache2") -Action "Переключатель браузеров"
    Add-SpaceItem -Items $Items -Scope "Кэш приложений" -Name "Steam HTTP cache" -Path $(if ($programFilesX86) { Join-Path $programFilesX86 "Steam\appcache\httpcache" }) -Action "Переключатель Steam"
    Add-SpaceItem -Items $Items -Scope "Кэш приложений" -Name "Steam shader cache" -Path $(if ($programFilesX86) { Join-Path $programFilesX86 "Steam\steamapps\shadercache" }) -Action "Переключатель Steam; шейдеры пересоберутся"
    Add-WildcardSpaceItems -Items $Items -Scope "Кэш приложений" -Name "Epic Games Launcher" -Pattern (Join-Path $local "EpicGamesLauncher\Saved\webcache*") -Action "Переключатель Epic"
    Add-SpaceItem -Items $Items -Scope "Кэш приложений" -Name "Battle.net" -Path (Join-Path $local "Battle.net\Cache") -Action "Переключатель Battle.net"
    Add-SpaceItem -Items $Items -Scope "Кэш приложений" -Name "EA App" -Path (Join-Path $local "Electronic Arts\EA Desktop\cache") -Action "Переключатель EA App"
    Add-SpaceItem -Items $Items -Scope "Кэш приложений" -Name "Adobe media cache" -Path (Join-Path $roaming "Adobe\Common\Media Cache Files") -Action "Переключатель Adobe"
    Add-SpaceItem -Items $Items -Scope "Кэш приложений" -Name "OBS browser cache" -Path (Join-Path $roaming "obs-studio\plugin_config\obs-browser\Cache") -Action "Переключатель OBS"
    Add-SpaceItem -Items $Items -Scope "Кэш приложений" -Name "Docker Desktop disk" -Path (Join-Path $local "Docker\wsl\data\ext4.vhdx") -Action "Только диагностика; обслуживать внутри Docker"
    Add-WildcardSpaceItems -Items $Items -Scope "Кэш приложений" -Name "WSL distribution disk" -Pattern (Join-Path $local "Packages\*\LocalState\ext4.vhdx") -Action "Только диагностика; обслуживать внутри WSL"

    if ($QuickMode) { return }

    Add-SpaceItem -Items $Items -Scope "Личные данные" -Name "Загрузки" -Path (Join-Path $profile "Downloads") -Action "Только диагностика; не удаляется KappaSweep"
    Add-SpaceItem -Items $Items -Scope "Личные данные" -Name "Рабочий стол" -Path (Join-Path $profile "Desktop") -Action "Только диагностика; не удаляется KappaSweep"
    Add-SpaceItem -Items $Items -Scope "Личные данные" -Name "Документы" -Path (Join-Path $profile "Documents") -Action "Только диагностика; не удаляется KappaSweep"
}

function Add-DriveFolderItems {
    param(
        [System.Collections.ArrayList]$Items,
        [object[]]$SelectedDrives,
        [string]$SystemDrive
    )

    foreach ($drive in @($SelectedDrives)) {
        $root = $drive.Drive + "\\"
        if ($drive.Drive -ieq $SystemDrive) {
            $profileRoot = $env:USERPROFILE
            $personalFolders = @("Downloads", "Desktop", "Documents", "Pictures", "Videos", "OneDrive")
            foreach ($folderName in $personalFolders) {
                $candidate = Join-Path $profileRoot $folderName
                Add-SpaceItem -Items $Items -Scope "Личные данные" -Name $folderName -Path $candidate -Action "Только диагностика; не удаляется KappaSweep"
            }
            continue
        }

        try {
            Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Name -in @("System Volume Information", "$Recycle.Bin", "Recovery")) { return }
                Add-SpaceItem -Items $Items -Scope "Крупная папка диска" -Name ("{0}: {1}" -f $drive.Drive, $_.Name) -Path $_.FullName -Action "Только диагностика; открой анализатор перед ручной разборкой"
            }
        }
        catch {
            continue
        }
    }
}

function Resolve-HistoryFile {
    param([string]$Folder)

    if ([string]::IsNullOrWhiteSpace($Folder)) { return "" }
    return (Join-Path $Folder "space-hog-history.jsonl")
}

function Get-LatestSnapshot {
    param([string]$HistoryFile)

    if ([string]::IsNullOrWhiteSpace($HistoryFile) -or -not (Test-Path -LiteralPath $HistoryFile -PathType Leaf -ErrorAction SilentlyContinue)) { return $null }

    try {
        $line = Get-Content -LiteralPath $HistoryFile -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Last 1
        if (-not [string]::IsNullOrWhiteSpace($line)) { return ($line | ConvertFrom-Json -ErrorAction Stop) }
    }
    catch {
        Write-Warning "Не удалось прочитать предыдущий снимок диагностики. $($_.Exception.Message)"
    }

    return $null
}

function Add-ChangeColumn {
    param(
        [object[]]$Items,
        $PreviousSnapshot
    )

    $previous = @{}
    if ($null -ne $PreviousSnapshot) {
        foreach ($entry in @($PreviousSnapshot.Items)) {
            $previous[[string]$entry.Key] = [int64]$entry.SizeBytes
        }
    }

    foreach ($item in @($Items)) {
        if (-not $previous.ContainsKey($item.Key)) {
            $item.Change = "первый снимок"
            continue
        }

        $delta = [int64]$item.SizeBytes - [int64]$previous[$item.Key]
        if ($delta -eq 0) {
            $item.Change = "без изменений"
        }
        elseif ($delta -gt 0) {
            $item.Change = ("рост +{0}" -f (Format-ByteSize -Bytes $delta))
        }
        else {
            $item.Change = ("меньше на {0}" -f (Format-ByteSize -Bytes ([Math]::Abs($delta))) )
        }
    }
}

function Save-Snapshot {
    param(
        [string]$HistoryFile,
        [object[]]$Items
    )

    if ([string]::IsNullOrWhiteSpace($HistoryFile)) { return }

    try {
        $snapshot = [pscustomobject]@{
            TimeUtc = (Get-Date).ToUniversalTime().ToString("o")
            Items = @($Items | ForEach-Object {
                [pscustomobject]@{ Key = $_.Key; SizeBytes = [int64]$_.SizeBytes }
            })
        }
        [IO.File]::AppendAllText($HistoryFile, (($snapshot | ConvertTo-Json -Depth 5 -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $lines = @(Get-Content -LiteralPath $HistoryFile -ErrorAction Stop)
        if ($lines.Count -gt 90) {
            [IO.File]::WriteAllLines($HistoryFile, @($lines | Select-Object -Last 90), [Text.UTF8Encoding]::new($false))
        }
    }
    catch {
        Write-Warning "Не удалось сохранить снимок диагностики. $($_.Exception.Message)"
    }
}

function ConvertTo-HtmlText {
    param($Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-HtmlRows {
    param([object[]]$Items)

    $rows = New-Object System.Collections.ArrayList
    foreach ($item in @($Items)) {
        [void]$rows.Add(("<tr><td>{0}</td><td>{1}</td><td class='size'>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td></tr>" -f `
            (ConvertTo-HtmlText $item.Scope), (ConvertTo-HtmlText $item.Name), (ConvertTo-HtmlText $item.Size), `
            (ConvertTo-HtmlText $item.Change), (ConvertTo-HtmlText $item.Action), (ConvertTo-HtmlText $item.Path)))
    }
    return ($rows -join [Environment]::NewLine)
}

function Write-HtmlReport {
    param(
        [object[]]$Items,
        [object[]]$SelectedDrives,
        [string]$Folder,
        [int]$Count
    )

    if ([string]::IsNullOrWhiteSpace($Folder)) { return "" }

    $driveCards = New-Object System.Collections.ArrayList
    foreach ($drive in @($SelectedDrives)) {
        $freePercent = [Math]::Round(($drive.FreeBytes / $drive.TotalBytes) * 100, 1)
        [void]$driveCards.Add(("<section class='metric'><strong>{0}</strong><span>{1} свободно из {2} ({3}%)</span></section>" -f `
            (ConvertTo-HtmlText $drive.Drive), (ConvertTo-HtmlText (Format-ByteSize $drive.FreeBytes)), (ConvertTo-HtmlText (Format-ByteSize $drive.TotalBytes)), $freePercent))
    }

    $largest = @($Items | Sort-Object SizeBytes -Descending | Select-Object -First $Count)
    $cacheItems = @($Items | Where-Object { $_.Scope -eq "Кэш приложений" } | Sort-Object SizeBytes -Descending | Select-Object -First $Count)
    $systemItems = @($Items | Where-Object { $_.Scope -eq "Windows" } | Sort-Object SizeBytes -Descending | Select-Object -First $Count)

    $path = Join-Path $Folder ("space-hogs-{0:yyyy-MM-dd-HHmmss}.html" -f (Get-Date))
    $htmlTemplate = @'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<title>KappaSweep - диагностика места</title>
<style>
body{margin:0;background:#f4f6f8;color:#18212b;font:14px/1.45 Segoe UI,Arial,sans-serif}main{max-width:1280px;margin:0 auto;padding:32px 24px 48px}h1{margin:0 0 6px;font-size:28px}h2{margin:30px 0 10px;font-size:18px}.muted{color:#5f6b76}.metrics{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:10px;margin-top:20px}.metric{background:#fff;border:1px solid #d8dee5;border-radius:6px;padding:14px}.metric strong{display:block;font-size:18px}.metric span{color:#52606d}section.table{background:#fff;border:1px solid #d8dee5;border-radius:6px;overflow:auto}table{width:100%;border-collapse:collapse;min-width:930px}th,td{padding:10px 12px;border-bottom:1px solid #e8edf1;text-align:left;vertical-align:top}th{background:#eef2f5;color:#344250;font-weight:600}.size{white-space:nowrap;font-weight:600}td:last-child{font:12px/1.35 Consolas,monospace;word-break:break-all}.notice{border-left:4px solid #2368a2;background:#eaf3fb;padding:12px 14px;margin-top:18px}.footer{color:#5f6b76;font-size:12px;margin-top:24px}
</style>
</head>
<body><main>
<h1>KappaSweep: куда ушло место</h1>
<p class="muted">Снимок создан __TIME__. Отчёт ничего не удаляет.</p>
<div class="metrics">__DRIVES__</div>
<div class="notice">"Доступно" означает, что для этой категории есть отдельный безопасный переключатель или режим KappaSweep. Личные данные, WinSxS, DriverStore, Docker/WSL и системные файлы отчёт только показывает.</div>
<h2>Главные потребители</h2><section class="table"><table><thead><tr><th>Категория</th><th>Название</th><th>Размер</th><th>С прошлого снимка</th><th>Что делать</th><th>Путь</th></tr></thead><tbody>__LARGEST__</tbody></table></section>
<h2>Кэши приложений</h2><section class="table"><table><thead><tr><th>Категория</th><th>Название</th><th>Размер</th><th>С прошлого снимка</th><th>Что делать</th><th>Путь</th></tr></thead><tbody>__CACHES__</tbody></table></section>
<h2>Windows и системное хранилище</h2><section class="table"><table><thead><tr><th>Категория</th><th>Название</th><th>Размер</th><th>С прошлого снимка</th><th>Что делать</th><th>Путь</th></tr></thead><tbody>__SYSTEM__</tbody></table></section>
<p class="footer">История хранится локально в space-hog-history.jsonl рядом с журналами KappaSweep.</p>
</main></body></html>
'@
    $html = $htmlTemplate.Replace("__TIME__", (Get-Date).ToString("yyyy-MM-dd HH:mm"))
    $html = $html.Replace("__DRIVES__", ($driveCards -join [Environment]::NewLine))
    $html = $html.Replace("__LARGEST__", (Get-HtmlRows $largest))
    $html = $html.Replace("__CACHES__", (Get-HtmlRows $cacheItems))
    $html = $html.Replace("__SYSTEM__", (Get-HtmlRows $systemItems))

    [IO.File]::WriteAllText($path, $html, [Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-ComponentStoreAnalysis {
    $dism = Join-Path $env:SystemRoot "System32\Dism.exe"
    if (-not (Test-Path -LiteralPath $dism -PathType Leaf -ErrorAction SilentlyContinue)) {
        Write-Warning "DISM не найден."
        return
    }

    Write-Host ""
    Write-Host "DISM анализирует хранилище компонентов. Это займёт несколько минут..." -ForegroundColor Green
    & $dism /Online /Cleanup-Image /AnalyzeComponentStore
}

$allFixed = @(Get-FixedDrives)
if ($Drives.Count -eq 0) {
    $selectedDrives = $allFixed
}
else {
    $wanted = @($Drives | ForEach-Object {
        $value = $_.Trim().TrimEnd("\\")
        if ($value.Length -eq 1) { "$value`:" } else { $value }
    })
    $selectedDrives = @($allFixed | Where-Object { $wanted -contains $_.Drive })
}

if ($selectedDrives.Count -eq 0) {
    throw "Не найдены доступные локальные диски для диагностики."
}

$items = New-Object System.Collections.ArrayList
$systemDrive = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) { "C:" } else { $env:SystemDrive.TrimEnd("\\") }
Add-SystemSpaceItems -Items $items -SystemDrive $systemDrive -SelectedDrives $selectedDrives -QuickMode:$Quick
Add-ApplicationSpaceItems -Items $items -QuickMode:$Quick
if (-not $Quick) {
    Add-DriveFolderItems -Items $items -SelectedDrives $selectedDrives -SystemDrive $systemDrive
}

$sortedItems = @($items | Sort-Object SizeBytes -Descending)
if ($NotificationSummary) {
    $summaryItems = @($sortedItems | Where-Object { $_.Scope -in @("Windows", "Кэш приложений") } | Select-Object -First $Top)
    if ($summaryItems.Count -eq 0) {
        Write-Output "нет крупных кэшей; открой Диагностику места"
    }
    else {
        Write-Output (($summaryItems | ForEach-Object { "{0} {1}" -f $_.Name, $_.Size }) -join "; ")
    }
    return
}

$logFolder = Resolve-LogFolder -PreferredLogDir $LogDir
$historyFile = if ($SkipHistory) { "" } else { Resolve-HistoryFile -Folder $logFolder }
$previousSnapshot = Get-LatestSnapshot -HistoryFile $historyFile
Add-ChangeColumn -Items $sortedItems -PreviousSnapshot $previousSnapshot
if (-not $SkipHistory) { Save-Snapshot -HistoryFile $historyFile -Items $sortedItems }

Write-Host ""
Write-Host "== KappaSweep: куда ушло место ==" -ForegroundColor Green
$selectedDrives | ForEach-Object {
    $freePercent = [Math]::Round(($_.FreeBytes / $_.TotalBytes) * 100, 1)
    Write-Host ("{0}: свободно {1} из {2} ({3}%)" -f $_.Drive, (Format-ByteSize $_.FreeBytes), (Format-ByteSize $_.TotalBytes), $freePercent)
}
Write-Host "Режим только читает данные: ничего не удаляется." -ForegroundColor DarkGray
if ($previousSnapshot) { Write-Host "Сравнение выполнено с прошлым снимком." -ForegroundColor DarkGray }
else { Write-Host "Первый снимок сохранён; следующий запуск покажет рост и уменьшение категорий." -ForegroundColor DarkGray }

Write-Host ""
Write-Host "== Главные потребители ==" -ForegroundColor Green
$sortedItems | Select-Object -First $Top Scope, Name, Size, Change, Action, Path | Format-Table -AutoSize

if (-not $Quick) {
    $reportPath = Write-HtmlReport -Items $sortedItems -SelectedDrives $selectedDrives -Folder $logFolder -Count $Top
    if (-not [string]::IsNullOrWhiteSpace($reportPath)) {
        Write-Host ""
        Write-Host "HTML-отчёт: $reportPath" -ForegroundColor Green
        if ($OpenReport) {
            try {
                $chromeOpener = Join-Path $PSScriptRoot "open-report-in-chrome.ps1"
                if (Test-Path -LiteralPath $chromeOpener -PathType Leaf) {
                    & $chromeOpener -Path $reportPath
                }
                else {
                    Start-Process -FilePath $reportPath | Out-Null
                }
            }
            catch { Write-Warning "Не удалось открыть HTML-отчёт." }
        }
    }
}

if ($AnalyzeComponentStore) { Invoke-ComponentStoreAnalysis }

Write-Host ""
Write-Host "Диагностика завершена." -ForegroundColor Green
