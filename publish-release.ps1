[CmdletBinding()]
param(
    [string]$Version = "",
    [string]$Repository = "kappapr1der/kappasweep",
    [string]$Token = "",
    [string]$TargetCommitish = "main",
    [switch]$Prerelease,
    [switch]$Draft,
    [switch]$UpdateExisting,
    [switch]$ReplaceAsset,
    [switch]$SkipTagPush,
    [switch]$Portable,
    [ValidateRange(10, 300)]
    [int]$RequestTimeoutSeconds = 300,
    [ValidateRange(30, 900)]
    [int]$BuildTimeoutSeconds = 300,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSCommandPath
$cleanupScript = Join-Path $root "cleanup-windows.ps1"
$buildScript = Join-Path $root "build-release.ps1"

function Get-KappaSweepVersion {
    param([string]$ScriptPath)

    $text = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
    if ($text -match 'KappaSweepVersion\s*=\s*"([^"]+)"') {
        return $Matches[1]
    }

    throw "Could not read KappaSweepVersion from cleanup-windows.ps1."
}

function Get-PlainTextSecret {
    param([Security.SecureString]$SecureValue)

    if (-not $SecureValue) {
        return ""
    }

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

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

function Get-StoredReleaseToken {
    $path = Get-TokenStorePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ""
    }

    try {
        $encrypted = (Get-Content -LiteralPath $path -Raw -Encoding ASCII).Trim()
        $secure = $encrypted | ConvertTo-SecureString
        $plain = Get-PlainTextSecret -SecureValue $secure
        if (-not [string]::IsNullOrWhiteSpace($plain)) {
            Write-Host "Using saved token from $path."
            return $plain.Trim()
        }
    }
    catch {
        Write-Warning "Saved token exists but could not be decrypted. Run save-github-token.ps1 again."
    }

    return ""
}

function Get-ReleaseToken {
    param([string]$ExplicitToken)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitToken)) {
        return $ExplicitToken.Trim()
    }

    foreach ($name in @("KAPPASWEEP_GITHUB_TOKEN", "WINSWEEP_GITHUB_TOKEN", "GITHUB_TOKEN", "GH_TOKEN")) {
        $value = [Environment]::GetEnvironmentVariable($name, "Process")
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            Write-Host "Using token from $name."
            return $value.Trim()
        }
    }

    $stored = Get-StoredReleaseToken
    if (-not [string]::IsNullOrWhiteSpace($stored)) {
        return $stored
    }

    Write-Host "GitHub token was not found in KAPPASWEEP_GITHUB_TOKEN, GITHUB_TOKEN, or GH_TOKEN."
    Write-Host "Create a fine-grained token with repository Contents: Read and write, then paste it below."
    Write-Host "Tip: run save-github-token.ps1 once to avoid pasting the token every time."
    $secure = Read-Host "GitHub token (hidden)" -AsSecureString
    $plain = Get-PlainTextSecret -SecureValue $secure
    if ([string]::IsNullOrWhiteSpace($plain)) {
        throw "GitHub token is required to publish a release."
    }

    return $plain.Trim()
}

function ConvertTo-ProcessArgumentString {
    param([string[]]$Arguments)

    return (($Arguments | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') {
            '"' + $value.Replace('"', '\"') + '"'
        }
        else {
            $value
        }
    }) -join ' ')
}

