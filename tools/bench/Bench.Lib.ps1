<#
.SYNOPSIS
    Functions for the upscale benchmark harness (issue #33). Dot-source; no top-level side effects.

.DESCRIPTION
    The harness only calls existing src code: Get-UpscalePlan and the Get-Upscale*ArgumentList
    builders from src/Upscale-Video.ps1, and Invoke-ArmTool for every external tool. The one
    harness-owned encode builder (Get-BenchEncodeArgumentList, hevc_amf only) exists because
    the shipping encode builder only emits libx265. Everything here is pure except
    Invoke-BenchVariantSample, which runs the tools.
#>

. (Join-Path $PSScriptRoot '..' '..' 'src' 'Common.ps1')
. (Join-Path $PSScriptRoot '..' '..' 'src' 'Upscale-Video.ps1')

$script:BenchInvariant = [System.Globalization.CultureInfo]::InvariantCulture

$script:BenchNamePattern = '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'

$script:BenchCsvColumns = @(
    'Sample', 'Variant', 'Status', 'Error', 'ContentType', 'Engine', 'InterlaceType',
    'Codec', 'Crf', 'Preset', 'Qp', 'Quality', 'PixFmt', 'Width', 'Height', 'Frames',
    'UpscaleSec', 'UpscaleCached', 'EncodeSec', 'UpscaleFps', 'WallFps', 'EncodeFps',
    'OutputBytes', 'Ssim', 'Psnr', 'OutputDurationSec', 'VideoLastPtsSec',
    'AudioLastPtsSec', 'AvLastPtsDeltaSec', 'Timestamp'
)

<#
.SYNOPSIS
    Column order of results CSV rows. Pure.
#>
function Get-BenchCsvColumns {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]$script:BenchCsvColumns
}

<#
.SYNOPSIS
    Validate a sample manifest (hashtable from Import-PowerShellDataFile). Pure.
.OUTPUTS
    [string[]] error messages; empty when valid.
#>
function Test-BenchSampleManifest {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)] [hashtable] $Manifest
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    $samples = @($Manifest['Samples'])
    if ($samples.Count -eq 0) {
        $errors.Add('Manifest has no Samples')
        return [string[]]$errors
    }
    $seen = @{}
    foreach ($sample in $samples) {
        $name = "$($sample['Name'])"
        if ($name -notmatch $script:BenchNamePattern) {
            $errors.Add("Sample name '$name' must match $($script:BenchNamePattern)")
            continue
        }
        if ($seen.ContainsKey($name)) { $errors.Add("Duplicate sample name '$name'") }
        $seen[$name] = $true
        if ([string]::IsNullOrWhiteSpace("$($sample['Source'])")) {
            $errors.Add("Sample '$name' has no Source")
        }
        $start = 0.0
        $duration = 0.0
        if (-not ($sample.ContainsKey('Start') -and [double]::TryParse("$($sample['Start'])", [System.Globalization.NumberStyles]::Float, $script:BenchInvariant, [ref]$start) -and $start -ge 0)) {
            $errors.Add("Sample '$name' needs Start >= 0 (seconds)")
        }
        if (-not ($sample.ContainsKey('Duration') -and [double]::TryParse("$($sample['Duration'])", [System.Globalization.NumberStyles]::Float, $script:BenchInvariant, [ref]$duration) -and $duration -gt 0)) {
            $errors.Add("Sample '$name' needs Duration > 0 (seconds)")
        }
    }
    return [string[]]$errors
}

<#
.SYNOPSIS
    Validate variant definitions (array from variants.psd1). Pure.
