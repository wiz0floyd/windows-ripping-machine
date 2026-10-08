# Upscale benchmark harness (`tools/bench`)

Reproducible measurements for the upscale stage: encoder settings, engines, filter chains, and
(once #27/#28 land) concurrency and the streamed pipeline. It is not part of the pipeline, not in
CI, and runs only on the real machine (real NAS rips, real ffmpeg/ncnn/Video2X).

Results are committed under `docs/bench/` as CSV, so later issues cite rows instead of re-running.
Paths in this doc are relative to the repo root.

## Files

| Path | Role | In git |
|---|---|---|
| `tools/bench/Invoke-Bench.ps1` | Entry point. `-Mode Cut`, `-Mode Run` (default), `-Mode Frames` | yes |
| `tools/bench/Bench.Lib.ps1` | Functions only. Dot-sources `src/Common.ps1` and `src/Upscale-Video.ps1` | yes |
| `tools/bench/variants.psd1` | Checked-in variant definitions | yes |
| `tools/bench/samples.example.psd1` | Template for the sample manifest | yes |
| `tools/bench/samples.local.psd1` | Your sample manifest with NAS paths | no (gitignored) |
| `tools/bench/out/` | Clips, upscaled intermediates, encodes, `results.csv`, frames | no (gitignored) |
| `tests/Bench.Tests.ps1` | Pester tests (no tools run) | yes |

## Method

1. **Cut** (`-Mode Cut`): each sample is a stream-copy (`-c copy`) cut of its source rip, so the
   telecine and field structure survive. `-ss` snaps to the previous keyframe, so the clip can start
   a little early. `out/clips/<name>.json` records the requested and probed values.
2. **Run** (`-Mode Run`): for each sample and variant, the harness calls the shipping path:
   `Get-VideoSourceInfo`, `Get-InterlaceType`, `Get-VideoFrameRate`, `Get-UpscalePlan`,
   `Get-UpscalePreprocessArgumentList`, `Get-UpscaleEngineArgumentList`, then the encode.
   `Get-UpscaleEncodeArgumentList` handles libx265. `hevc_amf` has a harness-owned encode builder,
   because the shipping builder only emits libx265.
   - The upscaled intermediate (the reference for SSIM/PSNR, as in the #24 spike) is cached in
     `out/cache/<key>.mkv`. The key covers the sample, filter chain, engine, model, and target size.
     Encoder-only variants reuse it, and their rows set `UpscaleCached=true`.
   - Every external tool goes through `Invoke-ArmTool`.
   - `-SampleOnly` is not used. The clip is the sample.
3. **Score**: SSIM and PSNR, one ffmpeg pass each, of the encode against the cached intermediate.
   Output duration and the A/V last-pts delta come from ffprobe.
4. **Frames** (`-Mode Frames -FrameTimes 12.5,60`): PNGs at the same timestamps from the clip and
   every encoded variant, under `out/frames/<sample>/`, for the side-by-side visual reviews.

## Running

```powershell
# one-time: copy and fill in the NAS paths
Copy-Item tools/bench/samples.example.psd1 tools/bench/samples.local.psd1

./tools/bench/Invoke-Bench.ps1 -Mode Cut
./tools/bench/Invoke-Bench.ps1 -Mode Run -Sample castaway-dark -Variant x265-slow-crf16,amf-cqp18-10bit
./tools/bench/Invoke-Bench.ps1 -Mode Frames -Sample castaway-dark -FrameTimes 12.5,60,95
```

Each run appends one row per sample x variant to `out/results.csv`. A failed pair is written as a
row with `Status=error` and `Error` set; it does not stop the run.

## CSV columns

`Sample, Variant, Status, Error, ContentType, Engine, InterlaceType, Codec, Crf, Preset, Qp, Quality,
PixFmt, Width, Height, Frames, UpscaleSec, UpscaleCached, EncodeSec, UpscaleFps, WallFps, EncodeFps,
OutputBytes, Ssim, Psnr, OutputDurationSec, VideoLastPtsSec, AudioLastPtsSec, AvLastPtsDeltaSec,
Timestamp`

- `UpscaleFps` is model-only (`Frames / UpscaleSec`). `WallFps` is `Frames / (UpscaleSec + EncodeSec)`.
  `EncodeFps` is `Frames / EncodeSec`.
- `UpscaleSec` for a cached intermediate is the time recorded when it was first made. `UpscaleCached`
  says which case applies.
- Blank cells mean the value was not measured (for example, a metric line that ffmpeg did not print).

## Adding a sample

Add a hashtable to `Samples` in your local `samples.local.psd1`:

```powershell
@{ Name = 'castaway-dark'; Source = '\\NAS\video\Cast Away\title.mkv'; Start = 1800; Duration = 120 }
```

- `Name` must match `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`. It names the output files.
- `Start` and `Duration` are seconds. A 240-frame clip at 24 fps is `Duration = 10`, the size #24 used.
- Commit the sample's purpose in a comment, not its path. The NAS paths stay local.

Then run `-Mode Cut -Sample <name>`.

## Adding a variant

Add a hashtable to `Variants` in `tools/bench/variants.psd1`:

```powershell
@{ Name = 'x265-medium-crf18'; ContentType = 'LiveAction'; Encode = @{ Codec = 'libx265'; Crf = 18; Preset = 'medium' } }
@{ Name = 'amf-cqp22-10bit';   Encode = @{ Codec = 'hevc_amf'; Qp = 22; Quality = 'quality'; PixFmt = 'p010le' } }
```

- `Config` overrides the base config for this variant only, for example
  `Config = @{ UpscaleLiveAction = 'anime4k' }`.
- `PlanOverride = @{ Filter = 'yadif=mode=send_frame' }` replaces the deinterlace chain on the plan.
  Use it for the #30 filter comparisons. The key changes, so the intermediate is re-made.
- `Pipeline = 'streamed'` and `Concurrency = 2` are rejected until #28 and #27 land. Do not work
  around them with hand-written loops.

`Test-BenchVariant` checks every variant before any tool runs.

## Not yet implemented

- Concurrency (#27): aggregate throughput for N parallel jobs.
- Streamed pipeline (#28): rejected by validation.
- Peak VRAM and temp-disk peak: needs a background counter poller. Not in this harness yet.
- VMAF: needs an ffmpeg build with libvmaf. Not in this harness yet.
