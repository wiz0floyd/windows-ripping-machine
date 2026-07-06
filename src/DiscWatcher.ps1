[CmdletBinding()]
param(
    [string] $ConfigPath,
    [switch] $Simulate,
    [switch] $Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source sibling modules (function libraries only; no top-level side effects).
$script:ArmModuleRoot = $PSScriptRoot
foreach ($module in @(
        'Common.ps1',
        'Rip-VideoDisc.ps1',
        'Rip-AudioCd.ps1',
        'Resolve-Title.ps1',
        'Move-ToNas.ps1',
        'Send-Notification.ps1'
    )) {
    $modulePath = Join-Path $script:ArmModuleRoot $module
    if (Test-Path -Path $modulePath) {
        . $modulePath
    } else {
        Write-Warning "DiscWatcher: sibling module not found (will fail at dispatch time if invoked): $modulePath"
    }
}

<#
.SYNOPSIS
    Environment variable used by -Simulate mode to fake the currently loaded disc.

.DESCRIPTION
    When $Config.Simulate is $true, DiscWatcher does not query real WMI/CIM state.
    Instead it reads WRM_SIM_DISC, one of 'Video', 'AudioCD', 'Data', 'None'
    (defaults to 'None' if unset/unrecognized). This lets tests drive the full
    dispatch path deterministically with -Once.
#>
$script:SimDiscEnvVar = 'WRM_SIM_DISC'
# 'D' matches the drive letter baked into tests/fixtures/makemkvcon-info.txt
# (the DRV: line's "D:" field), so Invoke-VideoRip's disc-index lookup resolves
# in simulate mode without a real optical drive.
$script:SimDriveLetter = [char] 'D'
$script:MutexName = 'Global\wrm-rip'

<#
.SYNOPSIS
    Enumerate drive letters of attached optical drives.

.OUTPUTS
    [char[]] Drive letters (e.g. 'D', 'E').
#>
function Get-OpticalDriveLetters {
    [CmdletBinding()]
    [OutputType([char[]])]
    param()

    try {
        $drives = Get-CimInstance -ClassName Win32_CDROMDrive -ErrorAction SilentlyContinue
        return @($drives | ForEach-Object { [char] ($_.Drive.TrimEnd(':')) })
    } catch {
        Write-Warning "Get-OpticalDriveLetters: failed to enumerate optical drives: $_"
        return @()
    }
}

<#
.SYNOPSIS
    Determine the drive letter and disc type of the disc that should be processed.

.DESCRIPTION
    In simulate mode, reads the WRM_SIM_DISC environment variable instead of
    querying real hardware, and reports a fixed placeholder drive letter ('D',
    matching the fixture data in tests/fixtures/makemkvcon-info.txt).
    Otherwise enumerates real optical drives via Get-OpticalDriveLetters and
    Get-DiscType, returning the first drive with media loaded.

.PARAMETER Config
    Configuration hashtable (used to check Simulate).

.OUTPUTS
    [pscustomobject] @{ DriveLetter; DiscType }
#>
function Resolve-CurrentDisc {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    if ($Config.Simulate) {
        $simType = [System.Environment]::GetEnvironmentVariable($script:SimDiscEnvVar)
        if ($simType -notin @('Video', 'AudioCD', 'Data', 'None')) {
            $simType = 'None'
        }
        return [pscustomobject]@{
            DriveLetter = $script:SimDriveLetter
            DiscType    = $simType
        }
    }

    foreach ($drive in Get-OpticalDriveLetters) {
        $type = Get-DiscType -DriveLetter $drive
        if ($type -ne 'None') {
            return [pscustomobject]@{ DriveLetter = $drive; DiscType = $type }
        }
    }

    return [pscustomobject]@{ DriveLetter = $null; DiscType = 'None' }
}

<#
.SYNOPSIS
    Eject the disc in the given drive via the Shell.Application COM object.

.PARAMETER DriveLetter
    Drive letter to eject.

.PARAMETER Config
    Configuration hashtable (for logging; also gates on EjectWhenDone).
#>
function Invoke-DiscEject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [char] $DriveLetter,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    if (-not $Config.EjectWhenDone) {
        return
    }

    if ($Config.Simulate) {
        Write-ArmLog -Level INFO -Message "Simulate: skipping physical eject of $DriveLetter`:" -Config $Config
        return
    }

    try {
        $shell = New-Object -ComObject Shell.Application
        $shell.NameSpace(17).ParseName("$DriveLetter`:").InvokeVerb('Eject')
    } catch {
        Write-ArmLog -Level WARN -Message "Failed to eject drive $DriveLetter`: $_" -Config $Config
    }
}

