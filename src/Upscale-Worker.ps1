param(
    [string] $ConfigPath,
    [switch] $Simulate,
    [switch] $Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'JobState.ps1')
. (Join-Path $PSScriptRoot 'Send-Notification.ps1')
. (Join-Path $PSScriptRoot 'Upscale-Video.ps1')
. (Join-Path $PSScriptRoot 'Move-ToNas.ps1')

<#
.SYNOPSIS
    Determine whether the current time falls inside the configured upscale
    active-hours window.

.DESCRIPTION
    $Config.UpscaleActiveHours is @('<start HH:mm>', '<end HH:mm>'). Since the
    window is meant for overnight processing it typically wraps midnight
    (e.g. '23:00' to '08:00'), so the window is in-range when
    now >= start OR now < end (rather than a simple start <= now <= end, which
    would always be false for an overnight span).

.PARAMETER Config
    Configuration hashtable (UpscaleActiveHours).

.OUTPUTS
    [bool]
#>
function Test-ArmActiveWindow {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $window = if ($Config.ContainsKey('UpscaleActiveHours')) { $Config.UpscaleActiveHours } else { $null }
    if (-not $window -or $window.Count -lt 2) {
        return $true
    }

    $now = Get-Date
    try {
        $start = [datetime]::ParseExact($window[0], 'HH:mm', $null)
        $end = [datetime]::ParseExact($window[1], 'HH:mm', $null)
    } catch {
        Write-ArmLog -Level WARN -Message "Invalid UpscaleActiveHours '$($window -join ', ')' (expected 'HH:mm'): $_; treating as always in-window" -Config $Config
        return $true
    }

    $nowTod = $now.TimeOfDay
    $startTod = $start.TimeOfDay
    $endTod = $end.TimeOfDay

    if ($startTod -le $endTod) {
        # Same-day window, e.g. 08:00 - 23:00
        return ($nowTod -ge $startTod -and $nowTod -lt $endTod)
    } else {
        # Wraps midnight, e.g. 23:00 - 08:00
        return ($nowTod -ge $startTod -or $nowTod -lt $endTod)
    }
}

<#
.SYNOPSIS
    Pick the Engine and InterlaceType a finished Invoke-Upscale reported, as job-record properties.

.DESCRIPTION
    Returns only the properties the result actually carries, so a result without them
    (older stub, failure) leaves the job record's existing values untouched.
#>
function Get-ArmUpscaleRunInfo {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        $Result
    )

    $info = @{}
    $names = $Result.PSObject.Properties.Name
    foreach ($key in @('Engine', 'InterlaceType')) {
        if ($names -contains $key -and $Result.$key) {
            $info[$key] = [string] $Result.$key
        }
    }
    return $info
}

<#
.SYNOPSIS
    Source frame height for the Jellyfin version label, or $null when unknown.

.DESCRIPTION
    Uses SourceHeight from the Invoke-Upscale result when it carries one,
    otherwise probes the source with Get-VideoSourceInfo (ffprobe via Invoke-ArmTool).
    Never throws.
#>
function Get-ArmUpscaleSourceHeight {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        $Result,

        [Parameter(Mandatory = $true)]
        [string] $SourceFile,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    try {
        $prop = $Result.PSObject.Properties['SourceHeight']
        if ($prop -and $prop.Value -and [int] $prop.Value -gt 0) {
            return [int] $prop.Value
        }
    } catch {
        Write-ArmLog -Level WARN -Message "Ignoring bad SourceHeight in upscale result: $_" -Config $Config
    }
    try {
        $info = Get-VideoSourceInfo -InputFile $SourceFile -Config $Config
        if ($info.Success -and $info.Height -and [int] $info.Height -gt 0) {
            return [int] $info.Height
        }
    } catch {
        Write-ArmLog -Level WARN -Message "Could not determine source height of $SourceFile : $_" -Config $Config
    }
    return $null
}

<#
.SYNOPSIS
    Why an upscale is not needed for a source file, or $null when it is.

.DESCRIPTION
    A source already at or above the upscale target height (UpscaleHeight, default 1080)
    gains nothing from the pipeline. Returns a reason string in that case. A failed
    probe returns $null so the normal path (and its own error handling) decides.
