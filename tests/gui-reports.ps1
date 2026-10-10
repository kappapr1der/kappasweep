[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputFolder)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$OutputFolder = [IO.Path]::GetFullPath($OutputFolder)
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
function Import-Function($File, $Name) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($File, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
    if ($null -eq $definition) { throw "Missing function: $Name" }
    . ([scriptblock]::Create($definition.Extent.Text))
    Set-Item -Path "Function:script:$Name" -Value (Get-Item "Function:$Name").ScriptBlock
}
Import-Function (Join-Path $root 'cleanup-windows.ps1') 'Write-HtmlReport'
function Write-Log { param($Message) }
function Get-ProfileName { 'Safe' }
function Format-ByteSize { param($Bytes) "$Bytes bytes" }
function ConvertTo-HtmlText { param($Value) [Net.WebUtility]::HtmlEncode([string]$Value) }
function Get-HtmlRows { param($Rows) '' }
$LogDir = $OutputFolder
$LogStamp = 'fixture'
$LogFile = Join-Path $OutputFolder 'cleanup-fixture.log'
$OpenReport = $false
$Quiet = $true
$script:KappaSweepVersion = '1.3.2'
$script:TargetResults = @([pscustomobject]@{ Label='Кэш приложения'; Bytes=[int64]1024; Items=2; Status='would clean'; Path='D:\Cache' })
$script:PreflightResults = @()
$script:CloseHints = @{ 'Close Spotify before cleanup.' = $true }
$snapshot = [pscustomobject]@{ FreeBytes=[int64]4096; FreePercent=20 }
Write-HtmlReport -Mode Analyze -Before $snapshot -After $snapshot -SummaryLines @('test')
$jsonPath = Join-Path $OutputFolder 'Reports\report-fixture.json'
$report = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($report.schemaVersion -ne 1 -or $report.totalBytes -ne 1024 -or $report.results[0].Label -ne 'Кэш приложения' -or $report.mode -ne 'Analyze') { throw 'JSON report failed.' }
'GUI_REPORT_WRITER_OK'
