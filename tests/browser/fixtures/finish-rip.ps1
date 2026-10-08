<#
.SYNOPSIS
    Finish a seeded rip through the REAL dispatch tail, as if makemkvcon had just returned.

.DESCRIPTION
    Dot-sources src/DiscWatcher.ps1 (functions only) and runs Invoke-VideoDispatch
    with only two seams replaced: Invoke-VideoRip (the rip is already "done": it
    returns the seeded staging dir) and Send-ArmNotification (no toasts). Everything
    after that is production code: Resolve-TitleOverride reads the metadata.json the
    web UI wrote, the staging dir is renamed, and Move-ToNas copies it to the temp
    NAS root. The spec then asserts on the NAS folder name.

.EXAMPLE
    pwsh -NoProfile -File finish-rip.ps1 -ConfigPath C:\t\config.psd1 -JobId 20260101-000000-abcdef
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $ConfigPath,

    [Parameter(Mandatory = $true)]
    [string] $JobId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-sourcing DiscWatcher.ps1 re-runs ITS param block in this scope (clobbering
# $ConfigPath), so keep our own copies under other names first.
$seedConfigPath = $ConfigPath
$seedJobId = $JobId

$repoRoot = Join-Path $PSScriptRoot '..' '..' '..'
. (Join-Path $repoRoot 'src' 'DiscWatcher.ps1')

$config = Import-PowerShellDataFile -Path $seedConfigPath
$job = Get-ArmJob -JobId $seedJobId -Config $config
if (-not $job) { throw "No such job '$seedJobId'" }
$staging = [string]$job.StagingDir

# Seams (defined after the dot-source, so they shadow the real functions).
function Invoke-VideoRip {
    param([char] $DriveLetter, [hashtable] $Config, [string] $JobId)
    $null = $DriveLetter, $Config, $JobId
    $fallback = [pscustomobject]@{ FolderName = 'Fallback Label 2000-01-01'; Matched = $false; Title = $null; Year = $null }
    return [pscustomobject]@{
        Success = $true; DiscLabel = $job.DiscLabel; DiscType = 'DVD'; OutputDir = $staging
        TitleCount = 1; Error = $null; Resolved = $fallback
    }
}
function Send-ArmNotification {
    param($Title, $Message, $Level, $Config)
    $null = $Title, $Message, $Level, $Config
}

Invoke-VideoDispatch -DriveLetter 'D' -Config $config -JobId $seedJobId
