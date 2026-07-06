# Windows-Native Automatic Ripping Pipeline ("wrm")

## Context

Goal: insert a disc into the PC's SATA Blu-ray drive → it rips automatically → finished files land on the NAS SMB share, while the Windows session stays fully interactive (audio stack must remain Windows) and no new hardware is bought.

Running ARM itself in WSL/Hyper-V/VMware was investigated and ruled out:
- **WSL2** never exposes optical drives (`/dev/sr0` does not exist; `wsl --mount` is disk-class only; `usbipd-win` is USB-only and the drive is SATA). Confirmed by ARM issue #422 and WSL issues #2633/#6134.
- **Hyper-V** has no raw SCSI passthrough for optical drives; MakeMKV needs `/dev/sg*`-level SCSI for AACS.
- **VMware Workstation** single-drive passthrough has widely-reported SCSI errors on Blu-ray; the reliable fix (full SATA controller PCIe passthrough) isn't available in desktop Workstation.

**Decision (user-confirmed):** replicate ARM's core loop natively on Windows. Only the disc read needs the drive, and `makemkvcon.exe` runs natively with full LibreDrive access. Confirmed choices: raw lossless MakeMKV remuxes (no transcode), audio CD support included, folder naming via online metadata lookup (TMDb for video, MusicBrainz for CDs) with disc-label fallback.

**Addition (user-requested):** optional AI upscaling of DVD rips using a local model on the Radeon RX 7800 XT. Video2X 6.x (Real-ESRGAN via ncnn/Vulkan) runs natively on AMD GPUs on Windows — no CUDA or ROCm required. Runs as a separate low-priority queue stage so it never blocks the rip loop.

## Architecture

```
[Disc inserted]
     │  WMI Win32_VolumeChangeEvent (arrival) + poll fallback
     ▼
disc-watcher (PowerShell, hidden Scheduled Task, runs as logged-in user)
     │  classify disc: audio CD (no filesystem) vs video (UDF/CDFS)
     ├─ video ──► makemkvcon mkv disc:N all → C:\rips\staging\<label>\
     │              │ TMDb lookup: label → "Title (Year)" (fallback: label + date)
     │              ▼
     │           robocopy → \\<nas>\<video-import>\Title (Year)\
     └─ audio ──► freaccmd → FLAC + MusicBrainz tags → staging
                    │
                    ▼
                 robocopy → \\<nas>\<music-import>\Artist\Album\
     then: verify copy, clean staging, eject tray, notify (toast + optional Home Assistant webhook)
```

Runs as the logged-in user so NAS SMB credentials and the interactive session are inherited; nothing touches the audio stack.

### Stage 2 (optional, DVDs): local AI upscaling on the RX 7800 XT

```
DVD rip finishes (and UpscaleDvds = $true, or file dropped in queue folder)
     ▼
upscale-worker (separate Scheduled Task, low priority, configurable active hours)
     │ 1. ffmpeg idet scan → classify: telecined film / true interlaced / progressive
     │ 2. IVTC (fieldmatch+decimate → 23.976p) or bwdif deinterlace accordingly
     │      (skipping this bakes combing artifacts into the upscale)
     │ 3. video2x CLI: Real-ESRGAN (realesr-general-v3) via ncnn/Vulkan → 3x (~1440×1080 / 2160×1080)
     │ 4. encode libx265 CRF 16 (high bitrate so upscaled detail survives)
     ▼
NAS: Title (Year)/Title (Year) [AI upscale 1080p].mkv  — original remux always kept
```

Sample-first gate: each title first produces a 2-minute upscaled sample clip for user review (`-SampleOnly`); the full run (est. several hours to overnight per movie on the 7800 XT) only proceeds per user approval or when `AutoUpscale = $true`. Upscale quality on live action is an aesthetic judgment (shimmer/oversharpening are real risks), so the user stays in the loop by default.

## Repository layout (new; `C:\dev\wrm`, will `git init`)

```
wrm/
├── config/config.psd1          # all user settings (template checked in as config.example.psd1)
├── src/
│   ├── DiscWatcher.ps1         # entry point: event loop, disc classification, dispatch
│   ├── Rip-VideoDisc.ps1       # makemkvcon wrapper: scan, rip, parse progress/errors
│   ├── Rip-AudioCd.ps1         # freaccmd wrapper: FLAC + MusicBrainz
│   ├── Resolve-Title.ps1       # clean disc label → TMDb search → "Title (Year)"; offline fallback
│   ├── Move-ToNas.ps1          # robocopy w/ verify, staging cleanup
│   ├── Send-Notification.ps1   # Windows toast + optional HA webhook
│   └── Upscale-Worker.ps1      # queue: idet classify → IVTC/bwdif → video2x → x265 → NAS
├── setup.ps1                   # installs deps (winget), creates dirs, registers Scheduled Task
├── tests/                      # Pester tests + simulation stubs (fake makemkvcon/freaccmd)
└── README.md
```

## Key config values (`config.psd1`)

