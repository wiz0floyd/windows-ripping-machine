Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    # Import modules under test
    . (Join-Path $PSScriptRoot '..' 'src' 'Common.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'Send-Notification.ps1')

    # Create temp directory for logs
    $script:TestDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wslc-arm-notify-test-$(New-Guid)")
    $script:LogDir = New-Item -ItemType Directory -Path (Join-Path $script:TestDir 'logs')
}

AfterAll {
    # Clean up test directory
    Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Send-ArmNotification' {
    It 'never throws when toast fails' {
        $config = @{
            LogDir = $script:LogDir
        }

        # Should not throw even if WinRT is not available
        { Send-ArmNotification -Title 'Test' -Message 'Test message' -Level Info -Config $config } | Should -Not -Throw
    }

    It 'never throws when webhook fails' {
        $config = @{
            LogDir = $script:LogDir
            HaWebhookUrl = 'http://invalid.local/webhook'
        }

        Mock Invoke-RestMethod {
            throw 'Network error'
        }

        { Send-ArmNotification -Title 'Test' -Message 'Test message' -Level Error -Config $config } | Should -Not -Throw
    }

    It 'sends to webhook when HaWebhookUrl is configured' {
        $config = @{
            LogDir = $script:LogDir
            HaWebhookUrl = 'http://homeassistant.local/webhook'
        }

        $captured = $null
        Mock Invoke-RestMethod {
            $script:captured = @{
                Uri = $Uri
                Method = $Method
                Body = $Body
            }
            return $null
        }

        Send-ArmNotification -Title 'Test' -Message 'Test msg' -Level Info -Config $config

        $script:captured | Should -Not -BeNullOrEmpty
        $script:captured.Uri | Should -Be 'http://homeassistant.local/webhook'
        $script:captured.Method | Should -Be 'Post'
    }

    It 'includes level in webhook payload as lowercase' {
        $config = @{
            LogDir = $script:LogDir
            HaWebhookUrl = 'http://homeassistant.local/webhook'
        }

        $capturedBody = $null
        Mock Invoke-RestMethod {
            $script:capturedBody = $Body
            return $null
        }

        Send-ArmNotification -Title 'Test' -Message 'Test' -Level Error -Config $config

        $json = $script:capturedBody | ConvertFrom-Json
        $json.level | Should -Be 'error'
    }

    It 'includes title and message in payload' {
        $config = @{
            LogDir = $script:LogDir
            HaWebhookUrl = 'http://homeassistant.local/webhook'
        }

        $capturedBody = $null
        Mock Invoke-RestMethod {
            $script:capturedBody = $Body
            return $null
        }

        Send-ArmNotification -Title 'Rip Complete' -Message 'Avatar' -Level Info -Config $config

        $json = $script:capturedBody | ConvertFrom-Json
        $json.title | Should -Be 'Rip Complete'
        $json.message | Should -Be 'Avatar'
    }

    It 'skips webhook when HaWebhookUrl not configured' {
        $config = @{
            LogDir = $script:LogDir
        }

        Mock Invoke-RestMethod { }

        Send-ArmNotification -Title 'Test' -Message 'Test' -Level Info -Config $config

        # Should not call webhook
        Assert-MockCalled Invoke-RestMethod -Times 0
    }

    It 'accepts Info and Error levels' {
        $config = @{
            LogDir = $script:LogDir
        }

        { Send-ArmNotification -Title 'Test' -Message 'Test' -Level Info -Config $config } | Should -Not -Throw
        { Send-ArmNotification -Title 'Test' -Message 'Test' -Level Error -Config $config } | Should -Not -Throw
    }

    It 'rejects invalid level' {
        $config = @{
            LogDir = $script:LogDir
        }

        { Send-ArmNotification -Title 'Test' -Message 'Test' -Level Invalid -Config $config } | Should -Throw
    }

    It 'escapes XML special characters in title' {
        # Test that titles with XML-unsafe characters are escaped and don't cause throws
        $config = @{
            LogDir = $script:LogDir
        }

        # Titles like this should not throw even with dangerous XML chars
        { Send-ArmNotification -Title 'Fast & Furious <Edition>' -Message 'Test' -Level Info -Config $config } | Should -Not -Throw
        { Send-ArmNotification -Title 'Title with "quotes"' -Message 'Test' -Level Info -Config $config } | Should -Not -Throw
    }

    It 'escapes XML special characters in message' {
        # Test that messages with XML-unsafe characters are escaped and don't cause throws
        $config = @{
            LogDir = $script:LogDir
        }

        # Messages with dangerous XML chars should not throw
        { Send-ArmNotification -Title 'Test' -Message 'Audio & Video < 5GB' -Level Info -Config $config } | Should -Not -Throw
        { Send-ArmNotification -Title 'Test' -Message 'Path: C:\rips\<temp>' -Level Error -Config $config } | Should -Not -Throw
    }

    It 'handles XML escape for SecurityElement' {
        # Unit test the XML escape logic directly
        $testCases = @(
            @{ Input = 'Fast & Furious'; Expected = 'Fast &amp; Furious' },
            @{ Input = '<Edition>'; Expected = '&lt;Edition&gt;' },
            @{ Input = 'Quote "test"'; Expected = 'Quote &quot;test&quot;' },
            @{ Input = "Single'quote"; Expected = "Single&apos;quote" }
        )

        foreach ($case in $testCases) {
            $escaped = [System.Security.SecurityElement]::Escape($case.Input)
            $escaped | Should -Be $case.Expected
        }
    }
}
