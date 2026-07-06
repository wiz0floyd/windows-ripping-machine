# Windows Ripping Machine

[![CI](https://github.com/wiz0floyd/windows-ripping-machine/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/wiz0floyd/windows-ripping-machine/actions/workflows/ci.yml)

A native Windows replacement for the Linux Automatic Ripping Machine: insert a disc → rips automatically → results land on your NAS, tray ejects, you're notified. Optional stage 2 upscales DVD rips using AI (Real-ESRGAN on your GPU).

## Architecture

- **DiscWatcher** (hidden Scheduled Task): runs at logon, watches optical drives via WMI events.
  - **Video discs** (DVD/Blu-ray): passes through `makemkvcon` → metadata lookup (TMDb) → staged rip copies to NAS video share.
  - **Audio CDs**: through `freaccmd` → FLAC with MusicBrainz tags → NAS music share.
  - **Data discs**: logged as unsupported.
- **Upscale-Worker** (optional, separate task): processes queued DVD rips with ffmpeg deinterlacing (IVTC or bwdif) → AI upscaling (video2x Real-ESRGAN ncnn/Vulkan) on the GPU → high-bitrate x265 encode → sample-first review gate or automatic.
- All work respects the logged-in user's NAS SMB credentials and audio stack (nothing touches Windows audio).

## Setup

1. **Clone and configure:**
   ```powershell
   cd <path-to-cloned-repo>
   .\setup.ps1
   ```
   - Installs `makemkvcon` (MakeMKV), `freaccmd` (fre:ac), and `ffmpeg` via `winget`.
   - Prompts for NAS UNC paths (`\\nas\media\import\movies`, etc.), optional TMDb/HA webhook URLs.
   - Creates staging directories, log folder.
   - Registers hidden Scheduled Tasks to start at logon.

2. **Manual step (Upscale stage only):** Download and install [Video2X 6.x](https://github.com/k4yt3x/video2x/releases) from GitHub (CLI installer; adds `video2x.exe` to PATH). Targets Video2X 6.4+ (verify flags match your release).

3. **Verify installation** (simulate mode — no disc or NAS required):
   ```powershell
   # Run a quick smoke test with all stubs
   Invoke-Pester -Path tests/Common.Tests.ps1 -Passthru
   
   # Or run the full test suite
   Invoke-Pester -Path tests
   ```

4. **Cleanup** (if you need to re-run setup):
   ```powershell
   .\setup.ps1 -Uninstall
   ```

## Usage

### Normal operation
- Insert a disc → DiscWatcher detects it → logs progress to `C:\rips\logs\wrm-<date>.log` → files appear on NAS → toast/HA notification.
- Results folder: `\\nas\media\import\movies\Title (Year)\` or `\\nas\media\import\music\Artist\Album\`.

### Upscale a DVD (if `UpscaleDvds=true` in config)
- When a DVD rip completes, a sample (2 min) is auto-generated if `AutoUpscale=false` (default).
- Review the sample → approve (rename from `<name>.awaiting-review` to `<name>.json` in the queue folder) → full upscale runs at off-peak hours.
- Or set `AutoUpscale=true` to skip the review gate and upscale everything automatically.
- Result: `Title (Year) [AI upscale 1080p].mkv` alongside the original.

### Configuration
Edit `config\config.psd1` (created at setup):
- `NasVideoPath`, `NasMusicPath` — UNC paths to your NAS shares.
- `TmdbApiKey` — optional; without it, folder names use disc label + date.
- `HaWebhookUrl` — optional Home Assistant webhook for notifications.
- `UpscaleDvds`, `AutoUpscale`, `UpscaleActiveHours` — upscale behavior.

Full options are documented in `SPEC.md`.

## Testing

```powershell
# Install test dependencies
Install-Module Pester -Scope CurrentUser -Force -MinimumVersion 5.0
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force

# Run Pester tests
Invoke-Pester -Path tests

# Run code quality checks
Invoke-ScriptAnalyzer -Path src -Recurse
```

Tests use fixtures and stubs (fake MakeMKV output, etc.) so no real disc or NAS access is needed.

CI runs this same suite automatically on every push and pull request (see the badge above and `.github/workflows/ci.yml`).

## Upscale review workflow

When a DVD rip completes and `UpscaleDvds=true`, the Upscale-Worker daemon processes it on a 60-second poll cycle (respecting `UpscaleActiveHours`).

**Sample-first review (default: `AutoUpscale=false`):**
1. A 2-minute sample is extracted from 10:00–12:00 in the ripped video
2. Sample is preprocessed (deinterlaced if interlaced/telecined via ffmpeg), then upscaled via video2x Real-ESRGAN 
3. Upscale-Worker renames the queue file from `.json` to `.awaiting-review` and notifies you with the sample path
4. You review the sample for quality (deinterlace method, upscale artifacts, audio sync)
5. If approved: rename `.awaiting-review` back to `.json` in the queue folder (`C:\rips\upscale-queue\` by default)
6. Upscale-Worker picks up the renamed file and runs the full upscale pipeline off-peak
7. Result lands as `Title (Year) [AI upscale 1080p].mkv` alongside the original rip

**Automatic upscale (set `AutoUpscale=true`):**
- Skips the 2-minute sample and review gate; queued rips are upscaled in full immediately

**Preprocessing logic:**
- **Telecined** (3:2 pulldown cadence, common on older broadcasts): applies fieldmatch + yadif deinterlace + decimate
- **Interlaced** (TFF/BFF fields): applies bwdif deinterlace
- **Progressive** (no interlacing): passes through as-is

Intermediate files are encoded lossless (ffv1) to avoid compounding generation loss before the AI upscale. Final encode uses libx265 at the quality level specified by `UpscaleCrf` (default: 16, high quality / near-transparent).

**Queue file format:**
```json
{ "Source": "C:\\rips\\staging\\Title.mkv", "DestDir": "\\\\nas\\media\\import\\movies\\Title (Year)" }
```

On error, the queue file is renamed to `.failed`; check logs and rename back to `.json` after fixing the issue.

## Acceptance checklist (manual)

The following tests require physical media and cannot be automated. Insert each disc type and verify the full rip-to-NAS workflow:

1. **Blu-ray disc:**
   - Insert a Blu-ray movie disc
   - Watch logs: `Get-Content C:\rips\logs\wrm-$(Get-Date -Format yyyyMMdd).log -Tail 20 -Wait`
   - Verify `.mkv` files appear under `\\nas\media\import\movies\Title (Year)\`
   - Tray ejects automatically
   - Toast notification appears (or HA webhook fires if configured)

2. **DVD disc:**
   - Repeat test 1 with a DVD movie (same verification)
   - Log should show deinterlace classification (Telecined/Interlaced/Progressive)

3. **Audio CD:**
   - Insert an audio CD with metadata (e.g., from MusicBrainz)
   - Verify tagged `.flac` files appear under `\\nas\media\import\music\Artist\Album\`
   - Check that artist/album metadata was extracted correctly

4. **Reboot and task auto-start:**
   - Reboot the machine
   - Verify Scheduled Task `wrm-watcher` started automatically at logon
   - Repeat test 1 or 2 to confirm the daemon is running post-reboot

5. **Upscale workflow** (requires `UpscaleDvds=true` in config):
   - Complete a DVD rip (test 2)
   - Check `C:\rips\upscale-queue\` for a `.awaiting-review` file (if `AutoUpscale=false`)
   - Open the sample MKV at the path in the notification — review image quality, deinterlace method, audio sync (2-minute clip from 10:00–12:00)
   - If satisfied: rename `.awaiting-review` back to `.json`
   - Monitor logs; full upscale should complete off-peak (respecting `UpscaleActiveHours`)
   - Final upscaled MKV lands as `Title (Year) [AI upscale 1080p].mkv` alongside the original

**Note:** MakeMKV beta key expires ~monthly. If rips fail with "Key expired" in logs, refresh the key at https://www.makemkv.com or purchase a license.

## Troubleshooting

Check `C:\rips\logs\wrm-<date>.log` for detailed progress and errors.

Key failure cases:
- **MakeMKV key expired:** watcher detects and notifies (refresh key or buy license at makemkv.com).
- **NAS unreachable:** robocopy fails; disc stays in drive, staging kept for forensics.
- **Upscale queue file stuck:** rename from `.failed` back to `.json` after checking logs.

## Project structure

See `SPEC.md` for full module contracts and `docs/PLAN.md` for architecture rationale.
