# wrm — Interface Specification (v1)

Authoritative contract for all modules. Implementers: build exactly against these
signatures and return shapes. Do not change a signature without architect approval.
Full product context: see `docs/PLAN.md`.

## What this is

A Windows-native "Automatic Ripping Machine" replacement: a disc-watcher drives
`makemkvcon` (video) / `freaccmd` (audio CD), stages rips locally, names video via
TMDb, moves results to a NAS SMB share, ejects, notifies. Optional stage 2 upscales
DVD rips with Video2X (Real-ESRGAN, ncnn/Vulkan — AMD RX 7800 XT) after ffmpeg
deinterlace/IVTC. WSL/VMs were ruled out (no optical SCSI passthrough); everything
runs natively on Windows in the logged-in user's session.

## Conventions (all files)

- PowerShell 7+. Every script: `Set-StrictMode -Version Latest`; `$ErrorActionPreference = 'Stop'`.
- `src/*.ps1` are dot-sourceable function libraries (no top-level side effects).
  Entry points (`DiscWatcher.ps1`, `Upscale-Worker.ps1`, `setup.ps1`) may execute.
- Functions: approved verbs, comment-based help, typed params.
- Never call external executables directly — always via `Invoke-ArmTool` (below) so
  simulation can intercept.
- Errors inside pipeline functions are caught and returned in the result object
  (`Success=$false; Error=<msg>`), not thrown, so the watcher loop never dies.
- PSScriptAnalyzer: zero errors; avoid warnings where reasonable.

## Repository layout

```
wrm/
├── SPEC.md                      # this file
├── docs/PLAN.md                 # approved plan
├── config/config.example.psd1   # template; real config.psd1 is gitignored
├── src/
│   ├── Common.ps1               # Get-ArmConfig, Write-ArmLog, Invoke-ArmTool, Get-DiscType
│   ├── Rip-VideoDisc.ps1        # Invoke-VideoRip
│   ├── Rip-AudioCd.ps1          # Invoke-AudioRip
│   ├── Resolve-Title.ps1        # Resolve-Title
│   ├── Move-ToNas.ps1           # Move-ToNas
│   ├── Send-Notification.ps1    # Send-ArmNotification
│   ├── Upscale-Video.ps1        # Get-InterlaceType, Invoke-Upscale
│   ├── DiscWatcher.ps1          # entry point (event loop)
│   └── Upscale-Worker.ps1       # entry point (queue loop)
├── setup.ps1
├── tests/
│   ├── *.Tests.ps1              # Pester 5, one per src module
│   ├── stubs/                   # stub-makemkvcon.ps1, stub-freaccmd.ps1, stub-video2x.ps1
│   └── fixtures/                # makemkvcon robot output, TMDb JSON, ffmpeg idet output samples
├── .gitignore                   # config/config.psd1, logs/, *.log
└── README.md
```

## Config schema (`config/config.example.psd1`)

```powershell
@{
    # --- Required (setup.ps1 prompts for these) ---
    NasVideoPath      = '\\nas\media\import\movies'   # UNC
    NasMusicPath      = '\\nas\media\import\music'    # UNC
    # --- Paths ---
    StagingDir        = 'C:\rips\staging'
    UpscaleQueueDir   = 'C:\rips\upscale-queue'
    LogDir            = 'C:\rips\logs'
    MakeMkvConPath    = 'C:\Program Files (x86)\MakeMKV\makemkvcon64.exe'
    FreacCmdPath      = 'C:\Program Files\fre-ac\freaccmd.exe'
    FfmpegPath        = 'ffmpeg'
    Video2xPath       = 'C:\Program Files\Video2X\video2x.exe'
    # --- Behavior ---
    MinTitleLengthSec = 600
    RipAllTitles      = $true          # else main title only
    EjectWhenDone     = $true
    TmdbApiKey        = ''             # blank => label+date naming
    HaWebhookUrl      = ''             # blank => toast only
    # --- Upscale stage ---
    UpscaleDvds       = $false
    AutoUpscale       = $false         # $false => stop after -SampleOnly clip, notify for review
    UpscaleActiveHours= @('23:00','08:00')
    UpscaleModel      = 'realesr-generalv3'
    UpscaleScale      = 3
    UpscaleCrf        = 16
    # --- Test/dev ---
    Simulate          = $false         # route Invoke-ArmTool to tests/stubs/
}
```