<#
.SYNOPSIS
    Write an upscale queue entry for a ripped DVD.

.PARAMETER MkvPath
    Full path to the main .mkv file to upscale.

.PARAMETER DestDir
    Destination directory (on the NAS) the upscaled output should land alongside.

.PARAMETER FolderName
    Base name used for the queue file (sanitized for filesystem use).

.PARAMETER Config
    Configuration hashtable (for UpscaleQueueDir and logging).
#>
function New-UpscaleQueueEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MkvPath,

        [Parameter(Mandatory = $true)]
        [string] $DestDir,

        [Parameter(Mandatory = $true)]
        [string] $FolderName,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $queueDir = $Config.UpscaleQueueDir
    if (-not (Test-Path -Path $queueDir)) {
        $null = New-Item -ItemType Directory -Force -Path $queueDir
    }

    $safeName = ($FolderName -replace '[\\/:*?"<>|]', '_')
    $queuePath = Join-Path $queueDir "$safeName.json"

    $entry = @{ Source = $MkvPath; DestDir = $DestDir }
    $entry | ConvertTo-Json | Set-Content -Path $queuePath -Encoding utf8

    Write-ArmLog -Level INFO -Message "Queued upscale job: $queuePath" -Config $Config
}

<#
.SYNOPSIS
    Dispatch handling for a Video disc: rip, resolve title, move to NAS, queue
    upscale (DVD only), eject, notify.
