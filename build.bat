@echo off
:: Builds the browser with the Odin compiler. Output: build\browser.exe
::   build.bat [debug|profile]       (default: optimized; profile = optimized + PDB + measurement hooks -> build\browser_prof.exe)
:: Dependencies are pinned git submodules, imported through Odin collections (ext\gui_toolkit -> "toolkit:<package>"),
:: and the Wasmtime C API, a pinned release checked by SHA-256 -> build\wasmtime (tools\fetch_wasmtime.ps1, fetched once).
:: The built-in image decoders (native\media, Rust: resvg, image-webp, zenavif-parse, rav1d, qcms; crates pinned by Cargo.lock,
:: NASM by SHA-256) -> build\media\wren_media.lib (tools\build_media.ps1, rebuilt only when its sources change).
setlocal
cd /D "%~dp0"
if exist ext\gui_toolkit\ui goto have_toolkit
echo ext\gui_toolkit is empty: run  git submodule update --init
exit /b 1
:have_toolkit
powershell -NoProfile -ExecutionPolicy Bypass -File tools\fetch_wasmtime.ps1 >nul || (echo fetching Wasmtime failed & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_media.ps1 >nul || (echo building the image decoders failed: run tools\build_media.ps1 & exit /b 1)
if not exist build mkdir build
:: the web API from its description (api\*.widl): host bindings, guest SDK, docs, conformance tests (only what changed)
odin run src/tools/bindgen -collection:wb=src -vet -out:build/bindgen.exe || exit /b 1
set "COLL=-collection:toolkit=ext/gui_toolkit -collection:wb=src -resource:src/browser/wren.rc"
if "%1"=="debug" goto debug
if "%1"=="profile" goto profile
odin build src/browser -out:build/browser.exe %COLL% -o:speed -vet -subsystem:windows
goto done
:profile
odin build src/browser -out:build/browser_prof.exe %COLL% -o:speed -debug -define:PROFILE=true -vet -subsystem:windows
if errorlevel 1 exit /b 1
echo built build\browser_prof.exe
exit /b 0
:debug
odin build src/browser -out:build/browser.exe %COLL% -debug -vet -subsystem:windows
:done
if errorlevel 1 exit /b 1
echo built build\browser.exe
