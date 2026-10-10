Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Classify the interlace type of a video file using ffmpeg's idet filter.

.DESCRIPTION
    Probes one or more mid-feature windows via Invoke-ArmTool
    (`ffmpeg -hide_banner -ss <start> -i <file> -filter:v idet -frames:v 1000 -an -f null -`),
    parses the two summary lines idet writes to stderr, SUMS the counts across the
    windows, then classifies. ffmpeg 8.x prints the whole summary twice (an all-zero
    one from a throw-away probe graph, then the real one); the LAST occurrence of each
    line per window is used (issue #30):

        Repeated Fields: Neither: <n> Top: <n> Bottom: <n>
        Multi frame detection: TFF: <n> BFF: <n> Progressive: <n> Undetermined: <n>

    Probe windows (default, no -Seek): 600 s and 50% of -SourceDuration (the duration
    Get-VideoSourceInfo already measured; no re-probe here), 1000 frames each, so the
    studio logos / opening credits at 0:00 do not decide the class. A window at or past
    the end of a known-length file is skipped (or yields zero counts); if no window
    produced parseable counts the probe falls back to 0:00. An explicit -Seek probes
    just that window (same 0:00 fallback).

    Classification (in order, first match wins), measured on 18 real DVD rips:
      1. Progressive  - Multi frame detection Progressive share >= 0.5 of the total
                         (TFF+BFF+Progressive+Undetermined). Film/progressive video reads
                         80.9-100%; interlaced and hard-telecined read 0-1.5%.
      2. Telecined    - Repeated Fields (Top+Bottom) > 15% of the Repeated Fields total
                         (Neither+Top+Bottom): the 3:2 pulldown cadence signature.
      3. Interlaced   - Anything else (counts parsed, no cadence).
      -  Unknown      - No counts could be parsed in any window: a WARN with the truncated
                         raw output is logged. Get-UpscalePlan maps it to the blanket
                         `bwdif=mode=send_frame` (the pre-#30 guaranteed behaviour).
    The parsed counts are logged at INFO for every classification. Whether a Telecined
    verdict is safe at the source's decoded frame rate is Get-UpscalePlan's call
    (soft-telecine guard).

.PARAMETER InputFile
    Path to the source video file.

.PARAMETER Config
    Configuration hashtable, passed through to Invoke-ArmTool.

.PARAMETER SourceDuration
    Source duration in seconds (Get-VideoSourceInfo.DurationSec). Enables the
    50%-of-duration window; 0 / unknown probes the 600 s window only.

.PARAMETER Seek
    Optional explicit single window start in seconds (`-ss <Seek>` before `-i`),
    replacing the default windows. Default -1 = use the default windows.

.PARAMETER Duration
    Optional length of each probe window in seconds (`-t <Duration>`). Default 0 =
    no time limit beyond the 1000-frame cap.

.OUTPUTS
    [string] One of 'Telecined', 'Interlaced', 'Progressive', 'Unknown'.

.EXAMPLE
    $type = Get-InterlaceType -InputFile 'C:\rips\staging\movie.mkv' -Config $config -SourceDuration 7200
#>
# Probe-window starts shared by Get-InterlaceType and Invoke-Upscale's per-window frame-rate
# measurement (soft-telecine guard): explicit -Seek, else 600 s and floor(50% of the known
# duration). Starts at or past the end of a known-length file are skipped.
function Get-InterlaceProbeStart {
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [double] $SourceDuration = 0,
        [int] $Seek = -1
    )
    $candidates = @(if ($Seek -ge 0) { $Seek } else { 600 })
    if ($Seek -lt 0 -and $SourceDuration -gt 0) { $candidates += [int][math]::Floor($SourceDuration * 0.5) }
    return [int[]]@($candidates | Select-Object -Unique | Where-Object { $SourceDuration -le 0 -or $_ -lt $SourceDuration })
}

# One idet window: runs ffmpeg and returns the LAST summary's counts (ffmpeg 8.x prints it
# twice, the first all-zero) plus the raw text. Parsed = $false when no non-zero multi-frame
# counts were found. Private to Get-InterlaceType.
function Get-IdetWindowCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $InputFile,
        [Parameter(Mandatory = $true)] [hashtable] $Config,
        [Parameter(Mandatory = $true)] [int] $Start,
        [int] $Duration = 0,
        [int] $FrameCap = 1000
    )
    $window = @('-ss', "$Start")
    if ($Duration -gt 0) { $window += @('-t', "$Duration") }
    # The idet summary prints at info level, so this probe keeps ffmpeg's default loglevel;
    # its stderr (input/stream/chapter dump included) is data, not log material (#32).
    $result = Invoke-ArmTool -Name ffmpeg -Config $Config -StdErrLevel None -Arguments (@('-hide_banner') + @($window) + @(
        '-i', $InputFile,
        '-filter:v', 'idet',
        '-frames:v', "$FrameCap",
        '-an',
        '-f', 'null',
        '-'
    ))
    $text = (@($result.StdErr) -join "`n")
    $counts = [pscustomobject]@{ Parsed = $false; Start = $Start; Raw = $text
        Tff = 0L; Bff = 0L; Prog = 0L; Und = 0L; Neither = 0L; Top = 0L; Bottom = 0L }

    $multi = [regex]::Matches($text,
        'Multi frame detection:\s*TFF:\s*(\d+)\s*BFF:\s*(\d+)\s*Progressive:\s*(\d+)\s*Undetermined:\s*(\d+)')
    if ($multi.Count -eq 0) { return $counts }
    $g = $multi[$multi.Count - 1].Groups
    $counts.Tff = [long]$g[1].Value; $counts.Bff = [long]$g[2].Value
    $counts.Prog = [long]$g[3].Value; $counts.Und = [long]$g[4].Value
    if (($counts.Tff + $counts.Bff + $counts.Prog + $counts.Und) -le 0) { return $counts }
    $counts.Parsed = $true

    $rep = [regex]::Matches($text, 'Repeated Fields:\s*Neither:\s*(\d+)\s*Top:\s*(\d+)\s*Bottom:\s*(\d+)')
    if ($rep.Count -gt 0) {
        $r = $rep[$rep.Count - 1].Groups
        $counts.Neither = [long]$r[1].Value; $counts.Top = [long]$r[2].Value; $counts.Bottom = [long]$r[3].Value
    }
    return $counts
}