.DESCRIPTION
    Rejects, rather than approximating, the variant dimensions this harness cannot measure
    yet: streamed pipeline (#28) and concurrency above 1 (#27).
.OUTPUTS
    [string[]] error messages; empty when valid.
#>
function Test-BenchVariant {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)] [AllowNull()] [object[]] $Variants
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($variant in @($Variants)) {
        $name = "$($variant['Name'])"
        if ($name -notmatch $script:BenchNamePattern) {
            $errors.Add("Variant name '$name' must match $($script:BenchNamePattern)")
            continue
        }
        if ($seen.ContainsKey($name)) { $errors.Add("Duplicate variant name '$name'") }
        $seen[$name] = $true

        $contentType = if ($variant.ContainsKey('ContentType')) { "$($variant['ContentType'])" } else { 'LiveAction' }
        if ($contentType -notin @('LiveAction', 'Animation')) {
            $errors.Add("Variant '$name' ContentType must be LiveAction or Animation")
        }

        if ($variant.ContainsKey('Pipeline') -and "$($variant['Pipeline'])" -ne 'staged') {
            $errors.Add("Variant '$name' Pipeline '$($variant['Pipeline'])' is unavailable until #28 (streamed pipeline); only 'staged' runs")
        }
        if ($variant.ContainsKey('Concurrency') -and [int]$variant['Concurrency'] -ne 1) {
            $errors.Add("Variant '$name' Concurrency $($variant['Concurrency']) is unavailable until #27 (concurrent runners); only 1 runs")
        }

        $encode = $variant['Encode']
        if ($encode -isnot [hashtable]) {
            $errors.Add("Variant '$name' needs an Encode hashtable")
            continue
        }
        switch ("$($encode['Codec'])") {
            'libx265' {
                $crf = 0
                if (-not ([int]::TryParse("$($encode['Crf'])", [ref]$crf) -and $crf -ge 0 -and $crf -le 51)) {
                    $errors.Add("Variant '$name' libx265 needs Crf 0..51")
                }
                if ([string]::IsNullOrWhiteSpace("$($encode['Preset'])")) {
                    $errors.Add("Variant '$name' libx265 needs a Preset")
                }
            }
            'hevc_amf' {
                $qp = 0
                if (-not ([int]::TryParse("$($encode['Qp'])", [ref]$qp) -and $qp -ge 0 -and $qp -le 51)) {
                    $errors.Add("Variant '$name' hevc_amf needs Qp 0..51 (CQP)")
                }
                if ("$($encode['PixFmt'])" -notin @('yuv420p', 'p010le')) {
                    $errors.Add("Variant '$name' hevc_amf PixFmt must be yuv420p or p010le")
                }
                if ([string]::IsNullOrWhiteSpace("$($encode['Quality'])")) {
                    $errors.Add("Variant '$name' hevc_amf needs a Quality (speed|balanced|quality)")
                }
            }
            default {
                $errors.Add("Variant '$name' Encode.Codec must be libx265 or hevc_amf")
            }
        }
    }
    return [string[]]$errors
}

<#
.SYNOPSIS
    Config for one variant: a copy of the base config with the variant's Config overrides applied. Pure.
#>
function Get-BenchVariantConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)] [hashtable] $BaseConfig,
        [Parameter(Mandatory = $true)] [hashtable] $Variant
    )
    $config = @{}
    foreach ($key in $BaseConfig.Keys) { $config[$key] = $BaseConfig[$key] }
    if ($Variant.ContainsKey('Config') -and $Variant['Config']) {
        foreach ($key in $Variant['Config'].Keys) { $config[$key] = $Variant['Config'][$key] }
    }
    return $config
}

<#
.SYNOPSIS
    Apply a variant's plan override (currently only Preprocess.Filter, for the #30 filter
    chains) to a plan returned by Get-UpscalePlan. Mutates and returns the plan. Pure.
#>
function Set-BenchPlanOverride {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Plan,
        [AllowNull()] [hashtable] $Override
    )
    if ($Override -and $Override.ContainsKey('Filter')) {
        $Plan.Preprocess['Filter'] = if ($null -eq $Override['Filter'] -or "$($Override['Filter'])" -eq '') { $null } else { "$($Override['Filter'])" }
    }
    return $Plan
}

<#
.SYNOPSIS
    Stream-copy cut of one sample window from its source rip. Pure.
.DESCRIPTION
    -c copy keeps the source's field/telecine structure (the point of the Cast Away and
    interlaced samples). Start snaps to the nearest earlier keyframe; the real start and
    duration are recorded from ffprobe in the clip's sidecar by Invoke-BenchCut.
#>
function Get-BenchCutArgumentList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)] $Sample,
        [Parameter(Mandatory = $true)] [string] $OutputFile
    )
    return [string[]]@(
        '-y',
        '-ss', ([double]$Sample.Start).ToString('0.###', $script:BenchInvariant),
        '-i', "$($Sample.Source)",
        '-t', ([double]$Sample.Duration).ToString('0.###', $script:BenchInvariant),
        '-map', '0:v:0',
        '-map', '0:a?',
        '-c', 'copy',
        $OutputFile
    )
}

