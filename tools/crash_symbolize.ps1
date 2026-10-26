# Names the frames of a crash report: each address inside the crashed program becomes its function (and, for a private
# Odin procedure, its file), read from the build's map (tools\symbols.ps1), found by the build's fingerprint.
#
#   powershell -File tools\crash_symbolize.ps1 "<profile>\crashes\crash 2026-10-26 15-47-09.txt" [-Symbols <folder or .map>] [-Exe <exe with its PDB>]
#   powershell -File tools\crash_symbolize.ps1 "...\crash 2026-10-26 15-47-09.dmp"
#
# The report (crashtrace) says "build <exe> <fingerprint>, base 0x..., size 0x..." and each frame's address. A report from before
# that line has only the addresses: the minidump beside it (same name, .dmp) gives the module's base and the fingerprint. Given a
# .dmp alone, only the exception's address is named (the stack is in the .txt).
# -Symbols: where the maps are (default: the report's folder, build\, build\symbols), or the .map itself: a map of another link
# of the same sources (rebuilt with the same flags) names the same functions as long as the code is the same; the script says
# when the fingerprints differ.
# -Exe: an exe with its PDB (a development or profile build: same fingerprint as the report): names with files and lines
# through DbgHelp instead of the map.
param([Parameter(Mandatory, Position = 0)][string]$Report, [string[]]$Symbols = @(), [string]$Exe = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'symbols.ps1')

$Report = (Resolve-Path $Report).Path
$stemPath = [IO.Path]::Combine((Split-Path $Report), [IO.Path]::GetFileNameWithoutExtension($Report))
$txt = if ($Report -match '\.dmp$') { "$stemPath.txt" } else { $Report }
$dmp = if ($Report -match '\.dmp$') { $Report } else { "$stemPath.dmp" }
if (-not (Test-Path $txt)) { $txt = '' }
if (-not (Test-Path $dmp) -or (Get-Item $dmp).Length -eq 0) { $dmp = '' }

# ---- which build, loaded where
$module = $null   # Name, Base, Size, Fingerprint
$lines = @()
if ($txt) {
    $lines = [IO.File]::ReadAllLines($txt)
    foreach ($l in $lines) {
        if ($l -match '^\s*build (\S+) ([0-9A-F]{9,16}), base 0x([0-9A-F]+), size 0x([0-9A-F]+)') {
            $module = [pscustomobject]@{ Name = $Matches[1]; Fingerprint = $Matches[2]; Base = [Convert]::ToUInt64($Matches[3], 16); Size = [Convert]::ToUInt64($Matches[4], 16) }
            break
        }
    }
}
$dump = $null
if ($dmp) { $dump = Read-MinidumpInfo $dmp }
if (-not $module) {
    if (-not $dump) { "error: the report has no 'build' line (a report from before) and no minidump beside it: nothing says where the program was loaded"; exit 1 }
    $main = $dump.Modules | Where-Object { $_.Name -match '\.exe$' } | Select-Object -First 1
    if (-not $main) { $main = $dump.Modules | Select-Object -First 1 }
    $module = [pscustomobject]@{ Name = $main.Name; Fingerprint = $main.Fingerprint; Base = $main.Base; Size = [UInt64]$main.Size }
    "(the module's base and fingerprint come from the minidump)"
}
if (-not $lines.Count) {
    if (-not $dump.Exception) { "error: no stack in the report and no exception in the minidump"; exit 1 }
    $lines = @(('*** crash: exception (0x{0:X8}) at 0x{1:X}, thread {2} (from the minidump: the stack is in the .txt)' -f $dump.Exception.Code, $dump.Exception.Address, $dump.Exception.Thread),
        ('  #00 0x{0:X} ?' -f $dump.Exception.Address))
}
'{0} {1}, base 0x{2:X}, size 0x{3:X}' -f $module.Name, $module.Fingerprint, $module.Base, $module.Size

