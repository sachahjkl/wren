@echo off
:: Builds the browser with the Odin compiler. Output: build\browser.exe
::   build.bat [debug|profile]       (default: optimized; profile = optimized + PDB + measurement hooks -> build\browser_prof.exe)
:: Dependencies are pinned git submodules, imported through Odin collections:
::   ext\gui_toolkit -> "toolkit:<package>"     ext\wamr -> build\wamr\wamr.lib (tools\build_wamr.bat, built once)
:: and the Wasmtime C API, a pinned release checked by SHA-256 -> build\wasmtime (tools\fetch_wasmtime.ps1, fetched once).
setlocal
cd /D "%~dp0"
if exist ext\gui_toolkit\ui goto have_toolkit
echo ext\gui_toolkit is empty: run  git submodule update --init
exit /b 1
:have_toolkit
:: the stamp changes when the set of WAMR sources does (it no longer carries the wasm-c-api, which Wasmtime provides)
set "WAMR_STAMP="
if exist build\wamr\STAMP set /p WAMR_STAMP=<build\wamr\STAMP
if exist build\wamr\wamr.lib if "%WAMR_STAMP%"=="no-c-api-1" goto have_wamr
echo building the Wasm interpreter (WAMR)...
call tools\build_wamr.bat || exit /b 1
:have_wamr
powershell -NoProfile -ExecutionPolicy Bypass -File tools\fetch_wasmtime.ps1 >nul || (echo fetching Wasmtime failed & exit /b 1)
if not exist build mkdir build
:: host-call thunks for the import signatures of the sources (rewrites src\wasm\thunks_generated.odin only on change)
odin run src/tools/wasmthunks -collection:wb=src -vet -out:build/wasmthunks.exe || exit /b 1
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
