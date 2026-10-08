# ContentType (Animation / LiveAction) detection: TMDb genre -> Resolve-Title ->
# metadata.json -> Resolve-TitleOverride -> upscale queue entry. See SPEC.md
# "Resolve-Title.ps1" and issue #25. No network: Invoke-RestMethod is mocked.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'JobState.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Resolve-Title.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Rip-VideoDisc.ps1')

    $script:FixturesDir = Join-Path $PSScriptRoot 'fixtures'
    $script:LiveJson = Get-Content -Path (Join-Path $script:FixturesDir 'tmdb-search.json') -Raw | ConvertFrom-Json
    $script:AnimJson = Get-Content -Path (Join-Path $script:FixturesDir 'tmdb-search-animation.json') -Raw | ConvertFrom-Json
    $script:TestDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wrm-ct-test-$(New-Guid)")
    $script:Config = @{ TmdbApiKey = 'test-key'; LogDir = Join-Path $script:TestDir 'logs' }
    $script:LlmConfig = $script:Config + @{ LlmDisambiguationEnabled = $true; LlmEndpoint = 'http://127.0.0.1:8080/v1'; LlmModel = 'qwen3.5-9b' }

    # Mock body for Invoke-RestMethod: TMDb search returns $Tmdb; the LLM endpoint
    # replies with $LlmContent (or throws when $LlmThrows).
    function Set-ArmContentTypeRestMock {
        param($Tmdb, [string] $LlmContent, [switch] $LlmThrows)
        $script:MockTmdb = $Tmdb
        $script:MockLlmContent = $LlmContent
        $script:MockLlmThrows = [bool]$LlmThrows
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*chat/completions*') {
                if ($script:MockLlmThrows) { throw 'connection refused' }
                return [pscustomobject]@{
                    choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = $script:MockLlmContent } })
                }
            }
            return $script:MockTmdb
        }
    }
}

AfterAll {
    Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ArmTmdbContentType' {
    It 'is Animation when genre_ids contains 16' {
        Get-ArmTmdbContentType -Candidate ([pscustomobject]@{ genre_ids = @(35, 16) }) | Should -Be 'Animation'
    }
    It 'is LiveAction when genre_ids lacks 16' {
        Get-ArmTmdbContentType -Candidate ([pscustomobject]@{ genre_ids = @(12, 18) }) | Should -Be 'LiveAction'
    }
    It 'is LiveAction when genre_ids is missing, empty, or null' {
        Get-ArmTmdbContentType -Candidate ([pscustomobject]@{ title = 'x' }) | Should -Be 'LiveAction'
        Get-ArmTmdbContentType -Candidate ([pscustomobject]@{ genre_ids = @() }) | Should -Be 'LiveAction'
        Get-ArmTmdbContentType -Candidate ([pscustomobject]@{ genre_ids = $null }) | Should -Be 'LiveAction'
        Get-ArmTmdbContentType -Candidate $null | Should -Be 'LiveAction'
    }
    It 'handles a single non-array genre id and hashtable candidates' {
        Get-ArmTmdbContentType -Candidate ([pscustomobject]@{ genre_ids = 16 }) | Should -Be 'Animation'
        Get-ArmTmdbContentType -Candidate @{ genre_ids = @(16) } | Should -Be 'Animation'
    }
}

