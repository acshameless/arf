#Requires -Version 5.1
# List every display the phone currently knows about, then show the mapping
# recorded by Start-MultiScreens.ps1 (if any).
param([string]$Serial = "")

. "$PSScriptRoot\common.ps1"

$serial = Get-DeviceSerial -Serial $Serial
$displays = Get-Displays -Serial $serial

$displays | Format-Table Id, Type, State, Width, Height, Name -AutoSize

$screens = Read-Screens
if ($screens.Count -gt 0) {
    Write-Host "Screens recorded by Start-MultiScreens.ps1:" -ForegroundColor Cyan
    $screens |
        Select-Object index, displayId, package, pid |
        Format-Table -AutoSize
}
