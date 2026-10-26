# The symbols of a build: the linker's map (build.bat links with /MAP), named by the build's fingerprint, and what reads them.
#
# A release has no PDB (-debug would change the program: ODIN_DEBUG, the Direct3D debug layer, other code), so a crash report of
# a release names no function of Wren in the process. The map names every function (Odin writes "pkg::proc" and, for a private
# one, "pkg::[file.odin]::proc") with its address; the report gives the build's fingerprint and the module's base
# (src/tools/crashtrace), and tools\crash_symbolize.ps1 turns the addresses of the frames into functions.
#
# The fingerprint is the PE header's link time stamp and image size, "%08X%X" (as a symbol server keys an executable):
# every link makes a new one, signing does not change it.
#
#   powershell -File tools\symbols.ps1 -Publish build\wren.exe [-Store]
#       build.bat after each link: build\wren.map becomes build\wren-<fingerprint>.map (the previous ones of that exe go);
#       -Store (release builds) also copies it to build\symbols, which keeps the 20 latest
#   powershell -File tools\symbols.ps1 -Fingerprint <exe>
#   . tools\symbols.ps1   (functions: Get-PeFingerprint, Find-BuildSymbols, Read-LinkerMap, Resolve-MapAddress, Read-MinidumpInfo)
param([string]$Publish = '', [switch]$Store, [string]$Fingerprint = '')

$script:SymbolStore = Join-Path (Split-Path $PSScriptRoot -Parent) 'build\symbols'

function Get-PeFingerprint([string]$Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $b = New-Object byte[] 4096
        $n = $fs.Read($b, 0, $b.Length)
        if ($n -lt 0x40 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) { throw "$Path is not a PE file" }
        $nt = [BitConverter]::ToInt32($b, 0x3C)
        if ($nt + 24 + 60 -gt $n -or [BitConverter]::ToUInt32($b, $nt) -ne 0x00004550) { throw "$Path has no PE header" }
        $stamp = [BitConverter]::ToUInt32($b, $nt + 8)
        $size = [BitConverter]::ToUInt32($b, $nt + 24 + 56)
        return ('{0:X8}{1:X}' -f $stamp, $size)
    } finally { $fs.Dispose() }
}

# The map of the build `$Fp`: "<anything>-<fp>.map" in the given folders (or the given file), then build\ and build\symbols.
function Find-BuildSymbols([string]$Fp, [string[]]$Where = @()) {
    $dirs = New-Object Collections.Generic.List[string]
    foreach ($w in $Where) {
        if (-not $w) { continue }
        if (Test-Path $w -PathType Leaf) { return (Resolve-Path $w).Path }
        if (Test-Path $w -PathType Container) { $dirs.Add((Resolve-Path $w).Path) }
    }
    $dirs.Add((Join-Path (Split-Path $PSScriptRoot -Parent) 'build'))
    $dirs.Add($script:SymbolStore)
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { continue }
        $hit = Get-ChildItem $d -Recurse -Depth 2 -Filter "*-$Fp.map" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return ''
}

# The functions of a map, sorted by address: .Rva (UInt64[]), .Name (string[]), .Stamp (the link's time stamp, hex), .Base.
function Read-LinkerMap([string]$Path) {
    $base = [UInt64]0x140000000
    $stamp = ''
    $rvas = New-Object Collections.Generic.List[UInt64]
    $names = New-Object Collections.Generic.List[string]
    $sym = [regex]'^\s+([0-9a-fA-F]{4}):[0-9a-fA-F]{8}\s+(\S.*?)\s+([0-9a-fA-F]{16})\s'
    foreach ($l in [IO.File]::ReadLines($Path)) {
        if ($l.Length -lt 30) { continue }
        $m = $sym.Match($l)
        if ($m.Success) {
            if ($m.Groups[1].Value -eq '0000') { continue }   # absolute symbols
            $va = [Convert]::ToUInt64($m.Groups[3].Value, 16)
            if ($va -lt $base) { continue }
            $rvas.Add($va - $base); $names.Add($m.Groups[2].Value)
            continue
        }
        if ($l -match '^\s*Preferred load address is ([0-9a-fA-F]+)') { $base = [Convert]::ToUInt64($Matches[1], 16) }
        elseif ($l -match '^\s*Timestamp is ([0-9a-fA-F]+)') { $stamp = $Matches[1].ToUpperInvariant().PadLeft(8, '0') }
    }
    $r = $rvas.ToArray(); $n = $names.ToArray()
    [Array]::Sort($r, $n)
    return [pscustomobject]@{ Rva = $r; Name = $n; Stamp = $stamp; Base = $base; Path = $Path }
}

