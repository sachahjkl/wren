# Runs a command by hand on a Windows desktop of its own, that nobody looks at (src\tools\test_all goes on one by itself, desktop_windows.odin): what it opens cannot take the focus, the mouse or the
# keyboard of the person at the machine, whatever it does, and their clicks cannot reach it. Everything it starts stays there.
#   powershell -File tools\test_desktop.ps1 -Command "build\e2e_test.exe -tests:name"
# Prints what the command prints, and ends with its exit code. WREN_ON_TEST_DESKTOP is 1 in it.
# (A real input of the machine, SendInput, SetCursorPos, goes nowhere there: what needs one is `test_all -Ui`.)
param([Parameter(Mandatory)][string]$Command, [string]$DesktopName = "WrenTests-$PID")

$PollMs = 200          # how often what the command printed is passed on
$GenericAll = 0x10000000
$HandleFlagInherit = 1
$OpenAlways = 4
$ShareAll = 7          # read, write, delete: this script reads the file while the command writes it
$StartfUseStdHandles = 0x100
$Infinite = 0xFFFFFFFF
$WaitTimeout = 0x102

Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class TestDesktop {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct STARTUPINFO {
    public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
  [StructLayout(LayoutKind.Sequential)] public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
  [StructLayout(LayoutKind.Sequential)] public struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public bool bInheritHandle; }
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr mode, uint flags, uint access, IntPtr sa);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool CloseDesktop(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool CreateProcessW(string app, System.Text.StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern IntPtr CreateFileW(string name, uint access, uint share, ref SECURITY_ATTRIBUTES sa, uint disposition, uint flags, IntPtr template);
  [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
"@

$desktop = [TestDesktop]::CreateDesktopW($DesktopName, [IntPtr]::Zero, [IntPtr]::Zero, 0, [uint32]$GenericAll, [IntPtr]::Zero)
if ($desktop -eq [IntPtr]::Zero) { throw "cannot make the desktop $DesktopName (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))" }

$out = Join-Path ([IO.Path]::GetTempPath()) "wren_test_desktop_$PID.txt"
$sa = New-Object TestDesktop+SECURITY_ATTRIBUTES
$sa.nLength = [Runtime.InteropServices.Marshal]::SizeOf($sa)
$sa.bInheritHandle = $true
$handle = [TestDesktop]::CreateFileW($out, [uint32]$GenericAll, [uint32]$ShareAll, [ref]$sa, [uint32]$OpenAlways, 0, [IntPtr]::Zero)
if ($handle -eq [IntPtr](-1)) { throw "cannot make $out" }

$si = New-Object TestDesktop+STARTUPINFO
$si.cb = [Runtime.InteropServices.Marshal]::SizeOf($si)
$si.lpDesktop = "WinSta0\$DesktopName"
$si.dwFlags = $StartfUseStdHandles
$si.hStdOutput = $handle
$si.hStdError = $handle
$pi = New-Object TestDesktop+PROCESS_INFORMATION
$env:WREN_ON_TEST_DESKTOP = '1'
$line = New-Object Text.StringBuilder $Command
if (-not [TestDesktop]::CreateProcessW([NullString]::Value, $line, [IntPtr]::Zero, [IntPtr]::Zero, $true, 0, [IntPtr]::Zero, (Get-Location -PSProvider FileSystem).ProviderPath, [ref]$si, [ref]$pi)) {
    throw "cannot start the command (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
}
[void][TestDesktop]::CloseHandle($handle)

$reader = New-Object IO.StreamReader((New-Object IO.FileStream($out, 'Open', 'Read', 'ReadWrite,Delete')))
do {
    $done = [TestDesktop]::WaitForSingleObject($pi.hProcess, $PollMs) -ne $WaitTimeout
    $text = $reader.ReadToEnd()
    if ($text) { [Console]::Out.Write($text) }
} while (-not $done)
$reader.Dispose()

[uint32]$code = 0
[void][TestDesktop]::GetExitCodeProcess($pi.hProcess, [ref]$code)
[void][TestDesktop]::CloseHandle($pi.hProcess)
[void][TestDesktop]::CloseHandle($pi.hThread)
[void][TestDesktop]::CloseDesktop($desktop)
[IO.File]::Delete($out)
exit ([int]$code)
