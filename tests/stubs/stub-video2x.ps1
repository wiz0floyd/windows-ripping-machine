# Simulated video2x for Simulate=$true runs. Invoked out-of-process by
# Invoke-ArmTool (Common.ps1) as `pwsh -NoProfile -File stub-video2x.ps1 <args>`,
# so this must behave like a real CLI: no param() block (short flags like -i/-s
# collide with PowerShell's common parameters and a declared param() block
# throws "ambiguous parameter" trying to bind them - read $args instead), write
# to the real stdout/stderr streams, and signal failure via exit code rather
# than a returned object.
#
# Flags mirrored here target Video2X 6.4: -i/-o for input/output, -p/--processor,
# -s/--scaling-factor, --realesrgan-model (see src/Upscale-Video.ps1). Only -i/-o
# matter to the stub's behavior; -p/-s/--realesrgan-model are accepted but
# otherwise ignored. Parses -i/-o and copies the input file to the output path,
# so downstream steps (final mux) have a real file to read.

$argList = @($args)

$inputFile = $null
$outputFile = $null

for ($i = 0; $i -lt $argList.Count; $i++) {
    if ($argList[$i] -eq '-i' -and ($i + 1) -lt $argList.Count) {
        $inputFile = $argList[$i + 1]
    }
    if ($argList[$i] -eq '-o' -and ($i + 1) -lt $argList.Count) {
        $outputFile = $argList[$i + 1]
    }
}

if (-not $inputFile -or -not $outputFile) {
    [Console]::Error.WriteLine('stub-video2x: missing -i or -o argument')
    exit 1
}

$outDir = Split-Path -Parent $outputFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    $null = New-Item -ItemType Directory -Path $outDir -Force
}

Copy-Item -LiteralPath $inputFile -Destination $outputFile -Force

Write-Output "stub-video2x: upscaled $inputFile -> $outputFile"
exit 0
