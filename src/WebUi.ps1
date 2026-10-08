param(
    [string] $ConfigPath,
    [switch] $Simulate,
    [switch] $Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'JobState.ps1')
. (Join-Path $PSScriptRoot 'Resolve-Title.ps1')
. (Join-Path $PSScriptRoot 'Rip-VideoDisc.ps1')

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
$script:ArmWebMetadataMaxLength = 200
$script:ArmWebMetadataMaxBody = 4096

# POSTs must carry this header (value '1'). A cross-origin page can't add a custom
# header without a CORS preflight, which this server never grants - so this is
# the CSRF guard for the state-changing routes.
$script:ArmWebActionHeader = 'X-WRM-Action'

# Upscale job actions: which job states each one is valid in (the single source
# of truth - /api/jobs exposes the result as each job's Actions list, and both
# renderers draw buttons from it).
$script:ArmWebUpscaleActionStates = [ordered]@{
    approve = @('AwaitingReview')
    retry   = @('Failed')
    cancel  = @('Queued', 'AwaitingReview')
}

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
            'DestDir', 'QueueFile', 'SamplePath', 'ContentType', 'Engine', 'InterlaceType', 'Error')) {
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
    $out.Actions = @(Get-ArmWebJobActionList -Kind $out.Kind -State $out.State -DiscType $out.DiscType)
    return $out
}

<#
.SYNOPSIS
    Actions valid for a job right now. Upscale jobs: approve / retry / cancel
    (empty while the worker is processing). Video rips: 'metadata' (manual title
    edit) while Ripping.
