Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Load wrm configuration from config/config.psd1 or config.example.psd1.

.DESCRIPTION
    Loads config/config.psd1; falls back to config.example.psd1 with a WARN log.
    Validates required keys and types; throws on missing NasVideoPath/NasMusicPath
    unless Simulate is $true. Expands relative paths to absolute.

.PARAMETER Path
    Path to config file. Defaults to config/config.psd1 in the script root.

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
        [string] $Path
    )

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

    # Backfill missing keys from example config
    foreach ($key in $exampleConfig.Keys) {
        if (-not $config.ContainsKey($key)) {
            $config[$key] = $exampleConfig[$key]
        }
    }

    # Validate required keys (check with ContainsKey for strict mode)
    $simulate = $config.ContainsKey('Simulate') -and $config.Simulate
    if (-not $simulate) {
        if (-not $config.ContainsKey('NasVideoPath') -or -not $config.NasVideoPath) {
            throw "NasVideoPath is required in config (or set Simulate=`$true)"
        }
        if (-not $config.ContainsKey('NasMusicPath') -or -not $config.NasMusicPath) {
            throw "NasMusicPath is required in config (or set Simulate=`$true)"
        }
    }

    # Expand relative paths to absolute
    $pathKeys = @('StagingDir', 'UpscaleQueueDir', 'LogDir', 'MakeMkvConPath', 'FreacCmdPath', 'FfmpegPath', 'Video2xPath')
    foreach ($key in $pathKeys) {
        if ($config.ContainsKey($key) -and $config[$key] -and -not [System.IO.Path]::IsPathRooted($config[$key])) {
            $config[$key] = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) $config[$key]
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

.EXAMPLE
    Write-ArmLog -Level INFO -Message "Rip started" -Config $config
#>
function Write-ArmLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level,

        [Parameter(Mandatory = $true)]
        [string] $Message,

        [hashtable] $Config
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logLine = "[$timestamp] [$Level] $Message"

    # Always write to console
    Write-Host -Object $logLine

    # Attempt file logging
    if ($Config -and $Config.LogDir) {
        try {
            $logDir = $Config.LogDir
            if (-not (Test-Path $logDir)) {
                $null = New-Item -ItemType Directory -Force -Path $logDir
            }

            $logFile = Join-Path $logDir "wrm-$(Get-Date -Format 'yyyyMMdd').log"
            Add-Content -Path $logFile -Value $logLine -ErrorAction Stop
        } catch {
            # Fail silently; logging failure must not fail the pipeline
        }
    }
}

<#
.SYNOPSIS
    Execute an external tool, optionally routing to a test stub in simulation mode.

.DESCRIPTION
    Runs an external tool (makemkvcon, freaccmd, ffmpeg, or video2x) with given arguments.
    Returns a hashtable with ExitCode, StdOut (array of lines), and StdErr (array of lines).

    When $Config.Simulate is $true, runs tests/stubs/stub-<name>.ps1 instead.
    Streams stdout lines to Write-ArmLog at INFO level with prefix "[<name>]".

.PARAMETER Name
    Tool name: makemkvcon, freaccmd, ffmpeg, or video2x.

.PARAMETER Arguments
    String array of command-line arguments.

.PARAMETER Config
    Configuration hashtable.

.PARAMETER TimeoutSec
    Timeout in seconds (default: 3600 for long rips).

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
        [ValidateSet('makemkvcon', 'freaccmd', 'ffmpeg', 'video2x')]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config,

        [int] $TimeoutSec = 3600
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
            $filePath = $Config["$($Name)Path"]
            if (-not $filePath) {
                throw "No path configured for $Name"
            }
            if (-not (Test-Path $filePath)) {
                throw "Tool not found: $filePath"
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

        # Launch process and capture streams concurrently to avoid deadlock
        $proc = [System.Diagnostics.Process]::Start($psi)

        # Start reading both streams asynchronously before WaitForExit to avoid deadlock
        # (process buffer fills -> blocks on write -> we're blocked waiting -> deadlock)
        $stdOutTask = $proc.StandardOutput.ReadToEndAsync()
        $stdErrTask = $proc.StandardError.ReadToEndAsync()

        # Use .NET WaitForExit to avoid race condition with fast-exiting processes
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            $proc.Kill($true)
            throw "Tool $Name timed out after $TimeoutSec seconds"
        }

        # Ensure async stream reads complete and collect results
        [System.Threading.Tasks.Task]::WaitAll($stdOutTask, $stdErrTask)
        $stdOutText = $stdOutTask.Result
        $stdErrText = $stdErrTask.Result

        $exitCode = $proc.ExitCode
        $stdout = @($stdOutText -split "`n" | Where-Object { $_ })
        $stderr = @($stdErrText -split "`n" | Where-Object { $_ })

        # Log stdout lines
        foreach ($line in $stdout) {
            if ($line) {
                Write-ArmLog -Level INFO -Message "[$Name] $line" -Config $Config
            }
        }

        # Log stderr if present
        foreach ($line in $stderr) {
            if ($line) {
                Write-ArmLog -Level WARN -Message "[$Name] STDERR: $line" -Config $Config
            }
        }

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
