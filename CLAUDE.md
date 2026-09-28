# CLAUDE.md

Orientation for Claude Code. Everything below is current; don't re-discover it — jump straight to the file you need.

## What this is

A Windows-native "Automatic Ripping Machine" in PowerShell 7. `DiscWatcher.ps1` watches optical drives, rips video discs with `makemkvcon` or audio CDs with `freaccmd`, stages locally, names video via TMDb (optionally validated by a local LLM), robocopies to a NAS SMB share, ejects, and notifies (toast + optional Home Assistant webhook). Optional stage 2: `Upscale-Worker.ps1` upscales DVD rips (ffmpeg deinterlace/IVTC → Video2X Real-ESRGAN → x265) behind a human review gate. Runs in the logged-in user's session as hidden Scheduled Tasks — no WSL/VMs (no optical passthrough; NAS creds/audio need the real session).

Pipeline: `DiscWatcher` → `Invoke-VideoRip` (calls `Resolve-Title` up front, writes `metadata.json`) / `Invoke-AudioRip` → `Resolve-TitleOverride` (user edits to `metadata.json`) → `Move-ToNas` → `Send-ArmNotification`. DVD + `UpscaleDvds=true` → queue file `<name>.json` in `UpscaleQueueDir` → `Upscale-Worker` (60s poll, only inside `UpscaleActiveHours`).

## Rules that aren't obvious from the code

- **`SPEC.md` is the authoritative contract** for every function signature, parameters, and return shape. Read the relevant section before module work; update it in the same change if a signature/behavior changes. Don't duplicate its details here.
- **Never call `makemkvcon`/`freaccmd`/`ffmpeg`/`video2x` directly** — go through `Invoke-ArmTool`, which routes to `tests/stubs/stub-<name>.ps1` when `$Config.Simulate`. This is what makes everything testable without hardware.
- Pipeline functions **don't throw** for expected failures — return `New-ArmResult` / `@{ Success=$false; Error=<msg> }` so the watcher loop survives. Exceptions = programmer errors only.
- `src/*.ps1` libraries are dot-sourced and have **no top-level side effects**. Only `DiscWatcher.ps1`, `Upscale-Worker.ps1`, `setup.ps1` run top-level logic, guarded by `if ($MyInvocation.InvocationName -ne '.')` so tests can dot-source their functions.
- Filenames: always sanitize via `ConvertTo-ArmSafeFileName` (the single canonical rule).
- Upscale review state machine (by filename in `UpscaleQueueDir`): `.json` → `.awaiting-review` (sample made) → user renames to `.json` (approved → full run) → deleted on success / `.failed` on error.
- Config: `config/config.psd1` (gitignored, real NAS paths/keys) loaded once via `Get-ArmConfig`; falls back to `config.example.psd1` with a WARN. New config keys go in `config.example.psd1` + SPEC.md "Config schema".
- This `CLAUDE.md` is shared (tracked); put personal/machine-specific notes in `CLAUDE.local.md` (gitignored). No `graphify-out/` exists here — skip the parent `C:\dev\CLAUDE.md` graphify step.

## How we work

- Shell: `pwsh` (7+), never Windows PowerShell 5.1 (breaks Pester 5 and multi-segment `Join-Path`).
- Git: branch off `main`, PR to `main` on `wiz0floyd/windows-ripping-machine` (`gh` CLI). One logical unit per PR; add/update Pester tests for every behavior change.
- Physical-media changes (disc detection, ripping, NAS transfer, upscale quality) can't be automated: work through README "Acceptance checklist (manual)" and record results in the PR description.
- CI (`.github/workflows/ci.yml`, `windows-latest`, Pester 5.8.0, PSScriptAnalyzer 1.25.0) runs on every push/PR. PSSA fails CI only on Severity=Error.

```powershell
# Full suite, CI-equivalent (excludes tests/manual, which makes LIVE TMDb + LLM calls)
$c = New-PesterConfiguration; $c.Run.Path = 'tests'; $c.Run.ExcludePath = '*\manual\*'; $c.Output.Verbosity = 'Detailed'; Invoke-Pester -Configuration $c

# Single file
Invoke-Pester -Path tests/Rip-VideoDisc.Tests.ps1

# Live LLM/TMDb regression (opt-in; needs real TmdbApiKey + local OpenAI-compatible server)
Invoke-Pester -Path tests/manual

# Lint
Invoke-ScriptAnalyzer -Path src -Recurse

# Whole pipeline with no disc/NAS (stubs + fixtures)
./src/DiscWatcher.ps1 -Simulate -Once
./src/Upscale-Worker.ps1 -Simulate -Once
```

