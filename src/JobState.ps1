Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Persistent job-state store for rips and upscale jobs (read by the web UI).

.DESCRIPTION
    One JSON file per job in <StateDir>\jobs\<id>.json. Writes are atomic
    (write a unique .tmp next to the target, then File.Move with overwrite) so
    a concurrent reader never sees a half-written record.

    Every function here is best-effort: failures (missing/blank StateDir,
    unwritable directory, corrupt file) are logged at WARN and swallowed, never
    thrown, so job-state bookkeeping can never break a rip or an upscale.

    Job IDs are generated here ('yyyyMMdd-HHmmss-<6 hex>') and validated
    against that exact pattern on every lookup, so an ID can never be used to
    reach a path outside the jobs directory.

    Record fields (in order): Id, Kind, State, Title, DiscLabel, DiscType,
    Drive, StagingDir, DestDir, QueueFile, SamplePath, OutputFile, Error, Created, Updated,
    History. History is an array of @{ State; At } appended whenever State
    changes. Timestamps are ISO 8601 round-trip strings (local time).

    States:
      Rip     : Detected -> Ripping -> Moving -> Complete | Failed
      Upscale : Queued -> Sampling -> AwaitingReview -> Upscaling -> Complete | Failed
                (Cancelled is reserved for the web UI's cancel action;
                Skipped = the worker decided no upscale is needed, Reason says why)
#>

$script:ArmJobFields = @(
    'Id', 'Kind', 'State', 'Title', 'DiscLabel', 'DiscType', 'Drive', 'StagingDir',
    'DestDir', 'QueueFile', 'SamplePath', 'OutputFile', 'ContentType', 'Engine', 'InterlaceType', 'Error', 'Reason', 'Created', 'Updated', 'History'
)
$script:ArmJobIdPattern = '^\d{8}-\d{6}-[0-9a-f]{6}$'
$script:ArmJobTerminalStates = @('Complete', 'Failed', 'Cancelled', 'Skipped')
$script:ArmJobStateDirWarned = $false

<#
.SYNOPSIS
    Resolve (and create) the jobs directory, or $null when job state is unavailable.
#>
function Get-ArmJobDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    if (-not $Config.ContainsKey('StateDir') -or -not $Config.StateDir) {
        if (-not $script:ArmJobStateDirWarned) {
            $script:ArmJobStateDirWarned = $true
            Write-ArmLog -Level WARN -Message 'StateDir is not configured; job-state tracking is disabled.' -Config $Config
        }
        return $null
    }

    $dir = Join-Path $Config.StateDir 'jobs'
    try {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            $null = New-Item -ItemType Directory -Force -Path $dir
        }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            throw 'directory could not be created'
        }
        return $dir
    } catch {
        Write-ArmLog -Level WARN -Message "Job-state directory '$dir' is unavailable: $_" -Config $Config
        return $null
    }
}

<#
.SYNOPSIS
    True when the string is a well-formed job ID (guards every path built from one).
#>
function Test-ArmJobId {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $JobId
    )

    return [bool]($JobId -and $JobId -cmatch $script:ArmJobIdPattern)
}

<#
.SYNOPSIS
    Atomically write a job record (ordered dictionary) to <dir>\<id>.json.
#>
function Write-ArmJobRecord {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Directory,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Record,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $target = Join-Path $Directory "$($Record.Id).json"
    $tmp = "$target.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $Record | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($tmp, $target, $true)
        return $true
    } catch {
        Write-ArmLog -Level WARN -Message "Failed to write job record '$target': $_" -Config $Config
        try {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        } catch {
            Write-Verbose "Could not remove temp file '$tmp': $_"
        }
        return $false
    }
}

<#
.SYNOPSIS
    Read one job record file; $null when missing or unreadable (logged at WARN).
#>
function Read-ArmJobRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    # A reader can race the writer's rename; retry briefly on sharing violations.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                return $null
            }
            $job = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
            if (-not $job -or -not ($job.PSObject.Properties.Name -contains 'Id')) {
                throw 'record has no Id'
            }
            return $job
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 50
        } catch {
            Write-ArmLog -Level WARN -Message "Skipping unreadable job record '$Path': $_" -Config $Config
            return $null
        }
    }
    Write-ArmLog -Level WARN -Message "Job record '$Path' stayed locked; skipping." -Config $Config
    return $null
}

