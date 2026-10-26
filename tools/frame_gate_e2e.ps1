# The frame gate end to end (windows.odin, toolkit platform/frame_gate.odin: every frame of the thread through one state machine,
# a frame asked for where none may begin is deferred, never nested). One Wren, its window shown where nobody sees nor touches it
# (fully transparent, click-through, at the bottom: a window never shown gets no WM_PAINT), driven with wren ctl; each source of
# re-entrance, then the process must answer, have left no crash report, and the gate must count no violation (the dev build
# panics on one: windows.odin frame_gate_init):
#   * a drag of the page taken out of the window and back (the system's drag, played through the window's own drop target: its
#     loop pumps the thread's messages and repaints the window between the steps): the repaints are deferred, drop before dragend;
#   * a long script of the page while input waits (the chrome preempts it: chrome frames, Light, inside the full frame's page
#     phase, counted as nested), and the window repainted meanwhile;
#   * the page's context menu (a menu of the chrome): opened by a right click, frames drawn while it is open, closed by Escape.
# The system menu (a loop of the system from the frame's end) is tools\system_menu_e2e.ps1 (it needs the desktop), a live
# resize begun inside a chrome frame tools\resize_e2e.ps1.
#   powershell -NoProfile -File tools\frame_gate_e2e.ps1 [-Exe build\wren.exe]
param([string]$Exe = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
. "$PSScriptRoot\wrenctl.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GateE2e {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool InvalidateRect(IntPtr h, IntPtr r, bool erase);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint f);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetLong(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetLong(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
    public static IntPtr FindWindow(uint pid) {
        IntPtr found = IntPtr.Zero; int best = 0;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            RECT r; if (p == pid && GetClientRect(h, out r) && r.r * r.b > best) { best = r.r * r.b; found = h; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    // shown where nobody sees nor touches it: LAYERED | TRANSPARENT | TOOLWINDOW | NOACTIVATE, alpha 0, at the bottom
    public static void ShowUnseen(IntPtr h) {
        long ex = (long)GetLong(h, -20);
        SetLong(h, -20, (IntPtr)((ex | 0x80000 | 0x20 | 0x80 | 0x08000000) & ~0x40000L));
        SetLayeredWindowAttributes(h, 0, 0, 2);
        SetWindowPos(h, (IntPtr)1, 40, 40, 0, 0, 0x0001 | 0x0010);
        ShowWindow(h, 8);
    }
}
'@
$fail = 0
function Check([bool]$ok, [string]$what, [string]$detail = '') { if ($ok) { "PASS  $what" } else { "FAIL  $what  $detail"; $script:fail++ } }
function Gate { return (Wren-Ctl stats --json | ConvertFrom-Json) }
function Alive([string]$what) {
    $null = Wren-Ctl ping --timeout 10000
    $crashes = @(Get-ChildItem (Join-Path $prof 'crashes') -Filter 'crash *.txt' -ErrorAction SilentlyContinue)
    $st = if ($global:WrenExit -eq 0) { Gate } else { $null }
    Check ($st -ne $null -and $crashes.Count -eq 0 -and $st.frameGate.violations -eq 0) "${what}: the process answers, no crash report, no violation of the gate" "(ctl exit $global:WrenExit, $($crashes.Count) report(s), violations $(if ($st) { "$($st.frameGate.violations) $($st.frameGate.lastViolation)" }))" | Out-Host
    return $st
}

$prof = Join-Path $env:TEMP ('wren-gate-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$page = 'file:///' + ((Join-Path $root 'examples\dnd\dnd.html') -replace '\\', '/')
$null = Start-Wren -Size 1000x700 -Dpi 96 -ProfileDir $prof -Pref 'blocker.update.enabled=false' -Url 'about:blank'
try {
    Wren-Ctl wait frames 4 | Out-Null
    $hwnd = [GateE2e]::FindWindow([uint32](Gate).pid)
    if ($hwnd -eq [IntPtr]::Zero) { throw 'no window of the process' }
    [GateE2e]::ShowUnseen($hwnd)
    Wren-Ctl nav $page --wait load | Out-Null
    $s0 = Alive 'start'

    # ---- the system's drag of the page's drag: out of the window and back onto the zone
    Wren-Ctl eval "log.length = 0; 'ok'" | Out-Null
    Wren-Ctl drag '50,30' '-300,30' '-300,200' '100,150' --steps 8 | Out-Null
    Start-Sleep -Milliseconds 200
    $log = Wren-Ctl eval "log.join(' | ')"
    $iDrop = $log.IndexOf('drop@zone'); $iEnd = $log.IndexOf('dragend@src')
    Check ($iDrop -ge 0 -and $iEnd -gt $iDrop) 'drag out of the window and back: drop before dragend' $log
    $s1 = Alive 'drag'
    Check ($s1.frameGate.deferred -gt $s0.frameGate.deferred) "the repaints asked for during the drag's loop were deferred ($($s1.frameGate.deferred - $s0.frameGate.deferred)), not made inside the frame that runs it"

    # ---- a long script while input waits: chrome frames (Light) inside the page phase
    $before = Gate
    Wren-Ctl eval "setTimeout(() => { const t = performance.now(); while (performance.now() - t < 1500) {} }, 50); 'ok'" | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds 150
    while ($sw.ElapsedMilliseconds -lt 1400) {
        $x = 200 + ($sw.ElapsedMilliseconds % 300); $y = 300
        [GateE2e]::PostMessageW($hwnd, 0x0200, [IntPtr]::Zero, [IntPtr](($y -shl 16) -bor $x)) | Out-Null   # WM_MOUSEMOVE
        [GateE2e]::InvalidateRect($hwnd, [IntPtr]::Zero, $false) | Out-Null
        Start-Sleep -Milliseconds 15
    }
    Start-Sleep -Milliseconds 400
    $s2 = Alive 'a long script with input waiting'
    Check ($s2.frameGate.nested -gt $before.frameGate.nested) "chrome frames were made inside the page phase ($($s2.frameGate.nested - $before.frameGate.nested) nested frames)"

    # ---- the page's context menu: a menu of the chrome, frames go on while it is open
    $before = Gate
    Wren-Ctl click '200,300' --right | Out-Null
    Wren-Ctl wait frames 3 | Out-Null
    $open = Gate
    Check ($open.menuOpen -eq $true) 'a right click on the page opens the context menu' "(menuOpen $($open.menuOpen))"
    Check ($open.framesDrawn -gt $before.framesDrawn) "frames are drawn while it is open ($($open.framesDrawn - $before.framesDrawn))"
    Wren-Ctl key Escape | Out-Null
    Wren-Ctl wait frames 2 | Out-Null
    $s3 = Alive 'the context menu'
    Check ($s3.menuOpen -eq $false) 'Escape closes it' "(menuOpen $($s3.menuOpen))"
    "frame gate: $($s3.frameGate.begun) frames, $($s3.frameGate.nested) nested, $($s3.frameGate.deferred) deferred, $($s3.frameGate.violations) violations"
} finally {
    try { Stop-Wren } catch { }
    Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { "frame_gate_e2e: $fail check(s) failed"; exit 1 }
'frame_gate_e2e: all checks passed'
