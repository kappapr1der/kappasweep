[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$DisableHibernation,
    [switch]$EnableHibernation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$encodingHelper = Join-Path $PSScriptRoot "kappasweep-encoding.ps1"
if (Test-Path -LiteralPath $encodingHelper -PathType Leaf) {
    . $encodingHelper
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-HibernationState {
    if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) {
        $drive = "C:"
    }
    else {
        $drive = $env:SystemDrive.TrimEnd([char]92)
    }

    $file = Join-Path ($drive + [char]92) "hiberfil.sys"
    $size = [int64]0
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        $size = [int64](Get-Item -LiteralPath $file).Length
    }

    if ($size -ge 1GB) {
        $sizeText = "{0:N2} GB" -f ($size / 1GB)
    }
    elseif ($size -ge 1MB) {
        $sizeText = "{0:N2} MB" -f ($size / 1MB)
    }
    else {
        $sizeText = "{0:N0} KB" -f ($size / 1KB)
    }

    [pscustomobject]@{
        Path       = $file
        Exists     = $size -gt 0
        SizeBytes  = $size
        Size       = $sizeText
    }
}

if (-not $Status -and -not $DisableHibernation -and -not $EnableHibernation) {
    $Status = $true
}

$before = Get-HibernationState
Write-Host "== KappaSweep: системные настройки ==" -ForegroundColor Green
Write-Host ("Файл гибернации: {0} ({1})" -f $before.Path, $before.Size)
Write-Host "Отключение убирает hiberfil.sys и Fast Startup. Действие обратимо кнопкой включения." -ForegroundColor DarkGray

if ($DisableHibernation -or $EnableHibernation) {
    if (-not (Test-IsAdministrator)) {
        throw "Для изменения гибернации нужны права администратора."
    }

    $powercfg = Join-Path $env:SystemRoot "System32\powercfg.exe"
    if (-not (Test-Path -LiteralPath $powercfg -PathType Leaf)) {
        throw "powercfg.exe не найден: $powercfg"
    }

    if ($DisableHibernation) {
        $mode = "off"
    }
    else {
        $mode = "on"
    }
    & $powercfg /hibernate $mode
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg завершился с кодом $LASTEXITCODE."
    }

    $after = Get-HibernationState
    if ($DisableHibernation) {
        Write-Host "Гибернация отключена. Освобождение места произойдёт после удаления hiberfil.sys системой." -ForegroundColor Green
    }
    else {
        Write-Host "Гибернация включена. Windows снова создаст hiberfil.sys при необходимости." -ForegroundColor Green
    }
    Write-Host ("Текущий размер файла: {0}" -f $after.Size)
}
else {
    Write-Host "Изменений не применялось." -ForegroundColor DarkGray
}
