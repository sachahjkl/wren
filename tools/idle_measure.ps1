# What a Wren at rest costs: CPU time, wakes of its threads (context switches, the system's own count), frames drawn and turns of
# its loop, over a fixed period, for each way of having a window and each kind of page. Run it on a desktop nobody looks at, a shown
# window is one of its cases:
#   powershell -File tools\test_desktop.ps1 -Command "powershell -NoProfile -File tools\idle_measure.ps1"
#   ... tools\idle_measure.ps1 -Exe build\baseline\wren.exe -Modes hidden -Pages static,field -Seconds 5
# One line per case; -Threads adds the threads that woke, by name. A driven Wren's channel is idle while it is measured: only the
# stats before and after go through it.
param([string]$Exe = '', [string[]]$Modes = @('shown', 'hidden', 'headless'), [string[]]$Pages = @('blank', 'static', 'field', 'anim', 'video'),
      [int]$Seconds = 10, [int]$SettleSeconds = 7, [switch]$Threads, [string[]]$Pref = @())
$ErrorActionPreference = 'Stop'
$Modes = $Modes -split ','; $Pages = $Pages -split ','   # (powershell -File hands a list over as one word)
$root =Split-Path $PSScriptRoot -Parent
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$Exe = (Resolve-Path $Exe).Path
$env:WREN_EXE = $Exe
. (Join-Path $PSScriptRoot 'wrenctl.ps1')

$ProcessInfoClass = 5        # SystemProcessInformation
$BufferBytes = 8MB
$ThreadQueryLimited = 0x800

Add-Type -TypeDefinition @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public class Idle_Thread { public int Id; public long Switches; public long Cpu100ns; }
public static class Idle_Probe {
  [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int size, out int need);
  [DllImport("kernel32.dll")] static extern IntPtr OpenThread(uint access, bool inherit, uint id);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern int GetThreadDescription(IntPtr h, out IntPtr name);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
  // The layout of SYSTEM_PROCESS_INFORMATION and SYSTEM_THREAD_INFORMATION on x64.
  const int NEXT = 0, THREADS = 4, PID = 0x50, PROCESS_SIZE = 0x100, THREAD_SIZE = 80, T_KERNEL = 0, T_USER = 8, T_TID = 48, T_SWITCHES = 64;
  public static List<Idle_Thread> Read(int pid, int cls, int bytes) {
    var list = new List<Idle_Thread>();
    IntPtr buf = Marshal.AllocHGlobal(bytes);
    try {
      int need;
      if (NtQuerySystemInformation(cls, buf, bytes, out need) != 0) throw new Exception("NtQuerySystemInformation");
      long p = buf.ToInt64();
      while (true) {
        if (Marshal.ReadIntPtr(new IntPtr(p + PID)).ToInt64() == pid) {
          int n = Marshal.ReadInt32(new IntPtr(p + THREADS));
          for (int i = 0; i < n; i++) {
            long t = p + PROCESS_SIZE + i * THREAD_SIZE;
            list.Add(new Idle_Thread { Id = Marshal.ReadInt64(new IntPtr(t + T_TID)).GetHashCode(), Switches = (uint)Marshal.ReadInt32(new IntPtr(t + T_SWITCHES)),
              Cpu100ns = Marshal.ReadInt64(new IntPtr(t + T_KERNEL)) + Marshal.ReadInt64(new IntPtr(t + T_USER)) });
          }
          break;
        }
        int next = Marshal.ReadInt32(new IntPtr(p + NEXT));
        if (next == 0) break;
        p += next;
      }
    } finally { Marshal.FreeHGlobal(buf); }
    return list;
  }
  public static string Name(int id, uint access) {
    IntPtr h = OpenThread(access, false, (uint)id);
    if (h == IntPtr.Zero) return "";
    IntPtr p; string s = "";
    if (GetThreadDescription(h, out p) >= 0 && p != IntPtr.Zero) { s = Marshal.PtrToStringUni(p); LocalFree(p); }
    CloseHandle(h);
    return s;
  }
}
"@

function Read-Threads([int]$procId) { return [Idle_Probe]::Read($procId, $ProcessInfoClass, $BufferBytes) }

$scratch = Join-Path ([IO.Path]::GetTempPath()) "wren_idle_$PID"
New-Item -ItemType Directory -Force $scratch | Out-Null
$video = Resolve-Path (Join-Path $root 'examples\site\media\video\clip.mp4') -ErrorAction SilentlyContinue
$pageHtml = @{
    static = '<!doctype html><meta charset="utf-8"><title>static</title><h1>A page that changes nothing</h1><p>Some text.</p>'
    field  = '<!doctype html><meta charset="utf-8"><title>field</title><p>A focused field:</p><input id="f" autofocus value="text"><script>document.getElementById("f").focus()</script>'
    anim   = '<!doctype html><meta charset="utf-8"><title>anim</title><style>@keyframes m{from{transform:translateX(0)}to{transform:translateX(300px)}}#b{width:80px;height:80px;background:#06c;animation:m 2s linear infinite}</style><div id="b"></div>'
}
if ($video) { $pageHtml.video = "<!doctype html><meta charset=`"utf-8`"><title>video</title><video src=`"$(([Uri]$video.Path).AbsoluteUri)`" autoplay muted loop width=`"480`"></video>" }

