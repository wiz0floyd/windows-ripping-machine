Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    # Cross-module functions (Rip-VideoDisc.ps1, Resolve-Title.ps1) may not exist
    # yet in a fresh checkout; define stand-ins matching the SPEC signatures so
    # Mock has a command to attach to regardless of build order.
    $script:VideoRipModule = Join-Path $PSScriptRoot '..' 'src' 'Rip-VideoDisc.ps1'
    $script:ResolveTitleModule = Join-Path $PSScriptRoot '..' 'src' 'Resolve-Title.ps1'

    $script:videoRipLoaded = $false
    if (Test-Path $script:VideoRipModule) {
        try {
            . $script:VideoRipModule
            $script:videoRipLoaded = $true
        } catch {
            Write-Warning "DiscWatcher.Tests: Rip-VideoDisc.ps1 exists but failed to load (falling back to stub): $_"
        }
    }
    if (-not $script:videoRipLoaded) {
        function Invoke-VideoRip {
            param([char] $DriveLetter, [hashtable] $Config)
            [pscustomobject]@{ Success = $true; DiscLabel = 'STUB'; DiscType = 'DVD'; OutputDir = ''; TitleCount = 1; Error = $null }
        }
    }

    $script:resolveTitleLoaded = $false
    if (Test-Path $script:ResolveTitleModule) {
        try {
            . $script:ResolveTitleModule
            $script:resolveTitleLoaded = $true
        } catch {
            Write-Warning "DiscWatcher.Tests: Resolve-Title.ps1 exists but failed to load (falling back to stub): $_"
        }
    }
    if (-not $script:resolveTitleLoaded) {
        function Resolve-Title {
            param([string] $DiscLabel, [hashtable] $Config)
            [pscustomobject]@{ FolderName = 'STUB_TITLE'; Matched = $false; Title = $null; Year = $null }
        }
    }

    # Rip-AudioCd.ps1, Move-ToNas.ps1, Send-Notification.ps1, Common.ps1 are
    # expected to exist (other agents own them); dot-source normally.
    . (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Rip-AudioCd.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Move-ToNas.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Send-Notification.ps1')

    # Dot-source DiscWatcher.ps1 itself (guarded: no loop/hardware access on dot-source).
    . (Join-Path $PSScriptRoot '..' 'src' 'DiscWatcher.ps1')

    function New-TestConfig {
        param([string] $StagingDir, [string] $NasVideoPath, [string] $NasMusicPath, [string] $UpscaleQueueDir)
        @{
            NasVideoPath      = $NasVideoPath
            NasMusicPath      = $NasMusicPath
            StagingDir        = $StagingDir
            UpscaleQueueDir   = $UpscaleQueueDir
            LogDir            = Join-Path $StagingDir 'logs'
            MinTitleLengthSec = 600
            RipAllTitles      = $true
            EjectWhenDone     = $true
            TmdbApiKey        = ''
            HaWebhookUrl      = ''
            UpscaleDvds       = $false
            AutoUpscale       = $false
            Simulate          = $true
        }
    }
}

