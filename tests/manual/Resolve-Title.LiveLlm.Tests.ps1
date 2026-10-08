<#
    Live regression suite for Resolve-Title's LLM validation path (issue #13).

    Unlike every other test in this repo, this one makes REAL network calls: a
    real TMDb search and a real chat-completion request to a local
    OpenAI-compatible LLM server (llama.cpp, etc.). That's intentional - it's
    the only way to catch a real regression in how the model actually reasons
    about ambiguous candidates, which no mock can substitute for. It is
    therefore NOT part of `Invoke-Pester -Path tests` or CI (see
    .github/workflows/ci.yml's ExcludePath) and must be run manually:

        Invoke-Pester -Path tests/manual

    Requirements to run (auto-skips with a clear reason if unmet):
      - config/config.psd1 has a real TmdbApiKey.
      - An OpenAI-compatible chat-completions server is reachable at
        $Config.LlmEndpoint (default http://127.0.0.1:8080/v1). LlmModel is
        auto-discovered from GET /models if not set in config.psd1.

    Fixtures assert Title equals the exact TMDb title for the disc label's
    title-cased clean form - the strongest, most model-agnostic signal for "is
    this actually the right pick" - rather than pinning exact wording that a
    different model or prompt tweak could phrase differently. TMDb's returned
    candidate set/popularity ordering can drift over time as new titles are
    added; if a fixture starts failing, check whether the live TMDb result set
    for that label has changed before assuming a code regression.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeDiscovery {
    # Disc label -> the exact TMDb title expected to win. Each was picked by
    # running Resolve-Title live and confirming (a) TMDb genuinely returns an
    # ambiguous or recency-biased-wrong result set for the bare label, and
    # (b) an exact-title candidate exists for the LLM to correctly prefer.
    $script:Fixtures = @(
        @{ DiscLabel = 'ALIEN'; ExpectedTitle = 'Alien' }
        @{ DiscLabel = 'PSYCHO'; ExpectedTitle = 'Psycho' }
        @{ DiscLabel = 'DUNE'; ExpectedTitle = 'Dune' }
        @{ DiscLabel = 'THE_THING'; ExpectedTitle = 'The Thing' }
        @{ DiscLabel = 'SUSPIRIA'; ExpectedTitle = 'Suspiria' }
        @{ DiscLabel = 'CARRIE'; ExpectedTitle = 'Carrie' }
        @{ DiscLabel = 'THE_GRUDGE'; ExpectedTitle = 'The Grudge' }
        @{ DiscLabel = 'OLDBOY'; ExpectedTitle = 'Oldboy' }
        # Recency-bias regression case: TMDb's own 2x-popularity rule accepts a
        # hyped upcoming/recent sequel outright, so this exercises the LLM
        # overriding an already-"accepted" TMDb top hit, not just the
        # ambiguous-rejection path.
        @{ DiscLabel = 'TOY_STORY'; ExpectedTitle = 'Toy Story' }
    )
}

BeforeAll {
    $script:RepoRoot = Join-Path $PSScriptRoot '..' '..'
    . (Join-Path $script:RepoRoot 'src' 'Common.ps1')
    . (Join-Path $script:RepoRoot 'src' 'Resolve-Title.ps1')

    $script:Config = Import-PowerShellDataFile -Path (Join-Path $script:RepoRoot 'config' 'config.psd1')
    $script:Config.LogDir = Join-Path $env:TEMP 'wrm-live-llm-test-logs'
    $script:Config.LlmDisambiguationEnabled = $true
    if (-not $script:Config.ContainsKey('LlmEndpoint') -or -not $script:Config.LlmEndpoint) {
        $script:Config.LlmEndpoint = 'http://127.0.0.1:8080/v1'
    }
    if (-not $script:Config.ContainsKey('LlmTimeoutSec') -or -not $script:Config.LlmTimeoutSec) {
        $script:Config.LlmTimeoutSec = 15
    }
    # A cold local model can take well over a minute to load into memory/GPU
    # before it answers its first request; this suite runs rarely/manually, so
    # trade patience for not flaking on a cold start.
    $script:Config.LlmTimeoutSec = [Math]::Max($script:Config.LlmTimeoutSec, 120)

    $script:SkipReason = $null
    if (-not $script:Config.TmdbApiKey) {
        $script:SkipReason = 'No TmdbApiKey configured in config/config.psd1'
    } else {
        try {
            $models = Invoke-RestMethod -Uri "$($script:Config.LlmEndpoint.TrimEnd('/'))/models" -Method Get -TimeoutSec 5
            if (-not $script:Config.ContainsKey('LlmModel') -or -not $script:Config.LlmModel) {
                $script:Config.LlmModel = $models.data[0].id
            }
        } catch {
            $script:SkipReason = "LLM endpoint '$($script:Config.LlmEndpoint)' unreachable: $_"
        }
    }
}

Describe 'Resolve-Title - live LLM validation (manual, not run in CI)' {
    It 'resolves "<DiscLabel>" to "<ExpectedTitle>" via the live LLM' -ForEach $script:Fixtures {
        if ($script:SkipReason) {
            Set-ItResult -Skipped -Because $script:SkipReason
            return
        }

        $result = Resolve-Title -DiscLabel $DiscLabel -Config $script:Config

        $result.Matched | Should -Be $true -Because "the LLM should confidently resolve the unambiguous franchise entry for '$DiscLabel'"
        $result.Title | Should -Be $ExpectedTitle
    }
}

BeforeDiscovery {
    # ContentType detection (issue #25). Expected = $null means "mixed content: record
    # what TMDb genres + the LLM say, assert nothing" (Roger Rabbit, Sesame Street).
    $script:ContentTypeFixtures = @(
        @{ DiscLabel = 'TOY_STORY'; Expected = 'Animation' }
        @{ DiscLabel = 'SNOOPY_COME_HOME'; Expected = 'Animation' }
        @{ DiscLabel = 'CAST_AWAY'; Expected = 'LiveAction' }
        @{ DiscLabel = 'WHO_FRAMED_ROGER_RABBIT'; Expected = $null }
        @{ DiscLabel = 'SESAME_STREET'; Expected = $null }
    )
}

Describe 'Resolve-Title - live ContentType detection (manual, not run in CI)' {
    It 'reports ContentType for "<DiscLabel>" (TMDb genre_ids + LLM animated cross-check)' -ForEach $script:ContentTypeFixtures {
        if ($script:SkipReason) {
            Set-ItResult -Skipped -Because $script:SkipReason
            return
        }

        $result = Resolve-Title -DiscLabel $DiscLabel -Config $script:Config

        Write-Host "[$DiscLabel] Matched=$($result.Matched) Title='$($result.Title)' ContentType=$($result.ContentType) Note='$($result.ContentTypeNote)'"
        $result.ContentType | Should -BeIn @('Animation', 'LiveAction')
        if ($Expected) {
            $result.ContentType | Should -Be $Expected
        }
    }
}
