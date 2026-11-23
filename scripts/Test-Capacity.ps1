#Requires -Version 5.1
<#
  Capacity test: add one virtual screen at a time, each with a DIFFERENT app,
  until something breaks. Reports per-screen CPU / memory / focused activity
  and the maximum number that stayed healthy.

  Examples:
    .\Test-Capacity.ps1 -Max 10
    .\Test-Capacity.ps1 -Max 8 -Apps com.android.settings,com.android.chrome,com.tencent.mm
    .\Test-Capacity.ps1 -Max 10 -LeaveOpen

  The windows are tiled for the maximum count up front, so adding screens does
  not shuffle the existing ones.
#>
[CmdletBinding()]
param(
    [int]$Max = 10,
    [string[]]$Apps = @(),
    [int]$Width = 720,
    [int]$Height = 1600,
    [int]$Dpi = 320,
    [int]$Fps = 30,
    [string]$Serial = "",
    [int]$BasePort = 27183,
    [int]$Settle = 3,
    [switch]$LeaveOpen
)

. "$PSScriptRoot\common.ps1"

if ($Max -lt 1 -or $Max -gt 20) { throw "Max must be between 1 and 20." }

Enable-DpiAwareness

$adb = Get-AdbPath
$scrcpy = Get-ScrcpyPath
$serial = Get-DeviceSerial -Serial $Serial

if ($Apps.Count -eq 1 -and $Apps[0] -match ",") {
    $Apps = @($Apps[0] -split "\s*,\s*" | Where-Object { $_ })
}
if ($Apps.Count -eq 0) {
    $Apps = @(
        "com.android.settings", "com.android.deskclock", "com.android.calculator2",
        "com.android.contacts", "com.android.dialer", "com.android.calendar",
        "org.lineageos.jelly", "org.lineageos.twelve", "com.android.documentsui",
        "com.android.messaging", "com.android.chrome", "com.tencent.mm",
        "com.taobao.taobao", "com.ss.android.ugc.trill", "com.xingin.xhs", "com.google.android.youtube", "com.google.android.apps.photos", "com.google.android.gm", "com.android.vending", "com.discord", "com.twitter.android"
    )
}

# Keep only packages that exist on the phone and have a launcher activity.
$installed = (& $adb -s $serial shell pm list packages 2>&1) -replace '^package:', '' -replace '\s', ''
$Apps = @($Apps | Where-Object { $installed -contains $_ })
if ($Apps.Count -lt $Max) {
    Write-Host ("Only {0} usable apps given/installed; lowering Max to {0}." -f $Apps.Count) -ForegroundColor Yellow
    $Max = $Apps.Count
}

# ---- clean slate -----------------------------------------------------------
Get-Process scrcpy -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Remove-Item (Join-Path $script:Root "run\screens.json") -Force -ErrorAction SilentlyContinue

# ---- layout for the maximum count (maximise tile area) ---------------------
Add-Type -AssemblyName System.Windows.Forms
$work = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$gap = 8
$best = $null
for ($c = 1; $c -le [Math]::Min(5, $Max); $c++) {
    $r = [int][Math]::Ceiling($Max / $c)
    $h = [int](($work.Height - $gap * ($r + 1)) / $r)
    $w = [int](($work.Width - $gap * ($c + 1)) / $c)
    $fit = [int]($h * ($Width / $Height))
    if ($fit -lt $w) { $w = $fit }
    $area = $w * $h
    if (-not $best -or $area -gt $best.Area) { $best = @{ Cols = $c; Rows = $r; W = $w; H = $h; Area = $area } }
}
$cols = $best.Cols
$rows = $best.Rows
$tileW = $best.W
$tileH = $best.H
$totalWidth = $cols * $tileW + $gap * ($cols - 1)
$startX = $work.X + [int](($work.Width - $totalWidth) / 2)
$startY = $work.Y + $gap

Write-Host ("Capacity test: up to {0} screens, {1}x{2} @ {3}dpi, tile {4}x{5}" -f $Max, $Width, $Height, $Dpi, $tileW, $tileH) -ForegroundColor Cyan

