# Windows Ripping Machine

[![CI](https://github.com/wiz0floyd/windows-ripping-machine/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/wiz0floyd/windows-ripping-machine/actions/workflows/ci.yml)

A native Windows replacement for the Linux Automatic Ripping Machine: insert a disc → rips automatically → results land on your NAS, tray ejects, you're notified. Optional stage 2 upscales DVD rips using AI (OpenProteus / Anime4K on your GPU).

## Architecture

- **DiscWatcher** (hidden Scheduled Task): runs at logon, watches optical drives via WMI events.
  - **Video discs** (DVD/Blu-ray): passes through `makemkvcon` → metadata lookup (TMDb) → staged rip copies to NAS video share.
  - **Audio CDs**: through `freaccmd` → FLAC with MusicBrainz tags → NAS music share.
  - **Data discs**: logged as a warning and you get a notification ("Data Disc Detected"); no rip is attempted.
- **Upscale-Worker** (optional, separate task): processes queued DVD rips with ffmpeg deinterlacing (IVTC or bwdif) → AI upscaling on the GPU (OpenProteus 2x via ncnn/Vulkan for live action, Anime4K via video2x for animation) → high-bitrate x265 encode → sample-first review gate or automatic.
- **Web UI** (separate task `wrm-webui`): a status page at `http://localhost:8765/` on this machine — see [Web UI](#web-ui).
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
   - **Requires Administrator.** Registering Scheduled Tasks needs elevation, so `setup.ps1`
     self-elevates via a UAC "Run as Administrator" prompt if it isn't already running elevated.
     Run it from a local console or RDP session so that prompt can be shown.
   - If run over SSH/WinRM or another non-interactive/remote session (where UAC has no desktop
     to prompt on), `setup.ps1` fails fast with guidance instead of hanging — re-run it from an
     elevated local/RDP pwsh session instead.

2. **Upscale stage only:** `setup.ps1` creates a Python venv (needs Python 3.10+ on PATH) at `C:\ProgramData\wrm\venv` and downloads the OpenProteus 2x model (SHA256-verified) to `C:\ProgramData\wrm\models`. For the animation engine (Anime4K) also download and install [Video2X 6.x](https://github.com/k4yt3x/video2x/releases) from GitHub (CLI installer; adds `video2x.exe` to PATH). Targets Video2X 6.4+ (verify flags match your release). Engines are chosen per content type with `UpscaleLiveAction` / `UpscaleAnimation` in `config.psd1`; the queue item's `ContentType` (`Animation` / `LiveAction`) picks which one runs. DiscWatcher fills it from the TMDb genre (see "Animation vs live action" below); you can also set `"ContentType": "Animation"` in a queue file by hand.

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

### Correcting a video title/year before the NAS move
As soon as a video disc's label is resolved (before the long rip even starts), a
`metadata.json` file is written into the rip's staging directory with the auto-resolved
`Title`/`Year` (blank if TMDb didn't find a confident match). While the rip is running you
can open that file and hand-edit `Title` and/or `Year`; right before the finished rip is
renamed and moved to the NAS, your edited values are used instead of the original guess (if
you leave `Title` blank or don't touch the file, the original auto-resolved result — or the
label+date fallback — is used as-is). This is useful when TMDb picks the wrong movie or no
match was found from the disc label alone.

The [Web UI](#web-ui) offers the same thing as a form: while a video disc is **Ripping**, its
card on the page has "Edit title / year" fields prefilled from `metadata.json`, a live preview
of the NAS folder name (invalid filename characters are stripped exactly as in the real
rename), and a Save button that writes `metadata.json` for you. Title is required; Year is blank
or 4 digits. Once the rip is Moving/Complete the form is read-only (the folder name is already
decided), and audio CDs have no form. Hand-editing the file keeps working. (The form does not
touch `ContentType`; saving a title there preserves whatever `ContentType` the file holds.)

### Animation vs live action (upscale engine)
`metadata.json` also carries `ContentType` (`Animation` or `LiveAction`) and `ContentTypeNote`.
`ContentType` is `Animation` when the matched TMDb movie has the Animation genre, else
`LiveAction` (no TMDb match, or a TV-only disc, also means `LiveAction`). It is copied into
the upscale queue item, where it selects `UpscaleAnimation` (Anime4K) instead of
`UpscaleLiveAction` (OpenProteus). With `LlmDisambiguationEnabled`, the local LLM is also asked
whether the picked movie is animated; if it disagrees with TMDb's genre, TMDb's value is kept
and `ContentTypeNote` records both answers (and the log gets a WARN), so you can look at it
during the sample review. To override, edit `"ContentType"` in `metadata.json` during the rip
(case-insensitive; you can change only that field and leave `Title` blank). Invalid values are
ignored with a WARN in the log. Changing `Title` alone does not re-query TMDb: the original
`ContentType` is kept.

### Upscale a DVD (if `UpscaleDvds=true` in config)
- When a DVD rip completes, a sample (2 min) is auto-generated if `AutoUpscale=false` (default).
- Review the sample → approve (rename from `<name>.awaiting-review` to `<name>.json` in the queue folder) → full upscale runs at off-peak hours.
- Or set `AutoUpscale=true` to skip the review gate and upscale everything automatically.
- Result: `Title (Year) [AI upscale 1080p].mkv` alongside the original.

### Web UI
Open `http://localhost:8765/` on the ripping machine (or over RDP). The page shows:
- **Active rip** — the disc being ripped right now: state (Detected → Ripping → Moving),
  drive, disc label, resolved title, and staging directory.
- **Rip history** — finished rips with their NAS destination, or the error if one failed.
- **Upscale queue** — every upscale job and its state (Queued, Sampling, AwaitingReview,
  Upscaling, Complete, Failed), with the sample path while it awaits review.
- **Today's log** — the last 200 lines of `wrm-<date>.log`.

It refreshes itself every 5 seconds. Upscale rows have buttons: **Approve** (job awaiting review,
same as renaming `.awaiting-review` to `.json`), **Retry** (failed job, `.failed` back to `.json`, sample
gate runs again) and **Cancel** (queued or awaiting review; deletes the queue file after a confirm).
Jobs the worker is processing (Sampling/Upscaling) have no buttons. The manual renames keep working.
The active video rip also has an **Edit title / year** form (see "Correcting a video title/year
before the NAS move"); renaming a rip that already reached the NAS is not supported.

It listens on `localhost` only (not reachable from other devices), started at logon by the
`wrm-webui` Scheduled Task. Change the port with `WebUiPort`, or set `WebUiEnabled = $false`
to turn it off. Use `http://localhost:<port>/` exactly: `127.0.0.1` is rejected with
`400 Invalid Hostname`.

### Configuration
Edit `config\config.psd1` (created at setup):
- `NasVideoPath`, `NasMusicPath` — UNC paths to your NAS shares.
- `TmdbApiKey` — optional; without it, folder names use disc label + date.
- `HaWebhookUrl` — optional Home Assistant webhook for notifications.
- `UpscaleDvds`, `AutoUpscale`, `UpscaleActiveHours` — upscale behavior.
- `WebUiEnabled`, `WebUiPort` — the local status page.
- `WebUiOpenOnDisc` (default `$true`) — open the dashboard in your default browser when a disc is
  detected (never in `-Simulate`, or when `WebUiEnabled` is `$false`).

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

Web UI browser tests use Playwright and need Node.js 20+ (test-only):

```powershell
cd tests/browser
npm ci
npx playwright install chromium
npx playwright test
```

CI runs this same suite automatically on every push and pull request (see the badge above and `.github/workflows/ci.yml`).

## Upscale review workflow

When a DVD rip completes and `UpscaleDvds=true`, the Upscale-Worker daemon processes it on a 60-second poll cycle (respecting `UpscaleActiveHours`).

**Sample-first review (default: `AutoUpscale=false`):**
1. A 2-minute sample is extracted from 10:00–12:00 in the ripped video
2. Sample is preprocessed (deinterlaced if interlaced/telecined via ffmpeg), then upscaled with the configured engine (OpenProteus for live action, Anime4K for animation) 
3. Upscale-Worker renames the queue file from `.json` to `.awaiting-review` and notifies you with the sample path
4. You review the sample for quality (deinterlace method, upscale artifacts, audio sync)
5. If approved: rename `.awaiting-review` back to `.json` in the queue folder (`C:\rips\upscale-queue\` by default)
6. Upscale-Worker picks up the renamed file and runs the full upscale pipeline off-peak
7. Result lands as `Title (Year) [AI upscale 1080p].mkv` alongside the original rip

**Automatic upscale (set `AutoUpscale=true`):**
- Skips the 2-minute sample and review gate; queued rips are upscaled in full immediately

**Preprocessing logic:**
- **Telecined** (3:2 pulldown cadence, common on older broadcasts): applies fieldmatch + yadif deinterlace + decimate
- **Interlaced** (TFF/BFF fields): applies bwdif deinterlace, only to frames idet flags as interlaced
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
   - Content type: for an animated DVD, `metadata.json` in the staging dir shows `"ContentType": "Animation"`, the queue JSON has the same, and the web UI / log shows `Engine=anime4k`; for a live-action DVD `LiveAction` / `openproteus`. Also run `Invoke-Pester -Path tests/manual` (live TMDb + LLM) and record the ContentType lines it prints.

**Note:** MakeMKV beta key expires ~monthly. If rips fail with "Key expired" in logs, refresh the key at https://www.makemkv.com or purchase a license.

## Troubleshooting

Check `C:\rips\logs\wrm-<date>.log` for detailed progress and errors.

Key failure cases:
- **MakeMKV key expired:** watcher detects and notifies (refresh key or buy license at makemkv.com).
- **NAS unreachable:** robocopy fails; disc stays in drive, staging kept for forensics.
- **Upscale queue file stuck:** rename from `.failed` back to `.json` after checking logs.

## Project structure

See `SPEC.md` for full module contracts and `docs/PLAN.md` for architecture rationale.
