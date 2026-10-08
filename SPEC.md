# wrm — Interface Specification (v1)

Authoritative contract for all modules. Implementers: build exactly against these
signatures and return shapes. Do not change a signature without architect approval.
Full product context: see `docs/PLAN.md`.

## What this is

A Windows-native "Automatic Ripping Machine" replacement: a disc-watcher drives
`makemkvcon` (video) / `freaccmd` (audio CD), stages rips locally, names video via
TMDb, moves results to a NAS SMB share, ejects, notifies. Optional stage 2 upscales
DVD rips (OpenProteus 2x via ncnn/Vulkan for live action, Anime4K via Video2X
libplacebo for animation — AMD RX 7800 XT) after ffmpeg deinterlace/IVTC. WSL/VMs were ruled out (no optical SCSI passthrough); everything
runs natively on Windows in the logged-in user's session.

## Conventions (all files)

- PowerShell 7+. Every script: `Set-StrictMode -Version Latest`; `$ErrorActionPreference = 'Stop'`.
- `src/*.ps1` are dot-sourceable function libraries (no top-level side effects).
  Entry points (`DiscWatcher.ps1`, `Upscale-Worker.ps1`, `WebUi.ps1`, `setup.ps1`) may execute.
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
│   ├── Common.ps1               # Get-ArmConfig, Resolve-ArmFfprobePath, Write-ArmLog, Invoke-ArmTool, Get-DiscType
│   ├── JobState.ps1             # New-ArmJob, Update-ArmJob, Get-ArmJob, Get-ArmJobList, Remove-ArmStaleJobs
│   ├── Rip-VideoDisc.ps1        # Invoke-VideoRip, Set-ArmMetadataFile
│   ├── Rip-AudioCd.ps1          # Invoke-AudioRip
│   ├── Resolve-Title.ps1        # Resolve-Title
│   ├── Move-ToNas.ps1           # Move-ToNas
│   ├── Send-Notification.ps1    # Send-ArmNotification
│   ├── Upscale-Video.ps1        # Get-InterlaceType, Get-VideoSourceInfo, Get-VideoFrameRate, Get-UpscalePlan, Invoke-Upscale
│   ├── DiscWatcher.ps1          # entry point (event loop)
│   ├── Upscale-Worker.ps1       # entry point (queue loop)
│   ├── WebUi.ps1                # entry point (localhost status page; Invoke-ArmWebRequest)
│   └── webui/                   # app.js, app.css served by WebUi.ps1
├── setup.ps1
├── tests/
│   ├── *.Tests.ps1              # Pester 5, one per src module
│   ├── stubs/                   # stub-makemkvcon.ps1, stub-freaccmd.ps1, stub-ffmpeg.ps1, stub-ffprobe.ps1, stub-video2x.ps1, stub-ncnn.ps1
│   ├── fixtures/                # makemkvcon robot output, TMDb JSON, ffmpeg idet samples, ffprobe JSON, golden upscale args
│   └── browser/                 # Playwright specs for the web UI (Node, test-only)
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
    StateDir          = 'C:\rips\state'    # job-state records (<StateDir>\jobs\<id>.json)
    MakeMkvConPath    = 'C:\Program Files (x86)\MakeMKV\makemkvcon64.exe'
    FreacCmdPath      = 'C:\Program Files\fre-ac\freaccmd.exe'
    FfmpegPath        = 'ffmpeg'
    FfprobePath       = 'ffprobe'      # omitted => ffprobe.exe next to FfmpegPath (bare 'ffprobe' if FfmpegPath is bare)
    Video2xPath       = 'C:\Program Files\Video2X\video2x.exe'
    NcnnPath          = 'C:\ProgramData\wrm\venv\Scripts\python.exe'   # venv python running tools/ncnn_upscale.py
    NcnnModelDir      = 'C:\ProgramData\wrm\models'                      # openproteus-x2.param/.bin
    # --- Behavior ---
    MinTitleLengthSec = 600
    RipAllTitles      = $true          # else main title only
    EjectWhenDone     = $true
    TmdbApiKey        = ''             # blank => label+date naming
    HaWebhookUrl      = ''             # blank => toast only
    # --- Upscale stage ---
    # (engine choice, speeds, VRAM and encoder measurements behind these defaults: docs/upscaler-spike-2026-10.md)
    UpscaleDvds       = $false
    AutoUpscale       = $false         # $false => stop after -SampleOnly clip, notify for review
    UpscaleActiveHours= @('23:00','08:00')
    UpscaleLiveAction = 'openproteus'  # openproteus | anime4k | realesrgan (legacy)
    UpscaleAnimation  = 'anime4k'      # engine when the queue item has ContentType='Animation' (set from the TMDb Animation genre; no config key)
    UpscaleHeight     = 1080           # output height; width = round(height * source DAR / 2) * 2
    UpscaleShader     = 'anime4k-v4-a+a'   # libplacebo shader for the anime4k engine
    UpscaleModel      = 'realesrgan-plus'  # legacy realesrgan engine only (video2x 6.4 models)
    UpscaleScale      = 4                  # legacy realesrgan engine only; plus/-anime ship x4 only
    UpscaleCrf        = 16
    # --- Web UI (http://localhost:<WebUiPort>/, this machine only) ---
    WebUiEnabled      = $true          # $false => WebUi.ps1 exits immediately
    WebUiPort         = 8765
    WebUiOpenOnDisc   = $true          # DiscWatcher opens the dashboard (Open-ArmWebUi) when a Video/AudioCD disc is detected; skipped under -Simulate / WebUiEnabled=$false
    # --- Job history ---
    JobHistoryDays    = 30             # prune Complete/Failed/Cancelled job records older than this
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
#  Expands relative paths. FfprobePath, when absent from config.psd1, is derived
#  (Resolve-ArmFfprobePath) before the example backfill: '<dir of FfmpegPath>\ffprobe.exe'
#  if FfmpegPath has a directory part, else the bare 'ffprobe' (resolved via PATH).