# ---- helpers ---------------------------------------------------------------
function Get-CpuSnapshot {
    param([string]$Serial)
    $line = ((& $adb -s $Serial shell "cat /proc/stat") 2>&1) | Select-Object -First 1
    $parts = $line.Trim() -split '\s+'
    $total = 0.0; $idle = 0.0
    for ($k = 1; $k -lt $parts.Count; $k++) {
        $v = 0.0
        [void][double]::TryParse($parts[$k], [ref]$v)
        $total += $v
        if ($k -eq 4 -or $k -eq 5) { $idle += $v }   # idle, iowait
    }
    return @{ Total = $total; Idle = $idle }
}

function Get-MemAvailableMb {
    param([string]$Serial)
    $line = ((& $adb -s $Serial shell "grep MemAvailable /proc/meminfo") 2>&1) | Select-Object -First 1
    if ($line -match '(\d+)') { return [int]([int]$matches[1] / 1024) }
    return -1
}

function Get-FocusedActivity {
    param([string]$Serial, [int]$DisplayId)
    $out = & $adb -s $Serial shell dumpsys activity activities 2>&1
    $start = -1
    for ($k = 0; $k -lt $out.Count; $k++) {
        if ($out[$k] -match "Display: mDisplayId=$DisplayId ") { $start = $k; break }
    }
    if ($start -lt 0) { return "" }
    for ($k = $start; $k -lt [Math]::Min($start + 40, $out.Count); $k++) {
        if ($out[$k] -match 'mFocusedApp=ActivityRecord\{\S+ u\d+ (\S+)') { return $matches[1] }
    }
    return ""
}

function Get-DisplayState {
    param([string]$Serial, [int]$DisplayId)
    foreach ($d in (Get-Displays -Serial $Serial)) {
        if ([int]$d.Id -eq $DisplayId) { return $d }
    }
    return $null
}

$known = @{}
foreach ($d in (Get-Displays -Serial $serial)) { $known[[int]$d.Id] = $true }

# ---- incremental launch ----------------------------------------------------
$runDir = Join-Path $script:Root "run"
$logDir = Join-Path $runDir "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$records = New-Object System.Collections.Generic.List[object]
$maxOk = 0
$failure = $null
$totalStart = Get-Date

