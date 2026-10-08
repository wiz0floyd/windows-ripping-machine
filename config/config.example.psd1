@{
    # --- Required (setup.ps1 prompts for these) ---
    NasVideoPath      = '\\nas\media\import\movies'   # UNC
    NasMusicPath      = '\\nas\media\import\music'    # UNC
    # --- Paths ---
    StagingDir        = 'C:\rips\staging'
    UpscaleQueueDir   = 'C:\rips\upscale-queue'
    LogDir            = 'C:\rips\logs'
    StateDir          = 'C:\rips\state'    # job-state records for the web UI (<StateDir>\jobs\<id>.json)
    MakeMkvConPath    = 'C:\Program Files (x86)\MakeMKV\makemkvcon64.exe'
    FreacCmdPath      = 'C:\Program Files\fre-ac\freaccmd.exe'
    FfmpegPath        = 'ffmpeg'
    FfprobePath       = 'ffprobe'      # if omitted from config.psd1, defaults to the ffprobe.exe next to FfmpegPath (bare 'ffprobe' when FfmpegPath is bare)
    Video2xPath       = 'C:\Program Files\Video2X\video2x.exe'
    NcnnPath          = 'C:\ProgramData\wrm\venv\Scripts\python.exe'   # venv python that runs tools/ncnn_upscale.py (setup.ps1 creates it)
    NcnnModelDir      = 'C:\ProgramData\wrm\models'                      # holds openproteus-x2.param/.bin (setup.ps1 downloads them)
    # --- Behavior ---
    MinTitleLengthSec = 600
    RipAllTitles      = $true          # else main title only
    EjectWhenDone     = $true
    TmdbApiKey        = ''             # blank => label+date naming
    HaWebhookUrl      = ''             # blank => toast only
    # --- LLM disambiguation (optional) ---
    LlmDisambiguationEnabled = $false  # $true => ask a local LLM to disambiguate ambiguous TMDb matches
    LlmEndpoint       = 'http://127.0.0.1:8080/v1'   # OpenAI-compatible base URL (llama.cpp, etc.)
    LlmModel          = 'qwen3.5-9b'
    LlmTimeoutSec     = 15
    # --- Upscale stage ---
    UpscaleDvds       = $false
    AutoUpscale       = $false         # $false => stop after -SampleOnly clip, notify for review
    UpscaleActiveHours= @('23:00','08:00')
    UpscaleLiveAction = 'openproteus'  # engine for live-action: openproteus (2x ncnn, natural) | anime4k (sharper) | realesrgan (legacy, uses UpscaleModel/UpscaleScale)
    UpscaleAnimation  = 'anime4k'      # engine for ContentType=Animation (queue item field `ContentType`); same choices
    UpscaleHeight     = 1080           # output height; width comes from the source display aspect ratio
    UpscaleShader     = 'anime4k-v4-a+a'   # libplacebo shader used by the anime4k engine
    UpscaleModel      = 'realesrgan-plus'  # legacy realesrgan engine only: video2x 6.4 models realesr-animevideov3, realesrgan-plus-anime, realesrgan-plus
    UpscaleScale      = 4                  # legacy realesrgan engine only: plus/-anime ship x4 only; use realesr-animevideov3 for x2/x3
    UpscaleCrf        = 16
    # --- Web UI (http://localhost:<WebUiPort>/, this machine only) ---
    WebUiEnabled      = $true          # $false => the wrm-webui task exits immediately
    WebUiPort         = 8765
    WebUiOpenOnDisc   = $true          # open the dashboard in the browser when a disc is detected
    # --- Job history ---
    JobHistoryDays    = 30             # finished (Complete/Failed/Cancelled) job records older than this are pruned
    # --- Test/dev ---
    Simulate          = $false         # route Invoke-ArmTool to tests/stubs/
}
