Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    Ask a local OpenAI-compatible LLM to disambiguate a set of TMDb candidates
    that were too close in popularity for Test-ArmTmdbAcceptance to accept.

.DESCRIPTION
    POSTs disc label + candidate list (title/year/overview/popularity) to
    "$($Config.LlmEndpoint)/chat/completions" and asks for a JSON object
    `{"index": N}` (N = position in $Candidates) or `{"index": null}` when
    none of the candidates plausibly match.

    Never throws. Any failure (HTTP error/timeout, malformed response, no
    JSON object in the reply, an out-of-range or non-integer index) is caught
    and logged at WARN, returning SelectedIndex = $null so the caller falls
    back to today's date-naming behavior. This validates the model's answer
    against the real candidate list - the model can only pick a position in
    the array it was given, never invent a title/ID of its own.

.PARAMETER DiscLabel
    Title-cased, cleaned disc label used as the disambiguation query context.

.PARAMETER Candidates
    Array of TMDb result objects (title/release_date/popularity), in the
    order they should be presented/indexed.

.PARAMETER Config
    Configuration hashtable (LlmEndpoint, LlmModel, LlmTimeoutSec).

.OUTPUTS
    [pscustomobject] @{ SelectedIndex = [int]$null or a valid index into $Candidates }

.EXAMPLE
    $llmResult = Invoke-ArmLlmDisambiguation -DiscLabel 'Alpha' -Candidates $sorted -Config $config
#>
function Invoke-ArmLlmDisambiguation {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DiscLabel,

        [Parameter(Mandatory = $true)]
        [array] $Candidates,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    try {
        $candidateLines = for ($i = 0; $i -lt $Candidates.Count; $i++) {
            $c = $Candidates[$i]
            $year = $null
            if ($c.release_date) {
                try { $year = ([datetime]$c.release_date).Year } catch { $year = $null }
            }
            $overviewProp = $c.PSObject.Properties['overview']
            [pscustomobject]@{
                index      = $i
                title      = $c.title
                year       = $year
                popularity = $c.popularity
                overview   = if ($overviewProp) { $overviewProp.Value } else { $null }
            }
        }

        $prompt = @"
Disc label: "$DiscLabel"

Candidate movies (JSON array, "index" is the only valid identifier to answer with):
$($candidateLines | ConvertTo-Json -Compress)

Pick the single candidate that best matches the disc label. Respond with ONLY a
JSON object: {"index": <candidate index>} or {"index": null} if none plausibly match.
"@

        $body = @{
            model       = $Config.LlmModel
            temperature = 0
            messages    = @(
                @{ role = 'system'; content = 'You disambiguate movie titles from a fixed candidate list. Reply with only a JSON object.' }
                @{ role = 'user'; content = $prompt }
            )
        } | ConvertTo-Json -Depth 6

        $timeoutSec = if ($Config.ContainsKey('LlmTimeoutSec') -and $Config.LlmTimeoutSec) { $Config.LlmTimeoutSec } else { 15 }
        $uri = "$($Config.LlmEndpoint.TrimEnd('/'))/chat/completions"

        $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body $body -TimeoutSec $timeoutSec

        $content = $response.choices[0].message.content
        if (-not $content) {
            throw 'LLM response had no message content'
        }

        $jsonMatch = [regex]::Match($content, '(?s)\{.*\}')
        if (-not $jsonMatch.Success) {
            throw "LLM response contained no JSON object: $content"
        }

        $parsed = $jsonMatch.Value | ConvertFrom-Json
        $indexProp = $parsed.PSObject.Properties['index']
        if (-not $indexProp -or $null -eq $indexProp.Value) {
            return [pscustomobject]@{ SelectedIndex = $null }
        }

        $index = 0
        if (-not [int]::TryParse("$($indexProp.Value)", [ref]$index)) {
            throw "LLM returned a non-integer index: $($indexProp.Value)"
        }
        if ($index -lt 0 -or $index -ge $Candidates.Count) {
            throw "LLM returned an out-of-range index: $index (candidate count $($Candidates.Count))"
        }

        return [pscustomobject]@{ SelectedIndex = $index }

    } catch {
        Write-ArmLog -Level WARN -Message "LLM disambiguation failed/declined for '$DiscLabel': $_" -Config $Config
        return [pscustomobject]@{ SelectedIndex = $null }
    }
}

<#
.SYNOPSIS
    Build a sanitized "Title (Year)" (or just "Title" when Year is blank)
    folder name, shared by Resolve-Title and Resolve-TitleOverride.
