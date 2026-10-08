Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'UpscaleGolden.Helpers.ps1')
    $script:GoldenCases = @(foreach ($s in Get-UpscaleGoldenScenarios) { @{ Id = $s.Id; Scenario = $s } })
}

BeforeAll {
    $script:ProbeStderr = @()
    . (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Upscale-Video.ps1')

    $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'
    $script:TestDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wrm-upscale-test-$(New-Guid)")

    . (Join-Path $PSScriptRoot 'UpscaleGolden.Helpers.ps1')

    function Get-FixtureLines($name) {
        Get-Content -Path (Join-Path $script:FixtureDir $name)
    }

    # The recorded ffprobe output (Cast Away DVD rip: 720x480, SAR 853:720 / DAR 853:480),
    # optionally re-tagged with another SAR. '8:9' is a 4:3 NTSC DVD (DAR 4:3).
    function New-FfprobeJson([string] $Sar = '853:720') {
        $text = (Get-FixtureLines 'ffprobe-dvd-source.json') -join "`n"
        if ($Sar -eq '8:9') {
            $text = $text.Replace('"sample_aspect_ratio": "853:720"', '"sample_aspect_ratio": "8:9"').Replace('"display_aspect_ratio": "853:480"', '"display_aspect_ratio": "4:3"')
        }
        $text
    }
}

AfterAll {
    Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-InterlaceType' {
    BeforeEach {
        $script:Config = @{ Simulate = $true; LogDir = $script:TestDir }
    }

    It 'classifies progressive source as Progressive' {
        Mock Invoke-ArmTool {
            [pscustomobject]@{
                ExitCode = 0
                StdOut   = @()
                StdErr   = Get-FixtureLines 'ffmpeg-idet-progressive.txt'
            }
        }

        $result = Get-InterlaceType -InputFile 'C:\fake\progressive.mkv' -Config $script:Config
        $result | Should -Be 'Progressive'
    }

    It 'classifies interlaced source as Interlaced' {
        Mock Invoke-ArmTool {
            [pscustomobject]@{
                ExitCode = 0
                StdOut   = @()
                StdErr   = Get-FixtureLines 'ffmpeg-idet-interlaced.txt'
            }
        }

        $result = Get-InterlaceType -InputFile 'C:\fake\interlaced.mkv' -Config $script:Config
        $result | Should -Be 'Interlaced'
    }

    It 'classifies telecined source as Telecined' {
        Mock Invoke-ArmTool {
            [pscustomobject]@{
                ExitCode = 0
                StdOut   = @()
                StdErr   = Get-FixtureLines 'ffmpeg-idet-telecined.txt'
            }
        }

        $result = Get-InterlaceType -InputFile 'C:\fake\telecined.mkv' -Config $script:Config
        $result | Should -Be 'Telecined'
    }

    It 'defaults to Interlaced when idet output is unparseable' {
        Mock Invoke-ArmTool {
            [pscustomobject]@{
                ExitCode = 0
                StdOut   = @()
                StdErr   = @('garbage output, no idet lines here')
            }
        }

        $result = Get-InterlaceType -InputFile 'C:\fake\unknown.mkv' -Config $script:Config
        $result | Should -Be 'Interlaced'
    }

    Context 'ffmpeg 8.x double idet summary (first all-zero, then real)' {
        It 'classifies a progressive source from the LAST summary' {
            Mock Invoke-ArmTool {
                [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = Get-FixtureLines 'ffmpeg-idet-double-progressive.txt' }
            }
            Get-InterlaceType -InputFile 'C:\fake\p.mkv' -Config $script:Config | Should -Be 'Progressive'
        }

        It 'classifies an interlaced (TFF-dominant, ~0% progressive) source as Interlaced' {
            Mock Invoke-ArmTool {
                [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = Get-FixtureLines 'ffmpeg-idet-double-interlaced.txt' }
            }
            Get-InterlaceType -InputFile 'C:\fake\i.mkv' -Config $script:Config | Should -Be 'Interlaced'
        }

        It 'classifies a hard-telecined source (high repeated fields) as Telecined' {
            Mock Invoke-ArmTool {
                [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = Get-FixtureLines 'ffmpeg-idet-double-telecined.txt' }
            }
            Get-InterlaceType -InputFile 'C:\fake\t.mkv' -Config $script:Config | Should -Be 'Telecined'
        }

        It 'does not log a WARN when the last summary is valid' {
            Mock Invoke-ArmTool {
                [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = Get-FixtureLines 'ffmpeg-idet-double-progressive.txt' }
            }
            Mock Write-ArmLog {}
            Get-InterlaceType -InputFile 'C:\fake\p.mkv' -Config $script:Config | Out-Null
            Should -Invoke Write-ArmLog -Times 0 -ParameterFilter { $Level -eq 'WARN' }
        }

        It 'returns Interlaced and logs a WARN naming the file when both summaries are all zero' {
            Mock Invoke-ArmTool {
                $zero = @(
                    '[Parsed_idet_0 @ 0000] Repeated Fields: Neither:     0 Top:     0 Bottom:     0'
                    '[Parsed_idet_0 @ 0000] Single frame detection: TFF:     0 BFF:     0 Progressive:     0 Undetermined:     0'
                    '[Parsed_idet_0 @ 0000] Multi frame detection: TFF:     0 BFF:     0 Progressive:     0 Undetermined:     0'
                )
                [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @($zero + $zero) }
            }
            Mock Write-ArmLog {}
            Get-InterlaceType -InputFile 'C:\fake\zeros.mkv' -Config $script:Config | Should -Be 'Interlaced'
            Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'zeros\.mkv' }
        }
    }

    Context 'older single-summary build' {
        It 'still classifies a single-summary progressive output' {
            Mock Invoke-ArmTool {
                [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = Get-FixtureLines 'ffmpeg-idet-progressive.txt' }
            }
            Get-InterlaceType -InputFile 'C:\fake\p.mkv' -Config $script:Config | Should -Be 'Progressive'
        }
    }

    Context 'progressive threshold boundary (>= 0.5 of the multi-frame total)' {
        BeforeAll {
            function New-IdetStderr([int] $Progressive, [int] $Total) {
                $other = $Total - $Progressive
                @(
                    '[Parsed_idet_0 @ 0000] Repeated Fields: Neither:     0 Top:     0 Bottom:     0'
                    '[Parsed_idet_0 @ 0000] Multi frame detection: TFF:     0 BFF:     0 Progressive:     0 Undetermined:     0'
                    '[Parsed_idet_0 @ 0001] Repeated Fields: Neither:  1000 Top:     0 Bottom:     0'
                    "[Parsed_idet_0 @ 0001] Multi frame detection: TFF: $other BFF: 0 Progressive: $Progressive Undetermined: 0"
                )
            }
        }

        It 'treats exactly 50% progressive as Progressive' {
            Mock Invoke-ArmTool { [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = New-IdetStderr -Progressive 500 -Total 1000 } }
            Get-InterlaceType -InputFile 'C:\fake\b.mkv' -Config $script:Config | Should -Be 'Progressive'
        }

        It 'treats just under 50% progressive (499/1000) as Interlaced' {
            Mock Invoke-ArmTool { [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = New-IdetStderr -Progressive 499 -Total 1000 } }
            Get-InterlaceType -InputFile 'C:\fake\b.mkv' -Config $script:Config | Should -Be 'Interlaced'
        }

        It 'treats the lowest measured real progressive share (80.9%) as Progressive' {
            Mock Invoke-ArmTool { [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = New-IdetStderr -Progressive 809 -Total 1000 } }
            Get-InterlaceType -InputFile 'C:\fake\b.mkv' -Config $script:Config | Should -Be 'Progressive'
        }
    }

    It 'calls Invoke-ArmTool with the ffmpeg idet filter and 2000 frame limit' {
        Mock Invoke-ArmTool {
            [pscustomobject]@{
                ExitCode = 0
                StdOut   = @()
                StdErr   = Get-FixtureLines 'ffmpeg-idet-progressive.txt'
            }
        }

        Get-InterlaceType -InputFile 'C:\fake\progressive.mkv' -Config $script:Config | Out-Null

        Should -Invoke Invoke-ArmTool -Times 1 -ParameterFilter {
            $Name -eq 'ffmpeg' -and ($Arguments -join ' ') -match 'idet' -and ($Arguments -join ' ') -match '2000'
        }
    }
}