#>
function Invoke-VideoDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [char] $DriveLetter,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $ripResult = Invoke-VideoRip -DriveLetter $DriveLetter -Config $Config

    if (-not $ripResult.Success) {
        if ($ripResult.Error -eq 'MAKEMKV_KEY_EXPIRED') {
            Write-ArmLog -Level ERROR -Message 'MakeMKV registration key expired or missing.' -Config $Config
            Send-ArmNotification -Title 'MakeMKV Key Expired' `
                -Message 'MakeMKV registration key has expired or is invalid. Rip cannot continue; staging preserved.' `
                -Level Error -Config $Config
        } else {
            Write-ArmLog -Level ERROR -Message "Video rip failed: $($ripResult.Error)" -Config $Config
            Send-ArmNotification -Title 'Video Rip Failed' `
                -Message "Rip failed: $($ripResult.Error). Staging preserved." -Level Error -Config $Config
        }
        return
    }

    $resolved = Resolve-TitleOverride -OutputDir $ripResult.OutputDir -FallbackResolved $ripResult.Resolved -Config $Config

    $renamedDir = $ripResult.OutputDir
    $parentDir = Split-Path -Parent $ripResult.OutputDir
    $targetDir = Join-Path $parentDir $resolved.FolderName
    try {
        if ($targetDir -ne $ripResult.OutputDir) {
            Rename-Item -LiteralPath $ripResult.OutputDir -NewName $resolved.FolderName -Force
            $renamedDir = $targetDir
        }
    } catch {
        Write-ArmLog -Level WARN -Message "Failed to rename staging dir to '$($resolved.FolderName)': $_" -Config $Config
    }

    $moveResult = Move-ToNas -SourceDir $renamedDir -DestRoot $Config.NasVideoPath -Config $Config

    if (-not $moveResult.Success) {
        Write-ArmLog -Level ERROR -Message "Move to NAS failed: $($moveResult.Error)" -Config $Config
        Send-ArmNotification -Title 'Move to NAS Failed' `
            -Message "Failed to move '$($resolved.FolderName)' to NAS: $($moveResult.Error). Staging preserved." `
            -Level Error -Config $Config
        return
    }

    if ($ripResult.DiscType -eq 'DVD' -and $Config.UpscaleDvds) {
        try {
            $mainMkv = Get-ChildItem -Path $moveResult.DestDir -Recurse -Filter '*.mkv' -ErrorAction SilentlyContinue |
                Sort-Object -Property Length -Descending | Select-Object -First 1
            if ($mainMkv) {
                New-UpscaleQueueEntry -MkvPath $mainMkv.FullName -DestDir $moveResult.DestDir `
                    -FolderName $resolved.FolderName -Config $Config
            } else {
                Write-ArmLog -Level WARN -Message "UpscaleDvds set but no .mkv found under $($moveResult.DestDir)" -Config $Config
            }
        } catch {
            Write-ArmLog -Level WARN -Message "Failed to queue upscale job: $_" -Config $Config
        }
    }

    Invoke-DiscEject -DriveLetter $DriveLetter -Config $Config
    Send-ArmNotification -Title 'Rip Complete' `
        -Message "$($resolved.FolderName) ripped and moved to NAS." -Level Info -Config $Config
}

<#
.SYNOPSIS
    Dispatch handling for an Audio CD: rip, move to NAS, eject, notify.
#>
function Invoke-AudioDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [char] $DriveLetter,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $ripResult = Invoke-AudioRip -DriveLetter $DriveLetter -Config $Config

    if (-not $ripResult.Success) {
        Write-ArmLog -Level ERROR -Message "Audio rip failed: $($ripResult.Error)" -Config $Config
        Send-ArmNotification -Title 'Audio Rip Failed' `
            -Message "Rip failed: $($ripResult.Error). Staging preserved." -Level Error -Config $Config
        return
    }

    $moveResult = Move-ToNas -SourceDir $ripResult.OutputDir -DestRoot $Config.NasMusicPath -Config $Config

    if (-not $moveResult.Success) {
        Write-ArmLog -Level ERROR -Message "Move to NAS failed: $($moveResult.Error)" -Config $Config
        Send-ArmNotification -Title 'Move to NAS Failed' `
            -Message "Failed to move '$($ripResult.Artist) - $($ripResult.Album)' to NAS: $($moveResult.Error). Staging preserved." `
            -Level Error -Config $Config
        return
    }

    Invoke-DiscEject -DriveLetter $DriveLetter -Config $Config
    Send-ArmNotification -Title 'Rip Complete' `
        -Message "$($ripResult.Artist) - $($ripResult.Album) ripped and moved to NAS." -Level Info -Config $Config
}

<#
.SYNOPSIS
    Route a detected disc to the appropriate rip/move/eject/notify pipeline.

.DESCRIPTION
    Video -> Invoke-VideoRip -> Resolve-Title -> rename staging dir -> Move-ToNas
            (NasVideoPath) -> queue upscale (DVD + UpscaleDvds) -> eject -> notify.
    AudioCD -> Invoke-AudioRip -> Move-ToNas (NasMusicPath) -> eject -> notify.
    Data -> WARN log + notify, no further action.
    None -> no-op.

    Any unexpected exception during dispatch is caught, logged as ERROR, and
    reported via Send-ArmNotification -Level Error; staging is always preserved
    on failure (no destructive cleanup happens on an error path).

.PARAMETER DriveLetter
    Drive letter of the disc to process.

.PARAMETER DiscType
    One of 'Video', 'AudioCD', 'Data', 'None' (as returned by Get-DiscType /
    Resolve-CurrentDisc).

.PARAMETER Config
    Configuration hashtable.
#>
function Invoke-DiscDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [char] $DriveLetter,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Video', 'AudioCD', 'Data', 'None')]
        [string] $DiscType,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    try {
        switch ($DiscType) {
            'Video' {
                Write-ArmLog -Level INFO -Message "Video disc detected on $DriveLetter`:" -Config $Config
                Invoke-VideoDispatch -DriveLetter $DriveLetter -Config $Config
            }
            'AudioCD' {
                Write-ArmLog -Level INFO -Message "Audio CD detected on $DriveLetter`:" -Config $Config
                Invoke-AudioDispatch -DriveLetter $DriveLetter -Config $Config
            }
            'Data' {
                Write-ArmLog -Level WARN -Message "Data disc detected on $DriveLetter`: (no action taken)" -Config $Config
                Send-ArmNotification -Title 'Data Disc Detected' `
                    -Message "A data disc was detected on $DriveLetter`:. No action was taken." `
                    -Level Info -Config $Config
            }
            'None' {
                # Nothing loaded; nothing to do.
            }
        }
    } catch {
        Write-ArmLog -Level ERROR -Message "Unhandled error dispatching disc on $DriveLetter`: $_" -Config $Config
        try {
            Send-ArmNotification -Title 'wrm Error' `
                -Message "Unhandled error processing disc on $DriveLetter`: $_. Staging preserved." `
                -Level Error -Config $Config
        } catch {
            # Notification itself must never take down the watcher.
        }
    }
}

