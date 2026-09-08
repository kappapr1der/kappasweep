[CmdletBinding()]
param(
    [string]$Token = "",
    [switch]$Clear,
    [switch]$ShowPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-TokenStorePath {
    $base = [Environment]::GetFolderPath("ApplicationData")
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = Join-Path $HOME "AppData\Roaming"
    }

    $current = Join-Path (Join-Path $base "KappaSweep") "github-token.txt"
    $legacy = Join-Path (Join-Path $base "WinSweep") "github-token.txt"
    if (-not (Test-Path -LiteralPath $current) -and (Test-Path -LiteralPath $legacy -PathType Leaf)) {
        return $legacy
    }
    return $current
}

$path = Get-TokenStorePath

if ($ShowPath) {
    Write-Host $path
    exit 0
}

if ($Clear) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
        Write-Host "Saved GitHub token removed:"
        Write-Host $path
    }
    else {
        Write-Host "No saved GitHub token was found:"
        Write-Host $path
    }
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    Write-Host "Paste a GitHub fine-grained token with Contents: Read and write for kappapr1der/kappasweep."
    Write-Host "The token will be encrypted for this Windows user with DPAPI and saved outside the repository."
    $secure = Read-Host "GitHub token (hidden)" -AsSecureString
}
else {
    $secure = ConvertTo-SecureString -String $Token -AsPlainText -Force
}

if ($null -eq $secure -or $secure.Length -eq 0) {
    throw "No token was entered. Paste the token into the hidden prompt, then press Enter."
}

$dir = Split-Path -Parent $path
New-Item -ItemType Directory -Path $dir -Force | Out-Null

$encrypted = ConvertFrom-SecureString -SecureString $secure
[IO.File]::WriteAllText($path, $encrypted, [Text.Encoding]::ASCII)

Write-Host "GitHub token saved:"
Write-Host $path
Write-Host "It is encrypted for the current Windows user and is not stored in the repository."