<#
.SYNOPSIS
    Encode arguments for one variant, from the upscaled intermediate. Pure.
.DESCRIPTION
    libx265: sets the plan's Encode fields and calls the shipping Get-UpscaleEncodeArgumentList.
    hevc_amf: harness-owned (the shipping builder is libx265-only); mirrors its mapping,
    SAR reset and audio copy, with CQP rate control and the variant's pixel format.
#>
function Get-BenchEncodeArgumentList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)] [hashtable] $Variant,
        [Parameter(Mandatory = $true)] [pscustomobject] $Plan,
        [Parameter(Mandatory = $true)] [string] $UpscaledFile,
        [Parameter(Mandatory = $true)] [string] $OutputFile
    )
    $encode = $Variant['Encode']
    if ($encode['Codec'] -eq 'libx265') {
        $Plan.Encode['Codec'] = 'libx265'
        $Plan.Encode['Crf'] = "$($encode['Crf'])"
        $Plan.Encode['Preset'] = "$($encode['Preset'])"
        return Get-UpscaleEncodeArgumentList -Plan $Plan -UpscaledFile $UpscaledFile -OutputFile $OutputFile
    }
    $argList = @('-y', '-i', $UpscaledFile, '-i', $Plan.InputFile, '-map', '0:v:0', '-map', '1:a')
    $vfParts = @()
    if ($Plan.Encode['ResetSar']) { $vfParts += 'setsar=1' }
    if ($Plan.ColorConvert) { $vfParts += "colorspace=all=bt709:$($Plan.ColorInputSpec):irange=tv:range=tv:dither=fsb" }
    if ($vfParts.Count -gt 0) { $argList += @('-vf', ($vfParts -join ',')) }
    $argList += @(
        '-c:v', 'hevc_amf',
        '-quality', "$($encode['Quality'])",
        '-rc', 'cqp',
        '-qp_i', "$($encode['Qp'])",
        '-qp_p', "$($encode['Qp'])",
        '-pix_fmt', "$($encode['PixFmt'])",
        '-c:a', 'copy',
        '-shortest',
        $OutputFile
    )
    return [string[]]$argList
}

<#
.SYNOPSIS
    ffmpeg args that score an encode against the reference intermediate, one metric per run. Pure.
.PARAMETER Metric
    ssim or psnr. Two runs (not one filtergraph) keeps the summary line unambiguous.
#>
function Get-BenchMetricArgumentList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)] [string] $EncodedFile,
        [Parameter(Mandatory = $true)] [string] $ReferenceFile,
        [Parameter(Mandatory = $true)] [ValidateSet('ssim', 'psnr')] [string] $Metric
    )
    return [string[]]@(
        '-hide_banner', '-nostats',
        '-i', $EncodedFile,
        '-i', $ReferenceFile,
        '-lavfi', "[0:v][1:v]$Metric",
        '-f', 'null', '-'
    )
}

<#
.SYNOPSIS
    Parse the SSIM "All" score from ffmpeg stderr lines. Returns $null when absent. Pure.
#>
function ConvertFrom-BenchSsimLine {
    [CmdletBinding()]
    [OutputType([Nullable[double]])]
    param([AllowNull()] [string[]] $Lines)
    foreach ($line in @($Lines)) {
        if ("$line" -match 'SSIM Y:\S+ \([^)]*\) U:\S+ \([^)]*\) V:\S+ \([^)]*\) All:(\d+(?:\.\d+)?)') {
            return [double]::Parse($Matches[1], $script:BenchInvariant)
        }
    }
    return $null
}

<#
.SYNOPSIS
    Parse the PSNR average from ffmpeg stderr lines. Returns $null when absent. Pure.
.DESCRIPTION
    An 'inf' average (identical frames) is returned as [double]::PositiveInfinity.
#>
function ConvertFrom-BenchPsnrLine {
    [CmdletBinding()]
    [OutputType([Nullable[double]])]
    param([AllowNull()] [string[]] $Lines)
    foreach ($line in @($Lines)) {
        if ("$line" -match 'PSNR y:\S+ u:\S+ v:\S+ average:(inf|\d+(?:\.\d+)?)') {
            if ($Matches[1] -eq 'inf') { return [double]::PositiveInfinity }
            return [double]::Parse($Matches[1], $script:BenchInvariant)
        }
    }
    return $null
}

