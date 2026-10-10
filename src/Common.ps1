Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Resolve the ffprobe executable for a config. Pure: no I/O.

.DESCRIPTION
    Returns $Config.FfprobePath when set. Otherwise ffprobe ships beside ffmpeg, so a
    FfmpegPath with a directory part yields '<that dir>\ffprobe.exe'; a bare or absent
    FfmpegPath yields the bare 'ffprobe' (resolved via PATH by Invoke-ArmTool).

.OUTPUTS
    [string]
#>
function Resolve-ArmFfprobePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    if ($Config.ContainsKey('FfprobePath') -and $Config['FfprobePath']) {
        return [string]$Config['FfprobePath']
    }
    $ffmpegPath = if ($Config.ContainsKey('FfmpegPath') -and $Config['FfmpegPath']) { [string]$Config['FfmpegPath'] } else { 'ffmpeg' }
    if ($ffmpegPath -match '[\\/]') {
        return Join-Path (Split-Path -Parent $ffmpegPath) 'ffprobe.exe'
    }
    return 'ffprobe'
}

<#
.SYNOPSIS
    Load wrm configuration from config/config.psd1 or config.example.psd1.

.DESCRIPTION
    Loads config/config.psd1; falls back to config.example.psd1 with a WARN log.
    Validates required keys and types; throws on missing NasVideoPath/NasMusicPath
    unless Simulate is $true. Expands relative paths to absolute.

.PARAMETER Path
    Path to config file. Defaults to config/config.psd1 in the script root.

.PARAMETER Simulate
    Treat the config as Simulate (sets Simulate = $true). When no explicit -Path
    was given (example fallback or the default config.psd1), all directory/NAS
    paths are rebased onto a shared temp sandbox (<TEMP>\wrm-sim). An explicit
    -Path is never rebased.

.OUTPUTS
    [hashtable] Configuration with expanded paths.

.EXAMPLE
    $config = Get-ArmConfig
    $config = Get-ArmConfig -Path 'C:\custom\config.psd1'
#>
function Get-ArmConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string] $Path,
        [switch] $Simulate
    )

    $explicitPath = [bool] $Path

    if (-not $Path) {
        $scriptRoot = Split-Path -Parent $PSScriptRoot
        $Path = Join-Path $scriptRoot 'config' 'config.psd1'
    }

    $examplePath = Join-Path (Split-Path -Parent $Path) 'config.example.psd1'

    # Try real config first
    if (Test-Path $Path) {
        try {
            $config = Import-PowerShellDataFile -Path $Path
        } catch {
            Write-ArmLog -Level WARN -Message "Failed to load config at $Path : $_; falling back to example"
            $config = Import-PowerShellDataFile -Path $examplePath
        }
    } else {
        Write-ArmLog -Level WARN -Message "Config not found at $Path; using $examplePath"
        $config = Import-PowerShellDataFile -Path $examplePath
    }

    # Load example config as defaults
    try {
        $exampleConfig = Import-PowerShellDataFile -Path $examplePath
    } catch {
        Write-ArmLog -Level WARN -Message "Could not load example config for defaults: $_"
        $exampleConfig = @{}
    }

    # FfprobePath defaults to the ffprobe next to FfmpegPath (they ship together), so
    # configs written before the key existed keep working with a full-path FfmpegPath.
    # Resolve it from the user's own config before the example backfill below would
    # fill in the bare PATH-resolved 'ffprobe'.
    if (-not $config.ContainsKey('FfprobePath') -or -not $config['FfprobePath']) {
        $config['FfprobePath'] = Resolve-ArmFfprobePath -Config $config
    }

    # Backfill missing keys from example config
    foreach ($key in $exampleConfig.Keys) {
        if (-not $config.ContainsKey($key)) {
            $config[$key] = $exampleConfig[$key]
        }
    }

    # Validate required keys (check with ContainsKey for strict mode)
    if ($Simulate) { $config['Simulate'] = $true }
    $configSimulate = $config.ContainsKey('Simulate') -and $config.Simulate
    if (-not $configSimulate) {
        if (-not $config.ContainsKey('NasVideoPath') -or -not $config.NasVideoPath) {
            throw "NasVideoPath is required in config (or set Simulate=`$true)"
        }
        if (-not $config.ContainsKey('NasMusicPath') -or -not $config.NasMusicPath) {
            throw "NasMusicPath is required in config (or set Simulate=`$true)"
        }
    }

    # Simulate without an explicit -Path (example fallback OR the default
    # config.psd1): production C:\rips\... and \\nas\... paths must never be
    # touched, so rebase every directory / NAS destination onto a stable temp
    # sandbox shared by all simulate processes (so DiscWatcher -> Upscale-Worker
    # hand-off works). Only an explicit -Path is the user opting in.
    if ($configSimulate -and -not $explicitPath) {
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) "wrm-sim"
        $sandboxDirs = [ordered]@{
            NasVideoPath    = 'nas-video'
            NasMusicPath    = 'nas-music'
            StagingDir      = 'staging'
            UpscaleQueueDir = 'upscale-queue'
            LogDir          = 'logs'
            StateDir        = 'state'
        }
        try {
            $null = New-Item -ItemType Directory -Path $sandbox -Force
        } catch {
            Write-Warning "Could not create simulate sandbox $sandbox : $_"
        }
        foreach ($key in $sandboxDirs.Keys) {
            $config[$key] = Join-Path $sandbox $sandboxDirs[$key]
        }
        $config['Simulate'] = $true
        $config['SimulateSandboxRoot'] = $sandbox
        Write-ArmLog -Level INFO -Message "Simulate without explicit -Path: using sandbox $sandbox instead of production paths" -Config $config
    }

    # Expand relative paths to absolute. Bare tool names (no path separator, e.g.
    # FfmpegPath = 'ffmpeg') are left untouched so Invoke-ArmTool/Test-Path can
    # resolve them via PATH instead of joining them onto the repo root.
    $pathKeys = @('StagingDir', 'UpscaleQueueDir', 'LogDir', 'StateDir', 'MakeMkvConPath', 'FreacCmdPath', 'FfmpegPath', 'FfprobePath', 'Video2xPath', 'NcnnPath', 'NcnnModelDir')
    foreach ($key in $pathKeys) {
        if ($config.ContainsKey($key) -and $config[$key] -and -not [System.IO.Path]::IsPathRooted($config[$key])) {
            $hasSeparator = $config[$key] -match '[\\/]'
            if ($hasSeparator) {
                $config[$key] = Join-Path (Split-Path -Parent $PSScriptRoot) $config[$key]
            }
        }
    }

    return $config
}

