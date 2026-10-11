Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'JobState.ps1')
}

Describe 'JobState' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive (New-Guid)
        New-Item -ItemType Directory -Force -Path $script:Root | Out-Null
        $script:Config = @{
            StateDir       = Join-Path $script:Root 'state'
            LogDir         = Join-Path $script:Root 'logs'
            JobHistoryDays = 30
        }
        $script:JobsDir = Join-Path $script:Config.StateDir 'jobs'
    }

    Context 'New-ArmJob' {
        It 'creates a record with a well-formed id, default state, and history' {
            $id = New-ArmJob -Kind Rip -Properties @{ Drive = 'D:'; DiscType = 'Video' } -Config $script:Config

            $id | Should -Match '^\d{8}-\d{6}-[0-9a-f]{6}$'
            Test-Path (Join-Path $script:JobsDir "$id.json") | Should -BeTrue

            $job = Get-ArmJob -JobId $id -Config $script:Config
            $job.Kind | Should -Be 'Rip'
            $job.State | Should -Be 'Detected'
            $job.Drive | Should -Be 'D:'
            @($job.History).Count | Should -Be 1
            @($job.History)[0].State | Should -Be 'Detected'
        }

        It 'defaults Upscale jobs to Queued' {
            $id = New-ArmJob -Kind Upscale -Config $script:Config
            (Get-ArmJob -JobId $id -Config $script:Config).State | Should -Be 'Queued'
        }

        It 'writes every record field, even ones not supplied' {
            $id = New-ArmJob -Kind Rip -Config $script:Config
            $names = (Get-ArmJob -JobId $id -Config $script:Config).PSObject.Properties.Name
            foreach ($field in @('Id', 'Kind', 'State', 'Title', 'DiscLabel', 'DiscType', 'Drive', 'StagingDir',
                    'DestDir', 'QueueFile', 'SamplePath', 'OutputFile', 'ContentType', 'Engine', 'InterlaceType', 'Error', 'Reason', 'Created', 'Updated', 'History')) {
                $names | Should -Contain $field
            }
        }

        It 'ignores attempts to set managed fields' {
            $id = New-ArmJob -Kind Rip -Properties @{ Id = '..\..\evil'; Kind = 'Upscale' } -Config $script:Config
            $id | Should -Not -Be '..\..\evil'
            (Get-ArmJob -JobId $id -Config $script:Config).Kind | Should -Be 'Rip'
        }
    }

    Context 'Update-ArmJob' {
        It 'merges properties, appends a history entry on state change, and bumps Updated' {
            $id = New-ArmJob -Kind Rip -Properties @{ Drive = 'D:' } -Config $script:Config
            Start-Sleep -Milliseconds 20

            Update-ArmJob -JobId $id -Properties @{ State = 'Ripping'; StagingDir = 'C:\s\X' } -Config $script:Config | Should -BeTrue
            Update-ArmJob -JobId $id -Properties @{ Title = 'X (1999)' } -Config $script:Config | Should -BeTrue

            $job = Get-ArmJob -JobId $id -Config $script:Config
            $job.State | Should -Be 'Ripping'
            $job.StagingDir | Should -Be 'C:\s\X'
            $job.Title | Should -Be 'X (1999)'
            $job.Drive | Should -Be 'D:'
            @($job.History).State | Should -Be @('Detected', 'Ripping')
            ([datetime] $job.Updated) | Should -BeGreaterThan ([datetime] $job.Created)
        }

        It 'does not add a history entry when the state is unchanged' {
            $id = New-ArmJob -Kind Rip -Config $script:Config
            $null = Update-ArmJob -JobId $id -Properties @{ State = 'Detected'; Title = 'T' } -Config $script:Config
            @((Get-ArmJob -JobId $id -Config $script:Config).History).Count | Should -Be 1
        }

        It 'leaves no .tmp files behind after writes' {
            $id = New-ArmJob -Kind Rip -Config $script:Config
            1..5 | ForEach-Object { $null = Update-ArmJob -JobId $id -Properties @{ Title = "T$_" } -Config $script:Config }

            @(Get-ChildItem -Path $script:JobsDir -Filter '*.tmp').Count | Should -Be 0
            @(Get-ChildItem -Path $script:JobsDir -Filter '*.json').Count | Should -Be 1
        }

        It 'returns false for unknown, blank, or malformed ids without throwing' {
            Update-ArmJob -JobId '20200101-000000-abcdef' -Properties @{ State = 'X' } -Config $script:Config | Should -BeFalse
            Update-ArmJob -JobId '' -Properties @{ State = 'X' } -Config $script:Config | Should -BeFalse
            Update-ArmJob -JobId $null -Properties @{ State = 'X' } -Config $script:Config | Should -BeFalse
            Update-ArmJob -JobId '..\..\config' -Properties @{ State = 'X' } -Config $script:Config | Should -BeFalse
        }
    }

    Context 'Get-ArmJob / Get-ArmJobList' {
        It 'rejects path-traversal ids' {
            Get-ArmJob -JobId '..\..\secrets' -Config $script:Config | Should -BeNullOrEmpty
        }

        It 'lists newest first and filters by Kind' {
            $a = New-ArmJob -Kind Rip -Config $script:Config
            Start-Sleep -Milliseconds 1100
            $b = New-ArmJob -Kind Upscale -Config $script:Config

            $all = Get-ArmJobList -Config $script:Config
            @($all).Count | Should -Be 2
            @($all)[0].Id | Should -Be $b
            @($all)[1].Id | Should -Be $a

            $rips = Get-ArmJobList -Kind Rip -Config $script:Config
            @($rips).Count | Should -Be 1
            @($rips)[0].Id | Should -Be $a
        }

        It 'skips corrupt and foreign files' {
            $good = New-ArmJob -Kind Rip -Config $script:Config
            Set-Content -Path (Join-Path $script:JobsDir '20200101-000000-aaaaaa.json') -Value '{ not json'
            Set-Content -Path (Join-Path $script:JobsDir 'notes.json') -Value '{"Id":"x"}'

            $list = Get-ArmJobList -Config $script:Config
            @($list).Count | Should -Be 1
            @($list)[0].Id | Should -Be $good
        }

        It 'returns nothing when there are no jobs' {
            @(Get-ArmJobList -Config $script:Config).Count | Should -Be 0
        }

        It 'returns one element per job when wrapped in @()' {
            $null = New-ArmJob -Kind Rip -Config $script:Config
            $null = New-ArmJob -Kind Rip -Config $script:Config
            @(Get-ArmJobList -Config $script:Config).Count | Should -Be 2
        }
    }

    Context 'Unavailable state directory' {
        It 'no-ops without throwing when StateDir is not configured' {
            $config = @{ LogDir = $script:Config.LogDir }
            { New-ArmJob -Kind Rip -Config $config } | Should -Not -Throw
            New-ArmJob -Kind Rip -Config $config | Should -BeNullOrEmpty
            Update-ArmJob -JobId '20200101-000000-abcdef' -Properties @{ State = 'X' } -Config $config | Should -BeFalse
            @(Get-ArmJobList -Config $config).Count | Should -Be 0
            Remove-ArmStaleJobs -Config $config | Should -Be 0
        }

        It 'no-ops without throwing when StateDir is unwritable' {
            # A file where the directory should be makes New-Item fail.
            $blocker = Join-Path $script:Root 'blocker'
            Set-Content -Path $blocker -Value 'x'
            $config = @{ StateDir = $blocker; LogDir = $script:Config.LogDir }

            { New-ArmJob -Kind Rip -Config $config } | Should -Not -Throw
            New-ArmJob -Kind Rip -Config $config | Should -BeNullOrEmpty
            { Update-ArmJob -JobId '20200101-000000-abcdef' -Properties @{ State = 'X' } -Config $config } | Should -Not -Throw
            @(Get-ArmJobList -Config $config).Count | Should -Be 0
        }
    }

    Context 'Remove-ArmStaleJobs' {
        It 'removes only terminal jobs older than JobHistoryDays' {
            $oldDone = New-ArmJob -Kind Rip -Properties @{ State = 'Complete' } -Config $script:Config
            $oldFailed = New-ArmJob -Kind Upscale -Properties @{ State = 'Failed' } -Config $script:Config
            $oldActive = New-ArmJob -Kind Upscale -Properties @{ State = 'AwaitingReview' } -Config $script:Config
            $newDone = New-ArmJob -Kind Rip -Properties @{ State = 'Complete' } -Config $script:Config

            # Backdate three records' Updated stamp by 40 days.
            foreach ($id in @($oldDone, $oldFailed, $oldActive)) {
                $path = Join-Path $script:JobsDir "$id.json"
                $raw = Get-Content -Path $path -Raw | ConvertFrom-Json
                $raw.Updated = (Get-Date).AddDays(-40).ToString('o')
                $raw | ConvertTo-Json -Depth 5 | Set-Content -Path $path
            }

            Remove-ArmStaleJobs -Config $script:Config | Should -Be 2

            Get-ArmJob -JobId $oldDone -Config $script:Config | Should -BeNullOrEmpty
            Get-ArmJob -JobId $oldFailed -Config $script:Config | Should -BeNullOrEmpty
            Get-ArmJob -JobId $oldActive -Config $script:Config | Should -Not -BeNullOrEmpty
            Get-ArmJob -JobId $newDone -Config $script:Config | Should -Not -BeNullOrEmpty
        }

        It 'defaults to 30 days when JobHistoryDays is missing' {
            $config = @{ StateDir = $script:Config.StateDir; LogDir = $script:Config.LogDir }
            $id = New-ArmJob -Kind Rip -Properties @{ State = 'Complete' } -Config $config
            $path = Join-Path $script:JobsDir "$id.json"
            $raw = Get-Content -Path $path -Raw | ConvertFrom-Json
            $raw.Updated = (Get-Date).AddDays(-20).ToString('o')
            $raw | ConvertTo-Json -Depth 5 | Set-Content -Path $path

            Remove-ArmStaleJobs -Config $config | Should -Be 0
            Get-ArmJob -JobId $id -Config $config | Should -Not -BeNullOrEmpty
        }
    }
}