function Get-InterlaceType {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $InputFile,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config,

        [double] $SourceDuration = 0,

        [int] $Seek = -1,

        [int] $Duration = 0
    )

    $starts = @(Get-InterlaceProbeStart -SourceDuration $SourceDuration -Seek $Seek)
    $windows = [System.Collections.Generic.List[object]]::new()
    foreach ($start in $starts) {
        $windows.Add((Get-IdetWindowCount -InputFile $InputFile -Config $Config -Start $start -Duration $Duration))
    }
    # Short file / nothing parsed: fall back to the start of the file.
    if (@($windows | Where-Object { $_.Parsed }).Count -eq 0 -and $starts -notcontains 0) {
        $windows.Add((Get-IdetWindowCount -InputFile $InputFile -Config $Config -Start 0 -Duration $Duration))
    }

    $used = @($windows | Where-Object { $_.Parsed })
    $sum = @{ Tff = 0L; Bff = 0L; Prog = 0L; Und = 0L; Neither = 0L; Top = 0L; Bottom = 0L }
    foreach ($w in $used) { foreach ($k in @($sum.Keys)) { $sum[$k] += $w.$k } }

    $multiTotal = $sum.Tff + $sum.Bff + $sum.Prog + $sum.Und
    $repeatTotal = $sum.Neither + $sum.Top + $sum.Bottom
    $countText = "multi TFF=$($sum.Tff) BFF=$($sum.Bff) Progressive=$($sum.Prog) Undetermined=$($sum.Und); repeated Neither=$($sum.Neither) Top=$($sum.Top) Bottom=$($sum.Bottom); windows=[$(($used | ForEach-Object { $_.Start }) -join ',')]"

    $label = 'Interlaced'
    if ($multiTotal -le 0) {
        $label = 'Unknown'
        $raw = ((@($windows | ForEach-Object { $_.Raw }) -join ' ') -replace '\s+', ' ').Trim()
        if ($raw.Length -gt 300) { $raw = $raw.Substring(0, 300) + '...' }
        Write-ArmLog -Level WARN -Message "Get-InterlaceType: could not parse idet output (missing or all-zero counts) for $InputFile; returning Unknown (blanket bwdif). Raw output: $raw" -Config $Config
    } elseif (($sum.Prog / $multiTotal) -ge 0.5) {
        $label = 'Progressive'
    } elseif ($repeatTotal -gt 0 -and (($sum.Top + $sum.Bottom) / $repeatTotal) -gt 0.15) {
        $label = 'Telecined'
    }

    Write-ArmLog -Level INFO -Message "Get-InterlaceType: $InputFile idet $countText -> $label" -Config $Config
    return $label
}

# Hashtable lookup that is safe under StrictMode: returns $Default when the key is
# absent or blank (configs written before a key existed won't contain it).
function Get-UpscaleSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [hashtable] $Config,
        [Parameter(Mandatory = $true)] [string] $Name,
        $Default = $null
    )
    if ($Config.ContainsKey($Name) -and $null -ne $Config[$Name] -and "$($Config[$Name])" -ne '') {
        return $Config[$Name]
    }
    return $Default
}

# Property lookup that is safe under StrictMode for objects parsed from JSON: returns
# $null when the property is absent. ffprobe reports unknown tags as 'unknown' / 'N/A';
# those are treated as absent too.
function Get-ProbeValue {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property) { return $null }
    $value = $property.Value
    if ($value -is [string] -and $value -in @('', 'unknown', 'N/A')) { return $null }
    return $value
}

# Parse 'n:d' (or 'n/d') into @{ Num; Den }; $null unless both parts are positive.
function ConvertFrom-ProbeRatio {
    param($Text)
    if ($null -eq $Text) { return $null }
    $m = [regex]::Match("$Text", '^\s*(\d+)\s*[:/]\s*(\d+)\s*$')
    if (-not $m.Success) { return $null }
    $num = [double]$m.Groups[1].Value
    $den = [double]$m.Groups[2].Value
    if ($num -le 0 -or $den -le 0) { return $null }
    return @{ Num = $num; Den = $den }
}

<#
.SYNOPSIS
    Turn ffprobe JSON into the source-info object. Pure: no I/O, never throws.

