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
# What measures time (the idle CPU and frames in 3 s, the closing times, all of -Stress) is a performance test: it runs only with
# WREN_PERF=1 (test_all.ps1 -Perf) and never when CI is set; otherwise it says "perf: skipped, run with -Perf" (Check-Perf, test_env.ps1).
#
# One Wren serves most of the scenarios (a start and a close are 0.6 s of work and the CPU of a start-up that must settle): between two of
# them `wren ctl reset` puts it back (and the scenarios check that it does), and after a scenario that failed the reset is the first thing
# the next one gets, so one failure does not hide the others. A process of its own stays where the check is about a process's life: a Wren
# that was not asked for the channel, a second instance, a taken name, quit with a client connected, `run` (start, load, capture and close
# in one call), the closing under load. The waits are for conditions (`wren ctl wait quiet | function`, a file that appears), with limits.
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
# Waits until a process (one that has no channel to ask) has finished starting: its CPU time moves by less than 25 ms in a second (at most 30 s).
# A fixed delay is not enough on a busy machine, where the start-up work is still running when the measure of an idle process begins.
# (A Wren with the channel on is asked instead: `wren ctl wait quiet`, which is decided in the browser.)
function Wait-Quiet($proc) {
    $deadline = (Get-Date).AddSeconds(30)
    $samples = New-Object Collections.Generic.List[object]
    while ((Get-Date) -lt $deadline) {
        $proc.Refresh()
        $now = [pscustomobject]@{ At = [Diagnostics.Stopwatch]::GetTimestamp(); Cpu = $proc.TotalProcessorTime.TotalMilliseconds }
        $samples.Add($now)
        $old = $samples | Where-Object { ($now.At - $_.At) / [Diagnostics.Stopwatch]::Frequency -ge 1.0 } | Select-Object -Last 1
        if ($old -and $now.Cpu - $old.Cpu -lt 25) { return }
        Start-Sleep -Milliseconds 200
    }
}
function Pipe-Names { [IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -like '*wren-remote-*' } }
# Waits (at most $Seconds) until $Test returns true; returns whether it did.
function Wait-Until([scriptblock]$Test, [double]$Seconds = 10, [int]$PollMs = 50) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) { if (& $Test) { return $true }; Start-Sleep -Milliseconds $PollMs }
    return [bool](& $Test)
}

$tmp = Join-Path $env:TEMP "wren-remote-e2e-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$started = @()   # processes this script started (and the only ones it ends)

# ---- the shared Wren --------------------------------------------------------------------------------------------------------------
$script:wrenName = ''
$script:wrenPid = 0
function Start-Shared([int]$w = 1000, [int]$h = 700) {
    $script:wrenName = Start-Wren -Size "${w}x$h"
    $script:wrenPid = [int]((Wren-Ctl ping --json | ConvertFrom-Json).pid)
}
# After a scenario, passed or not: the next one starts from a clean Wren; when the reset itself fails the Wren is started again.
function Reset-Shared {
    $null = Wren-Ctl reset --timeout 30000
    if ($global:WrenExit -ne 0) {
        "      reset failed (exit $global:WrenExit $global:WrenErr): the shared Wren is started again"
        try { Stop-Wren } catch { }
        Start-Shared
    }
}
function Scenario([string]$name, [scriptblock]$body) {
    Section $name
    try { & $body } catch { Check "$name ran to its end" $false "$_ $($_.ScriptStackTrace)" }
    Reset-Shared
}

