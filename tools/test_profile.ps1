# Where the time and the processors of a command go: every process of its tree, seen by name, with its exact wall time and CPU time, and the
# use of the processors second by second (the tree's, and the rest of the machine's: other runs on the machine skew a measure, this says by how much).
#   powershell -NoProfile -File tools\test_profile.ps1 -Out build\prof\quick -Run "powershell -NoProfile -File tools\test_all.ps1 -Quick"
#   powershell -NoProfile -File tools\test_profile.ps1 -Report build\prof\quick          (the table again, from the files)
#   powershell -NoProfile -File tools\test_profile.ps1 -Compare build\prof\before -With build\prof\after
# Writes <Out>.processes.tsv (pid, parent, name, start, wall, cpu, command line of each process) and <Out>.timeline.tsv (one line per second: the
# tree's processors in use, the machine's, how many processes of the tree run). No sampling of the CPU times: each process is opened when it is
# first seen (every 25 ms) and its handle gives the exact times after it has ended. A process that lives less than the tick may be missed, with
# its children (they are found by parent).
# test_all.ps1 -Profile runs itself under this script.
param([string]$Out = '', [string]$Run = '', [string]$Report = '', [string]$Compare = '', [string]$With = '', [int]$TickMs = 25)
$ErrorActionPreference = 'Stop'
$Top = 25

function Read-Processes([string]$base) {
    Import-Csv -Delimiter "`t" -Path "$base.processes.tsv" | ForEach-Object {
        [pscustomobject]@{ Pid = [int]$_.pid; Parent = [int]$_.parent; Name = $_.name; Start = [double]::Parse($_.start, [Globalization.CultureInfo]::InvariantCulture)
            Wall = [double]::Parse($_.wall, [Globalization.CultureInfo]::InvariantCulture); Cpu = [double]::Parse($_.cpu, [Globalization.CultureInfo]::InvariantCulture); Cmd = $_.cmd }
    }
}
function Read-Timeline([string]$base) {
    Import-Csv -Delimiter "`t" -Path "$base.timeline.tsv" | ForEach-Object {
        [pscustomobject]@{ T = [double]::Parse($_.t, [Globalization.CultureInfo]::InvariantCulture); Tree = [double]::Parse($_.tree_cores, [Globalization.CultureInfo]::InvariantCulture)
            Machine = [double]::Parse($_.machine_cores, [Globalization.CultureInfo]::InvariantCulture); Procs = [int]$_.processes }
    }
}
# the seconds at least one of these runs (several at once count once: what a run would gain if they took no time at all, at most)
function Get-Union($procs) {
    $sum = 0.0; $end = -1.0
    foreach ($p in ($procs | Sort-Object Start)) {
        $e = $p.Start + $p.Wall
        if ($p.Start -gt $end) { $sum += $e - $p.Start; $end = $e } elseif ($e -gt $end) { $sum += $e - $end; $end = $e }
    }
    return $sum
}
function Show-Report([string]$base) {
    $procs = @(Read-Processes $base)
    $tl = @(Read-Timeline $base)
    $wall = if ($tl.Count) { ($tl | Select-Object -Last 1).T } else { 0 }
    $cpu = ($procs | Measure-Object Cpu -Sum).Sum
    $cores = [Environment]::ProcessorCount
    $avgTree = if ($tl.Count) { ($tl | Measure-Object Tree -Average).Average } else { 0 }
    $avgMachine = if ($tl.Count) { ($tl | Measure-Object Machine -Average).Average } else { 0 }
    "${base}: {0:N0} s wall, {1:N0} s CPU in {2} processes; {3:N1} processors of {4} used on average by the tree, {5:N1} by the rest of the machine" -f $wall, $cpu, $procs.Count, $avgTree, $cores, [Math]::Max(0, $avgMachine - $avgTree)
    # how the run used the machine: the seconds in each band of the tree's use
    $bands = 1, 2, 4, 8, 12, 16, 1000
    $prev = 0
    $line = @()
    foreach ($b in $bands) {
        $n = @($tl | Where-Object { $_.Tree -ge $prev -and $_.Tree -lt $b }).Count
        $line += '{0}..{1}: {2} s' -f $prev, $(if ($b -ge 1000) { '' } else { $b }), $n
        $prev = $b
    }
    'seconds by processors used: ' + ($line -join ', ')
    $slice = [Math]::Max(1, [int]($wall / 12))
    $seg = for ($t = 0; $t -lt $wall; $t += $slice) { $r = @($tl | Where-Object { $_.T -ge $t -and $_.T -lt $t + $slice }); if ($r.Count) { '{0:N1}' -f ($r | Measure-Object Tree -Average).Average } }
    "processors used, every $slice s: " + ($seg -join ' ')
    '{0,7} {1,9} {2,9} {3,9}  {4}' -f 'count', 'wall s', 'union s', 'CPU s', 'program'
    foreach ($g in ($procs | Group-Object Name | Sort-Object { ($_.Group | Measure-Object Cpu -Sum).Sum } -Descending | Select-Object -First $Top)) {
        '{0,7} {1,9:N1} {2,9:N1} {3,9:N1}  {4}' -f $g.Count, ($g.Group | Measure-Object Wall -Sum).Sum, (Get-Union $g.Group), ($g.Group | Measure-Object Cpu -Sum).Sum, $g.Name
    }
}