## Common.ps1 (foundation — everything imports this)

```powershell
Get-ArmConfig [-Path <string>] -> [hashtable]
#  Loads config/config.psd1; falls back to config.example.psd1 with a WARN log.
#  Checks presence/truthiness of NasVideoPath/NasMusicPath (throws if missing
#  or blank) unless Simulate; no type validation is performed on any key.
#  Expands relative paths.

Write-ArmLog -Level <INFO|WARN|ERROR> -Message <string> [-Config <hashtable>]
#  Timestamped line to console AND $Config.LogDir\wrm-<yyyyMMdd>.log.
#  Must never throw (log dir auto-created; falls back to console-only).

Invoke-ArmTool -Name <makemkvcon|freaccmd|ffmpeg|video2x> -Arguments <string[]>
               -Config <hashtable> [-TimeoutSec <int>] -> [pscustomobject]
#  Returns @{ ExitCode=[int]; StdOut=[string[]]; StdErr=[string[]] }.
#  When $Config.Simulate: runs tests/stubs/stub-<name>.ps1 with same args instead.
#  Streams stdout lines to Write-ArmLog at INFO level (prefix "[<name>]").

Get-DiscType -DriveLetter <char> -> 'AudioCD'|'Video'|'Data'|'None'
#  AudioCD: media loaded (Win32_CDROMDrive.MediaLoaded) but no mountable filesystem.
#  Video:   CDFS/UDF volume containing VIDEO_TS\ or BDMV\ at root.
#  Data:    filesystem present, no video markers.  None: no media.
```

## Module contracts

