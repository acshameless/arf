#Requires -Version 5.1
# Close every scrcpy window started by Start-MultiScreens.ps1 and clean up.
param([switch]$Force)

. "$PSScriptRoot\common.ps1"

$screens = Read-Screens
if ($screens.Count -eq 0) {
    Write-Host "Nothing recorded in run\screens.json."
    return
}

foreach ($s in $screens) {
    $proc = Get-Process -Id $s.pid -ErrorAction SilentlyContinue
    if ($proc) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Write-Host ("stopped screen {0} (display {1}, pid {2})" -f $s.index, $s.displayId, $s.pid)
    }
    else {
        Write-Host ("screen {0}: pid {1} already gone" -f $s.index, $s.pid)
    }
}

Remove-Item (Join-Path $script:Root "run\screens.json") -Force -ErrorAction SilentlyContinue
Write-Host "Done. Virtual displays are destroyed when scrcpy exits."
