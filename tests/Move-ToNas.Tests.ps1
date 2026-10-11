Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    # Import modules under test
    . (Join-Path $PSScriptRoot '..' 'src' 'Move-ToNas.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')

    # Create temp directory for logs
    $script:TestDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wrm-move-test-$(New-Guid)")
    $script:LogDir = New-Item -ItemType Directory -Path (Join-Path $script:TestDir 'logs')

    # Builds a minimal Move-ToNas config hashtable. Callers only need to
    # override LogDir on the rare occasion a test wants a different one.
    function New-TestConfig {
        param([string] $LogDir = $script:LogDir)
        @{
            LogDir = $LogDir
        }
    }
}

AfterAll {
    # Clean up test directory
    Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Move-ToNas' {
    It 'successfully moves files and deletes source when verification passes' {
        $config = New-TestConfig

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
        $config = New-TestConfig

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
        $config = New-TestConfig

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
        $config = New-TestConfig

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
        $config = New-TestConfig

        $result = Move-ToNas -SourceDir 'C:\nonexistent\path' -DestRoot 'C:\dest' -Config $config

        $result.Success | Should -Be $false
        $result.Error | Should -Match 'Source directory not found'
    }

    It 'never throws when robocopy raises an error' {
        $config = New-TestConfig

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
        $config = New-TestConfig

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
        $config = New-TestConfig

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

Describe 'Move-ArmExtrasToSubdir' {
    BeforeEach {
        $script:Dir = Join-Path $env:TEMP "wrm-extras-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $script:Dir -Force
    }
    AfterEach { Remove-Item -Path $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'keeps the largest mkv in place and moves the others into extras' {
        Set-Content (Join-Path $script:Dir 't00.mkv') -Value ('a' * 100)
        Set-Content (Join-Path $script:Dir 't01.mkv') -Value ('a' * 5000)
        Set-Content (Join-Path $script:Dir 't02.mkv') -Value ('a' * 300)
        Set-Content (Join-Path $script:Dir 'metadata.json') -Value '{}'

        $r = Move-ArmExtrasToSubdir -Dir $script:Dir -Config (New-TestConfig)

        $r.Success | Should -BeTrue
        $r.Moved | Should -Be 2
        Test-Path (Join-Path $script:Dir 't01.mkv') | Should -BeTrue
        Test-Path (Join-Path $script:Dir 'extras' 't00.mkv') | Should -BeTrue
        Test-Path (Join-Path $script:Dir 'extras' 't02.mkv') | Should -BeTrue
        Test-Path (Join-Path $script:Dir 'metadata.json') | Should -BeTrue
    }

    It 'does nothing for a single mkv' {
        Set-Content (Join-Path $script:Dir 't00.mkv') -Value 'x'
        $r = Move-ArmExtrasToSubdir -Dir $script:Dir -Config (New-TestConfig)
        $r.Moved | Should -Be 0
        Test-Path (Join-Path $script:Dir 'extras') | Should -BeFalse
    }
}

Describe 'Rename-ArmMainFeature' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive "stage-$(New-Guid)" 'Grease (1978)'
        $null = New-Item -ItemType Directory -Path $script:Dir -Force
    }

    It 'renames the main feature to the folder name and leaves extras/ alone' {
        Set-Content -LiteralPath (Join-Path $script:Dir 'B1_t00.mkv') -Value ('a' * 100)
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Dir 'extras')
        Set-Content -LiteralPath (Join-Path $script:Dir 'extras' 'B1_t01.mkv') -Value 'b'

        $r = Rename-ArmMainFeature -Dir $script:Dir -Config (New-TestConfig)

        $r.Success | Should -BeTrue
        $r.Renamed | Should -BeTrue
        $r.Path | Should -Be (Join-Path $script:Dir 'Grease (1978).mkv')
        Test-Path -LiteralPath (Join-Path $script:Dir 'Grease (1978).mkv') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Dir 'B1_t00.mkv') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Dir 'extras' 'B1_t01.mkv') | Should -BeTrue
    }

    It 'does nothing when the file is already named after the folder (case-insensitive)' {
        Set-Content -LiteralPath (Join-Path $script:Dir 'grease (1978).mkv') -Value 'a'
        $r = Rename-ArmMainFeature -Dir $script:Dir -Config (New-TestConfig)
        $r.Success | Should -BeTrue
        $r.Renamed | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Dir -File).Name | Should -Be @('grease (1978).mkv')
    }

    It 'logs WARN and keeps the original name when the target already exists' {
        Set-Content -LiteralPath (Join-Path $script:Dir 'Grease (1978).mkv') -Value 'small'
        Set-Content -LiteralPath (Join-Path $script:Dir 'B1_t00.mkv') -Value ('big' * 100)
        Mock Write-ArmLog { }

        $r = Rename-ArmMainFeature -Dir $script:Dir -Config (New-TestConfig)

        $r.Success | Should -BeTrue
        $r.Renamed | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Dir 'B1_t00.mkv') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $script:Dir 'Grease (1978).mkv') -Raw).Trim() | Should -Be 'small'
        Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Level -eq 'WARN' }
    }

    It 'succeeds with no rename when there is no mkv, and returns a failure result (no throw) for a missing dir' {
        (Rename-ArmMainFeature -Dir $script:Dir -Config (New-TestConfig)).Renamed | Should -BeFalse
        $r = Rename-ArmMainFeature -Dir (Join-Path $TestDrive 'nope' 'Missing (2000)') -Config (New-TestConfig)
        $r.Success | Should -BeFalse
    }
}

