# End-to-end test of the remote control channel (wren ctl): a Wren with a throwaway profile and no window shown is started,
# driven through a page of the test server and checked, then closed; plus the cases around it (the channel is off when not
# asked for and costs nothing at rest, two instances do not meet, a taken name is an error, a client that vanishes or sends
# too much does not hurt, closing with clients connected).
#   powershell -NoProfile -File tools\remote_e2e.ps1 [-Exe build\wren.exe]
#   powershell -NoProfile -File tools\remote_e2e.ps1 -Stress 16   only the closing, with 16 busy loops saturating the machine (-Stress -1: every
#                                                              logical processor; -Rounds n, default 3): wren ctl quit with a client connected, and the
#                                                              window closed as the X button does, each with a video playing, must end within -CloseLimitMs
#                                                              (8 s) with no forced exit. A close that waits for a thread of lower priority starved by the
#                                                              load fails here (the disk cache's writer did: ten seconds).
#   powershell -NoProfile -File tools\remote_e2e.ps1 -Check     the same kind of session on the check build (build.bat check: every
#                                                              allocation tracked): it must exit with nothing left allocated
# Nothing here takes the desktop: the window is never shown and the capture is read from the renderer's frame.
param([string]$Exe = '', [switch]$Check, [int]$Stress = 0, [int]$Rounds = 3, [int]$CloseLimitMs = 8000)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\test_env.ps1"
if (-not $Exe) { $Exe = Join-Path $root $(if ($Check) { 'build\wren_check.exe' } else { 'build\wren.exe' }) }
if ($Check -and -not (Test-Path $Exe)) { cmd /c "build.bat check" | Out-Host; if ($LASTEXITCODE) { 'FAIL building the check build'; exit 1 } }
$env:WREN_EXE = (Resolve-Path $Exe).Path
. "$PSScriptRoot\wrenctl.ps1"
Section '0 script start: Add-Type, helpers'
Add-Type -AssemblyName System.Drawing

$script:fail = 0
$script:failedNames = @()
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "PASS  $name" } else { "FAIL  $name  $detail"; $script:fail++; $script:failedNames += $name }
}
function Pixel([string]$png, [int]$x, [int]$y) {
    $bmp = New-Object Drawing.Bitmap($png)
    try { $c = $bmp.GetPixel($x, $y); return @($c.R, $c.G, $c.B) } finally { $bmp.Dispose() }
}
function Near($a, $b, [int]$tol = 8) { for ($i = 0; $i -lt 3; $i++) { if ([Math]::Abs($a[$i] - $b[$i]) -gt $tol) { return $false } }; return $true }
# Waits until the process has finished starting: its CPU time moves by less than 25 ms in a second, twice in a row (at most 30 s). A fixed
# delay is not enough on a busy machine, where the start-up work is still running when the measure of an idle process begins.
function Wait-Quiet($proc) {
    $quiet = 0
    $deadline = (Get-Date).AddSeconds(30)
    $last = $proc.TotalProcessorTime.TotalMilliseconds
    while ($quiet -lt 2 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        $proc.Refresh()
        $now = $proc.TotalProcessorTime.TotalMilliseconds
        if ($now - $last -lt 25) { $quiet++ } else { $quiet = 0 }
        $last = $now
    }
}
function Pipe-Names { [IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -like '*wren-remote-*' } }

$tmp = Join-Path $env:TEMP "wren-remote-e2e-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$started = @()   # processes this script started (and the only ones it ends)

