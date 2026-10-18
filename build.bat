@echo off
:: Builds the browser with the Odin compiler. Output: build\browser.exe
::   build.bat [debug|profile]       (default: optimized; profile = optimized + PDB + measurement hooks -> build\browser_prof.exe)
:: Dependencies are pinned git submodules, imported through Odin collections:
::   ext\gui_toolkit -> "toolkit:<package>"     ext\wamr -> build\wamr\wamr.lib (tools\build_wamr.bat, built once)
setlocal
cd /D "%~dp0"
if exist ext\gui_toolkit\ui goto have_toolkit
echo ext\gui_toolkit is empty: run  git submodule update --init
exit /b 1
:have_toolkit
if exist build\wamr\wamr.lib goto have_wamr
echo building the Wasm runtime...
call tools\build_wamr.bat || exit /b 1
:have_wamr
if not exist build mkdir build
set "COLL=-collection:toolkit=ext/gui_toolkit -collection:wb=src"
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