#>
function ConvertTo-ArmFolderName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Title,

        [AllowNull()]
        $Year
    )

    $folderRaw = if ($Year) { "$Title ($Year)" } else { $Title }
    return ConvertTo-ArmSafeFileName -Name $folderRaw
}

<#
.SYNOPSIS
    Resolve a disc's display title/year via TMDb, falling back to a cleaned-label name.

.DESCRIPTION
    Cleans the raw disc label (separators, disc/season tokens, edition/region/
    format noise), then, if `$Config.TmdbApiKey` is set, searches
    `/3/search/movie`. If the full cleaned label returns zero results (leftover
    disc-authoring junk the noise-token list doesn't know about), retries with
    the last word dropped, up to 3 times or down to a single remaining word;
    ambiguous (non-zero but rejected) results do not trigger a retry, since
    dropping tokens only broadens an already-ambiguous field. The top hit from
    whichever query returned results is accepted when it is the only result or
    its popularity is at least 2x the runner-up's. On acceptance, returns
    folder name "Title (Year)" (invalid filename characters stripped).

    When `$Config.LlmDisambiguationEnabled` is set, every non-empty TMDb result
    set (not just ambiguous ones) is additionally validated by a local
    OpenAI-compatible LLM (`Invoke-ArmLlmDisambiguation`, POSTing to
    `$Config.LlmEndpoint`) with the disc label and the candidate list
    (title/year/overview/popularity). The model's answer is validated as an
    index into the real candidate array - it can never introduce a title TMDb
    didn't return - and, when it gives one, always wins: this catches cases
    where TMDb's popularity-based acceptance is confidently wrong (e.g. a bare
    franchise label like "TOY_STORY" matching a hyped upcoming sequel instead of
    the original) as well as the original "too close to call" ambiguous case.
    When the LLM is unavailable, times out, or declines, behavior degrades to
    exactly what TMDb alone would have produced: the top hit if TMDb's own
    accept rule was satisfied, or date-naming fallback if not. Off by default,
    so existing installs are unaffected.

    When no API key is configured, TMDb returns no acceptable match, or the HTTP
    call fails, falls back to "<CLEANLABEL>_<yyyy-MM-dd>" with `Matched = $false`.
    Never throws.

.PARAMETER DiscLabel
    Raw disc volume label (e.g., "STAR_WARS_ANH_DISC1").

