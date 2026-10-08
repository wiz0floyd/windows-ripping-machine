Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'tools' 'bench' 'Bench.Lib.ps1')

    $script:BenchDir = Join-Path $PSScriptRoot '..' 'tools' 'bench'
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures' 'bench'

    function Get-BenchFixtureLines([string] $Name) {
        [string[]](Get-Content -LiteralPath (Join-Path $script:Fixtures $Name))
    }

    # Minimal plan with the fields the argument builders read.
    function New-TestPlan([string] $Engine = 'openproteus', [string] $Filter = 'bwdif=mode=send_frame') {
        [pscustomobject]@{
            InputFile     = 'C:\clips\sample.mkv'
            Window        = $null
            Preprocess    = [ordered]@{ Filter = $Filter; FrameRate = '24000/1001' }
            Engine        = $Engine
            EngineTool    = 'ncnn'
            EngineLabel   = 'ncnn upscale'
            Target        = [ordered]@{ Width = 1440; Height = 1080; DisplayAspect = 1.7791 }
            Upscale       = [ordered]@{ Runner = 'r.py'; ModelBase = 'm'; Ffmpeg = 'ffmpeg'; Ffprobe = 'ffprobe' }
            Encode        = [ordered]@{ Codec = 'libx265'; Crf = 18; Preset = 'slow'; AudioCodec = 'copy'; ResetSar = $true }
            ColorInput    = 'bt601-6-525'
            ColorInputSpec = 'iall=bt601-6-525'
            ColorConvert  = $true
            Error         = $null
        }
    }

    # Example manifest and variants, as the entry script reads them.
    $script:ExampleManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:BenchDir 'samples.example.psd1')
    $script:ExampleVariants = @((Import-PowerShellDataFile -LiteralPath (Join-Path $script:BenchDir 'variants.psd1'))['Variants'])
}

Describe 'Sample manifest' {
    It 'accepts the checked-in example' {
        @(Test-BenchSampleManifest -Manifest $script:ExampleManifest) | Should -BeNullOrEmpty
    }

    It 'rejects a sample with no Source, a bad name, a zero duration and a duplicate name' {
        $manifest = @{ Samples = @(
                @{ Name = 'ok'; Source = 'x.mkv'; Start = 0; Duration = 10 }
                @{ Name = 'ok'; Source = 'x.mkv'; Start = 0; Duration = 10 }
                @{ Name = 'bad name'; Source = 'x.mkv'; Start = 0; Duration = 10 }
                @{ Name = 'nosrc'; Source = ''; Start = 0; Duration = 10 }
                @{ Name = 'zero'; Source = 'x.mkv'; Start = 0; Duration = 0 }
            ) }
        $errors = @(Test-BenchSampleManifest -Manifest $manifest)
        $errors | Should -Contain "Duplicate sample name 'ok'"
        ($errors -join "`n") | Should -Match "Sample name 'bad name'"
        ($errors -join "`n") | Should -Match "Sample 'nosrc' has no Source"
        ($errors -join "`n") | Should -Match "Sample 'zero' needs Duration > 0"
    }

    It 'rejects an empty manifest' {
        @(Test-BenchSampleManifest -Manifest @{ Samples = @() }) | Should -Contain 'Manifest has no Samples'
    }
}