Describe 'Invoke-DiscDispatch' {
    BeforeEach {
        $script:TestRoot = Join-Path $TestDrive (New-Guid)
        $script:StagingDir = Join-Path $script:TestRoot 'staging'
        $script:NasVideoRoot = Join-Path $script:TestRoot 'nas-video'
        $script:NasMusicRoot = Join-Path $script:TestRoot 'nas-music'
        $script:QueueDir = Join-Path $script:TestRoot 'queue'
        New-Item -ItemType Directory -Force -Path $script:StagingDir, $script:NasVideoRoot, $script:NasMusicRoot, $script:QueueDir | Out-Null

        $script:Config = New-TestConfig -StagingDir $script:StagingDir -NasVideoPath $script:NasVideoRoot `
            -NasMusicPath $script:NasMusicRoot -UpscaleQueueDir $script:QueueDir

        Mock Send-ArmNotification { }
        Mock Invoke-DiscEject { }
    }

    Context 'Video disc' {
        It 'rips, resolves title, renames staging dir, moves to NAS, and notifies success' {
            $ripOutputDir = Join-Path $script:StagingDir 'RAW_LABEL'
            New-Item -ItemType Directory -Force -Path $ripOutputDir | Out-Null
            'fake mkv bytes' | Set-Content (Join-Path $ripOutputDir 'title1.mkv')

            Mock Invoke-VideoRip {
                [pscustomobject]@{
                    Success = $true; DiscLabel = 'RAW_LABEL'; DiscType = 'BD'
                    OutputDir = $ripOutputDir; TitleCount = 1; Error = $null
                }
            }
            Mock Resolve-Title {
                [pscustomobject]@{ FolderName = 'My Movie (2020)'; Matched = $true; Title = 'My Movie'; Year = 2020 }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            $expectedDest = Join-Path $script:NasVideoRoot 'My Movie (2020)'
            Test-Path $expectedDest | Should -BeTrue
            Test-Path (Join-Path $expectedDest 'title1.mkv') | Should -BeTrue
            Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter { $Level -eq 'Info' }
            Should -Invoke Invoke-DiscEject -Times 1
        }

        It 'queues an upscale job when DVD and UpscaleDvds is true' {
            $script:Config.UpscaleDvds = $true
            $ripOutputDir = Join-Path $script:StagingDir 'RAW_LABEL'
            New-Item -ItemType Directory -Force -Path $ripOutputDir | Out-Null
            'x' * 100 | Set-Content (Join-Path $ripOutputDir 'small.mkv')
            'x' * 500 | Set-Content (Join-Path $ripOutputDir 'big.mkv')

            Mock Invoke-VideoRip {
                [pscustomobject]@{
                    Success = $true; DiscLabel = 'RAW_LABEL'; DiscType = 'DVD'
                    OutputDir = $ripOutputDir; TitleCount = 2; Error = $null
                }
            }
            Mock Resolve-Title {
                [pscustomobject]@{ FolderName = 'DVD Movie (1999)'; Matched = $true; Title = 'DVD Movie'; Year = 1999 }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            $queueFile = Join-Path $script:QueueDir 'DVD Movie (1999).json'
            Test-Path $queueFile | Should -BeTrue
            $entry = Get-Content $queueFile -Raw | ConvertFrom-Json
            $entry.Source | Should -Match 'big\.mkv$'
            $entry.DestDir | Should -Match 'DVD Movie \(1999\)$'
        }

        It 'does not queue an upscale job for BD discs even when UpscaleDvds is true' {
            $script:Config.UpscaleDvds = $true
            $ripOutputDir = Join-Path $script:StagingDir 'RAW_LABEL'
            New-Item -ItemType Directory -Force -Path $ripOutputDir | Out-Null
            'x' | Set-Content (Join-Path $ripOutputDir 'title1.mkv')

            Mock Invoke-VideoRip {
                [pscustomobject]@{
                    Success = $true; DiscLabel = 'RAW_LABEL'; DiscType = 'BD'
                    OutputDir = $ripOutputDir; TitleCount = 1; Error = $null
                }
            }
            Mock Resolve-Title {
                [pscustomobject]@{ FolderName = 'BD Movie (2021)'; Matched = $true; Title = 'BD Movie'; Year = 2021 }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            @(Get-ChildItem $script:QueueDir -Filter '*.json').Count | Should -Be 0
        }

        It 'sends a dedicated MAKEMKV_KEY_EXPIRED notification and keeps staging on key expiry' {
            Mock Invoke-VideoRip {
                [pscustomobject]@{ Success = $false; DiscLabel = $null; DiscType = $null; OutputDir = $null; TitleCount = 0; Error = 'MAKEMKV_KEY_EXPIRED' }
            }
            Mock Resolve-Title { throw 'should not be called' }
            Mock Move-ToNas { throw 'should not be called' }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter {
                $Level -eq 'Error' -and $Title -match 'Key Expired'
            }
            Should -Invoke Invoke-DiscEject -Times 0
        }

        It 'notifies Error and keeps staging on generic rip failure' {
            Mock Invoke-VideoRip {
                [pscustomobject]@{ Success = $false; DiscLabel = $null; DiscType = $null; OutputDir = $null; TitleCount = 0; Error = 'disc read error' }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter { $Level -eq 'Error' }
            Should -Invoke Invoke-DiscEject -Times 0
        }

        It 'notifies Error and keeps staging when Move-ToNas fails' {
            $ripOutputDir = Join-Path $script:StagingDir 'RAW_LABEL'
            New-Item -ItemType Directory -Force -Path $ripOutputDir | Out-Null
            'x' | Set-Content (Join-Path $ripOutputDir 'title1.mkv')

            Mock Invoke-VideoRip {
                [pscustomobject]@{
                    Success = $true; DiscLabel = 'RAW_LABEL'; DiscType = 'BD'
                    OutputDir = $ripOutputDir; TitleCount = 1; Error = $null
                }
            }
            Mock Resolve-Title {
                [pscustomobject]@{ FolderName = 'Failing Movie (2020)'; Matched = $true; Title = 'Failing Movie'; Year = 2020 }
            }
            Mock Move-ToNas {
                [pscustomobject]@{ Success = $false; DestDir = $null; Error = 'robocopy failed' }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter { $Level -eq 'Error' }
            Should -Invoke Invoke-DiscEject -Times 0
            Test-Path (Join-Path $script:StagingDir 'Failing Movie (2020)') | Should -BeTrue
        }
    }

    Context 'Audio CD' {
        It 'rips, moves to NAS, ejects, and notifies success' {
            $ripOutputDir = Join-Path $script:StagingDir 'audio-guid'
            New-Item -ItemType Directory -Force -Path $ripOutputDir | Out-Null
            'flac bytes' | Set-Content (Join-Path $ripOutputDir 'track01.flac')

            Mock Invoke-AudioRip {
                [pscustomobject]@{ Success = $true; OutputDir = $ripOutputDir; Artist = 'Some Artist'; Album = 'Some Album'; Error = $null }
            }

            Invoke-DiscDispatch -DriveLetter 'E' -DiscType 'AudioCD' -Config $script:Config

            $expectedDest = Join-Path $script:NasMusicRoot 'audio-guid'
            Test-Path (Join-Path $expectedDest 'track01.flac') | Should -BeTrue
            Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter { $Level -eq 'Info' }
            Should -Invoke Invoke-DiscEject -Times 1
        }

        It 'notifies Error and keeps staging on rip failure' {
            Mock Invoke-AudioRip {
                [pscustomobject]@{ Success = $false; OutputDir = $null; Artist = $null; Album = $null; Error = 'drive not ready' }
            }

            Invoke-DiscDispatch -DriveLetter 'E' -DiscType 'AudioCD' -Config $script:Config

            Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter { $Level -eq 'Error' }
            Should -Invoke Invoke-DiscEject -Times 0
        }
    }

    Context 'Data disc' {
        It 'logs WARN and notifies Info without touching Move-ToNas or eject' {
            Mock Move-ToNas { throw 'should not be called' }

            Invoke-DiscDispatch -DriveLetter 'F' -DiscType 'Data' -Config $script:Config

            Should -Invoke Send-ArmNotification -Times 1
            Should -Invoke Invoke-DiscEject -Times 0
        }
    }

    Context 'None' {
        It 'takes no action' {
            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'None' -Config $script:Config

            Should -Invoke Send-ArmNotification -Times 0
            Should -Invoke Invoke-DiscEject -Times 0
        }
    }

    Context 'Unhandled dispatch error' {
        It 'catches exceptions, logs Error, and notifies Error rather than propagating' {
            Mock Invoke-VideoRip { throw 'boom' }

            { Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config } | Should -Not -Throw
            Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter { $Level -eq 'Error' }
        }
    }
}

Describe 'Invoke-DiscMutexDispatch (single-flight)' {
    BeforeEach {
        $script:TestRoot = Join-Path $TestDrive (New-Guid)
        New-Item -ItemType Directory -Force -Path $script:TestRoot | Out-Null
        $script:Config = New-TestConfig -StagingDir (Join-Path $script:TestRoot 'staging') `
            -NasVideoPath (Join-Path $script:TestRoot 'nas-video') `
            -NasMusicPath (Join-Path $script:TestRoot 'nas-music') `
            -UpscaleQueueDir (Join-Path $script:TestRoot 'queue')
        Mock Send-ArmNotification { }
    }

    It 'skips dispatch when the named mutex is already held (by another runspace)' {
        # A named Mutex is reentrant on the *same* thread even via a different
        # Mutex object, so the holder must run in a separate runspace for this
        # test to actually exercise single-flight contention. A bare
        # System.Threading.Thread with a PowerShell scriptblock has no
        # runspace to execute in and crashes the process, so use a background
        # PowerShell instance instead.
        $holderPs = [powershell]::Create()
        $holderPs.AddScript({
            param($ReadyPath, $ReleasePath)
            $m = New-Object System.Threading.Mutex($false, 'Global\wrm-rip')
            $m.WaitOne() | Out-Null
            New-Item -ItemType File -Path $ReadyPath -Force | Out-Null
            while (-not (Test-Path $ReleasePath)) { Start-Sleep -Milliseconds 50 }
            $m.ReleaseMutex()
            $m.Dispose()
        }).AddArgument("$script:TestRoot\ready.flag").AddArgument("$script:TestRoot\release.flag") | Out-Null
        $asyncResult = $holderPs.BeginInvoke()

        try {
            $waited = 0
            while (-not (Test-Path "$script:TestRoot\ready.flag") -and $waited -lt 5000) {
                Start-Sleep -Milliseconds 50
                $waited += 50
            }
            Test-Path "$script:TestRoot\ready.flag" | Should -BeTrue

            Mock Invoke-DiscDispatch { }
            Invoke-DiscMutexDispatch -DriveLetter 'D' -DiscType 'Data' -Config $script:Config
            Should -Invoke Invoke-DiscDispatch -Times 0
        } finally {
            New-Item -ItemType File -Path "$script:TestRoot\release.flag" -Force | Out-Null
            $null = $holderPs.EndInvoke($asyncResult)
            $holderPs.Dispose()
        }
    }

    It 'dispatches and releases the mutex when free' {
        Mock Invoke-DiscDispatch { }
        Invoke-DiscMutexDispatch -DriveLetter 'D' -DiscType 'Data' -Config $script:Config
        Should -Invoke Invoke-DiscDispatch -Times 1

        # Mutex must be released afterward: a second immediate acquire should succeed.
        $m = New-Object System.Threading.Mutex($false, 'Global\wrm-rip')
        try {
            $m.WaitOne(0) | Should -BeTrue
        } finally {
            $m.ReleaseMutex()
            $m.Dispose()
        }
    }
}

