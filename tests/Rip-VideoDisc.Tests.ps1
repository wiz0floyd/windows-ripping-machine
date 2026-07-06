Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Resolve-Title.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Rip-VideoDisc.ps1')

    $script:FixturesDir = Join-Path $PSScriptRoot 'fixtures'
    $script:InfoLines = @(Get-Content -Path (Join-Path $script:FixturesDir 'makemkvcon-info.txt'))
    $script:DiscInfoLines = @(Get-Content -Path (Join-Path $script:FixturesDir 'makemkvcon-info-disc0.txt'))
    $script:RipLines = @(Get-Content -Path (Join-Path $script:FixturesDir 'makemkvcon-mkv.txt'))
    $script:ExpiredKeyLines = @(Get-Content -Path (Join-Path $script:FixturesDir 'makemkvcon-mkv-expired-key.txt'))

    $script:TestDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wrm-rip-test-$(New-Guid)")
}

AfterAll {
    Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-MakeMkvRobotLine' {
    It 'parses a DRV line with quoted fields containing commas' {
        $line = 'DRV:0,2,999,12,"BD-ROM PIONEER BD-RW  BDR-209M 1.10","STAR_WARS_ANH","D:"'
        $parsed = ConvertFrom-MakeMkvRobotLine -Line $line

        $parsed.Prefix | Should -Be 'DRV'
        $parsed.Fields.Count | Should -Be 7
        $parsed.Fields[4] | Should -Be 'BD-ROM PIONEER BD-RW  BDR-209M 1.10'
        $parsed.Fields[5] | Should -Be 'STAR_WARS_ANH'
        $parsed.Fields[6] | Should -Be 'D:'
    }

    It 'parses an empty-field DRV line' {
        $parsed = ConvertFrom-MakeMkvRobotLine -Line 'DRV:1,256,999,0,"","",""'
        $parsed.Fields.Count | Should -Be 7
        $parsed.Fields[5] | Should -Be ''
    }

    It 'returns $null for non-matching lines' {
        ConvertFrom-MakeMkvRobotLine -Line '' | Should -BeNullOrEmpty
        ConvertFrom-MakeMkvRobotLine -Line 'not a robot line' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-MakeMkvSeconds' {
    It 'converts H:MM:SS' {
        ConvertTo-MakeMkvSeconds -Duration '1:59:14' | Should -Be (1 * 3600 + 59 * 60 + 14)
    }
    It 'converts MM:SS' {
        ConvertTo-MakeMkvSeconds -Duration '5:32' | Should -Be (5 * 60 + 32)
    }
    It 'returns 0 for empty' {
        ConvertTo-MakeMkvSeconds -Duration '' | Should -Be 0
    }
}

Describe 'Get-MakeMkvDriveInfo' {
    It 'maps drive letter D to disc index 0 with label and BD type' {
        $info = Get-MakeMkvDriveInfo -Lines $script:InfoLines -DriveLetter 'D'
        $info.Index | Should -Be 0
        $info.Label | Should -Be 'STAR_WARS_ANH'
        $info.DiscType | Should -Be 'BD'
    }

    It 'returns $null for a drive with no disc name' {
        Get-MakeMkvDriveInfo -Lines $script:InfoLines -DriveLetter 'E' | Should -BeNullOrEmpty
    }

    It 'returns $null for an unmatched drive letter' {
        Get-MakeMkvDriveInfo -Lines $script:InfoLines -DriveLetter 'Z' | Should -BeNullOrEmpty
    }
}

Describe 'Get-MakeMkvLongestTitleIndex' {
    It 'picks the title with the longest duration' {
        Get-MakeMkvLongestTitleIndex -Lines $script:DiscInfoLines | Should -Be 0
    }

    It 'returns $null when given drive-scan lines with no TINFO' {
        Get-MakeMkvLongestTitleIndex -Lines $script:InfoLines | Should -BeNullOrEmpty
    }
}

Describe 'Test-MakeMkvExpiredKey' {
    It 'detects MSG code 5021' {
        Test-MakeMkvExpiredKey -Lines $script:ExpiredKeyLines | Should -Be $true
    }
    It 'returns $false for a normal transcript' {
        Test-MakeMkvExpiredKey -Lines $script:RipLines | Should -Be $false
    }
    It 'detects "registration key" text regardless of code' {
        $lines = @('MSG:9999,0,1,"Your registration key is invalid","%1",""')
        Test-MakeMkvExpiredKey -Lines $lines | Should -Be $true
    }
}

Describe 'Invoke-VideoRip' {
    BeforeEach {
        $script:OutDir = Join-Path $script:TestDir "case-$(New-Guid)"
        $config = @{
            Simulate          = $true
            StagingDir        = $script:OutDir
            MinTitleLengthSec = 600
            RipAllTitles      = $true
            TmdbApiKey        = ''
            LogDir            = Join-Path $script:TestDir 'logs'
        }
        $script:Config = $config
    }

    It 'rips successfully and returns disc metadata + title count' {
        Mock Invoke-ArmTool {
            if ($Arguments -contains 'disc:9999') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:InfoLines; StdErr = @() }
            }
            if ($Arguments -contains 'info') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:DiscInfoLines; StdErr = @() }
            }
            # mkv rip: create the fake output files ourselves (mirrors stub behavior)
            $outDir = $Arguments[-1]
            Set-Content -Path (Join-Path $outDir 'title_t00.mkv') -Value 'fake'
            Set-Content -Path (Join-Path $outDir 'title_t01.mkv') -Value 'fake'
            return [pscustomobject]@{ ExitCode = 0; StdOut = $script:RipLines; StdErr = @() }
        }

        $result = Invoke-VideoRip -DriveLetter 'D' -Config $script:Config

        $result.Success | Should -Be $true
        $result.DiscLabel | Should -Be 'STAR_WARS_ANH'
        $result.DiscType | Should -Be 'BD'
        $result.TitleCount | Should -Be 2
        $result.Error | Should -BeNullOrEmpty
        $result.OutputDir | Should -Be (Join-Path $script:OutDir 'STAR_WARS_ANH')
    }

    It 'writes metadata.json into the output dir and returns a Resolved result before the rip completes' {
        Mock Invoke-ArmTool {
            if ($Arguments -contains 'disc:9999') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:InfoLines; StdErr = @() }
            }
            if ($Arguments -contains 'info') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:DiscInfoLines; StdErr = @() }
            }
            $outDir = $Arguments[-1]
            # metadata.json must already exist by the time the long rip runs.
            Test-Path (Join-Path $outDir 'metadata.json') | Should -Be $true
            Set-Content -Path (Join-Path $outDir 'title_t00.mkv') -Value 'fake'
            return [pscustomobject]@{ ExitCode = 0; StdOut = $script:RipLines; StdErr = @() }
        }

        $result = Invoke-VideoRip -DriveLetter 'D' -Config $script:Config

        $result.Resolved | Should -Not -BeNullOrEmpty
        $result.Resolved.Matched | Should -Be $false
        $metadataPath = Join-Path $result.OutputDir 'metadata.json'
        Test-Path $metadataPath | Should -Be $true
        $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
        $metadata.Title | Should -Be ''
        $metadata.Year | Should -Be ''
    }

    It 'does not overwrite a pre-existing metadata.json (preserves a user edit from a prior failed attempt)' {
        $preExistingOutDir = Join-Path $script:OutDir 'STAR_WARS_ANH'
        $null = New-Item -ItemType Directory -Force -Path $preExistingOutDir
        '{"Title": "User Edited Title", "Year": "2024"}' | Set-Content -Path (Join-Path $preExistingOutDir 'metadata.json')

        Mock Invoke-ArmTool {
            if ($Arguments -contains 'disc:9999') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:InfoLines; StdErr = @() }
            }
            if ($Arguments -contains 'info') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:DiscInfoLines; StdErr = @() }
            }
            $outDir = $Arguments[-1]
            Set-Content -Path (Join-Path $outDir 'title_t00.mkv') -Value 'fake'
            return [pscustomobject]@{ ExitCode = 0; StdOut = $script:RipLines; StdErr = @() }
        }

        $result = Invoke-VideoRip -DriveLetter 'D' -Config $script:Config

        $metadataPath = Join-Path $result.OutputDir 'metadata.json'
        $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
        $metadata.Title | Should -Be 'User Edited Title'
        $metadata.Year | Should -Be '2024'
    }

    It 'creates the output directory before ripping (real makemkvcon requires it to exist)' {
        Mock Invoke-ArmTool {
            if ($Arguments -contains 'disc:9999') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:InfoLines; StdErr = @() }
            }
            if ($Arguments -contains 'info') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:DiscInfoLines; StdErr = @() }
            }
            # Assert the directory already exists by the time the mkv rip runs.
            $outDir = $Arguments[-1]
            Test-Path $outDir | Should -Be $true
            Set-Content -Path (Join-Path $outDir 'title_t00.mkv') -Value 'fake'
            return [pscustomobject]@{ ExitCode = 0; StdOut = $script:RipLines; StdErr = @() }
        }

        $result = Invoke-VideoRip -DriveLetter 'D' -Config $script:Config
        Test-Path $result.OutputDir | Should -Be $true
    }

    It 'selects only the longest title when RipAllTitles is $false' {
        $script:Config.RipAllTitles = $false
        $capturedArgs = $null

        Mock Invoke-ArmTool {
            if ($Arguments -contains 'disc:9999') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:InfoLines; StdErr = @() }
            }
            if ($Arguments -contains 'info') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:DiscInfoLines; StdErr = @() }
            }
            $script:capturedArgs = $Arguments
            $outDir = $Arguments[-1]
            Set-Content -Path (Join-Path $outDir 'title_t00.mkv') -Value 'fake'
            return [pscustomobject]@{ ExitCode = 0; StdOut = $script:RipLines; StdErr = @() }
        }

        $null = Invoke-VideoRip -DriveLetter 'D' -Config $script:Config

        # Longest title in makemkvcon-info-disc0.txt is title 0 (1:59:14).
        $script:capturedArgs -join ' ' | Should -Match 'disc:0 0 '
    }

    It 'falls back to title 0 when the disc-specific info call fails' {
        $script:Config.RipAllTitles = $false
        $capturedArgs = $null

        Mock Invoke-ArmTool {
            if ($Arguments -contains 'disc:9999') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:InfoLines; StdErr = @() }
            }
            if ($Arguments -contains 'info') {
                return [pscustomobject]@{ ExitCode = 1; StdOut = @(); StdErr = @('boom') }
            }
            $script:capturedArgs = $Arguments
            $outDir = $Arguments[-1]
            Set-Content -Path (Join-Path $outDir 'title_t00.mkv') -Value 'fake'
            return [pscustomobject]@{ ExitCode = 0; StdOut = $script:RipLines; StdErr = @() }
        }

        $null = Invoke-VideoRip -DriveLetter 'D' -Config $script:Config

        $script:capturedArgs -join ' ' | Should -Match 'disc:0 0 '
    }

    It 'returns MAKEMKV_KEY_EXPIRED when the key has expired' {
        Mock Invoke-ArmTool {
            if ($Arguments -contains 'disc:9999') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:InfoLines; StdErr = @() }
            }
            return [pscustomobject]@{ ExitCode = 1; StdOut = $script:ExpiredKeyLines; StdErr = @() }
        }

        $result = Invoke-VideoRip -DriveLetter 'D' -Config $script:Config

        $result.Success | Should -Be $false
        $result.Error | Should -Be 'MAKEMKV_KEY_EXPIRED'
        $result.DiscLabel | Should -Be 'STAR_WARS_ANH'
    }

    It 'fails gracefully when no disc is present in the requested drive' {
        Mock Invoke-ArmTool {
            return [pscustomobject]@{ ExitCode = 0; StdOut = $script:InfoLines; StdErr = @() }
        }

        $result = Invoke-VideoRip -DriveLetter 'Z' -Config $script:Config

        $result.Success | Should -Be $false
        $result.Error | Should -Match 'No disc detected'
        $result.DiscLabel | Should -BeNullOrEmpty
    }

    It 'fails gracefully when makemkvcon info exits non-zero' {
        Mock Invoke-ArmTool {
            return [pscustomobject]@{ ExitCode = 1; StdOut = @(); StdErr = @('boom') }
        }

        $result = Invoke-VideoRip -DriveLetter 'D' -Config $script:Config

        $result.Success | Should -Be $false
        $result.Error | Should -Match 'exit code 1'
    }

    It 'fails gracefully when the rip produces no mkv files' {
        Mock Invoke-ArmTool {
            if ($Arguments -contains 'disc:9999') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:InfoLines; StdErr = @() }
            }
            if ($Arguments -contains 'info') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:DiscInfoLines; StdErr = @() }
            }
            return [pscustomobject]@{ ExitCode = 0; StdOut = $script:RipLines; StdErr = @() }
        }

        $result = Invoke-VideoRip -DriveLetter 'D' -Config $script:Config

        $result.Success | Should -Be $false
        $result.Error | Should -Match 'No MKV files produced'
    }

    It 'never throws even when Invoke-ArmTool itself throws' {
        Mock Invoke-ArmTool { throw 'catastrophic failure' }

        { $script:result = Invoke-VideoRip -DriveLetter 'D' -Config $script:Config } | Should -Not -Throw
        $script:result.Success | Should -Be $false
    }
}

Describe 'Invoke-VideoRip (Simulate end-to-end via stub)' {
    It 'produces real mkv files through stub-makemkvcon.ps1' {
        $outDir = Join-Path $script:TestDir "stub-case-$(New-Guid)"
        $config = @{
            Simulate          = $true
            StagingDir        = $outDir
            MinTitleLengthSec = 600
            RipAllTitles      = $true
            TmdbApiKey        = ''
            LogDir            = Join-Path $script:TestDir 'logs'
        }

        $result = Invoke-VideoRip -DriveLetter 'D' -Config $config

        $result.Success | Should -Be $true
        $result.TitleCount | Should -Be 2
        Test-Path $result.OutputDir | Should -Be $true
        (Get-ChildItem $result.OutputDir -Filter '*.mkv').Count | Should -Be 2
    }
}
