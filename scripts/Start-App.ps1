#Requires -Version 5.1
<#
  Launch an app on one of the virtual displays created by Start-MultiScreens.ps1.

  Examples:
    .\Start-App.ps1 -Screen 2 -Package com.tencent.mm
    .\Start-App.ps1 -DisplayId 3 -Package com.android.settings -Activity .Settings
    .\Start-App.ps1 -Screen 1 -Package com.taobao.taobao -Wait
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Package,
    [int]$Screen = 1,
    [int]$DisplayId = -1,
    [string]$Activity = "",
    [string]$Serial = "",
    [switch]$Wait,
    [switch]$ForceStop
)

. "$PSScriptRoot\common.ps1"

$adb = Get-AdbPath
$serial = Get-DeviceSerial -Serial $Serial

if ($DisplayId -lt 0) {
    $screens = Read-Screens
    if ($screens.Count -eq 0) {
        throw "No run\screens.json. Start Start-MultiScreens.ps1 first, or pass -DisplayId <id>."
    }
    $match = $screens | Where-Object { $_.index -eq $Screen } | Select-Object -First 1
    if (-not $match) { throw "Screen $Screen is not in run\screens.json (1..$($screens.Count))." }
    $DisplayId = [int]$match.displayId
    if ($DisplayId -lt 0) { throw "Screen $Screen has no display id recorded." }
}

if ($ForceStop) {
    # NOTE: force-stop kills the package in the whole user, i.e. on every display.
    & $adb -s $serial shell am force-stop $Package | Out-Null
}

$amArgs = @("-s", $serial, "shell", "am", "start", "--display", "$DisplayId")
if ($Wait) { $amArgs += "-W" }
if ($Activity) {
    if ($Activity -match "/") { $amArgs += @("-n", $Activity) }
    else { $amArgs += @("-n", "$Package/$Activity") }
}
else {
    # Resolve the launcher activity explicitly: `am start -p <pkg>` fails for
    # some packages (e.g. com.android.calculator2 on Android 17).
    $resolved = (& $adb -s $serial shell cmd package resolve-activity --brief `
                    -c android.intent.category.LAUNCHER $Package 2>&1) |
                Where-Object { $_ -match "/" } | Select-Object -Last 1
    if ($resolved) {
        $amArgs += @("-n", $resolved.Trim())
    }
    else {
        $amArgs += @("-a", "android.intent.action.MAIN",
                     "-c", "android.intent.category.LAUNCHER",
                     "-p", $Package)
    }
}

$output = & $adb @amArgs 2>&1
$output | ForEach-Object { Write-Host $_ }

if (($output -join "`n") -match "Error|Exception|not found|Unable") {
    Write-Host "Launch failed. If the activity name is wrong, pass -Activity <pkg/.Activity> or check with:" -ForegroundColor Yellow
    Write-Host ("  adb -s {0} shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER {1}" -f $serial, $Package)
    exit 1
}