Describe 'Resolve-CurrentDisc' {
    It 'reads WRM_SIM_DISC when Config.Simulate is true' {
        $env:WRM_SIM_DISC = 'Video'
        try {
            $result = Resolve-CurrentDisc -Config @{ Simulate = $true }
            $result.DiscType | Should -Be 'Video'
        } finally {
            Remove-Item Env:\WRM_SIM_DISC -ErrorAction SilentlyContinue
        }
    }

    It 'defaults to None when WRM_SIM_DISC is unset in simulate mode' {
        Remove-Item Env:\WRM_SIM_DISC -ErrorAction SilentlyContinue
        $result = Resolve-CurrentDisc -Config @{ Simulate = $true }
        $result.DiscType | Should -Be 'None'
    }
}

Describe 'New-UpscaleQueueEntry' {
    It 'sanitizes invalid filename characters from the folder name' {
        $dir = Join-Path $TestDrive (New-Guid)
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $config = @{ UpscaleQueueDir = $dir; LogDir = $dir }

        New-UpscaleQueueEntry -MkvPath 'C:\x\movie.mkv' -DestDir 'C:\nas\movie' `
            -FolderName 'Weird: Title? (2020)' -Config $config

        $files = @(Get-ChildItem $dir -Filter '*.json')
        $files.Count | Should -Be 1
        $files[0].Name | Should -Not -Match '[:?]'
    }
}