<#
.SYNOPSIS
    Write timestamped log message to console and log file.

.DESCRIPTION
    Writes a timestamped line to both console and $Config.LogDir\wrm-<yyyyMMdd>.log.
    Must never throw; log directory is auto-created, and logging falls back to console-only
    if the log directory cannot be created.

.PARAMETER Level
    Log level: INFO, WARN, or ERROR.

.PARAMETER Message
    Log message text.

.PARAMETER Config
    Configuration hashtable (for LogDir). If omitted, logs to console only.
    $Config.LogContext, when set, is the default -Context.

.PARAMETER Context
    Optional tag (e.g. an upscale queue item name) written as "[<Context>]" after the
    level, so interleaved lines from parallel jobs can be told apart.

.EXAMPLE
    Write-ArmLog -Level INFO -Message "Rip started" -Config $config
    Write-ArmLog -Level INFO -Message "Sample ready" -Config $config -Context 'Movie (2001)'
#>
function Write-ArmLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level,

        [Parameter(Mandatory = $true)]
        [string] $Message,

        [hashtable] $Config,

        [string] $Context
    )

    if (-not $Context -and $Config -and $Config.ContainsKey('LogContext') -and $Config['LogContext']) {
        $Context = [string]$Config['LogContext']
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logLine = if ($Context) { "[$timestamp] [$Level] [$Context] $Message" } else { "[$timestamp] [$Level] $Message" }

    # Always write to console
    Write-Host -Object $logLine

    # Attempt file logging
    if ($Config -and $Config.ContainsKey('LogDir') -and $Config.LogDir) {
        try {
            $logDir = $Config.LogDir
            if (-not (Test-Path $logDir)) {
                $null = New-Item -ItemType Directory -Force -Path $logDir
            }

            $stamp = Get-Date -Format 'yyyyMMdd'
            $logFile = Join-Path $logDir "wrm-$stamp.log"
            if (-not (Add-ArmLogLine -Path $logFile -Line $logLine)) {
                # The shared daily file stayed locked by another wrm process for the whole
                # retry budget: keep the line in a per-process side file instead of dropping it.
                $fallback = Join-Path $logDir "wrm-$stamp-pid$PID.log"
                $null = Add-ArmLogLine -Path $fallback -Line "$logLine (shared log $logFile was locked)" -MaxAttempts 1
            }
        } catch {
            # Fail silently; logging failure must not fail the pipeline
        }
    }
}

