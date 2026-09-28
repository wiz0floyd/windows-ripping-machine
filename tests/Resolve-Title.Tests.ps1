Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Resolve-Title.ps1')

    $script:FixturesDir = Join-Path $PSScriptRoot 'fixtures'
    $script:TmdbMatchJson = Get-Content -Path (Join-Path $script:FixturesDir 'tmdb-search.json') -Raw | ConvertFrom-Json
    $script:TestDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wrm-title-test-$(New-Guid)")
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

    It 'strips audio codec noise tokens' {
        Get-ArmCleanDiscLabel -DiscLabel 'CASTAWAY_DTS' | Should -Be 'CASTAWAY'
        Get-ArmCleanDiscLabel -DiscLabel 'BLADE_RUNNER_DTS-HD_MA' | Should -Be 'BLADE RUNNER'
        Get-ArmCleanDiscLabel -DiscLabel 'BLADE_RUNNER_DOLBY_ATMOS' | Should -Be 'BLADE RUNNER'
        Get-ArmCleanDiscLabel -DiscLabel 'BLADE_RUNNER_TRUEHD_AC3' | Should -Be 'BLADE RUNNER'
        Get-ArmCleanDiscLabel -DiscLabel 'BLADE_RUNNER_DD5.1' | Should -Be 'BLADE RUNNER'
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

Describe 'Invoke-ArmLlmDisambiguation' {
    BeforeEach {
        $script:LlmConfig = @{
            LogDir      = $script:Config.LogDir
            LlmEndpoint = 'http://127.0.0.1:8080/v1'
            LlmModel    = 'qwen3.5-9b'
        }
        $script:Candidates = @(
            [pscustomobject]@{ title = 'Alpha'; release_date = '2001-01-01'; popularity = 10.0; overview = 'first' },
            [pscustomobject]@{ title = 'Alpha 2'; release_date = '2005-01-01'; popularity = 8.0; overview = 'second' }
        )
    }

    It 'returns the chosen index when the model replies with a valid index' {
        Mock Invoke-RestMethod {
            return [pscustomobject]@{
                choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = '{"index": 1}' } })
            }
        } -ParameterFilter { $Uri -like '*chat/completions*' }

        $result = Invoke-ArmLlmDisambiguation -DiscLabel 'Alpha' -Candidates $script:Candidates -Config $script:LlmConfig

        $result.SelectedIndex | Should -Be 1
    }

    It 'returns $null when the model declines with {"index": null}' {
        Mock Invoke-RestMethod {
            return [pscustomobject]@{
                choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = '{"index": null}' } })
            }
        }

        $result = Invoke-ArmLlmDisambiguation -DiscLabel 'Alpha' -Candidates $script:Candidates -Config $script:LlmConfig

        $result.SelectedIndex | Should -Be $null
    }

    It 'returns $null and does not throw when the HTTP call fails' {
        Mock Invoke-RestMethod { throw 'connection refused' }

        { $script:Result = Invoke-ArmLlmDisambiguation -DiscLabel 'Alpha' -Candidates $script:Candidates -Config $script:LlmConfig } | Should -Not -Throw
        $script:Result.SelectedIndex | Should -Be $null
    }

    It 'returns $null and does not throw when the response has no parseable JSON' {
        Mock Invoke-RestMethod {
            return [pscustomobject]@{
                choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = 'sorry, I cannot help with that' } })
            }
        }

        { $script:Result = Invoke-ArmLlmDisambiguation -DiscLabel 'Alpha' -Candidates $script:Candidates -Config $script:LlmConfig } | Should -Not -Throw
        $script:Result.SelectedIndex | Should -Be $null
    }

    It 'returns $null and does not throw when the model returns an out-of-range index' {
        Mock Invoke-RestMethod {
            return [pscustomobject]@{
                choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = '{"index": 99}' } })
            }
        }

        { $script:Result = Invoke-ArmLlmDisambiguation -DiscLabel 'Alpha' -Candidates $script:Candidates -Config $script:LlmConfig } | Should -Not -Throw
        $script:Result.SelectedIndex | Should -Be $null
    }

    It 'returns $null and does not throw when the model returns a non-integer index' {
        Mock Invoke-RestMethod {
            return [pscustomobject]@{
                choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = '{"index": "first one"}' } })
            }
        }

        { $script:Result = Invoke-ArmLlmDisambiguation -DiscLabel 'Alpha' -Candidates $script:Candidates -Config $script:LlmConfig } | Should -Not -Throw
        $script:Result.SelectedIndex | Should -Be $null
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

    It 'uses the LLM pick when results are ambiguous and LlmDisambiguationEnabled is true' {
        $llmConfig = $script:Config + @{ LlmDisambiguationEnabled = $true; LlmEndpoint = 'http://127.0.0.1:8080/v1'; LlmModel = 'qwen3.5-9b' }

        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*chat/completions*') {
                return [pscustomobject]@{
                    choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = '{"index": 1}' } })
                }
            }
            return [pscustomobject]@{
                results = @(
                    [pscustomobject]@{ title = 'Alpha'; release_date = '2001-01-01'; popularity = 10.0 },
                    [pscustomobject]@{ title = 'Alpha 2'; release_date = '2005-01-01'; popularity = 8.0 }
                )
            }
        }

        $result = Resolve-Title -DiscLabel 'ALPHA' -Config $llmConfig

        $result.Matched | Should -Be $true
        $result.Title | Should -Be 'Alpha 2'
        $result.Year | Should -Be 2005
        $result.FolderName | Should -Be 'Alpha 2 (2005)'
    }

    It 'falls back to label+date naming when the LLM declines an ambiguous match' {
        $llmConfig = $script:Config + @{ LlmDisambiguationEnabled = $true; LlmEndpoint = 'http://127.0.0.1:8080/v1'; LlmModel = 'qwen3.5-9b' }

        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*chat/completions*') {
                return [pscustomobject]@{
                    choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = '{"index": null}' } })
                }
            }
            return [pscustomobject]@{
                results = @(
                    [pscustomobject]@{ title = 'Alpha'; release_date = '2001-01-01'; popularity = 10.0 },
                    [pscustomobject]@{ title = 'Alpha 2'; release_date = '2005-01-01'; popularity = 8.0 }
                )
            }
        }

        $result = Resolve-Title -DiscLabel 'ALPHA' -Config $llmConfig

        $result.Matched | Should -Be $false
        $result.FolderName | Should -Match '^Alpha_\d{4}-\d{2}-\d{2}$'
    }

    It 'lets the LLM override an already-accepted TMDb top hit (recency-bias case)' {
        $llmConfig = $script:Config + @{ LlmDisambiguationEnabled = $true; LlmEndpoint = 'http://127.0.0.1:8080/v1'; LlmModel = 'qwen3.5-9b' }

        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*chat/completions*') {
                # Candidates sorted by popularity desc: [0]=Toy Story 5 (hyped/recent), [1]=Toy Story (1995, original)
                return [pscustomobject]@{
                    choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = '{"index": 1}' } })
                }
            }
            return [pscustomobject]@{
                results = @(
                    [pscustomobject]@{ title = 'Toy Story 5'; release_date = '2026-06-19'; popularity = 400.0 },
                    [pscustomobject]@{ title = 'Toy Story'; release_date = '1995-11-22'; popularity = 90.0 }
                )
            }
        }

        # TMDb's own acceptance rule would have accepted "Toy Story 5" outright (400 >= 2*90).
        Test-ArmTmdbAcceptance -Results @(
            [pscustomobject]@{ popularity = 400.0 }, [pscustomobject]@{ popularity = 90.0 }
        ) | Should -Be $true

        $result = Resolve-Title -DiscLabel 'TOY_STORY' -Config $llmConfig

        $result.Matched | Should -Be $true
        $result.Title | Should -Be 'Toy Story'
        $result.Year | Should -Be 1995
        $result.FolderName | Should -Be 'Toy Story (1995)'
    }

    It 'confirms an already-accepted TMDb top hit when the LLM agrees' {
        $llmConfig = $script:Config + @{ LlmDisambiguationEnabled = $true; LlmEndpoint = 'http://127.0.0.1:8080/v1'; LlmModel = 'qwen3.5-9b' }

        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*chat/completions*') {
                return [pscustomobject]@{
                    choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = '{"index": 0}' } })
                }
            }
            return $script:TmdbMatchJson
        }

        $result = Resolve-Title -DiscLabel 'STAR_WARS_ANH' -Config $llmConfig

        $result.Matched | Should -Be $true
        $result.Title | Should -Be 'Star Wars'
        $result.Year | Should -Be 1977
    }

    It 'uses TMDb''s own top hit when the LLM declines to validate an already-accepted match' {
        $llmConfig = $script:Config + @{ LlmDisambiguationEnabled = $true; LlmEndpoint = 'http://127.0.0.1:8080/v1'; LlmModel = 'qwen3.5-9b' }

        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*chat/completions*') {
                throw 'connection refused'
            }
            return $script:TmdbMatchJson
        }

        $result = Resolve-Title -DiscLabel 'STAR_WARS_ANH' -Config $llmConfig

        $result.Matched | Should -Be $true
        $result.Title | Should -Be 'Star Wars'
        $result.Year | Should -Be 1977
    }

    It 'does not call the LLM when TMDb returns zero results, even with LlmDisambiguationEnabled true' {
        $llmConfig = $script:Config + @{ LlmDisambiguationEnabled = $true; LlmEndpoint = 'http://127.0.0.1:8080/v1'; LlmModel = 'qwen3.5-9b' }

        Mock Invoke-RestMethod { return [pscustomobject]@{ results = @() } }

        $result = Resolve-Title -DiscLabel 'UNKNOWN_MOVIE_XYZ' -Config $llmConfig

        $result.Matched | Should -Be $false
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like '*chat/completions*' } -Times 0 -Exactly
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

    It 'retries with a truncated query when the full query returns zero results, down to a single word' {
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -match [regex]::Escape('query=Stardust Ps Ac')) {
                return [pscustomobject]@{ results = @() }
            }
            if ($Uri -match [regex]::Escape('query=Stardust Ps')) {
                return [pscustomobject]@{ results = @() }
            }
            return [pscustomobject]@{
                results = @(
                    [pscustomobject]@{ title = 'Stardust'; release_date = '2007-08-10'; popularity = 12.6 },
                    [pscustomobject]@{ title = 'Stardust Memories'; release_date = '1980-09-26'; popularity = 3.83 }
                )
            }
        }

        $result = Resolve-Title -DiscLabel 'STARDUST_PS_AC' -Config $script:Config

        $result.Matched | Should -Be $true
        $result.Title | Should -Be 'Stardust'
        $result.Year | Should -Be 2007
        $result.FolderName | Should -Be 'Stardust (2007)'
        Should -Invoke Invoke-RestMethod -Times 3 -Exactly
    }

    It 'does not retry when results are non-zero but ambiguous' {
        Mock Invoke-RestMethod {
            return [pscustomobject]@{
                results = @(
                    [pscustomobject]@{ title = 'Alpha One'; release_date = '2001-01-01'; popularity = 10.0 },
                    [pscustomobject]@{ title = 'Alpha Two'; release_date = '2005-01-01'; popularity = 8.0 }
                )
            }
        }

        $result = Resolve-Title -DiscLabel 'ALPHA ONE JUNK' -Config $script:Config

        $result.Matched | Should -Be $false
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'stops truncating at a single word and falls back to label+date if still no results' {
        Mock Invoke-RestMethod { return [pscustomobject]@{ results = @() } }

        $result = Resolve-Title -DiscLabel 'TOTALLY UNKNOWN JUNK LABEL' -Config $script:Config

        $result.Matched | Should -Be $false
        $result.FolderName | Should -Match '^Totally Unknown Junk Label_\d{4}-\d{2}-\d{2}$'
        # 1 initial + 3 truncations = 4 calls, last query is a single word
        Should -Invoke Invoke-RestMethod -Times 4 -Exactly
    }

    It 'matches a disc label carrying an audio codec suffix (e.g. CASTAWAY_DTS)' {
        Mock Invoke-RestMethod {
            return [pscustomobject]@{
                results = @(
                    [pscustomobject]@{ title = 'Cast Away'; release_date = '2000-12-22'; popularity = 16.39 },
                    [pscustomobject]@{ title = 'Castaway'; release_date = '1986-03-05'; popularity = 1.71 }
                )
            }
        }

        $result = Resolve-Title -DiscLabel 'CASTAWAY_DTS' -Config $script:Config

        $result.Matched | Should -Be $true
        $result.Title | Should -Be 'Cast Away'
        $result.Year | Should -Be 2000
        $result.FolderName | Should -Be 'Cast Away (2000)'
    }
}

