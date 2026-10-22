# Latency of the shell (tabs, address bar, menu, scrolling, resizing) while a page loads or keeps the browser busy.
#   powershell -File tools\shell_latency.ps1 [-Only name,name] [-Exe wren_prof.exe] [-Tag suffix] [-Prefs '--pref a=b']
# Needs build\wren_prof.exe (build.bat profile). For each scenario the browser opens a page that loads or works hard
# (a 50 000-element document, scripts that take 16 to 200 ms per frame or per task, a 40 ms relayout every 150 ms), and
# input is posted to its window meanwhile: the pointer over the tab strip, a click in the address bar and typing,
# the menu opened and closed, the wheel over the page, the window resized. Every post is noted with its QPC time;
# the browser notes each frame's input poll and present on the same clock (src/browser/shell_latency.odin). The
# latency of an input is the time from its post to the present of the first frame that polled after it.
# Writes build\shell\<scenario><tag>.inputs.csv, .latency.txt (and the profiler's .csv/.txt), and a summary table
# (build\shell\summary<tag>.txt). -NoLock: without bench.lock (to try the script out; other runs skew the numbers).
# -Report: the table again from the files of an earlier run. Holds bench.lock (tools\test_env.ps1) for each scenario; input is posted: no desktop.
param([string[]]$Only = @(), [string]$Exe = 'wren_prof.exe', [string]$Tag = '', [string]$Prefs = '', [switch]$Report, [switch]$NoLock)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build\shell'
New-Item -ItemType Directory -Force $out | Out-Null
Add-Type @"
using System; using System.Runtime.InteropServices;
public class SL {
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("kernel32.dll")] public static extern bool QueryPerformanceCounter(out long v);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
  public static long Qpc() { long v; QueryPerformanceCounter(out v); return v; }
}
"@
if (-not [SL]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [SL]::SetProcessDPIAware() | Out-Null }
. (Join-Path $PSScriptRoot 'test_env.ps1')
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

# ---------- pages ----------
$perfDir = Join-Path $root 'build\perf'
$p50k = Join-Path $perfDir 'p50k.html'
if (-not (Test-Path $p50k)) { & (Join-Path $PSScriptRoot 'perf.ps1') -Only '__pages_only__' | Out-Null }
function Lorem([int]$n) {
    $w = 'lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua'.Split(' ')
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $n; $i++) { [void]$sb.Append("<p>Paragraph $i $($w[$i % $w.Length]) $($w[($i * 7) % $w.Length]) $($w[($i * 3) % $w.Length]) lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore.</p>`n") }
    $sb.ToString()
}
# A script task of 200 ms every 250 ms (a page busy in JavaScript most of the time)
$busy = Join-Path $out 'busy200.html'
[IO.File]::WriteAllText($busy, "<!doctype html><meta charset=utf-8><title>busy 200 ms</title><style>body{font:15px sans-serif;margin:16px}</style><p id=s>0</p>`n$(Lorem 400)<script>var n=0,s=document.getElementById('s');setInterval(function(){var t=Date.now();while(Date.now()-t<200){}s.textContent='busy '+(++n);},250);</script>")
# A relayout of a long document every 150 ms (the body's width changes: every line is broken again)
$relayout = Join-Path $out 'relayout.html'
[IO.File]::WriteAllText($relayout, "<!doctype html><meta charset=utf-8><title>relayout</title><style>body{font:15px sans-serif;margin:16px} p{margin:4px 0}</style>`n$(Lorem 12000)<script>var n=0;setInterval(function(){n++;document.body.style.width=(n%2?'90%':'91%');},150);</script>")
function FileUrl($p) { 'file:///' + ($p -replace '\\', '/') }
$jsb = Join-Path $root 'examples\jsbench'