if ($Stress -ne 0) {
    Add-Type @"
using System; using System.Runtime.InteropServices;
public class WinClose {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  // WM_CLOSE to every top-level window of the process: what the close button of the title bar sends
  public static int Close(uint pid) { int n = 0; EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid) { PostMessage(h, 0x10, IntPtr.Zero, IntPtr.Zero); n++; } return true; }, IntPtr.Zero); return n; }
}
"@
    $cores = if ($Stress -lt 0) { [Environment]::ProcessorCount } else { $Stress }
    $hogs = @()
    $times = @()
    $server = Start-WrenTestServer
    try {
        Section 'stress: start the busy loops'
        for ($i = 0; $i -lt $cores; $i++) { $hogs += Start-Process -PassThru -WindowStyle Hidden -FilePath powershell -ArgumentList '-NoProfile', '-Command', 'while ($true) { }' }
        "      $cores busy loops running"
        Start-Sleep -Seconds 2
        $url = "$($server.Origin)/site/video.html"
        for ($round = 1; $round -le $Rounds; $round++) {
            Section "stress round ${round}: quit with a client connected"
            $prof = Join-Path $tmp "stress-quit-$round"
            $name = Start-Wren -Size 800x600 -ProfileDir $prof
            $null = Wren-Ctl nav $url --timeout 60000
            Start-Sleep -Milliseconds 1500
            $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', "wren-remote-$name", [IO.Pipes.PipeDirection]::InOut)
            $pipe.Connect(10000)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $q = Wren-Ctl quit --code 3 --timeout 60000
            $ms = $sw.ElapsedMilliseconds; $times += $ms
            $pipe.Dispose()
            $log = Join-Path $prof 'shutdown.log'
            $forced = (Test-Path $log) -and ((Get-Content $log -Raw) -match 'ending the process')
            Check "round ${round}: quit with a client connected and a video playing: $ms ms" ($global:WrenExit -eq 0 -and $q -match 'exit code 3' -and $ms -lt $CloseLimitMs -and -not $forced) "$q | $global:WrenErr | forced=$forced"
            if (Test-Path $log) { (Get-Content $log | Select-Object -First 14 | ForEach-Object { "      shutdown.log: " + $_.Substring(0, [Math]::Min(300, $_.Length)) }) -join "`n" }
            Remove-Item Env:\WREN_REMOTE -ErrorAction SilentlyContinue
            Section "stress round ${round}: the window closed (WM_CLOSE)"
            $prof = Join-Path $tmp "stress-x-$round"
            $name = Start-Wren -Size 800x600 -ProfileDir $prof
            $wpid = [int]((Wren-Ctl ping --json | ConvertFrom-Json).pid)
            $null = Wren-Ctl nav $url --timeout 60000
            Start-Sleep -Milliseconds 1500
            $proc = Get-Process -Id $wpid
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $n = [WinClose]::Close([uint32]$wpid)
            $ended = $proc.WaitForExit(40000)
            $ms = $sw.ElapsedMilliseconds; $times += $ms
            $log = Join-Path $prof 'shutdown.log'
            $forced = (Test-Path $log) -and ((Get-Content $log -Raw) -match 'ending the process')
            Check "round ${round}: the window closed (WM_CLOSE to $n window(s)) with a video playing: $ms ms" ($ended -and $ms -lt $CloseLimitMs -and -not $forced) "ended=$ended forced=$forced"
            if (-not $ended) { Stop-Process -Id $wpid -Force }
            if (Test-Path $log) { (Get-Content $log | Select-Object -First 14 | ForEach-Object { "      shutdown.log: " + $_.Substring(0, [Math]::Min(300, $_.Length)) }) -join "`n" }
            Remove-Item Env:\WREN_REMOTE -ErrorAction SilentlyContinue
        }
    } finally {
        foreach ($h in $hogs) { Stop-Process -Id $h.Id -Force -ErrorAction SilentlyContinue }
        Stop-WrenTestServer $server
        if ($env:WREN_REMOTE) { Stop-Wren }
    }
    $sorted = @($times | Sort-Object)
    if ($sorted.Count -gt 0) { "      closing times under load (ms): $($sorted -join ', ')  max $($sorted[-1])  p95 $($sorted[[Math]::Min($sorted.Count - 1, [int][Math]::Ceiling($sorted.Count * 0.95) - 1)])" }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Show-WrenSections 'remote_e2e -Stress'
    if ($script:fail -gt 0) { "$script:fail check(s) failed: " + ($script:failedNames -join " | "); exit 1 }
    'remote_e2e -Stress: all closings within the limit'
    exit 0
}

