@echo off
:: Builds the browser with the Odin compiler. Output: build\browser.exe
::   build.bat [release|debug|profile]   (default: optimized; profile = optimized + PDB + measurement hooks -> build\browser_prof.exe)
:: Every build is a development build (blueprint icon, about:home and the menu say "development build") but
:: build.bat release, the one the release workflow packages (amber icon). The channel goes in as -define:WREN_CHANNEL
:: (about.odin: APP_CHANNEL) with its icon (src\browser\wren.rc / wren_dev.rc), and in build\browser.channel next to
:: build\browser.exe, which tools\package.ps1 checks.
:: Dependencies are pinned git submodules, imported through Odin collections (ext\gui_toolkit -> "toolkit:<package>"),
:: and the Wasmtime C API, a pinned release checked by SHA-256 -> build\wasmtime (tools\fetch_wasmtime.ps1, fetched once).
:: The built-in image decoders (native\media, Rust: resvg, image-webp, zenavif-parse, rav1d, qcms; crates pinned by Cargo.lock,
:: NASM by SHA-256) -> build\media\wren_media.lib (tools\build_media.ps1, rebuilt only when its sources change).
:: Lexbor (ext\lexbor) and the C shims (src\shim) -> build\lexbor\lexbor.lib (tools\build_lexbor.ps1, MSVC, same rule).
:: The JavaScript engine (native\js, QuickJS-ng + the generated bindings, zig cc, pinned) -> build\js\wren_js.wasm (tools\build_js.ps1).
setlocal
cd /D "%~dp0"
if exist ext\gui_toolkit\ui goto have_toolkit
echo ext\gui_toolkit is empty: run  git submodule update --init
exit /b 1
:have_toolkit
:: the Odin compiler this tree is written for (odin.version; the CI installs that release, pinned by SHA-256 in
:: .github\actions\setup\action.yml): another one may build differently or not at all. WREN_ANY_ODIN=1 skips the check.
set /p WREN_ODIN=<odin.version
if defined WREN_ANY_ODIN goto have_odin
odin version 2>nul | findstr /C:"%WREN_ODIN%" >nul && goto have_odin
echo This tree needs Odin %WREN_ODIN% (odin.version); found:
odin version
echo Install that release, or set WREN_ANY_ODIN=1 to build anyway.
exit /b 1
:have_odin
powershell -NoProfile -ExecutionPolicy Bypass -File tools\fetch_wasmtime.ps1 >nul || (echo fetching Wasmtime failed & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_lexbor.ps1 >nul || (echo building Lexbor failed: run tools\build_lexbor.ps1 & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_media.ps1 >nul || (echo building the image decoders failed: run tools\build_media.ps1 & exit /b 1)
if not exist build mkdir build
:: the web API from its description (api\*.widl): host bindings, guest SDK, docs, conformance tests (only what changed)
odin run src/tools/bindgen -collection:wb=src -vet -out:build/bindgen.exe || exit /b 1
:: the JavaScript engine (native\js: QuickJS-ng compiled to Wasm with zig, pinned, and pre-initialized) -> build\js\wren_js.wasm,
:: embedded in browser.exe (src\js\image); rebuilt only when its sources change
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_js.ps1 >nul || (echo building the JavaScript engine failed: run tools\build_js.ps1 & exit /b 1)
set "WREN_CHANNEL=dev"
set "WREN_RC=src/browser/wren_dev.rc"
if "%1"=="release" set "WREN_CHANNEL=release"
if "%1"=="release" set "WREN_RC=src/browser/wren.rc"
set "COLL=-collection:toolkit=ext/gui_toolkit -collection:wb=src -resource:%WREN_RC% -define:WREN_CHANNEL=%WREN_CHANNEL%"
:: 32 MiB of stack for the window thread: Wasm calls run on it (wasm.wasmtime.max_stack_bytes + host_stack_reserve_bytes)
set "COLL=%COLL% -extra-linker-flags:/STACK:33554432"
:: every thread's temporary allocator takes a first block of this size, committed at once (4 MiB by default: with the
:: three dozen threads of the pools, over 100 MB of private bytes, mostly never touched); a bigger need adds a block
set "COLL=%COLL% -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=1048576"
:: the version of the sources (about.odin: APP_COMMIT, APP_COMMIT_DATE): short commit hash ("+" when the tree has
:: uncommitted changes) and its date; "dev" without git. The hash goes in as g<hash> (as git describe writes it): Odin
:: would read an all-digit value as a number.
set "WREN_COMMIT=dev"
set "WREN_DATE="
for /f "delims=" %%i in ('git rev-parse --short HEAD 2^>nul') do set "WREN_COMMIT=g%%i"
for /f "delims=" %%i in ('git log -1 --format^=%%cs 2^>nul') do set "WREN_DATE=%%i"
if "%WREN_COMMIT%"=="dev" goto have_version
git diff --quiet HEAD -- 2>nul || set "WREN_COMMIT=%WREN_COMMIT%+"
:have_version
set "COLL=%COLL% -define:WREN_COMMIT=%WREN_COMMIT%"
if defined WREN_DATE set "COLL=%COLL% -define:WREN_COMMIT_DATE=%WREN_DATE%"
:: the toolkit's render backend (WREN_RENDER=wgpu|d3d11; default d3d11): a wgpu build writes build\browser_prof_wgpu.exe etc. and links wgpu-native
:: as a DLL (wgpu_native.dll, next to the program: Wren already links another Rust static library, the image decoders, and two cannot coexist),
:: with the DXC DLLs next to it (toolkit tools\fetch_wgpu.ps1) so that Direct3D 12 compiles the shaders in 0.3 s instead of 2.8 s
set "WREN_SUFFIX="
if "%WREN_RENDER%"=="wgpu" set "WREN_SUFFIX=_wgpu"
if "%WREN_RENDER%"=="wgpu" set "COLL=%COLL% -define:TOOLKIT_RENDER=wgpu -define:WGPU_SHARED=true"
:: more Odin flags and an output suffix for experiments (WREN_ODIN_EXTRA="-define:TOOLKIT_WGPU_BACKEND=vulkan" WREN_TAG=_vk)
if defined WREN_ODIN_EXTRA set "COLL=%COLL% %WREN_ODIN_EXTRA%"
if defined WREN_TAG set "WREN_SUFFIX=%WREN_SUFFIX%%WREN_TAG%"
if "%WREN_RENDER%"=="wgpu" powershell -NoProfile -ExecutionPolicy Bypass -File ext\gui_toolkit\tools\fetch_wgpu.ps1 -Dest build >nul || (echo fetching the wgpu dependencies failed & exit /b 1)
if "%1"=="debug" goto debug
if "%1"=="profile" goto profile
if "%1"=="check" goto check
odin build src/browser -out:build/browser%WREN_SUFFIX%.exe %COLL% -o:speed -vet -subsystem:windows
goto done
:profile
:: (no Direct3D debug layer: GPU and present times as in a release build)
odin build src/browser -out:build/browser_prof%WREN_SUFFIX%.exe %COLL% -o:speed -debug -define:PROFILE=true -define:D3D_DEBUG=false -vet -subsystem:windows
if errorlevel 1 exit /b 1
echo built build\browser_prof%WREN_SUFFIX%.exe
exit /b 0
:check
:: the check build: debug information, Odin's bounds checks and assertions, the contracts checked in debug builds only
:: (thread ownership), and every allocation of the process tracked (src\base\memory.odin). At exit the blocks still
:: allocated go to <profile>\memtrack.txt (or WREN_MEMTRACK_REPORT); WREN_MEMTRACK_FAIL=1 makes them exit code 3,
:: WREN_MEMTRACK_STACK=1 records each block's call stack. Never shipped: the tracker serializes every allocation.
odin build src/browser -out:build/browser_check%WREN_SUFFIX%.exe %COLL% -debug -define:WREN_TRACK_MEMORY=true -vet -subsystem:windows
if errorlevel 1 exit /b 1
echo built build\browser_check%WREN_SUFFIX%.exe
exit /b 0
:debug
odin build src/browser -out:build/browser%WREN_SUFFIX%.exe %COLL% -debug -vet -subsystem:windows
:done
if errorlevel 1 exit /b 1
>build\browser.channel echo %WREN_CHANNEL%
echo built build\browser%WREN_SUFFIX%.exe (%WREN_CHANNEL%)
