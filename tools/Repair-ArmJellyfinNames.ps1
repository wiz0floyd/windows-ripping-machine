<#
.SYNOPSIS
    Rename existing movie files so Jellyfin groups them as versions of one movie.

.DESCRIPTION
    Older rips kept the MakeMKV file name (B1_t00.mkv) inside the resolved movie
    folder, and the upscale landed next to it as 'B1_t00 [AI upscale 1080p].mkv'.
    Jellyfin then lists two movies titled 'b1_t00'. Jellyfin groups files as
    versions of one movie only when each file name is the folder name, or the folder
    name followed by optional spaces and one of - _ . [ (case-insensitive).

    The largest raw .mkv is the main feature and everything else is an extra. For
    every movie folder directly under -Path (top-level .mkv files only):
      - raw .mkv files that Jellyfin would not group with the folder: the largest is
        renamed to '<Folder>.mkv' and every other one is moved into extras/
      - a version already labelled '<anything> - <N>p.mkv' / '<anything> - DVD.mkv' is never moved to
        extras/ and never competes to be the main feature; when its stem is not the folder name (an
        upscale named from the NFO title in a disc-name folder) it is renamed to '<Folder> - <label>.mkv'
      - a '* [AI upscale 1080p].mkv' file is renamed to '<Folder> - <UpscaleHeight>p.mkv'
        (1080p by default) and the largest raw file (its source) to
        '<Folder> - <H>p.mkv' (H = source height from ffprobe; 'DVD' when unknown), so
        the upscale sorts first and plays by default
      - a folder is skipped, and listed with a reason, when a raw file is the source of
        a pending upscale queue entry (.json, .awaiting-review or .failed in
        UpscaleQueueDir; the worker renames it itself), when a target name or an
        extras/ file already exists, or when there are several upscale files

    Run with -WhatIf first (it changes nothing), then for real, then rescan the
    library in Jellyfin.

.PARAMETER Path
    Movies root, e.g. '\\nas\media\movies'. Each sub-folder is one movie.

.PARAMETER ConfigPath
    Optional config file (used for the ffprobe path, logging and the queue dir).

.PARAMETER Simulate
    Use the test stubs instead of the real ffprobe.

.PARAMETER Since
    Only movie folders created on or after this date/time.

.PARAMETER Until
    Only movie folders created before this date/time.

.PARAMETER RemoveOrphans
    Also delete Jellyfin-generated sidecars (.nfo, -poster/-backdrop/... images, .trickplay
    folders) whose video no longer has that name. Evaluated against the post-rename names.

.PARAMETER RenameFolders
    First rename each movie folder to the Jellyfin NFO 'Title (Year)' (Get-ArmNfoMovieName of its
    main feature) when it differs, renaming the files and sidecars that carry the old folder name
    with it, then run the file repair above against the new names. Folders with no NFO are left
    alone; an NFO without a year, a pending upscale queue entry inside the folder, an existing
    target folder or a name clash skips the folder. Aborts the whole run (changes nothing) while the
    upscale queue holds .json/.awaiting-review entries or an upscale job is running, unless -Force.
    Jellyfin sees renamed folders as new items (watch state resets): rescan afterwards.

.PARAMETER Force
    With -RenameFolders, run despite pending upscale queue entries or a running upscale
    (folders that a queue entry points into are still skipped).

.EXAMPLE
    ./tools/Repair-ArmJellyfinNames.ps1 -Path \\nas\media\movies -WhatIf
    ./tools/Repair-ArmJellyfinNames.ps1 -Path \\nas\media\movies
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Path,
    [string] $ConfigPath,
    [switch] $Simulate,
    [Nullable[datetime]] $Since,
    [Nullable[datetime]] $Until,
    [switch] $RemoveOrphans,
    [switch] $RenameFolders,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'JobState.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'Upscale-Video.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'Move-ToNas.ps1')

$script:UpscaleSuffix = ' [AI upscale 1080p].mkv'

function New-RepairRow {
    param([string] $Folder, [string] $File, [string] $Action, [string] $NewName, [string] $Reason)
    [pscustomobject]@{ Folder = $Folder; File = $File; Action = $Action; NewName = $NewName; Reason = $Reason }
}