Resolve-ArmFfprobePath -Config <hashtable> -> [string]
#  Pure. $Config.FfprobePath if set, else ffprobe.exe beside a full-path FfmpegPath,
#  else 'ffprobe'. Used by Get-ArmConfig, Invoke-ArmTool (-Name ffprobe) and the
#  openproteus plan (the runner's --ffprobe).

Write-ArmLog -Level <INFO|WARN|ERROR> -Message <string> [-Config <hashtable>]
#  Timestamped line to console AND $Config.LogDir\wrm-<yyyyMMdd>.log.
#  Must never throw (log dir auto-created; falls back to console-only).

Invoke-ArmTool -Name <makemkvcon|freaccmd|ffmpeg|ffprobe|video2x|ncnn> -Arguments <string[]>
               -Config <hashtable> [-TimeoutSec <int>] -> [pscustomobject]
#  Returns @{ ExitCode=[int]; StdOut=[string[]]; StdErr=[string[]] }.
#  When $Config.Simulate: runs tests/stubs/stub-<name>.ps1 with same args instead.
#  `ncnn` runs $Config.NcnnPath (the venv python.exe); its Arguments start with
#  `-I <repo>\tools\ncnn_upscale.py`. Default -TimeoutSec is 3600; Invoke-Upscale passes 86400.
#  `ffprobe` runs Resolve-ArmFfprobePath (i.e. $Config.FfprobePath).
#  Streams stdout lines to Write-ArmLog at INFO level (prefix "[<name>]").

Get-DiscType -DriveLetter <char> -> 'AudioCD'|'Video'|'Data'|'None'
#  AudioCD: media loaded (Win32_CDROMDrive.MediaLoaded) but no mountable filesystem.
#  Video:   CDFS/UDF volume containing VIDEO_TS\ or BDMV\ at root.
#  Data:    filesystem present, no video markers.  None: no media.
```

## Module contracts

```powershell
# Rip-VideoDisc.ps1
Invoke-VideoRip -DriveLetter <char> -Config <hashtable> [-JobId <string>] -> [pscustomobject]
#  @{ Success; DiscLabel; DiscType('DVD'|'BD'); OutputDir; TitleCount; Error; Resolved }
#  -JobId: optional Rip job (JobState.ps1). Right after metadata.json is written
#  (the only point the staging dir is known mid-rip) the job is updated to
#  State=Ripping with StagingDir, Title (= Resolved.FolderName), DiscLabel, DiscType.
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
#
#  Set-ArmMetadataFile -OutputDir <string> -Title <string> -Year <string>
#                      [-ContentType <string>] [-ContentTypeNote <string>]
#                      -Config <hashtable> [-Force]
#  Writes a hand-editable metadata.json ({Title;Year;ContentType;ContentTypeNote})
#  into a rip's staging OutputDir once the disc label is resolved (called from
#  Invoke-VideoRip, which passes Resolved.ContentType/ContentTypeNote).
#  Skips the write if metadata.json already exists, unless -Force (used by the web
#  UI's manual edit) overwrites it. -Force MERGES: ContentType/ContentTypeNote that
#  the caller did not pass keep their value from the existing file (so a web UI
#  Title/Year edit never wipes them); a key that was never passed and has no
#  existing value is omitted. Writes are atomic (unique .tmp in the same dir,
#  then File.Move overwrite). Never throws (logs WARN); returns nothing.

# Rip-AudioCd.ps1
Invoke-AudioRip -DriveLetter <char> -Config <hashtable> [-JobId <string>] -> [pscustomobject]
#  @{ Success; OutputDir; Artist; Album; Error }
#  -JobId: optional Rip job; set to State=Ripping, StagingDir, DiscType='AudioCD'
#  once the staging dir is created.
#  freaccmd <drive> -e flac -o "<staging>\audio\<guid>\<artist> - <album>\..." (no
#  explicit CDDB/MusicBrainz flags are passed — this relies on freaccmd's own
#  configured defaults); parse resulting tags/dir for Artist/Album; fallback
#  names 'Unknown Artist'/'Unknown Album <yyyy-MM-dd>'.