<#
.SYNOPSIS
    Append one line to a log file, retrying while another process holds it. Never throws.

.DESCRIPTION
    The watcher, upscaler and web UI processes share one daily log. A writer that finds
    the file locked (sharing/lock violation) sleeps 10-60 ms and retries, up to
    -MaxAttempts times (~1.5 s by default). Any other failure, or running out of
    attempts, returns $false.

.OUTPUTS
    [bool] $true when the line was written.
#>
function Add-ArmLogLine {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Line,
        [int] $MaxAttempts = 40
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            [System.IO.File]::AppendAllText($Path, $Line + [Environment]::NewLine)
            return $true
        } catch {
            $ex = $_.Exception
            while ($ex.InnerException -and -not ($ex -is [System.IO.IOException])) { $ex = $ex.InnerException }
            # 32 = ERROR_SHARING_VIOLATION, 33 = ERROR_LOCK_VIOLATION: another writer has it.
            $locked = ($ex -is [System.IO.IOException]) -and (($ex.HResult -band 0xFFFF) -in @(32, 33))
            if (-not $locked) { return $false }
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Milliseconds (Get-Random -Minimum 10 -Maximum 60) }
        }
    }
    return $false
}

# key=value lines: ffmpeg `-progress pipe:1` blocks and tools/ncnn_upscale.py's progress
# lines. A block ends with `progress=continue|end`.
$script:ArmProgressLinePattern = '^([A-Za-z0-9_]+)=(.*)$'

<#
.SYNOPSIS
    Fold one key=value progress line into a parser state; return the parsed progress when
    the line closes a block (`progress=continue|end`), else $null. Pure apart from -State.

.OUTPUTS
    [pscustomobject] @{ Tool; Frame; Fps; OutTimeSec; Speed; Ended; Values } or $null.
    Frame/Fps/OutTimeSec/Speed are $null when the block lacks them or says N/A.
#>
function Update-ArmToolProgress {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Folds a line into an in-memory parser state; no system state changes.')]
    param(
        [Parameter(Mandatory = $true)] [hashtable] $State,
        [Parameter(Mandatory = $true)] [string] $Key,
        [AllowEmptyString()] [string] $Value = '',
        [string] $Tool = ''
    )

    if (-not $State.ContainsKey('Values')) { $State['Values'] = @{} }
    if ($Key -ne 'progress') {
        $State['Values'][$Key] = $Value.Trim()
        return $null
    }

    $v = $State['Values']
    $State['Values'] = @{}
    $num = {
        param($k)
        if (-not $v.ContainsKey($k)) { return $null }
        $s = ($v[$k] -replace 'x$', '').Trim()
        $d = 0.0
        if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
        return $null
    }
    $frame = & $num 'frame'
    # ffmpeg's out_time_ms is also in microseconds (a long-standing misnomer).
    $outUs = & $num 'out_time_us'
    if ($null -eq $outUs) { $outUs = & $num 'out_time_ms' }

    return [pscustomobject]@{
        Tool       = $Tool
        Frame      = if ($null -ne $frame) { [long]$frame } else { $null }
        Fps        = & $num 'fps'
        OutTimeSec = if ($null -ne $outUs -and $outUs -ge 0) { $outUs / 1e6 } else { $null }
        Speed      = & $num 'speed'
        Ended      = ($Value.Trim() -eq 'end')
        Values     = $v
    }
}

# Error-looking stderr lines are logged at WARN whatever -StdErrLevel says.
$script:ArmStdErrErrorPattern = '(?i)\b(error|fatal|failed|invalid|cannot|could not)\b'

<#
.SYNOPSIS
    Execute an external tool, optionally routing to a test stub in simulation mode.

