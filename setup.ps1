[CmdletBinding()]
param(
    [switch] $NonInteractive,
    [switch] $Uninstall,
    [string] $NasVideoPath,
    [string] $NasMusicPath,
    [string] $TmdbApiKey,
    [string] $HaWebhookUrl,
    [string] $RunAsUser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Check whether a winget package id is already installed.

.PARAMETER Id
    Winget package identifier (e.g. 'GuinpinSoft.MakeMKV').

.OUTPUTS
    [bool] $true if the package appears in `winget list --id <Id> -e`.
#>
function Test-WingetPackageInstalled {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Id
    )

    try {
        $result = & winget list --id $Id -e --accept-source-agreements 2>$null
        return ($LASTEXITCODE -eq 0) -and ($null -ne ($result | Select-String -SimpleMatch $Id))
    } catch {
        Write-Warning "Test-WingetPackageInstalled: unable to query winget for '$Id': $_"
        return $false
    }
}

<#
.SYNOPSIS
    Install a package via winget, skipping if already present (idempotent).

.PARAMETER Id
    Winget package identifier.

.PARAMETER DisplayName
    Human-readable name for log output.
#>
function Install-WingetPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Id,

        [Parameter(Mandatory = $true)]
        [string] $DisplayName
    )

    if (Test-WingetPackageInstalled -Id $Id) {
        Write-Host "$DisplayName already installed (winget id $Id); skipping."
        return
    }

    Write-Host "Installing $DisplayName via winget ($Id)..."
    & winget install --id $Id -e --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "winget install failed for $Id (exit code $LASTEXITCODE). Install '$DisplayName' manually."
    }
}

<#
.SYNOPSIS
    Print the manual installation step for Video2X (no winget package available).
#>
function Show-Video2xManualStep {
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host '== Manual step required: Video2X ==' -ForegroundColor Yellow
    Write-Host 'Video2X is not available via winget. Download the latest Windows release from:'
    Write-Host '  https://github.com/k4yt3x/video2x/releases'
    Write-Host 'and install it to the path configured as Video2xPath in config/config.psd1'
    Write-Host '(default: C:\Program Files\Video2X\video2x.exe).'
    Write-Host ''
}

function Invoke-ArmPython {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Python,
        [Parameter(Mandatory = $true)] [string[]] $Arguments
    )
    & $Python @Arguments
    return $LASTEXITCODE
}

function Expand-ArmTarGz {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Archive,
        [Parameter(Mandatory = $true)] [string] $Destination
    )
    $null = New-Item -ItemType Directory -Force -Path $Destination
    & tar -xzf $Archive -C $Destination
    return $LASTEXITCODE
}

<#
.SYNOPSIS
    Copy a repo-bundled ncnn model (tools/models/<Name>.param/.bin) into ModelDir after
    checking both files against pinned SHA256 values. Returns $true when installed or
    already present.

.DESCRIPTION
    Non-fatal: a missing or mismatched source file is a warning and nothing is copied.
    An existing pair in ModelDir is left alone (same idempotency rule as the OpenProteus
    download). The default is 2xLiveActionV1_SPAN (jcj83429, CC BY-NC-SA 4.0), converted
    by tools/convert_span_ncnn.py; see tools/models/README.md.