# Resolve-Title.ps1
Resolve-Title -DiscLabel <string> -Config <hashtable> -> [pscustomobject]
#  @{ FolderName; Matched=[bool]; Title; Year; ContentType; ContentTypeNote }
#  ContentType = 'Animation' when the chosen TMDb candidate's `genre_ids` contain 16
#  (TMDb's Animation genre), else 'LiveAction' (also when `genre_ids` is absent, and on
#  every no-match / fallback path). It always comes from the candidate actually used
#  (TMDb's top hit, or the LLM's pick), so the genre belongs to the title in
#  FolderName. ContentTypeNote is '' unless the LLM cross-check disagreed (below).
#  Only /search/movie is queried, so TV-only discs usually don't match -> LiveAction.
#  The result is built by one helper (New-ArmResolvedTitle); Get-ArmTmdbContentType
#  derives ContentType from a candidate; Get-ArmTmdbGenreId reads its genre_ids.
#  Clean label: '_'/'.'→space; strip tokens (DISC|DISK|D)\s*\d, SEASON \d, edition/
#  region/studio noise (SPECIAL EDITION, WS, 16X9, PAL, NTSC...); title-case.
#  If TmdbApiKey: GET api.themoviedb.org/3/search/movie?query=<clean>. Zero results
#  (not ambiguous ones) retry with the last word dropped, up to 3x or down to 1
#  word. Accept top hit from whichever query returned results when exactly 1
#  result OR top popularity ≥ 2× second. FolderName "Title (Year)"
#  (or just "Title" when Year is blank), sanitized via the single canonical
#  ConvertTo-ArmSafeFileName (Common.ps1): invalid Windows filename characters
#  (per [System.IO.Path]::GetInvalidFileNameChars()) are stripped (not replaced),
#  then whitespace is collapsed and the result trimmed. This same rule is used
#  consistently by DiscWatcher.ps1, Rip-VideoDisc.ps1, and Resolve-Title.ps1.
#  No key/no match/HTTP error → FolderName "<CLEANLABEL>_<yyyy-MM-dd>",
#  Matched=$false. Never throws.
#
#  LLM validation (opt-in, movies only): when $Config.LlmDisambiguationEnabled
#  is $true, EVERY non-empty TMDb result set - not just ambiguous ones - is
#  additionally checked by calling
#  Invoke-ArmLlmDisambiguation -DiscLabel <string> -Candidates <array>
#                               -Config <hashtable> -> [pscustomobject] @{ SelectedIndex; Animated }
#  POSTs {model;temperature=0;messages} to "$($Config.LlmEndpoint)/chat/completions"
#  (OpenAI-compatible; e.g. llama.cpp at http://127.0.0.1:8080/v1) with the disc
#  label and the candidate list (index/title/year/genres/popularity/overview, sorted by
#  popularity descending; index = position in that array, not a TMDb ID; genres =
#  TMDb genre NAMES from a fixed id->name table, no extra API call).
#  Expects a bare JSON reply {"index": N, "animated": true|false} or {"index": null}.
#  SelectedIndex is validated as an in-range integer index into the real candidate
#  array before use - the model can never introduce a title TMDb didn't return.
#  Animated = $true/$false for a valid boolean (or "true"/"false" string) about the
#  picked candidate, else $null (absent, invalid, or no index picked). A bad `animated`
#  never invalidates a valid index. No extra request: the call already runs per lookup.
#
#  ContentType cross-check: when the LLM picks a candidate and Animated is non-null,
#  it is compared with that candidate's TMDb genre. On disagreement TMDb's value is
#  used, a WARN is logged, and ContentTypeNote records both, e.g. "TMDb genres say
#  Animation but the LLM says not animated; using TMDb's Animation" (written to
#  metadata.json for sample review). LLM off/unavailable/declined/omits `animated`:
#  ContentType is the TMDb genre value and ContentTypeNote is ''.
#
#  The LLM has final say whenever it returns a valid index, whether or not
#  Test-ArmTmdbAcceptance had already accepted the top hit: this catches TMDb's
#  popularity heuristic confidently picking the wrong entry (e.g. a bare
#  franchise label like "TOY_STORY" matching a hyped upcoming sequel over the
#  original) in addition to the original "too close to call" ambiguous case.
#  When the LLM is unavailable, times out, returns malformed/non-JSON output, an
#  out-of-range/non-integer index, or an explicit "none" answer,
#  Invoke-ArmLlmDisambiguation catches it internally, logs WARN, and returns
#  SelectedIndex=$null (never throws) - Resolve-Title then degrades to exactly
#  what TMDb alone would have produced: the top hit if Test-ArmTmdbAcceptance
#  accepted it, or "<CLEANLABEL>_<yyyy-MM-dd>"/Matched=$false if not. Config
#  keys: LlmDisambiguationEnabled (default $false), LlmEndpoint, LlmModel,
#  LlmTimeoutSec (default 15s). Does not change Resolve-Title's signature or
#  output shape. Each path is logged (INFO when the LLM confirms TMDb's pick,
#  WARN when it overrides TMDb, disambiguates an ambiguous set, or declines) so
#  the match path stays auditable, same as the truncation-retry log.
#
#  (Set-ArmMetadataFile, which writes the metadata.json read below, lives in
#  Rip-VideoDisc.ps1 - see that section.)
#
#  Resolve-TitleOverride -OutputDir <string> -FallbackResolved <pscustomobject>
#                        -Config <hashtable> -> [pscustomobject]
#  @{ FolderName; Matched; Title; Year; ContentType; ContentTypeNote }
#  Called by DiscWatcher.ps1 (Invoke-VideoDispatch) immediately before the
#  staging dir is renamed for the NAS move. Re-reads metadata.json in
#  OutputDir; if present with a non-blank Title, builds "Title (Year)" from
#  the user-edited values (same sanitization as Resolve-Title). If
#  metadata.json is missing/unreadable/malformed or Title is blank, returns
#  FallbackResolved (the original Resolve-Title result from before the rip)
#  unchanged. Never throws. This lets a user pause between rip-start and
#  NAS-move to hand-edit metadata.json and correct the auto-resolved title/year.
#  ContentType is applied INDEPENDENTLY of Title: a valid `ContentType`
#  ('Animation' | 'LiveAction', case-insensitive, trimmed) in metadata.json wins even
#  when Title is blank/unedited (the fallback's FolderName/Title/Year are then kept).
#  An invalid or blank value keeps the fallback's ContentType (WARN for invalid). When
#  Title is edited but ContentType is not, the TMDb-derived value is kept (no TMDb
#  re-query) and an INFO line is logged; the sample review is the safety net.
#  A fallback without ContentType (legacy callers) counts as 'LiveAction';
#  ContentTypeNote is carried over from the fallback. This is the manual override
#  path: edit "ContentType" in <staging>\<label>\metadata.json during the rip.

