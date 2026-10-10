<#
.SYNOPSIS
    wrm - command-line front end for Windows Ripping Machine library maintenance.

.DESCRIPTION
    Subcommands:
      wrm repair  [-Path <movies root>] [-Since <date>] [-Until <date>] [-RemoveOrphans] [-WhatIf]
          Move extras to extras\ and name files so Jellyfin shows the original and the
          upscale as versions of one movie; -RemoveOrphans also deletes the stale Jellyfin
          sidecars (.nfo, posters, .trickplay) left under the old names (tools\Repair-ArmJellyfinNames.ps1).
      wrm upscale <movie folder or movies root>... [-ContentType LiveAction|Animation] [-Force] [-WhatIf]
          Queue upscales of existing DVD rips (main feature under 720 lines high). Skips
          folders that already have an upscale or a queue entry.
      wrm restart [-Force] [-WhatIf]
          Restart the wrm-watcher, wrm-upscaler and wrm-webui scheduled tasks so they load
          the current code. Refuses while a rip or upscale is running unless -Force.
      wrm install-cli
          Add the repo's bin\ folder (wrm.cmd) to your user PATH.

    -Path defaults to NasVideoPath from config.psd1. Run `wrm <command> -WhatIf` first.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('repair', 'upscale', 'restart', 'install-cli', 'help')]
    [string] $Command = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]] $Folder,

    [string] $Path,
    [string] $ConfigPath,
    [Nullable[datetime]] $Since,
    [Nullable[datetime]] $Until,
    [ValidateSet('LiveAction', 'Animation')]
    [string] $ContentType,
    [switch] $Force,
    [switch] $RemoveOrphans,
    [switch] $Simulate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# DiscWatcher.ps1 declares its own -ConfigPath/-Simulate, which dot-sourcing would overwrite here.
$wrmConfigPath = $ConfigPath
$wrmSimulate = $Simulate.IsPresent
$script:WrmRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'JobState.ps1')
. (Join-Path $PSScriptRoot 'Upscale-Video.ps1')
. (Join-Path $PSScriptRoot 'Move-ToNas.ps1')
. (Join-Path $PSScriptRoot 'DiscWatcher.ps1')
$ConfigPath = $wrmConfigPath
$Simulate = [switch] $wrmSimulate

<#
.SYNOPSIS
    Queue upscales for existing DVD rips in movie folders.

.PARAMETER MovieDir
    Movie folders (one movie each; 'extras' ignored).

.PARAMETER ContentType
    Overrides the ContentType in the folder's metadata.json (default LiveAction).

.OUTPUTS
    [pscustomobject[]] Folder, File, Action (Queued | WouldQueue | Skipped), Reason.
