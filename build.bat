@echo off
:: ============================================================================================================
::  build.bat : builds Wren with the Odin compiler
:: ============================================================================================================
::
::    build.bat            development build, fast to compile       -> build\wren.exe
::    build.bat debug      debug information, no optimisation       -> build\wren.exe
::    build.bat profile    optimised + PDB + measurement hooks      -> build\wren_prof.exe
::    build.bat check      debug + every allocation tracked         -> build\wren_check.exe
::    build.bat release    the build the release workflow packages  -> build\wren.exe
::
::  Channel: every build is a *development* build (blueprint icon, "development build" in about:home and the menu)
::  but `release` (amber icon). It goes in as -define:WREN_CHANNEL (about.odin: APP_CHANNEL) with its icon, and in
::  build\wren.channel, which tools\package.ps1 checks before packaging.
::
::  Compile speed: Odin hands LLVM one module per package with -use-separate-modules, and LLVM then works on all
::  cores (about 5 s instead of 55 s for a full build). The development, debug and check builds use it; `release`
::  and `profile` keep a single module (inlining across packages; measurements as in the shipped build).
::
::  Steps: 1. checks   2. dependencies   3. generated code   4. common flags   5. the build itself
:: ============================================================================================================
setlocal
cd /D "%~dp0"
set "VARIANT=%~1"
if "%VARIANT%"=="" set "VARIANT=dev"
if /I "%VARIANT%"=="help" goto usage
if "%VARIANT%"=="-h" goto usage
if "%VARIANT%"=="--help" goto usage
if "%VARIANT%"=="/?" goto usage
for %%v in (dev debug profile check release) do if /I "%VARIANT%"=="%%v" goto variant_ok
echo unknown build "%VARIANT%"
echo.
call :usage
exit /b 1
:variant_ok


:: ------------------------------------------------------------------------------------------------------------
::  1. Checks
:: ------------------------------------------------------------------------------------------------------------

:: the toolkit is a git submodule (ext\gui_toolkit, imported as "toolkit:<package>")
if not exist ext\gui_toolkit\ui (
    echo ext\gui_toolkit is empty: run  git submodule update --init
    exit /b 1
)

:: the Odin compiler this tree is written for (odin.version; the CI installs that release, pinned by SHA-256 in
:: .github\actions\setup\action.yml): another one may build differently or not at all. WREN_ANY_ODIN=1 skips this.
set /p WREN_ODIN=<odin.version
if not defined WREN_ANY_ODIN (
    odin version 2>nul | findstr /C:"%WREN_ODIN%" >nul || (
        echo This tree needs Odin %WREN_ODIN% ^(odin.version^); found:
        odin version
        echo Install that release, or set WREN_ANY_ODIN=1 to build anyway.
        exit /b 1
    )
)


:: ------------------------------------------------------------------------------------------------------------
::  2. Dependencies (each script does nothing when its output is up to date)
:: ------------------------------------------------------------------------------------------------------------
::  Wasmtime   C API, a pinned release checked by SHA-256                     -> build\wasmtime
::  Lexbor     HTML parser (ext\lexbor) + the C shims (src\shim), MSVC         -> build\lexbor\lexbor.lib
::  emoji      Noto Color Emoji (COLR v1), pinned by SHA-256                -> build\emoji (compiled into the exe)
::  media      image decoders in Rust (resvg, image-webp, zenavif-parse,       -> build\media\wren_media.lib
::             rav1d, qcms; crates pinned by Cargo.lock, NASM by SHA-256)

call :step "fetching Wasmtime"            tools\fetch_wasmtime.ps1 || exit /b 1
call :step "building Lexbor"              tools\build_lexbor.ps1   || exit /b 1
call :step "building the image decoders"  tools\build_media.ps1    || exit /b 1
call :step "fetching the emoji font"      tools\fetch_emoji.ps1    || exit /b 1
if not exist build mkdir build


:: ------------------------------------------------------------------------------------------------------------
::  3. Generated code
:: ------------------------------------------------------------------------------------------------------------
::  bindgen    the web API from its description (api\*.widl): host bindings, guest SDK, docs and conformance
::             tests (only what changed)
::  JS engine  QuickJS-ng + the generated bindings, compiled to Wasm with a pinned zig and pre-initialized
::             -> build\js\wren_js.wasm, embedded in wren.exe (src\js\image)
::  launcher   wren.com, the console launcher (src\tools\wrencom)                 -> build\wren.com, embedded in wren.exe