if ($Report) { Show-Report $Report; exit 0 }
if ($Compare -and $With) {
    $a = @(Read-Processes $Compare); $b = @(Read-Processes $With)
    Show-Report $Compare; ''; Show-Report $With; ''
    '{0,9} {1,9} {2,9}   {3}' -f 'CPU s', 'CPU s', 'diff', 'program'
    $names = @($a.Name) + @($b.Name) | Sort-Object -Unique
    $rows = foreach ($n in $names) {
        $x = (@($a | Where-Object Name -EQ $n) | Measure-Object Cpu -Sum).Sum; $y = (@($b | Where-Object Name -EQ $n) | Measure-Object Cpu -Sum).Sum
        [pscustomobject]@{ Name = $n; A = [double]$x; B = [double]$y; D = [double]$y - [double]$x }
    }
    foreach ($r in ($rows | Sort-Object { [Math]::Abs($_.D) } -Descending | Select-Object -First $Top)) { '{0,9:N1} {1,9:N1} {2,9:N1}   {3}' -f $r.A, $r.B, $r.D, $r.Name }
    exit 0
}
if (-not $Out -or -not $Run) { throw 'usage: test_profile.ps1 -Out <base> -Run "<command line>", or -Report <base>, or -Compare <base> -With <base>' }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Globalization;
public static class WrenProfiler {
    const uint TH32CS_SNAPPROCESS = 2;
    const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    const int ProcessCommandLineInformation = 60;
    const long TicksPerSecond = 10000000;
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32 {
        public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID; public uint th32ModuleID, cntThreads, th32ParentProcessID; public int pcPriClassBase; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snap, ref PROCESSENTRY32 e);
    [DllImport("kernel32", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snap, ref PROCESSENTRY32 e);
    [DllImport("kernel32")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32")] static extern bool GetProcessTimes(IntPtr h, out long create, out long exit, out long kernel, out long user);
    [DllImport("kernel32")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    [DllImport("ntdll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, byte[] buf, int len, out int ret);
    class P { public uint Pid, Parent; public string Name, Cmd; public IntPtr Handle; public long Create; }
    static string CommandLine(IntPtr h) {
        byte[] b = new byte[65536]; int ret;
        if (NtQueryInformationProcess(h, ProcessCommandLineInformation, b, b.Length, out ret) != 0 || ret < IntPtr.Size * 2) return "";
        int n = BitConverter.ToUInt16(b, 0);
        int off = IntPtr.Size * 2;
        if (off + n > b.Length) return "";
        return Encoding.Unicode.GetString(b, off, n);
    }
    static long Cpu(P p) { long c, e, k, u; return GetProcessTimes(p.Handle, out c, out e, out k, out u) ? k + u : 0; }
    static string F(double d) { return d.ToString("F3", CultureInfo.InvariantCulture); }
    // watches the tree of `root` until it ends (and until its last process has ended); returns the root's exit code by the caller
    public static void Watch(System.Diagnostics.Process root, string outBase, int tickMs) {
        Dictionary<uint, P> seen = new Dictionary<uint, P>();
        List<P> all = new List<P>();
        long t0 = DateTime.UtcNow.ToFileTimeUtc();
        P first = new P(); first.Pid = (uint)root.Id; first.Name = root.ProcessName + ".exe"; first.Handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, first.Pid); first.Cmd = CommandLine(first.Handle);
        long cc, ee, kk, uu; GetProcessTimes(first.Handle, out cc, out ee, out kk, out uu); first.Create = cc;
        seen[first.Pid] = first; all.Add(first);
        StreamWriter tl = new StreamWriter(outBase + ".timeline.tsv"); tl.NewLine = "\n";
        tl.WriteLine("t\ttree_cores\tmachine_cores\tprocesses");
        long lastIdle, lastKernel, lastUser, nextSec = t0 + TicksPerSecond, lastT = t0, lastCpu = 0; GetSystemTimes(out lastIdle, out lastKernel, out lastUser);
        PROCESSENTRY32 e = new PROCESSENTRY32(); e.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
        while (true) {
            IntPtr snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            List<PROCESSENTRY32> list = new List<PROCESSENTRY32>();
            if (Process32FirstW(snap, ref e)) { do { list.Add(e); } while (Process32NextW(snap, ref e)); }
            CloseHandle(snap);
            HashSet<uint> alive = new HashSet<uint>();
            foreach (PROCESSENTRY32 x in list) alive.Add(x.th32ProcessID);
            // (a parent is seen before its child; several passes for children listed before their parent)
            bool grew = true;
            while (grew) {
                grew = false;
                foreach (PROCESSENTRY32 x in list) {
                    P known;
                    if (seen.TryGetValue(x.th32ProcessID, out known)) {
                        // a process id used again by another program: not the one we know
                        if (known.Name.Equals(x.szExeFile, StringComparison.OrdinalIgnoreCase) && known.Parent == x.th32ParentProcessID || known == first) continue;
                        P parentOfNew;
                        if (!seen.TryGetValue(x.th32ParentProcessID, out parentOfNew)) { continue; }
                        seen.Remove(x.th32ProcessID);
                    }
                    P parent;
                    if (!seen.TryGetValue(x.th32ParentProcessID, out parent)) continue;
                    IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, x.th32ProcessID);
                    if (h == IntPtr.Zero) continue;
                    long c, ex, k, u;
                    if (!GetProcessTimes(h, out c, out ex, out k, out u) || c < parent.Create) { CloseHandle(h); continue; }
                    P p = new P(); p.Pid = x.th32ProcessID; p.Parent = x.th32ParentProcessID; p.Name = x.szExeFile; p.Handle = h; p.Create = c; p.Cmd = CommandLine(h);
                    seen[p.Pid] = p; all.Add(p); grew = true;
                }
            }
            long now = DateTime.UtcNow.ToFileTimeUtc();
            if (now >= nextSec) {
                long cpu = 0; int running = 0;
                foreach (P p in all) { cpu += Cpu(p); long c, ex, k, u; if (GetProcessTimes(p.Handle, out c, out ex, out k, out u) && ex == 0) running++; }
                long idle, kernel, user; GetSystemTimes(out idle, out kernel, out user);
                double dt = (now - lastT) / (double)TicksPerSecond;
                double tree = (cpu - lastCpu) / (double)TicksPerSecond / dt;
                double machine = ((kernel - lastKernel) + (user - lastUser) - (idle - lastIdle)) / (double)TicksPerSecond / dt;
                tl.WriteLine(F((now - t0) / (double)TicksPerSecond) + "\t" + F(tree) + "\t" + F(machine) + "\t" + running);
                tl.Flush();
                lastCpu = cpu; lastT = now; lastIdle = idle; lastKernel = kernel; lastUser = user; nextSec = now + TicksPerSecond;
                if (running == 0) break;
                // what outlives the command by more than this (a server left behind) is not waited for
                if (root.HasExited && (DateTime.Now - root.ExitTime).TotalSeconds > 20) break;
            }
            System.Threading.Thread.Sleep(tickMs);
        }
        tl.Close();
        StreamWriter pw = new StreamWriter(outBase + ".processes.tsv"); pw.NewLine = "\n";
        pw.WriteLine("pid\tparent\tname\tstart\twall\tcpu\tcmd");
        foreach (P p in all) {
            long c, ex, k, u; GetProcessTimes(p.Handle, out c, out ex, out k, out u);
            string name = p.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? p.Name.Substring(0, p.Name.Length - 4) : p.Name;
            pw.WriteLine(p.Pid + "\t" + p.Parent + "\t" + name + "\t" + F((c - t0) / (double)TicksPerSecond) + "\t" + F(((ex == 0 ? DateTime.UtcNow.ToFileTimeUtc() : ex) - c) / (double)TicksPerSecond) + "\t" + F((k + u) / (double)TicksPerSecond) + "\t" + (p.Cmd ?? "").Replace('\t', ' ').Replace('\n', ' ').Replace('\r', ' '));
        }
        pw.Close();
    }
}
'@

$dir = Split-Path $Out -Parent
if ($dir) { New-Item -ItemType Directory -Force $dir | Out-Null }
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = $env:ComSpec
# (the tree inherits this console; cmd reads the line as typed)
$psi.Arguments = "/d /s /c `"$Run`""
$psi.UseShellExecute = $false
$psi.WorkingDirectory = (Get-Location).Path
$p = [Diagnostics.Process]::Start($psi)
[WrenProfiler]::Watch($p, [IO.Path]::GetFullPath($Out), $TickMs)
$p.WaitForExit()
$code = $p.ExitCode
Show-Report $Out
exit $code
