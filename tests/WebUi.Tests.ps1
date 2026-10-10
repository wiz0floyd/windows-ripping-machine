Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    # Dot-source only: WebUi.ps1's listener is guarded on
    # $MyInvocation.InvocationName -ne '.', so this never opens a socket.
    . (Join-Path $PSScriptRoot '..' 'src' 'WebUi.ps1')

    function New-TestWebConfig {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        return @{
            StateDir = Join-Path $root 'state'
            LogDir   = Join-Path $root 'logs'
        }
    }

    function Get-TodayLogPath {
        param([hashtable] $Config)
        $null = New-Item -ItemType Directory -Force -Path $Config.LogDir
        return (Join-Path $Config.LogDir "wrm-$(Get-Date -Format 'yyyyMMdd').log")
    }
}

Describe 'Invoke-ArmWebRequest routing' {
    BeforeEach {
        $script:cfg = New-TestWebConfig
    }

    It 'serves the dashboard as HTML on GET /' {
        $r = Invoke-ArmWebRequest -Method GET -Path '/' -Config $script:cfg
        $r.Status | Should -Be 200
        $r.ContentType | Should -BeLike 'text/html*'
        $r.Body | Should -Match '<title>Ripping Machine</title>'
        $r.Body | Should -Match '<script src="/app.js"></script>'
    }

    It 'serves the static assets' {
        (Invoke-ArmWebRequest -Method GET -Path '/app.js' -Config $script:cfg).ContentType | Should -BeLike 'text/javascript*'
        (Invoke-ArmWebRequest -Method GET -Path '/app.css' -Config $script:cfg).ContentType | Should -BeLike 'text/css*'
    }

    It 'returns 404 JSON for an unknown path' {
        $r = Invoke-ArmWebRequest -Method GET -Path '/does-not-exist' -Config $script:cfg
        $r.Status | Should -Be 404
        ($r.Body | ConvertFrom-Json).Error | Should -Be 'Not found'
    }

    It 'does not treat a path with a traversal suffix as a static asset' {
        (Invoke-ArmWebRequest -Method GET -Path '/app.js/../../config/config.psd1' -Config $script:cfg).Status | Should -Be 404
    }

    It 'returns 405 with an Allow header for a known path with the wrong method' {
        $r = Invoke-ArmWebRequest -Method POST -Path '/api/jobs' -Config $script:cfg
        $r.Status | Should -Be 405
        $r.Headers.Allow | Should -Be 'GET'
    }

    It 'matches the method case-insensitively' {
        (Invoke-ArmWebRequest -Method get -Path '/api/jobs' -Config $script:cfg).Status | Should -Be 200
    }

    It 'returns 500 (without leaking the exception) when a handler throws' {
        Mock Get-ArmJobList { throw 'disk on fire' }
        $r = Invoke-ArmWebRequest -Method GET -Path '/api/jobs' -Config $script:cfg
        $r.Status | Should -Be 500
        $r.Body | Should -Not -Match 'disk on fire'
    }

    It 'always returns a Headers hashtable' {
        (Invoke-ArmWebRequest -Method GET -Path '/api/jobs' -Config $script:cfg).Headers | Should -BeOfType [hashtable]
    }
}

Describe 'GET /api/jobs' {
    BeforeEach {
        $script:cfg = New-TestWebConfig
    }

    It 'returns an empty JSON array when there are no jobs' {
        $r = Invoke-ArmWebRequest -Method GET -Path '/api/jobs' -Config $script:cfg
        $r.Status | Should -Be 200
        $r.ContentType | Should -BeLike 'application/json*'
        $r.Body.Trim() | Should -Be '[]'
    }

    It 'returns a JSON array for a single job' {
        $null = New-ArmJob -Kind Rip -Properties @{ Title = 'Alien (1979)' } -Config $script:cfg
        $r = Invoke-ArmWebRequest -Method GET -Path '/api/jobs' -Config $script:cfg
        $r.Body.TrimStart() | Should -Match '^\[\s*\{'
        $jobs = @($r.Body | ConvertFrom-Json)
        $jobs.Count | Should -Be 1
        $jobs[0].Title | Should -Be 'Alien (1979)'
    }

    It 'serializes every record field with ISO 8601 timestamps' {
        $id = New-ArmJob -Kind Rip -Properties @{ Drive = 'D:' } -Config $script:cfg
        $null = Update-ArmJob -JobId $id -Properties @{ State = 'Ripping' } -Config $script:cfg
        $r = Invoke-ArmWebRequest -Method GET -Path '/api/jobs' -Config $script:cfg
        $raw = $r.Body | ConvertFrom-Json -DateKind String
        $job = @($raw)[0]
        $job.PSObject.Properties.Name | Should -Be @('Id', 'Kind', 'State', 'Title', 'DiscLabel', 'DiscType', 'Drive',
            'StagingDir', 'DestDir', 'QueueFile', 'SamplePath', 'OutputFile', 'ContentType', 'Engine', 'InterlaceType', 'Error', 'Reason', 'Created', 'Updated', 'History', 'Actions')
        $job.Created | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+[+-]\d{2}:\d{2}$'
        @($job.History).State | Should -Be @('Detected', 'Ripping')
        @($job.History)[1].At | Should -Match '^\d{4}-\d{2}-\d{2}T'
    }

    It 'lists newest first' {
        $older = New-ArmJob -Kind Rip -Config $script:cfg
        Start-Sleep -Milliseconds 1100
        $newer = New-ArmJob -Kind Rip -Config $script:cfg
        $jobs = @((Invoke-ArmWebRequest -Method GET -Path '/api/jobs' -Config $script:cfg).Body | ConvertFrom-Json)
        $jobs.Id | Should -Be @($newer, $older)
    }

    It 'filters by ?kind= (case-insensitive)' {
        $null = New-ArmJob -Kind Rip -Config $script:cfg
        $upscale = New-ArmJob -Kind Upscale -Config $script:cfg
        $jobs = @((Invoke-ArmWebRequest -Method GET -Path '/api/jobs' -Query @{ kind = 'upscale' } -Config $script:cfg).Body | ConvertFrom-Json)
        $jobs.Id | Should -Be @($upscale)
    }

    It 'rejects an unknown kind with 400' {
        (Invoke-ArmWebRequest -Method GET -Path '/api/jobs' -Query @{ kind = 'Bogus' } -Config $script:cfg).Status | Should -Be 400
    }

    It 'returns an empty array (not an error) when StateDir is not configured' {
        $r = Invoke-ArmWebRequest -Method GET -Path '/api/jobs' -Config @{ LogDir = (New-TestWebConfig).LogDir }
        $r.Status | Should -Be 200
        $r.Body.Trim() | Should -Be '[]'
    }
}

