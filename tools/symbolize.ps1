# Names the function and source line at an offset of a module, with its PDB (DbgHelp), e.g. the "Fault offset" of a
# crash in the Windows event log.
#   powershell -File tools\symbolize.ps1 -Exe build\wren_prof.exe -Offset 0x18575b [-Offset ...]
param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$Offset)
$ErrorActionPreference = 'Stop'
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class Dbg {
  [DllImport("dbghelp.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SymInitializeW(IntPtr p, string path, bool invade);
  [DllImport("dbghelp.dll", SetLastError=true)] public static extern uint SymSetOptions(uint o);
  [DllImport("dbghelp.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern ulong SymLoadModuleExW(IntPtr p, IntPtr f, string img, string mod, ulong b, uint size, IntPtr d, uint fl);
  [DllImport("dbghelp.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SymFromAddrW(IntPtr p, ulong a, out ulong disp, IntPtr sym);
  [DllImport("dbghelp.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SymGetLineFromAddrW64(IntPtr p, ulong a, out uint disp, ref LINE l);
  [DllImport("dbghelp.dll")] public static extern bool SymCleanup(IntPtr p);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct LINE { public uint SizeOfStruct; public IntPtr Key; public uint LineNumber; public IntPtr FileName; public ulong Address; }
}
"@
$full = (Resolve-Path $Exe).Path
$h = [IntPtr]0x5752454e
[Dbg]::SymSetOptions(0x2 -bor 0x10) | Out-Null   # UNDNAME | LOAD_LINES
if (-not [Dbg]::SymInitializeW($h, (Split-Path $full), $false)) { throw "SymInitialize failed" }
$base = [UInt64]0x140000000
$b = [Dbg]::SymLoadModuleExW($h, [IntPtr]::Zero, $full, $null, $base, 0, [IntPtr]::Zero, 0)
if ($b -eq 0) { throw "cannot load the module's symbols" }
foreach ($o in $Offset) {
    $addr = $base + [Convert]::ToUInt64(($o -replace '^0x', ''), 16)
    $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal(88 + 2 * 512)
    [Runtime.InteropServices.Marshal]::WriteInt32($buf, 0, 88); [Runtime.InteropServices.Marshal]::WriteInt32($buf, 80, 512)
    $disp = [UInt64]0; $name = '?'
    if ([Dbg]::SymFromAddrW($h, $addr, [ref]$disp, $buf)) { $len = [Runtime.InteropServices.Marshal]::ReadInt32($buf, 76); $name = [Runtime.InteropServices.Marshal]::PtrToStringUni([IntPtr]($buf.ToInt64() + 84), $len) }
    [Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
    $line = New-Object Dbg+LINE; $line.SizeOfStruct = [Runtime.InteropServices.Marshal]::SizeOf($line); $ld = [UInt32]0; $where = ''
    if ([Dbg]::SymGetLineFromAddrW64($h, $addr, [ref]$ld, [ref]$line)) { $where = "  " + [Runtime.InteropServices.Marshal]::PtrToStringUni($line.FileName) + ":" + $line.LineNumber }
    "{0}  {1}+0x{2:x}{3}" -f $o, $name, $disp, $where
}
[Dbg]::SymCleanup($h) | Out-Null
