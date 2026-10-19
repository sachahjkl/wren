@echo off
:: Builds the browser with the Odin compiler. Output: build\browser.exe
::   build.bat [debug|profile]       (default: optimized; profile = optimized + PDB + measurement hooks -> build\browser_prof.exe)
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
powershell -NoProfile -ExecutionPolicy Bypass -File tools\fetch_wasmtime.ps1 >nul || (echo fetching Wasmtime failed & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_lexbor.ps1 >nul || (echo building Lexbor failed: run tools\build_lexbor.ps1 & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_media.ps1 >nul || (echo building the image decoders failed: run tools\build_media.ps1 & exit /b 1)
if not exist build mkdir build
:: the web API from its description (api\*.widl): host bindings, guest SDK, docs, conformance tests (only what changed)
odin run src/tools/bindgen -collection:wb=src -vet -out:build/bindgen.exe || exit /b 1
:: the JavaScript engine (native\js: QuickJS-ng compiled to Wasm with zig, pinned, and pre-initialized) -> build\js\wren_js.wasm,
:: embedded in browser.exe (src\js\image); rebuilt only when its sources change
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_js.ps1 >nul || (echo building the JavaScript engine failed: run tools\build_js.ps1 & exit /b 1)
set "COLL=-collection:toolkit=ext/gui_toolkit -collection:wb=src -resource:src/browser/wren.rc"
:: 32 MiB of stack for the window thread: Wasm calls run on it (wasm.wasmtime.max_stack_bytes + host_stack_reserve_bytes)
set "COLL=%COLL% -extra-linker-flags:/STACK:33554432"
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
if "%1"=="debug" goto debug
if "%1"=="profile" goto profile
odin build src/browser -out:build/browser.exe %COLL% -o:speed -vet -subsystem:windows
goto done
:profile
:: (no Direct3D debug layer: GPU and present times as in a release build)
odin build src/browser -out:build/browser_prof.exe %COLL% -o:speed -debug -define:PROFILE=true -define:D3D_DEBUG=false -vet -subsystem:windows
if errorlevel 1 exit /b 1
echo built build\browser_prof.exe
exit /b 0
:debug
odin build src/browser -out:build/browser.exe %COLL% -debug -vet -subsystem:windows
:done
if errorlevel 1 exit /b 1
echo built build\browser.exe