.DESCRIPTION
    Runs an external tool (makemkvcon, freaccmd, ffmpeg, ffprobe, video2x, or ncnn - the venv python.exe that runs tools/ncnn_upscale.py) with given arguments.
    Returns a hashtable with ExitCode, StdOut (array of lines), and StdErr (array of lines).

    When $Config.Simulate is $true, runs tests/stubs/stub-<name>.ps1 instead.

    Output is read line by line while the tool runs (not buffered to exit): the calling
    thread waits on one pending ReadLineAsync per stream in short slices and handles each
    line on the PowerShell thread, so -ProgressHandler never runs on a pool thread. Every
    stdout line is logged at INFO as "[<name>] <line>" as it arrives; stderr lines per
    -StdErrLevel. Lines split on CR, LF or CRLF (so ffmpeg's CR-separated stats arrive as
    separate lines); empty lines are dropped.

.PARAMETER Name
    Tool name: makemkvcon, freaccmd, ffmpeg, ffprobe, video2x, or ncnn.

.PARAMETER Arguments
    String array of command-line arguments.

.PARAMETER Config
    Configuration hashtable.

.PARAMETER TimeoutSec
    Timeout in seconds (default: 3600 for long rips). The tool's process tree is killed
    when it is exceeded and ExitCode is -1.

.PARAMETER StdErrLevel
    How stderr lines are logged: WARN (default) as "[<name>] STDERR: <line>"; INFO for a
    tool whose stderr is informational; None to keep them only in the result (probes whose
    stderr is data). Error-looking lines (error/fatal/failed/invalid/cannot/could not) are
    always logged at WARN.

.PARAMETER ProgressHandler
    Scriptblock called with one parsed progress object (see Update-ArmToolProgress) each
    time a stdout key=value block closes with `progress=continue|end` (ffmpeg -progress
    pipe:1, tools/ncnn_upscale.py). Those key=value lines are consumed: neither logged nor
    kept in StdOut. A handler that throws is logged at WARN once and never fails the run.

.OUTPUTS
    [pscustomobject] with ExitCode, StdOut, StdErr properties.

.EXAMPLE
    $result = Invoke-ArmTool -Name makemkvcon -Arguments @('-r', 'info', 'disc:0') -Config $config