#>
function Install-ArmBundledNcnnModel {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)] [string] $SourceDir,
        [Parameter(Mandatory = $true)] [string] $ModelDir,
        [string] $Name = 'liveaction-x2',
        [string] $ParamSha256 = '2b0a04ad8519d2bc526227e7fedde9b7ebe7bce2f42476ad73c3431c49928bdc',
        [string] $BinSha256 = '5395811c56e60f39e42d9a3587fba1fa7af07a3aed1dfca26ae38e580d3b6f27'
    )

    $targets = @(
        @{ Ext = 'param'; Sha = $ParamSha256 }
        @{ Ext = 'bin'; Sha = $BinSha256 }
    )
    if (@($targets | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ModelDir "$Name.$($_.Ext)")) }).Count -eq 0) {
        Write-Host "$Name model already installed: $ModelDir"
        return $true
    }
    try {
        foreach ($t in $targets) {
            $src = Join-Path $SourceDir "$Name.$($t.Ext)"
            if (-not (Test-Path -LiteralPath $src)) {
                Write-Warning "Bundled model file $src is missing; the '$Name' model was NOT installed."
                return $false
            }
            $actual = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
            if ($actual -ne $t.Sha.ToUpperInvariant()) {
                Write-Warning "$src SHA256 mismatch (expected $($t.Sha), got $($actual.ToLowerInvariant())); the '$Name' model was NOT installed."
                return $false
            }
        }
        $null = New-Item -ItemType Directory -Force -Path $ModelDir
        foreach ($t in $targets) {
            Copy-Item -LiteralPath (Join-Path $SourceDir "$Name.$($t.Ext)") -Destination (Join-Path $ModelDir "$Name.$($t.Ext)") -Force
        }
        Write-Host "Installed $Name model to $ModelDir"
        return $true
    } catch {
        Write-Warning "$Name model install failed: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Install the ncnn upscale runtime used by the 'openproteus' and 'liveaction' engines: a
    dedicated Python venv with tools/requirements-ncnn.txt, the repo-bundled LiveAction SPAN
    model (Install-ArmBundledNcnnModel), and the OpenProteus 2x ncnn model.

.DESCRIPTION
    Idempotent and non-fatal: every failure is a warning (the pipeline still works
    with the anime4k/realesrgan engines). The model download is verified against a
    pinned SHA256 before it is installed. The model comes from the
    TNTwise/real-video-enhancer-models release of Sirosky's 2x OpenProteus Compact;
    the upstream repo declares no license, so this is for personal use.

.PARAMETER RequirementsPath
    tools/requirements-ncnn.txt.

.PARAMETER PythonPath
    Target venv python.exe (config key NcnnPath). Created if missing.

.PARAMETER ModelDir
    Directory receiving openproteus-x2 / liveaction-x2 .param/.bin (config key NcnnModelDir).

.PARAMETER BundledModelDir
    Repo directory holding the bundled models (default tools/models next to this script).

.PARAMETER BasePython
    Python used to create the venv (default: python on PATH).
#>
function Install-NcnnUpscaler {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $RequirementsPath,
        [Parameter(Mandatory = $true)] [string] $PythonPath,
        [Parameter(Mandatory = $true)] [string] $ModelDir,
        [string] $BasePython = 'python',
        [string] $BundledModelDir = (Join-Path $PSScriptRoot 'tools' 'models'),
        [string] $ModelUrl = 'https://github.com/TNTwise/real-video-enhancer-models/releases/download/models/2x_OpenProteus_Compact_i2_70K.tar.gz',
        [string] $ModelSha256 = '0d96689273650613726ebae4482cdc56943f46e819f99109054d0ca325d6a7c7'
    )

    # --- venv + packages ---
    if (-not (Test-Path -LiteralPath $PythonPath)) {
        $venvDir = Split-Path -Parent (Split-Path -Parent $PythonPath)
        Write-Host "Creating Python venv: $venvDir"
        $rc = Invoke-ArmPython -Python $BasePython -Arguments @('-m', 'venv', $venvDir)
        if ($rc -ne 0 -or -not (Test-Path -LiteralPath $PythonPath)) {
            Write-Warning "Could not create the Python venv at $venvDir (is Python 3.10+ on PATH?). The 'openproteus' and 'liveaction' engines will be unavailable; set UpscaleLiveAction = 'anime4k' or install Python and re-run setup."
            return
        }
    } else {
        Write-Host "Python venv already exists: $PythonPath"
    }
    $rc = Invoke-ArmPython -Python $PythonPath -Arguments @('-I', '-m', 'pip', 'install', '--quiet', '-r', $RequirementsPath)
    if ($rc -ne 0) {
        Write-Warning "pip install -r $RequirementsPath failed (exit $rc); the 'openproteus' and 'liveaction' engines may not work."
        return
    }

    # --- bundled model (no download) ---
    $null = Install-ArmBundledNcnnModel -SourceDir $BundledModelDir -ModelDir $ModelDir

    # --- OpenProteus model ---
    $paramFile = Join-Path $ModelDir 'openproteus-x2.param'
    $binFile = Join-Path $ModelDir 'openproteus-x2.bin'
    if ((Test-Path -LiteralPath $paramFile) -and (Test-Path -LiteralPath $binFile)) {
        Write-Host "OpenProteus model already installed: $ModelDir"
        return
    }

    $work = Join-Path ([System.IO.Path]::GetTempPath()) "wrm-openproteus-$(New-Guid)"
    try {
        $null = New-Item -ItemType Directory -Force -Path $work
        $archive = Join-Path $work 'model.tar.gz'
        Write-Host 'Downloading OpenProteus 2x ncnn model...'
        Invoke-WebRequest -Uri $ModelUrl -OutFile $archive -UseBasicParsing
        $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        if ($actual -ne $ModelSha256.ToUpperInvariant()) {
            Write-Warning "OpenProteus model SHA256 mismatch (expected $ModelSha256, got $($actual.ToLowerInvariant())); NOT installing it."
            return
        }
        $extracted = Join-Path $work 'x'
        if ((Expand-ArmTarGz -Archive $archive -Destination $extracted) -ne 0) {
            Write-Warning 'Could not extract the OpenProteus model archive; skipping.'
            return
        }
        $param = Get-ChildItem -LiteralPath $extracted -Recurse -Filter '*.param' | Select-Object -First 1
        $bin = Get-ChildItem -LiteralPath $extracted -Recurse -Filter '*.bin' | Select-Object -First 1
        if (-not $param -or -not $bin) {
            Write-Warning 'OpenProteus archive did not contain a .param/.bin pair; skipping.'
            return
        }
        $null = New-Item -ItemType Directory -Force -Path $ModelDir
        Copy-Item -LiteralPath $param.FullName -Destination $paramFile -Force
        Copy-Item -LiteralPath $bin.FullName -Destination $binFile -Force
        Write-Host "Installed OpenProteus model to $ModelDir"
    } catch {
        Write-Warning "OpenProteus model install failed: $_"
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Create the staging/queue/log directories used by the pipeline, if missing.

.PARAMETER Paths
    Hashtable with keys StagingDir, UpscaleQueueDir, LogDir, StateDir.
#>
function Initialize-ArmDirectories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Paths
    )

    foreach ($key in @('StagingDir', 'UpscaleQueueDir', 'LogDir', 'StateDir')) {
        $path = $Paths[$key]
        if (-not $path) {
            continue
        }
        if (Test-Path -Path $path) {
            Write-Host "Directory already exists: $path"
        } else {
            $null = New-Item -ItemType Directory -Force -Path $path
            Write-Host "Created directory: $path"
        }
    }
}

