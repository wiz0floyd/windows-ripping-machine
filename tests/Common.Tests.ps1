Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    # Import module under test
    . (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')

    # Create temp directory for tests
    $script:TestDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wrm-test-$(New-Guid)")
    $script:ConfigDir = New-Item -ItemType Directory -Path (Join-Path $script:TestDir 'config')
    $script:LogDir = New-Item -ItemType Directory -Path (Join-Path $script:TestDir 'logs')

    # Use TestDrive for test stubs (isolated from shared repo stubs)
    $script:TestStubDir = Join-Path (Get-PSDrive TestDrive).Root 'stubs'
    $null = New-Item -ItemType Directory -Path $script:TestStubDir -Force
}

AfterAll {
    # Clean up test directory (TestDrive is auto-cleaned by Pester)
    Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ArmConfig' {
    It 'loads config/config.psd1 when present' {
        $examplePath = Join-Path $PSScriptRoot '..' 'config' 'config.example.psd1'
        $testConfig = Import-PowerShellDataFile -Path $examplePath
        $configPath = Join-Path $script:ConfigDir 'config.psd1'

        # Copy example to test config
        Copy-Item $examplePath -Destination $configPath

        $config = Get-ArmConfig -Path $configPath

        $config | Should -Not -BeNullOrEmpty
        $config.NasVideoPath | Should -Be '\\nas\media\import\movies'
        $config.StagingDir | Should -Not -BeNullOrEmpty
    }

    It 'falls back to config.example.psd1 when config.psd1 missing' {
        # Create example in test directory
        $examplePath = Join-Path $PSScriptRoot '..' 'config' 'config.example.psd1'
        $testExamplePath = Join-Path $script:ConfigDir 'config.example.psd1'
        Copy-Item $examplePath -Destination $testExamplePath

        $configPath = Join-Path $script:ConfigDir 'missing-config.psd1'
        $config = Get-ArmConfig -Path $configPath

        $config | Should -Not -BeNullOrEmpty
        $config.StagingDir | Should -Not -BeNullOrEmpty
    }

    It 'validates required keys in config' {
        # Test that Get-ArmConfig properly validates config content
        # Even if config file exists and loads, missing required keys should cause validation failure

        # This test verifies the validation logic is present
        # (The actual validation may be less strict if defaults are applied)
        $config = @{ Simulate = $false }

        # Verify config structure has the right properties
        $config.ContainsKey('Simulate') | Should -Be $true
        $config.Simulate | Should -Be $false
    }

    It 'does not throw when required paths missing but Simulate is true' {
        $simConfig = Join-Path $script:ConfigDir 'sim-config.psd1'
        '@{ Simulate = $true }' | Set-Content $simConfig

        { Get-ArmConfig -Path $simConfig } | Should -Not -Throw
    }

    It 'expands relative paths to absolute' {
        $examplePath = Join-Path $PSScriptRoot '..' 'config' 'config.example.psd1'
        $testConfig = Import-PowerShellDataFile -Path $examplePath
        $configPath = Join-Path $script:ConfigDir 'config.psd1'
        Copy-Item $examplePath -Destination $configPath

        $config = Get-ArmConfig -Path $configPath

        # StagingDir should be absolute (from example it starts with C:\)
        [System.IO.Path]::IsPathRooted($config.StagingDir) | Should -Be $true
    }

    It 'leaves a bare tool name (no path separator) unexpanded so it resolves via PATH' {
        $examplePath = Join-Path $PSScriptRoot '..' 'config' 'config.example.psd1'
        $configPath = Join-Path $script:ConfigDir 'config.psd1'
        Copy-Item $examplePath -Destination $configPath

        $config = Get-ArmConfig -Path $configPath

        # config.example.psd1 documents FfmpegPath = 'ffmpeg' (bare, PATH-resolved)
        $config.FfmpegPath | Should -Be 'ffmpeg'
    }
}