#>
function Get-ArmUpscaleSkipReason {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourceFile,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $target = 1080
    if ($Config.ContainsKey('UpscaleHeight') -and "$($Config.UpscaleHeight)" -match '^\d+$' -and [int] $Config.UpscaleHeight -gt 0) {
        $target = [int] $Config.UpscaleHeight
    }
    try {
        $info = Get-VideoSourceInfo -InputFile $SourceFile -Config $Config
        if ($info.Success -and $info.Height -and [int] $info.Height -ge $target) {
            return "source is already $([int] $info.Height)p (target $($target)p); no upscale needed"
        }
    } catch {
        Write-ArmLog -Level WARN -Message "Could not probe $SourceFile for the skip check: $_" -Config $Config
    }
    return $null
}

<#
.SYNOPSIS
    Process a single upscale queue file.

.DESCRIPTION
    Reads a queue JSON file ({Source;DestDir[;ContentType='Animation']}) and runs the
    upscale pipeline:
      - AutoUpscale = $false: runs Invoke-Upscale -SampleOnly, notifies with the
        sample path for review, and renames the queue file to '.awaiting-review'
        (the user renames it back to '.json' after approving, to be picked up on
        a later poll - see README).
      - AutoUpscale = $true: runs the full Invoke-Upscale, moves the result into
        DestDir, notifies, and deletes the queue file.
      - A source already at or above the target height (UpscaleHeight, default 1080) is
        not upscaled: the queue file becomes '.skipped' (SkipReason inside) and the job
        ends as Skipped with a Reason.
      - On failure (bad JSON, missing source, or Invoke-Upscale failure): renames
        the queue file to '.failed' and sends an Error notification.

    Square brackets in the upscaled output name ("[AI upscale 1080p]") are
    PowerShell wildcard metacharacters, so every file operation here on that path
    uses -LiteralPath to avoid silent glob-matching failures.

    Job state (JobState.ps1): the item's Upscale job is set to Sampling /
    Upscaling BEFORE Invoke-Upscale runs (so "queued" and "running" are
    distinguishable), then AwaitingReview (+SamplePath) / Complete / Failed.
    A queue file without a JobId (written before job tracking existed, or
    while StateDir was unavailable) gets a job created on first touch and the
    JobId persisted into the file. Job-state calls never throw, and persisting
    the JobId has its own try/catch, so bookkeeping can never fail an upscale.

.PARAMETER QueueFile
    Path to the *.json queue file to process.

.PARAMETER Config
    Configuration hashtable.