Describe 'GET /api/jobs/{id}' {
    BeforeEach {
        $script:cfg = New-TestWebConfig
    }

    It 'returns one job' {
        $id = New-ArmJob -Kind Upscale -Properties @{ Title = 'Heat (1995)' } -Config $script:cfg
        $r = Invoke-ArmWebRequest -Method GET -Path "/api/jobs/$id" -Config $script:cfg
        $r.Status | Should -Be 200
        ($r.Body | ConvertFrom-Json).Title | Should -Be 'Heat (1995)'
    }

    It 'returns 404 for an unknown well-formed id' {
        (Invoke-ArmWebRequest -Method GET -Path '/api/jobs/20200101-000000-abcdef' -Config $script:cfg).Status | Should -Be 404
    }

    It 'returns 404 for a malformed id (never touches the filesystem path)' {
        (Invoke-ArmWebRequest -Method GET -Path '/api/jobs/..%5C..%5Cconfig' -Config $script:cfg).Status | Should -Be 404
        (Invoke-ArmWebRequest -Method GET -Path '/api/jobs/a/b' -Config $script:cfg).Status | Should -Be 404
    }
}

Describe 'Dashboard HTML' {
    BeforeEach {
        $script:cfg = New-TestWebConfig
    }

    It 'HTML-encodes job titles' {
        $null = New-ArmJob -Kind Rip -Properties @{ State = 'Ripping'; Title = '<script>alert(1)</script>' } -Config $script:cfg
        $null = New-ArmJob -Kind Upscale -Properties @{ Title = '<img src=x onerror=alert(2)>' } -Config $script:cfg
        $body = (Invoke-ArmWebRequest -Method GET -Path '/' -Config $script:cfg).Body
        $body | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
        $body | Should -Not -Match '<script>alert'
        $body | Should -Match '&lt;img src=x onerror=alert\(2\)&gt;'
        $body | Should -Not -Match '<img'
    }

    It 'HTML-encodes paths, errors and log lines' {
        $id = New-ArmJob -Kind Rip -Properties @{ Title = 'x' } -Config $script:cfg
        $null = Update-ArmJob -JobId $id -Properties @{ State = 'Failed'; Error = 'bad "<b>" & worse' } -Config $script:cfg
        Set-Content -LiteralPath (Get-TodayLogPath -Config $script:cfg) -Value '<i>log</i>'
        $body = (Invoke-ArmWebRequest -Method GET -Path '/' -Config $script:cfg).Body
        $body | Should -Match 'bad &quot;&lt;b&gt;&quot; &amp; worse'
        $body | Should -Match '&lt;i&gt;log&lt;/i&gt;'
        $body | Should -Not -Match '<b>|<i>'
    }

    It 'shows the empty state when there are no jobs' {
        $body = (Invoke-ArmWebRequest -Method GET -Path '/' -Config $script:cfg).Body
        $body | Should -Match 'No rips yet'
        $body | Should -Match 'No upscale jobs'
    }

    It 'puts in-flight rips in the active section and finished ones in history' {
        $active = New-ArmJob -Kind Rip -Properties @{ State = 'Ripping'; Title = 'Active One' } -Config $script:cfg
        $done = New-ArmJob -Kind Rip -Properties @{ State = 'Complete'; Title = 'Done One' } -Config $script:cfg
        $body = (Invoke-ArmWebRequest -Method GET -Path '/' -Config $script:cfg).Body
        $activeSection = ($body -split 'id="h-history"')[0]
        $activeSection | Should -Match "data-job-id=`"$active`""
        $activeSection | Should -Not -Match "data-job-id=`"$done`""
        ($body -split 'id="h-history"')[1] | Should -Match "data-job-id=`"$done`""
    }

    It 'renders a state badge per job' {
        $null = New-ArmJob -Kind Upscale -Properties @{ State = 'AwaitingReview' } -Config $script:cfg
        $body = (Invoke-ArmWebRequest -Method GET -Path '/' -Config $script:cfg).Body
        $body | Should -Match '<span class="badge state-AwaitingReview" data-testid="job-state">AwaitingReview</span>'
    }
}

Describe 'GET /api/log' {
    BeforeEach {
        $script:cfg = New-TestWebConfig
    }

    It 'returns an empty list when today''s log does not exist' {
        $r = Invoke-ArmWebRequest -Method GET -Path '/api/log' -Config $script:cfg
        $r.Status | Should -Be 200
        @(($r.Body | ConvertFrom-Json).Lines).Count | Should -Be 0
    }

    It 'returns the last N lines' {
        Set-Content -LiteralPath (Get-TodayLogPath -Config $script:cfg) -Value (1..300 | ForEach-Object { "line $_" })
        $lines = @(((Invoke-ArmWebRequest -Method GET -Path '/api/log' -Query @{ lines = '5' } -Config $script:cfg).Body | ConvertFrom-Json).Lines)
        $lines | Should -Be @('line 296', 'line 297', 'line 298', 'line 299', 'line 300')
    }

    It 'defaults to 200 lines' {
        Set-Content -LiteralPath (Get-TodayLogPath -Config $script:cfg) -Value (1..300 | ForEach-Object { "line $_" })
        $lines = @(((Invoke-ArmWebRequest -Method GET -Path '/api/log' -Config $script:cfg).Body | ConvertFrom-Json).Lines)
        $lines.Count | Should -Be 200
        $lines[0] | Should -Be 'line 101'
    }

    It 'clamps lines to 1..1000' {
        Set-Content -LiteralPath (Get-TodayLogPath -Config $script:cfg) -Value (1..1200 | ForEach-Object { "line $_" })
        @(((Invoke-ArmWebRequest -Method GET -Path '/api/log' -Query @{ lines = '0' } -Config $script:cfg).Body | ConvertFrom-Json).Lines).Count | Should -Be 1
        @(((Invoke-ArmWebRequest -Method GET -Path '/api/log' -Query @{ lines = '-7' } -Config $script:cfg).Body | ConvertFrom-Json).Lines).Count | Should -Be 1
        @(((Invoke-ArmWebRequest -Method GET -Path '/api/log' -Query @{ lines = '5000' } -Config $script:cfg).Body | ConvertFrom-Json).Lines).Count | Should -Be 1000
    }

    It 'rejects a non-integer line count with 400' {
        (Invoke-ArmWebRequest -Method GET -Path '/api/log' -Query @{ lines = 'abc' } -Config $script:cfg).Status | Should -Be 400
    }

    It 'reads a log file another process holds open for writing' {
        $path = Get-TodayLogPath -Config $script:cfg
        $writer = [System.IO.FileStream]::new($path, 'Append', 'Write', 'ReadWrite')
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("held open`n")
            $writer.Write($bytes, 0, $bytes.Length)
            $writer.Flush()
            @(((Invoke-ArmWebRequest -Method GET -Path '/api/log' -Config $script:cfg).Body | ConvertFrom-Json).Lines) | Should -Be @('held open')
        } finally {
            $writer.Dispose()
        }
    }
}

