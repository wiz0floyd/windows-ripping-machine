Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'JobState.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Send-Notification.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Upscale-Video.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Upscale-Worker.ps1')
}

Describe 'Test-ArmActiveWindow' {
    It 'returns true when window spans midnight and now is late night' {
        Mock Get-Date { [datetime]::ParseExact('23:30', 'HH:mm', $null) }
        $config = @{ UpscaleActiveHours = @('23:00', '08:00') }
        Test-ArmActiveWindow -Config $config | Should -Be $true
    }

    It 'returns true when window spans midnight and now is early morning' {
        Mock Get-Date { [datetime]::ParseExact('03:00', 'HH:mm', $null) }
        $config = @{ UpscaleActiveHours = @('23:00', '08:00') }
        Test-ArmActiveWindow -Config $config | Should -Be $true
    }

    It 'returns false when window spans midnight and now is midday' {
        Mock Get-Date { [datetime]::ParseExact('14:00', 'HH:mm', $null) }
        $config = @{ UpscaleActiveHours = @('23:00', '08:00') }
        Test-ArmActiveWindow -Config $config | Should -Be $false
    }

    It 'returns true when window does not span midnight and now is inside it' {
        Mock Get-Date { [datetime]::ParseExact('10:00', 'HH:mm', $null) }
        $config = @{ UpscaleActiveHours = @('08:00', '23:00') }
        Test-ArmActiveWindow -Config $config | Should -Be $true
    }

    It 'returns true when no window is configured' {
        $config = @{}
        Test-ArmActiveWindow -Config $config | Should -Be $true
    }
}