:: (an exe of its own, deleted after: two builds at once, test_all -Jobs n runs several, wrote build\bindgen.exe together, Error(013))
set "BINDGEN=build\bindgen_%RANDOM%%RANDOM%.exe"
odin run src/tools/bindgen -collection:wb=src -vet -use-separate-modules -out:%BINDGEN% || exit /b 1
del "%BINDGEN%" 2>nul
call :step "building the JavaScript engine"  tools\build_js.ps1 || exit /b 1

:: the console launcher: build\wren.com, a small console program (src\tools\wrencom, core library only) that cmd and PowerShell
:: prefer to wren.exe when `wren` is typed; wren.exe embeds it (src\browser\console_launcher.odin) and Setup writes it beside
:: itself with the PATH entry. A console program waits for `wren ctl ...` and hands its output and exit code to the caller. The
:: same C runtime flags as wren.exe (below): nothing but the system's files.
:: Built only when a source is newer than it: two builds that run at once (test_all -Jobs n) would otherwise both write it, and
:: one of them is refused (Error(013)) when the other, or a test that runs it, holds the file.
powershell -NoProfile -Command "$b = Get-Item build\wren.com -ErrorAction SilentlyContinue; if ($b -and -not (Get-ChildItem src\tools\wrencom -Filter *.odin | Where-Object { $_.LastWriteTimeUtc -gt $b.LastWriteTimeUtc })) { exit 0 } else { exit 1 }"
if errorlevel 1 odin build src/tools/wrencom -vet -subsystem:console -o:size -out:build/wren.com -extra-linker-flags:"/NODEFAULTLIB:vcruntime.lib /DEFAULTLIB:libvcruntime.lib" || exit /b 1


:: ------------------------------------------------------------------------------------------------------------
::  4. Common flags
:: ------------------------------------------------------------------------------------------------------------

:: channel and icon
set "WREN_CHANNEL=dev"
set "WREN_RC=src/browser/wren_dev.rc"
if "%VARIANT%"=="release" (
    set "WREN_CHANNEL=release"
    set "WREN_RC=src/browser/wren.rc"
)

:: the version resource of wren.exe (publisher, product, File version) takes its numbers from APP_VERSION
powershell -NoProfile -ExecutionPolicy Bypass -File tools\make_version_h.ps1 || exit /b 1

:: collections: "toolkit:<package>" and "wb:<package>"
set "FLAGS=-collection:toolkit=ext/gui_toolkit -collection:wb=src"
set "FLAGS=%FLAGS% -resource:%WREN_RC% -define:WREN_CHANNEL=%WREN_CHANNEL%"
:: another toolkit checkout (WREN_TOOLKIT=S:/gt_wt/other), to compare two toolkits with the same browser sources
if defined WREN_TOOLKIT set "FLAGS=-collection:toolkit=%WREN_TOOLKIT% -collection:wb=src -resource:%WREN_RC% -define:WREN_CHANNEL=%WREN_CHANNEL%"

:: 32 MiB of stack for the window thread: Wasm calls run on it (wasm.wasmtime.max_stack_bytes + host_stack_reserve_bytes)
:: and the Visual C++ runtime (vcruntime) linked in, not loaded from vcruntime140.dll: the Windows 10/11 C runtime (ucrt) is part of
:: the system, so wren.exe then needs no file beside it and no Visual C++ redistributable installed
set FLAGS=%FLAGS% -extra-linker-flags:"/STACK:33554432 /NODEFAULTLIB:vcruntime.lib /DEFAULTLIB:libvcruntime.lib"

:: every thread's temporary allocator commits its first block at once: 1 MiB instead of Odin's 4 MiB (with the three
:: dozen threads of the pools, 4 MiB each was over 100 MB of private bytes, mostly never touched)
set "FLAGS=%FLAGS% -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=1048576"