.DESCRIPTION
    Parser behind Get-VideoSourceInfo (see there for the object's fields). Takes the
    text of `ffprobe -of json` output for streams + format. The display aspect ratio
    is derived in this order, first usable wins:
      1. sample_aspect_ratio x frame size   ('sar')
      2. display_aspect_ratio               ('dar')
      3. frame size                         ('frame-size')
      4. 16:9 with a warning                ('assumed')
    which is the same fallback chain the old ffmpeg-banner parse used (stream DAR,
    then frame-size ratio, then 16:9 with a WARN).

.PARAMETER Json
    ffprobe JSON text. Empty or malformed text yields Success=$false and the 16:9 fallback.

.PARAMETER InputFile
    Only used to name the file in warnings.

.OUTPUTS
    [pscustomobject]
#>
function ConvertTo-VideoSourceInfo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Json,

        [string] $InputFile = ''
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $label = if ($InputFile) { $InputFile } else { 'the source' }
    $success = $false
    $errorText = $null
    $video = $null
    $doc = $null
    $audioCount = 0

    try {
        if ([string]::IsNullOrWhiteSpace($Json)) { throw 'no ffprobe output' }
        $doc = $Json | ConvertFrom-Json -ErrorAction Stop
        $streams = @(Get-ProbeValue $doc 'streams')
        foreach ($stream in $streams) {
            $type = Get-ProbeValue $stream 'codec_type'
            if ($type -eq 'audio') { $audioCount++ }
            if ($type -eq 'video' -and $null -eq $video) { $video = $stream }
        }
        if ($null -eq $video) { throw 'ffprobe reported no video stream' }
        $success = $true
    } catch {
        $errorText = "$_"
    }

    $width = $null
    $height = $null
    $sarText = $null
    $darText = $null
    $frameRate = $null
    if ($video) {
        $w = Get-ProbeValue $video 'width'
        $h = Get-ProbeValue $video 'height'
        if ($w -and [int]$w -gt 0) { $width = [int]$w }
        if ($h -and [int]$h -gt 0) { $height = [int]$h }
        $sarText = Get-ProbeValue $video 'sample_aspect_ratio'
        $darText = Get-ProbeValue $video 'display_aspect_ratio'
        # r_frame_rate is the container/stream header rate (what soft-telecined rips
        # get wrong); avg_frame_rate is the fallback when r_ is absent.
        foreach ($name in 'r_frame_rate', 'avg_frame_rate') {
            $candidate = Get-ProbeValue $video $name
            if (ConvertFrom-ProbeRatio $candidate) { $frameRate = "$candidate"; break }
        }
    }

    $sar = ConvertFrom-ProbeRatio $sarText
    $dar = ConvertFrom-ProbeRatio $darText
    $displayAspect = $null
    $displayAspectSource = 'assumed'
    if ($sar -and $width -and $height) {
        $displayAspect = ($width * $sar.Num) / ($height * $sar.Den)
        $displayAspectSource = 'sar'
    } elseif ($dar) {
        $displayAspect = $dar.Num / $dar.Den
        $displayAspectSource = 'dar'
    } elseif ($width -and $height) {
        $displayAspect = [double]$width / [double]$height
        $displayAspectSource = 'frame-size'
    } else {
        $displayAspect = 16.0 / 9.0
        $warnings.Add("could not determine the aspect ratio of $label; assuming 16:9")
    }

    $duration = $null
    $format = Get-ProbeValue $doc 'format'
    $durationText = Get-ProbeValue $format 'duration'
    $parsed = 0.0
    if ($null -ne $durationText -and [double]::TryParse("$durationText", [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -gt 0) {
        $duration = $parsed
    }

    return [pscustomobject][ordered]@{
        Success             = $success
        Error               = $errorText
        Width               = $width
        Height              = $height
        SampleAspectRatio   = if ($sar) { "$sarText" } else { $null }
        DisplayAspectRatio  = if ($dar) { "$darText" } else { $null }
        DisplayAspect       = [double]$displayAspect
        DisplayAspectSource = $displayAspectSource
        PixelFormat         = Get-ProbeValue $video 'pix_fmt'
        ColorSpace          = Get-ProbeValue $video 'color_space'
        ColorPrimaries      = Get-ProbeValue $video 'color_primaries'
        ColorTransfer       = Get-ProbeValue $video 'color_transfer'
        ColorRange          = Get-ProbeValue $video 'color_range'
        FieldOrder          = Get-ProbeValue $video 'field_order'
        FrameRate           = $frameRate
        DurationSec         = $duration
        AudioStreamCount    = $audioCount
        Warnings            = @($warnings)
    }
}

<#
.SYNOPSIS
    Probe a video file once with ffprobe and return everything the upscale plan needs.

.DESCRIPTION
    Runs `ffprobe -v error -show_entries stream=...:format=duration -of json` through
    Invoke-ArmTool and parses it with ConvertTo-VideoSourceInfo. Always reads the
    SOURCE file (not the preprocessed intermediate), so it keeps working when the
    intermediate goes away (#28). Never throws: a failed probe returns Success=$false
    with the same fallbacks the old banner parse used (16:9 display aspect, logged as a
    WARN), and every other field $null / 0.

    Returned fields:
      Success, Error
      Width, Height                       frame size ($null if unknown)
      SampleAspectRatio, DisplayAspectRatio   'n:d' strings as ffprobe printed them
      DisplayAspect                       [double] display aspect ratio (width/height),
                                          never $null (see ConvertTo-VideoSourceInfo)
      DisplayAspectSource                 'sar' | 'dar' | 'frame-size' | 'assumed'
      PixelFormat, ColorSpace, ColorPrimaries, ColorTransfer, ColorRange, FieldOrder
      FrameRate                           header rate string, e.g. '30000/1001'
                                          (NOT the decoded rate: soft telecine lies)
      DurationSec                         [double] or $null
      AudioStreamCount                    [int]
      Warnings                            [string[]] already logged at WARN

.OUTPUTS
    [pscustomobject]
#>
function Get-VideoSourceInfo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $InputFile,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    try {
        $result = Invoke-ArmTool -Name ffprobe -Config $Config -Arguments @(
            '-v', 'error',
            '-show_entries', 'stream=index,codec_type,codec_name,width,height,sample_aspect_ratio,display_aspect_ratio,pix_fmt,color_space,color_primaries,color_transfer,color_range,field_order,r_frame_rate,avg_frame_rate:format=duration',
            '-of', 'json=compact=1',
            $InputFile
        )
        $info = ConvertTo-VideoSourceInfo -Json (@($result.StdOut) -join "`n") -InputFile $InputFile
        if (-not $info.Success -and $result.ExitCode -ne 0) {
            $info.Error = "ffprobe exited with code $($result.ExitCode): $($info.Error)"
        }
    } catch {
        $info = ConvertTo-VideoSourceInfo -Json '' -InputFile $InputFile
        $info.Error = "$_"
    }

    foreach ($warning in $info.Warnings) {
        Write-ArmLog -Level WARN -Message "Get-VideoSourceInfo: $warning" -Config $Config
    }
    if (-not $info.Success) {
        Write-ArmLog -Level WARN -Message "Get-VideoSourceInfo: probe of $InputFile failed ($($info.Error)); using fallbacks" -Config $Config
    }
    return $info
}

<#
.SYNOPSIS
    Measure a video's real frame rate by decoding a short window, as an ffmpeg rate string.

.DESCRIPTION
    DVD rips from MakeMKV are often soft-telecined: the container header says
    30000/1001 but the decoded frames (and their timestamps) are 23.976 fps. Tools that
    trust the header (video2x, the ncnn runner) then re-time the frames at 29.97 and
    the video plays ~25% fast against its audio. This runs
    `ffmpeg -ss <Seek> -t <Duration> -i <file> -map 0:v:0 -f null -`, takes the final
    `frame=`/`time=` progress line, and snaps frames/time to the nearest standard rate
    (within 2%). Retries from the start when the seek lands past the end of a short
    file. Returns $null when it cannot tell.

.OUTPUTS
    [string] '24000/1001', '24/1', '25/1', '30000/1001', '30/1', '50/1', '60000/1001',
    '60/1', or $null.
#>
function Get-VideoFrameRate {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $InputFile,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config,

        [int] $Seek = 600,

        [int] $Duration = 60
    )

    $candidates = @(
        @{ Rate = '24000/1001'; Value = 24000.0 / 1001 },
        @{ Rate = '24/1'; Value = 24.0 },
        @{ Rate = '25/1'; Value = 25.0 },
        @{ Rate = '30000/1001'; Value = 30000.0 / 1001 },
        @{ Rate = '30/1'; Value = 30.0 },
        @{ Rate = '50/1'; Value = 50.0 },
        @{ Rate = '60000/1001'; Value = 60000.0 / 1001 },
        @{ Rate = '60/1'; Value = 60.0 }
    )

    foreach ($start in @($Seek, 0)) {
        # Parses the stats `frame=`/`time=` lines, so keeps ffmpeg's default output; the
        # stderr is data and is not logged (#32).
        $result = Invoke-ArmTool -Name ffmpeg -Config $Config -StdErrLevel None -Arguments @(
            '-hide_banner', '-ss', "$start", '-t', "$Duration", '-i', $InputFile,
            '-map', '0:v:0', '-f', 'null', '-'
        )
        $text = (@($result.StdErr) -join "`n")
        $frames = [regex]::Matches($text, 'frame=\s*(\d+)')
        $times = [regex]::Matches($text, 'time=(\d+):(\d+):(\d+(?:\.\d+)?)')
        if ($frames.Count -eq 0 -or $times.Count -eq 0) { continue }

        $n = [double]$frames[$frames.Count - 1].Groups[1].Value
        $t = $times[$times.Count - 1].Groups
        $seconds = [int]$t[1].Value * 3600 + [int]$t[2].Value * 60 + [double]$t[3].Value
        if ($n -lt 24 -or $seconds -le 0) { continue }

        $fps = $n / $seconds
        $best = $candidates | Sort-Object { [math]::Abs($_.Value - $fps) } | Select-Object -First 1
        if ([math]::Abs($best.Value - $fps) / $best.Value -le 0.02) {
            return $best.Rate
        }
    }

    return $null
}

<#
.SYNOPSIS
    Decide the colour matrix of the engine output and whether the final encode must convert it to BT.709. Pure (#29).

.DESCRIPTION
    Every engine output is BT.601-ish for a DVD source, but the final file used to be untagged
    (players assume BT.709). Returns @{ Input; InputSpec; Convert; Warnings }:
      Input      'bt601-6-525' | 'bt601-6-625' | 'bt601-matrix-bt709-primaries' | $null
      InputSpec  colorspace-filter input options (e.g. 'iall=bt601-6-525'), or $null for tag only
      Convert    [bool]
    Rules: color_space smpte170m/bt470bg = BT.601 (525 vs 625 line variant from
    color_primaries, else from the space); bt709 = BT.709. Untagged: height < 720 is BT.601
    (<= 500 lines NTSC/525, else PAL/625); >= 720 or unknown height is BT.709.
    Tags outside smpte170m/bt470bg/bt709 add a Warning and fall back to the height rule.
    openproteus (tools/ncnn_upscale.py) re-encodes RGB to YUV with the swscale default, so its
    output is BT.601 matrix with the source's primaries whatever the source was: a BT.709 or
    untagged-HD source still converts (ispace=bt470bg, iprimaries/itrc bt709). anime4k and
    realesrgan keep the source matrix and are tag only for BT.709 sources.
#>
function Get-UpscaleColorInput {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $SourceInfo,
        [string] $Engine = ''
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $space = if ($SourceInfo.ColorSpace) { "$($SourceInfo.ColorSpace)".ToLowerInvariant() } else { '' }
    $prim = if ($SourceInfo.ColorPrimaries) { "$($SourceInfo.ColorPrimaries)".ToLowerInvariant() } else { '' }
    $height = if ($null -ne $SourceInfo.Height) { [int]$SourceInfo.Height } else { 0 }
    $known = @('smpte170m', 'bt470bg', 'bt709')

    $kind = $null   # '525' | '625' | '709'
    $unknownTag = @(@($space, $prim) | Where-Object { $_ -and $_ -notin $known })
    if ($unknownTag.Count -gt 0) {
        $warnings.Add("Get-UpscaleColorInput: unsupported colour tag '$($unknownTag -join ', ')'; deciding the matrix from the frame height ($height)")
    } elseif ($space -in @('smpte170m', 'bt470bg')) {
        $kind = if ($prim -eq 'bt470bg') { '625' } elseif ($prim -eq 'smpte170m') { '525' } elseif ($space -eq 'bt470bg') { '625' } else { '525' }
    } elseif ($space -eq 'bt709') {
        $kind = '709'
    } elseif ($space -eq '') {
        $kind = switch ($prim) { 'smpte170m' { '525' } 'bt470bg' { '625' } 'bt709' { '709' } default { $null } }
    }
    if (-not $kind) {
        $kind = if ($height -le 0 -or $height -ge 720) { '709' } elseif ($height -le 500) { '525' } else { '625' }
    }

    $matrix = $null
    $spec = $null
    if ($kind -eq '709') {
        if ($Engine -eq 'openproteus') {
            $matrix = 'bt601-matrix-bt709-primaries'
            $spec = 'ispace=bt470bg:iprimaries=bt709:itrc=bt709'
        }
    } else {
        $matrix = "bt601-6-$kind"
        $spec = "iall=$matrix"
    }
    return [pscustomobject][ordered]@{
        Input     = $matrix
        InputSpec = $spec
        Convert   = [bool]$spec
        Warnings  = @($warnings)
    }
}

<#
.SYNOPSIS
    Decide how to upscale a source: turn probe results + config into an upscale plan. Pure.

.DESCRIPTION
    No I/O and no process launches: everything it needs is passed in, so every decision
    is unit-testable. Invoke-Upscale gathers the facts (Get-VideoSourceInfo,
    Get-InterlaceType, Get-VideoFrameRate), calls this, then runs the plan's stages
    with the Get-Upscale*Arguments builders.

    Plan fields:
      InputFile, BaseName, ContentType, SampleOnly
      InterlaceType            'Telecined' | 'Interlaced' | 'Progressive' | 'Unknown' (after the
                               soft-telecine guard: Telecined + decoded 23.976 in ALL idet windows => Progressive)
      Window                   $null, or @{ Seek; Duration } (-SampleOnly: 600 / 120).
                               Applied to the preprocess input and the mux's audio input.
      Preprocess               @{ Filter; FrameRate }
                                 Filter     single -vf chain string, or $null (Progressive)
                                 FrameRate  rate for `-fps_mode cfr -r`, or $null. Set
                                            for non-Telecined sources whose decoded rate
                                            was measured (soft-telecined rips decode at
                                            23.976 under a 29.97 header).
      Engine                   'openproteus' | 'anime4k' | 'realesrgan' (as configured;
                               may be invalid - see Error)
      EngineTool               Invoke-ArmTool name for the upscale stage: 'ncnn' | 'video2x'
      EngineLabel              name used in failure messages
      Target                   @{ Width; Height; DisplayAspect } for openproteus/anime4k
                               (width = 2 * round(height * DAR / 2)); $null for realesrgan
      Upscale                  engine parameters: Model/Scale (realesrgan), Shader
                               (anime4k), Runner/ModelBase/Ffmpeg/Ffprobe/RequiredFiles
                               (openproteus)
      Encode                   @{ Codec; Crf; Preset; AudioCodec; ResetSar }
      Colour                   @{ Space; Primaries; Transfer; Range; Action } - the source's
                               colour tags; Action is 'convert-to-bt709' or 'tag-only'.
      ColorInput / ColorInputSpec / ColorConvert   from Get-UpscaleColorInput: the engine output's
                               matrix label, the colorspace input options, and whether the final
                               encode adds colorspace=all=bt709:<ColorInputSpec>:irange=tv:range=tv:dither=fsb
                               (output is always tagged BT.709 regardless)
      Source                   the Get-VideoSourceInfo object
      OutputFileName           '<basename> [AI upscale 1080p].mkv'
      Warnings                 [string[]] for the caller to log at WARN
      Error                    $null, or why the plan cannot run (unknown engine,
                               realesrgan model/scale mismatch). Validated up front so
                               a bad config fails before the slow preprocess.

.PARAMETER FrameRate
    Result of Get-VideoFrameRate ('24000/1001', ... or $null). Not used as the CFR rate for
    Telecined (decimate sets it), but a Telecined verdict at a decoded 23.976 (soft
    telecine) is downgraded to Progressive, with a warning.

.PARAMETER WindowFrameRate
    Decoded rate at each idet window. The guard downgrades only when every window decodes
    at 23.976 (a hybrid disc, soft in one window and hard in another, stays Telecined).

.OUTPUTS
    [pscustomobject]
#>
function Get-UpscalePlan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $InputFile,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $SourceInfo,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Telecined', 'Interlaced', 'Progressive', 'Unknown')]
        [string] $InterlaceType,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $FrameRate,

        # Decoded rate measured at EVERY idet window (Get-InterlaceProbeStart). Only used by
        # the soft-telecine guard; omitted => the guard falls back to -FrameRate alone.
        [AllowNull()]
        [string[]] $WindowFrameRate,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config,

        [ValidateSet('LiveAction', 'Animation')]
        [string] $ContentType = 'LiveAction',

        [switch] $SampleOnly
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $planError = $null
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)

    $window = $null
    if ($SampleOnly) {
        $window = [ordered]@{ Seek = 600; Duration = 120 }
    }

    # Soft-telecine guard (#30): a source that already DECODES at ~23.976 fps has had its
    # pulldown removed (flags only); `decimate` would drop a further 1 frame in 5 (19.2 fps)
    # and desync A/V. Never take the Telecined chain then - treat it as Progressive.
    $guardRates = @(if ($PSBoundParameters.ContainsKey('WindowFrameRate') -and $WindowFrameRate) { $WindowFrameRate } else { $FrameRate })
    if ($InterlaceType -eq 'Telecined' -and $guardRates.Count -gt 0 -and @($guardRates | Where-Object { $_ -in @('24000/1001', '24/1') }).Count -eq $guardRates.Count) {
        $warnings.Add("Invoke-Upscale: $InputFile was classified Telecined but decodes at 23.976 in every idet window ($($guardRates -join ', ')) (soft telecine); skipping IVTC/decimate and treating it as Progressive")
        $InterlaceType = 'Progressive'
    }

    # Deinterlace/IVTC chain (single field so it can move into the runner's decoder, #28).
    $filter = switch ($InterlaceType) {
        'Telecined' { 'fieldmatch,yadif=deint=interlaced,decimate' }
        'Interlaced' { 'idet,bwdif=mode=send_frame:deint=interlaced' }
        'Unknown' { 'bwdif=mode=send_frame' }
        default { $null }
    }

    # Force the intermediate to a constant frame rate that matches its timestamps.
    # Without it every downstream tool re-times soft-telecined frames at the 29.97
    # header rate (video ~25% fast, audio clipped by -shortest). Telecined sources are
    # skipped: decimate already emits the correct constant rate.
    $cfrRate = $null
    if ($InterlaceType -ne 'Telecined') {
        if ($FrameRate) {
            $cfrRate = $FrameRate
        } else {
            $warnings.Add("Invoke-Upscale: could not measure the frame rate of $InputFile; trusting the container header (video may be mistimed on soft-telecined sources)")
        }
    }

    $engine = if ($ContentType -eq 'Animation') {
        Get-UpscaleSetting -Config $Config -Name 'UpscaleAnimation' -Default 'anime4k'
    } else {
        Get-UpscaleSetting -Config $Config -Name 'UpscaleLiveAction' -Default 'openproteus'
    }

    $engineTool = $null
    $engineLabel = $null
    $target = $null
    $upscale = [ordered]@{}

    if ($engine -eq 'realesrgan') {
        # Legacy path. realesrgan-plus/-anime only ship x4 weights under video2x 6.4
        # (see SPEC.md); catch the mismatch with a clear error instead of an opaque
        # video2x CLI failure.
        if ($Config.UpscaleModel -in @('realesrgan-plus', 'realesrgan-plus-anime') -and [int]$Config.UpscaleScale -ne 4) {
            $planError = "UpscaleModel '$($Config.UpscaleModel)' only supports UpscaleScale=4, but UpscaleScale=$($Config.UpscaleScale) was configured"
        }
        $engineTool = 'video2x'
        $engineLabel = 'video2x'
        $upscale['Model'] = $Config.UpscaleModel
        $upscale['Scale'] = $Config.UpscaleScale
    } elseif ($engine -in @('openproteus', 'anime4k')) {
        # Target size from the display aspect ratio, not the frame size: DVD rips are
        # anamorphic (720x480 with SAR 853:720 is 16:9), and video2x keeps the SAR.
        $targetHeight = [int](Get-UpscaleSetting -Config $Config -Name 'UpscaleHeight' -Default 1080)
        $dar = [double]$SourceInfo.DisplayAspect
        $target = [ordered]@{
            Width         = 2 * [int][math]::Round($targetHeight * $dar / 2)
            Height        = $targetHeight
            DisplayAspect = $dar
        }
        if ($engine -eq 'openproteus') {
            $runner = Join-Path $PSScriptRoot '..' 'tools' 'ncnn_upscale.py'
            $modelBase = Join-Path (Get-UpscaleSetting -Config $Config -Name 'NcnnModelDir' -Default 'C:\ProgramData\wrm\models') 'openproteus-x2'
            $engineTool = 'ncnn'
            $engineLabel = 'ncnn upscale'
            $upscale['Runner'] = $runner
            $upscale['ModelBase'] = $modelBase
            $upscale['Ffmpeg'] = Get-UpscaleSetting -Config $Config -Name 'FfmpegPath' -Default 'ffmpeg'
            $upscale['Ffprobe'] = Resolve-ArmFfprobePath -Config $Config
            $upscale['RequiredFiles'] = @($runner, "$modelBase.param", "$modelBase.bin")
        } else {
            $engineTool = 'video2x'
            $engineLabel = 'video2x upscale'
            $upscale['Shader'] = Get-UpscaleSetting -Config $Config -Name 'UpscaleShader' -Default 'anime4k-v4-a+a'
        }
    } else {
        $planError = "Unknown upscale engine '$engine' for ContentType $ContentType (expected openproteus, anime4k, or realesrgan)"
    }

    # Colour policy (#29): see Get-UpscaleColorInput.
    $color = Get-UpscaleColorInput -SourceInfo $SourceInfo -Engine $engine
    foreach ($w in $color.Warnings) { $warnings.Add($w) }
    $colorInput = $color.Input
    $colorConvert = $color.Convert

    return [pscustomobject][ordered]@{
        InputFile      = $InputFile
        BaseName       = $baseName
        ContentType    = $ContentType
        SampleOnly     = [bool]$SampleOnly
        InterlaceType  = $InterlaceType
        Window         = $window
        Preprocess     = [ordered]@{ Filter = $filter; FrameRate = $cfrRate }
        Engine         = $engine
        EngineTool     = $engineTool
        EngineLabel    = $engineLabel
        Target         = $target
        Upscale        = $upscale
        Encode         = [ordered]@{
            Codec      = 'libx265'
            Crf        = $Config.UpscaleCrf
            Preset     = 'slow'
            AudioCodec = 'copy'
            # Upscaled to the exact display size; drop the source's anamorphic SAR
            # (video2x carries it through) so players don't stretch the frame twice.
            ResetSar   = ($engine -ne 'realesrgan')
        }
        Colour         = [ordered]@{
            Space      = $SourceInfo.ColorSpace
            Primaries  = $SourceInfo.ColorPrimaries
            Transfer   = $SourceInfo.ColorTransfer
            Range      = $SourceInfo.ColorRange
            Action     = if ($colorConvert) { 'convert-to-bt709' } else { 'tag-only' }
        }
        ColorInput     = $colorInput
        ColorInputSpec = $color.InputSpec
        ColorConvert   = $colorConvert
        Source         = $SourceInfo
        OutputFileName = "$baseName [AI upscale 1080p].mkv"
        Warnings       = @($warnings)
        Error          = $planError
    }
}

