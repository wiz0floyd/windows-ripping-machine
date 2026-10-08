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
    -Action Log     Replace today's wrm-<yyyyMMdd>.log with the decoded JSON string array.

.EXAMPLE
    pwsh -NoProfile -File seed.ps1 -ConfigPath C:\t\config.psd1 -Action New -Kind Rip -PropertiesB64 eyJTdGF0ZSI6IlJpcHBpbmcifQ==
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $ConfigPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Reset', 'New', 'Update', 'Log')]
    [string] $Action,

    [ValidateSet('Rip', 'Upscale')]
    [string] $Kind,

    [string] $JobId,

    [string] $PropertiesB64
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
    'Log' {
        $lines = @(ConvertFrom-SeedPayload)
        $null = New-Item -ItemType Directory -Force -Path $config.LogDir
        $log = Join-Path $config.LogDir "wrm-$(Get-Date -Format 'yyyyMMdd').log"
        Set-Content -LiteralPath $log -Value $lines -Encoding utf8
    }
}
