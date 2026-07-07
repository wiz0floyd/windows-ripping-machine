Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    # Dot-source only: setup.ps1's entry-point block is guarded on
    # $MyInvocation.InvocationName -ne '.', so this never installs software,
    # writes config, or touches Scheduled Tasks.
    . (Join-Path $PSScriptRoot '..' 'setup.ps1')
}

Describe 'Test-WingetPackageInstalled' {
    It 'returns true when winget list finds the id and exits 0' {
        Mock winget {
            $global:LASTEXITCODE = 0
            'Name     Id                   Version'
            'MakeMKV  GuinpinSoft.MakeMKV  1.17.2'
        }

        Test-WingetPackageInstalled -Id 'GuinpinSoft.MakeMKV' | Should -BeTrue
    }

    It 'returns false when winget list does not find the id' {
        Mock winget {
            $global:LASTEXITCODE = 0
            'No installed package found matching input criteria.'
        }

        Test-WingetPackageInstalled -Id 'GuinpinSoft.MakeMKV' | Should -BeFalse
    }

    It 'returns false when winget exits non-zero' {
        Mock winget {
            $global:LASTEXITCODE = 1
        }

        Test-WingetPackageInstalled -Id 'GuinpinSoft.MakeMKV' | Should -BeFalse
    }
}

Describe 'Install-WingetPackage' {
    It 'skips installation when already installed' {
        Mock Test-WingetPackageInstalled { $true }
        Mock winget { }

        Install-WingetPackage -Id 'GuinpinSoft.MakeMKV' -DisplayName 'MakeMKV'

        Should -Invoke Test-WingetPackageInstalled -Times 1
    }

    It 'invokes winget install when not already installed' {
        Mock Test-WingetPackageInstalled { $false }
        Mock winget { $global:LASTEXITCODE = 0 }

        Install-WingetPackage -Id 'enzo1982.freac' -DisplayName 'fre:ac'

        Should -Invoke Test-WingetPackageInstalled -Times 1
        Should -Invoke winget -Times 1
    }
}

Describe 'Initialize-ArmDirectories' {
    It 'creates missing directories and leaves existing ones alone' {
        $root = Join-Path $TestDrive (New-Guid)
        $existing = Join-Path $root 'already-there'
        New-Item -ItemType Directory -Force -Path $existing | Out-Null

        Initialize-ArmDirectories -Paths @{
            StagingDir      = Join-Path $root 'staging'
            UpscaleQueueDir = $existing
            LogDir          = Join-Path $root 'logs'
        }

        Test-Path (Join-Path $root 'staging') | Should -BeTrue
        Test-Path (Join-Path $root 'logs') | Should -BeTrue
        Test-Path $existing | Should -BeTrue
    }

    It 'is idempotent when run twice' {
        $root = Join-Path $TestDrive (New-Guid)
        $paths = @{ StagingDir = Join-Path $root 'a'; UpscaleQueueDir = Join-Path $root 'b'; LogDir = Join-Path $root 'c' }

        { Initialize-ArmDirectories -Paths $paths } | Should -Not -Throw
        { Initialize-ArmDirectories -Paths $paths } | Should -Not -Throw
        Test-Path $paths.StagingDir | Should -BeTrue
    }
}

