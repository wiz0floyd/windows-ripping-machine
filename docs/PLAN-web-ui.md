# Web UI for rip status, manual metadata, and upscale jobs — Implementation Plan

Issue: #15 (title only, no body). This plan fills the gaps with stated assumptions;
items marked **[ASSUMPTION]** need confirmation before the dependent story starts.

**Verifiability tier: V2 overall.** Browser behavior (S2–S4) is automated with
Playwright, so S1–S3 are V1. S4 stays V2 only for its real-disc acceptance step.

## Why this isn't "just add a page"

What the code does today (verified by reading `src/`):

| Need | Current state | Gap |
|---|---|---|
| Rip status | Only log lines (`wrm-<date>.log`) + staging dirs | No structured job record; `Invoke-VideoDispatch` only learns `OutputDir` after `Invoke-VideoRip` returns, so "ripping now, at <dir>" is invisible |
| Upscale status | Queue file extension: `.json` → `.awaiting-review` → `.json` → deleted / `.failed` | `.json` means both *queued* and *running* (it keeps that name through a multi-hour `Invoke-Upscale`) |
| Manual metadata | `metadata.json` in staging dir, re-read by `Resolve-TitleOverride` right before the rename+NAS move | Editable only during the rip window; nothing lists which dirs are editable |
| Hosting | None | Neither entry point can host a listener: `Invoke-VideoDispatch` blocks for the whole rip, `Invoke-Upscale` blocks for hours |

Consequences: (1) a **job-state store** is a prerequisite, and (2) the UI is a **fourth
entry point** (`src/WebUi.ps1`) run as its own Scheduled Task.

## Design decisions

- **Server:** `System.Net.HttpListener` — no new dependency (Pode isn't on CI's
  `windows-latest`). Verified 2026-09-28 in a non-elevated `pwsh`: prefix
  `http://localhost:18765/` starts OK; `http://+:18766/` fails `Access is denied`.
  So localhost needs no setup changes; LAN would need `netsh http add urlacl` +
  firewall rule from (already elevated) `setup.ps1`.
- **Bind:** `http://localhost:<WebUiPort>/` only. **Decided 2026-09-28** (open
  question 1): the user confirmed localhost-only, since discs must be loaded
  physically at the machine anyway and RDP covers the rare remote check.
- **Testability:** listener loop is a thin shell; routing + handlers are pure functions
  `Invoke-ArmWebRequest -Method -Path -Body -Config -> @{Status;ContentType;Body}`,
  unit-tested in Pester without sockets (same pattern as the other thin entry points).
- **UI:** server-rendered HTML + a small inline `<script>` polling `/api/jobs` every
  5s. No build step, no npm. Every string from TMDb / disc labels is HTML-escaped
  (`[System.Net.WebUtility]::HtmlEncode`).
- **State store:** one JSON file per job in `StateDir\jobs\<id>.json`, written
  atomically (write `<id>.json.tmp` → `Move-Item -Force`) because the UI reads
  concurrently. Writers never throw (log WARN), matching the pipeline's
  no-throw contract. Job IDs are generated (`yyyyMMdd-HHmmss-<6 hex>`), never
  derived from user input.