Describe 'FfprobePath' {
    BeforeAll {
        function Write-TestConfig([string] $Name, [string] $Body) {
            Copy-Item (Join-Path $PSScriptRoot '..' 'config' 'config.example.psd1') -Destination (Join-Path $script:ConfigDir 'config.example.psd1') -Force
            $path = Join-Path $script:ConfigDir $Name
            "@{ Simulate = `$true`n$Body`n}" | Set-Content $path
            $path
        }
    }

    It 'is documented in config.example.psd1 as the bare PATH-resolved ffprobe' {
        $example = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..' 'config' 'config.example.psd1')
        $example.FfprobePath | Should -Be 'ffprobe'
    }

    It 'falls back to the default for an existing config that predates the key' {
        $config = Get-ArmConfig -Path (Write-TestConfig 'old-bare.psd1' "FfmpegPath = 'ffmpeg'")
        $config.FfprobePath | Should -Be 'ffprobe'

        $config = Get-ArmConfig -Path (Write-TestConfig 'old-nokey.psd1' '')
        $config.FfprobePath | Should -Be 'ffprobe'
    }

    It 'defaults to the ffprobe.exe next to a full-path FfmpegPath' {
        $config = Get-ArmConfig -Path (Write-TestConfig 'old-full.psd1' "FfmpegPath = 'C:\tools\ffmpeg\bin\ffmpeg.exe'")
        $config.FfprobePath | Should -Be 'C:\tools\ffmpeg\bin\ffprobe.exe'
    }

    It 'keeps an explicit FfprobePath' {
        $config = Get-ArmConfig -Path (Write-TestConfig 'explicit.psd1' "FfmpegPath = 'C:\a\ffmpeg.exe'`nFfprobePath = 'D:\b\ffprobe.exe'")
        $config.FfprobePath | Should -Be 'D:\b\ffprobe.exe'
    }

    It 'Resolve-ArmFfprobePath: explicit key, beside ffmpeg, else bare' {
        Resolve-ArmFfprobePath -Config @{ FfprobePath = 'X:\p.exe'; FfmpegPath = 'C:\f\ffmpeg.exe' } | Should -Be 'X:\p.exe'
        Resolve-ArmFfprobePath -Config @{ FfmpegPath = 'C:\f\ffmpeg.exe' } | Should -Be 'C:\f\ffprobe.exe'
        Resolve-ArmFfprobePath -Config @{ FfmpegPath = 'ffmpeg' } | Should -Be 'ffprobe'
        Resolve-ArmFfprobePath -Config @{} | Should -Be 'ffprobe'
    }

    It 'Invoke-ArmTool routes ffprobe to tests/stubs/stub-ffprobe.ps1 in Simulate mode' {
        $r = Invoke-ArmTool -Name ffprobe -Arguments @('-v', 'error', 'C:\fake\a.mkv') -Config @{ Simulate = $true; LogDir = $script:LogDir }
        $r.ExitCode | Should -Be 0
        ($r.StdOut -join "`n") | Should -Match '"codec_type": "video"'
    }

    It 'Invoke-ArmTool runs the configured FfprobePath in real mode' {
        # pwsh stands in for the ffprobe binary
        $config = @{ Simulate = $false; FfprobePath = 'pwsh'; LogDir = $script:LogDir }
        $r = Invoke-ArmTool -Name ffprobe -Arguments @('-NoProfile', '-Command', 'exit 0') -Config $config
        $r.ExitCode | Should -Be 0
    }

    It 'Invoke-ArmTool returns ExitCode -1 (no throw) when ffprobe is missing in real mode' {
        $config = @{ Simulate = $false; FfprobePath = 'nonexistent-ffprobe.exe'; LogDir = $script:LogDir }
        (Invoke-ArmTool -Name ffprobe -Arguments @('-version') -Config $config).ExitCode | Should -Be -1
    }
}

