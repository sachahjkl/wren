# Builds Wren's Rust code (the native\ workspace) into build\native\wren_native.lib, the one Rust static library linked
# into wren.exe (no DLL to ship): the image decoders and WOFF2 (native\media: resvg, image-webp, zenavif-parse, rav1d,
# qcms, brotli), the toolkit's native text backend (ext\gui_toolkit\native\text) and its accessibility adapter
# (ext\gui_toolkit\native\a11y), picked by the assembly crate native\wren_native. See native\Cargo.toml.
#   powershell -NoProfile -File tools\build_native.ps1 [-Force]
# Pinned inputs: every crate by exact version in the crates' Cargo.toml and by SHA-256 in native\Cargo.lock (the build
# runs with --locked); NASM (rav1d's assembly kernels, the same as dav1d's) by version and SHA-256 below, fetched once
# into build\tools. Rust: the stable toolchain of rustup (the CI pins its version).
# The script does nothing when build\native\STAMP matches the hash of the sources, Cargo.lock and this script. Cargo's
# target directory (build\native\target) keeps every crate built: a change in one crate rebuilds that crate and what
# depends on it.
# WREN_TEXT=dwrite: a build that shapes with DirectWrite, without the text backend (feature `text` left out).
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$NasmVersion = '2.16.03'
$NasmSha256 = '3ee4782247bcb874378d02f7eab4e294a84d3d15f3f6ee2de2f47a46aa7226e6'

$root = Split-Path $PSScriptRoot -Parent
$ws = Join-Path $root 'native'
$out = Join-Path $root 'build\native'
$lib = Join-Path $out 'wren_native.lib'
$stampFile = Join-Path $out 'STAMP'
$text = $env:WREN_TEXT -ne 'dwrite'
$features = @('a11y')
if ($text) { $features = @('text') + $features }

# what the library is made of: change any of it and it is built again
$crates = @((Join-Path $ws 'media'), (Join-Path $ws 'wren_native'), (Join-Path $root 'ext\gui_toolkit\native\a11y'))
if ($text) { $crates += Join-Path $root 'ext\gui_toolkit\native\text' }
$inputs = @(Get-Item (Join-Path $ws 'Cargo.toml'), (Join-Path $ws 'Cargo.lock'), $PSCommandPath)
foreach ($c in $crates) { $inputs += @(Get-ChildItem (Join-Path $c 'src') -Recurse -File) + @(Get-Item (Join-Path $c 'Cargo.toml')) }
$sha = [Security.Cryptography.SHA256]::Create()
$all = New-Object IO.MemoryStream
$tag = [Text.Encoding]::UTF8.GetBytes("features=$($features -join ',')`n")   # two feature sets, two stamps
$all.Write($tag, 0, $tag.Length)
foreach ($f in ($inputs | Sort-Object FullName)) { $b = [IO.File]::ReadAllBytes($f.FullName); $all.Write($b, 0, $b.Length) }
$stamp = ([BitConverter]::ToString($sha.ComputeHash($all.ToArray())) -replace '-', '').ToLower()
if (-not $Force -and (Test-Path $lib) -and (Test-Path $stampFile) -and ((Get-Content $stampFile -Raw).Trim() -eq $stamp)) {
    "wren_native up to date in $out"
    exit 0
}

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { throw 'cargo not found: install Rust with rustup (stable, x86_64-pc-windows-msvc)' }

# (not Get-FileHash: under the CI's build step, run from cmd after the MSVC environment was set, Windows PowerShell does not find the cmdlet: "not recognized"; the hash the .NET way works everywhere)
function Sha256Of($path) {
    $h = [Security.Cryptography.SHA256]::Create()
    $s = [IO.File]::OpenRead($path)
    try { return ([BitConverter]::ToString($h.ComputeHash($s)) -replace '-', '').ToUpper() } finally { $s.Dispose(); $h.Dispose() }
}