:: the version of the sources (about.odin: APP_COMMIT, APP_COMMIT_DATE): short commit hash, "+" when the tree has
:: uncommitted changes, and its date; "dev" without git. The hash goes in as g<hash>, as git describe writes it (Odin
:: would read an all-digit value as a number).
set "WREN_COMMIT=dev"
set "WREN_DATE="
for /f "delims=" %%i in ('git rev-parse --short HEAD 2^>nul') do set "WREN_COMMIT=g%%i"
for /f "delims=" %%i in ('git log -1 --format^=%%cs 2^>nul') do set "WREN_DATE=%%i"
if not "%WREN_COMMIT%"=="dev" git diff --quiet HEAD -- 2>nul || set "WREN_COMMIT=%WREN_COMMIT%+"
set "FLAGS=%FLAGS% -define:WREN_COMMIT=%WREN_COMMIT%"
if defined WREN_DATE set "FLAGS=%FLAGS% -define:WREN_COMMIT_DATE=%WREN_DATE%"
:: a label shown after the version number (about:wren, the menu, the file's Details...): set WREN_VERSION_LABEL=experimental-2026-10-24 before building
if defined WREN_VERSION_LABEL set "FLAGS=%FLAGS% -define:WREN_VERSION_LABEL=%WREN_VERSION_LABEL%"
:: an experimental build also accepts the licences of the development key pair (public on purpose, worth nothing: tools\experimental.ps1 hands a demonstration licence out with it)
if defined WREN_ACCEPT_DEV_LICENSE_KEY set "FLAGS=%FLAGS% -define:WREN_ACCEPT_DEV_LICENSE_KEY=true"
:: a pre-registered build: this licence (the one line of a .wrenlicense) is put in the profile the first time it has none (browser/license_shell.odin). It must say what it is: a label is required.
if defined WREN_EMBEDDED_LICENSE if not defined WREN_VERSION_LABEL (echo WREN_EMBEDDED_LICENSE needs WREN_VERSION_LABEL: a build with a licence inside is not a release& exit /b 1)
if defined WREN_EMBEDDED_LICENSE set "FLAGS=%FLAGS% -define:WREN_EMBEDDED_LICENSE=%WREN_EMBEDDED_LICENSE%"

set "FLAGS=%FLAGS% -vet -subsystem:windows"
:: the toolkit's render backend (WREN_RENDER=wgpu|d3d11; default d3d11): a wgpu build writes build\wren_prof_wgpu.exe etc. and links wgpu-native
:: as a DLL (wgpu_native.dll, next to the program: Wren already links another Rust static library, the image decoders, and two cannot coexist),
:: with the DXC DLLs next to it (toolkit tools\fetch_wgpu.ps1) so that Direct3D 12 compiles the shaders in 0.3 s instead of 2.8 s
set "WREN_SUFFIX="
if "%WREN_RENDER%"=="wgpu" set "WREN_SUFFIX=_wgpu"
if "%WREN_RENDER%"=="wgpu" set "FLAGS=%FLAGS% -define:TOOLKIT_RENDER=wgpu -define:WGPU_SHARED=true"
:: more Odin flags and an output suffix for experiments (WREN_ODIN_EXTRA="-define:TOOLKIT_WGPU_BACKEND=vulkan" WREN_TAG=_vk)
if defined WREN_ODIN_EXTRA set "FLAGS=%FLAGS% %WREN_ODIN_EXTRA%"
if defined WREN_TAG set "WREN_SUFFIX=%WREN_SUFFIX%%WREN_TAG%"
:: the toolkit's native text backend (WREN_TEXT=native: Fontations, HarfRust and ICU4X instead of DirectWrite's shaper and
:: analyzers, from ext\gui_toolkit\native\text): build\wren_native.exe etc.
:: (built into the image decoders' library, tools\build_media.ps1 above: a program links one Rust static library at most)
if "%WREN_TEXT%"=="native" set "FLAGS=%FLAGS% -define:FONT_BACKEND=native -define:FONT_NATIVE_LINK=false"
if "%WREN_TEXT%"=="native" set "WREN_SUFFIX=%WREN_SUFFIX%_native"
if "%WREN_RENDER%"=="wgpu" powershell -NoProfile -ExecutionPolicy Bypass -File ext\gui_toolkit\tools\fetch_wgpu.ps1 -Dest build >nul || (echo fetching the wgpu dependencies failed & exit /b 1)

set "FAST=-use-separate-modules"


:: ------------------------------------------------------------------------------------------------------------
::  5. The build
:: ------------------------------------------------------------------------------------------------------------

if "%VARIANT%"=="dev"     goto build_dev
if "%VARIANT%"=="debug"   goto build_debug
if "%VARIANT%"=="profile" goto build_profile
if "%VARIANT%"=="check"   goto build_check
if "%VARIANT%"=="release" goto build_release
exit /b 1

:build_dev
:: -debug only adds the PDB: a crash report then names functions and lines (crashtrace)
odin build src/browser -out:build/wren%WREN_SUFFIX%.exe %FLAGS% -o:speed -debug %FAST% || exit /b 1
goto done_browser

:build_debug
odin build src/browser -out:build/wren%WREN_SUFFIX%.exe %FLAGS% -debug %FAST% || exit /b 1
goto done_browser

:build_release
:: one module: LLVM inlines across packages
odin build src/browser -out:build/wren%WREN_SUFFIX%.exe %FLAGS% -o:speed || exit /b 1
goto done_browser

:build_profile
:: one module, as the release; a PDB for the profiler; no Direct3D debug layer (GPU and present times as shipped)
odin build src/browser -out:build/wren_prof%WREN_SUFFIX%.exe %FLAGS% -o:speed -debug -define:PROFILE=true -define:D3D_DEBUG=false || exit /b 1
echo built build\wren_prof%WREN_SUFFIX%.exe
exit /b 0

:build_check
:: debug information, Odin's bounds checks and assertions, the contracts checked in debug builds only (thread
:: ownership), and every allocation of the process tracked (src\base\memory.odin). At exit the blocks still allocated
:: go to <profile>\memtrack.txt (or WREN_MEMTRACK_REPORT); WREN_MEMTRACK_FAIL=1 makes them exit code 3,
:: WREN_MEMTRACK_STACK=1 records each block's call stack. Never shipped: the tracker serializes every allocation.
odin build src/browser -out:build/wren_check%WREN_SUFFIX%.exe %FLAGS% -debug -define:WREN_TRACK_MEMORY=true %FAST% || exit /b 1
echo built build\wren_check%WREN_SUFFIX%.exe
exit /b 0

