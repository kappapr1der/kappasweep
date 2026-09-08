param([string]$PortableExe = '')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($PortableExe)) { $PortableExe = Join-Path $repo 'dist\KappaSweep-Portable.exe' }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('kappasweep-rebrand-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Invoke-BoundedProcess {
    param([string]$FilePath, [string]$Arguments)
    $info = [Diagnostics.ProcessStartInfo]::new($FilePath, $Arguments)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        if (-not $process.WaitForExit(45000)) {
            $process.Kill()
            throw "Timed out: $FilePath"
        }
        if ($process.ExitCode -ne 0) { throw "Exit $($process.ExitCode): $FilePath" }
    }
    finally { $process.Dispose() }
}

foreach ($scenario in @('fresh', 'upgrade')) {
    $folder = Join-Path $testRoot $scenario
    New-Item -ItemType Directory -Path $folder | Out-Null
    $exe = Join-Path $folder 'KappaSweep.exe'
    Copy-Item -LiteralPath $PortableExe -Destination $exe
    $engineName = if ($scenario -eq 'upgrade') { 'WinSweepData' } else { 'KappaSweepData' }
    $engine = Join-Path $folder $engineName
    if ($scenario -eq 'upgrade') {
        New-Item -ItemType Directory -Path $engine | Out-Null
        $config = Get-Content -Raw (Join-Path $repo 'kappasweep-config.json') | ConvertFrom-Json
        $config.thresholds.minFreeGB = 81
        $config.paths.excludedPaths = @('C:\PreserveMyProjects')
        $config.schedule.guardEveryHours = 6
        $legacy = Join-Path $engine 'winsweep-config.json'
        $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $legacy -Encoding UTF8
        $before = (Get-FileHash -LiteralPath $legacy).Hash
        Set-Content -LiteralPath (Join-Path $engine 'extra-cache-paths.txt') -Value '# custom path rules must survive' -Encoding UTF8
    }
    Invoke-BoundedProcess $exe '--test'
    $configPath = Join-Path $engine 'kappasweep-config.json'
    if (-not (Test-Path -LiteralPath $configPath)) { throw "Config missing: $scenario" }
    if ($scenario -eq 'upgrade') {
        if ((Get-FileHash -LiteralPath $configPath).Hash -ne $before) { throw 'Legacy settings were not imported verbatim.' }
        if ((Get-FileHash -LiteralPath $legacy).Hash -ne $before) { throw 'Original settings were changed.' }
        if (Test-Path -LiteralPath (Join-Path $folder 'KappaSweepData')) { throw 'Upgrade created a second engine.' }
        $config = Get-Content -Raw $configPath | ConvertFrom-Json
        $config.thresholds.minFreeGB = 82
        $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $configPath -Encoding UTF8
        $updatedHash = (Get-FileHash -LiteralPath $configPath).Hash
        Invoke-BoundedProcess $exe '--test'
        if ((Get-FileHash -LiteralPath $configPath).Hash -ne $updatedHash) { throw 'Second start replaced settings.' }
        if ((Get-Content -Raw (Join-Path $engine 'extra-cache-paths.txt')).Trim() -ne '# custom path rules must survive') { throw 'Custom paths were overwritten.' }
        $logs = Join-Path $folder 'Logs'
        $scriptPath = Join-Path $engine 'cleanup-windows.ps1'
        $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Invoke-BoundedProcess $shell "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -Analyze -Quiet -SmartGuard -MinFreeGB 0 -MinFreePercent 0 -ConfigPath `"$legacy`" -LogDir `"$logs`""
        $log = Get-ChildItem -LiteralPath $logs -Filter 'cleanup-*.log' | Select-Object -First 1
        if (-not (Get-Content -Raw $log.FullName).Contains("Config=$configPath ")) { throw 'Legacy scheduled action did not resolve the new config.' }
    }
    Write-Output "PASS: $scenario"
}
$renderPath = Join-Path $testRoot 'kappasweep-ui.png'
Invoke-BoundedProcess (Join-Path $testRoot 'fresh\KappaSweep.exe') "--render-test --render-output `"$renderPath`""
if (-not (Test-Path -LiteralPath $renderPath)) { throw 'No GUI render.' }
Write-Output "PASS: GUI render; screenshot=$renderPath"
Write-Output "Test artifacts: $testRoot"