# NASM, pinned
$tools = Join-Path $root 'build\tools'
$nasmDir = Join-Path $tools "nasm-$NasmVersion"
$nasm = Join-Path $nasmDir 'nasm.exe'
if (-not (Test-Path $nasm)) {
    New-Item -ItemType Directory -Force $tools | Out-Null
    $zip = Join-Path $tools "nasm-$NasmVersion-win64.zip"
    if (-not (Test-Path $zip) -or (Sha256Of $zip) -ne $NasmSha256.ToUpper()) {
        $url = "https://www.nasm.us/pub/nasm/releasebuilds/$NasmVersion/win64/nasm-$NasmVersion-win64.zip"
        "downloading $url"
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    }
    $got = Sha256Of $zip
    if ($got -ne $NasmSha256.ToUpper()) { Remove-Item $zip -Force; throw "SHA-256 mismatch for NASM: expected $NasmSha256, got $got" }
    Expand-Archive -Path $zip -DestinationPath $tools -Force
    if (-not (Test-Path $nasm)) { throw "nasm.exe not found in $nasmDir" }
}
$env:PATH = "$nasmDir;$env:PATH"
$env:NASM = $nasm

# MSVC for the few C / assembly helpers the crates build (cc crate finds it itself; vcvars only when needed)
if (-not $env:VCINSTALLDIR) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vs = & $vswhere -latest -products * -property installationPath
        cmd /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" >nul && set" | ForEach-Object {
            if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] }
        }
    }
}

$target = Join-Path $out 'target'
$t0 = Get-Date
& cargo build --release --locked --manifest-path (Join-Path $ws 'Cargo.toml') --target-dir $target -p wren_native --features ($features -join ',')
if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item (Join-Path $target 'release\wren_native.lib') $lib -Force

# Wasmtime's library carries its own Rust standard library (built by another compiler: its mangled symbols differ), and
# both define the unmangled rust_eh_personality (a no-op on MSVC, where unwinding goes through __CxxFrameHandler3). Ours
# is renamed in the object that defines it (with fat LTO, the assembly crate's single object) so that the two link
# together. This is the only symbol renamed: the libraries of this workspace share one standard library.
$sysroot = (& rustc --print sysroot).Trim()
$bin = Join-Path $sysroot 'lib\rustlib\x86_64-pc-windows-msvc\bin'
if (-not (Test-Path (Join-Path $bin 'llvm-objcopy.exe'))) {
    & rustup component add llvm-tools
    if ($LASTEXITCODE -ne 0) { throw 'rustup component add llvm-tools failed' }
}
$ar = Join-Path $bin 'llvm-ar.exe'
$nm = Join-Path $bin 'llvm-nm.exe'
$objcopy = Join-Path $bin 'llvm-objcopy.exe'
$defs = @(& $nm --defined-only --print-file-name $lib 2>$null | Where-Object { $_ -match '\.lib:(.+\.o): +[0-9a-fA-F]+ T rust_eh_personality$' } | ForEach-Object { $Matches[1] })
if ($defs.Count -ne 1) { throw "wren_native.lib: expected one object defining rust_eh_personality, found $($defs.Count)" }
$member = $defs[0]
$work = Join-Path $out 'rename'
if (Test-Path $work) { [IO.Directory]::Delete($work, $true) }
New-Item -ItemType Directory -Force $work | Out-Null
Push-Location $work
try {
    & $ar x $lib $member
    & $objcopy --redefine-sym=rust_eh_personality=wren_native_rust_eh_personality $member
    if ($LASTEXITCODE -ne 0) { throw 'llvm-objcopy failed' }
    & $ar r $lib $member
    if ($LASTEXITCODE -ne 0) { throw 'llvm-ar failed' }
} finally { Pop-Location }
[IO.Directory]::Delete($work, $true)
[IO.File]::WriteAllText($stampFile, $stamp)
"built $lib ($([math]::Round((Get-Item $lib).Length / 1MB, 1)) MB) in $([math]::Round(((Get-Date) - $t0).TotalSeconds)) s"