# Move-ToNas.ps1
Move-ToNas -SourceDir <string> -DestRoot <string> -Config <hashtable> -> [pscustomobject]
Move-ArmExtrasToSubdir -Dir <string> -Config <hashtable> -> [pscustomobject] { Success, Moved, Error }
# Called by Invoke-VideoDispatch before Move-ToNas: keeps the largest top-level .mkv in place and moves
# the other top-level .mkv files into <Dir>\extras\ (Jellyfin extras folder). No-op for <2 .mkv files.
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
Get-InterlaceType -InputFile <string> -Config <hashtable> [-Seek <int>] [-Duration <int>]
#  -> 'Telecined'|'Interlaced'|'Progressive'
#  ffmpeg -filter:v idet -frames:v 2000 -an -f null - ; parse "Multi frame detection"
#  and "Repeated Fields". ffmpeg 8.x prints the idet summary TWICE (a throw-away
#  probe graph's all-zero summary, then the real one; older builds print once), so
#  the LAST match of each line is used (issue #30). Decision table, first match wins:
#    Progressive share of Multi-frame total >= 0.5  → Progressive
#    else (Top+Bottom)/(Neither+Top+Bottom) of Repeated Fields > 0.15 → Telecined
#    else → Interlaced
#  Missing/unparseable Multi-frame line, or counts totalling zero → Interlaced plus
#  a WARN log naming the file. The 0.5 cut sits mid-gap of 18 surveyed DVD rips:
#  film/progressive video read 80.9-100% progressive, interlaced/hard-telecined 0-1.5%.

Get-VideoFrameRate -InputFile <string> -Config <hashtable> [-Seek 600] [-Duration 60] -> [string]|$null
#  Decodes a short window (`ffmpeg -ss -t -i -map 0:v:0 -f null -`; retries from 0),
#  snaps frames/time to a standard rate ('24000/1001', '30000/1001', ...; within 2%).
#  Needed because soft-telecined DVD rips decode at 23.976 but carry a 29.97 header.

Get-VideoSourceInfo -InputFile <string> -Config <hashtable> -> [pscustomobject]
#  Probes the SOURCE once with `ffprobe -v error -show_entries stream=...:format=duration
#  -of json=compact=1 <file>` (Invoke-ArmTool -Name ffprobe). Never throws; replaces the
#  old Get-VideoDisplayAspect (which parsed an `ffmpeg -i` banner of the intermediate).
#  @{ Success; Error;
#     Width; Height;                      # $null if unknown
#     SampleAspectRatio; DisplayAspectRatio;   # 'n:d' as ffprobe printed them, else $null
#     DisplayAspect;                      # [double] width/height of the displayed picture, never $null
#     DisplayAspectSource;                # 'sar' | 'dar' | 'frame-size' | 'assumed'
#     PixelFormat; ColorSpace; ColorPrimaries; ColorTransfer; ColorRange; FieldOrder;
#     FrameRate;                          # HEADER rate, e.g. '30000/1001' (soft telecine lies; see Get-VideoFrameRate)
#     DurationSec;                        # [double] or $null
#     AudioStreamCount;                   # [int]
#     Warnings }                          # [string[]], already logged at WARN
#  DisplayAspect = frame size x SAR; else display_aspect_ratio; else frame-size ratio;
#  else 16:9 with a WARN (the same chain the banner parse used). ffprobe's 'unknown'/
#  'N/A' tags read as $null. A failed probe (non-zero exit, no JSON, no video stream)
#  returns Success=$false, the 16:9 fallback, and WARNs.
#  ConvertTo-VideoSourceInfo -Json <string> [-InputFile <string>] is the pure parser.