if ($Check) {
    # a session that touches every part of the channel, then a normal exit: the tracker lists what is still allocated
    Section 'check: a session that touches the whole channel, then exit'
    $prof = Join-Path $tmp 'check-profile'
    $env:WREN_MEMTRACK_FAIL = '1'
    $server = Start-WrenTestServer
    try {
        $url = "$($server.Origin)/site/remote/fixture.htm"
        $name = Start-Wren -Size 900x600 -ProfileDir $prof
        $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', "wren-remote-$name", [IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(2000)
        $wr = New-Object IO.StreamWriter($pipe); $wr.AutoFlush = $true
        $wr.WriteLine('{"id":1,"method":"Remote.subscribe"}')
        $null = Wren-Ctl nav $url
        $null = Wren-Ctl eval '[1,2,3].map(x => x * 2)'
        $null = Wren-Ctl eval 'throw new Error("x")'
        $null = Wren-Ctl eval 'new Promise(r => setTimeout(() => r("later"), 50))' --await
        $null = Wren-Ctl click --selector '#go'
        $null = Wren-Ctl click --selector '#far'
        $null = Wren-Ctl click --selector '#name'
        $null = Wren-Ctl type 'abc'
        $null = Wren-Ctl key 'Ctrl+A Backspace'
        $null = Wren-Ctl drag '10,300' '200,320'
        $null = Wren-Ctl scroll -3
        $null = Wren-Ctl wait idle
        $null = Wren-Ctl wait stable
        $null = Wren-Ctl wait function 'window.clicks > 0'
        $null = Wren-Ctl shot (Join-Path $tmp 'a.png')
        $null = Wren-Ctl shot (Join-Path $tmp 'b.png') --selector '#box' --scale 0.5
        $null = Wren-Ctl shot (Join-Path $tmp 'c.png') --tab
        $null = Wren-Ctl snapshot (Join-Path $tmp 'snap')
        $null = Wren-Ctl record start
        $null = Wren-Ctl click '300,300'
        $null = Wren-Ctl record stop (Join-Path $tmp 'rec.json')
        $null = Wren-Ctl replay (Join-Path $tmp 'rec.json')
        $null = Wren-Ctl tab new about:blank
        $null = Wren-Ctl devtools elements
        $null = Wren-Ctl console; $null = Wren-Ctl network; $null = Wren-Ctl stats; $null = Wren-Ctl cmds
        $null = Wren-Ctl pref set browser.scroll.key_line_px 45
        $null = Wren-Ctl html '#box'; $null = Wren-Ctl style '#box' width; $null = Wren-Ctl query 'div'
        $null = Wren-Ctl window --size 700x500
        $wr.WriteLine('{"id":9,"method":"Wren.wait","params":{"for":"selector","selector":"#never","timeout":20000}}')
        Start-Sleep -Milliseconds 300
        $pipe.Dispose()   # a client that vanishes in the middle of a wait
        $null = Wren-Ctl wait selector '#never' --timeout 200
        $q = Wren-Ctl quit
        Check 'check build: exit code 0 after the session (nothing allocated)' ($global:WrenExit -eq 0 -and $q -match 'exit code 0') "$q | $global:WrenErr"
        $rep = Join-Path $prof 'memtrack.txt'
        if (Test-Path $rep) { Get-Content $rep | Select-Object -First 40 }
        Check 'the tracker reports 0 leaked blocks, 0 bad frees' (Test-Path $rep) -and ((Get-Content $rep -Raw) -match ' 0 leaked block\(s\), 0 byte\(s\); 0 bad free\(s\)')
    } finally {
        Stop-WrenTestServer $server
        Remove-Item Env:\WREN_MEMTRACK_FAIL -ErrorAction SilentlyContinue
        if ($env:WREN_REMOTE) { Stop-Wren }
    }
    # ---- 4. a playing video is a plane of the page's paint order: the same picture every frame ------------------------------------
# examples/site/remote/video-layers.htm: a video in a rounded overflow:hidden box, a fixed dialog (z-index) and a bar over it, a
# rotated half-transparent rounded video, and a script that keeps the thread busy a few ms every frame (so that frames are made
# under it, as under a player's). Forty captures in a row while it plays: in each the box's corners are rounded, the dialog and
# the bar are above the video, and what is not the video is the same pixel for pixel in every capture.
$server = Start-WrenTestServer
try {
    $env:WREN_TEST_BASE_PORT = "$($server.BasePort)"
    Section '4a video layers: start, wait idle, 2 s sleep'
    $null = Start-Wren -Dpi 96 -Size 1000x500 -Url "$($server.Origin)/site/remote/video-layers.htm"
    $null = Wren-Ctl wait idle
    Start-Sleep 2
    Section '4b video layers: 40 captures'
    $n = 40
    $shots = @()
    for ($i = 0; $i -lt $n; $i++) { $f = Join-Path $tmp "vl$i.png"; $null = Wren-Ctl shot $f --tab; $shots += $f; Start-Sleep -Milliseconds 25 }
    Section '4c video layers: pixels of the 40 captures (PowerShell GetPixel)'
    $badCorner = 0; $badDialog = 0; $badBar = 0
    $strict = @()   # regions that are never the video: the dialog, the bar, the box's four corners (outside the rounding)
    $bmps = @()
    foreach ($f in $shots) { $bmps += ,(New-Object Drawing.Bitmap($f)) }
    try {
        foreach ($b in $bmps) {
            $c = $b.GetPixel(45, 45); $d = $b.GetPixel(300, 150); $bar = $b.GetPixel(200, 255)
            if (-not ($c.R -gt 200 -and $c.R -lt 240 -and [Math]::Abs($c.R - $c.G) -lt 4 -and [Math]::Abs($c.R - $c.B) -lt 4)) { $badCorner++ }
            if (-not ($d.R -gt 190 -and $d.G -lt 70 -and $d.B -lt 70)) { $badDialog++ }
            if (-not ($bar.B -gt 180 -and $bar.R -lt 60 -and $bar.G -lt 110)) { $badBar++ }
        }
        Check "video layers: $n captures, the box's corner is rounded in all (missing in $badCorner)" ($badCorner -eq 0)
        Check "video layers: the dialog is above the video in all (hidden in $badDialog)" ($badDialog -eq 0)
        Check "video layers: the bar is above the video in all (hidden in $badBar)" ($badBar -eq 0)
        # frame to frame: regions that are not the video must not change at all (the dialog, the bar, the corners)
        $regions = @(@(236, 96, 250, 108), @(60, 242, 360, 26), @(41, 41, 14, 14), @(425, 41, 14, 14), @(41, 265, 14, 14), @(425, 265, 14, 14))
        $changed = 0
        for ($i = 1; $i -lt $n; $i++) {
            $diff = $false
            foreach ($r in $regions) {
                for ($y = $r[1]; $y -lt $r[1] + $r[3] -and -not $diff; $y += 3) {
                    for ($x = $r[0]; $x -lt $r[0] + $r[2]; $x += 3) {
                        $p = $bmps[$i - 1].GetPixel($x, $y); $q = $bmps[$i].GetPixel($x, $y)
                        if ($p.ToArgb() -ne $q.ToArgb()) { $diff = $true; break }
                    }
                }
                if ($diff) { break }
            }
            if ($diff) { $changed++ }
        }
        Check "video layers: nothing but the video changes between two captures (changed in $changed of $($n - 1))" ($changed -eq 0)
        # the video moves at all (the test is of a playing video)
        $moves = 0
        for ($i = 1; $i -lt $n; $i++) { if ($bmps[$i - 1].GetPixel(120, 120).ToArgb() -ne $bmps[$i].GetPixel(120, 120).ToArgb() -or $bmps[$i - 1].GetPixel(330, 220).ToArgb() -ne $bmps[$i].GetPixel(330, 220).ToArgb()) { $moves++ } }
        Check "video layers: the video plays ($moves of $($n - 1) captures differ in the video)" ($moves -gt 3)
    } finally { foreach ($b in $bmps) { $b.Dispose() } }
} finally { Stop-Wren; Stop-WrenTestServer $server }
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Show-WrenSections 'remote_e2e -Check'
    if ($script:fail -gt 0) { exit 1 }
    'remote_e2e -Check: clean'
    exit 0
}

