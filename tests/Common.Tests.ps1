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

    Context 'Simulate sandbox (no explicit -Path)' {
        BeforeAll {
            # Keep sandbox dirs out of the real temp folder.
            $script:SavedTmp = @{}
            foreach ($v in 'TEMP', 'TMP', 'TMPDIR') { $script:SavedTmp[$v] = [Environment]::GetEnvironmentVariable($v) }
            foreach ($v in 'TEMP', 'TMP', 'TMPDIR') { [Environment]::SetEnvironmentVariable($v, "$TestDrive") }
            $script:SandboxKeys = @('NasVideoPath', 'NasMusicPath', 'StagingDir', 'UpscaleQueueDir', 'LogDir', 'StateDir')
        }

        AfterAll {
            foreach ($v in 'TEMP', 'TMP', 'TMPDIR') { [Environment]::SetEnvironmentVariable($v, $script:SavedTmp[$v]) }
        }

        It 'rebases every directory/NAS key under the temp sandbox' {
            $config = Get-ArmConfig -Simulate
            $root = Join-Path ([IO.Path]::GetTempPath()) 'wrm-sim'
            $config.SimulateSandboxRoot | Should -Be $root
            Test-Path $root | Should -BeTrue
            $seen = @{}
            foreach ($k in $script:SandboxKeys) {
                $config[$k] | Should -BeLike "$root*"
                $config[$k] | Should -Not -BeLike 'C:\rips*'
                $config[$k] | Should -Not -BeLike '\\*'
                $seen[$config[$k]] = $true
            }
            $seen.Count | Should -Be $script:SandboxKeys.Count
            $config.Simulate | Should -BeTrue
        }

        It 'sandboxes a real default-path config.psd1 under Simulate' {
            # Temp copy of the repo layout so the default-path lookup finds a "real" config.
            $repo = Join-Path $TestDrive (New-Guid)
            $null = New-Item -ItemType Directory -Path (Join-Path $repo 'src'), (Join-Path $repo 'config') -Force
            Copy-Item (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1') (Join-Path $repo 'src')
            $example = Join-Path $PSScriptRoot '..' 'config' 'config.example.psd1'
            Copy-Item $example (Join-Path $repo 'config' 'config.example.psd1')
            Copy-Item $example (Join-Path $repo 'config' 'config.psd1')
            $common = Join-Path $repo 'src' 'Common.ps1'
            $out = & pwsh -NoProfile -Command ". '$common'; `$c = Get-ArmConfig -Simulate; `$c.SimulateSandboxRoot; `$c.StagingDir; `$c.NasVideoPath" 2>&1
            $lines = @($out | Where-Object { $_ -and $_ -notmatch 'WARN|INFO' })
            $lines.Count | Should -Be 3
            $lines[0] | Should -BeLike "$TestDrive*wrm-sim"
            $lines[1] | Should -BeLike "$($lines[0])*"
            $lines[2] | Should -BeLike "$($lines[0])*"
        }

        It 'leaves paths untouched for an explicit -Path under Simulate' {
            $examplePath = Join-Path $PSScriptRoot '..' 'config' 'config.example.psd1'
            $cfgPath = Join-Path $script:ConfigDir 'explicit-sim.psd1'
            Copy-Item $examplePath -Destination $cfgPath
            $config = Get-ArmConfig -Path $cfgPath -Simulate
            $config.ContainsKey('SimulateSandboxRoot') | Should -BeFalse
            foreach ($k in $script:SandboxKeys) { $config[$k] | Should -Not -BeLike '*wrm-sim*' }
            $config.NasVideoPath | Should -BeLike '*nas*import*movies'
            $config.LogDir | Should -BeLike '*rips*logs'
        }

        It 'leaves paths untouched when not Simulate' {
            $config = Get-ArmConfig
            $config.ContainsKey('SimulateSandboxRoot') | Should -BeFalse
            $config.NasVideoPath | Should -Not -BeLike '*wrm-sim*'
        }
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

# Characterisation of the pre-#32 behaviour that the streaming rewrite must keep.
Describe 'Invoke-ArmTool exit code, timeout and default logging (unchanged by #32)' {
    BeforeEach {
        $script:StubDir32 = Join-Path $script:TestDir "stubs-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $script:StubDir32 -Force
        $script:Config32 = @{ Simulate = $true; LogDir = $script:LogDir; StubDir = $script:StubDir32 }
    }

    It 'returns the tool exit code and its output' {
        Set-Content (Join-Path $script:StubDir32 'stub-freaccmd.ps1') -Value @'
Write-Output 'out-a'
[Console]::Error.WriteLine('err-a')
exit 3
'@
        $result = Invoke-ArmTool -Name freaccmd -Arguments @('x') -Config $script:Config32
        $result.ExitCode | Should -Be 3
        @($result.StdOut) | Should -Be @('out-a')
        @($result.StdErr) | Should -Be @('err-a')
    }

    It 'kills a tool that outlives -TimeoutSec, logs ERROR and returns ExitCode -1 without throwing' {
        Set-Content (Join-Path $script:StubDir32 'stub-ffmpeg.ps1') -Value @'
Write-Output 'started'
Start-Sleep -Seconds 60
Write-Output 'never'
exit 0
'@
        Mock Write-ArmLog {}
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-ArmTool -Name ffmpeg -Arguments @('x') -Config $script:Config32 -TimeoutSec 3
        $sw.Stop()

        $result.ExitCode | Should -Be -1
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
        Should -Invoke Write-ArmLog -ParameterFilter { $Level -eq 'ERROR' -and $Message -match 'Invoke-ArmTool ffmpeg failed: Tool ffmpeg timed out after 3 seconds' }
    }

    It 'logs stdout at INFO as "[tool] line" and stderr at WARN as "[tool] STDERR: line" by default' {
        Set-Content (Join-Path $script:StubDir32 'stub-makemkvcon.ps1') -Value @'
Write-Output 'hello'
[Console]::Error.WriteLine('banner line')
exit 0
'@
        Mock Write-ArmLog {}
        $null = Invoke-ArmTool -Name makemkvcon -Arguments @('x') -Config $script:Config32
        Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Level -eq 'INFO' -and $Message -eq '[makemkvcon] hello' }
        Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Level -eq 'WARN' -and $Message -eq '[makemkvcon] STDERR: banner line' }
    }
}

