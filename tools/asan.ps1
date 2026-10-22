# AddressSanitizer builds: heap and stack overflows, use after free, double frees, in the unit tests of packages or in the
# browser.
#   powershell -File tools\asan.ps1 [-Packages base,url,...] [-Browser [-Console]] [-Program <package dir>] [-Out build\asan]
# (-Console: the browser as a console program, its ASan reports on stderr; else set log_path in ASAN_OPTIONS)
# (-Names: only these tests, as ODIN_TEST_NAMES. Default: the unit tests of every package of src\ that test_all runs, with -define:ODIN_TEST_THREADS=1.)
# Odin's -sanitize:address links LLVM's static ASan runtime with the static C runtime (libcmt); the native libraries
# (Lexbor, the image decoders, Wasmtime) use the dynamic one (msvcrt), and the static runtime then cannot intercept
# memcpy ("CHECK failed ... real_memcpy"). So the Odin code is compiled with the instrumentation to object files
# (-build-mode:obj) and linked here with MSVC's dynamic ASan runtime (clang_rt.asan_dynamic, next to the executable)
# and the dynamic C runtime, with every library the normal build links (-print-linker-flags).
# What it sees: every Odin allocation (the process heap: ASAN_OPTIONS=windows_hook_rtl_allocators=true routes
# HeapAlloc through ASan), Odin's stack and globals. What it does not: inside the native libraries (not instrumented;
# their own heaps), virtual memory arenas (base.Scope, vmem.Arena: VirtualAlloc, no redzones), Wasm linear memories
# (Wasmtime's guard pages already trap there).
# The browser's ASan build: build\asan\wren_asan.exe (debug, 32 MiB stack, the check build's tracker and script
# driver); run it through tools\memcheck_e2e.ps1 -Exe build\asan\wren_asan.exe -NoBuild (with ASAN_OPTIONS set).
param([string[]]$Packages = @(), [switch]$Browser, [string]$Program = '', [string]$Names = '', [switch]$Console, [string]$Out = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
if (-not $Out) { $Out = Join-Path $root 'build\asan' }
New-Item -ItemType Directory -Force $Out | Out-Null
$env:TEMP = $env:TMP = (New-Item -ItemType Directory -Force (Join-Path $root 'build\tmp')).FullName

# MSVC: the linker and the dynamic ASan runtime of the newest toolset
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc = Get-ChildItem (Join-Path $vs 'VC\Tools\MSVC') | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
$link = Join-Path $msvc 'bin\Hostx64\x64\link.exe'
$asanLib = Join-Path $msvc 'lib\x64\clang_rt.asan_dynamic-x86_64.lib'
$asanThunk = Join-Path $msvc 'lib\x64\clang_rt.asan_dynamic_runtime_thunk-x86_64.lib'
$asanDll = Join-Path $msvc 'bin\Hostx64\x64\clang_rt.asan_dynamic-x86_64.dll'
if (-not (Test-Path $asanDll)) { 'SKIP MSVC has no AddressSanitizer runtime (the "C++ AddressSanitizer" component of Visual Studio): nothing checked'; exit 0 }
Copy-Item $asanDll $Out -Force

$Coll = @('-collection:toolkit=ext/gui_toolkit', '-collection:wb=src')
# 256 MiB of default stack (the main thread, threads started with the executable's size): ASan's frames are several
# times larger (redzones), the 32 MiB of the normal builds overflow on the first page
$Stack = '/STACK:268435456'

# the libraries: those of the browser, which links every package (odin test cannot print its own; a library a test
# does not use costs nothing)
$flags = & odin build src/browser @Coll -sanitize:address -debug -define:WREN_CHANNEL=dev -resource:src/browser/wren_dev.rc "-out:$Out\browser_flags.exe" -print-linker-flags 2>&1 | Out-String
$libs = @([regex]::Matches($flags, '"([^"]+\.(lib|res))"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch 'clang_rt' } | Select-Object -Unique)
$libpaths = @([regex]::Matches($flags, '/LIBPATH:"([^"]+)"') | ForEach-Object { "/LIBPATH:$($_.Groups[1].Value)" })
if ($libs.Count -eq 0) { "FAIL cannot read the browser's libraries: $flags"; exit 1 }
$libs += 'winmm.lib', 'psapi.lib'   # (what the browser's normal build does not use: layout's benchmarks, the driver's counters)

# Compiles `$target` (odin build or odin test) instrumented, links it with the dynamic runtimes; returns the executable.
function Build-Asan($verb, $path, $name, [string[]]$extra = @(), $subsystem = 'CONSOLE') {
    $objDir = Join-Path $Out "obj_$name"
    if (Test-Path $objDir) { Get-ChildItem $objDir -File | Remove-Item -Force } else { New-Item -ItemType Directory $objDir | Out-Null }
    $exe = Join-Path $Out "$name.exe"
    $common = @($verb, $path) + $Coll + @('-sanitize:address', '-debug') + $extra
    & odin @common -build-mode:obj "-out:$objDir\$name.obj" 2>&1 | Out-Host
    if ($LASTEXITCODE) { throw "compiling $path failed" }
    $objs = @(Get-ChildItem $objDir -Filter *.obj | ForEach-Object { $_.FullName })
    & $link /nologo @objs "/OUT:$exe" /DEBUG /ENTRY:mainCRTStartup "/SUBSYSTEM:$subsystem" /MACHINE:X64 /INCREMENTAL:NO $Stack /NODEFAULTLIB:libcmt /DEFAULTLIB:msvcrt @libpaths $asanLib $asanThunk @libs 2>&1 | Out-Host
    if ($LASTEXITCODE) { throw "linking $path failed" }
    return $exe
}

# handle_segv=0: the access violations that are not errors stay with their owners (Wasmtime's guard pages, the stack
# guard pages of threads ASan does not know: the shell's, the system's, where ASan reported a "stack-overflow")
$env:ASAN_OPTIONS = 'windows_hook_rtl_allocators=true:handle_segv=0:detect_stack_use_after_return=false'
$failed = 0
if ($Browser) {
    # (with the tracker of the check build: its script driver runs the sessions of memcheck_e2e.ps1 / endurance.ps1)
    $exe = Build-Asan 'build' 'src/browser' 'browser_asan' @('-define:WREN_CHANNEL=dev', '-resource:src/browser/wren_dev.rc', '-define:WREN_TRACK_MEMORY=true') $(if ($Console) { 'CONSOLE' } else { 'WINDOWS' })
    "built $exe (ASAN_OPTIONS=$env:ASAN_OPTIONS when you run it)"
}
if ($Program) {
    $exe = Build-Asan 'build' $Program ([IO.Path]::GetFileName($Program.TrimEnd('/\')) + '_asan')
    "built $exe"
}
if ((-not $Browser -and -not $Program) -or $Packages.Count -gt 0) {
    if ($Packages.Count -eq 0) {
        $Packages = 'base', 'host', 'dom', 'html', 'url', 'http', 'cookies', 'csp', 'httpcache', 'fetch', 'config', 'css', 'style', 'webfont', 'images', 'layout', 'forms', 'js', 'page', 'webauthn', 'wasm', 'browser'
    }
    foreach ($pkg in (($Packages -join ',') -split ',' | Where-Object { $_ })) {
        $t0 = Get-Date
        try {
            $exe = Build-Asan 'test' "src/$pkg" "${pkg}_asan_test" (@('-define:ODIN_TEST_THREADS=1', '-define:ODIN_TEST_FANCY=false', '-define:ODIN_TEST_LOG_STATE_CHANGES=true') + $(if ($Names) { @("-define:ODIN_TEST_NAMES=$Names") } else { @() }))
            $ErrorActionPreference = 'Continue'   # (the runner logs to stderr)
            $o = & $exe 2>&1 | Out-String
            $ErrorActionPreference = 'Stop'
        } catch { $o = "$_" }
        $ok = $o -match 'All tests were successful' -and $o -notmatch 'ERROR: AddressSanitizer'
        "{0} {1} ({2} s)" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), "unit tests of $pkg under AddressSanitizer", [int]((Get-Date) - $t0).TotalSeconds
        if (-not $ok) {
            $failed++
            $i = $o.IndexOf('ERROR: AddressSanitizer')
            if ($i -ge 0) { $o.Substring([Math]::Max(0, $i - 200), [Math]::Min(6000, $o.Length - [Math]::Max(0, $i - 200))) } else { ($o -split "`n" | Select-Object -Last 25) -join "`n" }
        }
    }
}
Remove-Item Env:\ASAN_OPTIONS
"failed: $failed"
exit $failed