<#
.SYNOPSIS
    Single-flight wrapper around Invoke-DiscDispatch using a named mutex.

.DESCRIPTION
    Acquires the 'wrm-rip' named mutex without blocking; if a rip is already
    in progress (mutex held elsewhere), logs a WARN and skips this dispatch.

.PARAMETER DriveLetter
    Drive letter of the disc to process.

.PARAMETER DiscType
    Disc type as returned by Resolve-CurrentDisc / Get-DiscType.

.PARAMETER Config
    Configuration hashtable.
#>
function Invoke-DiscMutexDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [char] $DriveLetter,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Video', 'AudioCD', 'Data', 'None')]
        [string] $DiscType,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(0)
        if (-not $acquired) {
            Write-ArmLog -Level WARN -Message 'Another rip is already in progress (mutex held); skipping.' -Config $Config
            return
        }
        Invoke-DiscDispatch -DriveLetter $DriveLetter -DiscType $DiscType -Config $Config
    } finally {
        if ($acquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

<#
.SYNOPSIS
    Run the event-driven watch loop: WMI volume-change events plus a 30s poll
    fallback, dispatching newly-loaded discs through the single-flight mutex.

.DESCRIPTION
    Registers a Win32_VolumeChangeEvent (EventType 2, media arrival) CIM
    indication event, then loops waiting on that event with a 30-second timeout;
    every iteration also polls Get-DiscType across all optical drives so a disc
    swap is caught even if the WMI event is missed or unavailable. Runs until
    the process is stopped (Ctrl+C / service stop).

.PARAMETER Config
    Configuration hashtable.
#>
function Start-DiscWatcherLoop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    Write-ArmLog -Level INFO -Message 'DiscWatcher loop starting.' -Config $Config

    $sourceId = 'wrm-volchange'
    $registered = $false
    try {
        $query = 'SELECT * FROM Win32_VolumeChangeEvent WHERE EventType = 2'
        Register-CimIndicationEvent -Query $query -SourceIdentifier $sourceId -ErrorAction Stop | Out-Null
        $registered = $true
    } catch {
        Write-ArmLog -Level WARN -Message "Failed to register WMI volume-change event; relying on poll fallback: $_" -Config $Config
    }

    $lastState = @{}
    try {
        while ($true) {
            $evt = Wait-Event -SourceIdentifier $sourceId -Timeout 30 -ErrorAction SilentlyContinue
            if ($evt) {
                Remove-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
                $driveName = $evt.SourceEventArgs.NewEvent.DriveName
                if ($driveName) {
                    $driveLetter = [char] ($driveName.ToString().TrimEnd(':'))
                    $type = Get-DiscType -DriveLetter $driveLetter
                    if ($type -ne 'None' -and $lastState[$driveLetter] -ne $type) {
                        Invoke-DiscMutexDispatch -DriveLetter $driveLetter -DiscType $type -Config $Config
                    }
                    $lastState[$driveLetter] = $type
                }
            }

            foreach ($drive in Get-OpticalDriveLetters) {
                $type = Get-DiscType -DriveLetter $drive
                if ($type -ne 'None' -and $lastState[$drive] -ne $type) {
                    Invoke-DiscMutexDispatch -DriveLetter $drive -DiscType $type -Config $Config
                }
                $lastState[$drive] = $type
            }
        }
    } finally {
        if ($registered) {
            Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
        }
    }
}

# --- Thin entry point --------------------------------------------------------
# Guarded so the file can be dot-sourced by tests (functions only) without
# starting the watcher loop or touching real hardware/config.
if ($MyInvocation.InvocationName -ne '.') {
    $armConfig = Get-ArmConfig -Path $ConfigPath
    if ($Simulate) {
        $armConfig.Simulate = $true
    }

    if ($Once) {
        $disc = Resolve-CurrentDisc -Config $armConfig
        if ($disc.DiscType -ne 'None') {
            Invoke-DiscMutexDispatch -DriveLetter $disc.DriveLetter -DiscType $disc.DiscType -Config $armConfig
        } else {
            Write-ArmLog -Level INFO -Message 'No disc detected (-Once); exiting.' -Config $armConfig
        }
    } else {
        Start-DiscWatcherLoop -Config $armConfig
    }
}