.PARAMETER Config
    Configuration hashtable (TmdbApiKey, LlmDisambiguationEnabled, LlmEndpoint,
    LlmModel, LlmTimeoutSec).

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
            Write-ArmLog -Level WARN -Message "No TmdbApiKey configured; using label+date naming for '$titleCaseLabel'" -Config $Config
            return [pscustomobject]@{ FolderName = $fallbackName; Matched = $false; Title = $null; Year = $null }
        }

        # Query TMDb with the full cleaned label; if that returns zero results (not
        # ambiguous results - those go straight to the fallback below, since dropping
        # tokens only broadens an already-ambiguous field), retry with the last word
        # dropped, up to $maxTruncations times or down to a single remaining word.
        # Leftover disc-authoring tokens the noise list doesn't know about (e.g. an
        # unexplained "PS AC" suffix) are the main thing this recovers from.
        $maxTruncations = 3
        $queryTokens = @($titleCaseLabel -split '\s+' | Where-Object { $_ })
        $truncations = 0
        $results = @()
        $queryUsed = $titleCaseLabel

        while ($true) {
            $queryUsed = ($queryTokens -join ' ')
            try {
                $response = Invoke-ArmTmdbSearch -Query $queryUsed -ApiKey $Config.TmdbApiKey
            } catch {
                Write-ArmLog -Level WARN -Message "TMDb lookup failed for '$queryUsed': $_" -Config $Config
                return [pscustomobject]@{ FolderName = $fallbackName; Matched = $false; Title = $null; Year = $null }
            }

            $results = @($response.results)
            if ($results.Count -gt 0) { break }
            if ($truncations -ge $maxTruncations -or $queryTokens.Count -le 1) { break }

            $truncations++
            $queryTokens = $queryTokens[0..($queryTokens.Count - 2)]
            Write-ArmLog -Level WARN -Message "No TMDb results for '$queryUsed'; retrying with truncated query '$($queryTokens -join ' ')' (attempt $truncations/$maxTruncations)" -Config $Config
        }

        if ($results.Count -eq 0) {
            return [pscustomobject]@{ FolderName = $fallbackName; Matched = $false; Title = $null; Year = $null }
        }

        $sortedResults = $results | Sort-Object -Property popularity -Descending
        $accepted = Test-ArmTmdbAcceptance -Results $results

        # When enabled, the LLM validates every non-empty result set - not just
        # ambiguous ones - since a confidently-"accepted" top hit can still be
        # wrong (e.g. TMDb popularity favors a hyped recent sequel over the
        # original for a bare franchise label like "TOY_STORY"). The LLM's
        # answer wins whenever it gives one, valid or not it never invents a
        # title outside $sortedResults (see Invoke-ArmLlmDisambiguation). If it
        # declines/is unavailable, behavior degrades to exactly what TMDb alone
        # would have produced (accept top hit, or fall back if TMDb rejected it).
        if ($Config.ContainsKey('LlmDisambiguationEnabled') -and $Config.LlmDisambiguationEnabled) {
            $llmResult = Invoke-ArmLlmDisambiguation -DiscLabel $titleCaseLabel -Candidates $sortedResults -Config $Config

            if ($null -ne $llmResult.SelectedIndex) {
                $chosen = $sortedResults[$llmResult.SelectedIndex]
                $llmTitle = $chosen.title
                $llmYear = $null
                if ($chosen.release_date) {
                    try { $llmYear = ([datetime]$chosen.release_date).Year } catch { $llmYear = $null }
                }

                if ($accepted -and $llmResult.SelectedIndex -eq 0) {
                    Write-ArmLog -Level INFO -Message "Matched '$llmTitle' via TMDb, confirmed by LLM validation ('$titleCaseLabel')" -Config $Config
                } elseif ($accepted) {
                    Write-ArmLog -Level WARN -Message "LLM validation overrode TMDb's top hit for '$titleCaseLabel': TMDb picked '$($sortedResults[0].title)', LLM picked '$llmTitle'" -Config $Config
                } else {
                    Write-ArmLog -Level WARN -Message "Matched '$llmTitle' via LLM disambiguation for ambiguous TMDb results ('$titleCaseLabel')" -Config $Config
                }

                $llmFolderName = ConvertTo-ArmFolderName -Title $llmTitle -Year $llmYear
                return [pscustomobject]@{ FolderName = $llmFolderName; Matched = $true; Title = $llmTitle; Year = $llmYear }
            }

            if (-not $accepted) {
                Write-ArmLog -Level WARN -Message "LLM disambiguation declined/unavailable for '$titleCaseLabel'; using label+date naming" -Config $Config
                return [pscustomobject]@{ FolderName = $fallbackName; Matched = $false; Title = $null; Year = $null }
            }
            Write-ArmLog -Level WARN -Message "LLM validation declined/unavailable for '$titleCaseLabel'; using TMDb's top hit" -Config $Config
        } elseif (-not $accepted) {
            return [pscustomobject]@{ FolderName = $fallbackName; Matched = $false; Title = $null; Year = $null }
        }

        $top = $sortedResults[0]
        $title = $top.title
        $year = $null
        if ($top.release_date) {
            try { $year = ([datetime]$top.release_date).Year } catch { $year = $null }
        }

        if ($queryUsed -ne $titleCaseLabel) {
            Write-ArmLog -Level WARN -Message "Matched '$title' via truncated query '$queryUsed' (original label '$titleCaseLabel')" -Config $Config
        }

        $folderName = ConvertTo-ArmFolderName -Title $title -Year $year

        return [pscustomobject]@{ FolderName = $folderName; Matched = $true; Title = $title; Year = $year }

    } catch {
        Write-ArmLog -Level WARN -Message "Resolve-Title failed for '$DiscLabel': $_" -Config $Config
        $safeLabel = ConvertTo-ArmSafeFileName -Name $DiscLabel
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

    Never throws. Property access uses the PSObject.Properties[...] indexer
    rather than direct dot-access so a missing key (e.g. the user deletes the
    Year line) doesn't throw under Set-StrictMode and discard a valid Title
    edit.

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
        if (-not (Test-Path -LiteralPath $path)) {
            return $FallbackResolved
        }

        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json

        $titleProp = $json.PSObject.Properties['Title']
        $title = if ($titleProp) { "$($titleProp.Value)" } else { '' }
        $title = $title.Trim()

        if (-not $title) {
            return $FallbackResolved
        }

        $yearProp = $json.PSObject.Properties['Year']
        $year = if ($yearProp) { "$($yearProp.Value)" } else { '' }
        $year = $year.Trim()

        $folderName = ConvertTo-ArmFolderName -Title $title -Year $year

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
