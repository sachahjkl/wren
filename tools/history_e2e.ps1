# End-to-end test of history in the real browser window (not part of test_all.ps1: it opens a window and needs the
# keyboard). examples/site/history/long.html scrolls the page and a box and fills its form by script, then goes to
# next.html; Alt+Left comes back; the page reports in its title what it found (scroll positions, form, whether it came
# from the back/forward cache), read from the window title. Runs twice: with the back/forward cache, then without (the
# entry loads again and its state is restored). The times of the traversals (WREN_HISTORY_TIMING) are printed.
# Starts build\testserver.exe on a block of ports of its own (tools\test_env.ps1) and holds desktop.lock only while a
# browser window is open (it is moved to the front and gets real keys), so other runs wait seconds, not the whole run.
#   powershell -File tools\history_e2e.ps1 [-Runs 3]
param([int]$Runs = 3)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
Add-Type @"
using System; using System.Runtime.InteropServices;
public class HE {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, IntPtr e);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
}
"@
$failed = 0
function Check($ok, $what) { if ($ok) { "PASS $what" } else { "FAIL $what"; $script:failed++ } }

function Wait-Title($p, $pattern, $ms) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        $p.Refresh()
        if ($p.MainWindowTitle -match $pattern) { return $p.MainWindowTitle }
        Start-Sleep -Milliseconds 50
    }
    $p.Refresh()
    return $null
}

function Alt-Left($h) {
    if ([HE]::GetForegroundWindow() -ne $h) {
        [HE]::keybd_event(0x12, 0, 0, [IntPtr]::Zero); [HE]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)
        [HE]::SetForegroundWindow($h) | Out-Null; Start-Sleep -Milliseconds 150
    }
    if ([HE]::GetForegroundWindow() -ne $h) { throw "the browser window is not in the foreground" }
    [HE]::keybd_event(0x12, 0, 0, [IntPtr]::Zero); [HE]::keybd_event(0x25, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 30
    [HE]::keybd_event(0x25, 0, 2, [IntPtr]::Zero); [HE]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)
}

function Run-Case($label, $prefs, $expectPersisted, $run) {
    $profile = Join-Path $root "build\history_e2e_profile_$label"
    if (Test-Path $profile) { Get-ChildItem $profile -File -Recurse | Remove-Item -Force }
    New-Item -ItemType Directory -Force $profile | Out-Null
    $timing = Join-Path $root "build\history_timing_$label.txt"
    $env:WREN_HISTORY_TIMING = $timing
    $args2 = @('--profile', $profile) + $prefs + @("$($script:srv.Origin)/site/history/long.html?auto")
    $desktop = Enter-WrenLock desktop "history_e2e.ps1 $label"
    $p = $null
    try {
        $p = Start-Process (Join-Path $root 'build\wren.exe') -ArgumentList $args2 -PassThru
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 20; $p.Refresh() }
        $h = $p.MainWindowHandle
        [HE]::SetWindowPos($h, [IntPtr](-1), 40, 40, 1280, 800, 0x10) | Out-Null
        $t = Wait-Title $p 'next$' 20000
        if ($t -eq $null) { "  title: $($p.MainWindowTitle)" }
        Check ($t -ne $null) "${label}: the page scrolled, filled its form and went on to the next page"
        Start-Sleep -Milliseconds 600
        Alt-Left $h
        $t = Wait-Title $p 'back persisted=' 15000
        "  title: $t"
        Check ($t -match "persisted=$expectPersisted") "${label}: back $(if ($expectPersisted -eq 'true') { 'from the back/forward cache (pageshow persisted)' } else { 'loads the page again' })"
        Check ($t -match ' y=2500 ') "${label}: the document is where it was left (2500 px), after its late content"
        Check ($t -match ' box=300 ') "${label}: the scroll container too (300 px)"
        Check ($t -match ' who=typed agree=true') "${label}: the form came back filled"
    } finally {
        if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) | Out-Null }
        Exit-WrenLock $desktop
        Remove-Item Env:\WREN_HISTORY_TIMING -ErrorAction SilentlyContinue
    }
    if (Test-Path $timing) {
        "  timing: $(Get-Content $timing | Select-Object -Last 1)"
    }
}

. (Join-Path $PSScriptRoot 'test_env.ps1')
$script:srv = Start-WrenTestServer
try {
    foreach ($label in 'bfcache', 'reload') { Remove-Item (Join-Path $root "build\history_timing_$label.txt") -ErrorAction SilentlyContinue }
    for ($i = 0; $i -lt $Runs; $i++) {
        Run-Case 'bfcache' @() 'true' $i
        Run-Case 'reload' @('--pref', 'history.bfcache.enabled=false') 'false' $i
    }
} finally {
    Stop-WrenTestServer $script:srv
}
"failed: $failed"
exit $failed
