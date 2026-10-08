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
        'JobState.ps1',
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
    True when the optical drive reports media loaded (Win32_CDROMDrive.MediaLoaded).

.DESCRIPTION
    Thin wrapper so tests can mock the media-state read. Three-state: $true
    (media loaded), $false (drive found, no media), $null (state unknown: CIM
    error, or the drive was not found). Callers must treat $null as "cannot
    tell", never as "empty".
#>
function Get-ArmDriveMediaLoaded {
    [CmdletBinding()]
    [OutputType([bool], [object])]
    param(
        [Parameter(Mandatory = $true)]
        [char] $DriveLetter
    )

    try {
        $drive = Get-CimInstance -ClassName Win32_CDROMDrive -Filter "Drive='$([char]::ToUpper($DriveLetter)):'" -ErrorAction Stop
        if (-not $drive -or $null -eq $drive.MediaLoaded) {
            return $null
        }
        return [bool] $drive.MediaLoaded
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
    Ask the Explorer shell to eject the drive (Shell.Application 'Eject' verb).

.DESCRIPTION
    Wrapper so tests never touch a real drive. The verb returns without
    throwing even when it does nothing (observed from the hidden wrm-watcher
    task, #41), so callers must verify with Wait-ArmEjected.
#>
function Invoke-ArmShellEject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [char] $DriveLetter
    )

    $shell = New-Object -ComObject Shell.Application
    $shell.NameSpace(17).ParseName("$DriveLetter`:").InvokeVerb('Eject')
}

<#
.SYNOPSIS
    Compile (once per process) the kernel32 P/Invoke helper used by the IOCTL eject.

.DESCRIPTION
    Wrm.NativeEject.Eject(devicePath) opens the device (e.g. \\.\F:) and issues
    FSCTL_LOCK_VOLUME / FSCTL_DISMOUNT_VOLUME (best effort),
    IOCTL_STORAGE_MEDIA_REMOVAL (allow) and IOCTL_STORAGE_EJECT_MEDIA. Returns 0
    on success, else the Win32 error code. No shell or desktop session needed.
#>
function Initialize-ArmNativeEject {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ('Wrm.NativeEject' -as [type]) {
        return $true
    }

    $source = @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Wrm {
    public static class NativeEject {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SafeFileHandle CreateFile(string fileName, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(SafeFileHandle device, uint code,
            byte[] inBuffer, uint inSize, IntPtr outBuffer, uint outSize, out uint returned, IntPtr overlapped);

        private const uint GENERIC_READ = 0x80000000;
        private const uint FILE_SHARE_READ_WRITE = 3;
        private const uint OPEN_EXISTING = 3;
        private const uint FSCTL_LOCK_VOLUME = 0x00090018;
        private const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;
        private const uint IOCTL_STORAGE_MEDIA_REMOVAL = 0x002D4804;
        private const uint IOCTL_STORAGE_EJECT_MEDIA = 0x002D4808;

        public static int Eject(string devicePath) {
            using (SafeFileHandle h = CreateFile(devicePath, GENERIC_READ, FILE_SHARE_READ_WRITE,
                       IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero)) {
                if (h.IsInvalid) {
                    int err = Marshal.GetLastWin32Error();
                    return err == 0 ? 1 : err;
                }
                uint ret;
                DeviceIoControl(h, FSCTL_LOCK_VOLUME, null, 0, IntPtr.Zero, 0, out ret, IntPtr.Zero);
                DeviceIoControl(h, FSCTL_DISMOUNT_VOLUME, null, 0, IntPtr.Zero, 0, out ret, IntPtr.Zero);
                DeviceIoControl(h, IOCTL_STORAGE_MEDIA_REMOVAL, new byte[] { 0 }, 1, IntPtr.Zero, 0, out ret, IntPtr.Zero);
                if (!DeviceIoControl(h, IOCTL_STORAGE_EJECT_MEDIA, null, 0, IntPtr.Zero, 0, out ret, IntPtr.Zero)) {
                    int err = Marshal.GetLastWin32Error();
                    return err == 0 ? 1 : err;
                }
                return 0;
            }
        }
    }
}
'@
    try {
        Add-Type -TypeDefinition $source -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
    Eject a drive with IOCTL_STORAGE_EJECT_MEDIA (shell-independent fallback).

.OUTPUTS
    [bool] $true when the ioctl was accepted (verify with Wait-ArmEjected).
#>
function Invoke-ArmIoctlEject {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [char] $DriveLetter,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    if (-not (Initialize-ArmNativeEject)) {
        Write-ArmLog -Level WARN -Message 'IOCTL eject unavailable: could not compile the native helper.' -Config $Config
        return $false
    }
    try {
        $err = [Wrm.NativeEject]::Eject("\\.\$([char]::ToUpper($DriveLetter)):")
    } catch {
        Write-ArmLog -Level WARN -Message "IOCTL eject of $DriveLetter`: threw: $_" -Config $Config
        return $false
    }
    if ($err -ne 0) {
        Write-ArmLog -Level WARN -Message "IOCTL eject of $DriveLetter`: failed (Win32 error $err)." -Config $Config
        return $false
    }
    return $true
}

<#
.SYNOPSIS
    Poll until the drive definitely reports no media, or the timeout elapses.

.OUTPUTS
    [bool] $true once the drive reports MediaLoaded = $false; $false if media is
    still loaded, or its state stayed unreadable ($null), after TimeoutSec.
#>
function Wait-ArmEjected {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [char] $DriveLetter,

        [int] $TimeoutSec = 10,

        [int] $PollMs = 500
    )

    $attempts = [Math]::Max(1, [int][Math]::Ceiling(($TimeoutSec * 1000) / [Math]::Max(1, $PollMs)))
    for ($i = 0; $i -le $attempts; $i++) {
        $loaded = Get-ArmDriveMediaLoaded -DriveLetter $DriveLetter
        if ($loaded -is [bool] -and -not $loaded) {
            return $true
        }
        if ($i -lt $attempts) {
            Start-Sleep -Milliseconds $PollMs
        }
    }
    return $false
}

<#
.SYNOPSIS
    Eject the disc in the given drive and verify that the media actually left.

.DESCRIPTION
    Gated on EjectWhenDone; under Simulate only logs that the physical eject is
    skipped. Otherwise: shell 'Eject' verb, then poll Win32_CDROMDrive for up to
    10 s. If media is still loaded (the verb silently does nothing from the
    hidden scheduled task, #41) falls back to IOCTL_STORAGE_EJECT_MEDIA and polls
    again. Logs INFO on success (naming the method used) and WARN on failure.
    Never throws; returns nothing.

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
        try {
            Invoke-ArmShellEject -DriveLetter $DriveLetter
        } catch {
            Write-ArmLog -Level WARN -Message "Shell eject of $DriveLetter`: threw: $_" -Config $Config
        }
        if (Wait-ArmEjected -DriveLetter $DriveLetter) {
            Write-ArmLog -Level INFO -Message "Ejected $DriveLetter`: (shell)" -Config $Config
            return
        }

        Write-ArmLog -Level WARN -Message "Media still loaded in $DriveLetter`: (or its state is unreadable) after the shell eject; trying IOCTL fallback." -Config $Config
        if ((Invoke-ArmIoctlEject -DriveLetter $DriveLetter -Config $Config) -and (Wait-ArmEjected -DriveLetter $DriveLetter)) {
            Write-ArmLog -Level INFO -Message "Ejected $DriveLetter`: (IOCTL fallback)" -Config $Config
            return
        }

        Write-ArmLog -Level WARN -Message "Failed to eject $DriveLetter`: media is still loaded (or its state is unreadable) after the shell and IOCTL attempts; eject not confirmed." -Config $Config
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

.PARAMETER ContentType
    'LiveAction' (default) or 'Animation'; selects the upscale engine in
    Upscale-Worker (UpscaleLiveAction vs UpscaleAnimation).

.PARAMETER Config
    Configuration hashtable (for UpscaleQueueDir and logging).

.DESCRIPTION
    Writes <UpscaleQueueDir>\<FolderName>.json as {Source;DestDir;JobId;ContentType}
    and creates the matching Upscale job record (State=Queued, ContentType).
    JobId is $null in the queue file when job state is unavailable;
    Upscale-Worker then creates the job on first touch.
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

        [ValidateSet('LiveAction', 'Animation')]
        [string] $ContentType = 'LiveAction',

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $queueDir = $Config.UpscaleQueueDir
    if (-not (Test-Path -Path $queueDir)) {
        $null = New-Item -ItemType Directory -Force -Path $queueDir
    }

    $safeName = ConvertTo-ArmSafeFileName -Name $FolderName
    $queuePath = Join-Path $queueDir "$safeName.json"

    $jobId = New-ArmJob -Kind Upscale -Properties @{
        State       = 'Queued'
        Title       = $FolderName
        DestDir     = $DestDir
        QueueFile   = $queuePath
        ContentType = $ContentType
    } -Config $Config

    $entry = [ordered]@{ Source = $MkvPath; DestDir = $DestDir; JobId = $jobId; ContentType = $ContentType }
    $entry | ConvertTo-Json | Set-Content -LiteralPath $queuePath -Encoding utf8

    Write-ArmLog -Level INFO -Message "Queued upscale job: $queuePath" -Config $Config
}

<#
.SYNOPSIS
    Dispatch handling for a Video disc: rip, resolve title, move to NAS, queue
    upscale (DVD only), eject, notify.

.PARAMETER JobId
    Optional Rip job ID (JobState.ps1); advanced through Moving -> Complete,
    or set to Failed with Error on any failure path.
#>
function Invoke-VideoDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [char] $DriveLetter,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config,

        [string] $JobId
    )

    $ripParams = @{ DriveLetter = $DriveLetter; Config = $Config }
    if ($JobId) {
        $ripParams.JobId = $JobId
    }
    $ripResult = Invoke-VideoRip @ripParams

    if (-not $ripResult.Success) {
        $null = Update-ArmJob -JobId $JobId -Properties @{ State = 'Failed'; Error = $ripResult.Error } -Config $Config
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
    $actualFolderName = Split-Path -Leaf $renamedDir

    $null = Update-ArmJob -JobId $JobId -Properties @{ State = 'Moving'; Title = $actualFolderName; StagingDir = $renamedDir } -Config $Config
    $extrasResult = Move-ArmExtrasToSubdir -Dir $renamedDir -Config $Config
    if (-not $extrasResult.Success) {
        Write-ArmLog -Level WARN -Message "Could not arrange extras subfolder: $($extrasResult.Error)" -Config $Config
    }
    # Jellyfin groups versions by file-name prefix = folder name (see Rename-ArmMainFeature).
    $renameResult = Rename-ArmMainFeature -Dir $renamedDir -Config $Config
    if (-not $renameResult.Success) {
        Write-ArmLog -Level WARN -Message "Could not rename main feature: $($renameResult.Error)" -Config $Config
    }

    $moveResult = Move-ToNas -SourceDir $renamedDir -DestRoot $Config.NasVideoPath -Config $Config

    if (-not $moveResult.Success) {
        $null = Update-ArmJob -JobId $JobId -Properties @{ State = 'Failed'; Error = "Move to NAS failed: $($moveResult.Error)" } -Config $Config
        Write-ArmLog -Level ERROR -Message "Move to NAS failed: $($moveResult.Error)" -Config $Config
        Send-ArmNotification -Title 'Move to NAS Failed' `
            -Message "Failed to move '$actualFolderName' to NAS: $($moveResult.Error). Staging preserved." `
            -Level Error -Config $Config
        return
    }

    if ($ripResult.DiscType -eq 'DVD' -and $Config.UpscaleDvds) {
        try {
            # Top level only: never pick something from extras/.
            $mainMkv = Get-ChildItem -LiteralPath $moveResult.DestDir -File -Filter '*.mkv' -ErrorAction SilentlyContinue |
                Sort-Object -Property Length -Descending | Select-Object -First 1
            if ($mainMkv) {
                $ctProp = if ($resolved) { $resolved.PSObject.Properties['ContentType'] } else { $null }
                $contentType = if ($ctProp -and $ctProp.Value -ieq 'Animation') { 'Animation' } else { 'LiveAction' }
                New-UpscaleQueueEntry -MkvPath $mainMkv.FullName -DestDir $moveResult.DestDir `
                    -FolderName $actualFolderName -ContentType $contentType -Config $Config
            } else {
                Write-ArmLog -Level WARN -Message "UpscaleDvds set but no top-level .mkv found in $($moveResult.DestDir)" -Config $Config
            }
        } catch {
            Write-ArmLog -Level WARN -Message "Failed to queue upscale job: $_" -Config $Config
        }
    }

    $null = Update-ArmJob -JobId $JobId -Properties @{ State = 'Complete'; DestDir = $moveResult.DestDir } -Config $Config

    Invoke-DiscEject -DriveLetter $DriveLetter -Config $Config
    Send-ArmNotification -Title 'Rip Complete' `
        -Message "$actualFolderName ripped and moved to NAS." -Level Info -Config $Config
}

<#
.SYNOPSIS
    Dispatch handling for an Audio CD: rip, move to NAS, eject, notify.

.PARAMETER JobId
    Optional Rip job ID (JobState.ps1); status only (Ripping/Moving/Complete/Failed).
#>
function Invoke-AudioDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [char] $DriveLetter,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config,

        [string] $JobId
    )

    $ripParams = @{ DriveLetter = $DriveLetter; Config = $Config }
    if ($JobId) {
        $ripParams.JobId = $JobId
    }
    $ripResult = Invoke-AudioRip @ripParams

    if (-not $ripResult.Success) {
        $null = Update-ArmJob -JobId $JobId -Properties @{ State = 'Failed'; Error = $ripResult.Error } -Config $Config
        Write-ArmLog -Level ERROR -Message "Audio rip failed: $($ripResult.Error)" -Config $Config
        Send-ArmNotification -Title 'Audio Rip Failed' `
            -Message "Rip failed: $($ripResult.Error). Staging preserved." -Level Error -Config $Config
        return
    }

    $null = Update-ArmJob -JobId $JobId -Properties @{
        State      = 'Moving'
        Title      = "$($ripResult.Artist) - $($ripResult.Album)"
        StagingDir = $ripResult.OutputDir
    } -Config $Config

    $moveResult = Move-ToNas -SourceDir $ripResult.OutputDir -DestRoot $Config.NasMusicPath -Config $Config

    if (-not $moveResult.Success) {
        $null = Update-ArmJob -JobId $JobId -Properties @{ State = 'Failed'; Error = "Move to NAS failed: $($moveResult.Error)" } -Config $Config
        Write-ArmLog -Level ERROR -Message "Move to NAS failed: $($moveResult.Error)" -Config $Config
        Send-ArmNotification -Title 'Move to NAS Failed' `
            -Message "Failed to move '$($ripResult.Artist) - $($ripResult.Album)' to NAS: $($moveResult.Error). Staging preserved." `
            -Level Error -Config $Config
        return
    }

    $null = Update-ArmJob -JobId $JobId -Properties @{ State = 'Complete'; DestDir = $moveResult.DestDir } -Config $Config

    Invoke-DiscEject -DriveLetter $DriveLetter -Config $Config
    Send-ArmNotification -Title 'Rip Complete' `
        -Message "$($ripResult.Artist) - $($ripResult.Album) ripped and moved to NAS." -Level Info -Config $Config
}

<#
.SYNOPSIS
    Open the web UI dashboard in the default browser when a disc is detected.

.DESCRIPTION
    Skipped when -Simulate, when WebUiEnabled is $false, or when WebUiOpenOnDisc
    is $false (default $true). Never throws: failing to open a browser must not
    affect the rip. The watcher runs in the logged-in user's session, so the
    page appears on their desktop.
#>
function Open-ArmWebUi {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    if ($Config.ContainsKey('Simulate') -and $Config.Simulate) { return $false }
    if ($Config.ContainsKey('WebUiEnabled') -and -not $Config.WebUiEnabled) { return $false }
    if ($Config.ContainsKey('WebUiOpenOnDisc') -and -not $Config.WebUiOpenOnDisc) { return $false }

    $port = if ($Config.ContainsKey('WebUiPort') -and $Config.WebUiPort) { [int]$Config.WebUiPort } else { 8765 }
    # 'localhost' exactly: HTTP.sys rejects 127.0.0.1 with 400 Invalid Hostname.
    $url = "http://localhost:$port/"
    try {
        Start-Process -FilePath $url -ErrorAction Stop
        Write-ArmLog -Level INFO -Message "Opened web UI at $url" -Config $Config
        return $true
    } catch {
        Write-ArmLog -Level WARN -Message "Could not open web UI at ${url}: $_" -Config $Config
        return $false
    }
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

    Video and AudioCD discs get a Rip job record (JobState.ps1, State=Detected)
    that the dispatch functions advance; an unhandled exception marks it Failed.

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

    $jobId = $null
    try {
        if ($DiscType -in @('Video', 'AudioCD')) {
            $jobId = New-ArmJob -Kind Rip -Properties @{ State = 'Detected'; Drive = "$DriveLetter`:"; DiscType = $DiscType } -Config $Config
            $null = Open-ArmWebUi -Config $Config
        }

        switch ($DiscType) {
            'Video' {
                Write-ArmLog -Level INFO -Message "Video disc detected on $DriveLetter`:" -Config $Config
                Invoke-VideoDispatch -DriveLetter $DriveLetter -Config $Config -JobId $jobId
            }
            'AudioCD' {
                Write-ArmLog -Level INFO -Message "Audio CD detected on $DriveLetter`:" -Config $Config
                Invoke-AudioDispatch -DriveLetter $DriveLetter -Config $Config -JobId $jobId
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
        $null = Update-ArmJob -JobId $jobId -Properties @{ State = 'Failed'; Error = "$_" } -Config $Config
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

.OUTPUTS
    [bool] $true if the mutex was acquired and dispatch was attempted; $false if
    another rip was already in progress and dispatch was skipped.
#>
function Invoke-DiscMutexDispatch {
    [CmdletBinding()]
    [OutputType([bool])]
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
            return $false
        }
        Invoke-DiscDispatch -DriveLetter $DriveLetter -DiscType $DiscType -Config $Config
        return $true
    } finally {
        if ($acquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

<#
.SYNOPSIS
    Advance the disc-watcher's last-seen-type state for a drive, dispatching
    through the single-flight mutex when the disc type has changed.

.DESCRIPTION
    Centralizes the logic shared by the WMI-event branch and the poll-fallback
    branch of Start-DiscWatcherLoop. When the observed type differs from the
    last-known state for the drive, attempts a dispatch via
    Invoke-DiscMutexDispatch. If the mutex was held elsewhere (another rip in
    progress), the dispatch is skipped and $LastState is deliberately left
    unchanged so the same disc is retried on the next iteration instead of
    being silently dropped. In every other case (type unchanged, or type is
    'None', or dispatch was actually attempted) $LastState is advanced to the
    observed type.

.PARAMETER DriveLetter
    Drive letter being observed.

.PARAMETER Type
    Disc type currently observed for the drive (as returned by Get-DiscType).

.PARAMETER LastState
    Hashtable of drive letter -> last-observed disc type, mutated in place.

.PARAMETER Config
    Configuration hashtable.
#>
function Update-ArmDiscWatcherState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [char] $DriveLetter,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Video', 'AudioCD', 'Data', 'None')]
        [string] $Type,

        [Parameter(Mandatory = $true)]
        [hashtable] $LastState,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    if ($Type -ne 'None' -and $LastState[$DriveLetter] -ne $Type) {
        $dispatched = Invoke-DiscMutexDispatch -DriveLetter $DriveLetter -DiscType $Type -Config $Config
        if (-not $dispatched) {
            # Mutex contention: leave $LastState as-is so this disc is retried
            # on the next iteration instead of being dropped forever.
            return
        }
    }

    $LastState[$DriveLetter] = $Type
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
            $driveHandledByEvent = $null
            if ($evt) {
                Remove-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
                $driveName = $evt.SourceEventArgs.NewEvent.DriveName
                if ($driveName) {
                    $driveLetter = [char] ($driveName.ToString().TrimEnd(':'))
                    $type = Get-DiscType -DriveLetter $driveLetter
                    Update-ArmDiscWatcherState -DriveLetter $driveLetter -Type $type -LastState $lastState -Config $Config
                    $driveHandledByEvent = $driveLetter
                }
            }

            foreach ($drive in Get-OpticalDriveLetters) {
                if ($drive -eq $driveHandledByEvent) {
                    continue
                }
                $type = Get-DiscType -DriveLetter $drive
                Update-ArmDiscWatcherState -DriveLetter $drive -Type $type -LastState $lastState -Config $Config
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
