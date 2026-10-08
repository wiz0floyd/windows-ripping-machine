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
        function Resolve-TitleOverride {
            param([string] $OutputDir, [pscustomobject] $FallbackResolved, [hashtable] $Config)
            $FallbackResolved
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
                    Resolved = [pscustomobject]@{ FolderName = 'My Movie (2020)'; Matched = $true; Title = 'My Movie'; Year = 2020 }
                }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            $expectedDest = Join-Path $script:NasVideoRoot 'My Movie (2020)'
            Test-Path $expectedDest | Should -BeTrue
            Test-Path (Join-Path $expectedDest 'title1.mkv') | Should -BeTrue
            Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter { $Level -eq 'Info' }
            Should -Invoke Invoke-DiscEject -Times 1
        }

        It 'places non-main mkv files in an extras subfolder on the NAS' {
            $ripOutputDir = Join-Path $script:StagingDir 'RAW_LABEL'
            New-Item -ItemType Directory -Force -Path $ripOutputDir | Out-Null
            'x' * 500 | Set-Content (Join-Path $ripOutputDir 'main.mkv')
            'x' * 50 | Set-Content (Join-Path $ripOutputDir 'bonus.mkv')

            Mock Invoke-VideoRip {
                [pscustomobject]@{
                    Success = $true; DiscLabel = 'RAW_LABEL'; DiscType = 'BD'
                    OutputDir = $ripOutputDir; TitleCount = 2; Error = $null
                    Resolved = [pscustomobject]@{ FolderName = 'Extras Movie (2020)'; Matched = $true; Title = 'Extras Movie'; Year = 2020 }
                }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            $dest = Join-Path $script:NasVideoRoot 'Extras Movie (2020)'
            Test-Path (Join-Path $dest 'main.mkv') | Should -BeTrue
            Test-Path (Join-Path $dest 'extras' 'bonus.mkv') | Should -BeTrue
            Test-Path (Join-Path $dest 'bonus.mkv') | Should -BeFalse
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
                    Resolved = [pscustomobject]@{ FolderName = 'DVD Movie (1999)'; Matched = $true; Title = 'DVD Movie'; Year = 1999 }
                }
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
                    Resolved = [pscustomobject]@{ FolderName = 'BD Movie (2021)'; Matched = $true; Title = 'BD Movie'; Year = 2021 }
                }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            @(Get-ChildItem $script:QueueDir -Filter '*.json').Count | Should -Be 0
        }

        It 'sends a dedicated MAKEMKV_KEY_EXPIRED notification and keeps staging on key expiry' {
            Mock Invoke-VideoRip {
                [pscustomobject]@{ Success = $false; DiscLabel = $null; DiscType = $null; OutputDir = $null; TitleCount = 0; Error = 'MAKEMKV_KEY_EXPIRED'; Resolved = $null }
            }
            Mock Move-ToNas { throw 'should not be called' }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter {
                $Level -eq 'Error' -and $Title -match 'Key Expired'
            }
            Should -Invoke Invoke-DiscEject -Times 0
        }

        It 'notifies Error and keeps staging on generic rip failure' {
            Mock Invoke-VideoRip {
                [pscustomobject]@{ Success = $false; DiscLabel = $null; DiscType = $null; OutputDir = $null; TitleCount = 0; Error = 'disc read error'; Resolved = $null }
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
                    Resolved = [pscustomobject]@{ FolderName = 'Failing Movie (2020)'; Matched = $true; Title = 'Failing Movie'; Year = 2020 }
                }
            }
            Mock Move-ToNas {
                [pscustomobject]@{ Success = $false; DestDir = $null; Error = 'robocopy failed' }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter { $Level -eq 'Error' }
            Should -Invoke Invoke-DiscEject -Times 0
            Test-Path (Join-Path $script:StagingDir 'Failing Movie (2020)') | Should -BeTrue
        }

        It 'uses a metadata.json override to rename the staging dir when present' {
            $ripOutputDir = Join-Path $script:StagingDir 'RAW_LABEL'
            New-Item -ItemType Directory -Force -Path $ripOutputDir | Out-Null
            'fake mkv bytes' | Set-Content (Join-Path $ripOutputDir 'title1.mkv')
            '{"Title": "Corrected Title", "Year": "2021"}' | Set-Content (Join-Path $ripOutputDir 'metadata.json')

            Mock Invoke-VideoRip {
                [pscustomobject]@{
                    Success = $true; DiscLabel = 'RAW_LABEL'; DiscType = 'BD'
                    OutputDir = $ripOutputDir; TitleCount = 1; Error = $null
                    Resolved = [pscustomobject]@{ FolderName = 'My Movie (2020)'; Matched = $true; Title = 'My Movie'; Year = 2020 }
                }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            $expectedDest = Join-Path $script:NasVideoRoot 'Corrected Title (2021)'
            Test-Path $expectedDest | Should -BeTrue
            Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter { $Level -eq 'Info' }
        }

        It 'falls back to the resolved title when metadata.json is malformed' {
            $ripOutputDir = Join-Path $script:StagingDir 'RAW_LABEL'
            New-Item -ItemType Directory -Force -Path $ripOutputDir | Out-Null
            'fake mkv bytes' | Set-Content (Join-Path $ripOutputDir 'title1.mkv')
            '{ not valid json' | Set-Content (Join-Path $ripOutputDir 'metadata.json')

            Mock Invoke-VideoRip {
                [pscustomobject]@{
                    Success = $true; DiscLabel = 'RAW_LABEL'; DiscType = 'BD'
                    OutputDir = $ripOutputDir; TitleCount = 1; Error = $null
                    Resolved = [pscustomobject]@{ FolderName = 'My Movie (2020)'; Matched = $true; Title = 'My Movie'; Year = 2020 }
                }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            $expectedDest = Join-Path $script:NasVideoRoot 'My Movie (2020)'
            Test-Path $expectedDest | Should -BeTrue
            Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter { $Level -eq 'Info' }
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

    Context 'Job state' {
        BeforeEach {
            $script:Config.StateDir = Join-Path $script:TestRoot 'state'
            $script:RipOutputDir = Join-Path $script:StagingDir 'RAW_LABEL'
            New-Item -ItemType Directory -Force -Path $script:RipOutputDir | Out-Null
            'x' * 500 | Set-Content (Join-Path $script:RipOutputDir 'big.mkv')
        }

        It 'records a Rip job that ends Complete with the NAS DestDir, passing JobId to Invoke-VideoRip' {
            Mock Invoke-VideoRip {
                [pscustomobject]@{
                    Success = $true; DiscLabel = 'RAW_LABEL'; DiscType = 'BD'
                    OutputDir = $script:RipOutputDir; TitleCount = 1; Error = $null
                    Resolved = [pscustomobject]@{ FolderName = 'My Movie (2020)'; Matched = $true; Title = 'My Movie'; Year = 2020 }
                }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            $jobs = @(Get-ArmJobList -Kind Rip -Config $script:Config)
            $jobs.Count | Should -Be 1
            $jobs[0].State | Should -Be 'Complete'
            $jobs[0].Drive | Should -Be 'D:'
            $jobs[0].Title | Should -Be 'My Movie (2020)'
            $jobs[0].DestDir | Should -Be (Join-Path $script:NasVideoRoot 'My Movie (2020)')
            @($jobs[0].History).State | Should -Be @('Detected', 'Moving', 'Complete')
            $expectedId = $jobs[0].Id
            Should -Invoke Invoke-VideoRip -Times 1 -ParameterFilter { $JobId -eq $expectedId }
        }

        It 'marks the Rip job Failed with the rip error' {
            Mock Invoke-VideoRip {
                [pscustomobject]@{ Success = $false; DiscLabel = $null; DiscType = $null; OutputDir = $null; TitleCount = 0; Error = 'makemkvcon rip failed'; Resolved = $null }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            $job = @(Get-ArmJobList -Kind Rip -Config $script:Config)[0]
            $job.State | Should -Be 'Failed'
            $job.Error | Should -Be 'makemkvcon rip failed'
        }

        It 'marks the Rip job Failed when the NAS move fails' {
            Mock Invoke-VideoRip {
                [pscustomobject]@{
                    Success = $true; DiscLabel = 'RAW_LABEL'; DiscType = 'BD'
                    OutputDir = $script:RipOutputDir; TitleCount = 1; Error = $null
                    Resolved = [pscustomobject]@{ FolderName = 'My Movie (2020)'; Matched = $true; Title = 'My Movie'; Year = 2020 }
                }
            }
            Mock Move-ToNas { [pscustomobject]@{ Success = $false; DestDir = $null; Error = 'robocopy failed' } }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            $job = @(Get-ArmJobList -Kind Rip -Config $script:Config)[0]
            $job.State | Should -Be 'Failed'
            $job.Error | Should -Match 'robocopy failed'
        }

        It 'writes JobId into the upscale queue file and creates a Queued Upscale job' {
            $script:Config.UpscaleDvds = $true
            Mock Invoke-VideoRip {
                [pscustomobject]@{
                    Success = $true; DiscLabel = 'RAW_LABEL'; DiscType = 'DVD'
                    OutputDir = $script:RipOutputDir; TitleCount = 1; Error = $null
                    Resolved = [pscustomobject]@{ FolderName = 'DVD Movie (1999)'; Matched = $true; Title = 'DVD Movie'; Year = 1999 }
                }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            $queueFile = Join-Path $script:QueueDir 'DVD Movie (1999).json'
            $entry = Get-Content -LiteralPath $queueFile -Raw | ConvertFrom-Json
            @($entry.PSObject.Properties.Name) | Should -Be @('Source', 'DestDir', 'JobId', 'ContentType')
            $entry.ContentType | Should -Be 'LiveAction'
            $upscale = Get-ArmJob -JobId $entry.JobId -Config $script:Config
            $upscale.Kind | Should -Be 'Upscale'
            $upscale.State | Should -Be 'Queued'
            $upscale.QueueFile | Should -Be $queueFile
            $upscale.Title | Should -Be 'DVD Movie (1999)'
            $upscale.ContentType | Should -Be 'LiveAction'
        }

        It 'carries the resolved ContentType=Animation into the queue JSON and the Upscale job record' {
            $script:Config.UpscaleDvds = $true
            Mock Invoke-VideoRip {
                [pscustomobject]@{
                    Success = $true; DiscLabel = 'RAW_LABEL'; DiscType = 'DVD'
                    OutputDir = $script:RipOutputDir; TitleCount = 1; Error = $null
                    Resolved = [pscustomobject]@{
                        FolderName = 'Toy Story (1995)'; Matched = $true; Title = 'Toy Story'; Year = 1995
                        ContentType = 'Animation'; ContentTypeNote = ''
                    }
                }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            $queueFile = Join-Path $script:QueueDir 'Toy Story (1995).json'
            $entry = Get-Content -LiteralPath $queueFile -Raw | ConvertFrom-Json
            $entry.ContentType | Should -Be 'Animation'
            (Get-ArmJob -JobId $entry.JobId -Config $script:Config).ContentType | Should -Be 'Animation'
        }

        It 'honours a metadata.json ContentType edit made during the rip when queueing the upscale' {
            $script:Config.UpscaleDvds = $true
            '{"Title": "", "Year": "", "ContentType": "Animation"}' | Set-Content -LiteralPath (Join-Path $script:RipOutputDir 'metadata.json')
            Mock Invoke-VideoRip {
                [pscustomobject]@{
                    Success = $true; DiscLabel = 'RAW_LABEL'; DiscType = 'DVD'
                    OutputDir = $script:RipOutputDir; TitleCount = 1; Error = $null
                    Resolved = [pscustomobject]@{
                        FolderName = 'DVD Movie (1999)'; Matched = $true; Title = 'DVD Movie'; Year = 1999
                        ContentType = 'LiveAction'; ContentTypeNote = ''
                    }
                }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            $entry = Get-Content -LiteralPath (Join-Path $script:QueueDir 'DVD Movie (1999).json') -Raw | ConvertFrom-Json
            $entry.ContentType | Should -Be 'Animation'
        }

        It 'records an audio Rip job through Moving to Complete' {
            $audioDir = Join-Path $script:StagingDir 'audio-guid'
            New-Item -ItemType Directory -Force -Path $audioDir | Out-Null
            'flac' | Set-Content (Join-Path $audioDir 'track01.flac')
            Mock Invoke-AudioRip {
                [pscustomobject]@{ Success = $true; OutputDir = $audioDir; Artist = 'Some Artist'; Album = 'Some Album'; Error = $null }
            }

            Invoke-DiscDispatch -DriveLetter 'E' -DiscType 'AudioCD' -Config $script:Config

            $job = @(Get-ArmJobList -Kind Rip -Config $script:Config)[0]
            $job.State | Should -Be 'Complete'
            $job.Title | Should -Be 'Some Artist - Some Album'
            $job.DestDir | Should -Be (Join-Path $script:NasMusicRoot 'audio-guid')
        }

        It 'creates no job for a Data disc' {
            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Data' -Config $script:Config
            @(Get-ArmJobList -Config $script:Config).Count | Should -Be 0
        }

        It 'still completes the rip when StateDir is not configured' {
            $script:Config.Remove('StateDir')
            Mock Invoke-VideoRip {
                [pscustomobject]@{
                    Success = $true; DiscLabel = 'RAW_LABEL'; DiscType = 'BD'
                    OutputDir = $script:RipOutputDir; TitleCount = 1; Error = $null
                    Resolved = [pscustomobject]@{ FolderName = 'My Movie (2020)'; Matched = $true; Title = 'My Movie'; Year = 2020 }
                }
            }

            Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $script:Config

            Test-Path (Join-Path $script:NasVideoRoot 'My Movie (2020)' 'big.mkv') | Should -BeTrue
            Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter { $Level -eq 'Info' }
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

    It 'returns $false when the named mutex is already held (by another runspace)' {
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
            $result = Invoke-DiscMutexDispatch -DriveLetter 'D' -DiscType 'Data' -Config $script:Config
            Should -Invoke Invoke-DiscDispatch -Times 0
            $result | Should -BeFalse
        } finally {
            New-Item -ItemType File -Path "$script:TestRoot\release.flag" -Force | Out-Null
            $null = $holderPs.EndInvoke($asyncResult)
            $holderPs.Dispose()
        }
    }

    It 'dispatches, returns $true, and releases the mutex when free' {
        Mock Invoke-DiscDispatch { }
        $result = Invoke-DiscMutexDispatch -DriveLetter 'D' -DiscType 'Data' -Config $script:Config
        Should -Invoke Invoke-DiscDispatch -Times 1
        $result | Should -BeTrue

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

Describe 'Update-ArmDiscWatcherState (loop last-state tracking)' {
    BeforeEach {
        $script:TestRoot = Join-Path $TestDrive (New-Guid)
        New-Item -ItemType Directory -Force -Path $script:TestRoot | Out-Null
        $script:Config = New-TestConfig -StagingDir (Join-Path $script:TestRoot 'staging') `
            -NasVideoPath (Join-Path $script:TestRoot 'nas-video') `
            -NasMusicPath (Join-Path $script:TestRoot 'nas-music') `
            -UpscaleQueueDir (Join-Path $script:TestRoot 'queue')
    }

    It 'does NOT advance last state when dispatch is skipped due to mutex contention (disc must be retried, not dropped)' {
        Mock Invoke-DiscMutexDispatch { return $false }
        $lastState = @{}

        Update-ArmDiscWatcherState -DriveLetter 'D' -Type 'Video' -LastState $lastState -Config $script:Config

        Should -Invoke Invoke-DiscMutexDispatch -Times 1
        $lastState.ContainsKey([char]'D') | Should -BeFalse
    }

    It 'advances last state when dispatch actually happens' {
        Mock Invoke-DiscMutexDispatch { return $true }
        $lastState = @{}

        Update-ArmDiscWatcherState -DriveLetter 'D' -Type 'Video' -LastState $lastState -Config $script:Config

        Should -Invoke Invoke-DiscMutexDispatch -Times 1
        $lastState[[char]'D'] | Should -Be 'Video'
    }

    It 'advances last state to None without attempting dispatch' {
        Mock Invoke-DiscMutexDispatch { return $true }
        $lastState = @{ [char]'D' = 'Video' }

        Update-ArmDiscWatcherState -DriveLetter 'D' -Type 'None' -LastState $lastState -Config $script:Config

        Should -Invoke Invoke-DiscMutexDispatch -Times 0
        $lastState[[char]'D'] | Should -Be 'None'
    }

    It 'does not re-dispatch when the type is unchanged from last state' {
        Mock Invoke-DiscMutexDispatch { return $true }
        $lastState = @{ [char]'D' = 'Video' }

        Update-ArmDiscWatcherState -DriveLetter 'D' -Type 'Video' -LastState $lastState -Config $script:Config

        Should -Invoke Invoke-DiscMutexDispatch -Times 0
        $lastState[[char]'D'] | Should -Be 'Video'
    }

    It 'retries on the next call after a skipped dispatch once the mutex is free' {
        $script:attempt = 0
        Mock Invoke-DiscMutexDispatch {
            $script:attempt++
            return ($script:attempt -gt 1)
        }
        $lastState = @{}

        # First poll: mutex contended, dispatch skipped, state must NOT advance.
        Update-ArmDiscWatcherState -DriveLetter 'D' -Type 'Video' -LastState $lastState -Config $script:Config
        $lastState.ContainsKey([char]'D') | Should -BeFalse

        # Second poll (same disc still in drive, same type): mutex now free, dispatch succeeds.
        Update-ArmDiscWatcherState -DriveLetter 'D' -Type 'Video' -LastState $lastState -Config $script:Config

        Should -Invoke Invoke-DiscMutexDispatch -Times 2
        $lastState[[char]'D'] | Should -Be 'Video'
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

Describe 'Invoke-DiscEject (verified eject, #41)' {
    BeforeEach {
        # Every native/shell touchpoint is mocked: these tests must never eject a real drive.
        Mock Invoke-ArmShellEject { }
        Mock Invoke-ArmIoctlEject { $true }
        Mock Get-ArmDriveMediaLoaded { $false }
        Mock Start-Sleep { }
        Mock Write-ArmLog { }
        $script:Config = @{ EjectWhenDone = $true; Simulate = $false; LogDir = $TestDrive }
    }

    It 'does nothing when EjectWhenDone is false' {
        $script:Config.EjectWhenDone = $false
        Invoke-DiscEject -DriveLetter 'F' -Config $script:Config
        Should -Invoke Invoke-ArmShellEject -Times 0
        Should -Invoke Invoke-ArmIoctlEject -Times 0
        Should -Invoke Get-ArmDriveMediaLoaded -Times 0
    }

    It 'skips the physical eject under Simulate and says so' {
        $script:Config.Simulate = $true
        Invoke-DiscEject -DriveLetter 'F' -Config $script:Config
        Should -Invoke Invoke-ArmShellEject -Times 0
        Should -Invoke Invoke-ArmIoctlEject -Times 0
        Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Level -eq 'INFO' -and $Message -like 'Simulate: skipping physical eject*' }
    }

    It 'logs INFO and skips the fallback when the shell eject empties the drive' {
        $script:polls = 0
        Mock Get-ArmDriveMediaLoaded { $script:polls++; $script:polls -lt 3 }
        Invoke-DiscEject -DriveLetter 'F' -Config $script:Config
        Should -Invoke Invoke-ArmShellEject -Times 1 -ParameterFilter { $DriveLetter -eq 'F' }
        Should -Invoke Invoke-ArmIoctlEject -Times 0
        Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Level -eq 'INFO' -and $Message -eq 'Ejected F: (shell)' }
        Should -Invoke Write-ArmLog -Times 0 -ParameterFilter { $Level -eq 'WARN' }
    }

    It 'WARNs, then falls back to IOCTL and logs INFO when the shell verb silently does nothing' {
        $script:ioctlDone = $false
        Mock Get-ArmDriveMediaLoaded { -not $script:ioctlDone }
        Mock Invoke-ArmIoctlEject { $script:ioctlDone = $true; $true }
        Invoke-DiscEject -DriveLetter 'F' -Config $script:Config
        Should -Invoke Invoke-ArmShellEject -Times 1
        Should -Invoke Invoke-ArmIoctlEject -Times 1 -ParameterFilter { $DriveLetter -eq 'F' }
        Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Level -eq 'WARN' -and $Message -like 'Media still loaded in F:*IOCTL fallback*' }
        Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Level -eq 'INFO' -and $Message -eq 'Ejected F: (IOCTL fallback)' }
    }

    It 'WARNs that the eject failed when media survives both methods (and never logs success)' {
        Mock Get-ArmDriveMediaLoaded { $true }
        Invoke-DiscEject -DriveLetter 'F' -Config $script:Config
        Should -Invoke Invoke-ArmIoctlEject -Times 1
        Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Level -eq 'WARN' -and $Message -like 'Failed to eject F:*still loaded*' }
        Should -Invoke Write-ArmLog -Times 0 -ParameterFilter { $Level -eq 'INFO' }
    }

    It 'WARNs and does not poll again when the IOCTL itself fails' {
        Mock Get-ArmDriveMediaLoaded { $true }
        Mock Invoke-ArmIoctlEject { $false }
        Invoke-DiscEject -DriveLetter 'F' -Config $script:Config
        Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Level -eq 'WARN' -and $Message -like 'Failed to eject F:*' }
    }

    It 'treats a throwing shell verb as a failed attempt and still tries the fallback' {
        Mock Invoke-ArmShellEject { throw 'COM unavailable' }
        $script:ioctlDone = $false
        Mock Get-ArmDriveMediaLoaded { -not $script:ioctlDone }
        Mock Invoke-ArmIoctlEject { $script:ioctlDone = $true; $true }
        { Invoke-DiscEject -DriveLetter 'F' -Config $script:Config } | Should -Not -Throw
        Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Level -eq 'WARN' -and $Message -like 'Shell eject of F: threw*COM unavailable*' }
        Should -Invoke Write-ArmLog -Times 1 -ParameterFilter { $Level -eq 'INFO' -and $Message -eq 'Ejected F: (IOCTL fallback)' }
    }

    It 'returns nothing (so dispatch pipelines are not polluted)' {
        Mock Get-ArmDriveMediaLoaded { $false }
        $out = Invoke-DiscEject -DriveLetter 'F' -Config $script:Config
        $out | Should -BeNullOrEmpty
    }
}

Describe 'Wait-ArmEjected' {
    BeforeEach {
        Mock Start-Sleep { }
    }

    It 'returns $true immediately when no media is loaded' {
        Mock Get-ArmDriveMediaLoaded { $false }
        Wait-ArmEjected -DriveLetter 'F' | Should -BeTrue
        Should -Invoke Start-Sleep -Times 0
    }

    It 'polls a bounded number of times, then returns $false' {
        Mock Get-ArmDriveMediaLoaded { $true }
        Wait-ArmEjected -DriveLetter 'F' -TimeoutSec 2 -PollMs 500 | Should -BeFalse
        Should -Invoke Get-ArmDriveMediaLoaded -Times 5
        Should -Invoke Start-Sleep -Times 4
    }

    It 'returns $true as soon as the media leaves' {
        $script:n = 0
        Mock Get-ArmDriveMediaLoaded { $script:n++; $script:n -lt 3 }
        Wait-ArmEjected -DriveLetter 'F' | Should -BeTrue
        Should -Invoke Start-Sleep -Times 2
    }
}

Describe 'Initialize-ArmNativeEject (P/Invoke helper)' {
    It 'compiles the helper and rejects a nonexistent device path without touching any drive' {
        Initialize-ArmNativeEject | Should -BeTrue
        # A device name that cannot exist: CreateFile fails, no drive is opened.
        [Wrm.NativeEject]::Eject('\\.\wrm-no-such-device-for-tests') | Should -Not -Be 0
    }
}

Describe 'New-UpscaleQueueEntry' {
    It 'writes ContentType into the queue JSON (default LiveAction) and the job record' {
        $dir = Join-Path $TestDrive (New-Guid)
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $config = @{ UpscaleQueueDir = $dir; LogDir = $dir; StateDir = (Join-Path $dir 'state') }

        New-UpscaleQueueEntry -MkvPath 'C:\x\a.mkv' -DestDir 'C:\nas\a' -FolderName 'Live (2000)' -Config $config
        New-UpscaleQueueEntry -MkvPath 'C:\x\b.mkv' -DestDir 'C:\nas\b' -FolderName 'Cartoon (2001)' -ContentType Animation -Config $config

        $live = Get-Content -LiteralPath (Join-Path $dir 'Live (2000).json') -Raw | ConvertFrom-Json
        $cartoon = Get-Content -LiteralPath (Join-Path $dir 'Cartoon (2001).json') -Raw | ConvertFrom-Json
        $live.ContentType | Should -Be 'LiveAction'
        $cartoon.ContentType | Should -Be 'Animation'
        (Get-ArmJob -JobId $cartoon.JobId -Config $config).ContentType | Should -Be 'Animation'
    }

    It 'rejects an unknown ContentType' {
        $dir = Join-Path $TestDrive (New-Guid)
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $config = @{ UpscaleQueueDir = $dir; LogDir = $dir }
        { New-UpscaleQueueEntry -MkvPath 'C:\x\a.mkv' -DestDir 'C:\nas\a' -FolderName 'X' -ContentType Documentary -Config $config } | Should -Throw
    }

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

    It 'uses the canonical ConvertTo-ArmSafeFileName sanitizer (removes invalid chars, collapses whitespace, not underscore-replacement)' {
        $dir = Join-Path $TestDrive (New-Guid)
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $config = @{ UpscaleQueueDir = $dir; LogDir = $dir }

        $folderName = 'Weird:   Title? (2020)'
        $expectedSafeName = ConvertTo-ArmSafeFileName -Name $folderName

        New-UpscaleQueueEntry -MkvPath 'C:\x\movie.mkv' -DestDir 'C:\nas\movie' `
            -FolderName $folderName -Config $config

        $files = @(Get-ChildItem $dir -Filter '*.json')
        $files.Count | Should -Be 1
        $files[0].BaseName | Should -Be $expectedSafeName
        # The old ad hoc sanitizer replaced invalid chars with '_' and left
        # runs of whitespace intact; the canonical sanitizer removes invalid
        # chars entirely and collapses whitespace, so it must not contain '_'.
        $files[0].BaseName | Should -Not -Match '_'
    }
}

Describe 'Open-ArmWebUi' {
    BeforeEach {
        Mock Start-Process { }
        Mock Write-ArmLog { }
        $script:Cfg = @{ Simulate = $false; WebUiEnabled = $true; WebUiPort = 9123; LogDir = $TestDrive }
    }

    It 'opens the dashboard on localhost at the configured port in the default browser' {
        Open-ArmWebUi -Config $script:Cfg | Should -BeTrue
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'http://localhost:9123/' }
    }

    It 'defaults to port 8765 when WebUiPort is missing' {
        $script:Cfg.Remove('WebUiPort')
        Open-ArmWebUi -Config $script:Cfg | Should -BeTrue
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'http://localhost:8765/' }
    }

    It 'does nothing under <Name>' -ForEach @(
        @{ Name = 'Simulate'; Key = 'Simulate'; Value = $true }
        @{ Name = 'WebUiEnabled = $false'; Key = 'WebUiEnabled'; Value = $false }
        @{ Name = 'WebUiOpenOnDisc = $false'; Key = 'WebUiOpenOnDisc'; Value = $false }
    ) {
        $script:Cfg[$Key] = $Value
        Open-ArmWebUi -Config $script:Cfg | Should -BeFalse
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'never throws when the browser cannot be launched' {
        Mock Start-Process { throw 'no default browser' }
        { Open-ArmWebUi -Config $script:Cfg } | Should -Not -Throw
        Open-ArmWebUi -Config $script:Cfg | Should -BeFalse
        Should -Invoke Write-ArmLog -ParameterFilter { $Level -eq 'WARN' }
    }
}

Describe 'Invoke-DiscDispatch web UI' {
    It 'opens the web UI when a video or audio disc is detected, not for Data/None' {
        Mock Open-ArmWebUi { $true }
        Mock Invoke-VideoDispatch { }
        Mock Invoke-AudioDispatch { }
        Mock Send-ArmNotification { }
        Mock Write-ArmLog { }
        $cfg = @{ Simulate = $true; LogDir = $TestDrive }

        Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Video' -Config $cfg
        Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'AudioCD' -Config $cfg
        Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'Data' -Config $cfg
        Invoke-DiscDispatch -DriveLetter 'D' -DiscType 'None' -Config $cfg
        Should -Invoke Open-ArmWebUi -Times 2 -Exactly
    }
}
