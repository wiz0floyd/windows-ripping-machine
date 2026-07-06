Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Parse a single makemkvcon `-r` robot-output line into a prefix and field array.

.DESCRIPTION
    makemkvcon robot lines look like `PREFIX:field0,field1,"quoted field",...`.
    Quoted fields may contain commas; a doubled quote ("") inside a quoted field
    is an escaped literal quote. Returns $null for lines that don't match the
    `PREFIX:...` shape (blank lines, stray tool banners, etc.).

.PARAMETER Line
    A single line of makemkvcon `-r` output.

.OUTPUTS
    [pscustomobject] @{ Prefix; Fields } or $null.
#>
function ConvertFrom-MakeMkvRobotLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Line
    )

    if ($Line -notmatch '^(?<prefix>[A-Z]+):(?<rest>.*)$') {
        return $null
    }

    $fields = [System.Collections.Generic.List[string]]::new()
    $pattern = '(?:^|,)(?:"(?<q>(?:[^"]|"")*)"|(?<u>[^,]*))'
    foreach ($m in [regex]::Matches($Matches.rest, $pattern)) {
        if ($m.Groups['q'].Success) {
            $fields.Add($m.Groups['q'].Value.Replace('""', '"'))
        } else {
            $fields.Add($m.Groups['u'].Value)
        }
    }

    return [pscustomobject]@{
        Prefix = $Matches.prefix
        Fields = $fields.ToArray()
    }
}

<#
.SYNOPSIS
    Convert a makemkvcon "H:MM:SS" (or "MM:SS") duration string to total seconds.
#>
function ConvertTo-MakeMkvSeconds {
    [CmdletBinding()]
    [OutputType([int])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Seconds is a unit of measure, not a collection noun.')]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Duration
    )

    if (-not $Duration) {
        return 0
    }

    $seconds = 0
    foreach ($part in $Duration.Split(':')) {
        $n = 0
        if ([int]::TryParse($part, [ref] $n)) {
            $seconds = ($seconds * 60) + $n
        }
    }
    return $seconds
}

<#
.SYNOPSIS
    Find the makemkvcon disc index, label, and disc type for a given Windows drive letter.

.DESCRIPTION
    Scans `DRV:` lines from `makemkvcon -r info disc:9999` output. A DRV line is
    `index,visible,enabled,flags,"drive name","disc name","device path"`. Matches
    the device path against the requested drive letter. Disc type is inferred from
    the drive-name hardware descriptor (contains "BD"/"Blu" => BD, else DVD).

.OUTPUTS
    [pscustomobject] @{ Index; Label; DiscType } or $null when no disc is present.
#>
function Get-MakeMkvDriveInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Lines,

        [Parameter(Mandatory = $true)]
        [char] $DriveLetter
    )

    $targetDevice = "$($DriveLetter):"

    foreach ($line in $Lines) {
        $parsed = ConvertFrom-MakeMkvRobotLine -Line $line
        if (-not $parsed -or $parsed.Prefix -ne 'DRV' -or $parsed.Fields.Count -lt 7) {
            continue
        }

        $device = $parsed.Fields[6].TrimEnd('\')
        if ($device -and $device -ieq $targetDevice) {
            $discName = $parsed.Fields[5]
            if (-not $discName) {
                return $null
            }

            $driveName = $parsed.Fields[4]
            $discType = if ($driveName -match '(?i)blu|bd[- ]?rom|bdxl') { 'BD' } else { 'DVD' }

            return [pscustomobject]@{
                Index    = [int]$parsed.Fields[0]
                Label    = $discName
                DiscType = $discType
            }
        }
    }

    return $null
}

<#
.SYNOPSIS
    Find the title index with the longest duration from TINFO lines (code 9 = Duration).

.OUTPUTS
    [int] title index, or $null if no TINFO duration lines are present.
#>
function Get-MakeMkvLongestTitleIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Lines
    )

    $bestIndex = $null
    $bestSeconds = -1

    foreach ($line in $Lines) {
        $parsed = ConvertFrom-MakeMkvRobotLine -Line $line
        if (-not $parsed -or $parsed.Prefix -ne 'TINFO' -or $parsed.Fields.Count -lt 4) {
            continue
        }
        if ($parsed.Fields[1] -ne '9') {
            continue
        }

        $seconds = ConvertTo-MakeMkvSeconds -Duration $parsed.Fields[3]
        if ($seconds -gt $bestSeconds) {
            $bestSeconds = $seconds
            $bestIndex = [int]$parsed.Fields[0]
        }
    }

    return $bestIndex
}

