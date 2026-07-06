Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Strip characters that are invalid in a Windows file/folder name.
#>
function ConvertTo-ArmSafeFileName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Name
    )

    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $pattern = "[$([regex]::Escape($invalid))]"
    return (($Name -replace $pattern, '') -replace '\s+', ' ').Trim()
}

<#
.SYNOPSIS
    Clean a raw optical disc volume label into a search-friendly title string.

.DESCRIPTION
    - Replaces '_' and '.' separators with spaces.
    - Strips disc/disk-number tokens (DISC 1, DISK2, D1...) and season tokens.
    - Strips common edition/region/format noise (SPECIAL EDITION, WS, 16X9,
      PAL, NTSC, REMASTERED, etc.).
    - Collapses whitespace.
#>
function Get-ArmCleanDiscLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $DiscLabel
    )

    $s = $DiscLabel -replace '[_.]', ' '

    # Disc/disk/season numbering tokens.
    $s = $s -replace '(?i)\b(DISC|DISK|D)\s*\d+\b', ' '
    $s = $s -replace '(?i)\bSEASON\s*\d+\b', ' '

    # Edition / region / format noise tokens.
    $noiseTokens = @(
        "DIRECTOR'?S CUT",
        'SPECIAL EDITION',
        'EXTENDED EDITION',
        'UNRATED EDITION',
        'ANNIVERSARY EDITION',
        "COLLECTOR'?S EDITION",
        'THEATRICAL CUT',
        'THEATRICAL',
        'UNRATED',
        'REMASTERED',
        'WIDESCREEN',
        'FULLSCREEN',
        '16X9',
        '4X3',
        '\bWS\b',
        '\bFS\b',
        '\bPAL\b',
        '\bNTSC\b',
        'REGION\s*\d',
        'RETAIL',
        'BLU\s*RAY',
        'BD25',
        'BD50',
        'BD9',
        'DTS(?:-?HD)?(?:\s*MA)?',
        'DOLBY',
        'ATMOS',
        'TRUEHD',
        '\bAC3\b',
        '\bDD\s*5\s*1\b',
        '\bDD\s*7\s*1\b'
    )
    foreach ($token in $noiseTokens) {
        $s = $s -replace "(?i)$token", ' '
    }

    return ($s -replace '\s+', ' ').Trim()
}

<#
.SYNOPSIS
    Title-case a cleaned label for display and search (e.g., "star wars" => "Star Wars").
#>
function ConvertTo-ArmTitleCase {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Text
    )

    if (-not $Text) {
        return $Text
    }
    return (Get-Culture).TextInfo.ToTitleCase($Text.ToLower())
}

<#
.SYNOPSIS
    Query the TMDb movie search endpoint.

.OUTPUTS
    [pscustomobject] parsed JSON response (has a `.results` array).
#>
function Invoke-ArmTmdbSearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Query,

        [Parameter(Mandatory = $true)]
        [string] $ApiKey
    )

    $uri = "https://api.themoviedb.org/3/search/movie?api_key=$ApiKey&query=$([uri]::EscapeDataString($Query))"
    return Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 10
}

<#
.SYNOPSIS
    Decide whether the top TMDb search result should be accepted as a match.

.DESCRIPTION
    Accepts when there is exactly one result, or when the top result's
    popularity is at least double the second result's popularity.
#>
function Test-ArmTmdbAcceptance {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array] $Results
    )

    if ($Results.Count -eq 1) {
        return $true
    }
    if ($Results.Count -lt 2) {
        return $false
    }

    $sorted = $Results | Sort-Object -Property popularity -Descending
    $top = [double]$sorted[0].popularity
    $second = [double]$sorted[1].popularity

    if ($second -le 0) {
        return $true
    }
    return ($top -ge (2 * $second))
}

<#
.SYNOPSIS
    Resolve a disc's display title/year via TMDb, falling back to a cleaned-label name.

.DESCRIPTION
    Cleans the raw disc label (separators, disc/season tokens, edition/region/
    format noise), then, if `$Config.TmdbApiKey` is set, searches
    `/3/search/movie`. The top hit is accepted when it is the only result or its
    popularity is at least 2x the runner-up's. On acceptance, returns folder name
    "Title (Year)" (invalid filename characters stripped).

    When no API key is configured, TMDb returns no acceptable match, or the HTTP
    call fails, falls back to "<CLEANLABEL>_<yyyy-MM-dd>" with `Matched = $false`.
    Never throws.

.PARAMETER DiscLabel
    Raw disc volume label (e.g., "STAR_WARS_ANH_DISC1").

.PARAMETER Config
    Configuration hashtable (TmdbApiKey).

.OUTPUTS
    [pscustomobject] @{ FolderName; Matched; Title; Year }

.EXAMPLE
    $result = Resolve-Title -DiscLabel 'STAR_WARS_ANH' -Config $config
