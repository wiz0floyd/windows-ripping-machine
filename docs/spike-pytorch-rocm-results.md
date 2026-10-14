# Spike results: PyTorch/ROCm (Windows) vs ncnn/Vulkan

Date: 2026-10-13. Machine: RX 7800 XT (gfx1101), scratch dir `C:\dev\wrm-torch-spike` (5.85 GB, venv 5.76 GB; left in place).

## Recommendation: GO (pending user visual verdict, step 7)

fp16 + batch 4 ran at about 3.3x the ncnn runner, with 15 minutes of flat VRAM and no driver events. Not implemented; needs approval.

## Commands run

```
uv python install 3.12 (UV_PYTHON_INSTALL_DIR=C:\dev\wrm-torch-spike\py); uv venv --python 3.12 venv
uv pip install rocm_sdk_core / rocm_sdk_devel / rocm_sdk_libraries_custom 7.2.1 + rocm-7.2.1.tar.gz   (repo.radeon.com/rocm/windows/rocm-rel-7.2.1)
uv pip install torch 2.9.1+rocm7.2.1, torchvision 0.24.1+rocm7.2.1, torchaudio 2.9.1+rocm7.2.1 (same host), spandrel==0.4.2, numpy
checkpoint 2xLiveActionV1_SPAN_490000.pth from the pinned jcj83429/upscaling commit; SHA256 8b166c75...b572f7 matches tools/models/README.md
clip: ffmpeg -ss 1800 -frames:v 240 from "Cast Away (2000) - 480p.mkv" (720x480, 29.97 fps, not 24)
smoke.py, ncnn_frame.py, torch_upscale.py (copy of tools/ncnn_upscale.py, inference swapped), bench.ps1
```

## Step 1: install/detection (PASS, no driver update needed)

```
2.9.1+rocm7.2.1 7.2.53211-158bd99533 True AMD Radeon RX 7800 XT
```

## Step 2: smoke (PASS)

Output 1440x960 in fp32 and fp16. fp16 vs fp32 max abs diff 0.000416 (0..1 scale), mean 6.1e-05, max 1 level in uint8.

## Step 3: correctness vs ncnn (PASS), frame 0

```
ncnn shape (960, 1440, 3) torch shape (960, 1440, 3)
max abs diff 2.0 mean abs diff 0.0037796585648148147 PSNR dB 72.35572382380329
```

Torch fp32 vs ncnn (ncnn is fp16 on the GPU, so not bit-identical).

## Step 4: speed (3 runs each, same session, `--benchmark`, 240 frames)

fps is end-to-end (decode + model + readback, warm-up excluded), the same definition the ncnn runner uses. Torch `model_fps` (model + transfer only) was equal to fps in every run, so decode is not a bottleneck.

| Variant | Runs (fps) | Median fps | vs ncnn | Peak VRAM alloc / reserved (MiB) |
|---|---|---|---|---|
| ncnn | 17.77, 17.54, 17.61 | 17.61 | 1.0x | n/a (not measured) |
| fp32 | 28.20, 28.23, 28.34 | 28.23 | 1.6x | 1291 / 1456 |
| fp16 | 43.46, 44.35, 43.90 | 43.90 | 2.5x | 645 / 734 |
| fp16 + channels_last | 43.15, 41.99, 41.87 | 41.99 | 2.4x | 645 / 734 |
| fp32, batch 4 | 6.69, 12.62, 12.65 | 12.62 | 0.7x | 5100 / 6120 |
| fp16, batch 4 | 57.14, 57.32, 59.97 | 57.32 | 3.3x | 2544 / 3094 |
| fp16 + channels_last, batch 4 | 58.67, 59.88, 57.71 | 58.67 | 3.3x | 2544 / 3094 |

fp32 batch 4 is slower than batch 1 (likely memory pressure/kernel choice); first run was an outlier. channels_last gives no gain. The earlier 13.5 fps ncnn figure was not reused; the same-session ncnn median is 17.6 fps. Pass bar was 1.3x: fp16 b1 and fp16 b4 both pass.

## Step 5: stability (PASS)

fp16 batch 4, benchmark mode, 15 min (16:51 to 17:06), 46,560 frames: model fps 57.80 to 59.01 (mean 58.15); `vram_reserved_mib` 3094 on all 91 samples (flat). No System-log errors/criticals and no Display/amdkmdag events in the window (Event Viewer queried via Get-WinEvent). Not tested: encoding path under load for 15 min, other drivers.

## Step 6: model reach (SKIPPED)

No heavier model (DAT/HAT) was tried. The spike brief only authorises the AMD wheels and the pinned checkpoint as downloads; an OpenModelDB model needs a separate decision.

## Step 7: visual check (USER ACTION)

Both made from the same clip, 1920x1080 libx264 crf 12 via each runner's default encode path:
- `C:\dev\wrm-torch-spike\out\torch-fp16.mkv` (fp16, batch 4)
- `C:\dev\wrm-torch-spike\out\ncnn.mkv`

Verdict on quality is the user's; no equivalence claim made. Numerically, frame 0 differs by PSNR 72 dB.

## Failures / caveats

- Python 3.12 was not installed; fetched with uv into the scratch dir (user approved).
- AMD calls Windows PyTorch a preview; the RX 7800 XT is not in AMD's product list but was detected and ran.
- Install burden: about 5.8 GB venv (ROCm SDK wheels ~1.3 GB download, torch ~ multi-GB), Python 3.12 pinned, ROCm 7.2.1 and torch 2.9.1 pinned, AMD driver 26.2.2 per the guide.
- Clip is 29.97 fps, not 24 as in the brief; frame count is 240.
- Disabling `wrm-upscaler` was denied (access denied), so the worker was stopped by killing it once its queue file vanished; that skipped the post-processing for one job, which was finished by hand.

## If GO: outline (do not implement without approval)

- New engine in a sibling map to `$script:ArmNcnnEngineModels`, e.g. `$script:ArmTorchEngineModels` (liveaction first).
- `Invoke-ArmTool` tool name `torch` running `tools/torch_upscale.py` (promote the spike runner, keep the ncnn args/progress contract).
- `setup.ps1`: `Install-TorchUpscaler` (Python 3.12 venv, pinned AMD wheel URLs, spandrel==0.4.2, checksum the .pth).
- `SPEC.md` config schema and `config.example.psd1` keys (e.g. `TorchPath`, `UpscaleTorchDtype`, `UpscaleTorchBatch`).
- `tests/stubs/stub-torch.ps1` and Pester tests for the plan/args.
- Keep ncnn as fallback engine; consider fp16 batch 4 default with VRAM ~3 GB.