Describe 'Resolve-TitleOverride' {
    BeforeEach {
        $script:OverrideDir = Join-Path $script:TestDir "override-$(New-Guid)"
        $null = New-Item -ItemType Directory -Force -Path $script:OverrideDir
        $script:Fallback = [pscustomobject]@{
            FolderName = 'Fallback Title (1999)'
            Matched    = $true
            Title      = 'Fallback Title'
            Year       = 1999
        }
    }

    It 'returns the fallback unchanged when metadata.json is missing' {
        $result = Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config
        $result | Should -Be $script:Fallback
    }

    It 'uses the override when Title and Year are both present' {
        '{"Title": "My Movie", "Year": "2020"}' | Set-Content -Path (Join-Path $script:OverrideDir 'metadata.json')

        $result = Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config

        $result.Matched | Should -Be $true
        $result.Title | Should -Be 'My Movie'
        $result.Year | Should -Be '2020'
        $result.FolderName | Should -Be 'My Movie (2020)'
    }

    It 'uses the override with just Title when Year is blank' {
        '{"Title": "My Movie", "Year": ""}' | Set-Content -Path (Join-Path $script:OverrideDir 'metadata.json')

        $result = Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config

        $result.Matched | Should -Be $true
        $result.FolderName | Should -Be 'My Movie'
    }

    It 'falls back to the original result when Title is blank/whitespace-only' {
        '{"Title": "   ", "Year": "2020"}' | Set-Content -Path (Join-Path $script:OverrideDir 'metadata.json')

        $result = Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config

        $result | Should -Be $script:Fallback
    }

    It 'uses the override when the Year key is entirely missing (not just blank)' {
        '{"Title": "My Movie"}' | Set-Content -Path (Join-Path $script:OverrideDir 'metadata.json')

        $result = Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config

        $result.Matched | Should -Be $true
        $result.FolderName | Should -Be 'My Movie'
    }

    It 'falls back to the original result when metadata.json is malformed JSON' {
        '{ this is not valid json' | Set-Content -Path (Join-Path $script:OverrideDir 'metadata.json')

        $result = Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config

        $result | Should -Be $script:Fallback
    }

    It 'falls back to the original result when metadata.json parses to a non-object' {
        '["not", "an", "object"]' | Set-Content -Path (Join-Path $script:OverrideDir 'metadata.json')

        $result = Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config

        $result | Should -Be $script:Fallback
    }

    It 'strips invalid filename characters from the override folder name' {
        '{"Title": "Se7en: Redux", "Year": "1995"}' | Set-Content -Path (Join-Path $script:OverrideDir 'metadata.json')

        $result = Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config

        $result.FolderName | Should -Not -Match '[\\/:*?"<>|]'
        $result.FolderName | Should -Be 'Se7en Redux (1995)'
    }

    It 'never throws' {
        '{ this is not valid json' | Set-Content -Path (Join-Path $script:OverrideDir 'metadata.json')
        { Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config } | Should -Not -Throw
    }
}