# "pkg::[file.odin]::proc" -> "pkg.proc (file.odin)"; "pkg::proc" -> "pkg.proc"
function Format-OdinSymbol([string]$s) {
    if ($s -match '^([\w.]+)::\[([^\]]+)\]::(.+)$') { return "$($Matches[1]).$($Matches[3])  ($($Matches[2]))" }
    if ($s -match '^([\w.]+)::(.+)$') { return "$($Matches[1]).$($Matches[2])" }
    return $s
}

# The function that holds `$Rva`: "name+0xoffset", or '' before the first one.
function Resolve-MapAddress($Map, [UInt64]$Rva) {
    $i = [Array]::BinarySearch($Map.Rva, $Rva)
    if ($i -lt 0) { $i = (-bnot $i) - 1 }
    if ($i -lt 0) { return '' }
    $name = Format-OdinSymbol $Map.Name[$i]
    $off = $Rva - $Map.Rva[$i]
    $paren = $name.IndexOf('  (')
    if ($paren -ge 0) { return '{0}+0x{1:X}{2}' -f $name.Substring(0, $paren), $off, $name.Substring($paren) }
    return '{0}+0x{1:X}' -f $name, $off
}

# What a minidump says of the crash: its modules (name, base, size, fingerprint) and the exception (code, address, thread).
function Read-MinidumpInfo([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 32 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'MDMP') { throw "$Path is not a minidump" }
    $count = [BitConverter]::ToUInt32($bytes, 8)
    $dir = [BitConverter]::ToUInt32($bytes, 12)
    $modules = New-Object Collections.Generic.List[object]
    $exception = $null
    for ($k = 0; $k -lt $count; $k++) {
        $e = $dir + 12 * $k
        $type = [BitConverter]::ToUInt32($bytes, $e)
        $rva = [BitConverter]::ToUInt32($bytes, $e + 8)
        if ($type -eq 4) {   # ModuleListStream: MINIDUMP_MODULE, 108 bytes each
            $n = [BitConverter]::ToUInt32($bytes, $rva)
            for ($i = 0; $i -lt $n; $i++) {
                $m = $rva + 4 + 108 * $i
                $base = [BitConverter]::ToUInt64($bytes, $m)
                $size = [BitConverter]::ToUInt32($bytes, $m + 8)
                $stamp = [BitConverter]::ToUInt32($bytes, $m + 16)
                $nameRva = [BitConverter]::ToUInt32($bytes, $m + 20)
                $len = [BitConverter]::ToUInt32($bytes, $nameRva)
                $name = [Text.Encoding]::Unicode.GetString($bytes, $nameRva + 4, $len)
                $modules.Add([pscustomobject]@{ Name = (Split-Path $name -Leaf); Path = $name; Base = $base; Size = $size; Fingerprint = ('{0:X8}{1:X}' -f $stamp, $size) })
            }
        } elseif ($type -eq 6) {   # ExceptionStream: thread id, then MINIDUMP_EXCEPTION (code, flags, record, address)
            $exception = [pscustomobject]@{
                Thread = [BitConverter]::ToUInt32($bytes, $rva)
                Code = [BitConverter]::ToUInt32($bytes, $rva + 8)
                Address = [BitConverter]::ToUInt64($bytes, $rva + 8 + 16)
            }
        }
    }
    return [pscustomobject]@{ Modules = $modules.ToArray(); Exception = $exception }
}

if ($Fingerprint) { Get-PeFingerprint $Fingerprint; exit 0 }
if ($Publish) {
    $ErrorActionPreference = 'Stop'
    $exe = (Resolve-Path $Publish).Path
    $dir = Split-Path $exe
    $stem = [IO.Path]::GetFileNameWithoutExtension($exe)
    $map = Join-Path $dir "$stem.map"
    if (-not (Test-Path $map)) { "error: $map is not there (build.bat links with /MAP)"; exit 1 }
    if ((Get-Item $map).LastWriteTimeUtc -lt (Get-Item $exe).LastWriteTimeUtc.AddMinutes(-5)) { "error: $map is older than $exe (not this link's)"; exit 1 }
    $fp = Get-PeFingerprint $exe
    $named = Join-Path $dir "$stem-$fp.map"
    Move-Item -Force $map $named
    $pattern = '^' + [regex]::Escape($stem) + '-[0-9A-F]{9,16}\.map$'
    Get-ChildItem $dir -Filter "$stem-*.map" -File | Where-Object { $_.Name -match $pattern -and $_.FullName -ne $named } | Remove-Item -Force
    if ($Store) {
        New-Item -ItemType Directory -Force $script:SymbolStore | Out-Null
        Copy-Item $named $script:SymbolStore -Force
        Get-ChildItem $script:SymbolStore -Filter '*.map' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 20 | Remove-Item -Force
    }
    "symbols: $named$(if ($Store) { ' (and in build\symbols)' })"
    exit 0
}