#>
function Resolve-Title {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DiscLabel,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    try {
        $cleanLabel = Get-ArmCleanDiscLabel -DiscLabel $DiscLabel
        $titleCaseLabel = ConvertTo-ArmTitleCase -Text $cleanLabel
        $fallbackBase = ConvertTo-ArmSafeFileName -Name $titleCaseLabel
        if (-not $fallbackBase) {
            $fallbackBase = 'Unknown Title'
        }
        $fallbackName = "$($fallbackBase)_$(Get-Date -Format 'yyyy-MM-dd')"

        if (-not $Config.TmdbApiKey) {
            return [pscustomobject]@{ FolderName = $fallbackName; Matched = $false; Title = $null; Year = $null }
        }

        try {
            $response = Invoke-ArmTmdbSearch -Query $titleCaseLabel -ApiKey $Config.TmdbApiKey
        } catch {
            Write-ArmLog -Level WARN -Message "TMDb lookup failed for '$titleCaseLabel': $_" -Config $Config
            return [pscustomobject]@{ FolderName = $fallbackName; Matched = $false; Title = $null; Year = $null }
        }

        $results = @($response.results)
        if ($results.Count -eq 0 -or -not (Test-ArmTmdbAcceptance -Results $results)) {
            return [pscustomobject]@{ FolderName = $fallbackName; Matched = $false; Title = $null; Year = $null }
        }

        $top = ($results | Sort-Object -Property popularity -Descending)[0]
        $title = $top.title
        $year = $null
        if ($top.release_date) {
            try { $year = ([datetime]$top.release_date).Year } catch { $year = $null }
        }

        $folderRaw = if ($year) { "$title ($year)" } else { $title }
        $folderName = ConvertTo-ArmSafeFileName -Name $folderRaw

        return [pscustomobject]@{ FolderName = $folderName; Matched = $true; Title = $title; Year = $year }

    } catch {
        Write-ArmLog -Level WARN -Message "Resolve-Title failed for '$DiscLabel': $_" -Config $Config
        $safeLabel = ($DiscLabel -replace '[\\/:*?"<>|_.]', ' ') -replace '\s+', ' '
        $safeLabel = $safeLabel.Trim()
        if (-not $safeLabel) { $safeLabel = 'Unknown Title' }
        return [pscustomobject]@{
            FolderName = "$($safeLabel)_$(Get-Date -Format 'yyyy-MM-dd')"
            Matched    = $false
            Title      = $null
            Year       = $null
        }
    }
}

<#
.SYNOPSIS
    Re-read a rip's metadata.json for a user-supplied Title/Year override.

.DESCRIPTION
    Called immediately before the staging dir is renamed for the NAS move.
    If metadata.json is missing, unreadable, malformed, not a JSON object, or
    has a blank/whitespace-only Title, returns $FallbackResolved unchanged
    (the original Resolve-Title result from before the rip). Otherwise builds
    a "Title (Year)" folder name (or just "Title" if Year is blank) from the
    override, sanitized the same way Resolve-Title sanitizes its own matches.

    Never throws. Property access uses PSObject.Properties.Match(...) rather
    than direct dot-access so a missing key (e.g. the user deletes the Year
    line) doesn't throw under Set-StrictMode and discard a valid Title edit.

.PARAMETER OutputDir
    The rip's staging output directory (same one metadata.json was written to).

.PARAMETER FallbackResolved
    The [pscustomobject] from Resolve-Title, computed before the rip started.

.PARAMETER Config
    Configuration hashtable (used for logging only).

.OUTPUTS
    [pscustomobject] @{ FolderName; Matched; Title; Year }

.EXAMPLE
    $resolved = Resolve-TitleOverride -OutputDir $ripResult.OutputDir -FallbackResolved $ripResult.Resolved -Config $config
#>
function Resolve-TitleOverride {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $OutputDir,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [pscustomobject] $FallbackResolved,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    try {
        $path = Join-Path $OutputDir 'metadata.json'
        if (-not (Test-Path $path)) {
            return $FallbackResolved
        }

        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json

        $titleProp = @($json.PSObject.Properties.Match('Title'))
        $title = if ($titleProp.Count -gt 0) { "$($titleProp[0].Value)" } else { '' }
        $title = $title.Trim()

        if (-not $title) {
            return $FallbackResolved
        }

        $yearProp = @($json.PSObject.Properties.Match('Year'))
        $year = if ($yearProp.Count -gt 0) { "$($yearProp[0].Value)" } else { '' }
        $year = $year.Trim()

        $folderRaw = if ($year) { "$title ($year)" } else { $title }
        $folderName = ConvertTo-ArmSafeFileName -Name $folderRaw

        return [pscustomobject]@{
            FolderName = $folderName
            Matched    = $true
            Title      = $title
            Year       = if ($year) { $year } else { $null }
        }

    } catch {
        Write-ArmLog -Level WARN -Message "Failed to read metadata.json override in '$OutputDir': $_" -Config $Config
        return $FallbackResolved
    }
}