Describe 'Rename-ArmMainFeature -Label' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive "stage-$(New-Guid)" 'Grease (1978)'
        $null = New-Item -ItemType Directory -Path $script:Dir -Force
    }

    It 'names the main feature with a version label' {
        Set-Content -LiteralPath (Join-Path $script:Dir 'B1_t00.mkv') -Value 'a'
        $r = Rename-ArmMainFeature -Dir $script:Dir -Config (New-TestConfig) -Label '480p'
        $r.Renamed | Should -BeTrue
        $r.Path | Should -Be (Join-Path $script:Dir 'Grease (1978) - 480p.mkv')
    }

    It 'adds the tag to a file already named after the folder' {
        Set-Content -LiteralPath (Join-Path $script:Dir 'Grease (1978).mkv') -Value 'a'
        (Rename-ArmMainFeature -Dir $script:Dir -Config (New-TestConfig) -Label '480p').Renamed | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:Dir -File).Name | Should -Be @('Grease (1978) - 480p.mkv')
    }

    It 'keeps a file that already carries a resolution tag' {
        Set-Content -LiteralPath (Join-Path $script:Dir 'Grease (1978) - 576p.mkv') -Value 'a'
        (Rename-ArmMainFeature -Dir $script:Dir -Config (New-TestConfig) -Label '480p').Renamed | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Dir -File).Name | Should -Be @('Grease (1978) - 576p.mkv')
    }
}

Describe 'Rename-ArmUpscaleVersions' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive "nas-$(New-Guid)" 'Grease (1978)'
        $null = New-Item -ItemType Directory -Path $script:Dir -Force
        $script:Src = Join-Path $script:Dir 'Grease (1978).mkv'
        $script:Up = Join-Path $script:Dir 'Grease (1978) [AI upscale 1080p].mkv'
        Set-Content -LiteralPath $script:Src -Value 'raw'
        Set-Content -LiteralPath $script:Up -Value 'up'
    }

    It 'names the upscale "- 1080p" and the source "- <Label>" for height <Height>' -ForEach @(
        @{ Height = 480; Label = '480p' }
        @{ Height = 576; Label = '576p' }
        @{ Height = $null; Label = 'DVD' }
    ) {
        $r = Rename-ArmUpscaleVersions -FolderName 'Grease (1978)' -UpscaledFile $script:Up -SourceFile $script:Src `
            -SourceHeight $Height -Config (New-TestConfig)

        $r.Success | Should -BeTrue
        $r.OutputFile | Should -Be (Join-Path $script:Dir 'Grease (1978) - 1080p.mkv')
        $r.SourceFile | Should -Be (Join-Path $script:Dir "Grease (1978) - $Label.mkv")
        @(Get-ChildItem -LiteralPath $script:Dir -File).Name | Sort-Object | Should -Be @(@('Grease (1978) - 1080p.mkv', "Grease (1978) - $Label.mkv") | Sort-Object)
        (Get-Content -LiteralPath $r.OutputFile -Raw).Trim() | Should -Be 'up'
        (Get-Content -LiteralPath $r.SourceFile -Raw).Trim() | Should -Be 'raw'
    }

    It 'does not throw when the source rename is blocked, and still renames the upscale' {
        Set-Content -LiteralPath (Join-Path $script:Dir 'Grease (1978) - 480p.mkv') -Value 'squatter'
        Mock Write-ArmLog { }

        $r = Rename-ArmUpscaleVersions -FolderName 'Grease (1978)' -UpscaledFile $script:Up -SourceFile $script:Src `
            -SourceHeight 480 -Config (New-TestConfig)

        $r.Success | Should -BeTrue
        $r.OutputRenamed | Should -BeTrue
        $r.SourceRenamed | Should -BeFalse
        $r.SourceFile | Should -Be $script:Src
        Test-Path -LiteralPath (Join-Path $script:Dir 'Grease (1978) - 1080p.mkv') | Should -BeTrue
        Should -Invoke Write-ArmLog -ParameterFilter { $Level -eq 'WARN' }
    }
}