Describe 'New-ArmConfigFile' {
    BeforeAll {
        $script:ExamplePath = Join-Path $PSScriptRoot '..' 'config' 'config.example.psd1'
    }

    It 'copies the example verbatim with -NonInteractive' {
        $out = Join-Path $TestDrive "$(New-Guid).psd1"
        New-ArmConfigFile -ExamplePath $script:ExamplePath -OutputPath $out -NonInteractive

        $config = Import-PowerShellDataFile -Path $out
        $config.NasVideoPath | Should -Be '\\nas\media\import\movies'
    }

    It 'substitutes supplied values without prompting when all params are given' {
        $out = Join-Path $TestDrive "$(New-Guid).psd1"
        New-ArmConfigFile -ExamplePath $script:ExamplePath -OutputPath $out `
            -NasVideoPath '\\myserver\movies' -NasMusicPath '\\myserver\music' `
            -TmdbApiKey 'abc123' -HaWebhookUrl 'http://ha.local/hook'

        $config = Import-PowerShellDataFile -Path $out
        $config.NasVideoPath | Should -Be '\\myserver\movies'
        $config.NasMusicPath | Should -Be '\\myserver\music'
        $config.TmdbApiKey | Should -Be 'abc123'
        $config.HaWebhookUrl | Should -Be 'http://ha.local/hook'
        # Untouched keys survive the substitution.
        $config.StagingDir | Should -Be 'C:\rips\staging'
    }

    It 'accepts explicit blank TmdbApiKey/HaWebhookUrl without prompting' {
        $out = Join-Path $TestDrive "$(New-Guid).psd1"
        New-ArmConfigFile -ExamplePath $script:ExamplePath -OutputPath $out `
            -NasVideoPath '\\s\v' -NasMusicPath '\\s\m' -TmdbApiKey '' -HaWebhookUrl ''

        $config = Import-PowerShellDataFile -Path $out
        $config.TmdbApiKey | Should -Be ''
        $config.HaWebhookUrl | Should -Be ''
    }
}

Describe 'Test-NonInteractiveSession' {
    BeforeEach {
        $script:origSshConnection = $env:SSH_CONNECTION
        $script:origSshClient = $env:SSH_CLIENT
        $script:origSshTty = $env:SSH_TTY
        $script:origSessionName = $env:SESSIONNAME
        $env:SSH_CONNECTION = $null
        $env:SSH_CLIENT = $null
        $env:SSH_TTY = $null
        $env:SESSIONNAME = 'Console'

        # Default to "interactive" so each test only has to override the one
        # signal it's exercising.
        Mock Get-ArmIsUserInteractive { $true }
    }

    AfterEach {
        $env:SSH_CONNECTION = $script:origSshConnection
        $env:SSH_CLIENT = $script:origSshClient
        $env:SSH_TTY = $script:origSshTty
        $env:SESSIONNAME = $script:origSessionName
    }

    It 'returns false for a normal local interactive console session' {
        Test-NonInteractiveSession | Should -BeFalse
    }

    It 'returns false for an RDP session' {
        $env:SESSIONNAME = 'RDP-Tcp#3'
        Test-NonInteractiveSession | Should -BeFalse
    }

    It 'returns true when SSH_CONNECTION is set' {
        $env:SSH_CONNECTION = '10.0.0.1 1234 10.0.0.2 22'
        Test-NonInteractiveSession | Should -BeTrue
    }

    It 'returns true when SSH_CLIENT is set' {
        $env:SSH_CLIENT = '10.0.0.1 1234 22'
        Test-NonInteractiveSession | Should -BeTrue
    }

    It 'returns true when SSH_TTY is set' {
        $env:SSH_TTY = '/dev/pts/0'
        Test-NonInteractiveSession | Should -BeTrue
    }

    It 'returns true when Get-ArmIsUserInteractive is false (service/SYSTEM context)' {
        Mock Get-ArmIsUserInteractive { $false }
        Test-NonInteractiveSession | Should -BeTrue
    }

    It 'returns true when SESSIONNAME is absent (typical WinRM/PSRemoting)' {
        $env:SESSIONNAME = $null
        Test-NonInteractiveSession | Should -BeTrue
    }

    It 'returns true when SESSIONNAME is Services-prefixed' {
        $env:SESSIONNAME = 'Services'
        Test-NonInteractiveSession | Should -BeTrue
    }

    It 'returns true when SESSIONNAME is RemoteControl-prefixed' {
        $env:SESSIONNAME = 'RemoteControl'
        Test-NonInteractiveSession | Should -BeTrue
    }
}

Describe 'Register-ArmScheduledTask / Unregister-ArmScheduledTask' {
    It 'skips registration when the task already exists' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'wrm-watcher' } }
        Mock New-ScheduledTaskAction { }
        Mock Register-ScheduledTask { }

        Register-ArmScheduledTask -TaskName 'wrm-watcher' -ScriptPath 'C:\dev\src\DiscWatcher.ps1'

        Should -Invoke Register-ScheduledTask -Times 0
    }

    It 'registers a hidden at-logon task when absent' {
        # New-Scheduled* cmdlets are pure, side-effect-free object constructors
        # (they don't touch the Task Scheduler), so let them run for real rather
        # than mocking them: their return types are typed to ScheduledTasks module
        # classes (e.g. CimInstance[]), and a Pester mock's proxy still validates
        # arguments against the real parameter metadata, so a fake/$null return
        # value would fail type/ValidateNotNull binding on the next call anyway.
        # Only mock the cmdlets that actually mutate system state.
        Mock Get-ScheduledTask { $null }
        Mock Register-ScheduledTask { }

        Register-ArmScheduledTask -TaskName 'wrm-upscaler' -ScriptPath 'C:\dev\src\Upscale-Worker.ps1'

        Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
            $Action.Execute -eq 'pwsh.exe' -and $Action.Arguments -match 'Hidden' -and $Action.Arguments -match 'Upscale-Worker\.ps1'
        }
    }

    It 'defaults the task principal to the current env user when -RunAsUser is not supplied' {
        Mock Get-ScheduledTask { $null }
        Mock Register-ScheduledTask { }

        Register-ArmScheduledTask -TaskName 'wrm-watcher' -ScriptPath 'C:\dev\src\DiscWatcher.ps1'

        Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
            $Principal.UserId -eq "$env:USERDOMAIN\$env:USERNAME"
        }
    }

    It 'uses the explicitly supplied -RunAsUser for the task principal' {
        Mock Get-ScheduledTask { $null }
        Mock Register-ScheduledTask { }

        Register-ArmScheduledTask -TaskName 'wrm-watcher' -ScriptPath 'C:\dev\src\DiscWatcher.ps1' -RunAsUser 'CONTOSO\originaluser'

        Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
            $Principal.UserId -eq 'CONTOSO\originaluser'
        }
    }

    It 'unregisters an existing task' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'wrm-watcher' } }
        Mock Unregister-ScheduledTask { }

        Unregister-ArmScheduledTask -TaskName 'wrm-watcher'

        Should -Invoke Unregister-ScheduledTask -Times 1
    }

    It 'no-ops unregistering a task that does not exist' {
        Mock Get-ScheduledTask { $null }
        Mock Unregister-ScheduledTask { }

        Unregister-ArmScheduledTask -TaskName 'wrm-nonexistent'

        Should -Invoke Unregister-ScheduledTask -Times 0
    }
}

Describe 'Invoke-ArmElevatedRelaunch' {
    It 'does not throw when the elevated child exits 0' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

        { Invoke-ArmElevatedRelaunch -ArgumentList @('-NoProfile', '-File', 'C:\dev\setup.ps1') } | Should -Not -Throw

        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            $FilePath -eq 'pwsh.exe' -and $Verb -eq 'RunAs' -and $Wait -eq $true -and $PassThru -eq $true
        }
    }

    It 'throws a clear, actionable error when the elevated child exits non-zero' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 1 } }

        { Invoke-ArmElevatedRelaunch -ArgumentList @('-NoProfile', '-File', 'C:\dev\setup.ps1') } |
            Should -Throw -ExpectedMessage '*exit code 1*'
    }
}