Describe 'Start-UpscaleWorker -Once' {
    BeforeAll {
        function New-TestConfig([bool] $AutoUpscale) {
            @{
                Simulate           = $true
                LogDir             = $script:LogDir
                StateDir           = Join-Path $script:TestDir 'state'
                UpscaleQueueDir    = $script:QueueDir.FullName
                AutoUpscale        = $AutoUpscale
                UpscaleActiveHours = @('23:00', '08:00')
                UpscaleModel       = 'realesr-generalv3'
                UpscaleScale       = 3
                UpscaleCrf         = 16
            }
        }
    }

    BeforeEach {
        $script:TestDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wrm-worker-test-$(New-Guid)")
        $script:QueueDir = New-Item -ItemType Directory -Path (Join-Path $script:TestDir 'queue')
        $script:DestDir = New-Item -ItemType Directory -Path (Join-Path $script:TestDir 'dest')
        $script:LogDir = New-Item -ItemType Directory -Path (Join-Path $script:TestDir 'logs')
        $script:ConfigDir = New-Item -ItemType Directory -Path (Join-Path $script:TestDir 'config')

        $script:SourceFile = Join-Path $script:TestDir 'movie.mkv'
        Set-Content -Path $script:SourceFile -Value 'fake source bytes'

        Mock Send-ArmNotification { }
        Mock Get-Process { [pscustomobject]@{ PriorityClass = $null } }
    }

    AfterEach {
        Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'sample-review path: runs SampleOnly, notifies, and renames queue file to .awaiting-review' {
        $config = New-TestConfig -AutoUpscale $false
        Mock Get-ArmConfig { $config }

        Mock Invoke-Upscale {
            [pscustomobject]@{
                Success       = $true
                OutputFile    = Join-Path $script:QueueDir.FullName 'movie [AI upscale 1080p].mkv'
                InterlaceType = 'Progressive'
                Error         = $null
            }
        }

        $queueFile = Join-Path $script:QueueDir.FullName 'movie.json'
        (@{ Source = $script:SourceFile; DestDir = $script:DestDir.FullName } | ConvertTo-Json) | Set-Content -Path $queueFile

        Start-UpscaleWorker -Once

        Test-Path -LiteralPath $queueFile | Should -Be $false
        Test-Path -LiteralPath (Join-Path $script:QueueDir.FullName 'movie.awaiting-review') | Should -Be $true
        Should -Invoke Invoke-Upscale -Times 1 -ParameterFilter { $SampleOnly -eq $true }
        Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter { $Level -eq 'Info' }
    }

    It 'auto-upscale path: runs full upscale, moves result to DestDir, notifies, deletes queue file' {
        $config = New-TestConfig -AutoUpscale $true
        Mock Get-ArmConfig { $config }

        $fakeOutput = Join-Path $script:QueueDir.FullName 'movie [AI upscale 1080p].mkv'
        Set-Content -LiteralPath $fakeOutput -Value 'fake upscaled bytes'

        Mock Invoke-Upscale {
            [pscustomobject]@{
                Success       = $true
                OutputFile    = $fakeOutput
                InterlaceType = 'Progressive'
                Error         = $null
            }
        }

        $queueFile = Join-Path $script:QueueDir.FullName 'movie.json'
        (@{ Source = $script:SourceFile; DestDir = $script:DestDir.FullName } | ConvertTo-Json) | Set-Content -Path $queueFile

        Start-UpscaleWorker -Once

        Test-Path -LiteralPath $queueFile | Should -Be $false
        Should -Invoke Invoke-Upscale -Times 1 -ParameterFilter { -not $SampleOnly }
        Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter { $Level -eq 'Info' }
    }

    It 'failure path: renames queue file to .failed and sends Error notification' {
        $config = New-TestConfig -AutoUpscale $true
        Mock Get-ArmConfig { $config }

        Mock Invoke-Upscale {
            [pscustomobject]@{
                Success       = $false
                OutputFile    = $null
                InterlaceType = 'Interlaced'
                Error         = 'video2x exploded'
            }
        }

        $queueFile = Join-Path $script:QueueDir.FullName 'movie.json'
        (@{ Source = $script:SourceFile; DestDir = $script:DestDir.FullName } | ConvertTo-Json) | Set-Content -Path $queueFile

        Start-UpscaleWorker -Once

        Test-Path -LiteralPath $queueFile | Should -Be $false
        Test-Path -LiteralPath (Join-Path $script:QueueDir.FullName 'movie.failed') | Should -Be $true
        Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter { $Level -eq 'Error' }
    }

    It 'does not process the queue outside active hours unless -Once is passed' {
        # Invoke-ArmUpscaleQueuePass without -Once should honor active hours;
        # verify directly rather than through the (always -Once) worker entry point.
        Mock Get-Date { [datetime]::ParseExact('14:00', 'HH:mm', $null) }

        $config = New-TestConfig -AutoUpscale $true
        Mock Invoke-Upscale { }

        $queueFile = Join-Path $script:QueueDir.FullName 'movie.json'
        (@{ Source = $script:SourceFile; DestDir = $script:DestDir.FullName } | ConvertTo-Json) | Set-Content -Path $queueFile

        Invoke-ArmUpscaleQueuePass -Config $config

        Test-Path -LiteralPath $queueFile | Should -Be $true
        Should -Invoke Invoke-Upscale -Times 0
    }
}

Describe 'Invoke-ArmUpscaleQueueItem job state' {
    BeforeEach {
        $script:TestDir = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wrm-worker-jobs-$(New-Guid)")).FullName
        $script:QueueDir = (New-Item -ItemType Directory -Path (Join-Path $script:TestDir 'queue')).FullName
        $script:DestDir = (New-Item -ItemType Directory -Path (Join-Path $script:TestDir 'dest')).FullName
        $script:SourceFile = Join-Path $script:TestDir 'movie.mkv'
        Set-Content -Path $script:SourceFile -Value 'fake source bytes'

        $script:Config = @{
            Simulate        = $true
            LogDir          = Join-Path $script:TestDir 'logs'
            StateDir        = Join-Path $script:TestDir 'state'
            UpscaleQueueDir = $script:QueueDir
            AutoUpscale     = $false
        }
        $script:QueueFile = Join-Path $script:QueueDir 'movie.json'
        $script:JobId = New-ArmJob -Kind Upscale -Properties @{ Title = 'movie'; QueueFile = $script:QueueFile; DestDir = $script:DestDir } -Config $script:Config
        ([ordered]@{ Source = $script:SourceFile; DestDir = $script:DestDir; JobId = $script:JobId } | ConvertTo-Json) |
            Set-Content -Path $script:QueueFile

        Mock Send-ArmNotification { }
    }

    AfterEach {
        Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'marks the job Sampling before Invoke-Upscale runs, then AwaitingReview with SamplePath' {
        $script:StateDuringUpscale = $null
        Mock Invoke-Upscale {
            $script:StateDuringUpscale = (Get-ArmJob -JobId $script:JobId -Config $script:Config).State
            [pscustomobject]@{ Success = $true; OutputFile = (Join-Path $script:QueueDir 'movie [AI upscale 1080p].mkv'); InterlaceType = 'Progressive'; Error = $null }
        }

        Invoke-ArmUpscaleQueueItem -QueueFile $script:QueueFile -Config $script:Config

        $script:StateDuringUpscale | Should -Be 'Sampling'
        $job = Get-ArmJob -JobId $script:JobId -Config $script:Config
        $job.State | Should -Be 'AwaitingReview'
        $job.SamplePath | Should -Be (Join-Path $script:QueueDir 'movie [AI upscale 1080p].mkv')
        $job.QueueFile | Should -Be (Join-Path $script:QueueDir 'movie.awaiting-review')
        @($job.History).State | Should -Be @('Queued', 'Sampling', 'AwaitingReview')
    }

    It 'marks the job Upscaling before the full run, then Complete' {
        $script:Config.AutoUpscale = $true
        $script:StateDuringUpscale = $null
        Mock Invoke-Upscale {
            $script:StateDuringUpscale = (Get-ArmJob -JobId $script:JobId -Config $script:Config).State
            [pscustomobject]@{ Success = $true; OutputFile = (Join-Path $script:DestDir 'movie [AI upscale 1080p].mkv'); InterlaceType = 'Progressive'; Error = $null }
        }

        Invoke-ArmUpscaleQueueItem -QueueFile $script:QueueFile -Config $script:Config

        $script:StateDuringUpscale | Should -Be 'Upscaling'
        (Get-ArmJob -JobId $script:JobId -Config $script:Config).State | Should -Be 'Complete'
    }

    It 'marks the job Failed with the error and the .failed queue path' {
        Mock Invoke-Upscale { [pscustomobject]@{ Success = $false; OutputFile = $null; InterlaceType = 'Interlaced'; Error = 'video2x exploded' } }

        Invoke-ArmUpscaleQueueItem -QueueFile $script:QueueFile -Config $script:Config

        $job = Get-ArmJob -JobId $script:JobId -Config $script:Config
        $job.State | Should -Be 'Failed'
        $job.Error | Should -Match 'video2x exploded'
        $job.QueueFile | Should -Be (Join-Path $script:QueueDir 'movie.failed')
    }

    It 'creates a job for a legacy queue file without JobId and persists the id into it' {
        Remove-Item -LiteralPath $script:QueueFile
        $legacy = Join-Path $script:QueueDir 'Old Movie (1990).json'
        (@{ Source = $script:SourceFile; DestDir = $script:DestDir } | ConvertTo-Json) | Set-Content -Path $legacy
        Mock Invoke-Upscale { [pscustomobject]@{ Success = $true; OutputFile = 'x'; InterlaceType = 'Progressive'; Error = $null } }

        Invoke-ArmUpscaleQueueItem -QueueFile $legacy -Config $script:Config

        $reviewFile = Join-Path $script:QueueDir 'Old Movie (1990).awaiting-review'
        $persisted = Get-Content -LiteralPath $reviewFile -Raw | ConvertFrom-Json
        $persisted.JobId | Should -Match '^\d{8}-\d{6}-[0-9a-f]{6}$'
        $persisted.SampleGenerated | Should -BeTrue
        $job = Get-ArmJob -JobId $persisted.JobId -Config $script:Config
        $job.Title | Should -Be 'Old Movie (1990)'
        $job.State | Should -Be 'AwaitingReview'
    }

    It 'surfaces an unparseable queue file as a Failed job' {
        Set-Content -LiteralPath $script:QueueFile -Value '{ not json'
        Mock Invoke-Upscale { }

        Invoke-ArmUpscaleQueueItem -QueueFile $script:QueueFile -Config $script:Config

        $failed = @(Get-ArmJobList -Kind Upscale -Config $script:Config | Where-Object { $_.Id -ne $script:JobId })
        $failed.Count | Should -Be 1
        $failed[0].State | Should -Be 'Failed'
        $failed[0].QueueFile | Should -Be (Join-Path $script:QueueDir 'movie.failed')
    }

    It 'still completes the upscale when job state is unavailable' {
        $blocker = Join-Path $script:TestDir 'blocker'
        Set-Content -Path $blocker -Value 'x'
        $script:Config.StateDir = $blocker
        $script:Config.AutoUpscale = $true
        Mock Invoke-Upscale { [pscustomobject]@{ Success = $true; OutputFile = 'x'; InterlaceType = 'Progressive'; Error = $null } }

        Invoke-ArmUpscaleQueueItem -QueueFile $script:QueueFile -Config $script:Config

        Test-Path -LiteralPath $script:QueueFile | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:QueueDir 'movie.failed') | Should -BeFalse
        Should -Invoke Send-ArmNotification -Times 1 -ParameterFilter { $Level -eq 'Info' }
    }

    It 'runs job-history retention once per pass, even outside active hours' {
        Mock Remove-ArmStaleJobs { 0 }
        Mock Test-ArmActiveWindow { $false }

        Invoke-ArmUpscaleQueuePass -Config $script:Config

        Should -Invoke Remove-ArmStaleJobs -Times 1
    }
}
