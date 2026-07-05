Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    # Import modules under test
    . (Join-Path $PSScriptRoot '..' 'src' 'Rip-AudioCd.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')

    # Create temp directories
    $script:TestDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wslc-arm-audio-test-$(New-Guid)")
    $script:StagingDir = New-Item -ItemType Directory -Path (Join-Path $script:TestDir 'staging')
    $script:LogDir = New-Item -ItemType Directory -Path (Join-Path $script:TestDir 'logs')
}

AfterAll {
    # Clean up test directory
    Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AudioRip' {
    It 'returns success with extracted artist and album' {
        $config = @{
            StagingDir = $script:StagingDir
            LogDir     = $script:LogDir
            Simulate   = $false
        }

        # Mock Invoke-ArmTool to simulate successful rip
        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec)

            # Create the album directory structure
            $outputPath = $Arguments[$Arguments.IndexOf('-o') + 1]
            $albumDir = Join-Path $outputPath 'Pink Floyd - The Wall'
            $null = New-Item -ItemType Directory -Path $albumDir -Force

            # Create fake .flac files
            for ($i = 1; $i -le 3; $i++) {
                $flacFile = Join-Path $albumDir "Track $i.flac"
                [System.IO.File]::WriteAllBytes($flacFile, @(0x66, 0x4C, 0x61, 0x43) + @(0x00) * 10)
            }

            return [pscustomobject]@{
                ExitCode = 0
                StdOut   = @('Successfully encoded')
                StdErr   = @()
            }
        }

        $result = Invoke-AudioRip -DriveLetter 'D' -Config $config

        $result.Success | Should -Be $true
        $result.Artist | Should -Be 'Pink Floyd'
        $result.Album | Should -Be 'The Wall'
        $result.OutputDir | Should -Not -BeNullOrEmpty
        $result.Error | Should -BeNullOrEmpty
    }

    It 'extracts artist and album from directory name with spaces' {
        $config = @{
            StagingDir = $script:StagingDir
            LogDir     = $script:LogDir
            Simulate   = $false
        }

        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec)

            $outputPath = $Arguments[$Arguments.IndexOf('-o') + 1]
            $albumDir = Join-Path $outputPath 'The Beatles - Abbey Road'
            $null = New-Item -ItemType Directory -Path $albumDir -Force

            for ($i = 1; $i -le 3; $i++) {
                $flacFile = Join-Path $albumDir "Track $i.flac"
                [System.IO.File]::WriteAllBytes($flacFile, @(0x66, 0x4C, 0x61, 0x43))
            }

            return [pscustomobject]@{
                ExitCode = 0
                StdOut   = @('Successfully encoded')
                StdErr   = @()
            }
        }

        $result = Invoke-AudioRip -DriveLetter 'D' -Config $config

        $result.Success | Should -Be $true
        $result.Artist | Should -Be 'The Beatles'
        $result.Album | Should -Be 'Abbey Road'
    }

    It 'returns fallback artist/album when freaccmd fails' {
        $config = @{
            StagingDir = $script:StagingDir
            LogDir     = $script:LogDir
            Simulate   = $false
        }

        Mock Invoke-ArmTool {
            return [pscustomobject]@{
                ExitCode = 1
                StdOut   = @()
                StdErr   = @('Device not ready')
            }
        }

        $result = Invoke-AudioRip -DriveLetter 'D' -Config $config

        $result.Success | Should -Be $false
        $result.Artist | Should -BeNullOrEmpty
        $result.Album | Should -BeNullOrEmpty
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'returns fallback values when no album directory found' {
        $config = @{
            StagingDir = $script:StagingDir
            LogDir     = $script:LogDir
            Simulate   = $false
        }

        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec)
            # Don't create album directory to simulate rip failure
            $outputPath = $Arguments[$Arguments.IndexOf('-o') + 1]
            $null = New-Item -ItemType Directory -Path $outputPath -Force

            return [pscustomobject]@{
                ExitCode = 0
                StdOut   = @('Completed')
                StdErr   = @()
            }
        }

        $result = Invoke-AudioRip -DriveLetter 'D' -Config $config

        $result.Success | Should -Be $false
        $result.Artist | Should -Be 'Unknown Artist'
        $result.Album | Should -Match 'Unknown Album \d{4}-\d{2}-\d{2}'
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'returns fallback when directory name does not match pattern' {
        $config = @{
            StagingDir = $script:StagingDir
            LogDir     = $script:LogDir
            Simulate   = $false
        }

        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec)

            $outputPath = $Arguments[$Arguments.IndexOf('-o') + 1]
            # Create directory with unparseable name
            $albumDir = Join-Path $outputPath 'UnparsableDirName'
            $null = New-Item -ItemType Directory -Path $albumDir -Force

            for ($i = 1; $i -le 3; $i++) {
                $flacFile = Join-Path $albumDir "Track $i.flac"
                [System.IO.File]::WriteAllBytes($flacFile, @(0x66, 0x4C, 0x61, 0x43))
            }

            return [pscustomobject]@{
                ExitCode = 0
                StdOut   = @('Completed')
                StdErr   = @()
            }
        }

        $result = Invoke-AudioRip -DriveLetter 'D' -Config $config

        $result.Success | Should -Be $true
        $result.Artist | Should -Be 'Unknown Artist'
        $result.Album | Should -Be 'UnparsableDirName'
    }

    It 'never throws an exception' {
        $config = @{
            StagingDir = $script:StagingDir
            LogDir     = $script:LogDir
            Simulate   = $false
        }

        Mock Invoke-ArmTool {
            throw "Simulated error"
        }

        { Invoke-AudioRip -DriveLetter 'D' -Config $config } | Should -Not -Throw
    }

    It 'creates staging directory with GUID' {
        $config = @{
            StagingDir = $script:StagingDir
            LogDir     = $script:LogDir
            Simulate   = $false
        }

        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec)

            $outputPath = $Arguments[$Arguments.IndexOf('-o') + 1]
            # Verify GUID in path
            $outputPath | Should -Match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

            $albumDir = Join-Path $outputPath 'Test Artist - Test Album'
            $null = New-Item -ItemType Directory -Path $albumDir -Force

            return [pscustomobject]@{
                ExitCode = 0
                StdOut   = @()
                StdErr   = @()
            }
        }

        $result = Invoke-AudioRip -DriveLetter 'D' -Config $config

        $result.Success | Should -Be $true
    }

    It 'handles missing Config gracefully' {
        $config = @{
            StagingDir = $script:StagingDir
            LogDir     = $script:LogDir
            Simulate   = $false
        }

        Mock Invoke-ArmTool {
            return [pscustomobject]@{
                ExitCode = 0
                StdOut   = @()
                StdErr   = @()
            }
        }

        # Should not throw even with edge cases
        { Invoke-AudioRip -DriveLetter 'D' -Config $config } | Should -Not -Throw
    }

    It 'passes correct arguments to Invoke-ArmTool' {
        $config = @{
            StagingDir = $script:StagingDir
            LogDir     = $script:LogDir
            Simulate   = $false
        }

        $capturedArgs = $null

        Mock Invoke-ArmTool {
            param($Name, $Arguments, $Config, $TimeoutSec)
            $script:capturedArgs = $Arguments

            $outputPath = $Arguments[$Arguments.IndexOf('-o') + 1]
            $albumDir = Join-Path $outputPath 'Test - Test'
            $null = New-Item -ItemType Directory -Path $albumDir -Force

            return [pscustomobject]@{
                ExitCode = 0
                StdOut   = @()
                StdErr   = @()
            }
        }

        $result = Invoke-AudioRip -DriveLetter 'D' -Config $config

        $script:capturedArgs[0] | Should -Be 'D:'
        $script:capturedArgs[1] | Should -Be '-e'
        $script:capturedArgs[2] | Should -Be 'flac'
        $script:capturedArgs[3] | Should -Be '-o'
        $script:capturedArgs[4] | Should -Match "audio\\[0-9a-f-]{36}"
    }
}
