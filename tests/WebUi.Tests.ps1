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
            'StagingDir', 'DestDir', 'QueueFile', 'SamplePath', 'Error', 'Created', 'Updated', 'History')
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
