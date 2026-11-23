#Requires -Version 5.1
<#
  Start N scrcpy windows, each mirroring its own NEW virtual display on the
  same physical phone (requires Android 12+ and scrcpy >= 2.4; this kit ships
  scrcpy 5.0.1).

  Example:
    .\Start-MultiScreens.ps1 -Count 3 -Apps com.android.settings,com.tencent.mm,com.taobao.taobao

  Each virtual display is created for the lifetime of its scrcpy process and is
  destroyed when that window closes.
#>
[CmdletBinding()]
param(
    [int]$Count = 3,
    [int]$Width = 720,
    [int]$Height = 1600,
    [int]$Dpi = 320,
    [string[]]$Apps = @(),
    [string]$Serial = "",
    [int]$WindowWidth = 0,
    [int]$WindowHeight = 0,
    [int]$Fps = 30,
    [int]$BasePort = 27183,
    [switch]$Audio,
    [switch]$KeepActive,
    [switch]$KeepApps,
    [switch]$NoDecorations,
    [switch]$DryRun
)

. "$PSScriptRoot\common.ps1"

if ($Count -lt 1 -or $Count -gt 9) { throw "Count must be between 1 and 9." }

# Must run before WinForms is loaded so Screen.WorkingArea is in physical pixels.
Enable-DpiAwareness

# `powershell -File script.ps1 -Apps a,b,c` passes one string, so normalize.
if ($Apps.Count -eq 1 -and $Apps[0] -match ",") {
    $Apps = @($Apps[0] -split "\s*,\s*" | Where-Object { $_ })
}

$adb = Get-AdbPath
$scrcpy = Get-ScrcpyPath
$serial = Get-DeviceSerial -Serial $Serial

# ---- window layout ---------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
$gap = 8
$cols = [Math]::Min($Count, 3)
$rows = [int][Math]::Ceiling($Count / $cols)
$work = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

if ($WindowHeight -le 0) { $WindowHeight = [int](($work.Height - $gap * ($rows + 1)) / $rows) }
if ($WindowWidth -le 0) { $WindowWidth = [int]($WindowHeight * ($Width / $Height)) }

$maxTileWidth = [int](($work.Width - $gap * ($cols + 1)) / $cols)
if ($WindowWidth -gt $maxTileWidth) {
    $WindowWidth = $maxTileWidth
    $WindowHeight = [int]($WindowWidth * ($Height / $Width))
}

$totalWidth = $cols * $WindowWidth + $gap * ($cols - 1)
$startX = $work.X + [int](($work.Width - $totalWidth) / 2)
$startY = $work.Y + $gap

Write-Host ("Device {0}: {1} virtual display(s) of {2}x{3} @ {4} dpi" -f $serial, $Count, $Width, $Height, $Dpi) -ForegroundColor Cyan
Write-Host ("Window tile: {0}x{1}, {2} column(s)" -f $WindowWidth, $WindowHeight, $cols) -ForegroundColor Cyan

# ---- baseline displays so we can tell which one is new --------------------
$known = @{}
foreach ($d in (Get-Displays -Serial $serial)) { $known[[int]$d.Id] = $true }

$runDir = Join-Path $script:Root "run"
$logDir = Join-Path $runDir "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$records = New-Object System.Collections.Generic.List[object]
$processes = New-Object System.Collections.Generic.List[System.Diagnostics.Process]

