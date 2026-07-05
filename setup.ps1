[CmdletBinding()]
param(
    [switch] $NonInteractive,
    [switch] $Uninstall,
    [string] $NasVideoPath,
    [string] $NasMusicPath,
    [string] $TmdbApiKey,
    [string] $HaWebhookUrl
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
    Scheduled task name (e.g. 'wslc-arm-watcher').

.PARAMETER ScriptPath
    Full path to the pwsh entry-point script to run.
#>
function Register-ArmScheduledTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $TaskName,

        [Parameter(Mandatory = $true)]
        [string] $ScriptPath
    )

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Scheduled task '$TaskName' already registered; skipping."
        return
    }

    $action = New-ScheduledTaskAction -Execute 'pwsh.exe' `
        -Argument "-WindowStyle Hidden -File `"$ScriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
    $settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description "wslc-arm: $TaskName" -Force | Out-Null
    Write-Host "Registered scheduled task '$TaskName' -> $ScriptPath"
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

# --- Thin entry point --------------------------------------------------------
# Guarded so the file can be dot-sourced by tests (functions only) without
# installing software, writing config, or registering scheduled tasks.
if ($MyInvocation.InvocationName -ne '.') {
    $repoRoot = $PSScriptRoot
    $watcherPath = Join-Path $repoRoot 'src' 'DiscWatcher.ps1'
    $upscalerPath = Join-Path $repoRoot 'src' 'Upscale-Worker.ps1'

    if ($Uninstall) {
        Unregister-ArmScheduledTask -TaskName 'wslc-arm-watcher'
        Unregister-ArmScheduledTask -TaskName 'wslc-arm-upscaler'
        Write-Host 'wslc-arm scheduled tasks removed.'
        return
    }

    Write-Host '== wslc-arm setup =='

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

    Register-ArmScheduledTask -TaskName 'wslc-arm-watcher' -ScriptPath $watcherPath
    Register-ArmScheduledTask -TaskName 'wslc-arm-upscaler' -ScriptPath $upscalerPath

    Write-Host ''
    Write-Host 'Setup complete.'
}