# ---------- input ----------
$script:log = $null
$script:win = [IntPtr]::Zero
$script:scale = 1.0
function Note($kind, $extra = '') { [void]$script:log.AppendLine("$([SL]::Qpc()),$kind,$extra") }
function Client { $r = New-Object SL+RECT; [SL]::GetClientRect($script:win, [ref]$r) | Out-Null; $r }
function PackXY([int]$x, [int]$y) { [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF)) }
function Dip([double]$v) { [int]($v * $script:scale) }
function PtrMove([int]$x, [int]$y, $kind) { Note $kind; [SL]::PostMessage($script:win, 0x0200, [IntPtr]::Zero, (PackXY $x $y)) | Out-Null }
function Click([int]$x, [int]$y, $kind) {
    Note $kind
    [SL]::PostMessage($script:win, 0x0200, [IntPtr]::Zero, (PackXY $x $y)) | Out-Null
    [SL]::PostMessage($script:win, 0x0201, [IntPtr]1, (PackXY $x $y)) | Out-Null
    [SL]::PostMessage($script:win, 0x0202, [IntPtr]::Zero, (PackXY $x $y)) | Out-Null
}
function Char([char]$c) { Note 'type'; [SL]::PostMessage($script:win, 0x0102, [IntPtr][int]$c, [IntPtr]1) | Out-Null }
function Key([int]$vk, $kind) {
    Note $kind
    [SL]::PostMessage($script:win, 0x0100, [IntPtr]$vk, [IntPtr]1) | Out-Null
    [SL]::PostMessage($script:win, 0x0101, [IntPtr]$vk, [IntPtr](0xC0000001 -band 0xFFFFFFFF)) | Out-Null
}
function Wheel([int]$x, [int]$y, [int]$notches) {
    $pt = New-Object SL+POINT; $pt.X = $x; $pt.Y = $y; [SL]::ClientToScreen($script:win, [ref]$pt) | Out-Null
    Note 'wheel'
    [SL]::PostMessage($script:win, 0x020A, [IntPtr](((120 * $notches) -shl 16) -band 0xFFFFFFFF), (PackXY $pt.X $pt.Y)) | Out-Null
}
function Nap([int]$ms) { Start-Sleep -Milliseconds $ms }

# The interactions, about 12 s: pointer over the tab strip, address bar typing, menu, wheel, resize
function Interact {
    $c = Client
    # the tab strip: back and forth over the first tab and the + button
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 2000) {
        $t = $sw.ElapsedMilliseconds / 1000.0
        PtrMove (Dip (80 + 200 * (0.5 + 0.5 * [Math]::Sin($t * 4)))) (Dip 21) 'tab_hover'
        Nap 16
    }
    # the address bar: click, type, Escape twice (the edit is undone, the field let go)
    Click ([int]($c.R / 2)) (Dip 63) 'address_click'; Nap 150
    foreach ($ch in 'wren shell latency probe'.ToCharArray()) { Char $ch; Nap 40 }
    Key 0x1B 'escape'; Nap 100; Key 0x1B 'escape'; Nap 200
    # the menu: open, close
    for ($i = 0; $i -lt 4; $i++) { Click ($c.R - (Dip 27)) (Dip 63) 'menu_open'; Nap 300; Key 0x1B 'menu_close'; Nap 300 }
    # the wheel over the page
    for ($i = 0; $i -lt 40; $i++) { Wheel ([int]($c.R / 2)) ([int]($c.B / 2)) $(if ($i -lt 20) { -1 } else { 1 }); Nap 50 }
    # resizing (posted: SWP_ASYNCWINDOWPOS, the driver does not wait for a busy window)
    $r = New-Object SL+RECT; [SL]::GetWindowRect($script:win, [ref]$r) | Out-Null
    $w0 = $r.R - $r.L; $h0 = $r.B - $r.T; $frameW = $w0 - $c.R
    for ($i = 0; $i -lt 20; $i++) {
        $w = [int]($w0 * (0.85 + 0.1 * ($i % 2)) - $i)
        Note 'resize' ($w - $frameW)
        [SL]::SetWindowPos($script:win, [IntPtr]::Zero, $r.L, $r.T, $w, $h0, 0x4014) | Out-Null
        Nap 120
    }
    Note 'resize' ($w0 - $frameW)
    [SL]::SetWindowPos($script:win, [IntPtr]::Zero, $r.L, $r.T, $w0, $h0, 0x4014) | Out-Null
    Nap 500
}

# ---------- driver ----------
function Run($name, $url, [int]$warmMs, [string]$extra = '') {
    if ($Only.Count -gt 0 -and $Only -notcontains $name) { return }
    $prefix = Join-Path $out "$name$Tag"
    $env:WREN_PROF = $prefix
    $env:WREN_SAMPLE = '0'
    $argv = (@($Prefs, $extra, $url) | Where-Object { $_ }) -join ' '
    $bench = if ($NoLock) { $null } else { Enter-WrenLock bench "shell_latency.ps1 $name" }
    $p = $null
    try {
        $p = Start-Process (Join-Path $root "build\$Exe") -ArgumentList $argv -PassThru
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not $p.HasExited -and $p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 20; $p.Refresh() }
        $script:win = $p.MainWindowHandle
        $script:scale = [SL]::GetDpiForWindow($script:win) / 96.0
        $script:log = New-Object Text.StringBuilder
        [void]$script:log.AppendLine("qpc,kind,extra")
        Nap $warmMs
        Note 'start'
        Interact
        [IO.File]::WriteAllText("$prefix.inputs.csv", $script:log.ToString())
        [SL]::PostMessage($script:win, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        if (-not $p.WaitForExit(30000)) { Write-Host "$name did not exit, killed"; $p.Kill() }
        elseif ($p.ExitCode -ne 0) { Write-Host ("$name exited with code 0x{0:x}" -f $p.ExitCode) }
    } finally { if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) | Out-Null }; if ($bench) { Exit-WrenLock $bench } }
    Write-Host "done $name"
}