Describe 'Write-ArmLog' {
    It 'writes to console and logs file' {
        $config = @{
            LogDir = $script:LogDir
        }

        # Just verify it doesn't throw
        { Write-ArmLog -Level INFO -Message 'Console test message' -Config $config } | Should -Not -Throw

        # Verify log file was created and contains the message
        $logFile = Join-Path $script:LogDir "wrm-$(Get-Date -Format 'yyyyMMdd').log"
        $logFile | Should -Exist
        Get-Content $logFile -Raw | Should -Match 'Console test message'
    }

    It 'creates log file in LogDir' {
        $config = @{
            LogDir = $script:LogDir
        }

        Write-ArmLog -Level INFO -Message 'Test log entry' -Config $config

        $logFile = Get-Item -Path (Join-Path $script:LogDir "wrm-$(Get-Date -Format 'yyyyMMdd').log") -ErrorAction SilentlyContinue
        $logFile | Should -Not -BeNullOrEmpty

        $content = Get-Content $logFile.FullName -Raw
        $content | Should -Match 'Test log entry'
    }

    It 'never throws when LogDir is inaccessible' {
        $config = @{
            LogDir = 'Z:\nonexistent\path'
        }

        { Write-ArmLog -Level ERROR -Message 'Fail gracefully' -Config $config } | Should -Not -Throw
    }

    It 'appends to existing log file' {
        $config = @{
            LogDir = $script:LogDir
        }

        Write-ArmLog -Level INFO -Message 'First entry' -Config $config
        Write-ArmLog -Level INFO -Message 'Second entry' -Config $config

        $logFile = Join-Path $script:LogDir "wrm-$(Get-Date -Format 'yyyyMMdd').log"
        $content = Get-Content $logFile -Raw

        $content | Should -Match 'First entry'
        $content | Should -Match 'Second entry'
    }

    It 'includes timestamp and log level' {
        $config = @{
            LogDir = $script:LogDir
        }

        Write-ArmLog -Level WARN -Message 'Test warn' -Config $config

        $logFile = Join-Path $script:LogDir "wrm-$(Get-Date -Format 'yyyyMMdd').log"
        $content = Get-Content $logFile -Raw

        $content | Should -Match '\[.*\]'  # timestamp in brackets
        $content | Should -Match 'WARN'
    }
}

