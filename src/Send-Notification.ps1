Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Send a Windows toast notification and optional Home Assistant webhook.

.DESCRIPTION
    Sends a Windows toast notification via WinRT (invokes Windows PowerShell out-of-process).
    If HaWebhookUrl is configured, also POSTs a JSON notification to the webhook
    with a 5-second timeout. Failures are caught and logged as WARN only;
    notification failures must never cause the pipeline to fail.

.PARAMETER Title
    Notification title (automatically XML-escaped).

.PARAMETER Message
    Notification message body (automatically XML-escaped).

.PARAMETER Level
    Severity level: Info or Error. Controls toast appearance and HA payload.

.PARAMETER Config
    Configuration hashtable (for HaWebhookUrl).

.EXAMPLE
    Send-ArmNotification -Title "Rip Complete" -Message "Avatar (2009)" -Level Info -Config $config
#>
function Send-ArmNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Title,

        [Parameter(Mandatory = $true)]
        [string] $Message,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Info', 'Error')]
        [string] $Level,

        [Parameter(Mandatory = $true)]
        [hashtable] $Config
    )

    # Send Windows toast via out-of-process Windows PowerShell
    # (PowerShell 7 doesn't support WinRT accelerator syntax)
    try {
        # Escape XML special characters in title and message
        $escapedTitle = [System.Security.SecurityElement]::Escape($Title)
        $escapedMessage = [System.Security.SecurityElement]::Escape($Message)

        $scenario = if ($Level -eq 'Error') { 'reminder' } else { 'default' }

        # Use registered Windows PowerShell AUMID for toast
        # '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $aumId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

        # Build the toast script to run in Windows PowerShell
        $toastXmlContent = @"
<toast scenario="$scenario">
    <visual>
        <binding template="ToastText02">
            <text id="1">$escapedTitle</text>
            <text id="2">$escapedMessage</text>
        </binding>
    </visual>
</toast>
"@

        $toastScript = @"
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > `$null
[Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] > `$null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > `$null
`$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
`$xml.LoadXml(@'
$toastXmlContent
'@)
`$toast = New-Object Windows.UI.Notifications.ToastNotification `$xml
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('$aumId').Show(`$toast)
"@

        # Invoke Windows PowerShell to display the toast
        & powershell.exe -NoProfile -Command $toastScript 2>$null
    } catch {
        Write-ArmLog -Level WARN -Message "Failed to send Windows toast: $_" -Config $Config
    }

    # Send to Home Assistant webhook if configured
    if ($Config -and $Config.ContainsKey('HaWebhookUrl') -and $Config.HaWebhookUrl) {
        try {
            $payload = @{
                title   = $Title
                message = $Message
                level   = $Level.ToLower()
            } | ConvertTo-Json

            Invoke-RestMethod -Uri $Config.HaWebhookUrl -Method Post -Body $payload `
                -ContentType 'application/json' -TimeoutSec 5 -ErrorAction Stop | Out-Null
        } catch {
            Write-ArmLog -Level WARN -Message "Failed to POST to HA webhook: $_" -Config $Config
        }
    }
}