# Leading options for the long ffmpeg runs (preprocess, final encode): no banner, no
# input/stream/chapter dump, no stats line - only warnings and errors reach stderr (#32).
# Invoke-Upscale adds `-progress pipe:1` in front when it wants progress.
$script:ArmFfmpegQuietArgs = @('-hide_banner', '-loglevel', 'warning', '-nostats')

<#
.SYNOPSIS
    ffmpeg arguments for the preprocess stage (deinterlace/IVTC to a lossless ffv1 intermediate). Pure.
#>
function Get-UpscalePreprocessArgumentList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Plan,
        [Parameter(Mandatory = $true)] [string] $OutputFile
    )

    $preArgs = @($script:ArmFfmpegQuietArgs) + @('-y', '-i', $Plan.InputFile)
    if ($Plan.Window) {
        $preArgs += @('-ss', "$($Plan.Window.Seek)", '-t', "$($Plan.Window.Duration)")
    }
    if ($Plan.Preprocess.Filter) {
        $preArgs += @('-vf', $Plan.Preprocess.Filter)
    }
    if ($Plan.Preprocess.FrameRate) {
        $preArgs += @('-fps_mode', 'cfr', '-r', $Plan.Preprocess.FrameRate)
    }
    $preArgs += @('-c:v', 'ffv1', '-an', $OutputFile)
    return [string[]]$preArgs
}