<#
.SYNOPSIS
    ffprobe args for packet pts of one stream selector (v:0 or a:0), one pts_time per line. Pure.
#>
function Get-BenchPacketProbeArgumentList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)] [string] $InputFile,
        [Parameter(Mandatory = $true)] [ValidateSet('v:0', 'a:0')] [string] $Stream
    )
    return [string[]]@(
        '-v', 'error',
        '-select_streams', $Stream,
        '-show_entries', 'packet=pts_time',
        '-of', 'csv=p=0',
        $InputFile
    )
}

<#
.SYNOPSIS
    Packet count and last pts from packet-probe output lines. Pure.
.OUTPUTS
    @{ Count = [int]; LastPts = [double] or $null }. Lines without a number (N/A) count as packets
    but not toward LastPts.
#>
function ConvertFrom-BenchPacketTimes {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()] [string[]] $Lines)
    $count = 0
    $last = $null
    foreach ($line in @($Lines)) {
        $text = "$line".Trim()
        if ($text -eq '') { continue }
        $count++
        $value = 0.0
        if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, $script:BenchInvariant, [ref]$value)) {
            if ($null -eq $last -or $value -gt $last) { $last = $value }
        }
    }
    return [pscustomobject]@{ Count = $count; LastPts = $last }
}

<#
.SYNOPSIS
    Cache key for an upscaled intermediate: everything that changes the upscale output. Pure.
.DESCRIPTION
    Two variants that differ only in encoder share one intermediate. A changed filter chain,
    engine, shader, model, or target size gets a new key.
#>
function Get-BenchIntermediateKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)] [string] $SampleName,
        [Parameter(Mandatory = $true)] [pscustomobject] $Plan
    )
    $material = [ordered]@{
        Sample     = $SampleName
        Preprocess = $Plan.Preprocess
        Engine     = $Plan.Engine
        Upscale    = $Plan.Upscale
        Target     = $Plan.Target
    }
    $json = $material | ConvertTo-Json -Depth 6 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 16).ToLowerInvariant()
}

<#
.SYNOPSIS
    ffmpeg args that extract one PNG frame at a timestamp. Pure.
#>
function Get-BenchFrameArgumentList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)] [string] $InputFile,
        [Parameter(Mandatory = $true)] [double] $TimeSec,
        [Parameter(Mandatory = $true)] [string] $OutputFile
    )
    return [string[]]@(
        '-hide_banner', '-nostats', '-y',
        '-ss', $TimeSec.ToString('0.###', $script:BenchInvariant),
        '-i', $InputFile,
        '-frames:v', '1',
        $OutputFile
    )
}

<#
.SYNOPSIS
    Append one result row to a CSV, writing the header on first use. Columns follow Get-BenchCsvColumns.
#>
function Add-BenchCsvRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Row
    )
    $columns = Get-BenchCsvColumns
    $obj = [ordered]@{}
    foreach ($column in $columns) { $obj[$column] = $Row[$column] }
    $line = [pscustomobject]$obj | ConvertTo-Csv -NoTypeInformation -UseQuotes AsNeeded
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    if (-not (Test-Path -LiteralPath $Path)) {
        Set-Content -LiteralPath $Path -Value ($columns -join ',') -Encoding utf8
    }
    Add-Content -LiteralPath $Path -Value $line[1] -Encoding utf8
}

<#
.SYNOPSIS
    Run one variant over one sample: plan, upscale (cached per intermediate key), encode, score, probe.

.DESCRIPTION
    Uses the shipping path: Get-VideoSourceInfo, Get-InterlaceType, Get-VideoFrameRate,
    Get-UpscalePlan, Get-UpscalePreprocessArgumentList, Get-UpscaleEngineArgumentList, then
    Get-BenchEncodeArgumentList (libx265 defers to Get-UpscaleEncodeArgumentList). Every
    external tool goes through Invoke-ArmTool. Never throws for an expected failure: the
    returned row carries Status='error' and Error.

    The upscaled intermediate is kept in <OutDir>\cache so encoder variants reuse it. Its
    upscale time is stored beside it, and rows report UpscaleCached when it was reused.