<#
.SYNOPSIS
    Write config/config.psd1, either interactively prompting for required values
    or by copying config.example.psd1 verbatim (-NonInteractive).

.DESCRIPTION
    Any of NasVideoPath/NasMusicPath/TmdbApiKey/HaWebhookUrl supplied as parameters
    are used as-is and skip the corresponding prompt, so this function is
    unit-testable without interactive input.

.PARAMETER ExamplePath
    Path to config/config.example.psd1.

.PARAMETER OutputPath
    Path to write config/config.psd1 to.

.PARAMETER NonInteractive
    Skip all prompts and copy the example file verbatim.

.PARAMETER NasVideoPath
    Pre-supplied NAS video UNC path; prompted for if omitted and not -NonInteractive.

.PARAMETER NasMusicPath
    Pre-supplied NAS music UNC path; prompted for if omitted and not -NonInteractive.

.PARAMETER TmdbApiKey
    Pre-supplied TMDb API key (optional; blank allowed).

.PARAMETER HaWebhookUrl
    Pre-supplied Home Assistant webhook URL (optional; blank allowed).
#>
function New-ArmConfigFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ExamplePath,

        [Parameter(Mandatory = $true)]
        [string] $OutputPath,

        [switch] $NonInteractive,

        [string] $NasVideoPath,

        [string] $NasMusicPath,

        [string] $TmdbApiKey,

        [string] $HaWebhookUrl
    )

    $content = Get-Content -Path $ExamplePath -Raw

    if ($NonInteractive) {
        Set-Content -Path $OutputPath -Value $content -NoNewline
        Write-Host "Wrote $OutputPath from config.example.psd1 (-NonInteractive)."
        return
    }

    if (-not $NasVideoPath) {
        $NasVideoPath = Read-Host 'NAS video path (UNC, e.g. \\nas\media\import\movies)'
    }
    if (-not $NasMusicPath) {
        $NasMusicPath = Read-Host 'NAS music path (UNC, e.g. \\nas\media\import\music)'
    }
    if ($PSBoundParameters.Keys -notcontains 'TmdbApiKey') {
        $TmdbApiKey = Read-Host 'TMDb API key (blank to skip; falls back to label+date naming)'
    }
    if ($PSBoundParameters.Keys -notcontains 'HaWebhookUrl') {
        $HaWebhookUrl = Read-Host 'Home Assistant webhook URL (blank to skip; toast-only notifications)'
    }

    $content = $content -replace "NasVideoPath\s*=\s*'[^']*'", "NasVideoPath      = '$NasVideoPath'"
    $content = $content -replace "NasMusicPath\s*=\s*'[^']*'", "NasMusicPath      = '$NasMusicPath'"
    $content = $content -replace "TmdbApiKey\s*=\s*'[^']*'", "TmdbApiKey        = '$TmdbApiKey'"
    $content = $content -replace "HaWebhookUrl\s*=\s*'[^']*'", "HaWebhookUrl      = '$HaWebhookUrl'"

    Set-Content -Path $OutputPath -Value $content -NoNewline
    Write-Host "Wrote $OutputPath."
}