<#
.SYNOPSIS
    Arguments for the upscale stage; run them with Invoke-ArmTool -Name $Plan.EngineTool. Pure.
#>
function Get-UpscaleEngineArgumentList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Plan,
        [Parameter(Mandatory = $true)] [string] $InputFile,
        [Parameter(Mandatory = $true)] [string] $OutputFile
    )

    switch ($Plan.Engine) {
        'realesrgan' {
            return [string[]]@(
                '-i', $InputFile,
                '-p', 'realesrgan',
                '--realesrgan-model', $Plan.Upscale.Model,
                '-s', "$($Plan.Upscale.Scale)",
                '-o', $OutputFile
            )
        }
        'openproteus' {
            return [string[]]@(
                '-I', $Plan.Upscale.Runner,
                '--input', $InputFile,
                '--param', "$($Plan.Upscale.ModelBase).param",
                '--bin', "$($Plan.Upscale.ModelBase).bin",
                '--scale', '2',
                '--out-width', "$($Plan.Target.Width)",
                '--out-height', "$($Plan.Target.Height)",
                '--ffmpeg', $Plan.Upscale.Ffmpeg,
                '--ffprobe', $Plan.Upscale.Ffprobe,
                '--output', $OutputFile
            )
        }
        'anime4k' {
            return [string[]]@(
                '-i', $InputFile,
                '-p', 'libplacebo',
                '--libplacebo-shader', $Plan.Upscale.Shader,
                '-w', "$($Plan.Target.Width)",
                '-h', "$($Plan.Target.Height)",
                '-o', $OutputFile
            )
        }
        default {
            throw "Get-UpscaleEngineArgumentList: no argument builder for engine '$($Plan.Engine)'"
        }
    }
}