function Move-RepairItem {
    # Rename an item in place; a case-only change goes through a temp name (case-insensitive FS).
    param([string] $Path, [string] $NewName)
    $parent = Split-Path -Parent $Path
    $target = Join-Path $parent $NewName
    if ((Split-Path -Leaf $Path) -ieq $NewName) {
        $tmp = Join-Path $parent "$NewName.wrm-tmp-$([guid]::NewGuid().ToString('N'))"
        Move-Item -LiteralPath $Path -Destination $tmp
        Move-Item -LiteralPath $tmp -Destination $target
    } else {
        Move-Item -LiteralPath $Path -Destination $target
    }
    return $target
}

<#
.SYNOPSIS
    Rename movie folders (and the files inside that carry the old folder name) to the NFO 'Title (Year)'.

.OUTPUTS
    [pscustomobject[]] rows: Action FolderRenamed | WouldRenameFolder | Skipped. NewName = new folder name.
    A Skipped row with no Folder means the whole run was aborted (queue entries / running upscale).
#>
function Invoke-RepairFolderRenames {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [object[]] $Dirs,
        [Parameter(Mandatory = $true)] [hashtable] $Config,
        [switch] $Force
    )

    $rows = [System.Collections.Generic.List[object]]::new()

    # Queue entries: json / awaiting-review block the run unless -Force; all of them (incl. .failed,
    # which the web UI can retry) block the folder their Source/DestDir is in.
    $entries = [System.Collections.Generic.List[object]]::new()
    $queueDir = if ($Config.ContainsKey('UpscaleQueueDir')) { [string] $Config.UpscaleQueueDir } else { $null }
    if ($queueDir -and (Test-Path -LiteralPath $queueDir -PathType Container)) {
        foreach ($qf in @(Get-ChildItem -LiteralPath $queueDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.json', '.awaiting-review', '.failed' })) {
            $paths = @()
            try {
                $q = Get-Content -LiteralPath $qf.FullName -Raw | ConvertFrom-Json
                foreach ($k in 'Source', 'DestDir') {
                    if ($q.PSObject.Properties.Name -contains $k -and $q.$k) { $paths += [string] $q.$k }
                }
            } catch {
                Write-ArmLog -Level WARN -Message "Ignoring unreadable queue file '$($qf.FullName)': $_" -Config $Config
            }
            $entries.Add([pscustomobject]@{ Name = $qf.Name; Extension = $qf.Extension; Paths = $paths })
        }
    }

    if (-not $Force) {
        $blocking = @($entries | Where-Object { $_.Extension -in '.json', '.awaiting-review' })
        $running = @()
        try {
            $running = @(Get-ArmJobList -Kind Upscale -Config $Config | Where-Object { $_.State -in 'Sampling', 'Upscaling' })
        } catch {
            Write-ArmLog -Level WARN -Message "Could not read upscale jobs: $_" -Config $Config
        }
        if ($blocking.Count -gt 0 -or $running.Count -gt 0) {
            $why = @()
            if ($blocking.Count -gt 0) { $why += "$($blocking.Count) upscale queue entry(ies) pending ($(($blocking.Name | Select-Object -First 5) -join ', '))" }
            if ($running.Count -gt 0) { $why += "$($running.Count) upscale job(s) running" }
            $rows.Add((New-RepairRow $null $null 'Skipped' $null "folder rename aborted, nothing changed: $($why -join '; '). Use -Force to override."))
            return $rows.ToArray()
        }
    }

    foreach ($dir in $Dirs) {
        $old = $dir.Name
        $mkvs = @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.mkv' |
                Where-Object { -not $_.Name.EndsWith($script:UpscaleSuffix, [System.StringComparison]::OrdinalIgnoreCase) } |
                Sort-Object -Property Length -Descending)
        if ($mkvs.Count -eq 0) { continue }
        $new = Get-ArmNfoMovieName -VideoFile $mkvs[0].FullName
        if (-not $new) { continue }
        if ($new -ceq $old) { continue }
        if ($new -notmatch '\(\d{4}\)$') {
            $rows.Add((New-RepairRow $old $null 'Skipped' $new 'NFO has no year'))
            continue
        }

        $prefix = $dir.FullName.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $inside = @($entries | Where-Object {
                @($_.Paths | Where-Object { $_.TrimEnd('\', '/') -ieq $dir.FullName.TrimEnd('\', '/') -or $_.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            })
        if ($inside.Count -gt 0) {
            $rows.Add((New-RepairRow $old $null 'Skipped' $new "queued for upscale ($($inside[0].Name))"))
            continue
        }

        $caseOnly = ($new -ieq $old)
        if (-not $caseOnly -and (Test-Path -LiteralPath (Join-Path $Path $new))) {
            $rows.Add((New-RepairRow $old $null 'Skipped' $new 'target folder already exists'))
            continue
        }

        # Top-level items that carry the old folder name (versions and their sidecars).
        $plan = @()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir.FullName -Force)) {
            if (-not $item.Name.StartsWith($old, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $rest = $item.Name.Substring($old.Length)
            if ($rest -notmatch '^(\s*[-_.\[]|$)') { continue }
            $plan += [pscustomobject]@{ Item = $item; NewName = "$new$rest" }
        }
        $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $clash = $null
        foreach ($p in $plan) {
            if (-not $names.Add($p.NewName)) { $clash = $p.NewName; break }
            if (($p.Item.Name -ine $p.NewName) -and (Test-Path -LiteralPath (Join-Path $dir.FullName $p.NewName))) { $clash = $p.NewName; break }
        }
        if ($clash) {
            $rows.Add((New-RepairRow $old $null 'Skipped' $new "target name already exists: $clash"))
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($dir.FullName, "Rename folder to '$new' (+ $($plan.Count) item(s))")) {
            $rows.Add((New-RepairRow $old $null 'WouldRenameFolder' $new "$($plan.Count) item(s) carry the old name"))
            continue
        }

        $done = [System.Collections.Generic.List[object]]::new()
        try {
            foreach ($p in $plan) {
                $oldName = $p.Item.Name
                $moved = Move-RepairItem -Path $p.Item.FullName -NewName $p.NewName
                $done.Add(@{ Path = $moved; OldName = $oldName })
            }
            $null = Move-RepairItem -Path $dir.FullName -NewName $new
            Write-ArmLog -Level INFO -Message "Renamed folder '$old' -> '$new' ($($plan.Count) item(s))" -Config $Config
            $rows.Add((New-RepairRow $old $null 'FolderRenamed' $new "$($plan.Count) item(s) renamed"))
        } catch {
            $err = "$_"
            for ($i = $done.Count - 1; $i -ge 0; $i--) {
                try { $null = Move-RepairItem -Path $done[$i].Path -NewName $done[$i].OldName } catch {
                    Write-ArmLog -Level ERROR -Message "Rollback failed for '$($done[$i].Path)': $_" -Config $Config
                }
            }
            $rows.Add((New-RepairRow $old $null 'Skipped' $new "folder rename failed, rolled back: $err"))
        }
    }
    return $rows.ToArray()
}

<#
.SYNOPSIS
    Repair the file names under a movies root; returns one summary row per file touched or skipped.

.OUTPUTS
    [pscustomobject[]] Folder, File, Action (Renamed | WouldRename | Moved | WouldMove | Removed | WouldRemove | Skipped),
    NewName, Reason.
#>
function Repair-ArmJellyfinNames {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config,

        [Nullable[datetime]] $Since,

        [Nullable[datetime]] $Until,

        [switch] $RemoveOrphans,

        [switch] $RenameFolders,

        [switch] $Force
    )

    $rows = [System.Collections.Generic.List[object]]::new()

    # Files that a pending upscale queue entry points at must keep their name: the
    # worker renames them itself on completion, and a rename here would fail the job.
    # .failed entries count too: the web UI retry turns them back into .json.
    $queued = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $queueDir = if ($Config.ContainsKey('UpscaleQueueDir')) { [string] $Config.UpscaleQueueDir } else { $null }
    if ($queueDir -and (Test-Path -LiteralPath $queueDir -PathType Container)) {
        foreach ($qf in @(Get-ChildItem -LiteralPath $queueDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.json', '.awaiting-review', '.failed' })) {
            try {
                $q = Get-Content -LiteralPath $qf.FullName -Raw | ConvertFrom-Json
                if ($q.PSObject.Properties.Name -contains 'Source' -and $q.Source) { $null = $queued.Add([string] $q.Source) }
            } catch {
                Write-ArmLog -Level WARN -Message "Ignoring unreadable queue file '$($qf.FullName)': $_" -Config $Config
            }
        }
    }
    $queuedReason = 'queued for upscale (worker renames it on completion)'

    $getDirs = {
        $d = @(Get-ChildItem -LiteralPath $Path -Directory | Sort-Object -Property Name)
        # Folder creation time = when WRM first wrote the movie (the move to the NAS).
        if ($Since) { $d = @($d | Where-Object { $_.CreationTime -ge $Since }) }
        if ($Until) { $d = @($d | Where-Object { $_.CreationTime -lt $Until }) }
        $d
    }
    $dirs = @(& $getDirs)

    if ($RenameFolders) {
        $folderRows = @(Invoke-RepairFolderRenames -Path $Path -Dirs $dirs -Config $Config -Force:$Force -WhatIf:$WhatIfPreference)
        foreach ($r in $folderRows) { $rows.Add($r) }
        if (@($folderRows | Where-Object { -not $_.Folder -and $_.Action -eq 'Skipped' }).Count -gt 0) {
            return $rows.ToArray()   # run-level abort: change nothing
        }
        # Re-read after the renames; a -WhatIf plan did not move anything, so leave those folders out.
        $planned = @($folderRows | Where-Object { $_.Action -eq 'WouldRenameFolder' } | ForEach-Object { $_.Folder })
        $dirs = @(& $getDirs | Where-Object { $planned -notcontains $_.Name })
    }

    foreach ($dir in $dirs) {
        $folder = $dir.Name
        $top = @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.mkv')
        $upscales = @($top | Where-Object { $_.Name.EndsWith($script:UpscaleSuffix, [System.StringComparison]::OrdinalIgnoreCase) })
        $raws = @($top | Where-Object { -not $_.Name.EndsWith($script:UpscaleSuffix, [System.StringComparison]::OrdinalIgnoreCase) })

        # '<stem> - <N>p.mkv' / '<stem> - DVD.mkv' is a version WRM (or Jellyfin multi-version) already labelled:
        # never an extra and never a main-feature candidate. Only its stem may be wrong (the upscale is named from the
        # NFO title, the folder may still carry the disc name), so it is renamed to '<Folder> - <label>.mkv'.
        $labelRx = '^.+ - (?<label>\d{3,4}p|DVD)$'
        $labeled = @($raws | Where-Object { $_.BaseName -match $labelRx })
        $raws = @($raws | Where-Object { $_.BaseName -notmatch $labelRx })
        $labelRenames = [System.Collections.Generic.List[object]]::new()
        foreach ($lf in $labeled) {
            if (Test-ArmJellyfinVersionName -BaseName $lf.BaseName -Folder $folder) { continue }
            $null = $lf.BaseName -match $labelRx
            $labelRenames.Add([pscustomobject]@{ File = $lf; Target = "$folder - $($Matches['label']).mkv" })
        }
        if ($raws.Count -eq 0 -and $labeled.Count -eq 0) { continue }

        $queuedRaws = @($raws | Where-Object { $queued.Contains($_.FullName) })
        if ($queuedRaws.Count -gt 0) {
            $rows.Add((New-RepairRow $folder ($queuedRaws.Name -join ', ') 'Skipped' $null $queuedReason))
            continue
        }
        if ($upscales.Count -gt 1) {
            $rows.Add((New-RepairRow $folder ($upscales.Name -join ', ') 'Skipped' $null 'ambiguous: several upscale files'))
            continue
        }

        $labelClash = @($labelRenames | Where-Object { Test-Path -LiteralPath (Join-Path $dir.FullName $_.Target) })
        if ($labelClash.Count -gt 0) {
            $rows.Add((New-RepairRow $folder ($labelClash.File.Name -join ', ') 'Skipped' $null "target name already exists: $($labelClash.Target -join ', ')"))
            continue
        }
        $applyLabelRenames = {
            foreach ($lr in $labelRenames) {
                if ($PSCmdlet.ShouldProcess($lr.File.FullName, "Rename to '$($lr.Target)'")) {
                    try {
                        Move-Item -LiteralPath $lr.File.FullName -Destination (Join-Path $dir.FullName $lr.Target)
                        $rows.Add((New-RepairRow $folder $lr.File.Name 'Renamed' $lr.Target $null))
                    } catch {
                        $rows.Add((New-RepairRow $folder $lr.File.Name 'Skipped' $lr.Target "rename failed: $_"))
                    }
                } else {
                    $rows.Add((New-RepairRow $folder $lr.File.Name 'WouldRename' $lr.Target $null))
                }
            }
        }
        if ($raws.Count -eq 0) { & $applyLabelRenames; continue }

        $bySize = @($raws | Sort-Object -Property Length -Descending)
        $main = $bySize[0]
        if ($upscales.Count -eq 1) {
            # The upscale's own source (same base name) wins over a larger unrelated raw.
            $upBase = $upscales[0].Name.Substring(0, $upscales[0].Name.Length - $script:UpscaleSuffix.Length)
            $match = @($bySize | Where-Object { $_.BaseName -ieq $upBase })
            if ($match.Count -eq 1) { $main = $match[0] }
        }
        $others = @($bySize | Where-Object { $_.FullName -ne $main.FullName })
        # Raws Jellyfin already groups with the folder are versions, never extras.
        $toExtras = @($others | Where-Object { -not (Test-ArmJellyfinVersionName -BaseName $_.BaseName -Folder $folder) })

        if ($upscales.Count -eq 0) {
            # Main is the largest raw unless a correctly named raw exists already.
            $named = @($raws | Where-Object { Test-ArmJellyfinVersionName -BaseName $_.BaseName -Folder $folder })
            if ($named.Count -gt 0) {
                $main = $null
                $toExtras = @($raws | Where-Object { -not (Test-ArmJellyfinVersionName -BaseName $_.BaseName -Folder $folder) })
            }
        }

        $extrasDir = Join-Path $dir.FullName 'extras'
        $extrasClash = @($toExtras | Where-Object { Test-Path -LiteralPath (Join-Path $extrasDir $_.Name) })
        if ($extrasClash.Count -gt 0) {
            $rows.Add((New-RepairRow $folder ($extrasClash.Name -join ', ') 'Skipped' $null 'extras/ already holds a file with that name'))
            continue
        }

        # Plan the renames first so a clash skips the whole folder before anything moves.
        $height = $null
        $upTarget = $null
        $mainTarget = $null
        $mainLabel = $null
        if ($upscales.Count -eq 1) {
            $up = $upscales[0]
            try {
                $info = Get-VideoSourceInfo -InputFile $main.FullName -Config $Config
                if ($info.Success -and $info.Height -and [int] $info.Height -gt 0) { $height = [int] $info.Height }
            } catch {
                Write-ArmLog -Level WARN -Message "Could not probe '$($main.FullName)': $_" -Config $Config
            }
            $outHeight = 1080
            if ($Config.ContainsKey('UpscaleHeight') -and "$($Config.UpscaleHeight)" -match '^\d+$' -and [int] $Config.UpscaleHeight -gt 0) {
                $outHeight = [int] $Config.UpscaleHeight
            }
            $mainLabel = if ($height) { "${height}p" } else { 'DVD' }
            $upTarget = "$folder - $($outHeight)p.mkv"
            $mainTarget = "$folder - $mainLabel.mkv"
            $clash = @()
            foreach ($pair in @(@($up, $upTarget), @($main, $mainTarget))) {
                if ((Test-Path -LiteralPath (Join-Path $dir.FullName $pair[1])) -and $pair[0].Name -ine $pair[1]) { $clash += $pair[1] }
            }
            if ($clash.Count -gt 0) {
                $rows.Add((New-RepairRow $folder "$($up.Name), $($main.Name)" 'Skipped' $null "target name already exists: $($clash -join ', ')"))
                continue
            }
        } elseif ($main -and -not (Test-ArmJellyfinVersionName -BaseName $main.BaseName -Folder $folder)) {
            $mainTarget = "$folder.mkv"
            if (Test-Path -LiteralPath (Join-Path $dir.FullName $mainTarget)) {
                $rows.Add((New-RepairRow $folder $main.Name 'Skipped' $mainTarget 'target name already exists'))
                continue
            }
        }

        $plannedTargets = @($upTarget, $mainTarget) | Where-Object { $_ }
        $labelCollide = @($labelRenames | Where-Object { $plannedTargets -contains $_.Target })
        if ($labelCollide.Count -gt 0) {
            $rows.Add((New-RepairRow $folder ($labelCollide.File.Name -join ', ') 'Skipped' $null "target name already planned: $($labelCollide.Target -join ', ')"))
            continue
        }

        $nothingToDo = ($toExtras.Count -eq 0) -and ($upscales.Count -eq 0) -and (-not $mainTarget) -and ($labelRenames.Count -eq 0)
        if ($nothingToDo) { continue }

        # --- extras ---
        foreach ($extra in $toExtras) {
            if ($PSCmdlet.ShouldProcess($extra.FullName, "Move to extras/")) {
                try {
                    $null = New-Item -ItemType Directory -Path $extrasDir -Force
                    Move-Item -LiteralPath $extra.FullName -Destination (Join-Path $extrasDir $extra.Name)
                    $rows.Add((New-RepairRow $folder $extra.Name 'Moved' "extras\$($extra.Name)" $null))
                } catch {
                    $rows.Add((New-RepairRow $folder $extra.Name 'Skipped' $null "move to extras failed: $_"))
                }
            } else {
                $rows.Add((New-RepairRow $folder $extra.Name 'WouldMove' "extras\$($extra.Name)" $null))
            }
        }

        # --- main feature / upscale ---
        if ($upscales.Count -eq 1) {
            if ($PSCmdlet.ShouldProcess($dir.FullName, "Rename '$($up.Name)' to '$upTarget' and '$($main.Name)' to '$mainTarget'")) {
                $r = Rename-ArmUpscaleVersions -FolderName $folder -UpscaledFile $up.FullName -SourceFile $main.FullName `
                    -SourceHeight $height -Config $Config
                $rows.Add((New-RepairRow $folder $up.Name $(if ($r.OutputRenamed) { 'Renamed' } else { 'Skipped' }) $upTarget $(if ($r.OutputRenamed) { $null } else { $r.Error })))
                $rows.Add((New-RepairRow $folder $main.Name $(if ($r.SourceRenamed) { 'Renamed' } else { 'Skipped' }) $mainTarget $(if ($r.SourceRenamed) { $null } else { $r.Error })))
            } else {
                $rows.Add((New-RepairRow $folder $up.Name 'WouldRename' $upTarget $null))
                $rows.Add((New-RepairRow $folder $main.Name 'WouldRename' $mainTarget $null))
            }
        } elseif ($mainTarget) {
            if ($PSCmdlet.ShouldProcess($main.FullName, "Rename to '$mainTarget'")) {
                try {
                    Move-Item -LiteralPath $main.FullName -Destination (Join-Path $dir.FullName $mainTarget)
                    $rows.Add((New-RepairRow $folder $main.Name 'Renamed' $mainTarget $null))
                } catch {
                    $rows.Add((New-RepairRow $folder $main.Name 'Skipped' $mainTarget "rename failed: $_"))
                }
            } else {
                $rows.Add((New-RepairRow $folder $main.Name 'WouldRename' $mainTarget $null))
            }
        }

        & $applyLabelRenames
    }

    if ($RemoveOrphans) {
        # Jellyfin sidecars (<name>.nfo, <name>-poster.jpg, <name>.trickplay\) are keyed on the video's
        # base name. After a rename the old ones point at nothing; Jellyfin regenerates the real ones.
        # Video names are taken as they will be after the planned renames, so -WhatIf shows the end state.
        $videoExt = @('.mkv', '.mp4', '.m4v', '.avi')
        $imageRx = '^(?<s>.+)-(poster|backdrop|landscape|logo|banner|thumb|clearlogo|clearart|fanart|disc)\.(jpg|jpeg|png|svg|webp)$'
        foreach ($dir in $dirs) {
            $folder = $dir.Name
            $mine = @($rows | Where-Object { $_.Folder -eq $folder })
            if (@($mine | Where-Object { $_.Action -eq 'Skipped' }).Count -gt 0) {
                $rows.Add((New-RepairRow $folder $null 'Skipped' $null 'orphan check skipped: folder has skipped files'))
                continue
            }
            $names = [System.Collections.Generic.List[string]]::new()
            foreach ($v in @(Get-ChildItem -LiteralPath $dir.FullName -File | Where-Object { $_.Extension -in $videoExt })) { $names.Add($v.Name) }
            foreach ($r in $mine) {
                if ($r.Action -in 'Renamed', 'WouldRename') { $null = $names.Remove($r.File); $names.Add($r.NewName) }
                elseif ($r.Action -eq 'WouldMove') { $null = $names.Remove($r.File) }
            }
            if ($names.Count -eq 0) { continue }
            $stems = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($n in $names) { $null = $stems.Add([System.IO.Path]::GetFileNameWithoutExtension($n)) }

            foreach ($item in @(Get-ChildItem -LiteralPath $dir.FullName -Force)) {
                $stem = $null
                if ($item.PSIsContainer) {
                    if ($item.Name -match '^(?<s>.+)\.trickplay$') { $stem = $Matches['s'] }
                } elseif ($item.Name -match $imageRx) {
                    $stem = $Matches['s']
                } elseif ($item.Name -match '^(?<s>.+)\.nfo$' -and $item.Name -ine 'movie.nfo') {
                    $stem = $Matches['s']
                }
                if (-not $stem -or $stems.Contains($stem)) { continue }
                if ($PSCmdlet.ShouldProcess($item.FullName, 'Remove orphaned Jellyfin sidecar')) {
                    try {
                        Remove-Item -LiteralPath $item.FullName -Recurse -Force
                        $rows.Add((New-RepairRow $folder $item.Name 'Removed' $null 'orphaned sidecar'))
                    } catch {
                        $rows.Add((New-RepairRow $folder $item.Name 'Skipped' $null "remove failed: $_"))
                    }
                } else {
                    $rows.Add((New-RepairRow $folder $item.Name 'WouldRemove' $null 'orphaned sidecar'))
                }
            }
        }
    }

    return $rows.ToArray()
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Path) { throw 'Specify the movies root with -Path.' }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Movies root not found: $Path" }
    $config = Get-ArmConfig -Path $ConfigPath
    if ($Simulate) { $config.Simulate = $true }

    $rows = @(Repair-ArmJellyfinNames -Path $Path -Config $config -Since $Since -Until $Until -RemoveOrphans:$RemoveOrphans -RenameFolders:$RenameFolders -Force:$Force -WhatIf:$WhatIfPreference)
    if ($rows.Count -eq 0) {
        Write-Host 'Nothing to rename.'
    } else {
        # Table only (no objects on the pipeline), so nothing prints twice.
        $rows | Format-Table -AutoSize -Wrap | Out-String | Write-Host
        $done = @($rows | Where-Object { $_.Action -in 'Renamed', 'WouldRename', 'Moved', 'WouldMove', 'Removed', 'WouldRemove', 'FolderRenamed', 'WouldRenameFolder' }).Count
        $skipped = @($rows | Where-Object { $_.Action -eq 'Skipped' }).Count
        Write-Host "Renamed/moved (or would): $done   Skipped: $skipped"
    }
}