function Page-Url([string]$page) {
    if ($page -eq 'blank') { return 'about:blank' }
    if (-not $pageHtml.ContainsKey($page)) { return '' }
    $f = Join-Path $scratch "$page.html"
    [IO.File]::WriteAllText($f, $pageHtml[$page], (New-Object Text.UTF8Encoding $false))
    return ([Uri]$f).AbsoluteUri
}

function Frames-Of($stats) { return [int]$stats.framesDrawn }

'{0,-9}{1,-8}{2,9}{3,10}{4,10}{5,8}{6,8}{7,8}{8,9}' -f 'window', 'page', 'cpu ms/s', 'wakes/s', 'main/s', 'frames', 'fps', 'turns', 'turns/s'
foreach ($mode in $Modes) {
    foreach ($page in $Pages) {
        $url = Page-Url $page
        if (-not $url) { "$mode $page`: no such page here"; continue }
        $profileDir = Join-Path $scratch "p_$mode`_$page"
        $start = @{ Size = '1280x800'; ProfileDir = $profileDir; Url = 'about:blank'; Pref = (@('blocker.update.enabled=false', 'blocker.welcome_toast=false') + $Pref) }   # (a profile named: a first run's lists are not what is measured)
        if ($mode -eq 'shown') { $start.Visible = $true }
        if ($mode -eq 'headless') { $start.Headless = $true }
        $name = Start-Wren @start
        try {
            [void](Wren-Ctl nav $url --wait load)
            Start-Sleep -Seconds $SettleSeconds   # (past memory_trim and the status bar's settle: what is left is what stays)
            $s0 = Wren-Ctl stats --json | ConvertFrom-Json
            $wren = [int]$s0.pid
            $t0 = Read-Threads $wren
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Start-Sleep -Seconds $Seconds
            $t1 = Read-Threads $wren
            $took = $clock.Elapsed.TotalSeconds
            $s1 = Wren-Ctl stats --json | ConvertFrom-Json
            $before = @{}; foreach ($x in $t0) { $before[$x.Id] = $x }
            $cpu = 0.0; $wakes = 0; $main = 0; $rows = @()
            $mainId = $t1[0].Id; foreach ($x in $t1) { if ($before.ContainsKey($x.Id)) { $mainId = $x.Id; break } }
            foreach ($x in $t1) {
                $b = $before[$x.Id]
                $dw = $x.Switches - $(if ($b) { $b.Switches } else { 0 })
                $dc = ($x.Cpu100ns - $(if ($b) { $b.Cpu100ns } else { 0 })) / 10000.0
                $cpu += $dc; $wakes += $dw
                if ($x.Id -eq $mainId) { $main = $dw }
                if ($dw -gt 0 -or $dc -gt 0) { $rows += [pscustomobject]@{ Name = [Idle_Probe]::Name($x.Id, $ThreadQueryLimited); Id = $x.Id; Wakes = [math]::Round($dw / $took, 1); CpuMs = [math]::Round($dc, 1) } }
            }
            $frames = (Frames-Of $s1) - (Frames-Of $s0)
            $turns = 0; if ($null -ne $s1.loop) { $turns = [int]$s1.loop.turns - [int]$s0.loop.turns }
            '{0,-9}{1,-8}{2,9:N1}{3,10:N1}{4,10:N1}{5,8}{6,8:N1}{7,8}{8,9:N1}' -f $mode, $page, ($cpu / $took), ($wakes / $took), ($main / $took), $frames, ($frames / $took), $turns, ($turns / $took)
            if ($Threads) { $rows | Sort-Object Wakes -Descending | Format-Table -AutoSize | Out-String | Write-Output }
            if ($null -ne $s1.loop) {
                $causes = @(); foreach ($c in $s1.loop.causes.PSObject.Properties) { $d = [int]$c.Value - [int]$s0.loop.causes.($c.Name); if ($d -ne 0) { $causes += "$($c.Name)=$d" } }
                if ($causes) { "    frames by cause: $($causes -join ' ')" }
                foreach ($g in ($s1.loop.reasons | Group-Object causes, by | Sort-Object Count -Descending)) { "    $($g.Count) x $($g.Name)" }
                "    wakes of the loop $([int]$s1.loop.sleeps - [int]$s0.loop.sleeps), of which no frame $([int]$s1.loop.barren - [int]$s0.loop.barren)"
            }
        } finally {
            [void](Wren-Ctl quit)
        }
    }
}
Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
