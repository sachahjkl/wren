# Builds Wren's JavaScript engine: QuickJS-ng compiled to WebAssembly with the browser's bindings (native\js), then
# pre-initialized (the engine, its intrinsics and the bindings set up once, at build time, and stored in the module's
# memory image: a realm starts from that image instead of running the engine's start-up code).
#   powershell -NoProfile -File tools\build_js.ps1 [-Force] [-Opt O2|O3|Os] [-NoLto] [-Out <dir>]
# Outputs, in build\js:
#   wren_js_raw.wasm   the engine as compiled (a WASI reactor)
#   wren_js.wasm       the pre-initialized module the browser embeds (src\js\engine.odin)
# Pinned inputs: Zig (its clang and wasi-libc) and the QuickJS-ng release source by version and SHA-256 below, fetched
# once into build\tools and build\js\src; native\js\patches\*.patch applied to the source; the generated headers and
# bindings in native\js\gen (bindgen). The script does nothing when build\js\STAMP matches the hash of every input.
param([switch]$Force, [switch]$Names, [string]$Opt = 'O3', [switch]$NoLto, [string]$Out = '', [switch]$NoSnapshot, [string[]]$ExtraFlags = @(),
      [ValidateSet('dlmalloc', 'mimalloc')][string]$Allocator = 'dlmalloc')
$ErrorActionPreference = 'Stop'
$ZigVersion = '0.15.2'
$ZigSha256 = '3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c'
$QjsVersion = '0.17.0'
$QjsSha256 = '559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9'
$MimallocVersion = '3.5.3'
$MimallocSha256 = '3b4a15153a59905995f7070296ed604bb5ccc00cabb8b93446931aff77224d47'

$root = Split-Path $PSScriptRoot -Parent
$native = Join-Path $root 'native\js'
$out = if ($Out) { [IO.Path]::GetFullPath((Join-Path (Get-Location) $Out)) } else { Join-Path $root 'build\js' }
$raw = Join-Path $out 'wren_js_raw.wasm'
$final = Join-Path $out 'wren_js.wasm'
$stampFile = Join-Path $out 'STAMP'

function Get-Pinned([string]$url, [string]$file, [string]$sha) {
    if ((Test-Path $file) -and (Get-FileHash $file -Algorithm SHA256).Hash -eq $sha.ToUpper()) { return }
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    "downloading $url"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
    $got = (Get-FileHash $file -Algorithm SHA256).Hash
    if ($got -ne $sha.ToUpper()) { Remove-Item $file -Force; throw "SHA-256 mismatch for $url`: expected $sha, got $got" }
}

# what the engine is made of: change any of it and it is built again
$inputs = @(Get-ChildItem $native -Recurse -File | Where-Object { $_.Extension -in '.c', '.h', '.patch', '.js' }) +
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
$flagText = [Text.Encoding]::UTF8.GetBytes("$ZigVersion|$QjsVersion|$Opt|$NoLto|$($ExtraFlags -join ' ')|$Allocator")
$all.Write($flagText, 0, $flagText.Length)
$stamp = ([BitConverter]::ToString($sha.ComputeHash($all.ToArray())) -replace '-', '').ToLower()
if (-not $Force -and (Test-Path $final) -and (Test-Path $stampFile) -and ((Get-Content $stampFile -Raw).Trim() -eq $stamp)) {
    "wren_js up to date in $out"
    exit 0
}

# Zig, pinned (its clang targets wasm32-wasi and ships wasi-libc)
$tools = Join-Path $root 'build\tools'
$zigDir = Join-Path $tools "zig-x86_64-windows-$ZigVersion"
$zig = Join-Path $zigDir 'zig.exe'
if (-not (Test-Path $zig)) {
    $zip = Join-Path $tools "zig-x86_64-windows-$ZigVersion.zip"
    Get-Pinned "https://ziglang.org/download/$ZigVersion/zig-x86_64-windows-$ZigVersion.zip" $zip $ZigSha256
    Expand-Archive -Path $zip -DestinationPath $tools -Force
    if (-not (Test-Path $zig)) { throw "zig.exe not found in $zigDir" }
}

# QuickJS-ng release source, pinned, patched
$srcRoot = Join-Path $out 'src'
$qjs = Join-Path $srcRoot "quickjs-$QjsVersion"
$tarball = Join-Path $tools "quickjs-ng-v$QjsVersion.tar.gz"
Get-Pinned "https://github.com/quickjs-ng/quickjs/archive/refs/tags/v$QjsVersion.tar.gz" $tarball $QjsSha256
if (Test-Path $qjs) { [IO.Directory]::Delete($qjs, $true) }
New-Item -ItemType Directory -Force $srcRoot | Out-Null
& tar -xzf $tarball -C $srcRoot
if ($LASTEXITCODE -ne 0) { throw "tar failed ($LASTEXITCODE)" }
# git apply as a plain patch tool: the source tree must not be taken for a part of this repository
$ceiling = $env:GIT_CEILING_DIRECTORIES
$env:GIT_CEILING_DIRECTORIES = $srcRoot
try {
    foreach ($p in (Get-ChildItem (Join-Path $native 'patches') -Filter *.patch | Sort-Object Name)) {
        Push-Location $qjs
        try {
            & git apply --whitespace=nowarn $p.FullName
            if ($LASTEXITCODE -ne 0) { throw "patch $($p.Name) does not apply to QuickJS-ng $QjsVersion" }
        } finally { Pop-Location }
    }
} finally { $env:GIT_CEILING_DIRECTORIES = $ceiling }
if (-not (Select-String -Path (Join-Path $qjs 'quickjs.h') -Pattern 'JS_SetGCPrologue' -Quiet)) { throw 'the QuickJS-ng patches were not applied' }

