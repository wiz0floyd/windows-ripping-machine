Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'wrm.ps1')

    function New-Movie {
        param([string] $Name, [hashtable] $Files)
        $dir = Join-Path $script:Root $Name
        $null = New-Item -ItemType Directory -Path $dir -Force
        foreach ($f in $Files.Keys) { Set-Content -LiteralPath (Join-Path $dir $f) -Value $Files[$f] }
        return $dir
    }
}

Describe 'Add-ArmUpscaleQueueFromLibrary' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive (New-Guid)
        $null = New-Item -ItemType Directory -Path $script:Root
        $script:Config = @{
            Simulate = $true; UpscaleQueueDir = Join-Path $TestDrive "q-$(New-Guid)"
            LogDir = Join-Path $TestDrive "logs-$(New-Guid)"; StateDir = Join-Path $TestDrive "state-$(New-Guid)"
        }
        $script:Height = 480
        Mock Get-VideoSourceInfo { [pscustomobject]@{ Success = $true; Height = $script:Height } }
    }

    It 'queues the largest mkv of a DVD-resolution movie, taking ContentType from metadata.json' {
        $dir = New-Movie 'Up (2009)' @{ 'a.mkv' = ('x' * 100); 'b.mkv' = 'x'; 'metadata.json' = '{"ContentType":"Animation"}' }
        $rows = @(Add-ArmUpscaleQueueFromLibrary -MovieDir $dir -Config $script:Config)
        $rows[0].Action | Should -Be 'Queued'
        $q = Get-Content -LiteralPath (Join-Path $script:Config.UpscaleQueueDir 'Up (2009).json') -Raw | ConvertFrom-Json
        $q.Source | Should -Be (Join-Path $dir 'a.mkv')
        $q.DestDir | Should -Be $dir
        $q.ContentType | Should -Be 'Animation'
    }

    It 'writes a plain filesystem DestDir when given a provider-qualified folder path' {
        $dir = New-Movie 'Up (2009)' @{ 'a.mkv' = 'x' }
        $null = Add-ArmUpscaleQueueFromLibrary -MovieDir "Microsoft.PowerShell.Core\FileSystem::$dir" -Config $script:Config
        $q = Get-Content -LiteralPath (Join-Path $script:Config.UpscaleQueueDir 'Up (2009).json') -Raw | ConvertFrom-Json
        $q.DestDir | Should -Be $dir
        $q.Source | Should -Be (Join-Path $dir 'a.mkv')
    }

    It 'queues nothing with -WhatIf' {
        $dir = New-Movie 'Up (2009)' @{ 'a.mkv' = 'x' }
        @(Add-ArmUpscaleQueueFromLibrary -MovieDir $dir -Config $script:Config -WhatIf)[0].Action | Should -Be 'WouldQueue'
        Test-Path -LiteralPath $script:Config.UpscaleQueueDir | Should -BeFalse
    }

    It 'skips a movie that already has an upscale, is already queued, or is HD' {
        $a = New-Movie 'A (2000)' @{ 'A (2000) - 480p.mkv' = 'x'; 'A (2000) - 1080p.mkv' = 'y' }
        $b = New-Movie 'B (2000)' @{ 'b.mkv' = 'x' }
        $null = New-Item -ItemType Directory -Path $script:Config.UpscaleQueueDir -Force
        Set-Content -LiteralPath (Join-Path $script:Config.UpscaleQueueDir 'B (2000).awaiting-review') -Value '{}'
        $c = New-Movie 'C (2000)' @{ 'c.mkv' = 'x' }
        $script:Height = 1080
        $rows = @(Add-ArmUpscaleQueueFromLibrary -MovieDir @($a, $b, $c) -Config $script:Config)
        $rows.Action | Should -Be @('Skipped', 'Skipped', 'Skipped')
        $rows[0].Reason | Should -Match 'already has an upscale'
        $rows[1].Reason | Should -Match 'queue'
        $rows[2].Reason | Should -Match 'DVD resolution'
    }
}

Describe 'Start-ArmManualRip' {
    BeforeEach {
        $script:Config = @{ Simulate = $false; LogDir = Join-Path $TestDrive "logs-$(New-Guid)" }
        $script:Detected = 'Data'
        $script:Dispatch = $true
        Mock Get-OpticalDriveLetters { [char[]]@('E', 'F') }
        Mock Get-DiscType { $script:Detected }
        Mock Get-ArmDriveMediaLoaded { [bool] ($DriveLetter -eq 'F') }
        Mock Invoke-DiscMutexDispatch { $script:Dispatch }
    }

    It 'rips the first drive with media, treating an unrecognised (Data) disc as Video' {
        $r = Start-ArmManualRip -Config $script:Config
        $r.DriveLetter | Should -Be 'F'
        $r.DiscType | Should -Be 'Video'
        Should -Invoke Invoke-DiscMutexDispatch -Times 1 -ParameterFilter { $DriveLetter -eq 'F' -and $DiscType -eq 'Video' }
    }

    It 'keeps a detected AudioCD type and accepts "F:" for -Drive' {
        $script:Detected = 'AudioCD'
        (Start-ArmManualRip -Config $script:Config -Drive 'f:').DiscType | Should -Be 'AudioCD'
    }

    It 'honours -DiscType over detection' {
        $script:Detected = 'Video'
        (Start-ArmManualRip -Config $script:Config -Drive F -DiscType AudioCD).DiscType | Should -Be 'AudioCD'
    }

    It 'throws when no drive has a disc, the drive is not optical, or a rip is in progress' {
        Mock Get-ArmDriveMediaLoaded { $false }
        { Start-ArmManualRip -Config $script:Config } | Should -Throw '*No optical drive with a disc*'
        { Start-ArmManualRip -Config $script:Config -Drive C } | Should -Throw '*not an optical drive*'
        { Start-ArmManualRip -Config $script:Config -Drive E } | Should -Throw '*No disc loaded*'
        Mock Get-ArmDriveMediaLoaded { $true }
        $script:Dispatch = $false
        { Start-ArmManualRip -Config $script:Config -Drive F } | Should -Throw '*already in progress*'
    }

    It 'uses the simulated disc under Simulate' {
        $script:Config.Simulate = $true
        Mock Resolve-CurrentDisc { [pscustomobject]@{ DriveLetter = [char] 'D'; DiscType = 'Video' } }
        (Start-ArmManualRip -Config $script:Config).DriveLetter | Should -Be 'D'
    }
}
