#Requires -Version 5.1
# Shared helpers for the K40 multi-display toolkit.
# Dot-source this file from the other scripts:  . "$PSScriptRoot\common.ps1"

$script:Root = Split-Path -Parent $PSScriptRoot

function Get-AdbPath {
    # Prefer the adb bundled with scrcpy (matches the scrcpy version), then
    # other platform-tools installs, then whatever is on PATH.
    $tools = Join-Path $script:Root "tools"
    $scrcpyDir = Get-ChildItem -Path $tools -Directory -Filter "scrcpy-win64-*" -ErrorAction SilentlyContinue |
                 Sort-Object Name -Descending | Select-Object -First 1
    if ($scrcpyDir) {
        $bundled = Join-Path $scrcpyDir.FullName "adb.exe"
        if (Test-Path $bundled) { return $bundled }
    }

    $candidates = @(
        "C:\Users\ac\Downloads\droidline_0.1.12_windows_amd64\adb.exe",
        (Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"),
        (Join-Path $tools "platform-tools\adb.exe")
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path $path)) { return $path }
    }
    $command = Get-Command adb -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw "adb.exe not found. Put platform-tools under tools\platform-tools\ or edit Get-AdbPath."
}

function Get-ScrcpyPath {
    $tools = Join-Path $script:Root "tools"
    $dir = Get-ChildItem -Path $tools -Directory -Filter "scrcpy-win64-*" -ErrorAction SilentlyContinue |
           Sort-Object Name -Descending | Select-Object -First 1
    if ($dir) {
        $exe = Join-Path $dir.FullName "scrcpy.exe"
        if (Test-Path $exe) { return $exe }
    }
    throw "scrcpy.exe not found. Expected tools\scrcpy-win64-*\scrcpy.exe"
}

function Get-DeviceSerial {
    param([string]$Serial = "")
    if ($Serial) { return $Serial }
    $adb = Get-AdbPath
    $output = & $adb devices 2>&1
    $unauthorized = $false
    foreach ($line in $output) {
        if ($line -match '^(\S+)\s+device$') { return $matches[1] }
        if ($line -match '^(\S+)\s+unauthorized$') { $unauthorized = $true }
    }
    if ($unauthorized) {
        throw "Device is unauthorized. Unlock the phone and tap 'Allow' on the 'Allow USB debugging?' dialog (check 'Always allow')."
    }
    throw "No adb device found. Connect the K40 with a data-capable USB cable and enable USB debugging (Developer options)."
}

function Get-Displays {
    param([string]$Serial)
    $adb = Get-AdbPath
    $lines = & $adb -s $Serial shell dumpsys display 2>&1

    # Modern Android (12+, verified on Android 17) prints one DisplayInfo block
    # per logical display. Unlike DisplayDeviceInfo, DisplayInfo still carries
    # "displayId N", so it is the reliable source.
    $byId = @{}
    foreach ($line in $lines) {
        if ($line -match 'DisplayInfo\{"([^"]*)"\s*,\s*displayId\s+(\d+)') {
            $name = $matches[1]
            $id = [int]$matches[2]
            if ($line -match 'mOverrideDisplayInfo' -and $byId.ContainsKey($id)) { continue }
            $w = 0; $h = 0
            if ($line -match 'real (\d+) x (\d+)') { $w = [int]$matches[1]; $h = [int]$matches[2] }
            $type = ""
            if ($line -match 'type ([A-Z_]+)') { $type = $matches[1] }
            $state = ""
            if ($line -match 'state ([A-Z_]+)') { $state = $matches[1] }
            $byId[$id] = [pscustomobject]@{
                Id = $id; Name = $name; Type = $type; State = $state; Width = $w; Height = $h
            }
        }
    }

    # Fallback for older dumpsys output: DisplayDeviceInfo + its "displayId".
    if ($byId.Count -eq 0) {
        foreach ($line in $lines) {
            if ($line -notmatch 'DisplayDeviceInfo\{"([^"]*)"') { continue }
            $name = $matches[1]
            if ($line -notmatch 'displayId (\d+)') { continue }
            $id = [int]$matches[1]
            $w = 0; $h = 0
            if ($line -match '(\d+) x (\d+)') { $w = [int]$matches[1]; $h = [int]$matches[2] }
            $type = ""
            if ($line -match 'type ([A-Z_]+)') { $type = $matches[1] }
            $state = ""
            if ($line -match 'state ([A-Z_]+)') { $state = $matches[1] }
            $byId[$id] = [pscustomobject]@{
                Id = $id; Name = $name; Type = $type; State = $state; Width = $w; Height = $h
            }
        }
    }

    return $byId.Values | Sort-Object Id
}

function Read-Screens {
    $runFile = Join-Path $script:Root "run\screens.json"
    if (-not (Test-Path $runFile)) { return @() }
    return @(Get-Content $runFile -Raw | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# DPI / window placement helpers.
#
# PowerShell 5.1 is DPI-unaware by default: on a 150% display it reports a
# 1280x720 desktop and its coordinates are virtualized, while scrcpy (SDL) is
# DPI-aware and works in physical pixels. Mixing the two gives tiny, overlapping
# windows. Enable-DpiAwareness fixes the coordinate space, and
# SetWindowPos lets us tile the outer window rectangles exactly.
# ---------------------------------------------------------------------------
function Enable-DpiAwareness {
    if (-not ("Dsh.Native" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace Dsh {
    public static class Native {
        public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);

        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

        [DllImport("user32.dll")]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);

        [DllImport("user32.dll")]
        public static extern uint GetDpiForSystem();

        public static IntPtr FindWindow(uint pid, string title) {
            IntPtr result = IntPtr.Zero;
            EnumWindows(delegate (IntPtr h, IntPtr l) {
                uint p;
                GetWindowThreadProcessId(h, out p);
                if (p != pid) return true;
                StringBuilder sb = new StringBuilder(256);
                GetWindowText(h, sb, 256);
                if (sb.ToString() == title) { result = h; return false; }
                return true;
            }, IntPtr.Zero);
            return result;
        }
    }
}
'@
    }
    try { [void][Dsh.Native]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }
}
