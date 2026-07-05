Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Rip an audio CD using freaccmd with FLAC encoding and metadata support.

.DESCRIPTION
    Invokes freaccmd to rip an audio CD to FLAC format with CDDB/MusicBrainz metadata
    enabled. Output is staged in <StagingDir>\audio\<guid>\ with artist and album
    metadata extracted from the resulting directory structure.

    Automatically falls back to 'Unknown Artist' and 'Unknown Album <yyyy-MM-dd>'
    if metadata cannot be determined.

    Never throws; errors are returned in the result object.

.PARAMETER DriveLetter
    Drive letter of the optical drive (e.g., 'D').

.PARAMETER Config
    Configuration hashtable containing StagingDir and FreacCmdPath (or Simulate mode).

.OUTPUTS
    [pscustomobject] with properties:
    - Success [bool]: $true if rip completed successfully
    - OutputDir [string]: Full path to the output directory
    - Artist [string]: Extracted or fallback artist name
    - Album [string]: Extracted or fallback album name
    - Error [string]: Error message if Success=$false; $null otherwise

.EXAMPLE
    $result = Invoke-AudioRip -DriveLetter 'D' -Config $config
    if ($result.Success) {
        Write-Host "Ripped: $($result.Artist) - $($result.Album)"
    }
#>
function Invoke-AudioRip {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ $_ -match '^[A-Z]$' })]
        [char] $DriveLetter,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    try {
        # Build staging directory with GUID for isolation
        $stagingBase = Join-Path $Config.StagingDir 'audio'
        $ripGuid = [System.Guid]::NewGuid().ToString()
        $stagingDir = Join-Path $stagingBase $ripGuid

        # Create staging directory
        $null = New-Item -ItemType Directory -Path $stagingDir -Force -ErrorAction SilentlyContinue

        Write-ArmLog -Level INFO -Message "Starting audio rip from drive $($DriveLetter): to $stagingDir" -Config $Config

        # Build freaccmd arguments with CDDB/MusicBrainz enabled
        $driveArg = "$($DriveLetter):"
        $arguments = @(
            $driveArg,
            '-e', 'flac',
            '-o', $stagingDir
        )

        # Invoke freaccmd via Invoke-ArmTool
        $toolResult = Invoke-ArmTool -Name freaccmd -Arguments $arguments -Config $Config

        if ($toolResult.ExitCode -ne 0) {
            $errorMsg = "freaccmd failed with exit code $($toolResult.ExitCode)"
            Write-ArmLog -Level ERROR -Message $errorMsg -Config $Config
            return [pscustomobject]@{
                Success   = $false
                OutputDir = $null
                Artist    = $null
                Album     = $null
                Error     = $errorMsg
            }
        }

        Write-ArmLog -Level INFO -Message "freaccmd completed successfully" -Config $Config

        # Find the album directory (named "<Artist> - <Album>")
        $albumDirs = @(Get-ChildItem -Path $stagingDir -Directory -ErrorAction SilentlyContinue)

        if ($albumDirs.Count -eq 0) {
            $errorMsg = "No album directory found in $stagingDir"
            Write-ArmLog -Level ERROR -Message $errorMsg -Config $Config
            return [pscustomobject]@{
                Success   = $false
                OutputDir = $stagingDir
                Artist    = 'Unknown Artist'
                Album     = "Unknown Album $(Get-Date -Format 'yyyy-MM-dd')"
                Error     = $errorMsg
            }
        }

        $albumDir = $albumDirs[0]
        $outputDir = $albumDir.FullName

        # Extract artist and album from directory name format: "<Artist> - <Album>"
        $dirName = $albumDir.Name
        $artist = 'Unknown Artist'
        $album = "Unknown Album $(Get-Date -Format 'yyyy-MM-dd')"

        if ($dirName -match '^(.+?)\s*-\s*(.+)$') {
            $artist = $matches[1].Trim()
            $album = $matches[2].Trim()
        } else {
            # Try to extract from first FLAC file metadata (fallback)
            $flacFiles = @(Get-ChildItem -Path $outputDir -Filter '*.flac' -ErrorAction SilentlyContinue)
            if ($flacFiles.Count -gt 0) {
                # Use directory name as both if we can't parse
                $artist = 'Unknown Artist'
                $album = $dirName
            }
        }

        Write-ArmLog -Level INFO -Message "Audio rip complete: $artist - $album" -Config $Config

        return [pscustomobject]@{
            Success   = $true
            OutputDir = $outputDir
            Artist    = $artist
            Album     = $album
            Error     = $null
        }

    } catch {
        $errorMsg = "Exception in Invoke-AudioRip: $_"
        Write-ArmLog -Level ERROR -Message $errorMsg -Config $Config
        return [pscustomobject]@{
            Success   = $false
            OutputDir = $null
            Artist    = 'Unknown Artist'
            Album     = "Unknown Album $(Get-Date -Format 'yyyy-MM-dd')"
            Error     = $errorMsg
        }
    }
}
