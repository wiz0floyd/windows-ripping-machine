# Simulated ncnn runner (venv python + tools/ncnn_upscale.py) for Simulate=$true
# runs. Invoked out-of-process by Invoke-ArmTool as
# `pwsh -NoProfile -File stub-ncnn.ps1 <args>` where <args> are the arguments that
# would follow python.exe: `-I <runner.py> --input X --output Y --param ... --bin ...`.
# Only --input/--output matter: copies the input to the output path so the final
# mux has a real file to read. No param() block (see stub-video2x.ps1 for why).

$argList = @($args)

$inputFile = $null
$outputFile = $null

for ($i = 0; $i -lt $argList.Count; $i++) {
    if ($argList[$i] -eq '--input' -and ($i + 1) -lt $argList.Count) {
        $inputFile = $argList[$i + 1]
    }
    if ($argList[$i] -eq '--output' -and ($i + 1) -lt $argList.Count) {
        $outputFile = $argList[$i + 1]
    }
}

if (-not $inputFile -or -not $outputFile) {
    [Console]::Error.WriteLine('stub-ncnn: missing --input or --output argument')
    exit 1
}

$outDir = Split-Path -Parent $outputFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    $null = New-Item -ItemType Directory -Path $outDir -Force
}

Copy-Item -LiteralPath $inputFile -Destination $outputFile -Force

Write-Output "stub-ncnn: upscaled $inputFile -> $outputFile"
exit 0
