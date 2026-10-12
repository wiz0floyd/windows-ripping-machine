# Spec: rename movie folders to match library NFO (`wrm repair -RenameFolders`)

Status: draft for review. Fold into SPEC.md ("Repair tool" section) when implemented.
Builds on PR #61 (`Get-ArmNfoMovieName`) and `tools/Repair-ArmJellyfinNames.ps1`.

## Problem
Jellyfin groups files as versions of one movie only when each file name starts with the
movie **folder** name. PR #61 names new upscales from the NFO `Title (Year)`, so where the
folder name differs from the NFO name the files do not group. Fix existing libraries by
renaming the folder (and the files in it) to the NFO name.

## Scope
In: a `-RenameFolders` switch on `Repair-ArmJellyfinNames` / `wrm repair`.
Out: Jellyfin API calls (library scan stays manual); watch-history preservation (accepted loss);
Plex (no NFO); TV/music libraries; renaming folders not under `-Path`.

## Behaviour
For each movie folder directly under `-Path` (honouring `-Since` / `-Until`):

1. **Target name** = `Get-ArmNfoMovieName` for the main feature (largest top-level `.mkv`
   that is not an `[AI upscale ...]` file). No usable NFO -> not touched, no row.
2. **Compare** target to folder name, case-insensitive ordinal. Equal -> no row.
3. **Plan** (nothing changes yet):
   - new folder path = `<Path>\<target>`
   - every top-level file whose name is the old folder name or old folder name + separator
     (`Test-ArmJellyfinVersionName`) gets the same suffix with the new prefix
     (`Grease - 480p.mkv` -> `Grease (1978) - 480p.mkv`); `[AI upscale 1080p]` and
     raw-name files are left for the existing repair pass, which runs after the folder rename
   - sidecars keyed on the old stem (`.nfo` except `movie.nfo`, `-poster.jpg` etc.,
     `.trickplay`) are renamed with the stem (decision 5); `movie.nfo` is never renamed
4. **Skip the folder (row `Skipped`, reason)** when any of:
   - an upscale queue entry (`.json`, `.awaiting-review`, `.failed`) has a `Source`/`DestDir`
     inside the folder
   - the target folder already exists (merge is out of scope)
   - a planned file target already exists
   - the NFO has no year (decision 3), or the target name is empty after `ConvertTo-ArmSafeFileName`
5. **Execute** (only without `-WhatIf`): rename files first, then the folder
   (`Move-Item`, same share = metadata-only). On any file failure, roll back renames done in
   this folder and report `Skipped`. A failed folder rename after files succeeded rolls the
   files back too.
6. After renaming, the existing file-naming pass (raw -> `<Folder>.mkv`, upscale versions)
   runs against the new folder name so one invocation fully repairs a folder.

## Global preconditions (abort whole run, nothing changes)
- `UpscaleQueueDir` holds any `.json` / `.awaiting-review` entry: **warn and list them**
  and abort unless `-Force`. (Per-folder skip in 4 covers `-Force` runs.)
- Upscale worker mid-run: detect via a job in state `Sampling` / `Upscaling` in `StateDir\jobs`;
  abort unless `-Force`.

## Interfaces
```
wrm repair -RenameFolders [-Path] [-Since] [-Until] [-RemoveOrphans] [-Force] [-WhatIf]
Repair-ArmJellyfinNames ... -RenameFolders [-Force]
```
Rows gain Action values `FolderRenamed | WouldRenameFolder`; `NewName` = new folder name.
`-WhatIf` default recommended in README; summary line adds `Folders renamed (or would): N`.

## Side effects to document (README "Troubleshooting")
- Jellyfin sees delete + add: watch state, favourites, collections reset for renamed titles.
  Trigger one library scan afterwards.
- Job history `DestDir` / `OutputFile` for renamed folders go stale (cosmetic; not rewritten).
- `metadata.json` inside the folder moves with it; its `Folder` field, if any, is not rewritten.

## Acceptance criteria
- Pester: rename plan/execute for folder + versioned files; skip on queue entry, existing
  target folder, planned-name clash; rollback on injected file-rename failure; `-WhatIf`
  changes nothing and emits `WouldRenameFolder`; idempotent (second run = no rows);
  `-Since/-Until` filter respected; case-only difference handled (rename via temp name on
  case-insensitive FS).
- `Invoke-ScriptAnalyzer -Severity Error` clean; full Pester suite green.
- Manual (needs user): `-WhatIf` on the real NAS reviewed, then run on 1-2 folders, Jellyfin
  scan shows the versions grouped.

## Decisions (from the user journey)
1. **NFO is the source of truth.** Metadata is corrected in the Jellyfin UI after the rip, and
   Jellyfin writes it to the NFO, so the NFO beats the folder name. Lookup order stays
   `<file>.nfo` then `movie.nfo` (both written by Jellyfin; they agree in practice).
2. **No fallback to WRM `metadata.json`.** By the time a repair runs, Jellyfin has populated the
   NFO for ~all titles; folders without one are left alone.
3. **Year-less NFO -> skip**, row `Skipped`, reason `NFO has no year`. (This replaces the
   bare-title behaviour in step 1 for the *folder* rename; the upscale naming in PR #61 is unchanged.)
4. **Job records are not rewritten.** `DestDir`/`OutputFile` are display-only in the web UI
   (`WebUi.ps1`, `app.js`: shown as text, never opened or used by an action) and records expire after
   `JobHistoryDays`. Stale paths are cosmetic; rewriting them would touch a store the repair
   tool otherwise never opens. Revisit only if a web UI action starts using them.
5. **Sidecars are renamed, not deleted,** whenever their stem matches the old folder name
   (`.nfo`, `-poster.jpg` etc., `.trickplay`), so Jellyfin keeps its edited metadata and images.
   `-RemoveOrphans` keeps its current meaning (delete sidecars whose video no longer exists).

## Open questions
None blocking. Decision 4 is the least certain; confirm or override.