# Probe window: Get-InterlaceType and Get-VideoFrameRate take the same optional -Seek/-Duration:
#  Get-InterlaceType -Seek <int> -Duration <int>   (defaults -1 / 0 = omitted, i.e. probe from 0:00)
#  Get-VideoFrameRate -Seek <int=600> -Duration <int=60>
#  Invoke-Upscale does not pass a window to Get-InterlaceType yet (windowed/multi-sample
#  classification is #30); the parameters exist so that change is a call-site edit.
#  Unlike Get-VideoFrameRate, Get-InterlaceType does NOT retry from 0:00 when the seek
#  lands past the end of a short file: idet then reports zero counts, which classifies
#  as Interlaced with a WARN (the safe default). #30 owns adding that fallback.

Get-UpscalePlan -InputFile <string> -SourceInfo <pscustomobject> -InterlaceType <Telecined|Interlaced|Progressive>
                -FrameRate <string|$null> -Config <hashtable> [-ContentType <LiveAction|Animation>]
                [-SampleOnly] -> [pscustomobject]
#  PURE: no I/O, no process launches, no logging - every decision lives here and is
#  unit-tested on its fields. Inputs are the facts Invoke-Upscale gathered
#  (Get-VideoSourceInfo, Get-InterlaceType, Get-VideoFrameRate [skipped for Telecined]).
#  @{ InputFile; BaseName; ContentType; SampleOnly; InterlaceType;
#     Window            # $null, or @{ Seek=600; Duration=120 } for -SampleOnly
#     Preprocess        # @{ Filter; FrameRate }  Filter = ONE -vf chain string or $null
#                       #   (Telecined 'fieldmatch,yadif=deint=interlaced,decimate',
#                       #    Interlaced 'bwdif=mode=send_frame', Progressive $null);
#                       #   FrameRate = measured rate for `-fps_mode cfr -r`, $null for
#                       #   Telecined or when unmeasured (then Warnings has the WARN)
#     Engine; EngineTool; EngineLabel   # EngineTool = 'ncnn' | 'video2x'
#     Target            # @{ Width; Height; DisplayAspect }, Width = 2*round(Height*DAR/2); $null for realesrgan
#     Upscale           # engine params: Model/Scale | Shader | Runner/ModelBase/Ffmpeg/Ffprobe/RequiredFiles
#     Encode            # @{ Codec='libx265'; Crf; Preset='slow'; AudioCodec='copy'; ResetSar }
#     Colour            # @{ Space; Primaries; Transfer; Range; Action='none' } - source tags carried for #29
#     Source; OutputFileName; Warnings; Error }
#  Error is non-$null for an unknown engine or the realesrgan-plus x4-only mismatch;
#  the plan never throws, Invoke-Upscale fails fast on it (before the slow preprocess).
#  Pure argument builders turn a plan into the stage command lines:
#    Get-UpscalePreprocessArgumentList -Plan -OutputFile            (ffmpeg -> ffv1 intermediate)
#    Get-UpscaleEngineArgumentList -Plan -InputFile -OutputFile     (Invoke-ArmTool -Name $Plan.EngineTool)
#    Get-UpscaleEncodeArgumentList -Plan -UpscaledFile -OutputFile  (ffmpeg libx265 mux)
#  tests/fixtures/golden-upscale-args.json pins the exact argument lists for 26
#  scenarios (captured before the plan refactor); tests assert the plan-built args
#  equal them. Changing an ffmpeg/runner argument means regenerating that file on purpose.

Invoke-Upscale -InputFile <string> -OutputDir <string> -Config <hashtable>
               [-ContentType <LiveAction|Animation>] [-SampleOnly] -> [pscustomobject]
#  @{ Success; OutputFile; InterlaceType; Engine; Error }   # Engine = openproteus|anime4k|realesrgan ($null if failed before engine selection)
#  Probe, plan, execute. (a) Probe: Get-VideoSourceInfo (ffprobe, source file),
#  Get-InterlaceType, and - unless Telecined - Get-VideoFrameRate. Then Get-UpscalePlan;
#  plan Warnings are logged, plan Error and (non-Simulate) missing openproteus
#  runner/model files (error points at setup.ps1) fail the run before any encode.
#  (b) preprocess with ffmpeg:
#     Telecined  → -vf fieldmatch,yadif=deint=interlaced,decimate  (→23.976p)
#     Interlaced → -vf bwdif=mode=send_frame
#     Progressive→ passthrough
#     encode intermediate ffv1 to temp;  -SampleOnly: -ss 600 -t 120.
#     Non-Telecined sources also get `-fps_mode cfr -r <Get-VideoFrameRate>` so the
#     intermediate's header rate matches its timestamps (else downstream tools
#     re-time soft-telecined 23.976 frames at 29.97: video ~25% fast, audio clipped).
#  (c) engine = UpscaleAnimation (ContentType Animation) or UpscaleLiveAction, at
#      W x H where H=UpscaleHeight, W=round(H*DAR/2)*2 (anamorphic-safe; DAR from the
#      SOURCE's Get-VideoSourceInfo):
#        openproteus -> ncnn tool: tools/ncnn_upscale.py (ffmpeg -> upscale-ncnn-py
#                       OpenProteus 2x -> ffmpeg lanczos to WxH, setsar=1, x264 crf12 temp;
#                       --ffmpeg $FfmpegPath --ffprobe Resolve-ArmFfprobePath)
#        anime4k     -> video2x -p libplacebo --libplacebo-shader $UpscaleShader -w W -h H
#        realesrgan  -> legacy video2x realesrgan (model/scale from config)
#  (d) ffmpeg mux: libx265 -crf $UpscaleCrf -preset slow, copy original audio;
#      `-vf setsar=1` for openproteus/anime4k (not legacy realesrgan).
#  Output name: "<basename> [AI upscale 1080p].mkv". Temp files cleaned on any exit.

