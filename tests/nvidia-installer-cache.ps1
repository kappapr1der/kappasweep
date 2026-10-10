$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'nvidia-installer-cache.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('kappasweep-nvidia-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$script:Busy = $false
$script:Installed = @('610.47')
function Get-NvidiaInstalledVersions { return $script:Installed }
function Test-NvidiaUpdateBusy { return $script:Busy }
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function New-Fixture([string]$Name) {
    $root = Join-Path $testRoot $Name
    $status = Join-Path $root 'status\grd'
    New-Item -ItemType Directory -Path $status -Force | Out-Null
    $downloads = @(); $processing = @(); $oldPaths = @()
    $versions = @('610.47','616.64','616.92')
    for ($i=0; $i -lt 3; $i++) {
        $id = ([string][char](97+$i))*32
        $dir = Join-Path $root ('ota-artifacts\grd\'+$id)
        $extracted = Join-Path $root ('ota-artifacts\grd\post-processing\'+$id)
        New-Item -ItemType Directory -Path $dir,$extracted -Force | Out-Null
        $exe = Join-Path $dir ($versions[$i]+'-desktop-win10-win11-64bit-international-dch-whql-g.exe')
        $setup = Join-Path $extracted 'setup.exe'
        [IO.File]::WriteAllText($exe, 'fixture-archive')
        [IO.File]::WriteAllText($setup, 'fixture-extracted')
        $downloads += [pscustomobject]@{taskId=$id;version=$versions[$i];state=8;percentComplete=100;errorCode=0;fileLocation=$exe}
        $processing += [pscustomobject]@{taskId=$id;status=1;postProcessingInput=$exe;taskOutput=$setup;actions=@(@{status=2})}
        if($i -eq 1) { $oldPaths=@($dir,$extracted) }
    }
    $downloadPath = Join-Path $status 'download.json'
    $processingPath = Join-Path $status 'postprocessing.json'
    $downloads | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $downloadPath -Encoding UTF8
    $processing | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $processingPath -Encoding UTF8
    Get-ChildItem -LiteralPath (Join-Path $root 'ota-artifacts') -Recurse -Force | ForEach-Object {
        $_.CreationTime=(Get-Date).AddDays(-3); $_.LastWriteTime=(Get-Date).AddDays(-3)
    }
    [pscustomobject]@{Root=$root;Downloads=$downloads;Processing=$processing;DownloadPath=$downloadPath;ProcessingPath=$processingPath;OldPaths=$oldPaths}
}

$f=New-Fixture 'preview'
$r=@(Invoke-NvidiaInstallerCache -UpdateRoot $f.Root)
Assert (@($r | Where-Object Status -eq 'would clean').Count -eq 1) ('Preview must select only one superseded package: ' + ($r | ConvertTo-Json -Compress))
Assert (@($r | Where-Object Status -eq 'kept').Count -eq 2) 'Installed and latest packages must be retained.'
Assert (Test-Path -LiteralPath $f.OldPaths[0]) 'Preview deleted files.'
'PASS: preview and retention'

$f=New-Fixture 'delete'
$r=@(Invoke-NvidiaInstallerCache -UpdateRoot $f.Root -Apply)
Assert (($r | Where-Object Version -eq '616.64').Items -eq 2) 'Cleanup did not remove the expected files.'
Assert (-not (Test-Path -LiteralPath $f.OldPaths[0])) 'Obsolete archive was retained.'
Assert (-not (Test-Path -LiteralPath $f.OldPaths[1])) 'Obsolete extraction was retained.'
Assert (Test-Path -LiteralPath $f.Downloads[0].fileLocation) 'Installed package was deleted.'
Assert (Test-Path -LiteralPath $f.Downloads[2].fileLocation) 'Latest package was deleted.'
'PASS: exact package deletion'
$repeat=@(Invoke-NvidiaInstallerCache -UpdateRoot $f.Root -Apply)
Assert (($repeat | Where-Object Version -eq '616.64').Status -eq 'missing') 'Repeated cleanup must skip an absent package.'
'PASS: repeat is a no-op'

foreach($case in @('busy','incomplete','malformed','traversal','recent','excluded','reparse','multi-gpu')) {
    $f=New-Fixture $case
    $excluded=@()
    switch($case) {
        'busy' { $script:Busy=$true }
        'incomplete' { $f.Downloads[1].state=4; $f.Downloads | ConvertTo-Json -Depth 6 | Set-Content $f.DownloadPath -Encoding UTF8 }
        'malformed' { Set-Content -LiteralPath $f.ProcessingPath -Value '{' }
        'traversal' { $f.Downloads[1].fileLocation='C:\Windows\System32\not-a-cache.exe'; $f.Downloads | ConvertTo-Json -Depth 6 | Set-Content $f.DownloadPath -Encoding UTF8 }
        'recent' { (Get-Item -LiteralPath $f.Downloads[1].fileLocation).CreationTime=Get-Date }
        'excluded' { $excluded=@((Join-Path $f.OldPaths[1] 'setup.exe')) }
        'reparse' {
            $outside=Join-Path $testRoot 'protected'
            New-Item -ItemType Directory -Path $outside -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'),'preserve')
            New-Item -ItemType Junction -Path (Join-Path $f.OldPaths[1] 'link') -Target $outside | Out-Null
        }
        'multi-gpu' { $script:Installed=@('610.47','616.64') }
    }
    $r=@(Invoke-NvidiaInstallerCache -UpdateRoot $f.Root -ExcludedPaths $excluded -Apply)
    Assert (Test-Path -LiteralPath $f.Downloads[0].fileLocation) "$case removed installed files."
    Assert (Test-Path -LiteralPath (Join-Path $f.OldPaths[1] 'setup.exe')) "$case bypassed a safety guard."
    Assert (@($r | Where-Object Status -in @('cleaned','partial')).Count -eq 0) "$case performed cleanup."
    $script:Busy=$false; $script:Installed=@('610.47')
    "PASS: $case"
}
"Test artifacts: $testRoot"