<#
.SYNOPSIS
    ffmpeg arguments for the final mux/encode: x265 video from the upscaled file, original audio copied. Pure.

.DESCRIPTION
    $UpscaledFile is already the trimmed clip when the plan has a Window, so only the
    audio source (the untouched original) needs the same trim here - otherwise the
    sample's audio track would start at 0:00 and run the full original length instead
    of matching the 2-minute video clip. Assumes feature-length input. -shortest guards
    against residual rounding drift between the two trimmed streams.
#>
function Get-UpscaleEncodeArgumentList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Plan,
        [Parameter(Mandatory = $true)] [string] $UpscaledFile,
        [Parameter(Mandatory = $true)] [string] $OutputFile
    )

    $muxArgs = @($script:ArmFfmpegQuietArgs) + @('-y', '-i', $UpscaledFile)
    if ($Plan.Window) {
        $muxArgs += @('-ss', "$($Plan.Window.Seek)", '-t', "$($Plan.Window.Duration)")
    }
    $muxArgs += @(
        '-i', $Plan.InputFile,
        '-map', '0:v:0',
        '-map', '1:a'
    )
    # One filter chain: SAR reset, then the BT.601 -> BT.709 matrix conversion. The
    # intermediates are 8-bit yuv420p and the encode sets no -pix_fmt, so the filter
    # runs at the encoder's own depth.
    $vfParts = @()
    if ($Plan.Encode.ResetSar) { $vfParts += 'setsar=1' }
    if ($Plan.ColorConvert) { $vfParts += "colorspace=all=bt709:$($Plan.ColorInputSpec):irange=tv:range=tv:dither=fsb" }
    if ($vfParts.Count -gt 0) {
        $muxArgs += @('-vf', ($vfParts -join ','))
    }
    # Always tag the output so libx265 writes BT.709 into the HEVC VUI.
    $muxArgs += @('-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-color_range', 'tv')
    $muxArgs += @(
        '-c:v', $Plan.Encode.Codec,
        '-crf', "$($Plan.Encode.Crf)",
        '-preset', $Plan.Encode.Preset,
        '-c:a', $Plan.Encode.AudioCodec,
        '-shortest',
        $OutputFile
    )
    return [string[]]$muxArgs
}

<#
.SYNOPSIS
    Turn one tool progress block into an upscale-stage progress object and log it at most
    once per State.IntervalSec (and once when the stage ends). Never throws.

.DESCRIPTION
    -State is created per stage by Invoke-Upscale:
      @{ Stage; IntervalSec; TotalSec; TotalFrames; LastLog = <datetime> }
    Percent/ETA come from out_time vs TotalSec at the reported speed (ffmpeg -progress),
    else from frames vs TotalFrames at the reported fps (tools/ncnn_upscale.py); either is
    $null when unknown. -Now is injectable for tests.

.OUTPUTS
    [pscustomobject] @{ Stage; Frame; Fps; Percent; EtaSec; Ended }
