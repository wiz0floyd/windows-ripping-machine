<#
.SYNOPSIS
    Scenario matrix and helpers for the Invoke-Upscale golden-argument tests (issue #31).
    Dot-source; not a test file.

.DESCRIPTION
    tests/fixtures/golden-upscale-args.json holds the ffmpeg/video2x/ncnn argument
    lists that Invoke-Upscale produced for each scenario below BEFORE the plan
    refactor (captured from main at f1eac7a). The plan-driven Invoke-Upscale must
    reproduce them exactly. Each scenario is a hashtable:
      Id          unique key in the golden file
      Interlace   Progressive | Interlaced | Telecined (selects the idet fixture)
      Sample      $true => -SampleOnly
      ContentType LiveAction | Animation
      Config      overrides merged over the base config (see New-UpscaleGoldenConfig)
      Sar         source sample aspect ratio 'n:d' (the frame size is always 720x480)
      RateStderr  frame-rate probe stderr ('' => the probe measures nothing)
                  Telecined scenarios use 29.97 (hard telecine); a decoded 23.976 trips the
                  soft-telecine guard (#30).
    Re-recorded for #30: two mid-feature idet probes (600 s and 50% of the 8627.9 s
    fixture duration, 1000 frames each), the Interlaced idet,bwdif chain, and the
    frame-rate probe now also runs for Telecined sources.
#>

function Get-UpscaleGoldenScenarios {
    $rate24 = 'frame= 1439 fps=0.0 q=-0.0 Lsize=N/A time=00:01:00.02 bitrate=N/A speed= 300x'
    $rate30 = 'frame= 1798 fps=0.0 q=-0.0 Lsize=N/A time=00:01:00.00 bitrate=N/A speed= 300x'
    $scenarios = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($interlace in 'Progressive', 'Interlaced', 'Telecined') {
        foreach ($engine in 'openproteus', 'anime4k', 'realesrgan') {
            foreach ($sample in $false, $true) {
                $mode = if ($sample) { 'sample' } else { 'full' }
                $scenarios.Add(@{
                    Id = "$interlace-$engine-$mode"; Interlace = $interlace; Sample = $sample
                    ContentType = 'LiveAction'; Config = @{ UpscaleLiveAction = $engine }
                    Sar = '853:720'; RateStderr = $(if ($interlace -eq 'Telecined') { $rate30 } else { $rate24 })
                })
            }
        }
    }
    $scenarios.Add(@{ Id = 'Progressive-rate-unmeasured'; Interlace = 'Progressive'; Sample = $false; ContentType = 'LiveAction'; Config = @{}; Sar = '853:720'; RateStderr = '' })
    $scenarios.Add(@{ Id = 'Interlaced-true-30fps'; Interlace = 'Interlaced'; Sample = $false; ContentType = 'LiveAction'; Config = @{}; Sar = '853:720'; RateStderr = $rate30 })
    $scenarios.Add(@{ Id = 'dar-4x3-openproteus'; Interlace = 'Progressive'; Sample = $false; ContentType = 'LiveAction'; Config = @{}; Sar = '8:9'; RateStderr = $rate24 })
    $scenarios.Add(@{ Id = 'dar-4x3-anime4k'; Interlace = 'Progressive'; Sample = $false; ContentType = 'Animation'; Config = @{}; Sar = '8:9'; RateStderr = $rate24 })
    $scenarios.Add(@{ Id = 'ffmpeg-dir-openproteus'; Interlace = 'Progressive'; Sample = $false; ContentType = 'LiveAction'; Config = @{ FfmpegPath = 'C:\tools\ffmpeg\bin\ffmpeg.exe' }; Sar = '853:720'; RateStderr = $rate24 })
    $scenarios.Add(@{ Id = 'height-720-anime4k-sample'; Interlace = 'Interlaced'; Sample = $true; ContentType = 'Animation'; Config = @{ UpscaleHeight = 720; UpscaleShader = 'anime4k-v4-b' }; Sar = '853:720'; RateStderr = $rate24 })
    $scenarios.Add(@{ Id = 'defaults-live'; Interlace = 'Progressive'; Sample = $false; ContentType = 'LiveAction'; Config = @{ _OmitEngines = $true }; Sar = '853:720'; RateStderr = $rate24 })
    $scenarios.Add(@{ Id = 'defaults-animation'; Interlace = 'Progressive'; Sample = $false; ContentType = 'Animation'; Config = @{ _OmitEngines = $true }; Sar = '853:720'; RateStderr = $rate24 })
    return $scenarios.ToArray()
}

# Base config for the golden scenarios; $Overrides win. '_OmitEngines' drops the engine
# keys so the built-in defaults (openproteus / anime4k) are exercised.
function New-UpscaleGoldenConfig {
    param([hashtable] $Overrides, [string] $LogDir)
    $config = @{
        Simulate          = $true
        LogDir            = $LogDir
        UpscaleLiveAction = 'openproteus'
        UpscaleAnimation  = 'anime4k'
        UpscaleHeight     = 1080
        UpscaleShader     = 'anime4k-v4-a+a'
        UpscaleModel      = 'realesr-animevideov3'
        UpscaleScale      = 2
        UpscaleCrf        = 16
        NcnnModelDir      = 'C:\models'
        FfmpegPath        = 'ffmpeg'
    }
    foreach ($key in $Overrides.Keys) {
        if ($key -eq '_OmitEngines') {
            $config.Remove('UpscaleLiveAction')
            $config.Remove('UpscaleAnimation')
        } else {
            $config[$key] = $Overrides[$key]
        }
    }
    return $config
}

# Normalise one recorded tool call so it is machine- and run-independent: the random
# temp dir, input/output dirs and repo root become placeholders.
function ConvertTo-UpscaleGoldenCall {
    param($Name, $Arguments, $TimeoutSec, [hashtable] $Paths)
    $tmpRoot = [regex]::Escape((Join-Path ([System.IO.Path]::GetTempPath()) 'wrm-upscale-'))
    $normalised = foreach ($a in @($Arguments)) {
        $s = "$a"
        $s = [regex]::Replace($s, "$tmpRoot[0-9a-fA-F-]{36}", '<TMP>', 'IgnoreCase')
        foreach ($k in @('InputFile', 'OutputDir', 'RepoRoot')) {
            $s = $s.Replace($Paths[$k], "<$k>")
        }
        # The runner path is built from $PSScriptRoot, whose spelling depends on how the
        # test dot-sourced the module (...\src vs ...\tests\..\src); canonicalise it.
        if ($s -match '[\\/]ncnn_upscale\.py$') { $s = '<RepoRoot>\src\..\tools\ncnn_upscale.py' }
        $s
    }
    [ordered]@{ Name = $Name; Args = @($normalised); TimeoutSec = $TimeoutSec }
}