Describe 'Variant definitions' {
    It 'accepts the checked-in variants' {
        @(Test-BenchVariant -Variants $script:ExampleVariants) | Should -BeNullOrEmpty
    }

    It 'rejects the streamed pipeline until #28 and concurrency above 1 until #27' {
        $variants = @(
            @{ Name = 'streamed'; Pipeline = 'streamed'; Encode = @{ Codec = 'libx265'; Crf = 16; Preset = 'slow' } }
            @{ Name = 'parallel'; Concurrency = 2; Encode = @{ Codec = 'libx265'; Crf = 16; Preset = 'slow' } }
        )
        $errors = @(Test-BenchVariant -Variants $variants) -join "`n"
        $errors | Should -Match "'streamed'.*#28"
        $errors | Should -Match "'parallel'.*#27"
    }

    It 'rejects bad encoder settings and duplicate names' {
        $variants = @(
            @{ Name = 'a'; Encode = @{ Codec = 'libvpx'; Crf = 16; Preset = 'slow' } }
            @{ Name = 'b'; Encode = @{ Codec = 'libx265'; Crf = 99; Preset = 'slow' } }
            @{ Name = 'c'; Encode = @{ Codec = 'hevc_amf'; Qp = 18; Quality = 'quality'; PixFmt = 'rgb24' } }
            @{ Name = 'c'; Encode = @{ Codec = 'hevc_amf'; Qp = 18; Quality = 'quality'; PixFmt = 'p010le' } }
        )
        $errors = @(Test-BenchVariant -Variants $variants) -join "`n"
        $errors | Should -Match "'a' Encode.Codec must be"
        $errors | Should -Match "'b' libx265 needs Crf"
        $errors | Should -Match "'c' hevc_amf PixFmt"
        $errors | Should -Match "Duplicate variant name 'c'"
    }
}

Describe 'Variant config and plan override' {
    It 'overlays variant Config on a copy of the base config' {
        $base = @{ UpscaleLiveAction = 'openproteus'; Simulate = $false }
        $variant = @{ Name = 'v'; Config = @{ UpscaleLiveAction = 'anime4k' } }
        $merged = Get-BenchVariantConfig -BaseConfig $base -Variant $variant
        $merged['UpscaleLiveAction'] | Should -Be 'anime4k'
        $merged['Simulate'] | Should -BeFalse
        $base['UpscaleLiveAction'] | Should -Be 'openproteus'
    }

    It 'replaces the filter chain on the plan only when the override sets one' {
        $plan = Set-BenchPlanOverride -Plan (New-TestPlan) -Override @{ Filter = 'yadif=mode=send_frame' }
        $plan.Preprocess['Filter'] | Should -Be 'yadif=mode=send_frame'
        $plan = Set-BenchPlanOverride -Plan (New-TestPlan) -Override $null
        $plan.Preprocess['Filter'] | Should -Be 'bwdif=mode=send_frame'
    }
}

Describe 'Argument builders' {
    It 'cuts with stream copy and seeks before the input' {
        $argList = Get-BenchCutArgumentList -Sample @{ Name = 's'; Source = 'D:\in.mkv'; Start = 600; Duration = 120 } -OutputFile 'C:\out.mkv'
        $argList | Should -Contain '-c'
        $argList[$argList.IndexOf('-c') + 1] | Should -Be 'copy'
        $argList[$argList.IndexOf('-ss') + 1] | Should -Be '600'
        $argList[$argList.IndexOf('-t') + 1] | Should -Be '120'
        $argList.IndexOf('-ss') | Should -BeLessThan $argList.IndexOf('-i')
        $argList[-1] | Should -Be 'C:\out.mkv'
    }

    It 'builds libx265 encode args through the shipping encode builder with the variant settings' {
        $variant = @{ Name = 'x'; Encode = @{ Codec = 'libx265'; Crf = 16; Preset = 'medium' } }
        $argList = Get-BenchEncodeArgumentList -Variant $variant -Plan (New-TestPlan) -UpscaledFile 'up.mkv' -OutputFile 'out.mkv'
        $argList[$argList.IndexOf('-crf') + 1] | Should -Be '16'
        $argList[$argList.IndexOf('-preset') + 1] | Should -Be 'medium'
        $argList[$argList.IndexOf('-c:v') + 1] | Should -Be 'libx265'
        $argList | Should -Contain '-shortest'
        $argList | Should -Contain 'setsar=1,colorspace=all=bt709:iall=bt601-6-525:irange=tv:range=tv:dither=fsb'
    }

    It 'builds hevc_amf CQP 10-bit args with no libx265 flags' {
        $variant = @{ Name = 'a'; Encode = @{ Codec = 'hevc_amf'; Qp = 20; Quality = 'quality'; PixFmt = 'p010le' } }
        $argList = Get-BenchEncodeArgumentList -Variant $variant -Plan (New-TestPlan) -UpscaledFile 'up.mkv' -OutputFile 'out.mkv'
        $argList[$argList.IndexOf('-c:v') + 1] | Should -Be 'hevc_amf'
        $argList[$argList.IndexOf('-rc') + 1] | Should -Be 'cqp'
        $argList[$argList.IndexOf('-qp_i') + 1] | Should -Be '20'
        $argList[$argList.IndexOf('-qp_p') + 1] | Should -Be '20'
        $argList[$argList.IndexOf('-pix_fmt') + 1] | Should -Be 'p010le'
        $argList | Should -Not -Contain '-crf'
        $argList | Should -Contain '-shortest'
    }

    It 'builds one ssim or psnr pass against the reference' {
        $ssim = Get-BenchMetricArgumentList -EncodedFile 'e.mkv' -ReferenceFile 'r.mkv' -Metric ssim
        $ssim | Should -Contain '[0:v][1:v]ssim'
        $ssim[$ssim.IndexOf('-i') + 1] | Should -Be 'e.mkv'
        $ssim | Should -Contain '-f'
        $psnr = Get-BenchMetricArgumentList -EncodedFile 'e.mkv' -ReferenceFile 'r.mkv' -Metric psnr
        $psnr | Should -Contain '[0:v][1:v]psnr'
    }

    It 'formats frame timestamps with a dot decimal separator' {
        $argList = Get-BenchFrameArgumentList -InputFile 'in.mkv' -TimeSec 12.5 -OutputFile 'f.png'
        $argList[$argList.IndexOf('-ss') + 1] | Should -Be '12.5'
        $argList[-1] | Should -Be 'f.png'
    }
}