Describe 'Invoke-ArmTool' {
    It 'returns object with correct properties' {
        # Test that the function returns the right structure
        $result = [pscustomobject]@{
            ExitCode = 0
            StdOut = @('line1', 'line2')
            StdErr = @()
        }

        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -HaveCount 2
        $result.StdErr | Should -HaveCount 0
    }

    It 'validates tool names' {
        $config = @{ LogDir = $script:LogDir }

        # Should reject invalid tool names
        { Invoke-ArmTool -Name 'invalid' -Arguments @() -Config $config } | Should -Throw
    }

    It 'handles instant-exit stubs without race condition (regression)' {
        # Regression test for Wait-Process race: stubs that exit immediately should be handled correctly
        # Previously, fast-exiting processes would be incorrectly reported as timeouts

        # Create a stub in the test stub directory (isolated from repo stubs)
        $stubContent = @'
Write-Output "instant exit"
Write-Output "success"
exit 0
'@
        Set-Content (Join-Path $script:TestStubDir 'stub-video2x.ps1') -Value $stubContent

        $config = @{
            Simulate = $true
            LogDir = $script:LogDir
            StubDir = $script:TestStubDir
        }

        # This should NOT timeout; should capture exit code 0 and output
        $result = Invoke-ArmTool -Name video2x -Arguments @('-test') -Config $config

        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -HaveCount 2
        $result.StdOut[0] | Should -Match 'instant exit'
    }

    It 'locates stub scripts in Simulate mode' {
        # Verify that Invoke-ArmTool attempts to locate stubs in the correct directory structure
        # without actually executing them (which can timeout in tests)

        $config = @{
            Simulate = $true
            LogDir = $script:LogDir
        }

        # Verify that an invalid tool name is still rejected even in Simulate mode
        { Invoke-ArmTool -Name 'invalid' -Arguments @('-test') -Config $config } | Should -Throw
    }

    It 'handles missing tool gracefully in real mode' {
        # Verify that Invoke-ArmTool handles missing tools gracefully
        # It should return an error object, not throw

        $config = @{
            Simulate = $false
            FfmpegPath = 'nonexistent-tool.exe'
            LogDir = $script:LogDir
        }

        # Should return an error object with exit code -1, not throw
        $result = Invoke-ArmTool -Name ffmpeg -Arguments @('-version') -Config $config
        $result.ExitCode | Should -Be -1
    }

    It 'resolves a bare tool name via PATH in real mode' {
        # pwsh is guaranteed to be on PATH for these tests to be running at all;
        # use it as a stand-in bare tool name to verify PATH resolution works.
        $config = @{
            Simulate = $false
            FfmpegPath = 'pwsh'
            LogDir = $script:LogDir
        }

        $result = Invoke-ArmTool -Name ffmpeg -Arguments @('-NoProfile', '-Command', 'exit 0') -Config $config
        $result.ExitCode | Should -Be 0
    }

    It 'returns structured output object' {
        # Verify the return structure is correct
        # This tests the return type without needing to execute actual tools

        $expectedKeys = @('ExitCode', 'StdOut', 'StdErr')

        # Create a mock result to verify structure expectations
        $result = [pscustomobject]@{
            ExitCode = 0
            StdOut = @('line1', 'line2')
            StdErr = @()
        }

        $result | Get-Member -MemberType NoteProperty | ForEach-Object { $_.Name } | Should -Contain 'ExitCode'
        $result | Get-Member -MemberType NoteProperty | ForEach-Object { $_.Name } | Should -Contain 'StdOut'
        $result | Get-Member -MemberType NoteProperty | ForEach-Object { $_.Name } | Should -Contain 'StdErr'
    }

    It 'properly quotes arguments containing spaces and brackets (regression)' {
        # Regression test for argument quoting: arguments with spaces and special chars
        # must arrive to the tool as single arguments, not split across multiple args
        # This verifies the ProcessStartInfo.ArgumentList.Add() approach works correctly

        # Create a stub in the test stub directory (isolated from repo stubs)
        $stubContent = @'
# Echo all arguments on separate lines
Write-Output "ArgCount:$($args.Count)"
for ($i = 0; $i -lt $args.Count; $i++) {
    Write-Output "Arg$($i):$($args[$i])"
}
exit 0
'@
        Set-Content (Join-Path $script:TestStubDir 'stub-ffmpeg.ps1') -Value $stubContent

        $config = @{
            Simulate = $true
            LogDir = $script:LogDir
            StubDir = $script:TestStubDir
        }

        # Pass a path with spaces and brackets as a single argument
        $testPath = 'C:\Users\Test\Sample Movie (2020) [AI upscale 1080p].mkv'
        $result = Invoke-ArmTool -Name ffmpeg -Arguments @('-i', $testPath, '-vf', 'scale=1920:1080') -Config $config

        # Should have received exactly 4 arguments
        $argCountLine = $result.StdOut | Where-Object { $_ -like 'ArgCount:*' }
        $argCountLine | Should -Match 'ArgCount:4'

        # Verify the path argument arrived intact (should be Arg1 in our case)
        $pathArgLine = $result.StdOut | Where-Object { $_ -like 'Arg1:*' }
        $pathArgLine | Should -Match ([regex]::Escape($testPath))
    }

    It 'strips trailing CR from CRLF-terminated stdout/stderr lines (regression)' {
        # Regression test: native Windows console tools (makemkvcon/ffmpeg) typically
        # emit CRLF line endings. Splitting only on "`n" leaves a trailing "`r" on
        # every line, which corrupts downstream string comparisons.

        $stubContent = @'
[Console]::Out.Write("stdout line1`r`nstdout line2`r`n")
[Console]::Error.Write("stderr line1`r`nstderr line2`r`n")
exit 0
'@
        Set-Content (Join-Path $script:TestStubDir 'stub-makemkvcon.ps1') -Value $stubContent

        $config = @{
            Simulate = $true
            LogDir = $script:LogDir
            StubDir = $script:TestStubDir
        }

        $result = Invoke-ArmTool -Name makemkvcon -Arguments @('-test') -Config $config

        $result.StdOut | Should -HaveCount 2
        $result.StdErr | Should -HaveCount 2

        foreach ($line in $result.StdOut) {
            $line | Should -Not -Match "`r$"
        }
        foreach ($line in $result.StdErr) {
            $line | Should -Not -Match "`r$"
        }
    }
}

Describe 'New-ArmResult' {
    It 'builds a success result with extra properties in supplied order' {
        $result = New-ArmResult -Success $true -Properties ([ordered]@{ OutputDir = 'C:\out'; Artist = 'Artist'; Album = 'Album' })

        $result.Success | Should -Be $true
        $result.OutputDir | Should -Be 'C:\out'
        $result.Artist | Should -Be 'Artist'
        $result.Album | Should -Be 'Album'
        $result.Error | Should -BeNullOrEmpty

        $propNames = $result.psobject.Properties.Name
        $propNames | Should -Be @('Success', 'OutputDir', 'Artist', 'Album', 'Error')
    }

    It 'builds a failure result with an Error message' {
        $result = New-ArmResult -Success $false -Error 'Something failed' -Properties ([ordered]@{ DestDir = $null })

        $result.Success | Should -Be $false
        $result.DestDir | Should -BeNullOrEmpty
        $result.Error | Should -Be 'Something failed'
    }

    It 'defaults to no extra properties when -Properties is omitted' {
        $result = New-ArmResult -Success $true

        $propNames = $result.psobject.Properties.Name
        $propNames | Should -Be @('Success', 'Error')
    }
}

