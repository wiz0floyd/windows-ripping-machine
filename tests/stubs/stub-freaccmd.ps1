<#
.SYNOPSIS
    Stub for freaccmd that creates realistic test output.

.DESCRIPTION
    Executes as a CLI-style script (out-of-process via pwsh -NoProfile -File).
    Reads freaccmd-style arguments, creates fake directory structure with tagged
    .flac files, and outputs to stdout. Exits with code 0 on success.

.PARAMETER Arguments
    Command-line arguments passed to freaccmd: drive, -e format, -o output_path
#>

$argList = @($args)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$driveLetter = $null
$outputPath = $null
$format = 'flac'

# Parse arguments: drive letter, -e format, -o output path
for ($i = 0; $i -lt $argList.Count; $i++) {
    $arg = $argList[$i]

    if ($arg -match '^[A-Z]:$') {
        $driveLetter = $arg
    } elseif ($arg -eq '-e' -and $i + 1 -lt $argList.Count) {
        $format = $argList[$i + 1]
        $i++
    } elseif ($arg -eq '-o' -and $i + 1 -lt $argList.Count) {
        $outputPath = $argList[$i + 1]
        $i++
    }
}

# If no output path specified, use temp
if (-not $outputPath) {
    $outputPath = Join-Path $env:TEMP "freac-stub-$(New-Guid)"
}

try {
    # Create output directory
    $outputDir = New-Item -ItemType Directory -Path $outputPath -Force -ErrorAction Stop

    # Create artist/album subdirectory
    $albumDir = Join-Path $outputDir "Test Artist - Test Album"
    $null = New-Item -ItemType Directory -Path $albumDir -Force -ErrorAction Stop

    # Create 3 fake .flac files with minimal FLAC header
    for ($i = 1; $i -le 3; $i++) {
        $flacFile = Join-Path $albumDir "Track $i.flac"
        # fLaC magic bytes followed by padding
        [byte[]]$flacMagic = @(0x66, 0x4C, 0x61, 0x43)  # "fLaC"
        $bytes = $flacMagic + @(0x00) * 100
        [System.IO.File]::WriteAllBytes($flacFile, $bytes)
    }

    # Output to stdout (as freaccmd would)
    Write-Output "[Reader 0] Artist: Test Artist"
    Write-Output "[Reader 0] Album: Test Album"
    Write-Output "[Reader 0] Track 1: Track 1"
    Write-Output "[Reader 0] Track 2: Track 2"
    Write-Output "[Reader 0] Track 3: Track 3"
    Write-Output "[Writer 0] Successfully wrote 3 tracks"

    exit 0

} catch {
    # Output error to stderr
    [Console]::Error.WriteLine("Error: $_")
    exit 1
}