```powershell
# Rip-VideoDisc.ps1
Invoke-VideoRip -DriveLetter <char> -Config <hashtable> -> [pscustomobject]
#  @{ Success; DiscLabel; DiscType('DVD'|'BD'); OutputDir; TitleCount; Error; Resolved }
#  1. `makemkvcon -r info disc:9999` output → map drive letter to makemkvcon index
#     (DRV: lines), read disc label + type.
#  2. As soon as the disc label is known (before the long rip runs), calls
#     Resolve-Title and stores the result on `Resolved`; also writes it to a
#     hand-editable `metadata.json` in OutputDir via Set-ArmMetadataFile (skips
#     the write if metadata.json already exists, so a retried rip of the same
#     staging dir never clobbers a prior user edit). `Resolved` is consumed by
#     Resolve-TitleOverride just before the NAS-move rename.
#  3. `makemkvcon -r --minlength=$($c.MinTitleLengthSec) mkv disc:<i> all <staging>\<label>\`
#     (or main title only when !RipAllTitles: pick longest TINFO duration).
#  4. Parse robot output: MSG codes, PRGV progress (log every ~10%), TINFO/CINFO.
#  5. Detect expired/absent key (MSG 5021/"registration key" text) → Success=$false,
#     Error='MAKEMKV_KEY_EXPIRED' (watcher notifies specially).

# Rip-AudioCd.ps1
Invoke-AudioRip -DriveLetter <char> -Config <hashtable> -> [pscustomobject]
#  @{ Success; OutputDir; Artist; Album; Error }
#  freaccmd <drive> -e flac -o "<staging>\audio\<guid>\<artist> - <album>\..." (no
#  explicit CDDB/MusicBrainz flags are passed — this relies on freaccmd's own
#  configured defaults); parse resulting tags/dir for Artist/Album; fallback
#  names 'Unknown Artist'/'Unknown Album <yyyy-MM-dd>'.

# Resolve-Title.ps1
Resolve-Title -DiscLabel <string> -Config <hashtable> -> [pscustomobject]
#  @{ FolderName; Matched=[bool]; Title; Year }
#  Clean label: '_'/'.'→space; strip tokens (DISC|DISK|D)\s*\d, SEASON \d, edition/
#  region/studio noise (SPECIAL EDITION, WS, 16X9, PAL, NTSC...); title-case.
#  If TmdbApiKey: GET api.themoviedb.org/3/search/movie?query=<clean>. Accept top hit
#  when exactly 1 result OR top popularity ≥ 2× second. FolderName "Title (Year)"
#  (or just "Title" when Year is blank), sanitized via the single canonical
#  ConvertTo-ArmSafeFileName (Common.ps1): invalid Windows filename characters
#  (per [System.IO.Path]::GetInvalidFileNameChars()) are stripped (not replaced),
#  then whitespace is collapsed and the result trimmed. This same rule is used
#  consistently by DiscWatcher.ps1, Rip-VideoDisc.ps1, and Resolve-Title.ps1.
#  No key/no match/HTTP error → FolderName "<CLEANLABEL>_<yyyy-MM-dd>",
#  Matched=$false. Never throws.
#
#  Set-ArmMetadataFile -OutputDir <string> -Title <string> -Year <string> -Config <hashtable>
#  Writes a hand-editable metadata.json ({Title;Year}) into a rip's staging
#  OutputDir once the disc label is resolved (called from Invoke-VideoRip).
#  Skips the write if metadata.json already exists. Never throws (logs WARN).
#
#  Resolve-TitleOverride -OutputDir <string> -FallbackResolved <pscustomobject>
#                        -Config <hashtable> -> [pscustomobject]
#  @{ FolderName; Matched; Title; Year }
#  Called by DiscWatcher.ps1 (Invoke-VideoDispatch) immediately before the
#  staging dir is renamed for the NAS move. Re-reads metadata.json in
#  OutputDir; if present with a non-blank Title, builds "Title (Year)" from
#  the user-edited values (same sanitization as Resolve-Title). If
#  metadata.json is missing/unreadable/malformed or Title is blank, returns
#  FallbackResolved (the original Resolve-Title result from before the rip)
#  unchanged. Never throws. This lets a user pause between rip-start and
#  NAS-move to hand-edit metadata.json and correct the auto-resolved title/year.

# Move-ToNas.ps1
Move-ToNas -SourceDir <string> -DestRoot <string> -Config <hashtable> -> [pscustomobject]
#  @{ Success; DestDir; Error }
#  robocopy <src> <dest> /E /Z /NP /R:3 /W:10; exit codes 0-7 = success, ≥8 = failure.
#  Verify: every source file exists at dest with equal Length. Delete source dir
#  ONLY after verification passes. Failures (robocopy failure or verification
#  mismatch) are NOT automatically retried or re-queued by design; the source
#  dir is preserved and the caller (DiscWatcher.ps1) logs/notifies for manual
#  re-trigger.

# Send-Notification.ps1
Send-ArmNotification -Title <string> -Message <string> -Level <Info|Error>
                     -Config <hashtable>
#  Windows toast via WinRT (Windows.UI.Notifications, no external module; wrap in
#  try/catch — toast failure must not fail the pipeline). If HaWebhookUrl set:
#  POST JSON @{title;message;level} with 5s timeout, failures logged WARN only.

# Upscale-Video.ps1
Get-InterlaceType -InputFile <string> -Config <hashtable>
#  -> 'Telecined'|'Interlaced'|'Progressive'
#  ffmpeg -filter:v idet -frames:v 2000 -an -f null - ; parse "Multi frame detection"
#  TFF+BFF vs Progressive counts: >80% progressive → Progressive; repeated-field
#  pattern (idet repeat counts) → Telecined; else Interlaced.

Invoke-Upscale -InputFile <string> -OutputDir <string> -Config <hashtable>
               [-SampleOnly] -> [pscustomobject]
#  @{ Success; OutputFile; InterlaceType; Error }
#  Chain: (a) classify; (b) preprocess with ffmpeg:
#     Telecined  → -vf fieldmatch,yadif=deint=interlaced,decimate  (→23.976p)
#     Interlaced → -vf bwdif=mode=send_frame
#     Progressive→ passthrough
#     encode intermediate ffv1|x264 crf 10 to temp;  -SampleOnly: -ss 600 -t 120.
#  (c) video2x -i temp -o upscaled --processor realesrgan (model/scale from config);
#  (d) ffmpeg mux: libx265 -crf $UpscaleCrf -preset slow, copy original audio.
#  Output name: "<basename> [AI upscale 1080p].mkv". Temp files cleaned on any exit.

# DiscWatcher.ps1 (entry point)
#  Param: [-ConfigPath] [-Simulate] [-Once] (-Once: process current disc then exit —
#  used by tests). Register-WmiEvent Win32_VolumeChangeEvent EventType 2 + 30s poll
#  fallback (compare Get-DiscType per optical drive). Single-flight lock via named
#  mutex 'wrm-rip'. Dispatch:
#    Video  → Invoke-VideoRip (captures Resolve-Title result on .Resolved before
#             the rip runs) → Resolve-TitleOverride (re-reads metadata.json for
#             a user Title/Year edit, else falls back to .Resolved) → rename
#             staging dir → Move-ToNas (NasVideoPath) → if DVD && UpscaleDvds: copy main mkv path into
#             UpscaleQueueDir queue file (<name>.json: {Source;DestDir}) → eject+notify
#    AudioCD→ Invoke-AudioRip → Move-ToNas (NasMusicPath) → eject+notify
#    Data   → log WARN + notify, no action.
#  Every failure path: Send-ArmNotification Level Error; staging kept for forensics.

# Upscale-Worker.ps1 (entry point)
#  Param: [-ConfigPath] [-Simulate] [-Once]. Poll UpscaleQueueDir every 60s for
#  *.json. Respect UpscaleActiveHours (start jobs only inside window). Process
#  priority BelowNormal. If !AutoUpscale: Invoke-Upscale -SampleOnly, notify with
#  sample path, rename queue file → .awaiting-review (user renames back to .json
#  after approving; document in README). Else full run → move result to DestDir,
#  notify, delete queue file. Failures → .failed + Error notification.

# setup.ps1
#  Idempotent. winget install GuinpinSoft.MakeMKV, enzo1982.freac, Gyan.FFmpeg
#  (skip present); print manual step for Video2X (GitHub release). Create dirs.
#  Prompt for NAS paths/TMDb key/HA URL → write config/config.psd1 (skip prompts
#  with -NonInteractive; copies example). Register hidden Scheduled Tasks
#  'wrm-watcher' and 'wrm-upscaler' (at logon, current user,
#  pwsh -WindowStyle Hidden -File <entrypoint>). -Uninstall removes tasks.
#  Requires Administrator: registering Scheduled Tasks needs elevation, so the
#  entry point checks WindowsPrincipal role membership and, if not elevated,
#  relaunches itself via `Start-Process -Verb RunAs` (UAC consent prompt).
#  Test-NonInteractiveSession detects sessions where UAC cannot show that
#  prompt (SSH_CONNECTION/SSH_CLIENT/SSH_TTY env vars, [Environment]::
#  UserInteractive=$false, or $env:SESSIONNAME absent/'Services'/
#  'RemoteControl'-prefixed) and, when not already elevated, throws an
#  actionable error immediately instead of hanging/failing silently on
#  Start-Process -Verb RunAs. -RunAsUser <string> ("DOMAIN\User"): internal/
#  advanced param used to register the scheduled tasks' principal as the
#  original pre-elevation user rather than whichever account UAC elevated to;
#  the entry point captures $env:USERDOMAIN\$env:USERNAME before relaunching
#  elevated and passes it through automatically, so end users normally never
#  need to set this themselves.
```

## Testing requirements

- Pester 5. Each module gets `tests/<Name>.Tests.ps1` exercising success + failure
  paths using fixtures — no real tools, no network (mock `Invoke-RestMethod`,
  `Invoke-ArmTool`, or run with `Simulate=$true`).
- Stubs (`tests/stubs/stub-*.ps1`) accept the real CLI argument shapes and emit
  realistic output: makemkvcon robot lines + create fake .mkv (a few KB of random
  bytes); freaccmd creates tagged-path .flac placeholder; video2x copies input to
  output. Fixtures include at least one real-format makemkvcon `-r` transcript
  (info + rip), a TMDb search JSON, and ffmpeg idet stderr samples for all three
  interlace classes.
- End-to-end: `DiscWatcher.ps1 -Simulate -Once` with a fixture "disc" must produce a
  named folder under a temp NAS root; same for audio; `Upscale-Worker.ps1 -Simulate
  -Once` must consume a queue file. These run in `tests/EndToEnd.Tests.ps1`.
```
