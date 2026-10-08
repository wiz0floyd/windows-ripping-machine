# Upscaler spike, October 2026

Results of the model, VRAM, parallelism and encoder spike that led to content-type engine routing (OpenProteus 2x ncnn runner for live action, Anime4K via Video2X for animation). The tables below are copied verbatim from issue [#24](https://github.com/wiz0floyd/windows-ripping-machine/issues/24) so the numbers survive the issue being edited; the issue's comments hold the follow-up list.

Context: the upscale stage ran at about 0.5 fps in practice. The model (`realesrgan-plus` x4) had been chosen from specs, not measured.

## Method

- Hardware: AMD Radeon RX 7800 XT, 16 GB VRAM.
- Test material: 240-frame, 720x480 DVD clips cut from existing NAS rips. Live action is *Cast Away*; animation is *Snoopy Come Home*.
- Upscalers: Video2X 6.4 (ncnn/Vulkan) for the model bake-off, the shipped `tools/ncnn_upscale.py` runner for the OpenProteus VRAM and parallel-runner measurements.
- fps figures are model-only unless noted ("wall" includes the encode).
- Quality judgments are one frame per clip, by eye. The encoder comparison used SSIM/PSNR against the upscaler's own output.
- Single short clips, so dark-scene banding and long-run behavior were not assessed.
- End-to-end timing used real 120 s samples through `Invoke-Upscale -SampleOnly`.

## 1. Model bake-off (x2 neural models vs the current x4)

| Config | Live fps (model-only) | Anim fps (model-only) | Notes |
|---|---|---|---|
| realesrgan-plus x4 (was default) | 1.1 (wall, incl. encode) | not run | output 2880x1920, then shrunk to 1080p |
| realesr-animevideov3 x2 | 22.2 | 23.2 | cleaner flat colors, some banding on live fabric |
| realcugan x2 (models-se) | 21.0 | 22.5 | natural on live action, anime-trained |
| OpenProteus Compact x2 (live-action model) | 24.0 | 23.8 | most natural on live action, keeps grain/texture |
| AniSD SPAN x2 | 22.3 | 22.1 | smoother, a bit plasticky on live action |
| Anime4K (libplacebo `anime4k-v4-a+a`) | 37.4 | 59.7 | sharpest, over-sharpened on live action |

All x2 neural models run at the same speed, so the choice is quality. Quality judgments are one frame per clip, by eye. Maintainer preference: sharper over softer for 480p on a modern TV; OpenProteus preferred for live action.

## 2. VRAM vs the llama chat model

- llama chat model (Ministral-3-14B, 98k ctx, `-ngl 99`) occupies ~13.6-13.8 GB of 16 GB when loaded; it unloads after 30 min idle (`--sleep-idle-seconds 1800`).
- Video2X x2 upscalers: peak 14.2-15.1 GB total with llama loaded. The shipped ncnn runner: ~0.5 GB of its own, 13.9 GB total with llama loaded.
- No slowdown with llama resident (runner 17.0 fps both ways; Video2X 18.27 vs 18.23 fps).
- The earlier 0.5 fps was not explained by VRAM contention in these tests; the x4 path is the likelier cause.

## 3. Parallel upscale runners (same clip, N concurrent)

| Runners | Total fps | Per runner |
|---|---|---|
| 1 | 16.2 | 16.2 |
| 2 | 26.5 | 13.3 |
| 3 | 29.5 | 9.8 |

All fit in VRAM. Two give ~1.6x aggregate; a third adds little.

## 4. Final-encode options (1080p, 240 frames; SSIM/PSNR vs the upscaler's own output)

| Encoder | fps | Size | SSIM | PSNR |
|---|---|---|---|---|
| libx265 crf16 slow (current) | 10.5 | 8.3 MB | 0.9939 | 50.1 |
| libx265 crf16 medium | 26.9 | 7.4 MB | 0.9934 | 49.5 |
| hevc_amf quality cqp 18 | 201 | 9.0 MB | 0.9935 | 49.8 |
| hevc_amf quality cqp 22 | 287 | 5.3 MB | 0.9917 | 48.2 |

`hevc_amf` VBR (`-rc vbr_peak`) failed with an ffmpeg/AMF error in this test. Single short clip; dark-scene banding not assessed.

## 5. End-to-end timing (real 120 s samples through `Invoke-Upscale -SampleOnly`)

~6-7 minutes per 120 s sample (366-409 s). The x265 `-preset slow` encode runs at 10.9-14.5 fps and dominates; stages are serial. Extrapolates to roughly 6-7 h per feature, which fits the 23:00-08:00 window only barely.

## Findings fixed alongside the spike

- Soft-telecined MakeMKV rips decode at 23.976 fps but carry a 29.97 header; video2x and the runner trust the header, so a 120 s window came out 96.6 s and `-shortest` clipped the audio (video ~25% fast). Fixed with `Get-VideoFrameRate` + `-fps_mode cfr -r` in preprocess.
- `Invoke-ArmTool`'s default 3600 s timeout would kill any full-length upscale/encode; upscale steps now pass 86400.
- Anamorphic DVDs (SAR 853:720) need output size from DAR, plus `setsar=1` in the final mux.

## Environment

Read locally on the machine that ran the spike (2026-10-07).

| Component | Value |
|---|---|
| GPU | AMD Radeon RX 7800 XT, 16 GB |
| Video2X | 6.4.0 (`C:\Program Files\Video2X`, `video2x.exe --version` prints `Video2X version 6.4.0`) |
| ffmpeg | `ffmpeg version 8.1.2-full_build-www.gyan.dev Copyright (c) 2000-2026 the FFmpeg developers` |
| upscale-ncnn-py | 1.2.0 (pinned in `tools/requirements-ncnn.txt`, with numpy 2.5.3 and sympy 1.14.0) |
| Runner Python | 3.13.13 (venv at `C:\ProgramData\wrm\venv`) |
| OpenProteus model archive | `2x_OpenProteus_Compact_i2_70K.tar.gz` from TNTwise/real-video-enhancer-models; SHA256 `0d96689273650613726ebae4482cdc56943f46e819f99109054d0ca325d6a7c7` (the value `setup.ps1` pins) |

SHA256 of the extracted OpenProteus model files in `C:\ProgramData\wrm\models`:

| File | Bytes | SHA256 |
|---|---|---|
| `openproteus-x2.bin` | 1205752 | `FD1BA2A0061FE6AB37182BB88A88F9C6A99DA2A4F31119FCCF8B38725C4B8309` |
| `openproteus-x2.param` | 3495 | `7C5AEC3347D1614048E3F3AFA853FFB4D2A84304E5F18C27CF900AE467F05934` |

## See also

- `SPEC.md`, "Config schema" (upscale keys) and `Invoke-Upscale`
- `docs/PLAN.md`, Stage 2