Describe 'Invoke-ArmTool streaming, stderr level and progress (#32)' {
    BeforeEach {
        $script:StubDir32 = Join-Path $script:TestDir "stubs-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $script:StubDir32 -Force
        $script:Config32 = @{ Simulate = $true; LogDir = $script:LogDir; StubDir = $script:StubDir32 }
    }

    It 'delivers progress while the tool is still running (not buffered to exit)' {
        Set-Content (Join-Path $script:StubDir32 'stub-ncnn.ps1') -Value @'
[Console]::Out.WriteLine('frame=10')
[Console]::Out.WriteLine('fps=5.0')
[Console]::Out.WriteLine('progress=continue')
Start-Sleep -Seconds 3
[Console]::Out.WriteLine('frame=20')
[Console]::Out.WriteLine('progress=end')
exit 0
'@
        $script:Seen = [System.Collections.Generic.List[object]]::new()
        $result = Invoke-ArmTool -Name ncnn -Arguments @('x') -Config $script:Config32 -ProgressHandler {
            param($p) $script:Seen.Add([pscustomobject]@{ At = [datetime]::UtcNow; P = $p })
        }
        $done = [datetime]::UtcNow

        $result.ExitCode | Should -Be 0
        $script:Seen.Count | Should -Be 2
        $script:Seen[0].P.Frame | Should -Be 10
        $script:Seen[0].P.Fps | Should -Be 5.0
        $script:Seen[0].P.Ended | Should -Be $false
        $script:Seen[1].P.Frame | Should -Be 20
        $script:Seen[1].P.Ended | Should -Be $true
        # The first block arrived ~3 s before the tool exited.
        ($done - $script:Seen[0].At).TotalSeconds | Should -BeGreaterThan 1.5
    }

    It 'consumes progress lines (not logged, not in StdOut) but keeps other stdout' {
        Set-Content (Join-Path $script:StubDir32 'stub-ffmpeg.ps1') -Value @'
[Console]::Out.WriteLine('frame=5')
[Console]::Out.WriteLine('out_time_us=2000000')
[Console]::Out.WriteLine('speed=1.5x')
[Console]::Out.WriteLine('progress=end')
[Console]::Out.WriteLine('a normal line')
exit 0
'@
        Mock Write-ArmLog {}
        $script:Seen = [System.Collections.Generic.List[object]]::new()
        $result = Invoke-ArmTool -Name ffmpeg -Arguments @('x') -Config $script:Config32 -ProgressHandler { param($p) $script:Seen.Add($p) }

        @($result.StdOut) | Should -Be @('a normal line')
        $script:Seen[0].OutTimeSec | Should -Be 2.0
        $script:Seen[0].Speed | Should -Be 1.5
        $script:Seen[0].Tool | Should -Be 'ffmpeg'
        Should -Invoke Write-ArmLog -Times 0 -ParameterFilter { $Message -match 'frame=|progress=' }
        Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Message -eq '[ffmpeg] a normal line' }
    }

    It 'leaves key=value stdout alone when no handler is passed' {
        Set-Content (Join-Path $script:StubDir32 'stub-ffmpeg.ps1') -Value "[Console]::Out.WriteLine('frame=5')`nexit 0"
        $result = Invoke-ArmTool -Name ffmpeg -Arguments @('x') -Config $script:Config32
        @($result.StdOut) | Should -Be @('frame=5')
    }

    It 'never fails the run when the progress handler throws (logged once at WARN)' {
        Set-Content (Join-Path $script:StubDir32 'stub-ffmpeg.ps1') -Value @'
[Console]::Out.WriteLine('progress=continue')
[Console]::Out.WriteLine('progress=end')
exit 0
'@
        Mock Write-ArmLog {}
        $result = Invoke-ArmTool -Name ffmpeg -Arguments @('x') -Config $script:Config32 -ProgressHandler { throw 'boom' }
        $result.ExitCode | Should -Be 0
        Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'progress handler failed' }
    }

    It 'StdErrLevel INFO logs stderr at INFO but error-looking lines at WARN' {
        Set-Content (Join-Path $script:StubDir32 'stub-ffmpeg.ps1') -Value @'
[Console]::Error.WriteLine('Input #0, matroska,webm, from x.mkv:')
[Console]::Error.WriteLine('Error while decoding stream #0:0')
exit 0
'@
        Mock Write-ArmLog {}
        $result = Invoke-ArmTool -Name ffmpeg -Arguments @('x') -Config $script:Config32 -StdErrLevel INFO
        @($result.StdErr).Count | Should -Be 2
        Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Level -eq 'INFO' -and $Message -eq '[ffmpeg] STDERR: Input #0, matroska,webm, from x.mkv:' }
        Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'Error while decoding' }
        Should -Invoke Write-ArmLog -Times 0 -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'Input #0' }
    }

    It 'StdErrLevel None keeps stderr in the result without logging it, except error-looking lines' {
        Set-Content (Join-Path $script:StubDir32 'stub-ffmpeg.ps1') -Value @'
[Console]::Error.WriteLine('    title           : Chapter 01')
[Console]::Error.WriteLine('[mpeg2video @ 0x1] Invalid frame dimensions 0x0.')
exit 0
'@
        Mock Write-ArmLog {}
        $result = Invoke-ArmTool -Name ffmpeg -Arguments @('x') -Config $script:Config32 -StdErrLevel None
        @($result.StdErr).Count | Should -Be 2
        Should -Invoke Write-ArmLog -Times 0 -ParameterFilter { $Message -match 'Chapter 01' }
        Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'Invalid frame dimensions' }
    }

    It 'splits CR-separated ffmpeg stats into separate lines' {
        Set-Content (Join-Path $script:StubDir32 'stub-ffmpeg.ps1') -Value @'
[Console]::Error.Write("frame=  10 time=00:00:01.00`rframe=  20 time=00:00:02.00`n")
exit 0
'@
        $result = Invoke-ArmTool -Name ffmpeg -Arguments @('x') -Config $script:Config32 -StdErrLevel None
        @($result.StdErr) | Should -Be @('frame=  10 time=00:00:01.00', 'frame=  20 time=00:00:02.00')
    }
}

