# The main menu that reaches the window's edge (no window shown, no real mouse): where it is drawn, the window answers the
# system's hit test (WM_NCHITTEST, sent as the system does) with "client", not a resize band: the band's diagonal cursor
# showed over the menu, and the pointer's moves never reached it, so the lit row stayed where the pointer had been.
# Beside the menu, the band is still there.
#   powershell -NoProfile -File tools\menu_edge_e2e.ps1 [-Exe build\wren.exe]
param([string]$Exe = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\wrenctl.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MenuEdge {
    [DllImport("user32.dll")] static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
    public static IntPtr FindWindow(uint pid) {
        IntPtr found = IntPtr.Zero; int best = 0;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            RECT r; if (p == pid && GetClientRect(h, out r) && r.r * r.b > best) { best = r.r * r.b; found = h; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint f);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetLong(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetLong(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
    // shown (a window never shown has no frame to resize) where nobody sees nor touches it: fully transparent, the pointer
    // passing through it, at the bottom of the windows, no taskbar button, never activated
    public static void ShowUnseen(IntPtr h) {
        long ex = (long)GetLong(h, -20);
        SetLong(h, -20, (IntPtr)((ex | 0x80000 | 0x20 | 0x80 | 0x08000000) & ~0x40000L));   // LAYERED | TRANSPARENT | TOOLWINDOW | NOACTIVATE
        SetLayeredWindowAttributes(h, 0, 0, 2);
        SetWindowPos(h, (IntPtr)1, 40, 40, 0, 0, 0x0001 | 0x0010);   // HWND_BOTTOM, NOSIZE | NOACTIVATE
        ShowWindow(h, 8);
    }
    public static int Size(IntPtr h, bool height) { SetThreadDpiAwarenessContext((IntPtr)(-4)); RECT r; GetClientRect(h, out r); return height ? r.b : r.r; }
    // the system's hit test at a client point
    public static int Hit(IntPtr h, int x, int y) {
        SetThreadDpiAwarenessContext((IntPtr)(-4));
        POINT p = new POINT { x = x, y = y };
        ClientToScreen(h, ref p);
        return (int)SendMessageW(h, 0x0084, IntPtr.Zero, (IntPtr)(((p.y & 0xFFFF) << 16) | (p.x & 0xFFFF)));
    }
}
'@
$fail = 0
function Pass($m) { "PASS  $m" }
function Fail($m) { "FAIL  $m"; $script:fail++ }
$names = @{ 1 = 'client'; 2 = 'caption'; 10 = 'left'; 11 = 'right'; 12 = 'top'; 13 = 'top left'; 14 = 'top right'; 15 = 'bottom'; 16 = 'bottom left'; 17 = 'bottom right' }
function Name($h) { if ($names.ContainsKey($h)) { $names[$h] } else { "$h" } }

# the tabs in a sidebar: the menu button is in the integrated title bar, near the window's right end
$null = Start-Wren -Size 1280x500 -Dpi 96 -Pref 'browser.tabs.position=left' -Url 'about:blank'
try {
    Wren-Ctl wait frames 4 | Out-Null
    $hwnd = [MenuEdge]::FindWindow([uint32](Wren-Ctl stats --json | ConvertFrom-Json).pid)
    if ($hwnd -eq [IntPtr]::Zero) { throw 'no window of the process' }
    [MenuEdge]::ShowUnseen($hwnd)
    Start-Sleep -Milliseconds 500
    Wren-Ctl wait frames 3 | Out-Null
    $w = [MenuEdge]::Size($hwnd, $false); $h = [MenuEdge]::Size($hwnd, $true)
    # (the left, right and bottom borders are the system's frame, outside the client area; the top band is inside it, over
    # the title bar, and its right end is the top right corner)
    $corner0 = [MenuEdge]::Hit($hwnd, $w - 4, 2)
    $top0 = [MenuEdge]::Hit($hwnd, [int]($w / 2), 2)
    if ($corner0 -eq 14 -and $top0 -eq 12) { Pass 'no menu: the top band resizes, its right end is the top right corner' } else { Fail "no menu: the top band answered $(Name $top0), its right end $(Name $corner0)" }
    # a menu taller than the window starts at its top: over the band
    Wren-Ctl cmd browser.main_menu | Out-Null
    Wren-Ctl wait frames 4 | Out-Null
    $corner = [MenuEdge]::Hit($hwnd, $w - 4, 2)
    $band = [MenuEdge]::Hit($hwnd, $w - 100, 2)
    $top = [MenuEdge]::Hit($hwnd, [int]($w / 2), 2)
    if ($corner -eq 1 -and $band -eq 1) { Pass 'the open menu over the top band and its corner is the browser''s' } else { Fail "the open menu over the top band answered $(Name $band), at the corner $(Name $corner) (a menu that does not reach the top: check the window's height)" }
    if ($top -eq 12) { Pass 'beside the menu the top band still resizes' } else { Fail "beside the menu the top band answered $(Name $top)" }
} finally { Stop-Wren | Out-Null }
if ($fail) { "menu_edge_e2e: $fail check(s) failed"; exit 1 }
'menu_edge_e2e: all checks passed'