#>
function Invoke-ArmTool {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('makemkvcon', 'freaccmd', 'ffmpeg', 'ffprobe', 'video2x', 'ncnn')]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config,

        [int] $TimeoutSec = 3600,

        [ValidateSet('WARN', 'INFO', 'None')]
        [string] $StdErrLevel = 'WARN',

        [scriptblock] $ProgressHandler
    )

    $stdout = @()
    $stderr = @()
    $exitCode = -1

    try {
        # Determine FilePath and ArgumentList based on simulate mode
        if ($Config.ContainsKey('Simulate') -and $Config.Simulate) {
            # Run stub as out-of-process PowerShell script
            # Honor StubDir config override (for tests to use isolated temp dirs)
            if ($Config.ContainsKey('StubDir') -and $Config.StubDir) {
                $stubDir = $Config.StubDir
            } else {
                $stubDir = Join-Path $PSScriptRoot '..' 'tests' 'stubs'
            }
            $stubPath = Join-Path $stubDir "stub-$Name.ps1"
            if (-not (Test-Path $stubPath)) {
                throw "Stub not found: $stubPath"
            }
            $filePath = (Get-Process -Id $PID).Path
            $argumentList = @('-NoProfile', '-File', $stubPath) + $Arguments
        } else {
            # Run real tool
            # ffprobe's path falls back to the file beside FfmpegPath (see Resolve-ArmFfprobePath).
            $filePath = if ($Name -eq 'ffprobe') { Resolve-ArmFfprobePath -Config $Config } else { $Config["$($Name)Path"] }
            if (-not $filePath) {
                throw "No path configured for $Name"
            }
            if ($filePath -match '[\\/]') {
                # Explicit path (relative or absolute) - must exist on disk
                if (-not (Test-Path $filePath)) {
                    throw "Tool not found: $filePath"
                }
            } else {
                # Bare tool name - resolve via PATH
                $resolved = Get-Command -Name $filePath -CommandType Application -ErrorAction SilentlyContinue
                if (-not $resolved) {
                    throw "Tool not found on PATH: $filePath"
                }
                $filePath = $resolved.Source
            }
            $argumentList = $Arguments
        }

        # Unified execution path using System.Diagnostics.Process for proper argument quoting
        # ProcessStartInfo.ArgumentList.Add() handles Windows argument escaping correctly,
        # unlike Start-Process -ArgumentList which can split on spaces
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $filePath
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        # Add each argument individually; .NET handles quoting/escaping per argument
        foreach ($arg in $argumentList) {
            $psi.ArgumentList.Add($arg)
        }

        $proc = [System.Diagnostics.Process]::Start($psi)
        $timeoutMs = [long]$TimeoutSec * 1000
        $clock = [System.Diagnostics.Stopwatch]::StartNew()

        # Both streams are drained concurrently (one pending ReadLineAsync each) so a full
        # pipe buffer on either can never deadlock the child. Lines are handled here, on
        # the PowerShell thread, between short waits.
        $readers = @($proc.StandardOutput, $proc.StandardError)
        $pending = @($readers[0].ReadLineAsync(), $readers[1].ReadLineAsync())
        $outLines = [System.Collections.Generic.List[string]]::new()
        $errLines = [System.Collections.Generic.List[string]]::new()
        $progressState = @{}
        $handlerFailed = $false

        while ($null -ne $pending[0] -or $null -ne $pending[1]) {
            $remaining = $timeoutMs - $clock.ElapsedMilliseconds
            if ($remaining -le 0) {
                $proc.Kill($true)
                throw "Tool $Name timed out after $TimeoutSec seconds"
            }
            if ($null -eq $pending[0]) {
                $live = @(1); $tasks = [System.Threading.Tasks.Task[]]@($pending[1])
            } elseif ($null -eq $pending[1]) {
                $live = @(0); $tasks = [System.Threading.Tasks.Task[]]@($pending[0])
            } else {
                $live = @(0, 1); $tasks = [System.Threading.Tasks.Task[]]@($pending[0], $pending[1])
            }
            $hit = [System.Threading.Tasks.Task]::WaitAny($tasks, [int][math]::Min(250, $remaining))
            if ($hit -lt 0) { continue }

            $stream = $live[$hit]
            $line = $pending[$stream].GetAwaiter().GetResult()
            if ($null -eq $line) {
                $pending[$stream] = $null   # EOF
                continue
            }
            $pending[$stream] = $readers[$stream].ReadLineAsync()
            if (-not $line) { continue }

            if ($stream -eq 0) {
                if ($ProgressHandler -and $line -match $script:ArmProgressLinePattern) {
                    $progress = Update-ArmToolProgress -State $progressState -Key $Matches[1] -Value $Matches[2] -Tool $Name
                    if ($progress) {
                        try {
                            & $ProgressHandler $progress
                        } catch {
                            if (-not $handlerFailed) {
                                Write-ArmLog -Level WARN -Message "[$Name] progress handler failed (further failures not logged): $_" -Config $Config
                                $handlerFailed = $true
                            }
                        }
                    }
                    continue
                }
                $outLines.Add($line)
                Write-ArmLog -Level INFO -Message "[$Name] $line" -Config $Config
            } else {
                $errLines.Add($line)
                if ($StdErrLevel -eq 'WARN' -or $line -match $script:ArmStdErrErrorPattern) {
                    Write-ArmLog -Level WARN -Message "[$Name] STDERR: $line" -Config $Config
                } elseif ($StdErrLevel -eq 'INFO') {
                    Write-ArmLog -Level INFO -Message "[$Name] STDERR: $line" -Config $Config
                }
            }
        }

        # Both streams hit EOF; the process may still be exiting.
        $remaining = [math]::Max(0, $timeoutMs - $clock.ElapsedMilliseconds)
        if (-not $proc.WaitForExit([int][math]::Min([int]::MaxValue, $remaining))) {
            $proc.Kill($true)
            throw "Tool $Name timed out after $TimeoutSec seconds"
        }
        $proc.WaitForExit()

        $exitCode = $proc.ExitCode
        $stdout = @($outLines)
        $stderr = @($errLines)

    } catch {
        Write-ArmLog -Level ERROR -Message "Invoke-ArmTool $Name failed: $_" -Config $Config
        $exitCode = -1
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

<#
.SYNOPSIS
    Determine the type of disc loaded in an optical drive.

.DESCRIPTION
    Examines an optical drive to determine disc type:
    - AudioCD: media loaded (Win32_CDROMDrive.MediaLoaded) but no mountable filesystem
    - Video: CDFS/UDF volume containing VIDEO_TS\ or BDMV\ at root
    - Data: filesystem present, no video markers
    - None: no media loaded

.PARAMETER DriveLetter
    Single character drive letter (e.g., 'D').

.OUTPUTS
    [string] One of: 'AudioCD', 'Video', 'Data', 'None'

.EXAMPLE
    $discType = Get-DiscType -DriveLetter 'D'
#>
function Get-DiscType {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ $_ -match '^[A-Za-z]$' })]
        [char] $DriveLetter
    )

    $DriveLetter = [char]::ToUpper($DriveLetter)

    try {
        # Check if media is loaded
        $drive = Get-CimInstance -ClassName Win32_CDROMDrive -Filter "Drive='$($DriveLetter):'" -ErrorAction SilentlyContinue
        if (-not $drive -or -not $drive.MediaLoaded) {
            return 'None'
        }

        # Try to get mounted volume
        $volume = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$($DriveLetter):'" -ErrorAction SilentlyContinue
        if (-not $volume -or -not $volume.FileSystem) {
            # Media loaded but no filesystem = audio CD
            return 'AudioCD'
        }

        # Check for video markers
        $videoPath = "$($DriveLetter):\VIDEO_TS"
        $bdmvPath = "$($DriveLetter):\BDMV"
        if ((Test-Path $videoPath -ErrorAction SilentlyContinue) -or (Test-Path $bdmvPath -ErrorAction SilentlyContinue)) {
            return 'Video'
        }

        # Has filesystem but no video markers = data
        return 'Data'

    } catch {
        Write-ArmLog -Level WARN -Message "Error checking disc type on $($DriveLetter): $_" -Config @{}
        return 'None'
    }
}

