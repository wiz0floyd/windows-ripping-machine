Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
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

    It 'returns Success=$false and Error when the video2x step fails' {
        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec)

            if ($Name -eq 'ffmpeg' -and ($Arguments -join ' ') -match 'idet') {
                return [pscustomobject]@{
                    ExitCode = 0
                    StdOut   = @()
                    StdErr   = Get-FixtureLines 'ffmpeg-idet-progressive.txt'
                }
            }
            if ($Name -eq 'video2x') {
                return [pscustomobject]@{ ExitCode = 1; StdOut = @(); StdErr = @('boom') }
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
