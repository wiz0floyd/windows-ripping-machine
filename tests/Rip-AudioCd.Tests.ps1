Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    # Import modules under test
    . (Join-Path $PSScriptRoot '..' 'src' 'Rip-AudioCd.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')

    # Create temp directories
    $script:TestDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wrm-audio-test-$(New-Guid)")
    $script:StagingDir = New-Item -ItemType Directory -Path (Join-Path $script:TestDir 'staging')
    $script:LogDir = New-Item -ItemType Directory -Path (Join-Path $script:TestDir 'logs')

    # Builds a minimal Invoke-AudioRip config hashtable. Callers only need to
    # override the handful of keys that vary between tests.
    function New-TestConfig {
        param(
            [string] $StagingDir = $script:StagingDir,
            [string] $LogDir = $script:LogDir,
            [bool] $Simulate = $false
        )
        @{
            StagingDir = $StagingDir
            LogDir     = $LogDir
            Simulate   = $Simulate
        }
    }

    # Builds an Invoke-ArmTool mock scriptblock that simulates a freaccmd rip:
    # it locates the '-o' output path, optionally creates an album directory
    # with fake .flac files inside it, and returns the given exit
    # code/stdout/stderr. Pass -AlbumDirName $null (the default) to skip
    # creating an album directory entirely (simulates a rip that produced no
    # output). Pass -OnInvoke for extra assertions/side effects (e.g.
    # capturing $Arguments or asserting on the output path) before the album
    # directory is created.
    function New-MockAudioRip {
        param(
            [string] $AlbumDirName,
            [int] $FlacFileCount = 3,
            [int] $ExitCode = 0,
            [string[]] $StdOut = @('Successfully encoded'),
            [string[]] $StdErr = @(),
            [scriptblock] $OnInvoke
        )

        return {
            param($Name, $Arguments, $Config, $TimeoutSec)

            if ($OnInvoke) { & $OnInvoke $Arguments }

            $outputPath = $Arguments[$Arguments.IndexOf('-o') + 1]

            if ($AlbumDirName) {
                $albumDir = Join-Path $outputPath $AlbumDirName
                $null = New-Item -ItemType Directory -Path $albumDir -Force

                for ($i = 1; $i -le $FlacFileCount; $i++) {
                    $flacFile = Join-Path $albumDir "Track $i.flac"
                    [System.IO.File]::WriteAllBytes($flacFile, @(0x66, 0x4C, 0x61, 0x43) + @(0x00) * 10)
                }
            } else {
                $null = New-Item -ItemType Directory -Path $outputPath -Force
            }

            return [pscustomobject]@{
                ExitCode = $ExitCode
                StdOut   = $StdOut
                StdErr   = $StdErr
            }
        }.GetNewClosure()
    }
}