#>
function Invoke-BenchVariantSample {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory = $true)] $Sample,
        [Parameter(Mandatory = $true)] [hashtable] $Variant,
        [Parameter(Mandatory = $true)] [hashtable] $BaseConfig,
        [Parameter(Mandatory = $true)] [string] $OutDir
    )
    $row = [ordered]@{ Sample = $Sample.Name; Variant = $Variant['Name']; Status = 'error'; Error = $null; Timestamp = (Get-Date).ToString('o') }
    $fail = {
        param([string] $Message)
        $row['Error'] = $Message
        Write-ArmLog -Level ERROR -Message "bench $($Sample.Name) x $($Variant['Name']): $Message" -Config $BaseConfig
        return $row
    }
    $clip = Join-Path $OutDir 'clips' "$($Sample.Name).mkv"
    if (-not (Test-Path -LiteralPath $clip)) { return & $fail "clip missing ($clip); run -Mode Cut first" }

    try {
        $config = Get-BenchVariantConfig -BaseConfig $BaseConfig -Variant $Variant
        $contentType = if ($Variant.ContainsKey('ContentType')) { "$($Variant['ContentType'])" } else { 'LiveAction' }
        $row['ContentType'] = $contentType

        $source = Get-VideoSourceInfo -InputFile $clip -Config $config
        if (-not $source.Success) { return & $fail "probe failed: $($source.Error)" }
        $interlace = Get-InterlaceType -InputFile $clip -Config $config
        $frameRate = $null
        if ($interlace -ne 'Telecined') { $frameRate = Get-VideoFrameRate -InputFile $clip -Config $config }
        $plan = Get-UpscalePlan -InputFile $clip -SourceInfo $source -InterlaceType $interlace `
            -FrameRate $frameRate -Config $config -ContentType $contentType
        $plan = Set-BenchPlanOverride -Plan $plan -Override $Variant['PlanOverride']
        if ($plan.Error) { return & $fail $plan.Error }
        $row['Engine'] = $plan.Engine
        $row['InterlaceType'] = $interlace
        $row['Width'] = $plan.Target.Width
        $row['Height'] = $plan.Target.Height

        $isSimulate = [bool](Get-UpscaleSetting -Config $config -Name 'Simulate' -Default $false)
        if ($plan.Upscale.Contains('RequiredFiles') -and -not $isSimulate) {
            foreach ($required in $plan.Upscale.RequiredFiles) {
                if (-not (Test-Path -LiteralPath $required)) { return & $fail "missing engine file '$required'" }
            }
        }

        $cacheDir = Join-Path $OutDir 'cache'
        $null = New-Item -ItemType Directory -Path $cacheDir -Force
        $key = Get-BenchIntermediateKey -SampleName $Sample.Name -Plan $plan
        $intermediate = Join-Path $cacheDir "$key.mkv"
        $sidecar = Join-Path $cacheDir "$key.json"
        $upscaleSec = $null
        if ((Test-Path -LiteralPath $intermediate) -and (Test-Path -LiteralPath $sidecar)) {
            $upscaleSec = [double](Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json).UpscaleSec
            $row['UpscaleCached'] = $true
        } else {
            $row['UpscaleCached'] = $false
            $preFile = Join-Path $cacheDir "$key.pre.mkv"
            $tmpUp = Join-Path $cacheDir "$key.tmp.mkv"
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $pre = Invoke-ArmTool -Name ffmpeg -Config $config -TimeoutSec 86400 `
                -Arguments (Get-UpscalePreprocessArgumentList -Plan $plan -OutputFile $preFile)
            if ($pre.ExitCode -ne 0) { return & $fail "preprocess exited $($pre.ExitCode)" }
            $up = Invoke-ArmTool -Name $plan.EngineTool -Config $config -TimeoutSec 86400 `
                -Arguments (Get-UpscaleEngineArgumentList -Plan $plan -InputFile $preFile -OutputFile $tmpUp)
            $sw.Stop()
            Remove-Item -LiteralPath $preFile -Force -ErrorAction SilentlyContinue
            if ($up.ExitCode -ne 0) { return & $fail "$($plan.EngineLabel) exited $($up.ExitCode)" }
            Move-Item -LiteralPath $tmpUp -Destination $intermediate -Force
            $upscaleSec = $sw.Elapsed.TotalSeconds
            [pscustomobject]@{ Key = $key; UpscaleSec = $upscaleSec } |
                ConvertTo-Json | Set-Content -LiteralPath $sidecar -Encoding utf8
        }
        $row['UpscaleSec'] = [math]::Round($upscaleSec, 3)

        $encodedDir = Join-Path $OutDir 'encoded'
        $null = New-Item -ItemType Directory -Path $encodedDir -Force
        $encoded = Join-Path $encodedDir "$($Sample.Name)--$($Variant['Name']).mkv"
        Remove-Item -LiteralPath $encoded -Force -ErrorAction SilentlyContinue
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $enc = Invoke-ArmTool -Name ffmpeg -Config $config -TimeoutSec 86400 `
            -Arguments (Get-BenchEncodeArgumentList -Variant $Variant -Plan $plan -UpscaledFile $intermediate -OutputFile $encoded)
        $sw.Stop()
        if ($enc.ExitCode -ne 0) { return & $fail "encode exited $($enc.ExitCode)" }
        $encodeSec = $sw.Elapsed.TotalSeconds

        $ssim = Invoke-ArmTool -Name ffmpeg -Config $config -TimeoutSec 86400 `
            -Arguments (Get-BenchMetricArgumentList -EncodedFile $encoded -ReferenceFile $intermediate -Metric ssim)
        $psnr = Invoke-ArmTool -Name ffmpeg -Config $config -TimeoutSec 86400 `
            -Arguments (Get-BenchMetricArgumentList -EncodedFile $encoded -ReferenceFile $intermediate -Metric psnr)

        $vProbe = Invoke-ArmTool -Name ffprobe -Config $config -Arguments (Get-BenchPacketProbeArgumentList -InputFile $encoded -Stream 'v:0')
        $aProbe = Invoke-ArmTool -Name ffprobe -Config $config -Arguments (Get-BenchPacketProbeArgumentList -InputFile $encoded -Stream 'a:0')
        $video = ConvertFrom-BenchPacketTimes -Lines $vProbe.StdOut
        $audio = ConvertFrom-BenchPacketTimes -Lines $aProbe.StdOut
        $durProbe = Invoke-ArmTool -Name ffprobe -Config $config -Arguments @('-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', $encoded)
        $durationSec = $null
        $parsed = 0.0
        if (@($durProbe.StdOut).Count -gt 0 -and [double]::TryParse("$(@($durProbe.StdOut)[0])", [System.Globalization.NumberStyles]::Float, $script:BenchInvariant, [ref]$parsed)) {
            $durationSec = $parsed
        }

        $frames = [int]$video.Count
        $wallSec = $upscaleSec + $encodeSec
        $row['Status'] = 'ok'
        $row['Codec'] = "$($Variant.Encode['Codec'])"
        $row['Crf'] = if ($Variant.Encode['Codec'] -eq 'libx265') { "$($Variant.Encode['Crf'])" } else { $null }
        $row['Preset'] = if ($Variant.Encode['Codec'] -eq 'libx265') { "$($Variant.Encode['Preset'])" } else { $null }
        $row['Qp'] = if ($Variant.Encode['Codec'] -eq 'hevc_amf') { "$($Variant.Encode['Qp'])" } else { $null }
        $row['Quality'] = if ($Variant.Encode['Codec'] -eq 'hevc_amf') { "$($Variant.Encode['Quality'])" } else { $null }
        $row['PixFmt'] = if ($Variant.Encode['Codec'] -eq 'hevc_amf') { "$($Variant.Encode['PixFmt'])" } else { 'source' }
        $row['Frames'] = $frames
        $row['EncodeSec'] = [math]::Round($encodeSec, 3)
        $row['UpscaleFps'] = if ($upscaleSec -gt 0) { [math]::Round($frames / $upscaleSec, 3) } else { $null }
        $row['EncodeFps'] = if ($encodeSec -gt 0) { [math]::Round($frames / $encodeSec, 3) } else { $null }
        $row['WallFps'] = if ($wallSec -gt 0) { [math]::Round($frames / $wallSec, 3) } else { $null }
        $row['OutputBytes'] = (Get-Item -LiteralPath $encoded).Length
        $row['Ssim'] = ConvertFrom-BenchSsimLine -Lines (@($ssim.StdErr) + @($ssim.StdOut))
        $row['Psnr'] = ConvertFrom-BenchPsnrLine -Lines (@($psnr.StdErr) + @($psnr.StdOut))
        $row['OutputDurationSec'] = $durationSec
        $row['VideoLastPtsSec'] = $video.LastPts
        $row['AudioLastPtsSec'] = $audio.LastPts
        $row['AvLastPtsDeltaSec'] = if ($null -ne $video.LastPts -and $null -ne $audio.LastPts) { [math]::Round([math]::Abs($video.LastPts - $audio.LastPts), 3) } else { $null }
        return $row
    } catch {
        return & $fail "$_"
    }
}

