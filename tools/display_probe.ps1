# What the screen really does, read three ways at once, once a second: for a monitor with a dynamic (Windows 11 DRR) or a
# variable (G-Sync, FreeSync) refresh rate, where the rate the system reports is not the rate frames are shown at.
#
#   powershell -NoProfile -File tools\display_probe.ps1 [-Seconds 30] [-Remote name]
#
#   modes   : EnumDisplaySettings (primary monitor): the current rate, and the highest rate offered at the current size (hzMax)
#   dwm     : DwmGetCompositionTimingInfo(NULL): rateRefresh, the rate the compositor says it runs at right now (a dynamic refresh
#             rate should raise it from 60 to 180 while something moves), and the rate it composes at.
#             DWM answers for the PRIMARY monitor only, and only to a NULL window handle (a handle gives E_INVALIDARG, 0x80070057;
#             a wrong cbSize 0x88980090: the size of the packed DWM_TIMING_INFO is 292). On another monitor read `hzSwapChain`.
#   wren    : `wren ctl stats` of a running Wren (-Remote name or $env:WREN_REMOTE): fps, the gaps between presents, hz (the
#             rate frames aim for), hzReported, hzMax, hzNow, hzSwapChain, variableRefresh
# Move the pointer over a window, or drag a tab in Wren, while it runs and watch rateRefresh.
param([int]$Seconds = 30, [string]$Remote = $env:WREN_REMOTE)
Set-Location (Split-Path $PSScriptRoot -Parent)
. tools\wrenctl.ps1
if ($Remote) { $env:WREN_REMOTE = $Remote }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DisplayProbe {
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct DWM_TIMING_INFO {
        public uint cbSize; public uint rrN, rrD; public ulong qpcRefreshPeriod; public uint rcN, rcD; public ulong qpcVBlank; public ulong cRefresh;
        public uint cDXRefresh; public ulong qpcCompose; public ulong cFrame; public uint cDXPresent; public ulong cRefreshFrame; public ulong cFrameSubmitted;
        public uint cDXPresentSubmitted; public ulong cFrameConfirmed; public uint cDXPresentConfirmed; public ulong cRefreshConfirmed;
        public uint cDXRefreshConfirmed; public ulong cFramesLate; public uint cFramesOutstanding; public ulong cFrameDisplayed; public ulong qpcFrameDisplayed;
        public ulong cRefreshFrameDisplayed; public ulong cFrameComplete; public ulong qpcFrameComplete; public ulong cFramePending; public ulong qpcFramePending;
        public ulong cFramesDisplayed; public ulong cFramesComplete; public ulong cFramesPending; public ulong cFramesAvailable; public ulong cFramesDropped;
        public ulong cFramesMissed; public ulong cRefreshNextDisplayed; public ulong cRefreshNextPresented; public ulong cRefreshesDisplayed;
        public ulong cRefreshesPresented; public ulong cRefreshStarted; public ulong cPixelsReceived; public ulong cPixelsDrawn; public ulong cBuffersEmpty;
    }
    // (the window handle must be NULL: with one the call fails with E_INVALIDARG; it answers for the primary monitor)
    [DllImport("dwmapi.dll")] static extern int DwmGetCompositionTimingInfo(IntPtr hwnd, ref DWM_TIMING_INFO info);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool EnumDisplaySettingsW([MarshalAs(UnmanagedType.LPWStr)] string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("kernel32.dll")] static extern bool QueryPerformanceFrequency(out long f);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public uint dmFields;
        public int px, py; public uint dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels; public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    public static IntPtr WindowOf(uint pid) {
        IntPtr found = IntPtr.Zero; int best = 0;
        EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); RECT r; if (p == pid && GetClientRect(h, out r) && r.r * r.b > best) { best = r.r * r.b; found = h; } return true; }, IntPtr.Zero);
        return found;
    }
    public static IntPtr Foreground() { return GetForegroundWindow(); }
    // current rate, highest rate at the current size, and the list of rates at it
    public static string Modes() {
        DEVMODE cur = new DEVMODE(); cur.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettingsW(null, -1, ref cur)) return "?";
        var rates = new System.Collections.Generic.SortedSet<uint>();
        for (int i = 0; i < 4096; i++) {
            DEVMODE dm = new DEVMODE(); dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettingsW(null, i, ref dm)) break;
            if (dm.dmPelsWidth == cur.dmPelsWidth && dm.dmPelsHeight == cur.dmPelsHeight && dm.dmBitsPerPel == cur.dmBitsPerPel) rates.Add(dm.dmDisplayFrequency);
        }
        return string.Format("{0}x{1} now {2} Hz, hzMax {3}, offered {4}", cur.dmPelsWidth, cur.dmPelsHeight, cur.dmDisplayFrequency, rates.Count > 0 ? new System.Collections.Generic.List<uint>(rates)[rates.Count - 1] : 0, string.Join("/", rates));
    }
    public static bool Timing(IntPtr h, out DWM_TIMING_INFO ti, out int hr) { ti = new DWM_TIMING_INFO(); ti.cbSize = (uint)Marshal.SizeOf(typeof(DWM_TIMING_INFO)); hr = DwmGetCompositionTimingInfo(h, ref ti); return hr == 0; }
    public static double Freq() { long f; QueryPerformanceFrequency(out f); return f; }
}
'@

$freq = [DisplayProbe]::Freq()
"modes: " + [DisplayProbe]::Modes()
$h = [IntPtr]::Zero   # (DWM answers for the primary monitor, and only to a NULL window handle)
$prev = $null
for ($s = 0; $s -lt $Seconds; $s++) {
    $ti = New-Object DisplayProbe+DWM_TIMING_INFO
    $hr = 0
    $ok = [DisplayProbe]::Timing($h, [ref]$ti, [ref]$hr)
    $line = '{0,3}s ' -f $s
    if ($ok) {
        # (cRefresh counts the calls of this process, not the screen's refreshes: the rate is rateRefresh / qpcRefreshPeriod)
        $line += 'dwm rateRefresh {0:N2} Hz (period {1:N3} ms), rateCompose {2:N1}, frames {3}, dropped {4}' -f ($ti.rrN / [Math]::Max($ti.rrD, 1)), ($ti.qpcRefreshPeriod * 1000 / $freq), ($ti.rcN / [Math]::Max($ti.rcD, 1)), $ti.cFrame, $ti.cFramesDropped
    } else { $line += ('dwm failed 0x{0:X8}' -f $hr) }
    if ($Remote) {
        $j = Wren-Ctl stats --json --reset-frames | ConvertFrom-Json
        if ($j) { $line += ' | wren fps {0:N0} gap p50 {1:N2} ms p95 {2:N2} | aims {3:N1} Hz (reported {4:N1}, max {5:N0}, now {6:N1}, swapchain {7:N1}) variable {8}' -f $j.fps, $j.frameGapP50Ms, $j.frameGapP95Ms, $j.hz, $j.hzReported, $j.hzMax, $j.hzNow, $j.hzSwapChain, $j.variableRefresh }
    }
    $line
    Start-Sleep -Seconds 1
}
