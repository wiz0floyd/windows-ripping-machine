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

<#
.SYNOPSIS
    Create the staging/queue/log directories used by the pipeline, if missing.

.PARAMETER Paths
    Hashtable with keys StagingDir, UpscaleQueueDir, LogDir.
#>
function Initialize-ArmDirectories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Paths
    )

    foreach ($key in @('StagingDir', 'UpscaleQueueDir', 'LogDir')) {
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
    Register a hidden, at-logon scheduled task running an entry-point script for
    the current user (idempotent: skips if the task already exists).

.PARAMETER TaskName
    Scheduled task name (e.g. 'wrm-watcher').

.PARAMETER ScriptPath
    Full path to the pwsh entry-point script to run.

.PARAMETER RunAsUser
    The "DOMAIN\User" the task's principal should run as. Defaults to the
    current process's user, which is only correct when this function runs
    un-elevated or in a session that was never relaunched for elevation. When
    setup.ps1 relaunches itself elevated (Start-Process -Verb RunAs), the
    elevated child's $env:USERNAME may be a different (admin) account than the
    user who invoked setup.ps1, so the entry point captures the original
    identity before relaunching and passes it through explicitly here.
#>
function Register-ArmScheduledTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $TaskName,

        [Parameter(Mandatory = $true)]
        [string] $ScriptPath,

        [string] $RunAsUser = "$env:USERDOMAIN\$env:USERNAME"
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
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        foreach ($key in $PSBoundParameters.Keys) {
            $value = $PSBoundParameters[$key]
            if ($value -is [switch]) {
                if ($value.IsPresent) { $argList += "-$key" }
            } else {
                $argList += "-$key"
                $argList += "`"$value`""
            }
        }
        if ($PSBoundParameters.Keys -notcontains 'RunAsUser') {
            # Capture the ORIGINAL (pre-elevation) identity so the elevated
            # child registers the scheduled task for the actual day-to-day
            # user, not whatever admin account UAC elevates to.
            $argList += '-RunAsUser'
            $argList += "`"$env:USERDOMAIN\$env:USERNAME`""
        }
        Invoke-ArmElevatedRelaunch -ArgumentList $argList
        return
    }

    $repoRoot = $PSScriptRoot
    $watcherPath = Join-Path $repoRoot 'src' 'DiscWatcher.ps1'
    $upscalerPath = Join-Path $repoRoot 'src' 'Upscale-Worker.ps1'
    $effectiveRunAsUser = if ($RunAsUser) { $RunAsUser } else { "$env:USERDOMAIN\$env:USERNAME" }

    if ($Uninstall) {
        Unregister-ArmScheduledTask -TaskName 'wrm-watcher'
        Unregister-ArmScheduledTask -TaskName 'wrm-upscaler'
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
    Initialize-ArmDirectories -Paths @{
        StagingDir      = $example.StagingDir
        UpscaleQueueDir = $example.UpscaleQueueDir
        LogDir          = $example.LogDir
    }

    $configOutputPath = Join-Path $repoRoot 'config' 'config.psd1'
    if (Test-Path -Path $configOutputPath) {
        Write-Host 'config/config.psd1 already exists; leaving untouched (delete it to reconfigure).'
    } else {
        New-ArmConfigFile -ExamplePath $examplePath -OutputPath $configOutputPath `
            -NonInteractive:$NonInteractive -NasVideoPath $NasVideoPath -NasMusicPath $NasMusicPath `
            -TmdbApiKey $TmdbApiKey -HaWebhookUrl $HaWebhookUrl
    }

    Register-ArmScheduledTask -TaskName 'wrm-watcher' -ScriptPath $watcherPath -RunAsUser $effectiveRunAsUser
    Register-ArmScheduledTask -TaskName 'wrm-upscaler' -ScriptPath $upscalerPath -RunAsUser $effectiveRunAsUser

    Write-Host ''
    Write-Host 'Setup complete.'
}
