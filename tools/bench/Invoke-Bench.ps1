<#
.SYNOPSIS
    Upscale benchmark harness entry point (issue #33). Real machine only; not part of the pipeline.

.DESCRIPTION
    -Mode Cut     stream-copy cut every sample in the manifest into <OutDir>\clips
    -Mode Run     run each selected variant over each selected sample; one CSV row per pair
                  appended to <OutDir>\results.csv
    -Mode Frames  extract the same timestamps from clips and encoded outputs for side-by-side review

    Manifest and variants: samples.local.psd1 (gitignored; copy samples.example.psd1 and point
    Source at your NAS rips) and variants.psd1 (checked in). See docs\bench\README.md.

.EXAMPLE
    ./tools/bench/Invoke-Bench.ps1 -Mode Cut
.EXAMPLE
    ./tools/bench/Invoke-Bench.ps1 -Mode Run -Variant x265-slow-crf16,amf-cqp18-10bit -Sample castaway-dark
.EXAMPLE
    ./tools/bench/Invoke-Bench.ps1 -Mode Frames -FrameTimes 12.5,60,95
#>
[CmdletBinding()]
param(
    [ValidateSet('Cut', 'Run', 'Frames')]
    [string] $Mode = 'Run',

    [string] $Manifest = (Join-Path $PSScriptRoot 'samples.local.psd1'),

    [string] $Variants = (Join-Path $PSScriptRoot 'variants.psd1'),

    [string[]] $Sample,

    [string[]] $Variant,

    [string] $OutDir = (Join-Path $PSScriptRoot 'out'),

    [string] $ConfigPath,

    [double[]] $FrameTimes = @(10, 60, 120)
)

. (Join-Path $PSScriptRoot 'Bench.Lib.ps1')

if ($MyInvocation.InvocationName -ne '.') {
    if (-not (Test-Path -LiteralPath $Manifest)) {
        throw "Manifest not found: $Manifest (copy tools/bench/samples.example.psd1 to samples.local.psd1 and set the NAS source paths)"
    }
    $manifestData = Import-PowerShellDataFile -LiteralPath $Manifest
    $manifestErrors = @(Test-BenchSampleManifest -Manifest $manifestData)
    if ($manifestErrors.Count -gt 0) { throw "Invalid manifest: $($manifestErrors -join '; ')" }

    $variantData = Import-PowerShellDataFile -LiteralPath $Variants
    $variantList = @($variantData['Variants'])
    $variantErrors = @(Test-BenchVariant -Variants $variantList)
    if ($variantErrors.Count -gt 0) { throw "Invalid variants: $($variantErrors -join '; ')" }

    $samples = @($manifestData['Samples'] | Where-Object { -not $Sample -or $_['Name'] -in $Sample })
    $selectedVariants = @($variantList | Where-Object { -not $Variant -or $_['Name'] -in $Variant })
    if ($samples.Count -eq 0) { throw 'No samples selected' }
    if ($selectedVariants.Count -eq 0) { throw 'No variants selected' }

    $baseConfig = if ($ConfigPath) { Get-ArmConfig -Path $ConfigPath } else { Get-ArmConfig }
    $samples = @($samples | ForEach-Object { [pscustomobject]@{ Name = $_['Name']; Source = $_['Source']; Start = $_['Start']; Duration = $_['Duration'] } })

    switch ($Mode) {
        'Cut' {
            $cut = Invoke-BenchCut -Samples $samples -BaseConfig $baseConfig -OutDir $OutDir
            Write-ArmLog -Level INFO -Message "bench cut: $($cut.Cut) ok, $($cut.Failed) failed" -Config $baseConfig
        }
        'Run' {
            $results = Join-Path $OutDir 'results.csv'
            foreach ($sampleDef in $samples) {
                foreach ($variantDef in $selectedVariants) {
                    $row = Invoke-BenchVariantSample -Sample $sampleDef -Variant $variantDef -BaseConfig $baseConfig -OutDir $OutDir
                    Add-BenchCsvRow -Path $results -Row $row
                    Write-ArmLog -Level INFO -Message "bench $($row['Sample']) x $($row['Variant']): $($row['Status']) wallFps=$($row['WallFps']) ssim=$($row['Ssim']) psnr=$($row['Psnr'])" -Config $baseConfig
                }
            }
            Write-ArmLog -Level INFO -Message "bench results: $results" -Config $baseConfig
        }
        'Frames' {
            $written = Invoke-BenchFrames -Samples $samples -Variants $selectedVariants -TimesSec $FrameTimes -BaseConfig $baseConfig -OutDir $OutDir
            Write-ArmLog -Level INFO -Message "bench frames written: $written" -Config $baseConfig
        }
    }
}
