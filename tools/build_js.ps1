# Builds Wren's JavaScript engine: the Odin engine (src\engine\jsrt, through the QuickJS C API of src\engine\jscapi) and the
# browser's bindings (native\js\odin, with the generated native\js\odin\bindings_gen.odin), compiled to WebAssembly, then
# pre-initialized (the engine, its intrinsics and the bindings set up once, at build time, and stored in the module's
# memory image: a realm starts from that image instead of running the engine's start-up code).
#   powershell -NoProfile -File tools\build_js.ps1 [-Force] [-OdinOpt size|speed...] [-Out <dir>]
# Outputs, in build\js:
#   wren_js_raw.wasm   the engine as compiled (a WASI reactor)
#   wren_js.wasm       the pre-initialized module the browser embeds (src\js\engine.odin)
# The linker is the wasm-ld that ships with Odin: nothing else is fetched. The script does nothing when build\js\STAMP
# matches the hash of every input (the glue, the engine and the host package that pre-initializes it).
# The QuickJS-ng pins below are not used to build anything: test262.ps1 and js_bench.ps1 read them (QuickJS-ng's test262
# configuration, and its native release as the reference to measure against).
param([switch]$Force, [switch]$Names, [string]$Out = '', [switch]$NoSnapshot, [string[]]$ExtraFlags = @(),
      # the Odin glue/engine object: -o: level, and extra flags (-disable-assert -no-bounds-check -no-type-assert -use-single-module -target-features:... -microarch:...)
      [ValidateSet('none', 'minimal', 'size', 'speed', 'aggressive')][string]$OdinOpt = 'size', [string[]]$OdinFlags = @($env:WREN_ODIN_FLAGS -split ';' | Where-Object { $_ }))
$ErrorActionPreference = 'Stop'
$QjsVersion = '0.17.0'
$QjsSha256 = '559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9'

$root = Split-Path $PSScriptRoot -Parent
$native = Join-Path $root 'native\js'
$out = if ($Out) { [IO.Path]::GetFullPath((Join-Path (Get-Location) $Out)) } else { Join-Path $root 'build\js' }
$raw = Join-Path $out 'wren_js_raw.wasm'
$final = Join-Path $out 'wren_js.wasm'
$stampFile = Join-Path $out 'STAMP'

# (not Get-FileHash: the CI's build step runs this from cmd after the MSVC environment was set, and Windows PowerShell did not find the cmdlet there)
function Sha256Of([string]$path) {
    $h = [Security.Cryptography.SHA256]::Create()
    $s = [IO.File]::OpenRead($path)
    try { return ([BitConverter]::ToString($h.ComputeHash($s)) -replace '-', '').ToUpper() } finally { $s.Dispose(); $h.Dispose() }
}

function Get-Pinned([string]$url, [string]$file, [string]$sha) {
    if ((Test-Path $file) -and (Sha256Of $file) -eq $sha.ToUpper()) { return }
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    "downloading $url"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
    $got = Sha256Of $file
    if ($got -ne $sha.ToUpper()) { Remove-Item $file -Force; throw "SHA-256 mismatch for $url`: expected $sha, got $got" }
}

# what the engine is made of: change any of it and it is built again (the Odin engine and its packages count: the glue
# imports them from src\)
$inputs = @(Get-ChildItem $native -Recurse -File | Where-Object { $_.Extension -in '.c', '.h', '.js', '.odin' }) +
          @(Get-ChildItem (Join-Path $root 'src\engine') -Recurse -Filter *.odin) +
          @(Get-ChildItem (Join-Path $root 'src\wasm') -Filter *.odin) +
          @(Get-ChildItem (Join-Path $root 'src\tools\jsengine') -Filter *.odin -ErrorAction SilentlyContinue) +
          @(Get-Item $PSCommandPath)
