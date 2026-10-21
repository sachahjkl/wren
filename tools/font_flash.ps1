# Films navigations inside a site, frame by frame, to see what the page shows between two documents (a fallback font
# before the web font, a blank frame...). Starts the browser on -Url with a profile of its own, then for each -Click
# (window-relative pixels, "x,y;x,y"): starts an ffmpeg gdigrab recording of the window at -Fps, clicks, records
# -RecordMs, stops. Then each clip is cut to -Crop ("x,y,w,h" of the window: leave out animated parts of the page and
# the status bar) and its frames are compared: consecutive identical frames are one state; the states are listed with
# the frame they start at and saved as PNG (<Out>\<name>_state<k>.png). A navigation without a flash has two states:
# the old page, the new one (three when the link shows a hover or pressed style first).
#   powershell -File tools\font_flash.ps1 -Url https://sacha.house -Click "300,208;478,208" -Out build\flash [-Profile dir]
#       [-KeepProfile] [-Extra "--pref","a=b"] [-Exe build\browser_prof.exe] [-WaitMs 6000] [-Name run]
# Opens a window: take the shared lock (S:\wb_wt\shared.lock) around it. WREN_PROF is set for a profile build: first
# paints go to <Out>\<name>.firstpaint.txt (first_paint.odin), what each page cost to <Out>\<name>.requests.txt.
param([string]$Url, [string]$Click = '', [string]$Out = 'build\flash', [string]$Profile = '', [switch]$KeepProfile,
      [string[]]$Extra = @(), [string]$Exe = '', [int]$WaitMs = 6000, [int]$RecordMs = 2500, [int]$Fps = 60,
      [string]$Crop = '0,140,1240,180', [string]$Name = 'run', [int]$Width = 1280, [int]$Height = 800, [switch]$AnalyzeOnly)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type @"
using System; using System.Runtime.InteropServices;
public class FF {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
}
"@
[FF]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
if (-not $Exe) { $Exe = Join-Path $root 'build\browser_prof.exe' }
if (-not $Profile) { $Profile = Join-Path $env:TEMP "wren_flash_profile" }
if (-not $KeepProfile -and (Test-Path $Profile)) { Remove-Item -LiteralPath $Profile -Recurse -Force }
New-Item -ItemType Directory -Force $Profile | Out-Null
$Extra = @($Extra | ForEach-Object { $_ -split ',(?=--)' } | ForEach-Object { if ($_ -match '^(--[a-z-]+),(.*)$') { $Matches[1]; $Matches[2] } else { $_ } } | Where-Object { $_ })

function Window-Rect($h) {
    $r = New-Object FF+RECT
    if ([FF]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [FF]::GetWindowRect($h, [ref]$r) | Out-Null }
    return $r
}