- **Browser tests: Playwright** (`@playwright/test`, Chromium only) in
  `tests/browser/` with its own `package.json`, `playwright.config.ts`, and
  `*.spec.ts`. Pester only collects `*.Tests.ps1`, so the two suites don't collide.
  - Playwright's `webServer` launches `pwsh -File src/WebUi.ps1 -Simulate -ConfigPath
    <temp config>` on a fixed test port (`18765`), with `StateDir`, `StagingDir`,
    `UpscaleQueueDir`, `LogDir` and the NAS paths all under a per-run temp root.
  - `tests/browser/fixtures/seed.ps1` dot-sources `src/JobState.ps1` and writes job
    records plus matching queue/staging files, so specs seed state through the real
    library rather than hand-written JSON. Specs call it via `child_process`.
  - Specs that cross into the pipeline (approve → worker completes; metadata edit →
    NAS folder name) shell out to `DiscWatcher.ps1` / `Upscale-Worker.ps1 -Simulate
    -Once` against the same temp config.
  - Localhost only, no external network, which is consistent with the repo's
    "no network in tests" rule.
  - `.gitignore`: `tests/browser/node_modules/`, `test-results/`, `playwright-report/`.
  - CI: a new `browser` job on `windows-latest`: `actions/setup-node`,
    `npm ci`, `npx playwright install --with-deps chromium`, `npx playwright test`;
    upload `playwright-report/` as an artifact on failure.
  - CONTRIBUTING.md: add Node 20+ as a dev prerequisite (runtime stays
    PowerShell-only; Node is test-only).
- **Actions resolve by job ID only** against files the server enumerated itself —
  no request ever carries a filesystem path (prevents path traversal).

## Stories

Each story ships independently and leaves the system working.

### S1 — Job-state store + pipeline instrumentation (V1)

New library `src/JobState.ps1` (dot-sourceable, no side effects):

```powershell
New-ArmJob     -Kind <Rip|Upscale> -Properties <hashtable> -Config <hashtable> -> [string] JobId
Update-ArmJob  -JobId <string> -Properties <hashtable> -Config <hashtable>      # merge + atomic write; never throws
Get-ArmJob     -JobId <string> -Config <hashtable> -> [pscustomobject] | $null
Get-ArmJobList [-Kind <Rip|Upscale>] -Config <hashtable> -> [pscustomobject[]]  # newest first; skips unreadable files
```

Job record: `{ Id; Kind; State; Title; DiscLabel; DiscType; Drive; StagingDir;
DestDir; QueueFile; SamplePath; Error; Created; Updated; History[] }`.

States:
- Rip: `Detected → Ripping → Moving → Complete | Failed`
- Upscale: `Queued → Sampling → AwaitingReview → Upscaling → Complete | Failed`

Instrumentation:
- `Rip-VideoDisc.ps1` (`Invoke-VideoRip`): new optional `-JobId` param; next to the
  existing `Set-ArmMetadataFile` call (line ~364) set `State=Ripping; StagingDir;
  Title; DiscLabel`. This is the only place the staging dir is known mid-rip.
- `DiscWatcher.ps1`: create job in `Invoke-DiscDispatch`; update on
  Moving/Complete/Failed; `New-UpscaleQueueEntry` writes `JobId` into the queue JSON
  and creates the Upscale job (`Queued`).
- `Rip-AudioCd.ps1` / audio dispatch: status only (Ripping/Moving/Complete/Failed).
- `Upscale-Worker.ps1`: set `Sampling`/`Upscaling` **before** calling
  `Invoke-Upscale` (fixes the queued-vs-running ambiguity), `AwaitingReview` +
  `SamplePath` after the sample, `Complete`/`Failed` at the end. Queue files without
  a `JobId` (pre-existing) get one created on first touch.
- Retention: `Remove-ArmStaleJobs` deletes terminal-state records older than
  `JobHistoryDays`, called once per Upscale-Worker pass.

Config (+ SPEC schema + `config.example.psd1`): `StateDir = 'C:\rips\state'`,
`JobHistoryDays = 30`.

SPEC.md: add `JobState.ps1` contract; add `-JobId` to `Invoke-VideoRip` /
`Invoke-AudioRip`; queue-file shape `{Source;DestDir;JobId}`. Also fix the existing
drift: SPEC lists `Set-ArmMetadataFile` under Resolve-Title.ps1 but it lives in
`Rip-VideoDisc.ps1`.

Tests: `tests/JobState.Tests.ps1` (create/update/merge, atomic write leaves no
`.tmp`, corrupt file skipped, never throws on unwritable dir). Extend
`EndToEnd.Tests.ps1`: after `DiscWatcher.ps1 -Simulate -Once` a `Rip` job exists
with `State=Complete` and correct `DestDir`; after `Upscale-Worker.ps1 -Simulate
-Once` the upscale job is `AwaitingReview` (AutoUpscale off) / `Complete` (on).

**Done when:** `Invoke-Pester -Path tests` green, `Invoke-ScriptAnalyzer -Path src
-Recurse` zero errors, simulated E2E produces the job records above.

### S2 — Read-only status UI (V1, Playwright)

- `src/WebUi.ps1` entry point: `[-ConfigPath] [-Simulate] [-Once]`; `-Once` serves
  one request then exits (for tests). Library portion: `Invoke-ArmWebRequest` and
  render helpers.
- Routes: `GET /` (dashboard: active rip card, rip history table, upscale queue
  table), `GET /api/jobs[?kind=]` (JSON), `GET /api/jobs/<id>`, `GET
  /api/log?lines=200` (tail of today's `wrm-<date>.log`, read-only).
- `setup.ps1`: register `wrm-webui` Scheduled Task (same pattern as `wrm-upscaler`,
  line ~453), unregister on `-Uninstall`; print the URL.
- Config: `WebUiEnabled = $true`, `WebUiPort = 8765`.
- Docs: SPEC entry-point list, CLAUDE.md "three entry points" → four, README
  section "Web UI".

Tests: `tests/WebUi.Tests.ps1` — routing table, 404/405, JSON shape, HTML-escaping
of a `<script>` title, log tail bounds. `Setup.Tests.ps1` asserts the new task.
One socket-level smoke test: start `WebUi.ps1 -Once` on a random port,
`Invoke-WebRequest /api/jobs`, assert 200.

S2 also lands the Playwright scaffolding (config, seed script, CI job).
`tests/browser/dashboard.spec.ts`:
- The seeded Ripping, Complete and Failed rips each render with the right state
  badge; Queued and AwaitingReview upscale jobs appear in the queue table.
- A job whose title is `<img src=x onerror=alert(1)>` renders as literal text: no
  `dialog` event fires and there's no `img` element in the card.
- Polling: update a job via `seed.ps1` and the card changes state within 10s,
  with no page reload.
- Log panel shows the tail of the seeded log file.
- Empty state: no jobs → "No rips yet" message, no JS console errors
  (`page.on('console')` asserts zero `error` entries on every spec).

**Done when:** Pester + `npx playwright test` green locally and in CI, and
ScriptAnalyzer reports zero errors.

### S3 — Upscale job actions (V1, Playwright)

- `POST /api/jobs/<id>/approve`: only when state is `AwaitingReview`; renames
  `.awaiting-review → .json`, state → `Queued`.
- `POST /api/jobs/<id>/retry`: only when `Failed`; `.failed → .json` (clears
  `SampleGenerated` so the sample gate reruns — **[ASSUMPTION]**), state → `Queued`.
- `POST /api/jobs/<id>/cancel`: only when `Queued`/`AwaitingReview`; deletes the queue
  file, state → `Cancelled`.
- Refuse (409) any action on `Sampling`/`Upscaling` jobs — the worker holds that
  file.
- The sample clip path is shown with a copy button (streaming video over HTTP is
  deferred).
- CSRF: localhost-only + require header `X-WRM-Action: 1` on POSTs (a cross-origin
  form can't set custom headers without CORS preflight, which the server never
  grants).
- README review-gate section: document the button alongside the manual rename,
  which keeps working.

Tests: each action's valid-state and invalid-state (409) paths, unknown ID (404),
missing header (403), filesystem rename verified in `TestDrive:`.

`tests/browser/upscale-actions.spec.ts`:
- Approve: seed AwaitingReview → click Approve → badge shows Queued, the
  `.awaiting-review` file is gone and `.json` exists → run `Upscale-Worker.ps1
  -Simulate -Once` → the card shows Complete and the upscaled mkv exists in DestDir.
- Retry: seed Failed → click Retry → Queued, `.failed` renamed to `.json`.
- Cancel: seed Queued → click Cancel → confirm dialog accepted → Cancelled,
  queue file deleted.
- Buttons only render for valid states. With a job seeded as Upscaling, there
  are no action buttons, and a forced `request.post` returns 409.
- A POST from `page.request` without `X-WRM-Action` returns 403.

**Done when:** Pester + Playwright green locally and in CI.

### S4 — Manual metadata edit during a rip (V2)

- `POST /api/jobs/<id>/metadata` `{Title;Year}`: allowed only while the rip job is
  `Ripping`; writes `metadata.json` in the job's `StagingDir` (reuse
  `Set-ArmMetadataFile` with a new `-Force` switch to overwrite, since it
  deliberately skips when the file exists). `Resolve-TitleOverride` already picks it
  up — no pipeline change needed.
- UI: edit form on the active rip card, prefilled from the TMDb resolution, showing
  the resulting folder name via the same `ConvertTo-ArmSafeFileName` rule
  (server-side preview endpoint so the rule isn't duplicated in JS).
- Year validated as blank or 4 digits; Title non-blank.
- Video only: audio CDs have no `metadata.json` path.

Tests: edit accepted while Ripping, 409 when Moving/Complete, validation errors,
`-Force` overwrite behavior, E2E: pre-seed an edit and assert the NAS folder name.

`tests/browser/metadata-edit.spec.ts`:
- Seed a Ripping job whose `StagingDir` contains stub mkvs and `metadata.json`.
  The form is prefilled from it; typing a new title updates the folder-name
  preview (including stripping of `:` and other invalid characters).
- Save → `metadata.json` on disk holds the new Title/Year. Then drive the rest
  of the pipeline (`Resolve-TitleOverride` → rename → `Move-ToNas` against the
  temp NAS root, via a small `finish-rip.ps1` fixture that dot-sources
  `DiscWatcher.ps1`). Assert the NAS folder is `New Title (1999)`.
- Validation: blank title / `99` as year shows inline errors, and nothing is
  written.
- Seed the job as Moving: the form is read-only and a forced POST returns 409.

**Done when:** Pester + Playwright green in CI, **plus** the V2 real-disc step:
during a real DVD rip, change the title in the UI and confirm the NAS folder
uses it. This can't be automated (physical media), so record the result in
the PR description per README "Acceptance checklist (manual)".

## Deferred / out of scope

- Renaming a folder **after** it reached the NAS (would also need to rewrite the
  `Source`/`DestDir` of any upscale queue entry pointing at it). **Open question 2.**
- Streaming the sample clip in-browser; live progress % for rips (would need
  `PRGV` parsing to push into the job record — easy follow-up after S1).
- Editing audio CD tags.

## Out of scope (decided)

- LAN / phone access (urlacl + firewall rule + real auth). Resolved 2026-09-28:
  the user confirmed localhost-only (they load discs physically; RDP covers
  remote checks). Revisit only if that changes.

## Open questions (asked one at a time)

1. ~~Localhost-only or LAN?~~ Resolved: localhost-only (see above).
2. Should "update metadata" also cover already-moved rips (rename on the NAS),
   or only in-flight rips as planned?

## Verification plan (summary)

| Story | Pester (V1) | Playwright (V1) | Human (V2) |
|---|---|---|---|
| S1 | Unit + simulated E2E job records; ScriptAnalyzer | — | — |
| S2 | Routing/escaping units; socket smoke; Setup task | `dashboard.spec.ts`: render, XSS, polling, empty state | — |
| S3 | Action state machine incl. 403/404/409 | `upscale-actions.spec.ts`: approve→worker completes, retry, cancel, 409/403 | — |
| S4 | Edit/409/validation units; `-Force` overwrite | `metadata-edit.spec.ts`: edit → NAS folder name | Real DVD rip renamed via UI |
