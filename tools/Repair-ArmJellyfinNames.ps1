<#
.SYNOPSIS
    Rename existing movie files so Jellyfin groups them as versions of one movie.

.DESCRIPTION
    Older rips kept the MakeMKV file name (B1_t00.mkv) inside the resolved movie
    folder, and the upscale landed next to it as 'B1_t00 [AI upscale 1080p].mkv'.
    Jellyfin then lists two movies titled 'b1_t00'. Jellyfin groups files as
    versions of one movie only when each file name starts with the folder name
    (case-insensitive) followed by nothing or a separator (' - ', '_', '.', '[label]').

    For every movie folder directly under -Path (top-level .mkv files only; extras/
    is never touched):
      - exactly one raw .mkv whose name does not start with the folder name is
        renamed to '<Folder>.mkv'
      - a '* [AI upscale 1080p].mkv' file is renamed to '<Folder> - 1080p.mkv' and
        its raw source to '<Folder> - <H>p.mkv' (H = source height from ffprobe;
        'DVD' when unknown), so the upscale sorts first and plays by default
      - anything ambiguous (several raw files, a target name that already exists, no
        matching source) is skipped and listed with a reason

    Run with -WhatIf first (it changes nothing), then for real, then rescan the
    library in Jellyfin.

.PARAMETER Path
    Movies root, e.g. '\\nas\media\movies'. Each sub-folder is one movie.

.PARAMETER ConfigPath
    Optional config file (used for the ffprobe path and logging).

.PARAMETER Simulate
    Use the test stubs instead of the real ffprobe.

.EXAMPLE
    ./tools/Repair-ArmJellyfinNames.ps1 -Path \\nas\media\movies -WhatIf
    ./tools/Repair-ArmJellyfinNames.ps1 -Path \\nas\media\movies
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Path,
    [string] $ConfigPath,
    [switch] $Simulate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'Upscale-Video.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'Move-ToNas.ps1')

$script:UpscaleSuffix = ' [AI upscale 1080p].mkv'

function New-RepairRow {
    param([string] $Folder, [string] $File, [string] $Action, [string] $NewName, [string] $Reason)
    [pscustomobject]@{ Folder = $Folder; File = $File; Action = $Action; NewName = $NewName; Reason = $Reason }
}

<#
.SYNOPSIS
    Repair the file names under a movies root; returns one summary row per file touched or skipped.

.OUTPUTS
    [pscustomobject[]] Folder, File, Action (Renamed | WouldRename | Skipped), NewName, Reason.
