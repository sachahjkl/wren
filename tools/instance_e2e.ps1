# Checks the single instance of real wren.exe processes (src/browser/instance_shell.odin, src/instance): a second start with the
# same profile hands its addresses to the first one and ends with exit code 0; the cases that must not (another profile,
# another executable, --new-window, a first Wren that does not answer) start a window of their own.
#   powershell -NoProfile -File tools\instance_e2e.ps1 [-Exe build\wren.exe]
# Everything is on scratch profiles under build\tmp (never the user's), each run with WREN_SINGLE_INSTANCE=on (test_env.ps1
# sets it to off for every script, so that tools never meet each other or the user's Wren). The windows take the focus: the
# script holds desktop.lock like the ones that capture the screen. Nothing is sent to a window but WM_CLOSE and a minimize.
param([string]$Exe = '', [int]$LockTimeoutSec = 600)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'test_env.ps1')
$desktopLock = Enter-WrenLock desktop 'instance_e2e.ps1' $LockTimeoutSec
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$Exe = (Resolve-Path $Exe).Path
Add-Type @"
using System; using System.Runtime.InteropServices;
public class IE {
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
  [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  // does the process own the message-only window a second start hands its addresses to (src/instance/instance_windows.odin)?
  public static bool HasOwnerWindow(uint pid) {
    IntPtr h = IntPtr.Zero;
    while ((h = FindWindowEx((IntPtr)(-3), h, "WrenInstanceWindow", null)) != IntPtr.Zero) { uint p; GetWindowThreadProcessId(h, out p); if (p == pid) return true; }
    return false;
  }
}
"@
$id = 'i' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$scratch = Join-Path $root "build\tmp\instance_e2e_$id"
New-Item -ItemType Directory -Force $scratch | Out-Null
$failures = New-Object Collections.Generic.List[string]
function Check($ok, $what) { if ($ok) { "  ok   $what" } else { "  FAIL $what"; $failures.Add($what) } }
$started = New-Object Collections.Generic.List[object]

function Start-Wren([string]$exe, [string[]]$wrenArgs, [bool]$single = $true) {
    $saved = [Environment]::GetEnvironmentVariable('WREN_SINGLE_INSTANCE')
    [Environment]::SetEnvironmentVariable('WREN_SINGLE_INSTANCE', $(if ($single) { 'on' } else { 'off' }))
    try { $p = Start-Process $exe -ArgumentList $wrenArgs -PassThru } finally { [Environment]::SetEnvironmentVariable('WREN_SINGLE_INSTANCE', $saved) }
    $started.Add($p)
    return $p
}
function Wait-Window($p) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $p.MainWindowHandle -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 50; $p.Refresh() }
    if ($p.HasExited) { throw "wren exited at once (code $($p.ExitCode))" }
    # ready for a second start: it owns the window that receives the addresses (not a fixed delay)
    while (-not $p.HasExited -and -not [IE]::HasOwnerWindow([uint32]$p.Id) -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 20 }
    Start-Sleep -Milliseconds 150   # (the first frames)
}
# Waits (at most $Seconds) until $Test is true; returns whether it was.
function Wait-Until([scriptblock]$Test, [double]$Seconds = 10) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) { if (& $Test) { return $true }; Start-Sleep -Milliseconds 25 }
    return [bool](& $Test)
}
# A start that kept its own window shows one (a start that handed its addresses over ends without ever making one): this is when it has decided.
function Wait-Decided($p) { $null = Wait-Until { $p.Refresh(); $p.HasExited -or $p.MainWindowHandle -ne [IntPtr]::Zero } 15 }
function Close-Wren($p) {
    if ($p.HasExited) { return }
    [IE]::PostMessage($p.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    if (-not $p.WaitForExit(20000)) { Stop-Process -Id $p.Id -Force; "  (had to be killed)" }
}
function Tabs($profileDir) {
    $f = "$profileDir\session.txt"
    if (-not (Test-Path $f)) { return @() }
    @(Get-Content $f | Where-Object { $_ -like 'tab *' } | ForEach-Object { $_.Substring(4) })
}
$restore = @('--pref', 'browser.session.restore=true')

try {
    $P1 = "$scratch\p1"; $P2 = "$scratch\p2"
    Section "1 a second start hands its addresses over and ends with code 0"; "1. a second start hands its addresses over and ends with code 0"
    $a = Start-Wren $Exe (@('--profile', $P1) + $restore + @('about:config'))
    Wait-Window $a
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $b = Start-Wren $Exe (@('--profile', $P1) + $restore + @('about:wren', 'about:about'))
    $ended = $b.WaitForExit(8000)
    Check $ended "the second start ended by itself ($([int]$sw.ElapsedMilliseconds) ms)"
    Check ($ended -and $b.ExitCode -eq 0) 'with exit code 0'
    Check (-not $a.HasExited) 'the first one is still running'
    Start-Sleep -Milliseconds 500   # (the first window opens the tabs on its next turn of the loop)
    Close-Wren $a
    $tabs = Tabs $P1
    Check ($tabs -contains 'about:config' -and $tabs -contains 'about:wren' -and $tabs -contains 'about:about') "one tab per address in the first window: $($tabs -join ', ')"

    Section "2 a minimized window is restored; no address: it just comes forward"; "2. a minimized window is restored; no address: it just comes forward"
    Remove-Item "$P1\session.txt" -ErrorAction SilentlyContinue
    $a = Start-Wren $Exe (@('--profile', $P1) + $restore + @('about:config'))
    Wait-Window $a
    [IE]::ShowWindow($a.MainWindowHandle, 6) | Out-Null   # SW_MINIMIZE
    $null = Wait-Until { [IE]::IsIconic($a.MainWindowHandle) } 5
    Check ([IE]::IsIconic($a.MainWindowHandle)) 'the window is minimized'
    $b = Start-Wren $Exe (@('--profile', $P1) + $restore)
    Check ($b.WaitForExit(8000) -and $b.ExitCode -eq 0) 'a start with nothing to open ends with code 0'
    $null = Wait-Until { -not [IE]::IsIconic($a.MainWindowHandle) } 5
    Check (-not [IE]::IsIconic($a.MainWindowHandle)) 'and the first window was restored'
    Close-Wren $a
    Check ((Tabs $P1).Count -eq 1) 'no tab was added'

    Section "3 what must not hand over"; "3. what must not hand over"
    Remove-Item "$P1\session.txt" -ErrorAction SilentlyContinue
    $a = Start-Wren $Exe (@('--profile', $P1) + $restore + @('about:config'))
    Wait-Window $a
    $nw = Start-Wren $Exe (@('--profile', "$scratch\p1nw") + $restore + @('--new-window', 'about:wren'))   # (its own folder, so that two windows do not write one session)
    $other = Start-Wren $Exe (@('--profile', $P2) + $restore + @('about:about'))
    Wait-Decided $nw; Wait-Decided $other
    Check (-not $nw.HasExited) '--new-window: a window of its own'
    Check (-not $other.HasExited) 'another profile: a window of its own'
    $dir = "$scratch\copy"; New-Item -ItemType Directory -Force $dir | Out-Null; Copy-Item $Exe "$dir\wren.exe"
    $copy = Start-Wren "$dir\wren.exe" (@('--profile', $P1) + $restore + @('about:wren'))
    Wait-Decided $copy
    Check (-not $copy.HasExited) 'another executable on the same profile: a window of its own (Setup must be able to replace the installed copy)'
    $env_off = Start-Wren $Exe (@('--profile', $P1) + $restore + @('about:about')) $false
    Wait-Decided $env_off
    Check (-not $env_off.HasExited) 'WREN_SINGLE_INSTANCE=off (what test_env.ps1 sets for every script): a window of its own'
    foreach ($w in @($copy, $env_off, $nw, $other)) { Close-Wren $w }
    Close-Wren $a

    Section "4 a first Wren that does not answer does not hold the second one"; "4. a first Wren that does not answer does not hold the second one"
    $a = Start-Wren $Exe (@('--profile', "$scratch\p4") + $restore + @('about:config'))
    Wait-Window $a
    [IE]::NtSuspendProcess($a.Handle) | Out-Null
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $b = Start-Wren $Exe (@('--profile', "$scratch\p4") + @('about:wren'))
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        while (-not $b.HasExited -and $b.MainWindowHandle -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 12000) { Start-Sleep -Milliseconds 50; $b.Refresh() }
        $ms = $sw.ElapsedMilliseconds
        Check ((-not $b.HasExited) -and $b.MainWindowHandle -ne [IntPtr]::Zero) "the second start opened its own window after $ms ms"
        Check ($ms -ge 2500 -and $ms -lt 9000) 'after about the 3 s timeout, not at once and not for ever'
    } finally { [IE]::NtResumeProcess($a.Handle) | Out-Null }
    Close-Wren $b; Close-Wren $a

    Section "5 a start while the first one is closing: its address is not lost"; "5. a start while the first one is closing: its address is not lost"
    $P5 = "$scratch\p5"
    $a = Start-Wren $Exe (@('--profile', $P5) + $restore + @('about:config'))
    Wait-Window $a
    [IE]::PostMessage($a.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null   # WM_CLOSE, and at once:
    $b = Start-Wren $Exe (@('--profile', $P5) + $restore + @('about:wren'))
    Wait-Decided $b   # (it took the profile over, or handed its address over and ended)
    $bAlive = -not $b.HasExited
    Check ($bAlive -or $b.ExitCode -eq 0) "the second start either took the profile over or handed its address over (alive=$bAlive)"
    Close-Wren $b; Close-Wren $a
    Check ((Tabs $P5) -contains 'about:wren') "the address arrived either way: $((Tabs $P5) -join ', ')"
}
finally {
    Exit-WrenLock $desktopLock
    foreach ($p in $started) { if ($p -and -not $p.HasExited) { try { Stop-Process -Id $p.Id -Force } catch { } } }
    Start-Sleep -Milliseconds 500
    if (Test-Path $scratch) { try { [IO.Directory]::Delete($scratch, $true) } catch { "scratch not deleted: $_" } }
}
Show-WrenSections instance_e2e
if ($failures.Count) { "FAILED: $($failures.Count)"; exit 1 }
"all scenarios passed"