# DiscWatcher.ps1 (entry point)
#  Param: [-ConfigPath] [-Simulate] [-Once] (-Once: process current disc then exit —
#  used by tests). Register-WmiEvent Win32_VolumeChangeEvent EventType 2 + 30s poll
#  fallback (compare Get-DiscType per optical drive). Single-flight lock via named
#  mutex 'wrm-rip'. Dispatch:
#    Video  → Invoke-VideoRip (captures Resolve-Title result on .Resolved before
#             the rip runs) → Resolve-TitleOverride (re-reads metadata.json for
#             a user Title/Year/ContentType edit, else falls back to .Resolved) → rename
#             staging dir → Move-ToNas (NasVideoPath) → if DVD && UpscaleDvds: copy main mkv path into
#             UpscaleQueueDir queue file via New-UpscaleQueueEntry (<name>.json:
#             {Source;DestDir;JobId;ContentType}, JobId = a new Upscale job in State=Queued
#             (with the same ContentType), $null if job state is unavailable) → eject+notify
#  New-UpscaleQueueEntry -MkvPath <string> -DestDir <string> -FolderName <string>
#                        [-ContentType <LiveAction|Animation>] -Config <hashtable>
#  ContentType (default LiveAction) = the resolved value (Resolve-TitleOverride result;
#  anything but 'Animation' is passed as LiveAction). Written into the queue JSON and the
#  Upscale job record, so the web UI shows which engine will run before the worker starts.
#  New optional per-entry fields are added as further optional parameters (same style).
#    AudioCD→ Invoke-AudioRip → Move-ToNas (NasMusicPath) → eject+notify
#    Data   → log WARN + notify, no action (no job record).
#  Invoke-DiscEject -DriveLetter <char> -Config <hashtable>   (returns nothing, never throws)
#    No-op unless EjectWhenDone; under Simulate logs INFO "Simulate: skipping physical
#    eject of X:" and touches nothing. Otherwise the eject is VERIFIED (#41): Shell.Application
#    'Eject' verb (Invoke-ArmShellEject), then Wait-ArmEjected polls Win32_CDROMDrive
#    MediaLoaded (Get-ArmDriveMediaLoaded) every 500 ms for up to 10 s. Gone -> INFO
#    "Ejected X: (shell)". Still loaded (the verb silently does nothing from the hidden
#    wrm-watcher task) -> WARN, then Invoke-ArmIoctlEject (kernel32 P/Invoke compiled by
#    Initialize-ArmNativeEject: open \\.\X:, FSCTL_LOCK_VOLUME/FSCTL_DISMOUNT_VOLUME best
#    effort, IOCTL_STORAGE_MEDIA_REMOVAL allow, IOCTL_STORAGE_EJECT_MEDIA; needs no shell or
#    desktop) and poll again -> INFO "Ejected X: (IOCTL fallback)". Still loaded -> WARN
#    "Failed to eject X: ...". Every shell/native/CIM call lives in its own wrapper
#    (Invoke-ArmShellEject, Invoke-ArmIoctlEject, Get-ArmDriveMediaLoaded) so tests mock them
#    and never touch a real drive.
#  Every failure path: Send-ArmNotification Level Error; staging kept for forensics.
#  Job state: Invoke-DiscDispatch creates a Rip job (State=Detected, Drive, DiscType)
#  for Video/AudioCD and passes -JobId down; dispatch advances it
#  Detected → Ripping (set inside the rip function) → Moving → Complete (DestDir),
#  or Failed (Error) on any failure path, including unhandled exceptions.

# Upscale-Worker.ps1 (entry point)
#  Param: [-ConfigPath] [-Simulate] [-Once]. Poll UpscaleQueueDir every 60s for
#  *.json. Respect UpscaleActiveHours (start jobs only inside window). Process
#  priority BelowNormal. If !AutoUpscale: Invoke-Upscale -SampleOnly, notify with
#  sample path, rename queue file → .awaiting-review (user renames back to .json
#  after approving; document in README). Else full run → move result to DestDir,
#  notify, delete queue file. Failures → .failed + Error notification.
#  Job state per item: resolve the queue file's JobId (a missing/unknown JobId gets
#  a new Upscale job, persisted into the queue file). Set State=Sampling /
#  Upscaling BEFORE Invoke-Upscale (so queued vs. running is distinguishable; also
#  record ContentType from the queue item), then AwaitingReview (+SamplePath,
#  QueueFile=<.awaiting-review>, Engine, InterlaceType from the Invoke-Upscale result)
#  / Complete (+Engine, InterlaceType) / Failed
#  (+Error, QueueFile=<.failed>). An unparseable queue file becomes a new Failed
#  job. Job-state writes never throw and can never turn a good upscale into .failed.
#  Each pass (inside or outside active hours) first calls Remove-ArmStaleJobs.

