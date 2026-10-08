<#
.SYNOPSIS
    Seed web-UI state for Playwright specs through the real JobState.ps1 library.

.DESCRIPTION
    Called by the specs (fixtures/seed.ts) via child_process. Properties are passed
    as base64-encoded JSON so titles like '<img src=x onerror=alert(1)>' survive
    Windows command-line quoting untouched.

    -Action Reset   Delete every job record, today's log, and the queue/staging contents.
    -Action New     New-ArmJob -Kind <Kind> -Properties <decoded>; writes the JobId to stdout.
    -Action Update  Update-ArmJob -JobId <JobId> -Properties <decoded>.
    -Action NewRip  A Rip job (default State Ripping, DiscType DVD) plus the staging dir
                    <StagingDir>\<DiscLabel>\ holding a stub mkv and metadata.json built from
                    the MetaTitle / MetaYear payload keys. Writes {JobId;StagingDir} to stdout.
    -Action Log     Replace today's wrm-<yyyyMMdd>.log with the decoded JSON string array.
    -Action NewUpscale
                    An Upscale job plus everything the worker would have left on disk:
                    a stub source mkv in <NasVideoPath>\<Title>\title1.mkv (DestDir =
                    that folder) and the queue file <UpscaleQueueDir>\<Title><QueueExtension>
                    ({Source;DestDir;JobId}, plus SampleGenerated=true unless the
                    extension is .json). Writes {JobId;QueueFile;DestDir;Source} as
                    one JSON line to stdout.

.EXAMPLE
    pwsh -NoProfile -File seed.ps1 -ConfigPath C:\t\config.psd1 -Action New -Kind Rip -PropertiesB64 eyJTdGF0ZSI6IlJpcHBpbmcifQ==
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $ConfigPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Reset', 'New', 'Update', 'Log', 'NewUpscale', 'NewRip')]
    [string] $Action,

    [ValidateSet('Rip', 'Upscale')]
    [string] $Kind,

    [string] $JobId,

    [string] $PropertiesB64,

    [ValidateSet('.json', '.awaiting-review', '.failed')]
    [string] $QueueExtension = '.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Join-Path $PSScriptRoot '..' '..' '..'
. (Join-Path $repoRoot 'src' 'Common.ps1')
. (Join-Path $repoRoot 'src' 'JobState.ps1')

# Import directly (not Get-ArmConfig): the temp config has no example beside it,
# and Get-ArmConfig would print a WARN to stdout, which carries the JobId.
$config = Import-PowerShellDataFile -Path $ConfigPath

function ConvertFrom-SeedPayload {
    if (-not $PropertiesB64) { return $null }
    $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($PropertiesB64))
    return ($json | ConvertFrom-Json -AsHashtable)
}

switch ($Action) {
    'Reset' {
        foreach ($dir in @((Join-Path $config.StateDir 'jobs'), $config.UpscaleQueueDir, $config.StagingDir)) {
            if (Test-Path -LiteralPath $dir) {
                Get-ChildItem -LiteralPath $dir -Force | Remove-Item -Recurse -Force
            }
        }
        $log = Join-Path $config.LogDir "wrm-$(Get-Date -Format 'yyyyMMdd').log"
        if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
    }
    'New' {
        if (-not $Kind) { throw '-Kind is required for -Action New' }
        $props = ConvertFrom-SeedPayload
        if ($null -eq $props) { $props = @{} }
        $id = New-ArmJob -Kind $Kind -Properties $props -Config $config
        if (-not $id) { throw 'New-ArmJob returned no id' }
        Write-Output $id
    }
    'Update' {
        $props = ConvertFrom-SeedPayload
        if (-not (Update-ArmJob -JobId $JobId -Properties $props -Config $config)) {
            throw "Update-ArmJob failed for '$JobId'"
        }
    }
    'NewUpscale' {
        $props = ConvertFrom-SeedPayload
        if ($null -eq $props) { $props = @{} }
        $title = if ($props['Title']) { [string]$props['Title'] } else { 'Seeded Movie (2020)' }
        $safe = ConvertTo-ArmSafeFileName -Name $title
        $destDir = Join-Path $config.NasVideoPath $safe
        $null = New-Item -ItemType Directory -Force -Path $destDir
        $source = Join-Path $destDir 'title1.mkv'
        [System.IO.File]::WriteAllBytes($source, (New-Object byte[] 4096))

        $queueFile = Join-Path $config.UpscaleQueueDir "$safe$QueueExtension"
        $props['QueueFile'] = $queueFile
        $props['DestDir'] = $destDir
        $id = New-ArmJob -Kind Upscale -Properties $props -Config $config
        if (-not $id) { throw 'New-ArmJob returned no id' }

        $item = [ordered]@{ Source = $source; DestDir = $destDir; JobId = $id }
        if ($QueueExtension -ne '.json') { $item.SampleGenerated = $true }
        $null = New-Item -ItemType Directory -Force -Path $config.UpscaleQueueDir
        $item | ConvertTo-Json | Set-Content -LiteralPath $queueFile -Encoding utf8

        Write-Output (@{ JobId = $id; QueueFile = $queueFile; DestDir = $destDir; Source = $source } | ConvertTo-Json -Compress)
    }
    'NewRip' {
        $props = ConvertFrom-SeedPayload
        if ($null -eq $props) { $props = @{} }
        $label = if ($props['DiscLabel']) { [string]$props['DiscLabel'] } else { 'SEEDED_DISC' }
        $metaTitle = if ($props.ContainsKey('MetaTitle')) { [string]$props['MetaTitle'] } else { '' }
        $metaYear = if ($props.ContainsKey('MetaYear')) { [string]$props['MetaYear'] } else { '' }
        $props.Remove('MetaTitle')
        $props.Remove('MetaYear')

        $staging = Join-Path $config.StagingDir (ConvertTo-ArmSafeFileName -Name $label)
        $null = New-Item -ItemType Directory -Force -Path $staging
        [System.IO.File]::WriteAllBytes((Join-Path $staging 'title_t00.mkv'), (New-Object byte[] 4096))
        @{ Title = $metaTitle; Year = $metaYear } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $staging 'metadata.json') -Encoding utf8

        $props['StagingDir'] = $staging
        $props['DiscLabel'] = $label
        if (-not $props.ContainsKey('DiscType')) { $props['DiscType'] = 'DVD' }
        if (-not $props.ContainsKey('State')) { $props['State'] = 'Ripping' }
        $id = New-ArmJob -Kind Rip -Properties $props -Config $config
        if (-not $id) { throw 'New-ArmJob returned no id' }
        Write-Output (@{ JobId = $id; StagingDir = $staging } | ConvertTo-Json -Compress)
    }
    'Log' {
        $lines = @(ConvertFrom-SeedPayload)
        $null = New-Item -ItemType Directory -Force -Path $config.LogDir
        $log = Join-Path $config.LogDir "wrm-$(Get-Date -Format 'yyyyMMdd').log"
        Set-Content -LiteralPath $log -Value $lines -Encoding utf8
    }
}