Describe 'Metric and probe parsers' {
    It 'reads the SSIM All score' {
        ConvertFrom-BenchSsimLine -Lines (Get-BenchFixtureLines 'ffmpeg-ssim-stderr.txt') | Should -Be 0.993564
        ConvertFrom-BenchSsimLine -Lines (Get-BenchFixtureLines 'ffmpeg-ssim-with-progress.txt') | Should -Be 0.9912
    }

    It 'returns null for SSIM when the summary is missing' {
        ConvertFrom-BenchSsimLine -Lines @('frame=  48 fps=0.0') | Should -BeNullOrEmpty
        ConvertFrom-BenchSsimLine -Lines $null | Should -BeNullOrEmpty
    }

    It 'reads the PSNR average, including inf' {
        ConvertFrom-BenchPsnrLine -Lines (Get-BenchFixtureLines 'ffmpeg-psnr-stderr.txt') | Should -Be 50.093
        ConvertFrom-BenchPsnrLine -Lines @('PSNR y:inf u:inf v:inf average:inf min:inf max:inf') | Should -Be ([double]::PositiveInfinity)
        ConvertFrom-BenchPsnrLine -Lines @() | Should -BeNullOrEmpty
    }

    It 'counts packets and takes the last pts, skipping N/A' {
        $result = ConvertFrom-BenchPacketTimes -Lines (Get-BenchFixtureLines 'packet-times-sample.txt')
        $result.Count | Should -Be 6
        $result.LastPts | Should -Be 0.166833
    }

    It 'returns zero packets and null last pts for empty output' {
        $result = ConvertFrom-BenchPacketTimes -Lines @()
        $result.Count | Should -Be 0
        $result.LastPts | Should -BeNullOrEmpty
    }
}

Describe 'Intermediate cache key' {
    It 'is the same for encoder-only changes and different for a filter or engine change' {
        $base = New-TestPlan
        $encodeOnly = New-TestPlan
        $encodeOnly.Encode['Crf'] = 20
        $filter = New-TestPlan -Filter 'fieldmatch,yadif=deint=interlaced,decimate'
        $engine = New-TestPlan -Engine 'anime4k'

        $key = Get-BenchIntermediateKey -SampleName 's' -Plan $base
        $key | Should -Match '^[0-9a-f]{16}$'
        Get-BenchIntermediateKey -SampleName 's' -Plan $encodeOnly | Should -Be $key
        Get-BenchIntermediateKey -SampleName 's' -Plan $filter | Should -Not -Be $key
        Get-BenchIntermediateKey -SampleName 's' -Plan $engine | Should -Not -Be $key
        Get-BenchIntermediateKey -SampleName 't' -Plan $base | Should -Not -Be $key
    }
}