# JobState.ps1 (job-state store; read by the web UI)
New-ArmJob     -Kind <Rip|Upscale> [-Properties <hashtable>] -Config <hashtable> -> [string] JobId | $null
Update-ArmJob  -JobId <string> -Properties <hashtable> -Config <hashtable> -> [bool]
Get-ArmJob     -JobId <string> -Config <hashtable> -> [pscustomobject] | $null
Get-ArmJobList [-Kind <Rip|Upscale>] -Config <hashtable> -> [pscustomobject] (pipeline; wrap in @())
Remove-ArmStaleJobs -Config <hashtable> -> [int] removed
#  One file per job: <StateDir>\jobs\<id>.json. Id = 'yyyyMMdd-HHmmss-<6 hex>'
#  (generated, never derived from input); every lookup validates that exact
#  pattern, so an Id can never address a path outside the jobs dir.
#  Record: { Id; Kind; State; Title; DiscLabel; DiscType; Drive; StagingDir;
#            DestDir; QueueFile; SamplePath; ContentType; Engine; InterlaceType;
#            Error; Created; Updated; History[] }
#  ContentType/Engine/InterlaceType are set on Upscale jobs only; the web UI shows them
#  next to the sample path so a reviewer sees which engine produced the sample.
#  History = [{ State; At }], appended on every State change. Timestamps are
#  ISO 8601 round-trip strings (PS 7 ConvertFrom-Json reads them back as [datetime]).
#  States: Rip     Detected → Ripping → Moving → Complete | Failed
#          Upscale Queued → Sampling → AwaitingReview → (Queued →) Upscaling → Complete | Failed
#                  (Cancelled reserved for the web UI's cancel action)
#  New-ArmJob: State defaults to Detected (Rip) / Queued (Upscale); Id/Kind/
#  Created/Updated/History are managed, not settable. Update-ArmJob merges
#  known fields (unknown keys and the managed ones are ignored) and stamps Updated.
#  Writes are atomic: unique <id>.json.<guid>.tmp then File.Move(overwrite).
#  Get-ArmJobList is newest first (by Id) and skips unreadable/foreign files.
#  Remove-ArmStaleJobs deletes Complete/Failed/Cancelled records whose Updated
#  is older than JobHistoryDays (default 30 when the key is missing), plus
#  stray .tmp files older than a day.
#  Never throws: missing/blank StateDir (logged WARN once), unwritable dir,
#  or corrupt records → WARN + no-op ($null / $false / nothing / 0).

# WebUi.ps1 (entry point)
#  Param: [-ConfigPath] [-Simulate] [-Once] (-Once: serve one request then exit —
#  used by tests). System.Net.HttpListener on http://localhost:<WebUiPort>/ only
#  (default 8765; no elevation/urlacl needed). HTTP.sys matches that prefix on the
#  Host header, so 127.0.0.1 / other host names get 400 Invalid Hostname (this also
#  defeats DNS rebinding). WebUiEnabled=$false → log INFO and exit. Both keys are
#  read with ContainsKey fallbacks. One failing request → 500, the loop carries on.
Invoke-ArmWebRequest -Method <string> -Path <string> [-Query <hashtable>] [-Body <string>]
                     [-Headers <hashtable>] -Config <hashtable> -> [hashtable]