# ---- the symbols
$resolve = $null
if ($Exe) {
    $efp = Get-PeFingerprint $Exe
    if ($efp -ne $module.Fingerprint) { "warning: $Exe is build $efp, the report's is $($module.Fingerprint): names may be wrong" }
    Add-Type @"
using System; using System.Runtime.InteropServices;
public static class CrashDbg {
  [DllImport("dbghelp.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SymInitializeW(IntPtr p, string path, bool invade);
  [DllImport("dbghelp.dll", SetLastError=true)] public static extern uint SymSetOptions(uint o);
  [DllImport("dbghelp.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern ulong SymLoadModuleExW(IntPtr p, IntPtr f, string img, string mod, ulong b, uint size, IntPtr d, uint fl);
  [DllImport("dbghelp.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SymFromAddrW(IntPtr p, ulong a, out ulong disp, IntPtr sym);
  [DllImport("dbghelp.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SymGetLineFromAddrW64(IntPtr p, ulong a, out uint disp, ref LINE l);
  [DllImport("dbghelp.dll")] public static extern bool SymCleanup(IntPtr p);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct LINE { public uint SizeOfStruct; public IntPtr Key; public uint LineNumber; public IntPtr FileName; public ulong Address; }
}
"@
    $exePath = (Resolve-Path $Exe).Path
    $h = [IntPtr]0x57524558
    [CrashDbg]::SymSetOptions(0x2 -bor 0x10) | Out-Null   # UNDNAME | LOAD_LINES
    if (-not [CrashDbg]::SymInitializeW($h, (Split-Path $exePath), $false)) { "error: SymInitialize failed"; exit 1 }
    if ([CrashDbg]::SymLoadModuleExW($h, [IntPtr]::Zero, $exePath, $null, $module.Base, [uint32]$module.Size, [IntPtr]::Zero, 0) -eq 0) { "error: DbgHelp cannot load $exePath"; exit 1 }
    $resolve = {
        param([UInt64]$addr)
        $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal(88 + 2 * 512)
        try {
            [Runtime.InteropServices.Marshal]::WriteInt32($buf, 0, 88); [Runtime.InteropServices.Marshal]::WriteInt32($buf, 80, 512)
            $disp = [UInt64]0
            if (-not [CrashDbg]::SymFromAddrW($h, $addr, [ref]$disp, $buf)) { return '' }
            $len = [Runtime.InteropServices.Marshal]::ReadInt32($buf, 76)
            $name = Format-OdinSymbol ([Runtime.InteropServices.Marshal]::PtrToStringUni([IntPtr]($buf.ToInt64() + 84), $len))
            $line = New-Object CrashDbg+LINE; $line.SizeOfStruct = [Runtime.InteropServices.Marshal]::SizeOf($line); $ld = [UInt32]0
            $at = if ([CrashDbg]::SymGetLineFromAddrW64($h, $addr, [ref]$ld, [ref]$line)) { '  ' + [Runtime.InteropServices.Marshal]::PtrToStringUni($line.FileName) + ':' + $line.LineNumber } else { '' }
            return ('{0}+0x{1:X}{2}' -f $name, $disp, $at)
        } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buf) }
    }
    "symbols: $exePath (PDB, DbgHelp)"
} else {
    $where = @($Symbols) + @((Split-Path $Report))
    $mapPath = Find-BuildSymbols $module.Fingerprint $where
    if (-not $mapPath) {
        "error: no map of build $($module.Fingerprint) (a file '*-$($module.Fingerprint).map' in $(($where + @('build', 'build\symbols')) -join ', ')): give -Symbols <folder or .map>"
        exit 1
    }
    $map = Read-LinkerMap $mapPath
    "symbols: $mapPath"
    $want = $module.Fingerprint.Substring(0, 8)
    if ($map.Stamp -and $map.Stamp -ne $want) { "warning: this map is of the link $($map.Stamp), the crashed build is ${want}: right only if both links come from the same sources and flags" }
    $resolve = { param([UInt64]$addr) Resolve-MapAddress $map ($addr - $module.Base) }
}

# ---- the frames
''
$named = 0
foreach ($l in $lines) {
    $m = [regex]::Match($l, '^(\s*#\d+ 0x([0-9A-Fa-f]+)) (\S+)(.*)$')
    if (-not $m.Success) { $l; continue }
    $addr = [Convert]::ToUInt64($m.Groups[2].Value, 16)
    if ($addr -ge $module.Base -and $addr -lt $module.Base + $module.Size) {
        $name = & $resolve $addr
        if ($name) {
            $named++
            '{0} {1}  [{2}+0x{3:X}]' -f $m.Groups[1].Value, $name, $module.Name, ($addr - $module.Base)
            continue
        }
    }
    $l
}
if ($Exe) { [CrashDbg]::SymCleanup($h) | Out-Null }
''
"$named frames named"
