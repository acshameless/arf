#Requires -Version 5.1
# Print adb/scrcpy/device information and warn about anything that will break
# virtual displays (Android < 12, unauthorized device, MIUI caveats).
param([string]$Serial = "")

. "$PSScriptRoot\common.ps1"

Write-Host "== tools ==" -ForegroundColor Cyan
$adb = Get-AdbPath
$scrcpy = Get-ScrcpyPath
Write-Host "adb    : $adb"
& $adb version | Select-Object -First 2 | ForEach-Object { Write-Host "         $_" }
Write-Host "scrcpy : $scrcpy"
(& $scrcpy --version | Select-Object -First 1) | ForEach-Object { Write-Host "         $_" }

Write-Host ""
Write-Host "== adb devices ==" -ForegroundColor Cyan
& $adb devices -l | ForEach-Object { Write-Host $_ }

try {
    $serial = Get-DeviceSerial -Serial $Serial
}
catch {
    Write-Host ""
    Write-Host $_.Exception.Message -ForegroundColor Red
    return
}

Write-Host ""
Write-Host "== device $serial ==" -ForegroundColor Cyan
$model   = (& $adb -s $serial shell getprop ro.product.model).Trim()
$release = (& $adb -s $serial shell getprop ro.build.version.release).Trim()
$sdk     = (& $adb -s $serial shell getprop ro.build.version.sdk).Trim()
$miui    = (& $adb -s $serial shell getprop ro.miui.ui.version.name).Trim()
Write-Host ("model   : {0}" -f $model)
Write-Host ("android : {0} (SDK {1})" -f $release, $sdk)
if ($miui) { Write-Host ("miui    : {0}" -f $miui) }

if ([int]$sdk -lt 31) {
    Write-Host ""
    Write-Host "Android 12 (SDK 31) or newer is required for --new-display." -ForegroundColor Red
    Write-Host "This device reports SDK $sdk - virtual displays will not work here." -ForegroundColor Red
}
else {
    Write-Host ""
    Write-Host "OK: Android 12+, virtual displays are supported." -ForegroundColor Green
}

$displays = Get-Displays -Serial $serial
Write-Host ""
Write-Host "== displays ==" -ForegroundColor Cyan
$displays | Format-Table Id, Type, State, Width, Height, Name -AutoSize