Describe 'POST /api/jobs/{id}/approve|retry|cancel (upscale actions)' {
    BeforeAll {
        $script:okHeaders = @{ 'X-WRM-Action' = '1' }

        function New-TestActionConfig {
            $cfg = New-TestWebConfig
            $cfg.UpscaleQueueDir = Join-Path (Split-Path -Parent $cfg.StateDir) 'queue'
            $null = New-Item -ItemType Directory -Force -Path $cfg.UpscaleQueueDir
            return $cfg
        }

        # An Upscale job plus its queue file (<Name><Extension>) as the worker leaves them.
        function New-TestUpscaleJob {
            param(
                [hashtable] $Config,
                [string] $State,
                [string] $Extension,
                [string] $Name = 'Sample Movie (2020)',
                [switch] $SampleGenerated,
                [string] $Content
            )
            $queueFile = Join-Path $Config.UpscaleQueueDir "$Name$Extension"
            $id = New-ArmJob -Kind Upscale -Properties @{ State = $State; Title = $Name; QueueFile = $queueFile } -Config $Config
            if (-not $PSBoundParameters.ContainsKey('Content')) {
                $item = [ordered]@{ Source = 'C:\nas\Sample Movie (2020)\title1.mkv'; DestDir = 'C:\nas\Sample Movie (2020)'; JobId = $id }
                if ($SampleGenerated) { $item.SampleGenerated = $true }
                $Content = $item | ConvertTo-Json
            }
            Set-Content -LiteralPath $queueFile -Value $Content -Encoding utf8
            return [pscustomobject]@{ Id = $id; QueueFile = $queueFile; Base = Join-Path $Config.UpscaleQueueDir $Name }
        }

        function Invoke-TestAction {
            param([hashtable] $Config, [string] $Id, [string] $Action, [hashtable] $Headers = $script:okHeaders)
            return (Invoke-ArmWebRequest -Method POST -Path "/api/jobs/$Id/$Action" -Headers $Headers -Config $Config)
        }
    }

    BeforeEach {
        $script:cfg = New-TestActionConfig
    }

    Context 'approve' {
        It 'renames .awaiting-review to .json, keeps SampleGenerated, and sets Queued' {
            $j = New-TestUpscaleJob -Config $script:cfg -State AwaitingReview -Extension '.awaiting-review' -SampleGenerated

            $r = Invoke-TestAction -Config $script:cfg -Id $j.Id -Action approve

            $r.Status | Should -Be 200
            ($r.Body | ConvertFrom-Json).State | Should -Be 'Queued'
            Test-Path -LiteralPath "$($j.Base).awaiting-review" | Should -BeFalse
            Test-Path -LiteralPath "$($j.Base).json" | Should -BeTrue
            (Get-Content -LiteralPath "$($j.Base).json" -Raw | ConvertFrom-Json).SampleGenerated | Should -BeTrue
            $job = Get-ArmJob -JobId $j.Id -Config $script:cfg
            $job.State | Should -Be 'Queued'
            $job.QueueFile | Should -Be "$($j.Base).json"
        }

        It 'returns 409 for a job that is <_>, leaving the file alone' -ForEach @('Queued', 'Sampling', 'Upscaling', 'Failed', 'Complete', 'Cancelled') {
            $j = New-TestUpscaleJob -Config $script:cfg -State $_ -Extension '.awaiting-review'

            (Invoke-TestAction -Config $script:cfg -Id $j.Id -Action approve).Status | Should -Be 409

            Test-Path -LiteralPath "$($j.Base).awaiting-review" | Should -BeTrue
            (Get-ArmJob -JobId $j.Id -Config $script:cfg).State | Should -Be $_
        }

        It 'returns 409 when the queue file is gone' {
            $j = New-TestUpscaleJob -Config $script:cfg -State AwaitingReview -Extension '.awaiting-review'
            Remove-Item -LiteralPath $j.QueueFile

            $r = Invoke-TestAction -Config $script:cfg -Id $j.Id -Action approve
            $r.Status | Should -Be 409
            ($r.Body | ConvertFrom-Json).Error | Should -Match 'no longer exists'
        }

        It 'returns 409 rather than overwrite an existing .json' {
            $j = New-TestUpscaleJob -Config $script:cfg -State AwaitingReview -Extension '.awaiting-review'
            Set-Content -LiteralPath "$($j.Base).json" -Value '{"Source":"other"}'

            (Invoke-TestAction -Config $script:cfg -Id $j.Id -Action approve).Status | Should -Be 409
            Get-Content -LiteralPath "$($j.Base).json" -Raw | Should -Match 'other'
            Test-Path -LiteralPath $j.QueueFile | Should -BeTrue
        }

        It 'rolls the rename back when the job record cannot be written' {
            $j = New-TestUpscaleJob -Config $script:cfg -State AwaitingReview -Extension '.awaiting-review'
            Mock Update-ArmJob { $false }

            (Invoke-TestAction -Config $script:cfg -Id $j.Id -Action approve).Status | Should -Be 500
            Test-Path -LiteralPath $j.QueueFile | Should -BeTrue
            Test-Path -LiteralPath "$($j.Base).json" | Should -BeFalse
        }
    }

    Context 'retry' {
        It 'renames .failed to .json without SampleGenerated and sets Queued' {
            $j = New-TestUpscaleJob -Config $script:cfg -State Failed -Extension '.failed' -SampleGenerated
            $null = Update-ArmJob -JobId $j.Id -Properties @{ Error = 'Upscale failed: boom'; SamplePath = 'C:\q\old sample.mkv' } -Config $script:cfg

            $r = Invoke-TestAction -Config $script:cfg -Id $j.Id -Action retry

            $r.Status | Should -Be 200
            Test-Path -LiteralPath $j.QueueFile | Should -BeFalse
            $item = Get-Content -LiteralPath "$($j.Base).json" -Raw | ConvertFrom-Json
            $item.PSObject.Properties.Name | Should -Not -Contain 'SampleGenerated'
            $item.Source | Should -Be 'C:\nas\Sample Movie (2020)\title1.mkv'
            $item.JobId | Should -Be $j.Id
            $job = Get-ArmJob -JobId $j.Id -Config $script:cfg
            $job.State | Should -Be 'Queued'
            $job.Error | Should -BeNullOrEmpty
            $job.SamplePath | Should -BeNullOrEmpty
        }

        It 'returns 409 for a job that is <_>' -ForEach @('Queued', 'AwaitingReview', 'Sampling', 'Upscaling', 'Complete') {
            $j = New-TestUpscaleJob -Config $script:cfg -State $_ -Extension '.failed'
            (Invoke-TestAction -Config $script:cfg -Id $j.Id -Action retry).Status | Should -Be 409
            Test-Path -LiteralPath $j.QueueFile | Should -BeTrue
        }

        It 'returns 409 (not 500) for a Failed job whose queue file was unparseable' {
            $j = New-TestUpscaleJob -Config $script:cfg -State Failed -Extension '.failed' -Content '{ not json'

            $r = Invoke-TestAction -Config $script:cfg -Id $j.Id -Action retry
            $r.Status | Should -Be 409
            ($r.Body | ConvertFrom-Json).Error | Should -Match 'not a valid queue entry'
            Get-Content -LiteralPath $j.QueueFile -Raw | Should -Match 'not json'
        }

        It 'returns 409 for a Failed job with no queue file on record' {
            $id = New-ArmJob -Kind Upscale -Properties @{ State = 'Failed' } -Config $script:cfg
            $r = Invoke-TestAction -Config $script:cfg -Id $id -Action retry
            $r.Status | Should -Be 409
            ($r.Body | ConvertFrom-Json).Error | Should -Match 'no queue file'
        }
    }

    Context 'cancel' {
        It 'deletes the queue file of a <State> job and sets Cancelled' -ForEach @(
            @{ State = 'Queued'; Extension = '.json' }
            @{ State = 'AwaitingReview'; Extension = '.awaiting-review' }
        ) {
            $j = New-TestUpscaleJob -Config $script:cfg -State $State -Extension $Extension

            $r = Invoke-TestAction -Config $script:cfg -Id $j.Id -Action cancel

            $r.Status | Should -Be 200
            ($r.Body | ConvertFrom-Json).State | Should -Be 'Cancelled'
            @(Get-ChildItem -LiteralPath $script:cfg.UpscaleQueueDir -Force) | Should -HaveCount 0
            (Get-ArmJob -JobId $j.Id -Config $script:cfg).State | Should -Be 'Cancelled'
        }

        It 'returns 409 for a job that is <_>' -ForEach @('Sampling', 'Upscaling', 'Failed', 'Complete', 'Cancelled') {
            $j = New-TestUpscaleJob -Config $script:cfg -State $_ -Extension '.json'
            (Invoke-TestAction -Config $script:cfg -Id $j.Id -Action cancel).Status | Should -Be 409
            Test-Path -LiteralPath $j.QueueFile | Should -BeTrue
        }

        It 'puts the file back and returns 409 when the worker starts the job mid-cancel' {
            $j = New-TestUpscaleJob -Config $script:cfg -State Queued -Extension '.json'
            $script:getCalls = 0
            Mock Get-ArmJob {
                $script:getCalls++
                $record = Read-ArmJobRecord -Path (Join-Path $Config.StateDir 'jobs' "$JobId.json") -Config $Config
                if ($script:getCalls -ge 2) { $record.State = 'Sampling' }
                $record
            }

            $r = Invoke-TestAction -Config $script:cfg -Id $j.Id -Action cancel
            $r.Status | Should -Be 409
            ($r.Body | ConvertFrom-Json).Error | Should -Match 'Sampling'
            Test-Path -LiteralPath $j.QueueFile | Should -BeTrue
            Test-Path -LiteralPath "$($j.Base).cancelling" | Should -BeFalse
        }
    }

    Context 'guards' {
        It 'returns 403 without the X-WRM-Action header, before looking at the job' {
            $j = New-TestUpscaleJob -Config $script:cfg -State AwaitingReview -Extension '.awaiting-review'
            Mock Get-ArmJob { throw 'must not be called' }

            foreach ($headers in @(@{}, @{ 'X-WRM-Action' = '0' })) {
                $r = Invoke-TestAction -Config $script:cfg -Id $j.Id -Action approve -Headers $headers
                $r.Status | Should -Be 403
            }
            Should -Invoke Get-ArmJob -Times 0 -Exactly
            Test-Path -LiteralPath $j.QueueFile | Should -BeTrue
        }

        It 'accepts the header name case-insensitively' {
            $j = New-TestUpscaleJob -Config $script:cfg -State AwaitingReview -Extension '.awaiting-review'
            (Invoke-TestAction -Config $script:cfg -Id $j.Id -Action approve -Headers @{ 'x-wrm-action' = '1' }).Status | Should -Be 200
        }

        It 'returns 404 for an unknown, malformed, or non-upscale job id' {
            $ripId = New-ArmJob -Kind Rip -Properties @{ State = 'Failed' } -Config $script:cfg
            foreach ($id in @('20260101-000000-abcdef', '..%5C..%5Cconfig', 'nope', $ripId)) {
                (Invoke-TestAction -Config $script:cfg -Id $id -Action retry).Status | Should -Be 404
            }
        }

        It 'returns 405 for GET on an action route and 404 for an unknown action' {
            $j = New-TestUpscaleJob -Config $script:cfg -State AwaitingReview -Extension '.awaiting-review'
            (Invoke-ArmWebRequest -Method GET -Path "/api/jobs/$($j.Id)/approve" -Config $script:cfg).Status | Should -Be 405
            (Invoke-TestAction -Config $script:cfg -Id $j.Id -Action delete).Status | Should -Be 404
        }

        It 'refuses a record whose QueueFile points outside UpscaleQueueDir' {
            $outside = Join-Path (Split-Path -Parent $script:cfg.StateDir) 'elsewhere'
            $null = New-Item -ItemType Directory -Force -Path $outside
            $victim = Join-Path $outside 'victim.awaiting-review'
            Set-Content -LiteralPath $victim -Value 'keep me'
            # Same file name also exists in the queue dir: must not be used as a fallback either.
            Set-Content -LiteralPath (Join-Path $script:cfg.UpscaleQueueDir 'victim.awaiting-review') -Value 'queue copy'
            $id = New-ArmJob -Kind Upscale -Properties @{ State = 'AwaitingReview'; QueueFile = $victim } -Config $script:cfg

            foreach ($action in @('approve', 'cancel')) {
                $r = Invoke-TestAction -Config $script:cfg -Id $id -Action $action
                $r.Status | Should -Be 409
                ($r.Body | ConvertFrom-Json).Error | Should -Match 'not inside UpscaleQueueDir'
            }
            Get-Content -LiteralPath $victim -Raw | Should -Match 'keep me'
            Test-Path -LiteralPath (Join-Path $script:cfg.UpscaleQueueDir 'victim.awaiting-review') | Should -BeTrue
        }

        It 'refuses a traversal-style QueueFile that normalizes outside the queue dir' {
            $victim = Join-Path (Split-Path -Parent $script:cfg.StateDir) 'victim.failed'
            Set-Content -LiteralPath $victim -Value '{"Source":"x"}'
            $sneaky = Join-Path $script:cfg.UpscaleQueueDir '..\victim.failed'
            $id = New-ArmJob -Kind Upscale -Properties @{ State = 'Failed'; QueueFile = $sneaky } -Config $script:cfg

            (Invoke-TestAction -Config $script:cfg -Id $id -Action retry).Status | Should -Be 409
            Test-Path -LiteralPath $victim | Should -BeTrue
        }

        It 'refuses a queue file with an unexpected extension for the action' {
            $j = New-TestUpscaleJob -Config $script:cfg -State AwaitingReview -Extension '.json'
            (Invoke-TestAction -Config $script:cfg -Id $j.Id -Action approve).Status | Should -Be 409
            Test-Path -LiteralPath $j.QueueFile | Should -BeTrue
        }
    }

    Context 'rendering' {
        It 'exposes the valid actions per state in /api/jobs' {
            $expected = @{ Queued = 'cancel'; AwaitingReview = 'approve,cancel'; Failed = 'retry'; Sampling = ''; Upscaling = ''; Complete = ''; Cancelled = '' }
            $ids = @{}
            foreach ($state in $expected.Keys) {
                $ids[$state] = New-ArmJob -Kind Upscale -Properties @{ State = $state } -Config $script:cfg
            }
            $rip = New-ArmJob -Kind Rip -Properties @{ State = 'Failed' } -Config $script:cfg

            $jobs = (Invoke-ArmWebRequest -Method GET -Path '/api/jobs' -Config $script:cfg).Body | ConvertFrom-Json
            foreach ($state in $expected.Keys) {
                $job = $jobs | Where-Object Id -eq $ids[$state]
                (@($job.Actions) -join ',') | Should -Be $expected[$state] -Because $state
            }
            @(($jobs | Where-Object Id -eq $rip).Actions) | Should -HaveCount 0
        }

        It 'server-renders action buttons only for valid states, plus a sample copy button' {
            $review = New-ArmJob -Kind Upscale -Properties @{ State = 'AwaitingReview'; SamplePath = 'C:\q\s.mkv' } -Config $script:cfg
            $busy = New-ArmJob -Kind Upscale -Properties @{ State = 'Upscaling' } -Config $script:cfg

            $html = (Invoke-ArmWebRequest -Method GET -Path '/' -Config $script:cfg).Body
            $reviewRow = [regex]::Match($html, "<tr[^>]*data-job-id=`"$review`".*?</tr>").Value
            $busyRow = [regex]::Match($html, "<tr[^>]*data-job-id=`"$busy`".*?</tr>").Value
            $reviewRow | Should -Match 'data-action="approve"'
            $reviewRow | Should -Match 'data-action="cancel"'
            $reviewRow | Should -Match 'data-testid="copy-sample"'
            $reviewRow | Should -Not -Match 'data-action="retry"'
            $busyRow | Should -Not -Match '<button'
        }

        It 'shows the engine, content type and interlace type of an upscale job (server-rendered, HTML-encoded)' {
            $withMeta = New-ArmJob -Kind Upscale -Properties @{ State = 'AwaitingReview'; SamplePath = 'C:\q\s.mkv'; ContentType = 'LiveAction'; Engine = 'openproteus'; InterlaceType = 'Telecined' } -Config $script:cfg
            $without = New-ArmJob -Kind Upscale -Properties @{ State = 'Queued' } -Config $script:cfg
            $evil = New-ArmJob -Kind Upscale -Properties @{ State = 'Complete'; Engine = '<script>x</script>' } -Config $script:cfg

            $html = (Invoke-ArmWebRequest -Method GET -Path '/' -Config $script:cfg).Body
            $row = { param($id) [regex]::Match($html, "<tr[^>]*data-job-id=`"$id`".*?</tr>").Value }
            (& $row $withMeta) | Should -Match 'data-testid="upscale-meta">openproteus / LiveAction / Telecined<'
            (& $row $without) | Should -Not -Match 'upscale-meta'
            (& $row $evil) | Should -Not -Match '<script>x'
            (& $row $evil) | Should -Match '&lt;script&gt;x'

            $api = (Invoke-ArmWebRequest -Method GET -Path "/api/jobs/$withMeta" -Config $script:cfg).Body | ConvertFrom-Json
            $api.Engine | Should -Be 'openproteus'
            $api.ContentType | Should -Be 'LiveAction'
            $api.InterlaceType | Should -Be 'Telecined'
        }
    }
}

Describe 'manual metadata edit (S4)' {
    BeforeAll {
        $script:okHeaders = @{ 'X-WRM-Action' = '1' }

        function New-TestMetaConfig {
            $cfg = New-TestWebConfig
            $cfg.StagingDir = Join-Path (Split-Path -Parent $cfg.StateDir) 'staging'
            $null = New-Item -ItemType Directory -Force -Path $cfg.StagingDir
            return $cfg
        }

        # A Rip job whose staging dir holds the metadata.json Invoke-VideoRip would have written.
        function New-TestRip {
            param(
                [hashtable] $Config,
                [string] $State = 'Ripping',
                [string] $DiscType = 'DVD',
                [string] $Dir = 'DISC_LABEL',
                [string] $Title = 'Old Title',
                [string] $Year = '1999'
            )
            $staging = Join-Path $Config.StagingDir $Dir
            $null = New-Item -ItemType Directory -Force -Path $staging
            @{ Title = $Title; Year = $Year } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $staging 'metadata.json') -Encoding utf8
            $id = New-ArmJob -Kind Rip -Properties @{ State = $State; DiscType = $DiscType; StagingDir = $staging; Title = "$Title ($Year)" } -Config $Config
            return [pscustomobject]@{ Id = $id; Staging = $staging; Metadata = (Join-Path $staging 'metadata.json') }
        }

        function Save-TestMeta {
            param([hashtable] $Config, [string] $Id, [string] $Body, [hashtable] $Headers = $script:okHeaders)
            return (Invoke-ArmWebRequest -Method POST -Path "/api/jobs/$Id/metadata" -Body $Body -Headers $Headers -Config $Config)
        }
    }

    BeforeEach {
        $script:cfg = New-TestMetaConfig
    }

    It 'writes metadata.json, updates the job title, and returns the folder name' {
        $rip = New-TestRip -Config $script:cfg
        $r = Save-TestMeta -Config $script:cfg -Id $rip.Id -Body '{"Title":"New: Title?","Year":"2001"}'
        $r.Status | Should -Be 200
        $body = $r.Body | ConvertFrom-Json
        $body.FolderName | Should -Be 'New Title (2001)'
        $disk = Get-Content -LiteralPath $rip.Metadata -Raw | ConvertFrom-Json
        $disk.Title | Should -Be 'New: Title?'
        $disk.Year | Should -Be '2001'
        (Get-ArmJob -JobId $rip.Id -Config $script:cfg).Title | Should -Be 'New Title (2001)'
        Get-ChildItem -LiteralPath $rip.Staging -Filter '*.tmp' | Should -BeNullOrEmpty
    }

    It 'is picked up by Resolve-TitleOverride (the pipeline reads the same file)' {
        $rip = New-TestRip -Config $script:cfg
        $null = Save-TestMeta -Config $script:cfg -Id $rip.Id -Body '{"Title":"Brand New","Year":2010}'
        $fallback = [pscustomobject]@{ FolderName = 'x'; Matched = $false; Title = $null; Year = $null }
        $resolved = Resolve-TitleOverride -OutputDir $rip.Staging -FallbackResolved $fallback -Config $script:cfg
        $resolved.FolderName | Should -Be 'Brand New (2010)'
    }

    It 'accepts a blank year' {
        $rip = New-TestRip -Config $script:cfg
        $r = Save-TestMeta -Config $script:cfg -Id $rip.Id -Body '{"Title":"No Year","Year":""}'
        $r.Status | Should -Be 200
        ($r.Body | ConvertFrom-Json).FolderName | Should -Be 'No Year'
    }

    It 'rejects invalid input with 400 and per-field errors, writing nothing' -ForEach @(
        @{ Name = 'blank title'; Body = '{"Title":"  ","Year":"1999"}'; Field = 'Title' }
        @{ Name = 'missing title'; Body = '{"Year":"1999"}'; Field = 'Title' }
        @{ Name = 'title of only invalid chars'; Body = '{"Title":":?*","Year":""}'; Field = 'Title' }
        @{ Name = 'dot-only title'; Body = '{"Title":"..","Year":""}'; Field = 'Title' }
        @{ Name = 'reserved device name'; Body = '{"Title":"CON","Year":""}'; Field = 'Title' }
        @{ Name = 'too-long title'; Body = (@{ Title = ('a' * 201); Year = '' } | ConvertTo-Json -Compress); Field = 'Title' }
        @{ Name = 'control characters'; Body = '{"Title":"a\u0000b","Year":""}'; Field = 'Title' }
        @{ Name = 'non-string title'; Body = '{"Title":5,"Year":""}'; Field = 'Title' }
        @{ Name = '2-digit year'; Body = '{"Title":"T","Year":"99"}'; Field = 'Year' }
        @{ Name = 'letters in year'; Body = '{"Title":"T","Year":"abcd"}'; Field = 'Year' }
        @{ Name = '5-digit year'; Body = '{"Title":"T","Year":"19999"}'; Field = 'Year' }
        @{ Name = 'object year'; Body = '{"Title":"T","Year":{"a":1}}'; Field = 'Year' }
    ) {
        $rip = New-TestRip -Config $script:cfg
        $before = Get-Content -LiteralPath $rip.Metadata -Raw
        $r = Save-TestMeta -Config $script:cfg -Id $rip.Id -Body $Body
        $r.Status | Should -Be 400 -Because $Name
        ($r.Body | ConvertFrom-Json).Errors.$Field | Should -Not -BeNullOrEmpty
        Get-Content -LiteralPath $rip.Metadata -Raw | Should -Be $before
    }

    It 'rejects a malformed or non-object body with 400' -ForEach @(
        @{ Body = 'not json' }
        @{ Body = '' }
        @{ Body = '[1,2]' }
        @{ Body = '"text"' }
    ) {
        $rip = New-TestRip -Config $script:cfg
        (Save-TestMeta -Config $script:cfg -Id $rip.Id -Body $Body).Status | Should -Be 400
    }

    It 'rejects an oversized body with 400' {
        $rip = New-TestRip -Config $script:cfg
        $big = '{"Title":"T","Year":"","Pad":"' + ('x' * 5000) + '"}'
        (Save-TestMeta -Config $script:cfg -Id $rip.Id -Body $big).Status | Should -Be 400
    }

    It 'returns 403 without the X-WRM-Action header and writes nothing' {
        $rip = New-TestRip -Config $script:cfg
        $r = Save-TestMeta -Config $script:cfg -Id $rip.Id -Body '{"Title":"Hacked","Year":""}' -Headers @{}
        $r.Status | Should -Be 403
        (Get-Content -LiteralPath $rip.Metadata -Raw | ConvertFrom-Json).Title | Should -Be 'Old Title'
    }

    It 'returns 404 for an unknown, malformed, or non-rip job id' {
        (Save-TestMeta -Config $script:cfg -Id '20000101-000000-abcdef' -Body '{"Title":"T","Year":""}').Status | Should -Be 404
        (Save-TestMeta -Config $script:cfg -Id '..' -Body '{"Title":"T","Year":""}').Status | Should -Be 404
        $up = New-ArmJob -Kind Upscale -Properties @{ State = 'Queued' } -Config $script:cfg
        (Save-TestMeta -Config $script:cfg -Id $up -Body '{"Title":"T","Year":""}').Status | Should -Be 404
        (Invoke-ArmWebRequest -Method GET -Path '/api/jobs/20000101-000000-abcdef/metadata' -Config $script:cfg).Status | Should -Be 404
    }

    It 'returns 409 once the rip is no longer Ripping, leaving the file untouched' -ForEach @(
        @{ State = 'Detected' }, @{ State = 'Moving' }, @{ State = 'Complete' }, @{ State = 'Failed' }
    ) {
        $rip = New-TestRip -Config $script:cfg -State $State
        $r = Save-TestMeta -Config $script:cfg -Id $rip.Id -Body '{"Title":"Too Late","Year":""}'
        $r.Status | Should -Be 409 -Because $State
        (Get-Content -LiteralPath $rip.Metadata -Raw | ConvertFrom-Json).Title | Should -Be 'Old Title'
    }

    It 'returns 409 for an audio CD rip' {
        $rip = New-TestRip -Config $script:cfg -DiscType 'AudioCD'
        (Save-TestMeta -Config $script:cfg -Id $rip.Id -Body '{"Title":"T","Year":""}').Status | Should -Be 409
    }

    It 'returns 409 when the recorded staging dir is outside StagingDir (tampered record)' {
        $victim = Join-Path $TestDrive 'elsewhere'
        $null = New-Item -ItemType Directory -Force -Path $victim
        $id = New-ArmJob -Kind Rip -Properties @{ State = 'Ripping'; DiscType = 'DVD'; StagingDir = $victim } -Config $script:cfg
        (Save-TestMeta -Config $script:cfg -Id $id -Body '{"Title":"T","Year":""}').Status | Should -Be 409
        Test-Path -LiteralPath (Join-Path $victim 'metadata.json') | Should -BeFalse
    }

    It 'returns 409 when the staging dir is gone, without leaking the path or exception text' {
        $rip = New-TestRip -Config $script:cfg
        Remove-Item -LiteralPath $rip.Staging -Recurse -Force
        $r = Save-TestMeta -Config $script:cfg -Id $rip.Id -Body '{"Title":"T","Year":""}'
        $r.Status | Should -Be 409
        $r.Body | Should -Not -Match ([regex]::Escape($script:cfg.StagingDir))
    }

    It 'returns 500 with a generic message (no exception text) when the write fails' {
        $rip = New-TestRip -Config $script:cfg
        Mock Set-ArmMetadataFile { }
        $r = Save-TestMeta -Config $script:cfg -Id $rip.Id -Body '{"Title":"Zzz Different","Year":""}'
        $r.Status | Should -Be 500
        $r.Body | Should -Not -Match 'Exception|StackTrace|at <ScriptBlock>'
    }

    It 'reports 409 when the rip moved on between the check and the write' {
        $rip = New-TestRip -Config $script:cfg
        # The read-back is the last step before the final state re-check: flip the state there.
        Mock Read-ArmWebMetadata {
            $null = Update-ArmJob -JobId $rip.Id -Properties @{ State = 'Moving' } -Config $script:cfg
            @{ Title = 'Raced'; Year = '' }
        }
        $r = Save-TestMeta -Config $script:cfg -Id $rip.Id -Body '{"Title":"Raced","Year":""}'
        $r.Status | Should -Be 409
        ($r.Body | ConvertFrom-Json).Error | Should -Match 'may not have been applied'
    }

    Context 'Set-ArmMetadataFile -Force' {
        It 'does not overwrite an existing file by default' {
            $rip = New-TestRip -Config $script:cfg
            Set-ArmMetadataFile -OutputDir $rip.Staging -Title 'Other' -Year '2000' -Config $script:cfg
            (Get-Content -LiteralPath $rip.Metadata -Raw | ConvertFrom-Json).Title | Should -Be 'Old Title'
        }
        It 'overwrites with -Force' {
            $rip = New-TestRip -Config $script:cfg
            Set-ArmMetadataFile -OutputDir $rip.Staging -Title 'Other' -Year '2000' -Config $script:cfg -Force
            $disk = Get-Content -LiteralPath $rip.Metadata -Raw | ConvertFrom-Json
            $disk.Title | Should -Be 'Other'
            $disk.Year | Should -Be '2000'
        }
    }

    Context 'GET /api/jobs/{id}/metadata and /api/metadata-preview' {
        It 'returns the current metadata.json values and Editable=true while Ripping' {
            $rip = New-TestRip -Config $script:cfg
            $r = Invoke-ArmWebRequest -Method GET -Path "/api/jobs/$($rip.Id)/metadata" -Config $script:cfg
            $r.Status | Should -Be 200
            $b = $r.Body | ConvertFrom-Json
            $b.Title | Should -Be 'Old Title'
            $b.Year | Should -Be '1999'
            $b.Editable | Should -BeTrue
            $b.FolderName | Should -Be 'Old Title (1999)'
        }
        It 'returns Editable=false with a reason once Moving' {
            $rip = New-TestRip -Config $script:cfg -State Moving
            $b = (Invoke-ArmWebRequest -Method GET -Path "/api/jobs/$($rip.Id)/metadata" -Config $script:cfg).Body | ConvertFrom-Json
            $b.Editable | Should -BeFalse
            $b.Reason | Should -Match 'Moving'
        }
        It 'previews the folder name using the pipeline sanitising rule' {
            $r = Invoke-ArmWebRequest -Method GET -Path '/api/metadata-preview' -Query @{ title = 'Star: Wars/ Ep?'; year = '1977' } -Config $script:cfg
            $r.Status | Should -Be 200
            $b = $r.Body | ConvertFrom-Json
            $b.Valid | Should -BeTrue
            $b.FolderName | Should -Be 'Star Wars Ep (1977)'
        }
        It 'previews validation errors with 200' {
            $b = (Invoke-ArmWebRequest -Method GET -Path '/api/metadata-preview' -Query @{ title = ''; year = '99' } -Config $script:cfg).Body | ConvertFrom-Json
            $b.Valid | Should -BeFalse
            $b.Errors.Title | Should -Not -BeNullOrEmpty
            $b.Errors.Year | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Actions in /api/jobs' {
        It 'offers metadata only for video rips that are Ripping' {
            $video = New-TestRip -Config $script:cfg
            $audio = New-TestRip -Config $script:cfg -DiscType 'AudioCD' -Dir 'CD'
            $moving = New-TestRip -Config $script:cfg -State Moving -Dir 'MV'
            $jobs = (Invoke-ArmWebRequest -Method GET -Path '/api/jobs' -Config $script:cfg).Body | ConvertFrom-Json
            (@(($jobs | Where-Object Id -eq $video.Id).Actions) -join ',') | Should -Be 'metadata'
            @(($jobs | Where-Object Id -eq $audio.Id).Actions) | Should -HaveCount 0
            @(($jobs | Where-Object Id -eq $moving.Id).Actions) | Should -HaveCount 0
        }
    }
}

Describe 'WebUi.ps1 entry point (socket smoke test)' {
    BeforeAll {
        # Real temp dir (not TestDrive): the server runs in a separate pwsh process.
        $script:smokeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "wrm-webui-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Force -Path $script:smokeRoot
        $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $probe.Start()
        $script:port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
        $probe.Stop()

        $script:smokeConfig = Join-Path $script:smokeRoot 'config.psd1'
        @"
@{
    StateDir  = '$((Join-Path $script:smokeRoot 'state') -replace "'", "''")'
    LogDir    = '$((Join-Path $script:smokeRoot 'logs') -replace "'", "''")'
    WebUiPort = $($script:port)
    Simulate  = `$true
}
"@ | Set-Content -LiteralPath $script:smokeConfig -Encoding utf8
        $script:webUiScript = Join-Path $PSScriptRoot '..' 'src' 'WebUi.ps1'
    }

    AfterAll {
        Remove-Item -LiteralPath $script:smokeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'serves one request on http://localhost:<port>/ with -Once, then exits' {
        $proc = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-File', $script:webUiScript, '-ConfigPath', $script:smokeConfig, '-Once')
        try {
            $response = $null
            $deadline = (Get-Date).AddSeconds(30)
            while (-not $response -and (Get-Date) -lt $deadline -and -not $proc.HasExited) {
                try {
                    # 'localhost', not 127.0.0.1: HTTP.sys matches the prefix on the Host header.
                    $response = Invoke-WebRequest -Uri "http://localhost:$($script:port)/api/jobs" -TimeoutSec 5
                } catch {
                    Start-Sleep -Milliseconds 250
                }
            }
            $response | Should -Not -BeNullOrEmpty
            $response.StatusCode | Should -Be 200
            $response.Headers['Content-Security-Policy'] | Should -Match "default-src 'self'"
            [string]$response.Content | Should -Match '^\s*\[\s*\]\s*$'
            $proc.WaitForExit(15000) | Should -BeTrue
        } finally {
            if (-not $proc.HasExited) { $proc.Kill() }
        }
    }

    It 'exits without listening when WebUiEnabled is $false' {
        $disabled = Join-Path $script:smokeRoot 'disabled.psd1'
        (Get-Content -LiteralPath $script:smokeConfig -Raw) -replace 'Simulate', "WebUiEnabled = `$false`n    Simulate" |
            Set-Content -LiteralPath $disabled -Encoding utf8
        $proc = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-File', $script:webUiScript, '-ConfigPath', $disabled)
        try {
            $proc.WaitForExit(30000) | Should -BeTrue
            $proc.ExitCode | Should -Be 0
        } finally {
            if (-not $proc.HasExited) { $proc.Kill() }
        }
    }
}
