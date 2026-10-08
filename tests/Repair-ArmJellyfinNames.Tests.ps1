Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'tools' 'Repair-ArmJellyfinNames.ps1')

    function New-MovieDir {
        param([string] $Name, [hashtable] $Files)
        $dir = Join-Path $script:Root $Name
        $null = New-Item -ItemType Directory -Path $dir -Force
        foreach ($f in $Files.Keys) {
            $p = Join-Path $dir $f
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force
            Set-Content -LiteralPath $p -Value $Files[$f]
        }
        return $dir
    }
    function Get-Names([string] $Dir) {
        @(Get-ChildItem -LiteralPath $Dir -File).Name | Sort-Object
    }
}

Describe 'Repair-ArmJellyfinNames' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive (New-Guid)
        $null = New-Item -ItemType Directory -Path $script:Root
        $script:Config = @{ Simulate = $true; LogDir = Join-Path $script:Root '_logs' }
        # Leave the movies root clean of the log dir.
        $script:Config.LogDir = Join-Path $TestDrive "logs-$(New-Guid)"
        Mock Get-VideoSourceInfo { [pscustomobject]@{ Success = $true; Height = 480 } }
    }

    It 'renames a single mismatched raw mkv to the folder name' {
        $dir = New-MovieDir 'Grease (1978)' @{ 'B1_t00.mkv' = 'raw'; 'metadata.json' = '{}' }
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config)
        Get-Names $dir | Should -Be @('Grease (1978).mkv', 'metadata.json')
        @($rows).Count | Should -Be 1
        $rows[0].Action | Should -Be 'Renamed'
        $rows[0].NewName | Should -Be 'Grease (1978).mkv'
    }

    It 'leaves a correctly named movie and its extras/ alone' {
        $dir = New-MovieDir 'Alien (1979)' @{ 'Alien (1979).mkv' = 'raw'; 'extras/B1_t01.mkv' = 'x' }
        @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config).Count | Should -Be 0
        Get-Names $dir | Should -Be @('Alien (1979).mkv')
        Test-Path -LiteralPath (Join-Path $dir 'extras' 'B1_t01.mkv') | Should -BeTrue
    }

    It 'renames the upscale to "- 1080p" and the raw source to "- Label" for height <Height>' -ForEach @(
        @{ Height = 480; Label = '480p' }
        @{ Height = 576; Label = '576p' }
        @{ Height = $null; Label = 'DVD' }
    ) {
        Mock Get-VideoSourceInfo { [pscustomobject]@{ Success = ($null -ne $Height); Height = $Height } }.GetNewClosure()
        $dir = New-MovieDir 'Grease (1978)' @{ 'B1_t00.mkv' = 'raw'; 'B1_t00 [AI upscale 1080p].mkv' = 'up' }
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config)
        Get-Names $dir | Should -Be @(@('Grease (1978) - 1080p.mkv', "Grease (1978) - $Label.mkv") | Sort-Object)
        (Get-Content -LiteralPath (Join-Path $dir 'Grease (1978) - 1080p.mkv') -Raw).Trim() | Should -Be 'up'
        (Get-Content -LiteralPath (Join-Path $dir "Grease (1978) - $Label.mkv") -Raw).Trim() | Should -Be 'raw'
        @($rows | Where-Object Action -eq 'Renamed').Count | Should -Be 2
    }

    It 'is idempotent: a second run changes nothing' {
        $dir = New-MovieDir 'Grease (1978)' @{ 'B1_t00.mkv' = 'raw'; 'B1_t00 [AI upscale 1080p].mkv' = 'up' }
        $null = Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config
        $before = Get-Names $dir
        @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config).Count | Should -Be 0
        Get-Names $dir | Should -Be $before
    }

    It 'skips and lists ambiguous folders: several raw mkvs' {
        $dir = New-MovieDir 'Grease (1978)' @{ 'B1_t00.mkv' = 'a'; 'B1_t01.mkv' = 'b' }
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config)
        Get-Names $dir | Should -Be @('B1_t00.mkv', 'B1_t01.mkv')
        $rows.Count | Should -Be 1
        $rows[0].Action | Should -Be 'Skipped'
        $rows[0].Reason | Should -Match 'ambiguous'
    }

    It 'skips when the target name already exists' {
        $dir = New-MovieDir 'Grease (1978)' @{ 'B1_t00.mkv' = 'raw'; 'Grease (1978) - 1080p.mkv' = 'old'; 'B1_t00 [AI upscale 1080p].mkv' = 'up' }
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config)
        Get-Names $dir | Should -Be @('B1_t00 [AI upscale 1080p].mkv', 'B1_t00.mkv', 'Grease (1978) - 1080p.mkv')
        $rows.Count | Should -Be 1
        $rows[0].Action | Should -Be 'Skipped'
        $rows[0].Reason | Should -Match 'already exists'
    }

    It 'skips an upscale whose source cannot be identified' {
        $dir = New-MovieDir 'Grease (1978)' @{ 'a.mkv' = '1'; 'b.mkv' = '2'; 'zzz [AI upscale 1080p].mkv' = 'up' }
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config)
        Get-Names $dir | Should -Be @('a.mkv', 'b.mkv', 'zzz [AI upscale 1080p].mkv')
        $rows[0].Action | Should -Be 'Skipped'
    }

    It '-WhatIf makes no changes but reports what it would rename' {
        $a = New-MovieDir 'Grease (1978)' @{ 'B1_t00.mkv' = 'raw'; 'B1_t00 [AI upscale 1080p].mkv' = 'up' }
        $b = New-MovieDir 'Alien (1979)' @{ 'B1_t00.mkv' = 'raw' }
        $beforeA = Get-Names $a
        $beforeB = Get-Names $b

        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -WhatIf)

        Get-Names $a | Should -Be $beforeA
        Get-Names $b | Should -Be $beforeB
        @($rows | Where-Object Action -eq 'WouldRename').Count | Should -Be 3
        @($rows | Where-Object Action -eq 'Renamed').Count | Should -Be 0
    }
}