#>
function Invoke-ArmUpscaleQueueItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $QueueFile,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $jobId = $null
    try {
        $item = Get-Content -LiteralPath $QueueFile -Raw | ConvertFrom-Json
        $source = $item.Source
        $destDir = $item.DestDir

        if ($item.PSObject.Properties.Name -contains 'JobId' -and $item.JobId -and (Get-ArmJob -JobId $item.JobId -Config $Config)) {
            $jobId = [string] $item.JobId
        } else {
            $jobId = New-ArmJob -Kind Upscale -Properties @{
                State     = 'Queued'
                Title     = [System.IO.Path]::GetFileNameWithoutExtension($QueueFile)
                DestDir   = $destDir
                QueueFile = $QueueFile
            } -Config $Config
            if ($jobId) {
                try {
                    $item | Add-Member -MemberType NoteProperty -Name JobId -Value $jobId -Force
                    $item | ConvertTo-Json | Set-Content -LiteralPath $QueueFile -Encoding utf8
                } catch {
                    Write-ArmLog -Level WARN -Message "Could not persist JobId into $QueueFile : $_" -Config $Config
                }
            }
        }

        if (-not $source -or -not (Test-Path -LiteralPath $source)) {
            throw "Queue item source not found: $source"
        }

        $approved = $item.PSObject.Properties.Name -contains 'SampleGenerated' -and $item.SampleGenerated

        # Optional queue field; selects UpscaleAnimation vs UpscaleLiveAction. Anything
        # other than 'Animation' (including absent) means LiveAction.
        $contentType = 'LiveAction'
        if ($item.PSObject.Properties.Name -contains 'ContentType' -and $item.ContentType -eq 'Animation') {
            $contentType = 'Animation'
        }

        # Nothing to gain from upscaling a source that is already at the target height:
        # park the queue file as .skipped (with the reason inside) and finish the job.
        $skipReason = Get-ArmUpscaleSkipReason -SourceFile $source -Config $Config
        if ($skipReason) {
            $item | Add-Member -MemberType NoteProperty -Name SkipReason -Value $skipReason -Force
            $item | ConvertTo-Json | Set-Content -LiteralPath $QueueFile -Encoding utf8
            $skippedPath = [System.IO.Path]::ChangeExtension($QueueFile, '.skipped')
            Move-Item -LiteralPath $QueueFile -Destination $skippedPath -Force
            Write-ArmLog -Level INFO -Message "Upscale skipped for ${source}: $skipReason" -Config $Config
            $null = Update-ArmJob -JobId $jobId -Properties @{ State = 'Skipped'; Reason = $skipReason; QueueFile = $skippedPath; Error = $null } -Config $Config
            return
        }

        if (-not $Config.AutoUpscale -and -not $approved) {
            $null = Update-ArmJob -JobId $jobId -Properties @{ State = 'Sampling'; QueueFile = $QueueFile; Error = $null; ContentType = $contentType } -Config $Config
            $result = Invoke-Upscale -InputFile $source -OutputDir (Split-Path -Parent $QueueFile) -Config $Config -ContentType $contentType -SampleOnly

            if (-not $result.Success) {
                throw "Sample upscale failed: $($result.Error)"
            }

            Send-ArmNotification -Title 'Upscale sample ready' `
                -Message "Sample clip ready for review: $($result.OutputFile)" `
                -Level Info -Config $Config

            # Mark approval state in the item content (not just the filename) so that
            # renaming back to .json is distinguishable from a never-sampled item.
            $item | Add-Member -MemberType NoteProperty -Name SampleGenerated -Value $true -Force
            $item | ConvertTo-Json | Set-Content -LiteralPath $QueueFile -Encoding utf8

            $reviewPath = [System.IO.Path]::ChangeExtension($QueueFile, '.awaiting-review')
            Move-Item -LiteralPath $QueueFile -Destination $reviewPath -Force

            $reviewProps = @{
                State      = 'AwaitingReview'
                SamplePath = $result.OutputFile
                QueueFile  = $reviewPath
            }
            $reviewProps += Get-ArmUpscaleRunInfo -Result $result
            $null = Update-ArmJob -JobId $jobId -Properties $reviewProps -Config $Config
        } else {
            $null = Update-ArmJob -JobId $jobId -Properties @{ State = 'Upscaling'; QueueFile = $QueueFile; Error = $null; ContentType = $contentType } -Config $Config
            $result = Invoke-Upscale -InputFile $source -OutputDir $destDir -Config $Config -ContentType $contentType

            if (-not $result.Success) {
                throw "Upscale failed: $($result.Error)"
            }

            # Delete the queue file first: if that fails the item goes to .failed with its
            # source still under its original name (the renames below would orphan it).
            Remove-Item -LiteralPath $QueueFile -Force

            # Jellyfin: name both files '<Folder> - <label>.mkv' so they group as versions
            # of one movie and the upscale plays by default. Never fails the job.
            $finalOutput = [string] $result.OutputFile
            try {
                $sourceHeight = Get-ArmUpscaleSourceHeight -Result $result -SourceFile $source -Config $Config
                $named = Rename-ArmUpscaleVersions -FolderName (Split-Path -Leaf ([string] $destDir).TrimEnd('\', '/')) `
                    -UpscaledFile $finalOutput -SourceFile $source -SourceHeight $sourceHeight -Config $Config
                $finalOutput = [string] $named.OutputFile
            } catch {
                Write-ArmLog -Level WARN -Message "Could not apply Jellyfin version names in $destDir : $_" -Config $Config
            }

            Send-ArmNotification -Title 'Upscale complete' `
                -Message "Upscaled: $finalOutput" `
                -Level Info -Config $Config

            $completeProps = @{ State = 'Complete'; DestDir = $destDir; OutputFile = $finalOutput }
            $completeProps += Get-ArmUpscaleRunInfo -Result $result
            $null = Update-ArmJob -JobId $jobId -Properties $completeProps -Config $Config
        }
    } catch {
        $failure = "$_"
        Write-ArmLog -Level ERROR -Message "Upscale queue item failed for $QueueFile : $failure" -Config $Config

        Send-ArmNotification -Title 'Upscale failed' `
            -Message "Failed to process $QueueFile : $_" `
            -Level Error -Config $Config

        $failedPath = [System.IO.Path]::ChangeExtension($QueueFile, '.failed')
        try {
            Move-Item -LiteralPath $QueueFile -Destination $failedPath -Force -ErrorAction SilentlyContinue
        } catch {
            Write-ArmLog -Level WARN -Message "Could not rename queue file $QueueFile to .failed : $_" -Config $Config
        }

        $failedQueueFile = if (Test-Path -LiteralPath $failedPath) { $failedPath } else { $QueueFile }
        if ($jobId) {
            $null = Update-ArmJob -JobId $jobId -Properties @{ State = 'Failed'; Error = $failure; QueueFile = $failedQueueFile } -Config $Config
        } else {
            # Unparseable queue file: still surface it as a Failed job.
            $null = New-ArmJob -Kind Upscale -Properties @{
                State     = 'Failed'
                Title     = [System.IO.Path]::GetFileNameWithoutExtension($QueueFile)
                QueueFile = $failedQueueFile
                Error     = $failure
            } -Config $Config
        }
    }
}

<#
.SYNOPSIS
    Run one pass over the upscale queue directory.

.DESCRIPTION
    Scans $Config.UpscaleQueueDir for *.json files and processes each one via
    Invoke-ArmUpscaleQueueItem, but only when Test-ArmActiveWindow reports the
    current time is inside $Config.UpscaleActiveHours (an -Once invocation from
    the watcher/tests is always treated as in-window).

.PARAMETER Config
    Configuration hashtable.

.PARAMETER Once
    Skip the active-hours gate (used for single-pass test/manual runs).
#>
function Invoke-ArmUpscaleQueuePass {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Config,

        [switch] $Once
    )

    # Job-history retention runs every pass (cheap; never throws), including
    # outside active hours.
    $null = Remove-ArmStaleJobs -Config $Config

    if (-not $Once -and -not (Test-ArmActiveWindow -Config $Config)) {
        Write-ArmLog -Level INFO -Message 'Upscale worker: outside active hours, skipping pass' -Config $Config
        return
    }

    if (-not (Test-Path -LiteralPath $Config.UpscaleQueueDir)) {
        return
    }

    $queueFiles = Get-ChildItem -LiteralPath $Config.UpscaleQueueDir -Filter '*.json' -File -ErrorAction SilentlyContinue
    foreach ($queueFile in $queueFiles) {
        Invoke-ArmUpscaleQueueItem -QueueFile $queueFile.FullName -Config $Config
    }
}