<#
.SYNOPSIS
    Build a standardized pipeline-step result object.

.DESCRIPTION
    Shared constructor for the [pscustomobject] result shape used across
    Rip-AudioCd.ps1, Move-ToNas.ps1, and Upscale-Video.ps1 (and similar
    scripts). Always includes Success first and Error last; any additional
    properties (OutputDir, Artist, Album, DestDir, OutputFile,
    InterlaceType, etc.) are inserted in between, in the order supplied via
    -Properties, so each call site can reproduce its existing output shape.

.PARAMETER Success
    Whether the operation succeeded.

.PARAMETER Properties
    Extra properties to include between Success and Error. Pass an
    [ordered]@{} (or [System.Collections.Specialized.OrderedDictionary])
    so the resulting property order matches insertion order; a plain
    @{} hashtable does not guarantee ordering in PowerShell.

.PARAMETER ErrorMessage
    Error message, if any. Omit or pass $null/empty on success. Populates
    the resulting object's 'Error' property. Aliased to -Error for callers
    (the parameter itself cannot be named $Error; that shadows PowerShell's
    automatic $Error variable).

.OUTPUTS
    [pscustomobject] with Success, the supplied extra properties, and Error.

.EXAMPLE
    New-ArmResult -Success $true -Properties ([ordered]@{ OutputDir = $dir; Artist = $artist; Album = $album })
    New-ArmResult -Success $false -Error 'Rip failed' -Properties ([ordered]@{ OutputDir = $null; Artist = $null; Album = $null })
#>
function New-ArmResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure object constructor; despite the New- verb it does not change system state.')]
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Success,

        [System.Collections.Specialized.OrderedDictionary] $Properties = [ordered]@{},

        [Alias('Error')]
        [string] $ErrorMessage
    )

    $obj = [ordered]@{ Success = $Success }
    foreach ($key in $Properties.Keys) {
        $obj[$key] = $Properties[$key]
    }
    $obj['Error'] = $ErrorMessage

    return [pscustomobject]$obj
}

<#
.SYNOPSIS
    Sanitize a string into a filesystem-safe file name.

.DESCRIPTION
    Removes characters invalid in Windows file names (per
    [System.IO.Path]::GetInvalidFileNameChars()), collapses runs of
    whitespace into a single space, and trims leading/trailing whitespace.

.PARAMETER Name
    Candidate file name (may be empty).

.OUTPUTS
    [string] Sanitized file name.

.EXAMPLE
    ConvertTo-ArmSafeFileName -Name 'My: Movie / Title?'
#>
function ConvertTo-ArmSafeFileName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Name
    )
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $pattern = "[$([regex]::Escape($invalid))]"
    return (($Name -replace $pattern, '') -replace '\s+', ' ').Trim()
}
