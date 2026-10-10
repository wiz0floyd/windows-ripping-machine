Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'wrm.ps1')

    function New-Movie {
        param([string] $Name, [hashtable] $Files)
        $dir = Join-Path $script:Root $Name
        $null = New-Item -ItemType Directory -Path $dir -Force
        foreach ($f in $Files.Keys) { Set-Content -LiteralPath (Join-Path $dir $f) -Value $Files[$f] }
        return $dir
    }
}

Describe 'Add-ArmUpscaleQueueFromLibrary' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive (New-Guid)
        $null = New-Item -ItemType Directory -Path $script:Root
        $script:Config = @{
            Simulate = $true; UpscaleQueueDir = Join-Path $TestDrive "q-$(New-Guid)"
            LogDir = Join-Path $TestDrive "logs-$(New-Guid)"; StateDir = Join-Path $TestDrive "state-$(New-Guid)"
        }
        $script:Height = 480
        Mock Get-VideoSourceInfo { [pscustomobject]@{ Success = $true; Height = $script:Height } }
    }

    It 'queues the largest mkv of a DVD-resolution movie, taking ContentType from metadata.json' {
        $dir = New-Movie 'Up (2009)' @{ 'a.mkv' = ('x' * 100); 'b.mkv' = 'x'; 'metadata.json' = '{"ContentType":"Animation"}' }
        $rows = @(Add-ArmUpscaleQueueFromLibrary -MovieDir $dir -Config $script:Config)
        $rows[0].Action | Should -Be 'Queued'
        $q = Get-Content -LiteralPath (Join-Path $script:Config.UpscaleQueueDir 'Up (2009).json') -Raw | ConvertFrom-Json
        $q.Source | Should -Be (Join-Path $dir 'a.mkv')
        $q.DestDir | Should -Be $dir
        $q.ContentType | Should -Be 'Animation'
    }

    It 'queues nothing with -WhatIf' {
        $dir = New-Movie 'Up (2009)' @{ 'a.mkv' = 'x' }
        @(Add-ArmUpscaleQueueFromLibrary -MovieDir $dir -Config $script:Config -WhatIf)[0].Action | Should -Be 'WouldQueue'
        Test-Path -LiteralPath $script:Config.UpscaleQueueDir | Should -BeFalse
    }

    It 'skips a movie that already has an upscale, is already queued, or is HD' {
        $a = New-Movie 'A (2000)' @{ 'A (2000) - 480p.mkv' = 'x'; 'A (2000) - 1080p.mkv' = 'y' }
        $b = New-Movie 'B (2000)' @{ 'b.mkv' = 'x' }
        $null = New-Item -ItemType Directory -Path $script:Config.UpscaleQueueDir -Force
        Set-Content -LiteralPath (Join-Path $script:Config.UpscaleQueueDir 'B (2000).awaiting-review') -Value '{}'
        $c = New-Movie 'C (2000)' @{ 'c.mkv' = 'x' }
        $script:Height = 1080
        $rows = @(Add-ArmUpscaleQueueFromLibrary -MovieDir @($a, $b, $c) -Config $script:Config)
        $rows.Action | Should -Be @('Skipped', 'Skipped', 'Skipped')
        $rows[0].Reason | Should -Match 'already has an upscale'
        $rows[1].Reason | Should -Match 'queue'
        $rows[2].Reason | Should -Match 'DVD resolution'
    }
}

Describe 'Restart-WrmTask' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        Mock Get-WrmBusyProcess { @() }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = $TaskName } }
        Mock Stop-ScheduledTask { $script:Calls.Add("stop $TaskName") }
        Mock Start-ScheduledTask { $script:Calls.Add("start $TaskName") }
    }

    It 'stops then starts each wrm task' {
        $rows = @(Restart-WrmTask)
        $rows.TaskName | Should -Be @('wrm-watcher', 'wrm-upscaler', 'wrm-webui')
        $rows.Action | Should -Be @('Restarted', 'Restarted', 'Restarted')
        $script:Calls | Should -Be @('stop wrm-watcher', 'start wrm-watcher', 'stop wrm-upscaler', 'start wrm-upscaler', 'stop wrm-webui', 'start wrm-webui')
    }

    It 'touches nothing with -WhatIf' {
        @(Restart-WrmTask -WhatIf).Action | Should -Be @('WouldRestart', 'WouldRestart', 'WouldRestart')
        Should -Invoke Stop-ScheduledTask -Times 0 -Exactly
    }

    It 'refuses while a rip or upscale is running, unless -Force' {
        Mock Get-WrmBusyProcess { @([pscustomobject]@{ Name = 'makemkvcon64'; Id = 42 }) }
        { Restart-WrmTask } | Should -Throw '*makemkvcon64 (42)*-Force*'
        Should -Invoke Stop-ScheduledTask -Times 0 -Exactly
        @(Restart-WrmTask -Force).Action | Should -Be @('Restarted', 'Restarted', 'Restarted')
    }

    It 'reports a task that is not registered or fails to restart, and keeps going' {
        Mock Get-ScheduledTask { $null } -ParameterFilter { $TaskName -eq 'wrm-upscaler' }
        Mock Stop-ScheduledTask { throw 'Access is denied.' } -ParameterFilter { $TaskName -eq 'wrm-webui' }
        $rows = @(Restart-WrmTask)
        $rows.Action | Should -Be @('Restarted', 'NotRegistered', 'Failed')
        $rows[2].Detail | Should -BeLike '*Access is denied*elevated*'
    }
}