<#
.SYNOPSIS
    Return the current Windows identity as "DOMAIN\User" (or "COMPUTER\User" on
    a workgroup machine).

.DESCRIPTION
    Uses the security token of the running process rather than the
    $env:USERDOMAIN / $env:USERNAME variables. On workgroup machines
    USERDOMAIN can be 'WORKGROUP' while the account really belongs to the
    computer, and Register-ScheduledTask then fails with "No mapping between
    account names and security IDs was done". Kept as its own function so
    Pester can mock it.

.OUTPUTS
    [string] The account name from [Security.Principal.WindowsIdentity]::GetCurrent().
#>
function Get-ArmCurrentUserName {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

<#
.SYNOPSIS
    Register a hidden, at-logon scheduled task running an entry-point script for
    the current user (idempotent: skips if the task already exists).

.PARAMETER TaskName
    Scheduled task name (e.g. 'wrm-watcher').

.PARAMETER ScriptPath
    Full path to the pwsh entry-point script to run.

.PARAMETER RunAsUser
    The "DOMAIN\User" (or "COMPUTER\User") the task's principal should run as.
    Defaults to Get-ArmCurrentUserName (the process's Windows identity, not
    $env:USERDOMAIN\$env:USERNAME, which can be 'WORKGROUP\user' on workgroup
    machines and makes Register-ScheduledTask fail). That default is only
    correct when this function runs un-elevated or in a session that was never
    relaunched for elevation. When setup.ps1 relaunches itself elevated
    (Start-Process -Verb RunAs), the elevated child's identity may be a
    different (admin) account than the user who invoked setup.ps1, so the
    entry point captures the original identity before relaunching and passes
    it through explicitly here.
#>
function Register-ArmScheduledTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $TaskName,

        [Parameter(Mandatory = $true)]
        [string] $ScriptPath,

        [string] $RunAsUser = (Get-ArmCurrentUserName)
    )

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Scheduled task '$TaskName' already registered; skipping."
        return
    }

    $action = New-ScheduledTaskAction -Execute 'pwsh.exe' `
        -Argument "-WindowStyle Hidden -File `"$ScriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId $RunAsUser -LogonType Interactive
    $settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Description "wrm: $TaskName" -Force `
            -ErrorAction Stop | Out-Null
    } catch {
        throw "Failed to register scheduled task '$TaskName': $($_.Exception.Message). Re-run setup.ps1 from an elevated (Run as Administrator) pwsh session."
    }
    Write-Host "Registered scheduled task '$TaskName' -> $ScriptPath"
}

<#
.SYNOPSIS
    The wrm scheduled tasks (name + entry-point script) that setup registers and
    -Uninstall removes, in registration order.

.PARAMETER RepoRoot
    Repository root (the directory containing src\).

.OUTPUTS
    [hashtable[]] @{ TaskName; ScriptPath }
#>
function Get-ArmScheduledTaskList {
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepoRoot
    )

    return @(
        @{ TaskName = 'wrm-watcher'; ScriptPath = Join-Path $RepoRoot 'src' 'DiscWatcher.ps1' }
        @{ TaskName = 'wrm-upscaler'; ScriptPath = Join-Path $RepoRoot 'src' 'Upscale-Worker.ps1' }
        @{ TaskName = 'wrm-webui'; ScriptPath = Join-Path $RepoRoot 'src' 'WebUi.ps1' }
    )
}

<#
.SYNOPSIS
    Thin wrapper around [Environment]::UserInteractive so it can be mocked
    in tests.

.OUTPUTS
    [bool] The value of [Environment]::UserInteractive.
#>
function Get-ArmIsUserInteractive {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return [Environment]::UserInteractive
}

<#
.SYNOPSIS
    Detect whether the current process lacks an interactive desktop for
    UAC's consent prompt.

.DESCRIPTION
    UAC's consent prompt requires an interactive window station/desktop.
    SSH sessions, WinRM/PSRemoting sessions, PsExec without -i, and
    service/SYSTEM contexts all lack one, so Start-Process -Verb RunAs
    cannot show the prompt and will hang or fail silently. Detecting this
    lets setup.ps1 fail fast with an actionable fix instead.

    Combines three signals, any of which is treated as non-interactive:
      - The standard OpenSSH session env vars (SSH_CONNECTION/SSH_CLIENT/
        SSH_TTY).
      - [Environment]::UserInteractive being false (services and other
        non-interactive process contexts).
      - $env:SESSIONNAME: 'Console' (local interactive logon) and
        'RDP-Tcp#N'-style (RDP) are treated as interactive; absent, or
        'Services'/'RemoteControl'-prefixed, indicates a WinRM/PSRemoting
        or service session.

.OUTPUTS
    [bool] $true if any of the above signals indicate a non-interactive
    session.
#>
function Test-NonInteractiveSession {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($env:SSH_CONNECTION -or $env:SSH_CLIENT -or $env:SSH_TTY) {
        return $true
    }

    if (-not (Get-ArmIsUserInteractive)) {
        return $true
    }

    $sessionName = $env:SESSIONNAME
    if ([string]::IsNullOrEmpty($sessionName)) {
        return $true
    }
    if ($sessionName -match '^(Services|RemoteControl)') {
        return $true
    }

    return $false
}

<#
.SYNOPSIS
    Remove a scheduled task if present (idempotent).

.PARAMETER TaskName
    Scheduled task name to remove.
#>
function Unregister-ArmScheduledTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $TaskName
    )

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Host "Scheduled task '$TaskName' not present; nothing to remove."
        return
    }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'."
}

<#
.SYNOPSIS
    Relaunch setup.ps1 elevated via Start-Process -Verb RunAs, and throw if
    the elevated child exits non-zero.

.DESCRIPTION
    Start-Process without -PassThru discards the child process's exit code,
    so a failure in the elevated child (e.g. Register-ArmScheduledTask
    throwing) would otherwise be silently swallowed and the original,
    un-elevated caller would return/exit as if everything succeeded. This
    function captures the exit code and throws an actionable error when it's
    non-zero, so the caller's own uncaught-throw/exit behavior surfaces the
    failure.

.PARAMETER ArgumentList
    Arguments to pass to the relaunched pwsh.exe (e.g. -File, bound
    parameters, etc.).
#>
function Invoke-ArmElevatedRelaunch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $ArgumentList
    )

    $proc = Start-Process -FilePath 'pwsh.exe' -ArgumentList $ArgumentList -Verb RunAs -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "Elevated setup.ps1 relaunch failed with exit code $($proc.ExitCode). Re-run setup.ps1 from an Administrator pwsh session to see the underlying error directly."
    }
}

<#
.SYNOPSIS
    Build the pwsh argument list used to relaunch setup.ps1 elevated.

.DESCRIPTION
    Re-emits every bound parameter. If -RunAsUser was not bound, it appends
    the pre-elevation identity from Get-ArmCurrentUserName, captured here in
    the un-elevated parent, so the elevated child registers the scheduled
    tasks for the day-to-day user rather than the admin account UAC uses.

.PARAMETER ScriptPath
    Path to setup.ps1 (normally $PSCommandPath).

.PARAMETER BoundParameters
    The caller's $PSBoundParameters.

.OUTPUTS
    [string[]] Arguments for Invoke-ArmElevatedRelaunch.
#>
function Get-ArmElevatedArgumentList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ScriptPath,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $BoundParameters
    )

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"")
    foreach ($key in $BoundParameters.Keys) {
        $value = $BoundParameters[$key]
        if ($value -is [switch]) {
            if ($value.IsPresent) { $argList += "-$key" }
        } else {
            $argList += "-$key"
            $argList += "`"$value`""
        }
    }
    if ($BoundParameters.Keys -notcontains 'RunAsUser') {
        $argList += '-RunAsUser'
        $argList += "`"$(Get-ArmCurrentUserName)`""
    }
    return $argList
}

# --- Thin entry point --------------------------------------------------------
# Guarded so the file can be dot-sourced by tests (functions only) without
# installing software, writing config, or registering scheduled tasks.
if ($MyInvocation.InvocationName -ne '.') {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        if (Test-NonInteractiveSession) {
            throw @'
Not running elevated, and this session appears non-interactive (SSH, WinRM/
PSRemoting, PsExec without -i, or a service/SYSTEM context): UAC cannot show
its consent prompt without an interactive desktop attached, so self-elevation
via "Run as Administrator" would hang or fail silently.

setup.ps1 registers Scheduled Tasks and installs software -- a one-time,
one-off action -- so it isn't worth loosening UAC just to run it non-interactively.
Run it instead from a local console or RDP session on this machine, in an
Administrator (Run as Administrator) pwsh window.
'@
        }
        Write-Host 'Registering scheduled tasks requires elevation; relaunching as Administrator...'
        # Passes the ORIGINAL (pre-elevation) identity via -RunAsUser so the
        # elevated child registers the tasks for the day-to-day user, not
        # whatever admin account UAC elevates to.
        $argList = Get-ArmElevatedArgumentList -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
        Invoke-ArmElevatedRelaunch -ArgumentList $argList
        return
    }

    $repoRoot = $PSScriptRoot
    $tasks = Get-ArmScheduledTaskList -RepoRoot $repoRoot
    $effectiveRunAsUser = if ($RunAsUser) { $RunAsUser } else { Get-ArmCurrentUserName }

    if ($Uninstall) {
        foreach ($task in $tasks) {
            Unregister-ArmScheduledTask -TaskName $task.TaskName
        }
        Write-Host 'wrm scheduled tasks removed.'
        return
    }

    Write-Host '== wrm setup =='

    Install-WingetPackage -Id 'GuinpinSoft.MakeMKV' -DisplayName 'MakeMKV'
    Install-WingetPackage -Id 'enzo1982.freac' -DisplayName 'fre:ac'
    Install-WingetPackage -Id 'Gyan.FFmpeg' -DisplayName 'FFmpeg'
    Show-Video2xManualStep

    $examplePath = Join-Path $repoRoot 'config' 'config.example.psd1'
    $example = Import-PowerShellDataFile -Path $examplePath
    Install-NcnnUpscaler -RequirementsPath (Join-Path $repoRoot 'tools' 'requirements-ncnn.txt') `
        -PythonPath $example.NcnnPath -ModelDir $example.NcnnModelDir -BundledModelDir (Join-Path $repoRoot 'tools' 'models')
    Initialize-ArmDirectories -Paths @{
        StagingDir      = $example.StagingDir
        UpscaleQueueDir = $example.UpscaleQueueDir
        LogDir          = $example.LogDir
        StateDir        = $example.StateDir
    }

    $configOutputPath = Join-Path $repoRoot 'config' 'config.psd1'
    if (Test-Path -Path $configOutputPath) {
        Write-Host 'config/config.psd1 already exists; leaving untouched (delete it to reconfigure).'
    } else {
        New-ArmConfigFile -ExamplePath $examplePath -OutputPath $configOutputPath `
            -NonInteractive:$NonInteractive -NasVideoPath $NasVideoPath -NasMusicPath $NasMusicPath `
            -TmdbApiKey $TmdbApiKey -HaWebhookUrl $HaWebhookUrl
    }

    foreach ($task in $tasks) {
        Register-ArmScheduledTask -TaskName $task.TaskName -ScriptPath $task.ScriptPath -RunAsUser $effectiveRunAsUser
    }

    $webUiPort = if ($example.ContainsKey('WebUiPort')) { $example.WebUiPort } else { 8765 }
    if (Test-Path -Path $configOutputPath) {
        $installed = Import-PowerShellDataFile -Path $configOutputPath
        if ($installed.ContainsKey('WebUiPort') -and $installed.WebUiPort) { $webUiPort = $installed.WebUiPort }
    }

    Write-Host ''
    Write-Host 'Setup complete.'
    Write-Host "Web UI (after next logon, or start the 'wrm-webui' task now): http://localhost:$webUiPort/"
}
