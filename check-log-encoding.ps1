[CmdletBinding()]
param(
    [string]$LogDir = "",
    [int]$Top = 50
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$encodingHelper = Join-Path $PSScriptRoot "kappasweep-encoding.ps1"
if (Test-Path -LiteralPath $encodingHelper -PathType Leaf) {
    . $encodingHelper
}

function Resolve-LogDir {
    param([string]$Preferred)

    if (-not [string]::IsNullOrWhiteSpace($Preferred)) {
        return [Environment]::ExpandEnvironmentVariables($Preferred)
    }

    $candidates = @(
        (Join-Path $env:ProgramData "CodexWindowsCleanup\Logs"),
        (Join-Path $env:TEMP "CodexWindowsCleanup\Logs")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return $candidate
        }
    }

    return $candidates[0]
}

function Test-Utf8File {
    param([IO.FileInfo]$File)

    $bytes = [IO.File]::ReadAllBytes($File.FullName)
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $valid = $true
    $text = ""
    try {
        $text = $utf8.GetString($bytes)
    }
    catch {
        $valid = $false
    }

    $replacementCount = 0
    $nullCount = 0
    foreach ($character in $text.ToCharArray()) {
        if ([int]$character -eq 0xFFFD) {
            $replacementCount++
        }
        if ([int]$character -eq 0) {
            $nullCount++
        }
    }

    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $status = if (-not $valid) { "INVALID_UTF8" } elseif ($replacementCount -gt 0 -or $nullCount -gt 0) { "SUSPICIOUS" } else { "OK" }

    [pscustomobject]@{
        File          = $File.FullName
        Size          = $File.Length
        Utf8          = $valid
        Bom           = $bom
        Replacement   = $replacementCount
        NullCharacters = $nullCount
        Status        = $status
    }
}

$resolvedLogDir = Resolve-LogDir -Preferred $LogDir
Write-Host "== KappaSweep: проверка кодировки логов ==" -ForegroundColor Green
Write-Host "Папка: $resolvedLogDir" -ForegroundColor DarkGray

if (-not (Test-Path -LiteralPath $resolvedLogDir -PathType Container)) {
    Write-Host "Логи пока не найдены." -ForegroundColor Yellow
    exit 0
}

$allFiles = @(Get-ChildItem -LiteralPath $resolvedLogDir -Recurse -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending)
$files = @()
foreach ($file in $allFiles) {
    if (@(".log", ".html", ".jsonl") -notcontains $file.Extension.ToLowerInvariant()) {
        continue
    }
    $files += $file
    if ($files.Count -ge $Top) {
        break
    }
}

if ($files.Count -eq 0) {
    Write-Host "Подходящие лог-файлы не найдены." -ForegroundColor Yellow
    exit 0
}

$results = @()
foreach ($file in $files) {
    $results += Test-Utf8File -File $file
}
$bad = @()
foreach ($result in $results) {
    if ($result.Status -ne "OK") {
        $bad += $result
    }
}
$results | Select-Object Status, Utf8, Bom, Replacement, NullCharacters, File | Format-Table -AutoSize

if ($bad.Count -eq 0) {
    Write-Host "Проверено: $($results.Count). Все файлы читаются как UTF-8." -ForegroundColor Green
    exit 0
}

Write-Warning "Проблемные или подозрительные файлы: $($bad.Count). Новые логи KappaSweep не переписывались автоматически."
exit 1
