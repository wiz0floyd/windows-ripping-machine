<#
.SYNOPSIS
    Shared helpers for Pester tests (dot-source; not a test file).
#>

if (-not ('WrmTest.NativePath' -as [type])) {
    Add-Type -Namespace WrmTest -Name NativePath -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern uint GetLongPathName(string shortPath, System.Text.StringBuilder longPath, uint bufferLength);
'@
}

<#
.SYNOPSIS
    Expand an existing path to its canonical long form.

.DESCRIPTION
    CI runners set %TEMP% to an 8.3 short path (C:\Users\RUNNER~1\...), and
    whether a path built from it stays short depends on which process and API
    produced it. Compare paths from different sources only after passing both
    through this. Paths that don't exist are returned unchanged.
#>
function ConvertTo-ArmLongPath {
    param(
        [AllowNull()]
        [string] $Path
    )

    if (-not $Path) {
        return $Path
    }
    $buffer = [System.Text.StringBuilder]::new(1024)
    $length = [WrmTest.NativePath]::GetLongPathName($Path, $buffer, [uint32] $buffer.Capacity)
    if ($length -eq 0 -or $length -gt $buffer.Capacity) {
        return $Path
    }
    return $buffer.ToString()
}