Describe 'stub-ffmpeg idet probe detection' {
    BeforeEach {
        $script:Config = @{ Simulate = $true; LogDir = $script:TestDir }
    }

    It 'treats the Get-InterlaceType probe shape as an idet probe (real stub, end to end)' {
        Get-InterlaceType -InputFile 'C:\fake\movie.mkv' -Config $script:Config | Should -Be 'Progressive'
    }

    It 'does not treat a preprocess call whose chain contains idet as a probe' {
        $out = Join-Path $script:TestDir "preprocess-$(New-Guid).mkv"
        $r = Invoke-ArmTool -Name ffmpeg -Config $script:Config -Arguments @(
            '-i', 'C:\fake\movie.mkv',
            '-vf', 'idet,bwdif=mode=send_frame:deint=interlaced',
            '-c:v', 'ffv1',
            $out
        )
        $r.ExitCode | Should -Be 0
        ($r.StdErr -join "`n") | Should -Not -Match 'Multi frame detection'
        Test-Path -LiteralPath $out | Should -Be $true
    }
}

Describe 'Invoke-Upscale' {
    BeforeEach {
        $script:Config = @{
            Simulate     = $true
            LogDir       = $script:TestDir
            UpscaleModel = 'realesr-generalv3'
            UpscaleScale = 3
            UpscaleCrf   = 16
        }

        $script:InputFile = Join-Path $script:TestDir 'movie.mkv'
        Set-Content -Path $script:InputFile -Value 'fake source bytes'

        $script:OutputDir = Join-Path $script:TestDir "out-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $script:OutputDir -Force
    }

    It 'returns Success with the expected output file name and interlace type' {
        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec)
            if ($Name -eq 'ffprobe') { return [pscustomobject]@{ ExitCode = 0; StdOut = @(Get-FixtureLines 'ffprobe-dvd-source.json'); StdErr = @() } }

            if ($Name -eq 'ffmpeg' -and ($Arguments -join ' ') -match 'idet') {
                return [pscustomobject]@{
                    ExitCode = 0
                    StdOut   = @()
                    StdErr   = Get-FixtureLines 'ffmpeg-idet-progressive.txt'
                }
            }

            # preprocess or mux: create the output file (last arg)
            # frame-rate probe (`-f null -`) writes nothing; don't let the generic branch create a file named '-'
            if ($Arguments[$Arguments.Count - 1] -eq '-') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @($script:ProbeStderr) }
            }
            $outFile = $Arguments[$Arguments.Count - 1]
            Set-Content -LiteralPath $outFile -Value 'fake bytes'
            return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @() }
        }

        $result = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config

        $result.Success | Should -Be $true
        $result.InterlaceType | Should -Be 'Progressive'
        $result.OutputFile | Should -Be (Join-Path $script:OutputDir 'movie [AI upscale 1080p].mkv')
        Test-Path -LiteralPath $result.OutputFile | Should -Be $true
    }

    It 'uses the telecined filter chain when source is telecined' {
        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec)
            if ($Name -eq 'ffprobe') { return [pscustomobject]@{ ExitCode = 0; StdOut = @(Get-FixtureLines 'ffprobe-dvd-source.json'); StdErr = @() } }

            if ($Name -eq 'ffmpeg' -and ($Arguments -join ' ') -match 'idet') {
                return [pscustomobject]@{
                    ExitCode = 0
                    StdOut   = @()
                    StdErr   = Get-FixtureLines 'ffmpeg-idet-telecined.txt'
                }
            }

            # frame-rate probe (`-f null -`) writes nothing; don't let the generic branch create a file named '-'
            if ($Arguments[$Arguments.Count - 1] -eq '-') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @($script:ProbeStderr) }
            }
            $outFile = $Arguments[$Arguments.Count - 1]
            Set-Content -LiteralPath $outFile -Value 'fake bytes'
            return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @() }
        }

        $result = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config

        $result.Success | Should -Be $true
        $result.InterlaceType | Should -Be 'Telecined'

        Should -Invoke Invoke-ArmTool -ParameterFilter {
            $Name -eq 'ffmpeg' -and ($Arguments -join ' ') -match 'fieldmatch'
        }
    }

    It 'passes -ss 600 -t 120 to the preprocess step when -SampleOnly is set' {
        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec)
            if ($Name -eq 'ffprobe') { return [pscustomobject]@{ ExitCode = 0; StdOut = @(Get-FixtureLines 'ffprobe-dvd-source.json'); StdErr = @() } }

            if ($Name -eq 'ffmpeg' -and ($Arguments -join ' ') -match 'idet') {
                return [pscustomobject]@{
                    ExitCode = 0
                    StdOut   = @()
                    StdErr   = Get-FixtureLines 'ffmpeg-idet-progressive.txt'
                }
            }

            # frame-rate probe (`-f null -`) writes nothing; don't let the generic branch create a file named '-'
            if ($Arguments[$Arguments.Count - 1] -eq '-') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @($script:ProbeStderr) }
            }
            $outFile = $Arguments[$Arguments.Count - 1]
            Set-Content -LiteralPath $outFile -Value 'fake bytes'
            return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @() }
        }

        $null = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config -SampleOnly

        Should -Invoke Invoke-ArmTool -ParameterFilter {
            $Name -eq 'ffmpeg' -and ($Arguments -join ' ') -notmatch 'idet' -and
            ($Arguments -join ' ') -match '-ss 600' -and ($Arguments -join ' ') -match '-t 120'
        }
    }

    It 'returns Success=$false and Error when the upscale step fails' {
        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec)
            if ($Name -eq 'ffprobe') { return [pscustomobject]@{ ExitCode = 0; StdOut = @(Get-FixtureLines 'ffprobe-dvd-source.json'); StdErr = @() } }

            if ($Name -eq 'ffmpeg' -and ($Arguments -join ' ') -match 'idet') {
                return [pscustomobject]@{
                    ExitCode = 0
                    StdOut   = @()
                    StdErr   = Get-FixtureLines 'ffmpeg-idet-progressive.txt'
                }
            }
            if ($Name -in @('video2x', 'ncnn')) {
                return [pscustomobject]@{ ExitCode = 1; StdOut = @(); StdErr = @('boom') }
            }

            # frame-rate probe (`-f null -`) writes nothing; don't let the generic branch create a file named '-'
            if ($Arguments[$Arguments.Count - 1] -eq '-') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @($script:ProbeStderr) }
            }
            $outFile = $Arguments[$Arguments.Count - 1]
            Set-Content -LiteralPath $outFile -Value 'fake bytes'
            return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @() }
        }

        $result = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config

        $result.Success | Should -Be $false
        $result.Error | Should -Not -BeNullOrEmpty
        $result.OutputFile | Should -BeNullOrEmpty
    }

    It 'removes a partial output file left behind when the mux step fails' {
        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec)
            if ($Name -eq 'ffprobe') { return [pscustomobject]@{ ExitCode = 0; StdOut = @(Get-FixtureLines 'ffprobe-dvd-source.json'); StdErr = @() } }

            if ($Name -eq 'ffmpeg' -and ($Arguments -join ' ') -match 'idet') {
                return [pscustomobject]@{
                    ExitCode = 0
                    StdOut   = @()
                    StdErr   = Get-FixtureLines 'ffmpeg-idet-progressive.txt'
                }
            }

            # frame-rate probe (`-f null -`) writes nothing; don't let the generic branch create a file named '-'
            if ($Arguments[$Arguments.Count - 1] -eq '-') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @($script:ProbeStderr) }
            }
            $outFile = $Arguments[$Arguments.Count - 1]

            # The mux step is the one writing into $OutputDir; simulate ffmpeg dying
            # partway through by leaving a truncated file at the expected output path
            # and returning a non-zero exit code.
            if ((Split-Path -Parent $outFile) -eq $script:OutputDir) {
                Set-Content -LiteralPath $outFile -Value 'partial truncated bytes'
                return [pscustomobject]@{ ExitCode = 1; StdOut = @(); StdErr = @('mux crashed') }
            }

            Set-Content -LiteralPath $outFile -Value 'fake bytes'
            return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @() }
        }

        $expectedOutputFile = Join-Path $script:OutputDir 'movie [AI upscale 1080p].mkv'

        $result = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config

        $result.Success | Should -Be $false
        Test-Path -LiteralPath $expectedOutputFile | Should -Be $false
    }

    It 'never throws even when Invoke-ArmTool throws' {
        Mock Invoke-ArmTool { throw 'catastrophic failure' }

        { Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config } | Should -Not -Throw
    }

    It 'cleans up temp files after a successful run' {
        $script:CapturedTempDir = $null

        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec)
            if ($Name -eq 'ffprobe') { return [pscustomobject]@{ ExitCode = 0; StdOut = @(Get-FixtureLines 'ffprobe-dvd-source.json'); StdErr = @() } }

            if ($Name -eq 'ffmpeg' -and ($Arguments -join ' ') -match 'idet') {
                return [pscustomobject]@{
                    ExitCode = 0
                    StdOut   = @()
                    StdErr   = Get-FixtureLines 'ffmpeg-idet-progressive.txt'
                }
            }

            # frame-rate probe (`-f null -`) writes nothing; don't let the generic branch create a file named '-'
            if ($Arguments[$Arguments.Count - 1] -eq '-') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @($script:ProbeStderr) }
            }
            $outFile = $Arguments[$Arguments.Count - 1]
            if ((Split-Path -Leaf (Split-Path -Parent $outFile)) -like 'wrm-upscale-*') {
                # preprocess/video2x steps write into Invoke-Upscale's own temp dir; capture it
                $script:CapturedTempDir = Split-Path -Parent $outFile
            }
            Set-Content -LiteralPath $outFile -Value 'fake bytes'
            return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @() }
        }

        $null = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config

        $script:CapturedTempDir | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $script:CapturedTempDir | Should -Be $false
    }
}