<#
.SYNOPSIS
    Cut every sample in the manifest to a stream-copy clip under <OutDir>\clips and record the real window. Never throws.
.OUTPUTS
    [pscustomobject] @{ Cut; Failed } counts.
#>
function Invoke-BenchCut {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)] [object[]] $Samples,
        [Parameter(Mandatory = $true)] [hashtable] $BaseConfig,
        [Parameter(Mandatory = $true)] [string] $OutDir
    )
    $clipDir = Join-Path $OutDir 'clips'
    $null = New-Item -ItemType Directory -Path $clipDir -Force
    $cut = 0
    $failed = 0
    foreach ($sample in @($Samples)) {
        $clip = Join-Path $clipDir "$($sample.Name).mkv"
        $sidecar = Join-Path $clipDir "$($sample.Name).json"
        $result = Invoke-ArmTool -Name ffmpeg -Config $BaseConfig -TimeoutSec 86400 `
            -Arguments (Get-BenchCutArgumentList -Sample $sample -OutputFile $clip)
        if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $clip)) {
            $failed++
            Write-ArmLog -Level ERROR -Message "bench cut failed for $($sample.Name) (exit $($result.ExitCode))" -Config $BaseConfig
            continue
        }
        # Record the real window: -c copy snaps the start to a keyframe.
        $info = Get-VideoSourceInfo -InputFile $clip -Config $BaseConfig
        [pscustomobject]@{
            Name              = $sample.Name
            Source            = "$($sample.Source)"
            RequestedStart    = [double]$sample.Start
            RequestedDuration = [double]$sample.Duration
            ClipDurationSec   = $info.DurationSec
            Probed            = [bool]$info.Success
        } | ConvertTo-Json | Set-Content -LiteralPath $sidecar -Encoding utf8
        $cut++
    }
    return [pscustomobject]@{ Cut = $cut; Failed = $failed }
}

<#
.SYNOPSIS
    Extract the same frame timestamps from each sample's clip (as 'source') and each encoded variant. Never throws.
#>
function Invoke-BenchFrames {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)] [object[]] $Samples,
        [Parameter(Mandatory = $true)] [object[]] $Variants,
        [Parameter(Mandatory = $true)] [double[]] $TimesSec,
        [Parameter(Mandatory = $true)] [hashtable] $BaseConfig,
        [Parameter(Mandatory = $true)] [string] $OutDir
    )
    $written = 0
    foreach ($sample in @($Samples)) {
        $frameDir = Join-Path $OutDir 'frames' $sample.Name
        $null = New-Item -ItemType Directory -Path $frameDir -Force
        foreach ($t in $TimesSec) {
            $stamp = $t.ToString('0.###', $script:BenchInvariant)
            $inputs = [ordered]@{ source = Join-Path $OutDir 'clips' "$($sample.Name).mkv" }
            foreach ($variant in @($Variants)) {
                $inputs[$variant['Name']] = Join-Path $OutDir 'encoded' "$($sample.Name)--$($variant['Name']).mkv"
            }
            foreach ($name in $inputs.Keys) {
                $file = $inputs[$name]
                if (-not (Test-Path -LiteralPath $file)) { continue }
                $out = Join-Path $frameDir "$stamp-$name.png"
                $r = Invoke-ArmTool -Name ffmpeg -Config $BaseConfig -Arguments (Get-BenchFrameArgumentList -InputFile $file -TimeSec $t -OutputFile $out)
                if ($r.ExitCode -eq 0) { $written++ }
            }
        }
    }
    return $written
}