# ---- 1. nothing is listening when the channel was not asked for, and an idle Wren costs no CPU ------------------------------
$prof0 = Join-Path $tmp 'plain'
$p0 = Start-Process -PassThru -FilePath $env:WREN_EXE -ArgumentList '--profile', $prof0, '--no-single-instance', '--headless', 'about:blank'
$started += $p0
try {
    Section '1a plain Wren: start and the fixed 3 s wait'
    Start-Sleep -Seconds 3
    Section '1b plain Wren: files, ctl finds no server'
    $beforePipes = @(Pipe-Names).Count
    Check 'no remote.json without --remote' (-not (Test-Path (Join-Path $prof0 'remote.json')))
    $null = Wren-Ctl ping --profile $prof0 --timeout 300
    Check 'ctl finds no server (exit 3)' ($global:WrenExit -eq 3) "exit $global:WrenExit"
    Section '1c plain Wren: Wait-Quiet'
    Wait-Quiet $p0
    Section '1d plain Wren: 3 s of idle CPU'
    $c1 = $p0.TotalProcessorTime.TotalMilliseconds; Start-Sleep -Seconds 3; $p0.Refresh()
    $idle0 = $p0.TotalProcessorTime.TotalMilliseconds - $c1
    Check 'idle Wren without remote uses < 60 ms CPU in 3 s' ($idle0 -lt 60) "$([int]$idle0) ms"
} finally { if (-not $p0.HasExited) { Stop-Process -Id $p0.Id -Force } }