Describe 'Get-InterlaceType probe window' {
    BeforeEach {
        $script:Config = @{ Simulate = $true; LogDir = $script:TestDir }
        Mock Invoke-ArmTool { [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = Get-FixtureLines 'ffmpeg-idet-progressive.txt' } }
    }

    It 'probes from 0:00 with the exact historical arguments when no window is given' {
        Get-InterlaceType -InputFile 'C:\fake\a.mkv' -Config $script:Config | Should -Be 'Progressive'
        Should -Invoke Invoke-ArmTool -Times 1 -ParameterFilter {
            $Name -eq 'ffmpeg' -and ($Arguments -join ' ') -eq '-i C:\fake\a.mkv -filter:v idet -frames:v 2000 -an -f null -'
        }
    }

    It 'puts -ss/-t before -i when a window is given (same window parameters as Get-VideoFrameRate)' {
        Get-InterlaceType -InputFile 'C:\fake\a.mkv' -Config $script:Config -Seek 600 -Duration 120 | Should -Be 'Progressive'
        Should -Invoke Invoke-ArmTool -Times 1 -ParameterFilter {
            ($Arguments -join ' ') -eq '-ss 600 -t 120 -i C:\fake\a.mkv -filter:v idet -frames:v 2000 -an -f null -'
        }
    }

    It 'accepts a seek without a duration' {
        $null = Get-InterlaceType -InputFile 'C:\fake\a.mkv' -Config $script:Config -Seek 0
        Should -Invoke Invoke-ArmTool -Times 1 -ParameterFilter {
            ($Arguments -join ' ') -eq '-ss 0 -i C:\fake\a.mkv -filter:v idet -frames:v 2000 -an -f null -'
        }
    }
}