#>
function Get-ArmWebJobActionList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [string] $Kind,

        [AllowNull()]
        [string] $State,

        [AllowNull()]
        [string] $DiscType
    )

    if ($Kind -eq 'Rip') {
        if ($State -eq 'Ripping' -and $DiscType -ne 'AudioCD') { return @('metadata') }
        return @()
    }
    if ($Kind -ne 'Upscale') { return @() }
    return @(foreach ($action in $script:ArmWebUpscaleActionStates.Keys) {
            if ($State -in $script:ArmWebUpscaleActionStates[$action]) { $action }
        })
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
    Action buttons for an upscale row (app.js renders the same markup from the
    job's Actions list and handles the clicks).
#>
function Format-ArmWebActionButtons {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Actions
    )

    $labels = @{ approve = 'Approve'; retry = 'Retry'; cancel = 'Cancel' }
    return (@(foreach ($action in @($Actions)) {
                if ($action -and $labels.ContainsKey($action)) {
                    $a = ConvertTo-ArmHtml $action
                    "<button type=`"button`" class=`"action action-$a`" data-action=`"$a`" data-testid=`"action-$a`">$(ConvertTo-ArmHtml $labels[$action])</button>"
                }
            }) -join ' ')
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
<p id="action-message" class="action-message" data-testid="action-message" role="status"></p>
<table data-testid="upscale-queue">
<thead><tr><th>Title</th><th>State</th><th>Sample / destination / error</th><th>Updated</th><th>Actions</th></tr></thead>
<tbody id="upscale-queue-body">
'@)
    if ($upscales.Count -eq 0) {
        $null = $sb.Append("<tr class=`"empty`"><td colspan=`"5`">No upscale jobs</td></tr>`n")
    }
    foreach ($job in $upscales) {
        $showSample = $job.SamplePath -and $job.State -eq 'AwaitingReview'
        $detail = if ($job.State -eq 'Failed') { $job.Error } elseif ($showSample) { $job.SamplePath } else { $job.DestDir }
        $copy = if ($showSample) { ' <button type="button" class="copy" data-action="copy" data-testid="copy-sample">Copy path</button>' } else { '' }
        $metaParts = @($job.Engine, $job.ContentType, $job.InterlaceType) | Where-Object { $_ }
        $meta = if ($metaParts) { " <span class=`"upscale-meta`" data-testid=`"upscale-meta`">$(& $h ($metaParts -join ' / '))</span>" } else { '' }
        $null = $sb.Append("<tr data-testid=`"job`" data-job-id=`"$(& $h $job.Id)`"><td data-testid=`"job-title`">$(& $h (Get-ArmWebJobDisplayTitle -Job $job))</td><td>$(Format-ArmWebStateBadge -State $job.State)</td><td class=`"path`"><span class=`"path-text`">$(& $h $detail)</span>$copy$meta</td><td>$(& $h $job.Updated)</td><td class=`"actions`">$(Format-ArmWebActionButtons -Actions $job.Actions)</td></tr>`n")
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

<#
.SYNOPSIS
    Locate an upscale job's queue file, refusing anything outside UpscaleQueueDir.

.DESCRIPTION
    The path comes only from the job record (never from the request). Even so, the
    record's directory must be UpscaleQueueDir, and the file name must carry one of
    the expected extensions, so a tampered/stale record can't steer a rename or
    delete anywhere else. The returned Path is rebuilt from the configured queue
    dir + the file name.

.OUTPUTS
    [hashtable] @{ Path; Name } on success, or @{ Error } when refused.
#>
function Resolve-ArmWebQueueFile {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Job,

        [Parameter(Mandatory = $true)]
        [string[]] $Extension,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    if (-not $Config.ContainsKey('UpscaleQueueDir') -or -not $Config.UpscaleQueueDir) {
        return @{ Error = 'UpscaleQueueDir is not configured' }
    }
    $recorded = if ($Job.PSObject.Properties.Name -contains 'QueueFile') { [string]$Job.QueueFile } else { '' }
    if (-not $recorded) {
        return @{ Error = 'This job has no queue file on record; re-queue it by hand' }
    }

    try {
        $queueDir = [System.IO.Path]::GetFullPath($Config.UpscaleQueueDir).TrimEnd('\', '/')
        $full = [System.IO.Path]::GetFullPath($recorded)
    } catch {
        return @{ Error = "The job's queue file path is invalid" }
    }
    $parent = [System.IO.Path]::GetDirectoryName($full)
    if (-not $parent -or -not [string]::Equals($parent.TrimEnd('\', '/'), $queueDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        return @{ Error = "The job's queue file is not inside UpscaleQueueDir; refusing to touch it" }
    }

    $name = [System.IO.Path]::GetFileName($full)
    $ext = [System.IO.Path]::GetExtension($name)
    if ($ext -notin $Extension) {
        return @{ Error = "The job's queue file '$name' is not a $($Extension -join ' / ') file" }
    }
    return @{ Path = (Join-Path $queueDir $name); Name = $name }
}

<#
.SYNOPSIS
    Approve / retry / cancel an upscale job (the web UI's POST actions).

.DESCRIPTION
    Performs the same queue-file renames a user would do by hand (README "Upscale
    review workflow"), then records the new job state:
      approve  AwaitingReview: <name>.awaiting-review -> <name>.json (SampleGenerated
               stays true, so the worker runs the full upscale)        -> Queued
      retry    Failed: <name>.failed -> <name>.json with SampleGenerated removed
               (so the sample/review gate runs again)                  -> Queued
      cancel   Queued / AwaitingReview: the queue file is deleted      -> Cancelled

    Any other state (notably Sampling / Upscaling, when the worker owns the file)
    is a 409, as is a queue file that is missing, unparseable (retry), or would
    overwrite an existing .json. The worker only ever picks up *.json, so the
    approve/retry renames can't race it. Cancel of a Queued job can: the file is
    first parked under a non-.json name, the job is re-read, and if the worker
    has meanwhile started it the file is put back and the cancel refused (409).
    If the job record can't be written, the file operation is rolled back so the
    record and the queue directory never disagree.

.OUTPUTS
    [hashtable] web response (200 with the updated job, or 404 / 409 / 500).
#>
function Invoke-ArmWebUpscaleAction {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $JobId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('approve', 'retry', 'cancel')]
        [string] $Action,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $action = $Action.ToLowerInvariant()
    $conflict = { param($message) New-ArmWebJsonResponse -Status 409 -InputObject @{ Error = $message } }

    $job = Get-ArmJob -JobId $JobId -Config $Config
    if (-not $job -or $job.Kind -ne 'Upscale') {
        return (New-ArmWebJsonResponse -Status 404 -InputObject @{ Error = 'Upscale job not found' })
    }
    $state = [string]$job.State
    $allowed = $script:ArmWebUpscaleActionStates[$action]
    if ($state -notin $allowed) {
        return (& $conflict "Cannot $action a job that is $state (only when $($allowed -join ' or '))")
    }

    $extension = switch ($action) {
        'approve' { @('.awaiting-review') }
        'retry' { @('.failed') }
        'cancel' { if ($state -eq 'Queued') { @('.json') } else { @('.awaiting-review') } }
    }
    $resolved = Resolve-ArmWebQueueFile -Job $job -Extension $extension -Config $Config
    if ($resolved.ContainsKey('Error')) {
        return (& $conflict $resolved.Error)
    }
    $file = $resolved.Path
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        return (& $conflict "Queue file '$($resolved.Name)' no longer exists")
    }

    $rollback = $null
    $properties = $null
    try {
        switch ($action) {
            'approve' {
                $target = [System.IO.Path]::ChangeExtension($file, '.json')
                if (Test-Path -LiteralPath $target) {
                    return (& $conflict "'$([System.IO.Path]::GetFileName($target))' already exists in the queue")
                }
                Move-Item -LiteralPath $file -Destination $target -ErrorAction Stop
                $rollback = @{ From = $target; To = $file }
                $properties = @{ State = 'Queued'; QueueFile = $target; Error = $null }
            }
            'retry' {
                $target = [System.IO.Path]::ChangeExtension($file, '.json')
                if (Test-Path -LiteralPath $target) {
                    return (& $conflict "'$([System.IO.Path]::GetFileName($target))' already exists in the queue")
                }
                $item = $null
                try {
                    $item = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                } catch {
                    $item = $null
                }
                if ($item -isnot [System.Collections.IDictionary] -or -not $item['Source']) {
                    return (& $conflict "Queue file '$($resolved.Name)' is not a valid queue entry; fix or delete it by hand")
                }
                # Rewrite in place first (the worker ignores .failed), then rename.
                $original = Get-Content -LiteralPath $file -Raw -ErrorAction Stop
                $item.Remove('SampleGenerated')
                $item['JobId'] = $JobId
                $item | ConvertTo-Json | Set-Content -LiteralPath $file -Encoding utf8 -ErrorAction Stop
                try {
                    Move-Item -LiteralPath $file -Destination $target -ErrorAction Stop
                } catch {
                    Set-Content -LiteralPath $file -Value $original -NoNewline -Encoding utf8 -ErrorAction SilentlyContinue
                    throw
                }
                $rollback = @{ From = $target; To = $file }
                $properties = @{ State = 'Queued'; QueueFile = $target; Error = $null; SamplePath = $null }
            }
            'cancel' {
                $parked = [System.IO.Path]::ChangeExtension($file, '.cancelling')
                if (Test-Path -LiteralPath $parked) {
                    return (& $conflict "'$([System.IO.Path]::GetFileName($parked))' already exists in the queue")
                }
                Move-Item -LiteralPath $file -Destination $parked -ErrorAction Stop
                $rollback = @{ From = $parked; To = $file }
                $now = Get-ArmJob -JobId $JobId -Config $Config
                if ($now -and [string]$now.State -notin $allowed) {
                    Move-Item -LiteralPath $parked -Destination $file -ErrorAction SilentlyContinue
                    return (& $conflict "The job became $($now.State) while cancelling; it can no longer be cancelled")
                }
                $properties = @{ State = 'Cancelled'; QueueFile = $null }
            }
        }
    } catch {
        Write-ArmLog -Level WARN -Message "Web UI: $action of job $JobId failed: $_" -Config $Config
        return (& $conflict "Could not $action the job: the queue file changed underneath (try again)")
    }

    if (-not (Update-ArmJob -JobId $JobId -Properties $properties -Config $Config)) {
        try {
            Move-Item -LiteralPath $rollback.From -Destination $rollback.To -ErrorAction Stop
        } catch {
            Write-ArmLog -Level ERROR -Message "Web UI: $action of job $JobId could not record state nor roll back $($rollback.From): $_" -Config $Config
        }
        return (New-ArmWebJsonResponse -Status 500 -InputObject @{ Error = 'Could not update the job record; the queue file was left as it was' })
    }

    if ($action -eq 'cancel') {
        try {
            Remove-Item -LiteralPath $rollback.From -Force -ErrorAction Stop
        } catch {
            Write-ArmLog -Level WARN -Message "Web UI: cancelled job $JobId but could not delete $($rollback.From): $_" -Config $Config
        }
    }
    Write-ArmLog -Level INFO -Message "Web UI: $action of upscale job $JobId -> $($properties.State)" -Config $Config
    return (New-ArmWebJsonResponse -InputObject (ConvertTo-ArmWebJob -Job (Get-ArmJob -JobId $JobId -Config $Config)))
}

<#
.SYNOPSIS
    Validate a manual Title/Year and compute the NAS folder name it would produce.

.DESCRIPTION
    The folder name comes from the same ConvertTo-ArmFolderName rule the pipeline
    uses (Resolve-TitleOverride), so the UI preview and the real rename agree.
    Title: required, at most 200 chars, no control characters, and must still be
    non-blank after invalid filename characters are stripped (so ':' alone is
    refused) and must not be a Windows-reserved/dot-only name. Year: blank or
    exactly 4 digits.

.OUTPUTS
    [hashtable] @{ Valid; Title; Year; FolderName; Errors } (Errors: field -> message).
#>
function Test-ArmWebMetadataInput {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Title,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Year
    )

    $errors = [ordered]@{}
    $titleTrim = if ($null -ne $Title) { $Title.Trim() } else { '' }
    $yearTrim = if ($null -ne $Year) { $Year.Trim() } else { '' }
    $folder = ''

    if (-not $titleTrim) {
        $errors.Title = 'Title is required'
    } elseif ($titleTrim.Length -gt $script:ArmWebMetadataMaxLength) {
        $errors.Title = "Title must be at most $($script:ArmWebMetadataMaxLength) characters"
    } elseif ($titleTrim -match '[\x00-\x1f\x7f]') {
        $errors.Title = 'Title must not contain control characters'
    } elseif (-not (ConvertTo-ArmSafeFileName -Name $titleTrim)) {
        $errors.Title = 'Title has no usable characters left after removing characters Windows does not allow in names'
    }

    if ($yearTrim -and $yearTrim -notmatch '^[0-9]{4}$') {
        $errors.Year = 'Year must be blank or 4 digits'
    }

    if (-not $errors.Contains('Title')) {
        $folder = ConvertTo-ArmFolderName -Title $titleTrim -Year $yearTrim
        if (-not $folder -or $folder -match '^\.+$' -or $folder -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$') {
            $errors.Title = 'Title would produce a folder name Windows does not allow'
            $folder = ''
        }
    }

    return @{
        Valid      = ($errors.Count -eq 0)
        Title      = $titleTrim
        Year       = $yearTrim
        FolderName = $folder
        Errors     = $errors
    }
}

<#
.SYNOPSIS
    Locate a rip job's staging directory, refusing anything outside StagingDir.

.DESCRIPTION
    The path comes only from the job record (never the request). The directory
    must exist and be a direct child of the configured StagingDir.

.OUTPUTS
    [hashtable] @{ Path } on success, or @{ Error } when refused.
#>
function Resolve-ArmWebStagingDir {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Job,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    if (-not $Config.ContainsKey('StagingDir') -or -not $Config.StagingDir) {
        return @{ Error = 'StagingDir is not configured' }
    }
    $recorded = if ($Job.PSObject.Properties.Name -contains 'StagingDir') { [string]$Job.StagingDir } else { '' }
    if (-not $recorded) {
        return @{ Error = 'This rip has no staging directory on record yet' }
    }
    try {
        $root = [System.IO.Path]::GetFullPath($Config.StagingDir).TrimEnd('\', '/')
        $full = [System.IO.Path]::GetFullPath($recorded).TrimEnd('\', '/')
    } catch {
        return @{ Error = "The rip's staging directory path is invalid" }
    }
    $parent = [System.IO.Path]::GetDirectoryName($full)
    if (-not $parent -or -not [string]::Equals($parent.TrimEnd('\', '/'), $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return @{ Error = "The rip's staging directory is not inside StagingDir; refusing to touch it" }
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        return @{ Error = 'The rip''s staging directory no longer exists' }
    }
    return @{ Path = $full }
}

<#
.SYNOPSIS
    $null when a rip job's metadata can be edited now, else the reason (for a 409).
#>
function Get-ArmWebMetadataBlocker {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Job
    )

    $discType = if ($Job.PSObject.Properties.Name -contains 'DiscType') { [string]$Job.DiscType } else { '' }
    if ($discType -eq 'AudioCD') {
        return 'Audio CDs have no editable title metadata'
    }
    if ([string]$Job.State -ne 'Ripping') {
        return "Cannot edit metadata of a rip that is $($Job.State) (only while Ripping)"
    }
    return $null
}

<#
.SYNOPSIS
    Current Title/Year from a staging dir's metadata.json ('' / '' when absent or unreadable).
#>
function Read-ArmWebMetadata {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StagingDir
    )

    $result = @{ Title = ''; Year = '' }
    $path = Join-Path $StagingDir 'metadata.json'
    try {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $json = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($field in @('Title', 'Year')) {
                $prop = $json.PSObject.Properties[$field]
                if ($prop -and $null -ne $prop.Value) { $result[$field] = ([string]$prop.Value).Trim() }
            }
        }
    } catch {
        Write-Verbose "Unreadable metadata.json in '$StagingDir': $_"
    }
    return $result
}

<#
.SYNOPSIS
    GET /api/jobs/<id>/metadata: the form's prefill (and whether it is editable).
#>
function Get-ArmWebMetadata {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $JobId,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $job = Get-ArmJob -JobId $JobId -Config $Config
    if (-not $job -or $job.Kind -ne 'Rip') {
        return (New-ArmWebJsonResponse -Status 404 -InputObject @{ Error = 'Rip job not found' })
    }
    $staging = Resolve-ArmWebStagingDir -Job $job -Config $Config
    $meta = if ($staging.ContainsKey('Path')) { Read-ArmWebMetadata -StagingDir $staging.Path } else { @{ Title = ''; Year = '' } }
    $blocker = Get-ArmWebMetadataBlocker -Job $job
    if (-not $blocker -and $staging.ContainsKey('Error')) { $blocker = $staging.Error }
    $check = Test-ArmWebMetadataInput -Title $meta.Title -Year $meta.Year
    return (New-ArmWebJsonResponse -InputObject ([ordered]@{
                Editable   = (-not $blocker)
                Reason     = $blocker
                Title      = $meta.Title
                Year       = $meta.Year
                FolderName = $check.FolderName
                Current    = if ($job.PSObject.Properties.Name -contains 'Title') { [string]$job.Title } else { '' }
            }))
}

<#
.SYNOPSIS
    POST /api/jobs/<id>/metadata {Title; Year}: write the manual title override.

.DESCRIPTION
    Writes the same metadata.json the user can hand-edit (Set-ArmMetadataFile
    -Force, atomic), which Resolve-TitleOverride reads right before the rename +
    NAS move - no pipeline change. Allowed only for a video rip that is Ripping
    (404 unknown job, 409 otherwise); invalid input is a 400 with per-field
    errors and nothing is written. The path comes from the job record and is
    checked to sit directly under StagingDir. After writing, the file is read
    back and the job re-read: if the rip moved on meanwhile the response is a
    409 saying the edit may not have been applied.

.OUTPUTS
    [hashtable] web response.
#>
function Save-ArmWebMetadata {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Request handler; the caller has already authorized the action (CSRF header).')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $JobId,

        [AllowEmptyString()]
        [string] $Body,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $job = Get-ArmJob -JobId $JobId -Config $Config
    if (-not $job -or $job.Kind -ne 'Rip') {
        return (New-ArmWebJsonResponse -Status 404 -InputObject @{ Error = 'Rip job not found' })
    }
    $blocker = Get-ArmWebMetadataBlocker -Job $job
    if ($blocker) {
        return (New-ArmWebJsonResponse -Status 409 -InputObject @{ Error = $blocker })
    }
    $staging = Resolve-ArmWebStagingDir -Job $job -Config $Config
    if ($staging.ContainsKey('Error')) {
        return (New-ArmWebJsonResponse -Status 409 -InputObject @{ Error = $staging.Error })
    }

    $badRequest = { param($message) New-ArmWebJsonResponse -Status 400 -InputObject @{ Error = $message } }
    if ($Body.Length -gt $script:ArmWebMetadataMaxBody) {
        return (& $badRequest 'Request body is too large')
    }
    $payload = $null
    try {
        $payload = $Body | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return (& $badRequest 'Body must be JSON like {"Title":"...","Year":"1999"}')
    }
    if ($payload -isnot [pscustomobject]) {
        return (& $badRequest 'Body must be a JSON object with Title and Year')
    }
    $title = $payload.PSObject.Properties['Title']
    $year = $payload.PSObject.Properties['Year']
    if (-not $title -or $title.Value -isnot [string]) {
        return (New-ArmWebJsonResponse -Status 400 -InputObject @{ Error = 'Validation failed'; Errors = @{ Title = 'Title is required' } })
    }
    $yearValue = ''
    if ($year -and $null -ne $year.Value) {
        if ($year.Value -isnot [string] -and $year.Value -isnot [int] -and $year.Value -isnot [long]) {
            return (New-ArmWebJsonResponse -Status 400 -InputObject @{ Error = 'Validation failed'; Errors = @{ Year = 'Year must be blank or 4 digits' } })
        }
        $yearValue = [string]$year.Value
    }

    $check = Test-ArmWebMetadataInput -Title $title.Value -Year $yearValue
    if (-not $check.Valid) {
        return (New-ArmWebJsonResponse -Status 400 -InputObject @{ Error = 'Validation failed'; Errors = $check.Errors })
    }

    Set-ArmMetadataFile -OutputDir $staging.Path -Title $check.Title -Year $check.Year -Config $Config -Force
    $written = Read-ArmWebMetadata -StagingDir $staging.Path
    if ($written.Title -ne $check.Title -or $written.Year -ne $check.Year) {
        return (New-ArmWebJsonResponse -Status 500 -InputObject @{ Error = 'Could not write metadata.json; see the log' })
    }

    $now = Get-ArmJob -JobId $JobId -Config $Config
    if ($now -and [string]$now.State -ne 'Ripping') {
        Write-ArmLog -Level WARN -Message "Web UI: metadata edit for job $JobId saved but the rip is now $($now.State)" -Config $Config
        return (New-ArmWebJsonResponse -Status 409 -InputObject @{ Error = "The rip became $($now.State) while saving; the edit may not have been applied" })
    }
    $null = Update-ArmJob -JobId $JobId -Properties @{ Title = $check.FolderName } -Config $Config
    Write-ArmLog -Level INFO -Message "Web UI: metadata for rip $JobId set to '$($check.FolderName)'" -Config $Config
    return (New-ArmWebJsonResponse -InputObject ([ordered]@{
                Title      = $check.Title
                Year       = $check.Year
                FolderName = $check.FolderName
            }))
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

Register-ArmWebRoute -Method POST -Pattern '/api/jobs/(?<id>[^/]+)/(?<action>approve|retry|cancel)' -Handler {
    param($Request)
    Invoke-ArmWebUpscaleAction -JobId $Request.Params.id -Action $Request.Params.action -Config $Request.Config
}

Register-ArmWebRoute -Method GET -Pattern '/api/jobs/(?<id>[^/]+)/metadata' -Handler {
    param($Request)
    Get-ArmWebMetadata -JobId $Request.Params.id -Config $Request.Config
}

Register-ArmWebRoute -Method POST -Pattern '/api/jobs/(?<id>[^/]+)/metadata' -Handler {
    param($Request)
    Save-ArmWebMetadata -JobId $Request.Params.id -Body $Request.Body -Config $Request.Config
}

# Folder-name preview for the edit form, so the sanitising rule lives only in PowerShell.
Register-ArmWebRoute -Method GET -Pattern '/api/metadata-preview' -Handler {
    param($Request)
    $check = Test-ArmWebMetadataInput -Title ([string]$Request.Query['title']) -Year ([string]$Request.Query['year'])
    New-ArmWebJsonResponse -InputObject ([ordered]@{ Valid = $check.Valid; FolderName = $check.FolderName; Errors = $check.Errors })
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
    path matches but not for this method -> 405 with an Allow header; a matched
    POST without the 'X-WRM-Action: 1' header -> 403 (CSRF guard). A handler that
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

        # CSRF guard: every state-changing route needs the custom header, checked
        # before the handler (and so before any job lookup) runs.
        if ($method -eq 'POST' -and [string]$Headers[$script:ArmWebActionHeader] -ne '1') {
            return (New-ArmWebJsonResponse -Status 403 -InputObject @{ Error = "Missing $($script:ArmWebActionHeader): 1 header" })
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

    $config = Get-ArmConfig -Path $ConfigPath -Simulate:$Simulate

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