if ($AnalyzeOnly) { $clips = @(Get-ChildItem $Out -Filter "${Name}_nav*.mkv" | Sort-Object Name | ForEach-Object { $_.FullName }) } else {
$env:WREN_PROF = Join-Path $Out $Name
$p = Start-Process $Exe -ArgumentList (@('--profile', $Profile) + $Extra + @($Url)) -PassThru
$clips = @()
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 20; $p.Refresh() }
    $h = $p.MainWindowHandle
    [FF]::SetWindowPos($h, [IntPtr](-1), 0, 0, $Width, $Height, 0x10) | Out-Null   # topmost, at a known place and size
    [FF]::SetForegroundWindow($h) | Out-Null
    $r = Window-Rect $h
    [FF]::SetCursorPos($r.R + 20, $r.B - 20) | Out-Null
    Start-Sleep -Milliseconds $WaitMs
    $i = 0
    foreach ($c in ($Click -split ';' | Where-Object { $_ })) {
        $i++
        $r = Window-Rect $h
        $w = ($r.R - $r.L) - (($r.R - $r.L) % 2); $hh = ($r.B - $r.T) - (($r.B - $r.T) % 2)
        $clip = Join-Path $Out ("{0}_nav{1}.mkv" -f $Name, $i)
        $ff = New-Object Diagnostics.Process
        $ff.StartInfo.FileName = (Get-Command ffmpeg).Source
        $ff.StartInfo.Arguments = "-y -hide_banner -loglevel error -f gdigrab -framerate $Fps -draw_mouse 0 -offset_x $($r.L) -offset_y $($r.T) -video_size ${w}x${hh} -i desktop -c:v ffv1 -level 3 `"$clip`""
        $ff.StartInfo.UseShellExecute = $false
        $ff.StartInfo.RedirectStandardInput = $true
        $ff.StartInfo.CreateNoWindow = $true
        $ff.Start() | Out-Null
        Start-Sleep -Milliseconds 700
        $xy = $c -split ','
        $pt = New-Object FF+POINT; $pt.X = $r.L + [int]$xy[0]; $pt.Y = $r.T + [int]$xy[1]
        [FF]::ScreenToClient($h, [ref]$pt) | Out-Null
        $lp = [IntPtr](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF))
        [FF]::PostMessage($h, 0x0200, [IntPtr]::Zero, $lp) | Out-Null
        Start-Sleep -Milliseconds 60
        [FF]::PostMessage($h, 0x0201, [IntPtr]1, $lp) | Out-Null
        Start-Sleep -Milliseconds 40
        [FF]::PostMessage($h, 0x0202, [IntPtr]::Zero, $lp) | Out-Null
        # the cursor leaves the page: no hover style on the new one
        [FF]::PostMessage($h, 0x02A3, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        Start-Sleep -Milliseconds $RecordMs
        $ff.StandardInput.Write('q'); $ff.StandardInput.Flush()
        if (-not $ff.WaitForExit(10000)) { $ff.Kill() }
        $clips += $clip
    }
} finally {
    if (-not $p.HasExited) {
        [FF]::PostMessage($p.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null   # WM_CLOSE: the profile (cache index) is written
        if (-not $p.WaitForExit(30000)) { try { $p.Kill() } catch { } }
    }
    Remove-Item Env:\WREN_PROF
}
}

# Analysis: the cropped region, gray, half size; identical consecutive frames are one state
$cx, $cy, $cw, $ch = $Crop -split ',' | ForEach-Object { [int]$_ }
$sw2 = [int]($cw / 2); $sh2 = [int]($ch / 2)
$md5 = [Security.Cryptography.MD5]::Create()
$report = @()
foreach ($clip in $clips) {
    $base = [IO.Path]::GetFileNameWithoutExtension($clip)
    $raw = Join-Path $Out "$base.gray"
    & ffmpeg -y -hide_banner -loglevel error -i $clip -vf "crop=${cw}:${ch}:${cx}:${cy},format=gray,scale=${sw2}:${sh2}:flags=area" -f rawvideo $raw
    $bytes = [IO.File]::ReadAllBytes($raw)
    $fsize = $sw2 * $sh2
    $n = [int]($bytes.Length / $fsize)
    $states = New-Object System.Collections.Generic.List[object]
    $last = ''
    for ($k = 0; $k -lt $n; $k++) {
        $hsh = [BitConverter]::ToString($md5.ComputeHash($bytes, $k * $fsize, $fsize))
        if ($hsh -ne $last) { $states.Add([pscustomobject]@{ frame = $k; hash = $hsh }); $last = $hsh }
    }
    Remove-Item $raw
    $s = 0
    $line = "$base : $n frames, $($states.Count) states:"
    foreach ($st in $states) {
        $s++
        $png = Join-Path $Out ("{0}_state{1}.png" -f $base, $s)
        & ffmpeg -y -hide_banner -loglevel error -i $clip -vf "select=eq(n\,$($st.frame))" -frames:v 1 $png
        $line += " #$s@f$($st.frame) ($([math]::Round($st.frame * 1000 / $Fps)) ms)"
    }
    $report += $line
}
$report | Tee-Object -FilePath (Join-Path $Out "$Name.states.txt")
$fp = Join-Path $Out "$Name.firstpaint.txt"
if (Test-Path $fp) { "first paints (ms since navigation, ms since document, url, sources):"; Get-Content $fp }
$rq = Join-Path $Out "$Name.requests.txt"
if (Test-Path $rq) { "pages left (url, document, subresources by source, network bytes):"; Get-Content $rq }