#  @{ Status; ContentType; Body; Headers }. Pure (no sockets); the listener loop
#  only translates HttpListenerContext to/from it. Routes live in an ordered table
#  added with Register-ArmWebRoute -Method <GET|POST> -Pattern <regex> -Handler
#  <scriptblock>; the pattern is anchored (^...$) against the URL path, named groups
#  arrive as $Request.Params, and the handler gets one hashtable
#  @{ Method; Path; Query; Body; Headers; Params; Config }. No path match → 404;
#  path matches another method → 405 + Allow; handler throws → 500 (logged ERROR,
#  exception text not returned). Errors are JSON {Error}.
#  Routes:
#    GET /                  dashboard HTML: active rip (Detected/Ripping/Moving),
#                           rip history, upscale queue, last 200 log lines.
#                           Every dynamic string is [WebUtility]::HtmlEncode'd.
#    GET /app.js, /app.css  fixed static files from src/webui (no request data in paths).
#                           app.js polls /api/jobs + /api/log every 5 s and renders with
#                           textContent only.
#    GET /api/jobs[?kind=Rip|Upscale]   JSON array (always an array), newest first;
#                           each job has every JobState field, Created/Updated/History[].At
#                           as ISO 8601 round-trip strings. Unknown kind → 400.
#    GET /api/jobs/<id>     one job; malformed or unknown id → 404.
#    POST /api/jobs/<id>/{approve|retry|cancel}   upscale actions; require header
#                           'X-WRM-Action: 1' (else 403). Valid states: approve=AwaitingReview,
#                           retry=Failed, cancel=Queued|AwaitingReview; other state → 409,
#                           unknown id → 404. Each job in /api/jobs carries an Actions list
#                           (video rips that are Ripping carry 'metadata').
#    GET  /api/jobs/<id>/metadata   Rip jobs only (else 404). {Editable; Reason; Title; Year;
#                           FolderName; Current}: Title/Year read from the rip's
#                           metadata.json (the form's prefill); Editable=false + Reason when
#                           the rip is not Ripping, is an AudioCD, or its staging dir is gone.
#    POST /api/jobs/<id>/metadata   body JSON {Title; Year}; manual title override for a
#                           video rip. Header 'X-WRM-Action: 1' (else 403). Order of checks:
#                           403, 404 (unknown/non-Rip id), 409 (State != Ripping, AudioCD, or
#                           StagingDir missing / not a direct child of StagingDir), 400 (bad
#                           JSON, body > 4096 chars, or {Error:'Validation failed'; Errors:
#                           {Title?;Year?}}), then Set-ArmMetadataFile -Force into the job's
#                           StagingDir (path from the job record only, never the request)
#                           and a read-back (mismatch → 500 generic). If the job is no
#                           longer Ripping afterwards → 409 "may not have been applied".
#                           200 {Title;Year;FolderName}; the job's Title becomes FolderName.
#                           Validation: Title trimmed, required, <= 200 chars, no control
#                           chars, non-blank after ConvertTo-ArmSafeFileName, folder name not
#                           dot-only or a Windows device name; Year blank or exactly 4 digits.
#                           Resolve-TitleOverride picks the file up unchanged. Known limit:
#                           an edit landing in the few ms between Resolve-TitleOverride and
#                           the Moving update is accepted (200) but not applied.
#    GET  /api/metadata-preview?title=&year=   200 {Valid; FolderName; Errors} using the same
#                           ConvertTo-ArmFolderName rule (the form's live preview).
#    GET /api/log[?lines=N] {Lines:[...]} = last N lines of today's wrm-<yyyyMMdd>.log
#                           (default 200, clamped 1..1000, non-integer → 400; missing
#                           file → []). Read with FileShare.ReadWrite; never written.
#  Every response: Cache-Control no-store, X-Content-Type-Options nosniff, and
#  Content-Security-Policy default-src 'self' (no inline script/style).

# setup.ps1
#  Idempotent. winget install GuinpinSoft.MakeMKV, enzo1982.freac, Gyan.FFmpeg
#  (skip present); print manual step for Video2X (GitHub release, needed for the
#  anime4k/legacy engines). Install-NcnnUpscaler: venv at NcnnPath + pinned
#  tools/requirements-ncnn.txt + SHA256-verified OpenProteus model into NcnnModelDir
#  (warn-only on failure). Create dirs (StagingDir, UpscaleQueueDir, LogDir, StateDir).
#  Prompt for NAS paths/TMDb key/HA URL → write config/config.psd1 (skip prompts
#  with -NonInteractive; copies example). Register hidden Scheduled Tasks
#  'wrm-watcher', 'wrm-upscaler' and 'wrm-webui' (at logon, current user,
#  pwsh -WindowStyle Hidden -File <entrypoint>; the list comes from
#  Get-ArmScheduledTaskList -RepoRoot -> @{TaskName;ScriptPath}[]) and print the
#  web UI URL. -Uninstall removes the same tasks.
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
  bytes); freaccmd creates tagged-path .flac placeholder; video2x and ncnn copy input to
  output. Fixtures include at least one real-format makemkvcon `-r` transcript
  (info + rip), a TMDb search JSON, and ffmpeg idet stderr samples for all three
  interlace classes.
- End-to-end: `DiscWatcher.ps1 -Simulate -Once` with a fixture "disc" must produce a
  named folder under a temp NAS root; same for audio; `Upscale-Worker.ps1 -Simulate
  -Once` must consume a queue file; a queue file written by `New-UpscaleQueueEntry
  -ContentType Animation` must run the anime4k engine (video2x stub, not the ncnn
  stub; job `Engine=anime4k`). These run in `tests/EndToEnd.Tests.ps1`.
- ContentType detection (`tests/Resolve-Title.ContentType.Tests.ps1`, mocks only):
  TMDb animation / live action / missing genres / every fallback path; LLM agrees,
  disagrees (both directions), picks a different candidate, omits or garbles
  `animated`, declines, unavailable, disabled; metadata.json merge and override
  (ContentType-only edit, invalid value, Title-only edit). The live check lives in
  `tests/manual/Resolve-Title.LiveLlm.Tests.ps1` (excluded from CI).
- Web UI: routing/rendering is unit-tested through Invoke-ArmWebRequest in
  `tests/WebUi.Tests.ps1` (plus one socket smoke test of `WebUi.ps1 -Once`).
  Browser behavior is tested with Playwright in `tests/browser/` (Chromium; Node is
  test-only): `playwright.config.ts` launches `WebUi.ps1 -Simulate` on
  http://localhost:18765/ against a per-run temp config, and specs seed state via
  `fixtures/seed.ps1`, which writes through the real `src/JobState.ps1`. Every spec
  fails on any browser console error.
```
