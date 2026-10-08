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

# Stream-info probe (`ffmpeg -hide_banner -i <file>`, no output file): like the real
# tool, print the stream line on stderr and exit 1. Never touch the input file.
if ($argList -contains '-hide_banner' -and $argList -notcontains '-f' -and $argList -notcontains '-c:v') {
    [Console]::Error.WriteLine('  Stream #0:0: Video: ffv1, yuv420p, 720x480, SAR 853:720 DAR 853:480, 23.98 fps, 23.98 tbr, 1k tbn')
    exit 1
}

# Null-sink invocations (`-f null -`, e.g. the frame-rate probe): nothing is written;
# emit a realistic final progress line for a 60s window of 23.976 fps film.
if ($argList[$argList.Count - 1] -eq '-') {
    [Console]::Error.WriteLine('frame= 1439 fps=0.0 q=-0.0 Lsize=N/A time=00:01:00.02 bitrate=N/A speed= 300x')
    exit 0
}

$outputFile = $argList[$argList.Count - 1]

$outDir = Split-Path -Parent $outputFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    $null = New-Item -ItemType Directory -Path $outDir -Force
}

$bytes = New-Object byte[] 2048
(New-Object Random).NextBytes($bytes)
[System.IO.File]::WriteAllBytes($outputFile, $bytes)

Write-Output "stub-ffmpeg: wrote $outputFile"
exit 0
