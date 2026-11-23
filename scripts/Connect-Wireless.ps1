#Requires -Version 5.1
<#
  Pair and connect to the phone over "Wireless debugging" (no USB cable).

  On the phone (LineageOS / Android 11+):
    Settings -> System -> Developer options -> Wireless debugging -> ON
    Tap "Pair device with pairing code" and read:
      - the IP address and port shown on that dialog
      - the 6-digit pairing code

  Then run:
    .\Connect-Wireless.ps1 -PairAddress 192.168.31.50:37123 -PairCode 123456

  After pairing, the script finds the _adb-tls-connect._tcp mDNS service and
  runs `adb connect` for you (or use -ConnectAddress ip:port explicitly).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PairAddress,
    [Parameter(Mandatory = $true)][string]$PairCode,
    [string]$ConnectAddress = ""
)

. "$PSScriptRoot\common.ps1"

$adb = Get-AdbPath

Write-Host "Pairing with $PairAddress ..." -ForegroundColor Cyan
$pairOut = & $adb pair $PairAddress $PairCode 2>&1
$pairOut | ForEach-Object { Write-Host $_ }
if (($pairOut -join "`n") -notmatch "Successfully paired") {
    Write-Host "Pairing failed. Check the IP:port and the 6-digit code on the phone's pairing dialog (it changes every time the dialog opens)." -ForegroundColor Red
    exit 1
}

Start-Sleep -Seconds 1

$target = $ConnectAddress
if (-not $target) {
    Write-Host "Looking up the wireless debugging endpoint via mDNS ..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds(20)
    while (-not $target -and (Get-Date) -lt $deadline) {
        $mdns = & $adb mdns services 2>&1
        foreach ($line in $mdns) {
            if ($line -match '_adb-tls-connect\._tcp\s+(\S+:\d+)') {
                $target = $matches[1]
                break
            }
        }
        if (-not $target) { Start-Sleep -Seconds 2 }
    }
}

if (-not $target) {
    Write-Host "Could not find the connect endpoint automatically." -ForegroundColor Yellow
    Write-Host "Look at the 'IP address & Port' line on the Wireless debugging screen and run:" -ForegroundColor Yellow
    Write-Host ("  .\Connect-Wireless.ps1 -PairAddress {0} -PairCode <code> -ConnectAddress <ip:port>" -f $PairAddress)
    exit 1
}

Write-Host "Connecting to $target ..." -ForegroundColor Cyan
& $adb connect $target | ForEach-Object { Write-Host $_ }

Start-Sleep -Seconds 1
& $adb devices -l | ForEach-Object { Write-Host $_ }

$serial = Get-DeviceSerial
Write-Host ""
Write-Host "Ready. Device serial: $serial" -ForegroundColor Green
Write-Host "Note: over Wi-Fi use -Fps 24 and keep the phone on its charger for long sessions." -ForegroundColor DarkGray
