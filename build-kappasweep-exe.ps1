[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PayloadRoot,
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    [switch]$Portable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSCommandPath
$launcherRoot = Join-Path $root "launcher"
$project = Join-Path $launcherRoot "KappaSweepLauncher.csproj"
$program = Join-Path $launcherRoot "Program.cs"
$icon = Join-Path $launcherRoot "assets\kappasweep.ico"
$payloadRootFull = [IO.Path]::GetFullPath($PayloadRoot)
$outputFull = [IO.Path]::GetFullPath($OutputPath)

if (-not (Test-Path -LiteralPath $project -PathType Leaf)) {
    throw "Launcher project was not found: $project"
}
if (-not (Test-Path -LiteralPath $program -PathType Leaf)) {
    throw "Launcher source was not found: $program"
}
if (-not (Test-Path -LiteralPath $icon -PathType Leaf)) {
    throw "Launcher icon was not found: $icon"
}
if (-not (Test-Path -LiteralPath $payloadRootFull -PathType Container)) {
    throw "Payload root was not found: $payloadRootFull"
}
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($null -eq $dotnet) {
    throw "dotnet SDK 8 or newer was not found. Install the .NET 8 SDK to build KappaSweep.exe."
}

$buildRoot = Join-Path $root ".launcher-build"
$payloadZip = Join-Path $launcherRoot "KappaSweepPayload.zip"
$publishRoot = Join-Path $buildRoot "publish"
$builtExe = Join-Path $publishRoot "KappaSweep.exe"

if (Test-Path -LiteralPath $buildRoot) {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
if (Test-Path -LiteralPath $payloadZip) {
    Remove-Item -LiteralPath $payloadZip -Force
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory(
    $payloadRootFull,
    $payloadZip,
    [IO.Compression.CompressionLevel]::Optimal,
    $false)

try {
    $publishArguments = @(
        "publish",
        $project,
        "--configuration", "Release",
        "--runtime", "win-x64",
        "--self-contained", "true",
        "--output", $publishRoot,
        "-p:PublishSingleFile=true",
        "-p:IncludeNativeLibrariesForSelfExtract=true",
        "-p:EnableCompressionInSingleFile=true",
        "-p:BaseIntermediateOutputPath=$buildRoot\obj\",
        "-p:BaseOutputPath=$buildRoot\bin\"
    )
    if ($Portable) {
        $publishArguments += "-p:PortableBuild=true"
    }

    & $dotnet.Source @publishArguments
    if ($LASTEXITCODE -ne 0) {
        throw ".NET 8 publication failed with exit code $LASTEXITCODE."
    }

    if (-not (Test-Path -LiteralPath $builtExe -PathType Leaf)) {
        throw "C# compilation did not produce KappaSweep.exe."
    }

    $outputDirectory = Split-Path -Parent $outputFull
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    Copy-Item -LiteralPath $builtExe -Destination $outputFull -Force
    Write-Host "KappaSweep.exe created:"
    Write-Host $outputFull
}
finally {
    if (Test-Path -LiteralPath $payloadZip) {
        Remove-Item -LiteralPath $payloadZip -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $buildRoot) {
        Remove-Item -LiteralPath $buildRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
