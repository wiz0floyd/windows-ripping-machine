Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Internal function to invoke robocopy. Can be mocked in tests.

.OUTPUTS
    [pscustomobject] with ExitCode [int] and Lines [string[]]
#>
function Invoke-Robocopy {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $SourceDir,
        [string] $DestDir
    )

    $lines = @()
    & robocopy $SourceDir $DestDir /E /Z /NP /R:3 /W:10 | ForEach-Object {
        if ($_) {
            $lines += $_
        }
    }
    $exitCode = $LASTEXITCODE

    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines    = $lines
    }
}

<#
.SYNOPSIS
    Move a directory tree to a NAS share using robocopy with verification.

.DESCRIPTION
    Uses robocopy to move files from SourceDir to a subdirectory of DestRoot.
    Creates a subdirectory under DestRoot with the same name as SourceDir.

    Robocopy is invoked with /E /Z /NP /R:3 /W:10 flags.
    Exit codes 0-7 are treated as success; >=8 as failure.

    After successful robocopy, verifies that every file exists at the destination
    with matching file size (Length). Source directory is deleted ONLY after
    verification passes. If verification fails, source is preserved.

    Never throws; errors are returned in the result object.

    Failures (robocopy failure or verification mismatch) are NOT automatically
    retried or re-queued; this is a deliberate design choice, not an oversight.
    The source directory is left in place, and the caller (DiscWatcher.ps1) is
    expected to log and notify so a human can investigate and manually re-trigger
    the move. Building a safe automatic retry/re-queue mechanism is nontrivial
    (duplicate partial copies, backoff, re-verification), so manual intervention
    is the accepted safer default.

.PARAMETER SourceDir
    Full path to the source directory to move.

.PARAMETER DestRoot
    Root path on the destination (e.g., '\\nas\media\import\movies').
    Destination directory will be DestRoot\<SourceDirName>.

.PARAMETER Config
    Configuration hashtable.

.OUTPUTS
    [pscustomobject] with properties:
    - Success [bool]: $true if move completed and verified successfully
    - DestDir [string]: Full path to the destination directory
    - Error [string]: Error message if Success=$false; $null otherwise

.EXAMPLE
    $result = Move-ToNas -SourceDir 'C:\rips\staging\MyMovie' `
                         -DestRoot '\\nas\media\import\movies' -Config $config
    if ($result.Success) {
        Write-Host "Moved to: $($result.DestDir)"
    }
#>
function Move-ToNas {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourceDir,

        [Parameter(Mandatory = $true)]
        [string] $DestRoot,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    try {
        # Validate source directory exists
        if (-not (Test-Path -Path $SourceDir -PathType Container)) {
            $errorMsg = "Source directory not found: $SourceDir"
            Write-ArmLog -Level ERROR -Message $errorMsg -Config $Config
            return New-ArmResult -Success $false -Properties ([ordered]@{ DestDir = $null }) -Error $errorMsg
        }

        # Resolve to the canonical long path so it matches Get-ChildItem's FullName
        # output later (short 8.3 paths like RUNNER~1 would otherwise break the
        # prefix Substring used for relative-path verification below).
        $SourceDir = (Get-Item -Path $SourceDir).FullName
        $sourceDirName = (Get-Item -Path $SourceDir).Name
        $destDir = Join-Path $DestRoot $sourceDirName

        Write-ArmLog -Level INFO -Message "Starting move: $SourceDir -> $destDir" -Config $Config

        # Create destination parent directory if needed
        $null = New-Item -ItemType Directory -Path $DestRoot -Force -ErrorAction SilentlyContinue

        # Run robocopy with specified flags
        Write-ArmLog -Level INFO -Message "Invoking robocopy with /E /Z /NP /R:3 /W:10" -Config $Config
        $robocopyResult = Invoke-Robocopy -SourceDir $SourceDir -DestDir $destDir
        $robocopyExitCode = $robocopyResult.ExitCode

        # Log robocopy output lines
        $robocopyResult.Lines | ForEach-Object {
            Write-ArmLog -Level INFO -Message "[robocopy] $_" -Config $Config
        }

        # Interpret robocopy exit code (0-7 = success, >=8 = failure)
        if ($robocopyExitCode -ge 8) {
            $errorMsg = "robocopy failed with exit code $robocopyExitCode"
            Write-ArmLog -Level ERROR -Message $errorMsg -Config $Config
            return New-ArmResult -Success $false -Properties ([ordered]@{ DestDir = $null }) -Error $errorMsg
        }

        Write-ArmLog -Level INFO -Message "robocopy completed with exit code $robocopyExitCode (success)" -Config $Config

        # Verify destination by comparing source and destination files
        Write-ArmLog -Level INFO -Message "Verifying file transfer..." -Config $Config

        $sourceFiles = @(Get-ChildItem -Path $SourceDir -Recurse -File -ErrorAction SilentlyContinue)
        $verificationFailed = $false

        foreach ($sourceFile in $sourceFiles) {
            $relativePath = $sourceFile.FullName.Substring($SourceDir.Length).TrimStart('\')
            $destFile = Join-Path $destDir $relativePath

            if (-not (Test-Path $destFile)) {
                Write-ArmLog -Level ERROR -Message "Verification failed: destination file missing: $relativePath" -Config $Config
                $verificationFailed = $true
                break
            }

            $destFileObj = Get-Item -Path $destFile -ErrorAction SilentlyContinue
            if ($sourceFile.Length -ne $destFileObj.Length) {
                Write-ArmLog -Level ERROR -Message "Verification failed: file size mismatch: $relativePath (source: $($sourceFile.Length), dest: $($destFileObj.Length))" -Config $Config
                $verificationFailed = $true
                break
            }
        }

        if ($verificationFailed) {
            $errorMsg = "Verification failed: source and destination mismatch"
            Write-ArmLog -Level ERROR -Message $errorMsg -Config $Config
            return New-ArmResult -Success $false -Properties ([ordered]@{ DestDir = $destDir }) -Error $errorMsg
        }

        Write-ArmLog -Level INFO -Message "Verification successful: all files match" -Config $Config

        # Delete source directory only after verification passes
        Write-ArmLog -Level INFO -Message "Deleting source directory: $SourceDir" -Config $Config
        Remove-Item -Path $SourceDir -Recurse -Force -ErrorAction Stop

        Write-ArmLog -Level INFO -Message "Move completed successfully: $destDir" -Config $Config

        return New-ArmResult -Success $true -Properties ([ordered]@{ DestDir = $destDir }) -Error $null

    } catch {
        $errorMsg = "Exception in Move-ToNas: $_"
        Write-ArmLog -Level ERROR -Message $errorMsg -Config $Config
        return New-ArmResult -Success $false -Properties ([ordered]@{ DestDir = $null }) -Error $errorMsg
    }
}
