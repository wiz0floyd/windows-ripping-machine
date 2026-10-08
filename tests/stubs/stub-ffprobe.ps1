# Simulated ffprobe for Simulate=$true runs. Invoked out-of-process by
# Invoke-ArmTool (Common.ps1) as `pwsh -NoProfile -File stub-ffprobe.ps1 <args>`.
#   - no param() block (short flags collide with PowerShell common parameters);
#     read the automatic $args array instead.
#   - write to the real stdout stream and signal failure via exit code.
#
# Every probe prints the same recorded fixture: the real `ffprobe -of json` output
# for a MakeMKV DVD rip (mpeg2video 720x480, SAR 853:720 / DAR 853:480, smpte170m,
# 29.97 header rate, 5 audio + 4 subtitle streams). Never touches the input file.

$fixturePath = Join-Path $PSScriptRoot '..' 'fixtures' 'ffprobe-dvd-source.json'
Get-Content -Path $fixturePath | ForEach-Object { [Console]::Out.WriteLine($_) }
exit 0