#>
function Add-ArmUpscaleQueueFromLibrary {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)] [string[]] $MovieDir,
        [Parameter(Mandatory = $true)] [hashtable] $Config,
        [string] $ContentType,
        [switch] $Force
    )

    $row = { param($f, $file, $a, $why) [pscustomobject]@{ Folder = $f; File = $file; Action = $a; Reason = $why } }
    $queueDir = [string] $Config.UpscaleQueueDir

    foreach ($dir in $MovieDir) {
        $name = Split-Path -Leaf ($dir.TrimEnd('\', '/'))
        $mkvs = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.mkv' | Sort-Object Length -Descending)
        if ($mkvs.Count -eq 0) { continue }
        # An upscale is a '[AI upscale 1080p]' file or a '- <H>p' version with H >= 720.
        $hasUpscale = @($mkvs | Where-Object {
                $_.Name -match '\[AI upscale \d+p\]\.mkv$' -or ($_.BaseName -match '- (\d+)p$' -and [int] $Matches[1] -ge 720)
            }).Count -gt 0
        if ($hasUpscale) {
            if (-not $Force) { & $row $name $null 'Skipped' 'already has an upscale'; continue }
        }
        $main = $mkvs[0]
        $queueFile = Join-Path $queueDir "$(ConvertTo-ArmSafeFileName -Name $name)"
        if ((Test-Path -LiteralPath "$queueFile.json") -or (Test-Path -LiteralPath "$queueFile.awaiting-review") -or (Test-Path -LiteralPath "$queueFile.failed") -or (Test-Path -LiteralPath "$queueFile.skipped")) {
            & $row $name $main.Name 'Skipped' 'already in the upscale queue'; continue
        }
        $info = Get-VideoSourceInfo -InputFile $main.FullName -Config $Config
        if (-not $info.Success -or -not $info.Height) { & $row $name $main.Name 'Skipped' "could not probe: $($info.Error)"; continue }
        if ([int] $info.Height -ge 720 -and -not $Force) { & $row $name $main.Name 'Skipped' "not DVD resolution ($($info.Height)p)"; continue }

        $ct = $ContentType
        if (-not $ct) {
            $ct = 'LiveAction'
            $meta = Join-Path $dir 'metadata.json'
            if (Test-Path -LiteralPath $meta) {
                try { if ((Get-Content -LiteralPath $meta -Raw | ConvertFrom-Json).ContentType -ieq 'Animation') { $ct = 'Animation' } } catch { $null = $_ }
            }
        }
        if ($PSCmdlet.ShouldProcess($main.FullName, "Queue $ct upscale")) {
            New-UpscaleQueueEntry -MkvPath $main.FullName -DestDir $dir -FolderName $name -ContentType $ct -Config $Config
            & $row $name $main.Name 'Queued' $ct
        } else {
            & $row $name $main.Name 'WouldQueue' $ct
        }
    }
}

# Tool processes that mean a rip or upscale is in flight (makemkvcon64 included by the regex).
function Get-WrmBusyProcess {
    [CmdletBinding()]
    param()
    @(Get-Process | Where-Object { $_.Name -match '^(makemkvcon|freaccmd|robocopy|ffmpeg|video2x)' })
}

<#
.SYNOPSIS
    Stop and start the wrm scheduled tasks so they load the current code.

.DESCRIPTION
    Refuses while a rip/upscale tool is running (restarting kills it) unless -Force.
    Task names match Get-ArmScheduledTaskList in setup.ps1.

.OUTPUTS
    [pscustomobject[]] TaskName, Action (Restarted | WouldRestart | NotRegistered | Failed), Detail.
#>
function Restart-WrmTask {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([switch] $Force)

    $busy = @(Get-WrmBusyProcess)
    if ($busy.Count -gt 0 -and -not $Force) {
        $names = ($busy | ForEach-Object { "$($_.Name) ($($_.Id))" }) -join ', '
        throw "A rip or upscale is running: $names. Restarting would kill it; wait or re-run with -Force."
    }

    foreach ($name in 'wrm-watcher', 'wrm-upscaler', 'wrm-webui') {
        $row = { param($a, $d) [pscustomobject]@{ TaskName = $name; Action = $a; Detail = $d } }
        if (-not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) {
            & $row 'NotRegistered' 'run setup.ps1'; continue
        }
        if (-not $PSCmdlet.ShouldProcess($name, 'Restart scheduled task')) { & $row 'WouldRestart' $null; continue }
        try {
            Stop-ScheduledTask -TaskName $name -ErrorAction Stop
            Start-ScheduledTask -TaskName $name -ErrorAction Stop
            & $row 'Restarted' $null
        } catch {
            & $row 'Failed' "$($_.Exception.Message) (try an elevated terminal)"
        }
    }
}

function Install-WrmCli {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $bin = Join-Path $script:WrmRoot 'bin'
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (@($current -split ';') -contains $bin) { Write-Host "Already on PATH: $bin"; return }
    if ($PSCmdlet.ShouldProcess($bin, 'Add to user PATH')) {
        [Environment]::SetEnvironmentVariable('Path', ($current.TrimEnd(';') + ';' + $bin), 'User')
        Write-Host "Added $bin to your user PATH. Open a new terminal, then run: wrm help"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    switch ($Command) {
        'help' { Get-Help $PSCommandPath -Full | Out-String | Write-Host }
        'install-cli' { Install-WrmCli -WhatIf:$WhatIfPreference }
        'restart' {
            $rows = @(Restart-WrmTask -Force:$Force -WhatIf:$WhatIfPreference)
            $rows | Format-Table -AutoSize -Wrap | Out-String | Write-Host
            if (@($rows | Where-Object Action -in 'Failed', 'NotRegistered').Count -gt 0) { exit 1 }
        }
        default {
            $config = Get-ArmConfig -Path $ConfigPath
            if ($Simulate) { $config.Simulate = $true }
            $root = if ($Path) { $Path } else { [string] $config.NasVideoPath }
            if ($Command -eq 'repair') {
                $a = @{ Path = $root; WhatIf = $WhatIfPreference }
                if ($ConfigPath) { $a.ConfigPath = $ConfigPath }
                if ($Simulate) { $a.Simulate = $true }
                if ($Since) { $a.Since = $Since }
                if ($Until) { $a.Until = $Until }
                if ($RemoveOrphans) { $a.RemoveOrphans = $true }
                & (Join-Path $script:WrmRoot 'tools' 'Repair-ArmJellyfinNames.ps1') @a
            } else {
                $dirs = foreach ($f in @($Folder)) {
                    if (-not $f) { continue }
                    $full = (Resolve-Path -LiteralPath $f).Path
                    # A movies root holds movie folders; a movie folder holds .mkv files directly.
                    if (Get-ChildItem -LiteralPath $full -File -Filter '*.mkv' -ErrorAction SilentlyContinue) { $full }
                    else { (Get-ChildItem -LiteralPath $full -Directory).FullName }
                }
                if (-not $dirs) { throw 'Specify at least one movie folder or movies root: wrm upscale <path>...' }
                $rows = @(Add-ArmUpscaleQueueFromLibrary -MovieDir @($dirs) -Config $config -ContentType $ContentType -Force:$Force -WhatIf:$WhatIfPreference)
                if ($rows.Count -eq 0) { Write-Host 'Nothing to queue.' } else { $rows | Format-Table -AutoSize -Wrap | Out-String | Write-Host }
            }
        }
    }
}