function Invoke-GitHubCurl {
    param(
        [ValidateSet("GET", "POST", "PATCH", "DELETE")]
        [string]$Method,
        [string]$Uri,
        [string]$AuthToken,
        [string]$ContentPath = "",
        [string]$ContentType = ""
    )

    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw "curl.exe was not found. Windows includes it by default; install curl or use a supported Windows version."
    }

    if (-not [string]::IsNullOrWhiteSpace($ContentPath) -and -not (Test-Path -LiteralPath $ContentPath -PathType Leaf)) {
        throw "GitHub request content file was not found: $ContentPath"
    }

    $responsePath = [IO.Path]::GetTempFileName()
    $statusPath = [IO.Path]::GetTempFileName()
    $errorPath = [IO.Path]::GetTempFileName()
    $configPath = [IO.Path]::GetTempFileName()
    try {
        $configLines = @(
            'silent'
            'show-error'
            'connect-timeout = 10'
            ("max-time = {0}" -f $RequestTimeoutSeconds)
            ('header = "Authorization: Bearer {0}"' -f $AuthToken)
            'header = "Accept: application/vnd.github+json"'
            'header = "X-GitHub-Api-Version: 2022-11-28"'
            'header = "User-Agent: KappaSweepReleasePublisher"'
        )
        [IO.File]::WriteAllLines($configPath, $configLines, [Text.UTF8Encoding]::new($false))

        $curlArgs = @(
            '--config', $configPath,
            '--request', $Method,
            '--output', $responsePath,
            '--write-out', '%{http_code}'
        )
        if (-not [string]::IsNullOrWhiteSpace($ContentPath)) {
            $curlArgs += @('--header', "Content-Type: $ContentType", '--data-binary', "@$ContentPath")
        }
        $curlArgs += $Uri

        $process = Start-Process `
            -FilePath 'curl.exe' `
            -ArgumentList (ConvertTo-ProcessArgumentString $curlArgs) `
            -PassThru `
            -WindowStyle Hidden `
            -RedirectStandardOutput $statusPath `
            -RedirectStandardError $errorPath
        $waitMilliseconds = [Math]::Min(305000, ($RequestTimeoutSeconds + 5) * 1000)
        if (-not $process.WaitForExit($waitMilliseconds)) {
            & taskkill.exe /PID $process.Id /T /F | Out-Null
            throw "GitHub API $Method timed out after $RequestTimeoutSeconds seconds. The request process tree was stopped."
        }
        # Finish stream redirection before reading the status file.
        $process.WaitForExit()

        $statusText = [IO.File]::ReadAllText($statusPath, [Text.UTF8Encoding]::new($false)).Trim()
        $errorText = [IO.File]::ReadAllText($errorPath, [Text.UTF8Encoding]::new($false)).Trim()
        $responseText = [IO.File]::ReadAllText($responsePath, [Text.UTF8Encoding]::new($false))

        [int]$statusCode = 0
        if (-not [int]::TryParse($statusText, [ref]$statusCode)) {
            throw "GitHub API $Method $Uri did not return an HTTP status code. $errorText $responseText"
        }

        return [pscustomobject]@{
            StatusCode = $statusCode
            BodyText   = $responseText
        }
    }
    finally {
        foreach ($path in @($responsePath, $statusPath, $errorPath, $configPath)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-ReleaseBuild {
    param(
        [string]$ScriptPath,
        [string]$BuildVersion,
        [switch]$BuildPortable
    )

    $outputPath = [IO.Path]::GetTempFileName()
    $errorPath = [IO.Path]::GetTempFileName()
    try {
        $buildArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-Version', $BuildVersion)
        if ($BuildPortable) {
            $buildArgs += '-Portable'
        }

        $process = Start-Process `
            -FilePath 'powershell.exe' `
            -ArgumentList (ConvertTo-ProcessArgumentString $buildArgs) `
            -PassThru `
            -WindowStyle Hidden `
            -RedirectStandardOutput $outputPath `
            -RedirectStandardError $errorPath
        if (-not $process.WaitForExit($BuildTimeoutSeconds * 1000)) {
            & taskkill.exe /PID $process.Id /T /F | Out-Null
            throw "Release build timed out after $BuildTimeoutSeconds seconds. The build process tree was stopped."
        }
        $process.WaitForExit()

        $output = [IO.File]::ReadAllText($outputPath, [Text.UTF8Encoding]::new($false)).Trim()
        $error = [IO.File]::ReadAllText($errorPath, [Text.UTF8Encoding]::new($false)).Trim()
        if (-not [string]::IsNullOrWhiteSpace($output)) { Write-Host $output }
        # Windows PowerShell can expose a null ExitCode for a successful .ps1 child.
        if ($null -ne $process.ExitCode -and $process.ExitCode -ne 0) {
            throw "Release build failed with exit code $($process.ExitCode). $error"
        }
    }
    finally {
        Remove-Item -LiteralPath $outputPath, $errorPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-GitHubJson {
    param(
        [ValidateSet("GET", "POST", "PATCH", "DELETE")]
        [string]$Method,
        [string]$Uri,
        [string]$AuthToken,
        $Body = $null,
        [switch]$AllowNotFound
    )

    $bodyPath = ""
    try {
        if ($null -ne $Body) {
            $bodyPath = [IO.Path]::GetTempFileName()
            $json = $Body | ConvertTo-Json -Depth 12
            [IO.File]::WriteAllText($bodyPath, $json, [Text.UTF8Encoding]::new($false))
        }

        $response = Invoke-GitHubCurl `
            -Method $Method `
            -Uri $Uri `
            -AuthToken $AuthToken `
            -ContentPath $bodyPath `
            -ContentType "application/json"

        if ($AllowNotFound -and $response.StatusCode -eq 404) {
            return $null
        }
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            throw "GitHub API $Method $Uri failed ($($response.StatusCode)) $($response.BodyText)"
        }
        if ([string]::IsNullOrWhiteSpace($response.BodyText)) {
            return $null
        }
        return $response.BodyText | ConvertFrom-Json
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($bodyPath)) {
            Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-GitHubUpload {
    param(
        [string]$Uri,
        [string]$AuthToken,
        [string]$FilePath
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Release asset was not found: $FilePath"
    }

    $response = Invoke-GitHubCurl `
        -Method "POST" `
        -Uri $Uri `
        -AuthToken $AuthToken `
        -ContentPath $FilePath `
        -ContentType "application/zip"

    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "GitHub release asset upload failed ($($response.StatusCode)) $($response.BodyText)"
    }

    return $response.BodyText | ConvertFrom-Json
}

if (-not (Test-Path -LiteralPath $cleanupScript -PathType Leaf)) {
    throw "cleanup-windows.ps1 was not found next to this file."
}

if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
    throw "build-release.ps1 was not found next to this file."
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = Get-KappaSweepVersion -ScriptPath $cleanupScript
}

$Version = $Version.Trim().TrimStart("v")
if ($Version -notmatch '^\d+\.\d+\.\d+([.-][A-Za-z0-9.-]+)?$') {
    throw "Version should look like 0.4.3 or v0.4.3. Got: $Version"
}

if ([string]::IsNullOrWhiteSpace($Repository) -or $Repository -notmatch '^[^/\s]+/[^/\s]+$') {
    throw "Repository should look like owner/name. Got: $Repository"
}

$tag = "v$Version"
$assetPrefix = if ($Portable) { "KappaSweep-Portable" } else { "KappaSweep" }
$releaseTitle = if ($Portable) { "KappaSweep $tag - Portable" } else { "KappaSweep $tag" }
$zipPath = Join-Path $root ("dist\{0}-v{1}.zip" -f $assetPrefix, $Version)
$notesPath = Join-Path $root "release-notes.md"
$assetName = Split-Path -Leaf $zipPath

if ($SkipTagPush) {
    Write-Host "Note: -SkipTagPush is no longer needed. The GitHub Releases API creates or reuses the tag."
}

Invoke-ReleaseBuild -ScriptPath $buildScript -BuildVersion $Version -BuildPortable:$Portable

if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
    throw "Release zip was not created: $zipPath"
}

$highlights = @(Get-Content -LiteralPath (Join-Path $root 'release-highlights.md') -Encoding UTF8 -ErrorAction Stop)

@(
    $releaseTitle,
    "",
    "Скачайте $assetName, распакуйте архив и запустите KappaSweep.exe.",
    "",
    "Что нового:"
) + $highlights | Set-Content -LiteralPath $notesPath -Encoding UTF8

Write-Host ""
Write-Host "Release asset:"
Write-Host $zipPath
Write-Host ""

if ($DryRun) {
    Write-Host "Dry run only. No GitHub release was created."
    Write-Host "Would publish $assetName to https://github.com/$Repository/releases using target $TargetCommitish."
    exit 0
}

$releaseToken = Get-ReleaseToken -ExplicitToken $Token
$apiRoot = "https://api.github.com/repos/$Repository"
$releaseByTagUri = "$apiRoot/releases/tags/$tag"
Write-Host "Checking GitHub release: $tag"
$release = Invoke-GitHubJson -Method GET -Uri $releaseByTagUri -AuthToken $releaseToken -AllowNotFound
$notes = [IO.File]::ReadAllText($notesPath, [Text.UTF8Encoding]::new($false))

if ($release) {
    Write-Host "Release already exists: $tag"
    if ($UpdateExisting) {
        Write-Host "Updating release metadata..."
        $release = Invoke-GitHubJson `
            -Method PATCH `
            -Uri "$apiRoot/releases/$($release.id)" `
            -AuthToken $releaseToken `
            -Body @{
                name       = $releaseTitle
                body       = $notes
                draft      = [bool]$Draft
                prerelease = [bool]$Prerelease
            }
    }
    else {
        Write-Host "Keeping existing release title and notes. Use -UpdateExisting to change them."
    }
}
else {
    Write-Host "Creating release: $tag"
    $release = Invoke-GitHubJson `
        -Method POST `
        -Uri "$apiRoot/releases" `
        -AuthToken $releaseToken `
        -Body @{
            tag_name               = $tag
            target_commitish       = $TargetCommitish
            name                   = $releaseTitle
            body                   = $notes
            draft                  = [bool]$Draft
            prerelease             = [bool]$Prerelease
            generate_release_notes = $false
        }
}

Write-Host "Checking release assets..."
$assets = Invoke-GitHubJson -Method GET -Uri "$apiRoot/releases/$($release.id)/assets?per_page=100" -AuthToken $releaseToken
$assetAlreadyExists = $false
foreach ($asset in @($assets)) {
    if ($asset.name -eq $assetName) {
        if ($ReplaceAsset) {
            Write-Host "Replacing existing asset: $assetName"
            Invoke-GitHubJson -Method DELETE -Uri "$apiRoot/releases/assets/$($asset.id)" -AuthToken $releaseToken | Out-Null
        }
        else {
            $assetAlreadyExists = $true
            Write-Host "Asset already exists: $assetName"
        }
    }
}

$uploadedAsset = $null
if (-not $assetAlreadyExists -or $ReplaceAsset) {
    Write-Host "Uploading release asset: $assetName"
    $encodedAssetName = [Uri]::EscapeDataString($assetName)
    $uploadUri = "https://uploads.github.com/repos/$Repository/releases/$($release.id)/assets?name=$encodedAssetName"
    $uploadedAsset = Invoke-GitHubUpload -Uri $uploadUri -AuthToken $releaseToken -FilePath $zipPath
}

Write-Host ""
Write-Host "Release published:"
Write-Host $release.html_url
if ($uploadedAsset) {
    Write-Host ""
    Write-Host "Asset:"
    Write-Host $uploadedAsset.browser_download_url
}