$sha = [Security.Cryptography.SHA256]::Create()
$all = New-Object IO.MemoryStream
foreach ($f in ($inputs | Sort-Object FullName)) {
    $name = [Text.Encoding]::UTF8.GetBytes($f.FullName.Substring($root.Length))
    $all.Write($name, 0, $name.Length)
    $b = [IO.File]::ReadAllBytes($f.FullName); $all.Write($b, 0, $b.Length)
}
$flagText = [Text.Encoding]::UTF8.GetBytes("$($ExtraFlags -join ' ')|$OdinOpt|$($OdinFlags -join ' ')")
$all.Write($flagText, 0, $flagText.Length)
$stamp = ([BitConverter]::ToString($sha.ComputeHash($all.ToArray())) -replace '-', '').ToLower()
if (-not $Force -and (Test-Path $final) -and (Test-Path $stampFile) -and ((Get-Content $stampFile -Raw).Trim() -eq $stamp)) {
    "wren_js up to date in $out"
    exit 0
}

# The linker: the wasm-ld that ships with Odin (<odin root>\bin). The module is a freestanding wasm32 object with no C library:
# the Odin runtime and the engine are all of it (the host provides the WASI calls the glue imports).
$odinRoot = (& odin root).Trim().TrimEnd('\', '/')
$wasmLd = Join-Path $odinRoot 'bin\wasm-ld.exe'
if (-not (Test-Path $wasmLd)) { throw "wasm-ld.exe not found in $odinRoot\bin (it ships with Odin)" }
$srcRoot = Join-Path $out 'src'
# (the JavaScript parts of the realm, native\js\prelude\*.js if there are any, are embedded by the Odin glue itself:
# native\js\odin\prelude.odin, #load_directory)

$ldflags = @(
    '--no-entry', '--gc-sections',
    # the C stack (in linear memory): JavaScript recursion depth is bounded by JS_SetMaxStackSize (768 KiB); the rest is
    # room for what runs past that bound before unwinding (reporting the RangeError of a listener deep in a recursion
    # through the browser: its error event, the host calls). Each realm commits its stack: 1 MiB, not more.
    '-z', 'stack-size=1048576'
)
if (-not $Names) { $ldflags += '--strip-debug' }
New-Item -ItemType Directory -Force $out | Out-Null
$t0 = Get-Date
# The Odin glue and engine (native\js\odin, src\engine) to one wasm32 object, linked by Odin's wasm-ld.
# It is freestanding (no Odin runtime start-up: wj_preinit runs it), -o:size to match the engine's size budget.
$odinObj = Join-Path $out 'odin_glue.o'
# the defines the Odin glue reads: the test262 image (test262_host.odin)
$odinDefines = @('-define:WJ_JSRT=true', '-define:JSCAPI_EXPORT=true')
if ($ExtraFlags -contains '-DWREN_TEST262=1') { $odinDefines += '-define:WREN_TEST262=true' }
& odin build (Join-Path $native 'odin') -build-mode:obj -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -vet "-o:$OdinOpt" @OdinFlags -collection:wb=src -collection:toolkit=ext/gui_toolkit @odinDefines -out:$odinObj
if ($LASTEXITCODE -ne 0) { throw "odin build of native\js\odin failed" }

& $wasmLd @ldflags $odinObj -o $raw
if ($LASTEXITCODE -ne 0) { throw "wasm-ld failed ($LASTEXITCODE)" }
"compiled $raw ($([math]::Round((Get-Item $raw).Length / 1KB)) KiB) in $([math]::Round(((Get-Date) - $t0).TotalSeconds)) s"
if ($NoSnapshot) { exit 0 }

# pre-initialize (src\tools\jsengine: runs wj_preinit under Wasmtime and writes the snapshot)
$exe = Join-Path $root 'build\jsengine.exe'
Push-Location $root
try {
    # Wasm calls run on the main thread: room for wasm.wasmtime.max_stack_bytes
    & odin build src/tools/jsengine -collection:wb=src -vet -out:$exe -o:speed "-extra-linker-flags:/STACK:33554432"
    if ($LASTEXITCODE -ne 0) { throw "building src\tools\jsengine failed" }
    & $exe snapshot $raw $final
    if ($LASTEXITCODE -ne 0) { throw "pre-initialization of the engine failed" }
} finally { Pop-Location }
[IO.File]::WriteAllText($stampFile, $stamp)
"built $final ($([math]::Round((Get-Item $final).Length / 1KB)) KiB)"