# the JavaScript parts of the realm (native\js\prelude\*.js) as C strings, run at pre-initialization
$genDir = Join-Path $out 'gen'
New-Item -ItemType Directory -Force $genDir | Out-Null
$pre = New-Object System.Text.StringBuilder
[void]$pre.Append("/* generated by tools/build_js.ps1 from native/js/prelude/*.js */`n")
$preludes = @(Get-ChildItem (Join-Path $native 'prelude') -Filter *.js -ErrorAction SilentlyContinue | Sort-Object Name)
foreach ($p in $preludes) {
    $bytes = [IO.File]::ReadAllBytes($p.FullName)
    [void]$pre.Append("static const char wj_prelude_$($p.BaseName -replace '[^A-Za-z0-9]', '_')[] = {")
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($i % 24 -eq 0) { [void]$pre.Append("`n    ") }
        [void]$pre.Append($bytes[$i]).Append(',')
    }
    [void]$pre.Append("0 };`n")
}
[void]$pre.Append("static const struct { const char *name; const char *source; } wj_prelude_sources[] = {`n")
foreach ($p in $preludes) { [void]$pre.Append("    { `"prelude/$($p.Name)`", wj_prelude_$($p.BaseName -replace '[^A-Za-z0-9]', '_') },`n") }
if ($preludes.Count -eq 0) { [void]$pre.Append("    { 0, 0 },`n") }
[void]$pre.Append("};`nstatic const int wj_prelude_count = $($preludes.Count);`n")
[IO.File]::WriteAllText((Join-Path $genDir 'prelude_sources.h'), $pre.ToString())

# compile: one translation unit per file, link-time optimization across all of them
$cflags = @(
    '-target', 'wasm32-wasi', "-$Opt", '-mexec-model=reactor',
    '-mbulk-memory', '-msimd128', '-mnontrapping-fptoint', '-msign-ext', '-mmutable-globals', '-mmultivalue',
    '-DWREN_JS=1', '-DQUICKJS_NG_BUILD', '-D_WASI_EMULATED_SIGNAL', '-DNDEBUG',
    '-fno-exceptions', '-fvisibility=hidden', $(if ($Names) { '-g' } else { '-g0' }),
    '-I', $qjs, '-I', (Join-Path $native 'engine'), '-I', (Join-Path $native 'gen'), '-I', (Join-Path $native 'runtime'), '-I', $genDir
)
if (-not $NoLto) { $cflags += '-flto' }
$cflags += $ExtraFlags
$sources = @('quickjs.c', 'libregexp.c', 'libunicode.c', 'dtoa.c') | ForEach-Object { Join-Path $qjs $_ }
$sources += @(Get-ChildItem (Join-Path $native 'engine'), (Join-Path $native 'runtime'), (Join-Path $native 'gen') -Recurse -Filter *.c -ErrorAction SilentlyContinue | ForEach-Object FullName)
if ($Allocator -eq 'mimalloc') {
    # the engine's heap through mimalloc (pinned), the C library's own through wasi-libc's dlmalloc
    $mi = Join-Path $srcRoot "mimalloc-$MimallocVersion"
    $mtar = Join-Path $tools "mimalloc-v$MimallocVersion.tar.gz"
    Get-Pinned "https://github.com/microsoft/mimalloc/archive/refs/tags/v$MimallocVersion.tar.gz" $mtar $MimallocSha256
    if (-not (Test-Path $mi)) { & tar -xzf $mtar -C $srcRoot; if ($LASTEXITCODE -ne 0) { throw "tar failed ($LASTEXITCODE)" } }
    $sources += (Join-Path $mi 'src\static.c')
    $cflags += @('-DWJ_MIMALLOC=1', '-I', (Join-Path $mi 'include'), '-DMI_STAT=0', '-DMI_SECURE=0', '-DMI_DEBUG=0')
}
$ldflags = @(
    '-lwasi-emulated-signal',
    # the C stack (in linear memory): JavaScript recursion depth is bounded by JS_SetMaxStackSize below this
    '-Wl,-z,stack-size=1048576',
    $(if ($Names) { '-Wl,--gc-sections' } else { '-Wl,--strip-debug' }), '-Wl,--gc-sections'
)
New-Item -ItemType Directory -Force $out | Out-Null
$t0 = Get-Date
& $zig cc @cflags @sources @ldflags -o $raw
if ($LASTEXITCODE -ne 0) { throw "zig cc failed ($LASTEXITCODE)" }
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
