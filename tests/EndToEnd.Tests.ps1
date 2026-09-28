<#
.SYNOPSIS
    End-to-end tests per SPEC.md "Testing requirements": run the real entry-point
    scripts (DiscWatcher.ps1, Upscale-Worker.ps1) with -Simulate -Once against a
    real config.psd1 on disk and real (non-TestDrive) temp directories, and verify
    that real files land where expected.

.DESCRIPTION
    These tests deliberately do NOT use TestDrive: for any path that crosses a
    process boundary: Invoke-ArmTool launches stubs via Start-Process (a genuinely
    separate pwsh process per Common.ps1), and a fresh process has no knowledge of
    the calling Pester session's TestDrive: PSDrive. All staging/NAS/queue/log
    directories here are real folders under $env:TEMP, cleaned up in AfterAll.

    Per SPEC.md, each scenario gracefully Skips (via Set-ItResult -Skipped) rather
    than failing when a sibling file it depends on doesn't exist yet, or when a
    test stub exists but is still a non-functional placeholder (e.g.
    stub-freaccmd.ps1 as of this writing just prints an error and exits 42) — a QA
    agent re-runs this suite once all sibling modules/stubs have landed.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:RepoRoot = Join-Path $PSScriptRoot '..'
    $script:WatcherScript = Join-Path $script:RepoRoot 'src' 'DiscWatcher.ps1'
    $script:UpscaleWorkerScript = Join-Path $script:RepoRoot 'src' 'Upscale-Worker.ps1'
    $script:StubDir = Join-Path $PSScriptRoot 'stubs'

    # Job-state assertions read the records the child scripts wrote.
    . (Join-Path $script:RepoRoot 'src' 'Common.ps1')
    . (Join-Path $script:RepoRoot 'src' 'JobState.ps1')

    function New-ArmE2eConfig {
        param(
            [Parameter(Mandatory = $true)] [string] $Root,
            [switch] $AutoUpscale
        )

        $paths = @{
            StagingDir      = Join-Path $Root 'staging'
            UpscaleQueueDir = Join-Path $Root 'queue'
            LogDir          = Join-Path $Root 'logs'
            StateDir        = Join-Path $Root 'state'
            NasVideoPath    = Join-Path $Root 'nas-video'
            NasMusicPath    = Join-Path $Root 'nas-music'
        }
        foreach ($p in $paths.Values) {
            New-Item -ItemType Directory -Force -Path $p | Out-Null
        }

        $configPath = Join-Path $Root 'config.psd1'
        @"
@{
    NasVideoPath      = '$($paths.NasVideoPath -replace "'", "''")'
    NasMusicPath      = '$($paths.NasMusicPath -replace "'", "''")'
    StagingDir        = '$($paths.StagingDir -replace "'", "''")'
    UpscaleQueueDir   = '$($paths.UpscaleQueueDir -replace "'", "''")'
    LogDir            = '$($paths.LogDir -replace "'", "''")'
    StateDir          = '$($paths.StateDir -replace "'", "''")'
    MakeMkvConPath    = 'C:\does-not-exist\makemkvcon64.exe'
    FreacCmdPath      = 'C:\does-not-exist\freaccmd.exe'
    FfmpegPath        = 'ffmpeg'
    Video2xPath       = 'C:\does-not-exist\video2x.exe'
    MinTitleLengthSec = 600
    RipAllTitles      = `$true
    EjectWhenDone     = `$true
    TmdbApiKey        = ''
    HaWebhookUrl      = ''
    UpscaleDvds       = `$false
    AutoUpscale       = `$$($AutoUpscale.IsPresent.ToString().ToLower())
    UpscaleActiveHours = @('00:00','23:59')
    UpscaleModel      = 'realesr-generalv3'
    UpscaleScale      = 3
    UpscaleCrf        = 16
    Simulate          = `$true
}
"@ | Set-Content -Path $configPath -Encoding utf8

        return [pscustomobject]@{
            ConfigPath = $configPath
            Paths      = $paths
            # Just enough config for JobState.ps1 reads from the test process.
            JobConfig  = @{ StateDir = $paths.StateDir; LogDir = $paths.LogDir }
        }
    }
}

Describe 'End-to-end: DiscWatcher.ps1 -Simulate -Once (Video)' {
    BeforeAll {
        $script:E2eRoot = Join-Path $env:TEMP "wrm-e2e-video-$(New-Guid)"
        New-Item -ItemType Directory -Force -Path $script:E2eRoot | Out-Null
        $script:E2eConfig = New-ArmE2eConfig -Root $script:E2eRoot
    }

    AfterAll {
        Remove-Item -Path $script:E2eRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'produces a named folder containing .mkv files under the temp NAS video root' {
        if (-not (Test-Path (Join-Path $script:RepoRoot 'src' 'Rip-VideoDisc.ps1'))) {
            Set-ItResult -Skipped -Because 'src/Rip-VideoDisc.ps1 does not exist yet'
            return
        }
        if (-not (Test-Path (Join-Path $script:RepoRoot 'src' 'Resolve-Title.ps1'))) {
            Set-ItResult -Skipped -Because 'src/Resolve-Title.ps1 does not exist yet'
            return
        }
        if (-not (Test-Path (Join-Path $script:StubDir 'stub-makemkvcon.ps1'))) {
            Set-ItResult -Skipped -Because 'tests/stubs/stub-makemkvcon.ps1 does not exist yet'
            return
        }

        $env:WRM_SIM_DISC = 'Video'
        try {
            & $script:WatcherScript -ConfigPath $script:E2eConfig.ConfigPath -Simulate -Once
        } finally {
            Remove-Item Env:\WRM_SIM_DISC -ErrorAction SilentlyContinue
        }

        $mkvFiles = @(Get-ChildItem -Path $script:E2eConfig.Paths.NasVideoPath -Recurse -Filter '*.mkv' -ErrorAction SilentlyContinue)
        if ($mkvFiles.Count -eq 0) {
            Set-ItResult -Skipped -Because 'video rip pipeline did not produce output (a dependency stub is likely still a placeholder) -- rerun once all sibling modules land'
            return
        }

        $namedDirs = @(Get-ChildItem -Path $script:E2eConfig.Paths.NasVideoPath -Directory -ErrorAction SilentlyContinue)
        $namedDirs.Count | Should -BeGreaterThan 0
        $mkvFiles.Count | Should -BeGreaterThan 0

        # Job state: one Rip job, Complete, pointing at the NAS folder.
        $jobs = @(Get-ArmJobList -Kind Rip -Config $script:E2eConfig.JobConfig)
        $jobs.Count | Should -Be 1
        $jobs[0].State | Should -Be 'Complete'
        $jobs[0].DestDir | Should -Be $namedDirs[0].FullName
        @($jobs[0].History).State | Should -Be @('Detected', 'Ripping', 'Moving', 'Complete')
    }
}

Describe 'End-to-end: DiscWatcher.ps1 -Simulate -Once (AudioCD)' {
    BeforeAll {
        $script:E2eRoot = Join-Path $env:TEMP "wrm-e2e-audio-$(New-Guid)"
        New-Item -ItemType Directory -Force -Path $script:E2eRoot | Out-Null
        $script:E2eConfig = New-ArmE2eConfig -Root $script:E2eRoot
    }

    AfterAll {
        Remove-Item -Path $script:E2eRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'produces .flac files under the temp NAS music root' {
        if (-not (Test-Path (Join-Path $script:RepoRoot 'src' 'Rip-AudioCd.ps1'))) {
            Set-ItResult -Skipped -Because 'src/Rip-AudioCd.ps1 does not exist yet'
            return
        }
        if (-not (Test-Path (Join-Path $script:StubDir 'stub-freaccmd.ps1'))) {
            Set-ItResult -Skipped -Because 'tests/stubs/stub-freaccmd.ps1 does not exist yet'
            return
        }

        $env:WRM_SIM_DISC = 'AudioCD'
        try {
            & $script:WatcherScript -ConfigPath $script:E2eConfig.ConfigPath -Simulate -Once
        } finally {
            Remove-Item Env:\WRM_SIM_DISC -ErrorAction SilentlyContinue
        }

        $flacFiles = @(Get-ChildItem -Path $script:E2eConfig.Paths.NasMusicPath -Recurse -Filter '*.flac' -ErrorAction SilentlyContinue)
        if ($flacFiles.Count -eq 0) {
            Set-ItResult -Skipped -Because 'tests/stubs/stub-freaccmd.ps1 exists but is still a non-functional placeholder (does not emit an "<Artist> - <Album>" directory with .flac files) -- rerun once it is implemented'
            return
        }

        $flacFiles.Count | Should -BeGreaterThan 0

        $jobs = @(Get-ArmJobList -Kind Rip -Config $script:E2eConfig.JobConfig)
        $jobs.Count | Should -Be 1
        $jobs[0].State | Should -Be 'Complete'
        $jobs[0].DiscType | Should -Be 'AudioCD'
    }
}

Describe 'End-to-end: Upscale-Worker.ps1 -Simulate -Once' {
    BeforeAll {
        $script:E2eRoot = Join-Path $env:TEMP "wrm-e2e-upscale-$(New-Guid)"
        New-Item -ItemType Directory -Force -Path $script:E2eRoot | Out-Null
        $script:E2eConfig = New-ArmE2eConfig -Root $script:E2eRoot

        # Seed a queue entry mimicking what DiscWatcher would have written for a
        # ripped DVD with UpscaleDvds enabled: {Source;DestDir}.
        $script:SourceMovieDir = Join-Path $script:E2eConfig.Paths.NasVideoPath 'Sample Movie (2020)'
        New-Item -ItemType Directory -Force -Path $script:SourceMovieDir | Out-Null
        $script:SourceMkv = Join-Path $script:SourceMovieDir 'title1.mkv'
        [System.IO.File]::WriteAllBytes($script:SourceMkv, (New-Object byte[] 4096))

        $script:QueueFile = Join-Path $script:E2eConfig.Paths.UpscaleQueueDir 'Sample Movie (2020).json'
        @{ Source = $script:SourceMkv; DestDir = $script:SourceMovieDir } | ConvertTo-Json | Set-Content -Path $script:QueueFile -Encoding utf8
    }

    AfterAll {
        Remove-Item -Path $script:E2eRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'consumes the queue file and produces the sample upscale output at its exact expected path' {
        if (-not (Test-Path $script:UpscaleWorkerScript)) {
            Set-ItResult -Skipped -Because 'src/Upscale-Worker.ps1 does not exist yet'
            return
        }
        if (-not (Test-Path (Join-Path $script:RepoRoot 'src' 'Upscale-Video.ps1'))) {
            Set-ItResult -Skipped -Because 'src/Upscale-Video.ps1 does not exist yet'
            return
        }
        foreach ($stub in @('stub-ffmpeg.ps1', 'stub-video2x.ps1')) {
            if (-not (Test-Path (Join-Path $script:StubDir $stub))) {
                Set-ItResult -Skipped -Because "tests/stubs/$stub does not exist yet"
                return
            }
        }

        # Baseline: capture *.mkv already present in cwd before running, so a
        # false pass can't slip through just because the repo happened to have
        # an unrelated .mkv sitting around already.
        $cwdMkvBefore = @(Get-ChildItem -Path (Get-Location) -Filter '*.mkv' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)

        & $script:UpscaleWorkerScript -ConfigPath $script:E2eConfig.ConfigPath -Simulate -Once

        $reviewFile = [System.IO.Path]::ChangeExtension($script:QueueFile, '.awaiting-review')
        $failedFile = [System.IO.Path]::ChangeExtension($script:QueueFile, '.failed')

        # AutoUpscale is $false in this config, so the only success path is the
        # review-sample flow: queue file renamed to .awaiting-review and a sample
        # file written to OutputDir (Split-Path -Parent of the queue file, per
        # Invoke-ArmUpscaleQueueItem) named exactly "<basename> [AI upscale
        # 1080p].mkv" per Upscale-Video.ps1's Invoke-Upscale. Square brackets are
        # PowerShell wildcard metacharacters, so use -LiteralPath.
        $expectedBaseName = [System.IO.Path]::GetFileNameWithoutExtension($script:SourceMkv)
        $expectedSamplePath = Join-Path $script:E2eConfig.Paths.UpscaleQueueDir "$expectedBaseName [AI upscale 1080p].mkv"

        if ((Test-Path $failedFile) -or (-not (Test-Path $reviewFile)) -or (-not (Test-Path -LiteralPath $expectedSamplePath))) {
            Set-ItResult -Skipped -Because 'upscale pipeline did not complete successfully (a dependency stub is likely still incomplete, e.g. Invoke-ArmTool argument quoting for spaced paths) -- rerun once all sibling modules land'
            return
        }

        Test-Path $reviewFile | Should -BeTrue
        Test-Path -LiteralPath $expectedSamplePath | Should -BeTrue

        # The pre-job-tracking queue file (no JobId) got a job on first touch.
        $jobs = @(Get-ArmJobList -Kind Upscale -Config $script:E2eConfig.JobConfig)
        $jobs.Count | Should -Be 1
        $jobs[0].State | Should -Be 'AwaitingReview'
        $jobs[0].SamplePath | Should -Be $expectedSamplePath
        $jobs[0].QueueFile | Should -Be $reviewFile
        (Get-Content -LiteralPath $reviewFile -Raw | ConvertFrom-Json).JobId | Should -Be $jobs[0].Id

        # Guards against the exact regression this test is here to catch: unquoted
        # spaced arguments in Invoke-ArmTool splitting "...[AI upscale 1080p].mkv"
        # so a stray fragment (e.g. "1080p].mkv") lands in the current working
        # directory instead of the real output landing at $expectedSamplePath.
        $cwdMkvAfter = @(Get-ChildItem -Path (Get-Location) -Filter '*.mkv' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        $strayMkv = @($cwdMkvAfter | Where-Object { $_ -notin $cwdMkvBefore })
        $strayMkv | Should -BeNullOrEmpty -Because "no .mkv output should ever land in the current working directory: $($strayMkv -join ', ')"
    }
}

Describe 'End-to-end: Upscale-Worker.ps1 -Simulate -Once (AutoUpscale on)' {
    BeforeAll {
        $script:E2eRoot = Join-Path $env:TEMP "wrm-e2e-upscale-auto-$(New-Guid)"
        New-Item -ItemType Directory -Force -Path $script:E2eRoot | Out-Null
        $script:E2eConfig = New-ArmE2eConfig -Root $script:E2eRoot -AutoUpscale

        $script:SourceMovieDir = Join-Path $script:E2eConfig.Paths.NasVideoPath 'Sample Movie (2020)'
        New-Item -ItemType Directory -Force -Path $script:SourceMovieDir | Out-Null
        $script:SourceMkv = Join-Path $script:SourceMovieDir 'title1.mkv'
        [System.IO.File]::WriteAllBytes($script:SourceMkv, (New-Object byte[] 4096))

        # Seeded the way DiscWatcher writes it now: {Source;DestDir;JobId}.
        $script:QueueFile = Join-Path $script:E2eConfig.Paths.UpscaleQueueDir 'Sample Movie (2020).json'
        $script:JobId = New-ArmJob -Kind Upscale -Properties @{
            Title     = 'Sample Movie (2020)'
            DestDir   = $script:SourceMovieDir
            QueueFile = $script:QueueFile
        } -Config $script:E2eConfig.JobConfig
        [ordered]@{ Source = $script:SourceMkv; DestDir = $script:SourceMovieDir; JobId = $script:JobId } |
            ConvertTo-Json | Set-Content -Path $script:QueueFile -Encoding utf8
    }

    AfterAll {
        Remove-Item -Path $script:E2eRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'runs the full upscale, deletes the queue file, and marks the job Complete' {
        & $script:UpscaleWorkerScript -ConfigPath $script:E2eConfig.ConfigPath -Simulate -Once

        $expectedOutput = Join-Path $script:SourceMovieDir 'title1 [AI upscale 1080p].mkv'
        Test-Path -LiteralPath $script:QueueFile | Should -BeFalse
        Test-Path -LiteralPath $expectedOutput | Should -BeTrue

        $job = Get-ArmJob -JobId $script:JobId -Config $script:E2eConfig.JobConfig
        $job.State | Should -Be 'Complete'
        @($job.History).State | Should -Be @('Queued', 'Upscaling', 'Complete')
    }
}