Describe 'Resolve-Title ContentType (TMDb only)' {
    BeforeEach { Mock Write-ArmLog { } }

    It 'returns Animation when the accepted TMDb hit has genre 16' {
        Set-ArmContentTypeRestMock -Tmdb $script:AnimJson
        $r = Resolve-Title -DiscLabel 'TOY_STORY' -Config $script:Config
        $r.Matched | Should -BeTrue
        $r.Title | Should -Be 'Toy Story'
        $r.ContentType | Should -Be 'Animation'
        $r.ContentTypeNote | Should -Be ''
    }

    It 'returns LiveAction when the accepted TMDb hit has no genre 16' {
        Set-ArmContentTypeRestMock -Tmdb $script:LiveJson
        $r = Resolve-Title -DiscLabel 'STAR_WARS_ANH' -Config $script:Config
        $r.Matched | Should -BeTrue
        $r.ContentType | Should -Be 'LiveAction'
        $r.ContentTypeNote | Should -Be ''
    }

    It 'returns LiveAction when the TMDb result has no genre_ids at all' {
        Set-ArmContentTypeRestMock -Tmdb ([pscustomobject]@{
                results = @([pscustomobject]@{ title = 'Gamma'; release_date = '2010-01-01'; popularity = 10.0 })
            })
        $r = Resolve-Title -DiscLabel 'GAMMA' -Config $script:Config
        $r.Matched | Should -BeTrue
        $r.ContentType | Should -Be 'LiveAction'
    }

    It 'returns LiveAction on every no-match fallback path' {
        # no API key
        $r = Resolve-Title -DiscLabel 'TOY_STORY' -Config @{ TmdbApiKey = ''; LogDir = $script:Config.LogDir }
        $r.Matched | Should -BeFalse
        $r.ContentType | Should -Be 'LiveAction'
        $r.ContentTypeNote | Should -Be ''

        # zero results
        Set-ArmContentTypeRestMock -Tmdb ([pscustomobject]@{ results = @() })
        $r = Resolve-Title -DiscLabel 'NOTHING' -Config $script:Config
        $r.Matched | Should -BeFalse
        $r.ContentType | Should -Be 'LiveAction'

        # ambiguous (even though both candidates are animated)
        Set-ArmContentTypeRestMock -Tmdb ([pscustomobject]@{
                results = @(
                    [pscustomobject]@{ title = 'Alpha'; release_date = '2001-01-01'; popularity = 10.0; genre_ids = @(16) },
                    [pscustomobject]@{ title = 'Alpha 2'; release_date = '2005-01-01'; popularity = 8.0; genre_ids = @(16) }
                )
            })
        $r = Resolve-Title -DiscLabel 'ALPHA' -Config $script:Config
        $r.Matched | Should -BeFalse
        $r.ContentType | Should -Be 'LiveAction'

        # HTTP failure
        Mock Invoke-RestMethod { throw 'boom' }
        $r = Resolve-Title -DiscLabel 'TOY_STORY' -Config $script:Config
        $r.Matched | Should -BeFalse
        $r.ContentType | Should -Be 'LiveAction'
    }
}

