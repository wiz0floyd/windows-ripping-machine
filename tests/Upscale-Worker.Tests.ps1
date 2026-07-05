Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')
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
        $script:TestDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wslc-arm-worker-test-$(New-Guid)")
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
