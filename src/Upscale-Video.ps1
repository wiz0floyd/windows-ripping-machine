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

<#
.SYNOPSIS
    Get a video file's display aspect ratio (DAR) as a number (width / height).

.DESCRIPTION
    Runs `ffmpeg -hide_banner -i <file>` via Invoke-ArmTool (ffmpeg exits non-zero
    with no output file; that is expected and ignored) and parses the video stream
    line, e.g. `720x480 [SAR 853:720 DAR 853:480]`. DVD rips are usually anamorphic,
    so the DAR (16:9 here), not the frame size (3:2), decides the correct output
    width. Falls back to the frame size's ratio when no DAR is printed, then to 16:9
    (with a WARN) when nothing parses.

.OUTPUTS
    [double]
#>
function Get-VideoDisplayAspect {
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $InputFile,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    $result = Invoke-ArmTool -Name ffmpeg -Config $Config -Arguments @('-hide_banner', '-i', $InputFile)
    $text = (@($result.StdErr) -join "`n")

    # ffmpeg prints the DAR either bracketed after the size (`720x480 [SAR 8:9 DAR 4:3]`)
    # or as a trailing field (`720x480, SAR 853:720 DAR 853:480` - what ffv1 gives), and
    # an mpeg2 stream can print both (codec-level first, stream-level last). The last
    # DAR on the Video: line is the effective one.
    $videoLine = [regex]::Match($text, 'Video:[^\r\n]*')
    if ($videoLine.Success) {
        $dars = [regex]::Matches($videoLine.Value, 'DAR\s*(\d+):(\d+)')
        if ($dars.Count -gt 0) {
            $last = $dars[$dars.Count - 1]
            if ([int]$last.Groups[2].Value -gt 0) {
                return [double]$last.Groups[1].Value / [double]$last.Groups[2].Value
            }
        }
        $size = [regex]::Match($videoLine.Value, '(\d{2,5})x(\d{2,5})')
        if ($size.Success -and [int]$size.Groups[2].Value -gt 0) {
            return [double]$size.Groups[1].Value / [double]$size.Groups[2].Value
        }
    }

    Write-ArmLog -Level WARN -Message "Get-VideoDisplayAspect: could not parse aspect ratio for $InputFile; assuming 16:9" -Config $Config
    return 16.0 / 9.0
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
        $result = Invoke-ArmTool -Name ffmpeg -Config $Config -Arguments @(
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
    Deinterlace/IVTC, upscale (Video2X libplacebo/Anime4K or Real-ESRGAN), and re-encode a DVD-sourced video.

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
    UpscaleShader, UpscaleCrf, NcnnPath, NcnnModelDir, etc).

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

        [switch] $SampleOnly
    )

    # Invoke-ArmTool's default 3600s timeout would kill a feature-length upscale/encode.
    $longTimeoutSec = 86400

    $interlaceType = $null
    $engine = $null
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
        # Force the intermediate to a constant frame rate that matches its timestamps.
        # Soft-telecined rips decode at 23.976 but carry a 29.97 header; without this
        # every downstream tool re-times the frames at 29.97 (video ~25% fast, audio
        # clipped by -shortest). Telecined sources are skipped: decimate already
        # emits the correct constant rate.
        if ($interlaceType -ne 'Telecined') {
            $trueRate = Get-VideoFrameRate -InputFile $InputFile -Config $Config
            if ($trueRate) {
                $preArgs += @('-fps_mode', 'cfr', '-r', $trueRate)
            } else {
                Write-ArmLog -Level WARN -Message "Invoke-Upscale: could not measure the frame rate of $InputFile; trusting the container header (video may be mistimed on soft-telecined sources)" -Config $Config
            }
        }
        $preArgs += @('-c:v', 'ffv1', '-an', $preprocessedFile)

        $preResult = Invoke-ArmTool -Name ffmpeg -Config $Config -Arguments $preArgs -TimeoutSec $longTimeoutSec
        if ($preResult.ExitCode -ne 0) {
            throw "ffmpeg preprocess failed with exit code $($preResult.ExitCode)"
        }

        # --- (c) AI upscale with the engine configured for this content type ---
        $engine = if ($ContentType -eq 'Animation') {
            Get-UpscaleSetting -Config $Config -Name 'UpscaleAnimation' -Default 'anime4k'
        } else {
            Get-UpscaleSetting -Config $Config -Name 'UpscaleLiveAction' -Default 'openproteus'
        }
        $upscaledFile = Join-Path $tempDir 'upscaled.mkv'

        if ($engine -eq 'realesrgan') {
            # Legacy path. realesrgan-plus/-anime only ship x4 weights under video2x 6.4
            # (see SPEC.md); catch the mismatch with a clear error instead of an opaque
            # video2x CLI failure.
            if ($Config.UpscaleModel -in @('realesrgan-plus', 'realesrgan-plus-anime') -and [int]$Config.UpscaleScale -ne 4) {
                throw "UpscaleModel '$($Config.UpscaleModel)' only supports UpscaleScale=4, but UpscaleScale=$($Config.UpscaleScale) was configured"
            }
            $upscaleResult = Invoke-ArmTool -Name video2x -Config $Config -TimeoutSec $longTimeoutSec -Arguments @(
                '-i', $preprocessedFile,
                '-p', 'realesrgan',
                '--realesrgan-model', $Config.UpscaleModel,
                '-s', "$($Config.UpscaleScale)",
                '-o', $upscaledFile
            )
            $engineLabel = 'video2x'
        } elseif ($engine -in @('openproteus', 'anime4k')) {
            # Target size from the display aspect ratio, not the frame size: DVD rips are
            # anamorphic (720x480 with SAR 853:720 is 16:9), and video2x keeps the SAR.
            $targetHeight = [int](Get-UpscaleSetting -Config $Config -Name 'UpscaleHeight' -Default 1080)
            $dar = Get-VideoDisplayAspect -InputFile $preprocessedFile -Config $Config
            $targetWidth = 2 * [int][math]::Round($targetHeight * $dar / 2)

            if ($engine -eq 'openproteus') {
                $runner = Join-Path $PSScriptRoot '..' 'tools' 'ncnn_upscale.py'
                $modelBase = Join-Path (Get-UpscaleSetting -Config $Config -Name 'NcnnModelDir' -Default 'C:\ProgramData\wrm\models') 'openproteus-x2'
                if (-not (Get-UpscaleSetting -Config $Config -Name 'Simulate' -Default $false)) {
                    foreach ($required in @($runner, "$modelBase.param", "$modelBase.bin")) {
                        if (-not (Test-Path -LiteralPath $required)) {
                            throw "OpenProteus engine needs '$required' - run setup.ps1 to install the ncnn runner and model"
                        }
                    }
                }
                $ffmpegPath = Get-UpscaleSetting -Config $Config -Name 'FfmpegPath' -Default 'ffmpeg'
                $ffprobeName = 'ffprobe'
                if ($ffmpegPath -match '[\\/]') {
                    $ffprobeName = Join-Path (Split-Path -Parent $ffmpegPath) 'ffprobe.exe'
                }
                $upscaleResult = Invoke-ArmTool -Name ncnn -Config $Config -TimeoutSec $longTimeoutSec -Arguments @(
                    '-I', $runner,
                    '--input', $preprocessedFile,
                    '--param', "$modelBase.param",
                    '--bin', "$modelBase.bin",
                    '--scale', '2',
                    '--out-width', "$targetWidth",
                    '--out-height', "$targetHeight",
                    '--ffmpeg', $ffmpegPath,
                    '--ffprobe', $ffprobeName,
                    '--output', $upscaledFile
                )
                $engineLabel = 'ncnn upscale'
            } else {
                $shader = Get-UpscaleSetting -Config $Config -Name 'UpscaleShader' -Default 'anime4k-v4-a+a'
                $upscaleResult = Invoke-ArmTool -Name video2x -Config $Config -TimeoutSec $longTimeoutSec -Arguments @(
                    '-i', $preprocessedFile,
                    '-p', 'libplacebo',
                    '--libplacebo-shader', $shader,
                    '-w', "$targetWidth",
                    '-h', "$targetHeight",
                    '-o', $upscaledFile
                )
                $engineLabel = 'video2x upscale'
            }
        } else {
            throw "Unknown upscale engine '$engine' for ContentType $ContentType (expected openproteus, anime4k, or realesrgan)"
        }

        if ($upscaleResult.ExitCode -ne 0) {
            throw "$engineLabel failed with exit code $($upscaleResult.ExitCode) (engine: $engine)"
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
            '-map', '1:a'
        )
        if ($engine -ne 'realesrgan') {
            # Upscaled to the exact display size above; drop the source's anamorphic SAR
            # (video2x carries it through) so players don't stretch the frame twice.
            $muxArgs += @('-vf', 'setsar=1')
        }
        $muxArgs += @(
            '-c:v', 'libx265',
            '-crf', "$($Config.UpscaleCrf)",
            '-preset', 'slow',
            '-c:a', 'copy',
            '-shortest',
            $outputFile
        )

        $muxResult = Invoke-ArmTool -Name ffmpeg -Config $Config -Arguments $muxArgs -TimeoutSec $longTimeoutSec
        if ($muxResult.ExitCode -ne 0) {
            throw "ffmpeg mux failed with exit code $($muxResult.ExitCode)"
        }

        $success = $true
        return New-ArmResult -Success $true -Properties ([ordered]@{ OutputFile = $outputFile; InterlaceType = $interlaceType; Engine = $engine }) -Error $null
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
