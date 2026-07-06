# Contributing

Thanks for your interest in improving the Windows-Native Automatic Ripping Machine.

## Development setup

1. Clone the repo and run `.\setup.ps1` to install dependencies (`makemkvcon`, `freaccmd`, `ffmpeg` via winget) and register the scheduled tasks. See `README.md` for full setup steps.
2. Install test tooling:
   ```powershell
   Install-Module Pester -Scope CurrentUser -Force -MinimumVersion 5.0
   Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
   ```
3. Use **PowerShell 7+ (`pwsh`)**, not Windows PowerShell 5.1 (`powershell.exe`). This repo relies on multi-segment `Join-Path` and Pester 5, both of which break under 5.1.

## Project layout

- `src/` — PowerShell modules (DiscWatcher, rip pipelines, Upscale-Worker, NAS transfer, TMDb naming).
- `tests/` — Pester tests with fixtures and simulate-mode stubs; no real disc or NAS access required.
- `config/` — user configuration (`config.psd1`), not checked in with real values.
- `SPEC.md` — module contracts; `docs/PLAN.md` — architecture rationale.

## Running tests

```powershell
Invoke-Pester -Path tests
Invoke-ScriptAnalyzer -Path src -Recurse
```

All simulate-mode tests must pass before submitting a change. If your change touches a physical-media workflow (disc detection, ripping, NAS transfer, upscale), also work through the manual acceptance checklist in `README.md` and note the results in your PR description — these steps can't be automated.

## Submitting changes

1. Fork the repo and create a feature branch off `main`.
2. Keep changes scoped to a single logical unit of work.
3. Add or update Pester tests for any behavior change.
4. Run the test suite and `PSScriptAnalyzer` locally before opening a PR.
5. Open a PR against `main` describing what changed and why, and include any manual test results for physical-media paths.

## Reporting issues

Include your `wslc-arm-<date>.log` excerpt (from `C:\rips\logs\`), the disc/media type involved, and your `config.psd1` settings (redact NAS paths/keys if needed).