<#
.SYNOPSIS
    Detect an expired/absent MakeMKV registration key from robot-output lines.

.DESCRIPTION
    Looks for MSG code 5021 or any MSG text containing "registration key"
    (case-insensitive), per the MakeMKV robot-output message catalog.
#>
function Test-MakeMkvExpiredKey {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Lines
    )

    foreach ($line in $Lines) {
        $parsed = ConvertFrom-MakeMkvRobotLine -Line $line
        if (-not $parsed -or $parsed.Prefix -ne 'MSG' -or $parsed.Fields.Count -lt 1) {
            continue
        }

        $code = $parsed.Fields[0]
        $text = if ($parsed.Fields.Count -gt 3) { $parsed.Fields[3] } else { '' }
        if ($code -eq '5021' -or $text -match '(?i)registration key') {
            return $true
        }
    }

    return $false
}

<#
.SYNOPSIS
    Log rip progress from PRGV lines at roughly 10% increments.

.DESCRIPTION
    PRGV lines are `current,total,max`. Logs one INFO line each time overall
    completion (current/max) crosses a new 10% decile, so a long rip doesn't
    flood the log with every PRGV tick.
#>
function Write-MakeMkvProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Lines,

        [hashtable] $Config
    )

    $lastDecile = -1

    foreach ($line in $Lines) {
        $parsed = ConvertFrom-MakeMkvRobotLine -Line $line
        if (-not $parsed -or $parsed.Prefix -ne 'PRGV' -or $parsed.Fields.Count -lt 3) {
            continue
        }

        $current = 0.0
        $max = 0.0
        if (-not [double]::TryParse($parsed.Fields[0], [ref] $current)) { continue }
        if (-not [double]::TryParse($parsed.Fields[2], [ref] $max)) { continue }
        if ($max -le 0) { continue }

        $decile = [math]::Floor(($current / $max) * 10) * 10
        if ($decile -gt $lastDecile) {
            $lastDecile = $decile
            Write-ArmLog -Level INFO -Message "Rip progress: $decile%" -Config $Config
        }
    }
}

<#
.SYNOPSIS
    Write a hand-editable metadata.json into a rip's staging output dir.

.DESCRIPTION
    Lets the user correct/fill in Title and Year while the rip is still
    running; re-read later by Resolve-TitleOverride before the destination
    folder name is finalized. Never throws - logs a WARN on failure.
#>
function Set-ArmMetadataFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $OutputDir,
        [AllowNull()] [string] $Title,
        [AllowNull()] $Year,
        [Parameter(Mandatory = $true)] [hashtable] $Config
    )

    try {
        $path = Join-Path $OutputDir 'metadata.json'
        [pscustomobject]@{
            Title = if ($Title) { $Title } else { '' }
            Year  = if ($Year) { "$Year" } else { '' }
        } | ConvertTo-Json | Set-Content -Path $path -Encoding utf8
    } catch {
        Write-ArmLog -Level WARN -Message "Failed to write metadata.json in '$OutputDir': $_" -Config $Config
    }
}

<#
.SYNOPSIS
    Rip a video disc (DVD/BD) in a drive to the staging directory via makemkvcon.

