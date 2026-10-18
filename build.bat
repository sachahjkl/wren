@echo off
:: Builds the browser with the Odin compiler. Output: build\browser.exe
::   build.bat [debug]       (default: optimized)
:: gui_toolkit is a git submodule (ext\gui_toolkit), pinned to a release tag and imported as "toolkit:<package>".
setlocal
cd /D "%~dp0"
if not exist ext\gui_toolkit\ui (
  echo ext\gui_toolkit is empty: run  git submodule update --init
  exit /b 1
)
if not exist build mkdir build
set "COLL=-collection:toolkit=ext/gui_toolkit"
if "%1"=="debug" (
  odin build src -out:build/browser.exe %COLL% -debug -vet -subsystem:windows
) else (
  odin build src -out:build/browser.exe %COLL% -o:speed -vet -subsystem:windows
)
if errorlevel 1 exit /b 1
echo built build\browser.exe