for ($i = 0; $i -lt $Max; $i++) {
    $app = $Apps[$i]
    $title = "CAP-S$($i + 1)"
    $col = $i % $cols
    $rowIndex = [int][Math]::Floor($i / $cols)
    $x = $startX + $col * ($tileW + $gap)
    $y = $startY + $rowIndex * ($tileH + $gap)

    $cmdArgs = @(
        "-s", $serial,
        "--new-display=${Width}x${Height}/${Dpi}",
        "--window-title=$title",
        "--window-x=$x", "--window-y=$y",
        "--window-width=$tileW", "--window-height=$tileH",
        "--max-fps=$Fps",
        "--port=$($BasePort + $i)",
        "--no-audio",
        "--keep-active",
        "--start-app=$app"
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stdout = Join-Path $logDir ("cap{0}.out.log" -f ($i + 1))
    $stderr = Join-Path $logDir ("cap{0}.err.log" -f ($i + 1))
    $cpuBefore = Get-CpuSnapshot -Serial $serial
    $proc = Start-Process -FilePath $scrcpy -ArgumentList $cmdArgs -PassThru -NoNewWindow `
                          -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    # wait for a new virtual display
    $deadline = (Get-Date).AddSeconds(30)
    $newId = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $proc.Refresh()
        if ($proc.HasExited) { break }
        foreach ($d in (Get-Displays -Serial $serial)) {
            if (-not $known.ContainsKey([int]$d.Id)) { $newId = [int]$d.Id; break }
        }
        if ($null -ne $newId) { break }
    }

    if ($null -ne $newId) {
        $known[$newId] = $true
        $hwnd = [IntPtr]::Zero
        $hwndDeadline = (Get-Date).AddSeconds(5)
        while ($hwnd -eq [IntPtr]::Zero -and (Get-Date) -lt $hwndDeadline) {
            $hwnd = [Dsh.Native]::FindWindow([uint32]$proc.Id, $title)
            if ($hwnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
        }
        if ($hwnd -ne [IntPtr]::Zero) {
            [void][Dsh.Native]::SetWindowPos($hwnd, [IntPtr]::Zero, $x, $y, $tileW, $tileH, 0x0014)
        }
    }

    Start-Sleep -Seconds $Settle
    $proc.Refresh()
    $alive = -not $proc.HasExited
    $display = if ($null -ne $newId) { Get-DisplayState -Serial $serial -DisplayId $newId } else { $null }
    $focus = if ($null -ne $newId) { Get-FocusedActivity -Serial $serial -DisplayId $newId } else { "" }
    $cpuAfter = Get-CpuSnapshot -Serial $serial
    $mem = Get-MemAvailableMb -Serial $serial
    $sw.Stop()

    $cpuPct = -1
    if ($cpuAfter.Total -gt $cpuBefore.Total) {
        $busy = 1.0 - (($cpuAfter.Idle - $cpuBefore.Idle) / ($cpuAfter.Total - $cpuBefore.Total))
        $cpuPct = [Math]::Round($busy * 100, 1)
    }

    $ok = $alive -and ($null -ne $display)
    $records.Add([pscustomobject]@{
        n = $i + 1
        app = $app
        displayId = if ($null -ne $newId) { $newId } else { -1 }
        alive = $alive
        focused = $focus
        cpuPct = $cpuPct
        memAvailMb = $mem
        seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        ok = $ok
        pid = $proc.Id
    })

    $status = if ($ok) { "OK" } else { "FAILED" }
    $color = if ($ok) { "Green" } else { "Red" }
    Write-Host ("[{0,2}] {1,-26} display={2,-3} alive={3,-5} cpu={4,5}% memFree={5,5}MB focus={6} ({7}s) {8}" -f `
        ($i + 1), $app, $(if ($null -ne $newId) { $newId } else { "-" }), $alive, $cpuPct, $mem, $focus, [Math]::Round($sw.Elapsed.TotalSeconds, 1), $status) -ForegroundColor $color

    if (-not $ok) {
        $failure = $records[$records.Count - 1]
        if (Test-Path $stderr) {
            $tail = ((Get-Content $stderr -Tail 15) -join "`n").Trim()
            if ($tail) { Write-Host $tail -ForegroundColor DarkGray }
        }
        break
    }
    $maxOk = $i + 1
}

# ---- screenshot + summary --------------------------------------------------
Add-Type -AssemblyName System.Drawing
$w = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
$h = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height
$shot = Join-Path $runDir "capacity.png"
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen(0, 0, 0, 0, (New-Object System.Drawing.Size $w, $h))
$bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

$json = ConvertTo-Json -InputObject ([object[]]$records.ToArray()) -Depth 4
Set-Content -Path (Join-Path $runDir "capacity.json") -Value $json -Encoding UTF8

if ($LeaveOpen) {
    $screens = @()
    foreach ($rec in $records) {
        if ($rec.displayId -ge 0 -and $rec.alive) {
            $screens += [pscustomobject]@{
                index = $rec.n; displayId = $rec.displayId; package = $rec.app; pid = $rec.pid
            }
        }
    }
    if ($screens.Count -gt 0) {
        $sjson = ConvertTo-Json -InputObject ([object[]]$screens) -Depth 3
        Set-Content -Path (Join-Path $runDir "screens.json") -Value $sjson -Encoding UTF8
    }
}

Write-Host ""
Write-Host ("Max healthy concurrent screens: {0}" -f $maxOk) -ForegroundColor Cyan
if ($failure) {
    Write-Host ("Failed at screen {0} ({1}): alive={2} display={3} focus='{4}'" -f $failure.n, $failure.app, $failure.alive, $failure.displayId, $failure.focused) -ForegroundColor Yellow
}
Write-Host ("Total wall time: {0:N0}s   Screenshot: {1}" -f ((Get-Date) - $totalStart).TotalSeconds, $shot)

if (-not $LeaveOpen) {
    Write-Host "Closing test screens ..." -ForegroundColor DarkGray
    Get-Process scrcpy -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $runDir "screens.json") -Force -ErrorAction SilentlyContinue
    Write-Host "Done."
}




