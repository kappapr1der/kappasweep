[CmdletBinding()]
param(
    [string]$DumpFolder = (Join-Path $env:ProgramData 'KappaSweep\Dumps'),

    [ValidateRange(1, 10)]
    [int]$DumpCount = 3,

    [switch]$Disable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    throw 'Run configure-powershell-dumps.ps1 as Administrator.'
}

$registryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\powershell.exe'

if ($Disable) {
    Remove-Item -LiteralPath $registryPath -Recurse -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Status = 'Disabled'
        Process = 'powershell.exe'
        DumpFolder = $DumpFolder
    }
    return
}

$resolvedDumpFolder = [IO.Path]::GetFullPath($DumpFolder)
New-Item -ItemType Directory -Path $resolvedDumpFolder -Force | Out-Null
New-Item -Path $registryPath -Force | Out-Null

New-ItemProperty -Path $registryPath -Name 'DumpFolder' -PropertyType ExpandString -Value $resolvedDumpFolder -Force | Out-Null
New-ItemProperty -Path $registryPath -Name 'DumpCount' -PropertyType DWord -Value $DumpCount -Force | Out-Null
New-ItemProperty -Path $registryPath -Name 'DumpType' -PropertyType DWord -Value 1 -Force | Out-Null

# This folder is dedicated to PowerShell minidumps, so pruning it is safe.
Get-ChildItem -LiteralPath $resolvedDumpFolder -Filter '*.dmp' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $DumpCount |
    Remove-Item -Force -ErrorAction SilentlyContinue

[pscustomobject]@{
    Status = 'Enabled'
    Process = 'powershell.exe'
    DumpType = 'MiniDump'
    DumpFolder = $resolvedDumpFolder
    DumpCount = $DumpCount
}