Describe 'Resolve-Title ContentType (LLM cross-check)' {
    BeforeEach { Mock Write-ArmLog { } }

    It 'LLM agrees (animated=true on an Animation hit): Animation, no note' {
        Set-ArmContentTypeRestMock -Tmdb $script:AnimJson -LlmContent '{"index": 0, "animated": true}'
        $r = Resolve-Title -DiscLabel 'TOY_STORY' -Config $script:LlmConfig
        $r.Title | Should -Be 'Toy Story'
        $r.ContentType | Should -Be 'Animation'
        $r.ContentTypeNote | Should -Be ''
        Should -Not -Invoke Write-ArmLog -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*ContentType disagreement*' }
    }

    It 'LLM agrees (animated=false on a LiveAction hit): LiveAction, no note' {
        Set-ArmContentTypeRestMock -Tmdb $script:LiveJson -LlmContent '{"index": 0, "animated": false}'
        $r = Resolve-Title -DiscLabel 'STAR_WARS_ANH' -Config $script:LlmConfig
        $r.ContentType | Should -Be 'LiveAction'
        $r.ContentTypeNote | Should -Be ''
    }

    It 'LLM disagrees (animated=false on an Animation hit): TMDb wins, WARN logged, both values in the note' {
        Set-ArmContentTypeRestMock -Tmdb $script:AnimJson -LlmContent '{"index": 0, "animated": false}'
        $r = Resolve-Title -DiscLabel 'TOY_STORY' -Config $script:LlmConfig
        $r.ContentType | Should -Be 'Animation'
        $r.ContentTypeNote | Should -BeLike '*TMDb genres say Animation*LLM says not animated*'
        Should -Invoke Write-ArmLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*ContentType disagreement*' }
    }

    It 'LLM disagrees (animated=true on a LiveAction hit): TMDb wins and the note records both' {
        Set-ArmContentTypeRestMock -Tmdb $script:LiveJson -LlmContent '{"index": 0, "animated": true}'
        $r = Resolve-Title -DiscLabel 'STAR_WARS_ANH' -Config $script:LlmConfig
        $r.ContentType | Should -Be 'LiveAction'
        $r.ContentTypeNote | Should -BeLike '*TMDb genres say LiveAction*LLM says animated*'
        Should -Invoke Write-ArmLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*ContentType disagreement*' }
    }

    It 'takes ContentType from the candidate the LLM picked, not TMDb''s top hit' {
        Set-ArmContentTypeRestMock -LlmContent '{"index": 1, "animated": false}' -Tmdb ([pscustomobject]@{
                results = @(
                    [pscustomobject]@{ title = 'Delta Reborn'; release_date = '2025-01-01'; popularity = 90.0; genre_ids = @(16, 35) },
                    [pscustomobject]@{ title = 'Delta'; release_date = '1999-01-01'; popularity = 30.0; genre_ids = @(18) }
                )
            })
        $r = Resolve-Title -DiscLabel 'DELTA' -Config $script:LlmConfig
        $r.Title | Should -Be 'Delta'
        $r.ContentType | Should -Be 'LiveAction'
        $r.ContentTypeNote | Should -Be ''
    }

    It 'omitted animated: ContentType comes from TMDb, no note, index still honoured' {
        Set-ArmContentTypeRestMock -Tmdb $script:AnimJson -LlmContent '{"index": 0}'
        $r = Resolve-Title -DiscLabel 'TOY_STORY' -Config $script:LlmConfig
        $r.Matched | Should -BeTrue
        $r.ContentType | Should -Be 'Animation'
        $r.ContentTypeNote | Should -Be ''
    }

    It 'invalid animated value does not invalidate a valid index' {
        Set-ArmContentTypeRestMock -Tmdb $script:AnimJson -LlmContent '{"index": 0, "animated": "maybe"}'
        $r = Resolve-Title -DiscLabel 'TOY_STORY' -Config $script:LlmConfig
        $r.Matched | Should -BeTrue
        $r.Title | Should -Be 'Toy Story'
        $r.ContentType | Should -Be 'Animation'
        $r.ContentTypeNote | Should -Be ''
    }

    It 'index null: animated is ignored and the TMDb top hit supplies ContentType' {
        Set-ArmContentTypeRestMock -Tmdb $script:AnimJson -LlmContent '{"index": null, "animated": false}'
        $r = Resolve-Title -DiscLabel 'TOY_STORY' -Config $script:LlmConfig
        $r.Matched | Should -BeTrue
        $r.ContentType | Should -Be 'Animation'
        $r.ContentTypeNote | Should -Be ''
    }

    It 'LLM unavailable: degrades to the TMDb genre with no note' {
        Set-ArmContentTypeRestMock -Tmdb $script:AnimJson -LlmThrows
        $r = Resolve-Title -DiscLabel 'TOY_STORY' -Config $script:LlmConfig
        $r.Matched | Should -BeTrue
        $r.ContentType | Should -Be 'Animation'
        $r.ContentTypeNote | Should -Be ''
    }

    It 'LLM disabled: no chat/completions call and ContentType is the TMDb genre' {
        Set-ArmContentTypeRestMock -Tmdb $script:AnimJson -LlmContent '{"index": 0, "animated": false}'
        $r = Resolve-Title -DiscLabel 'TOY_STORY' -Config $script:Config
        $r.ContentType | Should -Be 'Animation'
        Should -Not -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like '*chat/completions*' }
    }
}

