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
    Video2xPath       = 'C:\Program Files\Video2X\video2x.exe'
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
    UpscaleModel      = 'realesrgan-plus'      # video2x 6.4 RealESRGAN models: realesr-animevideov3, realesrgan-plus-anime, realesrgan-plus
    UpscaleScale      = 4                      # realesrgan-plus/-anime only ship x4 models; use realesr-animevideov3 for x2/x3
    UpscaleCrf        = 16
    # --- Job history ---
    JobHistoryDays    = 30             # finished (Complete/Failed/Cancelled) job records older than this are pruned
    # --- Test/dev ---
    Simulate          = $false         # route Invoke-ArmTool to tests/stubs/
}
