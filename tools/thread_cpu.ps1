# CPU time per thread of a running process over a window of time: the player's threads are named (wren-video-decode,
# wren-audio-decode, wren-audio-out), the others are listed by id.
#   powershell -File tools\thread_cpu.ps1 -ProcessId 1234 [-Seconds 10]
#   powershell -File tools\thread_cpu.ps1 -Exe build\browser_prof.exe -Url <url> [-Seconds 10] [-Warmup 12] [-Prefs '--pref a=b']
# With -Exe the script starts the browser, lets it load for -Warmup seconds, measures, closes it. Output: one line per
# thread that used CPU: name, user ms, kernel ms, and the share of one core over the window.
param([string]$ClickAt = '', [int]$ProcessId = 0, [string]$Exe = '', [string]$Url = '', [int]$Seconds = 10, [int]$Warmup = 12, [string]$Prefs = '', [string]$Profile = '')
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public class TC {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("kernel32.dll")] public static extern IntPtr OpenThread(uint access, bool inherit, uint tid);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] public static extern int GetThreadDescription(IntPtr h, out IntPtr name);
  [DllImport("kernel32.dll")] public static extern IntPtr LocalFree(IntPtr p);
  [DllImport("kernel32.dll")] public static extern bool GetThreadTimes(IntPtr h, out long c, out long e, out long k, out long u);
  public static string Name(IntPtr h) {
    IntPtr p; if (GetThreadDescription(h, out p) < 0 || p == IntPtr.Zero) return "";
    string s = Marshal.PtrToStringUni(p); LocalFree(p); return s;
  }
}
"@
[TC]::SetProcessDPIAware() | Out-Null
function Snapshot([int]$procId) {
    $r = @{}
    foreach ($t in (Get-Process -Id $procId).Threads) {
        $h = [TC]::OpenThread(0x800, $false, [uint32]$t.Id)
        if ($h -eq [IntPtr]::Zero) { continue }
        [long]$c = 0; [long]$e = 0; [long]$k = 0; [long]$u = 0
        if ([TC]::GetThreadTimes($h, [ref]$c, [ref]$e, [ref]$k, [ref]$u)) { $r[$t.Id] = [pscustomobject]@{ Name = [TC]::Name($h); K = $k / 10000.0; U = $u / 10000.0 } }
        [TC]::CloseHandle($h) | Out-Null
    }
    $r
}
$p = $null
if ($Exe) {
    $argv = (@($Prefs, $(if ($Profile) { "--profile `"$Profile`"" }), $Url) | Where-Object { $_ }) -join ' '
    $p = if ($argv) { Start-Process $Exe -ArgumentList $argv -PassThru } else { Start-Process $Exe -PassThru }
    $ProcessId = $p.Id
    Start-Sleep $Warmup
    # -ClickAt x,y: a click posted to the window (client coordinates) after the warm-up: the play button of a page
    if ($ClickAt) {
        $xy = $ClickAt -split ','; $p.Refresh(); $lp = [IntPtr]((([int]$xy[1]) -shl 16) -bor (([int]$xy[0]) -band 0xFFFF))
        [TC]::PostMessage($p.MainWindowHandle, 0x0200, [IntPtr]::Zero, $lp) | Out-Null; Start-Sleep -Milliseconds 100
        [TC]::PostMessage($p.MainWindowHandle, 0x0201, [IntPtr]1, $lp) | Out-Null; Start-Sleep -Milliseconds 80
        [TC]::PostMessage($p.MainWindowHandle, 0x0202, [IntPtr]::Zero, $lp) | Out-Null
        Start-Sleep 6
    }
}
try {
    $a = Snapshot $ProcessId
    Start-Sleep $Seconds
    $b = Snapshot $ProcessId
    $rows = foreach ($id in $b.Keys) {
        $k0 = if ($a.ContainsKey($id)) { $a[$id].K } else { 0 }; $u0 = if ($a.ContainsKey($id)) { $a[$id].U } else { 0 }
        $dk = $b[$id].K - $k0; $du = $b[$id].U - $u0
        if ($dk + $du -le 0) { continue }
        [pscustomobject]@{ Thread = $id; Name = $(if ($b[$id].Name) { $b[$id].Name } else { '(unnamed)' }); UserMs = [int]$du; KernelMs = [int]$dk; Core = '{0:P1}' -f (($du + $dk) / ($Seconds * 1000.0)) }
    }
    $rows | Sort-Object { $_.UserMs + $_.KernelMs } -Descending | Format-Table -AutoSize
    $tot = ($rows | Measure-Object -Property UserMs -Sum).Sum + ($rows | Measure-Object -Property KernelMs -Sum).Sum
    'total {0:P0} of one core over {1} s' -f ($tot / ($Seconds * 1000.0)), $Seconds
} finally {
    if ($p -and -not $p.HasExited) { $p.CloseMainWindow() | Out-Null; if (-not $p.WaitForExit(15000)) { 'did not exit: killed'; $p.Kill() } }
}
