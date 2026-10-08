param(
    [string] $ConfigPath,
    [switch] $Simulate,
    [switch] $Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'JobState.ps1')

<#
.SYNOPSIS
    Local web UI for rip / upscale job status (read by a browser on this machine).

.DESCRIPTION
    Library portion (dot-sourceable, no side effects): the route table,
    Invoke-ArmWebRequest (a pure request -> response function, unit-tested without
    sockets) and the HTML render helpers. The entry point at the bottom of the file
    is a thin System.Net.HttpListener loop around Invoke-ArmWebRequest.

    Binds http://localhost:<WebUiPort>/ only. HTTP.sys matches that prefix on the
    Host header, so requests addressed to 127.0.0.1 or any other host name are
    rejected (400) before they reach this code - which also blocks DNS-rebinding.

    Every dynamic string is HTML-encoded server-side; the browser script
    (webui/app.js) re-renders from /api/jobs using textContent only.
#>

$script:ArmWebStaticDir = Join-Path $PSScriptRoot 'webui'
$script:ArmWebDefaultPort = 8765
$script:ArmWebLogDefaultLines = 200
$script:ArmWebLogMaxLines = 1000
$script:ArmWebActiveRipStates = @('Detected', 'Ripping', 'Moving')

# Route table: ordered list of @{ Method; Pattern; Handler }. Pattern is a regex
# matched against the whole URL path (anchored by Invoke-ArmWebRequest); named
# groups are passed to the handler as $Request.Params. Add routes with
# Register-ArmWebRoute (S3 adds POST routes the same way).
$script:ArmWebRoutes = [System.Collections.Generic.List[object]]::new()

<#
.SYNOPSIS
    Build a web response hashtable.
#>
function New-ArmWebResponse {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure constructor for a response hashtable; changes no state.')]
    [OutputType([hashtable])]
    param(
        [int] $Status = 200,
        [string] $ContentType = 'text/plain; charset=utf-8',
        [AllowEmptyString()]
        [string] $Body = '',
        [hashtable] $Headers = @{}
    )

    return @{ Status = $Status; ContentType = $ContentType; Body = $Body; Headers = $Headers }
}

<#
.SYNOPSIS
    Build a JSON web response. -AsArray always serializes a JSON array (even for 0/1 items).
#>
function New-ArmWebJsonResponse {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure constructor for a response hashtable; changes no state.')]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object] $InputObject,
        [int] $Status = 200,
        [switch] $AsArray
    )

    $json = if ($AsArray) {
        # An array passed as -InputObject always serializes as a JSON array
        # (including [] and single-item); -AsArray would nest it a second time.
        ConvertTo-Json -InputObject @($InputObject | Where-Object { $null -ne $_ }) -Depth 6
    } else {
        ConvertTo-Json -InputObject $InputObject -Depth 6
    }
    return (New-ArmWebResponse -Status $Status -ContentType 'application/json; charset=utf-8' -Body $json)
}

<#
.SYNOPSIS
    Register a route: Method + anchored path regex + handler scriptblock.

.DESCRIPTION
    The handler is invoked with one argument, the request hashtable
    @{ Method; Path; Query; Body; Headers; Params; Config }, and must return a
    response from New-ArmWebResponse / New-ArmWebJsonResponse.
#>
function Register-ArmWebRoute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST')]
        [string] $Method,

        [Parameter(Mandatory = $true)]
        [string] $Pattern,

        [Parameter(Mandatory = $true)]
        [scriptblock] $Handler
    )

    $script:ArmWebRoutes.Add(@{ Method = $Method; Pattern = "^$Pattern$"; Handler = $Handler })
}

<#
.SYNOPSIS
    HTML-encode any value ($null -> '').
#>
function ConvertTo-ArmHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

<#
.SYNOPSIS
    Format a timestamp field (datetime or string) as an ISO 8601 round-trip string.
#>
function ConvertTo-ArmIsoTimestamp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToString('o') }
    return [string]$Value
}

<#
.SYNOPSIS
    Project a job record into the stable shape served by /api/jobs (ISO timestamps).