# ---------- analysis ----------
function Pct($v, $p) { if ($v.Count -eq 0) { return 0 }; $s = @($v | Sort-Object); $s[[Math]::Min($s.Count - 1, [Math]::Max(0, [int][Math]::Ceiling($s.Count * $p / 100) - 1))] }
function Analyze($name) {
    $prefix = Join-Path $out "$name$Tag"
    if (-not (Test-Path "$prefix.latency.txt") -or -not (Test-Path "$prefix.inputs.csv")) { return $null }
    $lines = [IO.File]::ReadAllLines("$prefix.latency.txt")
    $freq = [double]($lines[0].Split(',')[1])
    $frames = New-Object Collections.Generic.List[object]
    for ($i = 2; $i -lt $lines.Length; $i++) {
        $f = $lines[$i].Split(','); if ($f.Length -lt 6) { continue }
        $frames.Add([pscustomobject]@{ polled = [int64]$f[0]; presented = [int64]$f[1]; events = [int]$f[2]; w = [int]$f[3]; kind = [int]$f[5] })
    }
    $inputs = Import-Csv "$prefix.inputs.csv"
    $start = [int64]($inputs | Where-Object { $_.kind -eq 'start' } | Select-Object -First 1).qpc
    $end = [int64]$inputs[-1].qpc
    $budget = 1000.0 / 180
    $byKind = @{}
    $all = New-Object Collections.Generic.List[double]
    $j = 0
    foreach ($in in $inputs) {
        if ($in.kind -eq 'start') { continue }
        $t = [int64]$in.qpc
        while ($j -lt $frames.Count -and $frames[$j].polled -lt $t) { $j++ }
        $k = $j
        if ($in.kind -eq 'resize') { while ($k -lt $frames.Count -and $frames[$k].w -ne [int]$in.extra) { $k++ } }
        if ($k -ge $frames.Count) { continue }
        $ms = ($frames[$k].presented - $t) * 1000.0 / $freq
        $kind = $in.kind -replace '_(open|close|click)$', '' -replace '^escape$', 'address'
        $kind = $kind -replace '^type$', 'address'
        if (-not $byKind.ContainsKey($kind)) { $byKind[$kind] = New-Object Collections.Generic.List[double] }
        $byKind[$kind].Add($ms); $all.Add($ms)
    }
    # frames of the interaction window: work (poll -> present) over the budget, and the longest gap between presents
    $win = @($frames | Where-Object { $_.polled -ge $start -and $_.polled -le $end })
    $over = @($win | Where-Object { ($_.presented - $_.polled) * 1000.0 / $freq -gt $budget }).Count
    $gap = 0.0
    for ($i = 1; $i -lt $win.Count; $i++) { $g = ($win[$i].presented - $win[$i - 1].presented) * 1000.0 / $freq; if ($g -gt $gap) { $gap = $g } }
    $chromeOnly = @($win | Where-Object { $_.kind -eq 1 }).Count
    $row = [ordered]@{ scenario = "$name$Tag"; inputs = $all.Count; p50 = [math]::Round((Pct $all 50), 1); p95 = [math]::Round((Pct $all 95), 1); max = [math]::Round((Pct $all 100), 1); frames = $win.Count; over = $over; chrome_frames = $chromeOnly }
    foreach ($k in 'tab_hover', 'address', 'menu', 'wheel', 'resize') {
        $v = $byKind[$k]
        $row["${k}_p95"] = if ($v) { [math]::Round((Pct $v 95), 1) } else { '' }
    }
    [pscustomobject]$row
}

$scen = @(
    @{ n = 'blank';        u = 'about:blank';                                      w = 1500 },
    @{ n = 'p50k_load';    u = (FileUrl $p50k);                                    w = 200 },
    @{ n = 'js_anim1000';  u = (FileUrl (Join-Path $jsb 'anim1000.html'));         w = 3000 },
    @{ n = 'js_nodes10k';  u = (FileUrl (Join-Path $jsb 'nodes10k.html'));         w = 3000 },
    @{ n = 'busy200';      u = (FileUrl $busy);                                    w = 2000 },
    @{ n = 'relayout';     u = (FileUrl $relayout);                                w = 4000 }
)
if (-not $Report) {
    foreach ($s in $scen) { Run $s.n $s.u $s.w '--pref browser.frame.target_hz=180' }
}
$rows = foreach ($s in $scen) { if ($Only.Count -eq 0 -or $Only -contains $s.n) { Analyze $s.n } }
$table = $rows | Format-Table -Property * -AutoSize | Out-String -Width 400
$table
[IO.File]::WriteAllText((Join-Path $out "summary$Tag.txt"), "input -> present latency (ms), frames of the interaction window over 5.56 ms, longest gap between presents (ms); per kind: p95 (ms)`n$table")