Describe 'Jellyfin naming review fixes' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive "rv-$(New-Guid)" 'Grease (1978)'
        $null = New-Item -ItemType Directory -Path $script:Dir -Force
    }

    It 'Move-ArmExtrasToSubdir returns the kept main feature, and Rename-ArmMainFeature -MainFeature renames exactly that file' {
        Set-Content -LiteralPath (Join-Path $script:Dir 't00.mkv') -Value ('a' * 100)
        Set-Content -LiteralPath (Join-Path $script:Dir 't01.mkv') -Value ('a' * 5000)
        $e = Move-ArmExtrasToSubdir -Dir $script:Dir -Config (New-TestConfig)
        $e.MainFeature | Should -Be (Join-Path $script:Dir 't01.mkv')

        $r = Rename-ArmMainFeature -Dir $script:Dir -Config (New-TestConfig) -MainFeature $e.MainFeature
        $r.Renamed | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Dir 'Grease (1978).mkv') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Dir 'extras' 't00.mkv') | Should -BeTrue
    }

    It 'Move-ArmExtrasToSubdir reports the single mkv as MainFeature' {
        Set-Content -LiteralPath (Join-Path $script:Dir 't00.mkv') -Value 'x'
        (Move-ArmExtrasToSubdir -Dir $script:Dir -Config (New-TestConfig)).MainFeature | Should -Be (Join-Path $script:Dir 't00.mkv')
    }

    It 'Rename-ArmMainFeature renames Upgrade.mkv in folder Up (prefix alone is not a version name)' {
        $up = Join-Path $TestDrive "rv-$(New-Guid)" 'Up'
        $null = New-Item -ItemType Directory -Path $up -Force
        Set-Content -LiteralPath (Join-Path $up 'Upgrade.mkv') -Value 'x'
        (Rename-ArmMainFeature -Dir $up -Config (New-TestConfig)).Renamed | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $up 'Up.mkv') | Should -BeTrue
    }

    It 'Rename-ArmUpscaleVersions labels the upscale with UpscaleHeight' {
        $src = Join-Path $script:Dir 'Grease (1978).mkv'
        $up = Join-Path $script:Dir 'Grease (1978) [AI upscale 1080p].mkv'
        Set-Content -LiteralPath $src -Value 'raw'
        Set-Content -LiteralPath $up -Value 'up'
        $cfg = New-TestConfig
        $cfg.UpscaleHeight = 720
        $r = Rename-ArmUpscaleVersions -FolderName 'Grease (1978)' -UpscaledFile $up -SourceFile $src -SourceHeight 480 -Config $cfg
        $r.OutputFile | Should -Be (Join-Path $script:Dir 'Grease (1978) - 720p.mkv')
        Test-Path -LiteralPath (Join-Path $script:Dir 'Grease (1978) - 480p.mkv') | Should -BeTrue
    }

    It 'Rename-ArmUpscaleVersions leaves the source alone when the upscale rename did not happen' {
        $src = Join-Path $script:Dir 'Grease (1978).mkv'
        $up = Join-Path $script:Dir 'Grease (1978) [AI upscale 1080p].mkv'
        Set-Content -LiteralPath $src -Value 'raw'
        Set-Content -LiteralPath $up -Value 'up'
        Set-Content -LiteralPath (Join-Path $script:Dir 'Grease (1978) - 1080p.mkv') -Value 'squatter'
        Mock Write-ArmLog { }
        $r = Rename-ArmUpscaleVersions -FolderName 'Grease (1978)' -UpscaledFile $up -SourceFile $src -SourceHeight 480 -Config (New-TestConfig)
        $r.Success | Should -BeTrue
        $r.SourceRenamed | Should -BeFalse
        Test-Path -LiteralPath $src | Should -BeTrue
        Test-Path -LiteralPath $up | Should -BeTrue
    }
}