Describe 'ConvertTo-VideoSourceInfo' {
    BeforeAll {
        $script:FixtureJson = (Get-FixtureLines 'ffprobe-dvd-source.json') -join "`n"
    }

    It 'reads every field from a real MakeMKV DVD rip (fixture recorded with ffprobe 8.1.2)' {
        $i = ConvertTo-VideoSourceInfo -Json $script:FixtureJson
        $i.Success | Should -Be $true
        $i.Error | Should -BeNullOrEmpty
        $i.Width | Should -Be 720
        $i.Height | Should -Be 480
        $i.SampleAspectRatio | Should -Be '853:720'
        $i.DisplayAspectRatio | Should -Be '853:480'
        [math]::Round($i.DisplayAspect, 9) | Should -Be ([math]::Round((853.0 / 480.0), 9))
        $i.DisplayAspectSource | Should -Be 'sar'
        $i.PixelFormat | Should -Be 'yuv420p'
        $i.ColorSpace | Should -Be 'smpte170m'
        $i.ColorPrimaries | Should -Be 'smpte170m'
        $i.ColorTransfer | Should -Be 'smpte170m'
        $i.ColorRange | Should -Be 'tv'
        $i.FieldOrder | Should -Be 'progressive'
        $i.FrameRate | Should -Be '30000/1001'
        $i.DurationSec | Should -Be 8627.936
        $i.AudioStreamCount | Should -Be 5
        $i.Warnings.Count | Should -Be 0
    }

    It 'derives a 4:3 display aspect from an 8:9 SAR' {
        $i = ConvertTo-VideoSourceInfo -Json (New-FfprobeJson -Sar '8:9')
        [math]::Round($i.DisplayAspect, 9) | Should -Be ([math]::Round((4.0 / 3.0), 9))
    }

    It 'matches the DAR the old ffmpeg-banner parse printed for the same stream' {
        # banner: `720x480 [SAR 853:720 DAR 853:480]` => 853/480
        (ConvertTo-VideoSourceInfo -Json $script:FixtureJson).DisplayAspect | Should -Be (853.0 / 480.0)
    }

    It 'falls back to display_aspect_ratio, then the frame size, then 16:9 with a warning' {
        $dar = '{"streams":[{"codec_type":"video","width":720,"height":480,"display_aspect_ratio":"16:9"}]}'
        $i = ConvertTo-VideoSourceInfo -Json $dar
        [math]::Round($i.DisplayAspect, 9) | Should -Be ([math]::Round((16.0 / 9.0), 9))
        $i.DisplayAspectSource | Should -Be 'dar'

        $size = '{"streams":[{"codec_type":"video","width":640,"height":480,"sample_aspect_ratio":"0:1"}]}'
        $i = ConvertTo-VideoSourceInfo -Json $size
        [math]::Round($i.DisplayAspect, 9) | Should -Be ([math]::Round((640.0 / 480.0), 9))
        $i.DisplayAspectSource | Should -Be 'frame-size'
        $i.SampleAspectRatio | Should -BeNullOrEmpty

        $none = '{"streams":[{"codec_type":"video"}]}'
        $i = ConvertTo-VideoSourceInfo -Json $none -InputFile 'C:\fake\x.mkv'
        $i.Success | Should -Be $true
        [math]::Round($i.DisplayAspect, 9) | Should -Be ([math]::Round((16.0 / 9.0), 9))
        $i.DisplayAspectSource | Should -Be 'assumed'
        $i.Warnings | Should -Match 'x\.mkv.*16:9'
    }

    It 'treats unknown colour tags and a 0/0 header rate as absent' {
        $json = '{"streams":[{"codec_type":"video","width":720,"height":480,"color_space":"unknown","color_range":"N/A","r_frame_rate":"0/0","avg_frame_rate":"25/1"}]}'
        $i = ConvertTo-VideoSourceInfo -Json $json
        $i.ColorSpace | Should -BeNullOrEmpty
        $i.ColorRange | Should -BeNullOrEmpty
        $i.FrameRate | Should -Be '25/1'
    }

    It 'never throws: garbage, empty and audio-only input give Success=$false with the 16:9 fallback' {
        foreach ($bad in 'not json at all', '', '{"streams":[{"codec_type":"audio"}]}', '{}') {
            $i = ConvertTo-VideoSourceInfo -Json $bad
            $i.Success | Should -Be $false
            $i.Error | Should -Not -BeNullOrEmpty
            [math]::Round($i.DisplayAspect, 9) | Should -Be ([math]::Round((16.0 / 9.0), 9))
            $i.Width | Should -BeNullOrEmpty
            $i.AudioStreamCount | Should -BeLessOrEqual 1
        }
    }
}

Describe 'Get-VideoSourceInfo' {
    BeforeEach {
        $script:Config = @{ Simulate = $true; LogDir = $script:TestDir }
    }

    It 'runs ffprobe once on the given file and returns the parsed object' {
        Mock Invoke-ArmTool { [pscustomobject]@{ ExitCode = 0; StdOut = @(Get-FixtureLines 'ffprobe-dvd-source.json'); StdErr = @() } }

        $i = Get-VideoSourceInfo -InputFile 'C:\fake\a.mkv' -Config $script:Config
        $i.Success | Should -Be $true
        $i.AudioStreamCount | Should -Be 5
        Should -Invoke Invoke-ArmTool -Times 1 -ParameterFilter {
            $Name -eq 'ffprobe' -and $Arguments[-1] -eq 'C:\fake\a.mkv' -and ($Arguments -join ' ') -match '-of json'
        }
    }

    It 'works end to end against the real stub-ffprobe (Simulate)' {
        $i = Get-VideoSourceInfo -InputFile 'C:\fake\a.mkv' -Config $script:Config
        $i.Success | Should -Be $true
        $i.Width | Should -Be 720
        [math]::Round($i.DisplayAspect, 9) | Should -Be ([math]::Round((853.0 / 480.0), 9))
    }

    It 'falls back to 16:9 and logs WARNs when ffprobe fails' {
        Mock Invoke-ArmTool { [pscustomobject]@{ ExitCode = -1; StdOut = @(); StdErr = @() } }
        Mock Write-ArmLog {}

        $i = Get-VideoSourceInfo -InputFile 'C:\fake\a.mkv' -Config $script:Config
        $i.Success | Should -Be $false
        $i.Error | Should -Match 'ffprobe exited with code -1'
        [math]::Round($i.DisplayAspect, 9) | Should -Be ([math]::Round((16.0 / 9.0), 9))
        Should -Invoke Write-ArmLog -ParameterFilter { $Level -eq 'WARN' -and $Message -match '16:9' }
        Should -Invoke Write-ArmLog -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'a\.mkv.*failed' }
    }

    It 'never throws even when Invoke-ArmTool throws' {
        Mock Invoke-ArmTool { throw 'catastrophic failure' }
        Mock Write-ArmLog {}

        { Get-VideoSourceInfo -InputFile 'C:\fake\a.mkv' -Config $script:Config } | Should -Not -Throw
        (Get-VideoSourceInfo -InputFile 'C:\fake\a.mkv' -Config $script:Config).Success | Should -Be $false
    }
}