.DESCRIPTION
    1. Runs `makemkvcon -r info disc:9999`, maps the requested drive letter to a
       makemkvcon disc index via DRV: lines, and reads the disc label and type.
    2. Runs `makemkvcon -r --minlength=<N> mkv disc:<i> all <staging>\<label>\`
       (or, when `$Config.RipAllTitles` is `$false`, rips only the title with the
       longest TINFO duration).
    3. Parses robot output (MSG/PRGV/TINFO) as it streams, logging progress.
    4. Detects an expired/absent MakeMKV registration key (MSG 5021 or
       "registration key" text) and reports it as `Error = 'MAKEMKV_KEY_EXPIRED'`.

    Never throws: all failures are captured and returned in the result object so
    the disc-watcher loop can continue running.

.PARAMETER DriveLetter
    Single character drive letter (e.g., 'D').

.PARAMETER Config
    Configuration hashtable (StagingDir, MinTitleLengthSec, RipAllTitles, etc.).

.OUTPUTS
    [pscustomobject] @{ Success; DiscLabel; DiscType; OutputDir; TitleCount; Error; Resolved }
    `Resolved` is the [pscustomobject] returned by Resolve-Title, computed as
    soon as the disc label is known (before the long rip runs) and also
    written to `metadata.json` in OutputDir for the user to hand-edit.

.EXAMPLE
    $result = Invoke-VideoRip -DriveLetter 'D' -Config $config
#>
function Invoke-VideoRip {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ $_ -match '^[A-Za-z]$' })]
        [char] $DriveLetter,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $discLabel = $null
    $discType = $null
    $outputDir = $null
    $titleCount = 0
    $resolved = $null

    function ConvertTo-RipResult([bool]$Success, [string]$ErrorMessage) {
        [pscustomobject]@{
            Success    = $Success
            DiscLabel  = $discLabel
            DiscType   = $discType
            OutputDir  = $outputDir
            TitleCount = $titleCount
            Error      = $ErrorMessage
            Resolved   = $resolved
        }
    }

    try {
        $infoResult = Invoke-ArmTool -Name makemkvcon -Arguments @('-r', 'info', 'disc:9999') -Config $Config
        if ($infoResult.ExitCode -ne 0) {
            return ConvertTo-RipResult $false "makemkvcon info failed with exit code $($infoResult.ExitCode)"
        }

        $driveInfo = Get-MakeMkvDriveInfo -Lines $infoResult.StdOut -DriveLetter $DriveLetter
        if (-not $driveInfo) {
            return ConvertTo-RipResult $false "No disc detected in drive $($DriveLetter):"
        }

        $discLabel = $driveInfo.Label
        $discType = $driveInfo.DiscType
        $safeLabel = ($discLabel -replace '[\\/:*?"<>|]', '_')
        $outputDir = Join-Path $Config.StagingDir $safeLabel

        if (-not (Test-Path $outputDir)) {
            $null = New-Item -ItemType Directory -Force -Path $outputDir
        }

        $resolved = Resolve-Title -DiscLabel $discLabel -Config $Config
        Set-ArmMetadataFile -OutputDir $outputDir -Title $resolved.Title -Year $resolved.Year -Config $Config

        $ripArgs = @('-r', "--minlength=$($Config.MinTitleLengthSec)", 'mkv', "disc:$($driveInfo.Index)")
        if ($Config.RipAllTitles) {
            $ripArgs += 'all'
        } else {
            # `info disc:9999` is a drive-scan call and only emits DRV/MSG lines for
            # each drive; per-title TINFO (needed to find the longest title) only
            # comes back from a disc-specific info call.
            $discInfoResult = Invoke-ArmTool -Name makemkvcon -Arguments @('-r', 'info', "disc:$($driveInfo.Index)") -Config $Config
            $mainIndex = if ($discInfoResult.ExitCode -eq 0) {
                Get-MakeMkvLongestTitleIndex -Lines $discInfoResult.StdOut
            } else {
                $null
            }
            if ($null -eq $mainIndex) {
                $mainIndex = 0
            }
            $ripArgs += "$mainIndex"
        }
        $ripArgs += $outputDir

        $ripResult = Invoke-ArmTool -Name makemkvcon -Arguments $ripArgs -Config $Config

        if (Test-MakeMkvExpiredKey -Lines (@($ripResult.StdOut) + @($ripResult.StdErr))) {
            return ConvertTo-RipResult $false 'MAKEMKV_KEY_EXPIRED'
        }

        Write-MakeMkvProgress -Lines $ripResult.StdOut -Config $Config

        if (Test-Path $outputDir) {
            $titleCount = @(Get-ChildItem -Path $outputDir -Filter '*.mkv' -File -ErrorAction SilentlyContinue).Count
        }

        if ($ripResult.ExitCode -ne 0) {
            return ConvertTo-RipResult $false "makemkvcon rip failed with exit code $($ripResult.ExitCode)"
        }

        if ($titleCount -eq 0) {
            return ConvertTo-RipResult $false 'No MKV files produced'
        }

        return ConvertTo-RipResult $true $null

    } catch {
        Write-ArmLog -Level ERROR -Message "Invoke-VideoRip failed: $_" -Config $Config
        return ConvertTo-RipResult $false $_.Exception.Message
    }
}