#>
function ConvertTo-ArmWebJob {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Job
    )

    $names = $Job.PSObject.Properties.Name
    $out = [ordered]@{}
    foreach ($field in @('Id', 'Kind', 'State', 'Title', 'DiscLabel', 'DiscType', 'Drive', 'StagingDir',
            'DestDir', 'QueueFile', 'SamplePath', 'Error')) {
        $out[$field] = if ($names -contains $field -and $null -ne $Job.$field) { [string]$Job.$field } else { $null }
    }
    $out.Created = if ($names -contains 'Created') { ConvertTo-ArmIsoTimestamp -Value $Job.Created } else { $null }
    $out.Updated = if ($names -contains 'Updated') { ConvertTo-ArmIsoTimestamp -Value $Job.Updated } else { $null }
    $history = if ($names -contains 'History') { @($Job.History | Where-Object { $null -ne $_ }) } else { @() }
    $out.History = @(foreach ($entry in $history) {
            [ordered]@{
                State = [string]$entry.State
                At    = ConvertTo-ArmIsoTimestamp -Value $entry.At
            }
        })
    return $out
}

<#
.SYNOPSIS
    All jobs in /api/jobs shape, newest first, optionally filtered by Kind.
#>
function Get-ArmWebJobList {
    [CmdletBinding()]
    param(
        [ValidateSet('Rip', 'Upscale')]
        [string] $Kind,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $params = @{ Config = $Config }
    if ($Kind) { $params.Kind = $Kind }
    return @(foreach ($job in @(Get-ArmJobList @params)) { ConvertTo-ArmWebJob -Job $job })
}

<#
.SYNOPSIS
    Last N lines of today's wrm-<yyyyMMdd>.log (read-only, shared read so the
    pipeline can keep appending). Missing LogDir/file -> empty array.
#>
function Get-ArmLogTail {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [int] $Lines,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    if (-not $Config.ContainsKey('LogDir') -or -not $Config.LogDir) {
        return @()
    }
    $path = Join-Path $Config.LogDir "wrm-$(Get-Date -Format 'yyyyMMdd').log"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }

    $stream = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        $queue = [System.Collections.Generic.Queue[string]]::new()
        while ($null -ne ($line = $reader.ReadLine())) {
            $queue.Enqueue($line)
            if ($queue.Count -gt $Lines) { $null = $queue.Dequeue() }
        }
        return $queue.ToArray()
    } finally {
        $stream.Dispose()
    }
}

<#
.SYNOPSIS
    Display name for a job: Title, else DiscLabel, else a placeholder.
#>
function Get-ArmWebJobDisplayTitle {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Job
    )

    if ($Job.Title) { return $Job.Title }
    if ($Job.DiscLabel) { return $Job.DiscLabel }
    return '(unidentified disc)'
}

<#
.SYNOPSIS
    State badge HTML (state names are a fixed set, but are encoded anyway).
#>
function Format-ArmWebStateBadge {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [string] $State
    )

    $s = ConvertTo-ArmHtml $State
    return "<span class=`"badge state-$s`" data-testid=`"job-state`">$s</span>"
}

<#
.SYNOPSIS
    Render the dashboard HTML (server-side initial state; app.js keeps it fresh).
