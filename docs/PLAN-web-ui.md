# Web UI for rip status, manual metadata, and upscale jobs — Implementation Plan

Issue: #15 (title only, no body). This plan fills the gaps with stated assumptions;
items marked **[ASSUMPTION]** need confirmation before the dependent story starts.

**Verifiability tier: V2 overall** (S1 is V1; S2–S4 need a human browser check).

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
- **Bind:** `http://localhost:<WebUiPort>/` only. **[ASSUMPTION — open question 1]**
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

### S2 — Read-only status UI (V2)

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

**Done when:** tests green + manual: run `DiscWatcher.ps1 -Simulate -Once` and
`WebUi.ps1 -Simulate`, open `http://localhost:8765/`, see the simulated rip as
Complete and the upscale job as AwaitingReview; user confirms.

### S3 — Upscale job actions (V2)

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

**Done when:** tests green + manual: approve a simulated sample in the browser, then
`Upscale-Worker.ps1 -Simulate -Once` completes it; user confirms.

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

**Done when:** tests green + manual: during a real DVD rip, change the title in the
UI and confirm the NAS folder uses it; user confirms.

## Deferred / out of scope

- Renaming a folder **after** it reached the NAS (would also need to rewrite the
  `Source`/`DestDir` of any upscale queue entry pointing at it). **Open question 2.**
- LAN / phone access (urlacl + firewall + real auth). **Open question 1.**
- Streaming the sample clip in-browser; live progress % for rips (would need
  `PRGV` parsing to push into the job record — easy follow-up after S1).
- Editing audio CD tags.

## Open questions (asked one at a time)

1. Localhost-only, or reachable from other devices on the LAN (e.g. a phone)?
   Localhost keeps S2/S3 as scoped above; LAN adds a urlacl + firewall rule in
   `setup.ps1` and a real auth mechanism (shared token) to S2.
2. Should "update metadata" also cover already-moved rips (rename on the NAS),
   or only in-flight rips as planned?

## Verification plan (summary)

| Story | Automated (V1) | Human (V2) |
|---|---|---|
| S1 | Pester unit + simulated E2E job records; ScriptAnalyzer | — |
| S2 | Routing/escaping unit tests; socket smoke test; Setup task test | Browser shows simulated jobs |
| S3 | Action state-machine tests incl. 403/404/409 | Approve in browser → worker completes |
| S4 | Edit/409/validation tests; E2E folder-name assertion | Real rip renamed via UI |
