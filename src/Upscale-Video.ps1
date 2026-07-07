Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Classify the interlace type of a video file using ffmpeg's idet filter.

.DESCRIPTION
    Runs `ffmpeg -filter:v idet -frames:v 2000 -an -f null -` via Invoke-ArmTool and
    parses the two summary lines idet writes to stderr:

        Repeated Fields: Neither: <n> Top: <n> Bottom: <n>
        Multi frame detection: TFF: <n> BFF: <n> Progressive: <n> Undetermined: <n>

    Classification (in order, first match wins):
      1. Progressive  - Multi frame detection Progressive count is >80% of the
                         Multi frame detection total (TFF+BFF+Progressive+Undetermined).
      2. Telecined    - Repeated Fields (Top+Bottom) is >15% of the Repeated Fields
                         total (Neither+Top+Bottom). This is the 3:2 pulldown cadence
                         signature; both telecined and interlaced sources can show high
                         TFF/BFF on the Multi frame detection line, so that line alone
                         cannot distinguish them - the Repeated Fields line is the
                         discriminator.
      3. Interlaced   - Anything else (significant TFF/BFF, no repeated-field cadence).

    If stderr does not contain a parseable "Multi frame detection" line, defaults to
    'Interlaced' (the safer preprocessing choice - bwdif is a no-op-ish pass on
    progressive content, whereas skipping deinterlacing on genuinely interlaced
    content produces visible combing after upscale).

.PARAMETER InputFile
    Path to the source video file.

.PARAMETER Config
    Configuration hashtable, passed through to Invoke-ArmTool.

.OUTPUTS
    [string] One of 'Telecined', 'Interlaced', 'Progressive'.

.EXAMPLE
    $type = Get-InterlaceType -InputFile 'C:\rips\staging\movie.mkv' -Config $config
#>
function Get-InterlaceType {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $InputFile,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $result = Invoke-ArmTool -Name ffmpeg -Config $Config -Arguments @(
        '-i', $InputFile,
        '-filter:v', 'idet',
        '-frames:v', '2000',
        '-an',
        '-f', 'null',
        '-'
    )

    $stderrText = ($result.StdErr -join "`n")

    $multiMatch = [regex]::Match(
        $stderrText,
        'Multi frame detection:\s*TFF:\s*(\d+)\s*BFF:\s*(\d+)\s*Progressive:\s*(\d+)\s*Undetermined:\s*(\d+)'
    )
    $repeatMatch = [regex]::Match(
        $stderrText,
        'Repeated Fields:\s*Neither:\s*(\d+)\s*Top:\s*(\d+)\s*Bottom:\s*(\d+)'
    )

    if (-not $multiMatch.Success) {
        Write-ArmLog -Level WARN -Message "Get-InterlaceType: could not parse idet output for $InputFile; defaulting to Interlaced" -Config $Config
        return 'Interlaced'
    }

    $tff = [int]$multiMatch.Groups[1].Value
    $bff = [int]$multiMatch.Groups[2].Value
    $progressive = [int]$multiMatch.Groups[3].Value
    $undetermined = [int]$multiMatch.Groups[4].Value
    $multiTotal = $tff + $bff + $progressive + $undetermined

    if ($multiTotal -gt 0 -and ($progressive / $multiTotal) -gt 0.80) {
        return 'Progressive'
    }

    if ($repeatMatch.Success) {
        $neither = [int]$repeatMatch.Groups[1].Value
        $top = [int]$repeatMatch.Groups[2].Value
        $bottom = [int]$repeatMatch.Groups[3].Value
        $repeatTotal = $neither + $top + $bottom

        if ($repeatTotal -gt 0 -and (($top + $bottom) / $repeatTotal) -gt 0.15) {
            return 'Telecined'
        }
    }

    return 'Interlaced'
}

<#
.SYNOPSIS
    Deinterlace/IVTC, AI-upscale (Video2X/Real-ESRGAN), and re-encode a DVD-sourced video.

.DESCRIPTION
    Pipeline:
      1. Classify the source with Get-InterlaceType.
      2. ffmpeg preprocess to a temporary intermediate:
           Telecined  -> -vf fieldmatch,yadif=deint=interlaced,decimate
           Interlaced -> -vf bwdif=mode=send_frame
           Progressive-> passthrough (stream copy where possible)
         Intermediate is encoded ffv1 (lossless) to avoid compounding generation loss
         before the AI upscale. -SampleOnly restricts to a 2-minute clip starting at
         10 minutes in (-ss 600 -t 120), matching AutoUpscale=$false's review sample.
      3. video2x (CLI flags target Video2X 6.4: -p/--processor, --realesrgan-model,
         -s/--scaling-factor) upscales the intermediate using the realesrgan
         processor with the model/scale from $Config.UpscaleModel / $Config.UpscaleScale.
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
    Configuration hashtable (UpscaleModel, UpscaleScale, UpscaleCrf, etc).

