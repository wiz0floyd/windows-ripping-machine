# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Dev workflow

- **Always invoke scripts and tests via `pwsh`, never `powershell.exe`.** The codebase relies on multi-segment `Join-Path` (PS7+ syntax); under Windows PowerShell 5.1 this throws a `ParameterBindingException` at Pester *discovery* time, which looks like a mass test failure but is purely a shell-version mismatch. This machine also has a built-in Pester 3.4.0 (Windows PowerShell's default module path) alongside a user-installed 5.8.0 — 5.1 loads 3.4.0 first, producing the same misleading error. The fix is always `pwsh`, not `Import-Module Pester -RequiredVersion`.
- Run the full suite: `pwsh -NoProfile -Command "Invoke-Pester -Path tests -Passthru | Select-Object TotalCount,PassedCount,FailedCount,SkippedCount | Format-List"`.
- Run a single module's tests: `Invoke-Pester -Path tests\Rip-VideoDisc.Tests.ps1`.
- Lint: `Invoke-ScriptAnalyzer -Path src -Recurse`. CI treats only `Severity -eq 'Error'` as blocking — Warning/Information findings are expected and don't fail the build (see footguns).
- CI (`.github/workflows/ci.yml`, `windows-latest`) runs both of the above on every push to `main` and every PR — mirror them locally before pushing.
- Primary dev loop: set `Simulate = $true` in `config\config.psd1` to route `Invoke-ArmTool` to `tests/stubs/` and exercise the whole pipeline (disc detect → rip → naming → upscale → NAS transfer → notify) with no hardware or NAS access, then flip back to `$false` before a real-disc test.
- `setup.ps1` is idempotent and safe to re-run: it skips writing `config.psd1` if one exists and skips scheduled tasks already registered. Check current state with `Get-ScheduledTask -TaskName "wrm-*"` rather than assuming a rerun is needed.
- To validate a scheduled task without waiting for logon: `Start-ScheduledTask -TaskName "wrm-watcher"`, then check `Get-ScheduledTaskInfo`/task `State`.

## Architecture orientation

- Everything that shells out to an external tool goes through `Invoke-ArmTool` (`src/Common.ps1`) — this is the *only* seam between real execution and `tests/stubs/`. Any new external tool call that bypasses it is untestable under `Simulate`.
- Pipeline functions (`Invoke-VideoRip`, `Invoke-AudioRip`, `Move-ToNas`, etc.) never throw — they return `@{ Success=$false; Error=<msg> }` so the watcher's event loop survives individual failures. Preserve this convention when adding new pipeline steps.
- Two independent long-running processes, each its own Scheduled Task (`wrm-watcher`, `wrm-upscaler`): `DiscWatcher.ps1` and `Upscale-Worker.ps1`. They never talk directly — they hand off through the filesystem queue in `UpscaleQueueDir`, where a file's extension (`.json` → `.awaiting-review`/`.failed`) *is* the state machine.
- The project is named `wrm` everywhere in code (mutex, log file prefix, scheduled task names, env vars) — the repo directory name `wslc-arm` is a leftover from an abandoned WSL-based approach and should not be used as a naming convention when writing new code or docs.
- Full module contracts and signatures live in `SPEC.md` — read it before touching a module's public function shape.

## Known footguns

- **`powershell.exe` vs `pwsh`** and **Pester version shadowing** (3.4.0 built-in vs 5.8.0 installed) — see Dev workflow above; both produce the same misleading `ParameterBindingException`.
- **`setup.ps1` scheduled-task registration can fail on a stale `$env:USERDOMAIN`.** The task principal is built as `"$env:USERDOMAIN\$env:USERNAME"`; if `$env:USERDOMAIN` doesn't match `$env:COMPUTERNAME` (e.g. reports `WORKGROUP`), `Register-ScheduledTask` fails with a SID-mapping error ("No mapping between account names and security IDs was done"). Align `$env:USERDOMAIN` to `$env:COMPUTERNAME` if this specific error appears.
- **fre:ac's real winget install path doesn't match the documented default.** `config.example.psd1` shows `C:\Program Files\fre-ac\freaccmd.exe`, but winget actually installs it as a portable app under `AppData\Local\Microsoft\WinGet\Packages\enzo1982.freac_...\freac-<ver>-x64\freaccmd.exe`. Correct `FreacCmdPath` after a winget install.
- **Video2X has no winget package** — it must be installed manually from GitHub releases (`k4yt3x/video2x`); `setup.ps1` only prints a manual-step notice for it.
- **8.3 short-path mismatches break path-string comparisons.** `Move-ToNas` originally compared `Get-ChildItem`'s resolved `FullName` against a raw path string via `Substring`; this breaks whenever the raw string resolves to an 8.3 short form (e.g. `$env:TEMP` → `RUNNER~1` on GitHub-hosted Windows runners) while `FullName` returns the long form. Always resolve a path to `(Get-Item $path).FullName` before comparing it against another resolved path.
- **`Invoke-ScriptAnalyzer -EnableExit` exits on any diagnostic, not just errors**, despite its help text implying otherwise. Filter explicitly (`$results | Where-Object Severity -eq 'Error'`) and exit on that count instead, or CI will fail on pre-existing, non-blocking Warning/Information findings.