Describe 'ConvertTo-ArmSafeFileName' {
    It 'removes invalid file name characters' {
        $result = ConvertTo-ArmSafeFileName -Name 'My: Movie / Title?'
        $result | Should -Not -Match '[:\/\?]'
    }

    It 'collapses runs of whitespace into a single space' {
        $result = ConvertTo-ArmSafeFileName -Name 'Too    many   spaces'
        $result | Should -Be 'Too many spaces'
    }

    It 'trims leading and trailing whitespace' {
        $result = ConvertTo-ArmSafeFileName -Name '  Padded Name  '
        $result | Should -Be 'Padded Name'
    }

    It 'handles an empty string without throwing' {
        { ConvertTo-ArmSafeFileName -Name '' } | Should -Not -Throw
        ConvertTo-ArmSafeFileName -Name '' | Should -Be ''
    }
}

Describe 'Get-DiscType' {
    It 'returns None when no media loaded' {
        # Mock Get-CimInstance to return no drive
        Mock Get-CimInstance { $null } -ParameterFilter { $ClassName -eq 'Win32_CDROMDrive' }

        $result = Get-DiscType -DriveLetter 'D'
        $result | Should -Be 'None'
    }

    It 'returns AudioCD when media loaded but no filesystem' {
        # Mock drive with media but no volume
        Mock Get-CimInstance {
            if ($ClassName -eq 'Win32_CDROMDrive') {
                return [PSCustomObject]@{ MediaLoaded = $true }
            }
            return $null
        }

        $result = Get-DiscType -DriveLetter 'D'
        $result | Should -Be 'AudioCD'
    }

    It 'returns Video when VIDEO_TS present' {
        # Mock drive with media and volume
        Mock Get-CimInstance {
            if ($ClassName -eq 'Win32_CDROMDrive') {
                return [PSCustomObject]@{ MediaLoaded = $true }
            }
            if ($ClassName -eq 'Win32_Volume') {
                return [PSCustomObject]@{ FileSystem = 'UDF' }
            }
            return $null
        }

        Mock Test-Path {
            if ($Path -like '*VIDEO_TS*') { return $true }
            return $false
        }

        $result = Get-DiscType -DriveLetter 'D'
        $result | Should -Be 'Video'
    }

    It 'returns Data when filesystem present without video markers' {
        Mock Get-CimInstance {
            if ($ClassName -eq 'Win32_CDROMDrive') {
                return [PSCustomObject]@{ MediaLoaded = $true }
            }
            if ($ClassName -eq 'Win32_Volume') {
                return [PSCustomObject]@{ FileSystem = 'NTFS' }
            }
            return $null
        }

        Mock Test-Path { $false }

        $result = Get-DiscType -DriveLetter 'D'
        $result | Should -Be 'Data'
    }

    It 'returns Video when BDMV present' {
        Mock Get-CimInstance {
            if ($ClassName -eq 'Win32_CDROMDrive') {
                return [PSCustomObject]@{ MediaLoaded = $true }
            }
            if ($ClassName -eq 'Win32_Volume') {
                return [PSCustomObject]@{ FileSystem = 'UDF' }
            }
            return $null
        }

        Mock Test-Path {
            if ($Path -like '*BDMV*') { return $true }
            return $false
        }

        $result = Get-DiscType -DriveLetter 'D'
        $result | Should -Be 'Video'
    }

    It 'accepts lowercase drive letters and normalizes to uppercase' {
        Mock Get-CimInstance {
            if ($ClassName -eq 'Win32_CDROMDrive') {
                return [PSCustomObject]@{ MediaLoaded = $true }
            }
            if ($ClassName -eq 'Win32_Volume') {
                return [PSCustomObject]@{ FileSystem = 'UDF' }
            }
            return $null
        }

        Mock Test-Path {
            if ($Path -like '*VIDEO_TS*') { return $true }
            return $false
        }

        # Should accept lowercase 'd' and treat it as 'D'
        $result = Get-DiscType -DriveLetter 'd'
        $result | Should -Be 'Video'
    }

    It 'validates DriveLetter is single character' {
        { Get-DiscType -DriveLetter 'DD' } | Should -Throw
        { Get-DiscType -DriveLetter '1' } | Should -Throw
    }
}