.PARAMETER SampleOnly
    When set, only processes a 2-minute sample (10:00-12:00) instead of the full
    file - used for review before committing to AutoUpscale=$false's full run.

.OUTPUTS
    [pscustomobject] @{ Success; OutputFile; InterlaceType; Error }

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

        [switch] $SampleOnly
    )

    $interlaceType = $null
    $tempDir = $null
    $preprocessedFile = $null
    $upscaledFile = $null
    $outputFile = $null
    $success = $false

    try {
        $interlaceType = Get-InterlaceType -InputFile $InputFile -Config $Config

        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "wrm-upscale-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $tempDir -Force

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)

        # --- (b) preprocess: deinterlace/IVTC ---
        $preprocessedFile = Join-Path $tempDir 'preprocessed.mkv'
        $filterArgs = switch ($interlaceType) {
            'Telecined' { @('-vf', 'fieldmatch,yadif=deint=interlaced,decimate') }
            'Interlaced' { @('-vf', 'bwdif=mode=send_frame') }
            default { @() }
        }

        $preArgs = @('-y', '-i', $InputFile)
        if ($SampleOnly) {
            $preArgs += @('-ss', '600', '-t', '120')
        }
        $preArgs += $filterArgs
        $preArgs += @('-c:v', 'ffv1', '-an', $preprocessedFile)

        $preResult = Invoke-ArmTool -Name ffmpeg -Config $Config -Arguments $preArgs
        if ($preResult.ExitCode -ne 0) {
            throw "ffmpeg preprocess failed with exit code $($preResult.ExitCode)"
        }

        # --- (c) AI upscale via video2x (CLI flags per Video2X 6.4: -p/--processor,
        # -s/--scaling-factor, and the realesrgan-specific --realesrgan-model) ---
        $upscaledFile = Join-Path $tempDir 'upscaled.mkv'
        $video2xArgs = @(
            '-i', $preprocessedFile,
            '-p', 'realesrgan',
            '--realesrgan-model', $Config.UpscaleModel,
            '-s', "$($Config.UpscaleScale)",
            '-o', $upscaledFile
        )

        $video2xResult = Invoke-ArmTool -Name video2x -Config $Config -Arguments $video2xArgs
        if ($video2xResult.ExitCode -ne 0) {
            throw "video2x upscale failed with exit code $($video2xResult.ExitCode)"
        }

        # --- (d) final mux: x265 video, copy original audio ---
        $outputFileName = "$baseName [AI upscale 1080p].mkv"
        $outputFile = Join-Path $OutputDir $outputFileName
        if (-not (Test-Path -LiteralPath $OutputDir)) {
            $null = New-Item -ItemType Directory -Path $OutputDir -Force
        }

        # $upscaledFile is already the trimmed 10:00-12:00 clip (preprocess applied
        # -ss/-t before the AI upscale when -SampleOnly), so only the audio source
        # ($InputFile, the untouched original) needs the same trim applied here -
        # otherwise the sample's audio track would start at 0:00 and run the full
        # original length instead of matching the 2-minute video clip. Assumes
        # feature-length input. -shortest guards against residual rounding drift
        # between the two trimmed streams.
        $muxArgs = @('-y', '-i', $upscaledFile)
        if ($SampleOnly) {
            $muxArgs += @('-ss', '600', '-t', '120')
        }
        $muxArgs += @(
            '-i', $InputFile,
            '-map', '0:v:0',
            '-map', '1:a',
            '-c:v', 'libx265',
            '-crf', "$($Config.UpscaleCrf)",
            '-preset', 'slow',
            '-c:a', 'copy',
            '-shortest',
            $outputFile
        )

        $muxResult = Invoke-ArmTool -Name ffmpeg -Config $Config -Arguments $muxArgs
        if ($muxResult.ExitCode -ne 0) {
            throw "ffmpeg mux failed with exit code $($muxResult.ExitCode)"
        }

        $success = $true
        return New-ArmResult -Success $true -Properties ([ordered]@{ OutputFile = $outputFile; InterlaceType = $interlaceType }) -Error $null
    } catch {
        Write-ArmLog -Level ERROR -Message "Invoke-Upscale failed for $InputFile : $_" -Config $Config
        return New-ArmResult -Success $false -Properties ([ordered]@{ OutputFile = $null; InterlaceType = $interlaceType }) -Error "$_"
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