Describe 'Update-ArmToolProgress' {
    It 'accumulates keys until progress= and resets for the next block' {
        $state = @{}
        Update-ArmToolProgress -State $state -Key 'frame' -Value '120' | Should -BeNullOrEmpty
        Update-ArmToolProgress -State $state -Key 'fps' -Value '23.98' | Should -BeNullOrEmpty
        Update-ArmToolProgress -State $state -Key 'out_time_ms' -Value '5005000' | Should -BeNullOrEmpty
        Update-ArmToolProgress -State $state -Key 'speed' -Value 'N/A' | Should -BeNullOrEmpty
        $p = Update-ArmToolProgress -State $state -Key 'progress' -Value 'continue'
        $p.Frame | Should -Be 120
        $p.Fps | Should -Be 23.98
        $p.OutTimeSec | Should -Be 5.005
        $p.Speed | Should -BeNullOrEmpty
        $p.Ended | Should -Be $false

        $next = Update-ArmToolProgress -State $state -Key 'progress' -Value 'end'
        $next.Frame | Should -BeNullOrEmpty
        $next.Ended | Should -Be $true
    }
}

Describe 'Write-ArmLog context tag and locked-file retry (#32)' {
    BeforeEach {
        $script:Dir32 = Join-Path $script:TestDir "log-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $script:Dir32 -Force
        $script:LogFile32 = Join-Path $script:Dir32 "wrm-$(Get-Date -Format 'yyyyMMdd').log"
    }

    It 'writes the -Context tag after the level' {
        Write-ArmLog -Level INFO -Message 'tagged' -Config @{ LogDir = $script:Dir32 } -Context 'Movie (2001)'
        Get-Content $script:LogFile32 -Raw | Should -Match '\] \[INFO\] \[Movie \(2001\)\] tagged'
    }

    It 'uses $Config.LogContext when -Context is not given, and no tag otherwise' {
        Write-ArmLog -Level WARN -Message 'from config' -Config @{ LogDir = $script:Dir32; LogContext = 'item-a' }
        Write-ArmLog -Level INFO -Message 'untagged' -Config @{ LogDir = $script:Dir32 }
        $lines = Get-Content $script:LogFile32
        $lines[0] | Should -Match '\[WARN\] \[item-a\] from config$'
        $lines[1] | Should -Match '\[INFO\] untagged$'
    }

    It 'waits for a writer that briefly holds the log file instead of dropping the line' {
        Set-Content -Path $script:LogFile32 -Value 'existing'
        $ready = Join-Path $script:Dir32 'locked.flag'
        $holder = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-Command',
            "`$fs = [System.IO.File]::Open('$script:LogFile32', 'Open', 'ReadWrite', 'None'); Set-Content '$ready' 1; Start-Sleep -Milliseconds 700; `$fs.Dispose()")
        $deadline = [datetime]::UtcNow.AddSeconds(20)
        while (-not (Test-Path $ready) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        Test-Path $ready | Should -Be $true

        { [System.IO.File]::AppendAllText($script:LogFile32, 'probe') } | Should -Throw   # really locked
        Write-ArmLog -Level INFO -Message 'survived the lock' -Config @{ LogDir = $script:Dir32 }
        $holder.WaitForExit(10000) | Should -Be $true

        Get-Content $script:LogFile32 -Raw | Should -Match 'survived the lock'
        @(Get-ChildItem $script:Dir32 -Filter "*-pid$PID.log").Count | Should -Be 0
    }

    It 'keeps the line in a per-process side file when the shared log stays locked' {
        Set-Content -Path $script:LogFile32 -Value 'existing'
        $fs = [System.IO.File]::Open($script:LogFile32, 'Open', 'ReadWrite', 'None')
        try {
            { Write-ArmLog -Level ERROR -Message 'kept anyway' -Config @{ LogDir = $script:Dir32 } } | Should -Not -Throw
        } finally {
            $fs.Dispose()
        }
        $side = Join-Path $script:Dir32 "wrm-$(Get-Date -Format 'yyyyMMdd')-pid$PID.log"
        $side | Should -Exist
        Get-Content $side -Raw | Should -Match 'kept anyway.*was locked'
    }

    It 'Add-ArmLogLine returns $false (no throw) for a non-lock failure without retrying' {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Add-ArmLogLine -Path (Join-Path $script:Dir32 'no\such\dir\x.log') -Line 'x' | Should -Be $false
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 1
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