# ---- 2. a driven Wren ---------------------------------------------------------------------------------------------------------
$server = Start-WrenTestServer
try {
    $url = "$($server.Origin)/site/remote/fixture.htm"
    Section '2a driven Wren: start, window, nav, eval'
    $name = Start-Wren -Size 1000x700
    $pidOf = [int]((Wren-Ctl ping --json | ConvertFrom-Json).pid)
    Check 'start gives a name and the server answers' ($name -and $pidOf -gt 0)
    Check 'remote.json is written in the profile' (@(Get-ChildItem (Join-Path $env:TEMP 'wren-ctl') -Filter 'profile-*' -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'remote.json') }).Count -ge 1)

    $r = Wren-Ctl window --json | ConvertFrom-Json
    Check 'window client area is the size asked for' ($r.width -eq 1000 -and $r.height -eq 700) "$($r.width)x$($r.height)"

    $null = Wren-Ctl nav $url
    Check 'nav loads the page' ($global:WrenExit -eq 0 -and (Wren-Ctl eval 'document.title') -eq 'Remote fixture') $global:WrenErr
    Check 'eval returns JSON' ((Wren-Ctl eval '[1,2,{a:3}]') -eq '[1,2,{"a":3}]')
    $null = Wren-Ctl eval 'throw new Error("boom")'
    Check 'a script error is exit 1 with the stack' ($global:WrenExit -eq 1 -and $global:WrenErr -match 'boom') "exit $global:WrenExit $global:WrenErr"
    Check 'await waits for a promise' ((Wren-Ctl eval 'new Promise(r => setTimeout(() => r(42), 80))' --await) -eq '42')

    Section '2b driven Wren: box, click, type, console, wait'
    $box = Wren-Ctl box '#box' --json | ConvertFrom-Json
    Check 'box of an element' ($box.found -and $box.width -eq 200 -and $box.height -eq 100)

    # click by selector, by coordinates; typing; keys
    $null = Wren-Ctl click --selector '#go'
    Check 'click --selector runs the handler' ((Wren-Ctl eval 'window.clicks') -eq '1') "clicks=$(Wren-Ctl eval 'window.clicks')"
    $null = Wren-Ctl click "$($box.x + 20),$($box.y + 20)"
    $null = Wren-Ctl click --selector '#name'
    $null = Wren-Ctl type 'Wren'
    $null = Wren-Ctl key 'Shift+A'
    Check 'type and key reach the focused field' ((Wren-Ctl eval 'document.getElementById("name").value') -eq 'WrenA') (Wren-Ctl eval 'document.getElementById("name").value')

    $con = Wren-Ctl console
    Check 'console log' ($con -match 'fixture ready' -and $con -match 'warn: a warning')
    Check 'network log has the document' ((Wren-Ctl network) -match 'fixture.htm')
    $null = Wren-Ctl wait idle
    Check 'wait idle' ($global:WrenExit -eq 0)
    $null = Wren-Ctl wait selector '#nothing-here' --timeout 300
    Check 'wait for a missing element times out (exit 2)' ($global:WrenExit -eq 2) "exit $global:WrenExit"

    Section '2c driven Wren: captures and their pixels'
    $shot = Join-Path $tmp 'full.png'
    $sw = [Diagnostics.Stopwatch]::StartNew(); $null = Wren-Shot $shot; $shotMs = $sw.ElapsedMilliseconds
    $img = New-Object Drawing.Bitmap($shot); $w = $img.Width; $h = $img.Height; $img.Dispose()
    Check 'capture has the window size' ($w -eq 1000 -and $h -eq 700) "${w}x$h"
    $cx = [int]($box.window.x + $box.window.width / 2); $cy = [int]($box.window.y + $box.window.height / 2)
    Check 'capture pixel inside the red box' (Near (Pixel $shot $cx $cy) @(255, 0, 0)) ((Pixel $shot $cx $cy) -join ',')
    Check 'capture pixel outside the box is white' (Near (Pixel $shot ([int]$box.window.x + 400) ([int]$box.window.y + 400)) @(255, 255, 255))
    $el = Join-Path $tmp 'box.png'
    $null = Wren-Shot $el -Selector '#box'
    $img = New-Object Drawing.Bitmap($el)
    Check 'element capture is the element (red, its size)' ($img.Width -eq [int]$box.window.width -and $img.Height -eq [int]$box.window.height -and (Near @($img.GetPixel(10, 10).R, $img.GetPixel(10, 10).G, $img.GetPixel(10, 10).B) @(255, 0, 0))) "$($img.Width)x$($img.Height)"
    $img.Dispose()
    $sc = Join-Path $tmp 'half.png'
    $null = Wren-Shot $sc -Scale 0.5
    $img = New-Object Drawing.Bitmap($sc); Check 'scaled capture' ($img.Width -eq 500 -and $img.Height -eq 350) "$($img.Width)x$($img.Height)"; $img.Dispose()
    $df = Wren-Ctl diff $shot $shot
    Check 'diff of a picture with itself is 0 %' ($global:WrenExit -eq 0 -and $df -match '^0\.0000 %')
    $df = Wren-Ctl diff $shot $el
    Check 'diff of pictures of other sizes fails' ($global:WrenExit -eq 1)
    "      capture of the window took $shotMs ms (process start included)"

    # window covered, hidden, moved far off the screen: the capture does not care
    Section '2d driven Wren: window off screen, minimized'
    $null = Wren-Ctl window --pos '-30000,-30000'
    $off = Join-Path $tmp 'off.png'
    $null = Wren-Shot $off
    Check 'capture with the window off the screen' ($global:WrenExit -eq 0 -and (Near (Pixel $off $cx $cy) @(255, 0, 0)))
    $null = Wren-Ctl window --state minimized
    $mini = Join-Path $tmp 'mini.png'
    $null = Wren-Shot $mini
    Check 'capture of a minimized window' ($global:WrenExit -eq 0) "$global:WrenErr"
    $null = Wren-Ctl window --state normal

    Section '2e driven Wren: tabs, cmds, prefs, stats'
    $null = Wren-Ctl tab new 'about:blank'
    Check 'a second tab' ((Wren-Ctl tabs).Split("`n").Count -eq 2)
    Check 'a command of the registry runs' ((Wren-Ctl cmds) -match 'tab.new')
    $null = Wren-Ctl pref set browser.scroll.key_line_px 50
    Check 'pref set and get' ((Wren-Ctl pref get browser.scroll.key_line_px) -eq '50')
    $st = Wren-Ctl stats --json | ConvertFrom-Json
    Check 'stats' ($st.tabs -eq 2 -and $st.workingSetBytes -gt 0)

    # the instance is idle when nothing is asked: no CPU
    Section '2f driven Wren: Wait-Quiet'
    $proc = Get-Process -Id $pidOf
    Wait-Quiet $proc
    Section '2g driven Wren: 3 s of idle CPU'
    $a = $proc.TotalProcessorTime.TotalMilliseconds; Start-Sleep -Seconds 3; $proc.Refresh()
    $idle1 = $proc.TotalProcessorTime.TotalMilliseconds - $a
    Check 'idle Wren with remote on uses < 60 ms CPU in 3 s' ($idle1 -lt 60) "$([int]$idle1) ms"

    Section '2h driven Wren: raw protocol, vanishing client, giant request, ACL'
    # raw protocol: a request line, an unknown method, a bad line; a client that vanishes in the middle of a wait
    $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', "wren-remote-$name", [IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(2000)
    $wr = New-Object IO.StreamWriter($pipe); $wr.AutoFlush = $true
    $rd = New-Object IO.StreamReader($pipe)
    $wr.WriteLine('{"id":"a","method":"Remote.ping"}'); $l1 = $rd.ReadLine()
    $wr.WriteLine('{"id":2,"method":"No.such"}'); $l2 = $rd.ReadLine()
    $wr.WriteLine('not json'); $l3 = $rd.ReadLine()
    Check 'protocol: result keeps a string id' ($l1 -match '^\{"id":"a","result":\{')
    Check 'protocol: unknown method is -32601' ($l2 -match '"code":-32601')
    Check 'protocol: bad JSON is -32700' ($l3 -match '"code":-32700')
    $wr.WriteLine('{"id":9,"method":"Wren.wait","params":{"for":"selector","selector":"#never","timeout":20000}}')
    Start-Sleep -Milliseconds 200
    $pipe.Dispose()
    $null = Wren-Ctl ping
    Check 'a client that vanishes during a wait does not hurt' ($global:WrenExit -eq 0)

    # too large a line: refused, the connection ends, the server lives
    $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', "wren-remote-$name", [IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(2000)
    $big = [byte[]]::new(9MB); for ($i = 0; $i -lt $big.Length; $i++) { $big[$i] = 65 }
    $reply = ''
    try { $pipe.Write($big, 0, $big.Length) } catch { }
    try { $rd = New-Object IO.StreamReader($pipe); $reply = $rd.ReadLine() } catch { }
    $pipe.Dispose()
    Check 'a giant request is refused' ($reply -match 'max_message_bytes' -or $reply -eq '' -or $reply -eq $null)
    $null = Wren-Ctl ping
    Check 'the server lives after a giant request' ($global:WrenExit -eq 0)

    # the pipe is for this user only
    $acl = (Get-Acl "\\.\pipe\wren-remote-$name").Access
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $others = @($acl | Where-Object { try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -ne $me } catch { $true } })
    Check 'the pipe lets in this user only' ($acl.Count -ge 1 -and $others.Count -eq 0) (($acl | ForEach-Object { $_.IdentityReference }) -join ',')

    Section '2i second Wren, taken name (fixed 3 s wait)'
    # a second Wren with another profile has a name of its own; the same name is refused
    $prof2 = Join-Path $tmp 'second'
    $name2 = Start-Wren -Size 800x600 -ProfileDir $prof2
    $env:WREN_REMOTE = $name
    $pid1 = (Wren-Ctl ping --json | ConvertFrom-Json).pid
    $env:WREN_REMOTE = $name2
    $pid2 = (Wren-Ctl ping --json | ConvertFrom-Json).pid
    Check 'two instances answer separately' ($pid1 -ne $pid2 -and $pid1 -eq $pidOf)
    Stop-Wren $name2
    $env:WREN_REMOTE = $name
    $prof3 = Join-Path $tmp 'third'
    $errFile = Join-Path $tmp 'taken.err'
    $p3 = Start-Process -PassThru -FilePath $env:WREN_EXE -ArgumentList '--profile', $prof3, "--remote=$name", '--no-single-instance', '--headless', 'about:blank' -RedirectStandardError $errFile -RedirectStandardOutput (Join-Path $tmp 'taken.out')
    $started += $p3
    Start-Sleep -Seconds 3
    Check 'a name taken by another Wren is reported' ((Get-Content $errFile -Raw) -match 'taken')
    Check 'the first instance still answers under that name' ((Wren-Ctl ping --json | ConvertFrom-Json).pid -eq $pidOf)
    if (-not $p3.HasExited) { Stop-Process -Id $p3.Id -Force }

    Section '2j quit with a client connected'
    $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', "wren-remote-$name", [IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(2000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $q = Wren-Ctl quit --code 7
    Check 'quit waits for the end and reports the exit code' ($global:WrenExit -eq 0 -and $q -match 'exit code 7') "$q | $global:WrenErr"
    Check 'closing with a client connected takes < 8 s' ($sw.ElapsedMilliseconds -lt 8000) "$($sw.ElapsedMilliseconds) ms"
    $pipe.Dispose()
    Check 'the pipe is gone after quit' (@(Pipe-Names | Where-Object { $_ -like "*wren-remote-$name" }).Count -eq 0)
} finally {
    Stop-WrenTestServer $server
    if ($env:WREN_REMOTE) { Stop-Wren }
    foreach ($p in $started) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
    Remove-Item Env:\WREN_REMOTE -ErrorAction SilentlyContinue
}