# ---- a playing video is a plane of the page's paint order: the same picture every frame ------------------------------------------
# examples/site/remote/video-layers.htm: a video in a rounded overflow:hidden box, a fixed dialog (z-index) and a bar over it, a
# rotated half-transparent rounded video, and a script that keeps the thread busy a few ms every frame (so that frames are made
# under it, as under a player's). Thirty frames in a row while it plays (6 in -Check): in each the box's corners are rounded, the dialog and
# the bar are above the video, and what is not the video is the same pixel for pixel in every capture.
function Test-VideoLayers($server, [int]$n = 30) {
    Section '4a video layers: scale 100 %, a 1000x500 window, the page, the videos playing'
    $null = Wren-Ctl pref set browser.ui.scale 1
    $null = Wren-Ctl window --size 1000x500
    $null = Wren-Ctl nav "$($server.Origin)/site/remote/video-layers.htm" --wait idle
    $null = Wren-Ctl wait function 'document.getElementById("v1").currentTime > 1 && document.getElementById("v2").currentTime > 1' --timeout 30000
    Check 'video layers: both videos play' ($global:WrenExit -eq 0) "exit $global:WrenExit $global:WrenErr"
    Section "4b video layers: $n captures"
    # --settle 0: each capture is the very next frame drawn (the default waits three, for a page that has just been changed: here the page is at
    # rest and playing, so the n captures are n frames in a row, a third of the frames made, and each frame is compared with the one before).
    # On the CI a frame of this page (two videos, a clipped and a rotated plane, a script busy 8 ms) costs about 0.7 s: 40 captures at the default
    # settle were 80 s there. The check build (every allocation tracked) asks for fewer: it looks for leaks, the layers are checked in the other mode.
    $null = Wren-Ctl shot (Join-Path $tmp 'vl.png') --tab --count $n --settle 0 -TimeoutSec $(if ($Check) { 600 } else { 240 })
    $digits = "$($n - 1)".Length   # (the client numbers the files to the width of the last number)
    $shots = @(0..($n - 1) | ForEach-Object { Join-Path $tmp ("vl-{0:D$digits}.png" -f $_) })
    Check "video layers: $n captures were made" (@($shots | Where-Object { Test-Path $_ }).Count -eq $n) "exit $global:WrenExit $global:WrenErr"
    Section "4c video layers: pixels of the $n captures (PowerShell GetPixel)"
    $badCorner = 0; $badDialog = 0; $badBar = 0
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
        Check "video layers: the video plays ($moves of $($n - 1) captures differ in the video)" ($moves -gt [Math]::Min(3, [int](($n - 1) / 4)))
    } finally { foreach ($b in $bmps) { $b.Dispose() } }
}

# ---- a layout read by a script in a page just navigated to uses that page's images, videos and SVG ------------------------------
# The shell's "page whose natural sizes layout reads" was set by the frame's own layout only: a layout forced by a script (the first
# thing a page does) before any frame of the new page read the previous frame's page: another document (an image of the page before
# at the same place of the tree gave its size: 77 x 33) or one already freed (an access violation in shell_intrinsic, on youtube.com's
# watch page). The page after a page with an image of 77 x 33 reads its own image's width at once: never 77.
function Test-LayoutSized($server) {
    Section '5 layout read by a script after a navigation'
    $null = Wren-Ctl pref set browser.ui.scale 1
    $null = Wren-Ctl window --size 800x500
    $null = Wren-Ctl nav "$($server.Origin)/site/remote/layout-sized.htm" --wait idle
    $null = Wren-Ctl nav "$($server.Origin)/site/remote/layout-first.htm" --wait idle
    $first = Wren-Eval 'window.first'
    Check "layout read first by a script: the image's width is this page's, not the page before's 77 (got $first)" ($first -match '^\d' -and $first -notmatch '^77:') "exit $global:WrenExit $global:WrenErr"
    $null = Wren-Ctl ping
    Check 'and the Wren answers' ($global:WrenExit -eq 0)
}