AfterAll {
    # Clean up test directory
    Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AudioRip' {
    It 'returns success with extracted artist and album' {
        $config = New-TestConfig

        Mock Invoke-ArmTool (New-MockAudioRip -AlbumDirName 'Pink Floyd - The Wall')

        $result = Invoke-AudioRip -DriveLetter 'D' -Config $config

        $result.Success | Should -Be $true
        $result.Artist | Should -Be 'Pink Floyd'
        $result.Album | Should -Be 'The Wall'
        $result.OutputDir | Should -Not -BeNullOrEmpty
        $result.Error | Should -BeNullOrEmpty
    }

    It 'extracts artist and album from directory name with spaces' {
        $config = New-TestConfig

        Mock Invoke-ArmTool (New-MockAudioRip -AlbumDirName 'The Beatles - Abbey Road')

        $result = Invoke-AudioRip -DriveLetter 'D' -Config $config

        $result.Success | Should -Be $true
        $result.Artist | Should -Be 'The Beatles'
        $result.Album | Should -Be 'Abbey Road'
    }

    It 'returns fallback artist/album when freaccmd fails' {
        $config = New-TestConfig

        Mock Invoke-ArmTool (New-MockAudioRip -ExitCode 1 -StdOut @() -StdErr @('Device not ready'))

        $result = Invoke-AudioRip -DriveLetter 'D' -Config $config

        $result.Success | Should -Be $false
        $result.Artist | Should -BeNullOrEmpty
        $result.Album | Should -BeNullOrEmpty
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'returns fallback values when no album directory found' {
        $config = New-TestConfig

        # Don't create album directory, to simulate rip failure.
        Mock Invoke-ArmTool (New-MockAudioRip -StdOut @('Completed'))

        $result = Invoke-AudioRip -DriveLetter 'D' -Config $config

        $result.Success | Should -Be $false
        $result.Artist | Should -Be 'Unknown Artist'
        $result.Album | Should -Match 'Unknown Album \d{4}-\d{2}-\d{2}'
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'returns fallback when directory name does not match pattern' {
        $config = New-TestConfig

        Mock Invoke-ArmTool (New-MockAudioRip -AlbumDirName 'UnparsableDirName' -StdOut @('Completed'))

        $result = Invoke-AudioRip -DriveLetter 'D' -Config $config

        $result.Success | Should -Be $true
        $result.Artist | Should -Be 'Unknown Artist'
        $result.Album | Should -Be 'UnparsableDirName'
    }

    It 'never throws an exception' {
        $config = New-TestConfig

        Mock Invoke-ArmTool {
            throw "Simulated error"
        }

        { Invoke-AudioRip -DriveLetter 'D' -Config $config } | Should -Not -Throw
    }

    It 'creates staging directory with GUID' {
        $config = New-TestConfig

        Mock Invoke-ArmTool (New-MockAudioRip -AlbumDirName 'Test Artist - Test Album' -FlacFileCount 0 -StdOut @() -StdErr @() -OnInvoke {
                param($Arguments)
                # Verify GUID in path
                $outputPath = $Arguments[$Arguments.IndexOf('-o') + 1]
                $outputPath | Should -Match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
            })

        $result = Invoke-AudioRip -DriveLetter 'D' -Config $config

        $result.Success | Should -Be $true
    }

    It 'handles missing Config gracefully' {
        $config = New-TestConfig

        Mock Invoke-ArmTool (New-MockAudioRip -StdOut @() -StdErr @())

        # Should not throw even with edge cases
        { Invoke-AudioRip -DriveLetter 'D' -Config $config } | Should -Not -Throw
    }

    It 'passes correct arguments to Invoke-ArmTool' {
        $config = New-TestConfig

        Mock Invoke-ArmTool (New-MockAudioRip -AlbumDirName 'Test - Test' -FlacFileCount 0 -StdOut @() -StdErr @() -OnInvoke {
                param($Arguments)
                $script:capturedArgs = $Arguments
            })

        $result = Invoke-AudioRip -DriveLetter 'D' -Config $config

        $script:capturedArgs[0] | Should -Be 'D:'
        $script:capturedArgs[1] | Should -Be '-e'
        $script:capturedArgs[2] | Should -Be 'flac'
        $script:capturedArgs[3] | Should -Be '-o'
        $script:capturedArgs[4] | Should -Match "audio\\[0-9a-f-]{36}"
    }

    It 'returns Success=$false with the real error when staging directory creation fails' {
        # Point StagingDir at a drive letter that does not exist so the staging
        # path can never be created (New-Item -Force cannot fix a missing drive).
        $config = New-TestConfig -StagingDir 'Q:\definitely-does-not-exist-drive\staging'

        # Invoke-ArmTool should never be reached because directory creation
        # fails first; mock it so the test fails loudly if that assumption breaks.
        Mock Invoke-ArmTool {
            return [pscustomobject]@{
                ExitCode = 0
                StdOut   = @()
                StdErr   = @()
            }
        }

        $result = Invoke-AudioRip -DriveLetter 'D' -Config $config

        $result.Success | Should -Be $false
        $result.Error | Should -Not -BeNullOrEmpty
        $result.Error | Should -Match 'Exception in Invoke-AudioRip'
        $result.Error | Should -Not -Match 'freaccmd'
        Should -Invoke Invoke-ArmTool -Times 0
    }

    It 'does not throw when given a lowercase drive letter' {
        $config = New-TestConfig

        Mock Invoke-ArmTool (New-MockAudioRip -AlbumDirName 'Test Artist - Test Album' -FlacFileCount 0 -StdOut @() -StdErr @())

        { $script:lowercaseResult = Invoke-AudioRip -DriveLetter 'd' -Config $config } | Should -Not -Throw
        $script:lowercaseResult.Success | Should -Be $true
    }
}
