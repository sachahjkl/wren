# Builds Wren's built-in image decoders (native\media: resvg, image-webp, zenavif-parse, rav1d, qcms) into
# build\media\wren_media.lib, a static library linked into wren.exe (no DLL to ship).
#   powershell -NoProfile -File tools\build_media.ps1 [-Force]
# Pinned inputs: every crate by exact version in native\media\Cargo.toml and by SHA-256 in native\media\Cargo.lock (the
# build runs with --locked); NASM (rav1d's assembly kernels, the same as dav1d's) by version and SHA-256 below, fetched
# once into build\tools. Rust: the stable toolchain of rustup (rust-version of the crates: 1.93).
# The script does nothing when build\media\STAMP matches the hash of the sources, Cargo.lock and this script.
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$NasmVersion = '2.16.03'
$NasmSha256 = '3ee4782247bcb874378d02f7eab4e294a84d3d15f3f6ee2de2f47a46aa7226e6'

$root = Split-Path $PSScriptRoot -Parent
$crate = Join-Path $root 'native\media'
$out = Join-Path $root 'build\media'
$lib = Join-Path $out 'wren_media.lib'
$stampFile = Join-Path $out 'STAMP'

# what the library is made of: change any of it and it is built again
$inputs = @(Get-ChildItem (Join-Path $crate 'src') -Recurse -File) + @(Get-Item (Join-Path $crate 'Cargo.toml'), (Join-Path $crate 'Cargo.lock'), $PSCommandPath)
# the toolkit's native text backend (ext\gui_toolkit\native\text) is built into the library (feature `text`: one Rust
# static library per program), unless WREN_TEXT=dwrite (a build that shapes with DirectWrite)
$text = $env:WREN_TEXT -ne 'dwrite'
if ($text) {
    $textCrate = Join-Path $root 'ext\gui_toolkit\native\text'
    $inputs += @(Get-ChildItem (Join-Path $textCrate 'src') -Recurse -File) + @(Get-Item (Join-Path $textCrate 'Cargo.toml'))
}
$sha = [Security.Cryptography.SHA256]::Create()
$all = New-Object IO.MemoryStream
if ($text) { $all.Write([byte[]](116, 101, 120, 116), 0, 4) }   # "text": the two builds have different stamps
foreach ($f in ($inputs | Sort-Object FullName)) { $b = [IO.File]::ReadAllBytes($f.FullName); $all.Write($b, 0, $b.Length) }
$stamp = ([BitConverter]::ToString($sha.ComputeHash($all.ToArray())) -replace '-', '').ToLower()
if (-not $Force -and (Test-Path $lib) -and (Test-Path $stampFile) -and ((Get-Content $stampFile -Raw).Trim() -eq $stamp)) {
    "wren_media up to date in $out"
    exit 0
}

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { throw 'cargo not found: install Rust with rustup (stable, x86_64-pc-windows-msvc)' }

# NASM, pinned
$tools = Join-Path $root 'build\tools'
$nasmDir = Join-Path $tools "nasm-$NasmVersion"
$nasm = Join-Path $nasmDir 'nasm.exe'
if (-not (Test-Path $nasm)) {
    New-Item -ItemType Directory -Force $tools | Out-Null
    $zip = Join-Path $tools "nasm-$NasmVersion-win64.zip"
    if (-not (Test-Path $zip) -or (Get-FileHash $zip -Algorithm SHA256).Hash -ne $NasmSha256.ToUpper()) {
        $url = "https://www.nasm.us/pub/nasm/releasebuilds/$NasmVersion/win64/nasm-$NasmVersion-win64.zip"
        "downloading $url"
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    }
    $got = (Get-FileHash $zip -Algorithm SHA256).Hash
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
$features = @(if ($text) { '--features', 'text' })
& cargo build --release --locked --manifest-path (Join-Path $crate 'Cargo.toml') --target-dir $target @features
if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item (Join-Path $target 'release\wren_media.lib') $lib -Force

# Wasmtime's library carries its own Rust standard library: both define the unmangled rust_eh_personality (a no-op on
# MSVC, where unwinding goes through __CxxFrameHandler3). Ours is renamed in the object that defines it (with fat LTO,
# the crate's single object) so that the two link together.
$sysroot = (& rustc --print sysroot).Trim()
$bin = Join-Path $sysroot 'lib\rustlib\x86_64-pc-windows-msvc\bin'
if (-not (Test-Path (Join-Path $bin 'llvm-objcopy.exe'))) {
    & rustup component add llvm-tools
    if ($LASTEXITCODE -ne 0) { throw 'rustup component add llvm-tools failed' }
}
$ar = Join-Path $bin 'llvm-ar.exe'
$objcopy = Join-Path $bin 'llvm-objcopy.exe'
$work = Join-Path $out 'rename'
if (Test-Path $work) { [IO.Directory]::Delete($work, $true) }
New-Item -ItemType Directory -Force $work | Out-Null
$member = (& $ar t $lib) | Where-Object { $_ -like 'wren_media-*.rcgu.o' } | Select-Object -First 1
if (-not $member) { throw 'wren_media.lib: the crate object was not found' }
Push-Location $work
try {
    & $ar x $lib $member
    & $objcopy --redefine-sym=rust_eh_personality=wren_media_rust_eh_personality $member
    if ($LASTEXITCODE -ne 0) { throw 'llvm-objcopy failed' }
    & $ar r $lib $member
    if ($LASTEXITCODE -ne 0) { throw 'llvm-ar failed' }
} finally { Pop-Location }
[IO.Directory]::Delete($work, $true)
[IO.File]::WriteAllText($stampFile, $stamp)
"built $lib ($([math]::Round((Get-Item $lib).Length / 1MB, 1)) MB) in $([math]::Round(((Get-Date) - $t0).TotalSeconds)) s"