:done_browser
>build\wren.channel echo %WREN_CHANNEL%
echo built build\wren%WREN_SUFFIX%.exe (%VARIANT%, %WREN_CHANNEL% channel)
exit /b 0


:: ------------------------------------------------------------------------------------------------------------
::  :usage
:: ------------------------------------------------------------------------------------------------------------
:usage
echo usage: build.bat [variant]
echo.
echo   dev       (default) optimised, PDB, fast to compile          -^> build\wren.exe
echo   debug     debug information, no optimisation                 -^> build\wren.exe
echo   profile   optimised, PDB, the built-in profiler (perf.ps1)   -^> build\wren_prof.exe
echo   check     debug, every allocation tracked, leak report       -^> build\wren_check.exe
echo   release   what the release packages (one module, amber icon) -^> build\wren.exe
echo   help      this text
echo.
echo environment:
echo   WREN_RENDER=wgpu      the WebGPU render backend (-^> wren_wgpu.exe, wren_prof_wgpu.exe...)
echo   WREN_TAG=_x           a suffix for the output name, to keep several builds side by side
echo   WREN_ODIN_EXTRA=...   more Odin flags
echo   WREN_TOOLKIT=path     another gui_toolkit checkout instead of ext\gui_toolkit
echo   WREN_ANY_ODIN=1       build with another Odin than odin.version says
echo.
echo then: build\wren.exe [URL]   tests: powershell -File tools\test_all.ps1 -Quick
exit /b 0


:: ------------------------------------------------------------------------------------------------------------
::  :step "what" script.ps1 : runs a build script quietly; on failure says which one to run by hand
:: ------------------------------------------------------------------------------------------------------------
:step
powershell -NoProfile -ExecutionPolicy Bypass -File %2 >nul && exit /b 0
echo %~1 failed: run  powershell -File %2
exit /b 1