#>
function Write-ArmUpscaleProgress {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)] [hashtable] $State,
        [Parameter(Mandatory = $true)] [pscustomobject] $Progress,
        [hashtable] $Config,
        [datetime] $Now = [datetime]::UtcNow
    )

    $percent = $null
    $eta = $null
    try {
        $totalSec = if ($State['TotalSec']) { [double]$State['TotalSec'] } else { 0 }
        $totalFrames = if ($State['TotalFrames']) { [double]$State['TotalFrames'] } else { 0 }
        if ($totalSec -gt 0 -and $null -ne $Progress.OutTimeSec) {
            $percent = [math]::Min(100.0, 100.0 * $Progress.OutTimeSec / $totalSec)
            if ($Progress.Speed -gt 0) { $eta = [math]::Max(0.0, ($totalSec - $Progress.OutTimeSec) / $Progress.Speed) }
        } elseif ($totalFrames -gt 0 -and $null -ne $Progress.Frame) {
            $percent = [math]::Min(100.0, 100.0 * $Progress.Frame / $totalFrames)
            if ($Progress.Fps -gt 0) { $eta = [math]::Max(0.0, ($totalFrames - $Progress.Frame) / $Progress.Fps) }
        }
        if ($Progress.Ended) { $eta = 0 }

        $due = $Progress.Ended -or -not $State['LastLog'] -or (($Now - $State['LastLog']).TotalSeconds -ge $State['IntervalSec'])
        if ($due) {
            $State['LastLog'] = $Now
            $parts = @()
            if ($null -ne $Progress.Frame) { $parts += "frame $($Progress.Frame)" + $(if ($totalFrames -gt 0) { "/$([long]$totalFrames)" } else { '' }) }
            if ($null -ne $percent) { $parts += ('{0:0.0}%' -f $percent) }
            if ($null -ne $Progress.Fps) { $parts += ('{0:0.0} fps' -f $Progress.Fps) }
            if ($null -ne $Progress.Speed) { $parts += ('{0:0.00}x' -f $Progress.Speed) }
            $parts += if ($Progress.Ended) { 'done' } elseif ($null -ne $eta) { 'ETA ' + ([timespan]::FromSeconds([math]::Round($eta))).ToString('c') } else { 'ETA unknown' }
            Write-ArmLog -Level INFO -Message "Upscale $($State['Stage']) progress: $($parts -join ', ')" -Config $Config
        }
    } catch {
        # Progress reporting must never fail an upscale.
        Write-Verbose "Write-ArmUpscaleProgress: $_"
    }

    return [pscustomobject]@{
        Stage   = $State['Stage']
        Frame   = $Progress.Frame
        Fps     = $Progress.Fps
        Percent = $percent
        EtaSec  = $eta
        Ended   = [bool]$Progress.Ended
    }
}

<#
.SYNOPSIS
    Deinterlace/IVTC, upscale (OpenProteus ncnn runner, Video2X libplacebo/Anime4K, or Real-ESRGAN), and re-encode a DVD-sourced video.

.DESCRIPTION
    Probe, plan, execute:
      0. Probe once: Get-VideoSourceInfo (ffprobe on the SOURCE: size, SAR/DAR, colour
         tags, header rate, duration, audio streams), Get-InterlaceType (idet) and, for
         non-Telecined sources, Get-VideoFrameRate (decoded rate).
      1. Get-UpscalePlan (pure) turns those facts + config + -ContentType + -SampleOnly
         into a plan object; an invalid plan (unknown engine, realesrgan model/scale
         mismatch, missing OpenProteus runner/model) fails here, before any slow work.
      2. ffmpeg preprocess to a temporary intermediate:
           Telecined  -> -vf fieldmatch,yadif=deint=interlaced,decimate
           Interlaced -> -vf idet,bwdif=mode=send_frame:deint=interlaced
           Progressive-> passthrough
         Non-Telecined sources also get `-fps_mode cfr -r <measured rate>`.
         Intermediate is encoded ffv1 (lossless) to avoid compounding generation loss
         before the AI upscale. -SampleOnly restricts to a 2-minute clip starting at
         10 minutes in (-ss 600 -t 120), matching AutoUpscale=$false's review sample.
      3. Upscale the intermediate with the engine chosen for -ContentType
         ($Config.UpscaleLiveAction for LiveAction, $Config.UpscaleAnimation for
         Animation):
           openproteus -> tools/ncnn_upscale.py via the 'ncnn' tool: OpenProteus 2x ncnn
                          model (NcnnModelDir\openproteus-x2.*), scaled to the exact
                          UpscaleHeight x DAR-derived width, SAR reset to 1.
           anime4k     -> video2x -p libplacebo --libplacebo-shader $Config.UpscaleShader
                          at the same DAR-derived output size.
           realesrgan  -> legacy video2x realesrgan with UpscaleModel/UpscaleScale.
         Output width = round(UpscaleHeight x source DAR / 2) * 2, so anamorphic DVDs
         (e.g. 720x480 SAR 853:720) come out at the right aspect.
      4. ffmpeg mux: re-encode video libx265 -crf $Config.UpscaleCrf -preset slow,
         copy the original file's audio stream(s) untouched. -SampleOnly also trims
         the audio input to the same 10:00-12:00 window as the (already-trimmed)
         video intermediate, plus -shortest, so the sample's audio matches its video
         instead of playing from 0:00 at full length.
      5. Output is named "<basename> [AI upscale 1080p].mkv" in $OutputDir.

    All temp files (preprocessed intermediate, upscaled intermediate) are removed in
    a finally block regardless of success or failure. This function never throws;
    all failures are captured and returned in the result object.