Describe 'Get-UpscalePlan' {
    BeforeAll {
        $script:Source = ConvertTo-VideoSourceInfo -Json ((Get-FixtureLines 'ffprobe-dvd-source.json') -join "`n")
        function New-TestPlan {
            param($Interlace = 'Progressive', $Rate = '24000/1001', [hashtable] $Override = @{}, $ContentType = 'LiveAction', [switch] $Sample, $Source = $script:Source)
            $config = New-UpscaleGoldenConfig -Overrides $Override -LogDir $script:TestDir
            Get-UpscalePlan -InputFile 'C:\rips\movie.mkv' -SourceInfo $Source -InterlaceType $Interlace -FrameRate $Rate `
                -Config $config -ContentType $ContentType -SampleOnly:$Sample
        }
    }

    It 'plans a progressive live-action source: no filter, measured CFR, openproteus at 1920x1080' {
        $p = New-TestPlan
        $p.Error | Should -BeNullOrEmpty
        $p.InterlaceType | Should -Be 'Progressive'
        $p.Preprocess.Filter | Should -BeNullOrEmpty
        $p.Preprocess.FrameRate | Should -Be '24000/1001'
        $p.Window | Should -BeNullOrEmpty
        $p.Engine | Should -Be 'openproteus'
        $p.EngineTool | Should -Be 'ncnn'
        $p.Target.Width | Should -Be 1920
        $p.Target.Height | Should -Be 1080
        $p.Encode.ResetSar | Should -Be $true
        $p.Encode.Codec | Should -Be 'libx265'
        $p.Encode.Crf | Should -Be 16
        $p.OutputFileName | Should -Be 'movie [AI upscale 1080p].mkv'
        $p.Warnings.Count | Should -Be 0
    }

    It 'keeps the #30 per-class filter chains in a single Preprocess.Filter field' {
        (New-TestPlan -Interlace Interlaced).Preprocess.Filter | Should -Be 'bwdif=mode=send_frame'
        (New-TestPlan -Interlace Telecined).Preprocess.Filter | Should -Be 'fieldmatch,yadif=deint=interlaced,decimate'
    }

    It 'applies CFR to Progressive and Interlaced but never to Telecined (decimate sets the rate)' {
        (New-TestPlan -Interlace Interlaced -Rate '30000/1001').Preprocess.FrameRate | Should -Be '30000/1001'
        $t = New-TestPlan -Interlace Telecined -Rate '24000/1001'
        $t.Preprocess.FrameRate | Should -BeNullOrEmpty
        $t.Warnings.Count | Should -Be 0
    }

    It 'warns (once, naming the file) and leaves CFR off when the rate was not measured' {
        $p = New-TestPlan -Rate $null
        $p.Preprocess.FrameRate | Should -BeNullOrEmpty
        $p.Warnings.Count | Should -Be 1
        $p.Warnings[0] | Should -Match 'could not measure the frame rate of C:\\rips\\movie\.mkv'
    }

    It 'sets the 10:00-12:00 window for -SampleOnly' {
        $p = New-TestPlan -Sample
        $p.SampleOnly | Should -Be $true
        $p.Window.Seek | Should -Be 600
        $p.Window.Duration | Should -Be 120
    }

    It 'derives the target width from the DAR and height from UpscaleHeight' {
        $four3 = ConvertTo-VideoSourceInfo -Json (New-FfprobeJson -Sar '8:9')
        (New-TestPlan -Source $four3).Target.Width | Should -Be 1440
        $p = New-TestPlan -Override @{ UpscaleHeight = 720 }
        $p.Target.Width | Should -Be 1280
        $p.Target.Height | Should -Be 720
    }

    It 'routes Animation to anime4k with the configured shader and video2x' {
        $p = New-TestPlan -ContentType Animation -Override @{ UpscaleShader = 'anime4k-v4-b' }
        $p.Engine | Should -Be 'anime4k'
        $p.EngineTool | Should -Be 'video2x'
        $p.Upscale.Shader | Should -Be 'anime4k-v4-b'
        $p.Encode.ResetSar | Should -Be $true
    }

    It 'plans the legacy realesrgan engine without a target size or SAR reset' {
        $p = New-TestPlan -Override @{ UpscaleLiveAction = 'realesrgan' }
        $p.Engine | Should -Be 'realesrgan'
        $p.EngineTool | Should -Be 'video2x'
        $p.Target | Should -BeNullOrEmpty
        $p.Upscale.Model | Should -Be 'realesr-animevideov3'
        $p.Upscale.Scale | Should -Be 2
        $p.Encode.ResetSar | Should -Be $false
    }

    It 'carries the source colour tags for later colour handling, touching nothing today' {
        $p = New-TestPlan
        $p.Colour.Space | Should -Be 'smpte170m'
        $p.Colour.Primaries | Should -Be 'smpte170m'
        $p.Colour.Transfer | Should -Be 'smpte170m'
        $p.Colour.Range | Should -Be 'tv'
        $p.Colour.Action | Should -Be 'none'
        $p.Source.Width | Should -Be 720
    }

    It 'uses the built-in default engines when the config has no engine keys' {
        (New-TestPlan -Override @{ _OmitEngines = $true }).Engine | Should -Be 'openproteus'
        (New-TestPlan -Override @{ _OmitEngines = $true } -ContentType Animation).Engine | Should -Be 'anime4k'
    }

    It 'reports an unknown engine in Error (and keeps the name) instead of throwing' {
        $p = New-TestPlan -Override @{ UpscaleLiveAction = 'bogus' }
        $p.Engine | Should -Be 'bogus'
        $p.Error | Should -Match "Unknown upscale engine 'bogus'"
    }

    It 'reports the realesrgan-plus x4-only mismatch in Error' {
        $p = New-TestPlan -Override @{ UpscaleLiveAction = 'realesrgan'; UpscaleModel = 'realesrgan-plus'; UpscaleScale = 2 }
        $p.Error | Should -Match 'only supports UpscaleScale=4'
    }

    It 'takes the ncnn runner ffprobe from FfprobePath, else beside FfmpegPath, else bare' {
        (New-TestPlan).Upscale.Ffprobe | Should -Be 'ffprobe'
        (New-TestPlan -Override @{ FfmpegPath = 'C:\tools\ffmpeg\bin\ffmpeg.exe' }).Upscale.Ffprobe | Should -Be 'C:\tools\ffmpeg\bin\ffprobe.exe'
        (New-TestPlan -Override @{ FfmpegPath = 'C:\tools\ffmpeg\bin\ffmpeg.exe'; FfprobePath = 'D:\probe\ffprobe.exe' }).Upscale.Ffprobe | Should -Be 'D:\probe\ffprobe.exe'
    }

    It 'is pure: launches no tool and writes no log' {
        Mock Invoke-ArmTool { throw 'plan must not run tools' }
        Mock Write-ArmLog { throw 'plan must not log' }
        { New-TestPlan -Interlace Telecined -Sample } | Should -Not -Throw
        Should -Invoke Invoke-ArmTool -Times 0
        Should -Invoke Write-ArmLog -Times 0
    }
}

Describe 'Upscale stage argument builders' {
    BeforeAll {
        $script:Source = ConvertTo-VideoSourceInfo -Json ((Get-FixtureLines 'ffprobe-dvd-source.json') -join "`n")
        function New-TestPlan {
            param($Interlace = 'Progressive', $Rate = '24000/1001', [hashtable] $Override = @{}, $ContentType = 'LiveAction', [switch] $Sample)
            Get-UpscalePlan -InputFile 'C:\in\movie.mkv' -SourceInfo $script:Source -InterlaceType $Interlace -FrameRate $Rate `
                -Config (New-UpscaleGoldenConfig -Overrides $Override -LogDir $script:TestDir) -ContentType $ContentType -SampleOnly:$Sample
        }
    }

    It 'builds the preprocess arguments in the historical order (window, filter, CFR, ffv1)' {
        $a = Get-UpscalePreprocessArgumentList -Plan (New-TestPlan -Interlace Interlaced -Sample) -OutputFile 'T:\p.mkv'
        $a -join ' ' | Should -Be '-y -i C:\in\movie.mkv -ss 600 -t 120 -vf bwdif=mode=send_frame -fps_mode cfr -r 24000/1001 -c:v ffv1 -an T:\p.mkv'
    }

    It 'builds the telecined preprocess with no CFR flags' {
        $a = Get-UpscalePreprocessArgumentList -Plan (New-TestPlan -Interlace Telecined) -OutputFile 'T:\p.mkv'
        $a -join ' ' | Should -Be '-y -i C:\in\movie.mkv -vf fieldmatch,yadif=deint=interlaced,decimate -c:v ffv1 -an T:\p.mkv'
    }

    It 'builds the three engine argument lists' {
        (Get-UpscaleEngineArgumentList -Plan (New-TestPlan) -InputFile 'T:\p.mkv' -OutputFile 'T:\u.mkv') -join ' ' |
            Should -Match '^-I .*ncnn_upscale\.py --input T:\\p\.mkv --param C:\\models\\openproteus-x2\.param --bin C:\\models\\openproteus-x2\.bin --scale 2 --out-width 1920 --out-height 1080 --ffmpeg ffmpeg --ffprobe ffprobe --output T:\\u\.mkv$'
        (Get-UpscaleEngineArgumentList -Plan (New-TestPlan -ContentType Animation) -InputFile 'T:\p.mkv' -OutputFile 'T:\u.mkv') -join ' ' |
            Should -Be '-i T:\p.mkv -p libplacebo --libplacebo-shader anime4k-v4-a+a -w 1920 -h 1080 -o T:\u.mkv'
        (Get-UpscaleEngineArgumentList -Plan (New-TestPlan -Override @{ UpscaleLiveAction = 'realesrgan' }) -InputFile 'T:\p.mkv' -OutputFile 'T:\u.mkv') -join ' ' |
            Should -Be '-i T:\p.mkv -p realesrgan --realesrgan-model realesr-animevideov3 -s 2 -o T:\u.mkv'
    }

    It 'builds the mux arguments, trimming the audio input for a sample and resetting SAR' {
        (Get-UpscaleEncodeArgumentList -Plan (New-TestPlan -Sample) -UpscaledFile 'T:\u.mkv' -OutputFile 'O:\out.mkv') -join ' ' |
            Should -Be '-y -i T:\u.mkv -ss 600 -t 120 -i C:\in\movie.mkv -map 0:v:0 -map 1:a -vf setsar=1 -c:v libx265 -crf 16 -preset slow -c:a copy -shortest O:\out.mkv'
        (Get-UpscaleEncodeArgumentList -Plan (New-TestPlan -Override @{ UpscaleLiveAction = 'realesrgan' }) -UpscaledFile 'T:\u.mkv' -OutputFile 'O:\out.mkv') -join ' ' |
            Should -Be '-y -i T:\u.mkv -i C:\in\movie.mkv -map 0:v:0 -map 1:a -c:v libx265 -crf 16 -preset slow -c:a copy -shortest O:\out.mkv'
    }
}

Describe 'Invoke-Upscale golden arguments (issue #31: plan-built args == pre-refactor args)' {
    BeforeAll {
        $script:Golden = Get-Content -Path (Join-Path $script:FixtureDir 'golden-upscale-args.json') -Raw | ConvertFrom-Json -AsHashtable
        $script:GoldenInput = Join-Path $script:TestDir 'movie.mkv'
        Set-Content -Path $script:GoldenInput -Value 'fake source bytes'
        $script:GoldenOut = Join-Path $script:TestDir "golden-out-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $script:GoldenOut -Force
        $script:GoldenPaths = @{ InputFile = $script:GoldenInput; OutputDir = $script:GoldenOut; RepoRoot = (Split-Path -Parent $PSScriptRoot) }
        $script:GoldenCalls = [System.Collections.Generic.List[string]]::new()
        $script:GoldenProbes = [System.Collections.Generic.List[string]]::new()
    }

    It 'the golden file covers every scenario' {
        $scenarios = @(Get-UpscaleGoldenScenarios)
        foreach ($s in $scenarios) { $script:Golden.ContainsKey($s.Id) | Should -Be $true -Because $s.Id }
        $script:Golden.Count | Should -Be $scenarios.Count
    }

    It 'reproduces the pre-refactor ffmpeg/video2x/ncnn arguments: <Id>' -ForEach $script:GoldenCases {
        $script:CurrentScenario = $Scenario
        $script:GoldenCalls.Clear()
        $script:GoldenProbes.Clear()

        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec = 3600)
            $Arguments = @($Arguments)
            if ($Name -eq 'ffprobe') {
                $script:GoldenProbes.Add("$($Arguments[-1])")
                return [pscustomobject]@{ ExitCode = 0; StdOut = @(New-FfprobeJson -Sar $script:CurrentScenario.Sar); StdErr = @() }
            }
            $call = ConvertTo-UpscaleGoldenCall -Name $Name -Arguments $Arguments -TimeoutSec $TimeoutSec -Paths $script:GoldenPaths
            $script:GoldenCalls.Add("$($call.Name) [$($call.TimeoutSec)] " + ($call.Args -join [string][char]0x1f))
            if ($Name -eq 'ffmpeg' -and ($Arguments -join ' ') -match 'idet' -and $Arguments[-1] -eq '-') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @(Get-FixtureLines "ffmpeg-idet-$($script:CurrentScenario.Interlace.ToLower()).txt") }
            }
            if ($Arguments[-1] -eq '-') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @($script:CurrentScenario.RateStderr | Where-Object { $_ }) }
            }
            $out = $Arguments[-1]
            if ($Name -eq 'ncnn') { $out = $Arguments[[array]::IndexOf($Arguments, '--output') + 1] }
            if ($Name -eq 'video2x') { $out = $Arguments[[array]::IndexOf($Arguments, '-o') + 1] }
            Set-Content -LiteralPath $out -Value 'fake bytes'
            [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @() }
        }
        Mock Write-ArmLog {}

        $config = New-UpscaleGoldenConfig -Overrides $Scenario.Config -LogDir $script:TestDir
        $r = if ($Scenario.Sample) {
            Invoke-Upscale -InputFile $script:GoldenInput -OutputDir $script:GoldenOut -Config $config -ContentType $Scenario.ContentType -SampleOnly
        } else {
            Invoke-Upscale -InputFile $script:GoldenInput -OutputDir $script:GoldenOut -Config $config -ContentType $Scenario.ContentType
        }
        $r.Success | Should -Be $true -Because $r.Error

        $expected = $script:Golden[$Id]
        $r.InterlaceType | Should -Be $expected.InterlaceType
        $r.Engine | Should -Be $expected.Engine
        $expectedLines = @(foreach ($c in $expected.Calls) { "$($c.Name) [$($c.TimeoutSec)] " + (@($c.Args) -join [string][char]0x1f) })
        ($script:GoldenCalls -join "`n") | Should -BeExactly ($expectedLines -join "`n")

        # The source is probed exactly once, and it is the source file (not the intermediate).
        $script:GoldenProbes.Count | Should -Be 1
        $script:GoldenProbes[0] | Should -Be $script:GoldenInput
    }
}


Describe 'Invoke-Upscale engine routing' {
    BeforeEach {
        $script:Config = @{
            Simulate          = $true
            LogDir            = $script:TestDir
            UpscaleLiveAction = 'openproteus'
            UpscaleAnimation  = 'anime4k'
            UpscaleHeight     = 1080
            UpscaleShader     = 'anime4k-v4-a+a'
            UpscaleModel      = 'realesr-animevideov3'
            UpscaleScale      = 2
            UpscaleCrf        = 16
            NcnnModelDir      = 'C:\models'
            FfmpegPath        = 'ffmpeg'
        }
        $script:Sar = '853:720'

        $script:InputFile = Join-Path $script:TestDir 'movie.mkv'
        Set-Content -Path $script:InputFile -Value 'fake source bytes'
        $script:OutputDir = Join-Path $script:TestDir "out-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $script:OutputDir -Force

        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec)
            if ($Name -eq 'ffprobe') { return [pscustomobject]@{ ExitCode = 0; StdOut = @(New-FfprobeJson -Sar $script:Sar); StdErr = @() } }
            $joined = $Arguments -join ' '
            if ($Name -eq 'ffmpeg' -and $joined -match 'idet') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = Get-FixtureLines 'ffmpeg-idet-progressive.txt' }
            }
            # frame-rate probe (`-f null -`) writes nothing; don't let the generic branch create a file named '-'
            if ($Arguments[$Arguments.Count - 1] -eq '-') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @($script:ProbeStderr) }
            }
            $outFile = $Arguments[$Arguments.Count - 1]
            if ($Name -eq 'ncnn') { $outFile = $Arguments[[array]::IndexOf($Arguments, '--output') + 1] }
            if ($Name -eq 'video2x') { $outFile = $Arguments[[array]::IndexOf($Arguments, '-o') + 1] }
            Set-Content -LiteralPath $outFile -Value 'fake bytes'
            [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @() }
        }
    }

    It 'runs the ncnn OpenProteus runner for LiveAction at the DAR-derived 1920x1080' {
        $r = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config
        $r.Success | Should -Be $true
        $r.Engine | Should -Be 'openproteus'

        Should -Invoke Invoke-ArmTool -Times 1 -ParameterFilter {
            $Name -eq 'ncnn' -and ($Arguments -join ' ') -match '--out-width 1920 --out-height 1080' -and
            ($Arguments -join ' ') -match 'openproteus-x2\.param' -and ($Arguments -join ' ') -match '--scale 2'
        }
        Should -Invoke Invoke-ArmTool -Times 0 -ParameterFilter { $Name -eq 'video2x' }
    }

    It 'derives a 1440 width for a 4:3 source' {
        $script:Sar = '8:9'

        $r = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config
        $r.Success | Should -Be $true

        Should -Invoke Invoke-ArmTool -ParameterFilter {
            $Name -eq 'ncnn' -and ($Arguments -join ' ') -match '--out-width 1440 --out-height 1080'
        }
    }

    It 'runs video2x libplacebo Anime4K for Animation' {
        $r = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config -ContentType Animation
        $r.Success | Should -Be $true
        $r.Engine | Should -Be 'anime4k'

        Should -Invoke Invoke-ArmTool -Times 1 -ParameterFilter {
            $Name -eq 'video2x' -and ($Arguments -join ' ') -match '-p libplacebo' -and
            ($Arguments -join ' ') -match '--libplacebo-shader anime4k-v4-a\+a' -and ($Arguments -join ' ') -match '-w 1920 -h 1080'
        }
        Should -Invoke Invoke-ArmTool -Times 0 -ParameterFilter { $Name -eq 'ncnn' }
    }

    It 'resets SAR to 1 in the final mux for the new engines' {
        $null = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config

        Should -Invoke Invoke-ArmTool -Times 1 -ParameterFilter {
            $Name -eq 'ffmpeg' -and ($Arguments -join ' ') -match 'libx265' -and ($Arguments -join ' ') -match '-vf setsar=1'
        }
    }

    It 'keeps the legacy realesrgan path (no SAR reset) when configured' {
        $script:Config.UpscaleLiveAction = 'realesrgan'

        $r = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config
        $r.Success | Should -Be $true

        Should -Invoke Invoke-ArmTool -Times 1 -ParameterFilter {
            $Name -eq 'video2x' -and ($Arguments -join ' ') -match '-p realesrgan' -and ($Arguments -join ' ') -match '--realesrgan-model realesr-animevideov3'
        }
        Should -Invoke Invoke-ArmTool -Times 0 -ParameterFilter { $Name -eq 'ffmpeg' -and ($Arguments -join ' ') -match 'setsar' }
    }

    It 'fails with a clear error for an unknown engine' {
        $script:Config.UpscaleLiveAction = 'bogus'

        $r = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config
        $r.Success | Should -Be $false
        $r.Error | Should -Match "Unknown upscale engine 'bogus'"
    }

    It 'points at setup.ps1 when the OpenProteus model is missing (non-simulated run)' {
        $script:Config.Simulate = $false

        $r = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config
        $r.Success | Should -Be $false
        $r.Error | Should -Match 'setup\.ps1'
    }

    It 'overrides the 3600s default tool timeout for the long-running steps' {
        $null = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config

        Should -Invoke Invoke-ArmTool -Times 1 -ParameterFilter { $Name -eq 'ncnn' -and $TimeoutSec -ge 86400 }
        Should -Invoke Invoke-ArmTool -Times 1 -ParameterFilter { $Name -eq 'ffmpeg' -and ($Arguments -join ' ') -match 'libx265' -and $TimeoutSec -ge 86400 }
    }
}

Describe 'Get-VideoFrameRate' {
    BeforeEach {
        $script:Config = @{ Simulate = $true; LogDir = $script:TestDir }
    }

    It 'measures 23.976 from a soft-telecined decode (real ffmpeg progress line)' {
        Mock Invoke-ArmTool {
            [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @('frame= 2878 fps=0.0 q=-0.0 Lsize=N/A time=00:02:00.01 bitrate=N/A speed= 320x') }
        }

        Get-VideoFrameRate -InputFile 'C:\fake\a.mkv' -Config $script:Config | Should -Be '24000/1001'
    }

    It 'snaps a true 29.97 source to 30000/1001' {
        Mock Invoke-ArmTool {
            [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @('frame= 1798 fps=0.0 q=-0.0 Lsize=N/A time=00:01:00.00 bitrate=N/A speed= 300x') }
        }

        Get-VideoFrameRate -InputFile 'C:\fake\a.mkv' -Config $script:Config | Should -Be '30000/1001'
    }

    It 'retries from the start when the first window is empty (short file), then returns null if nothing parses' {
        Mock Invoke-ArmTool { [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @('frame=    0 fps=0.0 q=0.0 Lsize=N/A time=N/A') } }

        Get-VideoFrameRate -InputFile 'C:\fake\a.mkv' -Config $script:Config | Should -BeNullOrEmpty
        Should -Invoke Invoke-ArmTool -Times 2
    }

    It 'returns null for a rate far from every standard rate' {
        Mock Invoke-ArmTool {
            [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @('frame= 1000 fps=0.0 q=-0.0 Lsize=N/A time=00:01:00.00 bitrate=N/A speed= 300x') }
        }

        Get-VideoFrameRate -InputFile 'C:\fake\a.mkv' -Config $script:Config | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-Upscale constant-frame-rate preprocess' {
    BeforeEach {
        $script:Config = @{
            Simulate = $true; LogDir = $script:TestDir; UpscaleLiveAction = 'openproteus'
            UpscaleCrf = 16; NcnnModelDir = 'C:\models'
        }
        $script:InputFile = Join-Path $script:TestDir 'movie.mkv'
        Set-Content -Path $script:InputFile -Value 'fake source bytes'
        $script:OutputDir = Join-Path $script:TestDir "out-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $script:OutputDir -Force
        $script:IdetFixture = 'ffmpeg-idet-progressive.txt'
        $script:ProbeStderr = @('frame= 2878 fps=0.0 q=-0.0 Lsize=N/A time=00:02:00.01 bitrate=N/A speed= 320x')

        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec)
            if ($Name -eq 'ffprobe') { return [pscustomobject]@{ ExitCode = 0; StdOut = @(Get-FixtureLines 'ffprobe-dvd-source.json'); StdErr = @() } }
            $joined = $Arguments -join ' '
            if ($Name -eq 'ffmpeg' -and $joined -match 'idet') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = Get-FixtureLines $script:IdetFixture }
            }
            if ($Arguments[$Arguments.Count - 1] -eq '-') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @($script:ProbeStderr) }
            }
            $outFile = $Arguments[$Arguments.Count - 1]
            if ($Name -eq 'ncnn') { $outFile = $Arguments[[array]::IndexOf($Arguments, '--output') + 1] }
            Set-Content -LiteralPath $outFile -Value 'fake bytes'
            [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @() }
        }
    }

    It 'forces the measured constant rate on the ffv1 intermediate (fixes soft-telecine timing)' {
        $r = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config
        $r.Success | Should -Be $true

        Should -Invoke Invoke-ArmTool -Times 1 -ParameterFilter {
            $Name -eq 'ffmpeg' -and ($Arguments -join ' ') -match '-fps_mode cfr -r 24000/1001 -c:v ffv1'
        }
    }

    It 'leaves the preprocess unforced and logs a WARN when the rate cannot be measured' {
        $script:ProbeStderr = @()
        Mock Write-ArmLog {}

        $r = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config
        $r.Success | Should -Be $true

        Should -Invoke Invoke-ArmTool -Times 0 -ParameterFilter { ($Arguments -join ' ') -match '-fps_mode cfr' }
        Should -Invoke Write-ArmLog -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'could not measure the frame rate' }
    }

    It 'does not force a rate for telecined sources (decimate already emits a constant rate)' {
        $script:IdetFixture = 'ffmpeg-idet-telecined.txt'

        $r = Invoke-Upscale -InputFile $script:InputFile -OutputDir $script:OutputDir -Config $script:Config
        $r.Success | Should -Be $true

        Should -Invoke Invoke-ArmTool -Times 0 -ParameterFilter { ($Arguments -join ' ') -match '-fps_mode cfr' }
    }
}
