Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    # Import modules under test
    . (Join-Path $PSScriptRoot '..' 'src' 'Move-ToNas.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')

    # Create temp directory for logs
    $script:TestDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wrm-move-test-$(New-Guid)")
    $script:LogDir = New-Item -ItemType Directory -Path (Join-Path $script:TestDir 'logs')
}

AfterAll {
    # Clean up test directory
    Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Move-ToNas' {
    It 'successfully moves files and deletes source when verification passes' {
        $config = @{
            LogDir = $script:LogDir
        }

        # Create source directory with test files
        $sourceDir = Join-Path (Join-Path $env:TEMP "move-test-src-$(New-Guid)") 'TestMovie'
        $null = New-Item -ItemType Directory -Path $sourceDir -Force

        # Create test files
        $file1 = Join-Path $sourceDir 'movie.mkv'
        $file2 = Join-Path $sourceDir 'subtitles.srt'
        Set-Content $file1 -Value ('x' * 1000)
        Set-Content $file2 -Value ('y' * 100)

        # Create destination root
        $destRoot = Join-Path (Join-Path $env:TEMP "move-test-dest-$(New-Guid)") 'nas'
        $null = New-Item -ItemType Directory -Path $destRoot -Force

        # Mock Invoke-Robocopy to succeed and copy files
        Mock Invoke-Robocopy {
            param($SourceDir, $DestDir)

            # Copy source files to destination
            if (-not (Test-Path $DestDir)) {
                $null = New-Item -ItemType Directory -Path $DestDir -Force
            }

            Copy-Item -Path "$SourceDir\*" -Destination $DestDir -Recurse -Force

            # Return success with exit code and output lines
            return [pscustomobject]@{
                ExitCode = 0
                Lines    = @('ROBOCOPY :: Robust File Copy for Windows')
            }
        }

        $result = Move-ToNas -SourceDir $sourceDir -DestRoot $destRoot -Config $config

        $result.Success | Should -Be $true
        $result.DestDir | Should -Be (Join-Path $destRoot 'TestMovie')
        $result.Error | Should -BeNullOrEmpty

        # Verify source is deleted
        Test-Path $sourceDir | Should -Be $false

        # Verify destination has files
        Test-Path (Join-Path $result.DestDir 'movie.mkv') | Should -Be $true
        Test-Path (Join-Path $result.DestDir 'subtitles.srt') | Should -Be $true

        # Cleanup
        Remove-Item -Path (Split-Path $sourceDir) -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Split-Path $destRoot) -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'preserves source when robocopy fails with exit code >= 8' {
        $config = @{
            LogDir = $script:LogDir
        }

        # Create source directory
        $sourceDir = Join-Path (Join-Path $env:TEMP "move-test-fail-$(New-Guid)") 'TestMovie'
        $null = New-Item -ItemType Directory -Path $sourceDir -Force
        Set-Content (Join-Path $sourceDir 'test.mkv') -Value 'test'

        # Create destination
        $destRoot = Join-Path (Join-Path $env:TEMP "move-test-dest-fail-$(New-Guid)") 'nas'
        $null = New-Item -ItemType Directory -Path $destRoot -Force

        # Mock Invoke-Robocopy to fail with output lines (tests exit-code conflation bug fix)
        Mock Invoke-Robocopy {
            param($SourceDir, $DestDir)
            # Return failed exit code with output lines
            return [pscustomobject]@{
                ExitCode = 8
                Lines    = @('ERROR: Some output', 'More error output')
            }
        }

        $result = Move-ToNas -SourceDir $sourceDir -DestRoot $destRoot -Config $config

        $result.Success | Should -Be $false
        $result.Error | Should -Not -BeNullOrEmpty
        $result.Error | Should -Match 'robocopy failed with exit code 8'

        # Verify source still exists
        Test-Path $sourceDir | Should -Be $true

        # Cleanup
        Remove-Item -Path (Split-Path $sourceDir) -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Split-Path $destRoot) -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'preserves source when verification fails (file size mismatch)' {
        $config = @{
            LogDir = $script:LogDir
        }

        # Create source directory with files
        $sourceDir = Join-Path (Join-Path $env:TEMP "move-test-verify-$(New-Guid)") 'TestMovie'
        $null = New-Item -ItemType Directory -Path $sourceDir -Force
        Set-Content $sourceDir\movie.mkv -Value ('x' * 1000)

        # Create destination with mismatched file size
        $destRoot = Join-Path (Join-Path $env:TEMP "move-test-dest-verify-$(New-Guid)") 'nas'
        $destDir = Join-Path $destRoot 'TestMovie'
        $null = New-Item -ItemType Directory -Path $destDir -Force
        Set-Content $destDir\movie.mkv -Value ('y' * 500)  # Wrong size!

        # Mock Invoke-Robocopy to succeed
        Mock Invoke-Robocopy {
            param($SourceDir, $DestDir)
            return [pscustomobject]@{
                ExitCode = 0
                Lines    = @('ROBOCOPY :: Robust File Copy for Windows')
            }
        }

        $result = Move-ToNas -SourceDir $sourceDir -DestRoot $destRoot -Config $config

        $result.Success | Should -Be $false
        $result.Error | Should -Match 'Verification failed'

        # Verify source still exists
        Test-Path $sourceDir | Should -Be $true

        # Cleanup
        Remove-Item -Path (Split-Path $sourceDir) -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Split-Path $destRoot) -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'preserves source when destination file is missing' {
        $config = @{
            LogDir = $script:LogDir
        }

        # Create source with multiple files
        $sourceDir = Join-Path (Join-Path $env:TEMP "move-test-missing-$(New-Guid)") 'TestMovie'
        $null = New-Item -ItemType Directory -Path $sourceDir -Force
        Set-Content $sourceDir\file1.mkv -Value 'test1'
        Set-Content $sourceDir\file2.srt -Value 'test2'

        # Create destination with only one file
        $destRoot = Join-Path (Join-Path $env:TEMP "move-test-dest-missing-$(New-Guid)") 'nas'
        $destDir = Join-Path $destRoot 'TestMovie'
        $null = New-Item -ItemType Directory -Path $destDir -Force
        Set-Content $destDir\file1.mkv -Value 'test1'
        # file2.srt is missing!

        # Mock Invoke-Robocopy to succeed
        Mock Invoke-Robocopy {
            param($SourceDir, $DestDir)
            return [pscustomobject]@{
                ExitCode = 0
                Lines    = @('ROBOCOPY :: Robust File Copy for Windows')
            }
        }

        $result = Move-ToNas -SourceDir $sourceDir -DestRoot $destRoot -Config $config

        $result.Success | Should -Be $false
        $result.Error | Should -Match 'Verification failed'

        # Verify source still exists
        Test-Path $sourceDir | Should -Be $true

        # Cleanup
        Remove-Item -Path (Split-Path $sourceDir) -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Split-Path $destRoot) -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns error when source directory does not exist' {
        $config = @{
            LogDir = $script:LogDir
        }

        $result = Move-ToNas -SourceDir 'C:\nonexistent\path' -DestRoot 'C:\dest' -Config $config

        $result.Success | Should -Be $false
        $result.Error | Should -Match 'Source directory not found'
    }

    It 'never throws when robocopy raises an error' {
        $config = @{
            LogDir = $script:LogDir
        }

        # Create source directory
        $sourceDir = Join-Path (Join-Path $env:TEMP "move-test-except-$(New-Guid)") 'TestMovie'
        $null = New-Item -ItemType Directory -Path $sourceDir -Force
        Set-Content (Join-Path $sourceDir 'test.mkv') -Value 'test'

        # Create destination
        $destRoot = Join-Path (Join-Path $env:TEMP "move-test-dest-except-$(New-Guid)") 'nas'
        $null = New-Item -ItemType Directory -Path $destRoot -Force

        # Mock Invoke-Robocopy to throw
        Mock Invoke-Robocopy {
            throw "Simulated robocopy error"
        }

        # Should not throw, should return error in result
        { Move-ToNas -SourceDir $sourceDir -DestRoot $destRoot -Config $config } | Should -Not -Throw

        # Cleanup
        Remove-Item -Path (Split-Path $sourceDir) -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Split-Path $destRoot) -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'accepts robocopy exit codes 0-7 as success' {
        $config = @{
            LogDir = $script:LogDir
        }

        # Create source and destination
        $sourceDir = Join-Path (Join-Path $env:TEMP "move-test-exitcode-$(New-Guid)") 'TestMovie'
        $null = New-Item -ItemType Directory -Path $sourceDir -Force
        Set-Content (Join-Path $sourceDir 'test.mkv') -Value 'test'

        $destRoot = Join-Path (Join-Path $env:TEMP "move-test-dest-exitcode-$(New-Guid)") 'nas'
        $destDir = Join-Path $destRoot 'TestMovie'
        $null = New-Item -ItemType Directory -Path $destDir -Force

        # Test each success exit code
        @(0, 1, 2, 3, 4, 5, 6, 7) | ForEach-Object {
            $exitCode = $_

            # Mock Invoke-Robocopy to return each exit code
            Mock Invoke-Robocopy {
                param($SourceDir, $DestDir)

                # Ensure destination exists and copy files
                if (-not (Test-Path $DestDir)) {
                    $null = New-Item -ItemType Directory -Path $DestDir -Force
                }
                Copy-Item -Path "$SourceDir\*" -Destination $DestDir -Recurse -Force

                return [pscustomobject]@{
                    ExitCode = $exitCode
                    Lines    = @('ROBOCOPY :: Robust File Copy for Windows')
                }
            }

            # Recreate source for each test
            if (Test-Path $sourceDir) {
                Remove-Item $sourceDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            $null = New-Item -ItemType Directory -Path $sourceDir -Force
            Set-Content (Join-Path $sourceDir 'test.mkv') -Value 'test'

            $result = Move-ToNas -SourceDir $sourceDir -DestRoot $destRoot -Config $config

            $result.Success | Should -Be $true -Because "Exit code $exitCode should be treated as success"
        }

        # Cleanup
        Remove-Item -Path (Split-Path $sourceDir) -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Split-Path $destRoot) -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates subdirectory under DestRoot with SourceDir name' {
        $config = @{
            LogDir = $script:LogDir
        }

        # Create source with specific name
        $sourceDir = Join-Path (Join-Path $env:TEMP "move-test-subdir-$(New-Guid)") 'MyCustomMovie'
        $null = New-Item -ItemType Directory -Path $sourceDir -Force
        Set-Content (Join-Path $sourceDir 'test.mkv') -Value 'test'

        # Create destination root (without subdirectory)
        $destRoot = Join-Path (Join-Path $env:TEMP "move-test-dest-subdir-$(New-Guid)") 'nas'
        $null = New-Item -ItemType Directory -Path $destRoot -Force

        # Mock Invoke-Robocopy to copy files
        Mock Invoke-Robocopy {
            param($SourceDir, $DestDir)
            $null = New-Item -ItemType Directory -Path $DestDir -Force
            Copy-Item -Path "$SourceDir\*" -Destination $DestDir -Recurse -Force
            return [pscustomobject]@{
                ExitCode = 0
                Lines    = @('ROBOCOPY :: Robust File Copy for Windows')
            }
        }

        $result = Move-ToNas -SourceDir $sourceDir -DestRoot $destRoot -Config $config

        $result.Success | Should -Be $true
        # Destination should be destRoot\MyCustomMovie
        $result.DestDir | Should -Be (Join-Path $destRoot 'MyCustomMovie')

        # Cleanup
        Remove-Item -Path (Split-Path $sourceDir) -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Split-Path $destRoot) -Recurse -Force -ErrorAction SilentlyContinue
    }
}