# ---- the checks of `reset` and the checkpoints: what they say they put back is back ------------------------------------------------
# A state is made in every place a reset reaches (two tabs, a zoomed page, cookies, local and session storage, a changed preference
# and a scale, a resized window, developer tools, a console line, a visit in the history, a wait nobody is going to end), then
# reset; everything must be as it was at the start, a page must see no cookie or storage, and what --keep names must be left alone.
function Test-Reset($server) {
    $url = "$($server.Origin)/site/remote/fixture.htm"
    $base = Wren-Ctl stats --json | ConvertFrom-Json
    $w0 = Wren-Ctl window --json | ConvertFrom-Json
    $scale0 = Wren-Ctl pref get browser.scroll.key_line_px

    function Dirty {
        $null = Wren-Ctl nav $url
        $null = Wren-Eval 'document.cookie = "reset_cookie=1; path=/"; localStorage.setItem("reset_key", "kept?"); sessionStorage.setItem("reset_session", "kept?"); console.log("a line for the console"); "set"'
        $null = Wren-Ctl tab new "$($server.Origin)/site/remote/layout-sized.htm" --wait load
        $null = Wren-Ctl cmd page.zoom_in
        $null = Wren-Ctl pref set browser.scroll.key_line_px 77
        $null = Wren-Ctl pref set browser.ui.scale 1.25
        $null = Wren-Ctl window --size 640x480
        $null = Wren-Ctl devtools console
    }
    Dirty
    $d = Wren-Ctl stats --json | ConvertFrom-Json
    Check 'reset: the state to put back is there (2 tabs, a cookie, a site of storage, a visit, developer tools open)' ($d.tabs -eq 2 -and $d.cookies -ge 1 -and $d.storageSites -ge 1 -and $d.historyVisits -ge 1 -and $d.devtools) "tabs=$($d.tabs) cookies=$($d.cookies) sites=$($d.storageSites) visits=$($d.historyVisits) devtools=$($d.devtools)"

    # a client waiting for something that will not come: the reset ends its wait with an error
    $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', "wren-remote-$($script:wrenName)", [IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(2000)
    $wr = New-Object IO.StreamWriter($pipe); $wr.AutoFlush = $true
    $rd = New-Object IO.StreamReader($pipe)
    $wr.WriteLine('{"id":7,"method":"Wren.wait","params":{"for":"selector","selector":"#never","timeout":20000}}')
    Start-Sleep -Milliseconds 100

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Wren-Ctl reset --json | ConvertFrom-Json
    $resetMs = $sw.ElapsedMilliseconds
    Check 'reset: exit 0 and it says what it removed' ($global:WrenExit -eq 0 -and $r.closedTabs -eq 2 -and $r.cookies -ge 1 -and $r.sites -ge 1 -and $r.prefsRestored -ge 2 -and $r.windowRestored) "exit $global:WrenExit $global:WrenErr $($r | ConvertTo-Json -Compress)"
    "      reset took $resetMs ms"
    $line = $rd.ReadLine()
    $pipe.Dispose()
    Check 'reset: a command another client was waiting on ends with an error' ($line -match '"id":7' -and $line -match 'cancelled by a reset') $line

    $s = Wren-Ctl stats --json | ConvertFrom-Json
    $tabs = @((Wren-Ctl tabs).Split("`n") | Where-Object { $_ })
    Check 'reset: one blank tab' ($tabs.Count -eq 1 -and $tabs[0] -match 'about:blank') ($tabs -join ' | ')
    Check 'reset: no cookie, site of storage, cached response, visit, closed tab in the numbers' ($s.cookies -eq 0 -and $s.storageSites -eq 0 -and $s.cacheEntries -eq 0 -and $s.historyVisits -eq 0 -and $s.closedTabs -eq 0) "$($s.cookies) $($s.storageSites) $($s.cacheEntries) $($s.historyVisits) $($s.closedTabs)"
    Check 'reset: developer tools closed' (-not $s.devtools)
    Check 'reset: the preferences are back' ((Wren-Ctl pref get browser.scroll.key_line_px) -eq $scale0 -and (Wren-Ctl pref get browser.ui.scale) -eq (Wren-Ctl pref get browser.ui.scale --json | ConvertFrom-Json).default)
    $w1 = Wren-Ctl window --json | ConvertFrom-Json
    Check 'reset: the window is the size it had' ($w1.width -eq $w0.width -and $w1.height -eq $w0.height) "$($w1.width)x$($w1.height) was $($w0.width)x$($w0.height)"
    Check 'reset: the page zoom is back to 100 %' ([Math]::Abs($w1.pageScale - $w1.uiScale) -lt 0.001 -and [Math]::Abs($w1.uiScale - $w0.uiScale) -lt 0.001) "page $($w1.pageScale) ui $($w1.uiScale) was $($w0.uiScale)"
    Check 'reset: the console and the network log of the tab hold nothing of the page before' ((Wren-Ctl console) -eq '' -and (Wren-Ctl network) -notmatch 'fixture|layout-sized')
    # what a page sees: the same origin as before holds nothing
    $null = Wren-Ctl nav $url
    $seen = Wren-Eval 'JSON.stringify([document.cookie, localStorage.getItem("reset_key"), sessionStorage.getItem("reset_session")])'
    Check 'reset: a page of the same site sees no cookie, no localStorage, no sessionStorage' ($seen -eq '["",null,null]') $seen

    # --keep leaves the named parts alone
    Dirty
    $r = Wren-Ctl reset --keep 'prefs,window' --json | ConvertFrom-Json
    $w2 = Wren-Ctl window --json | ConvertFrom-Json
    Check 'reset --keep prefs,window: they stay, tabs and data go' ((Wren-Ctl pref get browser.scroll.key_line_px) -eq '77' -and $w2.width -eq 640 -and $r.closedTabs -eq 2 -and $r.cookies -ge 1) "$($w2.width) $($r | ConvertTo-Json -Compress)"
    $bad = Wren-Ctl reset --keep nonsense
    Check 'reset --keep nonsense is refused' ($global:WrenExit -eq 1 -and $global:WrenErr -match 'keep:')
    $null = Wren-Ctl pref reset --all
    Check 'pref reset --all puts the preferences back' ((Wren-Ctl pref get browser.scroll.key_line_px) -eq $scale0)
    $null = Wren-Ctl pref set browser.scroll.key_line_px 61
    $null = Wren-Ctl pref reset browser.scroll.key_line_px
    Check 'pref reset <name> puts one preference back' ((Wren-Ctl pref get browser.scroll.key_line_px) -eq $scale0)
    $null = Wren-Ctl reset
}

