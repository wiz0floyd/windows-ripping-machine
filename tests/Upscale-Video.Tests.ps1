Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:ProbeStderr = @()
    . (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Upscale-Video.ps1')

    $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'
    $script:TestDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wrm-upscale-test-$(New-Guid)")

    function Get-FixtureLines($name) {
        Get-Content -Path (Join-Path $script:FixtureDir $name)
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

Describe 'Get-VideoDisplayAspect' {
    BeforeEach {
        $script:Config = @{ Simulate = $true; LogDir = $script:TestDir }
    }

    It 'uses the DAR printed by ffmpeg for an anamorphic DVD stream' {
        Mock Invoke-ArmTool {
            [pscustomobject]@{ ExitCode = 1; StdOut = @(); StdErr = @(
                '  Stream #0:0: Video: ffv1 (FFV1 / 0x31564646), yuv420p(tv), 720x480 [SAR 853:720 DAR 853:480], SAR 853:720 DAR 853:480, 29.97 fps') }
        }

        Get-VideoDisplayAspect -InputFile 'C:\fake\a.mkv' -Config $script:Config | Should -BeGreaterThan 1.77
    }

    It 'parses the bracketless DAR that ffmpeg prints for an ffv1 intermediate (real output)' {
        Mock Invoke-ArmTool {
            [pscustomobject]@{ ExitCode = 1; StdOut = @(); StdErr = @(
                '  Stream #0:0(eng): Video: ffv1, yuv420p(tv, smpte170m, progressive), 720x480, SAR 853:720 DAR 853:480, 29.97 fps, 29.97 tbr, 1k tbn') }
        }

        Get-VideoDisplayAspect -InputFile 'C:\fake\a.mkv' -Config $script:Config | Should -BeGreaterThan 1.77
    }

    It 'uses the last DAR when the line has codec-level and stream-level values (real mpeg2 output)' {
        Mock Invoke-ArmTool {
            [pscustomobject]@{ ExitCode = 1; StdOut = @(); StdErr = @(
                '  Stream #0:0(eng): Video: mpeg2video (Main), yuv420p(tv, smpte170m, progressive), 720x480 [SAR 8:9 DAR 4:3], SAR 853:720 DAR 853:480, 29.97 fps') }
        }

        Get-VideoDisplayAspect -InputFile 'C:\fake\a.mkv' -Config $script:Config | Should -BeGreaterThan 1.77
    }

    It 'falls back to the frame-size ratio when no DAR is printed' {
        Mock Invoke-ArmTool {
            [pscustomobject]@{ ExitCode = 1; StdOut = @(); StdErr = @('  Stream #0:0: Video: h264, yuv420p, 640x480, 24 fps') }
        }

        Get-VideoDisplayAspect -InputFile 'C:\fake\a.mkv' -Config $script:Config | Should -Be (640 / 480)
    }

    It 'assumes 16:9 and logs a WARN when nothing parses' {
        Mock Invoke-ArmTool { [pscustomobject]@{ ExitCode = 1; StdOut = @(); StdErr = @('garbage') } }
        Mock Write-ArmLog {}

        Get-VideoDisplayAspect -InputFile 'C:\fake\a.mkv' -Config $script:Config | Should -Be (16.0 / 9.0)
        Should -Invoke Write-ArmLog -ParameterFilter { $Level -eq 'WARN' }
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
        $script:DarStderr = '  Stream #0:0: Video: ffv1, yuv420p, 720x480 [SAR 853:720 DAR 853:480], 29.97 fps'

        $script:InputFile = Join-Path $script:TestDir 'movie.mkv'
        Set-Content -Path $script:InputFile -Value 'fake source bytes'
        $script:OutputDir = Join-Path $script:TestDir "out-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $script:OutputDir -Force

        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec)
            $joined = $Arguments -join ' '
            if ($Name -eq 'ffmpeg' -and $joined -match 'idet') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = Get-FixtureLines 'ffmpeg-idet-progressive.txt' }
            }
            if ($Name -eq 'ffmpeg' -and $joined -match '-hide_banner') {
                return [pscustomobject]@{ ExitCode = 1; StdOut = @(); StdErr = @($script:DarStderr) }
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
        $script:DarStderr = '  Stream #0:0: Video: ffv1, yuv420p, 720x480 [SAR 8:9 DAR 4:3], 29.97 fps'

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
            $joined = $Arguments -join ' '
            if ($Name -eq 'ffmpeg' -and $joined -match 'idet') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = Get-FixtureLines $script:IdetFixture }
            }
            if ($Arguments[$Arguments.Count - 1] -eq '-') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @($script:ProbeStderr) }
            }
            if ($Name -eq 'ffmpeg' -and $joined -match '-hide_banner') {
                return [pscustomobject]@{ ExitCode = 1; StdOut = @(); StdErr = @('  Stream #0:0: Video: ffv1, yuv420p, 720x480, SAR 853:720 DAR 853:480, 23.98 fps') }
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
