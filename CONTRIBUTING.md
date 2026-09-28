# Contributing

Thanks for your interest in improving the Windows Ripping Machine.

## Development setup

1. Clone the repo and run `.\setup.ps1` to install dependencies (`makemkvcon`, `freaccmd`, `ffmpeg` via winget) and register the scheduled tasks. See `README.md` for full setup steps. `setup.ps1` needs Administrator rights (it self-elevates via UAC) and will fail fast with guidance rather than hang if run from a non-interactive/remote session (e.g. SSH) — run it from a local console or RDP session instead.
2. Install test tooling:
   ```powershell
   Install-Module Pester -Scope CurrentUser -Force -MinimumVersion 5.0
   Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
   ```
3. Use **PowerShell 7+ (`pwsh`)**, not Windows PowerShell 5.1 (`powershell.exe`). This repo relies on multi-segment `Join-Path` and Pester 5, both of which break under 5.1.
4. For the web UI browser tests only: **Node.js 20+** (CI uses 24). The ripping machine itself never needs Node.
   ```powershell
   cd tests/browser
   npm ci
   npx playwright install chromium
   ```

## Project layout

- `src/` — PowerShell modules (DiscWatcher, rip pipelines, Upscale-Worker, NAS transfer, TMDb naming).
- `tests/` — Pester tests with fixtures and simulate-mode stubs; no real disc or NAS access required.
- `tests/browser/` — Playwright specs for the web UI (`src/WebUi.ps1`); they start their own server on `http://localhost:18765/` against a temp config.
- `config/` — user configuration (`config.psd1`), not checked in with real values.
- `SPEC.md` — module contracts; `docs/PLAN.md` — architecture rationale.

## Running tests

```powershell
# CI-equivalent (tests/manual makes live TMDb/LLM calls and is excluded)
$c = New-PesterConfiguration; $c.Run.Path = 'tests'; $c.Run.ExcludePath = '*\manual\*'; Invoke-Pester -Configuration $c
Invoke-ScriptAnalyzer -Path src -Recurse

# Web UI browser tests
cd tests/browser; npx playwright test
```

All simulate-mode tests must pass before submitting a change. If your change touches a physical-media workflow (disc detection, ripping, NAS transfer, upscale), also work through the manual acceptance checklist in `README.md` and note the results in your PR description — these steps can't be automated.

## Submitting changes

1. Fork the repo and create a feature branch off `main`.
2. Keep changes scoped to a single logical unit of work.
3. Add or update Pester tests for any behavior change.
4. Run the test suite and `PSScriptAnalyzer` locally before opening a PR.
5. Open a PR against `main` describing what changed and why, and include any manual test results for physical-media paths.

## Reporting issues

Include your `wrm-<date>.log` excerpt (from `C:\rips\logs\`), the disc/media type involved, and your `config.psd1` settings (redact NAS paths/keys if needed).
