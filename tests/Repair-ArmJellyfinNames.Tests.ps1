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

    It 'honours -Since/-Until on the folder creation time' {
        $old = New-MovieDir 'Old (1990)' @{ 'A1_t00.mkv' = 'raw' }
        $new = New-MovieDir 'New (2020)' @{ 'A1_t00.mkv' = 'raw' }
        (Get-Item -LiteralPath $old).CreationTime = [datetime] '2026-01-01'
        (Get-Item -LiteralPath $new).CreationTime = [datetime] '2026-10-01'
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -Since ([datetime] '2026-09-27'))
        @($rows.Folder | Sort-Object -Unique) | Should -Be @('New (2020)')
        Get-Names $old | Should -Be @('A1_t00.mkv')
        $rows2 = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -Until ([datetime] '2026-09-27'))
        @($rows2.Folder | Sort-Object -Unique) | Should -Be @('Old (1990)')
    }

    It 'removes sidecars of old names with -RemoveOrphans and keeps the rest (previewed with -WhatIf)' {
        $dir = New-MovieDir 'Grease (1978)' @{
            'B1_t00.mkv' = 'raw'; 'B1_t00 [AI upscale 1080p].mkv' = 'up'; 'C1_t01.mkv' = 'x'
            'B1_t00.nfo' = 'n'; 'B1_t00-poster.jpg' = 'p'; 'B1_t00.trickplay/320/0.jpg' = 't'
            'C1_t01.nfo' = 'n'; 'poster.jpg' = 'keep'; 'movie.nfo' = 'keep'; 'metadata.json' = '{}'
            'Grease (1978) - 480p.nfo' = 'keep'; 'Grease (1978) - 1080p-poster.jpg' = 'keep'
        }
        $preview = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -RemoveOrphans -WhatIf)
        @($preview | Where-Object Action -eq 'WouldRemove').File | Sort-Object |
            Should -Be @('B1_t00-poster.jpg', 'B1_t00.nfo', 'B1_t00.trickplay', 'C1_t01.nfo')
        Test-Path -LiteralPath (Join-Path $dir 'B1_t00.nfo') | Should -BeTrue

        $null = Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -RemoveOrphans
        Get-Names $dir | Should -Be @('Grease (1978) - 1080p-poster.jpg', 'Grease (1978) - 1080p.mkv', 'Grease (1978) - 480p.mkv', 'Grease (1978) - 480p.nfo', 'metadata.json', 'movie.nfo', 'poster.jpg')
        Test-Path -LiteralPath (Join-Path $dir 'B1_t00.trickplay') | Should -BeFalse
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

    It 'treats the largest of several raw mkvs as the main feature and moves the rest to extras/' {
        $dir = New-MovieDir 'Grease (1978)' @{ 'B1_t00.mkv' = ('a' * 50); 'B1_t01.mkv' = ('b' * 500); 'B1_t02.mkv' = ('c' * 5) }
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config)
        Get-Names $dir | Should -Be @('Grease (1978).mkv')
        (Get-Content -LiteralPath (Join-Path $dir 'Grease (1978).mkv') -Raw).Trim() | Should -Be ('b' * 500)
        Get-Names (Join-Path $dir 'extras') | Should -Be @('B1_t00.mkv', 'B1_t02.mkv')
        @($rows | Where-Object Action -eq 'Moved').Count | Should -Be 2
        @($rows | Where-Object Action -eq 'Renamed').Count | Should -Be 1
    }

    It '-WhatIf reports WouldMove and WouldRename for several raw mkvs and changes nothing' {
        $dir = New-MovieDir 'Grease (1978)' @{ 'B1_t00.mkv' = ('a' * 50); 'B1_t01.mkv' = ('b' * 500) }
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -WhatIf)
        Get-Names $dir | Should -Be @('B1_t00.mkv', 'B1_t01.mkv')
        Test-Path -LiteralPath (Join-Path $dir 'extras') | Should -BeFalse
        @($rows | Where-Object Action -eq 'WouldMove').Count | Should -Be 1
        @($rows | Where-Object Action -eq 'WouldRename').Count | Should -Be 1
    }

    It 'does not treat Upgrade.mkv as already named for the movie Up' {
        $dir = New-MovieDir 'Up' @{ 'Upgrade.mkv' = 'x' }
        $null = Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config
        Get-Names $dir | Should -Be @('Up.mkv')
    }

    It 'accepts "Up - 480p.mkv", "Up [x].mkv", "Up_x.mkv" and "Up (2009).mkv"-style names only per the Jellyfin rule' {
        $dir = New-MovieDir 'Up' @{ 'Up - 480p.mkv' = 'x' }
        @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config).Count | Should -Be 0
        Test-ArmJellyfinVersionName -BaseName 'Up [x]' -Folder 'Up' | Should -BeTrue
        Test-ArmJellyfinVersionName -BaseName 'Up_x' -Folder 'Up' | Should -BeTrue
        Test-ArmJellyfinVersionName -BaseName 'up' -Folder 'Up' | Should -BeTrue
        Test-ArmJellyfinVersionName -BaseName 'Up (2009)' -Folder 'Up' | Should -BeFalse
        Test-ArmJellyfinVersionName -BaseName 'Upgrade' -Folder 'Up' | Should -BeFalse
    }

    It 'skips when the target name already exists' {
        $dir = New-MovieDir 'Grease (1978)' @{ 'B1_t00.mkv' = 'raw'; 'Grease (1978) - 1080p.mkv' = 'old'; 'B1_t00 [AI upscale 1080p].mkv' = 'up' }
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config)
        Get-Names $dir | Should -Be @('B1_t00 [AI upscale 1080p].mkv', 'B1_t00.mkv', 'Grease (1978) - 1080p.mkv')
        $rows.Count | Should -Be 1
        $rows[0].Action | Should -Be 'Skipped'
        $rows[0].Reason | Should -Match 'already exists'
    }

    It 'uses the largest raw as the upscale source when no raw shares its base name, and moves other raws to extras/' {
        $dir = New-MovieDir 'Grease (1978)' @{ 'a.mkv' = ('1' * 20); 'b.mkv' = ('2' * 200); 'zzz [AI upscale 1080p].mkv' = 'up' }
        $null = Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config
        Get-Names $dir | Should -Be @('Grease (1978) - 1080p.mkv', 'Grease (1978) - 480p.mkv')
        (Get-Content -LiteralPath (Join-Path $dir 'Grease (1978) - 480p.mkv') -Raw).Trim() | Should -Be ('2' * 200)
        Get-Names (Join-Path $dir 'extras') | Should -Be @('a.mkv')
    }

    It 'skips when several upscale files exist' {
        $dir = New-MovieDir 'Grease (1978)' @{ 'a.mkv' = '1'; 'a [AI upscale 1080p].mkv' = 'x'; 'b [AI upscale 1080p].mkv' = 'y' }
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config)
        $rows[0].Action | Should -Be 'Skipped'
        Get-Names $dir | Should -Be @('a [AI upscale 1080p].mkv', 'a.mkv', 'b [AI upscale 1080p].mkv')
    }

    It 'skips the whole folder when any raw is a queued source (.failed too) and moves nothing to extras' {
        $q = Join-Path $TestDrive "queue-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $q
        $script:Config.UpscaleQueueDir = $q
        $dir = New-MovieDir 'Grease (1978)' @{ 'B1_t00.mkv' = ('a' * 500); 'B1_t01.mkv' = ('b' * 5) }
        ([ordered]@{ Source = (Join-Path $dir 'B1_t00.mkv') } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $q 'Grease (1978).failed')
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config)
        Get-Names $dir | Should -Be @('B1_t00.mkv', 'B1_t01.mkv')
        $rows[0].Reason | Should -Be 'queued for upscale (worker renames it on completion)'
    }
    It 'skips raw files that a pending queue entry (.json or .awaiting-review) points at, ignoring junk queue files' {
        $q = Join-Path $TestDrive "queue-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $q
        $script:Config.UpscaleQueueDir = $q
        $a = New-MovieDir 'Grease (1978)' @{ 'B1_t00.mkv' = 'raw' }
        $b = New-MovieDir 'Alien (1979)' @{ 'B1_t00.mkv' = 'raw'; 'B1_t00 [AI upscale 1080p].mkv' = 'up' }
        $c = New-MovieDir 'Heat (1995)' @{ 'B1_t00.mkv' = 'raw' }
        ([ordered]@{ Source = (Join-Path $a 'b1_t00.mkv') } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $q 'Grease (1978).json')
        ([ordered]@{ Source = (Join-Path $b 'B1_t00.mkv') } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $q 'Alien (1979).awaiting-review')
        Set-Content -LiteralPath (Join-Path $q 'junk.json') -Value 'not json'

        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config)

        Get-Names $a | Should -Be @('B1_t00.mkv')
        Get-Names $b | Should -Be @('B1_t00 [AI upscale 1080p].mkv', 'B1_t00.mkv')
        Get-Names $c | Should -Be @('Heat (1995).mkv')
        @($rows | Where-Object { $_.Action -eq 'Skipped' -and $_.Reason -eq 'queued for upscale (worker renames it on completion)' }).Count | Should -Be 2
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

