Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Resolve-Title.ps1')

    $script:FixturesDir = Join-Path $PSScriptRoot 'fixtures'
    $script:TmdbMatchJson = Get-Content -Path (Join-Path $script:FixturesDir 'tmdb-search.json') -Raw | ConvertFrom-Json
    $script:TestDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wslc-arm-title-test-$(New-Guid)")
    $script:Config = @{ TmdbApiKey = 'test-key'; LogDir = Join-Path $script:TestDir 'logs' }
}

AfterAll {
    Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ArmCleanDiscLabel' {
    It 'replaces underscores and dots with spaces' {
        Get-ArmCleanDiscLabel -DiscLabel 'STAR_WARS.ANH' | Should -Be 'STAR WARS ANH'
    }

    It 'strips DISC/DISK/D + number tokens' {
        Get-ArmCleanDiscLabel -DiscLabel 'THE_MATRIX_DISC1' | Should -Be 'THE MATRIX'
        Get-ArmCleanDiscLabel -DiscLabel 'THE_MATRIX_DISK_2' | Should -Be 'THE MATRIX'
        Get-ArmCleanDiscLabel -DiscLabel 'THE_MATRIX_D1' | Should -Be 'THE MATRIX'
    }

    It 'strips SEASON N tokens' {
        Get-ArmCleanDiscLabel -DiscLabel 'THE_OFFICE_SEASON_3' | Should -Be 'THE OFFICE'
    }

    It 'strips edition/region/format noise tokens' {
        Get-ArmCleanDiscLabel -DiscLabel 'BLADE_RUNNER_SPECIAL_EDITION' | Should -Be 'BLADE RUNNER'
        Get-ArmCleanDiscLabel -DiscLabel 'BLADE_RUNNER_WS_16X9' | Should -Be 'BLADE RUNNER'
        Get-ArmCleanDiscLabel -DiscLabel 'BLADE_RUNNER_PAL_NTSC' | Should -Be 'BLADE RUNNER'
        Get-ArmCleanDiscLabel -DiscLabel 'BLADE_RUNNER_REMASTERED' | Should -Be 'BLADE RUNNER'
        Get-ArmCleanDiscLabel -DiscLabel "BLADE_RUNNER_DIRECTOR'S_CUT" | Should -Be 'BLADE RUNNER'
        Get-ArmCleanDiscLabel -DiscLabel 'BLADE_RUNNER_REGION1_RETAIL' | Should -Be 'BLADE RUNNER'
    }

    It 'collapses whitespace and trims' {
        Get-ArmCleanDiscLabel -DiscLabel '  THE___MATRIX  ' | Should -Be 'THE MATRIX'
    }
}

Describe 'ConvertTo-ArmTitleCase' {
    It 'title-cases a cleaned label' {
        ConvertTo-ArmTitleCase -Text 'THE MATRIX' | Should -Be 'The Matrix'
    }
}

Describe 'Test-ArmTmdbAcceptance' {
    It 'accepts a single result' {
        Test-ArmTmdbAcceptance -Results @(@{ popularity = 5.0 }) | Should -Be $true
    }
    It 'accepts when top popularity is at least 2x the runner-up' {
        Test-ArmTmdbAcceptance -Results @(@{ popularity = 82.5 }, @{ popularity = 1.2 }) | Should -Be $true
    }
    It 'rejects when top popularity is less than 2x the runner-up' {
        Test-ArmTmdbAcceptance -Results @(@{ popularity = 10.0 }, @{ popularity = 6.0 }) | Should -Be $false
    }
    It 'rejects an empty result set' {
        Test-ArmTmdbAcceptance -Results @() | Should -Be $false
    }
}

Describe 'Resolve-Title' {
    It 'falls back to label+date naming when no TMDb API key is configured' {
        $config = @{ TmdbApiKey = '' }
        $result = Resolve-Title -DiscLabel 'STAR_WARS_ANH' -Config $config

        $result.Matched | Should -Be $false
        $result.FolderName | Should -Match '^Star Wars Anh_\d{4}-\d{2}-\d{2}$'
    }

    It 'matches and returns "Title (Year)" when TMDb has one clear winner' {
        Mock Invoke-RestMethod { return $script:TmdbMatchJson }

        $result = Resolve-Title -DiscLabel 'STAR_WARS_ANH' -Config $script:Config

        $result.Matched | Should -Be $true
        $result.Title | Should -Be 'Star Wars'
        $result.Year | Should -Be 1977
        $result.FolderName | Should -Be 'Star Wars (1977)'
    }

    It 'falls back when TMDb results are ambiguous (no clear popularity winner)' {
        Mock Invoke-RestMethod {
            return [pscustomobject]@{
                results = @(
                    [pscustomobject]@{ title = 'Alpha'; release_date = '2001-01-01'; popularity = 10.0 },
                    [pscustomobject]@{ title = 'Alpha 2'; release_date = '2005-01-01'; popularity = 8.0 }
                )
            }
        }

        $result = Resolve-Title -DiscLabel 'ALPHA' -Config $script:Config

        $result.Matched | Should -Be $false
        $result.FolderName | Should -Match '^Alpha_\d{4}-\d{2}-\d{2}$'
    }

    It 'falls back when TMDb returns no results' {
        Mock Invoke-RestMethod {
            return [pscustomobject]@{ results = @() }
        }

        $result = Resolve-Title -DiscLabel 'UNKNOWN_MOVIE_XYZ' -Config $script:Config

        $result.Matched | Should -Be $false
        $result.FolderName | Should -Match '^Unknown Movie Xyz_\d{4}-\d{2}-\d{2}$'
    }

    It 'falls back when the TMDb HTTP call throws (offline/error)' {
        Mock Invoke-RestMethod { throw 'network unreachable' }

        $result = Resolve-Title -DiscLabel 'OFFLINE_TEST' -Config $script:Config

        $result.Matched | Should -Be $false
        $result.FolderName | Should -Match '^Offline Test_\d{4}-\d{2}-\d{2}$'
    }

    It 'strips invalid filename characters from the matched folder name' {
        Mock Invoke-RestMethod {
            return [pscustomobject]@{
                results = @(
                    [pscustomobject]@{ title = 'Se7en: Redux'; release_date = '1995-09-22'; popularity = 50.0 }
                )
            }
        }

        $result = Resolve-Title -DiscLabel 'SEVEN' -Config $script:Config
        $result.FolderName | Should -Not -Match '[\\/:*?"<>|]'
        $result.FolderName | Should -Be 'Se7en Redux (1995)'
    }

    It 'never throws' {
        Mock Invoke-RestMethod { throw 'boom' }
        { Resolve-Title -DiscLabel 'ANYTHING' -Config $script:Config } | Should -Not -Throw
    }
}