for ($i = 0; $i -lt $Count; $i++) {
    $col = $i % $cols
    $rowIndex = [int][Math]::Floor($i / $cols)
    $x = $startX + $col * ($WindowWidth + $gap)
    $y = $startY + $rowIndex * ($WindowHeight + $gap)
    $title = "K40-S$($i + 1)"

    $cmdArgs = @(
        "-s", $serial,
        "--new-display=${Width}x${Height}/${Dpi}",
        "--window-title=K40-S$($i + 1)",
        "--window-x=$x",
        "--window-y=$y",
        "--window-width=$WindowWidth",
        "--window-height=$WindowHeight",
        "--max-fps=$Fps",
        "--port=$($BasePort + $i)"
    )
    if ($KeepActive) { $cmdArgs += "--keep-active" }
    if ($KeepApps) { $cmdArgs += "--no-vd-destroy-content" }
    if ($NoDecorations) { $cmdArgs += "--no-vd-system-decorations" }
    if (-not ($Audio -and $i -eq 0)) { $cmdArgs += "--no-audio" }

    $app = $null
    if ($i -lt $Apps.Count -and $Apps[$i]) {
        $app = $Apps[$i]
        $cmdArgs += "--start-app=$app"
    }

    if ($DryRun) {
        Write-Host ("[dry-run] `"{0}`" {1}" -f $scrcpy, ($cmdArgs -join " "))
        continue
    }

    $stdout = Join-Path $logDir ("screen{0}.out.log" -f ($i + 1))
    $stderr = Join-Path $logDir ("screen{0}.err.log" -f ($i + 1))
    # -NoNewWindow: without it Start-Process gives scrcpy a console window that
    # covers the tiled scrcpy windows (blank white window titled scrcpy.exe).
    $proc = Start-Process -FilePath $scrcpy -ArgumentList $cmdArgs -PassThru -NoNewWindow `
                          -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $processes.Add($proc)

    # Wait for this instance's display to show up. Starting them one by one
    # keeps the index -> display id mapping deterministic.
    $deadline = (Get-Date).AddSeconds(25)
    $newId = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 600
        $proc.Refresh()
        if ($proc.HasExited) { break }
        foreach ($d in (Get-Displays -Serial $serial)) {
            if (-not $known.ContainsKey([int]$d.Id)) { $newId = [int]$d.Id; break }
        }
        if ($null -ne $newId) { break }
    }

    if ($proc.HasExited) {
        $tail = ""
        if (Test-Path $stderr) { $tail = ((Get-Content $stderr -Tail 30) -join "`n").Trim() }
        Write-Host ("scrcpy for screen {0} exited early (code {1}). Log: {2}" -f ($i + 1), $proc.ExitCode, $stderr) -ForegroundColor Red
        if ($tail) { Write-Host $tail -ForegroundColor DarkGray }
        foreach ($p in $processes) {
            if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        }
        throw "Aborted. Most common causes: Android < 12 (no virtual displays), USB debugging revoked, or TCP port $($BasePort + $i) already in use."
    }

    if ($null -eq $newId) {
        Write-Host ("Screen {0}: scrcpy is running but no new display appeared. Continuing anyway." -f ($i + 1)) -ForegroundColor Yellow
    }
    else {
        $known[$newId] = $true
    }

    # scrcpy positions the client area, so decorations + DPI scaling shift and
    # shrink the window. Force the outer rectangle onto its tile instead.
    $hwnd = [IntPtr]::Zero
    $hwndDeadline = (Get-Date).AddSeconds(6)
    while ($hwnd -eq [IntPtr]::Zero -and (Get-Date) -lt $hwndDeadline) {
        $hwnd = [Dsh.Native]::FindWindow([uint32]$proc.Id, $title)
        if ($hwnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
    }
    if ($hwnd -ne [IntPtr]::Zero) {
        [void][Dsh.Native]::SetWindowPos($hwnd, [IntPtr]::Zero, $x, $y, $WindowWidth, $WindowHeight, 0x0014)
    }
    else {
        Write-Host ("Screen {0}: window '{1}' not found for tiling." -f ($i + 1), $title) -ForegroundColor DarkYellow
    }

    $records.Add([pscustomobject]@{
        index     = $i + 1
        displayId = if ($null -ne $newId) { $newId } else { -1 }
        package   = $app
        pid       = $proc.Id
    })
}

if ($DryRun) { return }

# NOTE: @() around a generic List throws in Windows PowerShell 5.1,
# so cast the array explicitly.
$json = ConvertTo-Json -InputObject ([object[]]$records.ToArray()) -Depth 4
Set-Content -Path (Join-Path $runDir "screens.json") -Value $json -Encoding UTF8

Write-Host ""
$records | Select-Object index, displayId, package, pid | Format-Table -AutoSize

$first = $records | Where-Object { $_.displayId -ge 0 } | Select-Object -First 1
if ($first) {
    Write-Host "ADB examples for this session:" -ForegroundColor Cyan
    Write-Host ("  adb -s {0} shell am start --display {1} -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p com.android.settings" -f $serial, $first.displayId)
    Write-Host ("  adb -s {0} shell input -d {1} tap 360 800" -f $serial, $first.displayId)
}
Write-Host ""
Write-Host "Open an app on a screen with:  .\Start-App.ps1 -Screen 2 -Package com.tencent.mm" -ForegroundColor Cyan
Write-Host "Stop them all with:            .\Stop-MultiScreens.ps1" -ForegroundColor Cyan