Plain `Invoke-Pester -Path tests` also picks up `tests/manual` — use the configuration form above.

## Key files

| Path | What / public functions |
|---|---|
| `SPEC.md` | Module contracts, config schema, testing requirements (read first) |
| `docs/PLAN.md` | Architecture rationale/history |
| `README.md` | Setup, usage, "Upscale review workflow", "Acceptance checklist (manual)", "Troubleshooting" |
| `CONTRIBUTING.md` | Dev setup, PR expectations |
| `config/config.example.psd1` | All config keys with defaults and comments |
| `src/Common.ps1` | Foundation, dot-sourced by all: `Get-ArmConfig`, `Write-ArmLog`, `Invoke-ArmTool`, `Get-DiscType`, `New-ArmResult`, `ConvertTo-ArmSafeFileName` |
| `src/DiscWatcher.ps1` | Entry point (`-ConfigPath -Simulate -Once`): `Get-OpticalDriveLetters`, `Resolve-CurrentDisc`, `Invoke-DiscEject`, `New-UpscaleQueueEntry`, `Invoke-VideoDispatch`, `Invoke-AudioDispatch`, `Invoke-DiscDispatch`, `Invoke-DiscMutexDispatch`, `Update-ArmDiscWatcherState`, `Start-DiscWatcherLoop` |
| `src/Rip-VideoDisc.ps1` | `Invoke-VideoRip`, makemkvcon robot-output parsing (`ConvertFrom-MakeMkvRobotLine`, `ConvertTo-MakeMkvSeconds`, `Get-MakeMkvDriveInfo`, `Get-MakeMkvLongestTitleIndex`, `Test-MakeMkvExpiredKey`, `Write-MakeMkvProgress`), `Set-ArmMetadataFile` (lives here, though SPEC documents it under Resolve-Title) |
| `src/Rip-AudioCd.ps1` | `Invoke-AudioRip` |
| `src/Resolve-Title.ps1` | `Resolve-Title`, `Resolve-TitleOverride`, `Get-ArmCleanDiscLabel`, `ConvertTo-ArmTitleCase`, `Invoke-ArmTmdbSearch`, `Test-ArmTmdbAcceptance`, `Invoke-ArmLlmDisambiguation`, `ConvertTo-ArmFolderName` |
| `src/Move-ToNas.ps1` | `Move-ToNas`, `Invoke-Robocopy` |
| `src/Send-Notification.ps1` | `Send-ArmNotification` |
| `src/Upscale-Video.ps1` | `Get-InterlaceType`, `Invoke-Upscale` |
| `src/Upscale-Worker.ps1` | Entry point (`-ConfigPath -Simulate -Once`): `Test-ArmActiveWindow`, `Invoke-ArmUpscaleQueueItem`, `Invoke-ArmUpscaleQueuePass`, `Start-UpscaleWorker` |
| `setup.ps1` | Installer: winget deps, dirs, writes `config.psd1`, registers tasks; `-NonInteractive`, `-Uninstall`. Needs admin (self-elevates); fails fast over SSH |
| `tests/<Name>.Tests.ps1` | One per `src/<Name>.ps1` (+ `Setup.Tests.ps1`), success + failure paths |
| `tests/EndToEnd.Tests.ps1` | Runs both entry points `-Simulate -Once`, asserts NAS-root folder layout |
| `tests/manual/` | Live TMDb/LLM suite — excluded from CI |
| `tests/stubs/stub-{makemkvcon,freaccmd,ffmpeg,video2x}.ps1` | Simulate-mode tool stubs used by `Invoke-ArmTool` |
| `tests/fixtures/` | Recorded makemkvcon robot output (incl. expired key), ffmpeg `idet` samples (interlaced/progressive/telecined), `tmdb-search.json` |

Testing: no real tools or network in `tests/` — use stubs/fixtures or `Mock Invoke-RestMethod`.

## Runtime facts (default config)

- Logs: `C:\rips\logs\wrm-<yyyyMMdd>.log` · Staging: `C:\rips\staging` · Upscale queue: `C:\rips\upscale-queue`
- Single-flight named mutex `wrm-rip`; Scheduled Tasks `wrm-watcher`, `wrm-upscaler` (at logon, hidden `pwsh`)
- makemkvcon expired key → `Error='MAKEMKV_KEY_EXPIRED'` (special notification)
- NAS move failures are not retried; staging dir is kept for manual re-trigger