<#
.SYNOPSIS
    Upscale-Worker entry point: polls the upscale queue directory and processes
    pending jobs.

.DESCRIPTION
    Entry point script (has top-level side effects; guarded so dot-sourcing this
    file for its helper functions, e.g. from tests, does not start the poll loop).
    Sets its own process priority to BelowNormal, then polls
    $Config.UpscaleQueueDir every 60 seconds for *.json files, processing each
    per SPEC.md within the configured active-hours window. -Once processes a
    single pass and exits (used by tests).

.PARAMETER ConfigPath
    Path to config.psd1. Defaults per Get-ArmConfig.

.PARAMETER Simulate
    Force Simulate mode (routes Invoke-ArmTool to tests/stubs/) regardless of config.

.PARAMETER Once
    Process a single queue pass then exit, instead of looping forever.

.EXAMPLE
    ./Upscale-Worker.ps1 -Simulate -Once
#>
function Start-UpscaleWorker {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Daemon entry point that polls/processes queue files; not an interactive state-changing cmdlet.')]
    param(
        [string] $ConfigPath,
        [switch] $Simulate,
        [switch] $Once
    )

    $config = Get-ArmConfig -Path $ConfigPath -Simulate:$Simulate

    try {
        $proc = Get-Process -Id $PID
        $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
    } catch {
        Write-ArmLog -Level WARN -Message "Could not set process priority: $_" -Config $config
    }

    if ($Once) {
        Invoke-ArmUpscaleQueuePass -Config $config -Once
        return
    }

    while ($true) {
        Invoke-ArmUpscaleQueuePass -Config $config
        Start-Sleep -Seconds 60
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-UpscaleWorker @PSBoundParameters
}
