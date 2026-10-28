# build_spike.ps1: builds the Odin<->C link spike (native/js/odin_spike) into one wasm module.
#   powershell -NoProfile -File native\js\odin_spike\build_spike.ps1
# It compiles the QuickJS-ng C sources (the ones build_js.ps1 uses) and spike.c with zig cc, compiles hello.odin to a
# wasm32 object with Odin, and links them all with zig's wasm-ld into build\spike\spike.wasm. The flags match
# tools\build_js.ps1 (wasm32-wasi reactor, the same -m features) so the spike proves the real toolchain, not a toy one.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$zig  = Join-Path $root 'build\tools\zig-x86_64-windows-0.15.2\zig.exe'
$qjs  = Join-Path $root 'build\js\src\quickjs-0.17.0'
if (-not (Test-Path $zig)) { $zig = 'S:\wren\build\tools\zig-x86_64-windows-0.15.2\zig.exe' }
if (-not (Test-Path $qjs)) { $qjs = 'S:\wren\build\js\src\quickjs-0.17.0' }
$out  = Join-Path $root 'build\spike'
New-Item -ItemType Directory -Force $out | Out-Null

$cflags = @(
    '-target', 'wasm32-wasi', '-O2', '-mexec-model=reactor',
    '-mbulk-memory', '-msimd128', '-mnontrapping-fptoint', '-msign-ext', '-mmutable-globals', '-mmultivalue',
    '-DQUICKJS_NG_BUILD', '-D_WASI_EMULATED_SIGNAL', '-DNDEBUG',
    '-fno-exceptions', '-fvisibility=hidden', '-g0',
    '-I', $qjs
)
$objs = @()
$t0 = Get-Date

# QuickJS and the harness, each to an object
foreach ($c in @((Join-Path $qjs 'quickjs.c'), (Join-Path $qjs 'libregexp.c'), (Join-Path $qjs 'libunicode.c'), (Join-Path $qjs 'dtoa.c'), (Join-Path $PSScriptRoot 'spike.c'))) {
    $o = Join-Path $out ([IO.Path]::GetFileNameWithoutExtension($c) + '.o')
    & $zig cc @cflags -c $c -o $o
    if ($LASTEXITCODE -ne 0) { throw "zig cc failed on $c" }
    $objs += $o
}

# the Odin side, to a wasm32 object
$odinObj = Join-Path $out 'hello.o'
& odin build $PSScriptRoot -build-mode:obj -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -out:$odinObj
if ($LASTEXITCODE -ne 0) { throw 'odin build failed' }
$objs += $odinObj

# link everything with wasm-ld: a reactor (no _start), the C runtime's crt and libc from zig's wasi sysroot. zig cc
# gives us the right sysroot paths through -### once; simplest is to let `zig cc` do the final link (it drives wasm-ld
# and adds wasi-libc), passing all objects.
$ldflags = @('-target', 'wasm32-wasi', '-mexec-model=reactor', '-lwasi-emulated-signal', '-Wl,-z,stack-size=1048576', '-Wl,--gc-sections', '-g0')
$wasm = Join-Path $out 'spike.wasm'
& $zig cc @ldflags @objs -o $wasm
if ($LASTEXITCODE -ne 0) { throw 'link (zig cc) failed' }
"linked $wasm ($([math]::Round((Get-Item $wasm).Length / 1KB)) KiB) in $([math]::Round(((Get-Date) - $t0).TotalSeconds)) s"
