Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Internal function to invoke robocopy. Can be mocked in tests.

.OUTPUTS
    [pscustomobject] with ExitCode [int] and Lines [string[]]
#>
function Invoke-Robocopy {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $SourceDir,
        [string] $DestDir
    )

    $lines = @()
    & robocopy $SourceDir $DestDir /E /Z /NP /R:3 /W:10 | ForEach-Object {
        if ($_) {
            $lines += $_
        }
    }
    $exitCode = $LASTEXITCODE

    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines    = $lines
    }
}

<#
.SYNOPSIS
    Move a directory tree to a NAS share using robocopy with verification.

.DESCRIPTION
    Uses robocopy to move files from SourceDir to a subdirectory of DestRoot.
    Creates a subdirectory under DestRoot with the same name as SourceDir.

    Robocopy is invoked with /E /Z /NP /R:3 /W:10 flags.
    Exit codes 0-7 are treated as success; >=8 as failure.

    After successful robocopy, verifies that every file exists at the destination
    with matching file size (Length). Source directory is deleted ONLY after
    verification passes. If verification fails, source is preserved.

    Never throws; errors are returned in the result object.

    Failures (robocopy failure or verification mismatch) are NOT automatically
    retried or re-queued; this is a deliberate design choice, not an oversight.
    The source directory is left in place, and the caller (DiscWatcher.ps1) is
    expected to log and notify so a human can investigate and manually re-trigger
    the move. Building a safe automatic retry/re-queue mechanism is nontrivial
    (duplicate partial copies, backoff, re-verification), so manual intervention
    is the accepted safer default.

.PARAMETER SourceDir
    Full path to the source directory to move.

.PARAMETER DestRoot
    Root path on the destination (e.g., '\\nas\media\import\movies').
    Destination directory will be DestRoot\<SourceDirName>.

.PARAMETER Config
    Configuration hashtable.

.OUTPUTS
    [pscustomobject] with properties:
    - Success [bool]: $true if move completed and verified successfully
    - DestDir [string]: Full path to the destination directory
    - Error [string]: Error message if Success=$false; $null otherwise