.PARAMETER InputFile
    Path to the source video file (deinterlaced/IVTC'd DVD rip).

.PARAMETER OutputDir
    Directory to write the final muxed output file into.

.PARAMETER Config
    Configuration hashtable (UpscaleLiveAction, UpscaleAnimation, UpscaleHeight,
    UpscaleShader, UpscaleCrf, NcnnPath, NcnnModelDir, FfmpegPath, FfprobePath, etc).

.PARAMETER ContentType
    'LiveAction' (default) or 'Animation'; selects which configured engine runs.

.PARAMETER SampleOnly
    When set, only processes a 2-minute sample (10:00-12:00) instead of the full
    file - used for review before committing to AutoUpscale=$false's full run.

.OUTPUTS
    [pscustomobject] @{ Success; OutputFile; InterlaceType; Engine; Error }  (Engine: openproteus | anime4k | realesrgan; $null if it failed before engine selection)

.EXAMPLE
    Invoke-Upscale -InputFile 'C:\rips\staging\movie.mkv' -OutputDir 'C:\rips\staging' -Config $config

.EXAMPLE
    Invoke-Upscale -InputFile 'C:\rips\staging\movie.mkv' -OutputDir 'C:\rips\staging' -Config $config -SampleOnly
#>
function Invoke-Upscale {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $InputFile,

        [Parameter(Mandatory = $true)]
        [string] $OutputDir,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config,

        [ValidateSet('LiveAction', 'Animation')]
        [string] $ContentType = 'LiveAction',

        [switch] $SampleOnly,

        [scriptblock] $ProgressHandler
    )

    # Invoke-ArmTool's default 3600s timeout would kill a feature-length upscale/encode.
    $longTimeoutSec = 86400
    $progressIntervalSec = 60

    $interlaceType = $null
    $engine = $null
    $tempDir = $null
    $preprocessedFile = $null
    $upscaledFile = $null
    $outputFile = $null
    $success = $false

    try {
        # --- (a) probe the source, then plan ---
        $sourceInfo = Get-VideoSourceInfo -InputFile $InputFile -Config $Config
        $sourceDuration = if ($sourceInfo.DurationSec) { [double]$sourceInfo.DurationSec } else { 0 }
        $interlaceType = Get-InterlaceType -InputFile $InputFile -Config $Config -SourceDuration $sourceDuration
        # Always measured: Get-UpscalePlan needs the decoded rate for the soft-telecine guard.
        $frameRate = Get-VideoFrameRate -InputFile $InputFile -Config $Config
        # Soft-telecine guard input: the decoded rate at EVERY idet window (a hybrid disc can be
        # soft at 600 s and hard elsewhere). Only needed for a Telecined verdict.
        $windowFrameRates = @()
        if ($interlaceType -eq 'Telecined') {
            $windowFrameRates = @(foreach ($start in (Get-InterlaceProbeStart -SourceDuration $sourceDuration)) {
                if ($start -eq 600) { $frameRate } else { Get-VideoFrameRate -InputFile $InputFile -Config $Config -Seek $start }
            })
        }

        $plan = Get-UpscalePlan -InputFile $InputFile -SourceInfo $sourceInfo -InterlaceType $interlaceType `
            -FrameRate $frameRate -WindowFrameRate $windowFrameRates -Config $Config -ContentType $ContentType -SampleOnly:$SampleOnly
        $interlaceType = $plan.InterlaceType   # may differ from the probe (soft-telecine guard)
        foreach ($warning in $plan.Warnings) {
            Write-ArmLog -Level WARN -Message $warning -Config $Config
        }
        # The result's Engine stays $null for a failure before the engine is chosen (a
        # preprocess failure), exactly as before the plan refactor; a plan that cannot
        # run reports the engine it tried to choose.
        if ($plan.Error) {
            $engine = $plan.Engine
            throw $plan.Error
        }
        if ($plan.Upscale.Contains('RequiredFiles') -and -not (Get-UpscaleSetting -Config $Config -Name 'Simulate' -Default $false)) {
            foreach ($required in $plan.Upscale.RequiredFiles) {
                if (-not (Test-Path -LiteralPath $required)) {
                    $engine = $plan.Engine
                    throw "OpenProteus engine needs '$required' - run setup.ps1 to install the ncnn runner and model"
                }
            }
        }

        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "wrm-upscale-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $tempDir -Force

        # Progress (#32): ffmpeg stages report out_time via `-progress pipe:1`; the ncnn
        # runner reports frames. Expected totals give percent/ETA: the processed length
        # (sample window or whole source) and, for frame counts, the intermediate's rate
        # (decimated 24000/1001 for Telecined, else the forced or measured rate).
        $totalSec = $sourceDuration
        if ($plan.Window) { $totalSec = if ($sourceDuration -gt 0) { [math]::Min([double]$plan.Window.Duration, [math]::Max(0.0, $sourceDuration - $plan.Window.Seek)) } else { [double]$plan.Window.Duration } }
        $rateText = if ($interlaceType -eq 'Telecined') { '24000/1001' } elseif ($plan.Preprocess.FrameRate) { $plan.Preprocess.FrameRate } else { $frameRate }
        $rate = ConvertFrom-ProbeRatio $rateText
        $totalFrames = if ($rate -and $totalSec -gt 0) { [math]::Round($totalSec * $rate.Num / $rate.Den) } else { $null }
        $progressArgs = @('-progress', 'pipe:1')
        $newProgressState = { param($stage) @{ Stage = $stage; IntervalSec = $progressIntervalSec; TotalSec = $totalSec; TotalFrames = $totalFrames; LastLog = $null } }
        # Invoke-ArmTool runs this on the PowerShell thread in a child of ITS scope, so it
        # reaches this function's variables by dynamic scoping. Use names Invoke-ArmTool
        # does not define ($ProgressHandler/$Config there would shadow ours).
        $upscaleProgressConfig = $Config
        $upscaleProgressSink = $ProgressHandler
        $onToolProgress = {
            param($toolProgress)
            $stageProgress = Write-ArmUpscaleProgress -State $upscaleProgressState -Progress $toolProgress -Config $upscaleProgressConfig
            if ($upscaleProgressSink) { & $upscaleProgressSink $stageProgress }
        }

        # --- (b) preprocess: deinterlace/IVTC ---
        $preprocessedFile = Join-Path $tempDir 'preprocessed.mkv'
        $upscaleProgressState = & $newProgressState 'preprocess'
        $preResult = Invoke-ArmTool -Name ffmpeg -Config $Config -TimeoutSec $longTimeoutSec -ProgressHandler $onToolProgress `
            -Arguments ($progressArgs + (Get-UpscalePreprocessArgumentList -Plan $plan -OutputFile $preprocessedFile))
        if ($preResult.ExitCode -ne 0) {
            throw "ffmpeg preprocess failed with exit code $($preResult.ExitCode)"
        }

        # --- (c) AI upscale with the engine configured for this content type ---
        $upscaledFile = Join-Path $tempDir 'upscaled.mkv'
        $engine = $plan.Engine
        $upscaleProgressState = & $newProgressState 'upscale'
        $engineProgress = if ($plan.EngineTool -eq 'ncnn') { $onToolProgress } else { $null }
        $upscaleResult = Invoke-ArmTool -Name $plan.EngineTool -Config $Config -TimeoutSec $longTimeoutSec -ProgressHandler $engineProgress `
            -Arguments (Get-UpscaleEngineArgumentList -Plan $plan -InputFile $preprocessedFile -OutputFile $upscaledFile)
        if ($upscaleResult.ExitCode -ne 0) {
            throw "$($plan.EngineLabel) failed with exit code $($upscaleResult.ExitCode) (engine: $engine)"
        }

        # --- (d) final mux: x265 video, copy original audio ---
        $outputFile = Join-Path $OutputDir $plan.OutputFileName
        if (-not (Test-Path -LiteralPath $OutputDir)) {
            $null = New-Item -ItemType Directory -Path $OutputDir -Force
        }

        $upscaleProgressState = & $newProgressState 'encode'
        $muxResult = Invoke-ArmTool -Name ffmpeg -Config $Config -TimeoutSec $longTimeoutSec -ProgressHandler $onToolProgress `
            -Arguments ($progressArgs + (Get-UpscaleEncodeArgumentList -Plan $plan -UpscaledFile $upscaledFile -OutputFile $outputFile))
        if ($muxResult.ExitCode -ne 0) {
            throw "ffmpeg mux failed with exit code $($muxResult.ExitCode)"
        }

        $success = $true
        return New-ArmResult -Success $true -Properties ([ordered]@{ OutputFile = $outputFile; InterlaceType = $interlaceType; Engine = $engine; SourceHeight = $sourceInfo.Height }) -Error $null
    } catch {
        Write-ArmLog -Level ERROR -Message "Invoke-Upscale failed for $InputFile : $_" -Config $Config
        return New-ArmResult -Success $false -Properties ([ordered]@{ OutputFile = $null; InterlaceType = $interlaceType; Engine = $engine }) -Error "$_"
    } finally {
        foreach ($f in @($preprocessedFile, $upscaledFile)) {
            if ($f -and (Test-Path -LiteralPath $f)) {
                Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            }
        }
        if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (-not $success -and $outputFile -and (Test-Path -LiteralPath $outputFile)) {
            Remove-Item -LiteralPath $outputFile -Force -ErrorAction SilentlyContinue
        }
    }
}