#>
function Repair-ArmJellyfinNames {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $rows = [System.Collections.Generic.List[object]]::new()

    # Files that a pending upscale queue entry points at must keep their name: the
    # worker renames them itself on completion, and a rename here would fail the job.
    $queued = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $queueDir = if ($Config.ContainsKey('UpscaleQueueDir')) { [string] $Config.UpscaleQueueDir } else { $null }
    if ($queueDir -and (Test-Path -LiteralPath $queueDir -PathType Container)) {
        foreach ($qf in @(Get-ChildItem -LiteralPath $queueDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.json', '.awaiting-review' })) {
            try {
                $q = Get-Content -LiteralPath $qf.FullName -Raw | ConvertFrom-Json
                if ($q.PSObject.Properties.Name -contains 'Source' -and $q.Source) { $null = $queued.Add([string] $q.Source) }
            } catch {
                Write-ArmLog -Level WARN -Message "Ignoring unreadable queue file '$($qf.FullName)': $_" -Config $Config
            }
        }
    }
    $queuedReason = 'queued for upscale (worker renames it on completion)'

    foreach ($dir in @(Get-ChildItem -LiteralPath $Path -Directory | Sort-Object -Property Name)) {
        $folder = $dir.Name
        $top = @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.mkv')
        $upscales = @($top | Where-Object { $_.Name.EndsWith($script:UpscaleSuffix, [System.StringComparison]::OrdinalIgnoreCase) })
        $raws = @($top | Where-Object { -not $_.Name.EndsWith($script:UpscaleSuffix, [System.StringComparison]::OrdinalIgnoreCase) })

        if ($upscales.Count -eq 0) {
            $bad = @($raws | Where-Object { -not $_.BaseName.StartsWith($folder, [System.StringComparison]::OrdinalIgnoreCase) })
            if ($bad.Count -eq 0) { continue }
            if ($raws.Count -ne 1) {
                $rows.Add((New-RepairRow $folder ($raws.Name -join ', ') 'Skipped' $null "ambiguous: $($raws.Count) top-level .mkv files and not all start with the folder name"))
                continue
            }
            $file = $raws[0]
            if ($queued.Contains($file.FullName)) {
                $rows.Add((New-RepairRow $folder $file.Name 'Skipped' $null $queuedReason))
                continue
            }
            $target = "$folder.mkv"
            if (Test-Path -LiteralPath (Join-Path $dir.FullName $target)) {
                $rows.Add((New-RepairRow $folder $file.Name 'Skipped' $target 'target name already exists'))
                continue
            }
            if ($PSCmdlet.ShouldProcess($file.FullName, "Rename to '$target'")) {
                try {
                    Move-Item -LiteralPath $file.FullName -Destination (Join-Path $dir.FullName $target)
                    $rows.Add((New-RepairRow $folder $file.Name 'Renamed' $target $null))
                } catch {
                    $rows.Add((New-RepairRow $folder $file.Name 'Skipped' $target "rename failed: $_"))
                }
            } else {
                $rows.Add((New-RepairRow $folder $file.Name 'WouldRename' $target $null))
            }
            continue
        }

        # Upscale present.
        if ($upscales.Count -gt 1) {
            $rows.Add((New-RepairRow $folder ($upscales.Name -join ', ') 'Skipped' $null 'ambiguous: several upscale files'))
            continue
        }
        $up = $upscales[0]
        $base = $up.Name.Substring(0, $up.Name.Length - $script:UpscaleSuffix.Length)
        $source = @($raws | Where-Object { $_.BaseName -ieq $base })
        if ($source.Count -eq 0 -and $raws.Count -eq 1) { $source = @($raws[0]) }
        if ($source.Count -ne 1) {
            $rows.Add((New-RepairRow $folder $up.Name 'Skipped' $null "ambiguous: cannot tell which of $($raws.Count) top-level raw .mkv files is the upscale source"))
            continue
        }
        $src = $source[0]
        if ($queued.Contains($src.FullName)) {
            $rows.Add((New-RepairRow $folder $src.Name 'Skipped' $null $queuedReason))
            continue
        }

        $height = $null
        try {
            $info = Get-VideoSourceInfo -InputFile $src.FullName -Config $Config
            if ($info.Success -and $info.Height -and [int] $info.Height -gt 0) { $height = [int] $info.Height }
        } catch {
            Write-ArmLog -Level WARN -Message "Could not probe '$($src.FullName)': $_" -Config $Config
        }
        $label = if ($height) { "${height}p" } else { 'DVD' }
        $upTarget = "$folder - 1080p.mkv"
        $srcTarget = "$folder - $label.mkv"

        $clash = @()
        foreach ($pair in @(@($up, $upTarget), @($src, $srcTarget))) {
            $t = Join-Path $dir.FullName $pair[1]
            if ((Test-Path -LiteralPath $t) -and $pair[0].Name -ine $pair[1]) { $clash += $pair[1] }
        }
        if ($clash.Count -gt 0) {
            $rows.Add((New-RepairRow $folder "$($up.Name), $($src.Name)" 'Skipped' $null "target name already exists: $($clash -join ', ')"))
            continue
        }

        if ($PSCmdlet.ShouldProcess($dir.FullName, "Rename '$($up.Name)' to '$upTarget' and '$($src.Name)' to '$srcTarget'")) {
            $r = Rename-ArmUpscaleVersions -FolderName $folder -UpscaledFile $up.FullName -SourceFile $src.FullName `
                -SourceHeight $height -Config $Config
            $rows.Add((New-RepairRow $folder $up.Name $(if ($r.OutputRenamed) { 'Renamed' } else { 'Skipped' }) $upTarget $(if ($r.OutputRenamed) { $null } else { $r.Error })))
            $rows.Add((New-RepairRow $folder $src.Name $(if ($r.SourceRenamed) { 'Renamed' } else { 'Skipped' }) $srcTarget $(if ($r.SourceRenamed) { $null } else { $r.Error })))
        } else {
            $rows.Add((New-RepairRow $folder $up.Name 'WouldRename' $upTarget $null))
            $rows.Add((New-RepairRow $folder $src.Name 'WouldRename' $srcTarget $null))
        }
    }

    return $rows.ToArray()
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Path) { throw 'Specify the movies root with -Path.' }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Movies root not found: $Path" }
    $config = Get-ArmConfig -Path $ConfigPath
    if ($Simulate) { $config.Simulate = $true }

    $rows = @(Repair-ArmJellyfinNames -Path $Path -Config $config -WhatIf:$WhatIfPreference)
    if ($rows.Count -eq 0) {
        Write-Host 'Nothing to rename.'
    } else {
        $rows | Format-Table -AutoSize -Wrap | Out-String | Write-Host
        $renamed = @($rows | Where-Object { $_.Action -in 'Renamed', 'WouldRename' }).Count
        $skipped = @($rows | Where-Object { $_.Action -eq 'Skipped' }).Count
        Write-Host "Renamed (or would rename): $renamed   Skipped: $skipped"
    }
    $rows
}