.EXAMPLE
    $result = Move-ToNas -SourceDir 'C:\rips\staging\MyMovie' `
                         -DestRoot '\\nas\media\import\movies' -Config $config
    if ($result.Success) {
        Write-Host "Moved to: $($result.DestDir)"
    }
#>
function Move-ToNas {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourceDir,

        [Parameter(Mandatory = $true)]
        [string] $DestRoot,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    try {
        # Validate source directory exists
        if (-not (Test-Path -Path $SourceDir -PathType Container)) {
            $errorMsg = "Source directory not found: $SourceDir"
            Write-ArmLog -Level ERROR -Message $errorMsg -Config $Config
            return New-ArmResult -Success $false -Properties ([ordered]@{ DestDir = $null }) -Error $errorMsg
        }

        # Resolve to the canonical long path so it matches Get-ChildItem's FullName
        # output later (short 8.3 paths like RUNNER~1 would otherwise break the
        # prefix Substring used for relative-path verification below).
        $SourceDir = (Get-Item -Path $SourceDir).FullName
        $sourceDirName = (Get-Item -Path $SourceDir).Name
        $destDir = Join-Path $DestRoot $sourceDirName

        Write-ArmLog -Level INFO -Message "Starting move: $SourceDir -> $destDir" -Config $Config

        # Create destination parent directory if needed
        $null = New-Item -ItemType Directory -Path $DestRoot -Force -ErrorAction SilentlyContinue

        # Run robocopy with specified flags
        Write-ArmLog -Level INFO -Message "Invoking robocopy with /E /Z /NP /R:3 /W:10" -Config $Config
        $robocopyResult = Invoke-Robocopy -SourceDir $SourceDir -DestDir $destDir
        $robocopyExitCode = $robocopyResult.ExitCode

        # Log robocopy output lines
        $robocopyResult.Lines | ForEach-Object {
            Write-ArmLog -Level INFO -Message "[robocopy] $_" -Config $Config
        }

        # Interpret robocopy exit code (0-7 = success, >=8 = failure)
        if ($robocopyExitCode -ge 8) {
            $errorMsg = "robocopy failed with exit code $robocopyExitCode"
            Write-ArmLog -Level ERROR -Message $errorMsg -Config $Config
            return New-ArmResult -Success $false -Properties ([ordered]@{ DestDir = $null }) -Error $errorMsg
        }

        Write-ArmLog -Level INFO -Message "robocopy completed with exit code $robocopyExitCode (success)" -Config $Config

        # Verify destination by comparing source and destination files
        Write-ArmLog -Level INFO -Message "Verifying file transfer..." -Config $Config

        $sourceFiles = @(Get-ChildItem -Path $SourceDir -Recurse -File -ErrorAction SilentlyContinue)
        $verificationFailed = $false

        foreach ($sourceFile in $sourceFiles) {
            $relativePath = $sourceFile.FullName.Substring($SourceDir.Length).TrimStart('\')
            $destFile = Join-Path $destDir $relativePath

            if (-not (Test-Path $destFile)) {
                Write-ArmLog -Level ERROR -Message "Verification failed: destination file missing: $relativePath" -Config $Config
                $verificationFailed = $true
                break
            }

            $destFileObj = Get-Item -Path $destFile -ErrorAction SilentlyContinue
            if ($sourceFile.Length -ne $destFileObj.Length) {
                Write-ArmLog -Level ERROR -Message "Verification failed: file size mismatch: $relativePath (source: $($sourceFile.Length), dest: $($destFileObj.Length))" -Config $Config
                $verificationFailed = $true
                break
            }
        }

        if ($verificationFailed) {
            $errorMsg = "Verification failed: source and destination mismatch"
            Write-ArmLog -Level ERROR -Message $errorMsg -Config $Config
            return New-ArmResult -Success $false -Properties ([ordered]@{ DestDir = $destDir }) -Error $errorMsg
        }

        Write-ArmLog -Level INFO -Message "Verification successful: all files match" -Config $Config

        # Delete source directory only after verification passes
        Write-ArmLog -Level INFO -Message "Deleting source directory: $SourceDir" -Config $Config
        Remove-Item -Path $SourceDir -Recurse -Force -ErrorAction Stop

        Write-ArmLog -Level INFO -Message "Move completed successfully: $destDir" -Config $Config

        return New-ArmResult -Success $true -Properties ([ordered]@{ DestDir = $destDir }) -Error $null

    } catch {
        $errorMsg = "Exception in Move-ToNas: $_"
        Write-ArmLog -Level ERROR -Message $errorMsg -Config $Config
        return New-ArmResult -Success $false -Properties ([ordered]@{ DestDir = $null }) -Error $errorMsg
    }
}

<#
.SYNOPSIS
    Arrange a staged video directory in Jellyfin's extras layout.

.DESCRIPTION
    Jellyfin treats extra .mkv files sitting next to the main movie as
    alternate versions of it. Keeps the largest .mkv at the top level of
    Dir (the main feature) and moves every other top-level .mkv into an
    'extras' subdirectory, one of Jellyfin's recognised extras folder names
    (https://jellyfin.org/docs/general/server/media/movies/#extras-folders).

    No-op when Dir holds fewer than two top-level .mkv files. Never throws;
    failures are logged and returned so the caller can still proceed.

.PARAMETER Dir
    Staging directory containing the ripped .mkv files.

.PARAMETER Config
    Configuration hashtable (for logging).

.OUTPUTS
    [pscustomobject] with Success [bool], Moved [int] (extras relocated), MainFeature
    [string] (full path of the kept main feature, $null when none/unknown), Error [string].
#>
function Move-ArmExtrasToSubdir {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Dir,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    try {
        $mkvs = @(Get-ChildItem -LiteralPath $Dir -File -Filter '*.mkv' |
            Sort-Object -Property Length -Descending)
        if ($mkvs.Count -lt 2) {
            return New-ArmResult -Success $true -Properties ([ordered]@{ Moved = 0; MainFeature = if ($mkvs.Count -eq 1) { $mkvs[0].FullName } else { $null } }) -Error $null
        }

        $extrasDir = Join-Path $Dir 'extras'
        $null = New-Item -ItemType Directory -Path $extrasDir -Force

        $moved = 0
        foreach ($extra in ($mkvs | Select-Object -Skip 1)) {
            Move-Item -LiteralPath $extra.FullName -Destination (Join-Path $extrasDir $extra.Name) -Force
            $moved++
        }
        Write-ArmLog -Level INFO -Message "Moved $moved extra(s) into '$extrasDir'; main feature: $($mkvs[0].Name)" -Config $Config
        return New-ArmResult -Success $true -Properties ([ordered]@{ Moved = $moved; MainFeature = $mkvs[0].FullName }) -Error $null
    } catch {
        $errorMsg = "Exception in Move-ArmExtrasToSubdir: $_"
        Write-ArmLog -Level ERROR -Message $errorMsg -Config $Config
        return New-ArmResult -Success $false -Properties ([ordered]@{ Moved = 0; MainFeature = $null }) -Error $errorMsg
    }
}

<#
.SYNOPSIS
    Rename the main feature in a staged video directory to '<FolderName>.mkv'.

.DESCRIPTION
    Jellyfin only groups several files as versions of one movie when every file
    name starts with the folder name. A file named exactly like the folder is the
    primary version. MakeMKV names (B1_t00.mkv) would otherwise show up as a
    separate movie titled 'b1_t00', and so would the later upscale next to it.

    Call this after Move-ArmExtrasToSubdir: the largest top-level .mkv is the main
    feature and is renamed to '<leaf of Dir>.mkv'. Does nothing when the name
    already matches (case-insensitive) or Dir holds no top-level .mkv. When a
    different file already has the target name it logs WARN and keeps the original
    name. extras/ is never touched. Never throws.

.PARAMETER Dir
    Staging directory (leaf = resolved folder name, which is also the NAS leaf).

.PARAMETER MainFeature
    Optional full path of the main feature (Move-ArmExtrasToSubdir's MainFeature);
    without it the largest top-level .mkv is used.

.PARAMETER Label
    Optional version label (e.g. '480p'): the file becomes '<folder> - <Label>.mkv'
    unless it already carries a '- <N>p' / '- DVD' label.

.PARAMETER Config
    Configuration hashtable (for logging).

.OUTPUTS
    [pscustomobject] with Success [bool], Renamed [bool], Path [string] (main
    feature path after the call, or $null when there is none), Error [string].
    Already-named means Jellyfin would group it: name == folder, or folder followed by
    optional spaces and one of - _ . [ (Test-ArmJellyfinVersionName).
#>
function Test-ArmJellyfinVersionName {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)] [string] $BaseName,
        [Parameter(Mandatory = $true)] [string] $Folder
    )
    # Jellyfin: name == folder, or folder followed by optional spaces and then - _ . or [
    # (so a movie 'Up' does not claim 'Upgrade.mkv').
    if ($BaseName -ieq $Folder) { return $true }
    if (-not $BaseName.StartsWith($Folder, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    return ($BaseName.Substring($Folder.Length) -match '^\s*[-_.\[]')
}

function Rename-ArmMainFeature {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Dir,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config,

        [string] $MainFeature,

        [string] $Label
    )

    try {
        $folderName = Split-Path -Leaf ($Dir.TrimEnd('\', '/'))
        if ($MainFeature -and (Test-Path -LiteralPath $MainFeature -PathType Leaf)) {
            $main = Get-Item -LiteralPath $MainFeature
        } else {
            $main = @(Get-ChildItem -LiteralPath $Dir -File -Filter '*.mkv' |
                Sort-Object -Property Length -Descending) | Select-Object -First 1
        }
        if (-not $main) {
            return New-ArmResult -Success $true -Properties ([ordered]@{ Renamed = $false; Path = $null }) -Error $null
        }

        $targetName = "$folderName.mkv"
        if ($Label) {
            # Version label wanted ('<folder> - 480p.mkv'): keep a name that already carries one.
            $targetName = "$folderName - $Label.mkv"
            $labelled = $main.BaseName -match ('^' + [regex]::Escape($folderName) + '\s*-\s*(\d+p|DVD)$')
            if ($labelled -or $main.Name -ieq $targetName) {
                return New-ArmResult -Success $true -Properties ([ordered]@{ Renamed = $false; Path = $main.FullName }) -Error $null
            }
        } elseif (Test-ArmJellyfinVersionName -BaseName $main.BaseName -Folder $folderName) {
            return New-ArmResult -Success $true -Properties ([ordered]@{ Renamed = $false; Path = $main.FullName }) -Error $null
        }

        $targetPath = Join-Path $Dir $targetName
        if (Test-Path -LiteralPath $targetPath) {
            Write-ArmLog -Level WARN -Message "Not renaming main feature '$($main.Name)': '$targetName' already exists in '$Dir'" -Config $Config
            return New-ArmResult -Success $true -Properties ([ordered]@{ Renamed = $false; Path = $main.FullName }) -Error $null
        }

        Move-Item -LiteralPath $main.FullName -Destination $targetPath
        Write-ArmLog -Level INFO -Message "Renamed main feature '$($main.Name)' -> '$targetName'" -Config $Config
        return New-ArmResult -Success $true -Properties ([ordered]@{ Renamed = $true; Path = $targetPath }) -Error $null
    } catch {
        $errorMsg = "Exception in Rename-ArmMainFeature: $_"
        Write-ArmLog -Level ERROR -Message $errorMsg -Config $Config
        return New-ArmResult -Success $false -Properties ([ordered]@{ Renamed = $false; Path = $null }) -Error $errorMsg
    }
}

<#
.SYNOPSIS
    Rename a finished upscale and its source so Jellyfin groups them as two
    versions of one movie and plays the upscale by default.

.DESCRIPTION
    Jellyfin treats files named '<FolderName><separator><label>.mkv' as versions of
    the movie in <FolderName>. Versions whose label ends in 'p' sort by resolution,
    highest first, and the first one plays by default. So:
      - the upscale becomes '<FolderName> - <UpscaleHeight>p.mkv' (1080 by default)  (renamed first)
      - the source  becomes '<FolderName> - <H>p.mkv'   (H = SourceHeight, or
        'DVD' when the height is unknown or not positive)

    Never throws and never fails an upscale that already succeeded: a rename that
    cannot happen (target exists, file missing, IO error) logs WARN and leaves that
    file under its current name. Every path is used with -LiteralPath because the
    upscale name contains '[' and ']'.

.PARAMETER FolderName
    Movie folder leaf (e.g. 'Grease (1978)').

.PARAMETER UpscaledFile
    Full path of the upscale Invoke-Upscale produced.

.PARAMETER SourceFile
    Full path of the raw source .mkv.

.PARAMETER SourceHeight
    Source frame height in pixels (480 or 576); $null/0 when unknown.

.OUTPUTS
    [pscustomobject] with Success [bool], OutputFile [string] and SourceFile [string]
    (final paths, unchanged where a rename was skipped), OutputRenamed [bool],
    SourceRenamed [bool], Error [string] (first WARN, informational only).
#>
function Rename-ArmUpscaleVersions {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $FolderName,

        [Parameter(Mandatory = $true)]
        [string] $UpscaledFile,

        [Parameter(Mandatory = $true)]
        [string] $SourceFile,

        [Nullable[int]] $SourceHeight,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $state = [ordered]@{ OutputFile = $UpscaledFile; SourceFile = $SourceFile; OutputRenamed = $false; SourceRenamed = $false }
    $warning = $null

    $renameOne = {
        param([string] $Path, [string] $NewName)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return [pscustomobject]@{ Path = $Path; Renamed = $false; Warning = "'$Path' not found, cannot rename to '$NewName'" }
        }
        $item = Get-Item -LiteralPath $Path
        if ($item.Name -ieq $NewName) {
            return [pscustomobject]@{ Path = $Path; Renamed = $false; Warning = $null }
        }
        $target = Join-Path $item.DirectoryName $NewName
        if (Test-Path -LiteralPath $target) {
            return [pscustomobject]@{ Path = $Path; Renamed = $false; Warning = "'$NewName' already exists in '$($item.DirectoryName)'; keeping '$($item.Name)'" }
        }
        Move-Item -LiteralPath $Path -Destination $target
        return [pscustomobject]@{ Path = $target; Renamed = $true; Warning = $null }
    }

    $outHeight = 1080
    if ($Config.ContainsKey('UpscaleHeight') -and "$($Config.UpscaleHeight)" -match '^\d+$' -and [int] $Config.UpscaleHeight -gt 0) {
        $outHeight = [int] $Config.UpscaleHeight
    }
    $outTarget = "$FolderName - $($outHeight)p.mkv"
    $label = if ($SourceHeight -and $SourceHeight -gt 0) { "$($SourceHeight)p" } else { 'DVD' }

    try {
        $out = & $renameOne $UpscaledFile $outTarget
        $state.OutputFile = $out.Path
        $state.OutputRenamed = $out.Renamed
        if ($out.Warning) {
            $warning = $out.Warning
            Write-ArmLog -Level WARN -Message "Jellyfin naming (upscale): $($out.Warning)" -Config $Config
        }
    } catch {
        $warning = "Could not rename upscale '$UpscaledFile': $_"
        Write-ArmLog -Level WARN -Message $warning -Config $Config
    }

    if ((Split-Path -Leaf $state.OutputFile) -ine $outTarget) {
        # The upscale did not get the folder-name label: leave the source alone too.
        if (-not $warning) { $warning = "Upscale not renamed; leaving source '$SourceFile' as is" }
        Write-ArmLog -Level WARN -Message "Jellyfin naming: upscale not renamed; leaving source '$SourceFile' as is" -Config $Config
        return New-ArmResult -Success $true -Properties $state -Error $warning
    }

    try {
        $src = & $renameOne $SourceFile "$FolderName - $label.mkv"
        $state.SourceFile = $src.Path
        $state.SourceRenamed = $src.Renamed
        if ($src.Warning) {
            if (-not $warning) { $warning = $src.Warning }
            Write-ArmLog -Level WARN -Message "Jellyfin naming (source): $($src.Warning)" -Config $Config
        }
    } catch {
        if (-not $warning) { $warning = "Could not rename source '$SourceFile': $_" }
        Write-ArmLog -Level WARN -Message "Could not rename source '$SourceFile': $_" -Config $Config
    }

    return New-ArmResult -Success $true -Properties $state -Error $warning
}