function Test-Checkpoints($server) {
    $url = "$($server.Origin)/site/remote/fixture.htm"
    $null = Wren-Ctl nav $url
    $null = Wren-Eval 'document.cookie = "cp_session=A; path=/"; document.cookie = "cp_long=B; path=/; max-age=3600"; localStorage.setItem("cp_key", "one"); "set"'
    $null = Wren-Ctl tab new "$($server.Origin)/site/remote/layout-sized.htm" --wait load
    $null = Wren-Ctl pref set browser.scroll.key_line_px 51
    $null = Wren-Ctl cmd page.zoom_in
    $saved = Wren-Ctl checkpoint save one
    Check 'checkpoint save: says what it holds (2 tabs, 2 cookies, one origin of localStorage)' ($global:WrenExit -eq 0 -and $saved -match '2 tab\(s\), 2 cookie\(s\), localStorage of 1 origin') "exit $global:WrenExit $saved $global:WrenErr"
    Check 'checkpoint list' ((Wren-Ctl checkpoint list) -match '(?m)^one ')

    # afterwards: everything changes
    $null = Wren-Ctl reset
    $null = Wren-Ctl nav $url
    $null = Wren-Eval 'document.cookie = "cp_session=changed; path=/"; document.cookie = "cp_other=C; path=/"; localStorage.setItem("cp_key", "two"); localStorage.setItem("cp_new", "n"); "set"'
    $null = Wren-Ctl pref set browser.scroll.key_line_px 90
    $before = Wren-Ctl stats --json | ConvertFrom-Json

    $r = Wren-Ctl checkpoint restore one --json | ConvertFrom-Json
    Check 'checkpoint restore: exit 0 and the two tabs are back' ($global:WrenExit -eq 0 -and $r.tabs -eq 2) "exit $global:WrenExit $global:WrenErr $($r | ConvertTo-Json -Compress)"
    $tabs = @((Wren-Ctl tabs).Split("`n") | Where-Object { $_ })
    Check 'checkpoint restore: the tabs have their addresses, the current one is the second' ($tabs.Count -eq 2 -and $tabs[1] -match '^\d+\*' -and $tabs[0] -match 'fixture.htm' -and $tabs[1] -match 'layout-sized.htm') ($tabs -join ' | ')
    Check 'checkpoint restore: the preference' ((Wren-Ctl pref get browser.scroll.key_line_px) -eq '51')
    $seen = Wren-Eval '[document.cookie, localStorage.getItem("cp_key"), localStorage.getItem("cp_new")].join("|")'
    Check 'checkpoint restore: the cookies (session one too) and the localStorage are the saved ones' ($seen -match 'cp_session=A' -and $seen -match 'cp_long=B' -and $seen -notmatch 'cp_other' -and $seen -notmatch 'changed' -and $seen -match '\|one\|$') $seen
    $d = Wren-Ctl window --json | ConvertFrom-Json
    Check 'checkpoint restore: the zoom of the tab' ($d.pageScale -gt $d.uiScale) "page $($d.pageScale) ui $($d.uiScale)"
    $null = Wren-Ctl checkpoint delete one
    $null = Wren-Ctl checkpoint restore one
    Check 'checkpoint delete: it is gone' ($global:WrenExit -eq 1 -and $global:WrenErr -match 'no checkpoint')
    $null = Wren-Ctl checkpoint save 'bad name'
    Check 'checkpoint names are plain' ($global:WrenExit -eq 1)
}