<#
.SYNOPSIS
    Convert a job pscustomobject into an ordered dictionary with every field present.
#>
function ConvertTo-ArmJobRecord {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Job
    )

    $record = [ordered]@{}
    foreach ($field in $script:ArmJobFields) {
        $record[$field] = if ($Job.PSObject.Properties.Name -contains $field) { $Job.$field } else { $null }
    }
    $record.History = @($record.History | Where-Object { $null -ne $_ })
    return $record
}

<#
.SYNOPSIS
    Create a new job record and return its ID.

.PARAMETER Kind
    'Rip' or 'Upscale'.

.PARAMETER Properties
    Initial field values (e.g. @{ State = 'Detected'; Drive = 'D:' }). Unknown
    keys are ignored; Id/Kind/Created/Updated/History are managed here.
    State defaults to 'Detected' (Rip) or 'Queued' (Upscale).

.OUTPUTS
    [string] the new job ID, or $null when job state is unavailable. Never throws.
#>
function New-ArmJob {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal bookkeeping called from unattended pipeline code; -WhatIf has no meaning here.')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Rip', 'Upscale')]
        [string] $Kind,

        [hashtable] $Properties = @{},

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    try {
        $dir = Get-ArmJobDirectory -Config $Config
        if (-not $dir) {
            return $null
        }

        $now = Get-Date
        $id = '{0}-{1}' -f $now.ToString('yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
        $stamp = $now.ToString('o')

        $record = [ordered]@{}
        foreach ($field in $script:ArmJobFields) {
            $record[$field] = if ($Properties.ContainsKey($field)) { $Properties[$field] } else { $null }
        }
        $record.Id = $id
        $record.Kind = $Kind
        if (-not $record.State) {
            $record.State = if ($Kind -eq 'Rip') { 'Detected' } else { 'Queued' }
        }
        $record.Created = $stamp
        $record.Updated = $stamp
        $record.History = @([ordered]@{ State = $record.State; At = $stamp })

        if (-not (Write-ArmJobRecord -Directory $dir -Record $record -Config $Config)) {
            return $null
        }
        return $id
    } catch {
        Write-ArmLog -Level WARN -Message "New-ArmJob failed: $_" -Config $Config
        return $null
    }
}

<#
.SYNOPSIS
    Merge properties into an existing job record (atomic write). Never throws.

.DESCRIPTION
    No-op when JobId is blank/malformed, the job does not exist, or job state
    is unavailable. Id/Kind/Created/History cannot be overwritten; Updated is
    stamped automatically; a State change appends to History.

.OUTPUTS
    [bool] $true when the record was written.
#>
function Update-ArmJob {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal bookkeeping called from unattended pipeline code; -WhatIf has no meaning here.')]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $JobId,

        [Parameter(Mandatory = $true)]
        [hashtable] $Properties,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    try {
        if (-not (Test-ArmJobId -JobId $JobId)) {
            return $false
        }
        $dir = Get-ArmJobDirectory -Config $Config
        if (-not $dir) {
            return $false
        }
        $job = Read-ArmJobRecord -Path (Join-Path $dir "$JobId.json") -Config $Config
        if (-not $job) {
            Write-ArmLog -Level WARN -Message "Update-ArmJob: job '$JobId' not found." -Config $Config
            return $false
        }

        $record = ConvertTo-ArmJobRecord -Job $job
        $stamp = (Get-Date).ToString('o')
        foreach ($key in $Properties.Keys) {
            if ($key -in @('Id', 'Kind', 'Created', 'Updated', 'History')) { continue }
            if ($key -notin $script:ArmJobFields) { continue }
            if ($key -eq 'State' -and $Properties.State -and $Properties.State -ne $record.State) {
                $record.History = @($record.History) + @([ordered]@{ State = $Properties.State; At = $stamp })
            }
            $record[$key] = $Properties[$key]
        }
        $record.Updated = $stamp

        return (Write-ArmJobRecord -Directory $dir -Record $record -Config $Config)
    } catch {
        Write-ArmLog -Level WARN -Message "Update-ArmJob '$JobId' failed: $_" -Config $Config
        return $false
    }
}