- `NasVideoPath`, `NasMusicPath` (UNC) — **needed from user at setup**
- `StagingDir` (default `C:\rips\staging`, needs ~60 GB free), `MinTitleLengthSec` (default 600), `MakeMkvConPath`, `FreacCmdPath`, `TmdbApiKey` (optional; blank ⇒ label naming), `HaWebhookUrl` (optional), `EjectWhenDone`, `RipAllTitles`
- Upscale stage: `UpscaleDvds` (default off), `AutoUpscale` (default off ⇒ sample-first review), `UpscaleActiveHours` (e.g. 23:00–08:00), `Video2xPath`, `UpscaleModel` (default realesr-general-v3), `UpscaleCrf` (default 16)

## External prerequisites (user-supplied, flagged at setup)

1. **MakeMKV** (`winget install GuinpinSoft.MakeMKV`) — free beta key must be refreshed ~monthly or a $50 license bought; watcher detects an expired key and notifies rather than failing silently.
2. **fre:ac** (`winget install enzo1982.freac`) for audio CDs.
3. **TMDb API key** (free) for movie naming — optional, graceful fallback without it.
4. NAS UNC paths + working SMB credentials for the logged-in user.
5. **Video2X 6.x** (GitHub release installer; CLI `video2x.exe`) and **ffmpeg** (`winget install Gyan.FFmpeg`) — upscale stage only.

## Implementation steps

1. `git init`; scaffold repo, `config.example.psd1`, README.
2. `Rip-VideoDisc.ps1`: parse `makemkvcon -r info disc:N` robot output (disc name, type, titles), then `makemkvcon -r --minlength=N mkv disc:N all <staging>`; surface progress to log; detect key-expired/read errors.
3. `Rip-AudioCd.ps1`: `freaccmd` → FLAC with MusicBrainz metadata into staging.
4. `Resolve-Title.ps1`: strip disc-label noise (`_`, `DISC_1`, studio prefixes), TMDb `/search/movie`, confidence check; fallback `<LABEL>_<yyyy-MM-dd>`.
5. `Move-ToNas.ps1`: `robocopy /E /Z /NP /R:3` staging → NAS, compare file sizes, delete staging on success only.
6. `DiscWatcher.ps1`: `Register-WmiEvent Win32_VolumeChangeEvent` (EventType 2) + 30 s poll fallback; classify (no-filesystem ⇒ audio CD; UDF/CDFS ⇒ video via makemkvcon); serialize rips (one at a time); eject via Shell.Application; notify on success/failure.
7. `Send-Notification.ps1`: BurntToast-free native toast (WinRT) + optional HA webhook POST.
8. `setup.ps1`: winget installs, dir creation, config prompts (NAS paths, TMDb key), register hidden Scheduled Task "wrm-watcher" (at logon, logged-in user).
9. `Upscale-Worker.ps1`: queue folder watcher as its own low-priority Scheduled Task; ffmpeg `idet` interlace classification → IVTC (`fieldmatch,decimate`) or `bwdif` → `video2x` (Real-ESRGAN ncnn/Vulkan) → `libx265 -crf 16` mux; `-SampleOnly` 2-min clip mode; deliver `[AI upscale 1080p]` variant next to the original on the NAS; toast/HA notify with sample path for review.
10. Pester tests + `-Simulate` mode: stub rippers copy fixture files so the full pipeline (classify → "rip" → name → robocopy → notify) runs without a disc; upscale stage gets a short test clip fixture to exercise the real ffmpeg/video2x chain end-to-end.
11. Commit; no remote exists, so work stays in the local repo (per background-job rules, will note location instead of opening a PR).

## Verification plan (stated up front, per Karpathy tiers)

- **V1 (automated):** Pester unit tests for label cleaning, TMDb response parsing, makemkvcon robot-output parsing, robocopy result handling; full `-Simulate` end-to-end run against a temp "NAS" folder (and against the real NAS UNC if reachable); PSScriptAnalyzer clean; upscale chain run against a bundled short interlaced test clip, verifying Vulkan picks up the 7800 XT (`video2x` device listing) and output resolution/duration match.
- **V2 (user checkpoint — physical drive can't be automated):** acceptance test script in README:
  1. Insert a Blu-ray → watch log → MKVs appear under `\\nas\...\Title (Year)\` → tray ejects → toast fires.
  2. Insert a DVD → same.
  3. Insert an audio CD → tagged FLACs on NAS music path.
  4. Reboot → task auto-starts → repeat test 1.
  5. Upscale: rip a DVD with `UpscaleDvds` on → review the 2-min sample clip (aesthetic call is V3 — user-owned) → approve → full upscale lands on NAS beside the original.
  Task is done only when the user confirms these pass.

## Out of scope / future

- HandBrake transcode stage (user chose lossless remux; a WSL2/Docker watch-folder transcoder can be bolted on later without touching this pipeline).
- ARM-in-VMware experiment (documented dead-end unless controller passthrough becomes available).
- TV-series disc episode naming (TMDb TV matching is unreliable from labels; folders fall back to label naming).
- Upscaling Blu-rays or adding temporal-consistency/frame-interpolation models (RIFE) — revisit after DVD upscale quality is validated.
- QTGMC (VapourSynth) deinterlacing — highest quality but a heavy toolchain; start with ffmpeg IVTC/bwdif and upgrade only if sample review shows deinterlacing artifacts.