Describe 'Invoke-ArmLlmDisambiguation genres / animated' {
    BeforeEach {
        Mock Write-ArmLog { }
        $script:Cands = @(
            [pscustomobject]@{ title = 'Toy Story'; release_date = '1995-10-30'; popularity = 90.0; genre_ids = @(16, 35, 10751) },
            [pscustomobject]@{ title = 'No Genres'; release_date = '2000-01-01'; popularity = 5.0 }
        )
    }

    It 'sends genre names (not ids) for each candidate and asks for animated' {
        Set-ArmContentTypeRestMock -Tmdb $null -LlmContent '{"index": 0, "animated": true}'
        $null = Invoke-ArmLlmDisambiguation -DiscLabel 'Toy Story' -Candidates $script:Cands -Config $script:LlmConfig
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*chat/completions*' -and $Body -like '*Animation*' -and $Body -like '*Family*' -and $Body -like '*animated*'
        }
    }

    It 'returns Animated=$true / $false for boolean answers (and the strings "true"/"false")' {
        Set-ArmContentTypeRestMock -Tmdb $null -LlmContent '{"index": 0, "animated": true}'
        (Invoke-ArmLlmDisambiguation -DiscLabel 'x' -Candidates $script:Cands -Config $script:LlmConfig).Animated | Should -BeTrue
        Set-ArmContentTypeRestMock -Tmdb $null -LlmContent '{"index": 0, "animated": false}'
        (Invoke-ArmLlmDisambiguation -DiscLabel 'x' -Candidates $script:Cands -Config $script:LlmConfig).Animated | Should -BeFalse
        Set-ArmContentTypeRestMock -Tmdb $null -LlmContent '{"index": 0, "animated": "true"}'
        (Invoke-ArmLlmDisambiguation -DiscLabel 'x' -Candidates $script:Cands -Config $script:LlmConfig).Animated | Should -BeTrue
    }

    It 'returns Animated=$null when absent or invalid, and for failures / null index' {
        Set-ArmContentTypeRestMock -Tmdb $null -LlmContent '{"index": 1}'
        $r = Invoke-ArmLlmDisambiguation -DiscLabel 'x' -Candidates $script:Cands -Config $script:LlmConfig
        $r.SelectedIndex | Should -Be 1
        $r.Animated | Should -BeNullOrEmpty

        Set-ArmContentTypeRestMock -Tmdb $null -LlmContent '{"index": 1, "animated": 7}'
        $r = Invoke-ArmLlmDisambiguation -DiscLabel 'x' -Candidates $script:Cands -Config $script:LlmConfig
        $r.SelectedIndex | Should -Be 1
        $r.Animated | Should -BeNullOrEmpty

        Set-ArmContentTypeRestMock -Tmdb $null -LlmContent '{"index": null, "animated": true}'
        $r = Invoke-ArmLlmDisambiguation -DiscLabel 'x' -Candidates $script:Cands -Config $script:LlmConfig
        $r.SelectedIndex | Should -BeNullOrEmpty
        $r.Animated | Should -BeNullOrEmpty

        Set-ArmContentTypeRestMock -Tmdb $null -LlmThrows
        $r = Invoke-ArmLlmDisambiguation -DiscLabel 'x' -Candidates $script:Cands -Config $script:LlmConfig
        $r.SelectedIndex | Should -BeNullOrEmpty
        $r.Animated | Should -BeNullOrEmpty
    }
}