<#
.SYNOPSIS
    Get one job record by ID.

.OUTPUTS
    [pscustomobject] or $null (unknown/malformed ID, unreadable record, no state dir).
#>
function Get-ArmJob {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $JobId,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    try {
        if (-not (Test-ArmJobId -JobId $JobId)) {
            return $null
        }
        $dir = Get-ArmJobDirectory -Config $Config
        if (-not $dir) {
            return $null
        }
        return (Read-ArmJobRecord -Path (Join-Path $dir "$JobId.json") -Config $Config)
    } catch {
        Write-ArmLog -Level WARN -Message "Get-ArmJob '$JobId' failed: $_" -Config $Config
        return $null
    }
}

<#
.SYNOPSIS
    List job records, newest first, optionally filtered by Kind. Unreadable
    files are skipped (logged at WARN).

.OUTPUTS
    [pscustomobject] records on the pipeline (nothing when there are none);
    wrap the call in @() to always get an array.
#>
function Get-ArmJobList {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('Rip', 'Upscale')]
        [string] $Kind,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    try {
        $dir = Get-ArmJobDirectory -Config $Config
        if (-not $dir) {
            return @()
        }

        $jobs = foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            if ($file.BaseName -cnotmatch $script:ArmJobIdPattern) { continue }
            $job = Read-ArmJobRecord -Path $file.FullName -Config $Config
            if (-not $job) { continue }
            if ($Kind -and $job.Kind -ne $Kind) { continue }
            $job
        }
        # Id starts with a sortable local timestamp (yyyyMMdd-HHmmss), so sorting
        # on it is newest-first without depending on how ConvertFrom-Json typed
        # the Created field.
        return @($jobs | Sort-Object -Property Id -Descending)
    } catch {
        Write-ArmLog -Level WARN -Message "Get-ArmJobList failed: $_" -Config $Config
        return @()
    }
}

<#
.SYNOPSIS
    Delete terminal-state job records (Complete/Failed/Cancelled) whose last
    update is older than JobHistoryDays (default 30), plus stray .tmp files
    older than a day. Never throws.

.OUTPUTS
    [int] number of job records removed.
#>
function Remove-ArmStaleJobs {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Removes every stale job record in one call; name fixed by docs/PLAN-web-ui.md and SPEC.md.')]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $removed = 0
    try {
        $dir = Get-ArmJobDirectory -Config $Config
        if (-not $dir) {
            return 0
        }

        $days = 30
        if ($Config.ContainsKey('JobHistoryDays') -and $null -ne $Config.JobHistoryDays) {
            $days = [int] $Config.JobHistoryDays
        }
        $cutoff = (Get-Date).AddDays(-$days)

        foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            if ($file.BaseName -cnotmatch $script:ArmJobIdPattern) { continue }
            $job = Read-ArmJobRecord -Path $file.FullName -Config $Config
            if (-not $job -or $job.State -notin $script:ArmJobTerminalStates) { continue }
            # PS 7 ConvertFrom-Json already turns ISO 8601 strings into [datetime].
            $updated = [datetime]::MinValue
            if ($job.Updated -is [datetime]) {
                $updated = $job.Updated
            } elseif (-not [datetime]::TryParse("$($job.Updated)", [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref] $updated)) {
                continue
            }
            if ($updated -lt $cutoff -and $PSCmdlet.ShouldProcess($file.FullName, 'Remove stale job record')) {
                Remove-Item -LiteralPath $file.FullName -Force
                $removed++
            }
        }

        foreach ($tmp in Get-ChildItem -LiteralPath $dir -Filter '*.tmp' -File -ErrorAction SilentlyContinue) {
            if ($tmp.LastWriteTime -lt (Get-Date).AddDays(-1) -and $PSCmdlet.ShouldProcess($tmp.FullName, 'Remove stray temp file')) {
                Remove-Item -LiteralPath $tmp.FullName -Force
            }
        }
    } catch {
        Write-ArmLog -Level WARN -Message "Remove-ArmStaleJobs failed: $_" -Config $Config
    }
    return $removed
}