Describe 'Repair-ArmJellyfinNames -RenameFolders' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive (New-Guid)
        $null = New-Item -ItemType Directory -Path $script:Root
        $script:Queue = Join-Path $TestDrive "queue-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $script:Queue
        $script:Config = @{
            Simulate        = $true
            LogDir          = Join-Path $TestDrive "logs-$(New-Guid)"
            StateDir        = Join-Path $TestDrive "state-$(New-Guid)"
            UpscaleQueueDir = $script:Queue
        }
        Mock Get-VideoSourceInfo { [pscustomobject]@{ Success = $true; Height = 480 } }
        $script:Nfo = '<movie><title>Grease</title><year>1978</year></movie>'
    }

    It 'renames the folder, the files and sidecars carrying the old name, and keeps movie.nfo' {
        $dir = New-MovieDir 'b1' @{
            'b1.mkv' = 'raw'; 'b1.nfo' = $script:Nfo; 'b1-poster.jpg' = 'p'; 'b1.trickplay/320/0.jpg' = 't'
            'movie.nfo' = 'keep'; 'extras/e.mkv' = 'x'
        }
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -RenameFolders)
        $rows[0].Action | Should -Be 'FolderRenamed'
        $rows[0].Folder | Should -Be 'b1'
        $rows[0].NewName | Should -Be 'Grease (1978)'
        Test-Path -LiteralPath $dir | Should -BeFalse
        $new = Join-Path $script:Root 'Grease (1978)'
        Get-Names $new | Should -Be @('Grease (1978)-poster.jpg', 'Grease (1978).mkv', 'Grease (1978).nfo', 'movie.nfo')
        Test-Path -LiteralPath (Join-Path $new 'Grease (1978).trickplay/320/0.jpg') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $new 'extras/e.mkv') | Should -BeTrue
    }

    It 'changes nothing with -WhatIf and reports WouldRenameFolder' {
        $dir = New-MovieDir 'b1' @{ 'b1.mkv' = 'raw'; 'b1.nfo' = $script:Nfo }
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -RenameFolders -WhatIf)
        @($rows | Where-Object Action -eq 'WouldRenameFolder').Count | Should -Be 1
        Get-Names $dir | Should -Be @('b1.mkv', 'b1.nfo')
    }

    It 'is idempotent' {
        $null = New-MovieDir 'b1' @{ 'b1.mkv' = 'raw'; 'b1.nfo' = $script:Nfo }
        $null = Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -RenameFolders
        @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -RenameFolders).Count | Should -Be 0
    }

    It 'leaves folders without an NFO alone' {
        $dir = New-MovieDir 'b1' @{ 'b1.mkv' = 'raw' }
        @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -RenameFolders -WhatIf).Count | Should -Be 0
        Test-Path -LiteralPath $dir | Should -BeTrue
    }

    It 'skips an NFO without a year' {
        $dir = New-MovieDir 'b1' @{ 'b1.mkv' = 'raw'; 'b1.nfo' = '<movie><title>Grease</title></movie>' }
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -RenameFolders)
        $rows[0].Action | Should -Be 'Skipped'
        $rows[0].Reason | Should -Be 'NFO has no year'
        Test-Path -LiteralPath $dir | Should -BeTrue
    }

    It 'skips when the target folder already exists' {
        $null = New-MovieDir 'b1' @{ 'b1.mkv' = 'raw'; 'b1.nfo' = $script:Nfo }
        $null = New-MovieDir 'Grease (1978)' @{ 'Grease (1978).mkv' = 'other' }
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -RenameFolders)
        ($rows | Where-Object Folder -eq 'b1').Reason | Should -Be 'target folder already exists'
        Test-Path -LiteralPath (Join-Path $script:Root 'b1') | Should -BeTrue
    }

    It 'skips when a planned file name already exists' {
        $dir = New-MovieDir 'b1' @{ 'b1.mkv' = 'raw-raw-raw-raw'; 'b1.nfo' = $script:Nfo; 'b1 - 480p.mkv' = 'v'; 'Grease (1978) - 480p.mkv' = 'sq' }
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -RenameFolders)
        ($rows | Where-Object Folder -eq 'b1' | Select-Object -First 1).Reason | Should -BeLike 'target name already exists*'
        Test-Path -LiteralPath $dir | Should -BeTrue
    }

    It 'aborts the whole run while a queue entry is pending, and -Force skips only the folder it points into' {
        $a = New-MovieDir 'b1' @{ 'b1.mkv' = 'raw'; 'b1.nfo' = $script:Nfo }
        $b = New-MovieDir 'b2' @{ 'b2.mkv' = 'raw'; 'b2.nfo' = '<movie><title>Alien</title><year>1979</year></movie>' }
        ([ordered]@{ Source = (Join-Path $a 'b1.mkv'); DestDir = $a } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $script:Queue 'q.json')

        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -RenameFolders)
        $rows.Count | Should -Be 1
        $rows[0].Action | Should -Be 'Skipped'
        $rows[0].Reason | Should -BeLike 'folder rename aborted*'
        Test-Path -LiteralPath $a | Should -BeTrue
        Test-Path -LiteralPath $b | Should -BeTrue

        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -RenameFolders -Force)
        ($rows | Where-Object Folder -eq 'b1').Reason | Should -BeLike 'queued for upscale*'
        Test-Path -LiteralPath $a | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Root 'Alien (1979)') | Should -BeTrue
    }

    It 'aborts while an upscale job is running' {
        $dir = New-MovieDir 'b1' @{ 'b1.mkv' = 'raw'; 'b1.nfo' = $script:Nfo }
        $null = New-ArmJob -Kind Upscale -Properties @{ State = 'Upscaling'; Title = 'x' } -Config $script:Config
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -RenameFolders)
        $rows[0].Reason | Should -BeLike '*1 upscale job(s) running*'
        Test-Path -LiteralPath $dir | Should -BeTrue
    }

    It 'rolls back renamed files when a later rename fails' {
        # 'b1.zz' sorts after the other items, so the earlier renames succeed before this one fails.
        $dir = New-MovieDir 'b1' @{ 'b1.mkv' = 'raw'; 'b1.nfo' = $script:Nfo; 'b1.zz' = 'locked' }
        $lock = [System.IO.File]::Open((Join-Path $dir 'b1.zz'), 'Open', 'Read', 'None')
        try {
            $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -RenameFolders)
        } finally {
            $lock.Dispose()
        }
        $rows[0].Action | Should -Be 'Skipped'
        $rows[0].Reason | Should -BeLike 'folder rename failed, rolled back*'
        Get-Names $dir | Should -Be @('b1.mkv', 'b1.nfo', 'b1.zz')
    }

    It 'fixes a case-only difference' {
        $null = New-MovieDir 'grease (1978)' @{ 'grease (1978).mkv' = 'raw'; 'grease (1978).nfo' = $script:Nfo }
        $rows = @(Repair-ArmJellyfinNames -Path $script:Root -Config $script:Config -RenameFolders)
        $rows[0].Action | Should -Be 'FolderRenamed'
        @(Get-ChildItem -LiteralPath $script:Root -Directory).Name | Should -BeExactly @('Grease (1978)')
        Get-Names (Join-Path $script:Root 'Grease (1978)') | Should -BeExactly @('Grease (1978).mkv', 'Grease (1978).nfo')
    }
}