#>
function Format-ArmWebDashboard {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Jobs,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $LogLines
    )

    $h = { param($v) ConvertTo-ArmHtml $v }
    $rips = @($Jobs | Where-Object { $_.Kind -eq 'Rip' })
    $active = @($rips | Where-Object { $_.State -in $script:ArmWebActiveRipStates })
    $history = @($rips | Where-Object { $_.State -notin $script:ArmWebActiveRipStates })
    $upscales = @($Jobs | Where-Object { $_.Kind -eq 'Upscale' })

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append(@'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ripping Machine</title>
<link rel="icon" href="data:,">
<link rel="stylesheet" href="/app.css">
</head>
<body>
<header>
<h1>Ripping Machine</h1>
<span class="muted" id="refreshed" data-testid="refreshed"></span>
</header>
<main>
<section aria-labelledby="h-active">
<h2 id="h-active">Active rip</h2>
<div id="active-rip" data-testid="active-rip">
'@)

    if ($active.Count -eq 0) {
        $empty = if ($rips.Count -eq 0) { 'No rips yet' } else { 'No rip in progress' }
        $null = $sb.Append("<p class=`"empty`" data-testid=`"empty-rips`">$(& $h $empty)</p>`n")
    }
    foreach ($job in $active) {
        $null = $sb.Append("<article class=`"card`" data-testid=`"job`" data-job-id=`"$(& $h $job.Id)`">`n")
        $null = $sb.Append("<div class=`"card-head`"><h3 data-testid=`"job-title`">$(& $h (Get-ArmWebJobDisplayTitle -Job $job))</h3>$(Format-ArmWebStateBadge -State $job.State)</div>`n<dl>")
        foreach ($pair in @(@('Drive', $job.Drive), @('Disc type', $job.DiscType), @('Disc label', $job.DiscLabel),
                @('Staging dir', $job.StagingDir), @('Updated', $job.Updated))) {
            if ($pair[1]) {
                $null = $sb.Append("<dt>$(& $h $pair[0])</dt><dd>$(& $h $pair[1])</dd>")
            }
        }
        $null = $sb.Append("</dl>`n</article>`n")
    }

    $null = $sb.Append(@'
</div>
</section>
<section aria-labelledby="h-history">
<h2 id="h-history">Rip history</h2>
<table data-testid="rip-history">
<thead><tr><th>Title</th><th>Type</th><th>State</th><th>Destination / error</th><th>Updated</th></tr></thead>
<tbody id="rip-history-body">
'@)
    if ($history.Count -eq 0) {
        $null = $sb.Append("<tr class=`"empty`"><td colspan=`"5`">No finished rips</td></tr>`n")
    }
    foreach ($job in $history) {
        $detail = if ($job.State -eq 'Failed') { $job.Error } else { $job.DestDir }
        $null = $sb.Append("<tr data-testid=`"job`" data-job-id=`"$(& $h $job.Id)`"><td data-testid=`"job-title`">$(& $h (Get-ArmWebJobDisplayTitle -Job $job))</td><td>$(& $h $job.DiscType)</td><td>$(Format-ArmWebStateBadge -State $job.State)</td><td class=`"path`">$(& $h $detail)</td><td>$(& $h $job.Updated)</td></tr>`n")
    }

    $null = $sb.Append(@'
</tbody>
</table>
</section>
<section aria-labelledby="h-upscale">
<h2 id="h-upscale">Upscale queue</h2>
<table data-testid="upscale-queue">
<thead><tr><th>Title</th><th>State</th><th>Sample / destination / error</th><th>Updated</th></tr></thead>
<tbody id="upscale-queue-body">
'@)
    if ($upscales.Count -eq 0) {
        $null = $sb.Append("<tr class=`"empty`"><td colspan=`"4`">No upscale jobs</td></tr>`n")
    }
    foreach ($job in $upscales) {
        $detail = if ($job.State -eq 'Failed') { $job.Error } elseif ($job.SamplePath -and $job.State -eq 'AwaitingReview') { $job.SamplePath } else { $job.DestDir }
        $null = $sb.Append("<tr data-testid=`"job`" data-job-id=`"$(& $h $job.Id)`"><td data-testid=`"job-title`">$(& $h (Get-ArmWebJobDisplayTitle -Job $job))</td><td>$(Format-ArmWebStateBadge -State $job.State)</td><td class=`"path`">$(& $h $detail)</td><td>$(& $h $job.Updated)</td></tr>`n")
    }

    $null = $sb.Append(@'
</tbody>
</table>
</section>
<section aria-labelledby="h-log">
<h2 id="h-log">Today's log</h2>
<pre id="log-tail" data-testid="log-tail">
'@)
    $null = $sb.Append((& $h ($LogLines -join "`n")))
    $null = $sb.Append(@'
</pre>
</section>
</main>
<script src="/app.js"></script>
</body>
</html>
'@)
    return $sb.ToString()
}

<#
.SYNOPSIS
    Serve a fixed static asset from src/webui (names are hard-coded by the routes;
    no request data ever reaches a file path).
#>
function Get-ArmWebStaticResponse {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('app.js', 'app.css')]
        [string] $Name
    )

    $type = if ($Name -like '*.js') { 'text/javascript; charset=utf-8' } else { 'text/css; charset=utf-8' }
    $body = [System.IO.File]::ReadAllText((Join-Path $script:ArmWebStaticDir $Name))
    return (New-ArmWebResponse -ContentType $type -Body $body)
}

# --- Routes ------------------------------------------------------------------

Register-ArmWebRoute -Method GET -Pattern '/' -Handler {
    param($Request)
    $jobs = @(Get-ArmWebJobList -Config $Request.Config)
    $log = @(Get-ArmLogTail -Lines $script:ArmWebLogDefaultLines -Config $Request.Config)
    New-ArmWebResponse -ContentType 'text/html; charset=utf-8' -Body (Format-ArmWebDashboard -Jobs $jobs -LogLines $log)
}

Register-ArmWebRoute -Method GET -Pattern '/app\.js' -Handler { param($Request) $null = $Request; Get-ArmWebStaticResponse -Name 'app.js' }
Register-ArmWebRoute -Method GET -Pattern '/app\.css' -Handler { param($Request) $null = $Request; Get-ArmWebStaticResponse -Name 'app.css' }

Register-ArmWebRoute -Method GET -Pattern '/api/jobs' -Handler {
    param($Request)
    $kind = $Request.Query['kind']
    if ($kind) {
        $match = @('Rip', 'Upscale') | Where-Object { $_ -eq $kind }
        if (-not $match) {
            return (New-ArmWebJsonResponse -Status 400 -InputObject @{ Error = "Unknown kind '$kind' (expected Rip or Upscale)" })
        }
        return (New-ArmWebJsonResponse -AsArray -InputObject (Get-ArmWebJobList -Kind $match -Config $Request.Config))
    }
    New-ArmWebJsonResponse -AsArray -InputObject (Get-ArmWebJobList -Config $Request.Config)
}

Register-ArmWebRoute -Method GET -Pattern '/api/jobs/(?<id>[^/]+)' -Handler {
    param($Request)
    $job = Get-ArmJob -JobId $Request.Params.id -Config $Request.Config
    if (-not $job) {
        return (New-ArmWebJsonResponse -Status 404 -InputObject @{ Error = 'Job not found' })
    }
    New-ArmWebJsonResponse -InputObject (ConvertTo-ArmWebJob -Job $job)
}

Register-ArmWebRoute -Method GET -Pattern '/api/log' -Handler {
    param($Request)
    $lines = $script:ArmWebLogDefaultLines
    $raw = $Request.Query['lines']
    if ($raw) {
        $parsed = 0
        if (-not [int]::TryParse($raw, [ref]$parsed)) {
            return (New-ArmWebJsonResponse -Status 400 -InputObject @{ Error = "lines must be an integer" })
        }
        $lines = [Math]::Min([Math]::Max($parsed, 1), $script:ArmWebLogMaxLines)
    }
    New-ArmWebJsonResponse -InputObject ([ordered]@{ Lines = @(Get-ArmLogTail -Lines $lines -Config $Request.Config) })
}

<#
.SYNOPSIS
    Route one request to its handler. Pure: no sockets, so it is unit-testable.

.DESCRIPTION
    Matches Path against the route table (anchored regexes). No path match -> 404;
    path matches but not for this method -> 405 with an Allow header. A handler that
    throws -> 500 (logged at ERROR); the exception text is not sent to the client.

.PARAMETER Method
    HTTP method (GET, POST, ...).

.PARAMETER Path
    URL path only (no query string), e.g. '/api/jobs'.

.PARAMETER Query
    Query-string values (hashtable, case-insensitive keys).

.PARAMETER Body
    Request body as a string (POST routes).

.PARAMETER Headers
    Request headers (hashtable, case-insensitive keys).

.PARAMETER Config
    Configuration hashtable.

.OUTPUTS
    [hashtable] @{ Status; ContentType; Body; Headers }
#>
function Invoke-ArmWebRequest {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Method,

        [Parameter(Mandatory = $true)]
        [string] $Path,

        [hashtable] $Query = @{},

        [AllowEmptyString()]
        [string] $Body = '',

        [hashtable] $Headers = @{},

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $method = $Method.ToUpperInvariant()
    $allowed = [System.Collections.Generic.List[string]]::new()
    foreach ($route in $script:ArmWebRoutes) {
        $m = [regex]::Match($Path, $route.Pattern)
        if (-not $m.Success) { continue }
        if ($route.Method -ne $method) {
            if (-not $allowed.Contains($route.Method)) { $allowed.Add($route.Method) }
            continue
        }

        $params = @{}
        foreach ($group in $m.Groups) {
            if ($group.Name -notmatch '^\d+$') { $params[$group.Name] = $group.Value }
        }
        $request = @{
            Method  = $method
            Path    = $Path
            Query   = $Query
            Body    = $Body
            Headers = $Headers
            Params  = $params
            Config  = $Config
        }
        try {
            $response = & $route.Handler $request
            if ($response -is [array]) { $response = $response[-1] }
            if ($response -isnot [hashtable]) { throw "Route handler for $method $Path returned no response" }
            if (-not $response.ContainsKey('Headers') -or $null -eq $response.Headers) { $response.Headers = @{} }
            return $response
        } catch {
            Write-ArmLog -Level ERROR -Message "Web UI: $method $Path failed: $_" -Config $Config
            return (New-ArmWebJsonResponse -Status 500 -InputObject @{ Error = 'Internal server error' })
        }
    }

    if ($allowed.Count -gt 0) {
        $response = New-ArmWebJsonResponse -Status 405 -InputObject @{ Error = 'Method not allowed' }
        $response.Headers = @{ Allow = ($allowed -join ', ') }
        return $response
    }
    return (New-ArmWebJsonResponse -Status 404 -InputObject @{ Error = 'Not found' })
}

<#
.SYNOPSIS
    Translate one HttpListenerContext into Invoke-ArmWebRequest and write the reply.
    Never throws: a broken request/response is logged and the loop carries on.
#>
function Invoke-ArmWebListenerContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpListenerContext] $Context,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $req = $Context.Request
    $res = $Context.Response
    try {
        try {
            $query = @{}
            foreach ($key in $req.QueryString.AllKeys) {
                if ($key) { $query[$key] = $req.QueryString[$key] }
            }
            $headers = @{}
            foreach ($key in $req.Headers.AllKeys) {
                $headers[$key] = $req.Headers[$key]
            }
            $body = ''
            if ($req.HasEntityBody) {
                $reader = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
            $response = Invoke-ArmWebRequest -Method $req.HttpMethod -Path $req.Url.AbsolutePath -Query $query `
                -Body $body -Headers $headers -Config $Config
        } catch {
            Write-ArmLog -Level ERROR -Message "Web UI: request handling failed: $_" -Config $Config
            $response = New-ArmWebJsonResponse -Status 500 -InputObject @{ Error = 'Internal server error' }
        }

        $res.StatusCode = $response.Status
        $res.ContentType = $response.ContentType
        $res.Headers['Cache-Control'] = 'no-store'
        $res.Headers['X-Content-Type-Options'] = 'nosniff'
        $res.Headers['Content-Security-Policy'] = "default-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
        foreach ($key in $response.Headers.Keys) {
            $res.Headers[$key] = [string]$response.Headers[$key]
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$response.Body)
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch {
        Write-ArmLog -Level WARN -Message "Web UI: could not send response: $_" -Config $Config
    } finally {
        try { $res.Close() } catch { Write-Verbose "Response close failed: $_" }
    }
}

<#
.SYNOPSIS
    WebUi entry point: serve the dashboard on http://localhost:<WebUiPort>/.

.DESCRIPTION
    Entry point script (guarded so dot-sourcing it for its functions, e.g. from
    tests, does not start the listener). Exits immediately (INFO log) when
    WebUiEnabled is $false. -Once serves exactly one request then exits (tests).
    Waits for requests in 500 ms slices so Ctrl+C can stop an interactive run.

.PARAMETER ConfigPath
    Path to config.psd1. Defaults per Get-ArmConfig.

.PARAMETER Simulate
    Force Simulate mode (kept for parity with the other entry points).

.PARAMETER Once
    Serve a single request, then exit.

.EXAMPLE
    ./WebUi.ps1 -Simulate
#>
function Start-ArmWebUi {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Daemon entry point that serves HTTP requests; not an interactive state-changing cmdlet.')]
    param(
        [string] $ConfigPath,
        [switch] $Simulate,
        [switch] $Once
    )

    $config = Get-ArmConfig -Path $ConfigPath
    if ($Simulate) {
        $config.Simulate = $true
    }

    if ($config.ContainsKey('WebUiEnabled') -and -not $config.WebUiEnabled) {
        Write-ArmLog -Level INFO -Message 'Web UI disabled (WebUiEnabled = $false); exiting.' -Config $config
        return
    }
    $port = if ($config.ContainsKey('WebUiPort') -and $config.WebUiPort) { [int]$config.WebUiPort } else { $script:ArmWebDefaultPort }

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$port/")
    try {
        $listener.Start()
    } catch {
        Write-ArmLog -Level ERROR -Message "Web UI: could not listen on http://localhost:$port/ : $_" -Config $config
        throw
    }
    Write-ArmLog -Level INFO -Message "Web UI listening on http://localhost:$port/" -Config $config

    try {
        do {
            $pending = $listener.GetContextAsync()
            while (-not $pending.AsyncWaitHandle.WaitOne(500)) { }
            Invoke-ArmWebListenerContext -Context $pending.GetAwaiter().GetResult() -Config $config
        } while (-not $Once)
    } finally {
        $listener.Close()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-ArmWebUi @PSBoundParameters
}