Describe 'Set-ArmMetadataFile ContentType' {
    BeforeEach {
        Mock Write-ArmLog { }
        $script:MetaDir = Join-Path $script:TestDir "meta-$(New-Guid)"
        $null = New-Item -ItemType Directory -Force -Path $script:MetaDir
        $script:MetaPath = Join-Path $script:MetaDir 'metadata.json'
    }

    It 'writes Title, Year, ContentType and ContentTypeNote' {
        Set-ArmMetadataFile -OutputDir $script:MetaDir -Title 'Toy Story' -Year '1995' -ContentType 'Animation' -ContentTypeNote 'n' -Config $script:Config
        $m = Get-Content $script:MetaPath -Raw | ConvertFrom-Json
        $m.Title | Should -Be 'Toy Story'
        $m.Year | Should -Be '1995'
        $m.ContentType | Should -Be 'Animation'
        $m.ContentTypeNote | Should -Be 'n'
    }

    It '-Force without ContentType/ContentTypeNote preserves them (web UI title edit must not wipe them)' {
        Set-ArmMetadataFile -OutputDir $script:MetaDir -Title 'Toy Story' -Year '1995' -ContentType 'Animation' -ContentTypeNote 'both values' -Config $script:Config
        Set-ArmMetadataFile -OutputDir $script:MetaDir -Title 'Toy Story 2' -Year '1999' -Config $script:Config -Force
        $m = Get-Content $script:MetaPath -Raw | ConvertFrom-Json
        $m.Title | Should -Be 'Toy Story 2'
        $m.Year | Should -Be '1999'
        $m.ContentType | Should -Be 'Animation'
        $m.ContentTypeNote | Should -Be 'both values'
    }

    It '-Force with an explicit ContentType replaces only that field' {
        Set-ArmMetadataFile -OutputDir $script:MetaDir -Title 'Roger' -Year '1988' -ContentType 'LiveAction' -ContentTypeNote 'keep me' -Config $script:Config
        Set-ArmMetadataFile -OutputDir $script:MetaDir -Title 'Roger' -Year '1988' -ContentType 'Animation' -Config $script:Config -Force
        $m = Get-Content $script:MetaPath -Raw | ConvertFrom-Json
        $m.ContentType | Should -Be 'Animation'
        $m.ContentTypeNote | Should -Be 'keep me'
    }

    It 'without -Force never clobbers an existing file' {
        '{"Title": "Edited", "Year": "2001", "ContentType": "Animation"}' | Set-Content -Path $script:MetaPath
        Set-ArmMetadataFile -OutputDir $script:MetaDir -Title 'Other' -Year '1' -ContentType 'LiveAction' -Config $script:Config
        $m = Get-Content $script:MetaPath -Raw | ConvertFrom-Json
        $m.Title | Should -Be 'Edited'
        $m.ContentType | Should -Be 'Animation'
    }

    It 'omits ContentType keys when never given and nothing exists to preserve' {
        Set-ArmMetadataFile -OutputDir $script:MetaDir -Title 'Plain' -Year '2000' -Config $script:Config
        $m = Get-Content $script:MetaPath -Raw | ConvertFrom-Json
        $m.PSObject.Properties['ContentType'] | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-TitleOverride ContentType' {
    BeforeEach {
        Mock Write-ArmLog { }
        $script:OverrideDir = Join-Path $script:TestDir "override-$(New-Guid)"
        $null = New-Item -ItemType Directory -Force -Path $script:OverrideDir
        $script:MetaPath = Join-Path $script:OverrideDir 'metadata.json'
        $script:Fallback = [pscustomobject]@{
            FolderName = 'Toy Story (1995)'; Matched = $true; Title = 'Toy Story'; Year = 1995
            ContentType = 'Animation'; ContentTypeNote = 'a note'
        }
    }

    It 'keeps the fallback ContentType when metadata.json repeats it' {
        '{"Title": "Toy Story", "Year": "1995", "ContentType": "Animation"}' | Set-Content -Path $script:MetaPath
        $r = Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config
        $r.ContentType | Should -Be 'Animation'
        $r.ContentTypeNote | Should -Be 'a note'
    }

    It 'honours a ContentType-only edit even when Title is blank (fallback title/folder kept)' {
        '{"Title": "", "Year": "", "ContentType": "LiveAction"}' | Set-Content -Path $script:MetaPath
        $r = Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config
        $r.ContentType | Should -Be 'LiveAction'
        $r.FolderName | Should -Be 'Toy Story (1995)'
        $r.Title | Should -Be 'Toy Story'
        $r.Matched | Should -BeTrue
    }

    It 'honours a ContentType edit when Title is unedited' {
        $live = [pscustomobject]@{ FolderName = 'Roger (1988)'; Matched = $true; Title = 'Roger'; Year = 1988; ContentType = 'LiveAction'; ContentTypeNote = '' }
        '{"Title": "Roger", "Year": "1988", "ContentType": "Animation"}' | Set-Content -Path $script:MetaPath
        $r = Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $live -Config $script:Config
        $r.ContentType | Should -Be 'Animation'
        $r.FolderName | Should -Be 'Roger (1988)'
    }

    It 'matches ContentType case-insensitively and trims' {
        '{"Title": "", "ContentType": "  liveaction "}' | Set-Content -Path $script:MetaPath
        (Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config).ContentType | Should -Be 'LiveAction'
        '{"Title": "", "ContentType": "ANIMATION"}' | Set-Content -Path $script:MetaPath
        $live = [pscustomobject]@{ FolderName = 'R (1)'; Matched = $true; Title = 'R'; Year = 1; ContentType = 'LiveAction'; ContentTypeNote = '' }
        (Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $live -Config $script:Config).ContentType | Should -Be 'Animation'
    }

    It 'ignores an invalid ContentType value, keeps the fallback and logs a WARN' {
        '{"Title": "", "ContentType": "Cartoon"}' | Set-Content -Path $script:MetaPath
        $r = Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config
        $r.ContentType | Should -Be 'Animation'
        Should -Invoke Write-ArmLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -like "*invalid ContentType 'Cartoon'*" }
    }

    It 'title edited without a ContentType change keeps the TMDb-derived value and logs INFO' {
        '{"Title": "Toy Story 2", "Year": "1999", "ContentType": "Animation"}' | Set-Content -Path $script:MetaPath
        $r = Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config
        $r.Title | Should -Be 'Toy Story 2'
        $r.FolderName | Should -Be 'Toy Story 2 (1999)'
        $r.ContentType | Should -Be 'Animation'
        Should -Invoke Write-ArmLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'INFO' -and $Message -like '*ContentType not changed*' }
    }

    It 'title edited and ContentType key absent keeps the fallback value' {
        '{"Title": "Toy Story 2", "Year": "1999"}' | Set-Content -Path $script:MetaPath
        $r = Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config
        $r.ContentType | Should -Be 'Animation'
    }

    It 'title and ContentType both edited: both are used' {
        '{"Title": "My Movie", "Year": "2020", "ContentType": "LiveAction"}' | Set-Content -Path $script:MetaPath
        $r = Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config
        $r.FolderName | Should -Be 'My Movie (2020)'
        $r.ContentType | Should -Be 'LiveAction'
    }

    It 'a legacy fallback without ContentType defaults to LiveAction' {
        $legacy = [pscustomobject]@{ FolderName = 'Old (2000)'; Matched = $true; Title = 'Old'; Year = 2000 }
        '{"Title": "New", "Year": "2001"}' | Set-Content -Path $script:MetaPath
        (Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $legacy -Config $script:Config).ContentType | Should -Be 'LiveAction'
    }

    It 'returns the fallback object unchanged when metadata.json is missing, and never throws on bad JSON' {
        (Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config) | Should -Be $script:Fallback
        '{ not json' | Set-Content -Path $script:MetaPath
        { Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config } | Should -Not -Throw
    }

    It 'round-trips: Set-ArmMetadataFile output edited by hand is read back' {
        Set-ArmMetadataFile -OutputDir $script:OverrideDir -Title 'Toy Story' -Year '1995' -ContentType 'Animation' -ContentTypeNote '' -Config $script:Config
        $m = Get-Content $script:MetaPath -Raw | ConvertFrom-Json
        $m.ContentType = 'LiveAction'
        $m | ConvertTo-Json | Set-Content -Path $script:MetaPath
        (Resolve-TitleOverride -OutputDir $script:OverrideDir -FallbackResolved $script:Fallback -Config $script:Config).ContentType | Should -Be 'LiveAction'
    }
}
