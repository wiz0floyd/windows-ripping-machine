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
$isIdet = ($argList -join ' ') -match 'idet'

if ($isIdet) {
    $fixturePath = Join-Path $PSScriptRoot '..' 'fixtures' 'ffmpeg-idet-progressive.txt'
    Get-Content -Path $fixturePath | ForEach-Object { [Console]::Error.WriteLine($_) }
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
