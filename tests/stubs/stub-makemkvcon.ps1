<#
.SYNOPSIS
    Simulation stub for makemkvcon64.exe, invoked out-of-process by Invoke-ArmTool
    (via `pwsh -File`) when Config.Simulate is $true.

.DESCRIPTION
    Accepts the same argument shapes as the real CLI:
      -r info disc:9999        (drive scan: DRV/MSG lines only, no TINFO)
      -r info disc:<i>         (disc-specific: CINFO/TINFO lines for its titles)
      -r --minlength=<N> mkv disc:<i> all <dir>
      -r --minlength=<N> mkv disc:<i> <titleIndex> <dir>
    For an info request, writes the matching info fixture transcript to real
    stdout. For an mkv (rip) request, writes the rip fixture transcript to real
    stdout AND creates a couple of fake .mkv files (a few KB of random bytes) in
    the target directory. Invoke-ArmTool captures stdout/stderr via redirected
    streams and the process exit code, so this stub must behave like a real
    console app rather than returning a PowerShell object.
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Arguments
)

# NOTE: Set-StrictMode/$ErrorActionPreference must come AFTER param() - a script's
# `param()` block must be the first statement or pwsh -File no longer binds
# command-line arguments to it.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fixturesDir = Join-Path -Path $PSScriptRoot -ChildPath '..' | Join-Path -ChildPath 'fixtures'

function New-FakeMkvFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test stub; not a public cmdlet.')]
    param([string] $Path)
    $bytes = New-Object byte[] 4096
    (New-Object System.Random).NextBytes($bytes)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

$isInfo = $Arguments -contains 'info'
$isMkv = $Arguments -contains 'mkv'

if ($isInfo) {
    # `disc:9999` is the all-drives scan (DRV lines only); any other disc index
    # is a disc-specific query that returns CINFO/TINFO for that disc's titles.
    $isDriveScan = $Arguments -contains 'disc:9999'
    $fixtureName = if ($isDriveScan) { 'makemkvcon-info.txt' } else { 'makemkvcon-info-disc0.txt' }
    Get-Content -Path (Join-Path $fixturesDir $fixtureName) | ForEach-Object { Write-Output $_ }
    exit 0
}

if ($isMkv) {
    # Expired key simulation: pass disc:666 to trigger the expired-key transcript.
    $useExpiredKey = $Arguments -contains 'disc:666'
    $fixtureName = if ($useExpiredKey) { 'makemkvcon-mkv-expired-key.txt' } else { 'makemkvcon-mkv.txt' }
    Get-Content -Path (Join-Path $fixturesDir $fixtureName) | ForEach-Object { Write-Output $_ }

    # Last positional argument is the output directory.
    $outputDir = $Arguments[-1]

    if (-not $useExpiredKey) {
        if (-not (Test-Path $outputDir)) {
            $null = New-Item -ItemType Directory -Force -Path $outputDir
        }
        New-FakeMkvFile -Path (Join-Path $outputDir 'title_t00.mkv')
        New-FakeMkvFile -Path (Join-Path $outputDir 'title_t01.mkv')
    }

    exit 0
}

[Console]::Error.WriteLine("stub-makemkvcon.ps1: unrecognized arguments: $($Arguments -join ' ')")
exit 1