if ($Stress -ne 0) {
    # the closing time under load is the whole point of this mode: a performance test (-Perf, WREN_PERF=1), never on the CI
    if (-not (Test-WrenPerf)) { Skip-WrenPerf 'closing under load (remote_e2e -Stress)'; exit 0 }
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
        Section 'stress: start the busy loops and wait until each one has run'
        for ($i = 0; $i -lt $cores; $i++) { $hogs += Start-Process -PassThru -WindowStyle Hidden -FilePath powershell -ArgumentList '-NoProfile', '-Command', 'while ($true) { }' }
        "      $cores busy loops running"
        $null = Wait-Until { @($hogs | Where-Object { $_.Refresh(); $_.TotalProcessorTime.TotalMilliseconds -lt 300 }).Count -eq 0 } 30 100
        $url = "$($server.Origin)/site/video.html"
        # (the video is waited for until it plays or, on a machine whose every core is busy, for a few seconds: the closing is timed either way)
        $playing = 'document.getElementById("round").currentTime > 0.5'
        $playLimitMs = 3000
        for ($round = 1; $round -le $Rounds; $round++) {
            Section "stress round ${round}: quit with a client connected"
            # 1. wren ctl quit, a client connected, a video playing
            $prof = Join-Path $tmp "stress-quit-$round"
            $name = Start-Wren -Size 800x600 -ProfileDir $prof
            $null = Wren-Ctl nav $url --timeout 60000
            $null = Wren-Ctl wait function $playing --timeout $playLimitMs
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
            # 2. the window closed as the X button does
            $prof = Join-Path $tmp "stress-x-$round"
            $name = Start-Wren -Size 800x600 -ProfileDir $prof
            $wpid = [int]((Wren-Ctl ping --json | ConvertFrom-Json).pid)
            $null = Wren-Ctl nav $url --timeout 60000
            $null = Wren-Ctl wait function $playing --timeout $playLimitMs
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
    # a session that touches every part of the channel, then a normal exit: the tracker lists what is still allocated. The shared scenarios
    # (reset, a checkpoint, the video planes) run in it too, before the exit: what they allocate is checked as well.
    Section 'check: a session that touches the whole channel'
    $prof = Join-Path $tmp 'check-profile'
    $env:WREN_MEMTRACK_FAIL = '1'
    $server = Start-WrenTestServer
    try {
        $env:WREN_TEST_BASE_PORT = "$($server.BasePort)"
        $url = "$($server.Origin)/site/remote/fixture.htm"
        # (a Wren that lives 15 s starts downloading the content blocker's lists from the internet: not in a test)
        $name = Start-Wren -Size 900x600 -ProfileDir $prof -Pref 'blocker.update.enabled=false'
        $script:wrenName = $name
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
        $null = Wren-Ctl wait quiet
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
        $null = Wren-Ctl reset   # (the session above left tabs, a window and preferences changed: the scenarios start from a clean Wren, as in the other mode)
        Test-Reset $server
        Test-Checkpoints $server
        $null = Wren-Ctl reset
        Test-VideoLayers $server 6
        Test-LayoutSized $server
        $null = Wren-Ctl reset
        Section 'check: quit and the leak report'
        $q = Wren-Ctl quit
        Check 'check build: exit code 0 after the session (nothing allocated)' ($global:WrenExit -eq 0 -and $q -match 'exit code 0') "$q | $global:WrenErr"
        $rep = Join-Path $prof 'memtrack.txt'
        if (Test-Path $rep) { Get-Content $rep | Select-Object -First 40 }
        Check 'the tracker reports 0 leaked blocks, 0 bad frees' ((Test-Path $rep) -and ((Get-Content $rep -Raw) -match ' 0 leaked block\(s\), 0 byte\(s\); 0 bad free\(s\)'))
    } finally {
        Stop-WrenTestServer $server
        Remove-Item Env:\WREN_MEMTRACK_FAIL -ErrorAction SilentlyContinue
        if ($env:WREN_REMOTE) { Stop-Wren }
    }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Show-WrenSections 'remote_e2e -Check'
    if ($script:fail -gt 0) { exit 1 }
    'remote_e2e -Check: clean'
    exit 0
}

# ---- 1. nothing is listening when the channel was not asked for, and an idle Wren costs no CPU ------------------------------
# This Wren starts first and idles while the driven one is used: its checks and its idle measure (together with the driven Wren's, in the
# same three seconds) come when the driven one is at rest.
Section '1 a Wren without --remote: start (it settles while the scenarios run)'
$prof0 = Join-Path $tmp 'plain'
$p0 = Start-Process -PassThru -FilePath $env:WREN_EXE -ArgumentList '--profile', $prof0, '--pref', 'blocker.update.enabled=false', '--no-single-instance', '--headless', 'about:blank'
$started += $p0

$server = Start-WrenTestServer
try {
    $url = "$($server.Origin)/site/remote/fixture.htm"
    $env:WREN_TEST_BASE_PORT = "$($server.BasePort)"

    # ---- 2. a driven Wren ---------------------------------------------------------------------------------------------------------
    Section '2a driven Wren: start, window, nav, eval'
    Start-Shared 1000 700
    $name = $script:wrenName
    $pidOf = $script:wrenPid
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

    # capture, from the render target: the red box, the page, an element, scaled
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

    # tabs, commands, preferences
    Section '2e driven Wren: tabs, cmds, prefs, stats'
    $null = Wren-Ctl tab new 'about:blank'
    Check 'a second tab' ((Wren-Ctl tabs).Split("`n").Count -eq 2)
    Check 'a command of the registry runs' ((Wren-Ctl cmds) -match 'tab.new')
    $null = Wren-Ctl pref set browser.scroll.key_line_px 50
    Check 'pref set and get' ((Wren-Ctl pref get browser.scroll.key_line_px) -eq '50')
    $st = Wren-Ctl stats --json | ConvertFrom-Json
    Check 'stats' ($st.tabs -eq 2 -and $st.workingSetBytes -gt 0)
    Check 'stats: the process (pid, CPU time, threads, handles)' ($st.pid -eq $pidOf -and $st.cpuTimeMs -gt 0 -and $st.threads -gt 1 -and $st.handles -gt 10 -and $st.uptimeMs -gt 0) "pid $($st.pid) cpu $($st.cpuTimeMs) threads $($st.threads) handles $($st.handles)"

    # both idle Wrens, in the same three seconds: the one that was not asked for the channel (nothing to ask it, so its CPU time is watched
    # from outside until it has settled) and the driven one (asked: `wait quiet` is decided in the browser)
    Section '2f idle: wait quiet (driven Wren), settled (the other)'
    $null = Wren-Ctl wait quiet --timeout 30000
    Check 'wait quiet: ends when the process is at rest, and says what it saw' ($global:WrenExit -eq 0) "exit $global:WrenExit $global:WrenErr"
    Wait-Quiet $p0
    Section '2g idle: 3 s of CPU of both'
    $proc = Get-Process -Id $pidOf
    Check 'no remote.json without --remote' (-not (Test-Path (Join-Path $prof0 'remote.json')))
    $selected = $env:WREN_REMOTE; Remove-Item Env:\WREN_REMOTE   # (the shared Wren is not the one asked about)
    $null = Wren-Ctl ping --profile $prof0 --timeout 300
    $env:WREN_REMOTE = $selected
    Check 'ctl finds no server (exit 3)' ($global:WrenExit -eq 3) "exit $global:WrenExit"
    # What an idle Wren must not do is loop: a loop that does not rest takes 3000 ms of CPU in 3 s and draws 180 frames. The CPU time and the frames
    # in a window of 3 s depend on the machine (a cold cache and other steps keep a process working for a while after it settled: 594 ms and 6 frames
    # were measured on the CI): a performance test, off unless -Perf (WREN_PERF=1), with its original bounds. (The logic behind the frame count, "a
    # request that only reads draws no frame", cannot be asserted as a count before and after the requests today: at this commit each read request
    # of Remote.ping, Wren.stats... over one connection still leaves one frame behind it.)
    if (Test-WrenPerf) {
        # (The CPU is read between the two `stats` calls, not around them: a call is a connection, a request and a reply, 16 to 47 ms of the
        # Wren's CPU time at the time, and the 62 to 219 ms once "unexplained" here were those two calls, not an idle Wren.)
        $frames0 = [double](Wren-Ctl stats --json | ConvertFrom-Json).framesDrawn
        $proc.Refresh(); $p0.Refresh()
        $a = $proc.TotalProcessorTime.TotalMilliseconds; $c1 = $p0.TotalProcessorTime.TotalMilliseconds
        Start-Sleep -Seconds 3
        $proc.Refresh(); $p0.Refresh()
        $idle1 = $proc.TotalProcessorTime.TotalMilliseconds - $a
        $idle0 = $p0.TotalProcessorTime.TotalMilliseconds - $c1
        $frames1 = [double](Wren-Ctl stats --json | ConvertFrom-Json).framesDrawn
        "      idle for 3 s: CPU $([int]$idle0) ms without remote, $([int]$idle1) ms with remote on; $($frames1 - $frames0) frame(s) drawn by the driven Wren"
        Check-Perf 'idle Wren without remote uses < 60 ms CPU in 3 s' ($idle0 -lt 60) "$([int]$idle0) ms"
        Check-Perf 'idle Wren with remote on uses < 60 ms CPU in 3 s' ($idle1 -lt 60) "$([int]$idle1) ms"
        Check-Perf 'idle Wren with remote on draws at most 3 frames in 3 s' (($frames1 - $frames0) -le 3) "$($frames1 - $frames0) frame(s)"
    } else {
        Skip-WrenPerf 'idle Wren: CPU time and frames drawn in 3 s'
    }
    if (-not $p0.HasExited) { Stop-Process -Id $p0.Id -Force }

    # raw protocol: a request line, an unknown method, a bad line; a client that vanishes in the middle of a wait
    Section '2h driven Wren: raw protocol, vanishing client, giant request, ACL'
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
    $big = [Text.Encoding]::ASCII.GetBytes([string]::new([char]65, 9MB))
    $reply = ''
    try { $pipe.Write($big, 0, $big.Length) } catch { }
    try { $rd = New-Object IO.StreamReader($pipe); $reply = $rd.ReadLine() } catch { }
    $pipe.Dispose()
    Check 'a giant request is refused' ($reply -match 'max_message_bytes' -or $reply -eq '' -or $reply -eq $null)
    $null = Wren-Ctl ping
    Check 'the server lives after a giant request' ($global:WrenExit -eq 0)

    # clients that connect and go at once (a security query such as Get-Acl, a probe): ConnectNamedPipe then fails with ERROR_NO_DATA,
    # which once ended the accept thread for good (the pipe vanished while the process lived: no ctl could reach it again)
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class PipeStorm {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFileW(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  public static int Run(string path, int n) { int ok = 0; for (int i = 0; i < n; i++) { IntPtr h = CreateFileW(path, 0xC0000000, 0, IntPtr.Zero, 3, 0, IntPtr.Zero); if (h != new IntPtr(-1)) { CloseHandle(h); ok++; } } return ok; }
}
'@
    $touched = [PipeStorm]::Run("\\.\pipe\wren-remote-$name", 20000)
    $null = Wren-Ctl ping
    Check 'the server lives after clients that connect and go at once' ($global:WrenExit -eq 0 -and $touched -gt 0) "exit $global:WrenExit, $touched connections"

    # the pipe is for this user only
    # (the server makes the next instance of its pipe a moment after it ended a connection: a path that does not exist for an instant on a slow machine)
    $acl = $null; for ($try = 0; $try -lt 30 -and -not $acl; $try++) { try { $acl = (Get-Acl "\\.\pipe\wren-remote-$name" -ErrorAction Stop).Access } catch { Start-Sleep -Milliseconds 100 } }
    if (-not $acl) { $acl = @() }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $others = @($acl | Where-Object { try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -ne $me } catch { $true } })
    Check 'the pipe lets in this user only' ($acl.Count -ge 1 -and $others.Count -eq 0) (($acl | ForEach-Object { $_.IdentityReference }) -join ',')

    # a second Wren with another profile has a name of its own; the same name is refused
    Section '2i second Wren, taken name'
    $prof2 = Join-Path $tmp 'second'
    $name2 = Start-Wren -Size 800x600 -ProfileDir $prof2 -Pref 'browser.scroll.key_line_px=33'
    $env:WREN_REMOTE = $name2
    $pid2 = (Wren-Ctl ping --json | ConvertFrom-Json).pid
    # a value given with --pref: set is refused, --override changes that layer, reset puts the value of the start back (this one is the
    # Wren with a --pref; the shared one has none)
    Check '--pref value: read back' ((Wren-Ctl pref get browser.scroll.key_line_px) -eq '33')
    $null = Wren-Ctl pref set browser.scroll.key_line_px 44
    Check '--pref value: pref set is refused (the command line decides for the run)' ($global:WrenExit -eq 1 -and $global:WrenErr -match 'command line') "exit $global:WrenExit $global:WrenErr"
    $null = Wren-Ctl pref set browser.scroll.key_line_px 44 --override
    Check '--pref value: pref set --override changes it' ((Wren-Ctl pref get browser.scroll.key_line_px) -eq '44')
    $null = Wren-Ctl reset
    Check '--pref value: reset puts back the value the Wren started with' ((Wren-Ctl pref get browser.scroll.key_line_px) -eq '33')
    $null = Wren-Ctl pref set browser.scroll.key_line_px 55 --override
    $null = Wren-Ctl pref reset browser.scroll.key_line_px
    Check '--pref value: pref reset <name> too' ((Wren-Ctl pref get browser.scroll.key_line_px) -eq '33')
    Stop-Wren $name2
    $env:WREN_REMOTE = $name
    $pid1 = (Wren-Ctl ping --json | ConvertFrom-Json).pid
    Check 'two instances answer separately' ($pid1 -ne $pid2 -and $pid1 -eq $pidOf)
    $prof3 = Join-Path $tmp 'third'
    $errFile = Join-Path $tmp 'taken.err'
    $p3 = Start-Process -PassThru -FilePath $env:WREN_EXE -ArgumentList '--profile', $prof3, '--pref', 'blocker.update.enabled=false', "--remote=$name", '--no-single-instance', '--headless', 'about:blank' -RedirectStandardError $errFile -RedirectStandardOutput (Join-Path $tmp 'taken.out')
    $started += $p3
    $null = Wait-Until { (Test-Path $errFile) -and ((Get-Content $errFile -Raw) -match 'taken') -or $p3.HasExited } 15
    Check 'a name taken by another Wren is reported' ((@(Get-Content $errFile -ErrorAction SilentlyContinue) -join "`n") -match 'taken')
    Check 'the first instance still answers under that name' ((Wren-Ctl ping --json | ConvertFrom-Json).pid -eq $pidOf)
    if (-not $p3.HasExited) { Stop-Process -Id $p3.Id -Force }

    # the scenarios of the state commands, on the same Wren
    Reset-Shared
    Scenario '2k reset: everything it names is put back' { Test-Reset $server }
    Scenario '2l checkpoints: save, change everything, restore' { Test-Checkpoints $server }
    Scenario '4 video layers' { Test-VideoLayers $server }
    Scenario '5 layout read by a script after a navigation' { Test-LayoutSized $server }

    # closing with a client connected, and the exit code
    Section '2j quit with a client connected'
    $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', "wren-remote-$name", [IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(2000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $q = Wren-Ctl quit --code 7
    Check 'quit waits for the end and reports the exit code' ($global:WrenExit -eq 0 -and $q -match 'exit code 7') "$q | $global:WrenErr"
    Check-Perf "closing with a client connected takes < 8 s ($($sw.ElapsedMilliseconds) ms)" ($sw.ElapsedMilliseconds -lt 8000) "$($sw.ElapsedMilliseconds) ms"
    $pipe.Dispose()
    Check 'the pipe is gone after quit' (@(Pipe-Names | Where-Object { $_ -like "*wren-remote-$name" }).Count -eq 0)

    # ---- 3. `run`: the one-call form (a Wren of its own: start, load, capture, close) -------------------------------------------
    Section '3 wren ctl run (one call)'
    Remove-Item Env:\WREN_REMOTE -ErrorAction SilentlyContinue
    $out = Join-Path $tmp 'run.png'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Wren-Run -Url $url -Shot $out -Size 1000x700 -Wait idle -Eval 'document.title'
    $runMs = $sw.ElapsedMilliseconds
    Check 'run: loads, evaluates, captures, closes (exit 0)' ($global:WrenExit -eq 0 -and $r -match 'Remote fixture' -and (Test-Path $out)) "exit $global:WrenExit $global:WrenErr"
    "      run took $runMs ms (start, load, wait idle, eval, capture, close)"
} finally {
    Stop-WrenTestServer $server
    if ($env:WREN_REMOTE) { Stop-Wren }
    foreach ($p in $started) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
    Remove-Item Env:\WREN_REMOTE -ErrorAction SilentlyContinue
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Show-WrenSections remote_e2e
if ($script:fail -gt 0) { "$script:fail check(s) failed: " + ($script:failedNames -join " | "); exit 1 }
'remote_e2e: all checks passed'
