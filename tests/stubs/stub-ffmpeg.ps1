# Simulated ffmpeg for Simulate=$true runs. Invoked out-of-process by
# Invoke-ArmTool (Common.ps1) as `pwsh -NoProfile -File stub-ffmpeg.ps1 <args>`,
# so this must behave like a real CLI:
#   - no param() block. Short flags such as -i/-f/-an collide with PowerShell's
#     common parameters (-InformationAction, -Filter, -ErrorAction, ...) and a
#     declared param() block throws "ambiguous parameter" trying to bind them -
#     read the automatic $args array instead.
#   - write to the real stdout/stderr streams (Write-Output / [Console]::Error),
#     since Invoke-ArmTool reads those redirected streams from the child
#     process rather than a script return value. Use [Console]::Error, not
#     Write-Error, so idet's stderr lines arrive undecorated.
#   - signal failure via exit code, not a returned object.
#
# If invoked with the idet filter, emits the progressive idet fixture on
# stderr. Otherwise it's an encode/mux invocation - create the requested
# output file (the last argument, which is always the output path in these
# invocations) with a few KB of random bytes so downstream steps have a real
# file to work with.

$argList = @($args)

# Like real ffmpeg (#32): the version banner unless -hide_banner, and the input/stream/
# chapter/tag dump unless the loglevel is below info - so a caller that forgets to quiet
# a call shows up as noise in the simulated log. `-progress pipe:1` gets key=value
# progress blocks on stdout.
$quietLevels = @('quiet', 'panic', 'fatal', 'error', 'warning', '-8', '0', '8', '16', '24')
$logLevel = 'info'
for ($i = 0; $i -lt $argList.Count - 1; $i++) {
    if ($argList[$i] -in @('-loglevel', '-v')) { $logLevel = "$($argList[$i + 1])" }
}
$wantsProgress = $false
for ($i = 0; $i -lt $argList.Count - 1; $i++) {
    if ($argList[$i] -eq '-progress' -and $argList[$i + 1] -eq 'pipe:1') { $wantsProgress = $true }
}
function Write-StubHeader {
    if ($argList -notcontains '-hide_banner') {
        [Console]::Error.WriteLine('ffmpeg version 8.0-stub Copyright (c) 2000-2025 the FFmpeg developers')
        [Console]::Error.WriteLine('  configuration: --enable-gpl --enable-libx265')
    }
    if ($logLevel -notin $quietLevels) {
        [Console]::Error.WriteLine("Input #0, matroska,webm, from 'movie.mkv':")
        [Console]::Error.WriteLine('  Metadata:')
        [Console]::Error.WriteLine('    _STATISTICS_TAGS-eng: BPS DURATION NUMBER_OF_FRAMES NUMBER_OF_BYTES')
        [Console]::Error.WriteLine('  Chapters:')
        [Console]::Error.WriteLine('    Chapter #0:0: start 0.000000, end 300.000000')
        [Console]::Error.WriteLine('      Metadata:')
        [Console]::Error.WriteLine('        title           : Chapter 01')
        [Console]::Error.WriteLine('  Stream #0:0: Video: mpeg2video (Main), yuv420p(tv, smpte170m, progressive), 720x480 [SAR 8:9 DAR 4:3], 29.97 fps')
    }
}
function Write-StubProgress {
    if (-not $wantsProgress) { return }
    foreach ($block in @(@{ Frame = 1440; Us = 60060000; State = 'continue' }, @{ Frame = 2878; Us = 120037000; State = 'end' })) {
        [Console]::Out.WriteLine("frame=$($block.Frame)")
        [Console]::Out.WriteLine('fps=48.00')
        [Console]::Out.WriteLine("out_time_us=$($block.Us)")
        [Console]::Out.WriteLine('speed=2.00x')
        [Console]::Out.WriteLine("progress=$($block.State)")
    }
}

# The idet probe (Get-InterlaceType) is a null-sink run whose video filter is
# exactly `idet`: `... -filter:v idet ... -f null -`. A preprocess call may carry
# `idet` inside a longer chain (e.g. `idet,bwdif=...`) but writes a real output
# file, so matching `idet` anywhere in the args would misdetect it as the probe.
$isIdet = $false
if ($argList.Count -gt 0 -and $argList[$argList.Count - 1] -eq '-') {
    for ($i = 0; $i -lt $argList.Count - 1; $i++) {
        if ($argList[$i] -notin @('-filter:v', '-vf', '-filter')) { continue }
        $valueIdx = $i + 1
        # When pwsh launches the stub, `-filter:v` reaches $args split in two
        # (`-filter`, `v`) - skip the stream-specifier remnant.
        if ($argList[$i] -eq '-filter' -and $argList[$valueIdx] -eq 'v' -and $valueIdx + 1 -lt $argList.Count) { $valueIdx++ }
        if ($argList[$valueIdx] -match '^idet(=[^,]*)?$') {
            $isIdet = $true
            break
        }
    }
}

if ($isIdet) {
    $fixturePath = Join-Path $PSScriptRoot '..' 'fixtures' 'ffmpeg-idet-progressive.txt'
    Get-Content -Path $fixturePath | ForEach-Object { [Console]::Error.WriteLine($_) }
    exit 0
}

# Stream metadata (size, SAR/DAR, colour, rates) is read with ffprobe, not an
# `ffmpeg -i` banner parse - see stub-ffprobe.ps1. This stub only answers the two
# measured probes (idet, decoded frame rate) and encode/mux invocations.

# Null-sink invocations (`-f null -`, e.g. the frame-rate probe): nothing is written;
# emit a realistic final progress line for a 60s window of 23.976 fps film.
if ($argList[$argList.Count - 1] -eq '-') {
    Write-StubHeader
    [Console]::Error.WriteLine('frame= 1439 fps=0.0 q=-0.0 Lsize=N/A time=00:01:00.02 bitrate=N/A speed= 300x')
    exit 0
}

$outputFile = $argList[$argList.Count - 1]
Write-StubHeader
Write-StubProgress

$outDir = Split-Path -Parent $outputFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    $null = New-Item -ItemType Directory -Path $outDir -Force
}

$bytes = New-Object byte[] 2048
(New-Object Random).NextBytes($bytes)
[System.IO.File]::WriteAllBytes($outputFile, $bytes)

Write-Output "stub-ffmpeg: wrote $outputFile"
exit 0