Section '3 wren ctl run (one call)'
# ---- 3. `run`: the one-call form ------------------------------------------------------------------------------------------------
$server = Start-WrenTestServer
try {
    $url = "$($server.Origin)/site/remote/fixture.htm"
    $out = Join-Path $tmp 'run.png'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Wren-Run -Url $url -Shot $out -Size 1000x700 -Wait idle -Eval 'document.title'
    $runMs = $sw.ElapsedMilliseconds
    Check 'run: loads, evaluates, captures, closes (exit 0)' ($global:WrenExit -eq 0 -and $r -match 'Remote fixture' -and (Test-Path $out)) "exit $global:WrenExit $global:WrenErr"
    "      run took $runMs ms (start, load, wait idle, eval, capture, close)"
} finally { Stop-WrenTestServer $server }

# ---- 4. a playing video is a plane of the page's paint order: the same picture every frame ------------------------------------
# examples/site/remote/video-layers.htm: a video in a rounded overflow:hidden box, a fixed dialog (z-index) and a bar over it, a
# rotated half-transparent rounded video, and a script that keeps the thread busy a few ms every frame (so that frames are made
# under it, as under a player's). Forty captures in a row while it plays: in each the box's corners are rounded, the dialog and
# the bar are above the video, and what is not the video is the same pixel for pixel in every capture.
$server = Start-WrenTestServer
try {
    $env:WREN_TEST_BASE_PORT = "$($server.BasePort)"
    Section '4a video layers: start, wait idle, 2 s sleep'
    $null = Start-Wren -Dpi 96 -Size 1000x500 -Url "$($server.Origin)/site/remote/video-layers.htm"
    $null = Wren-Ctl wait idle
    Start-Sleep 2
    Section '4b video layers: 40 captures'
    $n = 40
    $shots = @()
    for ($i = 0; $i -lt $n; $i++) { $f = Join-Path $tmp "vl$i.png"; $null = Wren-Ctl shot $f --tab; $shots += $f; Start-Sleep -Milliseconds 25 }
    Section '4c video layers: pixels of the 40 captures (PowerShell GetPixel)'
    $badCorner = 0; $badDialog = 0; $badBar = 0
    $strict = @()   # regions that are never the video: the dialog, the bar, the box's four corners (outside the rounding)
    $bmps = @()
    foreach ($f in $shots) { $bmps += ,(New-Object Drawing.Bitmap($f)) }
    try {
        foreach ($b in $bmps) {
            $c = $b.GetPixel(45, 45); $d = $b.GetPixel(300, 150); $bar = $b.GetPixel(200, 255)
            if (-not ($c.R -gt 200 -and $c.R -lt 240 -and [Math]::Abs($c.R - $c.G) -lt 4 -and [Math]::Abs($c.R - $c.B) -lt 4)) { $badCorner++ }
            if (-not ($d.R -gt 190 -and $d.G -lt 70 -and $d.B -lt 70)) { $badDialog++ }
            if (-not ($bar.B -gt 180 -and $bar.R -lt 60 -and $bar.G -lt 110)) { $badBar++ }
        }
        Check "video layers: $n captures, the box's corner is rounded in all (missing in $badCorner)" ($badCorner -eq 0)
        Check "video layers: the dialog is above the video in all (hidden in $badDialog)" ($badDialog -eq 0)
        Check "video layers: the bar is above the video in all (hidden in $badBar)" ($badBar -eq 0)
        # frame to frame: regions that are not the video must not change at all (the dialog, the bar, the corners)
        $regions = @(@(236, 96, 250, 108), @(60, 242, 360, 26), @(41, 41, 14, 14), @(425, 41, 14, 14), @(41, 265, 14, 14), @(425, 265, 14, 14))
        $changed = 0
        for ($i = 1; $i -lt $n; $i++) {
            $diff = $false
            foreach ($r in $regions) {
                for ($y = $r[1]; $y -lt $r[1] + $r[3] -and -not $diff; $y += 3) {
                    for ($x = $r[0]; $x -lt $r[0] + $r[2]; $x += 3) {
                        $p = $bmps[$i - 1].GetPixel($x, $y); $q = $bmps[$i].GetPixel($x, $y)
                        if ($p.ToArgb() -ne $q.ToArgb()) { $diff = $true; break }
                    }
                }
                if ($diff) { break }
            }
            if ($diff) { $changed++ }
        }
        Check "video layers: nothing but the video changes between two captures (changed in $changed of $($n - 1))" ($changed -eq 0)
        # the video moves at all (the test is of a playing video)
        $moves = 0
        for ($i = 1; $i -lt $n; $i++) { if ($bmps[$i - 1].GetPixel(120, 120).ToArgb() -ne $bmps[$i].GetPixel(120, 120).ToArgb() -or $bmps[$i - 1].GetPixel(330, 220).ToArgb() -ne $bmps[$i].GetPixel(330, 220).ToArgb()) { $moves++ } }
        Check "video layers: the video plays ($moves of $($n - 1) captures differ in the video)" ($moves -gt 3)
    } finally { foreach ($b in $bmps) { $b.Dispose() } }
} finally { Stop-Wren; Stop-WrenTestServer $server }
# ---- 5. a layout read by a script in a page just navigated to uses that page's images, videos and SVG ------------------------------
# The shell's "page whose natural sizes layout reads" was set by the frame's own layout only: a layout forced by a script (the first
# thing a page does) before any frame of the new page read the previous frame's page: another document (an image of the page before
# at the same place of the tree gave its size: 77 x 33) or one already freed (an access violation in shell_intrinsic, on youtube.com's
# watch page). The page after a page with an image of 77 x 33 reads its own image's width at once: never 77.
$server = Start-WrenTestServer
try {
    $env:WREN_TEST_BASE_PORT = "$($server.BasePort)"
    Section '5 layout read by a script after a navigation'
    $null = Start-Wren -Dpi 96 -Size 800x500 -Url "$($server.Origin)/site/remote/layout-sized.htm"
    $null = Wren-Ctl wait idle
    $null = Wren-Ctl nav "$($server.Origin)/site/remote/layout-first.htm" --wait idle
    $first = Wren-Eval 'window.first'
    Check "layout read first by a script: the image's width is this page's, not the page before's 77 (got $first)" ($first -match '^\d' -and $first -notmatch '^77:') "exit $global:WrenExit $global:WrenErr"
    $null = Wren-Ctl ping
    Check 'and the Wren answers' ($global:WrenExit -eq 0)
} finally { Stop-Wren; Stop-WrenTestServer $server }
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Show-WrenSections remote_e2e
if ($script:fail -gt 0) { "$script:fail check(s) failed: " + ($script:failedNames -join " | "); exit 1 }
'remote_e2e: all checks passed'