Describe 'Results CSV' {
    It 'writes a header once and one row per call, in the fixed column order' {
        $csv = Join-Path $TestDrive 'results.csv'
        $row1 = [ordered]@{ Sample = 'castaway-dark'; Variant = 'x265-slow-crf16'; Status = 'ok'; Error = 'has, comma'; Ssim = 0.99 }
        $row2 = [ordered]@{ Sample = 'snoopy'; Variant = 'amf-cqp18-10bit'; Status = 'error'; Error = 'encode exited 1' }
        Add-BenchCsvRow -Path $csv -Row $row1
        Add-BenchCsvRow -Path $csv -Row $row2

        $lines = @(Get-Content -LiteralPath $csv)
        $lines.Count | Should -Be 3
        $lines[0] | Should -Be ((Get-BenchCsvColumns) -join ',')

        $rows = @(Import-Csv -LiteralPath $csv)
        $rows.Count | Should -Be 2
        $rows[0].Error | Should -Be 'has, comma'
        $rows[0].Ssim | Should -Be '0.99'
        $rows[1].Variant | Should -Be 'amf-cqp18-10bit'
        $rows[1].Ssim | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-BenchVariantSample failure paths (no tools run)' {
    It 'reports a missing clip as an error row instead of throwing' {
        $base = @{ Simulate = $true; LogDir = (Join-Path $TestDrive 'logs') }
        $row = Invoke-BenchVariantSample -Sample @{ Name = 'nope'; Source = 'x'; Start = 0; Duration = 10 } `
            -Variant $script:ExampleVariants[0] -BaseConfig $base -OutDir (Join-Path $TestDrive 'out')
        $row['Status'] | Should -Be 'error'
        $row['Error'] | Should -Match 'clip missing'
        $row['Sample'] | Should -Be 'nope'
    }
}

Describe 'Invoke-BenchVariantSample orchestration (tools mocked)' {
    BeforeAll {
        $script:OutDir = Join-Path $TestDrive 'bench-out'
        # The keys Get-UpscalePlan reads from a real config (config.example.psd1 defaults).
        $script:Base = @{
            Simulate = $true; LogDir = (Join-Path $TestDrive 'logs'); FfmpegPath = 'ffmpeg'; FfprobePath = 'ffprobe'
            UpscaleCrf = 18; UpscaleHeight = 1080; UpscaleLiveAction = 'openproteus'; UpscaleAnimation = 'anime4k'
            UpscaleShader = 'anime4k-v4-a+a'; NcnnModelDir = (Join-Path $TestDrive 'models')
        }
        $script:Sample = @{ Name = 'orch'; Source = 'src.mkv'; Start = 0; Duration = 10 }
        $script:ToolCalls = [System.Collections.Generic.List[object]]::new()

        New-Item -ItemType Directory -Path (Join-Path $script:OutDir 'clips') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:OutDir 'clips' 'orch.mkv') -Value 'clip'

        # Source facts for a 720x480 progressive DVD clip (what ConvertTo-VideoSourceInfo would return).
        $script:Source = [pscustomobject]@{
            Success = $true; Error = $null; Width = 720; Height = 480; DisplayAspect = (853.0 / 480.0)
            DisplayAspectSource = 'sar'; PixelFormat = 'yuv420p'; ColorSpace = 'bt601'; ColorPrimaries = 'smpte170m'
            ColorTransfer = 'bt709'; ColorRange = 'tv'; FieldOrder = 'progressive'; FrameRate = '24000/1001'
            DurationSec = 10.0; AudioStreamCount = 1; Warnings = @()
        }

        Mock Get-VideoSourceInfo { $script:Source }
        Mock Get-InterlaceType { 'Progressive' }
        Mock Get-VideoFrameRate { '24000/1001' }
        Mock Invoke-ArmTool {
            $script:ToolCalls.Add([pscustomobject]@{ Name = $Name; Arguments = $Arguments })
            $last = $Arguments[-1]
            switch ($Name) {
                'ffprobe' {
                    if ($Arguments -contains 'v:0') { return [pscustomobject]@{ ExitCode = 0; StdOut = (1..48 | ForEach-Object { '{0:F6}' -f ($_ / 23.976) }); StdErr = @() } }
                    if ($Arguments -contains 'a:0') { return [pscustomobject]@{ ExitCode = 0; StdOut = @('0.000000', '9.990000'); StdErr = @() } }
                    return [pscustomobject]@{ ExitCode = 0; StdOut = @('10.010000'); StdErr = @() }
                }
                'ffmpeg' {
                    if ($Arguments -contains '-lavfi') {
                        $stderr = if ($Arguments -contains '[0:v][1:v]ssim') { Get-Content -LiteralPath (Join-Path $script:Fixtures 'ffmpeg-ssim-stderr.txt') } else { Get-Content -LiteralPath (Join-Path $script:Fixtures 'ffmpeg-psnr-stderr.txt') }
                        return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @($stderr) }
                    }
                    Set-Content -LiteralPath $last -Value 'data'
                    return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @() }
                }
                default {
                    Set-Content -LiteralPath $last -Value 'data'
                    return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @() }
                }
            }
        }
    }

    It 'runs preprocess, upscale, encode, metrics and probes, and fills the row' {
        $script:ToolCalls.Clear()
        $row = Invoke-BenchVariantSample -Sample $script:Sample -Variant $script:ExampleVariants[0] -BaseConfig $script:Base -OutDir $script:OutDir
        $row['Status'] | Should -Be 'ok' -Because ($row['Error'])
        $row['Engine'] | Should -Be 'openproteus'
        $row['Frames'] | Should -Be 48
        $row['Ssim'] | Should -Be 0.993564
        $row['Psnr'] | Should -Be 50.093
        $row['UpscaleCached'] | Should -BeFalse
        $row['AvLastPtsDeltaSec'] | Should -Be ([math]::Round([math]::Abs((48 / 23.976) - 9.99), 3)) -Because 'video last pts is 48/23.976 and audio last pts is 9.99'
        @($script:ToolCalls | Where-Object Name -eq 'ncnn').Count | Should -Be 1
        @($script:ToolCalls | Where-Object { $_.Name -eq 'ffmpeg' -and $_.Arguments -contains 'ffv1' }).Count | Should -Be 1
    }

    It 'reuses the cached intermediate for a different encoder on the same sample' {
        $script:ToolCalls.Clear()
        $row = Invoke-BenchVariantSample -Sample $script:Sample -Variant $script:ExampleVariants[2] -BaseConfig $script:Base -OutDir $script:OutDir
        $row['Status'] | Should -Be 'ok' -Because ($row['Error'])
        $row['UpscaleCached'] | Should -BeTrue
        $row['Codec'] | Should -Be 'hevc_amf'
        @($script:ToolCalls | Where-Object Name -eq 'ncnn').Count | Should -Be 0
        @($script:ToolCalls | Where-Object { $_.Name -eq 'ffmpeg' -and $_.Arguments -contains 'hevc_amf' }).Count | Should -Be 1
    }

    It 'turns a failed encode into an error row' {
        Mock Invoke-ArmTool {
            if ($Name -eq 'ffmpeg' -and $Arguments -contains 'libx265') { return [pscustomobject]@{ ExitCode = 1; StdOut = @(); StdErr = @('boom') } }
            $last = $Arguments[-1]
            if ($Name -eq 'ffprobe') { return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @() } }
            Set-Content -LiteralPath $last -Value 'data'
            return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @() }
        }
        $row = Invoke-BenchVariantSample -Sample $script:Sample -Variant $script:ExampleVariants[0] -BaseConfig $script:Base -OutDir $script:OutDir
        $row['Status'] | Should -Be 'error'
        $row['Error'] | Should -Be 'encode exited 1'
    }
}
