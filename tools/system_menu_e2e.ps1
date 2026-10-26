# The system menu of the Wren icon (integrated title bar, window_chrome.odin): a click opens it, Escape closes it, and the process
# must live. It used to be opened during the build: its loop (TrackPopupMenu) painted the window from WM_PAINT, that frame was
# built inside the one being built, and the outer build went on with an empty parent stack (the crash of the 2026-10-26
# experimental build: a bounds check in ui.spacer, after app_icon). Now the menu opens after the frame (windows.odin: the frame gate).
# Needs the desktop (a visible window, a real popup menu: desktop.lock); the click itself is injected (Wren.click in window pixels).
#   powershell -NoProfile -File tools\system_menu_e2e.ps1 [-Exe build\wren.exe] [-Rounds 3] [-HoldMs 600] [-Positions top,left]
# For each position of the tabs (browser.tabs.position: the icon is in the row of tabs, or in the sidebar's title bar), one Wren;
# a round: click the icon, wait for the menu (class #32768 of the Wren's process), leave it open -HoldMs (the menu's loop paints
# the window meanwhile: about 16 ms per frame), Escape, then the process must answer and have left no crash report.
param([string]$Exe = '', [int]$Rounds = 3, [int]$HoldMs = 600, [string[]]$Positions = @('top', 'left'))
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\test_env.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$Exe = (Resolve-Path $Exe).Path
$env:WREN_EXE = $Exe
. "$PSScriptRoot\wrenctl.ps1"
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public class SM {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  // a visible popup menu (#32768) of process `pid`
  public static IntPtr Menu(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h)) return true;
      var sb = new StringBuilder(64); GetClassName(h, sb, 64);
      if (sb.ToString() == "#32768") { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@
$WM_KEYDOWN = 0x0100; $WM_KEYUP = 0x0101; $VK_ESCAPE = 0x1B; $WM_CANCELMODE = 0x001F
$fail = 0
$tmp = Join-Path $env:TEMP "wren-sysmenu-e2e-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:WREN_SINGLE_INSTANCE = 'off'
$lock = Enter-WrenLock desktop 'system_menu_e2e'
$prof = Join-Path $tmp 'profile'
$p = $null
try {
  foreach ($pos in $Positions) {
    if ($fail) { break }
    Section "start ($pos): the Wren, its window shown, the tabs $(if ($pos -eq 'top') { 'in the title bar' } else { 'in a sidebar, the icon in the title bar' })"
    # (100 % scale: the icon is 16 px at x 10..26, centred in the title bar of 32 px or more, in both layouts)
    $null = Start-Wren -Visible -Size 1000x700 -Dpi 100 -ProfileDir "$prof-$pos" -Pref 'browser.window.integrated_titlebar=true', "browser.tabs.position=$pos", 'blocker.update.enabled=false'
    $wpid = [int]((Wren-Ctl ping --json | ConvertFrom-Json).pid)
    $p = Get-Process -Id $wpid
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 50; $p.Refresh() }
    $h = $p.MainWindowHandle
    [SM]::SetForegroundWindow($h) | Out-Null
    for ($round = 1; $round -le $Rounds; $round++) {
        Section "round ${round}: a click on the icon opens the system menu"
        $before = Wren-Ctl stats --json | ConvertFrom-Json
        # (not waited for: the call's reply may need frames that the menu's loop makes)
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = 'ctl click 18,17 --window'   # (the Wren: $env:WREN_REMOTE, inherited)
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $click = [Diagnostics.Process]::Start($psi)
        $menu = [IntPtr]::Zero
        $sw.Restart()
        while ($menu -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 10000 -and -not $p.HasExited) {
            Start-Sleep -Milliseconds 25
            $menu = [SM]::Menu([uint32]$wpid)
        }
        if ($menu -eq [IntPtr]::Zero) {
            $p.Refresh()
            "FAIL  $pos, round ${round}: no system menu appeared within 10 s (process $(if ($p.HasExited) { "ended, exit code $($p.ExitCode)" } else { 'running' }))"
            $fail++
            break
        }
        Start-Sleep -Milliseconds $HoldMs
        Section "round ${round}: Escape closes it"
        [SM]::PostMessage($h, $WM_KEYDOWN, [IntPtr]$VK_ESCAPE, [IntPtr]1) | Out-Null
        [SM]::PostMessage($h, $WM_KEYUP, [IntPtr]$VK_ESCAPE, [IntPtr]0xC0000001L) | Out-Null
        $sw.Restart()
        while ([SM]::Menu([uint32]$wpid) -ne [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 25 }
        if ([SM]::Menu([uint32]$wpid) -ne [IntPtr]::Zero) {
            $r = [IntPtr]::Zero
            [SM]::SendMessageTimeout($h, $WM_CANCELMODE, [IntPtr]::Zero, [IntPtr]::Zero, 2, 3000, [ref]$r) | Out-Null
        }
        $click.WaitForExit(15000) | Out-Null
        if (-not $click.HasExited) { $click.Kill() }
        Section "round ${round}: does it live?"
        Start-Sleep -Milliseconds 300   # (a crash report is written before the process ends)
        $null = Wren-Ctl ping --timeout 10000
        $p.Refresh()
        $crashes = @(Get-ChildItem (Join-Path "$prof-$pos" 'crashes') -Filter 'crash *.txt' -ErrorAction SilentlyContinue)
        $alive = -not $p.HasExited -and $global:WrenExit -eq 0
        $after = if ($alive) { Wren-Ctl stats --json | ConvertFrom-Json } else { $null }
        # (the menu's loop ran, and the window was painted meanwhile: frames from WM_PAINT, drawn outside the frame that opened it)
        $loops = if ($after) { $after.modalLoops - $before.modalLoops } else { 0 }
        $drawn = if ($after) { $after.framesDrawn - $before.framesDrawn } else { 0 }
        if ($alive -and $crashes.Count -eq 0 -and $loops -lt 1) {
            "FAIL  $pos, round ${round}: no loop of the system was counted (modalLoops $($before.modalLoops) -> $($after.modalLoops)): the menu did not run its loop in this process"
            $fail++
            break
        }
        # (the frame gate, windows.odin: the menu's frames came through it, none where no frame may begin)
        $violations = if ($after) { $after.frameGate.violations } else { 0 }
        if ($alive -and $crashes.Count -eq 0 -and $violations -ne 0) {
            "FAIL  $pos, round ${round}: the frame gate counted $violations violation(s): $($after.frameGate.lastViolation)"
            $fail++
            break
        }
        if ($alive -and $crashes.Count -eq 0) { "PASS  $pos, round ${round}: the menu was open $HoldMs ms and closed, and the process lives ($loops loop(s) of the system, $drawn frames drawn meanwhile, no violation of the frame gate)" }
        else {
            "FAIL  $pos, round ${round}: the process ended or does not answer (exit code $(if ($p.HasExited) { $p.ExitCode } else { 'still running' }), ctl exit $global:WrenExit); $($crashes.Count) crash report(s)"
            foreach ($c in $crashes) { Get-Content $c.FullName | Select-Object -First 16 }
            $fail++
            break
        }
    }
    if (-not $p.HasExited) { Stop-Wren; $p.WaitForExit(10000) | Out-Null }
  }
} finally {
    Exit-WrenLock $lock
    try { if ($p -and -not $p.HasExited) { Stop-Wren } } catch { }
    if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) | Out-Null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Show-WrenSections system_menu_e2e
if ($fail) { "system_menu_e2e: $fail round(s) failed"; exit 1 }
'system_menu_e2e: all rounds passed'
