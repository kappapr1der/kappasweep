Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $PSScriptRoot '.spotify-cache-guard-fixture'
$fullFixture = [IO.Path]::GetFullPath($fixture)
$fullTests = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
if (-not $fullFixture.StartsWith($fullTests, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test fixture escaped the tests directory.'
}

$oldLocal = $env:LOCALAPPDATA
$oldSystem = $env:SystemRoot
$oldProgramData = $env:ProgramData
$link = Join-Path $fixture 'AppData\Local\Packages\SpotifyAB.SpotifyMusic_zpdnekdrzrea0\LocalCache\Spotify\Data'
$target = Join-Path $fixture 'SpotifyCache\Data'
$other = Join-Path $fixture 'OfflineDownloads\track.bin'

try {
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $link) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $other) -Force | Out-Null
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    [IO.File]::WriteAllText($other, 'keep')
    $env:LOCALAPPDATA = Join-Path $fixture 'AppData\Local'
    $env:SystemRoot = 'D:\Windows'
    $env:ProgramData = Join-Path $fixture 'ProgramData'

    function Get-Process { return $null }

    $file = Join-Path $target 'aa\cache.bin'
    New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
    $stream = [IO.File]::Create($file)
    try { $stream.SetLength(12MB) } finally { $stream.Dispose() }
    & (Join-Path $repo 'spotify-cache-guard.ps1') -ExpectedCachePath $target -MaxGB 0.01 | Out-Null
    if (Test-Path -LiteralPath $file) { throw 'Over-threshold cache file was not removed.' }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw 'Data directory was removed.' }
    if (-not (Test-Path -LiteralPath $link -PathType Container)) { throw 'Spotify junction was removed.' }
    if (([IO.File]::ReadAllText($other)) -ne 'keep') { throw 'Offline file was changed.' }

    New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
    [IO.File]::WriteAllText($file, 'small')
    & (Join-Path $repo 'spotify-cache-guard.ps1') -ExpectedCachePath $target -MaxGB 0.01 | Out-Null
    if (-not (Test-Path -LiteralPath $file)) { throw 'Below-threshold cache file was removed.' }

    function Get-Process { return [pscustomobject]@{ ProcessName = 'Spotify' } }
    & (Join-Path $repo 'spotify-cache-guard.ps1') -ExpectedCachePath $target -MaxGB 0.01 | Out-Null
    if (-not (Test-Path -LiteralPath $file)) { throw 'Open-Spotify cache file was removed.' }

    Write-Host 'Spotify cache guard tests passed.'
}
finally {
    Remove-Item Function:\Get-Process -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $oldLocal
    $env:SystemRoot = $oldSystem
    $env:ProgramData = $oldProgramData
    if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link, $false) }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
